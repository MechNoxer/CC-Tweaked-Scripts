--[[
  quarry.lua — CC: Tweaked mining turtle quarry script
  ------------------------------------------------------
  Usage:  quarry <width> <length>
  Example: quarry 8 8

  SETUP BEFORE RUNNING:
   - Place the turtle where you want it to start (this is "home").
   - Put a chest directly BEHIND the turtle (opposite the direction
     it is currently facing). The turtle will turn around and drop
     items into it.
   - Load fuel (coal, charcoal, lava buckets, etc.) into any slot(s).
     Non-fuel starting cargo is fine, it'll get dumped on the first
     unload trip.
   - Face the turtle toward the area you want quarried. It mines a
     WIDTH x LENGTH column straight down to bedrock, 3 layers per pass.

  Behavior:
   - Mines full-width, full-length "slabs" 3 blocks tall at a time
     (dig front/up/down while moving = 1 pass clears 3 vertical
     blocks), then drops down 3 and repeats.
   - Stops descending and comes home when it hits an undiggable
     block (bedrock).
   - Returns home and dumps into the chest whenever inventory is full.
   - Returns home if fuel gets low (keeps a safety margin equal to
     the trip home + buffer).
   - Any unexpected error: logs it, tries to return home, then stops.
   - All events are appended to "quarry_log.txt" on the turtle's disk.
]]--

local args = { ... }
local WIDTH  = tonumber(args[1]) or 8
local LENGTH = tonumber(args[2]) or 8
local MAX_DEPTH = tonumber(args[3]) or 400  -- hard cap on blocks dug downward, as a void backstop
local FUEL_SAFETY_MARGIN = 25   -- extra fuel buffer on top of the trip home
local VOID_SAFETY_BLOCKS = 3    -- consecutive "nothing below" reads before treating it as a void/chasm
local LOG_FILE = "quarry_log.txt"

-- ===================== STATE =====================
-- facing: 0 = +Z (forward, into the quarry), 1 = +X (right),
--         2 = -Z (back, toward the chest), 3 = -X (left)
local facing = 0
local posX, posY, posZ = 0, 0, 0   -- posY is <=0 (depth), 0 = start height
local consecutiveOpenBelow = 0     -- tracks unexpected open air below (cave/ravine/void gap)
local hasGPS = false
local worldX, worldY, worldZ = nil, nil, nil    -- real-world coords, if GPS is available
local facingVectors = nil                        -- [0..3] -> {dx, dz} in world space

-- ===================== LOGGING / STATUS PINGS =====================
local modemOpen = false
local TURTLE_LABEL = os.getComputerLabel() or ("Turtle" .. os.getComputerID())
local PROTOCOL = "quarry_status"
local PING_PROTOCOL = "quarry_ping"
local currentStatus = "starting"

local function broadcastStatus(status, detail)
    if not modemOpen then return end
    pcall(rednet.broadcast, {
        label = TURTLE_LABEL,
        status = status,
        detail = detail,
        x = posX, y = posY, z = posZ,
        wx = worldX, wy = worldY, wz = worldZ,
        fuel = turtle.getFuelLevel(),
    }, PROTOCOL)
end

local function log(msg)
    local line = "[" .. os.date("%H:%M:%S") .. "] " .. msg
    local f = fs.open(LOG_FILE, "a")
    if f then
        f.writeLine(line)
        f.close()
    end
    print(line)
    broadcastStatus(currentStatus, msg)
end

local function setStatus(s)
    currentStatus = s
    broadcastStatus(s, nil)
end

-- find and open a wireless modem, on any side (equipped or placed nearby)
do
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
    if modemSide then
        rednet.open(modemSide)
        modemOpen = true
        log("Wireless modem found on '" .. modemSide .. "'. Status pings enabled.")
    else
        log("No wireless modem found — running without status pings.")
    end
end

