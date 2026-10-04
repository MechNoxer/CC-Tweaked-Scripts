-- line.lua : production line server
-- CC:Tweaked + Advanced Peripherals ME Bridge + Redstone Relay -> Create clutch
-- Runs jobs given by the fusebox: fills the input chest from ME, runs the line,
-- drains the buffer chest to ME or directly into the next line's input chest.

local VERSION    = "2.0.3"
local UPDATE_URL = "https://raw.githubusercontent.com/MechNoxer/CC-Tweaked-Scripts/main/Factory/line.lua"

local PROTO     = "factory"
local CFG       = "line.cfg"
local HEARTBEAT = 5    -- seconds between status reports
local TICK      = 1    -- seconds between job steps
local QUIET     = 10   -- seconds without any movement before a job counts as finished

local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

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
  if not src:find("production line server", 1, true) then print("GitHub file is not line.lua - skipped"); sleep(2); return false end
  local remote = src:match('local VERSION%s*=%s*"([^"]+)"')
  if not remote or not newer(remote, VERSION) then print("Up to date"); return false end
  print("Updating " .. VERSION .. " -> " .. remote)
  local f = fs.open(shell.getRunningProgram(), "w"); f.write(src); f.close()
  sleep(1)
  return true
end

if checkUpdate() then return shell.run(shell.getRunningProgram()) end

