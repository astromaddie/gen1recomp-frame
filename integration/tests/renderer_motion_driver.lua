-- Bounded diagnostic: original gamepad callbacks, unchanged runtime head poses.
local saved=assert(loadfile(assert(os.getenv("POKEPORT_SAVED_SCENE_DRIVER"))))()
return function(game)
  local T=require("src.vr.Telemetry")
  local Runtime=require("src.vr.Runtime")
  local U=assert(loadfile(assert(os.getenv("GEN1_FRAME_DRIVER_UTIL"))))()
  assert(T.isEnabled(),"renderer motion requires opt-in telemetry")
  T.stopWindow();saved(game)
  local lib=assert(game.mods.exports.DRAMALESS_SHAPE.lib)
  local Renderer=require("src.render.Renderer")
  local Collision=require("src.world.Collision")
  local restore={}
  for _,p in ipairs({{game,"update","engine_update"},{game,"draw","engine_draw_rest"},
      {Renderer,"endFrame","engine_composite"},{Renderer,"compositeUi","engine_ui"},
      {Renderer,"drawTiltedWorld","engine_flat_world"},
      {require("src.render.Pipelines"),"update","mod_pipeline_update"},
      {lib.require("VoxelScene"),"prefetch","mod_prefetch"},
      {lib.require("ChunkMesher"),"pump","mod_mesh_pump"},
      {lib.require("TerrainAtlas"),"forMap","mod_atlas"},
      {Runtime,"compositeHud","vr_hud"}}) do
    restore[#restore+1]=T.wrapCpu(p[1],p[2],p[3])
  end
  local directions={"right","left","down","up"}
  local opposite={right="left",left="right",down="up",up="down"}
  local function releaseInputs()
    for _,dir in ipairs(directions) do game:gamepadreleased(nil,"dp"..dir) end
  end
  local originalQuit=love.quit
  local cleaned=false
  local quit
  local function cleanup()
    if cleaned then return end
    cleaned=true
    releaseInputs();T.stopWindow();T.setPhase(nil)
    for i=#restore,1,-1 do restore[i]() end
    if love.quit==quit then love.quit=originalQuit end
  end
  quit=function(...)
    cleanup()
    if originalQuit then return originalQuit(...) end
  end
  love.quit=quit
  local function snapshot()
    local world=assert(game.overworld);local p=assert(world.player);local c=assert(world.camera)
    return {map=world.map.id,x=p.px,y=p.py,cx=p.cellX,cy=p.cellY,camx=c.x,camy=c.y,
      moving=p.moving==true,facing=p.facing,progress=p.progress or 0,frame=Runtime.status().frame}
  end
  local function report(event,phase,start,previous,motion,presses)
    local s=snapshot()
    print("[renderer-motion]","event="..event,"phase="..phase,"monotonic_ns="..string.format("%.0f",T.monotonicNs() or 0),"frame="..s.frame,"map="..s.map,
      "cell="..s.cx..","..s.cy,"player="..s.x..","..s.y,"camera="..s.camx..","..s.camy,
      "facing="..tostring(s.facing),"moving="..tostring(s.moving),"progress="..s.progress,
      "wall_seconds="..string.format("%.3f",love.timer.getTime()-start),
      "player_distance="..string.format("%.3f",motion.player),"camera_distance="..string.format("%.3f",motion.camera),
      "pad_presses="..presses,"input_api=Game.gamepadpressed/released","source=pad:dp*",
      "start_cell="..previous.cx..","..previous.cy)
  end
  local function safe(dir)
    local world=game.overworld;local p=world.player;local map=world.map
    if game.stack:top()~=world or p.moving then return false end
    local x,y=Collision.target(p.cellX,p.cellY,dir)
    return Collision.canMove(map,world.entities,p,dir)
      and not map:isGrassCell(x,y) and not map:warpAtCell(x,y)
      and not map:isWarpTileCell(x,y) and not map:warpPadOrHoleAt(x,y)
  end
  local function phase(name,seconds,axis)
    releaseInputs();T.setPhase(name)
    local start=love.timer.getTime();local first=snapshot();local previous=first
    local motion={player=0,camera=0};local presses=0;local lastReport=start
    local held,pressedAt,pressedX,pressedY,nextDir=nil,nil,nil,nil,axis and axis[1]
    report("begin",name,start,first,motion,presses)
    while love.timer.getTime()-start<seconds do
      local world=game.overworld
      assert(world.map.id==first.map and game.stack:top()==world,"motion diagnostic left its overworld scene")
      local p=world.player;local now=love.timer.getTime()
      if held and (p.moving or p.cellX~=pressedX or p.cellY~=pressedY or now-pressedAt>0.5) then
        game:gamepadreleased(nil,"dp"..held);held=nil
      end
      if axis and now-start<seconds-0.5 and not held and not p.moving then
        local dir=safe(nextDir) and nextDir or (safe(opposite[nextDir]) and opposite[nextDir])
        if dir then
          game:gamepadpressed(nil,"dp"..dir)
          local sources=game.input.sources[dir]
          assert(sources and sources["pad:dp"..dir] and game.input:isDown(dir),"original D-pad source was not held")
          held,pressedAt,pressedX,pressedY,nextDir=dir,now,p.cellX,p.cellY,opposite[dir];presses=presses+1
        end
      end
      U.wait(1)
      local s=snapshot()
      motion.player=motion.player+math.sqrt((s.x-previous.x)^2+(s.y-previous.y)^2)
      motion.camera=motion.camera+math.sqrt((s.camx-previous.camx)^2+(s.camy-previous.camy)^2)
      previous=s
      if love.timer.getTime()-lastReport>=1 then report("sample",name,start,first,motion,presses);lastReport=love.timer.getTime() end
    end
    releaseInputs()
    report("end",name,start,first,motion,presses)
  end
  local ok,err=xpcall(function()
    local warm=love.timer.getTime()
    while love.timer.getTime()-warm<8 do U.wait(1) end
    T.startWindow()
    print("[renderer-motion]","measurement=started","seconds=32","resolution=runtime-recommended",
      "input_api=Game.gamepadpressed/released","source=pad:dp*","head_pose=runtime-unmodified")
    phase("stand-1",5)
    phase("walk-1",11,{"right","left"})
    phase("stand-2",5)
    phase("walk-2",11,{"down","up"})
    releaseInputs()
    for _,dir in ipairs(directions) do
      assert(not (game.input.sources[dir] or {})["pad:dp"..dir],"D-pad diagnostic source survived release")
    end
    T.sample()
    print("[renderer-motion]","measurement=complete","all_pad_sources_released=true")
  end,debug.traceback)
  cleanup()
  if not ok then error(err,0) end
  -- Keep the owned process available for the coordinator's evidence pull.
  while true do U.wait(1) end
end