-- ===================== GPS CALIBRATION (optional) =====================
-- if a GPS host array exists in the world, figure out this turtle's real
-- start coordinates AND which real-world direction its local "facing 0"
-- points, so we can report true world coordinates alongside relative ones.
local function rotate90CW(dx, dz)
    return -dz, dx
end

do
    local x1, y1, z1 = gps.locate(3)
    if x1 then
        local moved = false
        if turtle.detect() then turtle.dig() end
        if turtle.forward() then moved = true end
        if moved then
            local x2, y2, z2 = gps.locate(3)
            turtle.back()
            if x2 and (x2 ~= x1 or z2 ~= z1) then
                local dx, dz = x2 - x1, z2 - z1
                facingVectors = {}
                facingVectors[0] = { dx = dx, dz = dz }
                facingVectors[1] = { dx = select(1, rotate90CW(dx, dz)), dz = select(2, rotate90CW(dx, dz)) }
                facingVectors[2] = { dx = select(1, rotate90CW(facingVectors[1].dx, facingVectors[1].dz)), dz = select(2, rotate90CW(facingVectors[1].dx, facingVectors[1].dz)) }
                facingVectors[3] = { dx = select(1, rotate90CW(facingVectors[2].dx, facingVectors[2].dz)), dz = select(2, rotate90CW(facingVectors[2].dx, facingVectors[2].dz)) }
                worldX, worldY, worldZ = x1, y1, z1
                hasGPS = true
                log("GPS fix acquired. Broadcasting real-world coordinates.")
            else
                log("GPS signal found but calibration move failed — falling back to relative coordinates.")
            end
        else
            log("GPS signal found but couldn't move to calibrate (blocked) — falling back to relative coordinates.")
        end
    else
        log("No GPS signal found — broadcasting position relative to start only.")
    end
end

-- ===================== LOW-LEVEL SAFE MOVEMENT =====================
local function turnLeft()
    turtle.turnLeft()
    facing = (facing - 1) % 4
end

local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
end

local function turnTo(target)
    local diff = (target - facing) % 4
    if diff == 1 then turnRight()
    elseif diff == 2 then turnRight(); turnRight()
    elseif diff == 3 then turnLeft()
    end
end

-- forward declare so movement fns can call fuel/inventory checks
local ensureFuel
local ensureInventorySpace

-- ===================== HAZARDS (lava / water) =====================
local HAZARDS = {
    ["minecraft:lava"] = true,
    ["minecraft:flowing_lava"] = true,
    ["minecraft:water"] = true,
    ["minecraft:flowing_water"] = true,
}

-- finds a slot holding something that isn't fuel, to use as a plug block
local function findFillerSlot()
    for slot = 1, 16 do
        turtle.select(slot)
        if turtle.getItemCount(slot) > 0 and not turtle.refuel(0) then
            return slot
        end
    end
    return nil
end

-- checks the block via inspectFn; if it's lava/water, plugs it with a
-- spare inventory item via placeFn before anything digs/walks into it.
-- if it can't be sealed, aborts the whole run (caught by the top-level
-- pcall, which then tries to bring the turtle home).
local function handleHazard(inspectFn, placeFn)
    local ok, data = inspectFn()
    if not ok or not HAZARDS[data.name] then return end
    log("HAZARD DETECTED: " .. data.name .. " — attempting to seal it.")
    local slot = findFillerSlot()
    if not slot then
        setStatus("hazard_abort")
        log("CRITICAL: hazard detected and no spare block available to seal it. Aborting for safety.")
        error("HAZARD_ABORT")
    end
    turtle.select(slot)
    local placed = placeFn()
    turtle.select(1)
    if not placed then
        setStatus("hazard_abort")
        log("CRITICAL: could not seal hazard (placement failed). Aborting for safety.")
        error("HAZARD_ABORT")
    end
    log("Hazard sealed with a block from inventory.")
end

