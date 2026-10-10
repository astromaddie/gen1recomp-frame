-- Adapt the pinned mod's presentation hooks without changing its private
-- source or its UI artwork. All replacements are scoped to one draw/finish.
local Runtime = require("src.vr.Runtime")
local Presentation = {}
local frame, hud
local drawDistance
local telemetryResolved, telemetryRequested, telemetryModule = false, false, nil
local function diagnosticTelemetry()
  if not telemetryResolved then
    telemetryResolved = true
    pcall(function()
      telemetryRequested = os and os.getenv
        and os.getenv("POKEPORT_VR_TELEMETRY") == "1" or false
    end)
    if telemetryRequested then
      local ok, module = pcall(require, "src.vr.Telemetry")
      if ok and module.isEnabled() then telemetryModule = module end
    end
  end
  return telemetryModule
end

local function sceneName(game, lib)
  local mapId = game and game.overworld and game.overworld.map
      and game.overworld.map.id
  local cameraMode = "unknown"
  if lib then
    local ok, mode = pcall(function()
      if game.mods.exports.DRAMALESS_SHAPE then return require("src.vr.DramalessStereo").mode(lib) end
      return lib.require("CameraMode").mode()
    end)
    if ok and type(mode) == "string" then cameraMode = mode end
  end
  local identity = tostring(mapId or "unknown") .. "/" .. cameraMode
  if lib and game.mods.exports.DRAMALESS_SHAPE then
    local quality = lib.require("Quality")
    identity = identity .. "/rdist=" .. tostring(quality.renderDistanceSetting:get())
      .. "/res=" .. tostring(quality.setting:get())
  end
  return identity
end

local function library(game)
  local exports = game and game.mods and game.mods.exports
  local mod = exports and (exports.DRAMALESS_SHAPE or exports.DRAMATIC_SHAPE)
  return mod and mod.lib
end

function Presentation.endDraw()
  if drawDistance then drawDistance.finish() end
  if frame and frame.voxelScene
      and frame.voxelScene.render == frame.telemetrySceneRender then
    frame.voxelScene.render = frame.originalSceneRender
  end
  if frame and frame.voxelScene and frame.voxelScene.performanceMark==frame.performanceMark then
    frame.performanceMark(nil)
    frame.voxelScene.performanceMark=frame.previousPerformanceMark
  end
  if frame and frame.minimap and frame.minimap.draw == frame.captureMinimap then
    frame.minimap.draw = frame.drawMinimap
  end
  if frame and frame.player and frame.player.pose == frame.capturePose then
    frame.player.pose = frame.ownPose
  end
end

function Presentation.beginDraw(game)
  Presentation.endDraw()
  frame = nil
  if game and game.mods and game.mods.exports and game.mods.exports.DRAMALESS_SHAPE then
    require("src.vr.DramalessStereo").beginFrame()
  end
  if not Runtime.isBridgeActive() or not Runtime.shouldRender() then return end
  local lib = library(game)
  if not lib then return end
  local telemetry = diagnosticTelemetry()
  local scene = sceneName(game, lib)
  if telemetry then telemetry.setScene(scene);telemetry.recordSettings(game,lib) end
  drawDistance = drawDistance or require("src.vr.DrawDistance")
  drawDistance.begin(lib)
  local minimap
  if not game.mods.exports.DRAMALESS_SHAPE then minimap = lib.require("Minimap") end
  local w,h = love.graphics.getDimensions()
  if love.graphics.getPixelDimensions then w,h = love.graphics.getPixelDimensions() end
  if not hud or hud:getWidth() ~= w or hud:getHeight() ~= h then
    if hud then hud:release() end
    hud = love.graphics.newCanvas(w,h,{format="rgba8",dpiscale=1})
    hud:setFilter("nearest","nearest")
  end
  love.graphics.push("all")
  love.graphics.setCanvas(hud)
  love.graphics.clear(0,0,0,0)
  love.graphics.pop()
  frame = {minimap=minimap,drawMinimap=minimap and minimap.draw,source=hud,width=w,height=h,
    telemetry=telemetry,scene=scene,sourceEye=0}
  if telemetry then
    local voxelScene = lib.require("VoxelScene")
    local originalRender = voxelScene.render
    local function pack(...) return {n=select("#",...),...} end
    frame.voxelScene,frame.originalSceneRender = voxelScene,originalRender
    frame.previousPerformanceMark=voxelScene.performanceMark
    local phaseScope
    frame.performanceMark=function(name)
      telemetry.endCpuScope(phaseScope)
      phaseScope=name and telemetry.beginCpuScope(name) or nil
    end
    voxelScene.performanceMark=frame.performanceMark
    frame.telemetrySceneRender = function(...)
      frame.sourceEye = frame.sourceEye + 1
      local token = telemetry.beginGpuScope(
        "source_scene_eye" .. tostring(frame.sourceEye), frame.scene)
      local cpu=telemetry.beginCpuScope("mod_scene")
      local result = pack(pcall(originalRender,...))
      frame.performanceMark(nil)
      telemetry.endCpuScope(cpu)
      telemetry.endGpuScope(token)
      if not result[1] then error(result[2],0) end
      return unpack(result,2,result.n)
    end
    voxelScene.render = frame.telemetrySceneRender
  end
  local player = game.overworld and game.overworld.player
  if player and type(player.pose) == "function" then
    local originalPose, ownPose = player.pose, rawget(player,"pose")
    local cached
    local function pack(...) return {n=select("#",...),...} end
    frame.player,frame.ownPose = player,ownPose
    frame.capturePose = function(self,...)
      if not cached then cached = pack(originalPose(self,...)) end
      return unpack(cached,1,cached.n)
    end
    -- Player:pose advances surf/spinner timers on draw. Both eyes and any
    -- same-frame shadow/flat pass must consume that one result. Updates and
    -- NPC methods stay untouched; the instance override ends with this draw.
    player.pose = frame.capturePose
  end
  frame.captureMinimap = function(state)
    if frame.minimapDrawn then return end
    frame.minimapDrawn = true
    -- The existing implementation owns layout, tile art, player marker,
    -- palette and alpha. Only its destination and screen size change.
    frame.drawMinimap(state, {
      size=function() return w,h end,
      canvas=function() return hud end,
    })
  end
  if minimap then minimap.draw = frame.captureMinimap end
