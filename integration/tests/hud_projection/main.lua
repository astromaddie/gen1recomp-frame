local function load(path, ...) return assert(loadfile(path))(... ) end
local function save(canvas,name)
  love.graphics.setCanvas()
  local file=assert(io.open(assert(os.getenv("POKEPORT_TEST_OUTPUT")).."/"..name..".png","wb"))
  file:write(canvas:newImageData():encode("png"):getString());file:close()
end
local function blank(w,h)
  local target=love.graphics.newCanvas(w,h,{format="rgba8",dpiscale=1})
  love.graphics.setCanvas(target);love.graphics.clear(0.12,0.05,0.16,1)
  love.graphics.setCanvas();return target
end
local function centroid(canvas,kind)
  love.graphics.setCanvas()
  local data=canvas:newImageData()
  local count,sx,sy=0,0,0
  for y=0,data:getHeight()-1 do for x=0,data:getWidth()-1 do
    local r,g,b=data:getPixel(x,y)
    if (kind=="map" and g>0.8 and r<0.1 and b<0.1)
      or (kind=="dialog" and r>0.8 and g<0.1 and b<0.1) then
      count=count+1;sx=sx+x+0.5;sy=sy+y+0.5
    end
  end end
  assert(count>25,"missing "..kind.." pixels")
  return sx/count,sy/count
end
local function rotate(q,x,y,z)
  local tx,ty,tz=2*(q.y*z-q.z*y),2*(q.z*x-q.x*z),2*(q.x*y-q.y*x)
  return {x=x+q.w*tx+q.y*tz-q.z*ty,y=y+q.w*ty+q.z*tx-q.x*tz,
    z=z+q.w*tz+q.x*ty-q.y*tx}
end
local function planePoint(view,x,y)
  local f=view.fov
  local ray=rotate(view.orientation,math.tan(f.left)+(x/512)*(math.tan(f.right)-math.tan(f.left)),
    math.tan(f.up)-(y/512)*(math.tan(f.up)-math.tan(f.down)),-1)
  local t=(-2-view.position.z)/ray.z
  return {x=view.position.x+t*ray.x,y=view.position.y+t*ray.y,z=-2}
end

