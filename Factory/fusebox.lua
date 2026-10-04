-- fusebox.lua : central on/off control for all production lines
-- Runs on an advanced monitor (touch tiles, auto-scaled) and mirrors on the computer screen
-- (click / 1-9 keys, U = update). Click a line name on the computer to set its allowed items.

local VERSION = "1.4.0"
local UPDATE_URL = "https://raw.githubusercontent.com/MechNoxer/CC-Tweaked-Scripts/main/Factory/fusebox.lua"

local PROTO   = "factory"
local DATA    = "fusebox.dat"
local TIMEOUT = 15   -- seconds without heartbeat = OFFLINE

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

---------------------------------------------------------------- state
-- name -> { id, desired, actual, seen, allow (nil = all items), rev }
local lines = {}

local function save()
  local t = {}
  for name, l in pairs(lines) do t[name] = { on = l.desired, allow = l.allow, rev = l.rev or 0 } end
  local f = fs.open(DATA, "w"); f.write(textutils.serialize(t)); f.close()
end

local function load()
  if not fs.exists(DATA) then return end
  local f = fs.open(DATA, "r")
  local t = textutils.unserialize(f.readAll()) or {}
  f.close()
  for name, d in pairs(t) do
    if type(d) == "table" then
      lines[name] = { desired = d.on, allow = d.allow, rev = d.rev or 0 }
    else
      lines[name] = { desired = d, rev = 0 }   -- old fusebox.dat format
    end
  end
end

local function pushAllow(name)
  local l = lines[name]
  if l and l.id then
    rednet.send(l.id, { type = "allow", name = name, allow = l.allow, rev = l.rev or 0 }, PROTO)
  end
end

local function allowChanged(name)
  local l = lines[name]
  l.rev = (l.rev or 0) + 1
  save(); pushAllow(name)
end

local function sorted()
  local names = {}
  for name in pairs(lines) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function setLine(name, on)
  local l = lines[name]
  if not l then return end
  l.desired = on
  if l.id then rednet.send(l.id, { type = "set", name = name, on = on }, PROTO) end
end

local function setAll(on)
  for name in pairs(lines) do setLine(name, on) end
  save()
end

---------------------------------------------------------------- drawing
local lastCount = -1

local function findMonitor()
  mon = peripheral.find("monitor")
  lastCount = -1
end

-- Pick the largest text scale that still fits big touch tiles for every line
local function fitMonitor(count)
  if not mon then return end
  for _, s in ipairs({ 1.5, 1, 0.5 }) do
    mon.setTextScale(s)
    local w, h = mon.getSize()
    if (w >= 30 and count * 4 + 5 <= h) or s == 0.5 then return end
  end
end

-- Tiles are 3 rows high on the monitor (if they fit), 1 row on the terminal
local function layout(t, count)
  local w, h = t.getSize()
  local rowH = (t ~= term and count * 4 + 5 <= h) and 3 or 1
  local step = rowH > 1 and rowH + 1 or 1
  return w, h, rowH, step
end

local function fill(t, x, y, w, h, bg)
  t.setBackgroundColor(bg)
  local s = string.rep(" ", w)
  for yy = y, y + h - 1 do t.setCursorPos(x, yy); t.write(s) end
end

local function status(l)
  local online = l.seen and (os.clock() - l.seen) < TIMEOUT
  if not online then return "OFFLINE", colors.lightGray
  elseif l.actual ~= l.desired then return "SYNCING", colors.orange
  elseif l.actual then return "RUNNING", colors.lime
  else return "STOPPED", colors.red end
end

