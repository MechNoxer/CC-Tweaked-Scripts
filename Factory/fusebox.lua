-- fusebox.lua : factory manager
-- Monitor  : touch panel with every line (tap = ON/OFF), current job per line.
-- Computer : click a line name for its menu: new job, saved recipes, cancel job, allowed items.
-- Jobs can feed another line directly (buffer chest -> next line's input chest).

local VERSION    = "2.0.0"
local UPDATE_URL = "https://raw.githubusercontent.com/MechNoxer/CC-Tweaked-Scripts/main/Factory/fusebox.lua"

local PROTO       = "factory"
local DATA        = "fusebox.dat"
local TIMEOUT     = 15   -- seconds without heartbeat = OFFLINE
local MAX_RECIPES = 8

---------------------------------------------------------------- updater
local function newer(a, b)   -- true if version a > version b
  local pa, pb = {}, {}
  for n in a:gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
  for n in b:gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

-- Returns true if the file was replaced (caller should restart)
local function checkUpdate()
  if not http then print("HTTP disabled, skipping update check"); return false end
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
  term.clear(); term.setCursorPos(1, 1)
  print("v" .. VERSION .. " - checking GitHub for updates...")
  local res = http.get(UPDATE_URL .. "?t=" .. os.epoch("utc"))
  if not res then print("Update check failed (offline?)"); sleep(1); return false end
  local src = res.readAll(); res.close()
  if not src:find("factory manager", 1, true) then print("GitHub file is not fusebox.lua - skipped"); sleep(2); return false end
  local remote = src:match('local VERSION%s*=%s*"([^"]+)"')
  if not remote or not newer(remote, VERSION) then print("Up to date"); return false end
  print("Updating " .. VERSION .. " -> " .. remote)
  local f = fs.open(shell.getRunningProgram(), "w"); f.write(src); f.close()
  sleep(1)
  return true
end

if checkUpdate() then return shell.run(shell.getRunningProgram()) end

local modem = peripheral.find("modem", function(_, m) return not m.isWireless() end)
if not modem then error("No wired modem found", 0) end
rednet.open(peripheral.getName(modem))

local mon
local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")

---------------------------------------------------------------- state
-- lines[name] = { id, desired, actual, seen, allow, rev, job, status, input, buffer, recipes, last }
local lines = {}
local nextId = 1

local function save()
  local t = { nextId = nextId, lines = {} }
  for name, l in pairs(lines) do
    t.lines[name] = { on = l.desired, allow = l.allow, rev = l.rev or 0, job = l.job,
                      recipes = l.recipes, input = l.input, last = l.last }
  end
  local f = fs.open(DATA, "w"); f.write(textutils.serialize(t)); f.close()
end

local function load()
  if not fs.exists(DATA) then return end
  local f = fs.open(DATA, "r")
  local t = textutils.unserialize(f.readAll()) or {}
  f.close()
  if t.lines then   -- v2 format
    nextId = t.nextId or 1
    for name, d in pairs(t.lines) do
      lines[name] = { desired = d.on, allow = d.allow, rev = d.rev or 0, job = d.job,
                      recipes = d.recipes or {}, input = d.input, last = d.last }
    end
  else              -- v1 formats
    for name, d in pairs(t) do
      if type(d) == "table" then
        lines[name] = { desired = d.on, allow = d.allow, rev = d.rev or 0, recipes = {} }
      else
        lines[name] = { desired = d, rev = 0, recipes = {} }
      end
    end
  end
end

local function sorted()
  local names = {}
  for name in pairs(lines) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function online(l)
  return l and l.seen ~= nil and (os.clock() - l.seen) < TIMEOUT
end

local function refresh() os.queueEvent("fb_refresh") end

---------------------------------------------------------------- items / rules
local labels = {}   -- item id -> display name (learned from ME)

local function itemLabel(it)
  local d = it.displayName or it.name
  return (d:gsub("^%[(.*)%]$", "%1"))
end

local function nice(id)
  if not id then return "anything" end
  return labels[id] or (id:gsub("^[^:]*:", ""):gsub("_", " "))
end

local function meItems()
  if not bridge then return {}, "No ME Bridge on network - type item ids (with ':')" end
  local ok, list
  if bridge.listItems then ok, list = pcall(bridge.listItems) else ok, list = pcall(bridge.getItems, {}) end
  if not ok or type(list) ~= "table" then return {}, "ME read failed: " .. tostring(list) end
  for _, it in ipairs(list) do labels[it.name] = itemLabel(it) end
  table.sort(list, function(a, b) return itemLabel(a):lower() < itemLabel(b):lower() end)
  return list, #list .. " item types in ME"
end

local function globToPattern(g)
  return "^" .. g:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
end

-- "minecraft:copper_ingot" exact | "create:*" pattern | "~ingot" name/id contains
local function ruleMatches(a, id, lbl)
  if a:sub(1, 1) == "~" then
    local k = a:sub(2):lower()
    return id:lower():find(k, 1, true) ~= nil or (lbl ~= nil and lbl:lower():find(k, 1, true) ~= nil)
  end
  return a == id or (a:find("*", 1, true) ~= nil and id:find(globToPattern(a)) ~= nil)
end

local function covered(allow, id, lbl)
  if not allow then return true end
  if not id then return false end
  for _, a in ipairs(allow) do
    if ruleMatches(a, id, lbl or labels[id]) then return true end
  end
  return false
end

local function keywords(q)
  local out = {}
  for raw in q:gmatch("[^,]+") do
    local k = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if k ~= "" then out[#out + 1] = k:lower() end
  end
  return out
end

local function matchesAny(kws, id, lbl)
  if #kws == 0 then return true end
  for _, k in ipairs(kws) do
    if id:lower():find(k, 1, true) or lbl:lower():find(k, 1, true) then return true end
  end
  return false
end

local function ruleLabel(a)
  if a:sub(1, 1) == "~" then return "contains: " .. a:sub(2) end
  return a
end

---------------------------------------------------------------- talking to lines
local function send(name, msg)
  local l = lines[name]
  if l and l.id then msg.name = name; rednet.send(l.id, msg, PROTO) end
end

local function setLine(name, on)
  local l = lines[name]
  if not l then return end
  l.desired = on
  send(name, { type = "set", on = on })
end

local function setAll(on)
  for name in pairs(lines) do setLine(name, on) end
  save()
end

local function pushAllow(name)
  local l = lines[name]
  send(name, { type = "allow", allow = l.allow, rev = l.rev or 0 })
end

local function allowChanged(name)
  local l = lines[name]
  l.rev = (l.rev or 0) + 1
  save(); pushAllow(name)
end

local function pushJob(name)
  send(name, { type = "job", job = lines[name].job })
end

---------------------------------------------------------------- jobs
local function destName(d) return type(d) == "table" and d.line or "ME" end

local function jobText(j, st)
  if not j then return "" end
  local ins = {}
  for _, i in ipairs(j.inputs) do
    ins[#ins + 1] = nice(i.name) .. (j.fed and "" or (" x" .. i.count))
  end
  local from = j.fed and ("from " .. (j.upstream or "?")) or table.concat(ins, "+")
  if j.fed and #ins > 0 then from = ins[1] .. " " .. from end
  local made = st and st.id == j.id and (" [" .. (st.produced or 0) .. "]") or ""
  return from .. " > " .. nice(j.output) .. " > " .. destName(j.dest) .. made
end

local function recipeKey(r)
  local ins = {}
  for _, i in ipairs(r.inputs) do ins[#ins + 1] = i.name end
  return table.concat(ins, "+") .. "|" .. (r.output or "?") .. "|" .. r.dest
end

local function saveRecipe(name, inputs, output, dest)
  local l = lines[name]
  l.recipes = l.recipes or {}
  local r = { inputs = {}, output = output, dest = dest }
  for _, i in ipairs(inputs) do r.inputs[#r.inputs + 1] = { name = i.name, count = i.count } end
  local key = recipeKey(r)
  for i = #l.recipes, 1, -1 do
    if recipeKey(l.recipes[i]) == key then table.remove(l.recipes, i) end
  end
  table.insert(l.recipes, 1, r)
  while #l.recipes > MAX_RECIPES do table.remove(l.recipes) end
end

-- the recipe a line uses when it gets fed `item` automatically
local function recipeFor(name, item)
  for _, r in ipairs(lines[name].recipes or {}) do
    if #r.inputs == 1 and r.inputs[1].name == item then return r end
  end
end

local function newJobId()
  local id = nextId
  nextId = nextId + 1
  return id
end

-- inputs = { {name=, count=}, ... }, output = item id or nil, dest = "ME" or line name
-- Returns true, message or false, reason. Refuses if any line in the chain is busy/offline/not allowed.
local function createJob(name, inputs, output, dest)
  local l = lines[name]
  if not online(l) then return false, name .. " is offline" end
  if l.job then return false, name .. " already has a job" end
  for _, i in ipairs(inputs) do
    if not covered(l.allow, i.name) then return false, nice(i.name) .. " is not allowed on " .. name end
  end

  -- walk the chain of lines this job feeds into
  local chain, visited = {}, { [name] = true }
  local cur, item, prev = (dest ~= "ME") and dest or nil, output, name
  while cur do
    local d = lines[cur]
    if not d then return false, "unknown line " .. cur end
    if visited[cur] then return false, "loop: " .. cur .. " is already in this chain" end
    visited[cur] = true
    if not online(d) then return false, cur .. " is offline" end
    if d.job then return false, cur .. " is busy (job #" .. d.job.id .. ")" end
    if not d.input then return false, cur .. " has no input chest (update its line.lua)" end
    if d.allow and not item then return false, cur .. " has a whitelist; set this job's output item" end
    if item and not covered(d.allow, item) then return false, nice(item) .. " is not allowed on " .. cur end
    local r = recipeFor(cur, item)
    local dj = { inputs = item and { { name = item, count = 0 } } or {}, fed = true, upstream = prev,
                 output = r and r.output or nil, dest = "ME" }
    chain[#chain + 1] = { name = cur, job = dj }
    local nextDest = r and r.dest ~= "ME" and r.dest or nil
    item, prev, cur = dj.output, cur, nextDest
  end

  -- build and hand out the jobs
  local first = { inputs = inputs, output = output, dest = "ME" }
  local all = { { name = name, job = first } }
  for _, c in ipairs(chain) do all[#all + 1] = c end
  for i, c in ipairs(all) do
    c.job.id = newJobId()
    local nxt = all[i + 1]
    if nxt then c.job.dest = { line = nxt.name, chest = lines[nxt.name].input } end
  end
  for _, c in ipairs(all) do
    lines[c.name].job = c.job
    pushJob(c.name)
  end
  saveRecipe(name, inputs, output, dest)
  save(); refresh()
  local names = {}
  for _, c in ipairs(all) do names[#names + 1] = c.name end
  return true, "Started: " .. table.concat(names, " > ")
end

-- lines that push into `name` must stop doing so: send their output to ME instead
local function redirectUpstream(name)
  for un, u in pairs(lines) do
    if u.job and type(u.job.dest) == "table" and u.job.dest.line == name then
      u.job.dest = "ME"
      pushJob(un)
    end
  end
end

local function finishJob(name, st)
  local l = lines[name]
  if not l.job then return end
  redirectUpstream(name)
  l.last = { text = jobText(l.job), produced = st and st.produced or 0, cancelled = st and st.cancelled }
  -- tell lines fed by this one that no more input is coming
  for dn, d in pairs(lines) do
    if d.job and d.job.fed and d.job.upstream == name and not d.job.upstreamDone then
      d.job.upstreamDone = true
      pushJob(dn)
    end
  end
  l.job = nil
  pushJob(name)
  save(); refresh()
end

local function cancelJob(name)
  local l = lines[name]
  if not l.job then return end
  redirectUpstream(name)
  if online(l) then
    l.job.cancelling = true
    send(name, { type = "cancel", id = l.job.id })
  else
    finishJob(name, { cancelled = true })
  end
  save(); refresh()
end

local function onStatus(sender, m)
  local l = lines[m.name]
  if not l then
    l = { desired = m.on, allow = m.allow, rev = m.rev or 0, recipes = {} }
    lines[m.name] = l
    save()
  end
  l.id, l.actual, l.seen = sender, m.on, os.clock()
  l.status, l.input, l.ver, l.clutchOk = m.job, m.input or l.input, m.ver, m.clutchOk

  if l.desired ~= l.actual then send(m.name, { type = "set", on = l.desired }) end
  if (m.rev or 0) ~= (l.rev or 0) then pushAllow(m.name) end

  -- keep the line's job in sync with ours
  if l.job then
    if not m.job or m.job.id ~= l.job.id then
      pushJob(m.name)
    elseif m.job.state == "done" then
      finishJob(m.name, m.job)
    elseif l.job.cancelling and m.job.state ~= "cancel" then
      send(m.name, { type = "cancel", id = l.job.id })
    end
  elseif m.job then
    pushJob(m.name)   -- line has a job we don't know: close it
  end
  refresh()
end

---------------------------------------------------------------- drawing helpers
local function fill(t, x, y, w, h, bg)
  t.setBackgroundColor(bg)
  local s = string.rep(" ", w)
  for yy = y, y + h - 1 do t.setCursorPos(x, yy); t.write(s) end
end

local function status(l)
  if not online(l) then return "OFFLINE", colors.lightGray end
  if l.desired ~= l.actual then return "SYNCING", colors.orange end
  if l.clutchOk == false then return "NO RELAY", colors.orange end
  if l.job then
    if l.job.cancelling then return "CANCEL", colors.orange end
    if l.status and l.status.warn then return "WARN", colors.orange end
    if l.actual then return "RUNNING", colors.lime end
    return "PAUSED", colors.orange
  end
  if l.actual then return "IDLE", colors.lightGray end
  return "OFF", colors.red
end

---------------------------------------------------------------- main panel (monitor + computer)
local lastCount = -1

local function findMonitor()
  mon = peripheral.find("monitor")
  lastCount = -1
end

local function fitMonitor(count)
  if not mon then return end
  for _, s in ipairs({ 1.5, 1, 0.5 }) do
    mon.setTextScale(s)
    local w, h = mon.getSize()
    if (w >= 30 and count * 4 + 5 <= h) or s == 0.5 then return end
  end
end

-- tiles are 3 rows high on the monitor (if they fit), 1 row on the computer
local function layout(t, count)
  local w, h = t.getSize()
  local rowH = (t ~= term and count * 4 + 5 <= h) and 3 or 1
  local step = rowH > 1 and rowH + 1 or 1
  return w, h, rowH, step
end

local panelMsg, panelMsgColor = "", colors.lightGray

local function drawPanel(t)
  local names = sorted()
  local w, h, rowH, step = layout(t, #names)
  local tileBg = rowH > 1 and colors.gray or colors.black

  t.setBackgroundColor(colors.black); t.clear()
  fill(t, 1, 1, w, 1, colors.gray)
  t.setCursorPos(2, 1); t.setTextColor(colors.white); t.write("FACTORY FUSEBOX")
  local v = "v" .. VERSION
  t.setCursorPos(w - #v, 1); t.setTextColor(colors.lightGray); t.write(v)

  if t == term then
    t.setBackgroundColor(colors.black); t.setTextColor(colors.gray); t.setCursorPos(1, 2)
    t.write(("ON=toggle  name=jobs/items  U=update  mon:" .. (mon and peripheral.getName(mon) or "none")):sub(1, w))
  end

  if #names == 0 then
    t.setBackgroundColor(colors.black); t.setTextColor(colors.gray)
    t.setCursorPos(2, 3); t.write("Waiting for line terminals...")
  end

  for i, name in ipairs(names) do
    local y = 3 + (i - 1) * step
    if y + rowH - 1 > h - rowH - 1 then break end
    local l = lines[name]
    local st, col = status(l)
    local mid = y + (rowH > 1 and 0 or 0)
    local swBg = l.desired and colors.green or colors.red

    fill(t, 1, y, w, rowH, tileBg)
    fill(t, 1, y, 7, rowH, swBg)
    t.setCursorPos(2, y + math.floor(rowH / 2)); t.setBackgroundColor(swBg); t.setTextColor(colors.white)
    t.write(l.desired and " ON " or " OFF")

    t.setBackgroundColor(tileBg); t.setCursorPos(9, mid); t.setTextColor(colors.white)
    local room = math.max(1, w - #st - 11)
    local txt = (i .. ". " .. name):sub(1, room)
    t.write(txt)
    local tag = l.allow and (" [" .. #l.allow .. " rules]") or " [all items]"
    if #txt + #tag <= room then t.setTextColor(colors.lightGray); t.write(tag) end
    t.setCursorPos(w - #st, mid); t.setTextColor(col); t.write(st)

    -- job line (second row of the tile on the monitor)
    if rowH > 1 then
      t.setCursorPos(9, y + 1)
      if l.job then
        t.setTextColor(colors.yellow); t.write(("#" .. l.job.id .. " " .. jobText(l.job, l.status)):sub(1, w - 9))
      elseif l.last then
        t.setTextColor(colors.lightGray); t.write(("last: " .. l.last.text .. " (" .. l.last.produced .. ")"):sub(1, w - 9))
      else
        t.setTextColor(colors.gray); t.write("no job")
      end
      if l.status and l.status.warn then
        t.setCursorPos(9, y + 2); t.setTextColor(colors.orange); t.write(l.status.warn:sub(1, w - 9))
      end
    end
  end

  if t == term and panelMsg ~= "" then
    t.setBackgroundColor(colors.black); t.setCursorPos(1, h - 1); t.setTextColor(panelMsgColor); t.write(panelMsg:sub(1, w))
  end

  local by, half = h - rowH + 1, math.floor(w / 2)
  local bm = by + math.floor(rowH / 2)
  fill(t, 1, by, half - 1, rowH, colors.green)
  fill(t, half + 1, by, w - half, rowH, colors.red)
  t.setTextColor(colors.white)
  t.setBackgroundColor(colors.green); t.setCursorPos(math.max(1, math.floor((half - 7) / 2) + 1), bm); t.write("ALL ON")
  t.setBackgroundColor(colors.red); t.setCursorPos(half + math.max(1, math.floor((w - half - 7) / 2) + 1), bm); t.write("ALL OFF")
  t.setBackgroundColor(colors.black)
end

local function drawMonitor()
  if not mon then return end
  local count = 0
  for _ in pairs(lines) do count = count + 1 end
  if count ~= lastCount then fitMonitor(count); lastCount = count end
  drawPanel(mon)
end

-- returns "toggle", name | "open", name | nil
local function panelHit(t, x, y)
  local names = sorted()
  local w, h, rowH, step = layout(t, #names)
  if y >= h - rowH + 1 then setAll(x <= math.floor(w / 2)); return end
  if y < 3 or (y - 3) % step >= rowH then return end
  local name = names[math.floor((y - 3) / step) + 1]
  if not name then return end
  if t == term and x > 7 then return "open", name end
  setLine(name, not lines[name].desired); save()
  return "toggle", name
end

---------------------------------------------------------------- computer UI widgets
local W, H = term.getSize()

local function header(title)
  fill(term, 1, 1, W, 1, colors.gray)
  term.setCursorPos(2, 1); term.setTextColor(colors.white); term.write(title:sub(1, W - 9))
  term.setCursorPos(W - 6, 1); term.setBackgroundColor(colors.red); term.write(" Back ")
  term.setBackgroundColor(colors.black)
end

-- Generic list screen. opts: title, sub (string or fn), search (bool), query, hint, rows(query) -> rows
-- row = { label, right, color, rightColor, ... }. Returns row, query  (nil = back)
local function listSelect(opts)
  local query, sel, scroll, msg = opts.query or "", 1, 0, opts.msg
  while true do
    local rows = opts.rows(query)
    sel = math.max(1, math.min(sel, #rows))
    local top = 3 + (opts.search and 1 or 0)
    local bottom = H - 1
    local n = bottom - top + 1
    if sel < scroll + 1 then scroll = sel - 1 end
    if sel > scroll + n then scroll = sel - n end

    term.setBackgroundColor(colors.black); term.clear()
    header(opts.title)
    local sub = type(opts.sub) == "function" and opts.sub() or opts.sub
    if sub then term.setCursorPos(1, 2); term.setTextColor(colors.lightGray); term.write(sub:sub(1, W)) end
    if opts.search then
      term.setCursorPos(1, 3); term.setTextColor(colors.yellow); term.write("Search: ")
      term.setTextColor(colors.white); term.write(query)
    end
    for i = 1, n do
      local r = rows[scroll + i]
      if not r then break end
      local y = top + i - 1
      term.setCursorPos(1, y)
      term.setBackgroundColor(scroll + i == sel and colors.blue or colors.black); term.clearLine()
      term.setTextColor(r.color or colors.white); term.write((" " .. r.label):sub(1, W))
      if r.right and #r.label + #r.right + 3 <= W then
        term.setCursorPos(W - #r.right, y); term.setTextColor(r.rightColor or colors.gray); term.write(r.right)
      end
    end
    if #rows == 0 then
      term.setCursorPos(2, top); term.setTextColor(colors.gray); term.write(opts.empty or "Nothing here")
    end
    term.setBackgroundColor(colors.black); term.setCursorPos(1, H)
    if msg then term.setTextColor(msg[2] or colors.orange); term.write(msg[1]:sub(1, W))
    else term.setTextColor(colors.gray); term.write((opts.hint or "Enter/click=select  F1/Back=back"):sub(1, W)) end

    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "char" and opts.search then
      query = query .. ev[2]; sel, msg = 1, nil
    elseif e == "key" then
      local k = ev[2]
      if k == keys.backspace and opts.search and query ~= "" then query = query:sub(1, -2); sel = 1
      elseif k == keys.up then sel = math.max(1, sel - 1)
      elseif k == keys.down then sel = math.min(#rows, sel + 1)
      elseif (k == keys.enter or k == keys.numPadEnter) and rows[sel] and not rows[sel].info then return rows[sel], query
      elseif k == keys.f1 or (k == keys.backspace and (not opts.search or query == "")) then return nil, query
      end
    elseif e == "mouse_click" then
      local x, y = ev[3], ev[4]
      if y == 1 and x >= W - 6 then return nil, query end
      if y >= top and y <= bottom then
        local idx = scroll + (y - top + 1)
        if rows[idx] and not rows[idx].info then return rows[idx], query end
      end
    elseif e == "mouse_scroll" then
      sel = math.max(1, math.min(#rows, sel + ev[2]))
    end
  end
end

local function promptNumber(title, label, default)
  local s = default and tostring(default) or ""
  while true do
    term.setBackgroundColor(colors.black); term.clear()
    header(title)
    term.setCursorPos(2, 4); term.setTextColor(colors.yellow); term.write(label)
    term.setCursorPos(2, 6); term.setTextColor(colors.white); term.write("> " .. s .. "_")
    term.setCursorPos(1, H); term.setTextColor(colors.gray); term.write("Type a number, Enter=ok, F1/Back=cancel")
    local ev = { os.pullEvent() }
    if ev[1] == "char" and ev[2]:match("%d") and #s < 7 then s = s .. ev[2]
    elseif ev[1] == "key" then
      if ev[2] == keys.backspace then s = s:sub(1, -2)
      elseif ev[2] == keys.enter or ev[2] == keys.numPadEnter then
        local n = tonumber(s)
        if n and n > 0 then return n end
      elseif ev[2] == keys.f1 then return nil end
    elseif ev[1] == "mouse_click" and ev[4] == 1 and ev[3] >= W - 6 then return nil end
  end
end

-- item picker; extra = rows shown on top (e.g. "Done", "Anything"). Returns row or nil
local function pickItem(title, sub, filter, extra)
  local items, info = meItems()
  local row = listSelect({
    title = title, sub = sub, search = true,
    hint = "Type to search  Enter=pick  F1=back   " .. info,
    rows = function(q)
      local rows = {}
      for _, r in ipairs(extra or {}) do rows[#rows + 1] = r end
      if q:find(":", 1, true) then
        rows[#rows + 1] = { label = "+ use id \"" .. q .. "\"", color = colors.lime, id = q }
      end
      local kws = keywords(q)
      for _, it in ipairs(items) do
        local lbl = itemLabel(it)
        if (not filter or filter(it.name, lbl)) and matchesAny(kws, it.name, lbl) then
          rows[#rows + 1] = { label = lbl, right = it.name, id = it.name }
        end
      end
      return rows
    end,
  })
  return row
end

---------------------------------------------------------------- screens
local function allowEditor(name)
  local query = ""
  local items, info = meItems()
  while true do
    local l = lines[name]
    local row
    row, query = listSelect({
      title = "Allowed items: " .. name, search = true, query = query,
      sub = function()
        return (l.allow and ("WHITELIST: " .. #l.allow .. " rules") or "ALL ITEMS ALLOWED") .. "  (first row switches)"
      end,
      hint = "Word=keyword  a, b=several  id:*=pattern  F1=back  " .. info,
      rows = function(q)
        local rows, exact = {}, {}
        rows[1] = { label = l.allow and "[ switch to: all items allowed ]" or "[ switch to: whitelist ]",
                    color = colors.cyan, kind = "mode" }
        for _, a in ipairs(l.allow or {}) do exact[a] = true end
        local kws = keywords(q)
        if #kws > 0 then
          local n, new = 0, {}
          for _, it in ipairs(items) do if matchesAny(kws, it.name, itemLabel(it)) then n = n + 1 end end
          for _, k in ipairs(kws) do if not exact["~" .. k] then new[#new + 1] = k end end
          if #new > 0 then
            rows[#rows + 1] = { label = "+ allow all containing: " .. table.concat(new, ", ") .. " (" .. n .. " in ME)",
                                color = colors.lime, kind = "contains", kws = new }
          end
          if (q:find(":", 1, true) or q:find("*", 1, true)) and not exact[q] then
            rows[#rows + 1] = { label = "+ add \"" .. q .. "\"", color = colors.lime, kind = "add", id = q }
          end
        end
        local sortedAllow = { table.unpack(l.allow or {}) }
        table.sort(sortedAllow)
        for _, a in ipairs(sortedAllow) do
          if matchesAny(kws, a, a) then
            rows[#rows + 1] = { label = "[x] " .. ruleLabel(a), color = a:sub(1, 1) == "~" and colors.yellow or colors.white,
                                kind = "entry", id = a }
          end
        end
        for _, it in ipairs(items) do
          local lbl = itemLabel(it)
          if not exact[it.name] and matchesAny(kws, it.name, lbl) then
            local on = l.allow and covered(l.allow, it.name, lbl)
            rows[#rows + 1] = { label = (on and "[*] " or "[ ] ") .. lbl, right = it.name,
                                color = on and colors.lime or colors.white, kind = "item", id = it.name }
          end
        end
        return rows
      end,
    })
    if not row then return end

    local function add(id)
      l.allow = l.allow or {}
      for _, a in ipairs(l.allow) do if a == id then return end end
      l.allow[#l.allow + 1] = id
    end
    if row.kind == "mode" then
      if l.allow then l.backup, l.allow = l.allow, nil else l.allow, l.backup = l.backup or {}, nil end
    elseif row.kind == "contains" then
      for _, k in ipairs(row.kws) do add("~" .. k) end
      query = ""
    elseif row.kind == "add" or row.kind == "item" then
      add(row.id); query = ""
    elseif row.kind == "entry" then
      for i, a in ipairs(l.allow) do if a == row.id then table.remove(l.allow, i); break end end
    end
    allowChanged(name)
  end
end

local function pickDest(name)
  local row = listSelect({
    title = "Send output of " .. name .. " to",
    sub = "A line must be online, idle and allow the item",
    rows = function()
      local rows = { { label = "ME system", dest = "ME", color = colors.cyan } }
      for _, n in ipairs(sorted()) do
        if n ~= name then
          local d = lines[n]
          local note = not online(d) and "offline" or (d.job and "busy" or "idle")
          rows[#rows + 1] = { label = "line " .. n, right = note, dest = n,
                              rightColor = note == "idle" and colors.lime or colors.orange }
        end
      end
      return rows
    end,
  })
  return row and row.dest
end

-- returns true when a job was started
local function askAmountsAndStart(name, inputs, output, dest)
  local final = {}
  for _, i in ipairs(inputs) do
    local n = promptNumber("Job for " .. name, "How many " .. nice(i.name) .. "?", i.count)
    if not n then return false end
    final[#final + 1] = { name = i.name, count = n }
  end
  local ok, msg = createJob(name, final, output, dest)
  panelMsg, panelMsgColor = msg, ok and colors.lime or colors.red
  return ok
end

local function newJob(name)
  local l = lines[name]
  local inputs = {}
  while true do
    local extra = {}
    if #inputs > 0 then
      local names = {}
      for _, i in ipairs(inputs) do names[#names + 1] = nice(i.name) end
      extra[1] = { label = "> Done (inputs: " .. table.concat(names, ", ") .. ")", color = colors.cyan, done = true }
    end
    local row = pickItem("Input " .. (#inputs + 1) .. " for " .. name,
                         #inputs == 0 and "Pick what this line takes in (from ME)" or "Add another input or pick Done",
                         function(id, lbl) return covered(l.allow, id, lbl) end, extra)
    if not row then return end
    if row.done then break end
    inputs[#inputs + 1] = { name = row.id }
  end

  local orow = pickItem("Output of " .. name, "What comes out in the buffer chest?", nil,
                        { { label = "> Anything (send whole buffer)", color = colors.cyan, any = true } })
  if not orow then return end
  local output = (not orow.any) and orow.id or nil

  local dest = pickDest(name)
  if not dest then return end
  return askAmountsAndStart(name, inputs, output, dest)
end

local function recipeText(r)
  local ins = {}
  for _, i in ipairs(r.inputs) do ins[#ins + 1] = nice(i.name) .. " x" .. i.count end
  return table.concat(ins, " + ") .. " > " .. nice(r.output) .. " > " .. r.dest
end

local function lineMenu(name)
  while true do
    local l = lines[name]
    local row = listSelect({
      title = "Line: " .. name,
      sub = function()
        local st = status(l)
        return st .. "  |  input chest: " .. (l.input or "?") .. "  |  v" .. (l.ver or "?")
      end,
      msg = panelMsg ~= "" and { panelMsg, panelMsgColor } or nil,
      rows = function()
        local rows = {}
        if l.job then
          rows[#rows + 1] = { label = "Job #" .. l.job.id .. ": " .. jobText(l.job, l.status), color = colors.yellow, info = true }
          if l.status and l.status.warn then rows[#rows + 1] = { label = "  ! " .. l.status.warn, color = colors.orange, info = true } end
          rows[#rows + 1] = { label = l.job.cancelling and "  (cancelling...)" or "x Cancel job (returns chest contents to ME)",
                              color = colors.red, act = "cancel", info = l.job.cancelling }
        else
          rows[#rows + 1] = { label = "+ New job", color = colors.lime, act = "new" }
          for i, r in ipairs(l.recipes or {}) do
            rows[#rows + 1] = { label = "> " .. recipeText(r), act = "recipe", recipe = r, right = "#" .. i }
          end
        end
        rows[#rows + 1] = { label = "Allowed items" .. (l.allow and (" (" .. #l.allow .. " rules)") or " (all)"),
                            color = colors.cyan, act = "allow" }
        if l.last then
          rows[#rows + 1] = { label = "Last: " .. l.last.text .. "  made " .. l.last.produced ..
                              (l.last.cancelled and " (cancelled)" or ""), color = colors.gray, info = true }
        end
        return rows
      end,
    })
    panelMsg = ""
    if not row then return end
    if row.act == "cancel" then cancelJob(name)
    elseif row.act == "new" then newJob(name)
    elseif row.act == "recipe" then askAmountsAndStart(name, row.recipe.inputs, row.recipe.output, row.recipe.dest)
    elseif row.act == "allow" then allowEditor(name) end
  end
end

-- main computer screen; returns "update" when U pressed
local function mainScreen()
  while true do
    drawPanel(term)
    local ev = { os.pullEvent() }
    if ev[1] == "mouse_click" then
      local what, name = panelHit(term, ev[3], ev[4])
      panelMsg = ""
      if what == "open" then lineMenu(name) end
    elseif ev[1] == "char" then
      if ev[2] == "u" then return "update" end
      local n = tonumber(ev[2])
      local name = n and sorted()[n]
      if name then setLine(name, not lines[name].desired); save() end
    end
  end
end

---------------------------------------------------------------- network loop (runs alongside the UI)
local function netLoop()
  local tick = os.startTimer(1)
  drawMonitor()
  while true do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "rednet_message" and ev[4] == PROTO then
      local m = ev[3]
      if type(m) == "table" and m.type == "status" and m.name then onStatus(ev[2], m) end
      drawMonitor()
    elseif e == "timer" and ev[2] == tick then
      tick = os.startTimer(1)
      drawMonitor()
      refresh()
    elseif e == "monitor_touch" and mon and ev[2] == peripheral.getName(mon) then
      panelHit(mon, ev[3], ev[4]); drawMonitor(); refresh()
    elseif e == "peripheral" or e == "peripheral_detach" then
      findMonitor()
      bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
      drawMonitor()
    elseif e == "monitor_resize" then
      lastCount = -1; drawMonitor()
    end
  end
end

---------------------------------------------------------------- start
load()
findMonitor()
local result
parallel.waitForAny(netLoop, function() result = mainScreen() end)
if result == "update" and checkUpdate() then return shell.run(shell.getRunningProgram()) end
shell.run(shell.getRunningProgram())
