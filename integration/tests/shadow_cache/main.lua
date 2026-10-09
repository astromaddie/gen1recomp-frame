function love.load()
  local mod=assert(os.getenv("POKEPORT_TEST_VOXEL"))
  local Mat=assert(loadfile(mod.."/lib/Mat4.lua"))()
  local voxel={angle=math.rad(60),FOCAL=1.0}
  local off=false
  local allocations={}
  local modules={Mat4=Mat,VoxelState=voxel,Shadows={off=function()return off end},
    PixelCanvas={new=function(w,h)
      allocations[#allocations+1]={w,h}
      return pcall(love.graphics.newCanvas,w,h,{dpiscale=1})
    end}}
  local Shadow=assert(loadfile(mod.."/lib/ShadowMap.lua"))({require=function(name)return assert(modules[name],name)end})
  assert(Shadow.available())
  assert(Shadow.begin(160,144,320,288))
  Shadow.finish("scene/map/light/actor:1")
  local map=Shadow.texture();local res=Shadow.res
  assert(res>1024,"test must exercise fitted larger shadow target")
  local n=#allocations
  for eye=1,4 do
    assert(Shadow.available())
    assert(Shadow.texture()==map,"availability replaced the fitted shadow map")
    assert(not Shadow.stale("scene/map/light/actor:1"),"availability invalidated unchanged shadows")
  end
  assert(#allocations==n,"availability must not allocate per eye/frame")
  -- VoxelScene's full scene signature stays authoritative, independently of
  -- target retention. A changed map/light/actor stamp must rebuild normally.
  for _,sig in ipairs({"map:2","light:2","actor:2"}) do
    assert(Shadow.stale(sig))
    assert(Shadow.begin(160,144,320,288));Shadow.finish(sig)
    assert(not Shadow.stale(sig) and Shadow.texture()==map)
  end
  assert(Shadow.begin(16,16,32,32));Shadow.finish("small-view")
  assert(Shadow.res==1024 and Shadow.texture()~=map,"fit must still resize for a new view")
  assert(Shadow.available() and not Shadow.stale("small-view"))
  Shadow.discard();assert(Shadow.stale("small-view"),"battle/map discard must invalidate")
  off=true;assert(not Shadow.available() and not Shadow.active())
  print("SHADOW_CACHE_PASS: real shader/fit/canvas, larger-rung reuse, unchanged signature hit, changed map/light/actor stamp, fit resize, discard, shadows off")
  love.event.quit(0)
end
function love.errorhandler(message)io.stderr:write(tostring(message).."\n");return function()return 1 end end
