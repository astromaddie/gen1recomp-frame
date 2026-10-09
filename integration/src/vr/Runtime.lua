-- Optional, deliberately small VR runtime boundary.
--
-- The game can require this module on every platform.  Loading a native
-- xrbridge module is delayed until start(), and every call into that module
-- is protected so a missing DLL, headset, or malformed pose falls back to a
-- harmless desktop stereo-preview state.

local Runtime = {}
local monoPanel
local telemetryRequested = false
pcall(function()
  telemetryRequested = os and os.getenv
    and os.getenv("POKEPORT_VR_TELEMETRY") == "1" or false
end)
local telemetryModule
local telemetryAttempted = false

local function telemetry()
  if not telemetryRequested then return nil end
  if not telemetryAttempted then
    telemetryAttempted = true
    local ok, module = pcall(require, "src.vr.Telemetry")
    if ok and module.isEnabled() then telemetryModule = module end
  end
  return telemetryModule
end

local DEFAULT_IPD = 0.064
local DEFAULT_FOV = math.rad(90)
local WORLD_PIXELS_PER_METER = 48
-- The game camera is already collision-safe at the character's map position.
-- Keep room-scale head translation inside that cell-sized safety envelope so a
-- seated player can lean naturally without moving the eye through a wall,
-- floor, or ceiling. Rotation remains unrestricted and is the primary VR
-- looking control.
local POSE_MAX_HORIZONTAL_OFFSET = 5
local POSE_MAX_VERTICAL_DOWN = 4
local POSE_MAX_VERTICAL_UP = 5

local function envEnabled()
  local ok, value = pcall(function()
    return os and os.getenv and os.getenv("POKEPORT_VR")
  end)
  return ok and value == "1"
end

local function finiteNumber(value)
  return type(value) == "number"
    and value == value
    and math.abs(value) < 1e9
end

local function copyTable(value)
  if type(value) ~= "table" then return {} end
  local result = {}
  pcall(function()
    for key, item in pairs(value) do result[key] = item end
  end)
  return result
end

local function copyVector(value)
  return { x = value.x, y = value.y, z = value.z }
end

local function clampPoseOffset(eye, anchor)
  local dx = eye.x - anchor.x
  local dy = eye.y - anchor.y
  local dz = eye.z - anchor.z
  local horizontal = math.sqrt(dx * dx + dz * dz)
  if horizontal > POSE_MAX_HORIZONTAL_OFFSET and horizontal > 0 then
    local scale = POSE_MAX_HORIZONTAL_OFFSET / horizontal
    dx, dz = dx * scale, dz * scale
  end
  dy = math.max(-POSE_MAX_VERTICAL_DOWN,
               math.min(POSE_MAX_VERTICAL_UP, dy))
  return {
    x = anchor.x + dx,
    y = anchor.y + dy,
    z = anchor.z + dz,
  }
end

-- Accept both the named vector form used by Lua callers and the compact
-- numeric-array form commonly returned by native bindings.
local function readVector(value)
  if type(value) ~= "table" then return nil end
  local x = value.x
  if x == nil then x = value[1] end
  local y = value.y
  if y == nil then y = value[2] end
  local z = value.z
  if z == nil then z = value[3] end
  if not finiteNumber(x) or not finiteNumber(y or 0)
     or not finiteNumber(z or 0) then
    return nil
  end
  return { x = x, y = y or 0, z = z or 0 }
end

local function validFov(value)
  if finiteNumber(value) and value > 0 then return value end
  if type(value) ~= "table" then return nil end
  -- Keep a bridge's four-angle FOV representation intact, but reject an
  -- arbitrary table so malformed native data cannot leak into the renderer.
  local result = {}
  local found = false
  for _, key in ipairs({ "left", "right", "up", "down" }) do
    if value[key] ~= nil then
      if not finiteNumber(value[key]) then return nil end
      result[key] = value[key]
      found = true
    end
  end
  return found and result or nil
end

local function vectorFromCamera(camera, key)
  return readVector(camera[key])
end

local function defaultCenter(camera)
  return vectorFromCamera(camera, "position")
    or vectorFromCamera(camera, "eye")
    or readVector({
      x = finiteNumber(camera.x) and camera.x or 0,
      y = finiteNumber(camera.y) and camera.y or 0,
      z = finiteNumber(camera.z) and camera.z or 0,
    })
end

local function defaultFocus(camera, center)
  local focus = vectorFromCamera(camera, "focus")
    or vectorFromCamera(camera, "target")
  if focus then return focus end

  local forward = vectorFromCamera(camera, "forward")
  if forward then
    return {
      x = center.x + forward.x,
      y = center.y + forward.y,
      z = center.z + forward.z,
    }
  end
  return { x = center.x, y = center.y, z = center.z - 1 }
end

local function focusFromOrientation(position, orientation)
  if type(orientation) ~= "table" then return nil end
  local x = orientation.x or orientation[1]
  local y = orientation.y or orientation[2]
  local z = orientation.z or orientation[3]
  local w = orientation.w or orientation[4]
  if not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z)
     or not finiteNumber(w) then return nil end
  -- OpenXR poses use a right-handed frame and views look along -Z. Rotate
  -- that forward vector by the headset quaternion for a head-tracked focus.
  local fx = -2 * (x * z + w * y)
  local fy =  2 * (w * x - y * z)
  local fz = -1 + 2 * (x * x + y * y)
  return { x = position.x + fx, y = position.y + fy, z = position.z + fz }
end

