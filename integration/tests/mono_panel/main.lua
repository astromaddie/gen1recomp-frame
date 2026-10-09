local function check(ok, why) assert(ok, why) end
local function save(data, name)
  local dir = assert(os.getenv("POKEPORT_TEST_OUTPUT"))
  local file = assert(io.open(dir .. "/" .. name .. ".png", "wb"))
  file:write(data:encode("png"):getString()); file:close()
end

function love.load()
  local kit = assert(os.getenv("POKEPORT_TEST_KIT"))
  local Panel = assert(loadfile(kit .. "/integration/src/vr/MonoPanel.lua"))()
  local bridge = assert(package.loadlib(assert(os.getenv("POKEPORT_XRBRIDGE")),
    "luaopen_xrbridge"))()
  local source = love.graphics.newCanvas(800,600,{format="rgba8",dpiscale=1})
  love.graphics.setCanvas(source)
  love.graphics.clear(0.08,0.08,0.08,1)
  love.graphics.setColor(1,0,0,1); love.graphics.rectangle("fill",0,0,800,120)
  love.graphics.setColor(0,0,1,1); love.graphics.rectangle("fill",0,480,800,120)
  love.graphics.setColor(1,1,1,1)
  love.graphics.setFont(love.graphics.newFont(42))
  love.graphics.print("TOP / upright",40,35)
  love.graphics.print("BOTTOM",40,505)
  love.graphics.circle("line",400,300,110)
  love.graphics.setCanvas()
  save(source:newImageData(),"panel-source")
  local views = {}
  for i,x in ipairs({-0.032,0.032}) do
    views[i] = {position={x=x,y=0,z=0},orientation={x=0,y=0,z=0,w=1},
      fov={left=i==1 and -0.95 or -0.7,right=i==1 and 0.7 or 0.95,
        up=0.8,down=-0.6},width=512,height=512}
  end
  love.graphics.setScissor(2,3,7,5)
  local left,right = Panel.render(source,views)
  local sx,sy,sw,sh = love.graphics.getScissor()
  check(sx==2 and sy==3 and sw==7 and sh==5,"mono panel must restore graphics state")
  love.graphics.setScissor()
  for i,eye in ipairs({left,right}) do
    local data=eye:newImageData()
    save(data,i==1 and "panel-left" or "panel-right")
    local v=views[i]
    local function sample(x,y)
      local l,r,u,d=math.tan(v.fov.left),math.tan(v.fov.right),
        math.tan(v.fov.up),math.tan(v.fov.down)
      local px=((x-v.position.x)/2-l)/(r-l)*512
      local py=(u-y/2)/(u-d)*512
      return data:getPixel(math.floor(px),math.floor(py))
    end
    local r,g,b=sample(0.7,0.6)
    check(r>0.95 and b<0.05,"physical panel top must be red in both eyes")
    r,g,b=sample(0.7,-0.6)
    check(b>0.95 and r<0.05,"physical panel bottom must be blue in both eyes")
    r,g,b=data:getPixel(1,1)
    check(r==0 and g==0 and b==0,"flat screen must not fill the eye projection")
    local target=love.graphics.newCanvas(512,512,{format="rgba8",dpiscale=1})
    check(bridge.testCanvasCopy(eye,target,i==1 and "left" or "right"),
      "production GPU copy must accept projected mono eyes")
    local dest=target:newImageData()
    for y=0,511,7 do
      for x=0,511,7 do
        local ar,ag,ab=data:getPixel(x,y)
        local br,bg,bb=dest:getPixel(x,511-y)
        check(math.abs(ar-br)<0.005 and math.abs(ag-bg)<0.005 and math.abs(ab-bb)<0.005,
          "compositor pixels must match projected UI after GL origin conversion")
      end
    end
    target:release()
  end
  -- Reuse exact frame poses through Runtime's production mono dispatch.
  local submitted
  local native = {create=function()return true end, destroy=function()end,
    beginFrame=function() return views[1],views[2],true end,
    status=function()return {ready=true,focused=true}end,
    submitCanvases=function(l,r) submitted={l,r}; return true end}
  local oldLoad=package.loadlib
  package.loadlib=function()return function()return native end end
  package.loaded["src.vr.MonoPanel"]=Panel
  local Runtime=assert(loadfile(kit.."/integration/src/vr/Runtime.lua"))()
  Runtime.setEnabled(true); check(Runtime.start(),"runtime start")
  check(Runtime.beginFrame(800,600),"runtime frame")
  check(Runtime.submit(source,source),"runtime mono projection submit")
  check(submitted and submitted[1]~=source and submitted[1]~=submitted[2],
    "same mono source must become distinct projected eye canvases")
  package.loadlib=oldLoad
  Runtime.shutdown()
  print("MONO_PANEL_GPU_PASS: real LOVE shader, margins, orientation, asymmetric FOV/IPD, native copy, Runtime dispatch/state")
  love.event.quit(0)
end

function love.errorhandler(message)
  io.stderr:write(tostring(message).."\n")
  return function() return 1 end
end
