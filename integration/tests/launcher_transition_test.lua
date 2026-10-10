-- Production patched main + pinned original RomImporter input/Play methods.
-- Only asset/window/game loading is stubbed; no driver or forced XR state.
local mainPath=assert(arg[1])
local importerPath=assert(arg[2])
local originalRequire=require
local vrRoot=mainPath:match("^(.*)/main.lua$").."/src/vr/"
package.loaded["src.vr.MonoPanel"]=assert(loadfile(vrRoot.."MonoPanel.lua"))()
package.loaded["src.vr.LauncherPointer"]=assert(loadfile(vrRoot.."LauncherPointer.lua"))()
local views={}
for i,x in ipairs({-.032,.032})do views[i]={position={x=x,y=0,z=0},orientation={x=0,y=0,z=0,w=1}}end
local focused, actions, current, version, loads, updates, retiredCalls, loadFailure
local game={}
function game:load()
  if loadFailure then error("injected game load failure") end
  loads=loads+1;self.save={options={pipelines={voxel=0}}}
end
function game:update() updates=updates+1 end
function game:focus()end
local runtime={isEnabled=function()return true end,setEnabled=function()end,start=function()return true end,
  status=function()return {bridge=true}end,isBridgeActive=function()return true end,
  isQuitRequested=function()return false end,shouldSimulate=function()return focused end,
  pollActions=function()return actions end,frameViews=function()return views end}
local mods={
  ["src.vr.Runtime"]=runtime,
  ["src.core.HostShell"]={hideHostConsole=function()end},
  ["src.update.Boot"]={run=function()return false end},
  ["src.core.GameVersion"]={VERSIONS={yellow=true},set=function(v)version=v end,
    get=function()return version end},
  ["src.core.Strings"]={},["src.core.SafeArea"]={rect=function()return 0,0,800,600 end},
  ["src.import.CacheFs"]={mountVersion=function()end},["src.core.Game"]=game,
}
_G.require=function(name)return mods[name] or originalRequire(name)end
local originalImporter=assert(loadfile(importerPath))()
mods["src.import.RomImporter"]={isReady=function()return true end,new=function(callback)
  current=setmetatable({tab="yellow",panelVersion="yellow",ready={yellow=true},
    onComplete=callback,_padCursorActive=true,_padCursor={x=20,y=20},
    _padDir={},_padAxis={},playButtonRect={x=10,y=10,width=50,height=50}},originalImporter)
  -- Detect any access to the retired launcher's remaining input/update path.
  for _,name in ipairs({"gamepadpressed","gamepadreleased","gamepadaxis","update"})do
    local original=originalImporter[name]
    current[name]=function(self,...)
      if self._handedOff then retiredCalls=retiredCalls+1;error("retired launcher "..name)end
      if name~="update" then return original(self,...)end
    end
  end
  return current
end}
local function reset()
  focused=true;actions={move={x=.6,y=.3}};loads=0;updates=0;retiredCalls=0;loadFailure=false
  love={graphics={getDimensions=function()return 800,600 end,setDefaultFilter=function()end},
    mouse={},event={quit=function()end}}
  assert(loadfile(mainPath))();love.load({})
end
for _,case in ipairs({"native-start","native-a","native-trigger","desktop-pad","keyboard","mouse"})do
  reset()
  if case=="native-trigger" then
    actions={hands={right={valid=true,position={x=-.9025,y=.665,z=0},orientation={x=0,y=0,z=0,w=1},trigger=0}}}
    love.update(.016);actions.hands.right.trigger=.8;love.update(.016)
  elseif case=="native-start" then actions.start=true;love.update(.016)
  elseif case=="native-a" then actions.a=true;love.update(.016)
  elseif case=="desktop-pad" then love.gamepadpressed(nil,"start")
  elseif case=="keyboard" then love.keypressed("return")
  else love.mousepressed(20,20,1)end
  assert(loads==1 and version=="yellow",case..": original Play must boot chosen version exactly once")
  assert(retiredCalls==0 and updates==0,case..": transition must not touch retired launcher or update new game")
  love.update(.016);assert(updates==1,case..": new game must update next frame")
  focused=false;love.update(.016);assert(updates==1,case..": standby must still freeze game")
  focused=true;love.update(.016);assert(updates==2,case..": ordinary focus resumes game")
end
reset();focused=false;actions.start=true;love.update(.016)
assert(loads==0,"unfocused normal XR must not activate Play")
focused=true;love.update(.016);assert(loads==1,"Play must work when ordinary focus returns")
reset();loadFailure=true;actions.start=true
local ok,err=pcall(love.update,.016)
assert(not ok and tostring(err):find("injected game load failure",1,true),
  "launcher input must propagate original boot errors instead of swallowing them")
-- The actual importer update must keep laser hover despite OS mouse movement,
-- then yield normally when a pad/stick takes over. No OS mouse writes.
reset();love.mouse.getPosition=function()return 99,100 end
current._lastMouseX,current._lastMouseY=0,0
current._padAxis={};current._padDir={}
actions={hands={right={valid=true,position={x=0,y=0,z=0},orientation={x=0,y=0,z=0,w=1},trigger=0}}}
love.update(.016)
originalImporter._updatePadCursor(current,.016)
assert(current._padCursorActive and current._vrLaserCursor and current._padCursor.x==400)
actions.move={x=.5,y=0};love.update(.016)
originalImporter._updatePadCursor(current,.016)
assert(not current._vrLaserCursor and current._padCursor.x>400,"stick must own original pad navigation")
actions.scrollY=.8;love.update(.016);assert(current._padAxis.righty==-.8,"right stick scroll must reach original importer")
package.loaded["src.vr.LauncherPointer"].reset()
current._padAxis={};current._padDir={};current._lastMouseX,current._lastMouseY=0,0
originalImporter._updatePadCursor(current,.016)
assert(not current._padCursorActive,"flat/pad cursor must still yield to real mouse motion")
local input=assert(loadfile(mainPath:match("^(.*)/main.lua$").."/src/core/Input.lua"))()
input:init();input:vrActions({hands=actions.hands,scrollY=1})
assert(not input:isDown("a") and not input:isDown("b") and #input.pressQueue==0,"launcher-only trigger must not leak into gameplay")
_G.require=originalRequire
print("production launcher transitions passed: native trigger/Start/A, desktop pad, keyboard, mouse, focus, boot error")
