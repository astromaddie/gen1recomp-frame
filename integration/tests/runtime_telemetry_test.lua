local runtimePath = assert(arg[1], "pass integration/src/vr/Runtime.lua")
local integrationRoot = assert(runtimePath:match("^(.*)/src/vr/Runtime%.lua$"),
  "runtime path must end in integration/src/vr/Runtime.lua")
package.path = integrationRoot .. "/?.lua;" .. package.path

local oldGetenv, oldPrint, oldLoadlib = os.getenv, print, package.loadlib
os.getenv = function(key)
  if key == "POKEPORT_VR_TELEMETRY" then return "1" end
  if key == "POKEPORT_XRBRIDGE" then return "fake" end
  return oldGetenv(key)
end

local lines = {}
print = function(...)
  local values = {}
  for i = 1, select("#", ...) do values[i] = tostring(select(i, ...)) end
  lines[#lines + 1] = table.concat(values, " ")
end

local now = { wallNs = 100000000000, processCpuNs = 20000000000,
  mainCpuNs = 10000000000 }
local samples, polls = 0, 0
local bridge = {
  shouldRender = true,
  submits = 0,
  lastWaitWallNs = 8000000,
  lastWaitMainCpuNs = 80000,
}
function bridge.create() return true end
function bridge.beginFrame()
  now.wallNs = now.wallNs + bridge.lastWaitWallNs
  now.processCpuNs = now.processCpuNs + 120000
  now.mainCpuNs = now.mainCpuNs + bridge.lastWaitMainCpuNs
  return { fov = { left = -0.7, right = 0.7 } },
    { fov = { left = -0.7, right = 0.7 } }, bridge.shouldRender
end
function bridge.status()
  return { available = true, ready = true, focused = true,
    shouldRender = bridge.shouldRender, predictedDisplayPeriod = 11111111,
    predictedDisplayTime = now.wallNs, quitRequested = false,
    xrWaitWallNs = bridge.lastWaitWallNs,
    xrWaitMainCpuNs = bridge.lastWaitMainCpuNs }
end
function bridge.submitCanvases()
  bridge.submits = bridge.submits + 1
  now.wallNs = now.wallNs + 2000000
  now.processCpuNs = now.processCpuNs + 1000000
  now.mainCpuNs = now.mainCpuNs + 500000
  return true
end
function bridge.abortFrame() end
function bridge.telemetryClock()
  return { wallNs = now.wallNs, processCpuNs = now.processCpuNs,
    mainCpuNs = now.mainCpuNs }
end
function bridge.telemetryContext(frame, scene)
  bridge.context = { frame = frame, scene = scene }
  return true
end
function bridge.telemetryPollGpu() polls = polls + 1 end
function bridge.telemetrySample()
  samples = samples + 1
  if samples == 1 then return { intervalWallNs = 0 } end
  return { intervalWallNs = 1000000000, processCpuNs = 1500000000,
    mainCpuNs = 800000000, gpuBusyStatus = "unavailable",
    gpuTimestampStatus = "unsupported", gpuTimestampPending = 0,
    gpuTimestampDropped = 0, gpuTimestampErrors = 0,
    gpuTimestampResultsDropped = 0, gpuTimestamps = {}, gpuClients = {},
    gpuClientCount = 0, gpuAddedClients = 0, gpuRemovedClients = 0,
    gpuCounterRegressions = 0 }
end
function bridge.destroy() end

package.loadlib = function(path, symbol)
  assert(path == "fake" and symbol == "luaopen_xrbridge")
  return function() return bridge end
end

local Runtime = assert(loadfile(runtimePath))()
Runtime.setEnabled(true)
assert(Runtime.start() and Runtime.isBridgeActive())
local Telemetry = require("src.vr.Telemetry")
Telemetry.setScene("PEWTER_CITY/above", 0)
Telemetry.startWindow()

assert(Runtime.beginFrame(1728, 1728))
assert(Runtime.queue({}, {}))
assert(Runtime.flush() and bridge.submits == 1)

now.wallNs = now.wallNs + 1000000000
now.processCpuNs = now.processCpuNs + 1500000000
now.mainCpuNs = now.mainCpuNs + 800000000
assert(Runtime.beginFrame(1728, 1728))

local summary
local gpuStatus
for _, line in ipairs(lines) do
  if line:find("%[vr%-telemetry%] scene=PEWTER_CITY/above") then summary = line end
  if line:find("%[vr%-telemetry%-gpu%] scene=PEWTER_CITY/above") then gpuStatus = line end
end
assert(summary and summary:find("xr_begin_frame{n=2 wall_ms_p50=8.000")
  and summary:find("main_cpu_ms_p50=0.080")
  and summary:find("xr_submission"),
  "Runtime must record real begin-frame and submit wall/process/thread CPU stages")
assert(summary:find("xr_wait_wall{n=2 p50_ms=8.000")
  and summary:find("xr_wait_main_cpu{n=2 p50_ms=0.080"),
  "XR wait wall time and calling-thread execution time must stay distinct")
assert(gpuStatus and gpuStatus:find("query_status=unsupported")
  and gpuStatus:find("timestamps=0"),
  "unsupported GPU timestamps must remain visible as unsupported, not zero")
assert(polls == 2 and samples == 2,
  "GPU query readiness should poll per frame while counter samples stay at 1 Hz")
assert(bridge.context.scene == "PEWTER_CITY/above")

assert(Runtime.abortFrame())
bridge.shouldRender = false
now.wallNs = now.wallNs + 1000000000
now.processCpuNs = now.processCpuNs + 1000000000
now.mainCpuNs = now.mainCpuNs + 500000000
assert(Runtime.beginFrame(1728, 1728))
local excluded
for _, line in ipairs(lines) do
  if line:find("reason=focus%-or%-render%-loss") then excluded = line end
end
assert(excluded and not excluded:find("process_cpu_pct="),
  "Runtime's actual shouldRender state must exclude standby CPU utilization")

Telemetry.stopWindow()
Runtime.abortFrame()
Runtime.shutdown()
os.getenv, print, package.loadlib = oldGetenv, oldPrint, oldLoadlib
print("runtime telemetry path tests passed")