local function drawTo(t)
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
    t.write("1-9/ON=toggle name=items U=upd mon:" .. (mon and peripheral.getName(mon) or "none"))
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
    local mid = y + math.floor(rowH / 2)
    local swBg = l.desired and colors.green or colors.red

    fill(t, 1, y, w, rowH, tileBg)
    fill(t, 1, y, 7, rowH, swBg)
    t.setCursorPos(2, mid); t.setBackgroundColor(swBg); t.setTextColor(colors.white)
    t.write(l.desired and " ON " or " OFF")
    t.setBackgroundColor(tileBg); t.setCursorPos(9, mid)
    local tag = l.allow and (" [" .. #l.allow .. " items]") or " [all]"
    local room = math.max(1, w - #st - 11)
    local txt = (i .. ". " .. name):sub(1, room)
    t.write(txt)
    if #txt + #tag <= room then t.setTextColor(colors.lightGray); t.write(tag) end
    t.setCursorPos(w - #st, mid); t.setTextColor(col); t.write(st)
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

local function draw()
  local count = 0
  for _ in pairs(lines) do count = count + 1 end
  if count ~= lastCount then fitMonitor(count); lastCount = count end
  drawTo(term)
  if mon then drawTo(mon) end
end

local openEditor   -- defined below

local function click(t, x, y)
  local names = sorted()
  local w, h, rowH, step = layout(t, #names)
  if y >= h - rowH + 1 then setAll(x <= math.floor(w / 2)); return end
  if y < 3 or (y - 3) % step >= rowH then return end
  local name = names[math.floor((y - 3) / step) + 1]
  if not name then return end
  if t == term and x > 7 then openEditor(name); return end
  setLine(name, not lines[name].desired); save()
end

---------------------------------------------------------------- allowlist editor
-- Runs on the computer screen (needs a keyboard). The monitor keeps showing the panel.
local view = "main"
local ed = { name = nil, query = "", sel = 1, scroll = 0, rows = {}, me = {}, msg = "" }

local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")

local function itemLabel(it)
  local d = it.displayName or it.name
  return (d:gsub("^%[(.*)%]$", "%1"))
end

local function globToPattern(g)
  return "^" .. g:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
end

-- Rule formats:  "minecraft:copper_ingot" exact id | "create:*" id pattern
--                "~ingot" keyword: name or id contains "ingot" (case-insensitive)
local function ruleMatches(a, id, lbl)
  if a:sub(1, 1) == "~" then
    local k = a:sub(2):lower()
    return id:lower():find(k, 1, true) ~= nil or (lbl ~= nil and lbl:lower():find(k, 1, true) ~= nil)
  end
  return a == id or (a:find("*", 1, true) ~= nil and id:find(globToPattern(a)) ~= nil)
end

local function covered(allow, id, lbl)
  if not allow then return true end
  for _, a in ipairs(allow) do
    if ruleMatches(a, id, lbl) then return true end
  end
  return false
end

-- "wood, log" -> { "wood", "log" }
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

local function loadME()
  ed.me = {}
  if not bridge then ed.msg = "No ME Bridge on network - type item ids manually"; return end
  local ok, list
  if bridge.listItems then ok, list = pcall(bridge.listItems) else ok, list = pcall(bridge.getItems, {}) end
  if not ok or type(list) ~= "table" then ed.msg = "ME read failed: " .. tostring(list); return end
  ed.me = list
  table.sort(ed.me, function(a, b) return itemLabel(a):lower() < itemLabel(b):lower() end)
  ed.msg = #ed.me .. " item types in ME"
end

local function buildRows()
  local l, q = lines[ed.name], ed.query:lower()
  local rows, exact = {}, {}
  if l.allow then
    for _, a in ipairs(l.allow) do exact[a] = true end
  end
  local kws = keywords(ed.query)
  if #kws > 0 then
    -- keyword rule row: "allow all containing ..."
    local n = 0
    for _, it in ipairs(ed.me) do if matchesAny(kws, it.name, itemLabel(it)) then n = n + 1 end end
    local new = {}
    for _, k in ipairs(kws) do if not exact["~" .. k] then new[#new + 1] = k end end
    if #new > 0 then rows[#rows + 1] = { kind = "contains", kws = new, count = n } end
    -- exact id / pattern row, only when it looks like an id
    if (ed.query:find(":", 1, true) or ed.query:find("*", 1, true)) and not exact[ed.query] then
      rows[#rows + 1] = { kind = "add", id = ed.query }
    end
  end
  if l.allow then
    local sortedAllow = { table.unpack(l.allow) }
    table.sort(sortedAllow)
    for _, a in ipairs(sortedAllow) do
      if q == "" or matchesAny(kws, a, a) then rows[#rows + 1] = { kind = "entry", id = a } end
    end
  end
  for _, it in ipairs(ed.me) do
    if not exact[it.name] and matchesAny(kws, it.name, itemLabel(it)) then
      rows[#rows + 1] = { kind = "item", id = it.name, label = itemLabel(it) }
    end
  end
  ed.rows = rows
  ed.sel = math.max(1, math.min(ed.sel, #rows))
end

openEditor = function(name)
  view, ed.name, ed.query, ed.sel, ed.scroll = "edit", name, "", 1, 0
  loadME(); buildRows()
end

local function addAllow(id)
  local l = lines[ed.name]
  l.allow = l.allow or {}
  for _, a in ipairs(l.allow) do if a == id then return end end
  l.allow[#l.allow + 1] = id
  allowChanged(ed.name)
end

local function removeAllow(id)
  local l = lines[ed.name]
  if not l.allow then return end
  for i, a in ipairs(l.allow) do
    if a == id then table.remove(l.allow, i); allowChanged(ed.name); return end
  end
end

local function toggleMode()
  local l = lines[ed.name]
  if l.allow then l.backup, l.allow = l.allow, nil
  else l.allow, l.backup = l.backup or {}, nil end
  allowChanged(ed.name); buildRows()
end

local function activate(i)
  local r = ed.rows[i]
  if not r then return end
  if r.kind == "contains" then
    for _, k in ipairs(r.kws) do addAllow("~" .. k) end
    ed.query = ""
  elseif r.kind == "add" then addAllow(r.id); ed.query = ""
  elseif r.kind == "entry" then removeAllow(r.id)
  elseif r.kind == "item" then addAllow(r.id); ed.query = "" end
  buildRows()
end

local function edLayout()
  local w, h = term.getSize()
  return w, h, 5, h - 1
end

local function drawEditor()
  local t = term
  local w, h, top, bottom = edLayout()
  local l = lines[ed.name]
  t.setBackgroundColor(colors.black); t.clear()

  fill(t, 1, 1, w, 1, colors.gray)
  t.setCursorPos(2, 1); t.setTextColor(colors.white); t.write(("Allowed items: " .. ed.name):sub(1, w - 9))
  t.setCursorPos(w - 6, 1); t.setBackgroundColor(colors.red); t.write(" Back ")

  t.setCursorPos(1, 2); t.setBackgroundColor(l.allow and colors.orange or colors.green); t.setTextColor(colors.white)
  t.write(l.allow and (" WHITELIST: " .. #l.allow .. " ") or " ALL ITEMS ALLOWED ")
  t.setBackgroundColor(colors.black); t.setTextColor(colors.gray); t.write(" Tab/click=switch")

  t.setCursorPos(1, 3); t.setTextColor(colors.yellow); t.write("Search/add: ")
  t.setTextColor(colors.white); t.write(ed.query)
  t.setCursorPos(1, 4); t.setTextColor(colors.gray); t.write(string.rep("-", w))

  local rows = bottom - top + 1
  if ed.sel < ed.scroll + 1 then ed.scroll = ed.sel - 1 end
  if ed.sel > ed.scroll + rows then ed.scroll = ed.sel - rows end
  for i = 1, rows do
    local idx = ed.scroll + i
    local r = ed.rows[idx]
    if not r then break end
    local y = top + i - 1
    t.setCursorPos(1, y)
    t.setBackgroundColor(idx == ed.sel and colors.blue or colors.black); t.clearLine()
    if r.kind == "contains" then
      t.setTextColor(colors.lime)
      t.write((" + allow all containing: " .. table.concat(r.kws, ", ") .. " (" .. r.count .. " in ME)"):sub(1, w))
    elseif r.kind == "add" then
      t.setTextColor(colors.lime); t.write((" + add \"" .. r.id .. "\"" .. (r.id:find("*", 1, true) and " (pattern)" or "")):sub(1, w))
    elseif r.kind == "entry" then
      t.setTextColor(colors.lime); t.write(" [x] ")
      t.setTextColor(r.id:sub(1, 1) == "~" and colors.yellow or colors.white); t.write(ruleLabel(r.id):sub(1, w - 5))
    else
      local on = covered(l.allow, r.id, r.label)
      t.setTextColor(on and colors.lime or colors.gray); t.write(on and (l.allow and " [*] " or " [ ] ") or " [ ] ")
      t.setTextColor(colors.white); t.write(r.label:sub(1, w - 6))
      local id = r.id
      if 6 + #r.label + #id + 2 <= w then t.setCursorPos(w - #id, y); t.setTextColor(colors.gray); t.write(id) end
    end
  end
  if #ed.rows == 0 then
    t.setCursorPos(2, top); t.setTextColor(colors.gray); t.write("Type a word (ingot), list (wood, log) or id/pattern")
  end

  t.setBackgroundColor(colors.black); t.setCursorPos(1, h); t.setTextColor(colors.gray)
  t.write(("Enter/click=toggle F5=reload F1=back  " .. ed.msg):sub(1, w))
end

---------------------------------------------------------------- main loop
load()
findMonitor()
local tick = os.startTimer(1)

local function drawAll()
  if view == "edit" then
    if mon then
      local count = 0
      for _ in pairs(lines) do count = count + 1 end
      if count ~= lastCount then fitMonitor(count); lastCount = count end
      drawTo(mon)
    end
    drawEditor()
  else
    draw()
  end
end

drawAll()

local relaunch = false
while not relaunch do
  local ev = { os.pullEvent() }
  local e = ev[1]

  if e == "rednet_message" and ev[4] == PROTO then
    local sender, m = ev[2], ev[3]
    if type(m) == "table" and m.type == "status" and m.name then
      local l = lines[m.name]
      if not l then
        -- new line: adopt the state and allowlist it reports
        l = { desired = m.on, allow = m.allow, rev = m.rev or 0 }
        lines[m.name] = l
        save()
      end
      l.id, l.actual, l.seen = sender, m.on, os.clock()
      if l.desired ~= l.actual then
        rednet.send(sender, { type = "set", name = m.name, on = l.desired }, PROTO)
      end
      if (m.rev or 0) ~= (l.rev or 0) then pushAllow(m.name) end
    end

  elseif e == "timer" and ev[2] == tick then
    tick = os.startTimer(1)

  elseif e == "monitor_touch" and mon and ev[2] == peripheral.getName(mon) then
    click(mon, ev[3], ev[4])

  elseif e == "peripheral" or e == "peripheral_detach" then
    findMonitor()
    bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")

  elseif e == "monitor_resize" then
    lastCount = -1

  elseif view == "main" then
    if e == "mouse_click" then
      click(term, ev[3], ev[4])
    elseif e == "char" and ev[2] == "u" then
      relaunch = checkUpdate()
    elseif e == "char" then
      local n = tonumber(ev[2])
      local name = n and sorted()[n]
      if name then setLine(name, not lines[name].desired); save() end
    end

  else -- editor
    local w, h, top, bottom = edLayout()
    if e == "char" then
      ed.query = ed.query .. ev[2]; ed.sel = 1; buildRows()
    elseif e == "key" then
      local k = ev[2]
      if k == keys.backspace then ed.query = ed.query:sub(1, -2); ed.sel = 1; buildRows()
      elseif k == keys.up then ed.sel = math.max(1, ed.sel - 1)
      elseif k == keys.down then ed.sel = math.max(1, math.min(#ed.rows, ed.sel + 1))
      elseif k == keys.enter or k == keys.numPadEnter then activate(ed.sel)
      elseif k == keys.tab then toggleMode()
      elseif k == keys.f5 then loadME(); buildRows()
      elseif k == keys.f1 then view = "main"
      end
    elseif e == "mouse_click" then
      local x, y = ev[3], ev[4]
      if y == 1 and x >= w - 6 then view = "main"
      elseif y == 2 then toggleMode()
      elseif y >= top and y <= bottom then
        local idx = ed.scroll + (y - top + 1)
        if ed.rows[idx] then ed.sel = idx; activate(idx) end
      end
    elseif e == "mouse_scroll" then
      ed.sel = math.max(1, math.min(#ed.rows, ed.sel + ev[2]))
    end
  end

  drawAll()
end

shell.run(shell.getRunningProgram())
