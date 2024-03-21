-- @description MIDI Transformer
-- @version 1.0-alpha.0
-- @author sockmonkey72
-- @about
--   # MIDI Transformer
-- @changelog
--   - initial
-- @provides
--   Transformer/MIDIUtils.lua https://raw.githubusercontent.com/jeremybernstein/ReaScripts/main/MIDI/MIDIUtils.lua
--   [main=main,midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Transformer.lua

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

-- metric grid: dotted/triplet, slop, length of range, reset at next bar after pattern concludes (added to end of menu?)
-- TODO: time input
-- TODO: functions

local r = reaper

package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
-- package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'Transformer/?.lua'
local mu = require 'MIDIUtils'
mu.ENFORCE_ARGS = false -- turn off type checking
mu.CORRECT_OVERLAPS = true
mu.CLAMP_MIDI_BYTES = true

-- TODO: library to execute a preset without UI
-- package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
-- require "Transformer/TransformeUtils"
-- local tx = require 'TransformerLib'

local function fileExists(name)
  local f = io.open(name,'r')
  if f ~= nil then io.close(f) return true else return false end
end

local canStart = true

local imGuiPath = r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua'
if not fileExists(imGuiPath) then
  mu.post('MIDI Transformer requires \'ReaImGui\' 0.8+ (install from ReaPack)\n')
  canStart = false
end

if not r.APIExists('JS_Mouse_GetState') then
  mu.post('MIDI Transformer requires the \'js_ReaScriptAPI\' extension (install from ReaPack)\n')
  canStart = false
end

if not mu.CheckDependencies('MIDI Transformer') then
  canStart = false
end

if not canStart then return end

dofile(r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8')

local scriptID = 'sockmonkey72_Transformer'

local ctx = r.ImGui_CreateContext(scriptID)
r.ImGui_SetConfigVar(ctx, r.ImGui_ConfigVar_DockingWithShift(), 1) -- TODO docking

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local viewPort

local FONTSIZE_LARGE = 13
local FONTSIZE_SMALL = 11
local DEFAULT_WIDTH = 68 * FONTSIZE_LARGE
local DEFAULT_HEIGHT = 40 * FONTSIZE_LARGE
local DEFAULT_ITEM_WIDTH = 70

local PAREN_COLUMN_WIDTH = 20

local windowInfo
local fontInfo

local INVALID = -0xFFFFFFFF

local canvasScale = 1.0

local function scaled(num)
  return num * canvasScale
end

local DEFAULT_TITLEBAR_TEXT = 'Transformer'
local titleBarText = DEFAULT_TITLEBAR_TEXT
local focusKeyboardHere

local disabledAutoOverlap = false
local dockID = 0

local NOTE_TYPE = 0
local CC_TYPE = 1
local SYXTEXT_TYPE = 2

local findConsoleText = ''
local actionConsoleText = ''

local presetTable = {}
local presetLabel = ''
local presetInputVisible = false

local lastInputTextBuffer = ''
local inOKDialog = false
local statusMsg = ''
local statusTime = nil
local statusContext = 0

local findParserError = ''

local refocusInput = false

local metricLastUnit = 3 -- 1/16 in findMetricGridParam1Entries
local metricLastBarRestart = false

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
  { notation = '$delete', label = 'Delete' },
  { notation = '$transform', label = 'Transform' },
  { notation = '$insert', label = 'Insert' },
  { notation = '$insertexclusive', label = 'Insert Exclusive' },
  { notation = '$copy', label = 'Copy' }, -- creates new track/item?
  { notation = '$select', label = 'Select Matching' },
  { notation = '$selectadd', label = 'Add Matching To Selection' },
  { notation = '$invertselect', label = 'Select Non-Matching' },
  { notation = '$deselect', label = 'Deselect Matching' },
  { notation = '$extracttrack', label = 'Extract to Track' }, -- how is this different?
  { notation = '$extractlane', label = 'Extract to Lanes' },
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

local selectedFindRow = 0
local findRowTable = {}

local function addFindRow(idx, row)
  idx = (idx and idx ~= 0) and idx or #findRowTable+1
  table.insert(findRowTable, idx, row and row or FindRow())
  selectedFindRow = idx
end

local function removeFindRow()
  if selectedFindRow ~= 0 then
    table.remove(findRowTable, selectedFindRow) -- shifts
    selectedFindRow = selectedFindRow <= #findRowTable and selectedFindRow or #findRowTable
  end
end

local findColumns = {
  '(',
  'Target',
  'Condition',
  'Parameter 1',
  'Parameter 2',
  'Bar Range/Time Base',
  ')',
  'Boolean'
}

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

local selectedActionRow = 0
local actionRowTable = {}

local function addActionRow(idx, row)
  idx = (idx and idx ~= 0) and idx or #actionRowTable+1
  table.insert(actionRowTable, idx, row and row or ActionRow())
  selectedActionRow = idx
end

local function removeActionRow()
  if selectedActionRow ~= 0 then
    table.remove(actionRowTable, selectedActionRow) -- shifts
    selectedActionRow = selectedActionRow <= #actionRowTable and selectedActionRow or #actionRowTable
  end
end

local actionColumns = {
  'Target',
  'Operation',
  'Parameter 1',
  'Parameter 2'
}

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
  actionOperationPlus, actionOperationMinus, actionOperationFixed, actionOperationRandom
}

local actionTypeOperationEntries = {
  actionOperationFixed
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

local selectedNotes = {} -- interframe cache
local isClosing = false

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

local function handleExtState()
end

local function prepRandomShit()
  handleExtState()
end

local function gooseAutoOverlap()
  -- r.SetToggleCommandState(sectionID, 40681, 0) -- this doesn't work
  r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40681) -- but this does
  disabledAutoOverlap = not disabledAutoOverlap
end

local function processBaseFontUpdate(baseFontSize)

  if not baseFontSize then return FONTSIZE_LARGE end

  baseFontSize = math.floor(baseFontSize)
  if baseFontSize < 10 then baseFontSize = 10
  elseif baseFontSize > 48 then baseFontSize = 48
  end

  if baseFontSize == FONTSIZE_LARGE then return FONTSIZE_LARGE end

  FONTSIZE_LARGE = baseFontSize
  FONTSIZE_SMALL = math.floor(baseFontSize * (11/13))
  fontInfo.largeDefaultSize = FONTSIZE_LARGE
  fontInfo.smallDefaultSize = FONTSIZE_SMALL

  windowInfo.defaultWidth = 68 * fontInfo.largeDefaultSize
  windowInfo.defaultHeight = 40 * fontInfo.smallDefaultSize
  DEFAULT_ITEM_WIDTH = 4.6 * FONTSIZE_LARGE
  windowInfo.width = windowInfo.defaultWidth -- * canvasScale
  windowInfo.height = windowInfo.defaultHeight -- * canvasScale
  windowInfo.wantsResize = true

  return FONTSIZE_LARGE
end

local function prepWindowAndFont()
  windowInfo = {
    defaultWidth = DEFAULT_WIDTH,
    defaultHeight = DEFAULT_HEIGHT,
    width = DEFAULT_WIDTH,
    height = DEFAULT_HEIGHT,
    left = 100,
    top = 100,
    wantsResize = false,
    wantsResizeUpdate = false
  }

  fontInfo = {
    large = r.ImGui_CreateFont('sans-serif', FONTSIZE_LARGE), largeSize = FONTSIZE_LARGE, largeDefaultSize = FONTSIZE_LARGE,
    small = r.ImGui_CreateFont('sans-serif', FONTSIZE_SMALL), smallSize = FONTSIZE_SMALL, smallDefaultSize = FONTSIZE_SMALL
  }
  r.ImGui_Attach(ctx, fontInfo.large)
  r.ImGui_Attach(ctx, fontInfo.small)

  processBaseFontUpdate(tonumber(r.GetExtState(scriptID, 'baseFont')))
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

local ppqToTime -- forward declaration to avoid vs.code warning

local function windowFn()

  ---------------------------------------------------------------------------
  --------------------------- BUNCH OF VARIABLES ----------------------------

  local allEvents = {}
  local vx, vy = r.ImGui_GetWindowPos(ctx)
  local handledEscape = false

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

  local hoverCol = r.ImGui_GetStyleColor(ctx, r.ImGui_Col_HeaderHovered())
  local hoverAlphaCol = (hoverCol &~ 0xFF) | 0x3F
  local activeCol = r.ImGui_GetStyleColor(ctx, r.ImGui_Col_HeaderActive())
  local activeAlphaCol = (activeCol &~ 0xFF) | 0x7F
  local _, framePaddingY = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())

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
      local relMeasures, relBeats, _, relTicks = ppqToTime(relativeppq)
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

  function ppqToTime(take, ppqpos, projtime)
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
    e.measures, e.beats, e.beatsmax, e.ticks = ppqToTime(take, e.ppqpos, e.projtime)
  end

  -- local function chanmsgToType(chanmsg)
  --   local type = chanmsg
  --   -- if type and type >= 1 and type <= #textTypes then type = 1 end
  --   return type
  -- end

  -- local function unionEntry(name, val, entry)
  --   if chanmsgToType(entry.chanmsg) == popupFilter then
  --     if not union[name] then union[name] = val
  --     elseif union[name] ~= val then union[name] = INVALID end
  --   end
  -- end

  -- local function commonUnionEntries(e)
  --   for _, v in ipairs(commonEntries) do
  --     unionEntry(v, e[v], e)
  --   end

  --   if chanmsgToType(e.chanmsg) == popupFilter then
  --     if e.ppqpos < union.selposticks then union.selposticks = e.ppqpos end
  --     if e.type == NOTE_TYPE then
  --       if e.endppqpos > union.selendticks then union.selendticks = e.endppqpos end
  --     else
  --       if e.ppqpos > union.selendticks then union.selendticks = e.ppqpos end
  --     end
  --   end
  -- end

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE FUNS -----------------------------

  -- local itemBounds = {}
  -- local ranges = {}
  local currentRect = {}

  local function updateCurrentRect()
    -- cache the positions to generate next box position
    currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
    currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
    currentRect.right = currentRect.right + scaled(20) -- add some spacing after the button
  end

  -- local recalcEventTimes = false
  -- local recalcSelectionTimes = false

  -- local function genItemID(name)
  --   local itemID = '##'..name
  --   if rewriteIDForAFrame == name then
  --     itemID = itemID..'_inactive'
  --     rewriteIDForAFrame = nil
  --   end
  --   return itemID
  -- end

  -- local function registerItem(name, recalcEvent, recalcSelection)
  --   local ix1, ix2 = currentRect.left, currentRect.right
  --   local iy1, iy2 = currentRect.top, currentRect.bottom
  --   table.insert(itemBounds, { name = name,
  --                              hitx = { ix1 - vx, ix2 - vx },
  --                              hity = { iy1 - vy, iy2 - vy },
  --                              recalcEvent = recalcEvent and true or false,
  --                              recalcSelection = recalcSelection and true or false
  --                            })
  -- end

  -- local function stringToValue(name, str, op)
  --   local val = tonumber(str)
  --   if val then
  --     if (not op or op == OP_ABS)
  --       and (name == 'chan' or name == 'beats')
  --     then
  --         val = val - 1
  --     elseif (wantsBBU
  --       and (not op or op == OP_ABS or op == OP_ADD or op == OP_SUB)
  --       and (name == 'ticks' or name == 'notedur'))
  --     then
  --       val = math.floor((val * 0.01) * PPQ)
  --     end
  --     return val
  --   end
  --   return nil
  -- end

  -- local function makeVal(name, str, op)
  --   local val = stringToValue(name, str, op)
  --   if val then
  --     userValues[name] = { operation = op and op or OP_ABS, opval = val }
  --     return true
  --   end
  --   return false
  -- end

  -- local function makeStringVal(name, str)
  --   userValues[name] = { operation = OP_ABS, opval = str }
  --   return true
  -- end

  -- local function makeSysexVal(name, str)
  --   userValues[name] = { operation = OP_ABS, opval = sysexStringToBytes(str) }
  --   return true
  -- end

  -- local function makeNotationVal(name, str)
  --   userValues[name] = { operation = OP_ABS, opval = stringToNotationString(str) }
  --   return true
  -- end

  -- local function paramCanScale(name)
  --   local canscale = false
  --   for _, v in ipairs(scaleOpWhitelist) do
  --     if name == v then
  --       canscale = true
  --       break
  --     end
  --   end
  --   return canscale
  -- end

  -- local function processString(name, str)
  --   local char = str:byte(1)
  --   local val

  --   if name == 'textmsg' then
  --     if userValues.texttype.opval == -1 then
  --       return makeSysexVal(name, str)
  --     elseif userValues.texttype.opval == 15 then
  --       return makeNotationVal(name, str)
  --     elseif popupFilter < 0x80 then
  --       return makeStringVal(name, str)
  --     end
  --   end

  --   -- special case for setting negative numbers for pitch bend
  --   if name == 'ccval' and popupFilter == 0xE0 and char == OP_SUB then
  --     if str:byte(2) == OP_SUB then -- two '--' means 'set' for negative pitch bend
  --       return makeVal(name, str:sub(2))
  --     end
  --   end

  --   if char == OP_SCL then
  --     if not paramCanScale(name) then return false end

  --     local first, second = str:sub(2):match('([-+]?%d+)[%s%-]+([-+]?%d+)')
  --     if first and second then
  --       if needsBBUConversion(name) then
  --         first = (first * 0.01) * PPQ
  --         second = (second * 0.01) * PPQ
  --       end
  --       userValues[name] = { operation = char, opval = first, opval2 = second }
  --       return true
  --     else return false
  --     end
  --   elseif char == OP_ADD or char == OP_SUB or char == OP_MUL or char == OP_DIV then
  --     if makeVal(name, str:sub(2), char) then return true end
  --   end

  --   return makeVal(name, str)
  -- end

  -- local function isTimeValue(name)
  --   if name == 'measures' or name == 'beats' or name == 'ticks' or name == 'notedur' then
  --     return true
  --   end
  --   return false
  -- end

  -- local function getCurrentRange(name)
  --   if not ranges[name] then
  --     local rangeLo = 0xFFFF
  --     local rangeHi = -0xFFFF
  --     for _, v in ipairs(selectedEvents) do
  --       local type = chanmsgToType(v.chanmsg)
  --       if type == popupFilter then
  --         if v[name] and v[name] ~= INVALID then
  --           if v[name] < rangeLo then rangeLo = v[name] end
  --           if v[name] > rangeHi then rangeHi = v[name] end
  --         end
  --       end
  --     end
  --     ranges[name] = { lo = math.floor(rangeLo), hi = math.floor(rangeHi) }
  --   end
  --   return ranges[name].lo, ranges[name].hi
  -- end

  -- local function getCurrentRangeForDisplay(name)
  --   local lo, hi = getCurrentRange(name)
  --   if needsBBUConversion(name) then
  --     lo = math.floor((lo / PPQ) * 100)
  --     hi = math.floor((hi / PPQ) * 100)
  --   end
  --   return lo, hi
  -- end

  local function generateLabel(label)
    -- local oldX, oldY = r.ImGui_GetCursorPos(ctx)
    local ix, iy = currentRect.left, currentRect.top
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFEF)
    local tw, th = r.ImGui_CalcTextSize(ctx, label)
    local fp = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()) / 2
    local minx = ix + 2
    local miny = iy - r.ImGui_GetTextLineHeight(ctx) - 3
    r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(ctx), minx - fp, miny - fp, minx + tw + fp + 2, miny + th + fp + 1, 0xFFFFFF2F)
    minx = minx - vx
    miny = miny - vy
    r.ImGui_SetCursorPos(ctx, minx + 1, miny)
    r.ImGui_Text(ctx, label)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopFont(ctx)
    --r.ImGui_SetCursorPos(ctx, oldX, oldY)
  end

  -- local function generateRangeLabel(name)

  --   if not paramCanScale(name) then return end

  --   local text
  --   local lo, hi = getCurrentRangeForDisplay(name)
  --   if lo ~= hi then
  --     text = '['..lo..'-'..hi..']'
  --   elseif name == 'pitch' then
  --     text = '<'..mu.MIDI_NoteNumberToNoteName(lo)..'>'
  --   end
  --   if text then
  --     local ix, iy = currentRect.left, currentRect.bottom
  --     r.ImGui_PushFont(ctx, fontInfo.small)
  --     r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFBF)
  --     local tw, th = r.ImGui_CalcTextSize(ctx, text)
  --     local fp = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()) / 2
  --     local minx = ix
  --     local miny = iy + 3
  --     r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(ctx), minx - fp, miny - fp, minx + tw + fp + 2, miny + th + fp + 2, 0x333355BF)
  --     minx = minx - vx
  --     miny = miny - vy
  --     r.ImGui_SetCursorPos(ctx, minx + 1, miny + 2)
  --     r.ImGui_Text(ctx, text)
  --     r.ImGui_PopStyleColor(ctx)
  --     r.ImGui_PopFont(ctx)
  --   end
  -- end

  local function kbdEntryIsCompleted(retval)
    return (retval and (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
              or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Tab())
              or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())))
            or r.ImGui_IsItemDeactivated(ctx)
  end

  -- local function makeTextInput(name, label, more, wid)
  --   local timeval = isTimeValue(name)
  --   r.ImGui_SameLine(ctx)
  --   r.ImGui_BeginGroup(ctx)
  --   local nextwid = wid and scaled(wid) or scaled(DEFAULT_ITEM_WIDTH)
  --   r.ImGui_SetNextItemWidth(ctx, nextwid)
  --   r.ImGui_SetCursorPosX(ctx, (currentRect.right - vx) + scaled(2) + (more and scaled(4) or 0))

  --   r.ImGui_PushFont(ctx, fontInfo.large)

  --   local val = userValues[name].opval
  --   if val ~= INVALID then
  --     if (name == 'chan' or name == 'beats') then val = val + 1
  --     elseif needsBBUConversion(name) then val = math.floor((val / PPQ) * 100)
  --     elseif name == 'texttype' then
  --       if textTypes[userValues[name].opval] then
  --         r.ImGui_Button(ctx, textTypes[userValues[name].opval].label, nextwid)

  --         r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  --         if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
  --           r.ImGui_OpenPopup(ctx, 'texttype menu')
  --           activeFieldName = name
  --           focusKeyboardHere = name
  --         end

  --         if r.ImGui_BeginPopup(ctx, 'texttype menu') then
  --           if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
  --             if r.ImGui_IsPopupOpen(ctx, 'texttype menu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
  --               r.ImGui_CloseCurrentPopup(ctx)
  --               handledEscape = true
  --             end
  --           end
  --           for i = 1, #textTypes do
  --             local rv, selected = r.ImGui_Selectable(ctx, textTypes[i].label)
  --             if rv and selected then
  --               val = textTypes[i].val
  --               changedParameter = name
  --               userValues[name] = { operation = OP_ABS, opval = val }
  --               canProcess = true
  --             end
  --           end
  --           r.ImGui_EndPopup(ctx)
  --         end
  --         currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
  --         currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
  --         generateLabel(label)
  --         registerItem(name, false, false)
  --         r.ImGui_PopStyleColor(ctx)
  --       end
  --       r.ImGui_PopFont(ctx)
  --       r.ImGui_EndGroup(ctx)
  --       return
  --     elseif name == 'textmsg' then
  --       if popupFilter == -1 then
  --         val = sysexBytesToString(val)
  --       elseif popupFilter == 15 then
  --         val = notationStringToString(val)
  --       end
  --     end
  --   end

  --   local str = val ~= INVALID and tostring(val) or '-'
  --   if focusKeyboardHere == name then
  --     r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x77FFFF3F)
  --     -- r.ImGui_SetKeyboardFocusHere(ctx) -- we could reactivate the input field, but it's pretty good as-is
  --   end

  --   local flags = r.ImGui_InputTextFlags_AutoSelectAll()
  --   if name == 'textmsg' then
  --     if popupFilter == -1 then
  --       flags = flags + 0 --r.ImGui_InputTextFlags_CharsHexadecimal()
  --     end
  --   else
  --     flags = flags + r.ImGui_InputTextFlags_CharsNoBlank() + r.ImGui_InputTextFlags_CharsDecimal()
  --   end
  --   local rt, nstr = r.ImGui_InputText(ctx, genItemID(name), str, flags)
  --   if rt and kbdEntryIsCompleted() then
  --     if processString(name, nstr) then
  --       if timeval then recalcEventTimes = true else canProcess = true end
  --     end
  --     changedParameter = name
  --   end

  --   if focusKeyboardHere == name then
  --     r.ImGui_PopStyleColor(ctx)
  --   end

  --   currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
  --   currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
  --   r.ImGui_PopFont(ctx)
  --   registerItem(name, timeval)
  --   generateLabel(label)
  --   generateRangeLabel(name)
  --   r.ImGui_EndGroup(ctx)

  --   if r.ImGui_IsItemActive(ctx) then activeFieldName = name focusKeyboardHere = name end
  -- end

  -- local function generateUnitsLabel(name)

  --   local ix, iy = currentRect.left, currentRect.bottom
  --   r.ImGui_PushFont(ctx, fontInfo.small)
  --   r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFBF)
  --   local text =  '(bars.beats.'..(wantsBBU and 'percent' or 'ticks')..')'
  --   local tw, th = r.ImGui_CalcTextSize(ctx, text)
  --   local fp = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()) / 2
  --   local minx = ix
  --   local miny = iy + 3
  --   r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(ctx), minx - fp, miny - fp, minx + tw + fp + 2, miny + th + fp + 2, 0x333355BF)
  --   minx = minx - vx
  --   miny = miny - vy
  --   r.ImGui_SetCursorPos(ctx, minx + 1, miny + 2)
  --   r.ImGui_Text(ctx, text)
  --   r.ImGui_PopStyleColor(ctx)
  --   r.ImGui_PopFont(ctx)
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

  -- local function makeTimeInput(name, label, more, wid)
  --   r.ImGui_SameLine(ctx)
  --   r.ImGui_BeginGroup(ctx)
  --   r.ImGui_SetNextItemWidth(ctx, wid and scaled(wid) or scaled(DEFAULT_ITEM_WIDTH))
  --   r.ImGui_SetCursorPosX(ctx, (currentRect.right - vx) + scaled(2) + (more and scaled(4) or 0))

  --   r.ImGui_PushFont(ctx, fontInfo.large)

  --   local beatsOffset = name == 'seldurticks' and 0 or 1
  --   local val = userValues[name].opval

  --   local str = '-'

  --   if val ~= INVALID then
  --     local measures, beats, ticks
  --     if name == 'seldurticks' then
  --       measures, beats, ticks = ppqToLength(userValues.selposticks.opval, userValues.seldurticks.opval)
  --     else
  --       measures, beats, _, ticks = ppqToTime(userValues[name].opval)
  --     end
  --     if wantsBBU then
  --       str = measures..'.'..(beats + beatsOffset)..'.'..string.format('%.3f', (ticks / PPQ)):sub(3, -2)
  --     else
  --       str = measures..'.'..(beats + beatsOffset)..'.'..ticks
  --     end
  --   end

  --   if focusKeyboardHere == name then
  --     r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x77FFFF3F)
  --   end

  --   local rt, nstr = r.ImGui_InputText(ctx, genItemID(name), str, r.ImGui_InputTextFlags_CharsNoBlank()
  --                                                               + r.ImGui_InputTextFlags_CharsDecimal()
  --                                                               + r.ImGui_InputTextFlags_AutoSelectAll())
  --   if rt and kbdEntryIsCompleted() then
  --     if processTimeString(name, nstr) then
  --       recalcSelectionTimes = true
  --       changedParameter = name
  --     end
  --   end

  --   if focusKeyboardHere == name then
  --     r.ImGui_PopStyleColor(ctx)
  --   end

  --   currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
  --   currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
  --   r.ImGui_PopFont(ctx)
  --   registerItem(name, false, true)
  --   generateLabel(label)
  --   generateUnitsLabel()
  --   -- generateRangeLabel(name) -- no range support
  --   r.ImGui_EndGroup(ctx)

  --   if r.ImGui_IsItemActive(ctx) then activeFieldName = name focusKeyboardHere = name end
  -- end

  ---------------------------------------------------------------------------
  ----------------------------- PROCESSING FUNS -----------------------------

  -- local cachedSelPosTicks = nil
  -- local cachedSelDurTicks = nil

  -- local function performTimeSelectionOperation(name, e)
  --   local rv = true
  --   if changedParameter == 'seldurticks' then
  --     local newdur = cachedSelDurTicks
  --     if not newdur then
  --       local event = { seldurticks = union.seldurticks }
  --       rv, newdur = performOperation('seldurticks', event)
  --       if rv and newdur < 1 then newdur = 1 end
  --       cachedSelDurTicks = newdur
  --     end
  --     if rv then
  --       local inlo, inhi = union.selposticks, union.selendticks
  --       local outlo, outhi = union.selposticks, union.selposticks + newdur
  --       local oldppq = name == 'endppqpos' and e.endppqpos or e.ppqpos
  --       local newppq = math.floor(((oldppq - inlo) / (inhi - inlo)) * (outhi - outlo) + outlo)
  --       return true, newppq
  --     end
  --   elseif changedParameter == 'selposticks' then
  --     local newpos = cachedSelPosTicks
  --     if not newpos then
  --       local event = { selposticks = union.selposticks }
  --       rv, newpos = performOperation('selposticks', event)
  --       cachedSelPosTicks = newpos
  --     end
  --     if rv then
  --       local oldppq = name == 'endppqpos' and e.endppqpos or e.ppqpos
  --       local newppq = oldppq + (newpos - union.selposticks)
  --       return true, newppq
  --     end
  --   end
  --   return false, INVALID
  -- end

  -- function doPerformOperation(name, baseval, op, opval, opval2)
  --   local plusone = 0
  --   if (op == OP_MUL or op == OP_DIV) and (name == 'chan' or name == 'beats') then
  --     plusone = 1
  --   end
  --   if op == OP_ABS then
  --     if opval ~= INVALID then return true, opval
  --     else return true, baseval end
  --   elseif op == OP_ADD then
  --     return true, baseval + opval
  --   elseif op == OP_SUB then
  --     return true, baseval - opval
  --   elseif op == OP_MUL then
  --     return true, ((baseval + plusone) * opval) - plusone
  --   elseif op == OP_DIV then
  --     return true, ((baseval + plusone) / opval) - plusone
  --   elseif op == OP_SCL and name and opval2 then
  --     local inlo, inhi = getCurrentRange(name)
  --     local outlo, outhi = opval, opval2
  --     local inrange = inhi - inlo
  --     if inrange ~= 0 then
  --       local valnorm = (baseval - inlo) / (inhi - inlo)
  --       local valscaled = (valnorm * (opval2 - opval)) + opval
  --       return true, valscaled
  --     else return false, INVALID
  --     end
  --   end
  --   return false, INVALID
  -- end

  -- function performOperation(name, e, valname)
  --   if name == 'ppqpos' or name == 'endppqpos' then return performTimeSelectionOperation(name, e) end

  --   local op = userValues[name]
  --   if op then
  --     return doPerformOperation(name, e[valname and valname or name], op.operation, op.opval, op.opval2)
  --   end
  --   return false, INVALID
  -- end

  -- local function getEventValue(name, e, valname)
  --   local rv, val = performOperation(name, e, valname)
  --   if rv then
  --     if name == 'chan' then val = val < 0 and 0 or val > 15 and 15 or val
  --     elseif name == 'measures' or name == 'beats' or name == 'ticks' then val = val
  --     elseif name == 'vel' then val = val < 1 and 1 or val > 127 and 127 or val
  --     elseif name == 'pitch' or name == 'ccnum' then val = val < 0 and 0 or val > 127 and 127 or val
  --     elseif name == 'ccval' then
  --       if e.chanmsg == 0xE0 then val = val < -(1<<13) and -(1<<13) or val > ((1<<13) - 1) and ((1<<13) - 1) or val
  --       else val = val < 0 and 0 or val > 127 and 127 or val
  --       end
  --     elseif name == 'ppqpos' or name == 'endppqpos' then val = val
  --     elseif name == 'texttype' then
  --       if e.chanmsg == 1 then
  --         return (val < 1 and 1 or val > #textTypes and #textTypes or val)
  --       end
  --       return val
  --     elseif name == 'textmsg' then return val
  --     else val = val < 0 and 0 or val
  --     end

  --     if name == 'pitch' and changedParameter == 'pitch' then
  --       local dir = val < e.pitch and -1 or val > e.pitch and 1 or 0
  --       if pitchDirection == 0 and val ~= 0 then pitchDirection = dir end
  --     end

  --     return math.floor(val)
  --   end
  --   return INVALID
  -- end

  -- local function updateValuesForEvent(e)
  --   if chanmsgToType(e.chanmsg) ~= popupFilter then return {} end

  --   e.measures = getEventValue('measures', e)
  --   e.beats = getEventValue('beats', e)
  --   e.ticks = getEventValue('ticks', e)
  --   if popupFilter == NOTE_FILTER then
  --     e.chan = getEventValue('chan', e)
  --     e.pitch = getEventValue('pitch', e)
  --     e.vel = getEventValue('vel', e)
  --     e.notedur = getEventValue('notedur', e)
  --   elseif popupFilter >= 0x80 then
  --     e.chan = getEventValue('chan', e)
  --     e.ccnum = getEventValue('ccnum', e)
  --     e.ccval = getEventValue('ccval', e)
  --     if e.chanmsg == 0xA0 then
  --       e.msg2 = e.ccval
  --       e.msg3 = 0
  --     elseif e.chanmsg == 0xE0 then
  --       e.ccval = e.ccval + (1<<13)
  --       if e.ccval > ((1<<14) - 1) then e.ccval = ((1<<14) - 1) end
  --       e.msg2 = e.ccval & 0x7F
  --       e.msg3 = (e.ccval >> 7) & 0x7F
  --     else
  --       e.msg2 = e.ccnum
  --       e.msg3 = e.ccval
  --     end
  --   else
  --     e.chanmsg = getEventValue('texttype', e, 'chanmsg')
  --     e.textmsg = getEventValue('textmsg', e)
  --   end
  --   if recalcEventTimes then
  --     e.ppqpos = BBTToPPQ(e.measures, e.beats, e.ticks)
  --     if popupFilter == NOTE_FILTER then
  --       e.endppqpos = e.ppqpos + e.notedur
  --     end
  --   end
  --   if recalcSelectionTimes then
  --     e.ppqpos = getEventValue('ppqpos', e)
  --     if popupFilter == NOTE_FILTER then
  --       e.endppqpos = getEventValue('endppqpos', e)
  --       e.notedur = e.endppqpos - e.ppqpos
  --     end
  --   end
  -- end

  -- -- item extents management, currently disabled
  -- local function getItemExtents(item)
  --   local item_pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
  --   local item_len = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
  --   local extents = {}
  --   extents.item = item
  --   extents.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, item_pos)
  --   extents.ppqpos_cache = extents.ppqpos
  --   extents.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, item_pos + item_len)
  --   extents.endppqpos_cache = extents.endppqpos
  --   extents.ppqpos_changed = false
  --   extents.endppqpos_changed = false
  --   return extents
  -- end

  -- local function correctItemExtents(extents, v)
  --   if v.ppqpos < extents.ppqpos then
  --     extents.ppqpos = v.ppqpos
  --     extents.ppqpos_changed = true
  --   end
  --   if v.type == NOTE_TYPE and v.endppqpos > extents.endppqpos then
  --     extents.endppqpos = v.endppqpos
  --     extents.endppqpos_changed = true
  --   end
  -- end

  -- local function updateItemExtents(extents)
  --   if extents.ppqpos_changed or extents.endppqpos_changed then
  --     -- to nearest beat
  --     local extentStart = r.MIDI_GetProjQNFromPPQPos(take, extents.ppqpos)
  --     if extents.ppqpos_changed then
  --       extentStart = math.floor(extentStart) -- extent to previous beat
  --       extents.ppqpos = r.MIDI_GetPPQPosFromProjQN(take, extentStart) -- write it back, we need it below
  --     end
  --     local extentEnd = r.MIDI_GetProjQNFromPPQPos(take, extents.endppqpos)
  --     if extents.endppqpos_changed then
  --       extentEnd = math.floor(extentEnd + 1) -- extend to next beat
  --       extents.endppqpos = r.MIDI_GetPPQPosFromProjQN(take, extentEnd) -- write it back, we need it below
  --     end
  --     r.MIDI_SetItemExtents(extents.item, extentStart, extentEnd)
  --   end
  -- end

  ---------------------------------------------------------------------------
  ----------------------------------- ENDFN ---------------------------------

  ---------------------------------------------------------------------------
  ---------------------------------------------------------------------------

  ---------------------------------------------------------------------------
  ----------------------------------- SETUP ---------------------------------

  -- PPQ = getPPQ()
  --handleExtState()


  -- if #selectedEvents == 0 or not (selnotecnt > 0 or selcccnt > 0 or selsyxcnt > 0) then
  --   titleBarText = DEFAULT_TITLEBAR_TEXT..': No selection' -- (PPQ='..PPQ..')' -- does PPQ make sense here?
  --   return
  -- end

  ---------------------------------------------------------------------------
  ------------------------------ TITLEBAR TEXT ------------------------------

  titleBarText = DEFAULT_TITLEBAR_TEXT

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

  ---------------------------------------------------------------------------
  ------------------------------- PRESET RECALL -----------------------------

  r.ImGui_Spacing(ctx)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Button(ctx, 'Recall Preset...', scaled(DEFAULT_ITEM_WIDTH) * 1.5)
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    presetTable = enumerateTransformerPresets()
    if #presetTable ~= 0 then
      r.ImGui_OpenPopup(ctx, 'openPresetMenu') -- defined far below
    end
  end

  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, 0x00AAFFFF, presetLabel)

  ---------------------------------------------------------------------------
  --------------------------------- FIND ROWS -------------------------------

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x006655FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x008877FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x007766FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x006655FF)

  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_SetNextItemWidth(ctx, scaled(DEFAULT_ITEM_WIDTH))

  r.ImGui_Button(ctx, 'Insert Criteria', scaled(DEFAULT_ITEM_WIDTH) * 1.5)
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    addFindRow()
  end

  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, scaled(DEFAULT_ITEM_WIDTH))
  if selectedFindRow == 0 then
    r.ImGui_BeginDisabled(ctx)
  end
  r.ImGui_Button(ctx, 'Remove Criteria', scaled(DEFAULT_ITEM_WIDTH) * 1.5)
  if selectedFindRow == 0 then
    r.ImGui_EndDisabled(ctx)
  end

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    removeFindRow()
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

  local numbersOnlyCallback = r.ImGui_CreateFunctionFromEEL([[
    (EventChar < '0' || EventChar > '9') && EventChar != '-' ? EventChar = 0;
  ]])

  local function handleTableParam(row, condOp, paramName, paramTab, paramType, needsTerms, idx, procFn)
    local rv = 0
    if paramType == PARAM_TYPE_METRICGRID and needsTerms == 1 then paramType = PARAM_TYPE_MENU end -- special case, sorry
    if condOp.terms >= needsTerms then
        local targetTab = row:is_a(FindRow) and findTargetEntries or actionTargetEntries
        local target = targetTab[row.targetEntry]
        if paramType == PARAM_TYPE_MENU then
        r.ImGui_Button(ctx, #paramTab ~= 0 and paramTab[row[paramName .. 'Entry']].label or '---')
        if (#paramTab ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
          rv = idx
          r.ImGui_OpenPopup(ctx, paramName .. 'Menu')
        end
      elseif paramType == PARAM_TYPE_TEXTEDITOR or paramType == PARAM_TYPE_METRICGRID then -- for now
        r.ImGui_BeginGroup(ctx)
        local retval, buf = r.ImGui_InputText(ctx, '##' .. paramName .. 'edit', row[paramName .. 'TextEditorStr'], r.ImGui_InputTextFlags_CallbackCharFilter(), numbersOnlyCallback)
        if kbdEntryIsCompleted(retval) then
          row[paramName .. 'TextEditorStr'] = paramType == PARAM_TYPE_METRICGRID and buf or ensureNumString(buf, condOp.range and condOp.range or target.range)
          procFn()
        end
        r.ImGui_EndGroup(ctx)
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
          rv = idx
        end
      elseif paramType == PARAM_TYPE_TIME or paramType == PARAM_TYPE_TIMEDUR then
        -- time format depends on PPQ column value
        r.ImGui_BeginGroup(ctx)
        local retval, buf = r.ImGui_InputText(ctx, '##' .. paramName .. 'edit', row[paramName .. 'TimeFormatStr'], r.ImGui_InputTextFlags_CharsDecimal() + r.ImGui_InputTextFlags_CharsNoBlank())
        if kbdEntryIsCompleted(retval) then
          row[paramName .. 'TimeFormatStr'] = paramType == PARAM_TYPE_TIMEDUR and lengthFormatRebuf(buf) or timeFormatRebuf(buf)
          procFn()
        end
        r.ImGui_EndGroup(ctx)
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
          rv = idx
        end
      end
    end
    return rv
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
      addFindRow(nil, row)
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

  r.ImGui_SameLine(ctx)
  local fcrv, fcbuf = r.ImGui_InputText(ctx, '##findConsole', findConsoleText)
  if kbdEntryIsCompleted(fcrv) then
    findConsoleText = fcbuf
    processFindMacro(findConsoleText)
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE GEN ------------------------------

  -- requires userValues, above

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

  local function createPopup(name, source, selEntry, fun, special)
    if r.ImGui_BeginPopup(ctx, name) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        if r.ImGui_IsPopupOpen(ctx, name, r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
          r.ImGui_CloseCurrentPopup(ctx)
          handledEscape = true
        end
      end

      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x00000000)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), 0x00000000)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), 0x00000000)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

      local mousePos = {}
      mousePos.x, mousePos.y = r.ImGui_GetMousePos(ctx)
      local windowRect = {}
      windowRect.left, windowRect.top = r.ImGui_GetWindowPos(ctx)
      windowRect.right, windowRect.bottom = r.ImGui_GetWindowSize(ctx)
      windowRect.right = windowRect.right + windowRect.left
      windowRect.bottom = windowRect.bottom + windowRect.top

      for i = 1, #source do
        local selectText = source[i].label
        if source.targetTable then
          selectText = decorateTargetLabel(selectText)
        end
        local factoryFn = selEntry == -1 and r.ImGui_Selectable or r.ImGui_Checkbox
        local oldX = r.ImGui_GetCursorPosX(ctx)
        r.ImGui_BeginGroup(ctx)
        local rv, selected = factoryFn(ctx, selectText, selEntry == i and true or false)
        r.ImGui_SameLine(ctx)
        r.ImGui_SetCursorPosX(ctx, oldX) -- ugly, but the selectable needs info from the checkbox
        local rect = {}
        local _, itemTop = r.ImGui_GetItemRectMin(ctx)
        local _, itemBottom = r.ImGui_GetItemRectMax(ctx)
        local inVert = mousePos.y >= itemTop + framePaddingY and mousePos.y <= itemBottom - framePaddingY and mousePos.x >= windowRect.left and mousePos.x <= windowRect.right
        local srv = r.ImGui_Selectable(ctx, '##popup' .. i .. 'Selectable', inVert, r.ImGui_SelectableFlags_AllowItemOverlap())
        r.ImGui_EndGroup(ctx)

        if rv or srv then
          if selected or srv then fun(i) end
          r.ImGui_CloseCurrentPopup(ctx)
        end
      end

      r.ImGui_PopStyleColor(ctx, 5)

      if special then special(fun) end
      r.ImGui_EndPopup(ctx)
    end
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

    -- local param1Val = condOp.terms <= 0 and ''
    --   or paramType == PARAM_TYPE_TEXTEDITOR and row.param1TextEditorStr
    --   or paramType == PARAM_TYPE_TIME and (notation and row.param1TimeFormatStr or tostring(timeFormatToSeconds(row.param1TimeFormatStr)))
    --   or paramType == PARAM_TYPE_TIMEDUR and (notation and row.param1TimeFormatStr or tostring(lengthFormatToSeconds(row.param1TimeFormatStr)))
    --   or #param1Tab ~= 0 and (notation and param1Tab[row.param1Entry].notation or param1Tab[row.param1Entry].text)
    --   or ''
    -- local param2Val = condOp.terms <= 1 and ''
    --   or paramType == PARAM_TYPE_TEXTEDITOR and row.param2TextEditorStr
    --   or paramType == PARAM_TYPE_TIME and tostring(timeFormatToSeconds(row.param2TimeFormatStr))
    --   or paramType == PARAM_TYPE_TIMEDUR and tostring(lengthFormatToSeconds(row.param2TimeFormatStr))
    --   or #param2Tab ~= 0 and param2Tab[row.param2Entry].text
    --   or ''
    return param1Val, param2Val
  end

  ---------------------------------------------------------------------------
  -------------------------------- FIND UTILS -------------------------------

  local function doPrepFindEntries(row)
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

      local condTab, param1Tab, param2Tab, curTarget, curCondition = doPrepFindEntries(v)
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
      local condTab, param1Tab, param2Tab, curTarget, curCondition = doPrepFindEntries(v)

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

  ----------------------------------------------
  ---------- SELECTION CRITERIA TABLE ----------
  ----------------------------------------------

  r.ImGui_BeginTable(ctx, 'Selection Criteria', #findColumns, r.ImGui_TableFlags_ScrollY() + r.ImGui_TableFlags_BordersInnerH(), 0, r.ImGui_GetFrameHeightWithSpacing(ctx) * 6.2)

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
  for _, label in ipairs(findColumns) do
    local narrow = (label == '(' or label == ')' or label == 'Boolean')
    local flags = narrow and r.ImGui_TableColumnFlags_WidthFixed() or r.ImGui_TableColumnFlags_None()
    local colwid = narrow and (label == 'Boolean' and scaled(70) or scaled(PAREN_COLUMN_WIDTH)) or nil
    r.ImGui_TableSetupColumn(ctx, label, flags, colwid)
  end
  r.ImGui_TableHeadersRow(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)

  for k, v in ipairs(findRowTable) do
    if findTargetEntries[v.targetEntry].notation == '$type' then
      local label = GetSubtypeValueLabel(v.param1Entry)
      if not subtypeValueLabel or subtypeValueLabel == label then subtypeValueLabel = label
      else subtypeValueLabel = 'Multiple'
      end
      label = GetMainValueLabel(v.param1Entry)
      if not mainValueLabel or mainValueLabel == label then mainValueLabel = label
      else mainValueLabel = 'Multiple'
      end
    end
  end

  if not subtypeValueLabel then subtypeValueLabel = GetSubtypeValueLabel(1) end
  if not mainValueLabel then mainValueLabel = GetMainValueLabel(1) end

  for k, v in ipairs(findRowTable) do
    r.ImGui_PushID(ctx, tostring(k))
    local currentRow = v
    local currentFindTarget = {}
    local currentFindCondition = {}
    local conditionEntries = {}
    local param1Entries = {}
    local param2Entries = {}

    local function prepFindEntries()
      conditionEntries, param1Entries, param2Entries, currentFindTarget, currentFindCondition = doPrepFindEntries(currentRow)
    end

    prepFindEntries()

    r.ImGui_TableNextRow(ctx)

    if k == selectedFindRow then
      r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg0(), 0x77FFFF1F)
    end

    r.ImGui_TableSetColumnIndex(ctx, 0) -- '('
    if currentRow.startParenEntry < 2 then
      r.ImGui_InvisibleButton(ctx, '##startParen', scaled(PAREN_COLUMN_WIDTH), r.ImGui_GetFrameHeight(ctx)) -- or we can't test hover/click properly
    else
      r.ImGui_Button(ctx, startParenEntries[currentRow.startParenEntry].label)
    end
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      r.ImGui_OpenPopup(ctx, 'startParenMenu')
      selectedFindRow = k
    end

    r.ImGui_TableSetColumnIndex(ctx, 1) -- 'Target'
    local targetText = currentRow.targetEntry > 0 and currentFindTarget.label or '---'
    r.ImGui_Button(ctx, decorateTargetLabel(targetText))
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedFindRow = k
      r.ImGui_OpenPopup(ctx, 'targetMenu')
    end

    r.ImGui_TableSetColumnIndex(ctx, 2) -- 'Condition'
    r.ImGui_Button(ctx, #conditionEntries ~= 0 and currentFindCondition.label or '---')
    if (#conditionEntries ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedFindRow = k
      r.ImGui_OpenPopup(ctx, 'conditionMenu')
    end

    local paramType = getEditorTypeForRow(currentFindTarget, currentFindCondition)
    local selected

    r.ImGui_TableSetColumnIndex(ctx, 3) -- 'Parameter 1'
    selected = handleTableParam(currentRow, currentFindCondition, 'param1', param1Entries, paramType, 1, k, processFind)
    if selected and selected > 0 then selectedFindRow = selected end

    r.ImGui_TableSetColumnIndex(ctx, 4) -- 'Parameter 2'
    selected = handleTableParam(currentRow, currentFindCondition, 'param2', param2Entries, paramType, 2, k, processFind)
    if selected and selected > 0 then selectedFindRow = selected end

    r.ImGui_TableSetColumnIndex(ctx, 5) -- Time format
    if (currentFindTarget.time or currentFindTarget.timedur) and currentFindCondition.terms ~= 0 then
      r.ImGui_Button(ctx, findTimeFormatEntries[currentRow.timeFormatEntry].label or '---')
      if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
        selectedFindRow = k
        r.ImGui_OpenPopup(ctx, 'timeFormatMenu')
      end
    end

    r.ImGui_TableSetColumnIndex(ctx, 6) -- End Paren
    if currentRow.endParenEntry < 2 then
      r.ImGui_InvisibleButton(ctx, '##endParen', scaled(PAREN_COLUMN_WIDTH), r.ImGui_GetFrameHeight(ctx)) -- or we can't test hover/click properly
    else
      r.ImGui_Button(ctx, endParenEntries[currentRow.endParenEntry].label)
    end
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      r.ImGui_OpenPopup(ctx, 'endParenMenu')
      selectedFindRow = k
    end

    r.ImGui_TableSetColumnIndex(ctx, 7) -- Boolean
    if k ~= #findRowTable then
      r.ImGui_Button(ctx, findBooleanEntries[currentRow.booleanEntry].label or '---', 50)
      if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
        currentRow.booleanEntry = currentRow.booleanEntry == 1 and 2 or 1
        selectedFindRow = k
        processFind()
      end
    end

    r.ImGui_SameLine(ctx)

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
    if r.ImGui_Selectable(ctx, '##rowGroup', false, r.ImGui_SelectableFlags_SpanAllColumns() | r.ImGui_SelectableFlags_AllowItemOverlap()) then
      selectedFindRow = k
    end
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopStyleColor(ctx)

    createPopup('startParenMenu', startParenEntries, currentRow.startParenEntry, function(i)
        currentRow.startParenEntry = i
        processFind()
      end)

    createPopup('endParenMenu', endParenEntries, currentRow.endParenEntry, function(i)
        currentRow.endParenEntry = i
        processFind()
      end)

    createPopup('targetMenu', findTargetEntries, currentRow.targetEntry, function(i)
        currentRow:init()
        currentRow.targetEntry = i
        if findTargetEntries[currentRow.targetEntry].notation == '$length' then
          currentRow.param1TimeFormatStr = DEFAULT_LENGTHFORMAT_STRING
          currentRow.param2TimeFormatStr = DEFAULT_LENGTHFORMAT_STRING
        end
        processFind()
      end)

    createPopup('conditionMenu', conditionEntries, currentRow.conditionEntry, function(i)
        currentRow.conditionEntry = i
        if string.match(conditionEntries[i].notation, 'metricgrid') then
          currentRow.param1Entry = metricLastUnit
          currentRow.mg = {
            wantsBarRestart = metricLastBarRestart,
            preSlopPercent = 0,
            postSlopPercent = 0,
            modifiers = 0
          }
        end
        processFind()
      end)

    local function metricParam1Special(fun)
      r.ImGui_Separator(ctx)

      local mg = currentRow.mg

      local rv, sel = r.ImGui_Checkbox(ctx, 'Dotted', mg.modifiers & 1 ~= 0)
      if rv then
        mg.modifiers = sel and 1 or 0
        fun(1, true)
      end

      rv, sel = r.ImGui_Checkbox(ctx, 'Triplet', mg.modifiers & 2 ~= 0)
      if rv then
        mg.modifiers = sel and 2 or 0
        fun(2, true)
      end

      r.ImGui_Separator(ctx)

      rv, sel = r.ImGui_Checkbox(ctx, 'Restart pattern at next bar', mg.wantsBarRestart)
      if rv then
        mg.wantsBarRestart = sel
        fun(3, true)
      end
      r.ImGui_Text(ctx, 'Slop (% of unit)')
      r.ImGui_SameLine(ctx)
      local tbuf
      rv, tbuf = r.ImGui_InputDouble(ctx, '##slopPreInput', mg.preSlopPercent) -- TODO: regular text input (allow float)
      if kbdEntryIsCompleted(rv) then
        mg.preSlopPercent = tbuf
        fun(4, true)
      end
      r.ImGui_SameLine(ctx)
      rv, tbuf = r.ImGui_InputDouble(ctx, '##slopPostInput', mg.postSlopPercent) -- TODO: regular text input (allow float)
      if kbdEntryIsCompleted(rv) then
        mg.postSlopPercent = tbuf
        fun(5, true)
      end
    end

    createPopup('param1Menu', param1Entries, currentRow.param1Entry, function(i, isSpecial)
        if not isSpecial then
          currentRow.param1Entry = i
          currentRow.param1Val = param1Entries[i]
          if string.match(conditionEntries[currentRow.conditionEntry].notation, 'metricgrid') then
            metricLastUnit = i
          end
        end
        processFind()
      end,
      paramType == PARAM_TYPE_METRICGRID and metricParam1Special or nil)

    createPopup('param2Menu', param2Entries, currentRow.param2Entry, function(i)
        currentRow.param2Entry = i
        currentRow.param2Val = param2Entries[i]
        processFind()
      end)

    createPopup('timeFormatMenu', findTimeFormatEntries, currentRow.timeFormatEntry, function(i)
        currentRow.timeFormatEntry = i
        processFind()
      end)

    r.ImGui_PopID(ctx)
  end

  r.ImGui_EndTable(ctx)

  updateCurrentRect()

  local oldY = r.ImGui_GetCursorPosY(ctx)

  generateLabel('Selection Criteria')

  r.ImGui_SetCursorPosY(ctx, oldY + scaled(20))

  ---------------------------------------------------------------------------
  ------------------------------- FIND BUTTONS ------------------------------

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  r.ImGui_AlignTextToFramePadding(ctx)

  r.ImGui_Button(ctx, findScopeTable[currentFindScope].label, scaled(150))
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'findScopeMenu')
  end

  r.ImGui_SameLine(ctx)
  local oldX, oldY = r.ImGui_GetCursorPos(ctx)

  updateCurrentRect()
  generateLabel('Selection Scope')

  r.ImGui_SetCursorPos(ctx, oldX + 20, oldY)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, findParserError)

  r.ImGui_SameLine(ctx)

  createPopup('findScopeMenu', findScopeTable, currentFindScope, function(i)
      currentFindScope = i
    end)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)

  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)

  ---------------------------------------------------------------------------
  -------------------------------- ACTION ROWS ------------------------------

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x550077FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x770099FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x660088FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x440066FF)

  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_SetNextItemWidth(ctx, scaled(DEFAULT_ITEM_WIDTH))
  r.ImGui_Button(ctx, 'Insert Action', scaled(DEFAULT_ITEM_WIDTH) * 1.5)

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    addActionRow()
  end

  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, scaled(DEFAULT_ITEM_WIDTH))
  if selectedActionRow == 0 then
    r.ImGui_BeginDisabled(ctx)
  end
  r.ImGui_Button(ctx, 'Remove Action', scaled(DEFAULT_ITEM_WIDTH) * 1.5)
  if selectedActionRow == 0 then
    r.ImGui_EndDisabled(ctx)
  end

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    removeActionRow()
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
        opTab = actionGenericOperationEntries
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
      addActionRow(nil, row)
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

  r.ImGui_SameLine(ctx)
  local acrv, acbuf = r.ImGui_InputText(ctx, '##actionConsole', actionConsoleText)
  if kbdEntryIsCompleted(acrv) then
    actionConsoleText = acbuf
    processActionMacro(actionConsoleText)
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  ----------------------------------------------
  ---------------- ACTIONS TABLE ---------------
  ----------------------------------------------

  local function doPrepActionEntries(row)
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
      local opTab, param1Tab, param2Tab, curTarget, curOperation = doPrepActionEntries(v)
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

  local function processAction(select)
    local take = getNextTake()
    if not take then return end

    CACHED_METRIC = nil
    CACHED_WRAPPED = nil
    SOM = nil

    local fnString = ''

    for k, v in ipairs(actionRowTable) do
      local opTab, param1Tab, param2Tab, curTarget, curOperation = doPrepActionEntries(v)

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
          if notation == '$delete' then
            mu.MIDI_OpenWriteTransaction(take)
            for _, entry in ipairs(allEvents) do
              if findFn(entry) then
                if entry.type == NOTE_TYPE then
                  mu.MIDI_DeleteNote(take, entry.idx)
                elseif entry.type == CC_TYPE then
                  mu.MIDI_DeleteCC(take, entry.idx)
                elseif entry.type == SYXTEXT_TYPE then
                  mu.MIDI_DeleteTextSysexEvt(take, entry.idx)
                end
              end
            end
            mu.MIDI_CommitWriteTransaction(take, false, true)
          elseif notation == '$transform' then
            local found = {}
            local firstTime = 0xFFFFFFFF
            local lastTime = -0xFFFFFFFF
            for _, entry in ipairs(allEvents) do
              if findFn(entry) then
                if entry.projtime < firstTime then firstTime = entry.projtime end
                if entry.projtime > lastTime then lastTime = entry.projtime end
                table.insert(found, entry)
              end
            end
            if #found ~=0 then
              mu.MIDI_OpenWriteTransaction(take)
              for _, entry in ipairs(found) do
                actionFn(entry, GetSubtypeValueName(entry), GetMainValueName(entry), firstTime, lastTime)
                entry.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, entry.projtime)
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
          elseif notation == '$insert' then
          elseif notation == '$insertexclusive' then
          elseif notation == '$copy' then
          elseif notation == '$select' then
            mu.MIDI_OpenWriteTransaction(take)
            for _, entry in ipairs(allEvents) do
              entry.selected = findFn(entry)
              if entry.type == NOTE_TYPE then
                mu.MIDI_SetNote(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil, nil)
              elseif entry.type == CC_TYPE then
                mu.MIDI_SetCC(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil)
              elseif entry.type == SYXTEXT_TYPE then
                mu.MIDI_SetTextSysexEvt(take, entry.idx, entry.selected, nil, nil, nil, nil)
              end
            end
            mu.MIDI_CommitWriteTransaction(take, false, true)
          elseif notation == '$selectadd' then
            mu.MIDI_OpenWriteTransaction(take)
            for _, entry in ipairs(allEvents) do
              local matching = findFn(entry)
              if matching then
                entry.selected = true
                if entry.type == NOTE_TYPE then
                  mu.MIDI_SetNote(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil, nil)
                elseif entry.type == CC_TYPE then
                  mu.MIDI_SetCC(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil)
                elseif entry.type == SYXTEXT_TYPE then
                  mu.MIDI_SetTextSysexEvt(take, entry.idx, entry.selected, nil, nil, nil, nil)
                end
              end
            end
            mu.MIDI_CommitWriteTransaction(take, false, true)
          elseif notation == '$invertselect' then
            mu.MIDI_OpenWriteTransaction(take)
            for _, entry in ipairs(allEvents) do
              entry.selected = (findFn(entry) == false) and true or false
              if entry.type == NOTE_TYPE then
                mu.MIDI_SetNote(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil, nil)
              elseif entry.type == CC_TYPE then
                mu.MIDI_SetCC(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil)
              elseif entry.type == SYXTEXT_TYPE then
                mu.MIDI_SetTextSysexEvt(take, entry.idx, entry.selected, nil, nil, nil, nil)
              end
            end
            mu.MIDI_CommitWriteTransaction(take, false, true)
          elseif notation == '$deselect' then
            mu.MIDI_OpenWriteTransaction(take)
            for _, entry in ipairs(allEvents) do
              local matching = findFn(entry)
              if matching then
                entry.selected = false
                if entry.type == NOTE_TYPE then
                  mu.MIDI_SetNote(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil, nil)
                elseif entry.type == CC_TYPE then
                  mu.MIDI_SetCC(take, entry.idx, entry.selected, nil, nil, nil, nil, nil, nil)
                elseif entry.type == SYXTEXT_TYPE then
                  mu.MIDI_SetTextSysexEvt(take, entry.idx, entry.selected, nil, nil, nil, nil)
                end
              end
            end
            mu.MIDI_CommitWriteTransaction(take, false, true)
          elseif notation == '$extracttrack' then
          elseif notation == '$extractlane' then
          end
        end
        take = getNextTake()
      end
    end

    r.Undo_EndBlock2(0, 'Transformer: ' .. actionScopeTable[currentActionScope].label, -1)
  end

  r.ImGui_BeginTable(ctx, 'Actions', #actionColumns, r.ImGui_TableFlags_ScrollY() + r.ImGui_TableFlags_BordersInnerH(), 0, r.ImGui_GetFrameHeightWithSpacing(ctx) * 6.2)

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
  for _, label in ipairs(actionColumns) do
    local flags = r.ImGui_TableColumnFlags_None()
    r.ImGui_TableSetupColumn(ctx, label, flags)
  end
  r.ImGui_TableHeadersRow(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)

  for k, v in ipairs(actionRowTable) do
    r.ImGui_PushID(ctx, tostring(k))
    local currentRow = v
    local currentActionTarget = {}
    local currentActionOperation = {}
    local operationEntries = {}
    local param1Entries = {}
    local param2Entries = {}

    local function prepActionEntries()
      operationEntries, param1Entries, param2Entries, currentActionTarget, currentActionOperation = doPrepActionEntries(currentRow)
    end

    prepActionEntries()

    r.ImGui_TableNextRow(ctx)

    if k == selectedActionRow then
      r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg0(), 0xFF77FF1F)
    end

    r.ImGui_TableSetColumnIndex(ctx, 0) -- 'Target'
    local targetText = currentRow.targetEntry > 0 and currentActionTarget.label or '---'
    r.ImGui_Button(ctx, decorateTargetLabel(targetText))
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedActionRow = k
      r.ImGui_OpenPopup(ctx, 'targetMenu')
    end

    r.ImGui_TableSetColumnIndex(ctx, 1) -- 'Operation'
    r.ImGui_Button(ctx, #operationEntries ~= 0 and currentActionOperation.label or '---')
    if (#operationEntries ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedActionRow = k
      r.ImGui_OpenPopup(ctx, 'operationMenu')
    end

    local paramType = getEditorTypeForRow(currentActionTarget, currentActionOperation)
    local selected

    r.ImGui_TableSetColumnIndex(ctx, 2) -- 'Parameter 1'
    selected = handleTableParam(currentRow, currentActionOperation, 'param1', param1Entries, paramType, 1, k, processAction)
    if selected and selected > 0 then selectedActionRow = selected end

    r.ImGui_TableSetColumnIndex(ctx, 3) -- 'Parameter 2'
    selected = handleTableParam(currentRow, currentActionOperation, 'param2', param2Entries, paramType, 2, k, processAction)
    if selected and selected > 0 then selectedActionRow = selected end

    r.ImGui_SameLine(ctx)

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
    if r.ImGui_Selectable(ctx, '##rowGroup', false, r.ImGui_SelectableFlags_SpanAllColumns() | r.ImGui_SelectableFlags_AllowItemOverlap()) then
      selectedActionRow = k
    end
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopStyleColor(ctx)

    createPopup('targetMenu', actionTargetEntries, currentRow.targetEntry, function(i)
        currentRow:init()
        currentRow.targetEntry = i
        if actionTargetEntries[currentRow.targetEntry].notation == '$length' then
          currentRow.param1TimeFormatStr = DEFAULT_LENGTHFORMAT_STRING
          currentRow.param2TimeFormatStr = DEFAULT_LENGTHFORMAT_STRING
        end
        processAction()
      end)

    createPopup('operationMenu', operationEntries, currentRow.operationEntry, function(i)
        currentRow.operationEntry = i
        processAction()
      end)

    createPopup('param1Menu', param1Entries, currentRow.param1Entry, function(i)
        currentRow.param1Entry = i
        currentRow.param1Val = param1Entries[i]
        processAction()
      end)

    createPopup('param2Menu', param2Entries, currentRow.param2Entry, function(i)
        currentRow.param2Entry = i
        currentRow.param2Val = param2Entries[i]
        processAction()
      end)

    r.ImGui_PopID(ctx)
  end

  r.ImGui_EndTable(ctx)

  updateCurrentRect();

  local oldY = r.ImGui_GetCursorPosY(ctx)

  generateLabel('Actions')

  r.ImGui_SetCursorPosY(ctx, oldY + scaled(20))

  ---------------------------------------------------------------------------
  ------------------------------ ACTION BUTTONS -----------------------------

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  r.ImGui_AlignTextToFramePadding(ctx)

  r.ImGui_Button(ctx, 'Apply')
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    processAction(true)
  end

  r.ImGui_SameLine(ctx)

  r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + scaled(50))
  r.ImGui_Button(ctx, actionScopeTable[currentActionScope].label, scaled(120))
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'actionScopeMenu')
  end
  updateCurrentRect()
  generateLabel('Action Scope')

  createPopup('actionScopeMenu', actionScopeTable, currentActionScope, function(i)
      currentActionScope = i
    end)

  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)

  r.ImGui_NewLine(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Button(ctx, 'Save Preset...')
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) or refocusInput then
    presetInputVisible = true
    refocusInput = false
    r.ImGui_SetKeyboardFocusHere(ctx)
  end

  local function positionModalWindow(yOff)
    local winWid = 4 * DEFAULT_ITEM_WIDTH * canvasScale
    local winHgt = FONTSIZE_LARGE * 7
    r.ImGui_SetNextWindowSize(ctx, winWid, winHgt)
    local winPosX, winPosY = r.ImGui_Viewport_GetPos(viewPort)
    local winSizeX, winSizeY = r.ImGui_Viewport_GetSize(viewPort)
    local okPosX = winPosX + (winSizeX / 2.) - (winWid / 2.)
    local okPosY = winPosY + (winSizeY / 2.) - (winHgt / 2.) + (yOff and yOff or 0)
    if okPosY + winHgt > windowInfo.top + windowInfo.height then
      okPosY = okPosY - ((windowInfo.top + windowInfo.height) - (okPosY + winHgt))
    end
    r.ImGui_SetNextWindowPos(ctx, okPosX, okPosY)
    --r.ImGui_SetNextWindowPos(ctx, r.ImGui_GetMousePos(ctx))
  end

  local function handleOKDialog(title, text)
    local rv = false
    local retval = 0
    local doOK = false

    r.ImGui_PushFont(ctx, fontInfo.large)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

    if inOKDialog then
      positionModalWindow(r.ImGui_GetFrameHeight(ctx) / 2)
      r.ImGui_OpenPopup(ctx, title)
    elseif (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
      or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())) then
        doOK = true
    end

    if r.ImGui_BeginPopupModal(ctx, title, true, r.ImGui_WindowFlags_TopMost()) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        r.ImGui_CloseCurrentPopup(ctx)
        handledEscape = true
        refocusInput = true
      end
      if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
      r.ImGui_Spacing(ctx)
      r.ImGui_Text(ctx, text)
      r.ImGui_Spacing(ctx)
      if r.ImGui_Button(ctx, 'Cancel') then
        rv = true
        retval = 0
        r.ImGui_CloseCurrentPopup(ctx)
      end

      r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx, 'OK') or doOK then
        rv = true
        retval = 1
        r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_SetItemDefaultFocus(ctx)

      r.ImGui_EndPopup(ctx)
    end
    r.ImGui_PopFont(ctx)
    r.ImGui_PopStyleColor(ctx)

    inOKDialog = false

    return rv, retval
  end

  local function presetPathAndFilenameFromLastInput()
    local path
    local buf = lastInputTextBuffer
    if not buf:match('%' .. presetExt .. '$') then buf = buf .. presetExt end

    if not dirExists(presetPath) then r.RecursiveCreateDirectory(presetPath, 0) end

    path = presetPath .. buf
    return path, buf
  end

  local function doSavePreset(path, fname)
    local f = io.open(path, 'wb')
    local saved = false
    if f then
      local presetTab = {
        findScope = findScopeTable[currentFindScope].notation,
        findMacro = findRowsToNotation(),
        actionScope = actionScopeTable[currentActionScope].notation,
        actionMacro = actionRowsToNotation()
      }
      f:write(serialize(presetTab))
      f:close()
      saved = true
    end
    statusMsg = (saved and 'Saved' or 'Failed to save') .. ' ' .. fname
    statusTime = r.time_precise()
    statusContext = 2
    fname = fname:gsub('%' .. presetExt .. '$', '')
    presetLabel = fname
  end

  local function manageSaveAndOverwrite(pathFn, saveFn, statusCtx, suppressOverwrite)
    if inOKDialog then
      if not lastInputTextBuffer or lastInputTextBuffer == '' then
        statusMsg = 'Name must contain at least 1 character'
        statusTime = r.time_precise()
        statusContext = statusCtx
        inOKDialog = false
        return
      end
      local path, fname = pathFn()
      if not path then
        statusMsg = 'Could not find or create directory'
        statusTime = r.time_precise()
        statusContext = statusCtx
      elseif suppressOverwrite or not filePathExists(path) then
        saveFn(path, fname)
        inOKDialog = false
      end
    end

    if lastInputTextBuffer and lastInputTextBuffer ~= '' then
      local okrv, okval = handleOKDialog('Overwrite File?', 'Overwrite file '..lastInputTextBuffer..'?')
      if okrv then
        if okval == 1 then
          local path, fname = pathFn()
          saveFn(path, fname)
          r.ImGui_CloseCurrentPopup(ctx)
        end
      end
    end
  end

  if statusContext == 2 then
    presetInputVisible = false
  end

  if presetInputVisible then
    r.ImGui_SameLine(ctx)
    r.ImGui_SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    local retval, buf = r.ImGui_InputTextWithHint(ctx, '##presetname', 'Untitled', lastInputTextBuffer, r.ImGui_InputTextFlags_AutoSelectAll())
    if kbdEntryIsCompleted(retval) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        presetInputVisible = false
        handledEscape = true
      else
        lastInputTextBuffer = buf
        inOKDialog = true
      end
    else
      lastInputTextBuffer = buf
    end
    manageSaveAndOverwrite(presetPathAndFilenameFromLastInput, doSavePreset, 2)
  end

  local function handleStatus(ctext)
    if statusMsg ~= '' and statusTime and statusContext == ctext then
      if r.time_precise() - statusTime > 3 then statusTime = nil statusMsg = '' statusContext = 0
      else
        r.ImGui_SameLine(ctx)
        r.ImGui_AlignTextToFramePadding(ctx)
        r.ImGui_Text(ctx, statusMsg)
      end
    end
  end

  handleStatus(2)

  createPopup('openPresetMenu', presetTable, -1, function(i)
    local filename = presetTable[i].label .. presetExt
    local f = io.open(presetPath .. filename, 'r')
    if f then
      local tabStr = f:read('*all')
      f:close()

      if tabStr then
        local presetTab = deserialize(tabStr)
        if presetTab then
          currentActionScope = actionScopeFromNotation(presetTab.actionScope)
          currentFindScope = findScopeFromNotation(presetTab.findScope)
          findRowTable = {}
          processFindMacro(presetTab.findMacro)
          actionRowTable = {}
          processActionMacro(presetTab.actionMacro)

          presetLabel = presetTable[i].label
          lastInputTextBuffer = presetLabel
        end
      end
    end
  end)


  ---------------------------------------------------------------------------
  -------------------------------- PRESET SAVE ------------------------------

  -- TODO

  ---------------------------------------------------------------------------
  ------------------------------- MOD KEYS ------------------------------

  -- note that the mod is only captured if the window is explicitly focused
  -- with a click. not sure how to fix this yet. TODO
  -- local mods = r.ImGui_GetKeyMods(ctx)
  -- local shiftdown = mods & r.ImGui_Mod_Shift() ~= 0

  -- current 'fix' is using the JS extension
  local mods = r.JS_Mouse_GetState(24) -- shift key
  -- local shiftdown = mods & 8 ~= 0
  -- local optdown = mods & 16 ~= 0
  -- local PPQCent = math.floor(PPQ * 0.01) -- for BBU conversion

  ---------------------------------------------------------------------------
  ------------------------------- ARROW KEYS ------------------------------

  -- escape key kills our arrow key focus
  if not handledEscape and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
    if focusKeyboardHere then focusKeyboardHere = nil
    else
      isClosing = true
      return
    end
  end

  -- local arrowAdjust = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_UpArrow()) and 1
  --                  or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_DownArrow()) and -1
  --                  or 0
  -- if arrowAdjust ~= 0 and (activeFieldName or focusKeyboardHere) then
  --   for _, hitTest in ipairs(itemBounds) do
  --     if (hitTest.name == focusKeyboardHere
  --         or hitTest.name == activeFieldName)
  --       and hitTest.name ~= 'textmsg'
  --     then
  --       if hitTest.recalcSelection and optdown then
  --         arrowAdjust = arrowAdjust * PPQ -- beats instead of ticks
  --       elseif needsBBUConversion(hitTest.name) then
  --         arrowAdjust = arrowAdjust * PPQCent
  --       end

  --       userValues[hitTest.name].operation = OP_ADD
  --       userValues[hitTest.name].opval = arrowAdjust
  --       changedParameter = hitTest.name
  --       if hitTest.recalcEvent then recalcEventTimes = true
  --       elseif hitTest.recalcSelection then recalcSelectionTimes = true
  --       else canProcess = true end
  --       if hitTest.name == activeFieldName then
  --         rewriteIDForAFrame = hitTest.name
  --         focusKeyboardHere = hitTest.name
  --       end
  --       break
  --     end
  --   end
  -- end

  ---------------------------------------------------------------------------
  ------------------------------- MOUSE SCROLL ------------------------------

  -- local vertMouseWheel = r.ImGui_GetMouseWheel(ctx)
  -- local mScrollAdjust = vertMouseWheel > 0 and -1 or vertMouseWheel < 0 and 1 or 0
  -- if reverseScroll then mScrollAdjust = mScrollAdjust * -1 end

  -- local posx, posy = r.ImGui_GetMousePos(ctx)
  -- posx = posx - vx
  -- posy = posy - vy
  -- if mScrollAdjust ~= 0 then
  --   if shiftdown then
  --     mScrollAdjust = mScrollAdjust * 3
  --   end

  --   for _, hitTest in ipairs(itemBounds) do
  --     if userValues[hitTest.name].operation == OP_ABS -- and userValues[hitTest.name].opval ~= INVALID
  --       and posy > hitTest.hity[1] and posy < hitTest.hity[2]
  --       and posx > hitTest.hitx[1] and posx < hitTest.hitx[2]
  --       and hitTest.name ~= 'textmsg'
  --     then
  --       if hitTest.name == activeFieldName then
  --         rewriteIDForAFrame = activeFieldName
  --       end

  --       if hitTest.name == 'ticks' and shiftdown then
  --         mScrollAdjust = mScrollAdjust > 1 and 5 or -5
  --       elseif hitTest.name == 'notedur' and shiftdown then
  --         mScrollAdjust = mScrollAdjust > 1 and 10 or -10
  --       end

  --       if hitTest.recalcSelection and optdown then
  --         mScrollAdjust = mScrollAdjust * PPQ -- beats instead of ticks
  --       elseif needsBBUConversion(hitTest.name) then
  --         mScrollAdjust = mScrollAdjust * PPQCent
  --       end

  --       userValues[hitTest.name].operation = OP_ADD
  --       userValues[hitTest.name].opval = mScrollAdjust
  --       changedParameter = hitTest.name
  --       if hitTest.recalcEvent then recalcEventTimes = true
  --       elseif hitTest.recalcSelection then recalcSelectionTimes = true
  --       else canProcess = true end
  --       break
  --     end
  --   end
  -- end

  -- if recalcEventTimes or recalcSelectionTimes then canProcess = true end

