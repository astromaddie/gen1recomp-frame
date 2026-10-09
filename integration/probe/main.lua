local bridge
local leftCanvas
local rightCanvas
local exitAfter = 15
local startedAt = 0
local nextStatusLog = 0
local dryRun = false
local dumpedEyes = false
local dumpDirectory
local lastViews
local firstSubmitLogged = false
local maxDiagnosticPixels = 8 * 1024 * 1024

local function env(name)
  return os.getenv(name)
end

local function makeEyeCanvas(width, height, colors, label)
  local canvas = love.graphics.newCanvas(width, height, {
    dpiscale = 1,
    format = "rgba8",
    readable = true,
  })
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.025, 0.025, 0.04, 1)
  local halfWidth = math.floor(width / 2)
  local halfHeight = math.floor(height / 2)
  local rects = {
    { 0, 0, halfWidth, halfHeight },
    { halfWidth, 0, width - halfWidth, halfHeight },
    { 0, halfHeight, halfWidth, height - halfHeight },
    { halfWidth, halfHeight, width - halfWidth, height - halfHeight },
  }
  for i, rect in ipairs(rects) do
    love.graphics.setColor(colors[i])
    love.graphics.rectangle("fill", rect[1], rect[2], rect[3], rect[4])
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print(label, 24, 24, 0, 2, 2)
  love.graphics.setCanvas()
  return canvas
end

local function saveDiagnosticEyes()
  if not dumpDirectory or dumpedEyes then return end
  local function saveOne(canvas, name)
    local width, height = canvas:getDimensions()
    if width * height > maxDiagnosticPixels then
      print("[xrprobe] source eye dump skipped=" .. name
        .. " reason=pixel_limit dimensions=" .. width .. "x" .. height)
      return false
    end
    local okData, data = pcall(canvas.newImageData, canvas)
    if not okData or not data then return false end
    local okEncoded, fileData = pcall(data.encode, data, "png")
    local okWrite = false
    if okEncoded and fileData then
      local file = io.open(dumpDirectory .. "/" .. name .. ".png", "wb")
      if file then
        okWrite = file:write(fileData:getString()) ~= nil
        local closeOK = file:close()
        okWrite = okWrite and closeOK ~= nil
      end
    end
    if data.release then pcall(data.release, data) end
    return okWrite
  end
  local leftOK = saveOne(leftCanvas, "left")
  local rightOK = saveOne(rightCanvas, "right")
  if leftOK and rightOK then
    print("[xrprobe] source eye dump left=true right=true directory=" .. dumpDirectory)
  else
    print("[xrprobe] source eye dump left=" .. tostring(leftOK)
      .. " right=" .. tostring(rightOK)
      .. " directory=" .. dumpDirectory .. " (directory must exist and be writable)")
  end
  dumpedEyes = true
end

local function fovText(view)
  local fov = type(view) == "table" and view.fov or nil
  if type(fov) ~= "table" then return "unavailable" end
  return string.format("left=%.4f right=%.4f up=%.4f down=%.4f",
    fov.left or 0, fov.right or 0, fov.up or 0, fov.down or 0)
end

