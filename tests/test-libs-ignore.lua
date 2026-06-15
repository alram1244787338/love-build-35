--[[
  Regression test for the libs/ignore interaction in love-build.

  Background
  ----------
  `libs` entries are copied straight into each platform's output folder, so
  they must be excluded from the shared `.love` archive. The old code excluded
  them by *basename only*, which meant a real game resource that happened to
  share a filename with a lib (e.g. a lib `libs/win/steam_api.dll` and an asset
  `resources/steam_api.dll`) was silently dropped from the `.love`. With
  multiple configs this was especially nasty: the `.love` is built once and
  reused, so one config's lib naming could silently strip another config's
  asset.

  This test exercises the real code (no copy/paste of the logic) on two seams:
    Section A - love-zip `addFolder` ignore matching (the matching engine)
    Section B - love-build `readConfig` lib -> ignore construction

  It uses a tiny in-memory filesystem so it can run under a plain `lua`
  interpreter without the LÖVE runtime / network / GUI.

  Run from the repo root:  lua tests/test-libs-ignore.lua
]]

-- Lua 5.x has no built-in `bit`; love-zip does `require("bit")` at load time.
-- We never exercise the real bit ops (we stub Zip:_add), so a no-op is fine.
package.preload['bit'] = function()
  local function noop() return 0 end
  return setmetatable({}, { __index = function() return noop end })
end

