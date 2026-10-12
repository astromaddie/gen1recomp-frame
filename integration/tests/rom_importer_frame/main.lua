local checks = 0

local function check(value, message)
  if not value then error(message, 2) end
  checks = checks + 1
end

local function equal(actual, expected, message)
  check(actual == expected,
    (message or "values differ") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual))
end

local function parent(path)
  return path:match("^(.*)/[^/]+$")
end

local function pathJoin(left, right)
  return left:gsub("/+$", "") .. "/" .. right
end

local function replaceLiteral(text, needle, replacement)
  local first, last = text:find(needle, 1, true)
  check(first ~= nil, "expected display text to contain " .. needle)
  return text:sub(1, first - 1) .. replacement .. text:sub(last + 1)
end

local function makeDirectory(path, HostShell)
  local ok = os.execute("mkdir -p -- " .. HostShell.quote(path))
  check(ok == true or ok == 0, "could not create fixture directory: " .. path)
end

local function writeFile(path, data, HostShell)
  makeDirectory(parent(path), HostShell)
  local file, err = io.open(path, "wb")
  check(file ~= nil, "could not write fixture " .. path .. ": " .. tostring(err))
  file:write(data)
  file:close()
end

local function clearFiles(path, HostShell)
  makeDirectory(path, HostShell)
  os.execute("find " .. HostShell.quote(path)
    .. " -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null")
end

