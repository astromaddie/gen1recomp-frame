local runtimePath = assert(arg[1], "pass integration/src/vr/Runtime.lua")
local fakePath = assert(os.getenv("POKEPORT_XRBRIDGE"))
local bridge = {
  ready = true,
  focused = true,
  shouldRender = true,
  effectiveShouldRender = true,
  unattended = false,
  forceRenderActive = false,
  forcedRender = false,
  forceRenderExpired = false,
  period = 11111111,
  displayTime = 1000000000000000,
  statusCalls = 0,
  pollCalls = 0,
  beginCalls = 0,
  abortCalls = 0,
  gpuSubmits = 0,
}

function bridge.create() return true end
function bridge.status()
  bridge.statusCalls = bridge.statusCalls + 1
  return {
    available = true,
    ready = bridge.ready,
    focused = bridge.focused,
    shouldRender = bridge.shouldRender,
    effectiveShouldRender = bridge.effectiveShouldRender,
    unattended = bridge.unattended,
    forceRenderActive = bridge.forceRenderActive,
    forcedRender = bridge.forcedRender,
    forceRenderExpired = bridge.forceRenderExpired,
    predictedDisplayPeriod = bridge.period,
    predictedDisplayTime = bridge.displayTime,
    quitRequested = false,
  }
end
function bridge.pollActions()
  bridge.pollCalls = bridge.pollCalls + 1
  return { actions = { a = true, move = { x = 0, y = 0 } } }
end
function bridge.beginFrame()
  bridge.beginCalls = bridge.beginCalls + 1
  return bridge.leftView or { fov = { left = -0.7, right = 0.7 } },
    bridge.rightView or { fov = { left = -0.7, right = 0.7 } },
    bridge.effectiveShouldRender
end
function bridge.abortFrame() bridge.abortCalls = bridge.abortCalls + 1 end
function bridge.submitCanvases(left, right)
  assert(type(left) == "table" and type(right) == "table")
  bridge.gpuSubmits = bridge.gpuSubmits + 1
  return true
end
function bridge.destroy() end

package.loadlib = function(path, symbol)
  assert(path == fakePath and symbol == "luaopen_xrbridge")
  return function() return bridge end
end

local Runtime = assert(loadfile(runtimePath))()
Runtime.setEnabled(true)
assert(Runtime.start())
assert(Runtime.isBridgeActive())
assert(Runtime.beginFrame(640, 480))
assert(Runtime.isFramePaced())
assert(Runtime.shouldSimulate())
local dt = Runtime.frameDelta(0.5)
assert(math.abs(dt - 0.011111111) < 0.000001,
  "the first paced frame should fall back to OpenXR's predicted period")

local status = Runtime.status()
assert(status.native.focused and status.native.shouldRender)
assert(bridge.pollCalls == 0,
  "status refresh must not sync/consume the action input pulse")
local left, right = {}, {}
assert(Runtime.submit(left, right))
assert(bridge.gpuSubmits == 1,
  "Linux Canvas bridge path must be preferred over CPU image readback")
assert(bridge.pollCalls == 0)

bridge.displayTime = bridge.displayTime + 22222222
assert(Runtime.beginFrame(640, 480))
assert(math.abs(Runtime.frameDelta(0.5) - 0.022222222) < 0.000001,
  "simulation delta should use successive predicted display times after a skipped frame")
Runtime.abortFrame()

bridge.displayTime = bridge.displayTime - 1000000000
assert(Runtime.beginFrame(640, 480))
assert(math.abs(Runtime.frameDelta(0.5) - 0.011111111) < 0.000001,
  "a nonmonotonic XR timestamp should fall back to the display period")
Runtime.abortFrame()

bridge.focused = false
assert(not Runtime.shouldSimulate(), "focus loss must freeze game simulation")
bridge.focused = true
bridge.shouldRender = false
bridge.effectiveShouldRender = false
bridge.displayTime = bridge.displayTime + 1000000000
assert(Runtime.beginFrame(640, 480))
assert(Runtime.isFramePaced(), "standby frames remain compositor paced")
assert(not Runtime.shouldSimulate(), "standby must freeze game simulation")
Runtime.abortFrame()
assert(bridge.abortCalls == 3,
  "each non-rendered or explicitly discarded frame must be closed exactly once")

