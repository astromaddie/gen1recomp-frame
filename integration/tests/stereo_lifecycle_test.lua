local path=assert(arg[1])
local focused,fail,open,beginCount,endCount=true,false,false,0,0
local oldCamera={};local oldBegin=function()end;local adopted
local camera={eye={0,10,10},focus={0,0,0},up={0,1,0},width=1728,height=1728}
local graphics={camera=oldCamera,beginScene=oldBegin,beginOverlay=function()return false end,endScene=function()end}
local scene={glintStep=function()return {}end,beginStereoFrame=function()assert(not open);open=true;beginCount=beginCount+1 end,
 endStereoFrame=function()open=false;endCount=endCount+1 end,
 render=function()assert(open);if fail then error('injected eye error')end;return {}end}
local step=scene.glintStep
local modules={Voxel3D=graphics,VoxelScene=scene,FirstPerson={adoptTrackedEye=function(x)adopted=x end},
 AntiAlias={expand=function(w,h)return w,h end,resolve=function(c)return c end},ShadowMap={cancel=function()end}}
local V={require=function(name)return assert(modules[name],name)end}
local runtime={views=function()if focused then return camera,camera end end}
package.loaded['src.vr.Runtime']=runtime
local shadowOpen=false
package.loaded['src.vr.ShadowOptimization']={begin=function()shadowOpen=true end,finish=function()shadowOpen=false end,status=function()return {}end}
package.loaded['src.vr.Telemetry']={isEnabled=function()return false end,recordShadows=function()end}
local Stereo=assert(loadfile(path))();Stereo.baseCamera=function()return {aspect=1}end
local ctx={state={},width=1728,height=1728,vw=160,vh=144}
for _,errorMode in ipairs({false,true,false})do
 fail=errorMode;local ok=pcall(Stereo.drawWorld,V,ctx);assert(ok~=fail)
 assert(not open and not shadowOpen and not adopted)
 assert(graphics.camera==oldCamera and graphics.beginScene==oldBegin and scene.glintStep==step)
end
focused=false;assert(Stereo.drawWorld(V,ctx)==nil)
assert(beginCount==3 and endCount==3,'nonrenderable pair opened shared preparation')
print('production stereo shared preparation success/error/nonrenderable cleanup passed')