local function runTests()
  print("Frame ROM import harness started")
  io.stdout:flush()
  local source = assert(os.getenv("FRAME_IMPORT_TEST_SOURCE"),
    "set FRAME_IMPORT_TEST_SOURCE to the production source tree")
  local fixture = assert(os.getenv("FRAME_IMPORT_TEST_FIXTURE_ROOT"),
    "set FRAME_IMPORT_TEST_FIXTURE_ROOT to a temporary folder")
  package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path

  local GameVersion = require("src.core.GameVersion")
  local HostShell = require("src.core.HostShell")
  local RomImporter = require("src.import.RomImporter")
  print("Production importer modules loaded")
  io.stdout:flush()
  local base = fixture
  local game = pathJoin(base, "game")
  local save = pathJoin(base, "save")
  local roms = pathJoin(base, "roms")
  local marker = "scan-was-not-shell-injected"
  local markerPath = pathJoin(fixture, marker)
  local manual = pathJoin(pathJoin(fixture, "outside scan roots"), "Manual Blue.GB")

  makeDirectory(game, HostShell)
  makeDirectory(save, HostShell)
  makeDirectory(roms, HostShell)
  love.filesystem.getSourceBaseDirectory = function() return base end
  love.filesystem.getSource = function() return game end
  love.filesystem.getSaveDirectory = function() return save end

  local redData = string.rep("R", 1024 * 1024)
  local blueData = string.rep("B", 1024 * 1024)
  local yellowData = string.rep("Y", 1024 * 1024)
  local originalHashes = {}
  local expectedHashes = {
    red = "ea9bcae617fdf159b045185467ae58b2e4a48b9a",
    blue = "d7037c83e1ae5b39bde3c30787637ba1d4c48ce2",
    yellow = "cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1",
  }
  for version, expected in pairs(expectedHashes) do
    local info = GameVersion.info(version)
    equal(info.sha1, expected, "production supported ROM hash changed for " .. version)
    originalHashes[version] = info.sha1
    equal(GameVersion.forSha1(expected), version,
      "production hash should route to " .. version)
  end

  -- Keep LÖVE's real SHA-1 path, extending only the production version table
  -- with fixture digests. No player ROM is read or copied for this test.
  local function fixtureHash(data)
    return love.data.encode("string", "hex", love.data.hash("sha1", data))
  end
  GameVersion.info("red").sha1 = fixtureHash(redData)
  GameVersion.info("blue").sha1 = fixtureHash(blueData)
  GameVersion.info("yellow").sha1 = fixtureHash(yellowData)
  local function importer(ready)
    return setmetatable({
      workState = nil,
      ready = ready or { red = false, blue = false, yellow = false },
      chooseVersion = "red",
      tab = "red",
      importing = nil,
      notice = nil,
      status = "",
      detail = "",
      progress = 0,
    }, RomImporter)
  end

  local function clearRoots()
    clearFiles(roms, HostShell)
    clearFiles(base, HostShell)
    clearFiles(game, HostShell)
    clearFiles(save, HostShell)
  end

  local vrActive = true
  package.loaded["src.vr.Runtime"] = {
    isBridgeActive = function() return vrActive end,
  }
  if os.getenv("FRAME_IMPORT_TEST_BASELINE") == "1" then
    print("Baseline harness started")
    io.stdout:flush()
    clearRoots()
    print("Baseline fixture directories cleared")
    io.stdout:flush()
    writeFile(pathJoin(roms, "Install Yellow.GBC"), yellowData, HostShell)
    print("Baseline synthetic ROM written")
    io.stdout:flush()
    local fakeCalls = 0
    local originalPopen = HostShell.popen
    HostShell.popen = function(command, mode)
      if command:find("zenity", 1, true) or command:find("kdialog", 1, true) then
        fakeCalls = fakeCalls + 1
        return nil
      end
      return originalPopen(command, mode)
    end
    local state = importer()
    state:choose("yellow")
    HostShell.popen = originalPopen
    check(state.workState ~= "working",
      "baseline importer unexpectedly found a ROM in the install roms/ folder")
    check(state.notice ~= nil, "baseline should end with its generic no-picker notice")
    check(state.notice.detail ~= pathJoin(base, "roms"),
      "baseline should advertise the kit root rather than roms/")
    check(fakeCalls >= 1, "baseline should have attempted a blocking picker")
    print("Baseline reproduced: install-root ROM was missed; picker attempted; "
      .. "notice pointed to " .. state.notice.detail)
    love.event.quit(0)
    return
  end

  local function expectImported(path, data, version, ready)
    clearRoots()
    writeFile(path, data, HostShell)
    local state = importer(ready)
    state:choose("red")
    equal(state.importing, version, "ROM should route by supported version SHA-1")
    equal(state.workState, "working", "accepted ROM should enter production import state")
    local retained, retainError = io.open(path, "rb")
    check(retained ~= nil, "import must leave the source ROM in place: " .. tostring(retainError))
    retained:close()
    return state
  end

  -- Recommended installation roms/ placement and uppercase extensions.
  local state = expectImported(pathJoin(roms, "yellow copy.GBC"), yellowData, "yellow")
  equal(state.tab, "yellow", "Yellow should land on its own tab")

  -- Previously advertised kit root, mounted game/ legacy root, and save folder.
  expectImported(pathJoin(base, "Red dump.gb"), redData, "red")
  expectImported(pathJoin(game, "Pokémon ; $(touch " .. marker .. ") ' Blue.GB"),
    blueData, "blue")
  local markerFile = io.open(markerPath, "rb")
  if markerFile then markerFile:close() end
  check(markerFile == nil,
    "shell punctuation in roots and filenames must never execute")
  expectImported(pathJoin(save, "legacy yellow.GBC"), yellowData, "yellow")
  expectImported(pathJoin(roms, "Pokémon\nBlue.GBC"), blueData, "blue")

  -- Ready Red is ignored while a second supported Blue file is routed to Blue.
  clearRoots()
  writeFile(pathJoin(roms, "already imported red.gb"), redData, HostShell)
  writeFile(pathJoin(base, "Blue ; [second].GB"), blueData, HostShell)
  state = importer({ red = true, blue = false, yellow = false })
  state:choose("yellow")
  equal(state.importing, "blue", "a ready first version must not hide a pending second")
  equal(state.tab, "blue", "supported ROM detection should override the requested tab")

  clearRoots()
  writeFile(pathJoin(roms, "red is already ready.GB"), redData, HostShell)
  state = importer({ red = true, blue = true, yellow = true })
  local originalPopen = HostShell.popen
  local vrPickerCalls = 0
  HostShell.popen = function(command, mode)
    if command:find("zenity", 1, true) or command:find("kdialog", 1, true) then
      vrPickerCalls = vrPickerCalls + 1
      return nil
    end
    return originalPopen(command, mode)
  end
  state:choose("red")
  HostShell.popen = originalPopen
  check(state.importing == nil and state.workState == nil,
    "already-ready carts should be skipped rather than reimported")
  check(state.notice and state.notice.detail == pathJoin(base, "roms"),
    "an empty pending scan should show the recommended folder")
  equal(vrPickerCalls, 0, "native VR must not open a desktop file picker")

  clearRoots()
  local nested = pathJoin(roms, "nested")
  writeFile(pathJoin(nested, "hidden.gb"), redData, HostShell)
  state = importer()
  state:choose("red")
  check(state.importing == nil and state.workState == nil,
    "ROM discovery should not recurse into subfolders")
  os.execute("rm -rf -- " .. HostShell.quote(nested))

  -- Flat desktop keeps its picker, then uses the recommended folder notice if
  -- neither supported picker is installed and the scan is empty.
  clearRoots()
  vrActive = false
  local desktopPickerCalls = 0
  HostShell.popen = function(command, mode)
    if command:find("zenity", 1, true) or command:find("kdialog", 1, true) then
      desktopPickerCalls = desktopPickerCalls + 1
      return nil
    end
    return originalPopen(command, mode)
  end
  state = importer()
  state:choose("red")
  HostShell.popen = originalPopen
  equal(desktopPickerCalls, 2, "flat desktop should retain both native picker attempts")
  check(state.notice and state.notice.detail == pathJoin(base, "roms"),
    "desktop empty-folder fallback should advertise the recommended folder")
  vrActive = true

  -- A later valid file wins over an earlier rejected candidate.
  clearRoots()
  writeFile(pathJoin(roms, "00-short.gb"), string.rep("x", 31), HostShell)
  writeFile(pathJoin(game, "Blue valid.GBC"), blueData, HostShell)
  state = importer()
  state:choose("red")
  equal(state.importing, "blue", "valid candidates must win after a bad candidate")

  -- Wrong-size and unsupported-hash files surface actionable errors.
  clearRoots()
  writeFile(pathJoin(roms, "wrong size.GB"), string.rep("x", 31), HostShell)
  state = importer()
  state:choose("red")
  equal(state.workState, "error", "wrong-size candidate should raise an error")
  check(state.detail:find("exactly 1 MiB", 1, true),
    "wrong-size error should explain the accepted ROM size")

  -- A large sparse file exercises the production seek-before-read guard.
  clearRoots()
  local oversized = pathJoin(roms, "oversized.gb")
  local sparse = assert(io.open(oversized, "wb"))
  sparse:seek("set", 64 * 1024 * 1024 - 1)
  sparse:write("x")
  sparse:close()
  local originalOpen = io.open
  local oversizedReads = 0
  io.open = function(path, mode)
    local file, err = originalOpen(path, mode)
    if path ~= oversized or not file then return file, err end
    return {
      seek = function(_, ...) return file:seek(...) end,
      read = function(_, ...)
        oversizedReads = oversizedReads + 1
        return file:read(...)
      end,
      close = function() return file:close() end,
    }
  end
  state = importer()
  state:choose("red")
  io.open = originalOpen
  equal(state.workState, "error", "oversized file should raise an error")
  equal(oversizedReads, 0, "oversized file must be rejected before allocating its contents")

  clearRoots()
  writeFile(pathJoin(roms, "unsupported.GbC"), string.rep("U", 1024 * 1024), HostShell)
  state = importer()
  state:choose("red")
  equal(state.workState, "error", "unsupported hash should raise an error")
  check(state.detail:find("Unsupported ROM", 1, true)
    and state.detail:find("SHA-1", 1, true),
    "unsupported ROM error should identify the hash and supported family")

  clearRoots()
  local unreadable = pathJoin(roms, "unreadable.gb")
  writeFile(unreadable, redData, HostShell)
  originalOpen = io.open
  io.open = function(path, mode)
    if path == unreadable then return nil, "permission denied" end
    return originalOpen(path, mode)
  end
  state = importer()
  state:choose("red")
  io.open = originalOpen
  equal(state.workState, "error", "unreadable candidate should raise an error")
  check(state.detail:find("Could not read ROM file", 1, true)
    and state.detail:find("permissions", 1, true),
    "unreadable error should tell the player to check permissions")

  -- Repeated choose scans the live folders, so a file copied during play is
  -- picked up without a restart.
  clearRoots()
  state = importer()
  state:choose("red")
  check(state.notice ~= nil, "empty scan should show a folder notice")
  writeFile(pathJoin(roms, "copied while running.gb"), redData, HostShell)
  state.workState, state.notice = nil, nil
  state:choose("red")
  equal(state.importing, "red", "the next choose should discover a newly copied ROM")

  -- A rejected file stays visible if the flat desktop picker is canceled.
  clearRoots()
  writeFile(pathJoin(roms, "still rejected.gb"), string.rep("x", 31), HostShell)
  vrActive = false
  desktopPickerCalls = 0
  HostShell.popen = function(command, mode)
    if command:find("zenity", 1, true) or command:find("kdialog", 1, true) then
      desktopPickerCalls = desktopPickerCalls + 1
      return nil
    end
    return originalPopen(command, mode)
  end
  state = importer()
  state:choose("red")
  HostShell.popen = originalPopen
  equal(state.workState, "error", "canceling picker must preserve rejected-file error")
  check(state.detail:find("exactly 1 MiB", 1, true),
    "canceling picker must not overwrite the actionable size error")
  equal(desktopPickerCalls, 2, "rejected desktop scan should still allow picker attempts")

  -- With flat desktop mode, keep the normal native picker. A successful picker
  -- result outside the scanned folders still enters the production startPath.
  clearRoots()
  writeFile(manual, blueData, HostShell)
  vrActive = false
  originalPopen = HostShell.popen
  local pickerCalls = 0
  HostShell.popen = function(command, mode)
    if command:find("zenity", 1, true) then
      pickerCalls = pickerCalls + 1
      return { read = function() return manual end, close = function() return true end }
    end
    if command:find("kdialog", 1, true) then
      pickerCalls = pickerCalls + 1
      return nil
    end
    return originalPopen(command, mode)
  end
  state = importer()
  state:choose("red")
  HostShell.popen = originalPopen
  equal(state.importing, "blue", "desktop picker selection should retain version routing")
  check(pickerCalls == 1, "flat desktop should still open its native picker")

  -- Render the existing launcher card once with the empty-folder notice and
  -- once with a rejected-ROM error. No UI assets or layout are changed here.
  vrActive = true
  clearRoots()
  local displayBase = "/home/deck/Gen1RecompFrame"
  local visualBadRom = pathJoin(roms, "bad-size.gb")
  local visual = RomImporter.new(nil, { launcher = true })
  visual.ready = { red = false, blue = false, yellow = false }
  visual.chooseVersion, visual.tab = "red", "red"
  visual:choose("red")
  check(visual.notice and visual.notice.detail == roms,
    "render smoke should obtain its empty-folder notice from production choose")
  visual.notice.detail = pathJoin(displayBase, "roms")
  love.window.setMode(800, 600)
  local captures = { "empty-folder-800x600.png", "rejected-rom-800x600.png" }
  local captureIndex, capturePending = 1, false
  love.draw = function()
    visual:draw()
    if capturePending or captureIndex > #captures then return end
    capturePending = true
    local name = captures[captureIndex]
    love.graphics.captureScreenshot(function(imageData)
      local ok, err = pcall(function() return imageData:encode("png", name) end)
      check(ok, "could not save rendered evidence " .. name .. ": " .. tostring(err))
      capturePending = false
      captureIndex = captureIndex + 1
      if captureIndex == 2 then
        clearRoots()
        writeFile(visualBadRom, string.rep("x", 31), HostShell)
        visual.workState, visual.notice = nil, nil
        visual:choose("red")
        check(visual.workState == "error", "render smoke should show ROM error")
        check(visual.detail:find("exactly 1 MiB", 1, true),
          "render smoke error should come from production discovery")
        visual.detail = replaceLiteral(visual.detail, visualBadRom,
          pathJoin(pathJoin(displayBase, "roms"), "bad-size.gb"))
      elseif captureIndex > #captures then
        love.event.quit(0)
        print("Frame ROM import checks passed: " .. tostring(checks))
      end
    end)
  end
  love.update = function() end

  -- Preserve real LÖVE hashing outside the known synthetic fixtures.
  for version, hash in pairs(originalHashes) do
    GameVersion.info(version).sha1 = hash
    equal(GameVersion.info(version).sha1, expectedHashes[version],
      "production supported ROM hash must be restored for " .. version)
  end
end

function love.load()
  print("LOVE load entered")
  io.stdout:flush()
  local ok, err = xpcall(runTests, debug.traceback)
  if not ok then
    io.stderr:write("Frame ROM import test failed: " .. tostring(err) .. "\n")
    love.event.quit(1)
  end
end
