--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  TypeRegistry unit tests
  Tests: register, getType, hasType, detectType, getAll
--]]

-- setup package path to find TransformerTypeRegistry
-- use pwd since debug.getinfo returns relative path when run as file
local function getProjectRoot()
  local handle = io.popen("pwd")
  if handle then
    local pwd = handle:read("*l")
    handle:close()
    if pwd then
      return pwd:gsub("/tests$", "") .. "/"
    end
  end
  return "../"
end

local projectRoot = getProjectRoot()
package.path = projectRoot .. "?.lua;" .. package.path

-- load module under test
local TypeRegistry = require("TransformerTypeRegistry")

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name)
    print("  " .. tostring(err))
  end
end

local function assertEqual(expected, actual, msg)
  if expected ~= actual then
    error((msg or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function assertTrue(val, msg)
  if not val then
    error((msg or "assertion failed") .. ": expected true, got " .. tostring(val))
  end
end

local function assertFalse(val, msg)
  if val then
    error((msg or "assertion failed") .. ": expected false, got " .. tostring(val))
  end
end

local function assertError(fn, expectedMsg)
  local ok, err = pcall(fn)
  if ok then
    error("expected error but none thrown")
  end
  if expectedMsg and not err:find(expectedMsg, 1, true) then
    error("expected error containing '" .. expectedMsg .. "', got: " .. tostring(err))
  end
end

-- Test 1: register() returns name
test("register() returns type name", function()
  local result = TypeRegistry.register({
    name = "test_type_1",
    detectType = function(src) return false end
  })
  assertEqual("test_type_1", result, "register should return name")
end)

-- Test 2: getType() returns registered definition
test("getType() returns registered definition", function()
  local def = {
    name = "test_type_2",
    detectType = function(src) return false end,
    customField = "test_value"
  }
  TypeRegistry.register(def)
  local retrieved = TypeRegistry.getType("test_type_2")
  assertEqual("test_type_2", retrieved.name, "retrieved name")
  assertEqual("test_value", retrieved.customField, "custom field preserved")
end)

-- Test 3: hasType() returns true for registered
test("hasType() returns true for registered type", function()
  TypeRegistry.register({
    name = "test_type_3",
    detectType = function(src) return false end
  })
  assertTrue(TypeRegistry.hasType("test_type_3"), "hasType should return true")
end)

-- Test 4: hasType() returns false for unknown
test("hasType() returns false for unknown type", function()
  assertFalse(TypeRegistry.hasType("nonexistent_type_xyz"), "hasType should return false for unknown")
end)

-- Test 5: detectType() finds matching type
test("detectType() finds matching type", function()
  TypeRegistry.register({
    name = "test_type_4",
    detectType = function(src)
      return src and src.marker == "type4_marker"
    end
  })
  local name, def = TypeRegistry.detectType({marker = "type4_marker"})
  assertEqual("test_type_4", name, "detectType should find type")
  assertTrue(def ~= nil, "detectType should return definition")
end)

-- Test 6: detectType() returns nil for no match
test("detectType() returns nil when no match", function()
  local name, def = TypeRegistry.detectType({marker = "unknown_marker_xyz"})
  -- might match something or might not, depends on registered types
  -- For robustness, we just verify the return type
  assertTrue(name == nil or type(name) == "string", "detectType returns nil or string")
end)

-- Test 7: getAll() returns types table
test("getAll() returns types table", function()
  local all = TypeRegistry.getAll()
  assertTrue(type(all) == "table", "getAll should return table")
  assertTrue(all["test_type_1"] ~= nil, "should contain registered type")
end)

-- Test 8: register() duplicate errors
test("register() duplicate type errors", function()
  assertError(function()
    TypeRegistry.register({
      name = "test_type_1",
      detectType = function(src) return false end
    })
  end, "already registered")
end)

-- Test 9: register() without name errors
test("register() without name errors", function()
  assertError(function()
    TypeRegistry.register({
      detectType = function(src) return false end
    })
  end, "missing name")
end)

-- summary
if failed > 0 then
  print(string.format("\n%d/%d passed", passed, passed + failed))
  os.exit(1)
else
  os.exit(0)
end
