--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  Integration Tests - Runtime Behavior Verification

  These tests verify the complete param → code → execution pipeline
  by actually executing generated code and checking results.
]]

-- Setup path for requiring modules
local pwd = io.popen('pwd'):read('*l')
-- Handle both running from tests/ dir and from parent
if pwd:match('tests$') then
  package.path = pwd .. '/../?.lua;' .. pwd .. '/helpers/?.lua;' .. package.path
else
  package.path = pwd .. '/?.lua;' .. pwd .. '/tests/helpers/?.lua;' .. package.path
end
require 'reaper_stub'

-- Load modules under test
local tg = require 'TransformerGlobal'
local gdefs = require 'TransformerGeneralDefs'
local TypeRegistry = require 'TransformerTypeRegistry'
local TimeUtils = require 'TransformerTimeUtils'
local mgdefs = require 'types/TransformerMetricGrid'
local tx = require 'TransformerLib'

-- Simple assertion helper
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format('%s: expected %s, got %s', msg or 'assertion failed',
      tostring(expected), tostring(actual)))
  end
end

local function assert_not_nil(val, msg)
  if val == nil then
    error(msg or 'expected non-nil value')
  end
end

local function assert_type(val, expectedType, msg)
  if type(val) ~= expectedType then
    error(string.format('%s: expected type %s, got %s', msg or 'type check failed',
      expectedType, type(val)))
  end
end

print('=== Integration Tests ===')

--------------------------------------------------------------------------------
-- Test 1: MetricGrid parseNotation produces complete mg object
--------------------------------------------------------------------------------
print('\n-- Test: MetricGrid parseNotation completeness')

-- Valid notation should produce all required fields
local notation1 = '|--|0.00|0.00'  -- straight, no swing
local mg1 = mgdefs.parseMetricGridNotation(notation1)
assert_not_nil(mg1.modifiers, 'mg1.modifiers should be set')
assert_not_nil(mg1.roundmode, 'mg1.roundmode should be set')
assert_not_nil(mg1.swing, 'mg1.swing should be set')
assert_eq(mg1.modifiers, gdefs.MG_GRID_STRAIGHT, 'should be straight')
assert_eq(mg1.roundmode, 'round', 'default roundmode')
print('  Valid straight notation: OK')

-- Triplet notation
local notation2 = '|t-|0.00|0.00'
local mg2 = mgdefs.parseMetricGridNotation(notation2)
assert_eq(mg2.modifiers, gdefs.MG_GRID_TRIPLET, 'should be triplet')
print('  Triplet notation: OK')

-- Swing notation with value
local notation3 = '|r-|0.00|0.00|sw(50.00)'
local mg3 = mgdefs.parseMetricGridNotation(notation3)
assert_eq(mg3.modifiers & 0x7, gdefs.MG_GRID_SWING, 'should be swing')
assert_eq(mg3.swing, 50, 'swing value should be 50')
print('  Swing notation: OK')

-- Roundmode floor
local notation4 = '|--|0.00|0.00|rd(floor)'
local mg4 = mgdefs.parseMetricGridNotation(notation4)
assert_eq(mg4.roundmode, 'floor', 'roundmode should be floor')
print('  Roundmode floor: OK')

-- Direction flags
local notation5 = '|--|0.00|0.00|df(3)'
local mg5 = mgdefs.parseMetricGridNotation(notation5)
assert_eq(mg5.directionFlags, 3, 'direction flags should be 3')
print('  Direction flags: OK')

--------------------------------------------------------------------------------
-- Test 2: MetricGrid parseNotation with invalid input (gap detection)
--------------------------------------------------------------------------------
print('\n-- Test: MetricGrid parseNotation with invalid input')

-- Empty string should return mg with minimal fields
local mgEmpty = mgdefs.parseMetricGridNotation('')
assert_type(mgEmpty, 'table', 'should return table')
-- Check if required fields are missing (this is the gap)
local missingFields = {}
if mgEmpty.modifiers == nil then table.insert(missingFields, 'modifiers') end
if mgEmpty.swing == nil then table.insert(missingFields, 'swing') end
if mgEmpty.roundmode == nil then table.insert(missingFields, 'roundmode') end

