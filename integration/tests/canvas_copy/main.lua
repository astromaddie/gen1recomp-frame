local bridge
local finished = false

local function requireTest(condition, message)
  if not condition then
    io.stderr:write("CANVAS_COPY_TEST_FAIL: " .. message .. "\n")
    error(message, 0)
  end
end

local function closeColor(a, b)
  return math.abs(a - b) <= (1 / 255 + 0.0001)
end

function love.load()
  local modulePath = assert(os.getenv("POKEPORT_XRBRIDGE"),
    "POKEPORT_XRBRIDGE must name the XRBRIDGE_TESTING module")
  local loaded, factory = pcall(package.loadlib, modulePath, "luaopen_xrbridge")
  requireTest(loaded and type(factory) == "function",
    "could not load test xrbridge: " .. tostring(factory))
  bridge = factory()
  requireTest(type(bridge.testCanvasCopy) == "function",
    "native module lacks the test-only production Canvas copy hook")

  local source = love.graphics.newCanvas(16, 12, {
    dpiscale = 1, format = "rgba8", readable = true,
  })
  local target = love.graphics.newCanvas(16, 12, {
    dpiscale = 1, format = "rgba8", readable = true,
  })
  local colors = {
    { 1, 0, 0, 1 }, { 0, 1, 0, 1 },
    { 0, 0, 1, 1 }, { 1, 1, 0, 1 },
  }
  love.graphics.setCanvas(source)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setColor(colors[1]); love.graphics.rectangle("fill", 0, 0, 8, 6)
  love.graphics.setColor(colors[2]); love.graphics.rectangle("fill", 8, 0, 8, 6)
  love.graphics.setColor(colors[3]); love.graphics.rectangle("fill", 0, 6, 8, 6)
  love.graphics.setColor(colors[4]); love.graphics.rectangle("fill", 8, 6, 8, 6)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setCanvas()

  -- Exercise and verify the raw-GL state handoff that the production module
  -- must preserve for the next LOVE draw pass.
  love.graphics.setScissor(2, 3, 7, 5)
  love.graphics.setColorMask(true, false, true, false)
  local sx, sy, sw, sh = love.graphics.getScissor()
  local r, g, b, a = love.graphics.getColorMask()

  local dumpDirectory = os.getenv("POKEPORT_XR_PROBE_DUMP_DIR")
  local copied, detail = bridge.testCanvasCopy(source, target,
    dumpDirectory and "left" or nil)
  requireTest(copied, "native GPU Canvas copy failed: " .. tostring(detail))
  local afterX, afterY, afterW, afterH = love.graphics.getScissor()
  local afterR, afterG, afterB, afterA = love.graphics.getColorMask()
  requireTest(sx == afterX and sy == afterY and sw == afterW and sh == afterH,
    "native Canvas copy changed LOVE's cached scissor state")
  requireTest(r == afterR and g == afterG and b == afterB and a == afterA,
    "native Canvas copy changed LOVE's color mask")

  if dumpDirectory then
    local copiedRight, rightDetail = bridge.testCanvasCopy(source, target, "right")
    requireTest(copiedRight, "native right-eye dump failed: " .. tostring(rightDetail))
    local status = bridge.status()
    requireTest(status.swapchainDumpCount == 2,
      "native diagnostic must report one successful dump per eye")
    local function checkDump(eye)
      local file = assert(io.open(dumpDirectory .. "/xr-" .. eye .. ".ppm", "rb"),
        "native swapchain diagnostic did not create the " .. eye .. " eye dump")
      local bytes = file:read("*a")
      file:close()
      requireTest(bytes:find("P6\n# eye=" .. eye .. "\n", 1, true) == 1,
        "native eye dump is missing PPM metadata")
      local marker = assert(bytes:find("\n255\n", 1, true),
        "native eye dump has no PPM pixel header")
      local pixels = bytes:sub(marker + 5)
      requireTest(#pixels == 16 * 12 * 3,
        "native eye dump pixel dimensions do not match its header")
      -- The source is upper-left red/green and lower-left blue/yellow. PPM
      -- output must keep the same top-left row order after glReadPixels.
      local function pixel(x, y)
        local offset = (y * 16 + x) * 3 + 1
        return pixels:byte(offset, offset + 2)
      end
      local tr, tg, tb = pixel(1, 1)
      local br, bg, bb = pixel(1, 10)
      requireTest(tr > 240 and tg < 16 and tb < 16,
        "native eye dump top-left orientation/color is incorrect")
      requireTest(br < 16 and bg < 16 and bb > 240,
        "native eye dump lower-left orientation/color is incorrect")
    end
    checkDump("left")
    checkDump("right")
  end

  love.graphics.setScissor()
  love.graphics.setColorMask()

  -- A table with Canvas-shaped fields is not a native Canvas. The production
  -- entry point must reject it before interpreting any userdata as love::Proxy.
  local accepted = bridge.testCanvasCopy({}, target)
  requireTest(not accepted, "native Canvas copy accepted non-Canvas input")

  local sourceData = source:newImageData()
  local targetData = target:newImageData()
  for y = 0, 11 do
    for x = 0, 15 do
      local sr, sg, sb, sa = sourceData:getPixel(x, y)
      local tr, tg, tb, ta = targetData:getPixel(x, y)
      requireTest(closeColor(sr, tr) and closeColor(sg, tg)
          and closeColor(sb, tb) and closeColor(sa, ta),
        string.format("Canvas copy mismatch at %d,%d", x, y))
    end
  end

  print("CANVAS_COPY_TEST_PASS: pixel orientation, content, scissor, color mask, type guard")
  source:release()
  target:release()
  finished = true
  love.event.quit(0)
end

function love.update()
  if finished then love.event.quit(0) end
end

function love.draw() end
