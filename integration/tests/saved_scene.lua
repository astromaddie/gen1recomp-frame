return function(game)
  local U = assert(loadfile(assert(os.getenv("GEN1_FRAME_DRIVER_UTIL"), "Set GEN1_FRAME_DRIVER_UTIL")))()
  local SaveData = require("src.core.SaveData")
  local raw = assert(love.filesystem.read("saves/yellow/slot1.lua"))
  local checked = assert(SaveData.decode(raw))
  assert(checked.player, "Copied Yellow save has no player")
  assert(SaveData.setActiveSlot("yellow", "slot1") == "slot1")
  assert(SaveData.activeSlot("yellow") == "slot1", "Expected isolated Yellow slot1")
  local save, recovered = SaveData.load("yellow")
  assert(save and save.player, "Yellow save did not load")
  game:restoreSave(save, recovered)
  U.wait(5)
  local ow = game.overworld
  assert(ow and ow.map and not ow.transitioning)
  assert(ow.map.id == save.player.map and ow.player.cellX == save.player.x
      and ow.player.cellY == save.player.y, "Restored location differs from save")
  U.log("loaded-slot", SaveData.activeSlot("yellow"), "saved",
        save.player.map, save.player.x, save.player.y, "world",
        ow.map.id, ow.player.cellX, ow.player.cellY)
  if game.stack:top() ~= ow then
    U.tap(game, "a")
    U.wait(10)
  end
  assert(game.stack:top() == ow, "Load report did not return to overworld")
  local mod = game.mods and game.mods.exports and game.mods.exports.DRAMATIC_SHAPE
  assert(mod and mod.lib, "Dramatic Shape missing")
  local V = mod.lib
  local Camera = V.require("CameraMode")
  local Voxel = V.require("VoxelState")
  local Voxel3D = V.require("Voxel3D")
  local Pipelines = require("src.render.Pipelines")
  Camera.setting:sync("above")
  assert(Voxel3D.available())
  assert(Pipelines.setLevel("voxel", 3) == 3)
  for _ = 1, 600 do
    U.wait(1)
    if Pipelines.worldPipeline() == "voxel" and Voxel.active() and Voxel.ready then break end
  end
  assert(Pipelines.worldPipeline() == "voxel" and Voxel.active() and Voxel.ready)
  U.log("voxel-scene", ow.map.id, Camera.mode(), "ready", Voxel.ready)
  assert(U.shot(game, (os.getenv("SHOT_DIR") or "/tmp") .. "/yellow-slot1-voxel.png"))
  U.wait(120) -- Leave time for a delayed one-shot native eye capture.
end