local function digClearFront()
    handleHazard(turtle.inspect, turtle.place)
    local tries = 0
    while turtle.detect() do
        turtle.dig()
        tries = tries + 1
        if turtle.detect() then
            handleHazard(turtle.inspect, turtle.place)
            turtle.attack()
        end
        sleep(0.2)
        if tries > 15 then break end
    end
end

local function digClearUp()
    handleHazard(turtle.inspectUp, turtle.placeUp)
    local tries = 0
    while turtle.detectUp() do
        turtle.digUp()
        tries = tries + 1
        if turtle.detectUp() then
            handleHazard(turtle.inspectUp, turtle.placeUp)
            turtle.attackUp()
        end
        sleep(0.2)
        if tries > 15 then break end
    end
end

local function safeForward()
    ensureFuel()
    digClearFront()
    local tries = 0
    while not turtle.forward() do
        digClearFront()
        turtle.attack()
        tries = tries + 1
        if tries > 10 then
            log("ERROR: stuck moving forward, cannot proceed")
            return false
        end
        sleep(0.3)
    end
    if facing == 0 then posZ = posZ + 1
    elseif facing == 1 then posX = posX + 1
    elseif facing == 2 then posZ = posZ - 1
    elseif facing == 3 then posX = posX - 1
    end
    if hasGPS then
        worldX = worldX + facingVectors[facing].dx
        worldZ = worldZ + facingVectors[facing].dz
    end
    return true
end

local function safeUp()
    ensureFuel()
    digClearUp()
    local tries = 0
    while not turtle.up() do
        digClearUp()
        turtle.attackUp()
        tries = tries + 1
        if tries > 10 then
            log("ERROR: stuck moving up, cannot proceed")
            return false
        end
        sleep(0.3)
    end
    posY = posY + 1
    if hasGPS then worldY = worldY + 1 end
    return true
end

-- returns true if it moved down, false if it hit bedrock/unbreakable block
-- or an unsafe open drop (cave/ravine/void gap)
local function safeDown()
    ensureFuel()

    if posY <= -MAX_DEPTH then
        return false, "max_depth_reached"
    end

    if not turtle.detectDown() then
        -- nothing there at all — normal for a shallow cave pocket, but a
        -- run of these in a row means an open chasm or a gap in the
        -- bedrock leading to the void. Don't just step into it.
        consecutiveOpenBelow = consecutiveOpenBelow + 1
        if consecutiveOpenBelow >= VOID_SAFETY_BLOCKS then
            setStatus("void_hazard")
            log("CRITICAL: " .. consecutiveOpenBelow .. " consecutive open blocks below with no floor — likely a chasm or void gap. Placing a safety block and heading home.")
            local slot = findFillerSlot()
            if slot then
                turtle.select(slot)
                turtle.placeDown()
                turtle.select(1)
            end
            return false, "void_hazard"
        end
    else
        consecutiveOpenBelow = 0
    end

    local tries = 0
    while turtle.detectDown() do
        handleHazard(turtle.inspectDown, turtle.placeDown)
        if not turtle.digDown() then
            -- couldn't break it after clearing attempts -> likely bedrock
            tries = tries + 1
            if tries > 3 then
                return false, "bedrock_or_unbreakable"
            end
        else
            tries = 0
        end
        sleep(0.2)
    end
    local moveTries = 0
    while not turtle.down() do
        turtle.digDown()
        turtle.attackDown()
        moveTries = moveTries + 1
        if moveTries > 10 then
            log("ERROR: stuck moving down, cannot proceed")
            return false, "stuck"
        end
        sleep(0.3)
    end
    posY = posY - 1
    if hasGPS then worldY = worldY - 1 end
    return true
end

-- move along X axis to target, then Z axis to target (dig-safe)
local function moveAxisX(target)
    while posX ~= target do
        if target > posX then turnTo(1) else turnTo(3) end
        if not safeForward() then break end
    end
end