---------------------------------------------------------------- config
local function loadCfg()
  if not fs.exists(CFG) then return nil end
  local f = fs.open(CFG, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  return t
end

local function saveCfg(t)
  local f = fs.open(CFG, "w")
  f.write(textutils.serialize(t))
  f.close()
end

local function ask(prompt, default)
  write(prompt .. (default and (" [" .. default .. "]") or "") .. ": ")
  local v = read()
  if v == "" then return default end
  return v
end

local function networkInventories(exclude)
  local list = {}
  for _, n in ipairs(peripheral.getNames()) do
    if not SIDES[n] and n ~= exclude and peripheral.hasType(n, "inventory") then list[#list + 1] = n end
  end
  table.sort(list)
  return list
end

-- Chests must be on the wired network (wired modem on the chest), not just touching the computer
local function pickChest(title, exclude)
  while true do
    local inv = networkInventories(exclude)
    if #inv == 0 then
      print("No chests on the wired network.")
      print("Put a wired modem on the chest, connect it")
      print("to the cable and right-click the modem.")
      write("Press Enter to rescan...") read()
    else
      print(title .. ":")
      for i, n in ipairs(inv) do print(("  %d) %s"):format(i, n)) end
      local i = tonumber(ask("Number"))
      if inv[i] then return inv[i] end
      print("Invalid choice.")
    end
  end
end

local RELAY_TYPES = { "redstone_relay", "redstoneIntegrator" }

local function networkRelays()
  local list = {}
  for _, n in ipairs(peripheral.getNames()) do
    for _, t in ipairs(RELAY_TYPES) do
      if peripheral.hasType(n, t) then list[#list + 1] = n; break end
    end
  end
  table.sort(list)
  return list
end

local function askSide(prompt, default)
  while true do
    local s = ask(prompt .. " (all/top/bottom/left/right/front/back)", default)
    if s == "all" or SIDES[s] then return s end
    print("Not a valid side.")
  end
end

-- Clutch output: a Redstone Relay on the network, or this computer's own side
local function pickClutch(c)
  local relays = networkRelays()
  print("Clutch redstone output:")
  print("  0) this computer")
  for i, n in ipairs(relays) do print(("  %d) %s"):format(i, n)) end
  local i
  repeat i = tonumber(ask("Choice", #relays > 0 and "1" or "0")) until i and (i == 0 or relays[i])
  c.clutchRelay = relays[i]   -- nil when 0
  print("Side to power. 'all' = every side, so you")
  print("don't need to know which side faces the clutch.")
  c.clutchSide = askSide(c.clutchRelay and "Relay side" or "Computer side", "all")
  c.clutchSetup = 2
  c.stopWhenPowered = ask("Clutch stops line when powered? (y/n)", "y"):lower() == "y"
end

local function pickChests(c)
  c.inputChest  = pickChest("INPUT chest (start of the line, filled from ME)")
  c.bufferChest = pickChest("BUFFER chest (end of the line, finished items)", c.inputChest)
end

local cfg = loadCfg()
if not cfg then
  term.clear(); term.setCursorPos(1, 1)
  print("== Production line setup ==")
  cfg = {}
  repeat cfg.name = ask("Line name (unique)") until cfg.name
  pickChests(cfg)
  pickClutch(cfg)
  cfg.on = false
  saveCfg(cfg)
end

-- upgrades from v1: "chest" became "inputChest", buffer chest is new
if cfg.chest and not cfg.inputChest then cfg.inputChest, cfg.chest = cfg.chest, nil end
if cfg.reconfigure or not (cfg.inputChest and peripheral.isPresent(cfg.inputChest))
   or not (cfg.bufferChest and peripheral.isPresent(cfg.bufferChest)) then
  term.clear(); term.setCursorPos(1, 1)
  print("== Chest setup for line '" .. cfg.name .. "' ==")
  pickChests(cfg)
  if cfg.reconfigure then pickClutch(cfg) end
  cfg.reconfigure = nil
  saveCfg(cfg)
end
if cfg.clutchSetup ~= 2 then
  term.clear(); term.setCursorPos(1, 1)
  pickClutch(cfg)
  saveCfg(cfg)
end

---------------------------------------------------------------- peripherals
local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
if not bridge then error("No ME Bridge found (connect it via wired modem)", 0) end

local modem = peripheral.find("modem", function(_, m) return not m.isWireless() end)
if not modem then error("No wired modem found", 0) end
rednet.open(peripheral.getName(modem))

---------------------------------------------------------------- log
local logLines = {}
local function log(text, color)
  table.insert(logLines, 1, { t = text, c = color or colors.lightGray })
  while #logLines > 6 do table.remove(logLines) end
end

---------------------------------------------------------------- allowlist
-- cfg.allow == nil  -> every item allowed
-- rules: "minecraft:copper_ingot" exact | "create:*" pattern | "~ingot" name/id contains
local function globToPattern(g)
  return "^" .. g:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
end

local function ruleMatches(a, id, lbl)
  if a:sub(1, 1) == "~" then
    local k = a:sub(2):lower()
    return id:lower():find(k, 1, true) ~= nil or (lbl ~= nil and lbl:lower():find(k, 1, true) ~= nil)
  end
  return a == id or (a:find("*", 1, true) ~= nil and id:find(globToPattern(a)) ~= nil)
end

local function isAllowed(id, lbl)
  if cfg.allow == nil then return true end
  for _, a in ipairs(cfg.allow) do
    if ruleMatches(a, id, lbl) then return true end
  end
  return false
end

---------------------------------------------------------------- ME access
-- Advanced Peripherals changed the bridge API between versions:
--   0.7: exportItem(filter, target) / importItem(filter, source) -> number
--   0.8: exportItem(target, filter) / importItem(source, filter) -> table | nil, err
-- So we try the known call forms; the moved count comes from the return value,
-- or from counting the chest when the return value doesn't tell.
local VARIANTS = {
  export = { { "exportItemToPeripheral", false }, { "exportItem", false }, { "exportItem", true } },
  import = { { "importItemFromPeripheral", false }, { "importItem", false }, { "importItem", true } },
}
local working = {}   -- kind -> index of the call form that moved items

local function countItem(chest, name)
  local p = peripheral.wrap(chest)
  if not p then return nil end
  local ok, l = pcall(p.list)
  if not ok or type(l) ~= "table" then return nil end
  local n = 0
  for _, it in pairs(l) do if it.name == name then n = n + it.count end end
  return n
end

local function describe(ok, r, err)
  if not ok then return "error: " .. tostring(r) end
  local t = type(r) == "table" and textutils.serialize(r):gsub("%s+", " ") or tostring(r)
  return t .. (err and (", " .. tostring(err)) or "")
end

-- one bridge call; returns moved count, and on failure a report of every call form tried
local function bridgeMove(kind, name, count, chest)
  local before = countItem(chest, name)
  if not before then return 0, "chest " .. chest .. " not found" end
  local list = VARIANTS[kind]
  local tried = {}
  local from, to = 1, #list
  if working[kind] then from, to = working[kind], working[kind] end
  for i = from, to do
    local fname, targetFirst = list[i][1], list[i][2]
    local fn = bridge[fname]
    if fn then
      local filter = { name = name, count = count }
      local ok, r, err
      if targetFirst then ok, r, err = pcall(fn, chest, filter) else ok, r, err = pcall(fn, filter, chest) end
      -- prefer the count the bridge reports; only measure the chest if it doesn't say
      local moved
      if ok and type(r) == "number" then moved = r
      elseif ok and type(r) == "table" and type(r.count or r.amount) == "number" then moved = r.count or r.amount
      else
        local after = countItem(chest, name) or before
        moved = (kind == "export") and (after - before) or (before - after)
      end
      if moved > 0 then
        working[kind] = i
        return moved
      end
      tried[#tried + 1] = fname .. (targetFirst and "(chest,filter)" or "(filter,chest)") .. " -> " .. describe(ok, r, err)
    end
  end
  return 0, table.concat(tried, " | ")
end

local function export(name, count, target)
  local moved, err = 0, nil
  while moved < count do
    local n
    n, err = bridgeMove("export", name, count - moved, target)
    if n <= 0 then break end
    moved = moved + n
  end
  return moved, err
end

local function import(name, count, source)
  local moved, err = 0, nil
  while moved < count do
    local n
    n, err = bridgeMove("import", name, count - moved, source)
    if n <= 0 then break end
    moved = moved + n
  end
  return moved, err
end

-- nil when unknown
local function meCount(name)
  if not bridge.getItem then return nil end
  local ok, it = pcall(bridge.getItem, { name = name })
  if not ok then return nil end
  if type(it) ~= "table" then return 0 end
  return it.amount or it.count or 0
end

---------------------------------------------------------------- inventories
local function list(chest)
  local p = peripheral.wrap(chest)
  if not p then return nil end
  local ok, l = pcall(p.list)
  if ok and type(l) == "table" then return l, p end
  return nil
end

local function countIn(l, names)
  local n = 0
  for _, it in pairs(l) do
    if not names or names[it.name] then n = n + it.count end
  end
  return n
end

---------------------------------------------------------------- clutch
local clutchOk = true

local function job() return cfg.job end

local function running()
  local j = job()
  return cfg.on and j ~= nil and (j.state == "running")
end

local function applyState()
  local run = running()
  local powered = run
  if cfg.stopWhenPowered then powered = not run end
  local out = redstone
  if cfg.clutchRelay then out = peripheral.wrap(cfg.clutchRelay) end
  if out then
    if cfg.clutchSide == "all" then
      for side in pairs(SIDES) do out.setOutput(side, powered) end
    else
      out.setOutput(cfg.clutchSide, powered)
    end
    clutchOk = true
  else
    clutchOk = false   -- relay missing; retried every tick
  end
end

---------------------------------------------------------------- status
local function sendStatus()
  local j, js = job(), nil
  if j then
    js = { id = j.id, state = j.state, produced = j.produced or 0, warn = j.warn, inputs = {} }
    for i, inp in ipairs(j.inputs) do
      js.inputs[i] = { name = inp.name, count = inp.count, loaded = inp.loaded or 0, short = inp.short }
    end
  end
  rednet.broadcast({
    type = "status", ver = VERSION, name = cfg.name, on = cfg.on,
    rev = cfg.allowRev or 0, allow = cfg.allow,
    input = cfg.inputChest, buffer = cfg.bufferChest,
    job = js, clutchOk = clutchOk,
  }, PROTO)
end

---------------------------------------------------------------- job execution
local activity = os.clock()
local lastInputTotal = -1

local function inputNames(j)
  if #j.inputs == 0 then return nil end   -- unknown input (fed by a line with unknown output)
  local t = {}
  for _, i in ipairs(j.inputs) do t[i.name] = true end
  return t
end

local function stepJob()
  local j = job()
  if not j or j.state == "done" then return false end
  local now, changed = os.clock(), false
  local inL = list(cfg.inputChest)
  local bufL, buf = list(cfg.bufferChest)
  if not inL or not bufL then
    j.warn = "input or buffer chest missing"
    return false
  end

  -- cancelled: return everything in input + buffer to ME, then finish
  if j.state == "cancel" then
    for _, src in ipairs({ { cfg.inputChest, inL }, { cfg.bufferChest, bufL } }) do
      for _, it in pairs(src[2]) do import(it.name, it.count, src[1]) end
    end
    local a, b = list(cfg.inputChest), list(cfg.bufferChest)
    if a and b and next(a) == nil and next(b) == nil then
      j.state = "done"; j.cancelled = true
      log("Job cancelled, chests returned to ME", colors.orange)
    end
    return true
  end

  j.warn = nil

  -- 1) load inputs from ME (only while switched on, and only if not fed by another line)
  if cfg.on and not j.fed then
    for _, i in ipairs(j.inputs) do
      local rem = i.count - (i.loaded or 0)
      if rem > 0 and not i.short then
        local moved, err = export(i.name, rem, cfg.inputChest)
        if moved == 0 and meCount(i.name) ~= 0 then j.warn = "can't export from ME (input chest full?): " .. tostring(err or "") end
        if moved > 0 then
          i.loaded = (i.loaded or 0) + moved
          activity, changed = now, true
        elseif meCount(i.name) == 0 then
          i.short = true; changed = true
          log("ME has no more " .. i.name .. " (" .. (i.loaded or 0) .. "/" .. i.count .. ")", colors.orange)
        end
      end
    end
  end

  -- 2) drain buffer: job output -> next line (per slot), everything else -> ME (per item type)
  local toME = {}
  for slot, it in pairs(bufL) do
    local isOutput = (j.output == nil or it.name == j.output)
    if isOutput and type(j.dest) == "table" then
      local ok, n = pcall(buf.pushItems, j.dest.chest, slot)
      local moved = (ok and type(n) == "number") and n or 0
      if moved > 0 then
        activity, changed = now, true
        j.produced = (j.produced or 0) + moved
      else
        j.warn = "can't push to " .. j.dest.line .. " (chest full/missing)"
      end
    else
      toME[it.name] = (toME[it.name] or 0) + it.count
    end
  end
  for name, count in pairs(toME) do
    local moved, err = import(name, count, cfg.bufferChest)
    if moved > 0 then
      activity, changed = now, true
      if j.output == nil or name == j.output then j.produced = (j.produced or 0) + moved end
    else
      j.warn = "can't import into ME: " .. tostring(err or "?")
    end
  end

  -- 3) watch the input chest for movement
  local total = countIn(inL, inputNames(j))
  if total ~= lastInputTotal then activity, lastInputTotal = now, total end

  -- paused: don't let the quiet timer finish the job
  if not cfg.on then activity = now end

  -- 4) finished?
  local loaded
  if j.fed then
    loaded = j.upstreamDone
  else
    loaded = true
    for _, i in ipairs(j.inputs) do
      if (i.loaded or 0) < i.count and not i.short then loaded = false end
    end
  end
  local bufNow = list(cfg.bufferChest)
  if loaded and total == 0 and bufNow and next(bufNow) == nil and now - activity >= QUIET then
    j.state = "done"; changed = true
    log("Job done: " .. (j.produced or 0) .. " produced", colors.lime)
  end
  return changed
end

---------------------------------------------------------------- UI
local w, h = term.getSize()
local chestCounts = { input = "?", buffer = "?" }

local function short(id)
  return (id or "?"):gsub("^[^:]*:", ""):gsub("_", " ")
end

local function destText(d)
  if type(d) == "table" then return "line " .. d.line end
  return "ME"
end

local function draw()
  local t = term
  t.setBackgroundColor(colors.black); t.clear()
  local j = job()

  -- header
  t.setCursorPos(1, 1); t.setBackgroundColor(colors.gray); t.setTextColor(colors.white); t.clearLine()
  t.write(" " .. cfg.name); t.setTextColor(colors.lightGray); t.write("  v" .. VERSION)
  local st, col
  if not clutchOk then st, col = " NO RELAY ", colors.orange
  elseif not cfg.on then st, col = " OFF ", colors.red
  elseif j and j.state == "running" then st, col = " RUNNING ", colors.green
  elseif j and j.state == "cancel" then st, col = " CANCELLING ", colors.orange
  elseif j then st, col = " DONE ", colors.cyan
  else st, col = " IDLE ", colors.lightGray end
  t.setCursorPos(w - #st + 1, 1); t.setBackgroundColor(col); t.setTextColor(colors.white); t.write(st)
  t.setBackgroundColor(colors.black)

  local y = 3
  local function line(label, text, c)
    t.setCursorPos(1, y); t.setTextColor(colors.yellow); t.write(label)
    t.setTextColor(c or colors.white); t.write(tostring(text):sub(1, w - #label))
    y = y + 1
  end

  if not j then
    line("Job:    ", "none - start one on the fusebox", colors.lightGray)
  else
    line("Job:    ", "#" .. j.id .. (j.fed and ("  fed by " .. (j.upstream or "?") .. (j.upstreamDone and " (done)" or "")) or ""))
    if #j.inputs == 0 then line("Input:  ", "whatever arrives from " .. (j.upstream or "?")) end
    for _, i in ipairs(j.inputs) do
      local txt = short(i.name)
      if not j.fed then
        txt = txt .. "  " .. (i.loaded or 0) .. "/" .. i.count .. (i.short and "  ME EMPTY" or "")
      end
      line("Input:  ", txt, i.short and colors.orange or colors.white)
    end
    line("Output: ", j.output and short(j.output) or "anything in buffer")
    line("To:     ", destText(j.dest))
    line("Made:   ", j.produced or 0, colors.lime)
    if j.warn then
      local rest = j.warn
      line("Warn:   ", rest:sub(1, w - 8), colors.orange)
      rest = rest:sub(w - 7)
      while #rest > 0 and y < h - 4 do
        t.setCursorPos(1, y); t.setTextColor(colors.orange); t.write(rest:sub(1, w))
        rest = rest:sub(w + 1); y = y + 1
      end
    end
  end

  y = y + 1
  -- counts come from the job loop (no peripheral calls while drawing)
  line("In:     ", cfg.inputChest .. "  (" .. chestCounts.input .. " items)", colors.lightGray)
  line("Buffer: ", cfg.bufferChest .. "  (" .. chestCounts.buffer .. " items)", colors.lightGray)
  line("Clutch: ", (cfg.clutchRelay or "computer") .. " / " .. cfg.clutchSide, colors.lightGray)

  y = y + 1
  for _, l in ipairs(logLines) do
    if y >= h then break end
    t.setCursorPos(1, y); t.setTextColor(l.c); t.write(l.t:sub(1, w)); y = y + 1
  end

  t.setCursorPos(1, h); t.setTextColor(colors.gray)
  t.write("F2=setup chests/clutch  F9=update")
end

---------------------------------------------------------------- main loop
-- Three loops run side by side. Chest / ME calls make a coroutine wait for an
-- internal event and drop everything else meanwhile, so the heartbeat and the
-- job work each get their own loop and can never swallow each other's timers.
local relaunch = false
local function redraw() os.queueEvent("line_redraw") end

local function heartbeatLoop()
  while true do
    sendStatus()
    sleep(HEARTBEAT)
  end
end

local function jobLoop()
  while true do
    local ok, changed = pcall(stepJob)
    if not ok then
      log("Job error: " .. tostring(changed), colors.red)
    elseif changed then
      saveCfg(cfg)
    end
    applyState()
    local inL, bufL = list(cfg.inputChest), list(cfg.bufferChest)
    chestCounts.input = inL and countIn(inL) or "?"
    chestCounts.buffer = bufL and countIn(bufL) or "?"
    redraw()
    sleep(TICK)
  end
end

local function handle(m)
  if m.type == "set" and m.on ~= cfg.on then
    cfg.on = m.on; saveCfg(cfg); applyState(); sendStatus()
    log("Fusebox switched line " .. (cfg.on and "ON" or "OFF"), colors.orange)

  elseif m.type == "allow" then
    cfg.allow, cfg.allowRev = m.allow, m.rev; saveCfg(cfg); sendStatus()
    log("Allowed items updated", colors.orange)

  elseif m.type == "job" then
    local cur, new = cfg.job, m.job
    if new == nil then
      if cur then cfg.job = nil; saveCfg(cfg); log("Job #" .. cur.id .. " closed", colors.lightGray) end
    elseif not cur or cur.id ~= new.id then
      -- refuse inputs this line isn't allowed to take
      local bad
      for _, i in ipairs(new.inputs or {}) do
        if not isAllowed(i.name) then bad = i.name end
      end
      new.inputs = new.inputs or {}
      new.state, new.produced = "running", 0
      if bad then new.state, new.warn = "done", "input not allowed: " .. bad end
      cfg.job = new; saveCfg(cfg)
      activity, lastInputTotal = os.clock(), -1
      log("New job #" .. new.id .. (bad and " REFUSED (not allowed)" or ""), bad and colors.red or colors.lime)
    else
      -- same job: take over flags the fusebox may change later
      cur.upstreamDone, cur.dest = new.upstreamDone, new.dest
      saveCfg(cfg)
    end
    applyState(); sendStatus()

  elseif m.type == "cancel" and cfg.job and cfg.job.id == m.id and cfg.job.state ~= "done" then
    cfg.job.state = "cancel"; saveCfg(cfg); applyState(); sendStatus()
  end
end

local function eventLoop()
  draw()
  while true do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "rednet_message" and ev[4] == PROTO then
      local m = ev[3]
      if type(m) == "table" and m.name == cfg.name then handle(m) end
    elseif e == "key" then
      if ev[2] == keys.f9 then
        if checkUpdate() then relaunch = true; return end
      elseif ev[2] == keys.f2 then
        cfg.reconfigure = true; saveCfg(cfg); relaunch = true; return
      end
    end
    draw()
  end
end

log("Line server started", colors.lightGray)
applyState()
parallel.waitForAny(eventLoop, heartbeatLoop, jobLoop)
shell.run(shell.getRunningProgram())
