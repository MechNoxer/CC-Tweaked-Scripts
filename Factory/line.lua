-- line.lua : production line terminal
-- CC:Tweaked + Advanced Peripherals ME Bridge + Create clutch
-- Pulls items from ME into this line's chest, obeys the fusebox.

local VERSION   = "1.3.0"
local UPDATE_URL = "https://raw.githubusercontent.com/MechNoxer/CC-Tweaked-Scripts/main/Factory/line.lua"

local PROTO     = "factory"
local CFG       = "line.cfg"
local HEARTBEAT = 5    -- seconds between status reports
local REFRESH   = 10   -- seconds between ME list refreshes

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

local function networkInventories()
  local list = {}
  for _, n in ipairs(peripheral.getNames()) do
    if not SIDES[n] and peripheral.hasType(n, "inventory") then list[#list + 1] = n end
  end
  table.sort(list)
  return list
end

-- The ME Bridge does the export, so the chest must be on the wired network
-- (wired modem on the chest), not just touching this computer.
local function pickChest()
  while true do
    local inv = networkInventories()
    if #inv == 0 then
      print("No chests on the wired network.")
      print("Put a wired modem on the chest, connect it")
      print("to the cable and right-click the modem.")
      write("Press Enter to rescan...") read()
    else
      print("Chests on the network:")
      for i, n in ipairs(inv) do print(("  %d) %s"):format(i, n)) end
      local i = tonumber(ask("Target chest number"))
      if inv[i] then return inv[i] end
      print("Invalid choice.")
    end
  end
end

local function setup()
  term.clear(); term.setCursorPos(1, 1)
  print("== Production line setup ==")
  local c = {}
  repeat c.name = ask("Line name (unique)") until c.name
  c.chest = pickChest()
  c.clutchSide = ask("Clutch redstone side", "back")
  c.stopWhenPowered = ask("Clutch stops line when powered? (y/n)", "y"):lower() == "y"
  c.on = false
  saveCfg(c)
  return c
end

local cfg = loadCfg() or setup()
if SIDES[cfg.chest] or not peripheral.isPresent(cfg.chest) then
  term.clear(); term.setCursorPos(1, 1)
  print("Chest '" .. tostring(cfg.chest) .. "' is not on the wired network.")
  cfg.chest = pickChest()
  saveCfg(cfg)
end

---------------------------------------------------------------- peripherals
local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
if not bridge then error("No ME Bridge found (attach it or connect it via wired modem)", 0) end

local modem = peripheral.find("modem", function(_, m) return not m.isWireless() end)
if not modem then error("No wired modem found", 0) end
rednet.open(peripheral.getName(modem))

---------------------------------------------------------------- line state
local function applyState()
  local powered = cfg.on
  if cfg.stopWhenPowered then powered = not cfg.on end
  redstone.setOutput(cfg.clutchSide, powered)
end

local function sendStatus()
  rednet.broadcast({ type = "status", name = cfg.name, on = cfg.on, rev = cfg.allowRev or 0, allow = cfg.allow }, PROTO)
end

---------------------------------------------------------------- allowlist
-- cfg.allow == nil  -> every item allowed
-- cfg.allow == {..} -> only these item ids / patterns ("create:*", "*_ingot")
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

local function isAllowed(id, lbl)
  if cfg.allow == nil then return true end
  for _, a in ipairs(cfg.allow) do
    if ruleMatches(a, id, lbl) then return true end
  end
  return false
end

---------------------------------------------------------------- ME access
local items, filtered = {}, {}
local query, sel, scroll = "", 1, 0
local mode, amountStr = "browse", ""
local msg, msgColor = "Ready", colors.lightGray

local function amountOf(it) return it.amount or it.count or 0 end

local function label(it)
  local d = it.displayName or it.name
  return (d:gsub("^%[(.*)%]$", "%1"))
end

local function refreshItems()
  local fn = bridge.listItems or bridge.getItems
  if not fn then
    msg, msgColor = "Bridge methods: " .. table.concat(peripheral.getMethods(peripheral.getName(bridge)), ","), colors.red
    return
  end
  local ok, list, err
  if bridge.listItems then ok, list, err = pcall(fn) else ok, list, err = pcall(fn, {}) end
  if not ok or type(list) ~= "table" then
    msg, msgColor = "ME read failed: " .. tostring(ok and err or list), colors.red
    return
  end
  items = list
  table.sort(items, function(a, b) return label(a):lower() < label(b):lower() end)
end

local function applyFilter()
  filtered = {}
  local q = query:lower()
  for _, it in ipairs(items) do
    if isAllowed(it.name, label(it)) and (q == "" or label(it):lower():find(q, 1, true) or it.name:lower():find(q, 1, true)) then
      filtered[#filtered + 1] = it
    end
  end
  sel = math.max(1, math.min(sel, #filtered))
end

-- Export in a loop: the bridge may move less than requested per call
local function export(name, count)
  local moved = 0
  while moved < count do
    local req = { name = name, count = count - moved }
    local ok, n, err
    if SIDES[cfg.chest] then
      ok, n, err = pcall(bridge.exportItem, req, cfg.chest)
    elseif bridge.exportItemToPeripheral then
      ok, n, err = pcall(bridge.exportItemToPeripheral, req, cfg.chest)
    else
      ok, n, err = pcall(bridge.exportItem, req, cfg.chest)
    end
    if not ok then return moved, n end
    if type(n) ~= "number" or n <= 0 then return moved, err end
    moved = moved + n
  end
  return moved
end

---------------------------------------------------------------- UI
local w, h = term.getSize()
local listTop, listBottom = 4, h - 2

local function draw()
  term.setBackgroundColor(colors.black); term.clear()

  -- header
  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.gray); term.setTextColor(colors.white)
  term.clearLine(); term.write(" " .. cfg.name)
  term.setTextColor(colors.lightGray); term.write("  v" .. VERSION)
  local st = cfg.on and " RUNNING " or " STOPPED "
  term.setCursorPos(w - #st + 1, 1)
  term.setBackgroundColor(cfg.on and colors.green or colors.red)
  term.write(st)

  -- search bar
  term.setBackgroundColor(colors.black)
  term.setCursorPos(1, 2); term.setTextColor(colors.yellow); term.write("Search: ")
  term.setTextColor(colors.white); term.write(query)
  term.setCursorPos(1, 3); term.setTextColor(colors.gray); term.write(string.rep("-", w))

  -- item list
  local rows = listBottom - listTop + 1
  if sel < scroll + 1 then scroll = sel - 1 end
  if sel > scroll + rows then scroll = sel - rows end
  for i = 1, rows do
    local it = filtered[scroll + i]
    if not it then break end
    local y = listTop + i - 1
    term.setCursorPos(1, y)
    term.setBackgroundColor(scroll + i == sel and colors.blue or colors.black)
    term.setTextColor(colors.white); term.clearLine()
    local cnt = tostring(amountOf(it))
    term.write(" " .. label(it):sub(1, w - #cnt - 3))
    term.setCursorPos(w - #cnt, y); term.setTextColor(colors.lightGray); term.write(cnt)
  end
  if #filtered == 0 then
    term.setCursorPos(2, listTop); term.setTextColor(colors.gray)
    term.write((cfg.allow and #cfg.allow == 0) and "No items allowed - set them on the fusebox" or "No items")
  end

  -- status / amount prompt
  term.setBackgroundColor(colors.black)
  term.setCursorPos(1, h - 1)
  if mode == "amount" then
    term.setTextColor(colors.yellow); term.write("Amount of " .. label(filtered[sel]) .. ": ")
    term.setTextColor(colors.white); term.write(amountStr)
  else
    term.setTextColor(msgColor); term.write(msg:sub(1, w))
  end
  term.setCursorPos(1, h); term.setTextColor(colors.gray)
  term.write(mode == "amount" and "Enter=send  Bksp on empty=cancel"
                               or "Type=search Enter=request F5=refresh F9=update")
end

local function doRequest()
  local n, it = tonumber(amountStr), filtered[sel]
  mode = "browse"
  if not (n and n > 0 and it) then msg, msgColor = "Cancelled", colors.lightGray; return end
  if not isAllowed(it.name, label(it)) then msg, msgColor = "Not allowed on this line", colors.red; return end
  local moved, err = export(it.name, n)
  if moved == n then
    msg, msgColor = "Sent " .. moved .. "x " .. label(it), colors.lime
  else
    msg, msgColor = "Sent " .. moved .. "/" .. n .. (err and (" - " .. tostring(err)) or " (chest full?)"), colors.orange
  end
  refreshItems(); applyFilter()
end

---------------------------------------------------------------- main loop
applyState()
refreshItems(); applyFilter()
sendStatus()
local hbTimer = os.startTimer(HEARTBEAT)
local rfTimer = os.startTimer(REFRESH)
draw()

local relaunch = false
while not relaunch do
  local ev = { os.pullEvent() }
  local e = ev[1]

  if e == "rednet_message" and ev[4] == PROTO then
    local m = ev[3]
    if type(m) == "table" and m.type == "set" and m.name == cfg.name and m.on ~= cfg.on then
      cfg.on = m.on; saveCfg(cfg); applyState(); sendStatus()
      msg, msgColor = "Fusebox switched line " .. (cfg.on and "ON" or "OFF"), colors.orange
    elseif type(m) == "table" and m.type == "allow" and m.name == cfg.name then
      cfg.allow, cfg.allowRev = m.allow, m.rev; saveCfg(cfg)
      if mode == "amount" and filtered[sel] and not isAllowed(filtered[sel].name, label(filtered[sel])) then mode = "browse" end
      applyFilter(); sendStatus()
      msg, msgColor = "Allowed items updated by fusebox", colors.orange
    end

  elseif e == "timer" then
    if ev[2] == hbTimer then
      sendStatus(); hbTimer = os.startTimer(HEARTBEAT)
    elseif ev[2] == rfTimer then
      if mode == "browse" then refreshItems(); applyFilter() end
      rfTimer = os.startTimer(REFRESH)
    end

  elseif e == "char" then
    if mode == "browse" then
      query = query .. ev[2]; sel = 1; applyFilter()
    elseif ev[2]:match("%d") and #amountStr < 6 then
      amountStr = amountStr .. ev[2]
    end

  elseif e == "key" then
    local k = ev[2]
    if mode == "browse" then
      if k == keys.backspace then query = query:sub(1, -2); sel = 1; applyFilter()
      elseif k == keys.up then sel = math.max(1, sel - 1)
      elseif k == keys.down then sel = math.max(1, math.min(#filtered, sel + 1))
      elseif k == keys.f5 then refreshItems(); applyFilter(); msg, msgColor = "Refreshed", colors.lightGray
      elseif k == keys.f9 then
        relaunch = checkUpdate()
        if not relaunch then msg, msgColor = "Already on latest (v" .. VERSION .. ")", colors.lightGray end
      elseif (k == keys.enter or k == keys.numPadEnter) and filtered[sel] then mode, amountStr = "amount", ""
      end
    else
      if k == keys.backspace then
        if amountStr == "" then mode = "browse" else amountStr = amountStr:sub(1, -2) end
      elseif k == keys.enter or k == keys.numPadEnter then
        doRequest()
      end
    end

  elseif e == "mouse_click" and mode == "browse" then
    local y = ev[4]
    if y >= listTop and y <= listBottom then
      local idx = scroll + (y - listTop + 1)
      if filtered[idx] then
        if idx == sel then mode, amountStr = "amount", "" else sel = idx end
      end
    end

  elseif e == "mouse_scroll" and mode == "browse" then
    sel = math.max(1, math.min(#filtered, sel + ev[2]))
  end

  draw()
end

shell.run(shell.getRunningProgram())