end

local function stagedBattle(game)
  local lib = library(game)
  if not lib then return false end
  if game.mods.exports.DRAMALESS_SHAPE then
    local host = game.mods.exports.DRAMALESS_SHAPE.voxel2DBattleHost
    -- The public mod stages battles through the engine world override.
    return host and host.session and host.session.presented == true
  end
  local shot = lib.require("OverworldBattle").shot()
  return shot and shot.canvas ~= nil
end

-- Preserve the source ordering: world fade, original UI, wipe, palette veil.
local function surfaceEffect(target,draw)
  love.graphics.push("all")
  local ok,err=pcall(function()
    love.graphics.setCanvas(target)
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setScissor()
    love.graphics.setStencilTest()
    love.graphics.setDepthMode()
    love.graphics.setColorMask(true,true,true,true)
    love.graphics.setBlendMode("alpha","alphamultiply")
    draw(target:getDimensions())
  end)
  love.graphics.pop()
  if not ok then error(err,0) end
end

function Presentation.finish(game, finish, monoCanvas)
  if not frame or not Runtime.isBridgeActive() or not Runtime.shouldRender() then return finish() end
  local Renderer = require("src.render.Renderer")
  local original = Renderer.compositeUi
  local staged=stagedBattle(game)
  local battle = staged and not game.mods.exports.DRAMALESS_SHAPE
  local hudDistance=staged and game.mods.exports.DRAMALESS_SHAPE
    and require("src.vr.BattleStereo").HUD_DISTANCE or nil
  local eye = 0
  Renderer.compositeUi = function(self, target)
    if battle then return true end
    if not frame.uiDrawn then
      local ui = self.uiComposite
      if ui and ui.canvas then
        local copy = {}
        for key,value in pairs(ui) do copy[key]=value end
        -- Physical screen geometry now sets angular size. Preserve the
        -- original desktop layout instead of the old 20%-of-eye-texture UI.
        copy.vrScale, copy.vrPlacement, copy.vrPixelSnap = 1, "center", false
        self.uiComposite = copy
        love.graphics.push("all")
        love.graphics.origin()
        local ok,result = pcall(original,self,frame.source)
        love.graphics.pop()
        self.uiComposite = ui
        if not ok then error(result,0) end
      end
      frame.uiDrawn = true
    end
    eye = eye + 1
    assert(eye <= 2,"unexpected extra eye UI composite")
    if self.worldFadeAlpha and self.worldFadeAlpha>0 then
      surfaceEffect(target,function(w,h)
        love.graphics.setColor(0,0,0,self.worldFadeAlpha)
        love.graphics.rectangle("fill",0,0,w,h)
      end)
    end
    local result = Runtime.compositeHud(frame.source,target,eye,hudDistance)
    -- Source endFrame paints these after its UI snapshot. Repeat only their
    -- drawing over each finished eye; state/timers still advance once.
    local wipe,veil=self.battleWipe,self.screenVeil
    if wipe or (veil and veil[2]>0) then
      surfaceEffect(target,function(w,h)
        local ui=self.uiComposite
        if wipe and ui then
          local fit=math.min(w/ui.ww,h/ui.wh)
          local vw,vh=ui.vpw*fit,ui.vph*fit
          self:drawBattleWipe(wipe,w,h,(w-vw)/2,(h-vh)/2,vw,vh,ui.sx*fit,ui.sy*fit)
        end
        if veil and veil[2]>0 then
          love.graphics.setColor(veil[1],veil[1],veil[1],veil[2])
          love.graphics.rectangle("fill",0,0,w,h)
        end
      end)
    end
    return result
  end
  local ok,handled,mirror = pcall(finish)
  Renderer.compositeUi = original
  if not ok then error(handled,0) end
  if battle then
    -- Game:draw already composed the mono arena and original battle UI.
    -- Let the mod finish/clear its pending pair, then replace only its queue.
    -- The final source uses the same shared plane as every other mono screen.
    Runtime.queue(monoCanvas,monoCanvas)
    return true,monoCanvas
  end
  return handled,mirror
end

return Presentation
