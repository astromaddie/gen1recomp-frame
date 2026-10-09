function love.load()
  local kit=assert(os.getenv("POKEPORT_TEST_KIT"))
  local mod=assert(os.getenv("POKEPORT_TEST_VOXEL"))
  package.path=kit.."/integration/?.lua;"..package.path
  package.loaded["src.vr.Telemetry"]={isEnabled=function()return true end,
    beginStage=function()end,endStage=function()end,beginGpuScope=function()end,endGpuScope=function()end}
  local modules={VoxelState={angle=math.rad(60),FOCAL=1.0},Shadows={off=function()return false end}}
  local V={}
  V.require=function(name)
    if not modules[name] then modules[name]=assert(loadfile(mod.."/lib/"..name..".lua"))(V) end
    return modules[name]
  end
  local Mat=V.require("Mat4");local Shadow=V.require("ShadowMap")
  local native=assert(package.loadlib(assert(os.getenv("POKEPORT_TEST_BRIDGE")),"luaopen_xrbridge"))()
  package.loaded["src.vr.Runtime"]={restoreShadowCanvas=native.restoreShadowCanvas}
  local Optimization=require("src.vr.ShadowOptimization")
  local function quad(x,y,z,w)
    return love.graphics.newMesh({{"VertexPosition","float",3},{"VertexTexCoord","float",2}},
      {{x,y,z,0,0},{x+w,y,z,1,0},{x+w,y,z+w,1,1},{x,y,z+w,0,1}},"fan","static")
  end
  local terrain=quad(-30,0,-30,60);local actor=quad(-15,0,-15,30)
  local data=love.image.newImageData(2,2);data:mapPixel(function()return 1,1,1,1 end)
  local opaque=love.graphics.newImage(data)
  data:setPixel(0,0,1,1,1,0);local cutout=love.graphics.newImage(data)
  local function render(optimized,dy,cx,size)
    if optimized then Optimization.begin(V) end
    assert(Shadow.available());assert(Shadow.begin(cx,0,size,size))
    Shadow.draw(terrain,opaque)
    if Shadow.staticEnd then Shadow.staticEnd() end
    -- Dynamic world cutout then sprite: exercise lequal ties and B channel.
    Shadow.draw(actor,cutout,Mat.translate(0,dy,0))
    Shadow.sprites(true);Shadow.draw(actor,cutout,Mat.translate(1,dy,1));Shadow.sprites(false)
    Shadow.finish("probe")
    local result=Shadow.texture():newImageData()
    if optimized then Optimization.finish() end
    return result
  end
  for i,case in ipairs({{0,0,80},{1,0,80},{-1,0,80},{0,1,80},{0,1,320}}) do
    local a=render(false,unpack(case));local b=render(true,unpack(case))
    if a:getString()~=b:getString() then
      local changed=0;local w,h=a:getDimensions()
      for y=0,h-1 do for x=0,w-1 do
        local r,g,bb=a:getPixel(x,y);local rr,gg,bbb=b:getPixel(x,y)
        if r~=rr or g~=gg or bb~=bbb then
          changed=changed+1
          if changed<12 then print("DIFF",i,x,y,r,g,bb,rr,gg,bbb) end
        end
      end end
      print("DIFF_COUNT",changed,Optimization.status().lastFallback)
    end
    assert(a:getString()==b:getString(),"packed shadow/depth restore differs in case "..i)
    local status=Optimization.status()
    assert(status.fallbacks==0,status.lastFallback)
    assert(status.restores==1)
    assert((i==2 or i==3) and status.terrainHits==1 or (i~=2 and i~=3 and status.terrainBuilds==1),"static invalidation/hit wrong")
    a:release();b:release()
  end
  -- A failed native copy must replay the original caster prefix, even when
  -- the driver has already touched its destination before returning failure.
  Optimization.release()
  local expected=render(false,0,0,80)
  package.loaded["src.vr.Runtime"].restoreShadowCanvas=function()
    love.graphics.clear(1,0,1,1,true,true);return false,"injected copy failure"
  end
  local fallback=render(true,0,0,80)
  assert(expected:getString()==fallback:getString(),"failed copy must restore original caster result")
  assert(Optimization.status().fallbacks==1)
  Optimization.release()
  package.loaded["src.vr.Runtime"].restoreShadowCanvas=native.restoreShadowCanvas
  local source=love.graphics.newCanvas(32,32)
  local depth=love.graphics.newCanvas(32,32,{format="depth24",readable=true})
  local target=love.graphics.newCanvas(32,32)
  local targetDepth=love.graphics.newCanvas(32,32,{format="depth24",readable=true})
  local other=love.graphics.newCanvas(32,32)
  local small=love.graphics.newCanvas(16,16)
  local function bind()love.graphics.setCanvas({target,depthstencil=targetDepth});love.graphics.clear(0,0,0,1,true,true)end
  love.graphics.setCanvas({source,depthstencil=depth});love.graphics.clear(0.25,0.5,0.75,1,true,true)
  bind()
  love.graphics.setScissor(1,2,3,4);love.graphics.setColor(0.3,0.4,0.5,0.6)
  love.graphics.setBlendMode("alpha");love.graphics.setDepthMode("lequal",true)
  assert(native.restoreShadowCanvas(source,depth,target))
  assert(love.graphics.getCanvas()[1][1]==target)
  local x,y,w,h=love.graphics.getScissor();assert(x==1 and y==2 and w==3 and h==4)
  local r,g,b,a=love.graphics.getColor();assert(math.abs(r-0.3)<0.00001 and math.abs(a-0.6)<0.00001)
  assert(love.graphics.getBlendMode()=="alpha")
  local compare,write=love.graphics.getDepthMode();assert(compare=="lequal" and write)
  love.graphics.setScissor();love.graphics.setCanvas()
  local copied=target:newImageData();local src=source:newImageData()
  assert(copied:getString()==src:getString(),"copy must ignore scissor and color state without changing them")
  bind()
  for _,args in ipairs({{source,depth,source},{source,depth,other},{small,depth,target},
      {opaque,depth,target},{source,source,target},{source,targetDepth,target}}) do
    assert(native.restoreShadowCanvas(unpack(args))==false,"invalid type/target/format/alias must fail")
    assert(love.graphics.getCanvas()[1][1]==target,"rejected copy changed target")
  end
  local wrongDepth=love.graphics.newCanvas(32,32,{format="depth16",readable=true})
  assert(native.restoreShadowCanvas(source,wrongDepth,target)==false,"depth precision mismatch must fail")
  love.graphics.setCanvas()
  assert(native.restoreShadowCanvas(source,depth,target)==false,"window cannot be copy destination")
  native.destroy()
  Optimization.release()
  print("SHADOW_OPTIMIZATION_PASS: real shader and depth24 color/depth restore, overlap ties, alpha cutout, sprite classification, actor movement, fit and resolution invalidation")
  love.event.quit(0)
end
function love.errorhandler(message)io.stderr:write(tostring(message).."\n"..debug.traceback().."\n");return function()return 1 end end
