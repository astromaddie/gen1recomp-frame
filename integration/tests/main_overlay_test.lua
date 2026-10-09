local mainPath = assert(arg[1], "pass the patched main.lua path")
local originalRequire = require
local actions = {
  a = true,
  b = true,
  start = true,
  select = true,
  move = { x = 0.6, y = 0.25 },
}
local focused = true
local calls = {}
local startup = {}
local importer
local gameReady
local game = { writes = 0 }
function game:load() self.save = { options = { pipelines = {} } } end
function game:writeOptions() self.writes = self.writes + 1 end
local voxelSets = 0

local function count(kind, value)
  local total = 0
  for _, call in ipairs(calls) do
    if call.kind == kind and (value == nil or call.value == value) then
      total = total + 1
    end
  end
  return total
end

local runtime = {
  setEnabled = function(enabled)
    startup[#startup + 1] = "setEnabled"
    assert(enabled)
  end,
  start = function(width, height)
    startup[#startup + 1] = "start"
    assert(width == 800 and height == 600)
    return true
  end,
  status = function() return { bridge = true } end,
  isBridgeActive = function() return true end,
  isEnabled = function() return true end,
  isQuitRequested = function() return false end,
  shouldSimulate = function() return focused end,
  pollActions = function() return actions end,
}

local modules = {
  ["src.vr.Runtime"] = runtime,
  ["src.core.HostShell"] = {
    hideHostConsole = function() end,
  },
  ["src.update.Boot"] = {
    run = function() return false end,
  },
  ["src.import.RomImporter"] = {
    isReady = function() return false end,
    new = function(onComplete)
      gameReady = onComplete
      startup[#startup + 1] = "importer"
      importer = {
        update = function(self, dt) calls[#calls + 1] = { kind = "update", dt = dt } end,
        draw = function() calls[#calls + 1] = { kind = "draw" } end,
        keypressed = function(self, key)
          calls[#calls + 1] = { kind = "key", value = key }
        end,
        gamepadpressed = function(self, _, button)
          calls[#calls + 1] = { kind = "press", value = button }
        end,
        gamepadreleased = function(self, _, button)
          calls[#calls + 1] = { kind = "release", value = button }
        end,
        gamepadaxis = function(self, _, axis, value)
          calls[#calls + 1] = { kind = "axis", axis = axis, value = value }
        end,
      }
      return importer
    end,
  },
  ["src.core.GameVersion"] = { set = function() end, get = function() return "red" end },
  ["src.import.CacheFs"] = { mountVersion = function() end },
  ["src.core.Game"] = game,
  ["src.render.Pipelines"] = {
    setLevel = function(_, level) voxelSets = voxelSets + 1; return level end,
  },
}

love = {
  graphics = {
    getDimensions = function() return 800, 600 end,
    getPixelDimensions = function() return 800, 600 end,
    setDefaultFilter = function() end,
  },
  event = { quit = function() end },
}

_G.require = function(name)
  if modules[name] then return modules[name] end
  return originalRequire(name)
end
assert(loadfile(mainPath))()
love.load({})
assert(startup[1] == "setEnabled" and startup[2] == "start"
    and startup[3] == "importer",
  "required OpenXR must start before the title/importer is constructed")

love.update(0.016)
assert(count("press", "a") == 1 and count("press", "b") == 1
    and count("press", "start") == 1 and count("press", "back") == 1,
  "OpenXR A/B/Menu/View actions must use the existing importer gamepad handler")
local foundX, foundY = false, false
for _, call in ipairs(calls) do
  if call.kind == "axis" and call.axis == "leftx" then
    foundX = math.abs(call.value - 0.6) < 0.0001
  elseif call.kind == "axis" and call.axis == "lefty" then
    foundY = math.abs(call.value + 0.25) < 0.0001
  end
end
assert(foundX and foundY, "OpenXR left stick must map to importer cursor axes")

love.update(0.016)
assert(count("press", "a") == 1 and count("press", "start") == 1,
  "held native buttons must not repeat launcher presses every frame")
actions.a, actions.b, actions.start, actions.select = false, false, false, false
love.update(0.016)
assert(count("release", "back") == 1,
  "a short View action must release through the importer's Select/back handler")

local updatesBeforeSuspend = count("update")
focused = false
love.update(0.016)
assert(count("update") == updatesBeforeSuspend,
  "focus loss must freeze importer updates")
love.keypressed("return")
love.gamepadpressed(nil, "a")
assert(count("key", "return") == 0 and count("press", "a") == 1,
  "focus loss must ignore desktop and gamepad input callbacks")

focused = true
love.update(0.016)
assert(count("update") == updatesBeforeSuspend + 1,
  "importer updates should resume after focus returns")

gameReady("red")
assert(game.save.options.pipelines.voxel == 3 and game.writes == 1 and voxelSets == 1,
  "fresh VR game must enable the stereo voxel pipeline and persist its default")
function game:load() self.save = { options = { pipelines = { voxel = 0 } } } end
gameReady("red")
assert(game.save.options.pipelines.voxel == 0 and game.writes == 1 and voxelSets == 1,
  "VR startup must preserve an explicit player choice to disable voxel mode")

-- Exercise the production love.run loop, including its production draw
-- fallback, with a bridge that polls but declines submission. Current-frame
-- focus and delta must reach update; draw must not poll/begin it again.
love.load({})
love.load = nil
love.event = nil
local enabled, begins, currentDelta, ticks, aborts = true, 0, 0, 0, 0
runtime.isEnabled=function()return enabled end
runtime.isBridgeActive=function()return enabled end
runtime.isFramePaced=function()return enabled end
runtime.beginFrame=function()
  begins=begins+1
  currentDelta=begins/100
  focused=begins~=2
  return false
end
runtime.frameDelta=function()return currentDelta end
runtime.abortFrame=function()aborts=aborts+1 end
modules["src.core.FrameCap"]={current=60}
love.graphics.isActive=function()return true end
love.graphics.origin=function()end
love.graphics.clear=function()end
love.graphics.getBackgroundColor=function()return 0,0,0,1 end
love.graphics.present=function()calls[#calls+1]={kind="present"}end
love.timer={step=function()ticks=ticks+1;return .02 end,getTime=function()return ticks end,sleep=function()end}
local loop=love.run()
local before=count("update")
loop()
assert(begins==1 and count("update")==before+1,"one current XR begin before update/draw")
local function lastUpdateDelta()
  for i=#calls,1,-1 do if calls[i].kind=="update" then return calls[i].dt end end
end
assert(lastUpdateDelta()==.01,"update used a previous XR frame delta")
loop()
assert(begins==2 and count("update")==before+1,"same-frame focus loss must freeze simulation")
loop()
assert(begins==3 and count("update")==before+2 and lastUpdateDelta()==.03,"resume must use current XR delta")
love.draw();assert(begins==4,"direct draw must still prepare its frame")
enabled=false
loop();assert(begins==4 and lastUpdateDelta()==.02,"flat loop must preserve wall clock and skip XR")
enabled=true
local originalUpdate=love.update
local beforeAbort=aborts
love.update=function()error("injected update failure")end
assert(not pcall(loop) and aborts==beforeAbort+1,"update error must abort the prepared XR frame")
love.update=originalUpdate
local beforeBegin=begins
loop();assert(begins==beforeBegin+1,"error recovery must acquire a fresh frame")
beforeBegin=begins
love.graphics.isActive=function()return false end
loop();assert(begins==beforeBegin and lastUpdateDelta()==.02,"inactive graphics must not use stale XR delta")
love.graphics.isActive=function()return true end
local normalDraw=love.draw
love.draw=function()error("injected draw failure")end
beforeAbort=aborts
assert(not pcall(loop) and aborts==beforeAbort+1,"draw error must abort the prepared XR frame")
love.draw=function()end
beforeAbort=aborts
loop();assert(aborts==beforeAbort+1,"skipped draw must close the prepared frame")
love.draw=normalDraw
print("main frame ordering tests passed")

_G.require = originalRequire
print("main overlay tests passed")
