function love.load()
  local kit=assert(os.getenv("POKEPORT_TEST_KIT"))
  local mod=assert(os.getenv("POKEPORT_TEST_VOXEL"))
  local Window=assert(loadfile(kit.."/integration/src/vr/DrawDistance.lua"))()
  local Mat=assert(loadfile(mod.."/lib/Mat4.lua"))()
  local Voxel=assert(loadfile(mod.."/lib/Voxel3D.lua"))({require=function(name)if name=="Mat4" then return Mat end;return {}end})
  local verts,indices={},{}
  local function quad(x0,z0,x1,z1,y)
    local n=#verts
    for _,p in ipairs({{x0,y,z0},{x1,y,z0},{x1,y,z1},{x0,y,z1}})do
      verts[#verts+1]={p[1],p[2],p[3],0,0,1}
    end
    for _,i in ipairs({1,2,3,1,3,4})do indices[#indices+1]=n+i end
  end
  for z=-64,512,16 do for x=-64,512,16 do quad(x,z,x+16,z+16,0)end end
  local groundCount=#indices
  -- Complete tall boundary object, whose roof projects inside the viewport.
  quad(88,16,136,48,48)
  quad(88,16,136,16,48)
  local objectCount=#indices-groundCount
  quad(400,400,464,464,64)
  local terrain=assert(Voxel.newMesh(verts,indices))
  local water=assert(Voxel.newMesh({{0,-1,0,0,0,1},{64,-1,0,0,0,1},{64,-1,64,0,0,1},{0,-1,64,0,0,1}}, {1,2,3,1,3,4}))
  local actor=assert(Voxel.newMesh({{0,0,0,0,0,1},{16,0,0,0,0,1},{16,16,0,0,0,1},{0,16,0,0,0,1}}, {1,2,3,1,3,4}))
  local draws={}
  local function draw(mesh,texture,model) draws[#draws+1]={mesh,model} end
  local modules={ChunkMesher={pair=function()return terrain,water end,grass=function()end,flowers=function()end},
    Mat4=Mat,Voxel3D={draw=draw,curveK=0,camera={}},Water={draw=draw},
    SpriteBillboards={mesh=function()return actor end,shadowQuad=function()return actor end}}
  local cam={x=0,y=0,yaw=0};local model;local monoCamera
  modules.VoxelScene={render=function(state,w,h,vw,vh)
    local a,b=modules.ChunkMesher.pair()
    modules.Voxel3D.draw(a,nil,model);modules.VoxelScene.drawWater({{b,nil,model}})
    modules.Voxel3D.draw(modules.SpriteBillboards.mesh(),nil,Mat.translate(64,0,32))
    modules.Voxel3D.draw(modules.SpriteBillboards.mesh(),nil,Mat.translate(500,0,500))
  end}
  local reflections=0
  modules.VoxelScene.drawWater=function(waterDraws)
    reflections=reflections+1
    for _,d in ipairs(waterDraws) do modules.Water.draw(d[1],d[2],d[3]) end
  end
  local lib={require=function(name)return assert(modules[name],name)end}
  local function views()
    local result={}
    for i,x in ipairs({-1.536,1.536})do
      result[i]={eye={32+x+cam.x,100,128+cam.y},focus={32+x+cam.x+96*math.sin(cam.yaw),0,128+cam.y-96*math.cos(cam.yaw)},up={0,1,0},
        fov={left=-0.8,right=0.8,up=0.8,down=-0.8}}
    end
    return result[1],result[2]
  end
  local Runtime={views=views};package.loaded["src.vr.Runtime"]=Runtime
  local originalScene=modules.VoxelScene.render
  local function frame()
    draws={};Window.begin(lib);local left=Runtime.views()
    if monoCamera then modules.Voxel3D.camera={}
    elseif modules.Voxel3D.camera then modules.Voxel3D.camera=left end
    for eye=1,2 do modules.VoxelScene.render({camera=cam},1728,1728,64,64)end
    local status=Window.status();Window.finish()
    assert(modules.VoxelScene.render==originalScene and modules.Voxel3D.draw==draw)
    return status
  end
  local originalClock=love.timer.getTime
  love.timer.getTime=function()return 0 end
  local initial=frame();assert(initial.pendingDraws==2,"whole first stereo pair must use fallback")
  local status=frame();love.timer.getTime=originalClock
  assert(status.pendingDraws==0 and status.selectedIndices<status.sourceIndices)
  assert(#draws==8,"actor simulation/presentation remains untouched")
  assert(draws[1][1]==draws[5][1],"same selected mesh for both eyes")
  assert(draws[2][1]==water,"visible water remains original complete mesh")
  local chosen=draws[1][1]:getVertexMap()
  local previous=0;local retained=0
  for _,index in ipairs(chosen)do
    -- Compare full ordered subsequence against the original triangle stream.
    while previous<#indices and indices[previous+1]~=index do previous=previous+1 end
    previous=previous+1;assert(indices[previous]==index,"triangle order changed")
    if previous>groundCount and previous<=groundCount+objectCount then retained=retained+1 end
  end
  assert(retained==objectCount,"whole tall boundary object must survive")
  local original=terrain:getVertexMap();assert(#original==#indices)
  for i,v in ipairs(indices)do assert(original[i]==v,"source/shadow indices mutated")end
  -- The shadow view is independent of eye visibility. A light volume around
  -- the far object must retain it even while both tracked eyes look elsewhere.
  local light=Mat.mul(Mat.scale(1/40,1/80,1/40),Mat.translate(-432,-32,-432))
  local selected=Window.shadowSelection(terrain,nil,light)
  assert(selected and selected~=terrain,"actual light volume should select only its chunks")
  local shadowIndices=selected:getVertexMap()
  local farCount=0
  for _,i in ipairs(shadowIndices) do if i>#verts-4 then farCount=farCount+1 end end
  assert(farCount==6,"off-eye-frustum caster inside light volume must survive")
  assert(Window.shadowSelection(actor,nil,light)==actor,"unknown actor bounds fail open")
  assert(Window.shadowSelection(terrain,Mat.translate(5000,0,0),light)==nil,"outside light volume must reject")
  local all=Mat.scale(1/4096,1/4096,1/4096)
  assert(Window.shadowSelection(terrain,nil,all)==terrain,"light fit changes must invalidate selection")
  assert(Window.shadowSelection(terrain,{},light)==terrain,"unknown model must fail open")
  local bad=Mat.identity();bad[1]=0/0
  assert(Window.shadowSelection(terrain,nil,bad)==terrain,"invalid clip matrix must fail open")
  modules.Voxel3D.camera=nil
  frame();assert(draws[1][1]==terrain,"mono fallback must never reuse XR frusta")
  monoCamera=true;frame()
  assert(draws[1][1]==terrain,"mono POV camera must never reuse XR frusta")
  monoCamera=false;modules.Voxel3D.camera={}
  local stable=frame();assert(stable.indexUpdates==0,"unchanged viewport must reuse indices")
  model=Mat.translate(-256,0,-256);local moved=frame()
  assert(moved.indexUpdates>0,"neighbor translation must affect local selection")
  assert(draws[1][1]==draws[5][1],"translated neighbors agree between eyes")
  model=nil;cam.x=400;cam.y=400
  local shifted=frame();assert(shifted.indexUpdates>0,"scroll changes selection")
  cam.x=2000;local noWater=frame()
  assert(noWater.waterPassesSkipped==2,"off-frustum water must skip both reflection setups")
  for _,d in ipairs(draws) do assert(d[1]~=water,"off-frustum reflection must not draw water") end
  monoCamera=true;local fallback=frame()
  assert(fallback.waterPassesSkipped==0,"mono fallback must retain water")
  monoCamera=false;cam.x=0;cam.y=0;local visibleAgain=frame()
  assert(visibleAgain.waterPassesSkipped==0 and draws[2][1]==water,"visible water must retain its complete original mesh")
  cam.x=400;cam.y=400;frame()
  -- Replacing the source is its invalidation key; old selected GPU resources
  -- are retired after their last two-frame grace period.
  local retired=draws[1][1]
  local replacement=assert(Voxel.newMesh(verts,indices));terrain=replacement
  assert(frame().pendingDraws==2)
  love.timer.getTime=function()return 0 end
  assert(frame().pendingDraws==0);love.timer.getTime=originalClock
  frame();frame()
  assert(not pcall(retired.getVertexCount,retired),"unused proxy must be explicitly released")
  assert(replacement:getVertexCount()==#verts,"source ownership must stay with ChunkMesher")
  local baselinePath=os.getenv("POKEPORT_TEST_CULL_BASELINE")
  if baselinePath then
    local candidate=Window
    local baseline=assert(loadfile(baselinePath))()
    local ffi=require("ffi")
    local function bytes(mesh)
      if not mesh then return "nil" end
      local map=mesh:getVertexMap()
      local n=map and #map or mesh:getVertexCount()
      local data=ffi.new("uint32_t[?]",n)
      for i=1,n do data[i-1]=(map and map[i] or i)-1 end
      return ffi.string(data,n*4)
    end
    for _,indexed in ipairs({true,false}) do
      candidate.release();baseline.release()
      terrain=assert(Voxel.newMesh(verts,indexed and indices or nil))
      -- Non-indexed input must also be a complete original quad stream.
      if not indexed then
        terrain:release();local expanded={}
        for _,i in ipairs(indices) do expanded[#expanded+1]=verts[i] end
        terrain=assert(Voxel.newMesh(expanded))
      end
      love.timer.getTime=function()return 0 end
      for _,implementation in ipairs({baseline,candidate}) do Window=implementation;frame();frame() end
      love.timer.getTime=originalClock
      local savedNew=love.data.newByteData;local allocations=0
      love.data.newByteData=function(...)allocations=allocations+1;return savedNew(...)end
      for pose=1,40 do
        cam.x=160+180*math.sin(pose*0.37);cam.y=100+90*math.cos(pose*0.21);cam.yaw=math.sin(pose*0.27)*1.2
        model=pose%2==0 and Mat.translate(-64,0,32) or nil
        local maps={};local light=Mat.mul(Mat.scale(1/120,1/80,1/90),Mat.translate(-cam.x,-32,-cam.y))
        for i,implementation in ipairs({baseline,candidate}) do
          Window=implementation;frame();local eyeBytes=bytes(draws[1] and draws[1][1])
          local shadow=Window.shadowSelection(terrain,model,light)
          maps[i]={eyeBytes,bytes(shadow)}
          assert(eyeBytes==bytes(draws[1] and draws[1][1]),"shadow upload changed terrain index bytes")
        end
        assert(maps[1][1]==maps[2][1] and maps[1][2]==maps[2][2],"baseline index bytes differ at moving pose "..pose)
      end
      love.data.newByteData=savedNew
      print("CULL_INDEX_BYTES_PASS",indexed and "indexed" or "nonindexed","40 moving eye/light poses")
      -- Candidate storage is retained across changing selections: no new
      -- ByteData allocations after both paths have been exercised.
      local before=allocations
      love.data.newByteData=function(...)allocations=allocations+1;return savedNew(...)end
      Window=candidate;cam.x=350;cam.yaw=-0.8;frame();Window.shadowSelection(terrain,nil,all)
      cam.x=50;cam.yaw=0.8;frame();Window.shadowSelection(terrain,nil,light)
      love.data.newByteData=savedNew
      assert(allocations==before,"candidate reallocates index scratch during head motion")
    end
    baseline.release();Window=candidate
  end
  Window.release()
  assert(modules.Voxel3D.draw==draw)
  print("DRAW_DISTANCE_MESH_PASS: real pinned mesh format/indexed GPU path, conservative tall boundary geometry, original ordered indices and shadow source, water, actors unchanged, stereo readiness, translated neighbor, scroll/cache/invalidation")
  love.event.quit(0)
end
function love.errorhandler(message)io.stderr:write(tostring(message).."\n");return function()return 1 end end