end

-----------------------------------------------------------------------------
--------------------------------- CLEANUP -----------------------------------

local function doClose()
  r.ImGui_Detach(ctx, fontInfo.large)
  r.ImGui_Detach(ctx, fontInfo.small)
  r.ImGui_DestroyContext(ctx)
  ctx = nil
  if disabledAutoOverlap then
    gooseAutoOverlap()
  end
end

local function onCrash(err)
  if disabledAutoOverlap then
    gooseAutoOverlap()
  end
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
end

-----------------------------------------------------------------------------
----------------------------- WSIZE/FONTS JUNK ------------------------------

local function updateWindowPosition()
  local curWindowWidth, curWindowHeight = r.ImGui_GetWindowSize(ctx)
  local curWindowLeft, curWindowTop = r.ImGui_GetWindowPos(ctx)

  if dockID ~= 0 then
    local styleWidth, styleHeight = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_WindowMinSize())
    if curWindowWidth == styleWidth and curWindowHeight == styleHeight then
      curWindowWidth = windowInfo.width
      curWindowHeight = windowInfo.height
    end
  end

  if not windowInfo.wantsResize
    and (windowInfo.wantsResizeUpdate
      or curWindowWidth ~= windowInfo.width
      or curWindowHeight ~= windowInfo.height
      or curWindowLeft ~= windowInfo.left
      or curWindowTop ~= windowInfo.top)
  then
    if dockID == 0 then
      r.SetExtState(scriptID, 'windowRect', math.floor(curWindowLeft)..','..math.floor(curWindowTop)..','..math.floor(curWindowWidth)..','..math.floor(curWindowHeight), true)
    end
    windowInfo.left, windowInfo.top, windowInfo.width, windowInfo.height = curWindowLeft, curWindowTop, curWindowWidth, curWindowHeight
    windowInfo.wantsResizeUpdate = false
  end

  local isDocked = r.ImGui_IsWindowDocked(ctx)
  if isDocked then
    local curDockID = r.ImGui_GetWindowDockID(ctx)
    if dockID ~= curDockID then
      dockID = curDockID
      r.SetExtState(scriptID, 'dockID', tostring(math.floor(dockID)), true)
    end
  elseif dockID ~= 0 then
    dockID = 0
    r.DeleteExtState(scriptID, 'dockID', true)
  end
