--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  TransformerContext unit tests
  Tests Context class pattern via TransformerGlobal.class()

  NOTE: TransformerLib.TransformerContext cannot be tested directly due to
  heavy dependencies (MIDIUtils, ReaImGui, etc). Instead we test:
  1. The class() function pattern from TransformerGlobal
  2. A mock Context class with same init/accessor pattern

  This validates the class infrastructure used by TransformerContext.
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

-- load REAPER stub (needed by TransformerGlobal if it uses any REAPER calls)
reaper = require("reaper_stub")

-- require TransformerGlobal for class() function
local tg = require("TransformerGlobal")

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

local function assertTrue(val, msg)
  if not val then
    error((msg or "assertion failed") .. ": expected true, got " .. tostring(val))
  end
end

-- Create a mock Context class matching TransformerContext structure
local MockContext = tg.class()

function MockContext:init()
  -- same pattern as TransformerContext:init()
  self._allEvents = {}
  self._selectedEvents = {}
  self._gridInfo = { currentGrid = 0, currentSwing = 0 }
  self._rangeFilterGridOverride = nil
  self._contextInfo = nil
end

function MockContext:allEvents()
  return self._allEvents
end

function MockContext:selectedEvents()
  return self._selectedEvents
end

function MockContext:gridInfo()
  return self._gridInfo
end

function MockContext:setRangeFilterGrid(grid)
  self._rangeFilterGridOverride = grid
end

function MockContext:getRangeFilterGrid()
  return self._rangeFilterGridOverride
end

function MockContext:setContextInfo(info)
  self._contextInfo = info
end

function MockContext:getContextInfo()
  return self._contextInfo
end

-- Tests for class() factory
test("class(): creates callable constructor", function()
  local ctx = MockContext()
  assertTrue(ctx ~= nil, "should create instance")
end)

test("class(): init sets empty _allEvents table", function()
  local ctx = MockContext()
  local events = ctx:allEvents()
  assertTrue(type(events) == "table", "should return table")
  assertEqual(0, #events, "should be empty")
end)

test("class(): init sets empty _selectedEvents table", function()
  local ctx = MockContext()
  local events = ctx:selectedEvents()
  assertTrue(type(events) == "table", "should return table")
  assertEqual(0, #events, "should be empty")
end)

test("class(): gridInfo returns defaults", function()
  local ctx = MockContext()
  local info = ctx:gridInfo()
  assertEqual(0, info.currentGrid, "currentGrid default")
  assertEqual(0, info.currentSwing, "currentSwing default")
end)

test("class(): setRangeFilterGrid/getRangeFilterGrid", function()
  local ctx = MockContext()
  assertEqual(nil, ctx:getRangeFilterGrid(), "initial nil")
  ctx:setRangeFilterGrid(960)
  assertEqual(960, ctx:getRangeFilterGrid(), "after set")
end)

test("class(): setContextInfo/getContextInfo", function()
  local ctx = MockContext()
  assertEqual(nil, ctx:getContextInfo(), "initial nil")
  local info = { take = "fake-take", track = "fake-track" }
  ctx:setContextInfo(info)
  local retrieved = ctx:getContextInfo()
  assertEqual("fake-take", retrieved.take, "take preserved")
  assertEqual("fake-track", retrieved.track, "track preserved")
end)

test("class(): multiple instances are independent", function()
  local ctx1 = MockContext()
  local ctx2 = MockContext()
  ctx1:setRangeFilterGrid(100)
  ctx2:setRangeFilterGrid(200)
  assertEqual(100, ctx1:getRangeFilterGrid(), "ctx1 unchanged")
  assertEqual(200, ctx2:getRangeFilterGrid(), "ctx2 independent")
end)

test("class(): is_a returns true for same class", function()
  local ctx = MockContext()
  assertTrue(ctx:is_a(MockContext), "is_a MockContext")
end)

-- Test ParamInfo class pattern
test("ParamInfo: creates with defaults", function()
  local pi = tg.ParamInfo()
  assertEqual(1, pi.menuEntry, "menuEntry default")
  assertEqual("0", pi.textEditorStr, "textEditorStr default")
  assertEqual("1.1.00", pi.timeFormatStr, "timeFormatStr default")
end)

-- summary
if failed > 0 then
  print(string.format("\n%d/%d passed", passed, passed + failed))
  os.exit(1)
else
  os.exit(0)
end