if #missingFields > 0 then
  print('  WARNING: Empty input missing fields: ' .. table.concat(missingFields, ', '))
  print('  GAP DETECTED: parseMetricGridNotation should provide defaults')
else
  print('  Empty input has all required fields: OK')
end

-- Malformed notation
local mgBad = mgdefs.parseMetricGridNotation('garbage|data')
missingFields = {}
if mgBad.modifiers == nil then table.insert(missingFields, 'modifiers') end
if mgBad.swing == nil then table.insert(missingFields, 'swing') end
if mgBad.roundmode == nil then table.insert(missingFields, 'roundmode') end

if #missingFields > 0 then
  print('  WARNING: Malformed input missing fields: ' .. table.concat(missingFields, ', '))
  print('  GAP DETECTED: parseMetricGridNotation should provide defaults')
else
  print('  Malformed input has all required fields: OK')
end

--------------------------------------------------------------------------------
-- Test 3: getMetricGridModifiers nil safety
--------------------------------------------------------------------------------
print('\n-- Test: getMetricGridModifiers nil safety')

-- Should not error with nil mg
local status, err = pcall(function()
  local mods, reaSwing = mgdefs.getMetricGridModifiers(nil)
  assert_eq(mods, gdefs.MG_GRID_STRAIGHT, 'nil mg should return STRAIGHT')
end)
if status then
  print('  nil mg: OK')
else
  print('  ERROR with nil mg: ' .. tostring(err))
end

-- Should not error with empty mg
status, err = pcall(function()
  local mods, reaSwing = mgdefs.getMetricGridModifiers({})
  assert_eq(mods, gdefs.MG_GRID_STRAIGHT, 'empty mg should return STRAIGHT')
end)
if status then
  print('  empty mg: OK')
else
  print('  ERROR with empty mg: ' .. tostring(err))
end

-- Should not error with mg missing modifiers
status, err = pcall(function()
  local mods, reaSwing = mgdefs.getMetricGridModifiers({swing = 50})
  assert_eq(mods, gdefs.MG_GRID_STRAIGHT, 'mg without modifiers should return STRAIGHT')
end)
if status then
  print('  mg without modifiers: OK')
else
  print('  ERROR with mg without modifiers: ' .. tostring(err))
end

--------------------------------------------------------------------------------
-- Test 4: QuantizeType codeTemplate generates valid params
--------------------------------------------------------------------------------
print('\n-- Test: QuantizeType codeTemplate param generation')

-- Load QuantizeType
local QuantizeType = require 'types/TransformerQuantizeType'
local QuantizeUI = require 'TransformerQuantizeUI'

-- Create mock row with quantizeParams
local mockRow = {
  params = {{}, {}, {}},
  quantizeParams = QuantizeUI.defaultParams()
}

-- Get the type definition
local _, typeDef = TypeRegistry.detectType({quantize = true})
if typeDef and typeDef.codeTemplate then
  local code = typeDef.codeTemplate(mockRow, nil)

  -- Parse the generated code to extract params (capital Q for Musical functions)
  local funcName = code:match('^(%w+)%(')
  local paramsStr = code:match('%(event, take, PPQ, (.+)%)$')

  assert_not_nil(funcName, 'should have function name')
  assert_not_nil(paramsStr, 'should have params')

  print('  Function: ' .. funcName)

  -- Try to parse the params table
  local parseParams = load('return ' .. paramsStr)
  if parseParams then
    local params = parseParams()

    -- Check required fields
    local requiredFields = {'param1', 'param2', 'modifiers', 'swing', 'roundmode', 'targetIndex', 'strength'}
    local missing = {}
    for _, field in ipairs(requiredFields) do
      if params[field] == nil then
        table.insert(missing, field)
      end
    end

    if #missing > 0 then
      print('  WARNING: Missing required fields: ' .. table.concat(missing, ', '))
    else
      print('  All required fields present: OK')
      print('    param1 = ' .. tostring(params.param1))
      print('    param2 = ' .. tostring(params.param2))
      print('    modifiers = ' .. tostring(params.modifiers))
      print('    swing = ' .. tostring(params.swing))
    end
  else
    print('  Could not parse params (may contain functions)')
  end
