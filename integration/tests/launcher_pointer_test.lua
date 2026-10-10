local root=assert(arg[1])
local Panel=assert(loadfile(root.."/MonoPanel.lua"))()
package.loaded["src.vr.MonoPanel"]=Panel
local Pointer=assert(loadfile(root.."/LauncherPointer.lua"))()
local function near(a,b)assert(math.abs(a-b)<1e-6,tostring(a).." != "..tostring(b))end
local function rotate(q,x,y,z)
 local tx,ty,tz=2*(q.y*z-q.z*y),2*(q.z*x-q.x*z),2*(q.x*y-q.y*x)
 return x+q.w*tx+q.y*tz-q.z*ty,y+q.w*ty+q.z*tx-q.x*tz,z+q.w*tz+q.x*ty-q.y*tx
end
local views,aim
for _,yaw in ipairs({0,0.7,math.pi})do
 for _,roll in ipairs({0,0.5,-0.8})do
  local q={x=math.sin(yaw/2)*math.sin(roll/2),y=math.sin(yaw/2)*math.cos(roll/2),z=math.cos(yaw/2)*math.sin(roll/2),w=math.cos(yaw/2)*math.cos(roll/2)}
  views={}
  for i,x in ipairs({-.032,.032})do
   local px,py,pz=rotate(q,x,0,0)
   views[i]={position={x=px,y=py,z=pz},orientation=q,width=1200,height=1000,
    fov={left=i==1 and -.95 or -.7,right=i==1 and .7 or .95,up=.8,down=-.6}}
  end
  for _,size in ipairs({{800,600},{600,1000}})do
   Panel.reset()
   local a,w,h=Panel.geometry(views,unpack(size))
   for _,uv in ipairs({{.5,.5},{0,0},{1,0},{1,1},{0,1}})do
    local x=(uv[1]-.5)*w;local y=(.5-uv[2])*h
    aim={valid=true,position={x=a.rx*x,y=y,z=a.rz*x},orientation={x=0,y=math.sin(yaw/2),z=0,w=math.cos(yaw/2)},trigger=0}
    local hit=assert(Panel.hit(views,size[1],size[2],aim));assert(hit.inside)
    near(hit.x,size[1]*uv[1]);near(hit.y,size[2]*uv[2])
    for _,v in ipairs(views)do
     local px,py=Panel.project(v,hit.point)
     local verts=Panel.vertices(v,a,w,h)
     if uv[1]~=.5 then
      local idx=uv[2]==0 and (uv[1]==0 and 1 or 2) or (uv[1]==1 and 3 or 4)
      near(px,(verts[idx][1]/verts[idx][4]+1)*v.width/2)
      near(py,(verts[idx][2]/verts[idx][4]+1)*v.height/2)
     end
    end
   end
  end
 end
end
Panel.reset();views={}
for i,x in ipairs({-.032,.032})do views[i]={position={x=x,y=0,z=0},orientation={x=0,y=0,z=0,w=1}}end
local function hand(x,trigger,valid)return {valid=valid~=false,position={x=x,y=0,z=0},orientation={x=0,y=0,z=0,w=1},trigger=trigger or 0}end
local clicks=0
local importer={mousepressed=function(self,x,y,b)clicks=clicks+1;near(x,400);near(y,300);assert(b==1)end}
local function update(l,r)Pointer.update(importer,{hands={left=l,right=r}},views,800,600)end
update(nil,hand(0,1));assert(clicks==0,"held at entry")
update(nil,hand(0,0));update(nil,hand(0,.6));update(nil,hand(0,.9));assert(clicks==1)
update(nil,hand(0,.5));update(nil,hand(0,.65));assert(clicks==1,"hysteresis")
update(nil,hand(0,.45));update(nil,hand(0,.6));assert(clicks==2)
update(nil,hand(0,0,false));update(nil,hand(0,1));assert(clicks==2,"tracking recovery held")
Pointer.reset();update(hand(0,0));update(hand(0,1));assert(clicks==3,"left fallback")
update(hand(0,0),hand(2,0));update(hand(0,1),hand(2,1));assert(clicks==3,"right preferred and off panel")
Pointer.update(importer,{},nil,800,600);update(nil,hand(0,1));assert(clicks==3,"focus recovery held")
local behind=hand(0);behind.position.z=-3;assert(not Panel.hit(views,800,600,behind))
local away=hand(0);away.orientation={x=0,y=1,z=0,w=0};assert(not Panel.hit(views,800,600,away))
print("pointer math/routing: yaw/roll, asymmetric FOV, wide/tall edges, both hands, invalid/focus, off/behind, trigger hysteresis passed")
