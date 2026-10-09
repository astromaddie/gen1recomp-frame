-- Restore the copied Yellow save into its ABOVE camera scene, then
-- leave the controls free for a focused/renderable outdoor-to-indoor interval.
local runSavedScene = assert(loadfile(assert(os.getenv("POKEPORT_SAVED_SCENE_DRIVER"),
  "Set POKEPORT_SAVED_SCENE_DRIVER to diagnostics/saved_scene.lua")))()

local function pack(...) return { n = select("#", ...), ... } end

return function(game)
  local Telemetry = require("src.vr.Telemetry")
  Telemetry.stopWindow()
  runSavedScene(game)

  local Runtime = require("src.vr.Runtime")
  local U = assert(loadfile(assert(os.getenv("GEN1_FRAME_DRIVER_UTIL"))))()
  assert(Telemetry.isEnabled(), "Set POKEPORT_VR_TELEMETRY=1 for this driver")

  for _, pair in ipairs({ { love, "update", "game_update" },
                           { love, "draw", "game_draw" } }) do
    local owner, key, stage = pair[1], pair[2], pair[3]
    local original = assert(owner[key], "missing love." .. key)
    owner[key] = function(...)
      local token = Telemetry.beginStage(stage)
      local args = pack(...)
      local result = pack(xpcall(function()
        return original(unpack(args, 1, args.n))
      end, debug.traceback))
      Telemetry.endStage(token)
      if not result[1] then error(result[2], 0) end
      return unpack(result, 2, result.n)
    end
  end

  local warmup = love.timer.getTime()
  while love.timer.getTime() - warmup < 10 do U.wait(1) end
  Telemetry.startWindow()

  local duration = tonumber(os.getenv("POKEPORT_VR_TELEMETRY_SECONDS")) or 90
  duration = math.max(10, math.min(300, duration))
  local started = love.timer.getTime()
  local firstFrame = Runtime.status().native
  print("[vr-telemetry-driver]", "measurement=started",
    "seconds=" .. tostring(duration), "scene=" .. tostring(
      game.overworld and game.overworld.map and game.overworld.map.id or "unknown"),
    "expected_submission_rate_hz=72", "resolution=runtime-recommended")
  while love.timer.getTime() - started < duration do
    U.wait(1)
  end
  local final = Runtime.status().native or {}
  local initial = type(firstFrame) == "table" and firstFrame or {}
  print("[vr-telemetry-driver]", "measurement=complete",
    "wall_seconds=" .. string.format("%.3f", love.timer.getTime() - started),
    "submitted_frames=" .. tostring((final.submitCount or 0) - (initial.submitCount or 0)),
    "final_scene=" .. tostring(game.overworld and game.overworld.map
      and game.overworld.map.id or "unknown"))

  -- The initial interval has a completion marker, but collection remains on
  -- while the player adjusts settings. POKEPORT_DRIVER must also stay alive:
  -- the pinned main loop quits when its coroutine returns.
  while true do U.wait(1) end
end
