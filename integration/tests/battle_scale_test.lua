local root=assert(arg[1])
local x,y=0,0
local q={x=0,y=0,z=0,w=1}
local function eye(offset)return {position={x=x+offset,y=y,z=0},orientation=q,positionValid=true,orientationValid=true,fov={left=-.95,right=.7,up=.8,down=-.6},width=1728,height=1728}end
local bridge={create=function()return true end,destroy=function()end,status=function()return {ready=true,focused=true,shouldRender=true}end,
 beginFrame=function()return eye(-.032),eye(.032),true end,abortFrame=function()end}
package.loadlib=function()return function()return bridge end end
local R=assert(loadfile(root..'/Runtime.lua'))();R.setEnabled(true);assert(R.start())
local function near(a,b)assert(math.abs(a-b)<1e-8,tostring(a)..' differs from '..tostring(b))end
local function views(units)
 R.abortFrame();assert(R.beginFrame(100,100))
 return R.views({mode=units and 'battle' or 'above',eye={0,10,50},focus={0,10,0},worldUnitsPerMeter=units},1)
end
for _,units in ipairs({48,24,16})do
 x,y=0,0;R.recenter();local a,b=views(units)
 near(b.eye.x-a.eye.x,.064*units);near((a.eye.x+b.eye.x)/2,0)
 local ox,oy,oz=a.baseEye.x,a.baseEye.y,a.baseEye.z
 x,y=.25,-.25;a,b=views(units)
 near(((a.eye.x+b.eye.x)/2-ox)/units,5/48)
 near(((a.eye.y+b.eye.y)/2-oy)/units,-4/48)
 near(b.eye.x-a.eye.x,.064*units)
 assert(a.fov.left==-.95 and a.fov.right==.7,'native FOV altered')
 R.recenter();a,b=views(units)
 near((a.eye.x+b.eye.x)/2,ox);near((a.eye.y+b.eye.y)/2,oy)
 -- Returning to the overworld reinstates the ordinary conversion immediately,
 -- without retaining the previous battle's scale or centre.
 a,b=views(nil);near(b.eye.x-a.eye.x,.064*48)
 x,y=0,0;R.recenter();a,b=views(units);near((a.eye.x+b.eye.x)/2,0)
end
R.shutdown()
print('BATTLE_SCALE_PASS physical IPD/FOV, metre-consistent lean clamps, recenter, enter/exit/reentry at 48/24/16 world pixels per metre')
