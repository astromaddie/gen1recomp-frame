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

local function bucketFor(scene)
  local key = scene or "unknown"
  local bucket = state.buckets[key]
  if not bucket then
    bucket = {
      scene = key, frames = 0, submitted = 0, firstFrame = nil, lastFrame = nil,
      stages = {}, xrWaitWall = {}, xrWaitCpu = {},
      culler = { frames = 0, indexUpdates = 0, sourceIndices = 0,
        selectedIndices = 0, pendingDraws = 0 },
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
  culler.mode = status.mode or culler.mode
  culler.active = status.active == true
end

function Telemetry.isEnabled()
  return enabled
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
  if state.scene ~= scene then
    state.sceneChangesSinceSample = state.sceneChangesSinceSample + 1
    state.scene = scene
  end
  if frame ~= nil then state.frame = safeNumber(frame) end
  if bridge and type(bridge.telemetryContext) == "function" then
    pcall(bridge.telemetryContext, state.frame, state.scene)
  end
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

function Telemetry.recordFrame(frame, status)
  if not enabled then return end
  status = type(status) == "table" and status or {}
  state.frame = safeNumber(frame)
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
    if bucket.frames > 0 then
      local culler = bucket.culler
      local cullerText = string.format("culler_mode=%s culler_active=%s culler_samples=%d index_updates=%d source_indices=%d selected_indices=%d pending_draws=%d",
        tostring(culler.mode or "unavailable"), tostring(culler.active == true),
        culler.frames, culler.indexUpdates, culler.sourceIndices,
        culler.selectedIndices, culler.pendingDraws)
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
  if state.armed then printGpuTimestamps(sample, windowScene, tagsText) end
  state.buckets = {}
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