local function readQuaternion(value)
  if type(value) ~= "table" then return nil end
  local x = value.x or value[1]
  local y = value.y or value[2]
  local z = value.z or value[3]
  local w = value.w or value[4]
  if not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z)
     or not finiteNumber(w) then return nil end
  local length = math.sqrt(x * x + y * y + z * z + w * w)
  if length < 1e-6 then return nil end
  return { x = x / length, y = y / length, z = z / length,
           w = w / length }
end

local function quaternionConjugate(q)
  return { x = -q.x, y = -q.y, z = -q.z, w = q.w }
end

local function quaternionMultiply(a, b)
  return {
    x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
  }
end

local function quaternionRotate(q, vector)
  local v = { x = vector.x, y = vector.y, z = vector.z, w = 0 }
  local rotated = quaternionMultiply(quaternionMultiply(q, v),
                                     quaternionConjugate(q))
  return { x = rotated.x, y = rotated.y, z = rotated.z }
end

local function crossVector(a, b)
  return {
    x = a.y * b.z - a.z * b.y,
    y = a.z * b.x - a.x * b.z,
    z = a.x * b.y - a.y * b.x,
  }
end

local function normalizedVector(vector, fallback)
  local length = math.sqrt(vector.x * vector.x + vector.y * vector.y
    + vector.z * vector.z)
  if length < 1e-6 then return fallback end
  return { x = vector.x / length, y = vector.y / length,
           z = vector.z / length }
end

local function normalizedRight(camera)
  local right = vectorFromCamera(camera, "right") or { x = 1, y = 0, z = 0 }
  local length = math.sqrt(right.x * right.x + right.y * right.y
    + right.z * right.z)
  if length < 1e-6 then return { x = 1, y = 0, z = 0 } end
  return { x = right.x / length, y = right.y / length, z = right.z / length }
end

-- OpenXR's local view direction is -Z.  A game camera is free to face a
-- different world direction, so rotate the headset in its camera basis rather
-- than applying the quaternion directly to the world-space forward vector.
-- This keeps pitch intuitive for the game's +Z-facing POV and leaves yaw in
-- the same camera-relative direction.
local function trackedDirection(delta, baseForward)
  local baseRight = normalizedVector(crossVector(baseForward,
                                                  { x = 0, y = 1, z = 0 }),
                                      { x = 1, y = 0, z = 0 })
  local baseUp = crossVector(baseRight, baseForward)
  local localForward = quaternionRotate(delta, { x = 0, y = 0, z = -1 })
  return normalizedVector({
    x = baseRight.x * localForward.x
      + baseUp.x * localForward.y
      - baseForward.x * localForward.z,
    y = baseRight.y * localForward.x
      + baseUp.y * localForward.y
      - baseForward.y * localForward.z,
    z = baseRight.z * localForward.x
      + baseUp.z * localForward.y
      - baseForward.z * localForward.z,
  }, baseForward)
end

local function validAspect(aspect, camera)
  if not finiteNumber(aspect) or aspect <= 0 then
    aspect = camera.aspect
  end
  if not finiteNumber(aspect) or aspect <= 0 then aspect = 1 end
  return aspect
end

local function validIpd(camera)
  local ipd = camera.ipd
  if not finiteNumber(ipd) or ipd <= 0 then ipd = DEFAULT_IPD end
  return ipd
end

local function callFunction(fn, ...)
  local ok, first, second, third = pcall(fn, ...)
  if not ok then return false, nil, nil, first end
  return true, first, second, third
end

local function errorText(value)
  if type(value) == "string" then return value end
  local ok, text = pcall(tostring, value)
  return ok and text or "unknown bridge error"
end

local state = {
  enabled = envEnabled(),
  started = false,
  bridge = nil,
  bridgeAttempted = false,
  bridgeActive = false,
  bridgeError = nil,
  mode = envEnabled() and "preview" or "disabled",
  frame = 0,
  preview = nil,
  frameViews = nil,
  frameOpen = false,
  framePaced = false,
  shouldRender = true,
  poseOrigin = nil,
  poseScale = WORLD_PIXELS_PER_METER,
  lastPredictedDisplayTime = nil,
  predictedFrameDelta = nil,
  pendingSubmit = nil,
  lastError = nil,
  nativeStatus = nil,
  cameraSetbackMeters = 0,
}

do
  local ok, value = pcall(function() return os.getenv("POKEPORT_VR_CAMERA_SETBACK_METERS") end)
  value = ok and tonumber(value) or 0
  if finiteNumber(value) then state.cameraSetbackMeters = math.max(0, math.min(3, value)) end
end

local function setError(prefix, value)
  state.lastError = prefix .. ": " .. errorText(value)
end

local function nativeLastError()
  if type(state.bridge) ~= "table" or type(state.bridge.lastError) ~= "function" then
    return nil
  end
  local ok, value = callFunction(state.bridge.lastError)
  if not ok or value == nil or value == "" then return nil end
  return errorText(value)
end

local function refreshNativeStatus()
  if type(state.bridge) ~= "table" then return state.nativeStatus end
  local status = state.bridge.status or state.bridge.pollActions
  if type(status) ~= "function" then return state.nativeStatus end
  local ok, value, _, err = callFunction(status)
  if not ok then
    setError("xrbridge status", err)
    return state.nativeStatus
  end
  if type(value) == "table" then
    state.nativeStatus = copyTable(value)
    if value.ready == false then state.framePaced = false end
  end
  return state.nativeStatus
end

