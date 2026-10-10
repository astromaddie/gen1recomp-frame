local kit,mod=assert(arg[1]),assert(arg[2])
local Runtime={isEnabled=function()return true end,isBridgeActive=function()return true end,shouldRender=function()return true end}
local views={{eye={x=-1.536,y=30,z=60},focus={x=-1.536,y=0,z=0},width=1728,height=1728},{eye={x=1.536,y=30,z=60},focus={x=1.536,y=0,z=0},width=1728,height=1728}}
Runtime.views=function(base)assert(base.mode=="battle");return views[1],views[2]end
package.loaded["src.vr.Runtime"]=Runtime
local queued
package.loaded["src.vr.DramalessStereo"]={queue=function(a,b)queued={a,b}end}
local stereo=assert(loadfile(kit.."/BattleStereo.lua"))()
package.loaded["src.vr.BattleStereo"]=stereo
local draws,updates,captures,worlds=0,0,0,0
local host
local Battle={draw=function()draws=draws+1 end,drawPicsLayer=function()captures=captures+1 end}
package.loaded["src.battle.BattleState"]=Battle
love={graphics={clear=function()end,rectangle=function()end,getColor=function()return 1,1,1,1 end}}
local V={log={error=function(_,fmt,...)error(string.format(fmt,...))end,event=function()end},require=function(name)
 if name=="VoxelScene" then return {groundAt=function()return 0 end}end
 if name=="BattleCam" then return {rig=function(arena)assert(arena.cam=="wide");return {eye={0,30,60},focus={0,0,0},fov=1},.7 end}end
 error(name)
end}
host=assert(loadfile(mod.."/lib/VoxelBattleStandalone.lua"))(V)
local arena={mid={0,0},playerCell={1,1},map={}}
local failure
local provider={state={map={}},arena=function()return arena end,begin=function()return true end,
 update=function()updates=updates+1 end,render=function(self,ctx,a,actors)
  worlds=worlds+1;assert(ctx.services.camera.nativeXR and ctx.services.camera.pose==views[(worlds-1)%2+1]);
  assert(ctx.services.camera.width==1728)
  if failure and worlds%2==0 then error("second-eye-failure")end
  actors({width=1728,height=1728,groundY=0,project=function()end});return {eye=worlds}
 end}
local cards={begin=function()captures=captures+1;return true end,update=function()captures=captures+1 end,
 drawWorld=function()draws=draws+1 end,covers=function()return true end}
local battle=setmetatable({game={renderer={setWorldOverride=function(_,s)assert(s)end}}},{__index=Battle})
assert(host.begin(battle,provider,cards));host.install();host.update(.016)
local captured=captures;local updated=updates
battle:draw()
assert(worlds==2 and draws==3 and captures==captured and updates==updated)
assert(host.session.presented and queued[1]~=queued[2] and host.session.context.services.camera==nil)
failure=true;local ok,err=pcall(battle.draw,battle);assert(not ok and tostring(err):find("second%-eye%-failure"));assert(host.session.context.services.camera==nil and not host.session.presented)
host.finish("battle.ended");assert(not host.session)
local before=worlds;battle:draw();assert(worlds==before,"no stale arena after battle exit")
print("production battle host: original draw once, two eye-only arena/card draws, no recapture/update on eyes, scoped error restoration, exit reset passed")
