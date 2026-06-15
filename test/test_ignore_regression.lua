#!/usr/bin/env lua
--[[
  Regression tests for libs/ignore conflict fix
  Run: lua test/test_ignore_regression.lua

  Covers:
    1. Same-name resources not accidentally excluded
    2. Platform-specific libs still copied to output
    3. `all` config libs still work
    4. Multi-config build correctness
    5. Missing lib files produce warnings
--]]

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
  if actual == expected then
    passed = passed + 1
    print("  PASS: " .. msg)
  else
    failed = failed + 1
    print("  FAIL: " .. msg)
    print("    expected: " .. tostring(expected))
    print("    actual:   " .. tostring(actual))
  end
end

local function assert_true(val, msg)
  assert_eq(not not val, true, msg)
end

local function assert_false(val, msg)
  assert_eq(not not val, false, msg)
end

----------------------------------------------------------------------
-- Simulate the ignore-checking logic from love-zip.lua addFolder()
-- This is the core matching function after the fix.
----------------------------------------------------------------------
local function is_ignored(item, folder_prefix, ignore_list)
  local item_relpath = folder_prefix .. item
  for i = 1, #ignore_list do
    if ignore_list[i] == item or ignore_list[i] == item_relpath then
      return true
    end
  end
  return false
end

----------------------------------------------------------------------
-- Simulate the libs-processing logic from readConfig()
-- Returns the ignore list after processing libs.
----------------------------------------------------------------------
local function process_libs(libs_config, file_exists_fn)
  local ignore = {}
  for key, value in pairs(libs_config) do
    if key == 'windows' or key == 'macos' or key == 'linux'
       or key == 'steamdeck' or key == 'all' then
      for l = 1, #value do
        local filepath = value[l]
        if file_exists_fn(filepath) then
          table.insert(ignore, filepath)
        else
          -- WARNING logged in real code
        end
      end
    else
      local filepath = value
      if file_exists_fn(filepath) then
        table.insert(ignore, filepath)
      end
    end
  end
  return ignore
end

----------------------------------------------------------------------
-- Helper: build a file-existence checker from a set of known paths
----------------------------------------------------------------------
local function make_exists(known_paths)
  local set = {}
  for _, p in ipairs(known_paths) do set[p] = true end
  return function(path) return set[path] == true end
end

----------------------------------------------------------------------
-- Helper: collect files that would be included in the zip
-- given a flat list of project files and an ignore list.
----------------------------------------------------------------------
local function collect_included_files(project_files, ignore_list)
  local included = {}
  for _, fullpath in ipairs(project_files) do
    -- Extract basename and folder prefix
    local basename = fullpath
    local prefix = ""
    local slash = fullpath:find("/[^/]*$")
    if slash then
      basename = fullpath:sub(slash + 1)
      prefix = fullpath:sub(1, slash)
    end
    if not is_ignored(basename, prefix, ignore_list) then
      table.insert(included, fullpath)
    end
  end
  return included
end

