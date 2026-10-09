local function fail(message)
  io.stderr:write("XRBRIDGE_LOAD_SMOKE_FAIL: " .. tostring(message) .. "\n")
  love.event.quit(1)
end

function love.load()
  local path = os.getenv("POKEPORT_XRBRIDGE")
  if not path or path == "" then return fail("POKEPORT_XRBRIDGE is unset") end

  local ok, factory, loadError = pcall(package.loadlib, path, "luaopen_xrbridge")
  if not ok then return fail(factory) end
  if type(factory) ~= "function" then return fail(loadError or factory) end

  local created, bridge = pcall(factory)
  if not created then return fail(bridge) end
  if type(bridge) ~= "table" or type(bridge.beginFrame) ~= "function" then
    return fail("factory did not return the xrbridge API table")
  end
  if os.getenv("POKEPORT_VR_TELEMETRY") == "1" then
    if type(bridge.telemetryClock) ~= "function" then
      return fail("telemetry API was not registered")
    end
  end

  print("XRBRIDGE_LOAD_SMOKE_PASS: package.loadlib and native factory loaded without OpenXR startup")
  love.event.quit(0)
end

function love.draw() end