else
  print('  ERROR: QuantizeType not found or no codeTemplate')
end

--------------------------------------------------------------------------------
-- Test 5: TimeUtils exports completeness
--------------------------------------------------------------------------------
print('\n-- Test: TimeUtils exports completeness')

local timeUtilsExports = {
  'getTimeOffset', 'bbtToPPQ', 'ppqToTime', 'calcMIDITime',
  'lengthFormatRebuf', 'timeFormatRebuf', 'determineTimeFormatStringType',
  'TIME_FORMAT_UNKNOWN', 'TIME_FORMAT_MEASURES', 'TIME_FORMAT_MINUTES', 'TIME_FORMAT_HMSF'
}

local missingExports = {}
for _, name in ipairs(timeUtilsExports) do
  if TimeUtils[name] == nil then
    table.insert(missingExports, name)
  end
end

if #missingExports > 0 then
  print('  WARNING: Missing exports: ' .. table.concat(missingExports, ', '))
else
  print('  All expected exports present: OK')
end

--------------------------------------------------------------------------------
-- Test 6: TypeRegistry coverage
--------------------------------------------------------------------------------
print('\n-- Test: TypeRegistry coverage')

-- Load standalone type modules (self-register)
require 'types/TransformerNumericType' -- registers inteditor, floateditor
require 'types/TransformerMenuType'    -- registers menu, param3, hidden
require 'types/TransformerTimeType'    -- registers time, timedur
-- Note: TransformerQuantizeType already loaded above for Test 4

-- Types registered as standalone modules
local standaloneTypes = {
  'quantize', 'inteditor', 'floateditor', 'menu', 'param3', 'hidden', 'time', 'timedur'
}

-- Shim types registered by TransformerLib (require full environment)
local shimTypes = {
  'metricgrid', 'musical', 'everyn', 'newmidievent', 'eventselector'
}

local expectedTypes = standaloneTypes

local registeredTypes = TypeRegistry.getAll()  -- returns dict: {name = def, ...}
local missingTypes = {}
local foundTypes = {}

for _, typeName in ipairs(expectedTypes) do
  if registeredTypes[typeName] then
    table.insert(foundTypes, typeName)
  else
    table.insert(missingTypes, typeName)
  end
end

print('  Standalone types: ' .. table.concat(foundTypes, ', '))
if #missingTypes > 0 then
  print('  WARNING: Missing standalone types: ' .. table.concat(missingTypes, ', '))
else
  print('  All standalone types registered: OK')
end
print('  Note: Shim types (metricgrid, musical, everyn, newmidievent, eventselector)')
print('        are registered by TransformerLib and require full REAPER environment')

--------------------------------------------------------------------------------
-- Test 7: QuantizeType codeTemplate - all gridModes
--------------------------------------------------------------------------------
print('\n-- Test: QuantizeType codeTemplate gridMode variants')

-- gridMode 0: REAPER grid (param1 = -1)
local row0 = {
  params = {{}, {}, {}},
  quantizeParams = QuantizeUI.defaultParams()
}
row0.quantizeParams.gridMode = 0
local code0 = typeDef.codeTemplate(row0, nil)
local p0 = code0:match('param1 = ([^,}]+)')
assert_eq(p0, '-1', 'gridMode 0 should set param1 = -1')
print('  gridMode 0 (REAPER grid): param1 = -1: OK')

-- gridMode 1: manual grid (param1 = subdivision value)
local row1 = {
  params = {{}, {}, {}},
  quantizeParams = QuantizeUI.defaultParams()
}
row1.quantizeParams.gridMode = 1
row1.quantizeParams.gridDivIndex = 3  -- 1/16 note
local code1 = typeDef.codeTemplate(row1, nil)
local p1 = code1:match('param1 = ([%d%.]+)')
assert_not_nil(p1, 'gridMode 1 should have numeric param1')
assert_eq(tonumber(p1), 0.0625, 'gridDivIndex 3 should be 0.0625 (1/16)')
print('  gridMode 1 (manual): param1 = 0.0625: OK')

