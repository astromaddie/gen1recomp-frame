-- Scoped production composition: flat path, source effects and failure cleanup.
local root=assert(arg[1])
local active=true
local hudDistances={}
local events,colorKind={},nil
local Runtime={isBridgeActive=function()return active end,shouldRender=function()return true end,
 compositeHud=function(_,_,eye,distance)events[#events+1]="hud";hudDistances[eye]=distance or 2;return true end}
package.loaded['src.vr.Runtime']=Runtime
package.loaded['src.vr.DrawDistance']={begin=function()end,finish=function()end}
package.loaded['src.vr.DramalessStereo']={beginFrame=function()end,mode=function()return 'above'end}
local depth,veils,wipes,captures=0,0,0,0
local target={getDimensions=function()return 100,100 end}
local canvas={getWidth=function()return 100 end,getHeight=function()return 100 end,setFilter=function()end}
love={graphics=setmetatable({getDimensions=function()return 100,100 end,getPixelDimensions=function()return 100,100 end,
 newCanvas=function()return canvas end,push=function()depth=depth+1 end,pop=function()depth=depth-1 end,
 setColor=function(r)colorKind=r==0 and "fade" or "veil"end,
 rectangle=function()veils=veils+1;events[#events+1]=colorKind end},{__index=function()return function()end end})}
local failure
local Renderer={uiComposite={canvas={},ww=100,wh=100,vpw=80,vph=72,sx=5,sy=5}}
local original=function()captures=captures+1;return true end
Renderer.compositeUi=original
local wipe={style='shrink',prog=.5}
Renderer.battleWipe=wipe;Renderer.screenVeil={1,.25};Renderer.worldFadeAlpha=.4
Renderer.drawBattleWipe=function(self,value,w,h,ox,oy,vw,vh,sx,sy)
 assert(value==wipe and value.prog==.5 and w==100 and h==100 and ox==10 and oy==14)
 assert(vw==80 and vh==72 and sx==5 and sy==5)
 events[#events+1]="wipe";wipes=wipes+1;if failure then error('wipe failure')end
end
package.loaded['src.render.Renderer']=Renderer
local quality={renderDistanceSetting={get=function()return 16 end},setting={get=function()return 4 end}}
local game={mods={exports={DRAMALESS_SHAPE={lib={require=function(name)assert(name=='Quality');return quality end}}}}}
local P=assert(loadfile(root..'/GamePresentation.lua'))()
local function finish()Renderer:compositeUi(target);Renderer:compositeUi(target);return true,target end
P.beginDraw(game);P.endDraw();assert(P.finish(game,finish,target))
assert(wipes==2 and veils==4 and captures==1 and depth==0 and Renderer.compositeUi==original)
assert(hudDistances[1]==2 and hudDistances[2]==2,'nonbattle HUD distance changed')
assert(table.concat(events,",")=="fade,hud,wipe,veil,fade,hud,wipe,veil","source composition order changed")
package.loaded["src.vr.BattleStereo"]=assert(loadfile(root.."/BattleStereo.lua"))()
game.mods.exports.DRAMALESS_SHAPE.voxel2DBattleHost={session={presented=true}}
P.beginDraw(game);P.endDraw();assert(P.finish(game,finish,target))
assert(hudDistances[1]==1 and hudDistances[2]==1,"battle-specific plane was not selected")
game.mods.exports.DRAMALESS_SHAPE.voxel2DBattleHost.session=nil
failure=true;P.beginDraw(game);P.endDraw();local ok,err=pcall(P.finish,game,finish,target)
assert(not ok and tostring(err):find('wipe failure') and depth==0 and Renderer.compositeUi==original)
active=false;P.beginDraw(game);local before=wipes;assert(P.finish(game,finish,target))
assert(wipes==before and Renderer.compositeUi==original and depth==0,'flat path intercepted')
print('BATTLE_COMPOSITION_PASS original wipe/veil twice, UI once, flat unchanged, error scopes restored')

-- Production plane placement retains angular bounds while changing disparity.
local Panel=assert(loadfile(root..'/MonoPanel.lua'))()
local function qrotate(q,x,y,z)
 local tx,ty,tz=2*(q.y*z-q.z*y),2*(q.z*x-q.x*z),2*(q.x*y-q.y*x)
 return x+q.w*tx+q.y*tz-q.z*ty,y+q.w*ty+q.z*tx-q.x*tz,z+q.w*tz+q.x*ty-q.y*tx
end
for _,yaw in ipairs({0,.35,-.7})do for _,roll in ipairs({0,.25,-.8})do
 local q={x=math.sin(yaw/2)*math.sin(roll/2),y=math.sin(yaw/2)*math.cos(roll/2),z=math.cos(yaw/2)*math.sin(roll/2),w=math.cos(yaw/2)*math.cos(roll/2)}
 local views={}
 for i,x in ipairs({-.032,.032})do local a,b,c=qrotate(q,x,0,0);views[i]={position={x=a+.08,y=b+.03,z=c-.04},orientation=q,fov={left=-.95,right=.7,up=.8,down=-.6},width=1728,height=1728}end
 local far,near=Panel.placement(views,true),Panel.placement(views,true,1)
 assert(math.abs(near.scale-.5)<1e-9 and math.abs(far.scale-1)<1e-9)
 assert(math.abs(near.rx*near.ux+near.rz*near.uz)<1e-9,'HUD basis not orthogonal')
 assert(near.uy>0,'HUD must stay upright')
 local head={position={x=.08,y=.03,z=-.04},orientation=q,fov=views[1].fov,width=1728,height=1728}
 local a,b=Panel.vertices(head,far,1.9,1.425),Panel.vertices(head,near,.95,.7125)
 for j=1,4 do for k=1,2 do assert(math.abs(a[j][k]/a[j][4]-b[j][k]/b[j][4])<1e-9,'angular size changed')end end
 for _,v in ipairs(views)do local _,_,zf=Panel.project(v,far);local _,_,zn=Panel.project(v,near);assert(math.abs(zf-2)<1e-9 and math.abs(zn-1)<1e-9)end
end end
print('HUD_DEPTH_MATH_PASS 1m versus 2m, equal angular bounds, physical IPD/yaw/roll/translation, upright plane')
