local telemetryPath = assert(arg[1], "pass integration/src/vr/Telemetry.lua")
local oldGetenv = os.getenv
local oldPrint = print
os.getenv = function(key)
  if key == "POKEPORT_VR_TELEMETRY" then return "1" end
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
local sampleIndex = 0
local bridge
bridge = {
  gpuPolls = 0,
  resetWindows = 0,
  telemetryClock = function()
    return { wallNs = now.wallNs, processCpuNs = now.processCpuNs,
      mainCpuNs = now.mainCpuNs }
  end,
  telemetryContext = function(frame, scene)
    bridge.lastContext = { frame = frame, scene = scene }
    return true
  end,
  telemetryPollGpu = function() bridge.gpuPolls = bridge.gpuPolls + 1 end,
  telemetryResetWindow = function() bridge.resetWindows = bridge.resetWindows + 1 end,
  gpuScopeBegin = function(name, frame, scene)
    bridge.lastScope = { name = name, frame = frame, scene = scene }
    return true
  end,
  gpuScopeEnd = function() bridge.scopeEnded = true end,
  telemetrySample = function()
    sampleIndex = sampleIndex + 1
    if sampleIndex == 1 then return { intervalWallNs = 0 } end
    return {
      intervalWallNs = 1000000000,
      processCpuNs = 1500000000,
      mainCpuNs = 800000000,
      gpuBusyStatus = "partial",
      gpuBusyAvailable = true,
      gpuBusyPct = 50,
      gpuClientCount = 1,
      gpuAddedClients = 1,
      gpuRemovedClients = 0,
      gpuCounterRegressions = 0,
      gpuCurrentFreqHz = 600000000,
      gpuMaxFreqHz = 903000000,
      gpuClients = { { identity = "msm:no-pdev:417895", driver = "msm",
        busyPct = 50, cycles = 4, maxFreqHz = 903000000 } },
      gpuTimestampStatus = "available",
      gpuTimestampPending = 2,
      gpuTimestampDropped = 1,
      gpuTimestampErrors = 0,
      gpuTimestamps = { { name = "source_scene_eye1", scene = "PEWTER_CITY/above",
        frame = 10, durationNs = 7000000 } },
    }
  end,
}

local culler = { status = function()
  return { mode = "frustum", active = true, indexUpdates = 2,
    sourceIndices = 1000, selectedIndices = 250, pendingDraws = 1 }
end }
package.loaded["src.vr.DrawDistance"] = culler
local Telemetry = assert(loadfile(telemetryPath))()
assert(Telemetry.isEnabled())
Telemetry.attach(bridge)
Telemetry.setScene("PEWTER_CITY/above", 9)
assert(bridge.lastContext.scene == "PEWTER_CITY/above")
Telemetry.startWindow()
assert(bridge.resetWindows == 1,
  "the bounded diagnostic window must reset setup-time query drop counters")

local token = Telemetry.beginStage("game_draw")
now.wallNs = now.wallNs + 13000000
now.processCpuNs = now.processCpuNs + 9000000
now.mainCpuNs = now.mainCpuNs + 8000000
Telemetry.endStage(token)
assert(Telemetry.beginGpuScope("source_scene_eye1", "PEWTER_CITY/above"))
assert(bridge.lastScope.name == "source_scene_eye1" and bridge.lastScope.frame == 9)
Telemetry.endGpuScope(true)
assert(bridge.scopeEnded)
Telemetry.recordFrame(10, { focused = true, shouldRender = true,
  xrWaitWallNs = 8000000, xrWaitMainCpuNs = 1000000 })
Telemetry.recordSubmit()

now.wallNs = now.wallNs + 1000000000
now.processCpuNs = now.processCpuNs + 1500000000
now.mainCpuNs = now.mainCpuNs + 800000000
Telemetry.recordFrame(11, { focused = true, shouldRender = true,
  xrWaitWallNs = 9000000, xrWaitMainCpuNs = 1000000 })
Telemetry.recordSubmit()

local loadLine, sceneLine, gpuLine, clientLine
for _, line in ipairs(lines) do
  if line:find("%[vr%-telemetry%-load%]") then loadLine = line end
  if line:find("%[vr%-telemetry%] scene=PEWTER_CITY/above") then sceneLine = line end
  if line:find("%[vr%-telemetry%-gpu%] scene=PEWTER_CITY/above") then gpuLine = line end
  if line:find("%[vr%-telemetry%-gpu%-client%]") then clientLine = line end
end
assert(loadLine and loadLine:find("process_cpu_pct=150.0"),
  "process CPU utilization must use one-core normalization and may exceed 100 percent")
assert(loadLine:find("main_thread_cpu_pct=80.0")
  and loadLine:find("process_gpu_busy_pct=50.0"))
assert(sceneLine and sceneLine:find("scene=PEWTER_CITY/above")
  and sceneLine:find("game_draw") and sceneLine:find("index_updates=4")
  and sceneLine:find("xr_wait_wall"),
  "per-stage CPU/wall, wait wall, and sampled eligible geometry must be reported")
assert(gpuLine and gpuLine:find("source_scene_eye1") and gpuLine:find("frames=10%-10")
  and gpuLine:find("pending=2") and gpuLine:find("dropped=1"))
assert(clientLine and clientLine:find("msm:no%-pdev:417895")
  and clientLine:find("busy_pct=50.0"))
assert(bridge.gpuPolls == 2 and sampleIndex == 2,
  "readiness polling should run per frame while proc/sysfs sampling stays at 1 Hz")

Telemetry.setScene("PEWTER_GYM/above", 12)
now.wallNs = now.wallNs + 1000000000
now.processCpuNs = now.processCpuNs + 1000000000
now.mainCpuNs = now.mainCpuNs + 500000000
Telemetry.recordFrame(12, { focused = true, shouldRender = true })
local transitionLine
for _, line in ipairs(lines) do
  if line:find("cpu_interval_scene=transition%-or%-unrenderable") then transitionLine = line end
end
assert(transitionLine and not transitionLine:find("process_cpu_pct="),
  "CPU load across a map transition must not be labeled as one map")

now.wallNs = now.wallNs + 1000000000
now.processCpuNs = now.processCpuNs + 1000000000
now.mainCpuNs = now.mainCpuNs + 500000000
Telemetry.recordFrame(13, { focused = true, shouldRender = false })
local renderLossLine
for _, line in ipairs(lines) do
  if line:find("reason=focus%-or%-render%-loss") then renderLossLine = line end
end
assert(renderLossLine and not renderLossLine:find("process_cpu_pct="),
  "CPU utilization intervals containing render loss must be excluded")
Telemetry.stopWindow()
local samplesAfterStop = sampleIndex
assert(not Telemetry.beginGpuScope("after_stop", "PEWTER_GYM/above"))
Telemetry.recordFrame(14, { focused = true, shouldRender = true })
assert(sampleIndex == samplesAfterStop,
  "stopping the bounded window must stop timestamp scopes and system-counter scans")
os.getenv, print = oldGetenv, oldPrint
print("telemetry integration tests passed")
