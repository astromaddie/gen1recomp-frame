local runtimePath = assert(arg[1], "pass integration/src/vr/Runtime.lua")
local oldGetenv, oldLoadlib, oldStderr = os.getenv, package.loadlib, io.stderr

local function runFailure(expected, loadlib)
  local logs = {}
  os.getenv = function(key)
    if key == "POKEPORT_XRBRIDGE" then return "/runtime/xrbridge.so" end
    if key == "POKEPORT_VR_REQUIRED" then return "1" end
    return oldGetenv(key)
  end
  package.loadlib = loadlib
  io.stderr = { write = function(_, value) logs[#logs + 1] = value end }

  local Runtime = assert(loadfile(runtimePath))()
  Runtime.setEnabled(true)
  assert(Runtime.start())
  assert(#logs == 1, "required bridge failure must be logged during startup")
  assert(logs[1] == "[vr] xrbridge load failed: " .. expected .. "\n",
    "startup stderr must retain the exact native loader diagnostic")
  local status = Runtime.status()
  assert(not status.bridge and status.bridgeError == expected,
    "required bridge status must retain the exact native loader diagnostic")
  Runtime.shutdown()
end

runFailure("undefined symbol: love::Module::instances", function(path, symbol)
  assert(path == "/runtime/xrbridge.so" and symbol == "luaopen_xrbridge")
  return nil, "undefined symbol: love::Module::instances"
end)

runFailure("dlopen transport failure", function()
  error("dlopen transport failure", 0)
end)

runFailure("xrbridge factory failure", function()
  return function() return nil, "xrbridge factory failure" end
end)

os.getenv, package.loadlib, io.stderr = oldGetenv, oldLoadlib, oldStderr
print("runtime loader diagnostics tests passed")