----------------------------------------------------------------------
-- assertion helpers
----------------------------------------------------------------------
local passed, failed = 0, 0
local function check(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    io.write('  FAIL: ' .. msg .. '\n')
  end
end
local function listHas(list, value)
  for i = 1, #list do if list[i] == value then return true end end
  return false
end
local function logsMatch(logs, pat)
  for i = 1, #logs do if logs[i]:find(pat, 1, true) then return true end end
  return false
end

----------------------------------------------------------------------
-- tiny in-memory filesystem built from a flat list of file paths
----------------------------------------------------------------------
local function makeFS(paths)
  local files, dirs = {}, {}
  for _, p in ipairs(paths) do
    files[p] = true
    local parts = {}
    for seg in p:gmatch('[^/]+') do parts[#parts + 1] = seg end
    local cur = ''
    for i = 1, #parts - 1 do
      cur = (cur == '') and parts[i] or (cur .. '/' .. parts[i])
      dirs[cur] = true
    end
  end
  local function immediateChild(path, prefix, seen, out)
    if path:sub(1, #prefix) ~= prefix then return end
    local child = path:sub(#prefix + 1):match('^[^/]+')
    if child and not seen[child] then
      seen[child] = true
      out[#out + 1] = child
    end
  end
  return {
    getDirectoryItems = function(dir)
      local prefix, seen, out = dir .. '/', {}, {}
      for p in pairs(files) do immediateChild(p, prefix, seen, out) end
      for d in pairs(dirs) do immediateChild(d, prefix, seen, out) end
      table.sort(out)
      return out
    end,
    getInfo = function(path)
      if files[path] then return { type = 'file', modtime = 0 } end
      if dirs[path] then return { type = 'directory' } end
      return nil
    end,
  }
end

----------------------------------------------------------------------
-- Section A: love-zip addFolder ignore matching
----------------------------------------------------------------------
io.write('Section A: love-zip addFolder ignore matching\n')

-- minimal love surface needed to load + run addFolder
local recorded
love = {
  filesystem = {
    getDirectoryItems = function() return {} end,
    getInfo = function() return nil end,
    read = function() return '' end,
    getSaveDirectory = function() return '/tmp' end,
  },
  timer = { getTime = function() return 0 end },
  data = {},                                  -- unused: _add is stubbed
  system = { getOS = function() return 'OS X' end },
}
assert(loadfile('libs/love-zip.lua'), 'cannot find libs/love-zip.lua (run from repo root)')()
-- record what would be written instead of doing real compression
love.zip._add = function(self, filename)
  recorded[#recorded + 1] = filename
  return true, nil
end

-- a project where libs deliberately share filenames with real assets, at
-- several different depths
local projectFiles = {
  'project/main.lua',
  'project/conf.lua',
  'project/resources/steam_api.dll',  -- real asset, same name as the windows lib
  'project/mods/steam_api.dll',       -- real asset (deeper), same name again
  'project/libs/win/steam_api.dll',   -- the actual windows lib (declared in build.lua)
  'project/data/license.txt',         -- real asset, same name as the 'all' lib
  'project/resources/license.txt',    -- the actual 'all' lib
  'project/assets/.DS_Store',         -- junk to be ignored anywhere by basename
  'project/.DS_Store',
}

local function runAddFolder(ignore)
  local fs = makeFS(projectFiles)
  love.filesystem.getDirectoryItems = fs.getDirectoryItems
  love.filesystem.getInfo = fs.getInfo
  recorded = {}
  love.zip:newZip(false):addFolder('project', ignore)
  local set = {}
  for _, name in ipairs(recorded) do set[name] = true end
  return set
end

-- exact relative paths exclude ONLY the declared libs, keeping same-named assets
local got = runAddFolder({ 'libs/win/steam_api.dll', 'resources/license.txt' })
check(got['libs/win/steam_api.dll'] == nil, 'declared lib libs/win/steam_api.dll must be excluded from .love')
check(got['resources/license.txt'] == nil, "declared 'all' lib resources/license.txt must be excluded from .love")
check(got['resources/steam_api.dll'] == true, 'same-named asset resources/steam_api.dll must be KEPT (bug #1)')
check(got['mods/steam_api.dll'] == true, 'same-named asset mods/steam_api.dll (deeper) must be KEPT')
check(got['data/license.txt'] == true, 'same-named asset data/license.txt must be KEPT')
check(got['main.lua'] == true, 'normal files must still be included')
check(got['conf.lua'] == true, 'normal files must still be included')

-- basename entries still ignore matching files at ANY depth (back-compat for
-- .git / .DS_Store / user ignore entries)
local got2 = runAddFolder({ '.DS_Store' })
check(got2['.DS_Store'] == nil, 'top-level .DS_Store must be ignored by basename')
check(got2['assets/.DS_Store'] == nil, 'nested .DS_Store must be ignored by basename')
check(got2['main.lua'] == true, 'unrelated files unaffected by basename ignore')

-- a directory ignore entry still drops the whole directory
local got3 = runAddFolder({ 'libs' })
check(got3['libs/win/steam_api.dll'] == nil, 'ignoring the libs dir drops everything under it')
check(got3['resources/steam_api.dll'] == true, 'ignoring libs dir does not touch other dirs')

----------------------------------------------------------------------
-- Section B: love-build readConfig lib -> ignore construction
----------------------------------------------------------------------
io.write('Section B: love-build readConfig lib -> ignore construction\n')

-- stub everything love-build pulls in at load time
package.preload['https'] = function() return {} end
package.preload['libs.love-zip'] = function() return {} end
package.preload['libs.love-icon'] = function() return {} end
package.preload['libs.love-squashfs'] = function() return {} end
package.preload['libs.love-exedit'] = function() return {} end

local TEST_CONFIG, existing, logs

local function loadBuild()
  logs = {}
  love = {
    window = nil, graphics = nil,                       -- skip canvas/logo/font block
    timer = { getTime = function() return 0 end },
    filesystem = {
      load = function() return function() return TEST_CONFIG end end,
      getInfo = function(path)
        local rel = path:gsub('^project/', '')
        if existing[rel] then return { type = 'file' } end
        return nil
      end,
    },
    system = { getOS = function() return 'OS X' end },
  }
  local mod = assert(loadfile('love-build.lua'), 'cannot find love-build.lua (run from repo root)')()
  love.build = mod
  mod.log = function(msg) logs[#logs + 1] = tostring(msg) end
  mod.readData = function() return 'x' end              -- pretend build.lua/main.lua exist
  mod.targets = ''
  return mod
end

-- config mixing every supported form:
--   per-platform tables, an 'all' table, AND bare-string (single) entries
TEST_CONFIG = {
  name = 'G', version = '1.0.0', love = '11.5',
  platforms = { 'windows', 'macos', 'linux' },
  ignore = { 'dist' },
  libs = {
    windows = { 'resources/windows/https.dll' },
    macos   = { 'resources/macos/https.so' },
    linux   = { 'resources/linux/https.so' },
    all     = { 'resources/license.txt' },
    'resources/shared.dll',     -- bare-string (single entry) form
    'libs\\win\\back.dll',      -- backslash path -> must be normalised, and is MISSING
  },
}
existing = {
  ['resources/windows/https.dll'] = true,
  ['resources/macos/https.so']    = true,
  ['resources/linux/https.so']    = true,
  ['resources/license.txt']       = true,
  ['resources/shared.dll']        = true,
  -- libs/win/back.dll intentionally absent -> should produce a WARNING log
}

local mod = loadBuild()
mod.readConfig()
local ign = mod.opts.ignore

-- every declared lib is ignored by its FULL relative path
check(listHas(ign, 'resources/windows/https.dll'), 'windows lib ignored by full path')
check(listHas(ign, 'resources/macos/https.so'), 'macos lib ignored by full path')
check(listHas(ign, 'resources/linux/https.so'), 'linux lib ignored by full path')
check(listHas(ign, 'resources/license.txt'), "'all' lib ignored by full path")
check(listHas(ign, 'resources/shared.dll'), 'bare-string (single entry) lib ignored by full path')
check(listHas(ign, 'libs/win/back.dll'), 'backslash path normalised to forward slashes')

-- the regression guard: NO bare basenames are inserted (that was the bug)
check(not listHas(ign, 'https.dll'), 'must NOT insert bare basename https.dll')
check(not listHas(ign, 'https.so'), 'must NOT insert bare basename https.so')
check(not listHas(ign, 'license.txt'), 'must NOT insert bare basename license.txt')
check(not listHas(ign, 'shared.dll'), 'must NOT insert bare basename shared.dll')
check(not listHas(ign, 'back.dll'), 'must NOT insert bare basename back.dll')

-- user ignore + default git/junk ignores still present
check(listHas(ign, 'dist'), 'user ignore entry preserved')
check(listHas(ign, '.git'), 'default .git ignore preserved')
check(listHas(ign, '.DS_Store'), 'default .DS_Store ignore preserved')

-- a missing lib is clearly logged with its offending entry
check(logsMatch(logs, 'WARNING'), 'missing lib produces a WARNING log')
check(logsMatch(logs, 'libs/win/back.dll'), 'missing lib log names the offending entry')

----------------------------------------------------------------------
-- results
----------------------------------------------------------------------
io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
