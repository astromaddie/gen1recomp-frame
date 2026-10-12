-- Discover player-supplied ROMs in the Steam Frame install and data folders.
-- LOVE 11.5 only exposes its mounted game and save roots to getDirectoryItems;
-- the Frame kit launches the game/ child of the install, so list the sibling
-- roms/ folder and other established roots with a quoted, shallow host scan.
local GameVersion = require("src.core.GameVersion")
local HostShell = require("src.core.HostShell")

local Discovery = {}

local ROM_SIZE = 1024 * 1024

local function safePath(getter)
  if type(getter) ~= "function" then return nil end
  local ok, value = pcall(getter)
  if ok and type(value) == "string" and value ~= "" then return value end
  return nil
end

local function parent(path)
  return path and path:match("^(.*)/[^/]+$") or nil
end

local function normalize(path)
  if type(path) ~= "string" or path == "" then return nil end
  path = path:gsub("/+$", "")
  return path == "" and "/" or path
end

local function join(directory, name)
  directory = normalize(directory)
  if not directory then return nil end
  if directory == "/" then return "/" .. name end
  return directory .. "/" .. name
end

local function paths()
  local fs = love and love.filesystem or {}
  local source = normalize(safePath(fs.getSource))
  local base = normalize(safePath(fs.getSourceBaseDirectory)) or parent(source)
  local save = normalize(safePath(fs.getSaveDirectory))
  local candidates = {}
  local function add(path)
    path = normalize(path)
    if path then candidates[#candidates + 1] = path end
  end
  add(join(base, "roms")) -- recommended player-facing location
  add(base)                -- previously advertised kit root
  add(source)              -- legacy mounted game/ root
  add(save)                -- existing save-directory drop flow
  local result, seen = {}, {}
  for _, path in ipairs(candidates) do
    path = normalize(path)
    if path and not seen[path] then
      seen[path] = true
      result[#result + 1] = path
    end
  end
  return result, join(base, "roms") or save or "the game folder"
end

local function listRomPaths(directory)
  local command = "find " .. HostShell.quote(directory)
    .. " -mindepth 1 -maxdepth 1 -type f"
    .. " \\( -iname '*.gb' -o -iname '*.gbc' \\) -print0 2>/dev/null"
  local pipe = HostShell.popen(command)
  if not pipe then return {} end

  local ok, output = pcall(function() return pipe:read("*a") end)
  pcall(function() pipe:close() end)
  if not ok or type(output) ~= "string" or output == "" then return {} end

  local found, offset = {}, 1
  while true do
    local ending = output:find("\0", offset, true)
    if not ending then break end
    found[#found + 1] = output:sub(offset, ending - 1)
    offset = ending + 1
  end
  table.sort(found)
  return found
end

local function readFile(path)
  local ok, file, openError = pcall(io.open, path, "rb")
  if not ok or not file then
    return nil, "Could not read ROM file " .. path .. ": "
      .. tostring(ok and openError or file)
      .. ". Check its permissions or copy a readable file into roms/."
  end

  local seekOk, size = pcall(function() return file:seek("end") end)
  if not seekOk or type(size) ~= "number" then
    pcall(function() file:close() end)
    return nil, "Could not read ROM file " .. path
      .. ". Check its permissions or copy a readable file into roms/."
  end
  if size ~= ROM_SIZE then
    pcall(function() file:close() end)
    return nil, ("ROM file %s is %d bytes; the supported image must be exactly "
      .. "1 MiB. Choose a clean US Red, Blue, or Yellow ROM."):format(path, size)
  end
  local resetOk = pcall(function() file:seek("set", 0) end)
  if not resetOk then
    pcall(function() file:close() end)
    return nil, "Could not read ROM file " .. path
      .. ". Check its permissions or copy a readable file into roms/."
  end

  local readOk, data, readError = pcall(function() return file:read("*a") end)
  pcall(function() file:close() end)
  if not readOk or type(data) ~= "string" then
    return nil, "Could not read ROM file " .. path .. ": "
      .. tostring(readOk and readError or data)
      .. ". Check its permissions or copy a readable file into roms/."
  end
  return data
end

local function sha1(data)
  local digest = love.data.hash("sha1", data)
  if type(digest) == "userdata" and digest.getString then
    digest = digest:getString()
  end
  return love.data.encode("string", "hex", digest)
end

local function rejected(path, data)
  if #data ~= ROM_SIZE then
    return ("ROM file %s is %d bytes; the supported image must be exactly 1 MiB. "
      .. "Choose a clean US Red, Blue, or Yellow ROM."):format(path, #data)
  end
  local digest = sha1(data)
  if not GameVersion.forSha1(digest) then
    return ("Unsupported ROM file %s (SHA-1 %s). Choose an unmodified US "
      .. "Pokemon Red, Blue, or Yellow ROM; patched, trimmed, and overdumped "
      .. "files are not supported."):format(path, digest)
  end
  return nil -- already imported versions are intentionally skipped
end

-- Returns a pending absolute path and bytes, or the first actionable rejection
-- after checking every candidate so a later valid ROM always takes precedence.
function Discovery.findPendingRom(ready)
  ready = type(ready) == "table" and ready or {}
  local roots, recommended = paths()
  local firstError

  for _, root in ipairs(roots) do
    for _, path in ipairs(listRomPaths(root)) do
      local data, readError = readFile(path)
      if not data then
        firstError = firstError or readError
      else
        local version = #data == ROM_SIZE and GameVersion.forSha1(sha1(data)) or nil
        if version and not ready[version] then
          return path, data
        end
        if not version then
          firstError = firstError or rejected(path, data)
        end
      end
    end
  end

  return nil, nil, firstError, recommended
end

function Discovery.recommendedDirectory()
  local _, recommended = paths()
  return recommended
end

return Discovery
