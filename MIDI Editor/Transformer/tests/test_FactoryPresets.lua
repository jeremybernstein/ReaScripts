--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  Factory Preset Validation Tests - 4-Stage Pipeline

  Stage 1: Deserialize preset file
  Stage 2: Parse findMacro/actionMacro
  Stage 3: Generate action code (syntax check)
  Stage 4: Execute generated code with mock event
]]

-- setup path for requiring modules
local pwd = io.popen('pwd'):read('*l')
-- handle both running from tests/ dir and from parent
if pwd:match('tests$') then
  package.path = pwd .. '/../?.lua;' .. pwd .. '/helpers/?.lua;' .. package.path
else
  package.path = pwd .. '/?.lua;' .. pwd .. '/tests/helpers/?.lua;' .. package.path
end

-- load REAPER stub FIRST (before any Transformer modules)
reaper = require("reaper_stub")

-- load modules
local tg = require("TransformerGlobal")
local tx = require("TransformerLib")

-- helpers
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

--------------------------------------------------------------------------------
-- preset discovery
--------------------------------------------------------------------------------

local function discoverPresets()
  -- relative from tests/ or from parent
  local presetRoot = '../../../Transformer Presets/Factory Presets'
  if not pwd:match('tests$') then
    presetRoot = '../../Transformer Presets/Factory Presets'
  end

  -- support absolute path via env var for CI
  if os.getenv('FACTORY_PRESET_PATH') then
    presetRoot = os.getenv('FACTORY_PRESET_PATH')
  end

  local presets = {}
  local cmd = string.format('find "%s" -name "*.tfmrPreset" 2>/dev/null', presetRoot)
  local handle = io.popen(cmd)
  if not handle then
    error('failed to discover presets: ' .. presetRoot)
  end

  for line in handle:lines() do
    table.insert(presets, line)
  end
  handle:close()

  if #presets == 0 then
    error('no presets found in: ' .. presetRoot)
  end

  return presets
end

--------------------------------------------------------------------------------
-- validation stages
--------------------------------------------------------------------------------

-- Stage 1: deserialize preset file
local function validateDeserialize(path)
  local file = io.open(path, 'r')
  if not file then
    return false, 'failed to open file'
  end

  local content = file:read('*all')
  file:close()

  local presetTab = tg.deserialize(content)
  if not presetTab then
    return false, 'deserialize returned nil'
  end

  return true, presetTab
end

-- Stage 2: parse macros
local function validateParseMacros(presetTab)
  local ok, err = pcall(function()
    tx.loadPresetFromTable(presetTab)
  end)

  if not ok then
    return false, tostring(err)
  end

  return true, nil
end

-- Stage 3: code generation and syntax check
local function validateCodeGen(presetTab)
  local ok, fnString = pcall(function()
    -- processActionForTake generates Lua code from action rows
    -- nil take is fine for syntax validation
    return tx.processActionForTake(nil)
  end)

  if not ok then
    return false, tostring(fnString)
  end

  if not fnString or fnString == '' then
    return false, 'no code generated'
  end

  -- validate syntax by loading generated code
  -- processActionForTake returns code wrapped as: return function(event, _value1, _value2, _context) ... end
  local compiledFunc, syntaxErr = load(fnString)

  if not compiledFunc then
    return false, 'syntax error: ' .. tostring(syntaxErr)
  end

  -- execute the load result to get the actual function
  local funcConstructor = compiledFunc()
  if type(funcConstructor) ~= 'function' then
    return false, 'loaded code did not return a function'
  end

  return true, funcConstructor
end

-- Stage 4: runtime execution
local function validateExecution(compiledFunc)
  -- mock event with typical note data
  local mockEvent = {
    type = 0x90,
    selected = false,
    muted = false,
    ppqpos = 0,
    msg2 = 60,  -- middle C
    msg3 = 80,  -- velocity
    chanmsg = 0x90,
    chan = 0
  }

  -- processActionForTake returns function(event, _value1, _value2, _context)
  -- where _value1/_value2 are optional parameters
  local ok, err = pcall(function()
    compiledFunc(mockEvent, nil, nil, nil)
  end)

  if not ok then
    return false, tostring(err)
  end

  return true, nil
end

--------------------------------------------------------------------------------
-- main test
--------------------------------------------------------------------------------

print('=== Factory Preset Validation ===')

local presets = discoverPresets()
print(string.format('Discovered %d presets\n', #presets))

local results = {}
local passCount = 0
local failCount = 0

for i, path in ipairs(presets) do
  local result = {
    path = path,
    stage1_ok = false,
    stage2_ok = false,
    stage3_ok = false,
    stage4_ok = false,
    error = nil,
    failed_stage = nil
  }

  local presetTab, err2, compiledFunc, err4

  -- Stage 1: deserialize
  result.stage1_ok, presetTab = validateDeserialize(path)
  if not result.stage1_ok then
    result.error = presetTab
    result.failed_stage = 1
    io.write('1')
  else
    -- Stage 2: parse macros
    result.stage2_ok, err2 = validateParseMacros(presetTab)
    if not result.stage2_ok then
      result.error = err2
      result.failed_stage = 2
      io.write('2')
    else
      -- Stage 3: code generation
      result.stage3_ok, compiledFunc = validateCodeGen(presetTab)
      if not result.stage3_ok then
        result.error = compiledFunc
        result.failed_stage = 3
        io.write('3')
      else
        -- Stage 4: execution
        result.stage4_ok, err4 = validateExecution(compiledFunc)
        if not result.stage4_ok then
          result.error = err4
          result.failed_stage = 4
          io.write('4')
        else
          -- all stages passed
          io.write('.')
          passCount = passCount + 1
        end
      end
    end
  end

  if not result.stage4_ok then
    failCount = failCount + 1
  end

  table.insert(results, result)
  io.flush()
end

print('\n')

-- summary
print(string.format('%d/%d presets passed all stages', passCount, #presets))

-- failure details
if failCount > 0 then
  print('\nFailures:')
  for _, result in ipairs(results) do
    if result.failed_stage then
      local name = result.path:match('([^/]+)%.tfmrPreset$')
      print(string.format('  %s (Stage %d failed)', name, result.failed_stage))
      print(string.format('    Error: %s', result.error))
    end
  end
  os.exit(1)
end

os.exit(0)
