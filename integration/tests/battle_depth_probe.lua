-- Host QA only. Read the actual scene depth attachment and original opaque
-- HUD footprint. No production readbacks or alternate scene geometry.
return function(graphics,Runtime)
 local P={enabled=false}
 local endScene,composite=graphics.endScene,Runtime.compositeHud
 local shader=love.graphics.newShader([[
 uniform float clipNear; uniform float clipFar; uniform float units;
 vec4 effect(vec4 c, Image t, vec2 uv,vec2 px) {
  float z=Texel(t,uv).r;
  float depth=(2.0*clipNear*clipFar)/(clipFar+clipNear-(2.0*z-1.0)*(clipFar-clipNear));
  return vec4(vec3(depth/units),1.0);
 }
 ]])
 local function v(p,i,k)return p[k] or p[i]end
 local function rotate(q,x,y,z)
  local tx,ty,tz=2*(q.y*z-q.z*y),2*(q.z*x-q.x*z),2*(q.x*y-q.y*x)
  return x+q.w*tx+q.y*tz-q.z*ty,y+q.w*ty+q.z*tx-q.x*tz,z+q.w*tz+q.x*ty-q.y*tx
 end
 graphics.endScene=function(...)
  if not P.enabled then return endScene(...)end
  local held
  for i=1,20 do local name,value=debug.getupvalue(graphics.depthReadable,i);if not name then break end;if name=='held' then held=value end end
  assert(held and held.depth,'host must expose original readable scene depth')
  local cam=graphics.camera;local a,b=cam.eye,cam.focus
  local ex,ey,ez=v(a,1,'x'),v(a,2,'y'),v(a,3,'z')
  local dx,dy,dz=v(b,1,'x')-ex,v(b,2,'y')-ey,v(b,3,'z')-ez
  local dist=math.sqrt(dx*dx+dy*dy+dz*dz)
  local n,f=math.max(1,dist*.05),dist*4+4096
  local units=cam.worldUnitsPerMeter or 48
  local result=endScene(...)
  local w,h=held.depth:getDimensions();local c=love.graphics.newCanvas(w,h,{format='rgba32f'})
  love.graphics.push('all');love.graphics.setCanvas(c);love.graphics.origin();love.graphics.setColor(1,1,1,1)
  love.graphics.setBlendMode('replace');love.graphics.setShader(shader)
  shader:send('clipNear',n);shader:send('clipFar',f);shader:send('units',units)
  love.graphics.draw(held.depth);love.graphics.pop()
  local data=c:newImageData();c:release();P.depths[#P.depths+1]=data
  -- Independent ray/known-plane calibration against thousands of visible
  -- authored floor points, not a second copy of the depth inversion formula.
  local fx,fy,fz=dx/dist,dy/dist,dz/dist
  local up=cam.up or {0,1,0};local ux,uy,uz=v(up,1,'x'),v(up,2,'y'),v(up,3,'z')
  local rx,ry,rz=fy*uz-fz*uy,fz*ux-fx*uz,fx*uy-fy*ux
  local length=math.sqrt(rx*rx+ry*ry+rz*rz);rx,ry,rz=rx/length,ry/length,rz/length
  ux,uy,uz=ry*fz-rz*fy,rz*fx-rx*fz,rx*fy-ry*fx
  local fov=cam.fov;local l,r,d,u=math.tan(fov.left),math.tan(fov.right),math.tan(fov.down),math.tan(fov.up)
  local hits,maxError=0,0
  for y=math.floor(h*.6),h-1,17 do for x=0,w-1,17 do
   local rayY=fy+ry*(l+(x+.5)/w*(r-l))+uy*(u-(y+.5)/h*(u-d))
   if rayY<0 then
    local expected=(P.ground-ey)/rayY/units;local actual=data:getPixel(x,y)
    if math.abs(expected-actual)<.001 then hits=hits+1;maxError=math.max(maxError,math.abs(expected-actual))end
   end
  end end
  assert(hits>100,'calibrate depth against visible authored ground')
  print('DEPTH_CALIBRATION',n,f,'world px/m',units,'floor matches',hits,'max error m',maxError)
  return result
 end
 Runtime.compositeHud=function(source,target,eye,distance)
  if P.enabled then
   local w,h=target:getDimensions();local mask=love.graphics.newCanvas(w,h)
   love.graphics.push('all');love.graphics.setCanvas(mask);love.graphics.clear(0,0,0,0);love.graphics.pop()
   composite(source,mask,eye,distance)
   local im=mask:newImageData();mask:release()
   local data=assert(P.depths[eye]);local dw,dh=data:getDimensions()
   local views=Runtime.frameViews();local view=views[eye]
   local plane=require('src.vr.MonoPanel').placement(views,true,distance)
   local nx,ny,nz=plane.rz*plane.uy,-plane.rz*plane.ux+plane.rx*plane.uz,-plane.rx*plane.uy
   local p=view.position
   local numerator=(plane.x-p.x)*nx+(plane.y-p.y)*ny+(plane.z-p.z)*nz
   local f=view.fov;local l,r,u,d=math.tan(f.left),math.tan(f.right),math.tan(f.up),math.tan(f.down)
   local closest,gap,count=math.huge,math.huge,0
   for y=0,h-1 do for x=0,w-1 do
    local _,_,_,alpha=im:getPixel(x,y)
    if alpha>.9 then
     local rx,ry,rz=rotate(view.orientation,l+(x+.5)/w*(r-l),u-(y+.5)/h*(u-d),-1)
     local hudDepth=numerator/(rx*nx+ry*ny+rz*nz)
     local sceneDepth=data:getPixel(math.floor(x*dw/w),math.floor(y*dh/h))
     closest=math.min(closest,sceneDepth);gap=math.min(gap,sceneDepth-hudDepth);count=count+1
    end
   end end
   assert(count>100,'missing original opaque battle HUD')
   print('HUD_DEPTH_ORDER',P.label,eye,'HUD m',distance,'nearest scene m',closest,'minimum signed gap m',gap,'opaque pixels',count)
   assert(gap>0,'original opaque HUD is behind scene geometry: '..gap)
   P.eyes=P.eyes+1;im:release()
  end
  return composite(source,target,eye,distance)
 end
 function P.begin(label,ground)P.enabled=true;P.depths={};P.eyes=0;P.label=label;P.ground=ground end
 function P.finish()
  P.enabled=false;assert(P.eyes==2 and #P.depths==2,'measure exactly two actual eye passes')
  for _,data in ipairs(P.depths)do data:release()end;P.depths={}
 end
 function P.close()graphics.endScene=endScene;Runtime.compositeHud=composite;shader:release()end
 return P
end
