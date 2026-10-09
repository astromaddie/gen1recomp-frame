-- Production patched main + pinned original RomImporter input/Play methods.
-- Only asset/window/game loading is stubbed; no driver or forced XR state.
local mainPath=assert(arg[1])
local importerPath=assert(arg[2])
local originalRequire=require
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
  pollActions=function()return actions end}
local mods={
  ["src.vr.Runtime"]=runtime,
  ["src.core.HostShell"]={hideHostConsole=function()end},
  ["src.update.Boot"]={run=function()return false end},
  ["src.core.GameVersion"]={VERSIONS={yellow=true},set=function(v)version=v end,
    get=function()return version end},
  ["src.core.Strings"]={},["src.core.SafeArea"]={},
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
for _,case in ipairs({"native-start","native-a","desktop-pad","keyboard","mouse"})do
  reset()
  if case=="native-start" then actions.start=true;love.update(.016)
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
_G.require=originalRequire
print("production launcher transitions passed: native Start/A, desktop pad, keyboard, mouse, focus, boot error")
