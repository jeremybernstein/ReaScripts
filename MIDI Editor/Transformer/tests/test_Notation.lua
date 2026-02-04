--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  Notation module unit tests
  Tests: getParamPercentTerm code generation, handleMacroParam percent parsing

  Limitations:
  - processFindMacro, processActionMacro need full fdefs/adefs setup
  - findRowToNotation, actionRowToNotation need integration test
  - These would require full TransformerLib loading (too heavy for unit tests)
--]]

-- setup package path
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
package.path = projectRoot .. "?.lua;" .. projectRoot .. "tests/helpers/?.lua;" .. package.path

-- stub REAPER before loading any modules
reaper = require("reaper_stub")

-- stub MIDIUtils (Notation requires it)
package.loaded["MIDIUtils"] = {
  post = function() end,
  tprint = function() end
}

-- load module under test
local Notation = require("TransformerNotation")
local gdefs = require("TransformerGeneralDefs")
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
    error((msg or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function assertTrue(val, msg)
  if not val then
    error((msg or "assertion failed") .. ": expected true, got " .. tostring(val))
  end
end

local function assertNear(expected, actual, tolerance, msg)
  tolerance = tolerance or 1
  if math.abs(expected - actual) > tolerance then
    error((msg or "assertion failed") .. ": expected ~" .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

--------------------------------------------------------------------------------
-- getParamPercentTerm tests - verify generated code EXECUTES and returns correct values
--------------------------------------------------------------------------------

-- helper to execute generated code with mocked event
local function execPercentTerm(percent, bipolar, chanmsg)
  local code = Notation.getParamPercentTerm(percent, bipolar)
  -- create environment with event mock
  local env = {
    event = { chanmsg = chanmsg or 0xE0 },  -- 0xE0 = pitch bend (14-bit), else 7-bit
    math = math
  }
  local fn, err = load("return " .. code, "percent_term", "t", env)
  if not fn then
    error("failed to compile: " .. tostring(err) .. "\ncode: " .. code)
  end
  return fn()
end

-- 14-bit max = (1 << 14) - 1 = 16383
-- 7-bit max = (1 << 7) - 1 = 127

test("getParamPercentTerm(50, false) - 50% of 14-bit max", function()
  local result = execPercentTerm(50, false, 0xE0)  -- pitch bend = 14-bit
  local expected = math.floor(0.5 * 16383 + 0.5)   -- ~8191
  assertNear(expected, result, 1, "50% of 14-bit")
end)

test("getParamPercentTerm(100, false) - 100% of 14-bit max", function()
  local result = execPercentTerm(100, false, 0xE0)
  local expected = math.floor(1.0 * 16383 + 0.5)  -- 16383
  assertEqual(expected, result, "100% of 14-bit")
end)

test("getParamPercentTerm(0, false) - 0% returns 0", function()
  local result = execPercentTerm(0, false, 0xE0)
  assertEqual(0, result, "0% should be 0")
end)

test("getParamPercentTerm(50, false) - 7-bit context", function()
  local result = execPercentTerm(50, false, 0xB0)  -- CC = 7-bit
  local expected = math.floor(0.5 * 127 + 0.5)    -- ~63
  assertNear(expected, result, 1, "50% of 7-bit")
end)

test("getParamPercentTerm(100, false) - 7-bit max", function()
  local result = execPercentTerm(100, false, 0xB0)
  local expected = math.floor(1.0 * 127 + 0.5)   -- 127
  assertEqual(expected, result, "100% of 7-bit")
end)

test("getParamPercentTerm(-50, true) - bipolar negative", function()
  local result = execPercentTerm(-50, true, 0xE0)
  -- bipolar allows -100 to 100, so -50% => -0.5 * 16383
  local expected = math.floor(-0.5 * 16383 + 0.5)  -- ~-8191
  assertNear(expected, result, 1, "bipolar -50%")
end)

test("getParamPercentTerm(150, false) - allows > 100%", function()
  -- NOTE: getParamPercentTerm does NOT clamp >100% values
  -- (clamping happens earlier in handleMacroParam)
  local result = execPercentTerm(150, false, 0xE0)
  local expected = math.floor(1.5 * 16383 + 0.5)  -- 150% = 1.5x
  assertNear(expected, result, 1, "150% should produce 1.5x value")
end)

test("getParamPercentTerm(-50, false) - unipolar clamps negative to 0", function()
  -- unipolar (bipolar=false) should clamp negative to 0
  local result = execPercentTerm(-50, false, 0xE0)
  assertEqual(0, result, "unipolar should clamp negative to 0")
end)

--------------------------------------------------------------------------------
-- handleMacroParam tests - percent notation parsing
--------------------------------------------------------------------------------

-- mock helpers for handleMacroParam
local function makeHelpers(opts)
  opts = opts or {}
  return {
    getParamTypesForRow = function() return opts.paramTypes or {} end,
    opIsBipolar = function() return opts.bipolar or false end,
    check14Bit = function() return opts.has14bit or false, opts.hasOther or false end,
    PARAM_PERCENT_RANGE = { 0, 100 },
    PARAM_PERCENT_BIPOLAR_RANGE = { -100, 100 },
    PARAM_PITCHBEND_RANGE = gdefs.EDITOR_PITCHBEND_RANGE,
    PARAM_PITCHBEND_BIPOLAR_RANGE = gdefs.EDITOR_PITCHBEND_BIPOLAR_RANGE,
  }
end

-- mock row with params
local function makeRow()
  return {
    params = {
      [1] = tg.ParamInfo(),
      [2] = tg.ParamInfo()
    }
  }
end

test("handleMacroParam parses percent<50>", function()
  local row = makeRow()
  local helpers = makeHelpers()
  local target = {}
  local condOp = {}
  local paramTab = {}

  Notation.handleMacroParam(row, target, condOp, paramTab, "percent<50>", 1, helpers)

  assertEqual(50, row.params[1].percentVal, "percentVal should be 50")
  assertEqual("50", row.params[1].textEditorStr, "textEditorStr should be '50'")
end)

test("handleMacroParam parses percent<-25> with bipolar", function()
  local row = makeRow()
  local helpers = makeHelpers({ bipolar = true })
  local target = {}
  local condOp = {}
  local paramTab = {}

  Notation.handleMacroParam(row, target, condOp, paramTab, "percent<-25>", 1, helpers)

  assertEqual(-25, row.params[1].percentVal, "percentVal should be -25")
  assertEqual("-25", row.params[1].textEditorStr, "textEditorStr should be '-25'")
end)

test("handleMacroParam clamps percent<150> to 100", function()
  local row = makeRow()
  local helpers = makeHelpers()
  local target = {}
  local condOp = {}
  local paramTab = {}

  Notation.handleMacroParam(row, target, condOp, paramTab, "percent<150>", 1, helpers)

  assertEqual(100, row.params[1].percentVal, "percentVal should clamp to 100")
end)

test("handleMacroParam clamps percent<-50> to 0 for unipolar", function()
  local row = makeRow()
  local helpers = makeHelpers({ bipolar = false })
  local target = {}
  local condOp = {}
  local paramTab = {}

  Notation.handleMacroParam(row, target, condOp, paramTab, "percent<-50>", 1, helpers)

  assertEqual(0, row.params[1].percentVal, "percentVal should clamp to 0 for unipolar")
end)

test("handleMacroParam returns textEditorStr", function()
  local row = makeRow()
  local helpers = makeHelpers()
  local target = {}
  local condOp = {}
  local paramTab = {}

  local result = Notation.handleMacroParam(row, target, condOp, paramTab, "percent<75>", 1, helpers)

  assertEqual("75", result, "should return textEditorStr")
end)

--------------------------------------------------------------------------------
-- summary
--------------------------------------------------------------------------------

if failed > 0 then
  print(string.format("\n%d/%d passed", passed, passed + failed))
  os.exit(1)
else
  os.exit(0)
end
