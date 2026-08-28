--[[
  ping.lua — check connectivity with quarry turtle(s)
  ------------------------------------------------------
  Run from any computer with a wireless modem attached.

  Usage:
    ping                → pings every turtle in range, lists all replies
    ping <label-or-id>  → only shows the reply matching that label or
                           computer id (e.g. "ping Turtle3")

  Prints round-trip time, current status, fuel, and position for each
  turtle that responds within 3 seconds. No response = unreachable,
  out of modem range, or not currently running quarry.lua.
]]--

local PING_PROTOCOL = "quarry_ping"
local TIMEOUT = 3

local args = { ... }
local filter = args[1]

-- open a wireless modem
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

print("Pinging turtles" .. (filter and (" (filter: " .. filter .. ")") or "") .. " ...")

local sentAt = os.epoch("utc")
rednet.broadcast({ type = "ping", sentAt = sentAt }, PING_PROTOCOL)

local found = {}
local timer = os.startTimer(TIMEOUT)
local running = true
while running do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" then
        local senderId, message, protocol = a, b, c
        if protocol == PING_PROTOCOL and type(message) == "table" and message.type == "pong" then
            if not filter or tostring(senderId) == filter or message.label == filter then
                if not found[senderId] then
                    found[senderId] = true
                    local rtt = os.epoch("utc") - (message.sentAt or sentAt)
                    print(string.format("%s (id %d): %dms  status=%s  fuel=%s  pos=(%d,%d,%d)",
                        message.label or "?", senderId, rtt, message.status or "?",
                        tostring(message.fuel), message.x or 0, message.y or 0, message.z or 0))
                    if message.wx then
                        print(string.format("    world pos=(%d,%d,%d)", message.wx, message.wy, message.wz))
                    end
                end
            end
        end
    elseif event == "timer" and a == timer then
        running = false
    end
end

local count = 0
for _ in pairs(found) do count = count + 1 end
if count == 0 then
    print("No response. Turtle is unreachable, out of modem range, or not running quarry.lua.")
else
    print(count .. " turtle(s) responded.")
end