end

local function initializeWindowPosition()
  local wLeft = 100
  local wTop = 100
  local wWidth = windowInfo.defaultWidth
  local wHeight = windowInfo.defaultHeight
  if r.HasExtState(scriptID, 'windowRect') then
    local rectStr = r.GetExtState(scriptID, 'windowRect')
    local rectTab = {}
    for word in string.gmatch(rectStr, '([^,]+)') do
      table.insert(rectTab, word)
    end
    if rectTab[1] then wLeft = rectTab[1] end
    if rectTab[2] then wTop = rectTab[2] end
    if rectTab[3] then wWidth = rectTab[3] end
    if rectTab[4] then wHeight = rectTab[4] end
  end
  return wLeft, wTop, wWidth, wHeight
end

local function updateOneFont(name)
  if not fontInfo[name] then return end

  local newFontSize = math.floor(scaled(fontInfo[name..'DefaultSize']))
  if newFontSize < 1 then newFontSize = 1 end
  local fontSize = fontInfo[name..'Size']

  if newFontSize ~= fontSize then
    r.ImGui_Detach(ctx, fontInfo[name])
    fontInfo[name] = r.ImGui_CreateFont('sans-serif', newFontSize)
    r.ImGui_Attach(ctx, fontInfo[name])
    fontInfo[name..'Size'] = newFontSize
  end
