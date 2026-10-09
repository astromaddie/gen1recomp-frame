local driverPath = assert(arg[1], "pass integration/tests/vr_telemetry_driver.lua")
local now = 0
local output = {}
local stageCalls = {}
local telemetry
telemetry = {
  active = false,
  isEnabled = function() return true end,
  startWindow = function() telemetry.active = true end,
  stopWindow = function() telemetry.active = false end,
  beginStage = function(name) stageCalls[#stageCalls + 1] = "begin:" .. name; return name end,
  endStage = function(name) stageCalls[#stageCalls + 1] = "end:" .. tostring(name) end,
}
local runtime = { status = function()
  return { native = { submitCount = math.floor(now) } }
end }
local util = {
  wait = function(frames)
    for _ = 1, frames do
      now = now + 1
      coroutine.yield()
    end
  end,
}
local love = {
  update = function(value) return "updated:" .. value end,
  draw = function(value) return "drawn:" .. value end,
  timer = { getTime = function() return now end },
}
local fakeOs = { getenv = function(key)
  if key == "POKEPORT_SAVED_SCENE_DRIVER" then return "saved" end
  if key == "GEN1_FRAME_DRIVER_UTIL" then return "util" end
  if key == "POKEPORT_VR_TELEMETRY_SECONDS" then return "10" end
end }
local env = setmetatable({
  os = fakeOs,
  love = love,
  loadfile = function(path)
    if path == "saved" then return function() return function() end end end
    if path == "util" then return function() return util end end
    error("unexpected driver dependency: " .. tostring(path))
  end,
  require = function(name)
    if name == "src.vr.Runtime" then return runtime end
    if name == "src.vr.Telemetry" then return telemetry end
    error("unexpected module: " .. tostring(name))
  end,
  print = function(...)
    local values = {}
    for i = 1, select("#", ...) do values[i] = tostring(select(i, ...)) end
    output[#output + 1] = table.concat(values, " ")
  end,
}, { __index = _G })

local chunk = assert(loadfile(driverPath))
setfenv(chunk, env)
local runDriver = chunk()
local driver = coroutine.create(function()
  runDriver({ overworld = { map = { id = "PEWTER_CITY" } } })
end)

local mainWouldQuit = false
local function mainDriverStep()
  -- Pinned main.lua quits as soon as the POKEPORT_DRIVER coroutine is dead.
  if coroutine.status(driver) == "dead" then mainWouldQuit = true; return end
  local ok, err = coroutine.resume(driver)
  assert(ok, err)
  if coroutine.status(driver) == "dead" then mainWouldQuit = true end
end

mainDriverStep()
assert(coroutine.status(driver) == "suspended")
assert(love.update("test") == "updated:test")
assert(love.draw("test") == "drawn:test")
assert(stageCalls[1] == "begin:game_update" and stageCalls[2] == "end:game_update"
  and stageCalls[3] == "begin:game_draw" and stageCalls[4] == "end:game_draw")

for _ = 1, 40 do mainDriverStep() end
assert(not mainWouldQuit and coroutine.status(driver) == "suspended",
  "the driver must keep yielding after the bounded window so main.lua stays alive")
assert(telemetry.active, "telemetry should keep running for manual settings changes")
local complete = false
for _, line in ipairs(output) do
  if line:find("measurement=complete") then complete = true end
end
assert(complete, "the driver should mark its initial interval before remaining alive")
print("VR telemetry driver keep-alive tests passed")
