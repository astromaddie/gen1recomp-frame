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
      cpuStages = {{name="swapchain_wait_eye1",scene="PEWTER_CITY/above",frame=10,
        wallNs=4000000,processCpuNs=200000,mainCpuNs=100000}},
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
Telemetry.recordFrame(9, { focused = true, shouldRender = true })
local shadowEnabled,speed=true,1
package.loaded["src.core.FrameCap"]={current=75}
local settingsGame={logicSpeed=function()return speed end}
local settingsLib={require=function(name)assert(name=="Shadows");return {enabled=function()return shadowEnabled end}end}
Telemetry.recordSettings(settingsGame,settingsLib)
local settingsCount=#lines
Telemetry.recordSettings(settingsGame,settingsLib);assert(#lines==settingsCount,"unchanged settings should not spam")
shadowEnabled=false;speed=2;Telemetry.recordSettings(settingsGame,settingsLib)
assert(lines[#lines]:find("shadows_enabled=false") and lines[#lines]:find("max_fps_setting=75")
  and lines[#lines]:find("logic_speed=2"),"settings snapshot must read actual game getters")

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
local source={getDimensions=function()return 2444,2444 end}
local resolved={getDimensions=function()return 1728,1728 end}
Telemetry.recordSourceEye(1,source,resolved,2,2444/1728)
Telemetry.recordShadows({terrainBuilds=1,terrainHits=2,terrainTriangles=42,dynamicTriangles=8,
  sourceTerrainTriangles=84,sourceDynamicTriangles=12,restores=3,fallbacks=0})

now.wallNs = now.wallNs + 1000000000
now.processCpuNs = now.processCpuNs + 1500000000
now.mainCpuNs = now.mainCpuNs + 800000000
Telemetry.recordFrame(11, { focused = true, shouldRender = true,
  xrWaitWallNs = 9000000, xrWaitMainCpuNs = 1000000,
  foveationRequested="eye",foveationApplied="eye-medium",foveationFrameAttempted=true,
  foveationFrameUpdated=true,foveationQueryAttempted=true,foveationQueryResult=0,
  foveationEyeValid=false,foveationEyeFlags=0,foveationCenterEye1X=0,foveationCenterEye1Y=0,
  foveationCenterEye2X=0,foveationCenterEye2Y=0 })
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
  and sceneLine:find("game_draw") and sceneLine:find("index_updates=6")
  and sceneLine:find("xr_wait_wall"),
  "per-stage CPU/wall, wait wall, and sampled eligible geometry must be reported")
assert(gpuLine and gpuLine:find("source_scene_eye1") and gpuLine:find("frames=10%-10")
  and gpuLine:find("pending=2") and gpuLine:find("dropped=1"))
assert(clientLine and clientLine:find("msm:no%-pdev:417895")
  and clientLine:find("busy_pct=50.0"))
assert(bridge.gpuPolls == 3 and sampleIndex == 2,
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

-- Unattended rendering is measured only while its explicit native window is
-- active; raw focus and shouldRender remain false in every emitted record.
Telemetry.setScene("PEWTER_CITY/unattended", 15)
assert(Telemetry.startWindow())
local forcedStatus = { focused = false, shouldRender = false,
  effectiveShouldRender = true, unattended = true, forceRenderActive = true,
  forcedRender = true, poseSource = "synthetic-fixed-center",
  ipdSource = "runtime" }
Telemetry.recordFrame(15, forcedStatus)
assert(Telemetry.beginGpuScope("source_scene_eye1", "PEWTER_CITY/unattended"))
Telemetry.endGpuScope(true)
Telemetry.recordSubmit()
now.wallNs = now.wallNs + 1000000000
now.processCpuNs = now.processCpuNs + 1200000000
now.mainCpuNs = now.mainCpuNs + 700000000
Telemetry.recordFrame(16, forcedStatus)
local forcedLoad, forcedScene, forcedGpu
for _, line in ipairs(lines) do
  if line:find("%[vr%-telemetry%-load%]") and line:find("mode=unattended") then
    forcedLoad = line
  end
  if line:find("scene=PEWTER_CITY/unattended") and line:find("measured_frames=2") then
    forcedScene = line
  end
  if line:find("%[vr%-telemetry%-gpu%]") and line:find("mode=unattended") then
    forcedGpu = line
  end
end
assert(forcedLoad and forcedLoad:find("runtime_focused_frames=0")
  and forcedLoad:find("runtime_should_render_frames=0")
  and forcedLoad:find("effective_render_frames=2")
  and forcedLoad:find("forced_render_frames=2")
  and forcedLoad:find("pose_source=synthetic%-fixed%-center")
  and forcedLoad:find("ipd_source=runtime"),
  "unattended CPU/GPU load must retain raw runtime flags and synthetic-pose provenance")
assert(forcedScene and forcedScene:find("mode=unattended")
  and forcedScene:find("runtime_focused_frames=0")
  and forcedScene:find("submits=1"),
  "scene summaries must label actual forced work separately from raw focused frames")
assert(forcedGpu and forcedGpu:find("force_render_mode=true")
  and forcedGpu:find("force_render_window_active=true"),
  "GPU timestamp summaries must carry unattended authorization tags")

Telemetry.stopWindow()
os.getenv, print = oldGetenv, oldPrint
assert(table.concat(lines,"\n"):find("swapchain_wait_eye1",1,true),"native CPU stages missing")
local output=table.concat(lines,"\n")
assert(output:find("source=2444x2444 resolved=1728x1728 aa_samples=2",1,true),"actual source/resolve allocation missing")
assert(output:find("terrainBuilds=1 terrainHits=2 terrainTriangles=42 dynamicTriangles=8",1,true),"shadow pass attribution missing")
assert(output:find("eye_valid=false flags=0",1,true) and output:find("source_fdm_attachment=unverified",1,true),"eye validity/source attribution missing")
print("telemetry integration tests passed")