local function loadBridge()
  if state.bridgeAttempted then return state.bridge end
  state.bridgeAttempted = true

  local candidate, failure
  local explicitPath
  pcall(function()
    explicitPath = os and os.getenv and os.getenv("POKEPORT_XRBRIDGE")
  end)
  if explicitPath and explicitPath ~= "" then
    if not package or type(package.loadlib) ~= "function" then
      failure = "package.loadlib is unavailable for " .. explicitPath
    else
      local loaded, factory, loadError = pcall(package.loadlib, explicitPath,
                                               "luaopen_xrbridge")
      if not loaded then
        failure = factory
      elseif type(factory) ~= "function" then
        failure = loadError or factory
          or "package.loadlib returned no factory or diagnostic"
      else
        local called, value, factoryError = pcall(factory)
        if not called then
          failure = value
        elseif type(value) ~= "table" then
          failure = factoryError or "xrbridge factory did not return a table"
        else
          candidate = value
        end
      end
    end
  else
    local loaded, value = pcall(require, "xrbridge")
    if loaded then candidate = value else failure = value end
  end

  if failure then
    -- Absence is the normal desktop path; keep it as diagnostic state rather
    -- than as a runtime error that callers must handle.
    state.bridgeError = errorText(failure)
    local required = false
    pcall(function()
      required = os and os.getenv and os.getenv("POKEPORT_VR_REQUIRED") == "1"
    end)
    if (explicitPath and explicitPath ~= "") or required then
      pcall(function()
        if io and io.stderr then
          io.stderr:write("[vr] xrbridge load failed: " .. state.bridgeError .. "\n")
        end
      end)
    end
    return nil
  end
  if type(candidate) ~= "table" then
    state.bridgeError = "xrbridge module did not return a table"
    if (explicitPath and explicitPath ~= "") then
      pcall(function()
        if io and io.stderr then
          io.stderr:write("[vr] xrbridge load failed: " .. state.bridgeError .. "\n")
        end
      end)
    end
    return nil
  end
  state.bridge = candidate
  state.bridgeError = nil
  return candidate
end

local function bridgeMethod(bridge, names)
  for _, name in ipairs(names) do
    if type(bridge[name]) == "function" then return bridge[name], name end
  end
  return nil, nil
end

local function beginPreviewFrame()
  state.preview = nil
end

local function fallbackCameras(baseCamera, aspect)
  local camera = type(baseCamera) == "table" and baseCamera or {}
  local center = defaultCenter(camera)
  local focus = defaultFocus(camera, center)
  local right = normalizedRight(camera)
  local halfIpd = validIpd(camera) / 2
  local fov = validFov(camera.fov) or DEFAULT_FOV

  local leftEye = {
    x = center.x - right.x * halfIpd,
    y = center.y - right.y * halfIpd,
    z = center.z - right.z * halfIpd,
  }
  local rightEye = {
    x = center.x + right.x * halfIpd,
    y = center.y + right.y * halfIpd,
    z = center.z + right.z * halfIpd,
  }

  local function makeEye(name, index, eye)
    local result = copyTable(camera)
    result.eye = eye
    result.focus = copyVector(focus)
    result.fov = fov
    result.aspect = aspect
    result.ipd = halfIpd * 2
    result.eyeName = name
    result.eyeIndex = index
    result.stereo = true
    return result
  end

  return makeEye("left", 1, leftEye), makeEye("right", 2, rightEye),
    center, focus, fov
end

