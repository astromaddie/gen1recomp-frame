local probePath = assert(arg[1], "pass integration/probe/main.lua")
local realGetenv = os.getenv
local realLoadlib = package.loadlib

local function run(shouldRender, dryRun, legacyForceRender)
  local values = {
    POKEPORT_XRBRIDGE = "/test/xrbridge.so",
    POKEPORT_XR_PROBE_DRY_RUN = dryRun and "1" or nil,
    POKEPORT_XR_PROBE_FORCE_RENDER = legacyForceRender and "1" or nil,
  }
  os.getenv = function(name) return values[name] end
  local bridge = { submits = 0, aborts = 0 }
  function bridge.create() return true end
  function bridge.status()
    return {
      swapchainWidth = 16, swapchainHeight = 12,
      runtimeName = "test", sessionState = "FOCUSED",
      recommendedViewDimensions = {}, interactionProfiles = {},
      focused = true, shouldRender = shouldRender,
      predictedDisplayPeriod = 11111111, predictedDisplayTime = 123,
      submitCount = bridge.submits, swapchainDumpCount = 0,
      swapchainDumpMessage = "",
    }
  end
  function bridge.beginFrame()
    local view = { fov = { left = -0.7, right = 0.7, up = 0.7, down = -0.7 } }
    return view, view, shouldRender
  end
  function bridge.submitCanvases()
    bridge.submits = bridge.submits + 1
    return true
  end
  function bridge.abortFrame() bridge.aborts = bridge.aborts + 1 end
  function bridge.destroy() end

  package.loadlib = function(path, symbol)
    assert(path == "/test/xrbridge.so" and symbol == "luaopen_xrbridge")
    return function() return bridge end
  end

  local function canvas(width, height)
    return {
      getWidth = function() return width end,
      getHeight = function() return height end,
      getDimensions = function() return width, height end,
    }
  end
  love = {
    timer = { getTime = function() return 0 end },
    event = { quit = function() end },
    window = { setVSync = function() end },
    graphics = {
      newCanvas = function(width, height) return canvas(width, height) end,
      setCanvas = function() end,
      clear = function() end,
      setColor = function() end,
      rectangle = function() end,
      print = function() end,
      getRendererInfo = function() return "OpenGL", "3.3", "test", "test" end,
      getDimensions = function() return 320, 240 end,
      draw = function() end,
    },
  }

  dofile(probePath)
  love.load()
  love.draw()
  assert(bridge.submits == (shouldRender and not dryRun and 1 or 0),
    "probe default/dry-run policy did not match shouldRender")
  assert(bridge.aborts == (shouldRender and not dryRun and 0 or 1),
    "probe must end every non-rendered frame without a projection")
end

run(true, false, false)
run(true, true, false)
run(false, false, false)
run(false, false, true)
os.getenv = realGetenv
package.loadlib = realLoadlib
print("probe policy tests passed: default submit, explicit dry-run, shouldRender gate")
