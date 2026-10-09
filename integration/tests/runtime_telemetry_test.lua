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
  return { available = true, ready = true, focused = bridge.focused~=false,
    shouldRender = bridge.shouldRender, predictedDisplayPeriod = 11111111,
    predictedDisplayTime = bridge.displayTime or now.wallNs, quitRequested = false,
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

-- Observe the actual returned clock choice, including the existing 100ms
-- boundary. This test deliberately does not change the recovery policy.
Telemetry.startWindow()
bridge.shouldRender=true;bridge.displayTime=1000000000000
local function advance(ns,expected)
  bridge.displayTime=bridge.displayTime+ns
  assert(Runtime.beginFrame(1728,1728))
  assert(math.abs(Runtime.frameDelta(0.5)-expected)<1e-12)
  Runtime.abortFrame()
end
advance(0,0.011111111) -- startup
advance(22222222,0.022222222) -- skipped display frame is preserved
advance(100000000,0.1) -- inclusive boundary
advance(100000001,0.011111111) -- one ns over boundary uses period
bridge.focused=false
assert(not Runtime.shouldSimulate());assert(not Runtime.shouldSimulate())
assert(Runtime.beginFrame(1728,1728));Runtime.frameDelta(0.5);Runtime.abortFrame()
bridge.focused=true
advance(500000000,0.011111111) -- focus gap is reset, not discarded game time
bridge.shouldRender=false
assert(not Runtime.shouldSimulate());assert(not Runtime.shouldSimulate())
now.wallNs=now.wallNs+1000000000
Telemetry.sample()
local clockLine
for _,line in ipairs(lines) do if line:find("%[vr%-frame%-clock%]") then clockLine=line end end
assert(clockLine and clockLine:find("selected_calls=5") and clockLine:find("inactive_calls=1"),clockLine)
assert(clockLine:find("selected_sum_ms=155.556") and clockLine:find("selected_min_ms=11.111")
  and clockLine:find("selected_max_ms=100.000"),clockLine)
assert(clockLine:find("predicted_elapsed_count=3") and clockLine:find("predicted_elapsed_sum_ms=222.222")
  and clockLine:find("discarded_elapsed_ms=88.889"),clockLine)
assert(clockLine:find("fallback_count=3") and clockLine:find("startup:2,too%-long:1")
  and clockLine:find("runtime%-period:3"),clockLine)
assert(clockLine:find("clock_resets=2") and clockLine:find("focus%-loss:1,render%-loss:1"),clockLine)
-- New windows cannot inherit elapsed-time losses or reset counts.
Telemetry.startWindow();bridge.shouldRender=true
advance(1000000000,0.011111111)
now.wallNs=now.wallNs+1000000000;Telemetry.sample()
for _,line in ipairs(lines) do if line:find("%[vr%-frame%-clock%]") then clockLine=line end end
assert(clockLine:find("selected_calls=1") and clockLine:find("discarded_elapsed_ms=0.000")
  and clockLine:find("clock_resets=0"),clockLine)

Telemetry.stopWindow()
Runtime.abortFrame()
Runtime.shutdown()
os.getenv, print, package.loadlib = oldGetenv, oldPrint, oldLoadlib
print("runtime telemetry path tests passed")
