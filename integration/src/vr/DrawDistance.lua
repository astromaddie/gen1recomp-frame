-- Conservative stereo-frustum selection for immutable pinned map meshes.
-- No distance/viewport cutoff: every chunk visible to EITHER eye is retained.
-- Actors remain untouched. Shadow selection uses the light's own clip volume.
-- Selected meshes share the
-- original vertex buffers and preserve the original triangle order.
local Culling = {}
local ffi = require("ffi")
local cache, hooks, tick, frusta = {}, {}, 0, nil
local graphics, metrics
local profile,profileRestores
local nativePlanes,nativeLightPlanes
local CELL, MARGIN = 32, 8
local function clock() return love.timer.getTime() end
local function prepare(record)
  local mesh=record.source
  local count=mesh:getVertexCount()
  local indices=mesh:getVertexMap()
  local n=indices and #indices or count
  assert(n%6==0,"expected pinned quad triangle stream")
  record.total=n
  -- Pack once during budgeted preparation. View changes copy contiguous
  -- original ranges instead of converting millions of Lua indices again.
  record.packed=love.data.newByteData(n*4)
  local packed=ffi.cast("uint32_t*",record.packed:getFFIPointer())
  record.packedPointer=packed
  local byCell,groups,ranges={},{},{}
  for first=1,n,6 do
    local x0,y0,z0,x1,y1,z1=math.huge,math.huge,math.huge,-math.huge,-math.huge,-math.huge
    for j=first,first+5 do
      packed[j-1]=(indices and indices[j] or j)-1
      local x,y,z=mesh:getVertexAttribute(indices and indices[j] or j,1)
      x0=math.min(x0,x);y0=math.min(y0,y);z0=math.min(z0,z)
      x1=math.max(x1,x);y1=math.max(y1,y);z1=math.max(z1,z)
    end
    local key=math.floor((x0+x1)/(2*CELL))..":"..math.floor((z0+z1)/(2*CELL))
    local g=byCell[key]
    if not g then
      g={x0=x0,y0=y0,z0=z0,x1=x1,y1=y1,z1=z1};byCell[key]=g;groups[#groups+1]=g
    else
      g.x0=math.min(g.x0,x0);g.y0=math.min(g.y0,y0);g.z0=math.min(g.z0,z0)
      g.x1=math.max(g.x1,x1);g.y1=math.max(g.y1,y1);g.z1=math.max(g.z1,z1)
    end
    -- Coalesce adjacent quads without reordering transparent surfaces.
    local previous=ranges[#ranges]
    if previous and previous[3]==g then previous[2]=first+5 else ranges[#ranges+1]={first,first+5,g} end
    if first%1536==1 then coroutine.yield() end
  end
  record.ranges,record.groups=ranges,groups
  local Runtime=require("src.vr.Runtime")
  local kernel=Runtime.visibilityKernel and Runtime.visibilityKernel()
  if kernel and not record.visibilityOnly then
    local bounds=love.data.newByteData(#groups*48)
    local values=ffi.cast("double*",bounds:getFFIPointer())
    for i,g in ipairs(groups) do
      g.nativeIndex=i-1;local j=(i-1)*6
      values[j],values[j+1],values[j+2]=g.x0,g.y0,g.z0
      values[j+3],values[j+4],values[j+5]=g.x1,g.y1,g.z1
    end
    local packedRanges=love.data.newByteData(#ranges*12)
    local values=ffi.cast("uint32_t*",packedRanges:getFFIPointer())
    for i,r in ipairs(ranges) do
      local j=(i-1)*3;values[j],values[j+1],values[j+2]=r[1]-1,r[2]-r[1]+1,r[3].nativeIndex
    end
    local ok,value=pcall(kernel.createVisibilitySelection,bounds,packedRanges,record.packed)
    bounds:release();packedRanges:release()
    if ok and value then record.native=value;record.kernel=kernel end
  end
  if not record.visibilityOnly then
    local selected=love.graphics.newMesh({{"CullingUnused","byte",4}},count,"triangles","dynamic")
    record.selected=selected
    selected:setAttributeEnabled("CullingUnused",false)
    for _,attribute in ipairs(mesh:getVertexFormat()) do selected:attachAttribute(attribute[1],mesh) end
  end
  record.ready=true
end
local function releaseNative(record)
  if record.native and record.kernel.releaseVisibilitySelection then
    pcall(record.kernel.releaseVisibilitySelection,record.native)
  end
  record.native=nil;record.kernel=nil
end
local function release(record)
  releaseNative(record)
  if record.selected then record.selected:release() end
  if record.shadowSelected then record.shadowSelected:release() end
  if record.packed then record.packed:release() end
  if record.scratch then record.scratch:release() end
end
local function uploadSelection(record,selected,field,n,nativeReady)
  if not nativeReady then
  local copyScope=profile and profile.beginCpuScope("vr_range_copy")
  if not record.scratch then record.scratch=love.data.newByteData(record.total*4) end
  local out=ffi.cast("uint32_t*",record.scratch:getFFIPointer())
  local index=0
  for _,r in ipairs(record.ranges) do if r[3][field] then
    local count=r[2]-r[1]+1
    ffi.copy(out+index,record.packedPointer+r[1]-1,count*4)
    index=index+count
  end end
  if profile then profile.endCpuScope(copyScope) end
  end
  -- LOVE copies this prefix synchronously; one CPU scratch buffer can serve
  -- the independent terrain and shadow GPU index buffers without aliasing.
  local uploadScope=profile and profile.beginCpuScope("vr_index_upload")
  selected:setVertexMap(record.scratch,"uint32",n)
  if profile then profile.endCpuScope(uploadScope) end
end
-- All masks, count scans and ordered memcpy ranges stay in one native call.
-- A rejected capability/input drops back to the original independent Lua masks.
local function nativeSelection(record,planes,shadow,ox,oy,oz,pull)
  if not record.native or not planes then return nil end
  if not record.scratch then record.scratch=love.data.newByteData(record.total*4) end
  local scope=profile and profile.beginCpuScope(shadow and "vr_native_light_gather" or "vr_native_eye_gather")
  metrics.nativeCalls=(metrics.nativeCalls or 0)+1
  local ok,n,changed=pcall(record.kernel.selectVisibility,record.native,record.scratch,planes,shadow,
    ox or 0,oy or 0,oz or 0,pull or 0,graphics.curveK or 0,graphics.curveX or 0,graphics.curveZ or 0)
  if profile then profile.endCpuScope(scope) end
  if ok and type(n)=="number" then return n,changed end
  releaseNative(record)
  metrics.nativeFallbacks=(metrics.nativeFallbacks or 0)+1
  return nil
end
local function packedPlanes(planes,previous)
  local n=#planes*4
  local data=previous or love.data.newByteData(n*8)
  local out=ffi.cast("double*",data:getFFIPointer())
  for i,p in ipairs(planes) do for j=1,4 do out[(i-1)*4+j-1]=p[j] end end
  return data
end
local function register(mesh,visibilityOnly)
  if not mesh then return end
  local record=cache[mesh]
  if not record then
    record={source=mesh,visibilityOnly=visibilityOnly};record.worker=coroutine.create(function()prepare(record)end);cache[mesh]=record
  end
  record.seen=tick
end
local function planes(camera,Mat)
  local function vec(v)return {v.x or v[1],v.y or v[2],v.z or v[3]}end
  local eye,focus,up=vec(camera.eye),vec(camera.focus),vec(camera.up or {0,1,0})
  local dist=math.max(1,math.sqrt((eye[1]-focus[1])^2+(eye[2]-focus[2])^2+(eye[3]-focus[3])^2))
  local f=camera.fov
  if type(f)~="table" then return nil end
  local projection=Mat.perspectiveOffAxis(f.left,f.right,f.up,f.down,math.max(1,dist*0.05),dist*4+4096)
  local vp=Mat.mul(Mat.mul(Mat.scale(1,-1,1),projection),Mat.lookAt(eye,focus,up))
  local result={}
  -- Side planes only: depth pulls and near/far clipping remain the shader's
  -- responsibility. A 4% angular margin adds conservatism at lens edges.
  for _,axis in ipairs({1,2}) do for _,sign in ipairs({-1,1}) do
    local p={}
    for j=1,4 do p[j]=vp[12+j]*1.04+sign*vp[(axis-1)*4+j] end
    result[#result+1]=p
  end end
  return result
end
local function visible(g,ox,oy,oz,pull)
  local x0,x1,z0,z1=g.x0+ox-MARGIN,g.x1+ox+MARGIN,g.z0+oz-MARGIN,g.z1+oz+MARGIN
  local y0,y1=g.y0+oy-MARGIN,g.y1+oy+MARGIN
  -- Bound the actual quadratic WorldCurve vertex displacement across the
  -- entire chunk, including interior extrema, rather than only its corners.
  local k,cx,cz=graphics.curveK or 0,graphics.curveX or 0,graphics.curveZ or 0
  if k>0 then
    local farX=math.max(math.abs(x0-cx),math.abs(x1-cx))
    local farZ=math.max(math.abs(z0-cz),math.abs(z1-cz))
    local nearX=math.max(x0-cx,0,cx-x1)
    local nearZ=math.max(z0-cz,0,cz-z1)
    y0=y0-k*(farX*farX+farZ*farZ)
    y1=y1-k*(nearX*nearX+nearZ*nearZ)
  end
  -- The shader can pull grass/flowers through the eye when very close.
  -- Bounding its displacement also covers that case instead of assuming
  -- it always preserves screen-space position.
  x0,x1,y0,y1,z0,z1=x0-pull,x1+pull,y0-pull,y1+pull,z0-pull,z1+pull
  for _,eye in ipairs(frusta) do
    local outside=false
    for _,p in ipairs(eye) do
      -- AABB support point maximizes the signed plane distance. Reject only
      -- when ALL geometry lies outside this eye on at least one side plane.
      local d=p[1]*(p[1]>=0 and x1 or x0)+p[2]*(p[2]>=0 and y1 or y0)
        +p[3]*(p[3]>=0 and z1 or z0)+p[4]
      if d<0 then outside=true;break end
    end
    if not outside then return true end
  end
  return false
end
-- Reflection setup copies the entire eye and paints actors even if its water
-- will be clipped completely. Keep the original water meshes whenever any
-- part can reach either eye; fail open until immutable bounds are ready.
local function waterVisible(mesh,model)
  local record=cache[mesh]
  if not record or not record.ready or not frusta or not graphics.camera
    or graphics.camera.__frameCullingTick~=tick then return true end
  if model and (model[1]~=1 or model[6]~=1 or model[11]~=1 or model[2]~=0
    or model[3]~=0 or model[5]~=0 or model[7]~=0 or model[9]~=0 or model[10]~=0) then return true end
  local ox,oy,oz=model and model[4] or 0,model and model[8] or 0,model and model[12] or 0
  for _,g in ipairs(record.groups) do if visible(g,ox,oy,oz,0) then return true end end
  return false
end
local function selection(mesh,model,pull)
  pull=type(pull)=="number" and math.abs(pull) or 0
  local record=cache[mesh]
  if not record or record.visibilityOnly or not frusta or not graphics.camera
     or graphics.camera.__frameCullingTick~=tick then return mesh end
  metrics.active=true
  metrics.sourceIndices=metrics.sourceIndices+(record.total or 0)
  if not record.ready then
    metrics.pendingDraws=metrics.pendingDraws+1
    metrics.selectedIndices=metrics.selectedIndices+(record.total or 0);return mesh
  end
  if model and (model[1]~=1 or model[6]~=1 or model[11]~=1 or model[2]~=0
    or model[3]~=0 or model[5]~=0 or model[7]~=0 or model[9]~=0 or model[10]~=0) then
    metrics.selectedIndices=metrics.selectedIndices+record.total;return mesh
  end
  local ox,oy,oz=model and model[4] or 0,model and model[8] or 0,model and model[12] or 0
  -- The pair uses one selection. Preparation advances only before views are
  -- rendered; no second-eye transition from full fallback to culled geometry.
  local key=tick..":"..ox..":"..oy..":"..oz..":"..pull
  if record.frameKey~=key then
    record.frameKey=key
    local nativeCount,nativeChanged=nativeSelection(record,nativePlanes,false,ox,oy,oz,pull)
    if nativeCount then
      record.count=nativeCount
      if nativeChanged and nativeCount>0 and nativeCount<record.total then
        uploadSelection(record,record.selected,"keep",nativeCount,true)
        metrics.indexUpdates=metrics.indexUpdates+1
      end
    else
    local scope=profile and profile.beginCpuScope("vr_eye_visibility")
    local changed=false
    for _,g in ipairs(record.groups) do
      local keep=visible(g,ox,oy,oz,pull)
      if keep~=g.keep then changed=true;g.keep=keep end
    end
    if profile then profile.endCpuScope(scope) end
    if changed then
      scope=profile and profile.beginCpuScope("vr_range_count")
      local n=0
      for _,r in ipairs(record.ranges) do if r[3].keep then n=n+r[2]-r[1]+1 end end
      record.count=n
      if profile then profile.endCpuScope(scope) end
      if n>0 and n<record.total then
        uploadSelection(record,record.selected,"keep",n)
        metrics.indexUpdates=metrics.indexUpdates+1
      end
    end
  end
    end
  metrics.selectedIndices=metrics.selectedIndices+record.count
  if record.count==0 then return nil end
  return record.count==record.total and mesh or record.selected
end
local function hook(object,name,wrapper)
  local original=object[name];local replacement=wrapper(original);object[name]=replacement
  hooks[#hooks+1]={object,name,original,replacement}
end
function Culling.finish()
  for i=#hooks,1,-1 do local h=hooks[i];if h[1][h[2]]==h[4] then h[1][h[2]]=h[3] end end
  hooks={}
  for i=#(profileRestores or {}),1,-1 do profileRestores[i]() end
  profileRestores=nil;profile=nil
end
function Culling.begin(lib)
  Culling.finish();tick=tick+1;frusta=nil
  local telemetry=package.loaded["src.vr.Telemetry"]
  profile=telemetry and telemetry.isEnabled() and telemetry or nil
  metrics={sourceIndices=0,selectedIndices=0,pendingDraws=0,indexUpdates=0,readyMeshes=0,preparingMeshes=0,waterPassesSkipped=0}
  local disabled=os.getenv("POKEPORT_VR_DRAW_DISTANCE")=="off"
  metrics.mode=disabled and "off" or "frustum"
  metrics.active=false
  local deadline=clock()+0.002
  for mesh,record in pairs(cache) do
    if record.seen<tick-2 then release(record);cache[mesh]=nil
    elseif not disabled and not record.ready and not record.error and clock()<deadline then
      repeat
        local scope=profile and profile.beginCpuScope("vr_prepare_indices")
        local ok,err=coroutine.resume(record.worker)
        if profile then profile.endCpuScope(scope) end
        if not ok then record.error=tostring(err);break end
      until record.ready or clock()>=deadline
    end
    if cache[mesh] then
      if record.ready then metrics.readyMeshes=metrics.readyMeshes+1 else metrics.preparingMeshes=metrics.preparingMeshes+1 end
      if record.error then metrics.lastError=record.error end
    end
  end
  if disabled then return end
  local Mesher=lib.require("ChunkMesher")
  local Mat=lib.require("Mat4")
  graphics=lib.require("Voxel3D")
  if profile then
    profileRestores={
      profile.wrapCpu(graphics,"draw","mod_draw_submit"),
      profile.wrapCpu(lib.require("ShadowMap"),"draw","mod_shadow_submit"),
      profile.wrapCpu(lib.require("Water"),"draw","mod_water_submit"),
    }
  end
  hook(require("src.vr.Runtime"),"views",function(original)return function(...)
    local left,right=original(...)
    if left and right then
      local a,b=planes(left,Mat),planes(right,Mat)
      if a and b then
        frusta={a,b}
        nativePlanes=packedPlanes({a[1],a[2],a[3],a[4],b[1],b[2],b[3],b[4]},nativePlanes)
        -- VRStereo copies camera fields. A mono POV fallback also owns a
        -- camera, so only our actual tracked pair may consume these planes.
        left.__frameCullingTick=tick;right.__frameCullingTick=tick
      end
    end
    return left,right
  end end)
  for _,name in ipairs({"pair","grass","flowers"}) do
    hook(Mesher,name,function(original)return function(...)
      local a,b=original(...);register(a);if name=="pair" then register(b,true) end;return a,b
    end end)
  end
  local scene=lib.require("VoxelScene")
  if scene.drawWater then
    hook(scene,"drawWater",function(original)return function(draws,...)
      for _,d in ipairs(draws) do
        if waterVisible(d[1],d[3]) then return original(draws,...) end
      end
      metrics.waterPassesSkipped=metrics.waterPassesSkipped+1
    end end)
  end
  for _,name in ipairs({"Voxel3D"}) do
    hook(lib.require(name),"draw",function(original)return function(mesh,texture,model,...)
      local selected=selection(mesh,model,...)
      if selected then return original(selected,texture,model,...) end
    end end)
  end
end
function Culling.status()return metrics end
-- Shadow vertices are uncurved and receive no camera depth pull. Test the
-- original bounds against the actual light/model matrix, never either eye.
-- The wider legacy GL z range is conservative on both LOVE 11 and 12.
function Culling.shadowSelection(mesh,model,clip)
  local record=cache[mesh]
  if not record or not record.ready or type(clip)~="table" or (model and type(model)~="table") then return mesh,record and record.total,record and record.total end
  local m={}
  for row=0,3 do for col=1,4 do
    local v=0
    for k=1,4 do
      local a=clip[row*4+k]
      local b=k==col and 1 or 0
      if model then b=model[(k-1)*4+col] end
      if type(a)~="number" or type(b)~="number" then return mesh,record.total,record.total end
      v=v+a*b
    end
    if v~=v or math.abs(v)==math.huge then return mesh,record and record.total,record and record.total end
    m[row*4+col]=v
  end end
  local planes={}
  local visibilityScope=profile and profile.beginCpuScope("vr_light_visibility")
  for axis=0,2 do for _,sign in ipairs({-1,1}) do
    local p={};for j=1,4 do p[j]=m[12+j]+sign*m[axis*4+j] end
    planes[#planes+1]=p
  end end
  if profile then profile.endCpuScope(visibilityScope) end
  nativeLightPlanes=packedPlanes(planes,nativeLightPlanes)
  local nativeCount,nativeChanged=nativeSelection(record,nativeLightPlanes,true)
  local changed=nativeChanged
  if nativeCount then record.shadowCount=nativeCount else
  visibilityScope=profile and profile.beginCpuScope("vr_light_visibility")
  changed=false
  for _,g in ipairs(record.groups) do
    local keep=true
    for _,p in ipairs(planes) do
      local d=p[1]*(p[1]>=0 and g.x1 or g.x0)+p[2]*(p[2]>=0 and g.y1 or g.y0)
        +p[3]*(p[3]>=0 and g.z1 or g.z0)+p[4]
      if d < -0.0001 then keep=false;break end
    end
    if keep~=g.shadowKeep then changed=true;g.shadowKeep=keep end
  end
  if profile then profile.endCpuScope(visibilityScope) end
  end
  if changed then
    if not nativeCount then
    local countScope=profile and profile.beginCpuScope("vr_range_count")
    local n=0
    for _,r in ipairs(record.ranges) do if r[3].shadowKeep then n=n+r[2]-r[1]+1 end end
    record.shadowCount=n
    if profile then profile.endCpuScope(countScope) end
    end
    local n=record.shadowCount
    if n>0 and n<record.total then
      if not record.shadowSelected then
        local selected=love.graphics.newMesh({{"CullingUnused","byte",4}},mesh:getVertexCount(),"triangles","dynamic")
        selected:setAttributeEnabled("CullingUnused",false)
        for _,a in ipairs(mesh:getVertexFormat()) do selected:attachAttribute(a[1],mesh) end
        record.shadowSelected=selected
      end
      uploadSelection(record,record.shadowSelected,"shadowKeep",n,nativeCount~=nil)
    end
  end
  if record.shadowCount==0 then return nil,record.total,0 end
  return record.shadowCount==record.total and mesh or record.shadowSelected,record.total,record.shadowCount
end
function Culling.release()
  Culling.finish();for _,record in pairs(cache) do release(record) end;cache={}
  if nativePlanes then nativePlanes:release();nativePlanes=nil end
  if nativeLightPlanes then nativeLightPlanes:release();nativeLightPlanes=nil end
end
return Culling