function love.load()
  startedAt = love.timer.getTime()
  exitAfter = tonumber(env("POKEPORT_XR_PROBE_SECONDS")) or 15
  exitAfter = math.max(1, math.min(exitAfter, 300))
  dryRun = env("POKEPORT_XR_PROBE_DRY_RUN") == "1"
  dumpDirectory = env("POKEPORT_XR_PROBE_DUMP_DIR")
    or env("POKEPORT_XR_PROBE_EYE_DUMP_DIR")
  if love.graphics and love.graphics.getRendererInfo then
    local infoOK, name, version, vendor, device =
      pcall(love.graphics.getRendererInfo)
    if infoOK then
      print(string.format("[xrprobe] love_gl renderer=%s version=%s vendor=%s device=%s",
        tostring(name), tostring(version), tostring(vendor), tostring(device)))
    else
      print("[xrprobe] love_gl renderer info unavailable: " .. tostring(name))
    end
  end
  local path = env("POKEPORT_XRBRIDGE")
  if not path or path == "" then
    error("set POKEPORT_XRBRIDGE to the built xrbridge.so path", 0)
  end
  local loaded, factory = pcall(package.loadlib, path, "luaopen_xrbridge")
  if not loaded or type(factory) ~= "function" then
    error("could not load xrbridge: " .. tostring(factory), 0)
  end
  bridge = factory()
  local created, detail = bridge.create()
  if not created then
    print("[xrprobe] OpenXR create failed: " .. tostring(detail or bridge.lastError()))
    love.event.quit(1)
    return
  end

  local status = bridge.status()
  local width = status.swapchainWidth > 0 and status.swapchainWidth or 640
  local height = status.swapchainHeight > 0 and status.swapchainHeight or 640
  leftCanvas = makeEyeCanvas(width, height, {
    { 1, 0.05, 0.04, 1 }, { 0.04, 1, 0.06, 1 },
    { 0.05, 0.12, 1, 1 }, { 1, 0.8, 0.05, 1 },
  }, "LEFT")
  rightCanvas = makeEyeCanvas(width, height, {
    { 0.05, 1, 1, 1 }, { 1, 0.05, 0.9, 1 },
    { 1, 0.35, 0.04, 1 }, { 0.95, 0.95, 0.95, 1 },
  }, "RIGHT")
  saveDiagnosticEyes()
  if love.window and love.window.setVSync then
    pcall(love.window.setVSync, 0)
  end
  local dimensions = status.recommendedViewDimensions or {}
  local profiles = status.interactionProfiles or {}
  print(string.format("[xrprobe] runtime=%s state=%s view_config=%s swapchain_format=%s swapchain=%dx%d recommended_views=%dx%d|%dx%d dry_run=%s dump_after_submits=%s exit_after=%.1fs",
    tostring(status.runtimeName), tostring(status.sessionState),
    tostring(status.viewConfiguration), tostring(status.swapchainFormat),
    width, height, tonumber(dimensions.leftWidth) or 0,
    tonumber(dimensions.leftHeight) or 0, tonumber(dimensions.rightWidth) or 0,
    tonumber(dimensions.rightHeight) or 0, tostring(dryRun),
    tostring(status.swapchainDumpAfterSubmits), exitAfter))
  print(string.format("[xrprobe] xr_gl context=%s vendor=%s renderer=%s openxr_required=%s..%s interaction_profiles=left:%s right:%s frame_profile_advertised=%s suggested=%s",
    tostring(status.glVersion), tostring(status.glVendor), tostring(status.glRenderer),
    tostring(status.openGlMinVersion), tostring(status.openGlMaxVersion),
    tostring(profiles.left), tostring(profiles.right),
    tostring(status.frameControllerProfileAvailable),
    tostring(status.frameControllerBindingsSuggested)))
end

function love.update()
  if not bridge then return end
  local now = love.timer.getTime()
  local status = bridge.status()
  if status.quitRequested or status.instanceLossPending then
    love.event.quit()
    return
  end
  if now >= nextStatusLog then
    nextStatusLog = now + 1
    local period = tonumber(status.predictedDisplayPeriod) or 0
    local rate = period > 0 and 1000000000 / period or 0
    local profiles = status.interactionProfiles or {}
    print(string.format("[xrprobe] state=%s ready=%s focused=%s shouldRender=%s period_ns=%.0f hz=%.2f displayTime=%.0f submits=%s swapchain_dump_count=%s dump_after_submits=%s dump=%s views=%s | %s",
      tostring(status.sessionState), tostring(status.ready), tostring(status.focused),
      tostring(status.shouldRender), period, rate,
      tonumber(status.predictedDisplayTime) or 0,
      tostring(status.submitCount), tostring(status.swapchainDumpCount),
      tostring(status.swapchainDumpAfterSubmits),
      tostring(status.swapchainDumpMessage),
      fovText(lastViews and lastViews[1]), fovText(lastViews and lastViews[2])))
    print(string.format("[xrprobe] interaction_profiles=left:%s right:%s frame_profile_advertised=%s suggested=%s swapchain_format=%s swapchain=%dx%d",
      tostring(profiles.left), tostring(profiles.right),
      tostring(status.frameControllerProfileAvailable),
      tostring(status.frameControllerBindingsSuggested),
      tostring(status.swapchainFormat), tonumber(status.swapchainWidth) or 0,
      tonumber(status.swapchainHeight) or 0))
  end
  if now - startedAt >= exitAfter then love.event.quit() end
end

function love.draw()
  local width, height = love.graphics.getDimensions()
  love.graphics.setColor(1, 1, 1, 1)
  if leftCanvas then love.graphics.draw(leftCanvas, 0, 0, 0, width / leftCanvas:getWidth(), height / leftCanvas:getHeight()) end

  if not bridge then return end
  local left, right, shouldRender = bridge.beginFrame()
  if left and right then
    lastViews = { left, right }
    if shouldRender and not dryRun then
      local submitted, detail = bridge.submitCanvases(leftCanvas, rightCanvas)
      if not submitted then
        print("[xrprobe] submit failed: " .. tostring(detail or bridge.lastError()))
        love.event.quit(1)
      elseif not firstSubmitLogged then
        firstSubmitLogged = true
        local status = bridge.status()
        print("[xrprobe] first projection submit succeeded submit_count="
          .. tostring(status.submitCount) .. " swapchain_dump_count="
          .. tostring(status.swapchainDumpCount) .. " dump="
          .. tostring(status.swapchainDumpMessage))
      end
    else
      bridge.abortFrame()
    end
  end
end

function love.quit()
  if bridge then bridge.destroy() end
end
