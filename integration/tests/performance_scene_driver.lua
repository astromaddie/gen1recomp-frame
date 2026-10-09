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
  local latest
  local bridge={create=function()return true end,destroy=function()end,
    beginFrame=function()stamp=stamp+13888889;return eye(-0.032),eye(0.032),true end,
    status=function()return {ready=true,focused=true,shouldRender=true,predictedDisplayTime=stamp,predictedDisplayPeriod=13888889}end,
    submitCanvases=function(a,b)latest={a,b};return true end,abortFrame=function()end,
    pollActions=function()return {actions={}}end}
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
  local mode="frustum"
  local Scene=lib.require("VoxelScene")
  local shadowCache=lib.require("ShadowMap")
  local available=shadowCache.available
  shadowCache.available=function(...)
    -- Reproduce the old availability bug's compulsory redraws while keeping
    -- its exact fitter/shader/caster path; target churn is tested separately.
    if mode=="off" and shadowCache.res>shadowCache.SIZES[1] then shadowCache.discard() end
    return available(...)
  end
  local originalWater=Scene.drawWater
  local originalBegin=Window.begin
  Window.begin=function(...)
    originalBegin(...)
    if mode=="off" then Scene.drawWater=originalWater end
  end
  local getenv=os.getenv
  os.getenv=function(name)return getenv(name)end
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
  local regions={}
  local scene=lib.require("VoxelScene")
  local oldRender=scene.render
  scene.render=function(state,w,h,vw,vh,...)
    local result=oldRender(state,w,h,vw,vh,...)
    local camera=state.camera;local points={}
    for _,p in ipairs({{camera.x,camera.y},{camera.x+vw,camera.y},{camera.x+vw,camera.y+vh},{camera.x,camera.y+vh}})do
      local x,y=lib.require("Voxel3D").project(p[1],0,p[2])
      if not (x and y) then points={};break end
      points[#points+1]={x,y}
    end
    regions[#regions+1]=points
    return result
  end
  local function inside(poly,x,y)
    if #poly<3 then return false end
    local sign
    for i,p in ipairs(poly)do
      local q=poly[i%#poly+1];local c=(q[1]-p[1])*(y-p[2])-(q[2]-p[2])*(x-p[1])
      if math.abs(c)>1e-6 then local value=c>0;if sign~=nil and sign~=value then return false end;sign=value end
    end
    return true
  end
  local counts={}
  local waterBegin=lib.require("Voxel3D").beginWater
  lib.require("Voxel3D").beginWater=function(...) counts.reflections=(counts.reflections or 0)+1;return waterBegin(...) end
  for _,module in ipairs({"Voxel3D","Water","ShadowMap"})do
    local object=lib.require(module);local original=object.draw
    object.draw=function(mesh,...)
      if mesh then
        local map=mesh:getVertexMap()
        counts[module]=(counts[module] or 0)+(map and #map or mesh:getVertexCount())/3
      end
      return original(mesh,...)
    end
  end
  local shadow=lib.require("ShadowMap")
  local shadowBegin=shadow.begin
  shadow.begin=function(...)
    local ok=shadowBegin(...)
    if ok then counts.shadowRebuilds=(counts.shadowRebuilds or 0)+1 end
    return ok
  end
  local originalDraw=love.draw
  local completed=false
  love.draw=function()
    if completed then return originalDraw() end
    completed=true
    -- Same game update, pose, world rectangle and original full-resolution
    -- eye pass on both sides. No second simulation tick between captures.
    local captureTime=realClock()
    local realDelta=love.timer.getDelta
    local day=lib.require("DayNight")
    local realHours=day.hours;local fixedHours=realHours()
    day.hours=function()return fixedHours end
    love.timer.getTime=function()return captureTime end
    -- TileRenderer.tick is deliberately draw-driven for dialogue animation.
    -- The off/off control proved two draws advance flowers without this.
    love.timer.getDelta=function()return 0 end
    Runtime.beginFrame(1728,1728) -- current test pose, no simulation tick
    mode="off";counts={};regions={};originalDraw()
    local baseline=snapshot("baseline");local baseCounts=counts;local region=regions
    assert(#regions==2,"baseline must render exactly two actual stereo scenes")
    mode=getenv("QA_CONTROL") and "off" or "frustum";counts={};originalDraw()
    local bounded=snapshot("bounded");local boundedCounts=counts
    assert(#regions==4,"bounded must render exactly two actual stereo scenes")

    local status=Window.status()
    assert(not status.lastError,status.lastError)
    assert(status.pendingDraws==0,"all visible registered meshes must be prepared")


    if not getenv("QA_CONTROL") then assert(status.active and status.mode=="frustum") end

    print("SHADOW_RESOLUTION",shadow.res)
    print("SHADOW_REBUILDS",baseCounts.shadowRebuilds or 0,boundedCounts.shadowRebuilds or 0)
    print("REFLECTION_PASSES",baseCounts.reflections or 0,boundedCounts.reflections or 0)
    for module,n in pairs(baseCounts)do print("FRUSTUM_TRIANGLES",module,n,boundedCounts[module] or 0)end
    print("FRUSTUM_COUNTS",status.sourceIndices/3,status.selectedIndices/3,"waterPassesSkipped",status.waterPassesSkipped,
      "stereo-frustum")
    local changed,centerChanged,regionChanged,regionCount=0,0,0,0
    local maxError,totalError,exactChanged=0,0,0
    for i=1,2 do
      for y=0,1727 do for x=0,1727 do
        local inRegion=inside(region[i],x+0.5,y+0.5)
        if inRegion then regionCount=regionCount+1 end
        local r,g,b=baseline[i]:getPixel(x,y);local rr,gg,bb=bounded[i]:getPixel(x,y)
        local dr,dg,db=math.abs(r-rr),math.abs(g-gg),math.abs(b-bb)
        maxError=math.max(maxError,dr,dg,db);totalError=totalError+dr+dg+db
        if dr+dg+db>0 then exactChanged=exactChanged+1 end
        if dr+dg+db>0.02 then
          changed=changed+1
          if inRegion then regionChanged=regionChanged+1 end
          if x>=704 and x<1024 and y>=704 and y<1024 then centerChanged=centerChanged+1 end
        end
      end end
    end
    print("FRUSTUM_PIXELS",changed,centerChanged,"projected_ground_viewport",regionChanged,regionCount)
    print("FRUSTUM_ERROR", "max_channel",maxError,"mean_channel",totalError/(2*1728*1728*3),"pixels_nonzero",exactChanged)
    assert(regionChanged==0,"original scrolling viewport differs")
    assert(changed==0,"full eye image differs after frustum culling")
    print("PERFORMANCE_SCENE_PASS",game.overworld.map.id,"1728x1728 actual scene/mesher, one stereo pair each, same-update A/B", "yaw", math.deg(yaw)*2,"roll",math.deg(roll)*2,"shift",shift,"curve",os.getenv("QA_CURVE"))
    -- Exercise actual VoxelScene actor/light signatures, not synthetic stamps.
    local player=game.overworld.player
    local oldPx=player.px
    player.px=oldPx+1;counts={};originalDraw()
    assert((counts.shadowRebuilds or 0)>=1,"moving an actor must invalidate actual scene shadows")
    player.px=oldPx;counts={};originalDraw()
    assert((counts.shadowRebuilds or 0)>=1,"restoring actor position must invalidate shadows")
    if game.overworld.map.id=="PEWTER_CITY" then
      day.hours=function()return (fixedHours+6)%24 end
      counts={};originalDraw()
      assert((counts.shadowRebuilds or 0)>=1,"changing sunlight must invalidate actual scene shadows")
    end
    print("SCENE_SHADOW_INVALIDATION_PASS",game.overworld.map.id)
    love.timer.getTime=realClock;love.timer.getDelta=realDelta;day.hours=realHours
    os.getenv=getenv
  end
  while not completed do U.wait(1)end
  U.wait(1)
end
