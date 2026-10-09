-- Original native host adapter for the pinned public DRAMALESS renderer.
-- Game/update and the upstream controls run once. Only the world draw repeats.
local Runtime = require("src.vr.Runtime")
local Stereo = {}
local pending
local function vector(v) return {v.x or v[1],v.y or v[2],v.z or v[3]} end
function Stereo.mode(V)
  local voxel=V.require("VoxelState")
  return voxel.isFirstPerson() and "pov" or voxel.isThirdPerson() and "third" or "above"
end
function Stereo.active(ctx)
  return Runtime.isEnabled() and Runtime.isBridgeActive() and Runtime.shouldRender()
    and ctx.state == require("src.core.Game").overworld
end
function Stereo.beginFrame() pending=nil end
function Stereo.baseCamera(V,ctx)
  local voxel,fp,graphics=V.require("VoxelState"),V.require("FirstPerson"),V.require("Voxel3D")
  local cx,cy=ctx.state.camera.x+ctx.vw/2,ctx.state.camera.y+ctx.vh/2
  local player=ctx.state.player
  local me
  if player and not ctx.state.flyAnim then
    local _,px,py=player:pose()
    me={px=px,py=player.py,lift=player.py-py,
      gh=V.require("VoxelScene").groundAt(ctx.state.map,player.cellX,player.cellY)}
  end
  local previous=graphics.camera
  local camera=fp.frame(me,cx,cy,ctx.vw,ctx.vh)
  graphics.camera=previous
  if not camera then
    local a,d=voxel.angle,voxel.FOCAL*ctx.vh
    camera={eye={cx,d*math.cos(a),cy+d*math.sin(a)},focus={cx,0,cy},
      up={0,math.sin(a),-math.cos(a)},fov=2*math.atan(1/(2*voxel.FOCAL))}
  end
  local copy={}
  for key,value in pairs(camera) do copy[key]=value end
  copy.mode,copy.aspect=Stereo.mode(V),ctx.width/ctx.height
  return copy
end
local function eyePass(V,ctx,view,slot,w,h)
  local graphics,fp=V.require("Voxel3D"),V.require("FirstPerson")
  local camera={}
  for key,value in pairs(view) do camera[key]=value end
  camera.eye,camera.focus,camera.up=vector(view.eye),vector(view.focus),vector(view.up)
  local oldCamera,oldBegin=graphics.camera,graphics.beginScene
  graphics.camera=camera
  fp.adoptTrackedEye(camera)
  graphics.beginScene=function(a,b,c,d,e,f,g) return oldBegin(a,b,c,d,e,f,g,slot) end
  local aa=V.require("AntiAlias")
  local rw,rh=aa.expand(w,h)
  local ok,result=xpcall(function()
    local canvas=V.require("VoxelScene").render(ctx.state,rw,rh,ctx.vw,ctx.vh,ctx.paletteFor)
    if not canvas then return nil end
    if graphics.beginOverlay() then
      ctx.drawFx(function(x,y) return graphics.project(x,0,y) end,ctx.scale*aa.factor())
      graphics.endOverlay()
    end
    local resolved=aa.resolve(canvas,w,h,slot)
    local telemetry=package.loaded["src.vr.Telemetry"]
    if telemetry and telemetry.isEnabled() then
      telemetry.recordSourceEye(slot=="native-xr-left" and 1 or 2,canvas,resolved,aa.samples(),aa.factor())
    end
    return resolved
  end,debug.traceback)
  graphics.beginScene,graphics.camera=oldBegin,oldCamera
  fp.adoptTrackedEye(nil)
  if not ok then
    pcall(V.require("ShadowMap").cancel);pcall(graphics.endScene)
    error(result,0)
  end
  return result
end
function Stereo.drawWorld(V,ctx)
  pending=nil
  local base=Stereo.baseCamera(V,ctx)
  local left,right=Runtime.views(base,base.aspect)
  if not (left and right) then return nil end
  local w=math.max(left.width or ctx.width,right.width or ctx.width)
  local h=math.max(left.height or ctx.height,right.height or ctx.height)
  local scene=V.require("VoxelScene")
  local step=scene.glintStep
  local glint
  scene.glintStep=function(...)
    if not glint then glint=step(...) end
    return glint
  end
  local shadows=require("src.vr.ShadowOptimization")
  shadows.begin(V)
  local ok,a,b=xpcall(function()
    local a=eyePass(V,ctx,left,"native-xr-left",w,h)
    local b=eyePass(V,ctx,right,"native-xr-right",w,h)
    return a,b
  end,debug.traceback)
  shadows.finish()
  if ok then require("src.vr.Telemetry").recordShadows(shadows.status()) end
  scene.glintStep=step
  if not ok then error(a,0) end
  if not (a and b) then return V.require("VoxelLoadingVeil").get(ctx.width,ctx.height) end
  pending={a,b}
  return a
end
function Stereo.finish()
  local pair=pending;pending=nil
  if not pair then return false end
  local renderer=require("src.render.Renderer")
  renderer:compositeUi(pair[1]);renderer:compositeUi(pair[2])
  Runtime.queue(pair[1],pair[2])
  return true,pair[1]
end
return Stereo