bridge.focused = false
bridge.unattended = true
bridge.forceRenderActive = true
bridge.forcedRender = true
bridge.effectiveShouldRender = true
bridge.displayTime = bridge.displayTime + bridge.period
assert(Runtime.beginFrame(640, 480))
assert(Runtime.shouldRender() and Runtime.shouldSimulate(),
  "active explicit unattended authorization must admit simulation and rendering")
assert(math.abs(Runtime.frameDelta(0.5) - bridge.period / 1000000000) < 0.000001,
  "unattended rendering must keep the real OpenXR predicted period")
local forcedStatus = Runtime.status().native
assert(forcedStatus.focused == false and forcedStatus.shouldRender == false
  and forcedStatus.effectiveShouldRender == true
  and forcedStatus.unattended == true and forcedStatus.forceRenderActive == true
  and forcedStatus.forcedRender == true,
  "diagnostic rendering must preserve raw runtime status separately")
Runtime.abortFrame()
bridge.leftView = { position = { x = -0.032, y = 0, z = 0 },
  orientation = { x = 0, y = 0, z = 0, w = 1 }, positionValid = false,
  orientationValid = false, poseUsable = true, syntheticPose = true,
  fov = { left = -0.7, right = 0.7 } }
bridge.rightView = { position = { x = 0.032, y = 0, z = 0 },
  orientation = { x = 0, y = 0, z = 0, w = 1 }, positionValid = false,
  orientationValid = false, poseUsable = true, syntheticPose = true,
  fov = { left = -0.7, right = 0.7 } }
bridge.displayTime = bridge.displayTime + bridge.period
assert(Runtime.beginFrame(640, 480))
local forcedLeft, forcedRight = Runtime.views({ mode = "above",
  eye = { x = 0, y = 0, z = 0 }, focus = { x = 0, y = 0, z = -10 } }, 1)
assert(math.abs(math.abs(forcedLeft.eye.x - forcedRight.eye.x) - 3.072) < 0.01,
  "derived synthetic views must preserve runtime-measured eye separation in the game cameras")
bridge.leftView, bridge.rightView = nil, nil
Runtime.abortFrame()

bridge.forceRenderActive = false
bridge.forcedRender = false
bridge.forceRenderExpired = true
bridge.effectiveShouldRender = false
bridge.displayTime = bridge.displayTime + 1000000000
assert(Runtime.beginFrame(640, 480))
assert(not Runtime.shouldSimulate() and not Runtime.shouldRender(),
  "expired authorization must restore the raw standby gate")
Runtime.abortFrame()

-- A runtime can leave shouldRender true while focus is lost. After timeout,
-- that must not keep simulation active merely because the raw flag stayed true.
bridge.shouldRender = true
bridge.effectiveShouldRender = true
bridge.displayTime = bridge.displayTime + bridge.period
assert(Runtime.beginFrame(640, 480))
assert(Runtime.shouldRender() and not Runtime.shouldSimulate(),
  "unfocused raw shouldRender after timeout must not bypass simulation policy")
Runtime.abortFrame()

bridge.focused = true
bridge.unattended = false
bridge.forceRenderActive = false
bridge.forcedRender = false
bridge.forceRenderExpired = false
bridge.shouldRender = true
bridge.effectiveShouldRender = true
bridge.displayTime = bridge.displayTime + 1000000000
assert(Runtime.beginFrame(640, 480))
assert(math.abs(Runtime.frameDelta(0.5) - 0.011111111) < 0.000001,
  "resuming from standby must not catch up the elapsed display-time gap")
Runtime.abortFrame()

bridge.focused = false
assert(not Runtime.shouldSimulate())
bridge.focused = true
bridge.displayTime = bridge.displayTime + 1000000000
assert(Runtime.beginFrame(640, 480))
assert(math.abs(Runtime.frameDelta(0.5) - 0.011111111) < 0.000001,
  "resuming after focus loss must not catch up the elapsed display-time gap")
Runtime.abortFrame()

local actions = Runtime.pollActions()
assert(actions.a and bridge.pollCalls == 1,
  "game input polling remains separate from non-consuming status refresh")
Runtime.shutdown()
assert(not Runtime.isBridgeActive() and not Runtime.isFramePaced())
Runtime.setEnabled(false)
assert(not Runtime.isEnabled() and not Runtime.isBridgeActive())
assert(Runtime.frameDelta(0.016) == 0.016,
  "desktop mode must keep its host-timer delta")
assert(Runtime.shouldSimulate(), "desktop mode must preserve ordinary simulation")
print("runtime overlay tests passed")
