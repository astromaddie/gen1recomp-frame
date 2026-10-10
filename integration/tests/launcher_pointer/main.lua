function love.load()
 io.stdout:setvbuf("no")
 love.errorhandler=function(e)io.stderr:write(tostring(e).."\n"..debug.traceback().."\n");return function()return 1 end end
 local kit=assert(os.getenv("POKEPORT_TEST_KIT"))
 local P=assert(loadfile(kit.."/integration/src/vr/MonoPanel.lua"))()
 local source=love.graphics.newCanvas(800,600)
 love.graphics.setCanvas({source,stencil=true});love.graphics.clear(.06,.09,.12,1)
 love.graphics.setColor(.18,.24,.3,1);love.graphics.rectangle("fill",80,220,640,130)
 love.graphics.setColor(1,1,1);love.graphics.setFont(love.graphics.newFont(32));love.graphics.print("Original launcher hit surface",120,260)
 local engine=os.getenv("POKEPORT_TEST_ENGINE")
 local importer
 if engine then
  assert(love.filesystem.getInfo("src/import/RomImporter.lua"),"run harness from a private assembled game")
  importer=require("src.import.RomImporter").new(function()end)
  source:release()
  local w,h=love.graphics.getDimensions()
  source=love.graphics.newCanvas(w,h)
  love.graphics.setCanvas({source,stencil=true})
  importer:update(0)
  importer._padCursorActive=true;importer._padCursor={x=w/2,y=h/2};importer._vrLaserCursor=true

 end
 love.graphics.setCanvas()
 local views={}
 for i,x in ipairs({-.032,.032})do views[i]={position={x=x,y=0,z=0},orientation={x=0,y=0,z=0,w=1},width=1024,height=1024,fov={left=i==1 and -.95 or -.7,right=i==1 and .7 or .95,up=.8,down=-.6}}end
 local sw,sh=source:getDimensions()
 local hit=P.hit(views,sw,sh,{valid=true,position={x=.15,y=-.3,z=-.25},orientation={x=0,y=0,z=0,w=1}})
 assert(hit and hit.inside);P.setPointer(hit)
 if importer then
  love.graphics.setCanvas({source,stencil=true})
  importer._padCursor.x,importer._padCursor.y=hit.x,hit.y
  importer:draw()
  love.graphics.setCanvas()
 end
 local l,r=P.render(source,views)
 for i,c in ipairs({l,r})do
  local data=c:newImageData();local x,y=P.project(views[i],hit.point)
  local a,b,d=data:getPixel(math.floor(x),math.floor(y));assert(b>.8 and d>.9,"dot must be above opaque panel")
  local f=assert(io.open(os.getenv("POKEPORT_TEST_OUTPUT").."/pointer-eye-"..i..".png","wb"));f:write(data:encode("png"):getString());f:close()
 end
 print("pointer rendered above opaque source in both asymmetric eyes")
 love.event.quit()
end