local function set_contains(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then return true end
  end
  return false
end

----------------------------------------------------------------------
print("\n=== Test 1: Same-name resource NOT excluded ===")
----------------------------------------------------------------------
-- Scenario: project has resources/windows/https.dll (a lib) AND
--           assets/sounds/https.dll (an unrelated sound effect).
-- Only the lib should be excluded from the .love file.
do
  local project_files = {
    "main.lua",
    "assets/sounds/https.dll",
    "resources/windows/https.dll",
    "resources/icon.png",
  }
  local known = { "resources/windows/https.dll" }
  local libs_config = {
    windows = { "resources/windows/https.dll" }
  }
  local ignore = process_libs(libs_config, make_exists(known))
  assert_eq(#ignore, 1, "ignore list has exactly 1 entry")
  assert_eq(ignore[1], "resources/windows/https.dll", "ignore contains full path")

  local included = collect_included_files(project_files, ignore)
  assert_true(set_contains(included, "main.lua"),
    "main.lua included")
  assert_true(set_contains(included, "assets/sounds/https.dll"),
    "assets/sounds/https.dll NOT excluded (same basename, different path)")
  assert_false(set_contains(included, "resources/windows/https.dll"),
    "resources/windows/https.dll correctly excluded (it's the lib)")
  assert_true(set_contains(included, "resources/icon.png"),
    "resources/icon.png included")
end

----------------------------------------------------------------------
print("\n=== Test 2: Platform-specific libs still excluded ===")
----------------------------------------------------------------------
-- Scenario: different platforms have different libs, all should be
-- excluded from the .love file.
do
  local project_files = {
    "main.lua",
    "libs/win/helper.dll",
    "libs/mac/helper.dylib",
    "libs/linux/helper.so",
  }
  local known = {
    "libs/win/helper.dll",
    "libs/mac/helper.dylib",
    "libs/linux/helper.so",
  }
  local libs_config = {
    windows = { "libs/win/helper.dll" },
    macos   = { "libs/mac/helper.dylib" },
    linux   = { "libs/linux/helper.so" },
  }
  local ignore = process_libs(libs_config, make_exists(known))
  assert_eq(#ignore, 3, "ignore list has 3 entries")

  local included = collect_included_files(project_files, ignore)
  assert_true(set_contains(included, "main.lua"), "main.lua included")
  assert_false(set_contains(included, "libs/win/helper.dll"),
    "windows lib excluded")
  assert_false(set_contains(included, "libs/mac/helper.dylib"),
    "macos lib excluded")
  assert_false(set_contains(included, "libs/linux/helper.so"),
    "linux lib excluded")
end

----------------------------------------------------------------------
print("\n=== Test 3: `all` config libs work ===")
----------------------------------------------------------------------
do
  local project_files = {
    "main.lua",
    "shared/license.txt",
    "other/data.txt",
  }
  local known = { "shared/license.txt" }
  local libs_config = {
    all = { "shared/license.txt" }
  }
  local ignore = process_libs(libs_config, make_exists(known))
  assert_eq(#ignore, 1, "ignore list has 1 entry for 'all' lib")
  assert_eq(ignore[1], "shared/license.txt", "full path stored")

  local included = collect_included_files(project_files, ignore)
  assert_true(set_contains(included, "main.lua"), "main.lua included")
  assert_false(set_contains(included, "shared/license.txt"),
    "'all' lib excluded from .love")
  assert_true(set_contains(included, "other/data.txt"),
    "other/data.txt included")
end

----------------------------------------------------------------------
print("\n=== Test 4: Multi-config build correctness ===")
----------------------------------------------------------------------
-- Simulate two configs that use different libs. Each config's ignore
-- list should only exclude its own libs, not the other config's.
do
  local project_files = {
    "main.lua",
    "libs/free/lib.dll",
    "libs/pro/lib.dll",      -- same basename, different path
    "assets/data.json",
  }

  -- Config 1: free tier uses libs/free/lib.dll
  local known1 = { "libs/free/lib.dll" }
  local libs1  = { windows = { "libs/free/lib.dll" } }
  local ignore1 = process_libs(libs1, make_exists(known1))

  local inc1 = collect_included_files(project_files, ignore1)
  assert_false(set_contains(inc1, "libs/free/lib.dll"),
    "config1: own lib excluded")
  assert_true(set_contains(inc1, "libs/pro/lib.dll"),
    "config1: other config's lib NOT excluded (same basename)")
  assert_true(set_contains(inc1, "assets/data.json"),
    "config1: data.json included")

  -- Config 2: pro tier uses libs/pro/lib.dll
  local known2 = { "libs/pro/lib.dll" }
  local libs2  = { windows = { "libs/pro/lib.dll" } }
  local ignore2 = process_libs(libs2, make_exists(known2))

  local inc2 = collect_included_files(project_files, ignore2)
  assert_true(set_contains(inc2, "libs/free/lib.dll"),
    "config2: other config's lib NOT excluded")
  assert_false(set_contains(inc2, "libs/pro/lib.dll"),
    "config2: own lib excluded")
end

----------------------------------------------------------------------
print("\n=== Test 5: Single-entry format (non-platform key) ===")
----------------------------------------------------------------------
do
  local project_files = {
    "main.lua",
    "extra/mylib.dll",
    "sounds/mylib.dll",
  }
  local known = { "extra/mylib.dll" }
  -- Simulating: libs = { mykey = 'extra/mylib.dll' }
  local libs_config = { mykey = "extra/mylib.dll" }
  local ignore = process_libs(libs_config, make_exists(known))
  assert_eq(#ignore, 1, "single-entry format adds 1 ignore")

  local included = collect_included_files(project_files, ignore)
  assert_true(set_contains(included, "sounds/mylib.dll"),
    "single-entry: same basename at different path NOT excluded")
  assert_false(set_contains(included, "extra/mylib.dll"),
    "single-entry: exact path excluded")
end

----------------------------------------------------------------------
print("\n=== Test 6: Missing lib file produces warning ===")
----------------------------------------------------------------------
do
  local missing_libs = {}
  local function exists_fn(path)
    if path == "libs/missing.dll" then
      return false
    end
    return true
  end
  -- Simulate readConfig behavior for missing files
  local libs_config = {
    windows = { "libs/missing.dll", "libs/exists.dll" }
  }
  local ignore = {}
  for key, value in pairs(libs_config) do
    if key == 'windows' then
      for l = 1, #value do
        local filepath = value[l]
        if exists_fn(filepath) then
          table.insert(ignore, filepath)
        else
          table.insert(missing_libs, filepath)
        end
      end
    end
  end
  assert_eq(#missing_libs, 1, "one missing lib detected")
  assert_eq(missing_libs[1], "libs/missing.dll", "correct missing file reported")
  assert_eq(#ignore, 1, "only existing lib added to ignore")
end

----------------------------------------------------------------------
print("\n=== Test 7: Backward compatibility - basename ignore entries ===")
----------------------------------------------------------------------
-- Ensure old-style ignore entries (basenames like ".git", ".DS_Store")
-- still work correctly.
-- Note: In the real addFolder(), when a directory like ".git" is ignored,
-- recursion stops and none of its children are visited. Here we simulate
-- that by testing directory entries (not their children).
do
  -- Simulate top-level items returned by getDirectoryItems("project")
  local top_level_items = { "main.lua", ".git", ".DS_Store", "src" }
  local ignore = { ".git", ".DS_Store", ".github" }

  -- Check each top-level item
  assert_false(is_ignored("main.lua", "", ignore), "main.lua not ignored")
  assert_true(is_ignored(".git", "", ignore), ".git directory ignored by basename")
  assert_true(is_ignored(".DS_Store", "", ignore), ".DS_Store ignored by basename")
  assert_false(is_ignored("src", "", ignore), "src directory not ignored")

  -- Inside src/ subfolder, items would have prefix "src/"
  assert_false(is_ignored("main.lua", "src/", ignore), "src/main.lua not ignored")
end

----------------------------------------------------------------------
-- Summary
----------------------------------------------------------------------
print("\n" .. string.rep("=", 50))
print(string.format("Results: %d passed, %d failed, %d total",
  passed, failed, passed + failed))
print(string.rep("=", 50))

if failed > 0 then
  os.exit(1)
else
  print("All tests passed!")
  os.exit(0)
end