end

local function updateFonts()
  updateOneFont('large')
  updateOneFont('small')
end

local function openWindow()
  local windowSizeFlag = r.ImGui_Cond_Appearing()
  if windowInfo.wantsResize then
    windowSizeFlag = nil
  end
  if dockID == 0 then
    r.ImGui_SetNextWindowSize(ctx, windowInfo.width, windowInfo.height, windowSizeFlag)
    r.ImGui_SetNextWindowPos(ctx, windowInfo.left, windowInfo.top, windowSizeFlag)
  end
  if windowInfo.wantsResize then
    windowInfo.wantsResize = false
    windowInfo.wantsResizeUpdate = true
  end

  r.ImGui_SetNextWindowBgAlpha(ctx, 1.0)

  r.ImGui_PushFont(ctx, fontInfo.large)
  local winheight = r.ImGui_GetFrameHeightWithSpacing(ctx) * 30
  r.ImGui_SetNextWindowSizeConstraints(ctx, windowInfo.defaultWidth, winheight, windowInfo.defaultWidth * 3, winheight)
  r.ImGui_PopFont(ctx)

  r.ImGui_PushFont(ctx, fontInfo.small)
  r.ImGui_SetNextWindowDockID(ctx, ~0, r.ImGui_Cond_Appearing()) --, r.ImGui_Cond_Appearing()) -- TODO docking
  local visible, open = r.ImGui_Begin(ctx, titleBarText .. '###' .. scriptID, true,
                                        r.ImGui_WindowFlags_TopMost()
                                      + r.ImGui_WindowFlags_NoScrollWithMouse()
                                      + r.ImGui_WindowFlags_NoScrollbar()
                                      + r.ImGui_WindowFlags_NoSavedSettings())

  if r.ImGui_IsWindowDocked(ctx) then
    r.ImGui_Text(ctx, titleBarText)
    r.ImGui_Separator(ctx)
  end
  r.ImGui_PopFont(ctx)

  if r.ImGui_IsWindowAppearing(ctx) then
    viewPort = r.ImGui_GetWindowViewport(ctx)
  end

  return visible, open