function love.load()
  local kit=assert(os.getenv("POKEPORT_TEST_KIT"))
  local engine=assert(os.getenv("POKEPORT_TEST_ENGINE"))
  local mod=assert(os.getenv("POKEPORT_TEST_VOXEL"))
  local views,submitted
  local bridge={create=function()return true end,destroy=function()end,
    status=function()return {ready=true,focused=true}end,
    beginFrame=function()return views[1],views[2],true end,
    submitCanvases=function(l,r)submitted={l,r};return true end,
    abortFrame=function()end}
  package.loadlib=function()return function()return bridge end end
  local Runtime=load(kit.."/integration/src/vr/Runtime.lua")
  package.loaded["src.vr.Runtime"]=Runtime
  package.loaded["src.vr.MonoPanel"]=load(kit.."/integration/src/vr/MonoPanel.lua")
  for _,name in ipairs({"Zoom","Tilt","Pipelines","PixelCanvas"}) do
    package.loaded["src.render."..name]={}
  end
  package.loaded["src.mods.Runtime"]={}
  package.loaded["src.core.GameVersion"]={get=function()return "yellow"end}
  for _,name in ipairs({"src.world.Collision","src.world.FieldDefaults","src.render.SpriteRenderer"})do
    package.loaded[name]={}
  end
  local Player=load(engine.."/src/world/Player.lua")
  package.loaded["src.render.PaletteFX"]=load(engine.."/src/render/PaletteFX.lua")
  local Renderer=load(engine.."/src/render/Renderer.lua")
  package.loaded["src.render.Renderer"]=Renderer
  local Minimap=load(mod.."/lib/Minimap.lua",{require=function(name)
    assert(name=="ModSetting")
    return {new=function()return {get=function()return true end}end}
  end})
  local player=setmetatable({cellX=5,cellY=5,px=80,py=80,facing="down",
    surfing=true,spinning=true,bobTimer=15,spinTimer=0,surfSprite={},sprite={}},Player)
  local state={player=player,entities={player},map={id="test",renderer={drawMapOnly=function()
    love.graphics.clear(0,1,0,1)
  end}}}
  local shot
  local game={stack={top=function()return state end},mods={exports={DRAMATIC_SHAPE={lib={require=function(name)
    if name=="Minimap" then return Minimap end
    assert(name=="OverworldBattle");return {shot=function()return shot end}
  end}}}}}
  game.overworld=state
  package.loaded["src.core.Game"]=game
  local Presentation=load(kit.."/integration/src/vr/GamePresentation.lua")
  local originalMap,originalUI=Minimap.draw,Renderer.compositeUi
  -- Execute the exact pinned finishStereo closure (with its private pending
  -- pair supplied), including its real battle-copy and UI/queue behavior.
  local sourceFile=assert(io.open(mod.."/main.lua","rb"))
  local modSource=sourceFile:read("*a");sourceFile:close()
  local first=assert(modSource:find("local function copyBattleShotToEye",1,true))
  local last=assert(modSource:find("-- BattleState can draw",first,true))
  local finishFactory=assert(loadstring("local OverworldBattle,Runtime,pendingStereo=...\n"
    ..modSource:sub(first,last-1).."\nreturn finishStereo","pinned-finishStereo"))
  local function finishFor(eyes)
    return finishFactory({shot=function()return shot end},Runtime,{left=eyes[1],right=eyes[2]})
  end
  -- Use the exact pose gathering function called by both real VRStereo
  -- passes; surrounding terrain work is irrelevant to timer advancement.
  local sceneFile=assert(io.open(mod.."/lib/VoxelScene.lua","rb"))
  local sceneSource=sceneFile:read("*a");sceneFile:close()
  local pa=assert(sceneSource:find("local function posesOf(",1,true))
  local pb=assert(sceneSource:find("-- ------- the glint",pa,true))
  local posesOf=assert(loadstring("local groundAt=function()return 0 end\n"
    ..sceneSource:sub(pa,pb-1).."\nreturn posesOf"))()
  local gathered={}
  local Voxel3D={beginScene=function()end}
  local stereoModules={Voxel3D=Voxel3D,CameraMode={},ShadowMap={},
    FirstPerson={engaged=function()return false end,endFrame=function()end,adoptVReye=function()end},
    VoxelScene={render=function(state)
      local _,me=posesOf(state,function()return {}end)
      gathered[#gathered+1]=me
      return me
    end}}
  local VRStereo=load(mod.."/lib/VRStereo.lua",{require=function(name)return assert(stereoModules[name])end})
  local poseView={eye={0,0,0},focus={0,0,-1},fov=1}
  local function twoEyePoses()
    gathered={}
    assert(VRStereo.render(state,512,512,160,144,nil,poseView,"vr-left",{}))
    assert(VRStereo.render(state,512,512,160,144,nil,poseView,"vr-right",{}))
    return gathered[1],gathered[2]
  end
  local beforeBob,beforeSpin=player.bobTimer,player.spinTimer
  twoEyePoses()
  assert(player.bobTimer==(beforeBob+2)%32 and player.spinTimer==beforeSpin+2,
    "baseline actual stereo pose collection must expose double advancement")
  player.bobTimer,player.spinTimer=beforeBob,beforeSpin
  local ui=love.graphics.newCanvas(160,144,{format="rgba8",dpiscale=1})
  love.graphics.setCanvas(ui);love.graphics.clear(0,0,0,0)
  love.graphics.setColor(1,0,0,1);love.graphics.rectangle("fill",0,104,160,40)
  love.graphics.setColor(1,1,1,1);love.graphics.setCanvas()
  Renderer.uiComposite={canvas=ui,sx=4,sy=4,vpw=640,vph=576,ww=800,wh=600,vrScale=0.2}
  Runtime.setEnabled(true);assert(Runtime.start())
  local baselineMismatch
  for _,degrees in ipairs({0,30,90,-45}) do
    local a=math.rad(degrees)/2
    local q={x=0,y=0,z=math.sin(a),w=math.cos(a)}
    views={}
    for i,x in ipairs({-0.032,0.032}) do views[i]={position=rotate(q,x,0,0),orientation=q,
      fov={left=i==1 and -0.95 or -0.7,right=i==1 and 0.7 or 0.95,up=0.8,down=-0.6},
      width=512,height=512} end
    assert(Runtime.beginFrame(800,600))
    local eyes={blank(512,512),blank(512,512)}
    if degrees==0 then
      local positions={}
      for i,target in ipairs(eyes) do
        Minimap.draw(state,{size=function()return 512,512 end,canvas=function()return target end})
        Renderer:compositeUi(target)
        positions[i]=planePoint(views[i],centroid(target,"map"))
        save(target,"baseline-"..i)
      end
      baselineMismatch=math.abs(positions[1].x-positions[2].x)
      assert(baselineMismatch>0.5,"baseline must expose reference texture-space binocular mismatch")
      eyes={blank(512,512),blank(512,512)}
    end
    Presentation.beginDraw(game)
    local bob,spin=player.bobTimer,player.spinTimer
    local leftPose,rightPose=twoEyePoses()
    for _,key in ipairs({"sprite","px","py","facing","phase","flip","gh","lift"})do
      assert(leftPose[key]==rightPose[key],"both eye poses must match: "..key)
    end
    assert(player.bobTimer==(bob+1)%32 and player.spinTimer==spin+1,
      "actual Player:pose timers must advance once across the two eyes")
    for _,target in ipairs(eyes) do
      Minimap.draw(state,{size=function()return 512,512 end,canvas=function()return target end})
    end
    Presentation.endDraw()
    assert(Minimap.draw==originalMap,"restore minimap function after world draw")
    assert(rawget(player,"pose")==nil and player.pose==Player.pose,"restore inherited Player method")
    local handled=Presentation.finish(game,finishFor(eyes),blank(800,600))
    assert(handled and Renderer.compositeUi==originalUI,"restore renderer after finish")
    for _,kind in ipairs({"map","dialog"}) do
      local positions={}
      for i,target in ipairs(eyes) do
        positions[i]=planePoint(views[i],centroid(target,kind))
        -- At the shared plane, both original HUD elements remain within
        -- +/-30 degrees horizontally/vertically around the forward view.
        assert(math.abs(positions[i].x)<2*math.tan(math.rad(30)))
        assert(math.abs(positions[i].y)<2*math.tan(math.rad(30)))
      end
      -- Four raster texels at this resolution span under 4cm on the plane.
      assert(math.abs(positions[1].x-positions[2].x)<0.04,kind.." stereo horizontal mismatch")
      assert(math.abs(positions[1].y-positions[2].y)<0.04,kind.." stereo vertical mismatch")
    end
    for i,target in ipairs(eyes)do save(target,"corrected-roll"..degrees.."-"..i)end
    assert(Runtime.flush())
  end
  -- A pure overworld frame may have no dialogue/menu UI descriptor; the
  -- independently captured minimap still has to be projected into both eyes.
  assert(Runtime.beginFrame(800,600))
  local savedUI=Renderer.uiComposite;Renderer.uiComposite=nil
  local mapOnly={blank(512,512),blank(512,512)}
  Presentation.beginDraw(game);Minimap.draw(state);Presentation.endDraw()
  assert(Presentation.finish(game,finishFor(mapOnly),blank(800,600)))
  for _,target in ipairs(mapOnly)do centroid(target,"map")end
  assert(Runtime.flush());Renderer.uiComposite=savedUI
  -- A staged battle uses the engine's finished original screen, even when
  -- the reference hook has queued two distinct canvases containing copies.
  assert(Runtime.beginFrame(800,600))
  Presentation.beginDraw(game);Presentation.endDraw()
  local mono=blank(800,600);shot={canvas=mono}
  local handled,mirror=Presentation.finish(game,finishFor({blank(512,512),blank(512,512)}),mono)
  assert(handled and mirror==mono)
  love.graphics.setCanvas() -- main.endVROutput unbinds before Runtime.flush
  local originalSubmit=Runtime.submit
  Runtime.submit=function(l,r,options)
    assert(l==mono and r==mono,"battle must queue the single finished original source")
    return originalSubmit(l,r,options)
  end
  assert(Runtime.flush())
  assert(submitted[1]~=submitted[2] and submitted[1]~=mono,"battle must project per eye")
  Runtime.submit=originalSubmit
  shot=nil
  local ok=pcall(Presentation.finish,game,function()error("test failure")end,mono)
  assert(not ok and Renderer.compositeUi==originalUI,"callback error must restore renderer")
  Runtime.shutdown()
  print(string.format("HUD_GPU_PASS: actual pinned Minimap/Renderer/finishStereo/Player.pose, original baseline mismatch=%.3fm; projected HUD/dialog rolls0/30/90/-45, alpha, once-per-frame pose timers, scope cleanup and mono battle dispatch",baselineMismatch))
  love.event.quit(0)
end

function love.errorhandler(message)
  io.stderr:write(tostring(message).."\n")
  return function()return 1 end
end
