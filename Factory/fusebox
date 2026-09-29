-- fusebox.lua : central on/off control for all production lines
-- Shows on an attached monitor (touch) and on the computer screen (click / 1-9 keys).

local PROTO   = "factory"
local DATA    = "fusebox.dat"
local TIMEOUT = 15   -- seconds without heartbeat = OFFLINE

local modem = peripheral.find("modem", function(_, m) return not m.isWireless() end)
if not modem then error("No wired modem found", 0) end
rednet.open(peripheral.getName(modem))

local mon = peripheral.find("monitor")
if mon then mon.setTextScale(0.5) end

---------------------------------------------------------------- state
local lines = {}   -- name -> { id, desired, actual, seen }

local function save()
  local t = {}
  for name, l in pairs(lines) do t[name] = l.desired end
  local f = fs.open(DATA, "w"); f.write(textutils.serialize(t)); f.close()
end

local function load()
  if not fs.exists(DATA) then return end
  local f = fs.open(DATA, "r")
  local t = textutils.unserialize(f.readAll()) or {}
  f.close()
  for name, d in pairs(t) do lines[name] = { desired = d } end
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
local function drawTo(t)
  local w, h = t.getSize()
  t.setBackgroundColor(colors.black); t.clear()
  t.setCursorPos(1, 1)
  t.setBackgroundColor(colors.gray); t.setTextColor(colors.white)
  t.clearLine(); t.write(" FACTORY FUSEBOX")

  local names = sorted()
  if #names == 0 then
    t.setBackgroundColor(colors.black); t.setTextColor(colors.gray)
    t.setCursorPos(2, 3); t.write("Waiting for line terminals...")
  end

  for i, name in ipairs(names) do
    local y = i + 2
    if y > h - 2 then break end
    local l = lines[name]
    local online = l.seen and (os.clock() - l.seen) < TIMEOUT

    t.setCursorPos(1, y)
    t.setBackgroundColor(l.desired and colors.green or colors.red); t.setTextColor(colors.white)
    t.write(l.desired and "  ON  " or "  OFF ")
    t.setBackgroundColor(colors.black)
    t.write(" " .. i .. ". " .. name)

    local st, col
    if not online then st, col = "OFFLINE", colors.gray
    elseif l.actual ~= l.desired then st, col = "SYNCING", colors.orange
    elseif l.actual then st, col = "RUNNING", colors.lime
    else st, col = "STOPPED", colors.red end
    t.setCursorPos(w - #st + 1, y); t.setTextColor(col); t.write(st)
  end

  t.setCursorPos(1, h)
  t.setBackgroundColor(colors.green); t.setTextColor(colors.white); t.write(" ALL ON ")
  t.setBackgroundColor(colors.black); t.write(" ")
  t.setBackgroundColor(colors.red); t.write(" ALL OFF ")
  t.setBackgroundColor(colors.black)
end

local function draw()
  drawTo(term)
  if mon then drawTo(mon) end
end

local function click(t, x, y)
  local _, h = t.getSize()
  if y == h then
    if x <= 8 then setAll(true) elseif x >= 10 and x <= 18 then setAll(false) end
    return
  end
  local name = sorted()[y - 2]
  if name then setLine(name, not lines[name].desired); save() end
end

---------------------------------------------------------------- main loop
load()
local tick = os.startTimer(1)
draw()

while true do
  local ev = { os.pullEvent() }
  local e = ev[1]

  if e == "rednet_message" and ev[4] == PROTO then
    local sender, m = ev[2], ev[3]
    if type(m) == "table" and m.type == "status" and m.name then
      local l = lines[m.name]
      if not l then
        l = { desired = m.on }   -- new lines keep whatever state they report
        lines[m.name] = l
        save()
      end
      l.id, l.actual, l.seen = sender, m.on, os.clock()
      if l.desired ~= l.actual then
        rednet.send(sender, { type = "set", name = m.name, on = l.desired }, PROTO)
      end
    end

  elseif e == "timer" and ev[2] == tick then
    tick = os.startTimer(1)

  elseif e == "monitor_touch" and mon then
    click(mon, ev[3], ev[4])

  elseif e == "mouse_click" then
    click(term, ev[3], ev[4])

  elseif e == "char" then
    local n = tonumber(ev[2])
    local name = n and sorted()[n]
    if name then setLine(name, not lines[name].desired); save() end
  end

  draw()
end