end

-----------------------------------------------------------------------------
-------------------------------- SHORTCUTS ----------------------------------

local function checkShortcuts()
  if r.ImGui_IsAnyItemActive(ctx) then return end

  local keyMods = r.ImGui_GetKeyMods(ctx)
  local modKey = keyMods == r.ImGui_Mod_Shortcut()
  local modShiftKey = keyMods == r.ImGui_Mod_Shortcut() + r.ImGui_Mod_Shift()
  local noMod = keyMods == 0

  if modKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then -- undo
    r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40013)
  elseif modShiftKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then -- redo
    r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40014)
  elseif noMod and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Space()) then -- play/pause
    r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40016)
  end
end

-----------------------------------------------------------------------------
-------------------------------- MAIN LOOP ----------------------------------

local function loop()

  if isClosing then
    doClose()
    return
  end

  canvasScale = windowInfo.width / windowInfo.defaultWidth
  if canvasScale > 2 then canvasScale = 2 end

  updateFonts()

  local visible, open = openWindow()
  if visible then
    checkShortcuts()

    r.ImGui_PushFont(ctx, fontInfo.large)
    windowFn()
    r.ImGui_PopFont(ctx)

    updateWindowPosition()

    r.ImGui_End(ctx)
  end

  if not open then
    isClosing = true -- will close out on the next frame
  end

  r.defer(function() xpcall(loop, onCrash) end)
end

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

prepRandomShit()
prepWindowAndFont()
windowInfo.left, windowInfo.top, windowInfo.width, windowInfo.height = initializeWindowPosition()
r.defer(function() xpcall(loop, onCrash) end)

-----------------------------------------------------------------------------
----------------------------------- FIN -------------------------------------
