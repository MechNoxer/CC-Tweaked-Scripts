-- dig_room.lua
-- Mines out a room of given width x height x depth.
-- Place the turtle on the FLOOR, in the LEFT-FRONT corner of the room,
-- facing INTO the room, with a chest directly BEHIND it.
--
-- Usage:  dig_room <width> <height> <depth>
--   width  = how many blocks left-to-right (X)
--   height = how many blocks up (Y)
--   depth  = how many blocks into the room, away from the chest (Z)

local args = { ... }
local width  = tonumber(args[1])
local height = tonumber(args[2])
local depth  = tonumber(args[3])

if not (width and height and depth) then
  print("Usage: dig_room <width> <height> <depth>")
  return
end
if width < 1 or height < 1 or depth < 1 then
  print("Width, height and depth must all be >= 1")
  return
end

-- ===== position tracking =====
-- facing: 0 = +Z (into room), 1 = +X (right), 2 = -Z (toward chest), 3 = -X (left)
local posX, posY, posZ, facing = 0, 0, 0, 0

local function tryRefuel()
  if turtle.getFuelLevel() == "unlimited" then return end
  if turtle.getFuelLevel() < 50 then
    for i = 1, 16 do
      turtle.select(i)
      if turtle.refuel(0) then turtle.refuel() end
    end
    turtle.select(1)
  end
end

local function turnRight()
  turtle.turnRight()
  facing = (facing + 1) % 4
end

local function turnLeft()
  turtle.turnLeft()
  facing = (facing - 1) % 4
end

local function turnTo(dir)
  while facing ~= dir do turnRight() end
end

local function forward()
  tryRefuel()
  while turtle.detect() do
    turtle.dig()
    sleep(0.3)
  end
  while not turtle.forward() do
    turtle.attack()
    sleep(0.3)
  end
  if facing == 0 then posZ = posZ + 1
  elseif facing == 1 then posX = posX + 1
  elseif facing == 2 then posZ = posZ - 1
  else posX = posX - 1 end
end

local function up()
  tryRefuel()
  while turtle.detectUp() do
    turtle.digUp()
    sleep(0.3)
  end
  while not turtle.up() do
    turtle.attackUp()
    sleep(0.3)
  end
  posY = posY + 1
end

local function down()
  while turtle.detectDown() do
    turtle.digDown()
    sleep(0.3)
  end
  while not turtle.down() do
    turtle.attackDown()
    sleep(0.3)
  end
  posY = posY - 1
end

local function goTo(tx, ty, tz)
  while posY < ty do up() end
  while posY > ty do down() end
  if posZ ~= tz then
    turnTo(tz > posZ and 0 or 2)
    while posZ ~= tz do forward() end
  end
  if posX ~= tx then
    turnTo(tx > posX and 1 or 3)
    while posX ~= tx do forward() end
  end
end

local function isInventoryFull()
  for i = 1, 16 do
    if turtle.getItemCount(i) == 0 then return false end
  end
  return true
end

-- Go dump inventory into the chest behind the start point, then return.
local function dumpItems()
  local sx, sy, sz, sf = posX, posY, posZ, facing
  goTo(0, 0, 0)
  turnTo(2) -- face the chest
  for i = 1, 16 do
    turtle.select(i)
    turtle.drop()
  end
  turtle.select(1)
  goTo(sx, sy, sz)
  turnTo(sf)
end

local function checkFull()
  if isInventoryFull() then dumpItems() end
end

-- ===== main mining loop =====
for y = 0, height - 1 do
  for x = 0, width - 1 do
    local zDir = (x % 2 == 0) and 0 or 2
    turnTo(zDir)
    for d = 1, depth - 1 do
      forward()
      checkFull()
    end
    if x < width - 1 then
      turnTo(1)
      forward()
      checkFull()
    end
  end
  goTo(0, y, 0)
  if y < height - 1 then
    up()
  end
end

-- return to floor, face the chest, drop everything
while posY > 0 do down() end
turnTo(2)
for i = 1, 16 do
  turtle.select(i)
  turtle.drop()
end
turtle.select(1)

print("Room mined: " .. width .. "x" .. height .. "x" .. depth .. ". Done.")