local function moveAxisZ(target)
    while posZ ~= target do
        if target > posZ then turnTo(0) else turnTo(2) end
        if not safeForward() then break end
    end
end

local function moveAxisY(target)
    while posY ~= target do
        if target > posY then
            if not safeUp() then break end
        else
            local ok = safeDown()
            if not ok then break end
        end
    end
end

-- generic go-to: if heading up (toward y=0) go vertical first, then
-- horizontal; if heading down, go horizontal first (at the clear y=0
-- plane) then vertical down into the shaft.
local function goTo(x, y, z)
    if y >= posY then
        moveAxisY(y)
        moveAxisX(x)
        moveAxisZ(z)
    else
        moveAxisX(x)
        moveAxisZ(z)
        moveAxisY(y)
    end
end

-- ===================== FUEL =====================
local function tryRefuelFromInventory()
    for slot = 1, 16 do
        turtle.select(slot)
        if turtle.getItemCount(slot) > 0 and turtle.refuel(0) then
            turtle.refuel(1)
        end
    end
    turtle.select(1)
end

local function distanceHome()
    return math.abs(posX) + math.abs(posY) + math.abs(posZ)
end

-- called before movements; if fuel is too low to safely get home,
-- bail out and return home now.
ensureFuel = function()
    local level = turtle.getFuelLevel()
    if level == "unlimited" then return end
    local needed = distanceHome() + FUEL_SAFETY_MARGIN
    if level <= needed then
        tryRefuelFromInventory()
        level = turtle.getFuelLevel()
        if level ~= "unlimited" and level <= needed then
            setStatus("returning_low_fuel")
            log("LOW FUEL (" .. tostring(level) .. "). Returning home.")
            goTo(0, 0, 0)
            turnTo(0)
            log("Stopped at home due to low fuel. Please refuel and rerun.")
            error("LOW_FUEL_ABORT")
        end
    end
end

-- ===================== INVENTORY =====================
local function hasEmptySlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return true end
    end
    return false
end

local function unloadAtHome()
    local savedX, savedY, savedZ, savedFacing = posX, posY, posZ, facing
    setStatus("unloading")
    log("Returning home to unload inventory.")
    goTo(0, 0, 0)
    turnTo(2) -- face the chest, which sits behind the start position
    local dropped, keptFuel, blockedFull = 0, 0, false
    for slot = 1, 16 do
        turtle.select(slot)
        if turtle.getItemCount(slot) > 0 then
            if turtle.refuel(0) then
                keptFuel = keptFuel + 1
            else
                if turtle.drop() then
                    dropped = dropped + 1
                else
                    blockedFull = true
                end
            end
        end
    end
    turtle.select(1)
    if blockedFull then
        log("WARNING: chest appears full, some items kept in inventory.")
    end
    log("Unloaded " .. dropped .. " stack(s), kept " .. keptFuel .. " fuel stack(s).")
    turnTo(savedFacing)
    goTo(savedX, savedY, savedZ)
    turnTo(savedFacing)
    setStatus("mining")
end

ensureInventorySpace = function()
    if not hasEmptySlot() then
        unloadAtHome()
    end
end