local function bridgeCamera(baseCamera, fallback, rawView, name, index, aspect)
  if type(rawView) ~= "table" then return nil end

  local pose = rawView.pose or rawView.viewPose
  local rawPosition = readVector(rawView.position)
    or readVector(rawView.location)
    or readVector(rawView.eye)
  if not rawPosition and type(pose) == "table" then
    rawPosition = readVector(pose.position) or readVector(pose.eye)
  end
  if not rawPosition then rawPosition = readVector(rawView) end

  local result = copyTable(fallback)
  local derivedPoseUsable = rawView.poseUsable == true
  local positionValid = derivedPoseUsable or rawView.positionValid ~= false
  local orientationValid = derivedPoseUsable or rawView.orientationValid ~= false
  local orientation = readQuaternion(rawView.orientation)
  if not orientation and type(pose) == "table" then
    orientation = readQuaternion(pose.orientation)
  end

  -- OpenXR reports meters in a local reference space; the voxel renderer uses
  -- map pixels. Anchor the first tracked pose to the current game camera and
  -- apply only subsequent movement in a small, explicit world scale.
  local center = defaultCenter(baseCamera)
  local baseFocus = defaultFocus(baseCamera, center)
  local baseForward = normalizedVector({
    x = baseFocus.x - center.x,
    y = baseFocus.y - center.y,
    z = baseFocus.z - center.z,
  }, { x = 0, y = 0, z = -1 })
  local baseRight = normalizedVector(crossVector(baseForward,
    { x = 0, y = 1, z = 0 }), { x = 1, y = 0, z = 0 })
  local baseUp = crossVector(baseRight, baseForward)
  local eye = copyVector(fallback.eye)
  if positionValid and rawPosition and state.poseOrigin
     and state.poseOrigin.position then
    local origin = state.poseOrigin.position
    local anchor = state.poseOrigin.center or fallback.eye
    local function inCameraBasis(position)
      local offset = {
        x = position.x - origin.x,
        y = position.y - origin.y,
        z = position.z - origin.z,
      }
      if state.poseOrigin.orientation then
        offset = quaternionRotate(quaternionConjugate(state.poseOrigin.orientation), offset)
      end
      return {
        x = (baseRight.x * offset.x + baseUp.x * offset.y - baseForward.x * offset.z) * state.poseScale,
        y = (baseRight.y * offset.x + baseUp.y * offset.y - baseForward.y * offset.z) * state.poseScale,
        z = (baseRight.z * offset.x + baseUp.z * offset.y - baseForward.z * offset.z) * state.poseScale,
      }
    end
    -- Translation and rotation must share the recentered camera basis.
    -- Raw tracking XYZ otherwise puts IPD along depth after a 90-degree
    -- recenter, or swaps the eyes when the game camera faces +Z.
    local offset = inCameraBasis(rawPosition)
    local head = inCameraBasis(state.poseOrigin.currentPosition or origin)
    local clamped = clampPoseOffset({
      x = anchor.x + head.x, y = anchor.y + head.y, z = anchor.z + head.z,
    }, anchor)
    -- Clamp the head centre, not each eye independently: eye-wise clamping
    -- collapses IPD at the lean boundary and changes apparent world scale.
    eye = { x = clamped.x + offset.x - head.x,
      y = clamped.y + offset.y - head.y, z = clamped.z + offset.z - head.z }
  end

  local focus = readVector(rawView.target)
  local trackedUp
  if orientationValid and orientation and state.poseOrigin
     and state.poseOrigin.orientation then
    -- Poses are local-to-reference transforms.  Form the relative rotation
    -- in the headset's recentered local frame (origin^-1 * current), then
    -- let the renderer map that local -Z/+Y/+X basis onto the game camera.
    -- Using current * origin^-1 would express the delta in reference-space
    -- axes, making pitch depend on which way the player faced at recenter.
    local delta = quaternionMultiply(
      quaternionConjugate(state.poseOrigin.orientation), orientation)
    local forward = trackedDirection(delta, baseForward)
    local localUp = quaternionRotate(delta, { x = 0, y = 1, z = 0 })
    trackedUp = {
      x = baseRight.x * localUp.x + baseUp.x * localUp.y - baseForward.x * localUp.z,
      y = baseRight.y * localUp.x + baseUp.y * localUp.y - baseForward.y * localUp.z,
      z = baseRight.z * localUp.x + baseUp.z * localUp.y - baseForward.z * localUp.z,
    }
    local distance = math.sqrt(
      (baseFocus.x - center.x)^2
      + (baseFocus.y - center.y)^2
      + (baseFocus.z - center.z)^2)
    focus = {
      x = eye.x + forward.x * distance,
      y = eye.y + forward.y * distance,
      z = eye.z + forward.z * distance,
    }
  end
  result.eye = eye
  result.focus = focus or copyVector(fallback.focus)
  result.baseEye = copyVector(center)
  result.baseFocus = copyVector(baseFocus)
  result.fov = validFov(rawView.fov) or fallback.fov
  if finiteNumber(rawView.width) and rawView.width > 0 then
    result.width = math.floor(rawView.width)
  end
  if finiteNumber(rawView.height) and rawView.height > 0 then
    result.height = math.floor(rawView.height)
  end
  result.aspect = aspect
  result.eyeName = name
  result.eyeIndex = index
  result.stereo = true
  if orientation then result.orientation = orientation end
  -- Supply the complete tracked camera directly. The reference voxel mod's
  -- legacy orientationDelta branch removes roll, which disagrees with the
  -- full pose submitted to OpenXR and makes the world move on head tilt.
  result.orientationDelta = nil
  if trackedUp then result.up = trackedUp end
  if rawView.rotation ~= nil then result.rotation = rawView.rotation end
  if pose ~= nil then result.pose = pose end
  return result
end

local function establishPoseOrigin(left, right, center)
  local leftDerivedPoseUsable = type(left) == "table"
    and left.poseUsable == true
  local rightDerivedPoseUsable = type(right) == "table"
    and right.poseUsable == true
  local leftPosition = type(left) == "table"
    and (leftDerivedPoseUsable or left.positionValid ~= false)
    and (readVector(left.position) or readVector(left.location)) or nil
  local rightPosition = type(right) == "table"
    and (rightDerivedPoseUsable or right.positionValid ~= false)
    and (readVector(right.position) or readVector(right.location)) or nil
  local position
  if leftPosition and rightPosition then
    position = {
      x = (leftPosition.x + rightPosition.x) / 2,
      y = (leftPosition.y + rightPosition.y) / 2,
      z = (leftPosition.z + rightPosition.z) / 2,
    }
  else
    position = leftPosition or rightPosition
  end

  local orientation = type(left) == "table"
    and (leftDerivedPoseUsable or left.orientationValid ~= false)
    and readQuaternion(left.orientation) or nil
  if not orientation and type(right) == "table"
     and (rightDerivedPoseUsable or right.orientationValid ~= false) then
    orientation = readQuaternion(right.orientation)
  end
  local origin = state.poseOrigin or {}
  if position then origin.currentPosition = position end
  if position and not origin.position then origin.position = position end
  if orientation and not origin.orientation then origin.orientation = orientation end
  -- The game camera follows the player. Keep the physical headset offset
  -- relative to that moving camera anchor rather than pinning it to the
  -- first frame of the session; otherwise walking leaves the VR world behind
  -- at the point where the headset was first detected.
  if center then origin.center = center end
  if origin.position or origin.orientation then
    state.poseOrigin = origin
  end
end

local function splitBridgeViews(first, second)
  local left, right = first, second
  if second ~= nil or type(first) ~= "table" then return left, right end

  local container = first
  local nested = container.views or container.poses
  if type(nested) == "table" then container = nested end
  local hasPair = container.left ~= nil or container.right ~= nil
    or container[1] ~= nil or container[2] ~= nil
  if hasPair then
    left = container.left or container[1]
    right = container.right or container[2]
  end
  return left, right
