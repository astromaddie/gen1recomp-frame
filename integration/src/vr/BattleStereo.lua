-- Repeat only the existing arena/card draw, never battle update or capture.
local Runtime=require("src.vr.Runtime")
local Battle={}
function Battle.active()
  return Runtime.isEnabled() and Runtime.isBridgeActive() and Runtime.shouldRender()
end
function Battle.render(V,session,drawActors)
  local context=session.context
  local arena=context.arena
  local cell=arena.playerCell
  local ground=cell and V.require("VoxelScene").groundAt(arena.map or session.arenaProvider.state.map,cell[1],cell[2]) or 0
  -- The source tele rig is five blocks away behind an 11.5-degree lens.
  -- Its existing wide rig supplies a usable VR seat with native headset FOV.
  -- Copy only the presentation descriptor; arena cells/options stay original.
  local vrArena={}
  for k,v in pairs(arena) do vrArena[k]=v end
  vrArena.cam="wide"
  local base,pitch=V.require("BattleCam").rig(vrArena,ground)
  base.mode="battle"
  local left,right=Runtime.views(base,1)
  if not (left and right) then return nil end
  local services=context.services
  local previous=services.camera
  local function render(view,slot)
    services.camera={pose=view,pitch=pitch,width=view.width,height=view.height,slot=slot,nativeXR=true}
    return session.arenaProvider:render(context,arena,drawActors)
  end
  local ok,a,b=xpcall(function()
    return render(left,"native-battle-left"),render(right,"native-battle-right")
  end,debug.traceback)
  services.camera=previous
  if not ok then error(a,0) end
  if not (a and b) then return nil end
  require("src.vr.DramalessStereo").queue(a,b)
  return a
end
return Battle
