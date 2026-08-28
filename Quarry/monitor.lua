--[[
  monitor.lua — status receiver for quarry.lua turtles
  ------------------------------------------------------
  Run this on a separate computer (not the mining turtle) that has:
   - a wireless (or ender) modem attached to any side
   - a monitor attached to any side

  It listens for status pings broadcast by quarry.lua and shows live
  position, fuel, and status for each turtle, plus a scrolling log.
  Supports multiple turtles at once (each shown in its own block).
]]--

local PROTOCOL = "quarry_status"

-- find and open a wireless modem
local modemSide
for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
        if m.isWireless and m.isWireless() then
            modemSide = side
            break
        end
    end
end
if not modemSide then
    error("No wireless modem found. Attach one and rerun.")
end
rednet.open(modemSide)

-- find a monitor
local mon = peripheral.find("monitor")
if not mon then
    error("No monitor found. Attach one and rerun.")
end
mon.setTextScale(0.5)
local w, h = mon.getSize()

local turtles = {}   -- [senderId] = { label, status, x, y, z, fuel, lastUpdate }
local logLines = {}

local function addLog(line)
    table.insert(logLines, os.date("%H:%M:%S") .. " " .. line)
    while #logLines > 300 do table.remove(logLines, 1) end
end

local function countTurtles()
    local n = 0
    for _ in pairs(turtles) do n = n + 1 end
    return n
end

local function redraw()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    mon.setCursorPos(1, 1)
    mon.setTextColor(colors.yellow)
    mon.write("=== Quarry Turtle Status ===")

    local row = 3
    local blockHeight = 5
    local n = countTurtles()
    -- reserve space for the log section below the turtle blocks
    local logStart = row + math.max(n, 1) * blockHeight + 1

    for id, t in pairs(turtles) do
        mon.setCursorPos(1, row)
        mon.setTextColor(colors.white)
        mon.write((t.label or ("Turtle " .. id)) .. "  [" .. (t.status or "?") .. "]")
        row = row + 1

        mon.setCursorPos(1, row)
        mon.setTextColor(colors.lightGray)
        mon.write(string.format("  pos x=%d y=%d z=%d", t.x or 0, t.y or 0, t.z or 0))
        row = row + 1

        if t.wx then
            mon.setCursorPos(1, row)
            mon.write(string.format("  world x=%d y=%d z=%d", t.wx, t.wy, t.wz))
            row = row + 1
        end

        mon.setCursorPos(1, row)
        mon.write("  fuel: " .. tostring(t.fuel))
        row = row + 1

        mon.setCursorPos(1, row)
        mon.write("  last update: " .. os.date("%H:%M:%S", t.lastUpdate))
        row = row + 2
    end

    if n == 0 then
        mon.setCursorPos(1, row)
        mon.setTextColor(colors.gray)
        mon.write("Waiting for a turtle to check in...")
        row = row + 2
    end

    mon.setCursorPos(1, logStart)
    mon.setTextColor(colors.yellow)
    mon.write("--- Log ---")

    local logRow = logStart + 1
    local available = h - logRow + 1
    if available > 0 then
        local startIdx = math.max(1, #logLines - available + 1)
        for i = startIdx, #logLines do
            mon.setCursorPos(1, logRow)
            mon.setTextColor(colors.white)
            mon.write(logLines[i]:sub(1, w))
            logRow = logRow + 1
        end
    end
end

addLog("Monitor started. Waiting for turtle pings on protocol '" .. PROTOCOL .. "'...")
redraw()

while true do
    local senderId, message = rednet.receive(PROTOCOL)
    if type(message) == "table" then
        turtles[senderId] = {
            label = message.label,
            status = message.status,
            x = message.x,
            y = message.y,
            z = message.z,
            wx = message.wx,
            wy = message.wy,
            wz = message.wz,
            fuel = message.fuel,
            lastUpdate = os.time(),
        }
        if message.detail then
            addLog((message.label or ("Turtle " .. senderId)) .. ": " .. message.detail)
        end
        redraw()
    end
end
