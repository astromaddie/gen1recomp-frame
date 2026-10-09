-- Existing flat screens on a shared physical plane, rendered into the normal
-- eye projection layer. No compositor quad and no desktop-aspect stretch.
local Panel = {}
local anchor, shader, mesh
local targets = {}
local DISTANCE, WIDTH = 2, 1.9

local function rotate(q, x, y, z)
  local tx, ty, tz = 2 * (q.y * z - q.z * y),
    2 * (q.z * x - q.x * z), 2 * (q.x * y - q.y * x)
  return x + q.w * tx + q.y * tz - q.z * ty,
    y + q.w * ty + q.z * tx - q.x * tz,
    z + q.w * tz + q.x * ty - q.y * tx
end

function Panel.reset() anchor = nil end

function Panel.placement(views, followPitch)
  local first, second = views[1], views[2]
  local fx, fy, fz = rotate(first.orientation, 0, 0, -1)
  local horizontal = math.sqrt(fx * fx + fz * fz)
  local rx, rz = 1, 0
  if horizontal > 1e-6 then rx, rz = -fz / horizontal, fx / horizontal end
  if not followPitch then fx, fy, fz = rz, 0, -rx end
  return {
    x = (first.position.x + second.position.x) / 2 + fx * DISTANCE,
    y = (first.position.y + second.position.y) / 2 + fy * DISTANCE,
    z = (first.position.z + second.position.z) / 2 + fz * DISTANCE,
    rx = rx, rz = rz,
    ux = -rz * fy, uy = rz * fx - rx * fz, uz = rx * fy,
  }
end

-- Exposed geometry is also used by the GPU path. Homogeneous positions retain
-- perspective-correct texture interpolation when viewing the panel obliquely.
function Panel.vertices(view, placement, width, height)
  local f = assert(view.fov, "mono panel requires the current eye FOV")
  local l, r, u, d = math.tan(f.left), math.tan(f.right),
    math.tan(f.up), math.tan(f.down)
  assert(r > l and u > d, "invalid mono panel FOV")
  local p, q = view.position, view.orientation
  local inverse = { x = -q.x, y = -q.y, z = -q.z, w = q.w }
  local result = {}
  for _, uv in ipairs({ {0, 0}, {1, 0}, {1, 1}, {0, 1} }) do
    local x = (uv[1] - 0.5) * width
    local y = (0.5 - uv[2]) * height
    local ex, ey, ez = rotate(inverse,
      placement.x + placement.rx * x + (placement.ux or 0) * y - p.x,
      placement.y + (placement.uy or 1) * y - p.y,
      placement.z + placement.rz * x + (placement.uz or 0) * y - p.z)
    local w = -ez
    result[#result + 1] = {
      (2 * ex - (r + l) * w) / (r - l),
      -(2 * ey - (u + d) * w) / (u - d), -- LOVE Canvas Y convention
      0, w, uv[1], uv[2],
    }
  end
  return result
end

local function draw(source, view, target, placement, overlay)
  local sw, sh = source:getDimensions()
  -- Fit tall screens too, preserving the entire original desktop layout.
  local width = math.min(WIDTH, WIDTH * sw / sh)
  local height = width * sh / sw
  if not shader then
    shader = love.graphics.newShader([[
      vec4 position(mat4 transform_projection, vec4 vertex_position) {
        return vertex_position;
      }
    ]])
    mesh = love.graphics.newMesh({
      { "VertexPosition", "float", 4 }, { "VertexTexCoord", "float", 2 },
    }, 4, "fan", "stream")
  end
  love.graphics.push("all")
  local ok, err = pcall(function()
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setColorMask(true, true, true, true)
    love.graphics.setDepthMode()
    love.graphics.setMeshCullMode("none")
    love.graphics.setBlendMode(overlay and "alpha" or "replace", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(shader)
    mesh:setTexture(source)
    love.graphics.setCanvas(target)
    if not overlay then love.graphics.clear(0, 0, 0, 1) end
    mesh:setVertices(Panel.vertices(view, placement, width, height))
    love.graphics.draw(mesh)
  end)
  love.graphics.pop()
  if not ok then error(err, 0) end
end

function Panel.render(source, views)
  assert(views and views[1] and views[2], "mono panel requires both frame views")
  if not anchor then anchor = Panel.placement(views, false) end
  for i, view in ipairs(views) do
      local w, h = assert(view.width), assert(view.height)
      local target = targets[i]
      if not target or target:getWidth() ~= w or target:getHeight() ~= h then
        if target then target:release() end
        target = love.graphics.newCanvas(w, h, { dpiscale = 1, format = "rgba8" })
        targets[i] = target
      end
      draw(source, view, target, anchor, false)
  end
  return targets[1], targets[2]
end

-- HUD follows yaw/pitch, stays level with gravity, and is projected with the
-- full eye pose (including roll). Transparent pixels leave the world intact.
function Panel.composite(source, views, eyeIndex, target)
  draw(source, views[eyeIndex], target, Panel.placement(views, true), true)
end

function Panel.release()
  Panel.reset()
  for _, target in pairs(targets) do target:release() end
  targets = {}
  if mesh then mesh:release(); mesh = nil end
  if shader then shader:release(); shader = nil end
end

return Panel
