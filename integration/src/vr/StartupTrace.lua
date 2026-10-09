-- Explicit startup diagnostics only. No forced rendering or input injection.
local Trace = {}
local sampled, nextSample, samples, screen = false, 0, 0, "startup"
local function now()
  return love.timer and love.timer.getTime and love.timer.getTime() or 0
end
local function value(v)
  return tostring(v):gsub("[\r\n\t]", " ")
end
local function emit(stage, runtime, version, luaError)
  local status = runtime.status()
  local native = status.native or {}
  local g = love.graphics or {}
  local line = string.format(
    "[vr-startup] time=%.6f stage=%s screen=%s version=%s active=%s created=%s frame=%s open=%s bridge=%s session=%s focused=%s raw_render=%s effective_render=%s begins=%s submits=%s error=%s lua_error=%s\n",
    now(), stage, screen, value(version),
    value(g.isActive and g.isActive()), value(g.isCreated and g.isCreated()),
    value(status.frame), value(status.frameOpen), value(status.bridge),
    value(native.sessionState), value(native.focused), value(native.shouldRender),
    value(status.shouldRender), value(native.beginCount), value(native.submitCount),
    value(status.lastError or status.bridgeError), value(luaError):sub(1, 2048))
  io.stdout:write(line)
  io.stdout:flush()
end
function Trace.failure(message, runtime)
  emit("frame-error", runtime, nil, message)
end
function Trace.mark(stage, runtime, version)
  emit(stage, runtime, version)
end
function Trace.tick(runtime, currentScreen)
  sampled = false
  screen = currentScreen
  local time = now()
  -- Three minutes of samples, at most once per second; startup milestones
  -- remain available if a person spends longer choosing a game.
  if samples >= 180 or time < nextSample then return end
  samples, nextSample, sampled = samples + 1, time + 1, true
  emit("frame-enter", runtime)
end
function Trace.stage(stage, runtime)
  if sampled then emit(stage, runtime) end
end
return Trace
