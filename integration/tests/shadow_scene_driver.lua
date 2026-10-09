-- Requires a private assembled game and player-local Yellow cache/save.
-- The runtime and pinned VoxelScene/ChunkMesher remain the production paths.
return function(game)
  io.stdout:setvbuf("no")
  love.errorhandler=function(message)io.stderr:write(tostring(message).."\n"..debug.traceback().."\n");return function()return 1 end end
  local U=assert(loadfile(assert(os.getenv("GEN1_FRAME_DRIVER_UTIL"))))()
  local Save=require("src.core.SaveData")
  Save.setActiveSlot("yellow","slot1")
  local save,recovered=Save.load("yellow");assert(save and save.player)
  game:restoreSave(save,recovered);U.wait(5)
  if game.stack:top()~=game.overworld then U.tap(game,"a");U.wait(10) end
  if os.getenv("QA_MAP") then U.teleport(game,os.getenv("QA_MAP"),tonumber(os.getenv("QA_X")) or 3,tonumber(os.getenv("QA_Y")) or 4) end
  local lib=assert(game.mods.exports.DRAMALESS_SHAPE.lib)
  local Voxel=lib.require("VoxelState")
  local Mesher=lib.require("ChunkMesher")
  local Runtime=require("src.vr.Runtime")
  local Window=require("src.vr.DrawDistance")
  local baselinePath=os.getenv("POKEPORT_TEST_CULL_BASELINE")
  local unculledReference=os.getenv("POKEPORT_TEST_CULL_UNCULLED")=="1"
  local implementations
  if baselinePath then
    implementations={assert(loadfile(baselinePath))(),
      assert(loadfile(assert(os.getenv("POKEPORT_TEST_CULL_CANDIDATE"))))()}
  end
  local threadTime,selectionCpu
  local function selectCuller(index)
    Window.finish()
    for k,v in pairs(implementations[index]) do Window[k]=v end
    local begin,finish=Window.begin,Window.finish
    local restoreSelection
    Window.finish=function(...)
      if restoreSelection then restoreSelection();restoreSelection=nil end
      return finish(...)
    end
    Window.begin=function(...)
      if restoreSelection then restoreSelection();restoreSelection=nil end
      begin(...)
      -- Time the real private selector, excluding software rasterization.
      -- This QA-only wrapper neither replaces its algorithm nor its result.
      local draw=lib.require("Voxel3D").draw
      for i=1,20 do
        local name,value=debug.getupvalue(draw,i)
        if not name then break end
        if name=="selection" then
          debug.setupvalue(draw,i,function(...)
            local start=threadTime();local selected=value(...)
            selectionCpu=selectionCpu+threadTime()-start
            return selected
          end)
          restoreSelection=function()debug.setupvalue(draw,i,value)end
          break
        end
      end
    end
  end
  local ffi=require("ffi")
  ffi.cdef("int clock_gettime(int, void*);")
  local timespec=ffi.new("int64_t[2]")
  threadTime=function()
    assert(ffi.C.clock_gettime(3,timespec)==0)
    return tonumber(timespec[0])+tonumber(timespec[1])*1e-9
  end
  local level=tonumber(os.getenv("QA_LEVEL")) or 3
  assert(require("src.render.Pipelines").setLevel("voxel",level)==level)
  for i=1,600 do U.wait(1);if Voxel.ready and Mesher.pending()==0 then break end end
  assert(Voxel.ready)
  -- The fake native boundary owns no graphics: all eye targets, shaders,
  -- world geometry, water, shadows and composition are the actual game.
  local stamp=0
  local q={x=0,y=0,z=0,w=1};local shift=0
  local function rotate(x,y,z)
    local tx,ty,tz=2*(q.y*z-q.z*y),2*(q.z*x-q.x*z),2*(q.x*y-q.y*x)
    return x+q.w*tx+q.y*tz-q.z*ty,y+q.w*ty+q.z*tx-q.x*tz,z+q.w*tz+q.x*ty-q.y*tx
  end
  local function eye(x)
    local px,py,pz=rotate(x,0,0)
    return {position={x=px+shift,y=py,z=pz},orientation=q,
      fov={left=x<0 and -0.95 or -0.7,right=x<0 and 0.7 or 0.95,up=0.8,down=-0.6},width=1728,height=1728,
      positionValid=true,orientationValid=true}
  end
  local native=assert(package.loadlib(assert(os.getenv("POKEPORT_TEST_BRIDGE")),"luaopen_xrbridge"))()
  local latest
  local bridge={create=function()return true end,destroy=function()end,
    beginFrame=function()stamp=stamp+13888889;return eye(-0.032),eye(0.032),true end,
    status=function()return {ready=true,focused=true,shouldRender=true,predictedDisplayTime=stamp,predictedDisplayPeriod=13888889}end,
    submitCanvases=function(a,b)latest={a,b};return true end,abortFrame=function()end,
    pollActions=function()return {actions={}}end}
  bridge.restoreShadowCanvas=native.restoreShadowCanvas
  package.loadlib=function()return function()return bridge end end
  Runtime.shutdown();Runtime.setEnabled(true);assert(Runtime.start())
  U.wait(3)
  -- Finish budgeted one-time index analysis before comparison; this QA-only
  -- clock freeze changes preparation scheduling, never selected geometry.
  local realClock=love.timer.getTime
  love.timer.getTime=function()return 0 end
  U.wait(1)
  love.timer.getTime=realClock
  local yaw=math.rad(tonumber(os.getenv("QA_YAW")) or 0)/2
  local pitch=math.rad(tonumber(os.getenv("QA_PITCH")) or 0)/2
  local roll=math.rad(tonumber(os.getenv("QA_ROLL")) or 0)/2
  q={x=math.cos(yaw)*math.sin(pitch)*math.cos(roll)+math.sin(yaw)*math.cos(pitch)*math.sin(roll),
    y=math.sin(yaw)*math.cos(pitch)*math.cos(roll)-math.cos(yaw)*math.sin(pitch)*math.sin(roll),
    z=math.cos(yaw)*math.cos(pitch)*math.sin(roll)-math.sin(yaw)*math.sin(pitch)*math.cos(roll),
    w=math.cos(yaw)*math.cos(pitch)*math.cos(roll)+math.sin(yaw)*math.sin(pitch)*math.sin(roll)}
  shift=tonumber(os.getenv("QA_SHIFT")) or 0
  if os.getenv("QA_CURVE") then lib.require("WorldCurve").setting:sync(tonumber(os.getenv("QA_CURVE"))) end
  local mode,cullerMode="on","frustum"
  local getenv=os.getenv
  os.getenv=function(name)
    if name=="POKEPORT_VR_SHADOW_OPTIMIZATION" then return mode end
    if implementations and name=="POKEPORT_VR_DRAW_DISTANCE" then return cullerMode end
    return getenv(name)
  end
  local Optimization=require("src.vr.ShadowOptimization")
  local function snapshot(label)
    local result={}
    love.graphics.setCanvas()
    for i,c in ipairs(assert(latest)) do
      assert(c:getWidth()==1728 and c:getHeight()==1728)
      result[i]=c:newImageData()
      local f=assert(io.open(assert(getenv("SHOT_DIR")).."/"..label.."-"..i..".png","wb"))
      f:write(result[i]:encode("png"):getString());f:close()
    end
    return result
  end
  local counts={}
  local shadow=lib.require("ShadowMap")
  local originalBegin=shadow.begin
  shadow.begin=function(...)
    local ok=originalBegin(...);if ok then counts.rebuilds=(counts.rebuilds or 0)+1 end;return ok
  end
  local draw=shadow.draw
  shadow.draw=function(mesh,...)
    if mesh and not implementations then local map=mesh:getVertexMap();counts.triangles=(counts.triangles or 0)+(map and #map or mesh:getVertexCount())/3 end
    return draw(mesh,...)
  end
  local waterBegin=lib.require("Voxel3D").beginWater
  lib.require("Voxel3D").beginWater=function(...) counts.reflections=(counts.reflections or 0)+1;return waterBegin(...) end
  local originalDraw=love.draw
  local completed=false
  love.draw=function()
    if completed then return originalDraw() end
    completed=true
    local captureTime=realClock()
    local realDelta=love.timer.getDelta
    local day=lib.require("DayNight")
    local realHours=day.hours;local fixedHours=realHours()
    day.hours=function()return fixedHours end
    love.timer.getTime=function()return captureTime end
    love.timer.getDelta=function()return 0 end
    -- Glass glints have their own draw-driven easing; hold the already-built
    -- scene value so camera-fit comparisons differ only in the shadow path.
    local Scene=lib.require("VoxelScene");local glint=Scene.glintStep
    Scene.glintStep=function(g)return g end
    local function pair(label,cold)
      if cold then Optimization.release() end
      Runtime.beginFrame(1728,1728)
      if implementations then selectCuller(1) end
      cullerMode=unculledReference and "off" or "frustum"
      mode=implementations and "on" or "off";shadow.discard();counts={}
      selectionCpu=0
      local started=threadTime();originalDraw();local beforeCpu=(threadTime()-started)*1000
      local beforeSelection=selectionCpu*1000
      local beforeCuller=Window.status()
      local a=snapshot(label.."-original");local before=counts
      if implementations then selectCuller(2) end
      cullerMode="frustum"
      mode="on";shadow.discard();counts={};started=threadTime();selectionCpu=0;originalDraw()
      local afterCpu=(threadTime()-started)*1000
      local afterCuller=Window.status()
      local b=snapshot(label.."-optimized");local after=counts
      local status=Optimization.status()
      assert(status.fallbacks==0,status.lastFallback)
      local maxError,totalError,changed=0,0,0
      for eye=1,2 do for y=0,1727 do for x=0,1727 do
        local r,g,bb=a[eye]:getPixel(x,y);local rr,gg,bbb=b[eye]:getPixel(x,y)
        local dr,dg,db=math.abs(r-rr),math.abs(g-gg),math.abs(bb-bbb)
        maxError=math.max(maxError,dr,dg,db);totalError=totalError+dr+dg+db
        if dr+dg+db>0 then changed=changed+1 end
      end end end
      print("SHADOW_COMPARE",label,"resolution",shadow.res,"original_triangles",before.triangles or 0,
        "optimized_triangles",after.triangles or 0,"rebuilds",before.rebuilds or 0,after.rebuilds or 0,
        "reflections",before.reflections or 0,after.reflections or 0,
        "terrain_builds",status.terrainBuilds,"terrain_hits",status.terrainHits,"terrain_triangles",status.terrainTriangles,
        "dynamic_triangles",status.dynamicTriangles,"source_terrain",status.sourceTerrainTriangles,
        "source_dynamic",status.sourceDynamicTriangles,"restores",status.restores,
        "max_channel_error",maxError,"mean_channel_error",totalError/(2*1728*1728*3),"different_pixels",changed)
      assert(changed==0,"complete stereo image differs: "..label)
      if implementations then
        assert(beforeCuller.pendingDraws==0 and afterCuller.pendingDraws==0,"head-motion comparison includes unprepared meshes")
        if not unculledReference then assert(beforeCuller.selectedIndices==afterCuller.selectedIndices and beforeCuller.indexUpdates==afterCuller.indexUpdates) end
        print(unculledReference and "UNCULLED_HEAD_COMPARE" or "HEAD_MOTION_COMPARE",label,"baseline_main_cpu_ms",beforeCpu,"candidate_main_cpu_ms",afterCpu,
          "baseline_selection_ms",beforeSelection,"candidate_selection_ms",selectionCpu*1000,
          "index_updates",afterCuller.indexUpdates,"selected_indices",afterCuller.selectedIndices,"different_pixels",changed)
      end
      for _,images in ipairs({a,b}) do for _,im in ipairs(images) do im:release() end end
    end
    if implementations then
      -- Finish both implementations' budgeted preparation under the same
      -- frozen update, then traverse changing tracked poses continuously.
      selectionCpu=0
      for i=1,2 do selectCuller(i);originalDraw();originalDraw() end
      local sweep=unculledReference and {-45,0,45} or {-45,-30,-15,0,15,30,45,30,15,0,-15,-30,-45}
      for step,degrees in ipairs(sweep) do
        local y=math.rad(degrees)/2
        q={x=math.cos(y)*math.sin(pitch)*math.cos(roll)+math.sin(y)*math.cos(pitch)*math.sin(roll),
          y=math.sin(y)*math.cos(pitch)*math.cos(roll)-math.cos(y)*math.sin(pitch)*math.sin(roll),
          z=math.cos(y)*math.cos(pitch)*math.sin(roll)-math.sin(y)*math.sin(pitch)*math.cos(roll),
          w=math.cos(y)*math.cos(pitch)*math.cos(roll)+math.sin(y)*math.sin(pitch)*math.sin(roll)}
        pair("head-"..step.."-yaw"..degrees)
      end
    else
    pair("cold",true);pair("warm")
    local function changed(label,requiresTerrain)
      counts={};originalDraw()
      local status=Optimization.status()
      assert((counts.rebuilds or 0)>0,"scene signature did not invalidate: "..label)
      if requiresTerrain then assert(status.terrainBuilds>0,"terrain fit/light signature did not invalidate: "..label) end
      print("SHADOW_INVALIDATION",label,"terrain_builds",status.terrainBuilds,"terrain_hits",status.terrainHits)
      pair(label)
    end
    local player=game.overworld.player
    local oldPx=player.px;player.px=oldPx+3
    changed("player-move",level==6)
    player.px=oldPx
    -- Exercise original entity pose/frame selection on an actual NPC.
    local npc
    for _,e in ipairs(game.overworld.entities) do if e~=player and e.pose then npc=e;break end end
    if npc then
      local px,moving,progress=npc.px,npc.moving,npc.progress
      npc.px=npc.px+2;npc.moving=true;npc.progress=6
      changed("npc-walk")
      npc.px,npc.moving,npc.progress=px,moving,progress
    end
    -- Animate atlas pointers using the actual TileRenderer clock, while
    -- keeping game simulation and the captured timestamp fixed.
    originalDraw() -- settle restored NPC pose before isolating atlas animation
    local tiles=require("src.render.TileRenderer")
    local beforeAtlas=Scene.warmAtlas(game.overworld.map)
    local animated=false
    for i=1,24 do
      tiles.tick(0.25)
      if Scene.warmAtlas(game.overworld.map)~=beforeAtlas then animated=true;break end
    end
    if animated then changed("flower-water-animation",true)
    else print("SHADOW_ANIMATION_UNAVAILABLE",game.overworld.map.id,"no animated atlas in this tileset") end
    if game.overworld.map.id=="PEWTER_CITY" then
      fixedHours=(fixedHours+6)%24;changed("sunlight",true)
      if level==6 then
        local savedQ=q;q={x=0,y=math.sin(math.pi/8),z=0,w=math.cos(math.pi/8)}
        -- Tracked attitude changes the eye views, while the original fitted
        -- shadow center follows FirstPerson.yaw. Verify both dependencies.
        pair("tracked-head-turn");q=savedQ
        local firstPerson=lib.require("FirstPerson")
        local savedYaw,savedPitch=firstPerson.yaw,firstPerson.pitch
        firstPerson.lookBy(math.pi/4,0)
        changed("pov-look-fit",true)
        firstPerson.yaw,firstPerson.pitch=savedYaw,savedPitch
      else
        local camera=game.overworld.camera
        local x=camera.x;camera.x=x+17;changed("camera-fit",true);camera.x=x
      end
    end
    end
    Scene.glintStep=glint
    love.timer.getTime=realClock;love.timer.getDelta=realDelta;day.hours=realHours;os.getenv=getenv
    print(implementations and "HEAD_MOTION_SCENE_PASS" or "SHADOW_SCENE_PASS",game.overworld.map.id,"1728x1728 full stereo, same-update comparisons")
  end
  while not completed do U.wait(1)end
  U.wait(1)
end
