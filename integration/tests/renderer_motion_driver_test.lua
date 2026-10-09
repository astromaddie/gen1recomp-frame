local path=assert(arg[1])
for _,mode in ipairs({'complete','error','quit'}) do
 local now,presses,releases,restored=0,0,0,0
 local output={};local sources={};local held
 local p={px=0,py=0,cellX=22,cellY=19,moving=false,facing='up'}
 local map={id='PEWTER_CITY',isGrassCell=function()return false end,warpAtCell=function()end,isWarpTileCell=function()end,warpPadOrHoleAt=function()end}
 local world={player=p,map=map,camera={x=0,y=0},entities={}}
 local game={overworld=world,input={sources=sources,isDown=function(_,d)return sources[d] and next(sources[d])~=nil end},stack={top=function()return world end}}
 function game:gamepadpressed(_,button)local d=button:sub(3);sources[d]=sources[d] or {};sources[d]['pad:'..button]=true;held=d;presses=presses+1 end
 function game:gamepadreleased(_,button)local d=button:sub(3);if sources[d] then sources[d]['pad:'..button]=nil end;if held==d then held=nil end;releases=releases+1 end
 local quitCount=0;local originalQuit=function()quitCount=quitCount+1 end
 local love={quit=originalQuit,timer={getTime=function()return now end}}
 local T={isEnabled=function()return true end,startWindow=function()end,stopWindow=function()end,setPhase=function()end,sample=function()end,monotonicNs=function()return now*1e9 end,
 wrapCpu=function()return function()restored=restored+1 end end}
 local R={status=function()return {frame=math.floor(now*10)}end}
 local C={target=function(x,y)return x+1,y end,canMove=function()return true end}
 local U={wait=function(n)for _=1,n do coroutine.yield()end end}
 game.mods={exports={DRAMALESS_SHAPE={lib={require=function()return {}end}}}}
 local env=setmetatable({love=love,os={getenv=function(k)return k end},
 require=function(n)if n=='src.vr.Telemetry'then return T elseif n=='src.vr.Runtime'then return R elseif n=='src.world.Collision'then return C else return {}end end,
 loadfile=function(n)if n=='POKEPORT_SAVED_SCENE_DRIVER'then return function()return function()end end elseif n=='GEN1_FRAME_DRIVER_UTIL'then return function()return U end end end,
 print=function(...)local a={};for i=1,select('#',...)do a[i]=tostring(select(i,...))end;output[#output+1]=table.concat(a,' ')end},{__index=_G})
 local f=assert(loadfile(path));setfenv(f,env);local run=f();local co=coroutine.create(function()run(game)end)
 local failed=false
 for i=1,600 do
  now=now+.1
  if held then p.px=p.px+1;p.cellX=p.cellX+1;world.camera.x=world.camera.x+1;p.moving=true else p.moving=false end
  if mode=='error' and presses>0 then game.stack.top=function()return {}end end
  if mode=='quit' and presses>0 then love.quit();break end
  local ok=coroutine.resume(co)
  if not ok then failed=true;break end
 end
 assert(presses>0,'driver did not call gamepad callbacks')
 for _,s in pairs(sources)do assert(next(s)==nil,'input leaked on '..mode)end
 assert(love.quit==originalQuit and restored==10,'cleanup failed on '..mode)
 assert(releases>0)
 if mode=='error'then assert(failed) elseif mode=='quit'then assert(quitCount==1) else
  assert(not failed and coroutine.status(co)=='suspended')
  local text=table.concat(output,'\n');assert(text:find('measurement=complete') and text:find('phase=walk%-2') and text:find('monotonic_ns='))
 end
end
print('renderer motion completion/error/quit cleanup tests passed')
