--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  Type modules detection tests
  Verifies TypeRegistry.detectType finds all registered types

  Types registered:
  - TransformerNumericType: 'inteditor', 'floateditor'
  - TransformerMenuType: 'menu', 'param3', 'hidden'
  - TransformerTimeType: 'time', 'timedur' (requires TimeUtils which needs reaper stub)
  - TransformerQuantizeType: 'quantize' (too many deps, skip)
  - Shims in TransformerLib: 'everyn', 'newmidievent', 'eventselector', 'metricgrid', 'musical' (skip, lib deps heavy)
--]]

-- setup package path (pwd-based for subprocess execution)
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
package.path = projectRoot .. "tests/helpers/?.lua;" .. package.path

-- load REAPER stub (needed by TimeUtils which is used by TransformerTimeType)
reaper = require("reaper_stub")

-- require type modules (they self-register on load)
local TypeRegistry = require("TransformerTypeRegistry")

-- numeric types: inteditor, floateditor
require("types/TransformerNumericType")

-- menu types: menu, param3, hidden
require("types/TransformerMenuType")

-- time types: time, timedur
require("types/TransformerTimeType")

-- NOTE: skipping TransformerQuantizeType - too many deps (TransformerQuantizeUI, TransformerGlobal)
-- NOTE: skipping TransformerLib shims - require full lib with many deps

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
    error((msg or "assertion failed") .. ": expected '" .. tostring(expected) .. "', got '" .. tostring(actual) .. "'")
  end
end

local function assertNil(val, msg)
  if val ~= nil then
    error((msg or "assertion failed") .. ": expected nil, got '" .. tostring(val) .. "'")
  end
end

-- numeric type detection
test("detectType: inteditor", function()
  local name = TypeRegistry.detectType({ inteditor = true })
  assertEqual("inteditor", name)
end)

test("detectType: floateditor", function()
  local name = TypeRegistry.detectType({ floateditor = true })
  assertEqual("floateditor", name)
end)

-- menu type detection
test("detectType: menu", function()
  local name = TypeRegistry.detectType({ menu = true })
  assertEqual("menu", name)
end)

test("detectType: param3", function()
  local name = TypeRegistry.detectType({ param3 = true })
  assertEqual("param3", name)
end)

test("detectType: hidden", function()
  local name = TypeRegistry.detectType({ hidden = true })
  assertEqual("hidden", name)
end)

-- time type detection
test("detectType: time", function()
  local name = TypeRegistry.detectType({ time = true })
  assertEqual("time", name)
end)

test("detectType: timedur", function()
  local name = TypeRegistry.detectType({ timedur = true })
  assertEqual("timedur", name)
end)

-- negative tests
test("detectType: empty source returns nil", function()
  local name = TypeRegistry.detectType({})
  assertNil(name)
end)

test("detectType: unknown property returns nil", function()
  local name = TypeRegistry.detectType({ unknowntype = true })
  assertNil(name)
end)

test("detectType: nil source returns nil", function()
  local name = TypeRegistry.detectType(nil)
  assertNil(name)
end)

-- verify all expected types are registered
test("hasType: inteditor registered", function()
  assertEqual(true, TypeRegistry.hasType("inteditor"))
end)

test("hasType: floateditor registered", function()
  assertEqual(true, TypeRegistry.hasType("floateditor"))
end)

test("hasType: menu registered", function()
  assertEqual(true, TypeRegistry.hasType("menu"))
end)

test("hasType: param3 registered", function()
  assertEqual(true, TypeRegistry.hasType("param3"))
end)

test("hasType: hidden registered", function()
  assertEqual(true, TypeRegistry.hasType("hidden"))
end)

test("hasType: time registered", function()
  assertEqual(true, TypeRegistry.hasType("time"))
end)

test("hasType: timedur registered", function()
  assertEqual(true, TypeRegistry.hasType("timedur"))
end)

-- summary
if failed > 0 then
  print(string.format("\n%d/%d passed", passed, passed + failed))
  os.exit(1)
else
  os.exit(0)
end