-- ===================== MINING =====================
-- clears the block above and below the current cell (the 3rd dimension
-- of the 3-tall slab we're cutting as we move forward)
local function clearColumn()
    digClearUp()
    turtle.digUp()
    local tries = 0
    while turtle.detectDown() do
        handleHazard(turtle.inspectDown, turtle.placeDown)
        if turtle.digDown() then
            tries = 0
        else
            tries = tries + 1
            if tries > 5 then
                -- likely bedrock this deep; stop trying and move on,
                -- the real bedrock check happens in safeDown() below
                break
            end
        end
        sleep(0.1)
    end
    broadcastStatus(currentStatus, nil) -- heartbeat: position/fuel ping each cell
end

-- mines one row of `length` cells in the turtle's current facing direction
local function mineRow(length)
    ensureInventorySpace()
    clearColumn()
    for _ = 1, length - 1 do
        if not safeForward() then break end
        ensureInventorySpace()
        clearColumn()
    end
end

-- mines a full width x length x 3(tall) slab starting from wherever the
-- turtle currently stands (always a corner of the WIDTH x LENGTH grid)
local function mineLayer(width, length)
    local xDir = (posX == 0) and 1 or 3       -- which way to step between rows
    local zDir = (posZ == 0) and 0 or 2       -- which way the first row runs

    for row = 1, width do
        turnTo(zDir)
        mineRow(length)
        if row < width then
            turnTo(xDir)
            safeForward()
            clearColumn()
            zDir = (zDir == 0) and 2 or 0
        end
    end
end

-- ===================== MAIN =====================
local function runQuarry()
    setStatus("mining")
    log("Starting quarry: " .. WIDTH .. " x " .. LENGTH .. " down to bedrock.")
    tryRefuelFromInventory()

    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < FUEL_SAFETY_MARGIN then
        setStatus("error_no_fuel")
        log("ERROR: Not enough fuel to safely start. Add fuel and rerun.")
        return
    end

    local hitBedrock = false
    while not hitBedrock do
        mineLayer(WIDTH, LENGTH)

        for _ = 1, 3 do
            local ok, reason = safeDown()
            if not ok then
                if reason == "bedrock_or_unbreakable" then
                    setStatus("bedrock_reached")
                    log("Bedrock (or unbreakable block) reached at depth " .. math.abs(posY) .. ". Heading home.")
                elseif reason == "void_hazard" then
                    log("Stopped at depth " .. math.abs(posY) .. " due to an open drop below (possible chasm/void gap). Heading home.")
                elseif reason == "max_depth_reached" then
                    setStatus("max_depth_reached")
                    log("Hit the configured max depth (" .. MAX_DEPTH .. ") without finding bedrock. Heading home.")
                else
                    setStatus("movement_problem")
                    log("Movement problem while descending. Heading home.")
                end
                hitBedrock = true
                break
            end
        end
    end

    setStatus("returning_home_complete")
    goTo(0, 0, 0)
    turnTo(0)
    unloadAtHome()
    setStatus("complete")
    log("Quarry complete. Turtle is home.")
end

-- ===================== PING LISTENER (runs alongside mining) =====================
local function pingListener()
    while true do
        local senderId, message = rednet.receive(PING_PROTOCOL)
        if type(message) == "table" and message.type == "ping" then
            rednet.send(senderId, {
                type = "pong",
                label = TURTLE_LABEL,
                status = currentStatus,
                x = posX, y = posY, z = posZ,
                wx = worldX, wy = worldY, wz = worldZ,
                fuel = turtle.getFuelLevel(),
                sentAt = message.sentAt,
            }, PING_PROTOCOL)
        end
    end
end

-- top-level error guard: on any unexpected error, log it, try to get home,
-- and stop cleanly instead of crashing silently.
local function runQuarryGuarded()
    local ok, err = pcall(runQuarry)
    if not ok then
        setStatus("error")
        log("UNEXPECTED ERROR: " .. tostring(err))
        local homeOk = pcall(function()
            goTo(0, 0, 0)
            turnTo(0)
        end)
        if homeOk then
            setStatus("home_after_error")
            log("Returned home after error.")
        else
            setStatus("stuck_after_error")
            log("Could NOT return home after error — manual recovery needed. Last known position: x="
                .. posX .. " y=" .. posY .. " z=" .. posZ .. " facing=" .. facing)
        end
    end
end

if modemOpen then
    -- run the quarry and the ping listener side by side; ends when the
    -- quarry run finishes (the listener alone never returns on its own)
    parallel.waitForAny(runQuarryGuarded, pingListener)
else
    runQuarryGuarded()
end