end

local function bridgeViewCameras(baseCamera, leftFallback, rightFallback, aspect)
  if not state.bridgeActive or type(state.bridge) ~= "table" then return nil end
  if state.frameViews then
    local center = {
      x = (leftFallback.eye.x + rightFallback.eye.x) / 2,
      y = (leftFallback.eye.y + rightFallback.eye.y) / 2,
      z = (leftFallback.eye.z + rightFallback.eye.z) / 2,
    }
    establishPoseOrigin(state.frameViews[1], state.frameViews[2], center)
    return bridgeCamera(baseCamera, leftFallback, state.frameViews[1],
                        "left", 1, aspect),
      bridgeCamera(baseCamera, rightFallback, state.frameViews[2],
                   "right", 2, aspect)
  end
  local fn = bridgeMethod(state.bridge, { "getViews", "getViewPoses", "views" })
  if not fn then return nil end

  local ok, first, second, err = callFunction(fn, aspect)
  if not ok then
    setError("xrbridge views", err)
    return nil
  end
  local rawLeft, rawRight = splitBridgeViews(first, second)
  local center = {
    x = (leftFallback.eye.x + rightFallback.eye.x) / 2,
    y = (leftFallback.eye.y + rightFallback.eye.y) / 2,
    z = (leftFallback.eye.z + rightFallback.eye.z) / 2,
  }
  establishPoseOrigin(rawLeft, rawRight, center)
  return bridgeCamera(baseCamera, leftFallback, rawLeft, "left", 1, aspect)
    or leftFallback,
    bridgeCamera(baseCamera, rightFallback, rawRight, "right", 2, aspect)
      or rightFallback
end

function Runtime.isEnabled()
  return state.enabled
end

function Runtime.mode()
  return state.mode
end

function Runtime.isBridgeActive()
  return state.bridgeActive
end

function Runtime.isFramePaced()
  return state.bridgeActive and state.framePaced
end

local XR_MIN_FRAME_DELTA = 1 / 240
local XR_MAX_FRAME_DELTA = 0.1
local XR_DEFAULT_FRAME_DELTA = 1 / 72

local function validXrTimestamp(value)
  -- XrTime is a nanosecond int64 and commonly exceeds finiteNumber's small
  -- application-value ceiling; validate timestamps independently.
  return type(value) == "number" and value == value
    and value > 0 and value < 9e18
    and value ~= math.huge and value ~= -math.huge
end

local function periodFrameDelta(native)
  local period = native and native.predictedDisplayPeriod
  if type(period) == "number" and period == period and period > 0
     and period < 1e9 then
    local seconds = period / 1000000000
    if seconds >= XR_MIN_FRAME_DELTA and seconds <= XR_MAX_FRAME_DELTA then
      return seconds
    end
  end
  return XR_DEFAULT_FRAME_DELTA
end

local function resetXrFrameClock()
  state.lastPredictedDisplayTime = nil
  state.predictedFrameDelta = nil
end

local function updateXrFrameClock(native)
  local ordinaryRendering = native and native.focused == true
    and native.shouldRender == true
  local forcedUnattendedRendering = native and native.unattended == true
    and native.forceRenderActive == true
    and native.effectiveShouldRender == true
  if not ordinaryRendering and not forcedUnattendedRendering then
    resetXrFrameClock()
    return
  end

  local displayTime = native.predictedDisplayTime
  local delta = periodFrameDelta(native)
  if validXrTimestamp(displayTime) then
    local previous = state.lastPredictedDisplayTime
    if validXrTimestamp(previous) and displayTime > previous then
      local measured = (displayTime - previous) / 1000000000
      -- Stalls and malformed/nonmonotonic runtime timestamps must not turn
      -- into a large simulation catch-up. Period is the startup/recovery path.
      if measured >= XR_MIN_FRAME_DELTA and measured <= XR_MAX_FRAME_DELTA then
        delta = measured
      end
    end
    state.lastPredictedDisplayTime = displayTime
  else
    state.lastPredictedDisplayTime = nil
  end
  state.predictedFrameDelta = delta
end

-- xrWaitFrame is the clock once OpenXR starts pacing. Use the difference
-- between successive predicted display times to account for dropped display
-- frames, with the runtime period for startup/resume and invalid timestamps.
function Runtime.frameDelta(fallback)
  if not Runtime.isFramePaced() then return fallback end
  return state.predictedFrameDelta
    or periodFrameDelta(state.nativeStatus or refreshNativeStatus() or {})
end

-- Focus loss and standby freeze game simulation. The bridge still polls
-- OpenXR events and closes empty frames from draw until rendering resumes.
function Runtime.shouldSimulate()
  if not state.bridgeActive then return true end
  local native = refreshNativeStatus() or {}
  local ordinaryRendering = native.focused == true and native.shouldRender == true
  local forcedUnattendedRendering = native.unattended == true
    and native.forceRenderActive == true
    and native.effectiveShouldRender == true
  local active = ordinaryRendering or forcedUnattendedRendering
  if not active then resetXrFrameClock() end
  return active
end

function Runtime.isQuitRequested()
  if not state.bridgeActive then return false end
  local native = refreshNativeStatus() or {}
  return native.quitRequested == true or native.instanceLossPending == true
end

function Runtime.setEnabled(on)
  local enabled = on == true
  if not enabled then
    Runtime.shutdown()
    state.enabled = false
    state.mode = "disabled"
    return false
  end

  state.enabled = true
  if not state.started then state.mode = "preview" end
  return true
