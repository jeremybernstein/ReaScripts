--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

-- metric grid: dotted/triplet, slop, length of range, reset at next bar after pattern concludes (added to end of menu?)
-- TODO: time input
-- TODO: functions

local r = reaper

package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
local mu = require 'MIDIUtils'

-- package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
-- local mu = require 'MIDIUtils'

mu.ENFORCE_ARGS = false -- turn off type checking
mu.CORRECT_OVERLAPS = true
mu.CLAMP_MIDI_BYTES = true

local TransformerLib = {}

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local viewPort

local INVALID = -0xFFFFFFFF

local disabledAutoOverlap = false

local NOTE_TYPE = 0
local CC_TYPE = 1
local SYXTEXT_TYPE = 2

local findParserError = ''

-----------------------------------------------------------------------------
----------------------------------- OOP -------------------------------------

local DEBUG_CLASS = false -- enable to check whether we're using known object properties

local function class(base, setup, init) -- http://lua-users.org/wiki/SimpleLuaClasses
  local c = {}    -- a new class instance
  if not init and type(base) == 'function' then
    init = base
    base = nil
  elseif type(base) == 'table' then
   -- our new class is a shallow copy of the base class!
    for i, v in pairs(base) do
      c[i] = v
    end
    c._base = base
  end
  if DEBUG_CLASS then
    c._names = {}
    if setup then
      for i, v in pairs(setup) do
        c._names[i] = true
      end
    end

    c.__newindex = function(table, key, value)
      local found = false
      if table._names and table._names[key] then found = true
      else
        local m = getmetatable(table)
        while (m) do
          if m._names[key] then found = true break end
          m = m._base
        end
      end
      if not found then
        error("unknown property: "..key, 3)
      else rawset(table, key, value)
      end
    end
  end

  -- the class will be the metatable for all its objects,
  -- and they will look up their methods in it.
  c.__index = c

  -- expose a constructor which can be called by <classname>(<args>)
  local mt = {}
  mt.__call = function(class_tbl, ...)
    local obj = {}
    setmetatable(obj, c)
    if class_tbl.init then
      class_tbl.init(obj,...)
    else
      -- make sure that any stuff from the base class is initialized!
      if base and base.init then
        base.init(obj, ...)
      end
    end
    return obj
  end
  c.init = init
  c.is_a = function(self, klass)
    local m = getmetatable(self)
    while m do
      if m == klass then return true end
      m = m._base
    end
    return false
  end
  setmetatable(c, mt)
  return c
end

local findScopeTable = {
  { notation = '$everywhere', label = 'Everywhere' },
  { notation = '$selected', label = 'Selected Items' },
  { notation = '$midieditor', label = 'Active MIDI Editor' }
}

local function findScopeFromNotation(notation)
  if notation then
    for k, v in ipairs(findScopeTable) do
      if v.notation == notation then
        return k
      end
    end
  end
  return findScopeFromNotation('$midieditor') -- default
end

local currentFindScope = findScopeFromNotation()

local actionScopeTable = {
  { notation = '$select', label = 'Select Matching' },
  { notation = '$selectadd', label = 'Add Matching To Selection' },
  { notation = '$invertselect', label = 'Select Non-Matching' },
  { notation = '$deselect', label = 'Deselect Matching' },
  { notation = '$transform', label = 'Transform' },
  { notation = '$copy', label = 'Copy' }, -- creates new track/item?
  { notation = '$insert', label = 'Insert' },
  { notation = '$insertexclusive', label = 'Insert Exclusive' },
  { notation = '$extracttrack', label = 'Extract to Track' }, -- how is this different?
  { notation = '$extractlane', label = 'Extract to Lanes' },
  { notation = '$delete', label = 'Delete' },
}

local function actionScopeFromNotation(notation)
  if notation then
    for k, v in ipairs(actionScopeTable) do
      if v.notation == notation then
        return k
      end
    end
  end
  return actionScopeFromNotation('$select') -- default
end

local currentActionScope = actionScopeFromNotation()

local DEFAULT_TIMEFORMAT_STRING = '1.1.00'
local DEFAULT_LENGTHFORMAT_STRING = '0.0.00'

local FindRow = class(nil, {})

function FindRow:init()
  self.targetEntry = 1
  self.conditionEntry = 1
  self.param1Entry = 1
  self.param1Val = ''
  self.param2Entry = 1
  self.param2Val = ''
  self.timeFormatEntry = 1
  self.booleanEntry = 1
  self.param1TextEditorStr = '0'
  self.param1TimeFormatStr = DEFAULT_TIMEFORMAT_STRING
  self.param2TextEditorStr = '0'
  self.param2TimeFormatStr = DEFAULT_TIMEFORMAT_STRING
  self.startParenEntry = 1
  self.endParenEntry = 1
end

local findRowTable = {}

local function addFindRow(row)
  table.insert(findRowTable, #findRowTable+1, row and row or FindRow())
end

local startParenEntries = {
  { notation = '', label = 'All Off', text = '' },
  { notation = '(', label = '(', text = '(' },
  { notation = '((', label = '((', text = '((' },
  { notation = '(((', label = '(((', text = '((('}
}

local endParenEntries = {
  { notation = '', label = 'All Off', text = '' },
  { notation = ')', label = ')', text = ')' },
  { notation = '))', label = '))', text = '))' },
  { notation = ')))', label = ')))', text = ')))'}
}

local findTargetEntries = {
  { notation = '$position', label = 'Position', text = 'entry.projtime', time = true },
  { notation = '$length', label = 'Length', text = 'entry.chanmsg == 0x90 and entry.projlen', timedur = true },
  { notation = '$channel', label = 'Channel', text = 'entry.chan', menu = true },
  { notation = '$type', label = 'Type', text = 'entry.chanmsg', menu = true },
  { notation = '$property', label = 'Property', text = 'entry.flags', menu = true },
  { notation = '$value1', label = 'Value 1', text = 'GetSubtypeValue(entry)', texteditor = true, range = {0, 127} }, -- different for AT and PB
  { notation = '$value2', label = 'Value 2', text = 'GetMainValue(entry)', texteditor = true, range = {0, 127} }, -- CC# or Note# or ...
  { notation = '$velocity', label = 'Velocity', text = 'entry.chanmsg == 0x90 and entry.msg3', texteditor = true, range = {1, 127} },
  { notation = '$relvel', label = 'Release Velocity', text = 'entry.relvel', texteditor = true, range = {0, 127} }
  -- { label = 'Last Event' },
  -- { label = 'Context Variable' }
}
findTargetEntries.targetTable = true

local findGenericConditionEntries = {
  { notation = '==', label = 'Equal', text = '==', terms = 1 },
  { notation = '!=', label = 'Unequal', text = '~=', terms = 1 },
  { notation = '>', label = 'Greater Than', text = '>', terms = 1 },
  { notation = '>=', label = 'Greater Than or Equal', text = '>=', terms = 1 },
  { notation = '<', label = 'Less Than', text = '<', terms = 1 },
  { notation = '<=', label = 'Less Than or Equal', text = '<=', terms = 1 },
  { notation = ':inrange', label = 'Inside Range', text = '{tgt} >= {param1} and {tgt} <= {param2}', terms = 2, sub = true },
  { notation = '!:inrange', label = 'Outside Range', text = '{tgt} < {param1} or {tgt} > {param2}', terms = 2, sub = true }
}

local function RandomValue(min, max)
  return math.random(min, max)
end

local function GetTimeSelectionStart()
  local ts_start, ts_end = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  return ts_start
end

local function GetTimeSelectionEnd()
  local ts_start, ts_end = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  return ts_end
end

local function GetSubtypeValue(entry)
  if entry.type == SYXTEXT_TYPE then return 0
  else return entry.msg2
  end
end

local function GetSubtypeValueName(entry)
  if entry.type == SYXTEXT_TYPE then return 'devnull'
  else return 'msg2'
  end
end

local function GetSubtypeValueLabel(typeIndex)
  if typeIndex == 1 then return 'Note #'
  elseif typeIndex == 2 then return 'Note #'
  elseif typeIndex == 3 then return 'CC #'
  elseif typeIndex == 4 then return 'Pgm #'
  elseif typeIndex == 5 then return 'Pressure Amount'
  elseif typeIndex == 6 then return 'PBnd LSB'
  else return ''
  end
end

local function GetMainValue(entry)
  if entry.chanmsg == 0xC0 or entry.chanmsg == 0xD0 then return entry.msg2
  elseif entry.type == SYXTEXT_TYPE then return 0
  else return entry.msg3
  end
end

local function GetMainValueName(entry)
  if entry.chanmsg == 0xC0 or entry.chanmsg == 0xD0 then return 'msg2'
  elseif entry.type == SYXTEXT_TYPE then return 'devnull'
  else return 'msg3'
  end
end

local function GetMainValueLabel(typeIndex)
  if typeIndex == 1 then return 'Velocity'
  elseif typeIndex == 2 then return 'Pressure Amount'
  elseif typeIndex == 3 then return 'CC Value'
  elseif typeIndex == 4 then return 'unused'
  elseif typeIndex == 5 then return 'unused'
  elseif typeIndex == 6 then return 'PBnd MSB'
  else return ''
  end
end

local function QuantizeTo(val, quant)
  if quant == 0 then return val end
  local newval = quant * math.floor((val / quant) + 0.5)
  return newval
end

local function OnMetricGrid(take, PPQ, ppqpos, mgParams)
  if not take then return false end

  local subdiv = mgParams.param1
  local gridStr = mgParams.param2

  local gridLen = #gridStr
  local gridUnit = PPQ * (subdiv * 4) -- subdiv=1 means whole note
  if ((mgParams.modifiers & 1) ~= 0) then gridUnit = gridUnit * 1.5
  elseif ((mgParams.modifiers & 2) ~= 0) then gridUnit = (gridUnit * 2 / 3) end

  local cycleLength = gridUnit * gridLen
  local som = r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)
  local preSlop = gridUnit * (mgParams.preSlopPercent / 100)
  local postSlop = gridUnit * (mgParams.postSlopPercent / 100)
  if postSlop == 0 then postSlop = 1 end

  -- handle cycle lengths > measure
  if mgParams.wantsBarRestart then
    if not SOM then SOM = som end
    if som - SOM > cycleLength then
      SOM = som
      CACHED_METRIC = nil
      CACHED_WRAPPED = nil
    end
    ppqpos = ppqpos - SOM
  end

  local wrapped = math.floor(ppqpos / cycleLength)

  -- mu.post('metric: ' .. (CACHED_METRIC and CACHED_METRIC or 'nil'), 'wrapped: ' .. (CACHED_WRAPPED and CACHED_WRAPPED or 'nil'), 'curwrap; '.. wrapped)

  if wrapped ~= CACHED_WRAPPED then
    CACHED_WRAPPED = wrapped
    CACHED_METRIC = nil
  end
  local modPos = math.fmod(ppqpos, cycleLength)

  -- CACHED_METRIC is used to avoid iterating from the beginning each time
  for i = CACHED_METRIC and CACHED_METRIC or 1, gridLen do
    local c = gridStr:sub(i, i)
    local trueStartRange = (gridUnit * (i - 1))
    local startRange = trueStartRange - preSlop
    local endRange = trueStartRange + postSlop
    if modPos >= startRange and modPos <= endRange then
      CACHED_METRIC = i
      return c ~= '0' and true or false
    end
  end
  return false
