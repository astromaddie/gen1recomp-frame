-- Private game/cache/save are supplied by the host runner; no bundled art.
return function(game)
 io.stdout:setvbuf("no")
 love.errorhandler=function(e)io.stderr:write(tostring(e).."\n"..debug.traceback().."\n");return function()return 1 end end
 local U=assert(loadfile(assert(os.getenv("GEN1_FRAME_DRIVER_UTIL"))))()
 local Save=require("src.core.SaveData");Save.setActiveSlot("yellow","slot1")
 local save,recovered=Save.load("yellow");assert(save and save.player);game:restoreSave(save,recovered);U.wait(5)
 if game.stack:top()~=game.overworld then U.tap(game,"a");U.wait(10)end
 local V=game.mods.exports.DRAMALESS_SHAPE.lib
 assert(require("src.render.Pipelines").setLevel("voxel",3)==3)
 local R=require("src.vr.Runtime")
 local W=require("src.vr.DrawDistance")
 local latest,q,shift={}, {x=0,y=0,z=0,w=1},0
 local function rotate(x,y,z)
  local tx,ty,tz=2*(q.y*z-q.z*y),2*(q.z*x-q.x*z),2*(q.x*y-q.y*x)
  return x+q.w*tx+q.y*tz-q.z*ty,y+q.w*ty+q.z*tx-q.x*tz,z+q.w*tz+q.x*ty-q.y*tx
 end
 local function eye(x)
  local a,b,c=rotate(x,0,0)
  return {position={x=a+shift,y=b,z=c},orientation=q,positionValid=true,orientationValid=true,
   width=1728,height=1728,fov={left=x<0 and -.95 or -.7,right=x<0 and .7 or .95,up=.8,down=-.6}}
 end
 local native=assert(package.loadlib(os.getenv("POKEPORT_TEST_BRIDGE"),"luaopen_xrbridge"))()
 local bridge={create=function()return true end,destroy=function()end,
  beginFrame=function()return eye(-.032),eye(.032),true end,
  status=function()return {ready=true,focused=true,shouldRender=true}end,
  submitCanvases=function(a,b)latest={a,b};return true end,abortFrame=function()end,pollActions=function()return {actions={}}end,
  createVisibilitySelection=native.createVisibilitySelection,selectVisibility=native.selectVisibility}
 package.loadlib=function()return function()return bridge end end
 R.shutdown();R.setEnabled(true);assert(R.start())
 for i=1,600 do U.wait(1);if V.require("VoxelState").ready and V.require("ChunkMesher").pending()==0 then break end end
 local Battle=require("src.battle.BattleState")
 local host=game.mods.exports.DRAMALESS_SHAPE.voxel2DBattleHost
 local battle=Battle.newWild(game,"PIDGEY",3);assert(not battle.dead);game.stack:push(battle)
 for i=1,800 do
  if battle.phase=="menu" then break end
  if i%20==0 then U.tap(game,"a")else U.wait(1)end
 end
 assert(battle.phase=="menu","intro did not reach existing fight menu")
 assert(host.session and host.session.presented)
 local arena=host.session.context.arena
 local ground=V.require("VoxelScene").groundAt(arena.map,arena.playerCell[1],arena.playerCell[2])
 local authored=V.require("BattleCam").rig(arena,ground)
 local vrArena={};for k,v in pairs(arena)do vrArena[k]=v end;vrArena.cam="wide"
 local wide=V.require("BattleCam").rig(vrArena,ground)
 print("BATTLE_CAMERA", "source",unpack(authored.eye));print("BATTLE_CAMERA","VR-wide",unpack(wide.eye))
 local scene=V.require("VoxelBattleScene")
 local graphics=V.require("Voxel3D")
 local originalDrawMesh=graphics.draw
 local cardBounds={}
 local alphaBounds={}
 graphics.draw=function(mesh,texture,model,...)
  if mesh==V.require("BattleBillboard").mesh() and texture and model then
   local box=alphaBounds[texture]
   if not box then
    local data=texture:newImageData();local w,h=data:getDimensions();box={w,h,0,0,w=w,h=h}
    for y=0,h-1 do for x=0,w-1 do local _,_,_,a=data:getPixel(x,y);if a>.1 then
     box[1]=math.min(box[1],x);box[2]=math.min(box[2],y);box[3]=math.max(box[3],x+1);box[4]=math.max(box[4],y+1)
    end end end
    alphaBounds[texture]=box
   end
   local points={}
   for _,uv in ipairs({{box[1],box[2]},{box[3],box[2]},{box[3],box[4]},{box[1],box[4]}})do
    local x,y=uv[1]/box.w-.5,1-uv[2]/box.h
    local wx,wy,wz=model[1]*x+model[2]*y+model[4],model[5]*x+model[6]*y+model[8],model[9]*x+model[10]*y+model[12]
    local px,py=graphics.project(wx,wy,wz);points[#points+1]={px,py}
   end
   cardBounds[#cardBounds+1]=points
  end
  return originalDrawMesh(mesh,texture,model,...)
 end
 local original=scene.render
 local renderViews={}
 scene.render=function(state,arena,actors,camera)
  assert(camera and camera.nativeXR)
  renderViews[#renderViews+1]=camera.pose
  return original(state,arena,actors,camera)
 end
 local card=host.session.cardProvider
 local update,draw=card.update,card.drawWorld
 local updates,draws=0,0
 card.update=function(...)updates=updates+1;return update(...)end
 card.drawWorld=function(...)draws=draws+1;return draw(...)end
 local function saveEye(c,name)
  local d=c:newImageData();local f=assert(io.open(os.getenv("SHOT_DIR").."/"..name..".png","wb"));f:write(d:encode("png"):getString());f:close();return d
 end
 local oldDraw=love.draw
 local requested,done
 local function capture(label)
  requested=label;done=false
  while not done do U.wait(1)end
 end
 love.draw=function()
  if not requested then return oldDraw()end
  local label=requested;requested=nil
  renderViews={};updates,draws=0,0
  local clock,env=love.timer.getTime,os.getenv
  local t=clock();love.timer.getTime=function()return t end
  os.getenv=function(k)if k=="POKEPORT_VR_DRAW_DISTANCE" then return "off" end;return env(k)end
  oldDraw();os.getenv=env
  local baselineViews=renderViews
  local base={latest[1]:newImageData(),latest[2]:newImageData()}
  renderViews={};draws=0;cardBounds={}
  oldDraw();love.timer.getTime=clock
  assert(#renderViews==2 and draws==2 and updates==0,"eye repeats must draw cards twice without recapture/update")
  for i=1,2 do
   for _,axis in ipairs({"x","y","z"})do
    assert(math.abs(baselineViews[i].eye[axis]-renderViews[i].eye[axis])<1e-7,"comparison poses differ")
    assert(math.abs(baselineViews[i].focus[axis]-renderViews[i].focus[axis])<1e-7,"comparison orientations differ")
   end
  end
  local a,b=renderViews[1].eye,renderViews[2].eye
  local ipd=math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)
  assert(math.abs(ipd-.064*48)<1e-6,"runtime IPD")
  assert(latest[1]~=latest[2],"battle is still mono")
  assert(#cardBounds==4,"both original card pictures must be present in both eyes")
  for i,points in ipairs(cardBounds)do
   local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
   for _,p in ipairs(points)do assert(p[1] and p[2],"card behind view");x0=math.min(x0,p[1]);x1=math.max(x1,p[1]);y0=math.min(y0,p[2]);y1=math.max(y1,p[2])end
   print("BATTLE_CARD_BOUNDS",label,i,x0,y0,x1-x0,y1-y0)
  end
  local status=W.status();assert(status.active and not status.lastError,"battle must retain native visibility selection")
  local sum,max=0,0
  for i,c in ipairs(latest)do
   local d=saveEye(c,label.."-"..i)
   for y=0,1727 do for x=0,1727 do
    local r,g,b=d:getPixel(x,y);local ar,ag,ab=base[i]:getPixel(x,y)
    local e=math.abs(r-ar)+math.abs(g-ag)+math.abs(b-ab);sum=sum+e;max=math.max(max,e)
   end end
  end
  local mean=sum/(1728*1728*2*3)
  assert(mean<.0001,"culling changed visible battle geometry: "..mean)
  print("BATTLE_STEREO_PASS",label,"IPD",ipd,"passes",#renderViews,"card draws",draws,"card updates during draw",updates,"selected/source",status.selectedIndices,status.sourceIndices,"image mean/max",mean,max)
  done=true
 end
 -- Finish the existing incremental selector preparation without elapsed-time budget.
 local clock=love.timer.getTime;love.timer.getTime=function()return 0 end;U.wait(1);love.timer.getTime=clock
 capture("battle-menu")
 U.tap(game,"a");U.wait(2);assert(battle.phase=="moveSelect","original Fight A action")
 capture("battle-moves")
 U.tap(game,"b");U.wait(2);assert(battle.phase=="menu","original B cancel")
 local yaw,roll=.35,.25
 q={x=math.sin(yaw/2)*math.sin(roll/2),y=math.sin(yaw/2)*math.cos(roll/2),z=math.cos(yaw/2)*math.sin(roll/2),w=math.cos(yaw/2)*math.cos(roll/2)};shift=.08
 U.wait(1) -- main prepares XR before update; consume the old prepared pose first.
 capture("battle-tracked")
 love.draw=oldDraw;scene.render=original;graphics.draw=originalDrawMesh;card.update=update;card.drawWorld=draw
 -- End via the authoritative battle exit and verify host/pending reset.
 q={x=0,y=0,z=0,w=1};shift=0
 battle.result="run";battle:finish()
 for i=1,120 do if game.stack:top()==game.overworld then break end;U.wait(1)end
 assert(not host.session,"battle exit must clear provider session")
 assert(game.stack:top()==game.overworld,"battle exit returns to overworld")
 local ow=V.require("VoxelScene")
 local owRender=ow.render;local returnedViews={}
 ow.render=function(...)
  returnedViews[#returnedViews+1]=V.require("Voxel3D").camera
  return owRender(...)
 end
 U.wait(1);ow.render=owRender
 assert(#returnedViews==2,"overworld stereo must resume after battle exit")
 local a,b=returnedViews[1].eye,returnedViews[2].eye
 local dx,dy,dz=a[1]-b[1],a[2]-b[2],a[3]-b[3]
 assert(math.abs(math.sqrt(dx*dx+dy*dy+dz*dz)-.064*48)<1e-6)
 -- A repeated battle must create a new session and use its own arena anchor.
 local second=Battle.newWild(game,"RATTATA",3);game.stack:push(second);U.wait(1)
 assert(host.session and host.session.battle==second and host.session.presented)
 second.result="run";second:finish()
 for i=1,120 do if game.stack:top()==game.overworld then break end;U.wait(1)end
 assert(not host.session)
 print("BATTLE_INTERACTION_PASS intro->fight->moves->B->menu; authoritative finish->overworld; tracking yaw/roll/translation")
end
