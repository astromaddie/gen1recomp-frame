-- Opt-in Frame performance telemetry. CPU clocks are Linux monotonic,
-- process and calling-thread clocks; native file counters are sampled at 1 Hz.
local Telemetry = {}

local function requested()
  local ok, value = pcall(function()
    return os and os.getenv and os.getenv("POKEPORT_VR_TELEMETRY")
  end)
  return ok and value == "1"
end

local enabled = requested()
local bridge
local state = {
  scene = "unknown",
  frame = 0,
  measurementActive = false,
  focused = false,
  unattendedMode = false,
  forceRenderWindowActive = false,
  forcedRenderActive = false,
  forcedRenderExpired = false,
  forceRenderBlocked = false,
  poseSource = "unavailable",
  ipdSource = "unavailable",
  windowRuntimeFocusedFrames = 0,
  windowRuntimeShouldRenderFrames = 0,
  windowEffectiveRenderFrames = 0,
  windowForcedRenderFrames = 0,
  windowUnattendedFrames = 0,
  armed = enabled,
  lastSampleWallNs = nil,
  lastSampleScene = nil,
  sceneChangesSinceSample = 0,
  nonRenderableSinceSample = false,
  buckets = {},
  firstFrame = 0,
}

local function clock()
  if bridge and type(bridge.telemetryClock) == "function" then
    local ok, value = pcall(bridge.telemetryClock)
    if ok and type(value) == "table" then return value end
  end
  return nil
end

function Telemetry.monotonicNs()
  if not enabled then return nil end
  local value=clock();return value and value.wallNs
end

local function bucketFor(scene)
  local key = scene or "unknown"
  local bucket = state.buckets[key]
  if not bucket then
    bucket = {
      scene = key, frames = 0, submitted = 0, firstFrame = nil, lastFrame = nil,
      stages = {}, xrWaitWall = {}, xrWaitCpu = {},
      culler = { frames = 0, indexUpdates = 0, sourceIndices = 0,
        selectedIndices = 0, pendingDraws = 0, waterPassesSkipped = 0 },
    }
    state.buckets[key] = bucket
  end
  return bucket
end