end

function Runtime.start(width, height)
  if not state.enabled then
    state.mode = "disabled"
    return false
  end
  if state.started then
    -- The desktop mirror is an independent, resizable LOVE canvas. Native
    -- OpenXR swapchains use the headset's recommended eye dimensions and do
    -- not need to be torn down when that mirror changes size. Recreating the
    -- native session during a Windows resize can race the compositor and
    -- crash inside the OpenXR/SteamVR loader.
    return true
  end

  state.started = true
  state.lastError = nil
  local bridge = loadBridge()
  if bridge then
    state.bridgeActive = true
    -- The native module uses create(config); older adapters used start().
    -- Keep both spellings supported without making the bridge mandatory.
    local start = bridge.create or bridge.start
    if type(start) == "function" then
      local config = nil
      -- The desktop drawable is not the headset's render target.  Let OpenXR
      -- choose each eye's recommended size so the submitted image fills the
      -- headset view; explicit overrides remain available for diagnostics.
      local requestedWidth, requestedHeight
      pcall(function()
        requestedWidth = tonumber(os and os.getenv
          and os.getenv("POKEPORT_VR_WIDTH"))
        requestedHeight = tonumber(os and os.getenv
          and os.getenv("POKEPORT_VR_HEIGHT"))
      end)
      if requestedWidth and requestedHeight
          and requestedWidth > 0 and requestedHeight > 0 then
        config = { width = math.floor(requestedWidth),
                   height = math.floor(requestedHeight) }
      end
      local ok, result, detail, err = callFunction(start, config)
      if not ok then
        state.bridgeActive = false
        state.mode = "preview"
        setError("xrbridge start", err)
      elseif result == false then
        state.bridgeActive = false
        state.mode = "preview"
        setError("xrbridge start", err or detail or "bridge declined startup")
      end
    end
  end
  if state.bridgeActive then state.mode = "bridge" else state.mode = "preview" end
  local diagnostics = telemetry()
  if diagnostics then diagnostics.attach(state.bridge) end
  state.startedWidth = width
  state.startedHeight = height
  return true
end

local function ensureStarted(width, height)
  if not state.enabled then return false end
  if not state.started then
    Runtime.start(width, height)
  end
  return state.started
end

function Runtime.beginFrame(width, height)
  if state.frameOpen then Runtime.abortFrame() end
  if not ensureStarted(width, height) then return false end
  state.frame = state.frame + 1
  beginPreviewFrame()
  state.frameViews = nil
  state.frameOpen = false
  state.shouldRender = true
  state.framePaced = false
  state.predictedFrameDelta = nil
  local diagnostics = telemetry()
  if diagnostics then diagnostics.setFrame(state.frame) end

  if state.bridgeActive then
    local begin = state.bridge.beginFrame
    if type(begin) == "function" then
      local stage = diagnostics and diagnostics.beginStage("xr_begin_frame")
      local ok, first, second, third = callFunction(begin)
      if diagnostics then diagnostics.endStage(stage) end
      if ok and first ~= nil and first ~= false then
        state.frameViews = { first, second }
        state.frameOpen = true
        state.framePaced = true
        state.shouldRender = third ~= false
      elseif not ok then
        -- SteamVR can take a few frames to move the session from idle to
        -- focused. Keep the bridge alive and use the local IPD camera while
        -- that happens instead of permanently abandoning VR.
        setError("xrbridge beginFrame", third or "bridge declined frame")
        state.shouldRender = false
        local abort = state.bridge.abortFrame or state.bridge.discardFrame
        if type(abort) == "function" then pcall(abort) end
      else
        setError("xrbridge beginFrame",
          nativeLastError() or "the OpenXR session is not ready for frames")
        state.shouldRender = false
      end
      refreshNativeStatus()
    end
  end
  if state.framePaced then
    updateXrFrameClock(state.nativeStatus)
  else
    resetXrFrameClock()
  end
  if diagnostics then
    local telemetryStatus = copyTable(state.nativeStatus)
    telemetryStatus.effectiveShouldRender = state.shouldRender
    diagnostics.recordFrame(state.frame, telemetryStatus)
  end
  return true
end

function Runtime.shouldRender()
  return state.shouldRender
end

-- The game camera can change its world anchor independently of the headset
-- pose (for example when the voxel view switches from ABOVE to POV). Drop
-- the old anchor so the next tracked frame establishes the physical headset
-- position against the new game camera instead of leaving the player behind.
function Runtime.recenter()
  state.poseOrigin = nil
  if monoPanel then monoPanel.reset() end
  return true
end

function Runtime.views(baseCamera, aspect)
  local camera = type(baseCamera) == "table" and baseCamera or {}
  if state.enabled and state.cameraSetbackMeters > 0
     and (camera.mode == "above" or camera.mode == "third") then
    local center = defaultCenter(camera)
    local focus = defaultFocus(camera, center)
    local forward = normalizedVector({x=focus.x-center.x,y=focus.y-center.y,z=focus.z-center.z},
      {x=0,y=0,z=-1})
    local offset = state.cameraSetbackMeters * WORLD_PIXELS_PER_METER
    camera = copyTable(camera)
    camera.eye = {x=center.x-forward.x*offset,y=center.y-forward.y*offset,z=center.z-forward.z*offset}
    camera.position = camera.eye
    camera.focus = {x=focus.x-forward.x*offset,y=focus.y-forward.y*offset,z=focus.z-forward.z*offset}
  end
  aspect = validAspect(aspect, camera)
  if state.enabled then ensureStarted() end

  local left, right = fallbackCameras(camera, aspect)
  if state.bridgeActive then
    local bridgeLeft, bridgeRight = bridgeViewCameras(camera, left, right, aspect)
    if bridgeLeft and bridgeRight then left, right = bridgeLeft, bridgeRight end
  end
  return left, right
