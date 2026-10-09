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
  local scopes,scopeScenes={},{}
  local bridge={create=function()return true end,destroy=function()end,
    beginFrame=function()stamp=stamp+13888889;return eye(-0.032),eye(0.032),true end,
    status=function()return {ready=true,focused=true,shouldRender=true,predictedDisplayTime=stamp,predictedDisplayPeriod=13888889}end,
    submitCanvases=function(a,b)latest={a,b};return true end,abortFrame=function()end,
    gpuScopeBegin=function(name,frame,scene) scopes[#scopes+1]=name;scopeScenes[#scopeScenes+1]=scene;return true end,
    gpuScopeEnd=function()return true end,
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

  local Scene=lib.require("VoxelScene")
  local Graphics=lib.require("Voxel3D")
  local originalRender,originalGlint=Scene.render,Scene.glintStep
  local renders,glints,views=0,0,{}
  Scene.glintStep=function(...)glints=glints+1;return originalGlint(...)end
  Scene.render=function(...)
    renders=renders+1
    local result=originalRender(...)
    assert(result,"real DRAMALESS scene did not render")
    views[#views+1]=Graphics.camera
    return result
  end
  local Quality=lib.require("Quality")
  assert(Quality.scale()==1,"fresh native RES must be FULL")
  assert(Quality.renderDistanceSetting:get()==-1,"fresh R.DIST must be FULL")
  local Menu=require("src.ui.OptionsMenu")
  local menu=Menu.new(game)
  local distance
  for _,row in ipairs(menu.rows)do if row.id=="DRAMALESS_SHAPE:renderDistanceSetting" then distance=row end end
  assert(distance and distance.value()=="FULL","existing options R.DIST row unreachable")
  distance.step(game,1);assert(distance.value()=="MEDIUM" and Quality.renderDistance()==64)
  distance.step(game,-1);assert(distance.value()=="FULL" and Quality.renderDistance()==256)
  print("DRAMALESS_SETTINGS_PASS RES=FULL R.DIST=FULL->MEDIUM->FULL existing menu API")
  local Stereo=require("src.vr.DramalessStereo")
  local oldBase,lastBase=Stereo.baseCamera
  Stereo.baseCamera=function(...)lastBase=oldBase(...);return lastBase end
  local originalDraw=love.draw
  local done=false
  local captureLabel="eye"
  love.draw=function()
    if done then return originalDraw()end
    done=true;renders,glints,scopes,scopeScenes,views=0,0,{},{},{}
    local player=game.overworld.player
    player.surfing=true
    local bob=player.bobTimer or 0
    originalDraw()
    player.surfing=false
    assert(renders==2,"must execute exactly two production VoxelScene passes")
    assert(glints==1,"glint advanced twice")
    assert(player.bobTimer==(bob+1)%32,"player draw animation advanced twice")
    assert(#scopes==2 and scopes[1]=="source_scene_eye1" and scopes[2]=="source_scene_eye2","source GPU scopes missing")
    assert(scopeScenes[1]:find("/rdist=-1/res=1",1,true) and scopeScenes[2]==scopeScenes[1],"source GPU scene missing settings")
    assert(views[1]~=views[2] and views[1].fov.left~=views[2].fov.left)
    local a,b=views[1].eye,views[2].eye
    local ipd=math.sqrt((a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2)
    assert(math.abs(ipd-0.064*48)<1e-6,"tracked IPD changed")
    local base=lastBase
    local ex,ey,ez=base.eye[1],base.eye[2],base.eye[3]
    local dx,dy,dz=base.focus[1]-ex,base.focus[2]-ey,base.focus[3]-ez
    local length=math.sqrt(dx*dx+dy*dy+dz*dz)
    local offset=base.mode=="pov" and 0 or 36
    for i,d in ipairs({dx,dy,dz})do
      assert(math.abs((a[i]+b[i])/2-base.eye[i]+d/length*offset)<1e-6,"accepted camera setback changed")
    end
    print("DRAMALESS_CAMERA_PASS",base.mode,"setback_worldpx",offset)
    love.graphics.setCanvas()
    for i,c in ipairs(assert(latest)) do
      assert(c:getWidth()==1728 and c:getHeight()==1728)
      local data=c:newImageData()
      local f=assert(io.open(assert(os.getenv("SHOT_DIR")).."/"..captureLabel.."-"..i..".png","wb"))
      f:write(data:encode("png"):getString());f:close()
    end
    local status=Window.status()
    assert(status.active and not status.lastError,"frustum culling missing or failed")
    print("DRAMALESS_STEREO_PASS",game.overworld.map.id,"1728x1728",renders,"real passes",glints,"glint steps",ipd,"IPD world pixels",#scopes,"source GPU scopes",status.mode)
  end
  while not done do U.wait(1)end
  U.wait(1)
  if os.getenv("QA_MODES") then
    for _,entry in ipairs({{6,"pov"},{7,"third"}})do
      assert(require("src.render.Pipelines").setLevel("voxel",entry[1])==entry[1])
      U.wait(40)
      captureLabel=entry[2];done=false
      while not done do U.wait(1)end
      U.wait(1)
    end
  end
  if os.getenv("QA_UI") then
    love.draw=originalDraw
    local function capture(label)
      U.wait(2)
      love.graphics.setCanvas()
      for i,c in ipairs(latest) do
        local data=c:newImageData()
        local f=assert(io.open(os.getenv("SHOT_DIR").."/"..label.."-"..i..".png","wb"))
        f:write(data:encode("png"):getString());f:close()
      end
    end
    for i,row in ipairs(menu.rows) do
      if row.id=="DRAMALESS_SHAPE:renderDistanceSetting" then menu.index=i end
    end
    game.stack:push(menu)
    U.wait(2)
    capture("options")
    assert(game.stack:top()==menu)
    U.tap(game,"b");U.wait(2)
    assert(game.stack:top()==game.overworld,"existing options cancel did not return")
    print("DRAMALESS_OPTIONS_INTERACTION_PASS")
    local Battle=require("src.battle.BattleState")
    local battle=Battle.newWild(game,"PIDGEY",3)
    assert(not battle.dead)
    game.stack:push(battle)
    U.wait(40)
    capture("battle")
    local host=game.mods.exports.DRAMALESS_SHAPE.voxel2DBattleHost
    assert(host.session and host.session.presented,"native DRAMALESS battle host did not present")
    print("DRAMALESS_BATTLE_PRESENTATION_PASS",battle.phase)
  end
end
