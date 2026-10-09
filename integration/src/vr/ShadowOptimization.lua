-- Scoped to native stereo. The original caster order, fitter, packed color,
-- sprite classification and receiver shaders stay authoritative.
local Optimization = {}
local Culling = require("src.vr.DrawDistance")
local Telemetry = require("src.vr.Telemetry")
local caches = setmetatable({}, {__mode="k"})
local hooks, metrics, closeScopes = {}, nil, nil
local function release(c)
  for _,name in ipairs({"color","depth"}) do
    if c[name] then c[name]:release();c[name]=nil end
  end
  c.key=nil
end
local function equal(a,b)
  if not a or #a~=#b then return false end
  for i=1,#a do if a[i]~=b[i] then return false end end
  return true
end
local function hook(object,name,replacement)
  hooks[#hooks+1]={object,name,object[name],replacement};object[name]=replacement
end
function Optimization.finish()
  if closeScopes then closeScopes();closeScopes=nil end
  for i=#hooks,1,-1 do local h=hooks[i];if h[1][h[2]]==h[4] then h[1][h[2]]=h[3] end end
  hooks={}
end
function Optimization.status() return metrics end
function Optimization.release()
  Optimization.finish()
  for _,c in pairs(caches) do release(c) end
  caches=setmetatable({}, {__mode="k"})
end
function Optimization.begin(V)
  Optimization.finish()
  metrics={terrainBuilds=0,terrainHits=0,terrainTriangles=0,dynamicTriangles=0,
    sourceTerrainTriangles=0,sourceDynamicTriangles=0,restores=0,fallbacks=0}
  if os.getenv("POKEPORT_VR_SHADOW_OPTIMIZATION")=="off" then return end
  local Shadow=V.require("ShadowMap")
  local cache=caches[Shadow]
  if not cache then cache={counts=setmetatable({}, {__mode="k"})};caches[Shadow]=cache end
  local draws, terrain, dynamicGpu, dynamicCpu
  local originalBegin,originalDraw,originalFinish=Shadow.begin,Shadow.draw,Shadow.finish
  local diagnostic=Telemetry.isEnabled()
  hook(Shadow,"sceneSignature",function(sig,state,atlasFor)
    -- Prebuilt animated atlases change identity, including alpha silhouettes.
    -- Flowers remain dynamic even when no actor has moved this update.
    local parts={sig}
    local function mapStamp(map,ox,oy)
      parts[#parts+1]=tostring(atlasFor(map))
      parts[#parts+1]=tostring(V.require("ChunkMesher").flowers(map))
      parts[#parts+1]=ox;parts[#parts+1]=oy
    end
    mapStamp(state.map,0,0)
    for _,nb in ipairs(state.neighbors or {}) do mapStamp(nb.map,nb.ox,nb.oy) end
    return table.concat(parts,",")
  end)
  local function count(mesh)
    if not mesh then return 0 end
    if not cache.counts[mesh] then
      local map=mesh:getVertexMap();cache.counts[mesh]=map and #map or mesh:getVertexCount()
    end
    return cache.counts[mesh]
  end
  local function draw(mesh,texture,model,kind)
    local selected,sourceCount,selectedCount=Culling.shadowSelection(mesh,model,Shadow.clipVP)
    if diagnostic then
      metrics[kind.."Triangles"]=metrics[kind.."Triangles"]+(selectedCount or count(selected))/3
      local key=kind=="terrain" and "sourceTerrainTriangles" or "sourceDynamicTriangles"
      metrics[key]=metrics[key]+(sourceCount or count(mesh))/3
    end
    if selected then originalDraw(selected,texture,model) end
  end
  local function resources(res)
    if cache.failed then return false end
    if cache.color and cache.res==res then return true end
    release(cache)
    local ok,err=pcall(function()
      local made,color=V.require("PixelCanvas").new(res,res);assert(made,color)
      cache.color=color;color:setFilter("nearest","nearest")
      -- Match LOVE 11's temporary depth=true attachment (Graphics.cpp):
      -- depth24 when supported as a render target, otherwise depth16.
      -- Refuse this cache if the SAME format cannot be read; never reduce it.
      local format=love.graphics.getCanvasFormats(false).depth24 and "depth24" or "depth16"
      local good,depth=V.require("PixelCanvas").new(res,res,{format=format,readable=true})
      assert(good,depth);cache.depth=depth;depth:setFilter("nearest","nearest");depth:setDepthSampleMode()
      cache.res=res
    end)
    if not ok then release(cache);cache.failed=true;metrics.lastFallback=tostring(err) end
    return ok
  end
  hook(Shadow,"begin",function(...)
    local ok=originalBegin(...)
    if ok then draws={};terrain=true end
    return ok
  end)
  hook(Shadow,"draw",function(mesh,texture,model)
    if terrain then draws[#draws+1]={mesh,texture,model}
    else draw(mesh,texture,model,"dynamic") end
  end)
  hook(Shadow,"staticEnd",function()
    if not terrain then return end
    terrain=false
    local key={Shadow.res}
    for i=1,16 do key[#key+1]=Shadow.clipVP[i] end
    for _,d in ipairs(draws) do
      key[#key+1]=d[1] or false;key[#key+1]=d[2] or false
      for i=1,16 do key[#key+1]=d[3] and d[3][i] or (i==1 or i==6 or i==11 or i==16) and 1 or 0 end
    end
    local main=love.graphics.getCanvas()
    local gpu=Telemetry.beginGpuScope("shadow_terrain")
    local cpu=Telemetry.beginStage("shadow_terrain")
    if resources(Shadow.res) then
      local bound=pcall(love.graphics.setCanvas,{cache.color,depthstencil=cache.depth})
      if bound then
        if not equal(cache.key,key) then
          love.graphics.clear(1,1,0,1,true,true)
          for _,d in ipairs(draws) do draw(d[1],d[2],d[3],"terrain") end
          cache.key=key;metrics.terrainBuilds=metrics.terrainBuilds+1
        else metrics.terrainHits=metrics.terrainHits+1 end
        love.graphics.setCanvas({main,depth=true})
        love.graphics.clear(1,1,0,1,true,true)
        local restored,reason=require("src.vr.Runtime").restoreShadowCanvas(cache.color,cache.depth,main)
        if restored then metrics.restores=metrics.restores+1
        else
          cache.failed=true;release(cache)
          metrics.lastFallback=tostring(reason);metrics.fallbacks=metrics.fallbacks+1
          love.graphics.clear(1,1,0,1,true,true)
          for _,d in ipairs(draws) do draw(d[1],d[2],d[3],"terrain") end
        end
      else
        cache.failed=true;release(cache)
        love.graphics.setCanvas({main,depth=true})
        love.graphics.clear(1,1,0,1,true,true)
        for _,d in ipairs(draws) do draw(d[1],d[2],d[3],"terrain") end
        metrics.fallbacks=metrics.fallbacks+1
      end
    else
      for _,d in ipairs(draws) do draw(d[1],d[2],d[3],"terrain") end
      metrics.fallbacks=metrics.fallbacks+1
    end
    Telemetry.endStage(cpu);Telemetry.endGpuScope(gpu)
    draws=nil
    dynamicGpu=Telemetry.beginGpuScope("shadow_dynamic")
    dynamicCpu=Telemetry.beginStage("shadow_dynamic")
  end)
  closeScopes=function()
    Telemetry.endStage(dynamicCpu);Telemetry.endGpuScope(dynamicGpu)
    dynamicGpu,dynamicCpu=nil,nil
  end
  hook(Shadow,"finish",function(...)
    closeScopes()
    return originalFinish(...)
  end)
  for _,name in ipairs({"invalidate","discard"}) do
    local original=Shadow[name]
    hook(Shadow,name,function(...)cache.key=nil;return original(...)end)
  end
end
return Optimization
