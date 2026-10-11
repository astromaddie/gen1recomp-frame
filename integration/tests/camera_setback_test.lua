local root,mod=assert(arg[1]),assert(arg[2])
local mode="above"
-- Exercise the current renderer's camera path, including the VR adapter.
-- CameraMode belonged to the replaced renderer and is no longer shipped.
local modules={ModSetting={new=function(_,_,values)
  return {get=function()return values[1]end}
end},VoxelScene={groundAt=function()return 0 end}}
local V={}
function V.require(name)
  if not modules[name] then modules[name]=assert(loadfile(mod.."/lib/"..name..".lua"))(V) end
  return modules[name]
end
local Mat4=V.require("Mat4")
local Voxel=assert(loadfile(mod.."/lib/Voxel3D.lua"))({require=function(name)
  if name=="Mat4" then return Mat4 end; return {}
end})
modules.Voxel3D=Voxel
local voxel,fp=V.require("VoxelState"),V.require("FirstPerson")
package.loaded["src.vr.Runtime"]={}
local Stereo=assert(loadfile(root.."/DramalessStereo.lua"))()
local Camera={view=function(state,w,h)
  voxel.level=mode=="pov" and voxel.FP_LEVEL or mode=="third" and voxel.TP_LEVEL or voxel.FULL_LEVEL
  voxel.angle=math.rad(35)
  fp.blend=mode=="above" and 0 or 1
  local camera=Stereo.baseCamera(V,{state=state,vw=w,vh=h,width=w,height=h})
  -- The renderer uses arrays; Runtime accepts arrays and named vectors.
  for _,key in ipairs({"eye","focus","up"})do
    local v=camera[key];camera[key]={x=v[1],y=v[2],z=v[3]}
  end
  return camera
end}
local q={x=0,y=0,z=0,w=1}
local function eye(x)return {position={x=x,y=0,z=0},orientation=q,
  fov={left=-0.8,right=0.8,up=0.8,down=-0.8}}end
local bridge={create=function()return true end,destroy=function()end,
  status=function()return {ready=true,focused=true}end,
  beginFrame=function()return eye(-0.032),eye(0.032),true end,
  abortFrame=function()end}
package.loadlib=function()return function()return bridge end end
local realGetenv=os.getenv
local function runtime(value)
  os.getenv=function(name)
    if name=="POKEPORT_VR_CAMERA_SETBACK_METERS" then return value end
    return realGetenv(name)
  end
  local R=assert(loadfile(root.."/Runtime.lua"))()
  os.getenv=realGetenv
  R.setEnabled(true);assert(R.start());assert(R.beginFrame(800,600));return R
end
local function near(a,b,label)assert(math.abs(a-b)<1e-7,label)end
local state={camera={x=50,y=50},player={cellX=5,cellY=6,py=96,facing="down",pose=function()return nil,80,96 end}}
for _,m in ipairs({"above","third","pov"})do
  mode=m
  local base=assert(Camera.view(state,160,144,0))
  local original={x=base.eye.x,y=base.eye.y,z=base.eye.z}
  local zero=runtime("0")
  local zl,zr=zero.views(base,1)
  local farther=runtime("0.75")
  local l,r=farther.views(base,1)
  local dx,dy,dz=base.focus.x-base.eye.x,base.focus.y-base.eye.y,base.focus.z-base.eye.z
  local len=math.sqrt(dx*dx+dy*dy+dz*dz)
  local units=m=="pov" and 0 or 36
  for _,axis in ipairs({"x","y","z"})do
    local direction=({x=dx,y=dy,z=dz})[axis]/len
    near(l.eye[axis]-zl.eye[axis],-direction*units,m.." eye setback")
    near(l.focus[axis]-zl.focus[axis],-direction*units,m.." focus setback")
    near(base.eye[axis],original[axis],"must not mutate game's camera")
  end
  local function separation(a,b)return math.sqrt((a.eye.x-b.eye.x)^2+(a.eye.y-b.eye.y)^2+(a.eye.z-b.eye.z)^2)end
  near(separation(l,r),0.064*48,"setback must preserve physical IPD and world scale")
  Voxel.camera=l
  local matrix=Voxel.viewProjection(0,0,160,144)
  for _,v in ipairs(matrix)do assert(v==v and math.abs(v)<1e8,"finite actual Voxel3D matrix")end
  zero.shutdown();farther.shutdown()
end
-- The default remains the original camera. The diagnostic launch can request
-- the previously accepted 0.75m distance explicitly.
mode="third"
local base=Camera.view(state,160,144,0)
do
  local R=runtime(nil);local l,r=R.views(base,1)
  local center={x=(l.eye.x+r.eye.x)/2,y=(l.eye.y+r.eye.y)/2,z=(l.eye.z+r.eye.z)/2}
  local distance=math.sqrt((center.x-base.eye.x)^2+(center.y-base.eye.y)^2+(center.z-base.eye.z)^2)
  near(distance,0,"absent configuration must preserve the original camera distance")
  R.shutdown()
end
for _,value in ipairs({"bad","nan","-1","100"})do
  local R=runtime(value);local l,r=R.views(base,1)
  local center={x=(l.eye.x+r.eye.x)/2,y=(l.eye.y+r.eye.y)/2,z=(l.eye.z+r.eye.z)/2}
  local distance=math.sqrt((center.x-base.eye.x)^2+(center.y-base.eye.y)^2+(center.z-base.eye.z)^2)
  near(distance,value=="100" and 144 or 0,"bounded setback")
  R.shutdown()
end
print("CAMERA_SETBACK_PASS: pinned FirstPerson/DramalessStereo/Voxel3D, default0, explicit0.75m, POV unchanged,48px/m/IPD, bounded invalid config")