end

local function LinearChangeOverSelection(projTime, p1, p2, firstTime, lastTime)
  if firstTime ~= lastTime and projTime >= firstTime and projTime <= lastTime then
    local linearPos = (projTime - firstTime) / (lastTime - firstTime)
    local val = ((p2 - p1) * linearPos) + p1
    return math.floor(val + 0.5)
  end
  return 0
end

local findPositionConditionEntries = {
  { notation = '==', label = 'Equal', text = '==', terms = 1 },
  { notation = '!=', label = 'Unequal', text = '~=', terms = 1 },
  { notation = '>', label = 'Greater Than', text = '>', terms = 1 },
  { notation = '>=', label = 'Greater Than or Equal', text = '>=', terms = 1 },
  { notation = '<', label = 'Less Than', text = '<', terms = 1 },
  { notation = '<=', label = 'Less Than or Equal', text = '<=', terms = 1 },
  { notation = ':inrange', label = 'Inside Range', text = '{tgt} >= {param1} and {tgt} <= {param2}', terms = 2, sub = true }, -- absolute position
  { notation = '!:inrange', label = 'Outside Range', text = '{tgt} < {param1} or {tgt} > {param2}', terms = 2, sub = true },
  { notation = ':inbarrange', label = 'Inside Bar Range', text = '{tgt} >= {param1} and {tgt} <= {param1}', terms = 2, sub = true }, -- intra-bar position, cubase handles this as percent
  { notation = '!:inbarrange', label = 'Outside Bar Range', text = '{tgt} < {param1} or {tgt} > {param2}', terms = 2, sub = true},
  { notation = ':onmetricgrid', label = 'On Metric Grid', text = 'OnMetricGrid(take, PPQ, entry.ppqpos, {metricgridparams})', terms = 2, sub = true, metricgrid = true }, -- intra-bar position, cubase handles this as percent
  { notation = '!:onmetricgrid', label = 'Off Metric Grid', text = 'not OnMetricGrid(take, PPQ, entry.ppqpos, {metricgridparams})', terms = 2, sub = true, metricgrid = true },
  { notation = ':beforecursor', label = 'Before Cursor', text = '< r.GetCursorPositionEx(0)', terms = 0 },
  { notation = ':aftercursor', label = 'After Cursor', text = '> r.GetCursorPositionEx(0)', terms = 0 },
  { notation = ':intimesel', label = 'Inside Time Selection', text = '{tgt} >= GetTimeSelectionStart() and {tgt} <= GetTimeSelectionEnd()', terms = 0, sub = true },
  { notation = '!:intimesel', label = 'Outside Time Selection', text = '{tgt} < GetTimeSelectionStart() or {tgt} > GetTimeSelectionEnd()', terms = 0, sub = true },
  -- { label = 'Inside Track Loop', text = '', terms = 1 },
  -- { label = 'Exactly Matching Cycle', text = '', terms = 1 },
  -- { label = 'Inside Selected Marker', text = { '>= GetSelectedRegionStart() and', '<= GetSelectedRegionEnd()' }, terms = 0 } -- region?
}

local findTypeConditionEntries = {
  { notation = '==', label = 'Equal', text = '==', terms = 1 },
  { notation = '!=', label = 'Unequal', text = '~=', terms = 1 },
  { notation = ':all', label = 'All', text = '~= nil', terms = 0 }
}

local findPropertyConditionEntries = {
  { notation = ':iset', label = 'Is Set', text = '({tgt} & {param1}) ~= 0', terms = 1, sub = true },
  { notation = '!:isset', label = 'Is Not Set', text = '({tgt} & {param1}) == 0', terms = 1, sub = true }
}

local findTypeParam1Entries = {
  { notation = '$note', label = 'Note', text = '0x90' },
  { notation = '$polyat', label = 'Poly Pressure', text = '0xA0' },
  { notation = '$cc', label = 'Controller', text = '0xB0' },
  { notation = '$pc', label = 'Program Change', text = '0xC0' },
  { notation = '$at', label = 'Aftertouch', text = '0xD0' },
  { notation = '$pb', label = 'Pitch Bend', text = '0xE0' },
  { notation = '$syx', label = 'System Exclusive', text = '0xF0' }
  -- { label = 'SMF Event', text = '0x90' },
  -- { label = 'Notation Event', text = '0x90' },
  -- { label = '...', text = '0x90' }
}

local findPropertyParam1Entries = {
  { notation = '$selected', label = 'Selected', text = '0x01' },
  { notation = '$muted', label = 'Muted', text = '0x02' }
}

local findChannelParam1Entries = {
  { notation = '1', label = '1', text = '0' },
  { notation = '2', label = '2', text = '1' },
  { notation = '3', label = '3', text = '2' },
  { notation = '4', label = '4', text = '3' },
  { notation = '5', label = '5', text = '4' },
  { notation = '6', label = '6', text = '5' },
  { notation = '7', label = '7', text = '6' },
  { notation = '8', label = '8', text = '7' },
  { notation = '9', label = '9', text = '8' },
  { notation = '10', label = '10', text = '9' },
  { notation = '11', label = '11', text = '10' },
  { notation = '12', label = '12', text = '11' },
  { notation = '13', label = '13', text = '12' },
  { notation = '14', label = '14', text = '13' },
  { notation = '15', label = '15', text = '14' },
  { notation = '16', label = '16', text = '15' },
}

local findTimeFormatEntries = { -- time format not yet respected, these are also not 100% relevant to REAPER
  { label = 'PPQ' },
  { label = 'Seconds' },
  { label = 'Samples' },
  { label = 'Frames' }
}

local findMetricGridParam1Entries = {
  { notation = '$1/64', label = '1/64', text = '0,015625' },
  { notation = '$1/32', label = '1/32', text = '0.03125' },
  { notation = '$1/16', label = '1/16', text = '0.0625' },
  { notation = '$1/8', label = '1/8', text = '0.125' },
  { notation = '$1/4', label = '1/4', text = '0.25' },
  { notation = '$1/2', label = '1/2', text = '0.5' },
  { notation = '$1/1', label = '1/1', text = '1' },
  { notation = '$2/1', label = '2/1', text = '2' },
  { notation = '$4/1', label = '4/1', text = '4' },
  -- we need some way to enable triplets and dotted notes, I guess as selections at the bottom of the menu?
}

local findBooleanEntries = { -- in cubase this a simple toggle to switch, not a bad idea
  { notation = '&&', label = 'And', text = 'and'},
  { notation = '||', label = 'Or', text = 'or'}
}

local ActionRow = class(nil, {})

function ActionRow:init()
  self.targetEntry = 1
  self.operationEntry = 1
  self.param1Entry = 1
  self.param1Val = ''
  self.param2Entry = 1
  self.param2Val = ''
  self.param1TextEditorStr = '0'
  self.param1TimeFormatStr = DEFAULT_TIMEFORMAT_STRING
  self.param2TextEditorStr = '0'
  self.param2TimeFormatStr = DEFAULT_TIMEFORMAT_STRING
end

local actionRowTable = {}

local function addActionRow(row)
  table.insert(actionRowTable, #actionRowTable+1, row and row or ActionRow())
end

local actionTargetEntries = {
  { notation = '$position', label = 'Position', text = 'entry.projtime', time = true },
  { notation = '$length', label = 'Length', text = 'entry.projlen', timedur = true, cond = 'entry.chanmsg == 0x90' },
  { notation = '$channel', label = 'Channel', text = 'entry.chan', menu = true },
  { notation = '$type', label = 'Type', text = 'entry.chanmsg', menu = true },
  { notation = '$property', label = 'Property', text = 'entry.flags', menu = true },
  { notation = '$value1', label = 'Value 1', text = 'entry[_value1]', texteditor = true, range = {0, 127} },
  { notation = '$value2', label = 'Value 2', text = 'entry[_value2]', texteditor = true, range = {0, 127} },
  { notation = '$velocity', label = 'Velocity', text = 'entry.msg3', texteditor = true, cond = 'entry.chanmsg == 0x90', range = {1, 127} },
  { notation = '$relvel', label = 'Release Velocity', text = 'entry.relvel', texteditor = true, cond = 'entry.chanmsg == 0x90', range = {0, 127} },
  -- { label = 'Last Event' },
  -- { label = 'Context Variable' }
}
actionTargetEntries.targetTable = true

local actionOperationPlus = { notation = '+', label = 'Add', text = '+', terms = 1, texteditor = true }
local actionOperationMinus = { notation = '-', label = 'Subtract', text = '-', terms = 1, texteditor = true }

local actionOperationTimePlus = { notation = '+', label = 'Add', text = '+', terms = 1, timedur = 1 }
local actionOperationTimeMinus = { notation = '-', label = 'Subtract', text = '-', terms = 1, timedur = 1 }

local actionOperationMult = { notation = '*', label = 'Multiply', text = '*', terms = 1, texteditor = true }
local actionOperationDivide = { notation = '/', label = 'Divide By', text = '/', terms = 1, texteditor = true }
local actionOperationRound = { notation = ':round', label = 'Round By', text = '= QuantizeTo({tgt}, {param1})', terms = 1, sub = true, texteditor = true }
local actionOperationRandom = { notation = ':random', label = 'Set Random Values Between', text = '= RandomValue({param1}, {param2})', terms = 2, sub = true, texteditor = true }
-- this might need a different range for length vs MIDI data
local actionOperationRelRandom = { notation = ':relrandom', label = 'Set Relative Random Values Between', text = '= {tgt} + RandomValue({param1}, {param2})', terms = 2, sub = true, texteditor = true, range = { -127, 127 } }
local actionOperationFixed = { notation = '=', label = 'Set to Fixed Value', text = '= {param1}', terms = 1, sub = true }
local actionOperationLine = { notation = ':line', label = 'Linear Change in Selection Range', text = '= LinearChangeOverSelection(entry.projtime, {param1}, {param2}, _firstSel, _lastSel)', terms = 2, sub = true, texteditor = true }
-- this has issues with handling range (should support negative numbers, and clamp output to supplied range). challenging, since the clamping is target-dependent and probably needs to be written to the actionFn
local actionOperationRelLine = { notation = ':relline', label = 'Relative Change in Selection Range', text = '= {tgt} + LinearChangeOverSelection(entry.projtime, {param1}, {param2}, _firstSel, _lastSel)', terms = 2, sub = true, texteditor = true, range = {-127, 127 } }

local actionPositionOperationEntries = {
  actionOperationTimePlus, actionOperationTimeMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationRelRandom,
  { notation = ':tocursor', label = 'Move to Cursor', text = '= r.GetCursorPositionEx()', terms = 0 },
  { notation = ':addlength', label = 'Add Length', text = '+', terms = 1, timeval = true },
}

local actionLengthOperationEntries = {
  actionOperationTimePlus, actionOperationTimeMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationRandom, actionOperationRelRandom
}

local actionChannelOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationFixed, actionOperationRandom,
  actionOperationRelRandom, actionOperationLine, actionOperationRelLine
}

