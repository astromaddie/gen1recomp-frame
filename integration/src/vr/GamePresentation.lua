-- Adapt the pinned mod's presentation hooks without changing its private
-- source or its UI artwork. All replacements are scoped to one draw/finish.
local Runtime = require("src.vr.Runtime")
local Presentation = {}
local frame, hud
local drawDistance

local function library(game)
  local exports = game and game.mods and game.mods.exports
  local mod = exports and exports.DRAMATIC_SHAPE
  return mod and mod.lib
end

function Presentation.endDraw()
  if drawDistance then drawDistance.finish() end
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
  if not Runtime.isBridgeActive() or not Runtime.shouldRender() then return end
  local lib = library(game)
  if not lib then return end
  drawDistance = drawDistance or require("src.vr.DrawDistance")
  drawDistance.begin(lib)
  local minimap = lib.require("Minimap")
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
  frame = {minimap=minimap,drawMinimap=minimap.draw,source=hud,width=w,height=h}
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
  minimap.draw = frame.captureMinimap
end

local function stagedBattle(game)
  local lib = library(game)
  if not lib then return false end
  local shot = lib.require("OverworldBattle").shot()
  return shot and shot.canvas ~= nil
end

function Presentation.finish(game, finish, monoCanvas)
  if not frame or not Runtime.isBridgeActive() or not Runtime.shouldRender() then return finish() end
  local Renderer = require("src.render.Renderer")
  local original = Renderer.compositeUi
  local battle = stagedBattle(game)
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
    return Runtime.compositeHud(frame.source,target,eye)
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