end

function Runtime.compositeHud(source, target, eyeIndex)
  if not state.bridgeActive or not state.frameViews then return false end
  monoPanel = monoPanel or require("src.vr.MonoPanel")
  monoPanel.composite(source, state.frameViews, eyeIndex, target)
  return true
end

local function canvasValue(value)
  -- Real canvases are userdata; headless tests and desktop adapters commonly
  -- use a table-shaped canvas.  Nil is also useful for an intentionally blank
  -- eye and is passed through to the bridge.
  return value == nil or type(value) == "userdata" or type(value) == "table"
end

-- Native OpenXR uploads are intentionally kept at the module boundary. LÖVE
-- does not expose a stable GPU texture handle to Lua, so the optional bridge
-- accepts tightly packed RGBA8 bytes. This readback is a deliberately simple
-- compatibility path; the bridge remains optional and can later be replaced
-- by a zero-copy adapter without changing voxel code.
local function canvasPixels(canvas)
  if type(canvas) ~= "userdata" and type(canvas) ~= "table" then
    return nil, nil, nil, "canvas value is not userdata/table"
  end
  local makeData = canvas.newImageData
  if type(makeData) ~= "function" then
    return nil, nil, nil, "Canvas:newImageData is unavailable"
  end
  local ok, imageData, _, dataError = callFunction(makeData, canvas)
  if not ok then
    return nil, nil, nil, "Canvas:newImageData failed: " .. errorText(dataError)
  end
  if not imageData then
    return nil, nil, nil, "Canvas:newImageData returned nil"
  end
  local getString = imageData.getString
  if type(getString) ~= "function" then
    return nil, nil, nil, "ImageData:getString is unavailable"
  end
  local okString, bytes, _, stringError = callFunction(getString, imageData)
  if not okString then
    return nil, nil, nil, "ImageData:getString failed: " .. errorText(stringError)
  end
  if type(bytes) ~= "string" then
    return nil, nil, nil, "ImageData:getString did not return a string"
  end

  local width, height
  if type(imageData.getDimensions) == "function" then
    local okSize, w, h = callFunction(imageData.getDimensions, imageData)
    if okSize then width, height = w, h end
  end
  if (not finiteNumber(width) or not finiteNumber(height)
      or width <= 0 or height <= 0)
     and type(canvas.getDimensions) == "function" then
    local okSize, w, h = callFunction(canvas.getDimensions, canvas)
    if okSize then width, height = w, h end
  end
  if not finiteNumber(width) or not finiteNumber(height)
     or width <= 0 or height <= 0 then
    return nil, nil, nil, "could not determine Canvas dimensions"
  end
  width, height = math.floor(width), math.floor(height)
  if #bytes ~= width * height * 4 then
    return nil, nil, nil, ("RGBA8 byte count was %d, expected %d"):format(
      #bytes, width * height * 4)
  end
  return width, height, bytes, nil
end

function Runtime.submit(leftCanvas, rightCanvas, options)
  if not ensureStarted() then return false end
  if not canvasValue(leftCanvas) then
    setError("vr submit", "leftCanvas is not a Canvas-like value")
    leftCanvas = nil
  end
  if not canvasValue(rightCanvas) then
    setError("vr submit", "rightCanvas is not a Canvas-like value")
    rightCanvas = nil
  end

  if state.bridgeActive then
    -- Linux binds to LOVE 11.5 Canvas userdata and copies directly through
    -- GPU framebuffers. This keeps true-3D eye targets on the projection layer
    -- without Canvas:newImageData() readback or a mono composition quad.
    local submitCanvases = state.bridge.submitCanvases
    if type(submitCanvases) == "function" then
      if leftCanvas and leftCanvas == rightCanvas then
        monoPanel = monoPanel or require("src.vr.MonoPanel")
        local rendered, left, right = pcall(monoPanel.render, leftCanvas, state.frameViews)
        if not rendered then
          setError("vr mono panel", left)
          Runtime.abortFrame()
          return false
        end
        leftCanvas, rightCanvas = left, right
      elseif monoPanel then
        monoPanel.reset()
      end
      local ok, result, detail, err = callFunction(submitCanvases,
        leftCanvas, rightCanvas)
      if ok and result ~= false then
        state.frameOpen = false
        state.lastError = nil
        return true
      end
      setError("xrbridge submitCanvases",
        err or detail or nativeLastError() or "bridge declined Canvas submission")
      return false
    end

    -- The intro, menus, and other fallback screens are one flat image.  A
    -- quad layer keeps them at a comfortable distance and avoids sending the
    -- same texture through both perspective eyes, which causes stereo overlap.
    local submitQuad = state.bridge.submitQuad
    if rightCanvas == leftCanvas and type(submitQuad) == "function" then
      local width, height, bytes, readError = canvasPixels(leftCanvas)
      if width and height then
        local quadScale = tonumber(options and options.quadScale) or 1
        if quadScale <= 0 then quadScale = 1 end
        if quadScale > 4 then quadScale = 4 end
        local ok, result, detail, err = callFunction(submitQuad,
          width, height, bytes, quadScale)
        if ok and result ~= false then
          state.frameOpen = false
          state.lastError = nil
          return true
        end
        setError("xrbridge submitQuad",
          err or detail or nativeLastError() or "bridge declined quad submission")
      else
        setError("xrbridge submitQuad", readError
          or "could not read the monoscopic RGBA8 image from the LÖVE canvas")
      end
      Runtime.abortFrame()
      return false
    end

    if type(state.bridge.submit) ~= "function" then
      setError("xrbridge submit", "bridge has no submit function")
      Runtime.abortFrame()
      return false
    end
    local leftWidth, leftHeight, leftBytes, leftError = canvasPixels(leftCanvas)
    local rightWidth, rightHeight, rightBytes
    local rightError
    if rightCanvas == leftCanvas then
      rightWidth, rightHeight, rightBytes, rightError =
        leftWidth, leftHeight, leftBytes, leftError
    else
      rightWidth, rightHeight, rightBytes, rightError = canvasPixels(rightCanvas)
    end
    if leftWidth and rightWidth and leftWidth == rightWidth
       and leftHeight == rightHeight then
      local ok, result, detail, err = callFunction(state.bridge.submit,
        leftWidth, leftHeight, leftBytes, rightBytes)
      if ok and result ~= false then
        state.frameOpen = false
        state.lastError = nil
        return true
      end
      setError("xrbridge submit",
        err or detail or nativeLastError() or "bridge declined submission")
    else
      setError("xrbridge submit",
        leftError or rightError
          or "could not read equal-size RGBA8 eye images from the LÖVE canvases")
    end
    Runtime.abortFrame()
    return false
  end

  -- No bridge is a supported desktop mode.  Keep the actual handles so a
  -- desktop compositor or debug overlay can display the two eye images later.
  state.preview = {
    active = true,
    frame = state.frame,
    leftCanvas = leftCanvas,
    rightCanvas = rightCanvas,
  }
  return true
end

function Runtime.queue(leftCanvas, rightCanvas, options)
  if not state.enabled then return false end
  state.pendingSubmit = { leftCanvas = leftCanvas, rightCanvas = rightCanvas,
                          options = options }
  return true
end

function Runtime.hasPendingSubmission()
  return state.pendingSubmit ~= nil
end

function Runtime.flush()
  local pending = state.pendingSubmit
  state.pendingSubmit = nil
  if not pending then return true end
  local diagnostics = telemetry()
  local stage = diagnostics and diagnostics.beginStage("xr_submission")
  local ok = Runtime.submit(pending.leftCanvas, pending.rightCanvas,
                            pending.options)
  if diagnostics then
    diagnostics.endStage(stage)
    if ok then diagnostics.recordSubmit() end
  end
  refreshNativeStatus()
  return ok
end

function Runtime.abortFrame()
  state.pendingSubmit = nil
  if not state.frameOpen then return true end
  local bridge = state.bridge
  local abort = type(bridge) == "table"
    and (bridge.abortFrame or bridge.discardFrame) or nil
  if type(abort) == "function" then
    local ok, _, _, err = callFunction(abort)
    if not ok then setError("xrbridge abortFrame", err) end
  end
  state.frameOpen = false
  state.frameViews = nil
  return true
end

function Runtime.pollActions()
  if not ensureStarted() then return {} end
  if not state.bridgeActive then return {} end

  local poll = state.bridge.pollActions
  if type(poll) ~= "function" then return {} end
  local ok, status, _, err = callFunction(poll)
  if not ok then
    setError("xrbridge pollActions", err)
    return {}
  end
  if type(status) ~= "table" or type(status.actions) ~= "table" then
    return {}
  end
  return status.actions
end

function Runtime.shutdown()
  local bridge = state.bridge
  Runtime.abortFrame()
  if monoPanel then monoPanel.release() end
  local culling = package.loaded["src.vr.DrawDistance"]
  if culling then culling.release() end
  local stop = type(bridge) == "table"
    and (bridge.shutdown or bridge.destroy) or nil
  if type(stop) == "function" then
    local ok, _, _, err = callFunction(stop)
    if not ok then setError("xrbridge shutdown", err) end
  end
  state.started = false
  state.bridge = nil
  state.bridgeAttempted = false
  state.bridgeActive = false
  state.frameViews = nil
  state.frameOpen = false
  state.framePaced = false
  state.shouldRender = true
  state.poseOrigin = nil
  resetXrFrameClock()
  state.pendingSubmit = nil
  state.startedWidth = nil
  state.startedHeight = nil
  state.preview = nil
  state.nativeStatus = nil
  state.mode = state.enabled and "preview" or "disabled"
  return true
end

function Runtime.status()
  -- Refresh after submit so the desktop mirror can report the native frame
  -- counters from the same frame, rather than one frame behind.
  if state.bridgeActive then refreshNativeStatus() end
  local preview = nil
  if state.preview then
    preview = {
      active = true,
      frame = state.preview.frame,
      leftCanvas = state.preview.leftCanvas,
      rightCanvas = state.preview.rightCanvas,
    }
  end
  return {
    enabled = state.enabled,
    mode = state.mode,
    started = state.started,
    bridge = state.bridgeActive,
    frame = state.frame,
    frameOpen = state.frameOpen,
    shouldRender = state.shouldRender,
    preview = preview,
    previewActive = preview ~= nil,
    bridgeError = state.bridgeError,
    lastError = state.lastError,
    native = copyTable(state.nativeStatus),
  }
end

Runtime.DEFAULT_IPD = DEFAULT_IPD
Runtime.DEFAULT_FOV = DEFAULT_FOV

return Runtime