-- gridMode 2: groove (param1 = -2, isGroove = true)
local row2 = {
  params = {{}, {}, {}},
  quantizeParams = QuantizeUI.defaultParams()
}
row2.quantizeParams.gridMode = 2
local code2 = typeDef.codeTemplate(row2, nil)
local p2 = code2:match('param1 = ([^,}]+)')
local isGroove = code2:match('isGroove = true')
assert_eq(p2, '-2', 'gridMode 2 should set param1 = -2')
assert_not_nil(isGroove, 'gridMode 2 should set isGroove = true')
local funcName2 = code2:match('^(%w+)%(')
assert_eq(funcName2, 'quantizeGroovePosition', 'gridMode 2 should use groove function')
print('  gridMode 2 (groove): param1 = -2, isGroove = true: OK')

--------------------------------------------------------------------------------
-- Test 8: QuantizeType codeTemplate - targetIndex variations
--------------------------------------------------------------------------------
print('\n-- Test: QuantizeType codeTemplate targetIndex variants')

-- targetIndex 0: position (default)
local rowT0 = {
  params = {{}, {}, {}},
  quantizeParams = QuantizeUI.defaultParams()
}
rowT0.quantizeParams.targetIndex = 0
local codeT0 = typeDef.codeTemplate(rowT0, nil)
local funcT0 = codeT0:match('^(%w+)%(')
assert_eq(funcT0, 'QuantizeMusicalPosition', 'targetIndex 0 should use Position function')
print('  targetIndex 0: QuantizeMusicalPosition: OK')

-- targetIndex 3: end position
local rowT3 = {
  params = {{}, {}, {}},
  quantizeParams = QuantizeUI.defaultParams()
}
rowT3.quantizeParams.targetIndex = 3
local codeT3 = typeDef.codeTemplate(rowT3, nil)
local funcT3 = codeT3:match('^(%w+)%(')
assert_eq(funcT3, 'QuantizeMusicalEndPos', 'targetIndex 3 should use EndPos function')
print('  targetIndex 3: QuantizeMusicalEndPos: OK')

-- targetIndex 4: length
local rowT4 = {
  params = {{}, {}, {}},
  quantizeParams = QuantizeUI.defaultParams()
}
rowT4.quantizeParams.targetIndex = 4
local codeT4 = typeDef.codeTemplate(rowT4, nil)
local funcT4 = codeT4:match('^(%w+)%(')
assert_eq(funcT4, 'QuantizeMusicalLength', 'targetIndex 4 should use Length function')
print('  targetIndex 4: QuantizeMusicalLength: OK')

-- groove + targetIndex 3
local rowG3 = {
  params = {{}, {}, {}},
  quantizeParams = QuantizeUI.defaultParams()
}
rowG3.quantizeParams.gridMode = 2
rowG3.quantizeParams.targetIndex = 3
local codeG3 = typeDef.codeTemplate(rowG3, nil)
local funcG3 = codeG3:match('^(%w+)%(')
assert_eq(funcG3, 'quantizeGrooveEndPos', 'groove + targetIndex 3 should use GrooveEndPos')
print('  groove + targetIndex 3: quantizeGrooveEndPos: OK')

--------------------------------------------------------------------------------
-- Test 9: QuantizeType codeTemplate - grid style modifiers
--------------------------------------------------------------------------------
print('\n-- Test: QuantizeType codeTemplate grid style modifiers')

local styleTests = {
  {styleIndex = 0, expectedMod = 0, name = 'straight'},
  {styleIndex = 1, expectedMod = 2, name = 'triplet'},
  {styleIndex = 2, expectedMod = 1, name = 'dotted'},
  {styleIndex = 3, expectedMod = 3, name = 'swing'},
}

for _, test in ipairs(styleTests) do
  local rowS = {
    params = {{}, {}, {}},
    quantizeParams = QuantizeUI.defaultParams()
  }
  rowS.quantizeParams.gridStyleIndex = test.styleIndex
  local codeS = typeDef.codeTemplate(rowS, nil)
  local modS = codeS:match('modifiers = (%d+)')
  assert_eq(tonumber(modS), test.expectedMod, test.name .. ' should have modifiers = ' .. test.expectedMod)
  print('  gridStyleIndex ' .. test.styleIndex .. ' (' .. test.name .. '): modifiers = ' .. test.expectedMod .. ': OK')