local actionTypeOperationEntries = {
  actionOperationFixed
}

local actionPropertyOperationEntries = {
  actionOperationFixed
}

local actionPropertyParam1Entries = {
  { notation = '0', label = 'Clear', text = '0' },
  { notation = '1', label = 'Selected', text = '1' },
  { notation = '2', label = 'Muted', text = '2' },
  { notation = '3', label = 'Selected + Muted', text = '3' },
}

local actionSubtypeOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationRandom, actionOperationRelRandom,
  { notation = ':getvalue2', label = 'Use Value 2', text = '= GetMainValue(entry)', terms = 0 }, -- note that this is different for AT and PB
  actionOperationLine, actionOperationRelLine
}

local actionVelocityOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationRandom, actionOperationRelRandom,
  { notation = ':getvalue1', label = 'Use Value 1', text = '= GetSubtypeValue(entry)', terms = 0 }, -- ?? note that this is different for AT and PB
  { notation = ':mirror', label = 'Mirror', text = '= Mirror({tgt}, {param1})', terms = 1, sub = true },
  actionOperationLine, actionOperationRelLine
}

local actionGenericOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationRandom, actionOperationRelRandom,
  { notation = ':mirror', label = 'Mirror', text = '= Mirror({tgt}, {param1})', terms = 1, sub = true },
  actionOperationLine, actionOperationRelLine
}

local PARAM_TYPE_UNKNOWN = 0
local PARAM_TYPE_MENU = 1
local PARAM_TYPE_TEXTEDITOR = 2
local PARAM_TYPE_TIME = 3
local PARAM_TYPE_TIMEDUR = 4
local PARAM_TYPE_METRICGRID = 5

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

local function gooseAutoOverlap()
  -- r.SetToggleCommandState(sectionID, 40681, 0) -- this doesn't work
  r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40681) -- but this does
  disabledAutoOverlap = not disabledAutoOverlap
end

local function sysexStringToBytes(input)
  local result = {}
  local currentByte = 0
  local nibbleCount = 0
  local count = 0

  for hex in input:gmatch("%x+") do
    for nibble in hex:gmatch("%x") do
      currentByte = currentByte * 16 + tonumber(nibble, 16)
      nibbleCount = nibbleCount + 1

      if nibbleCount == 2 then
        if count == 0 and currentByte == 0xF0 then
        elseif currentByte == 0xF7 then
          return table.concat(result)
        else
          table.insert(result, string.char(currentByte))
        end
        currentByte = 0
        nibbleCount = 0
      elseif nibbleCount == 1 and #hex == 1 then
        -- Handle a single nibble in the middle of the string
        table.insert(result, string.char(currentByte))
        currentByte = 0
        nibbleCount = 0
      end
    end
  end

  if nibbleCount == 1 then
    -- Handle a single trailing nibble
    currentByte = currentByte * 16
    table.insert(result, string.char(currentByte))
  end

  return table.concat(result)
end

local function sysexBytesToString(bytes)
  local str = ''
  for i = 1, string.len(bytes) do
    str = str .. string.format('%02X', tonumber(string.byte(bytes, i)))
    if i ~= string.len(bytes) then str = str .. ' ' end
  end
  return str
end

local function notationStringToString(notStr)
  local a, b = string.find(notStr, 'TRAC ')
  if a and b then return string.sub(notStr, b + 1) end
  return notStr
end

local function stringToNotationString(str)
  local a, b = string.find(str, 'TRAC ')
  if a and b then return str end
  return 'TRAC ' .. str
end

