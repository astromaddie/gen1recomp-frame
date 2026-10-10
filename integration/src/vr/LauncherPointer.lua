-- Launcher-only adapter. Original importer owns hover/hit rectangles/actions.
local Panel = require("src.vr.MonoPanel")
local Pointer = {}
local armed = {left=false,right=false}
local owner
local trace=os.getenv("POKEPORT_VR_POINTER_TRACE")=="1"
local traces,lastTrace=0,-math.huge
local function report(hands,selected,hit,click)
  if not trace or traces>=180 then return end
  local now=love.timer and love.timer.getTime() or os.clock()
  if not click and now-lastTrace<1 then return end
  traces=traces+1;lastTrace=now
  print(string.format("[vr-pointer] left=%s right=%s hand=%s hit=%s u=%.4f v=%.4f x=%.2f y=%.2f click=%s",
    tostring(hands.left and hands.left.valid or false),tostring(hands.right and hands.right.valid or false),
    tostring(selected or "none"),tostring(hit and hit.inside or false),hit and hit.u or -1,hit and hit.v or -1,hit and hit.x or -1,hit and hit.y or -1,tostring(click or false)))
end
function Pointer.reset()
  armed = {left=false,right=false}
  if owner then owner._vrLaserCursor = nil end
  owner = nil
  Panel.setPointer(nil)
  report({},nil,nil,false)
end
function Pointer.update(importer, actions, views, width, height)
  if owner ~= importer then Pointer.reset();owner=importer end
  if not importer or not views then Pointer.reset();return false end
  local hands=actions.hands or {}
  local selected=hands.right and hands.right.valid and "right"
    or hands.left and hands.left.valid and "left"
  local pressed={}
  for _,hand in ipairs({"left","right"}) do
    local aim=hands[hand]
    if not aim or not aim.valid then armed[hand]=false
    elseif (tonumber(aim.trigger) or 0) <= 0.45 then armed[hand]=true
    elseif aim.trigger >= 0.6 then
      pressed[hand]=armed[hand];armed[hand]=false
    end
  end
  local hit=selected and Panel.hit(views,width,height,hands[selected])
  local move=actions.move or {}
  if math.abs(move.x or 0)>.2 or math.abs(move.y or 0)>.2 then hit=nil end
  importer._vrLaserCursor=hit and hit.inside or nil
  Panel.setPointer(hit)
  report(hands,selected,hit,hit and hit.inside and pressed[selected])
  if not hit or not hit.inside then return false end
  importer._padCursor=importer._padCursor or {}
  importer._padCursor.x,importer._padCursor.y=hit.x,hit.y
  importer._padCursorActive=true
  if pressed[selected] and type(importer.mousepressed)=="function" then
    importer:mousepressed(hit.x,hit.y,1)
    return true
  end
  return false
end
return Pointer