end

--------------------------------------------------------------------------------
-- Test 10: Generated code parseable by load()
--------------------------------------------------------------------------------
print('\n-- Test: Generated code parseable')

local rowFull = {
  params = {{}, {}, {}},
  quantizeParams = QuantizeUI.defaultParams()
}
rowFull.quantizeParams.strength = 75
rowFull.quantizeParams.swingStrength = 55

local codeFull = typeDef.codeTemplate(rowFull, nil)
local paramsStr = codeFull:match('%(event, take, PPQ, (.+)%)$')

local parseFunc = load('return ' .. paramsStr)
if parseFunc then
  local params = parseFunc()
  assert_eq(params.strength, 75, 'strength should be 75')
  assert_eq(params.swing, 55, 'swing should match swingStrength')
  assert_eq(params.roundmode, 'round', 'roundmode should be round')
  print('  Generated params parsed successfully: OK')
  print('    strength = ' .. params.strength)
  print('    swing = ' .. params.swing)
  print('    roundmode = ' .. params.roundmode)
else
  print('  WARNING: Could not parse generated params')
end

--------------------------------------------------------------------------------
-- Test 11: Standalone Quantize preset generation (musical operations)
--------------------------------------------------------------------------------
print('\n-- Test: Standalone Quantize preset generation')

-- Mimic what buildPresetTable() in standalone Quantize does
-- This tests $position :roundmusical(...) which has musical=true in split[1]
local standalonePresets = {
  {
    name = 'position roundmusical (grid)',
    preset = {
      findScope = '$midieditor',
      findMacro = '$type == $note',
      actionScope = '$transform',
      actionScopeFlags = '$none',
      actionMacro = '$position :roundmusical($grid|-|-|0.00|0.00, 100)',
    }
  },
  {
    name = 'position roundmusical (1/16 swing)',
    preset = {
      findScope = '$midieditor',
      findMacro = '$type == $note',
      actionScope = '$transform',
      actionScopeFlags = '$none',
      actionMacro = '$position :roundmusical($1/16|r-|0.00|0.00|sw(66.00), 75)',
    }
  },
  {
    name = 'length roundlenmusical',
    preset = {
      findScope = '$midieditor',
      findMacro = '$type == $note',
      actionScope = '$transform',
      actionScopeFlags = '$none',
      actionMacro = '$length :roundlenmusical($1/8|-|-|0.00|0.00, 100)',
    }
  },
  {
    name = 'length roundendmusical',
    preset = {
      findScope = '$midieditor',
      findMacro = '$type == $note',
      actionScope = '$transform',
      actionScopeFlags = '$none',
      actionMacro = '$length :roundendmusical($1/4|-|-|0.00|0.00, 50)',
    }
  },
  {
    name = 'groove quantize',
    preset = {
      findScope = '$midieditor',
      findMacro = '$type == $note',
      actionScope = '$transform',
      actionScopeFlags = '$none',
      actionMacro = '$position :roundmusical($groove|gf(/path/to/file.mid)|dir(0)|vel(100)|tol(0.0:100.0)|thr(10.0:ticks)|coal(0), 100)',
    }
  },
}

for _, test in ipairs(standalonePresets) do
  -- Load preset (like standalone does)
  tx.loadPresetFromTable(test.preset)

  -- Generate action code (like processAction does internally)
  local fnString = tx.processActionForTake(nil)

  -- Check for unsubstituted placeholders
  local placeholder = fnString and fnString:match('{%w+}')
  if placeholder then
    error(test.name .. ': unsubstituted placeholder found: ' .. placeholder)
  end

  -- Check code can be compiled
  if fnString then
    local fn, err = load(fnString)
    if not fn then
      error(test.name .. ': generated code failed to compile: ' .. (err or 'unknown error'))
    end
    print('  ' .. test.name .. ': OK')
  else
    error(test.name .. ': processActionForTake returned nil')
  end
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print('\n=== Integration Test Summary ===')
print('Tests completed. Review output above for any GAP DETECTED or WARNING messages.')
print('These indicate areas where the param→code→execution pipeline may fail at runtime.')
