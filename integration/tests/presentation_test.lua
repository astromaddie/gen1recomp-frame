local root = assert(arg[1], "pass integration/src/vr")
local Runtime
local yaw, gameForward = 0, -1
local views
local modRoot = assert(arg[2], "pass pinned voxel-mod root for its production matrix path")
local Mat4 = assert(loadfile(modRoot .. "/lib/Mat4.lua"))()
local Voxel3D = assert(loadfile(modRoot .. "/lib/Voxel3D.lua"))({
  require=function(name) if name=="Mat4" then return Mat4 end; return {} end,
})
local function qrotate(q, x, y, z)
  local tx, ty, tz = 2*(q.y*z-q.z*y), 2*(q.z*x-q.x*z), 2*(q.x*y-q.y*x)
  return { x=x+q.w*tx+q.y*tz-q.z*ty,
    y=y+q.w*ty+q.z*tx-q.x*tz, z=z+q.w*tz+q.x*ty-q.y*tx }
end
local function near(a, b, label)
  assert(math.abs(a-b) < 1e-7, label .. ": " .. a .. " vs " .. b)
end
local bridge = { create=function() return true end, destroy=function() end,
  status=function() return {ready=true, focused=true} end,
  abortFrame=function() end }
function bridge.beginFrame() return views[1], views[2], true end
package.loadlib = function() return function() return bridge end end
Runtime = assert(loadfile(root .. "/Runtime.lua"))()
Runtime.setEnabled(true)
assert(Runtime.start())
for _, angle in ipairs({0, 90, 180}) do
  for _, forward in ipairs({-1, 1}) do
    yaw, gameForward = math.rad(angle), forward
    local q = {x=0, y=math.sin(yaw/2), z=0, w=math.cos(yaw/2)}
    views = {}
    for i, x in ipairs({-0.032, 0.032}) do
      views[i] = {position=qrotate(q,x,0,0), orientation=q,
        fov={left=-0.9,right=0.7,up=0.8,down=-0.65},width=320,height=320}
    end
    Runtime.recenter()
    assert(Runtime.beginFrame(800,600))
    local l,r = Runtime.views({eye={x=0,y=10,z=0},
      focus={x=0,y=10,z=forward},right={x=1,y=0,z=0},fov=math.pi/2},1)
    near(l.eye.x, 0.032*48*forward, "left eye in camera basis at yaw"..angle)
    near(r.eye.x, -0.032*48*forward, "right eye in camera basis")
    near(l.eye.z, 0, "IPD must not turn into depth after recenter")
    near(l.focus.x-l.eye.x, 0, "parallel eye forward; no toe-in")
    near(r.focus.x-r.eye.x, 0, "parallel eye forward; no toe-in")
    Runtime.abortFrame()
    for _, rollDegrees in ipairs({-45,30,90}) do
      local roll=math.rad(rollDegrees)
      local s,c=math.sin(roll/2),math.cos(roll/2)
      local rolled={x=q.y*s,y=q.y*c,z=q.w*s,w=q.w*c}
      for i,x in ipairs({-0.032,0.032}) do
        views[i].orientation=rolled
        views[i].position=qrotate(rolled,x,0,0)
      end
      assert(Runtime.beginFrame(800,600))
      local eye=Runtime.views({eye={x=0,y=10,z=0},
        focus={x=0,y=10,z=forward},right={x=1,y=0,z=0},fov=math.pi/2},1)
      near(eye.up.x,forward*math.sin(roll),"tracked roll right/up in game basis")
      near(eye.up.y,math.cos(roll),"tracked roll vertical")
      assert(eye.orientationDelta==nil,"must bypass reference renderer's roll-stripping branch")
      Voxel3D.camera=eye
      local actual=Voxel3D.viewProjection(0,0,160,144)
      local pos={eye.eye.x,eye.eye.y,eye.eye.z}
      local focus={eye.focus.x,eye.focus.y,eye.focus.z}
      local expected=Mat4.mul(Mat4.scale(1,-1,1),Mat4.mul(
        Mat4.perspectiveOffAxis(-0.9,0.7,0.8,-0.65,1,4100),
        Mat4.lookAt(pos,focus,{forward*math.sin(roll),math.cos(roll),0})))
      for j=1,16 do near(actual[j],expected[j],"production Voxel3D full-roll matrix") end
      Runtime.abortFrame()
    end
    for i,x in ipairs({-0.032,0.032}) do
      views[i].orientation=q
      views[i].position=qrotate(q,1+x,0,0)
    end
    assert(Runtime.beginFrame(800,600))
    local ll,rr=Runtime.views({eye={x=0,y=10,z=0},
      focus={x=0,y=10,z=forward},right={x=1,y=0,z=0},fov=math.pi/2},1)
    near(math.abs(rr.eye.x-ll.eye.x),0.064*48,"lean clamp must preserve runtime IPD")
    near((ll.eye.x+rr.eye.x)/2,-forward*5,"lean clamp still constrains the head centre")
    Runtime.abortFrame()
  end
end
Runtime.shutdown()

local Panel = assert(loadfile(root .. "/MonoPanel.lua"))()
local placement = {x=0,y=0,z=-2,rx=1,rz=0}
for i, x in ipairs({-0.032,0.032}) do
  local view = {position={x=x,y=0,z=0},orientation={x=0,y=0,z=0,w=1},
    fov={left=i==1 and -0.95 or -0.7,right=i==1 and 0.7 or 0.95,
      up=0.8,down=-0.6}}
  local vertices = Panel.vertices(view,placement,1.9,1.425)
  for corner, v in ipairs(vertices) do
    local f=view.fov
    -- Invert the actual eye's projection back to the physical screen. Both
    -- asymmetric eyes must land on the SAME rectangle, including IPD.
    local rayX=((v[1]/v[4])*(math.tan(f.right)-math.tan(f.left))
      + math.tan(f.right)+math.tan(f.left))/2
    local rayY=(-(v[2]/v[4])*(math.tan(f.up)-math.tan(f.down))
      + math.tan(f.up)+math.tan(f.down))/2
    near(x+rayX*2, (v[5]-0.5)*1.9, "shared binocular horizontal position")
    near(rayY*2,(0.5-v[6])*1.425,"upright shared binocular vertical position")
    assert(math.abs(v[1]/v[4])<1 and math.abs(v[2]/v[4])<1,
      "panel must have visible margins")
  end
end
print("PRESENTATION_TEST_PASS: yaw0/90/180 eye basis, parallel cameras, actual Voxel3D full-roll matrix, asymmetric FOV/IPD panel correspondence, upright aspect")