-----------------------------------------------------------------------------
-------------------------------- THE GUTS -----------------------------------

  ---------------------------------------------------------------------------
  --------------------------- BUNCH OF VARIABLES ----------------------------

  local allEvents = {}

  local context = {}
  context.r = reaper
  context.math = math
  context.RandomValue = RandomValue
  context.GetTimeSelectionStart = GetTimeSelectionStart
  context.GetTimeSelectionEnd = GetTimeSelectionEnd
  context.GetSubtypeValue = GetSubtypeValue
  context.GetMainValue = GetMainValue
  context.QuantizeTo = QuantizeTo
  context.OnMetricGrid = OnMetricGrid
  context.LinearChangeOverSelection = LinearChangeOverSelection

  ---------------------------------------------------------------------------
  --------------------------- BUNCH OF FUNCTIONS ----------------------------

  -- local function getPPQ()
  --   local qn1 = r.MIDI_GetProjQNFromPPQPos(take, 0)
  --   local qn2 = qn1 + 1
  --   return math.floor(r.MIDI_GetPPQPosFromProjQN(take, qn2) - r.MIDI_GetPPQPosFromProjQN(take, qn1))
  -- end

  -- local function needsBBUConversion(name)
  --   return wantsBBU and (name == 'ticks' or name == 'notedur' or name == 'selposticks' or name == 'seldurticks')
  -- end

  local function BBTToPPQ(take, measures, beats, ticks, relativeppq, nosubtract)
    local nilmeas = measures == nil
    if not measures then measures = 0 end
    if not beats then beats = 0 end
    if not ticks then ticks = 0 end
    if relativeppq then
      local relMeasures, relBeats, _, relTicks = PpqToTime(relativeppq)
      measures = measures + relMeasures
      beats = beats + relBeats
      ticks = ticks + relTicks
    end
    local bbttime
    if nilmeas then
      bbttime = r.TimeMap2_beatsToTime(0, beats) -- have to do it this way, passing nil as 3rd arg is equivalent to 0 and breaks things
    else
      bbttime = r.TimeMap2_beatsToTime(0, beats, measures)
    end
    local ppqpos = r.MIDI_GetPPQPosFromProjTime(take, bbttime) + ticks
    if relativeppq and not nosubtract then ppqpos = ppqpos - relativeppq end
    return math.floor(ppqpos)
  end

  function PpqToTime(take, ppqpos, projtime)
    local _, posMeasures, cml, posBeats = r.TimeMap2_timeToBeats(0, projtime)
    local _, posMeasuresSOM, _, posBeatsSOM = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)))

    local measures = posMeasures
    local beats = math.floor(posBeats - posBeatsSOM)
    local beatsmax = math.floor(cml)
    local posBeats_PPQ = BBTToPPQ(take, nil, math.floor(posBeats))
    local ticks = math.floor(ppqpos - posBeats_PPQ)
    return measures, beats, beatsmax, ticks
  end

  -- local function ppqToLength(ppqpos, ppqlen)
  --   -- REAPER, why is this so difficult?
  --   -- get the PPQ position of the nearest measure start (to ensure that we're dealing with round values)
  --   local _, startMeasures, _, startBeats = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)))
  --   local startPPQ = BBTToPPQ(nil, math.floor(startBeats))

  --   -- now we need the nearest measure start to the end position
  --   local _, endMeasuresSOM, _, endBeatsSOM = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, r.MIDI_GetPPQPos_StartOfMeasure(take, startPPQ + ppqlen)))
  --   -- and the actual end position
  --   local _, endMeasures, _, endBeats = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, startPPQ + ppqlen))

  --   local measures = endMeasures - startMeasures -- measures from start to end
  --   local beats = math.floor(endBeats - endBeatsSOM) -- beats from the SOM (only this measure)
  --   local endBeats_PPQ = BBTToPPQ(nil,  math.floor(endBeats)) -- ppq location of the beginning of this beat
  --   local ticks = math.floor((startPPQ + ppqlen) - endBeats_PPQ) -- finally the ticks
  --   return measures, beats, ticks
  -- end

  local function calcMIDITime(take, e)
    e.projtime = r.MIDI_GetProjTimeFromPPQPos(take, e.ppqpos)
    if e.endppqpos then
      e.projlen = r.MIDI_GetProjTimeFromPPQPos(take, e.endppqpos) - e.projtime
    else
      e.projlen = 0
    end
    e.measures, e.beats, e.beatsmax, e.ticks = PpqToTime(take, e.ppqpos, e.projtime)
  end

  -- local function isTimeValue(name)
  --   if name == 'measures' or name == 'beats' or name == 'ticks' or name == 'notedur' then
  --     return true
  --   end
  --   return false
  -- end

  -- local function timeStringToTime(timestr, ispos)
  --   local a = 1
  --   local dots = {}
  --   repeat
  --     a = timestr:find('%.', a)
  --     if a then
  --       table.insert(dots, a)
  --       a = a + 1
  --     end
  --   until not a

  --   local nums = {}
  --   if #dots ~= 0 then
  --       local str = timestr:sub(1, dots[1] - 1)
  --       table.insert(nums, str)
  --       for k, v in ipairs(dots) do
  --           str = timestr:sub(v + 1, k ~= #dots and dots[k + 1] - 1 or nil)
  --           table.insert(nums, str)
  --       end
  --   end

  --   if #nums == 0 then table.insert(nums, timestr) end

  --   local measures = (not nums[1] or nums[1] == '') and 0 or tonumber(nums[1])
  --   measures = measures and math.floor(measures) or 0
  --   local beats = (not nums[2] or nums[2] == '') and (ispos and 1 or 0) or tonumber(nums[2])
  --   beats = beats and math.floor(beats) or 0

  --   local ticks
  --   if wantsBBU then
  --     local units = (not nums[3] or nums[3] == '') and 0 or tonumber(nums[3])
  --     ticks = math.floor((units * 0.01) * PPQ)
  --   else
  --     ticks = (not nums[3] or nums[3] == '') and 0 or tonumber(nums[3])
  --     ticks = ticks and math.floor(ticks) or 0
  --    end

  --   if ispos then
  --     beats = beats - 1
  --     if beats < 0 then beats = 0 end
  --   end

  --   return measures, beats, ticks
  -- end

  -- local function parseTimeString(name, str)
  --   local ppqpos = nil
  --   local measures, beats, ticks = timeStringToTime(str, name == 'selposticks')
  --   if measures and beats and ticks then
  --     if name == 'selposticks' then
  --       ppqpos = BBTToPPQ(measures, beats, ticks)
  --     elseif name == 'seldurticks' then
  --       ppqpos = BBTToPPQ(measures, beats, ticks, union.selposticks)
  --     else return nil
  --     end
  --   end
  --   return math.floor(ppqpos)
  -- end

  -- local function processTimeString(name, str)
  --   local char = str:byte(1)
  --   local ppqpos = nil

  --   if char == OP_SCL then str = '0'..str end

  --   if char == OP_ADD or char == OP_SUB or char == OP_MUL or char == OP_DIV then
  --     if char == OP_ADD or char == OP_SUB then
  --       local measures, beats, ticks = timeStringToTime(str:sub(2), false)
  --       if measures and beats and ticks then
  --         local opand = BBTToPPQ(measures, beats, ticks, union.selposticks)
  --         _, ppqpos = doPerformOperation(nil, union[name], char, opand)
  --       end
  --     end
  --     if not ppqpos then
  --       _, ppqpos = doPerformOperation(nil, union[name], char, tonumber(str:sub(2)))
  --     end
  --   else
  --     ppqpos = parseTimeString(name, str)
  --   end
  --   if ppqpos then
  --     userValues[name] = { operation = OP_ABS, opval = ppqpos }
  --     return true
  --   end
  --   return false
  -- end

  ---------------------------------------------------------------------------
  --------------------------------- UTILITIES -------------------------------

  -- https://stackoverflow.com/questions/1340230/check-if-directory-exists-in-lua
  --- Check if a file or directory exists in this path
  local function filePathExists(file)
    local ok, err, code = os.rename(file, file)
    if not ok then
      if code == 13 then
      -- Permission denied, but it exists
        return true
      end
    end
    return ok, err
  end

    --- Check if a directory exists in this path
  local function dirExists(path)
    -- "/" works on both Unix and Windows
    return filePathExists(path:match('/$') and path or path..'/')
  end

  local function ensureNumString(str, range)
    local num = tonumber(str)
    if not num then num = 0 end
    if range then
      if range[1] and num < range[1] then num = range[1] end
      if range[2] and num > range[2] then num = range[2] end
    end
    return tostring(num)
  end

  local function timeFormatClampPad(str, min, max, fmt)
    local num = tonumber(str)
    if not num then num = 0 end
    num = (min and num < min) and min or (max and num > max) and max or num
    return string.format(fmt, num)
  end

  local function lengthFormatRebuf(buf)
    if string.match(buf, '%d*%.') then
      local bars, beats, fraction = string.match(buf, '(%d*)%.(%d+)%.(%d+)')
      if not bars then
        bars, beats = string.match(buf, '(%d*)%.(%d+)')
        if not bars then
          bars = string.match(buf, '(%d*)')
        end
      end
      if not bars or bars == '' then bars = 0 end
      bars = timeFormatClampPad(bars, 0, nil, '%d')
      if not beats or beats == '' then beats = 1 end -- need to check number of beats in bar N
      beats = timeFormatClampPad(beats, 0, nil, '%d')
      if not fraction or fraction == '' then fraction = 0 end
      fraction = timeFormatClampPad(fraction, 0, 99, '%02d')

      return bars .. '.' .. beats .. '.' .. fraction
    end
    -- if (string.match(buf, '%d*:')) then
    --   local minutes, seconds, fracsecs = string.match(buf, '(%d*):(%d+)%.(%d+)')
    --   if not minutes then
    --     minutes, seconds = string.match(buf, '(%d*):(%d+)')
    --     if not minutes then
    --       minutes = string.match(buf, '(%d*)')
    --     end
    --   end
    --   if not minutes or minutes == '' then minutes = 0 end
    --   minutes = timeFormatClampPad(minutes, 0, 59, '%02d')
    --   if not seconds or seconds == '' then seconds = 0 end
    --   seconds = timeFormatClampPad(seconds, 0, 59, '%02d')
    --   if not fracsecs then fracsecs = 0 end
    --   fracsecs = timeFormatClampPad(fracsecs, 0, 99, '%02d')

    --   return minutes .. '.' .. seconds .. '.' .. fracsecs
    -- end
    return DEFAULT_LENGTHFORMAT_STRING
    -- ... etc.
  end

  local function timeFormatRebuf(buf)
    if string.match(buf, '%d*%.') then
      local bars, beats, fraction = string.match(buf, '(%d*)%.(%d+)%.(%d+)')
      if not bars then
        bars, beats = string.match(buf, '(%d*)%.(%d+)')
        if not bars then
          bars = string.match(buf, '(%d*)')
        end
      end
      if not bars or bars == '' then bars = 0 end
      bars = timeFormatClampPad(bars, nil, nil, '%d')
      if not beats or beats == '' then beats = 1 end -- need to check number of beats in bar N
      beats = timeFormatClampPad(beats, 1, nil, '%d')
      if not fraction or fraction == '' then fraction = 0 end
      fraction = timeFormatClampPad(fraction, 0, 99, '%02d')

      return bars .. '.' .. beats .. '.' .. fraction
    end
    -- if (string.match(buf, '%d*:')) then
    --   local minutes, seconds, fracsecs = string.match(buf, '(%d*):(%d+)%.(%d+)')
    --   if not minutes then
    --     minutes, seconds = string.match(buf, '(%d*):(%d+)')
    --     if not minutes then
    --       minutes = string.match(buf, '(%d*)')
    --     end
    --   end
    --   if not minutes or minutes == '' then minutes = 0 end
    --   minutes = timeFormatClampPad(minutes, 0, 59, '%02d')
    --   if not seconds or seconds == '' then seconds = 0 end
    --   seconds = timeFormatClampPad(seconds, 0, 59, '%02d')
    --   if not fracsecs then fracsecs = 0 end
    --   fracsecs = timeFormatClampPad(fracsecs, 0, 99, '%02d')

    --   return minutes .. '.' .. seconds .. '.' .. fracsecs
    -- end
    return DEFAULT_TIMEFORMAT_STRING
    -- ... etc.
  end

local presetPath = r.GetResourcePath() .. '/Scripts/Transformer Presets/'
local presetExt = '.tfmrPreset'

local function spairs(t, order) -- sorted iterator (https://stackoverflow.com/questions/15706270/sort-a-table-in-lua)
  -- collect the keys
  local keys = {}
  for k in pairs(t) do keys[#keys+1] = k end
  -- if order function given, sort by it by passing the table and keys a, b,
  -- otherwise just sort the keys
  if order then
    table.sort(keys, function(a,b) return order(t, a, b) end)
  else
    table.sort(keys)
  end
  -- return the iterator function
  local i = 0
  return function()
    i = i + 1
    if keys[i] then
      return keys[i], t[keys[i]]
    end
  end
end

local function enumerateTransformerPresets()
  if not dirExists(presetPath) then return {} end

  local idx = 0
  local fnames = {}

  r.EnumerateFiles(presetPath, -1)
  local fname = r.EnumerateFiles(presetPath, idx)
  while fname do
    if fname:match('%' .. presetExt .. '$') then
      fname = { label = fname:gsub('%' .. presetExt .. '$', '') }
      table.insert(fnames, fname)
    end
    idx = idx + 1
    fname = r.EnumerateFiles(presetPath, idx)
  end
  local sorted = {}
  for _, v in spairs(fnames, function (t, a, b) return string.lower(t[a].label) < string.lower(t[b].label) end) do
    table.insert(sorted, v)
  end
  return sorted
end

local function tableCopy(obj, seen)
  if type(obj) ~= 'table' then return obj end
  if seen and seen[obj] then return seen[obj] end
  local s = seen or {}
  local res = setmetatable({}, getmetatable(obj))
  s[obj] = res
  for k, v in pairs(obj) do res[tableCopy(k, s)] = tableCopy(v, s) end
  return res
end

local function deserialize(str)
  local f, err = load('return ' .. str)
  if not f then mu.post(err) end
  return f ~= nil and f() or nil
end

local function OrderByKey(t, a, b)
  return a < b
end

local function serialize(val, name, skipnewlines, depth)
  skipnewlines = skipnewlines or false
  depth = depth or 0
  local tmp = string.rep(' ', depth)
  if name then
    if type(name) == 'number' and math.floor(name) == name then
      name = '[' .. name .. ']'
    elseif not string.match(name, '^[a-zA-z_][a-zA-Z0-9_]*$') then
      name = string.gsub(name, "'", "\\'")
      name = "['".. name .. "']"
    end
    tmp = tmp .. name .. ' = '
  end
  if type(val) == 'table' then
    tmp = tmp .. '{' .. (not skipnewlines and '\n' or '')
    for k, v in spairs(val, OrderByKey) do
      tmp =  tmp .. serialize(v, k, skipnewlines, depth + 1) .. ',' .. (not skipnewlines and '\n' or '')
    end
    tmp = tmp .. string.rep(' ', depth) .. '}'
  elseif type(val) == 'number' then
    tmp = tmp .. tostring(val)
  elseif type(val) == 'string' then
    tmp = tmp .. string.format('%q', val)
  elseif type(val) == 'boolean' then
    tmp = tmp .. (val and 'true' or 'false')
  else
    tmp = tmp .. '"[unknown datatype:' .. type(val) .. ']"'
  end
  return tmp
end

local function findTargetToTabs(row, targetEntry)
  local condTab = {}
  local param1Tab = {}
  local param2Tab = {}

  if targetEntry > 0 then
    local notation = findTargetEntries[targetEntry].notation
    if notation == '$position' then
      condTab = findPositionConditionEntries
      local condition = condTab[row.conditionEntry]
      if condition and condition.metricgrid then
        param1Tab = findMetricGridParam1Entries
      end
    -- elseif notation == '$length' then
    elseif notation == '$channel' then
      condTab = findGenericConditionEntries
      param1Tab = findChannelParam1Entries
      param2Tab = findChannelParam1Entries
    elseif notation == '$type' then
      condTab = findTypeConditionEntries
      param1Tab = findTypeParam1Entries
    elseif notation == '$property' then
      condTab = findPropertyConditionEntries
      param1Tab = findPropertyParam1Entries
    -- elseif notation == '$value1' then
    -- elseif notation == '$value2' then
    -- elseif notation == '$velocity' then
    -- elseif notation == '$relvel' then
    else
      condTab = findGenericConditionEntries
    end
  end
  return condTab, param1Tab, param2Tab
end

local function generateMetricGridNotation(row)
  if not row.mg then return '' end
  local mgStr = '|'
  mgStr = mgStr .. (((row.mg.modifiers & 2) ~= 0) and 't' or ((row.mg.modifiers & 1) ~= 0) and 'd' or '-')
  mgStr = mgStr .. (row.mg.wantsBarRestart and 'b' or '-')
  mgStr = mgStr .. string.format('|%0.2f|%0.2f', row.mg.preSlopPercent, row.mg.postSlopPercent)
  return mgStr
end

local function parseMetricGridNotation(str)
  local fs, fe, mod, rst, pre, post = string.find(str, '|([td%-])([b-])|(.-)|(.-)$')
  if fs and fe then
    local modval = mod == 't' and 2 or mod == 'd' and 1 or 0
    local rstval = rst == 'b' and true or false
    local preval = tonumber(pre)
    local postval = tonumber(post)
    return modval, rstval, preval, postval
  end
  return 0, false, 0, 0
end

local function getEditorTypeForRow(target, condOp)
  local paramType = condOp.menu and PARAM_TYPE_MENU
    or condOp.texteditor and PARAM_TYPE_TEXTEDITOR
    or condOp.time and PARAM_TYPE_TIME
    or condOp.timedur and PARAM_TYPE_TIMEDUR
    or condOp.metricgrid and PARAM_TYPE_METRICGRID
    or 0
  if paramType == PARAM_TYPE_UNKNOWN then
    paramType = target.menu and PARAM_TYPE_MENU
    or target.texteditor and PARAM_TYPE_TEXTEDITOR
    or target.time and PARAM_TYPE_TIME
    or target.timedur and PARAM_TYPE_TIMEDUR
    or target.metricgrid and PARAM_TYPE_METRICGRID
    or PARAM_TYPE_TEXTEDITOR
  end
  return paramType
end

local function handleParam(row, target, condOp, paramName, paramTab, paramStr)
  local paramType = getEditorTypeForRow(target, condOp)
  paramStr = string.gsub(paramStr, '^%s*(.-)%s*$', '%1') -- trim whitespace
  if #paramTab ~= 0 then
    for kk, vv in ipairs(paramTab) do
      local pa, pb = string.find(paramStr, vv.notation)
      if pa and pb then
        row[paramName .. 'Entry'] = kk
        if paramType == PARAM_TYPE_METRICGRID then
          row.mg = {}
          row.mg.modifiers, row.mg.wantsBarRestart, row.mg.preSlopPercent, row.mg.postSlopPercent = parseMetricGridNotation(paramStr:sub(pb + 1))
        end
        break
      end
    end
  elseif paramType == PARAM_TYPE_TEXTEDITOR then
    row[paramName .. 'TextEditorStr'] = ensureNumString(paramStr, condOp.range and condOp.range or target.range)
  elseif paramType == PARAM_TYPE_TIME then
    row[paramName .. 'TimeFormatStr'] = timeFormatRebuf(paramStr)
  elseif paramType == PARAM_TYPE_TIMEDUR then
    row[paramName .. 'imeFormatStr'] = lengthFormatRebuf(paramStr)
  elseif paramType == PARAM_TYPE_METRICGRID then
    row[paramName .. 'TextEditorStr'] = paramStr
  end
  return paramStr
end

local function processFindMacroRow(buf, boolstr)
  local row = FindRow()
  local bufstart = 0
  local findstart, findend, parens = string.find(buf, '^%s*(%(+)%s*')

  row.targetEntry = 0
  row.conditionEntry = 0

  if findstart and findend and parens ~= '' then
    parens = string.sub(parens, 0, 3)
    for k, v in ipairs(startParenEntries) do
      if v.notation == parens then
        row.startParenEntry = k
        break
      end
    end
    bufstart = findend + 1
  end
  for k, v in ipairs(findTargetEntries) do
    findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%s+', bufstart)
    if findstart and findend then
      row.targetEntry = k
      bufstart = findend + 1
      -- mu.post('found target: ' .. v.label)
      break
    end
  end

  if row.targetEntry < 1 then return end

  local param1Tab, param2Tab
  local condTab = findTargetToTabs(row, row.targetEntry)

  -- do we need some way to filter out extraneous (/) chars?
  for k, v in ipairs(condTab) do
    -- mu.post('testing ' .. buf .. ' against ' .. '/^%s*' .. v.notation .. '%s+/')
    local param1, param2

    findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%s+', bufstart)
    if findstart and findend then
      row.conditionEntry = k
      bufstart = findend + 1
      condTab, param1Tab, param2Tab = findTargetToTabs(row, row.targetEntry)
      findstart, findend, param1 = string.find(buf, '^%s*([^%s%)]*)%s*', bufstart)
      if param1 and param1 ~= '' then
        bufstart = findend + 1
        param1 = handleParam(row, findTargetEntries[row.targetEntry], condTab[row.conditionEntry], 'param1', param1Tab, param1)
      end
      row.param1Val = param1
      break
    else
      findstart, findend, param1, param2 = string.find(buf, '^%s*' .. v.notation .. '%(([^,]-)[,%s]*([^,]-)%)', bufstart)
      if not (findstart and findend) then
        findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%(%s-%)', bufstart)
      end
      if findstart and findend then
        row.conditionEntry = k
        bufstart = findend + 1

        condTab, param1Tab, param2Tab = findTargetToTabs(row, row.targetEntry)
        if param2 and not (param1 and param1 ~= '') then param1 = param2 param2 = nil end
        if param1 and param1 ~= '' then
          param1 = handleParam(row, findTargetEntries[row.targetEntry], condTab[row.conditionEntry], 'param1', param1Tab, param1)
        end
        if param2 and param2 ~= '' then
          param2 = handleParam(row, findTargetEntries[row.targetEntry], condTab[row.conditionEntry], 'param2', param2Tab, param2)
        end
        row.param1Val = param1
        row.param2Val = param2
        break
      end
    end
  end

  findstart, findend, parens = string.find(buf, '^%s*(%)+)%s*', bufstart)
  if findstart and findend and parens ~= '' then
    parens = string.sub(parens, 0, 3)
    for k, v in ipairs(endParenEntries) do
      if v.notation == parens then
        row.endParenEntry = k
        break
      end
    end
    bufstart = findend + 1
  end

  if row.targetEntry ~= 0 and row.conditionEntry ~= 0 then
    if boolstr == '||' then row.booleanEntry = 2 end
    addFindRow(row)
  else
    mu.post('Error parsing row: ' .. buf)
  end
end

local function processFindMacro(buf)
  local bufstart = 0
  local rowstart, rowend, boolstr = string.find(buf, '%s+(&&)%s+')
  if not (rowstart and rowend) then
    rowstart, rowend, boolstr = string.find(buf, '%s+(||)%s+')
  end
  while rowstart and rowend do
    local rowbuf = string.sub(buf, bufstart, rowend)
    -- mu.post('got row: ' .. rowbuf) -- process
    processFindMacroRow(rowbuf, boolstr)
    bufstart = rowend + 1
    rowstart, rowend, boolstr = string.find(buf, '%s+(&&)%s+', bufstart)
    if not (rowstart and rowend) then
      rowstart, rowend, boolstr = string.find(buf, '%s+(||)%s+', bufstart)
    end
  end
  -- last iteration
  -- mu.post('last row: ' .. string.sub(buf, bufstart)) -- process
  processFindMacroRow(string.sub(buf, bufstart))
end

local function lengthFormatToSeconds(buf)
  -- b.b.f vs h:m.s vs ...?
  local tbars, tbeats, tfraction = string.match(buf, '(%d+)%.(%d+)%.(%d+)')
  local bars = tonumber(tbars)
  local beats = tonumber(tbeats)
  local fraction = tonumber(tfraction)
  fraction = not fraction and 0 or fraction > 99 and 99 or fraction < 0 and 0 or fraction
  return r.TimeMap2_beatsToTime(0, beats + (fraction / 100.), bars)
end

local function timeFormatToSeconds(buf)
  -- b.b.f vs h:m.s vs ...?
  local tbars, tbeats, tfraction = string.match(buf, '(%d+)%.(%d+)%.(%d+)')
  local bars = tonumber(tbars)
  local beats = tonumber(tbeats)
  local fraction = tonumber(tfraction)
  fraction = not fraction and 0 or fraction > 99 and 99 or fraction < 0 and 0 or fraction
  return r.TimeMap2_beatsToTime(0, beats + (fraction / 100.), bars)
end

local mainValueLabel
local subtypeValueLabel

local function decorateTargetLabel(label)
  if label == 'Value 1' then
    label = label .. ((subtypeValueLabel and subtypeValueLabel ~= '') and ' (' .. subtypeValueLabel .. ')' or '')
  elseif label == 'Value 2' then
    label = label .. ((mainValueLabel and mainValueLabel ~= '') and ' (' .. mainValueLabel .. ')' or '')
  end
  return label
end

local function doProcessParams(row, target, condOp, paramName, paramType, paramTab, terms, notation)
  local addMetricGridNotation = false
  if paramType == PARAM_TYPE_METRICGRID then
    if terms == 1 then
      if notation then addMetricGridNotation = true end
      paramType = PARAM_TYPE_MENU
    end
  end
  local paramVal = condOp.terms < terms and ''
    or paramType == PARAM_TYPE_TEXTEDITOR and row[paramName .. 'TextEditorStr']
    or paramType == PARAM_TYPE_TIME and (notation and row[paramName .. 'TimeFormatStr'] or tostring(timeFormatToSeconds(row[paramName .. 'TimeFormatStr'])))
    or paramType == PARAM_TYPE_TIMEDUR and (notation and row[paramName .. 'TimeFormatStr'] or tostring(lengthFormatToSeconds(row[paramName .. 'TimeFormatStr'])))
    or paramType == PARAM_TYPE_METRICGRID and row[paramName .. 'TextEditorStr']
    or #paramTab ~= 0 and (notation and paramTab[row[paramName .. 'Entry']].notation or paramTab[row[paramName .. 'Entry']].text)
  if addMetricGridNotation then
    paramVal = paramVal .. generateMetricGridNotation(row)
  end
  return paramVal
end

local function processParams(row, target, condOp, param1Tab, param2Tab, notation)
  local paramType = getEditorTypeForRow(target, condOp)
  local param1Val = doProcessParams(row, target, condOp, 'param1', paramType, param1Tab, 1, notation)
  local param2Val = doProcessParams(row, target, condOp, 'param2', paramType, param2Tab, 2, notation)

  return param1Val, param2Val
end

  ---------------------------------------------------------------------------
  -------------------------------- FIND UTILS -------------------------------

local function prepFindEntries(row)
  if row.targetEntry < 1 then return {}, {}, {}, {}, {} end

  local condTab, param1Tab, param2Tab = findTargetToTabs(row, row.targetEntry)
  local curTarget = findTargetEntries[row.targetEntry]
  local curCondition = condTab[row.conditionEntry]

  return condTab, param1Tab, param2Tab, curTarget, curCondition
end

local function findRowsToNotation()
  local notationString = ''
  for k, v in ipairs(findRowTable) do
    local rowText = ''

    local condTab, param1Tab, param2Tab, curTarget, curCondition = prepFindEntries(v)
    rowText = curTarget.notation .. ' ' .. curCondition.notation
    local param1Val, param2Val
    local paramType = getEditorTypeForRow(curTarget, curCondition)
    if paramType == PARAM_TYPE_MENU then
      param1Val = (curCondition.terms > 0 and #param1Tab) and param1Tab[v.param1Entry].notation or nil
      param2Val = (curCondition.terms > 1 and #param2Tab) and param2Tab[v.param2Entry].notation or nil
    else
      param1Val, param2Val = processParams(v, curTarget, curCondition, param1Tab, param2Tab, true)
    end
    if string.match(curCondition.notation, '[!]*%:') then
      rowText = rowText .. '('
      if param1Val and param1Val ~= '' then
        rowText = rowText .. param1Val
        if param2Val and param2Val ~= '' then
          rowText = rowText .. ', ' .. param2Val
        end
      end
      rowText = rowText .. ')'
    else
      if param1Val and param1Val ~= '' then
        rowText = rowText .. ' ' .. param1Val -- no param2 val without a function
      end
    end

    if v.startParenEntry > 1 then rowText = startParenEntries[v.startParenEntry].notation .. ' ' .. rowText end
    if v.endParenEntry > 1 then rowText = rowText .. ' ' .. endParenEntries[v.endParenEntry].notation end

    if k ~= #findRowTable then
      rowText = rowText .. (v.booleanEntry == 2 and ' || ' or ' && ')
    end
    notationString = notationString .. rowText
  end
  mu.post('find macro: ' .. notationString)
  return notationString
end

local function processFind(take)

  local fnString = ''

  for k, v in ipairs(findRowTable) do
    local condTab, param1Tab, param2Tab, curTarget, curCondition = prepFindEntries(v)

    if (#condTab == 0) then return end -- continue?

    local targetTerm = curTarget.text
    local condition = curCondition
    local conditionVal = condition.text
    local findTerm = ''

    v.param1Val, v.param2Val = processParams(v, curTarget, condition, param1Tab, param2Tab)

    local param1Term = v.param1Val -- param1Entries[currentFindParam1Entry].text
    local param2Term = v.param2Val -- (condition.terms > 1 and #param2Entries ~= 0) and param2Entries[currentFindParam2Entry].text or ''

    if curCondition.terms > 0 and param1Term == '' then return end

    local param1Num = tonumber(param1Term)
    local param2Num = tonumber(param2Term)
    if param1Num and param2Num and param2Num < param1Num then
      local tmp = param2Term
      param2Term = param1Term
      param1Term = tmp
    end

    findTerm = targetTerm .. ' ' .. conditionVal .. (condition.terms == 0 and '' or ' ' .. param1Term)

    local paramType = getEditorTypeForRow(curTarget, condition)

    if condition.sub then
      findTerm = conditionVal
      findTerm = string.gsub(findTerm, '{tgt}', targetTerm)
      findTerm = string.gsub(findTerm, '{param1}', param1Term)
      findTerm = string.gsub(findTerm, '{param2}', param2Term)
      if paramType == PARAM_TYPE_METRICGRID then
        local mgParams = tableCopy(v.mg)
        mgParams.param1 = param1Num
        mgParams.param2 = param2Term
        findTerm = string.gsub(findTerm, '{metricgridparams}', serialize(mgParams))
      end
    else
      findTerm = targetTerm .. ' ' .. conditionVal .. (condition.terms == 0 and '' or ' ' .. param1Term)
    end

    findTerm = string.gsub(findTerm, '^%s*(.-)%s*$', '%1')

    local startParen = v.startParenEntry > 1 and (startParenEntries[v.startParenEntry].text .. ' ') or ''
    local endParen = v.endParenEntry > 1 and (' ' .. endParenEntries[v.endParenEntry].text) or ''

    local rowStr = startParen .. '( ' .. findTerm .. ' )' .. endParen
    if k ~= #findRowTable then
      rowStr = rowStr .. ' ' .. findBooleanEntries[v.booleanEntry].text
    end
    -- mu.post(k .. ': ' .. rowStr)

    fnString = fnString == '' and rowStr or fnString .. ' ' .. rowStr -- TODO Boolean

  end
  -- what about multiple param1?

  fnString = 'local entry = ... \nreturn ' .. fnString
  -- mu.post(fnString)

  local findFn

  context.take = take
  context.PPQ = take and mu.MIDI_GetPPQ(take) or 960 -- REAPER default, we could look this up from the prefs
  local success, pret, err = pcall(load, fnString, nil, nil, context)
  if success then
    findFn = pret
    findParserError = ''
  else
    mu.post(pret)
    findParserError = 'Fatal error: could not load selection criteria'
    if err then
      if string.match(err, '\'%)\' expected') then
        findParserError = findParserError .. ' (Unmatched Parentheses)'
      end
    end
  end
  return findFn
end

local function actionTargetToTabs(targetEntry)
  local opTab = {}
  local param1Tab = {}
  local param2Tab = {}

  if targetEntry > 0 then
    local notation = actionTargetEntries[targetEntry].notation
    if notation == '$position' then
      opTab = actionPositionOperationEntries
    elseif notation == '$length' then
      opTab = actionLengthOperationEntries
    elseif notation == '$channel' then
      opTab = actionChannelOperationEntries
      param1Tab = findChannelParam1Entries -- same as find
    elseif notation == '$type' then
      opTab = actionTypeOperationEntries
      param1Tab = findTypeParam1Entries -- same entries as find
    elseif notation == '$property' then
      opTab = actionPropertyOperationEntries
      param1Tab = actionPropertyParam1Entries
    elseif notation == '$value1' then
      opTab = actionSubtypeOperationEntries
    elseif notation == '$value2' then
      opTab = actionVelocityOperationEntries
    elseif notation == '$velocity' then
      opTab = actionVelocityOperationEntries
    elseif notation == '$relvel' then
      opTab = actionVelocityOperationEntries
    else
      opTab = actionGenericOperationEntries
    end
  end
  return opTab, param1Tab, param2Tab
end

local function processActionMacroRow(buf)
  local row = ActionRow()
  local bufstart = 0
  local findstart, findend

  row.targetEntry = 0
  row.operationEntry = 0

  for k, v in ipairs(actionTargetEntries) do
    findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%s*', bufstart)
    if findstart and findend then
      row.targetEntry = k
      bufstart = findend + 1
      -- mu.post('found target: ' .. v.label)
      break
    end
  end

  if row.targetEntry < 1 then return end

  local opTab, param1Tab, param2Tab = actionTargetToTabs(row.targetEntry) -- a little simpler than findTargets, no operation-based overrides (yet)

  -- do we need some way to filter out extraneous (/) chars?
  for k, v in ipairs(opTab) do
    -- mu.post('testing ' .. buf .. ' against ' .. '/^%s*' .. v.notation .. '%s+/')
    findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%s+', bufstart)
    if findstart and findend then
      row.operationEntry = k
      bufstart = findend + (buf[findend] == '(' and 0 or 1)

      local _, _, param1 = string.find(buf, '^%s*([^%s]*)%s*', bufstart)
      if param1 and param1 ~= '' then
        param1 = handleParam(row, actionTargetEntries[row.targetEntry], opTab[row.operationEntry], 'param1', param1Tab, param1)
      end
      row.param1Val = param1
      break
    else
      local param1, param2
      findstart, findend, param1, param2 = string.find(buf, '^%s*' .. v.notation .. '%(([^,]-)[,%s]*([^,]-)%)', bufstart)
      if findstart and findend then
        row.operationEntry = k
        if param2 and not (param1 and param1 ~= '') then param1 = param2 param2 = nil end
        if param1 and param1 ~= '' then
          param1 = handleParam(row, actionTargetEntries[row.targetEntry], opTab[row.operationEntry], 'param1', param1Tab, param1)
        end
        if param2 and param2 ~= '' then
          param2 = handleParam(row, actionTargetEntries[row.targetEntry], opTab[row.operationEntry], 'param2', param2Tab, param2)
        end
        row.param1Val = param1
        row.param2Val = param2
        -- mu.post(v.label .. ': ' .. (param1 and param1 or '') .. ' / ' .. (param2 and param2 or ''))
        break
      end
    end
  end

  if row.targetEntry ~= 0 and row.operationEntry ~= 0 then
    addActionRow(row)
  else
    mu.post('Error parsing row: ' .. buf)
  end
end

local function processActionMacro(buf)
  local bufstart = 0
  local rowstart, rowend = string.find(buf, '%s+(&&)%s+')
  while rowstart and rowend do
    local rowbuf = string.sub(buf, bufstart, rowend)
    -- mu.post('got row: ' .. rowbuf) -- process
    processActionMacroRow(rowbuf)
    bufstart = rowend + 1
    rowstart, rowend = string.find(buf, '%s+(&&)%s+', bufstart)
  end
  -- last iteration
  -- mu.post('last row: ' .. string.sub(buf, bufstart)) -- process
  processActionMacroRow(string.sub(buf, bufstart))
end


  ----------------------------------------------
  ---------------- ACTIONS TABLE ---------------
  ----------------------------------------------

local function prepActionEntries(row)
  if row.targetEntry < 1 then return {}, {}, {}, {}, {} end

  local opTab, param1Tab, param2Tab = actionTargetToTabs(row.targetEntry)
  local curTarget = actionTargetEntries[row.targetEntry]
  local curOperation = opTab[row.operationEntry]
  return opTab, param1Tab, param2Tab, curTarget, curOperation
end

local mediaItemCount
local mediaItemIndex

local function getNextTake()
  local take
  local notation = findScopeTable[currentFindScope].notation
  if notation == '$midieditor' and not mediaItemCount then
    mediaItemCount = 1
    take = r.MIDIEditor_GetTake(r.MIDIEditor_GetActive())
    return take
  elseif notation == '$selected' then
    if not mediaItemCount then
      mediaItemCount = r.CountSelectedMediaItems(0)
      mediaItemIndex = 0
    else
      mediaItemIndex = mediaItemIndex + 1
    end

    while mediaItemIndex < mediaItemCount do
      local item = r.GetSelectedMediaItem(0, mediaItemIndex)
      if item then
        take = r.GetActiveTake(item)
        if take and r.TakeIsMIDI(take) then
          return take
        end
      end
      mediaItemIndex = mediaItemIndex + 1
    end
  elseif notation == '$everywhere' then
    if not mediaItemCount then
      mediaItemCount = r.CountMediaItems(0)
      mediaItemIndex = 0
    else
      mediaItemIndex = mediaItemIndex + 1
    end

    while mediaItemIndex < mediaItemCount do
      local item = r.GetMediaItem(0, mediaItemIndex)
      if item then
        take = r.GetActiveTake(item)
        if take and r.TakeIsMIDI(take) then
          return take
        end
      end
      mediaItemIndex = mediaItemIndex + 1
    end
  end
  return nil
end

local function initializeTake(take)
  allEvents = {}
  mu.MIDI_InitializeTake(take) -- reset this each cycle
  local noteidx = mu.MIDI_EnumNotes(take, -1)
  while noteidx ~= -1 do
    local e = { type = NOTE_TYPE, idx = noteidx }
    _, e.selected, e.muted, e.ppqpos, e.endppqpos, e.chan, e.pitch, e.vel, e.relvel = mu.MIDI_GetNote(take, noteidx)
    e.msg2 = e.pitch
    e.msg3 = e.vel
    e.notedur = e.endppqpos - e.ppqpos
    e.chanmsg = 0x90
    e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
    calcMIDITime(take, e)
    table.insert(allEvents, e)
    noteidx = mu.MIDI_EnumNotes(take, noteidx)
  end

  local ccidx = mu.MIDI_EnumCC(take, -1)
  while ccidx ~= -1 do
    local e = { type = CC_TYPE, idx = ccidx }
    _, e.selected, e.muted, e.ppqpos, e.chanmsg, e.chan, e.msg2, e.msg3 = mu.MIDI_GetCC(take, ccidx)

    if e.chanmsg == 0xE0 then
      e.ccnum = INVALID
      e.ccval = ((e.msg3 << 7) + e.msg2) - (1 << 13)
    elseif e.chanmsg == 0xD0 then
      e.ccnum = INVALID
      e.ccval = e.msg2
    else
      e.ccnum = e.msg2
      e.ccval = e.msg3
    end
    e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
    calcMIDITime(take, e)
    table.insert(allEvents, e)
    ccidx = mu.MIDI_EnumCC(take, ccidx)
  end

  local syxidx = mu.MIDI_EnumSelTextSysexEvts(take, -1)
  while syxidx ~= -1 do
    local e = { type = SYXTEXT_TYPE, idx = syxidx }
    _, e.selected, e.muted, e.ppqpos, e.chanmsg, e.textmsg = mu.MIDI_GetTextSysexEvt(take, syxidx)
    e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
    calcMIDITime(take, e)
    table.insert(allEvents, e)
    syxidx = mu.MIDI_EnumSelTextSysexEvts(take, syxidx)
  end
end

local function actionRowsToNotation()
  local notationString = ''
  for k, v in ipairs(actionRowTable) do
    local rowText = ''

    -- mu.tprint(v)
    local opTab, param1Tab, param2Tab, curTarget, curOperation = prepActionEntries(v)
    rowText = curTarget.notation .. ' ' .. curOperation.notation
    local param1Val, param2Val
    if curTarget.menu then
      param1Val = (curOperation.terms > 0 and #param1Tab) and param1Tab[v.param1Entry].notation or nil
      param2Val = (curOperation.terms > 1 and #param2Tab) and param2Tab[v.param2Entry].notation or nil
    else
      param1Val, param2Val = processParams(v, curTarget, curOperation, param1Tab, param2Tab, true)
    end
    if string.match(curOperation.notation, '[!]*%:') then
      rowText = rowText .. '('
      if param1Val and param1Val ~= '' then
        rowText = rowText .. param1Val
        if param2Val and param2Val ~= '' then
          rowText = rowText .. ', ' .. param2Val
        end
      end
      rowText = rowText .. ')'
    else
      if param1Val and param1Val ~= '' then
        rowText = rowText .. ' ' .. param1Val -- no param2 val without a function
      end
    end

    if k ~= #actionRowTable then
      rowText = rowText .. ' && '
    end
    notationString = notationString .. rowText
  end
  mu.post('action macro: ' .. notationString)
  return notationString
end

local function runFind(findFn, getUnfound)
  local found = {}
  local unfound = {}

  local firstTime = 0xFFFFFFFF
  local lastTime = -0xFFFFFFFF
  for _, entry in ipairs(allEvents) do
    if findFn(entry) then
      if entry.projtime < firstTime then firstTime = entry.projtime end
      if entry.projtime > lastTime then lastTime = entry.projtime end
      table.insert(found, entry)
    elseif getUnfound then
      table.insert(unfound, entry)
    end
  end
  return found, firstTime, lastTime, getUnfound and unfound or nil
end

local function deleteEventsInTake(take, entryTab, doTx)
  if doTx == true or doTx == nil then
    mu.MIDI_OpenWriteTransaction(take)
  end
  for _, entry in ipairs(entryTab) do
    if entry.type == NOTE_TYPE then
      mu.MIDI_DeleteNote(take, entry.idx)
    elseif entry.type == CC_TYPE then
      mu.MIDI_DeleteCC(take, entry.idx)
    elseif entry.type == SYXTEXT_TYPE then
      mu.MIDI_DeleteTextSysexEvt(take, entry.idx)
    end
  end
  if doTx == true or doTx == nil then
    mu.MIDI_CommitWriteTransaction(take, false, true)
  end
end

local function insertEventsIntoTake(take, entryTab, actionFn, selStart, selEnd, doTx)
  if doTx == true or doTx == nil then
    mu.MIDI_OpenWriteTransaction(take)
  end
  for _, entry in ipairs(entryTab) do
    actionFn(entry, GetSubtypeValueName(entry), GetMainValueName(entry), selStart, selEnd)
    entry.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, entry.projtime)
    entry.selected = (entry.flags & 1) ~= 0
    entry.muted = (entry.flags & 2) ~= 0
    if entry.type == NOTE_TYPE then
      entry.endppqos = r.MIDI_GetPPQPosFromProjTime(take, entry.projtime + entry.projlen)
      mu.MIDI_InsertNote(take, entry.selected, entry.muted, entry.ppqpos, entry.endppqos, entry.chan, entry.msg2, entry.msg3, entry.relvel)
    elseif entry.type == CC_TYPE then
      mu.MIDI_InsertCC(take, entry.selected, entry.muted, entry.ppqpos, entry.chanmsg, entry.chan, entry.msg2, entry.msg3)
    elseif entry.type == SYXTEXT_TYPE then
      mu.MIDI_InsertTextSysexEvt(take, entry.selected, entry.muted, entry.ppqpos, entry.chanmsg, entry.textmsg)
    end
  end
  if doTx == true or doTx == nil then
    mu.MIDI_CommitWriteTransaction(take, false, true)
  end
end

local function setEntrySelectionInTake(take, entry)
  if entry.type == NOTE_TYPE then
    mu.MIDI_SetNote(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil, nil)
  elseif entry.type == CC_TYPE then
    mu.MIDI_SetCC(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil)
  elseif entry.type == SYXTEXT_TYPE then
    mu.MIDI_SetTextSysexEvt(take, entry.idx, entry.selected, nil, nil, nil, nil)
  end
end

local function transformEntryInTake(take, entryTab, actionFn, firstTime, lastTime)
  mu.MIDI_OpenWriteTransaction(take)
  for _, entry in ipairs(entryTab) do
    actionFn(entry, GetSubtypeValueName(entry), GetMainValueName(entry), firstTime, lastTime)
    entry.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, entry.projtime)
    entry.selected = (entry.flags & 1) ~= 0
    entry.muted = (entry.flags & 2) ~= 0
    if entry.type == NOTE_TYPE then
      entry.endppqos = r.MIDI_GetPPQPosFromProjTime(take, entry.projtime + entry.projlen)
      mu.MIDI_SetNote(take, entry.idx, entry.selected, entry.muted, entry.ppqpos, entry.endppqos, entry.chan, entry.msg2, entry.msg3, entry.relvel)
    elseif entry.type == CC_TYPE then
      mu.MIDI_SetCC(take, entry.idx, entry.selected, entry.muted, entry.ppqpos, entry.chanmsg, entry.chan, entry.msg2, entry.msg3)
    elseif entry.type == SYXTEXT_TYPE then
      mu.MIDI_SetTextSysexEvt(take, entry.idx, entry.selected, entry.muted, entry.ppqpos, entry.chanmsg, entry.textmsg)
    end
  end
  mu.MIDI_CommitWriteTransaction(take, false, true)
end

local function newTakeInNewTrack(take)
  local track = r.GetMediaItemTake_Track(take)
  local item = r.GetMediaItemTake_Item(take)
  local trackid = r.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER')
  local newtake
  if trackid ~= 0 then
    r.InsertTrackAtIndex(trackid, true)
    local newtrack = r.GetTrack(0, trackid)
    if newtrack then
      local itemPos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
      local itemLen = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local newitem = r.CreateNewMIDIItemInProj(newtrack, itemPos, itemPos + itemLen)
      if newitem then
        newtake = r.GetActiveTake(newitem)
      end
    end
  end
  return newtake
end

local function newTakeInNewLane(take)
  local newtake
  local track = r.GetMediaItemTake_Track(take)
  local item = r.GetMediaItemTake_Item(take)
  if track and item then
    local freemode = r.GetMediaTrackInfo_Value(track, 'I_FREEMODE')
    local numLanes = r.GetMediaTrackInfo_Value(track, 'I_NUMFIXEDLANES')
    if freemode ~= 2 then
      r.SetMediaTrackInfo_Value(track, 'I_FREEMODE', 2)
    end
    r.SetMediaTrackInfo_Value(track, 'I_NUMFIXEDLANES', numLanes + 1)

    local itemPos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
    local itemLen = r.GetMediaItemInfo_Value(item, 'D_LENGTH')

    local trackid = r.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER')

    local tmi = r.CountTrackMediaItems(track)
    local lastItem = r.GetTrackMediaItem(track, tmi - 1)
    if lastItem then
      local lastItemPos = r.GetMediaItemInfo_Value(lastItem, 'D_POSITION')
      local lastItemLen = r.GetMediaItemInfo_Value(lastItem, 'D_LENGTH')
      local safeTime = lastItemPos + lastItemLen + 5

      local newitem = r.CreateNewMIDIItemInProj(track, safeTime, safeTime + itemLen) -- make new item at the very end
      if newitem then
        r.SetMediaItemInfo_Value(newitem, 'I_FIXEDLANE', numLanes)
        r.SetMediaItemInfo_Value(newitem, 'D_POSITION', itemPos)
        r.SetMediaItemInfo_Value(newitem, 'D_LENGTH', itemLen)
        newtake = r.GetActiveTake(newitem)
      end
      r.UpdateTimeline()
    end
  end
  return newtake
end

local function processAction(select)
  mediaItemCount = nil
  mediaItemIndex = nil

  local take = getNextTake()
  if not take then return end

  CACHED_METRIC = nil
  CACHED_WRAPPED = nil
  SOM = nil

  local fnString = ''

  for k, v in ipairs(actionRowTable) do
    local opTab, param1Tab, param2Tab, curTarget, curOperation = prepActionEntries(v)

    if (#opTab == 0) then return end -- continue?

    local targetTerm = curTarget.text
    local operation = curOperation
    local operationVal = operation.text
    local actionTerm = ''

    v.param1Val, v.param2Val = processParams(v, curTarget, curOperation, param1Tab, param2Tab)

    local param1Term = v.param1Val
    local param2Term = v.param2Val

    if param1Term == '' then return end

    local param1Num = tonumber(param1Term)
    local param2Num = tonumber(param2Term)
    if param1Num and param2Num and param2Num < param1Num then
      local tmp = param2Term
      param2Term = param1Term
      param1Term = tmp
    end

    if not operation.sub then
      targetTerm = targetTerm .. ' = ' .. targetTerm
      actionTerm = targetTerm .. ' ' .. operationVal .. (operation.terms == 0 and '' or ' ' .. param1Term)
    else
      actionTerm = targetTerm .. ' ' .. operationVal
    end

    if operation.sub then
      actionTerm = string.gsub(actionTerm, '{tgt}', targetTerm)
      actionTerm = string.gsub(actionTerm, '{param1}', param1Term)
      actionTerm = string.gsub(actionTerm, '{param2}', param2Term)
    end

    actionTerm = string.gsub(actionTerm, '^%s*(.-)%s*$', '%1') -- trim whitespace

    local rowStr = actionTerm
    if curTarget.cond then
      rowStr = 'if ' .. curTarget.cond .. ' then ' .. rowStr .. ' end'
    end
    -- mu.post(k .. ': ' .. rowStr)

    fnString = fnString == '' and rowStr or fnString .. ' ' .. rowStr ..'\n'

  end
  fnString = 'return function(entry, _value1, _value2, _firstSel, _lastSel)\n' .. fnString .. '\nreturn entry' .. '\nend'
  -- mu.post(fnString)

  r.Undo_BeginBlock2(0)

  while take do
    initializeTake(take)

    local actionFn
    local findFn = processFind(take)
    if findFn then
      local success, pret, err = pcall(load, fnString, nil, nil, context)
      if success and pret then
        actionFn = pret()
      else
        mu.post(err)
        findParserError = 'Fatal error: could not load action description'
      end
    end

    if findFn and actionFn then
      if not select then -- not select then -- DEBUG
        -- local entry = { chanmsg = 0xA0, chan = 2, flags = 2, ppqpos = 2.25, msg2 = 64, msg3 = 64 }
        -- -- mu.tprint(entry, 2)
        -- actionFn(entry, GetSubtypeValueName(entry), GetMainValueName(entry)) -- always returns true
        -- mu.tprint(entry, 2)
      else
        local notation = actionScopeTable[currentActionScope].notation
        if notation == '$select' then
          mu.MIDI_OpenWriteTransaction(take)
          for _, entry in ipairs(allEvents) do
            entry.selected = findFn(entry)
            setEntrySelectionInTake(take, entry)
          end
          mu.MIDI_CommitWriteTransaction(take, false, true)
        elseif notation == '$selectadd' then
          mu.MIDI_OpenWriteTransaction(take)
          for _, entry in ipairs(allEvents) do
            local matching = findFn(entry)
            if matching then
              entry.selected = true
              setEntrySelectionInTake(take, entry)
            end
          end
          mu.MIDI_CommitWriteTransaction(take, false, true)
        elseif notation == '$invertselect' then
          mu.MIDI_OpenWriteTransaction(take)
          for _, entry in ipairs(allEvents) do
            entry.selected = (findFn(entry) == false) and true or false
            setEntrySelectionInTake(take, entry)
          end
          mu.MIDI_CommitWriteTransaction(take, false, true)
        elseif notation == '$deselect' then
          mu.MIDI_OpenWriteTransaction(take)
          for _, entry in ipairs(allEvents) do
            local matching = findFn(entry)
            if matching then
              entry.selected = false
              setEntrySelectionInTake(take, entry)
            end
          end
          mu.MIDI_CommitWriteTransaction(take, false, true)
        elseif notation == '$transform' then
          local found, firstTime, lastTime = runFind(findFn)
          if #found ~=0 then
            transformEntryInTake(take, found, actionFn, firstTime, lastTime)
          end
        elseif notation == '$copy' then
          local found, firstTime, lastTime = runFind(findFn)
          if #found ~=0 then
            local newtake = newTakeInNewTrack(take)
            if newtake then
              insertEventsIntoTake(newtake, found, actionFn, firstTime, lastTime)
            end
          end
        elseif notation == '$insert' then
          local found, firstTime, lastTime = runFind(findFn)
          if #found ~=0 then
            insertEventsIntoTake(take, found, actionFn, firstTime, lastTime)
          end
        elseif notation == '$insertexclusive' then
          local found, firstTime, lastTime, unfound = runFind(findFn, true)
          mu.MIDI_OpenWriteTransaction(take)
          if #found ~=0 then
            insertEventsIntoTake(take, found, actionFn, firstTime, lastTime, false)
          end
          if #unfound ~=0 then
            for _, entry in ipairs(unfound) do
              deleteEventsInTake(take, unfound, false)
            end
          end
          mu.MIDI_CommitWriteTransaction(take, false, true)
        elseif notation == '$extracttrack' then
          local found, firstTime, lastTime = runFind(findFn)
          if #found ~=0 then
            deleteEventsInTake(take, found)
            local newtake = newTakeInNewTrack(take)
            if newtake then
              insertEventsIntoTake(newtake, found, actionFn, firstTime, lastTime)
            end
          end
        elseif notation == '$extractlane' then
          local found, firstTime, lastTime = runFind(findFn)
          if #found ~=0 then
            deleteEventsInTake(take, found)
            local newtake = newTakeInNewLane(take)
            if newtake then
              insertEventsIntoTake(newtake, found, actionFn, firstTime, lastTime)
            end
          end
        elseif notation == '$delete' then
          local found = runFind(findFn)
          if #found ~= 0 then
            deleteEventsInTake(take, found)
          end
        end
      end
      take = getNextTake()
    end
  end

  r.Undo_EndBlock2(0, 'Transformer: ' .. actionScopeTable[currentActionScope].label, -1)
end

local function savePreset(presetPath, wantsScript)
  local f = io.open(presetPath, 'wb')
  local saved = false
  if f then
    local presetTab = {
      findScope = findScopeTable[currentFindScope].notation,
      findMacro = findRowsToNotation(),
      actionScope = actionScopeTable[currentActionScope].notation,
      actionMacro = actionRowsToNotation()
    }
    f:write(serialize(presetTab) .. '\n')
    f:close()
    saved = true
  end

  if (saved and wantsScript) then
    saved = false

    local fPath, fName = presetPath:match('^(.*[/\\])(.*)$')
    if fPath and fName then
      local fRoot = fName:match('(.*)%.')
      if fRoot then
        f = io.open(fPath .. fRoot .. '.lua', 'wb')
        if f then
          f:write('package.path = reaper.GetResourcePath() .. "/Scripts/sockmonkey72 Scripts/MIDI Editor/Transformer/?.lua"\n')
          f:write('local tx = require("TransformerLib")\n')
          f:write('local thisPath = debug.getinfo(1, "S").source:match [[^@?(.*[\\/])[^\\/]-$]]\n')
          f:write('tx.loadPreset(thisPath .. "' .. fName .. '")\n')
          f:write('tx.processAction(true)\n')
          f:close()
          saved = true
        end
      end
    end
  end
  return saved
end

local function loadPresetFromTable(presetTab)
  currentActionScope = actionScopeFromNotation(presetTab.actionScope)
  currentFindScope = findScopeFromNotation(presetTab.findScope)
  findRowTable = {}
  processFindMacro(presetTab.findMacro)
  actionRowTable = {}
  processActionMacro(presetTab.actionMacro)
end

local function loadPreset(presetPath)
  local f = io.open(presetPath, 'r')
  if f then
    local presetStr = f:read('*all')
    f:close()

    if presetStr then
      local _, ps = string.find(presetStr, '-- START_PRESET')
      local pe = string.find(presetStr, '-- END_PRESET')
      local tabStr
      if ps and pe then
        tabStr = presetStr:sub(ps+1, pe-1)
      else
        tabStr = presetStr -- fallback for old presets
      end
      if tabStr and tabStr ~= '' then
        local presetTab = deserialize(tabStr)
        if presetTab then
          loadPresetFromTable(presetTab)
          return true
        end
      end
    end
  end
  return false
end

-- or accessors? it kind of doesn't matter, does it?
TransformerLib.findScopeTable = findScopeTable
TransformerLib.currentFindScope = function() return currentFindScope end
TransformerLib.setCurrentFindScope = function(val) currentFindScope = val < 1 and 1 or val > #findScopeTable and #findScopeTable or val end
TransformerLib.actionScopeTable = actionScopeTable
TransformerLib.currentActionScope = function() return currentActionScope end
TransformerLib.setCurrentActionScope = function(val) currentActionScope = val < 1 and 1 or val > #actionScopeTable and #actionScopeTable or val end

TransformerLib.FindRow = FindRow
TransformerLib.findRowTable = function() return findRowTable end

TransformerLib.startParenEntries = startParenEntries
TransformerLib.endParenEntries = endParenEntries
TransformerLib.findBooleanEntries = findBooleanEntries
TransformerLib.findTimeFormatEntries = findTimeFormatEntries

TransformerLib.ActionRow = ActionRow
TransformerLib.actionRowTable = function() return actionRowTable end

TransformerLib.findTargetEntries = findTargetEntries
TransformerLib.actionTargetEntries = actionTargetEntries

TransformerLib.GetSubtypeValueLabel = GetSubtypeValueLabel
TransformerLib.GetMainValueLabel = GetMainValueLabel

TransformerLib.processFindMacro = processFindMacro
TransformerLib.processActionMacro = processActionMacro

TransformerLib.processFind = processFind
TransformerLib.processAction = processAction

TransformerLib.prepFindEntries = prepFindEntries
TransformerLib.prepActionEntries = prepActionEntries

TransformerLib.savePreset = savePreset
TransformerLib.loadPreset = loadPreset

TransformerLib.timeFormatRebuf = timeFormatRebuf
TransformerLib.lengthFormatRebuf = lengthFormatRebuf

TransformerLib.getEditorTypeForRow = getEditorTypeForRow

TransformerLib.PARAM_TYPE_UNKNOWN = PARAM_TYPE_UNKNOWN
TransformerLib.PARAM_TYPE_MENU = PARAM_TYPE_MENU
TransformerLib.PARAM_TYPE_TEXTEDITOR = PARAM_TYPE_TEXTEDITOR
TransformerLib.PARAM_TYPE_TIME = PARAM_TYPE_TIME
TransformerLib.PARAM_TYPE_TIMEDUR = PARAM_TYPE_TIMEDUR
TransformerLib.PARAM_TYPE_METRICGRID = PARAM_TYPE_METRICGRID

return TransformerLib

-----------------------------------------------------------------------------
----------------------------------- FIN -------------------------------------