local function appendStage(scene, name, wallNs, processCpuNs, mainCpuNs)
  if type(wallNs) ~= "number" or wallNs < 0 then return end
  local bucket = bucketFor(scene)
  local values = bucket.stages[name]
  if not values then values = { wall = {}, processCpu = {}, mainCpu = {} }; bucket.stages[name] = values end
  values.wall[#values.wall + 1] = wallNs
  if type(processCpuNs) == "number" then
    values.processCpu[#values.processCpu + 1] = processCpuNs
  end
  if type(mainCpuNs) == "number" then
    values.mainCpu[#values.mainCpu + 1] = mainCpuNs
  end
end

local function percentile(values, fraction)
  if #values == 0 then return nil end
  local sorted = {}
  for i, value in ipairs(values) do sorted[i] = value end
  table.sort(sorted)
  return sorted[math.max(1, math.ceil(#sorted * fraction))]
end

local function milliseconds(value)
  return value and string.format("%.3f", value / 1000000) or "unavailable"
end

local function stageSummary(values)
  if not values then return "samples=0" end
  return string.format("n=%d wall_ms_p50=%s wall_ms_p95=%s main_cpu_ms_p50=%s process_cpu_ms_p50=%s",
    #values.wall, milliseconds(percentile(values.wall, 0.50)),
    milliseconds(percentile(values.wall, 0.95)),
    milliseconds(percentile(values.mainCpu, 0.50)),
    milliseconds(percentile(values.processCpu, 0.50)))
end

local function safeNumber(value)
  return type(value) == "number" and value == value and value or 0
end

local function collectCuller(bucket)
  local module = package.loaded["src.vr.DrawDistance"]
  if type(module) ~= "table" or type(module.status) ~= "function" then return end
  local ok, status = pcall(module.status)
  if not ok or type(status) ~= "table" then return end
  local culler = bucket.culler
  culler.frames = culler.frames + 1
  culler.indexUpdates = culler.indexUpdates + safeNumber(status.indexUpdates)
  culler.sourceIndices = culler.sourceIndices + safeNumber(status.sourceIndices)
  culler.selectedIndices = culler.selectedIndices + safeNumber(status.selectedIndices)
  culler.pendingDraws = culler.pendingDraws + safeNumber(status.pendingDraws)
  culler.waterPassesSkipped = culler.waterPassesSkipped + safeNumber(status.waterPassesSkipped)
  culler.mode = status.mode or culler.mode
  culler.active = status.active == true
end

function Telemetry.isEnabled()
  return enabled
end

local function frameClockBucket()
  if not state.frameClock then
    state.frameClock={calls=0,inactive=0,selectedSum=0,predictedCount=0,predictedSum=0,predictedMax=0,
      discarded=0,fallbacks=0,reasons={},sources={},resets=0,resetReasons={}}
  end
  return state.frameClock
end

-- Account for the delta actually returned to love.update, separately from
-- submitted frames. Inactive calls do not represent simulation advancement.
function Telemetry.recordFrameDelta(selected,elapsed,reason,source,active)
  if not enabled or not state.armed then return end
  local c=frameClockBucket()
  c.firstFrame=c.firstFrame or state.frame;c.lastFrame=state.frame
  if not active then c.inactive=c.inactive+1;return end
  c.calls=c.calls+1;c.selectedSum=c.selectedSum+selected
  c.selectedMin=math.min(c.selectedMin or selected,selected)
  c.selectedMax=math.max(c.selectedMax or selected,selected)
  if elapsed then
    c.predictedCount=c.predictedCount+1;c.predictedSum=c.predictedSum+elapsed
    c.predictedMax=math.max(c.predictedMax,elapsed)
    c.discarded=c.discarded+math.max(0,elapsed-selected)
  end
  if reason~="predicted" then
    c.fallbacks=c.fallbacks+1;c.reasons[reason]=(c.reasons[reason] or 0)+1
    c.sources[source]=(c.sources[source] or 0)+1
  end
end

function Telemetry.recordClockReset(reason)
  if not enabled or not state.armed then return end
  local c=frameClockBucket()
  c.resets=c.resets+1;c.resetReasons[reason]=(c.resetReasons[reason] or 0)+1
end

local function reasonCounts(values)
  local result={}
  for reason,count in pairs(values) do result[#result+1]=reason..":"..count end
  table.sort(result)
  return #result>0 and table.concat(result,",") or "none"
end

function Telemetry.recordSettings(game,lib)
  if not enabled or not state.armed then return end
  local ok,shadows=pcall(function()return lib.require("Shadows").enabled()end)
  if not ok then shadows="unavailable" end
  local cap=package.loaded["src.core.FrameCap"]
  local maxFps=cap and cap.current or "unavailable"
  local speedOK,speed=pcall(function()return game:logicSpeed()end)
  if not speedOK then speed="unavailable" end
  local previous=state.settings
  if not previous or previous.scene~=state.scene or previous.shadows~=shadows
      or previous.maxFps~=maxFps or previous.speed~=speed then
    state.settings={scene=state.scene,shadows=shadows,maxFps=maxFps,speed=speed}
    print("[vr-settings]","frame="..state.frame,"scene="..state.scene,
      "shadows_enabled="..tostring(shadows),"max_fps_setting="..tostring(maxFps),"logic_speed="..tostring(speed))
  end
end

function Telemetry.attach(nativeBridge)
  if not enabled then return false end
  bridge = nativeBridge
  return true
end

function Telemetry.setFrame(frame)
  if not enabled then return end
  state.frame = safeNumber(frame)
end

function Telemetry.setScene(scene, frame)
  if not enabled then return end
  scene = type(scene) == "string" and scene ~= "" and scene or "unknown"
  state.baseScene=scene
  if state.phase then scene=scene.."/phase="..state.phase end
  if state.scene ~= scene then
    state.sceneChangesSinceSample = state.sceneChangesSinceSample + 1
    state.scene = scene
  end
  if frame ~= nil then state.frame = safeNumber(frame) end
  if bridge and type(bridge.telemetryContext) == "function" then
    pcall(bridge.telemetryContext, state.frame, state.scene)
  end
end

function Telemetry.setPhase(phase)
  if not enabled then return end
  state.phase=phase
  Telemetry.setScene(state.baseScene or "unknown")
end

function Telemetry.beginStage(name)
  if not enabled or not state.armed then return nil end
  local now = clock()
  if not now then return { name = name, scene = state.scene } end
  return { name = name, scene = state.scene, clock = now }
end

function Telemetry.endStage(token)
  if not enabled or not state.armed or type(token) ~= "table" then return end
  local finish = clock()
  if not finish or not token.clock then return end
  local before = token.clock
  appendStage(token.scene, token.name,
    math.max(0, safeNumber(finish.wallNs) - safeNumber(before.wallNs)),
    math.max(0, safeNumber(finish.processCpuNs) - safeNumber(before.processCpuNs)),
    math.max(0, safeNumber(finish.mainCpuNs) - safeNumber(before.mainCpuNs)))
end

-- Diagnostic CPU ownership scopes. Children are subtracted on this exact
-- invocation before aggregation; independently aggregated percentiles are
-- never subtracted. Existing wall/GPU stage summaries remain non-additive.
function Telemetry.beginCpuScope(name)
  if not enabled or not state.armed then return nil end
  local now=clock();if not now then return nil end
  local token={name=name,scene=state.scene,frame=state.frame,clock=now,parent=state.cpuScope,
    childWall=0,childMain=0,childProcess=0}
  state.cpuScope=token
  return token
end

function Telemetry.endCpuScope(token)
  if not token then return end
  if state.cpuScope~=token then
    state.cpuScope=nil
    local bucket=bucketFor(token.scene)
    bucket.cpuScopeErrors=(bucket.cpuScopeErrors or 0)+1
    return
  end
  state.cpuScope=token.parent
  local after=clock();if not after then return end
  local wall=math.max(0,safeNumber(after.wallNs)-safeNumber(token.clock.wallNs))
  local main=math.max(0,safeNumber(after.mainCpuNs)-safeNumber(token.clock.mainCpuNs))
  local process=math.max(0,safeNumber(after.processCpuNs)-safeNumber(token.clock.processCpuNs))
  if token.parent then
    local p=token.parent
    p.childWall=p.childWall+wall;p.childMain=p.childMain+main;p.childProcess=p.childProcess+process
  end
  local bucket=bucketFor(token.scene)
  bucket.cpuFirstFrame=math.min(bucket.cpuFirstFrame or token.frame,token.frame)
  bucket.cpuLastFrame=math.max(bucket.cpuLastFrame or token.frame,token.frame)
  bucket.cpuSelf=bucket.cpuSelf or {}
  local value=bucket.cpuSelf[token.name] or {calls=0,wall=0,main=0,process=0}
  bucket.cpuSelf[token.name]=value
  value.calls=value.calls+1;value.wall=value.wall+math.max(0,wall-token.childWall)
  value.main=value.main+math.max(0,main-token.childMain)
  value.process=value.process+math.max(0,process-token.childProcess)
end

function Telemetry.wrapCpu(owner,key,name)
  if not enabled or type(owner[key])~="function" then return function()end end
  local original,own=owner[key],rawget(owner,key)
  local function pack(...)return {n=select("#",...),...}end
  local wrapper=function(...)
    local token=Telemetry.beginCpuScope(name)
    local result=pack(pcall(original,...))
    Telemetry.endCpuScope(token)
    if not result[1] then error(result[2],0) end
    return unpack(result,2,result.n)
  end
  owner[key]=wrapper
  return function()if owner[key]==wrapper then owner[key]=own end end
end

function Telemetry.beginGpuScope(name, scene)
  if not enabled or not state.armed or not state.measurementActive or not bridge
      or type(bridge.gpuScopeBegin) ~= "function" then
    return false
  end
  local ok, opened = pcall(bridge.gpuScopeBegin, name, state.frame,
                           scene or state.scene)
  return ok and opened == true
end

function Telemetry.endGpuScope(opened)
  if not enabled or opened ~= true or not bridge
      or type(bridge.gpuScopeEnd) ~= "function" then return end
  pcall(bridge.gpuScopeEnd)
end

-- Source allocation attribution is opt-in. GPU scope names already carry
-- the current frame and actual VoxelScene call order (GamePresentation).
function Telemetry.recordSourceEye(eye,source,resolved,samples,factor)
  if not enabled or not state.armed or not state.measurementActive or not source or not resolved then return end
  local bucket=bucketFor(state.scene);bucket.sourceEyes=bucket.sourceEyes or {}
  local w,h=source:getDimensions();local rw,rh=resolved:getDimensions()
  local record=bucket.sourceEyes[eye]
  if not record or record.width~=w or record.height~=h or record.resolvedWidth~=rw
    or record.resolvedHeight~=rh or record.samples~=samples or record.factor~=factor then
    record={width=w,height=h,resolvedWidth=rw,resolvedHeight=rh,samples=samples,factor=factor,firstFrame=state.frame}
    bucket.sourceEyes[eye]=record
    print("[vr-source-eye]","scene="..state.scene,"frame="..state.frame,"eye="..eye,
      "source="..w.."x"..h,"resolved="..rw.."x"..rh,"aa_samples="..samples,"aa_factor="..factor,
      "source_fdm_attachment=unverified")
  end
  record.lastFrame=state.frame
end

local shadowFields={"terrainBuilds","terrainHits","terrainTriangles","dynamicTriangles",
  "sourceTerrainTriangles","sourceDynamicTriangles","restores","fallbacks"}
function Telemetry.recordShadows(status)
  if not enabled or not state.armed or not state.measurementActive or not status then return end
  local bucket=bucketFor(state.scene);bucket.shadows=bucket.shadows or {}
  for _,key in ipairs(shadowFields) do bucket.shadows[key]=(bucket.shadows[key] or 0)+safeNumber(status[key]) end
  bucket.shadowFallback=status.lastFallback or bucket.shadowFallback
end

function Telemetry.recordFrame(frame, status)
  if not enabled then return end
  status = type(status) == "table" and status or {}
  state.frame = safeNumber(frame)
  state.foveation = status
  state.focused = status.focused == true
  state.unattendedMode = status.unattendedMode == true
    or status.unattended == true
  state.forceRenderWindowActive = status.forceRenderActive == true
  state.forcedRenderActive = status.forcedRender == true
  state.forcedRenderExpired = status.forceRenderExpired == true
  state.forceRenderBlocked = status.forceRenderBlocked == true
  state.poseSource = status.poseSource or "unavailable"
  state.ipdSource = status.ipdSource or "unavailable"
  local runtimeShouldRender = status.shouldRender == true
  local effectiveShouldRender = status.effectiveShouldRender == true
    or runtimeShouldRender
  local forcedUnattendedRendering = state.unattendedMode
    and state.forceRenderWindowActive and effectiveShouldRender
  state.measurementActive = (state.focused and runtimeShouldRender)
    or forcedUnattendedRendering
  state.windowRuntimeFocusedFrames = state.windowRuntimeFocusedFrames
    + (state.focused and 1 or 0)
  state.windowRuntimeShouldRenderFrames = state.windowRuntimeShouldRenderFrames
    + (runtimeShouldRender and 1 or 0)
  state.windowEffectiveRenderFrames = state.windowEffectiveRenderFrames
    + (effectiveShouldRender and 1 or 0)
  state.windowForcedRenderFrames = state.windowForcedRenderFrames
    + (state.forcedRenderActive and 1 or 0)
  state.windowUnattendedFrames = state.windowUnattendedFrames
    + (state.unattendedMode and 1 or 0)
  if not state.measurementActive then state.nonRenderableSinceSample = true end
  if state.measurementActive and state.armed then
    local bucket = bucketFor(state.scene)
    bucket.frames = bucket.frames + 1
    if not bucket.firstFrame then bucket.firstFrame = state.frame end
    bucket.lastFrame = state.frame
    if type(status.xrWaitWallNs) == "number" then
      bucket.xrWaitWall[#bucket.xrWaitWall + 1] = status.xrWaitWallNs
      bucket.xrWaitCpu[#bucket.xrWaitCpu + 1] = safeNumber(status.xrWaitMainCpuNs)
    end
    bucket.unattended = state.unattendedMode
    bucket.runtimeFocusedFrames = (bucket.runtimeFocusedFrames or 0)
      + (state.focused and 1 or 0)
    bucket.runtimeShouldRenderFrames = (bucket.runtimeShouldRenderFrames or 0)
      + (runtimeShouldRender and 1 or 0)
    bucket.effectiveRenderFrames = (bucket.effectiveRenderFrames or 0)
      + (effectiveShouldRender and 1 or 0)
    bucket.forcedRenderFrames = (bucket.forcedRenderFrames or 0)
      + (state.forcedRenderActive and 1 or 0)
    collectCuller(bucket)
  end
  Telemetry.sample()
end

function Telemetry.recordSubmit()
  if not enabled or not state.armed or not state.measurementActive then return end
  bucketFor(state.scene).submitted = bucketFor(state.scene).submitted + 1
end

function Telemetry.startWindow()
  if not enabled then return false end
  state.buckets = {}
  state.frameClock = nil
  state.settings = nil
  state.cpuScope = nil
  state.armed = true
  state.firstFrame = state.frame + 1
  state.lastSampleWallNs = nil
  state.lastSampleScene = nil
  state.sceneChangesSinceSample = 0
  state.nonRenderableSinceSample = false
  state.windowRuntimeFocusedFrames = 0
  state.windowRuntimeShouldRenderFrames = 0
  state.windowEffectiveRenderFrames = 0
  state.windowForcedRenderFrames = 0
  state.windowUnattendedFrames = 0
  if bridge and type(bridge.telemetrySample) == "function" then
    -- Establish fresh CPU/DRM counter baselines without admitting warmup.
    pcall(bridge.telemetrySample)
  end
  if bridge and type(bridge.telemetryResetWindow) == "function" then
    -- Exclude setup-time query drops/results while retaining in-flight slots;
    -- those retain their issue-time frame and will be filtered from this window.
    pcall(bridge.telemetryResetWindow)
  end
  local baseline = clock()
  state.lastSampleWallNs = baseline and baseline.wallNs or nil
  return true
end

function Telemetry.stopWindow()
  if not enabled then return end
  state.armed = false
end

local function printSceneBuckets(loadSample, windowScene)
  for scene, bucket in pairs(state.buckets) do
    if bucket.cpuSelf then
      local parts,total={},0
      for name,value in pairs(bucket.cpuSelf) do
        parts[#parts+1]=string.format("%s{calls=%d main_cpu_ms_total=%s process_cpu_ms_total=%s wall_ms_total=%s}",
          name,value.calls,milliseconds(value.main),milliseconds(value.process),milliseconds(value.wall))
        total=total+value.main
      end
      table.sort(parts)
      print("[vr-cpu-attribution]","scene="..scene,
        "frame="..tostring(bucket.cpuFirstFrame).."-"..tostring(bucket.cpuLastFrame),
        "accounting=exclusive-invocation","coverage=instrumented-scopes",
        "scope_errors="..tostring(bucket.cpuScopeErrors or 0),"main_cpu_ms_total="..milliseconds(total),
        "stages="..table.concat(parts,";"))
    end
    if bucket.frames > 0 then
      local culler = bucket.culler
      local cullerText = string.format("culler_mode=%s culler_active=%s culler_samples=%d index_updates=%d source_indices=%d selected_indices=%d pending_draws=%d water_passes_skipped=%d",
        tostring(culler.mode or "unavailable"), tostring(culler.active == true),
        culler.frames, culler.indexUpdates, culler.sourceIndices,
        culler.selectedIndices, culler.pendingDraws, culler.waterPassesSkipped)
      local waitWall = string.format("n=%d p50_ms=%s p95_ms=%s",
        #bucket.xrWaitWall, milliseconds(percentile(bucket.xrWaitWall, 0.50)),
        milliseconds(percentile(bucket.xrWaitWall, 0.95)))
      local waitCpu = string.format("n=%d p50_ms=%s",
        #bucket.xrWaitCpu, milliseconds(percentile(bucket.xrWaitCpu, 0.50)))
      local mode = bucket.unattended and "unattended" or "focused"
      local stages = {}
      for name, values in pairs(bucket.stages) do
        stages[#stages + 1] = name .. "{" .. stageSummary(values) .. "}"
      end
      table.sort(stages)
      if bucket.shadows then
        local values={}
        for _,key in ipairs(shadowFields) do values[#values+1]=key.."="..bucket.shadows[key] end
        print("[vr-shadow-work]","scene="..scene,table.concat(values," "),"fallback="..tostring(bucket.shadowFallback or "none"))
      end
      for eye,source in pairs(bucket.sourceEyes or {}) do
        print("[vr-source-eye]","scene="..scene,"eye="..eye,"frame="..source.firstFrame.."-"..source.lastFrame,
          "source="..source.width.."x"..source.height,"resolved="..source.resolvedWidth.."x"..source.resolvedHeight,
          "aa_samples="..source.samples,"aa_factor="..source.factor,"source_fdm_attachment=unverified")
      end
      print("[vr-telemetry]", "scene=" .. scene,
        "mode=" .. mode,
        "frame=" .. tostring(bucket.firstFrame or state.firstFrame) .. "-" .. tostring(bucket.lastFrame or state.frame),
        "measured_frames=" .. tostring(bucket.frames),
        "runtime_focused_frames=" .. tostring(bucket.runtimeFocusedFrames or 0),
        "runtime_should_render_frames=" .. tostring(bucket.runtimeShouldRenderFrames or 0),
        "effective_render_frames=" .. tostring(bucket.effectiveRenderFrames or 0),
        "forced_render_frames=" .. tostring(bucket.forcedRenderFrames or 0),
        "submits=" .. tostring(bucket.submitted),
        "xr_wait_wall{" .. waitWall .. "}",
        "xr_wait_main_cpu{" .. waitCpu .. "}",
        "stages=" .. (#stages > 0 and table.concat(stages, ";") or "unavailable"),
        cullerText,
        "cpu_interval_scene=" .. tostring(windowScene))
    end
  end
end

local function modeTags()
  local mode = state.windowUnattendedFrames > 0 and "unattended" or "focused"
  return "mode=" .. mode,
    "force_render_mode=" .. tostring(state.unattendedMode),
    "force_render_window_active=" .. tostring(state.forceRenderWindowActive),
    "runtime_focused_frames=" .. tostring(state.windowRuntimeFocusedFrames),
    "runtime_should_render_frames=" .. tostring(state.windowRuntimeShouldRenderFrames),
    "effective_render_frames=" .. tostring(state.windowEffectiveRenderFrames),
    "forced_render_frames=" .. tostring(state.windowForcedRenderFrames),
    "force_render_expired=" .. tostring(state.forcedRenderExpired),
    "force_render_blocked=" .. tostring(state.forceRenderBlocked),
    "pose_source=" .. tostring(state.poseSource),
    "ipd_source=" .. tostring(state.ipdSource)
end

local function printGpuTimestamps(sample, fallbackScene, tags)
  local groups = {}
  for _, item in ipairs(sample.gpuTimestamps or {}) do
    if item.frame >= state.firstFrame then
      local key = item.scene
      local group = groups[key]
      if not group then group = {}; groups[key] = group end
      local list = group[item.name]
      if not list then list = { values = {}, firstFrame = item.frame, lastFrame = item.frame }; group[item.name] = list end
      list.values[#list.values + 1] = item.durationNs
      list.firstFrame = math.min(list.firstFrame, item.frame)
      list.lastFrame = math.max(list.lastFrame, item.frame)
    end
  end
  for scene, scopes in pairs(groups) do
    local summaries = {}
    for name, values in pairs(scopes) do
      summaries[#summaries + 1] = string.format("%s_n=%d_ms_p50=%s_ms_p95=%s_frames=%d-%d",
        name, #values.values, milliseconds(percentile(values.values, 0.50)),
        milliseconds(percentile(values.values, 0.95)), values.firstFrame, values.lastFrame)
    end
    table.sort(summaries)
    print("[vr-telemetry-gpu]", "scene=" .. scene, tags,
      "frames=" .. tostring(state.firstFrame) .. "-" .. tostring(state.frame),
      "query_status=" .. tostring(sample.gpuTimestampStatus),
      "pending=" .. tostring(sample.gpuTimestampPending),
      "dropped=" .. tostring(sample.gpuTimestampDropped),
      "errors=" .. tostring(sample.gpuTimestampErrors),
      "results_dropped=" .. tostring(sample.gpuTimestampResultsDropped or 0),
      table.concat(summaries, ";"))
  end
  if not next(groups) then
    print("[vr-telemetry-gpu]", "scene=" .. tostring(fallbackScene), tags,
      "frames=" .. tostring(state.firstFrame) .. "-" .. tostring(state.frame),
      "query_status=" .. tostring(sample.gpuTimestampStatus),
      "pending=" .. tostring(sample.gpuTimestampPending),
      "dropped=" .. tostring(sample.gpuTimestampDropped),
      "errors=" .. tostring(sample.gpuTimestampErrors),
      "results_dropped=" .. tostring(sample.gpuTimestampResultsDropped or 0),
      "timestamps=0")
  end
end

function Telemetry.sample()
  if not enabled or not bridge or type(bridge.telemetryClock) ~= "function"
      or type(bridge.telemetrySample) ~= "function" then return end
  if type(bridge.telemetryPollGpu) == "function" then
    pcall(bridge.telemetryPollGpu)
  end
  if not state.armed then return end
  local now = clock()
  if not now then return end
  if state.lastSampleWallNs and now.wallNs - state.lastSampleWallNs < 1000000000 then return end
  state.lastSampleWallNs = now.wallNs
  local ok, sample = pcall(bridge.telemetrySample)
  if not ok or type(sample) ~= "table" then return end

  for _,stage in ipairs(sample.cpuStages or {}) do
    if stage.frame >= state.firstFrame then
      appendStage(stage.scene,stage.name,stage.wallNs,stage.processCpuNs,stage.mainCpuNs)
    end
  end
  if (sample.cpuStagesDropped or 0) > 0 then
    print("[vr-telemetry]", "cpu_stages_dropped=" .. tostring(sample.cpuStagesDropped))
  end
  local f=state.foveation
  if f and f.foveationRequested then
    print("[vr-foveation-frame]","frame="..state.frame,"scene="..state.scene,
      "requested="..tostring(f.foveationRequested),"applied="..tostring(f.foveationApplied),
      "attempted="..tostring(f.foveationFrameAttempted),"updated="..tostring(f.foveationFrameUpdated),
      "update_eye1="..tostring(f.foveationUpdateEye1Result),"update_eye2="..tostring(f.foveationUpdateEye2Result),
      "query_attempted="..tostring(f.foveationQueryAttempted),"query_result="..tostring(f.foveationQueryResult),
      "eye_valid="..tostring(f.foveationEyeValid),"flags="..tostring(f.foveationEyeFlags),
      "eye1_ndc="..tostring(f.foveationCenterEye1X)..","..tostring(f.foveationCenterEye1Y),
      "eye2_ndc="..tostring(f.foveationCenterEye2X)..","..tostring(f.foveationCenterEye2Y),
      "display_time="..tostring(f.foveationDisplayTime),"raw_focused="..tostring(f.focused),
      "raw_should_render="..tostring(f.shouldRender),"forced="..tostring(f.forcedRender),
      "source_fdm_attachment=unverified")
  end
  local stableScene = state.sceneChangesSinceSample == 0
      and not state.nonRenderableSinceSample and state.measurementActive
  local windowScene = stableScene and state.scene or "transition-or-unrenderable"
  local tags = { modeTags() }
  local tagsText = table.concat(tags, " ")
  if state.armed and stableScene and sample.intervalWallNs > 0 then
    local wall = sample.intervalWallNs
    print("[vr-telemetry-load]", "scene=" .. windowScene, tagsText,
      "window_wall_ms=" .. milliseconds(wall),
      "process_cpu_pct=" .. string.format("%.1f", sample.processCpuNs * 100 / wall),
      "main_thread_cpu_pct=" .. string.format("%.1f", sample.mainCpuNs * 100 / wall),
      "gpu_busy_status=" .. tostring(sample.gpuBusyStatus),
      "process_gpu_busy_pct=" .. (sample.gpuBusyPct and string.format("%.1f", sample.gpuBusyPct) or "unavailable"),
      "gpu_clients=" .. tostring(sample.gpuClientCount),
      "gpu_added=" .. tostring(sample.gpuAddedClients),
      "gpu_removed=" .. tostring(sample.gpuRemovedClients),
      "gpu_counter_regressions=" .. tostring(sample.gpuCounterRegressions),
      "gpu_current_mhz=" .. (sample.gpuCurrentFreqHz and sample.gpuCurrentFreqHz > 0
        and string.format("%.0f", sample.gpuCurrentFreqHz / 1000000) or "unavailable"),
      "gpu_max_mhz=" .. (sample.gpuMaxFreqHz and sample.gpuMaxFreqHz > 0
        and string.format("%.0f", sample.gpuMaxFreqHz / 1000000) or "unavailable"))
    for _, client in ipairs(sample.gpuClients or {}) do
      print("[vr-telemetry-gpu-client]", "scene=" .. windowScene, tagsText,
        "identity=" .. tostring(client.identity), "driver=" .. tostring(client.driver),
        "busy_pct=" .. (client.busyPct and string.format("%.1f", client.busyPct) or "warming"),
        "cycles=" .. tostring(client.cycles or "unavailable"),
        "max_mhz=" .. (client.maxFreqHz and string.format("%.0f", client.maxFreqHz / 1000000) or "unavailable"))
    end
  elseif state.armed and (state.nonRenderableSinceSample
      or state.sceneChangesSinceSample > 0) then
    local reason = state.nonRenderableSinceSample
        and "focus-or-render-loss" or "scene-transition"
    print("[vr-telemetry]", "window=excluded", "reason=" .. reason,
      tagsText,
      "scene=" .. tostring(windowScene),
      "cpu_interval_scene=" .. tostring(windowScene))
  end
  if state.armed and sample.intervalWallNs > 0 then
    -- Stage clocks carry their own scene-at-begin identity, so a transition
    -- excludes interval utilization without discarding useful per-scene work.
    printSceneBuckets(sample, windowScene)
  end
  local c=state.frameClock
  if c then
    local function ms(seconds)return milliseconds(seconds and seconds*1000000000)end
    print("[vr-frame-clock]","scene="..tostring(windowScene),
      "frame="..tostring(c.firstFrame or state.frame).."-"..tostring(c.lastFrame or state.frame),
      "selected_calls="..c.calls,"inactive_calls="..c.inactive,
      "selected_sum_ms="..ms(c.selectedSum),"selected_min_ms="..ms(c.selectedMin),"selected_max_ms="..ms(c.selectedMax),
      "predicted_elapsed_count="..c.predictedCount,"predicted_elapsed_sum_ms="..ms(c.predictedSum),
      "predicted_elapsed_max_ms="..ms(c.predictedMax),"discarded_elapsed_ms="..ms(c.discarded),
      "fallback_count="..c.fallbacks,"fallback_reasons="..reasonCounts(c.reasons),
      "fallback_sources="..reasonCounts(c.sources),"clock_resets="..c.resets,"reset_reasons="..reasonCounts(c.resetReasons))
  end
  if state.armed then printGpuTimestamps(sample, windowScene, tagsText) end
  state.buckets = {}
  state.frameClock = nil
  state.sceneChangesSinceSample = 0
  state.nonRenderableSinceSample = false
  state.lastSampleScene = state.scene
  state.windowRuntimeFocusedFrames = 0
  state.windowRuntimeShouldRenderFrames = 0
  state.windowEffectiveRenderFrames = 0
  state.windowForcedRenderFrames = 0
  state.windowUnattendedFrames = 0
end

return Telemetry
