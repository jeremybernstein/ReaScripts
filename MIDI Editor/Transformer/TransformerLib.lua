--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

-- function in this file mostly global due to Lua's 200 global variable limitation... not ideal.

-- TODO: metric grid editor
-- TODO: function generator (N sliders, lin interpolate between?)
-- TODO: split at intervals

local r = reaper
local mu

local DEBUG = false
local DEBUGPOST = false

if DEBUG then
  package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
  mu = require 'MIDIUtils'
else
  package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. '?.lua;' -- GET DIRECTORY FOR REQUIRE
  mu = require 'MIDIUtils'
end

mu.ENFORCE_ARGS = false -- turn off type checking
mu.CORRECT_OVERLAPS = true
mu.CLAMP_MIDI_BYTES = true
mu.CORRECT_OVERLAPS_FAVOR_SELECTION = true -- any downsides to having it on all the time?
mu.CORRECT_OVERLAPS_FAVOR_NOTEON = true
mu.CORRECT_EXTENTS = true

function P(...)
  mu.post(...)
end

function T(...)
  if ... then
    mu.tprint(...)
  end
end

local function startup(scriptName)
  if mu then return mu.CheckDependencies() end
  return false
end

local TransformerLib = {}

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. '?.lua;' -- GET DIRECTORY FOR REQUIRE
local te = require 'TransformerExtra'
te.initExtra(TransformerLib)

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local INVALID = -0xFFFFFFFF

local NOTE_TYPE = 0
local CC_TYPE = 1
local SYXTEXT_TYPE = 2
local OTHER_TYPE = 7

local CC_CURVE_SQUARE = 0
-- local CC_CURVE_LINEAR = 1
-- local CC_CURVE_SLOW_START_END = 2
-- local CC_CURVE_FAST_START = 3
-- local CC_CURVE_FAST_END = 4
local CC_CURVE_BEZIER = 5

local SELECT_TIME_SHEBANG = 0
local SELECT_TIME_MINRANGE = 1
local SELECT_TIME_MAXRANGE = 2
local SELECT_TIME_RANGE = 3
local SELECT_TIME_INDIVIDUAL = 4

local parserError = ''
local dirtyFind = false
local wantsTab = {}

local allEvents = {}
local selectedEvents = {}

local libPresetNotesBuffer = ''

-----------------------------------------------------------------------------
------------------------------- TRANSFORMER ---------------------------------

local findScopeTable = {
  { notation = '$everywhere', label = 'Everywhere' },
  { notation = '$selected', label = 'Selected Items' },
  { notation = '$midieditor', label = 'Active MIDI Editor' },
  -- { notation = '$midieditorselected', label = 'Active MIDI Editor / Selected Events' }
}

local FIND_SCOPE_FLAG_NONE = 0x00
local FIND_SCOPE_FLAG_SELECTED_ONLY = 0x01
local FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW = 0x02

local currentFindScopeFlags = FIND_SCOPE_FLAG_NONE

function FindScopeFromNotation(notation)
  if notation then
    if notation == '$midieditorselected' then
      local scope = FindScopeFromNotation('$midieditor')
      currentFindScopeFlags = FIND_SCOPE_FLAG_SELECTED_ONLY
      return scope
    end
    for k, v in ipairs(findScopeTable) do
      if v.notation == notation then
        return k
      end
    end
  end
  return FindScopeFromNotation('$midieditor') -- default
end

local currentFindScope = FindScopeFromNotation()

local findScopeFlagsTable = {
  { notation = '$selectedonly', label = 'Selected Events', flag = FIND_SCOPE_FLAG_SELECTED_ONLY },
  { notation = '$activenoterow', label = 'Active Note Row (notes only)', flag = FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW },
}

function FindScopeFlagFromNotation(notation)
  if notation then
    for _, v in ipairs(findScopeFlagsTable) do
      if v.notation == notation then
        return v.flag
      end
    end
  end
  return FIND_SCOPE_FLAG_NONE -- default
end

local FIND_POSTPROCESSING_FLAG_NONE = 0x00
local FIND_POSTPROCESSING_FLAG_FIRSTEVENT = 0x01
local FIND_POSTPROCESSING_FLAG_LASTEVENT = 0x02

local currentFindPostProcessingInfo

function ClearFindPostProcessingInfo()
  currentFindPostProcessingInfo = {
    flags = FIND_POSTPROCESSING_FLAG_NONE,
    front = { count = 1, offset = 0 },
    back = { count = 1, offset = 0 },
  }
end
ClearFindPostProcessingInfo()

local findPostProcessingTable = {
  { notation = '$firstevent', flag = FIND_POSTPROCESSING_FLAG_FIRSTEVENT },
  { notation = '$lastevent', flag = FIND_POSTPROCESSING_FLAG_LASTEVENT },
}

function FindPostProcessingFlagFromNotation(notation)
  if notation then
    for _, v in ipairs(findPostProcessingTable) do
      if v.notation == notation then
        return v.flag
      end
    end
  end
  return FIND_POSTPROCESSING_FLAG_NONE -- default
end

local actionScopeTable = {
  { notation = '$select', label = 'Select', selectonly = true },
  { notation = '$selectadd', label = 'Add To Selection', selectonly = true },
  { notation = '$invertselect', label = 'Inverted Select', selectonly = true },
  { notation = '$deselect', label = 'Deselect', selectonly = true },
  { notation = '$transform', label = 'Transform' },
  { notation = '$replace', label = 'Transform & Replace' },
  { notation = '$copy', label = 'Transform to Track' },
  { notation = '$copylane', label = 'Transform to Lane', disable = not te.isREAPER7() },
  { notation = '$insert', label = 'Insert' },
  { notation = '$insertexclusive', label = 'Insert Exclusive' },
  { notation = '$extracttrack', label = 'Extract to Track' },
  { notation = '$extractlane', label = 'Extract to Lane', disable = not te.isREAPER7() },
  { notation = '$delete', label = 'Delete' },
}

function ActionScopeFromNotation(notation)
  if isValidString(notation) then
    for k, v in ipairs(actionScopeTable) do
      if v.notation == notation then
        return k
      end
    end
  end
  return ActionScopeFromNotation('$select') -- default
end

local actionScopeFlagsTable = {
  { notation = '$none', label = 'Do Nothing' },
  { notation = '$addselect', label = 'Add To Existing Selection' },
  { notation = '$exclusiveselect', label = 'Exclusive Select' },
  { notation = '$unselect', label = 'Deselect Transformed Events' }
  -- { notation = '$invertselect', label = 'Deselect Transformed Events (Selecting Others)' }, -- not so useful
}

function ActionScopeFlagsFromNotation(notation)
  if isValidString(notation) then
    for k, v in ipairs(actionScopeFlagsTable) do
      if v.notation == notation then
        return k
      end
    end
  end
  return ActionScopeFlagsFromNotation('$none') -- default
end

local currentActionScope = ActionScopeFromNotation()
local currentActionScopeFlags = ActionScopeFlagsFromNotation()

local DEFAULT_TIMEFORMAT_STRING = '1.1.00'
TransformerLib.DEFAULT_TIMEFORMAT_STRING = DEFAULT_TIMEFORMAT_STRING
local DEFAULT_LENGTHFORMAT_STRING = '0.0.00'
TransformerLib.DEFAULT_LENGTHFORMAT_STRING = DEFAULT_LENGTHFORMAT_STRING

local scriptIgnoreSelectionInArrangeView = false

-----------------------------------------------------------------------------
------------------------------ FIND DEFS ------------------------------------

local ParamInfo = class(nil, {})

function ParamInfo:init()
  self.menuEntry = 1
  self.textEditorStr = '0'
  self.timeFormatStr = DEFAULT_TIMEFORMAT_STRING
  self.editorType = nil
  self.percentVal = nil
end

local FindRow = class(nil, {})

function FindRow:init()
  self.targetEntry = 1
  self.conditionEntry = 1
  self.timeFormatEntry = 1
  self.booleanEntry = 1
  self.startParenEntry = 1
  self.endParenEntry = 1

  self.params = {
    ParamInfo(),
    ParamInfo()
  }
  self.isNot = false
  self.except = nil
end

local findRowTable = {}

function AddFindRow(row)
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

-- fullrange is just for velocity, allowing 0
-- norange can be used to turn off editor type range hints (and disable the range)
-- nooverride means no editor override possible
-- literal means save what was typed, not a percent
-- freeterm means don't flip the param fields if p1 > p2

-- notnot means no not checkbox

local findTargetEntries = {
  { notation = '$position', label = 'Position', text = '\'projtime\'', time = true },
  { notation = '$length', label = 'Length', text = '\'projlen\'', timedur = true, cond = 'event.chanmsg == 0x90' },
  { notation = '$channel', label = 'Channel', text = '\'chan\'', menu = true },
  { notation = '$type', label = 'Type', text = '\'chanmsg\'', menu = true },
  { notation = '$property', label = 'Property', text = '\'flags\'', menu = true },
  { notation = '$value1', label = 'Value 1', text = '_value1', inteditor = true, range = {0, 127} },
  { notation = '$value2', label = 'Value 2', text = '_value2', inteditor = true, range = {0, 127} },
  { notation = '$velocity', label = 'Velocity (Notes)', text = '\'msg3\'', inteditor = true, cond = 'event.chanmsg == 0x90', range = {1, 127} },
  { notation = '$relvel', label = 'Release Velocity (Notes)', text = '\'relvel\'', inteditor = true, cond = 'event.chanmsg == 0x90', range = {0, 127} },
  { notation = '$lastevent', label = 'Last Event', text = '\'\'', inteditor = true },
}
findTargetEntries.targetTable = true

local OP_EQ = 1
local OP_GT = 2
local OP_GTE = 3
local OP_LT = 4
local OP_LTE = 5
local OP_INRANGE = 6
local OP_INRANGE_EXCL = 7
local OP_EQ_SLOP = 8
local OP_SIMILAR = 9
local OP_EQ_NOTE = 10

local findConditionEqual = { notation = '==', label = 'Equal', text = 'TestEvent1(event, {tgt}, OP_EQ, {param1})', terms = 1 }
local findConditionGreaterThan = { notation = '>', label = 'Greater Than', text = 'TestEvent1(event, {tgt}, OP_GT, {param1})', terms = 1, notnot = true }
local findConditionGreaterThanEqual = { notation = '>=', label = 'Greater Than or Equal', text = 'TestEvent1(event, {tgt}, OP_GTE, {param1})', terms = 1, notnot = true }
local findConditionLessThan = { notation = '<', label = 'Less Than', text = 'TestEvent1(event, {tgt}, OP_LT, {param1})', terms = 1, notnot = true }
local findConditionLessThanEqual = { notation = '<=', label = 'Less Than or Equal', text = 'TestEvent1(event, {tgt}, OP_LTE, {param1})', terms = 1, notnot = true }
local findConditionInRange = { notation = ':inrange', label = 'Inside Range', text = 'TestEvent2(event, {tgt}, OP_INRANGE, {param1}, {param2})', terms = 2 }
local findConditionInRangeExcl = { notation = ':inrangeexcl', label = 'Inside Range (Exclusive End)', text = 'TestEvent2(event, {tgt}, OP_INRANGE_EXCL, {param1}, {param2})', terms = 2 }
local findConditionEqualSlop = { notation = ':eqslop', label = 'Equal (Slop)', text = 'TestEvent2(event, {tgt}, OP_EQ_SLOP, {param1}, {param2})', terms = 2, inteditor = true, freeterm = true }

-- these have the same notation, should be fine since they will never be in the same menu
local findConditionSimilar = { notation = ':similar', label = 'Similar to Selection', text = 'TestEvent2(event, {tgt}, OP_SIMILAR, 0, 0)', terms = 0, rangelabel = { 'pre-slop', 'post-slop' } }
local findConditionSimilarSlop = { notation = ':similar', label = 'Similar to Selection', text = 'TestEvent2(event, {tgt}, OP_SIMILAR, {param1}, {param2})', terms = 2, fullrange = true, literal = true, freeterm = true, rangelabel = { 'pre-slop', 'post-slop' } }

local findGenericConditionEntries = {
  findConditionEqual,
  findConditionEqualSlop,
  findConditionGreaterThan, findConditionGreaterThanEqual, findConditionLessThan, findConditionLessThanEqual,
  findConditionInRange,
  findConditionInRangeExcl,
  findConditionSimilarSlop,
}

local findValue1ConditionEntries = {
  findConditionEqual,
  findConditionEqualSlop,
  { notation = ':eqnote', label = 'Equal (Note)', text = 'TestEvent1(event, {tgt}, OP_EQ_NOTE, {param1})', terms = 1, menu = true },
  findConditionGreaterThan, findConditionGreaterThanEqual, findConditionLessThan, findConditionLessThanEqual,
  findConditionInRange,
  findConditionInRangeExcl,
  findConditionSimilarSlop,
}

local findLastEventConditionEntries = {
  { notation = ':everyN', label = 'Every N Event', text = 'FindEveryN(event, {everyNparams})', terms = 1, range = { 1, nil }, nooverride = true, literal = true, freeterm = true, everyn = true },
  { notation = ':everyNnote', label = 'Every N Event (Note)', text = 'FindEveryNNote(event, {everyNparams}, {param2})', terms = 2, split = {{ range = { 1, nil }, default = 1 }, { menu = true }}, nooverride = true, literal = true, freeterm = true, everyn = true },
  { notation = ':everyNnotenum', label = 'Every N Event (Note #)', text = 'FindEveryNNote(event, {everyNparams}, {param2})', terms = 2, split = {{ range = { 1, nil }, default = 1 }, { inteditor = true, range = { 0, 127 } }}, nooverride = true, literal = true, freeterm = true, everyn = true },
  { notation = ':chordhigh', label = 'Highest Note in Chord', text = 'SelectChordNote(event, \'$high\')', terms = 0 },
  { notation = ':chordlow', label = 'Lowest Note in Chord', text = 'SelectChordNote(event, \'$low\')', terms = 0 },
  { notation = ':chordpos', label = 'Position in Chord', text = 'SelectChordNote(event, {param1})', terms = 1, inteditor = true, literal = true, nooverride = true},
}

function FindConditionAddSelectRange(t, r)
  local tt = tableCopy(t)
  tt.timeselect = r
  return tt
end

local findConditionSimilarSlopTime = tableCopy(findConditionSimilarSlop)
findConditionSimilarSlopTime.timedur = true

local findPositionConditionEntries = {
  FindConditionAddSelectRange(findConditionEqual, SELECT_TIME_INDIVIDUAL),
  { notation = ':eqslop', label = 'Equal (Slop)', text = 'TestEvent2(event, {tgt}, OP_EQ_SLOP, {param1}, {param2})', terms = 2, split = { { time = true }, { timedur = true } }, freeterm = true, timeselect = SELECT_TIME_RANGE },
  FindConditionAddSelectRange(findConditionGreaterThan, SELECT_TIME_MINRANGE),
  FindConditionAddSelectRange(findConditionGreaterThanEqual, SELECT_TIME_MINRANGE),
  FindConditionAddSelectRange(findConditionLessThan, SELECT_TIME_MAXRANGE),
  FindConditionAddSelectRange(findConditionLessThanEqual, SELECT_TIME_MAXRANGE),
  FindConditionAddSelectRange(findConditionInRange, SELECT_TIME_RANGE),
  FindConditionAddSelectRange(findConditionInRangeExcl, SELECT_TIME_RANGE),
  FindConditionAddSelectRange(findConditionSimilarSlopTime, SELECT_TIME_INDIVIDUAL),
  { notation = ':ongrid', label = 'On Grid', text = 'OnGrid(event, {tgt}, take, PPQ)', terms = 0, timeselect = SELECT_TIME_INDIVIDUAL },
  { notation = ':inbarrange', label = 'Inside Bar Range %', text = 'InBarRange(take, PPQ, event.ppqpos, {param1}, {param2})', terms = 2, split = {{ floateditor = true, percent = true }, { floateditor = true, percent = true, default = 100 }}, timeselect = SELECT_TIME_RANGE },
  { notation = ':onmetricgrid', label = 'On Metric Grid', text = 'OnMetricGrid(take, PPQ, event.ppqpos, {metricgridparams})', terms = 2, metricgrid = true, split = {{ }, { bitfield = true, default = '0', rangelabel = 'bitfield' }}, timeselect = SELECT_TIME_INDIVIDUAL },
  { notation = ':cursorpos', label = 'Cursor Position', text = 'CursorPosition(event, {tgt}, r.GetCursorPositionEx(0) + GetTimeOffset(), {param1})', terms = 1, menu = true, notnot = true },
  { notation = ':undereditcursor', label = 'Under Edit Cursor (Slop)', text = 'UnderEditCursor(event, take, PPQ, r.GetCursorPositionEx(0), {param1}, {param2})', terms = 2, split = { { menu = true, default = 4 }, { hidden = true, literal = true } }, freeterm = true },
  { notation = ':intimesel', label = 'Inside Time Selection', text = 'TestEvent2(event, {tgt}, OP_INRANGE_EXCL, GetTimeSelectionStart(), GetTimeSelectionEnd())', terms = 0, timeselect = SELECT_TIME_RANGE },
  { notation = ':inrazor', label = 'Inside Razor Area', text = 'InRazorArea(event, take)', terms = 0, timeselect = SELECT_TIME_RANGE },
  { notation = ':nearevent', label = 'Is Near Event', text = 'IsNearEvent(event, take, PPQ, {eventselectorparams}, {param2})', terms = 2, split = {{ eventselector = true }, { menu = true, default = 4 }}, freeterm = true },
  -- { label = 'Inside Selected Marker', text = { '>= GetSelectedRegionStart() and', '<= GetSelectedRegionEnd()' }, terms = 0 } -- region?
}

local findLengthConditionEntries = {
  findConditionEqual,
  { notation = ':eqslop', label = 'Equal (Slop)', text = 'TestEvent2(event, {tgt}, OP_EQ_SLOP, {param1}, {param2})', terms = 2, timedur = true, freeterm = true },
  { notation = ':eqmusical', label = 'Equal (Musical)', text = 'EqualsMusicalLength(event, take, PPQ, {musicalparams})', terms = 1, musical = true },
  findConditionGreaterThan, findConditionGreaterThanEqual, findConditionLessThan, findConditionLessThanEqual,
  findConditionInRange,
  findConditionInRangeExcl,
  findConditionSimilarSlopTime,
}

local findTypeConditionEntries = {
  findConditionEqual,
  { notation = ':all', label = 'All', text = 'event.chanmsg ~= nil', terms = 0, notnot = true },
  findConditionSimilar,
}

local findPropertyConditionEntries = {
  { notation = ':isselected', label = 'Selected', text = '(event.flags & 0x01) ~= 0', terms = 0 },
  { notation = ':ismuted', label = 'Muted', text = '(event.flags & 0x02) ~= 0', terms = 0 },
  { notation = ':inchord', label = 'In Chord', text = '(event.flags & 0x04) ~= 0', terms = 0 },
  { notation = ':inscale', label = 'In Scale', text = 'InScale(event, {param1}, {param2})', terms = 2, menu = true },
  { notation = ':cchascurve', label = 'CC has Curve', text = 'CCHasCurve(take, event, {param1})', terms = 1, menu = true },
}

local typeEntries = {
  { notation = '$note', label = 'Note', text = '0x90' },
  { notation = '$polyat', label = 'Poly Pressure', text = '0xA0' },
  { notation = '$cc', label = 'Controller', text = '0xB0' },
  { notation = '$pc', label = 'Program Change', text = '0xC0' },
  { notation = '$at', label = 'Aftertouch', text = '0xD0' },
  { notation = '$pb', label = 'Pitch Bend', text = '0xE0' },
}

local findTypeParam1Entries = tableCopy(typeEntries)
table.insert(findTypeParam1Entries, { notation = '$syx', label = 'System Exclusive', text = '0xF0' })
table.insert(findTypeParam1Entries, { notation = '$txt', label = 'Text', text = '0x100' }) -- special case; these need a new chanmsg

local typeEntriesForEventSelector = tableCopy(typeEntries)
table.insert(typeEntriesForEventSelector, 1, { notation = '$any', label = 'Any', text = '0x00' })
table.insert(typeEntriesForEventSelector, { notation = '$syx', label = 'System Exclusive', text = '0xF0' })

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

local findTimeFormatEntries = {
  { label = 'REAPER time' },
  { label = 'Seconds' },
  { label = 'Samples' },
  -- { label = 'Frames' }
}

local CURSOR_LT = 1
local CURSOR_GT = 2
local CURSOR_AT = 3
local CURSOR_LTE = 4
local CURSOR_GTE = 5
local CURSOR_UNDER = 6

local findCursorParam1Entries = {
  { notation = '$before', label = 'Before Cursor', text = 'CURSOR_LT', timeselect = SELECT_TIME_MAXRANGE }, -- todo search for notation
  { notation = '$after', label = 'After Cursor', text = 'CURSOR_GT', timeselect = SELECT_TIME_MINRANGE },
  { notation = '$at', label = 'At Cursor', text = 'CURSOR_AT', timeselect = SELECT_TIME_INDIVIDUAL },
  { notation = '$before_at', label = 'Before or At Cursor', text = 'CURSOR_LTE', timeselect = SELECT_TIME_MAXRANGE },
  { notation = '$after_at', label = 'After or At Cursor', text = 'CURSOR_GTE', timeselect = SELECT_TIME_MINRANGE },
  { notation = '$under', alias = {'$undercursor'}, label = 'Under Cursor (note)', text = 'CURSOR_UNDER', timeselect = SELECT_TIME_INDIVIDUAL },
}

local findMusicalParam1Entries = {
  { notation = '$1/64', label = '1/64', text = '0.015625' },
  { notation = '$1/32', label = '1/32', text = '0.03125' },
  { notation = '$1/16', label = '1/16', text = '0.0625' },
  { notation = '$1/8', label = '1/8', text = '0.125' },
  { notation = '$1/4', label = '1/4', text = '0.25' },
  { notation = '$1/2', label = '1/2', text = '0.5' },
  { notation = '$1/1', label = '1/1', text = '1' },
  { notation = '$2/1', label = '2/1', text = '2' },
  { notation = '$4/1', label = '4/1', text = '4' },
  { notation = '$grid', label = 'Current Grid', text = '-1' },
}

local findPositionMusicalSlopEntries = tableCopy(findMusicalParam1Entries)
table.insert(findPositionMusicalSlopEntries, 1, { notation = '$none', label = '<none>', text = '0' })

local findBooleanEntries = { -- in cubase this a simple toggle to switch, not a bad idea
  { notation = '&&', label = 'And', text = 'and'},
  { notation = '||', label = 'Or', text = 'or'}
}

local nornsScales = { -- https://github.com/monome/norns/blob/main/lua/lib/musicutil.lua
  { notation = '$major', text = '{0, 2, 4, 5, 7, 9, 11, 12}', label = 'Major', alt_names = {'Ionian'}, intervals = {0, 2, 4, 5, 7, 9, 11, 12}, chords = {{1, 2, 3, 4, 5, 6, 7, 14}, {14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19}, {1, 2, 3, 4, 5}, {1, 2, 4, 8, 9, 10, 11, 14, 15}, {14, 15, 17, 19, 21, 22}, {24, 26}, {1, 2, 3, 4, 5, 6, 7, 14}} },
  { notation = '$minor', text = '{0, 2, 3, 5, 7, 8, 10, 12}', label = 'Natural Minor', alt_names = {'Minor', 'Aeolian'}, intervals = {0, 2, 3, 5, 7, 8, 10, 12}, chords = {{14, 15, 17, 19, 21, 22}, {24, 26}, {1, 2, 3, 4, 5, 6, 7, 14}, {14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19}, {1, 2, 3, 4, 5}, {1, 2, 4, 8, 9, 10, 11, 14, 15}, {14, 15, 17, 19, 21, 22}} },
  { notation = '$harmonicmminor', text = '{0, 2, 3, 5, 7, 8, 11, 12}', label = 'Harmonic Minor', intervals = {0, 2, 3, 5, 7, 8, 11, 12}, chords = {{14, 16, 17}, {24, 25, 26}, {12, 27}, {17, 18, 19, 20, 21, 24, 25, 26}, {1, 8, 12, 13, 14, 15}, {1, 2, 3, 16, 17, 18, 24, 25}, {12, 24, 25}, {14, 16, 17}} },
  { notation = '$melodicminor', text = '{0, 2, 3, 5, 7, 9, 11, 12}', label = 'Melodic Minor', intervals = {0, 2, 3, 5, 7, 9, 11, 12}, chords = {{14, 16, 17, 18, 20}, {14, 15, 17, 18, 19}, {12, 27}, {1, 2, 4, 8, 9}, {1, 8, 9, 10, 12, 13, 14, 15}, {24, 26}, {12, 13, 24, 26}, {14, 16, 17, 18, 20}} },
  { notation = '$dorian', text = '{0, 2, 3, 5, 7, 9, 10, 12}', label = 'Dorian', intervals = {0, 2, 3, 5, 7, 9, 10, 12}, chords = {{14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19}, {1, 2, 3, 4, 5}, {1, 2, 4, 8, 9, 10, 11, 14, 15}, {14, 15, 17, 19, 21, 22}, {24, 26}, {1, 2, 3, 4, 5, 6, 7, 14}, {14, 15, 17, 18, 19, 20, 21, 22, 23}} },
  { notation = '$phrygian', text = '{0, 1, 3, 5, 7, 8, 10, 12}', label = 'Phrygian', intervals = {0, 1, 3, 5, 7, 8, 10, 12}, chords = {{14, 15, 17, 19}, {1, 2, 3, 4, 5}, {1, 2, 4, 8, 9, 10, 11, 14, 15}, {14, 15, 17, 19, 21, 22}, {24, 26}, {1, 2, 3, 4, 5, 6, 7, 14}, {14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19}} },
  { notation = '$lydian', text = '{0, 2, 4, 6, 7, 9, 11, 12}', label = 'Lydian', intervals = {0, 2, 4, 6, 7, 9, 11, 12}, chords = {{1, 2, 3, 4, 5}, {1, 2, 4, 8, 9, 10, 11, 14, 15}, {14, 15, 17, 19, 21, 22}, {24, 26}, {1, 2, 3, 4, 5, 6, 7, 14}, {14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19}, {1, 2, 3, 4, 5}} },
  { notation = '#mixolydian', text = '{0, 2, 4, 5, 7, 9, 10, 12}', label = 'Mixolydian', intervals = {0, 2, 4, 5, 7, 9, 10, 12}, chords = {{1, 2, 4, 8, 9, 10, 11, 14, 15}, {14, 15, 17, 19, 21, 22}, {24, 26}, {1, 2, 3, 4, 5, 6, 7, 14}, {14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19}, {1, 2, 3, 4, 5}, {1, 2, 4, 8, 9, 10, 11, 14, 15}} },
  { notation = '$locrian', text = '{0, 1, 3, 5, 6, 8, 10, 12}', label = 'Locrian', intervals = {0, 1, 3, 5, 6, 8, 10, 12}, chords = {{24, 26}, {1, 2, 3, 4, 5, 6, 7, 14}, {14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19}, {1, 2, 3, 4, 5}, {1, 2, 4, 8, 9, 10, 11, 14, 15}, {14, 15, 17, 19, 21, 22}, {24, 26}} },
  { notation = '$wholetone', text = '{0, 2, 4, 6, 8, 10, 12}', label = 'Whole Tone', intervals = {0, 2, 4, 6, 8, 10, 12}, chords = {{12, 13}, {12, 13}, {12, 13}, {12, 13}, {12, 13}, {12, 13}, {12, 13}} },
  { notation = '$majorpentatonic', text = '{0, 2, 4, 7, 9, 12}', label = 'Major Pentatonic', alt_names = {'Gagaku Ryo Sen Pou'}, intervals = {0, 2, 4, 7, 9, 12}, chords = {{1, 2, 4}, {14, 15}, {}, {14}, {14, 15, 17, 19}, {1, 2, 4}} },
  { notation = '$minorpentatonic', text = '{0, 3, 5, 7, 10, 12}', label = 'Minor Pentatonic', alt_names = {'Zokugaku Yo Sen Pou'}, intervals = {0, 3, 5, 7, 10, 12}, chords = {{14, 15, 17, 19}, {1, 2, 4}, {14, 15}, {}, {14}, {14, 15, 17, 19}} },
  { notation = '$majorbebop', text = '{0, 2, 4, 5, 7, 8, 9, 11, 12}', label = 'Major Bebop', intervals = {0, 2, 4, 5, 7, 8, 9, 11, 12}, chords = {{1, 2, 3, 4, 5, 6, 7, 12, 14, 27}, {14, 15, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26}, {1, 8, 12, 13, 14, 15, 17, 19}, {1, 2, 3, 4, 5, 16, 17, 18, 20, 24, 25}, {1, 2, 4, 8, 9, 10, 11, 14, 15}, {12, 24, 25, 27}, {14, 15, 16, 17, 19, 21, 22}, {24, 25, 26}, {1, 2, 3, 4, 5, 6, 7, 12, 14, 27}} },
  { notation = '$alteredscale', text = '{0, 1, 3, 4, 6, 8, 10, 12}', label = 'Altered Scale', intervals = {0, 1, 3, 4, 6, 8, 10, 12}, chords = {{12, 13, 24, 26}, {14, 16, 17, 18, 20}, {14, 15, 17, 18, 19}, {12, 27}, {1, 2, 4, 8, 9}, {1, 8, 9, 10, 12, 13, 14, 15}, {24, 26}, {12, 13, 24, 26}} },
  { notation = '$dorianbebop', text = '{0, 2, 3, 4, 5, 7, 9, 10, 12}', label = 'Dorian Bebop', intervals = {0, 2, 3, 4, 5, 7, 9, 10, 12}, chords = {{1, 2, 4, 8, 9, 10, 11, 14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19, 21, 22}, {1, 2, 3, 4, 5}, {24, 26}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 15}, {14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19, 24, 26}, {1, 2, 3, 4, 5, 6, 7, 14}, {1, 2, 4, 8, 9, 10, 11, 14, 15, 17, 18, 19, 20, 21, 22, 23}} },
  { notation = '$mixolydianbebop', text = '{0, 2, 4, 5, 7, 9, 10, 11, 12}', label = 'Mixolydian Bebop', intervals = {0, 2, 4, 5, 7, 9, 10, 11, 12}, chords = {{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 15}, {14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19, 24, 26}, {1, 2, 3, 4, 5, 6, 7, 14}, {1, 2, 4, 8, 9, 10, 11, 14, 15, 17, 18, 19, 20, 21, 22, 23}, {14, 15, 17, 19, 21, 22}, {1, 2, 3, 4, 5}, {24, 26}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 15}} },
  { notation = '$blues', text = '{0, 3, 5, 6, 7, 10, 12}', label = 'Blues Scale', alt_names = {'Blues'}, intervals = {0, 3, 5, 6, 7, 10, 12}, chords = {{14, 15, 17, 19, 24, 26}, {1, 2, 4, 17, 18, 20}, {14, 15}, {}, {}, {14}, {14, 15, 17, 19, 24, 26}} },
  { notation = '$dimwholehalf', text = '{0, 2, 3, 5, 6, 8, 9, 11, 12}', label = 'Diminished Whole Half', intervals = {0, 2, 3, 5, 6, 8, 9, 11, 12}, chords = {{24, 25}, {1, 2, 8, 17, 18, 19, 24, 25, 26}, {24, 25}, {1, 2, 8, 17, 18, 19, 24, 25, 26}, {24, 25}, {1, 2, 8, 17, 18, 19, 24, 25, 26}, {24, 25}, {1, 2, 8, 17, 18, 19, 24, 25, 26}, {24, 25}} },
  { notation = '$dimhalfwhole', text = '{0, 1, 3, 4, 6, 7, 9, 10, 12}', label = 'Diminished Half Whole', intervals = {0, 1, 3, 4, 6, 7, 9, 10, 12}, chords = {{1, 2, 8, 17, 18, 19, 24, 25, 26}, {24, 25}, {1, 2, 8, 17, 18, 19, 24, 25, 26}, {24, 25}, {1, 2, 8, 17, 18, 19, 24, 25, 26}, {24, 25}, {1, 2, 8, 17, 18, 19, 24, 25, 26}, {24, 25}, {1, 2, 8, 17, 18, 19, 24, 25, 26}} },
  { notation = '$neapolitanmajor', text = '{0, 1, 3, 5, 7, 9, 11, 12}', label = 'Neapolitan Major', intervals = {0, 1, 3, 5, 7, 9, 11, 12}, chords = {{14, 16, 17, 18}, {12, 13, 27}, {12, 13}, {1, 8, 9, 12, 13}, {12, 13}, {12, 13, 24, 26}, {12, 13}, {14, 16, 17, 18}} },
  { notation = '$hungarianmajor', text = '{0, 3, 4, 6, 7, 9, 10, 12}', label = 'Hungarian Major', intervals = {0, 3, 4, 6, 7, 9, 10, 12}, chords = {{1, 2, 8, 17, 18, 19, 24, 25, 26}, {1, 2, 17, 18, 24, 25}, {24}, {24, 25, 26}, {}, {17, 18, 19, 24, 25, 26}, {}, {1, 2, 8, 17, 18, 19, 24, 25, 26}} },
  { notation = '$harmonicmajor', text = '{0, 2, 4, 5, 7, 8, 11, 12}', label = 'Harmonic Major', intervals = {0, 2, 4, 5, 7, 8, 11, 12}, chords = {{1, 3, 5, 6, 12, 14, 27}, {24, 25, 26}, {1, 8, 12, 13, 17, 19}, {16, 17, 18, 20, 24, 25}, {1, 2, 8, 14, 15}, {12, 24, 25, 27}, {24, 25}, {1, 3, 5, 6, 12, 14, 27}} },
  { notation = '$hungarianminor', text = '{0, 2, 3, 6, 7, 8, 11, 12}', label = 'Hungarian Minor', intervals = {0, 2, 3, 6, 7, 8, 11, 12}, chords = {{16, 17, 24}, {}, {12, 27}, {}, {1, 3, 12, 14, 27}, {1, 3, 8, 16, 17, 19, 24, 26}, {1, 2, 12, 17, 18}, {16, 17, 24}} },
  { notation = '$lydianminor', text = '{0, 2, 4, 6, 7, 8, 10, 12}', label = 'Lydian Minor', intervals = {0, 2, 4, 6, 7, 8, 10, 12}, chords = {{1, 8, 9, 12, 13}, {12, 13}, {12, 13, 24, 26}, {12, 13}, {14, 16, 17, 18}, {12, 13, 27}, {12, 13}, {1, 8, 9, 12, 13}} },
  { notation = '$neapolitanminor', text = '{0, 1, 3, 5, 7, 8, 11, 12}', label = 'Neapolitan Minor', alt_names = {'Byzantine'}, intervals = {0, 1, 3, 5, 7, 8, 11, 12}, chords = {{14, 16, 17}, {1, 3, 5, 8, 9}, {12, 13}, {17, 19, 21, 24, 26}, {12, 13}, {1, 2, 3, 14, 16, 17, 18}, {12}, {14, 16, 17}} },
  { notation = '$majorlocrian', text = '{0, 2, 4, 5, 6, 8, 10, 12}', label = 'Major Locrian', intervals = {0, 2, 4, 5, 6, 8, 10, 12}, chords = {{12, 13}, {12, 13, 24, 26}, {12, 13}, {14, 16, 17, 18}, {12, 13, 27}, {12, 13}, {1, 8, 9, 12, 13}, {12, 13}} },
  { notation = '$leadingwholetone', text = '{0, 2, 4, 6, 8, 10, 11, 12}', label = 'Leading Whole Tone', intervals = {0, 2, 4, 6, 8, 10, 11, 12}, chords = {{12, 13, 27}, {12, 13}, {1, 8, 9, 12, 13}, {12, 13}, {12, 13, 24, 26}, {12, 13}, {14, 16, 17, 18}, {12, 13, 27}} },
  { notation = '$sixtone', text = '{0, 1, 4, 5, 8, 9, 11, 12}', label = 'Six Tone Symmetrical', intervals = {0, 1, 4, 5, 8, 9, 11, 12}, chords = {{12, 27}, {1, 3, 8, 12, 13, 16, 17, 19, 27}, {1, 2, 12, 14}, {1, 3, 12, 16, 17, 24, 27}, {12}, {1, 3, 5, 12, 16, 17, 27}, {}, {12, 27}} },
  { notation = '$balinese', text = '{0, 1, 3, 7, 8, 12}', label = 'Balinese', intervals = {0, 1, 3, 7, 8, 12}, chords = {{17}, {}, {}, {}, {1, 3, 14}, {17}} },
  { notation = '$persian', text = '{0, 1, 4, 5, 6, 8, 11, 12}', label = 'Persian', intervals = {0, 1, 4, 5, 6, 8, 11, 12}, chords = {{12, 27}, {1, 3, 8, 14, 15, 16, 17, 19}, {1, 2, 4, 12}, {16, 17, 24}, {14, 15}, {12, 13}, {14}, {12, 27}} },
  { notation = '$eastindianpurvi', text = '{0, 1, 4, 6, 7, 8, 11, 12}', label = 'East Indian Purvi', intervals = {0, 1, 4, 6, 7, 8, 11, 12}, chords = {{1, 3, 12, 27}, {14, 15, 16, 17, 19, 24, 26}, {1, 2, 4, 12, 17, 18, 20}, {14, 15}, {}, {12, 13, 27}, {14}, {1, 3, 12, 27}} },
  { notation = '$oriental', text = '{0, 1, 4, 5, 6, 9, 10, 12}', label = 'Oriental', intervals = {0, 1, 4, 5, 6, 9, 10, 12}, chords = {{}, {12, 27}, {}, {1, 3, 12, 14, 27}, {1, 3, 8, 16, 17, 19, 24, 26}, {1, 2, 12, 17, 18}, {16, 17, 24}, {}} },
  { notation = '$doubleharmonic', text = '{0, 1, 4, 5, 7, 8, 11, 12}', label = 'Double Harmonic', intervals = {0, 1, 4, 5, 7, 8, 11, 12}, chords = {{1, 3, 12, 14, 27}, {1, 3, 8, 16, 17, 19, 24, 26}, {1, 2, 12, 17, 18}, {16, 17, 24}, {}, {12, 27}, {}, {1, 3, 12, 14, 27}} },
  { notation = '$enigmatic', text = '{0, 1, 4, 6, 8, 10, 11, 12}', label = 'Enigmatic', intervals = {0, 1, 4, 6, 8, 10, 11, 12}, chords = {{12, 13, 27}, {14, 15, 16, 17, 18, 19}, {1, 2, 4, 12}, {1, 8, 9, 10, 14, 15}, {12, 13}, {24, 26}, {14}, {12, 13, 27}} },
  { notation = '$overtone', text = '{0, 2, 4, 6, 7, 9, 10, 12}', label = 'Overtone', intervals = {0, 2, 4, 6, 7, 9, 10, 12}, chords = {{1, 2, 4, 8, 9}, {1, 8, 9, 10, 12, 13, 14, 15}, {24, 26}, {12, 13, 24, 26}, {14, 16, 17, 18, 20}, {14, 15, 17, 18, 19}, {12, 27}, {1, 2, 4, 8, 9}} },
  { notation = '$eighttonespanish', text = '{0, 1, 3, 4, 5, 6, 8, 10, 12}', label = 'Eight Tone Spanish', intervals = {0, 1, 3, 4, 5, 6, 8, 10, 12}, chords = {{12, 13, 24, 26}, {1, 2, 3, 4, 5, 6, 7, 14, 16, 17, 18, 20}, {14, 15, 17, 18, 19, 20, 21, 22, 23}, {12, 27}, {14, 15, 16, 17, 19}, {1, 2, 3, 4, 5, 8, 9}, {1, 2, 4, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 15, 17, 19, 21, 22, 24, 26}, {12, 13, 24, 26}} },
  { notation = '$prometheus', text = '{0, 2, 4, 6, 9, 10, 12}', label = 'Prometheus', intervals = {0, 2, 4, 6, 9, 10, 12}, chords = {{}, {1, 8, 9, 12, 13}, {}, {12, 13, 24, 26}, {14, 17, 18}, {12, 27}, {}} },
  { notation = '$gagaku', text = '{0, 2, 5, 7, 9, 10, 12}', label = 'Gagaku Rittsu Sen Pou', intervals = {0, 2, 5, 7, 9, 10, 12}, chords = {{14, 15}, {14, 15, 17, 19}, {1, 2, 4, 14}, {14, 15, 17, 19, 21, 22}, {}, {1, 2, 3, 4, 5}, {14, 15}} },
  { notation = '$insenpou', text = '{0, 1, 5, 2, 8, 12}', label = 'In Sen Pou', intervals = {0, 1, 5, 2, 8, 12}, chords = {{}, {1, 3}, {17, 18}, {24, 26}, {}, {}} },
  { notation = '$okinawa', text = '{0, 4, 5, 7, 11, 12}', label = 'Okinawa', intervals = {0, 4, 5, 7, 11, 12}, chords = {{1, 3, 14}, {17}, {}, {}, {}, {1, 3, 14}} },
  { notation = '$chromatic', text = '{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}', label = 'Chromatic', intervals = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}, chords = {{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}} }
}

local scaleRoots = {
  { notation = 'c', label = 'C', text = '0' },
  { notation = 'c#', label = 'C# / Db', text = '1' },
  { notation = 'd', label = 'D', text = '2' },
  { notation = 'd#', label = 'D# / Eb', text = '3' },
  { notation = 'e', label = 'E', text = '4' },
  { notation = 'f', label = 'F', text = '5' },
  { notation = 'f#', label = 'F# / Gb', text = '6' },
  { notation = 'g', label = 'G', text = '7' },
  { notation = 'g#', label = 'G# / Ab', text = '8' },
  { notation = 'a', label = 'A', text = '9' },
  { notation = 'a#', label = 'A# / Bb', text = '10' },
  { notation = 'b', label = 'B', text = '11' },
}

local findCCCurveParam1Entries = {
  { notation = '$square', label = 'Square', text = '0'},
  { notation = '$linear', label = 'Linear', text = '1'},
  { notation = '$slowstartend', label = 'Slow Start/End', text = '2'},
  { notation = '$faststart', label = 'Fast Start', text = '3'},
  { notation = '$fastend', label = 'Fast End', text = '4'},
  { notation = '$bezier', label = 'Bezier', text = '5'},
}

local findPropertyParam1Entries = nornsScales
local findPropertyParam2Entries = scaleRoots

-----------------------------------------------------------------------------
----------------------------- ACTION DEFS -----------------------------------

local ActionRow = class(nil, {})

function ActionRow:init()
  self.targetEntry = 1
  self.operationEntry = 1
  self.params = {
    ParamInfo(),
    ParamInfo()
  }
end

local actionRowTable = {}

function AddActionRow(row)
  table.insert(actionRowTable, #actionRowTable+1, row and row or ActionRow())
end

local actionTargetEntries = {
  { notation = '$position', label = 'Position', text = '\'projtime\'', time = true },
  { notation = '$length', label = 'Length', text = '\'projlen\'', timedur = true, cond = 'event.chanmsg == 0x90' },
  { notation = '$channel', label = 'Channel', text = '\'chan\'', menu = true },
  { notation = '$type', label = 'Type', text = '\'chanmsg\'', menu = true },
  { notation = '$property', label = 'Property', text = '\'flags\'', menu = true },
  { notation = '$value1', label = 'Value 1', text = '_value1', inteditor = true, range = {0, 127} },
  { notation = '$value2', label = 'Value 2', text = '_value2', inteditor = true, range = {0, 127} },
  { notation = '$velocity', label = 'Velocity (Notes)', text = '\'msg3\'', inteditor = true, cond = 'event.chanmsg == 0x90', range = {1, 127} },
  { notation = '$relvel', label = 'Release Velocity (Notes)', text = '\'relvel\'', inteditor = true, cond = 'event.chanmsg == 0x90', range = {0, 127} },
  { notation = '$newevent', label = 'Create Event', text = '\'\'', newevent = true },
}
actionTargetEntries.targetTable = true

local OP_ADD = 1
local OP_SUB = 2
local OP_MULT = 3
local OP_DIV = 4
local OP_FIXED = 5
local OP_SCALEOFF = 6

local actionOperationPlus = { notation = '+', label = 'Add', text = 'OperateEvent1(event, {tgt}, OP_ADD, {param1})', terms = 1, inteditor = true, fullrange = true, literal = true, nixnote = true }
local actionOperationMinus = { notation = '-', label = 'Subtract', text = 'OperateEvent1(event, {tgt}, OP_SUB, {param1})', terms = 1, inteditor = true, fullrange = true, literal = true, nixnote = true }
local actionOperationMult = { notation = '*', label = 'Multiply', text = 'OperateEvent1(event, {tgt}, OP_MULT, {param1})', terms = 1, floateditor = true, norange = true, literal = true, nixnote = true }
local actionOperationDivide = { notation = '/', label = 'Divide By', text = 'OperateEvent1(event, {tgt}, OP_DIV, {param1})', terms = 1, floateditor = true, norange = true, literal = true, nixnote = true }
local actionOperationRound = { notation = ':round', label = 'Round By', text = 'QuantizeTo(event, {tgt}, {param1})', terms = 1, inteditor = true, literal = true }
local actionOperationClamp = { notation = ':clamp', label = 'Clamp Between', text = 'ClampValue(event, {tgt}, {param1}, {param2})', terms = 2, inteditor = true }
local actionOperationRandom = { notation = ':random', label = 'Random Values Btw', text = 'RandomValue(event, {tgt}, {param1}, {param2})', terms = 2, inteditor = true }
local actionOperationRelRandom = { notation = ':relrandom', label = 'Relative Random Values Btw', text = 'OperateEvent1(event, {tgt}, OP_ADD, RandomValue(event, nil, {param1}, {param2}))', terms = 2, inteditor = true, range = { -127, 127 }, fullrange = true, bipolar = true, literal = true, nixnote = true }
local actionOperationRelRandomSingle = { notation = ':relrandomsingle', label = 'Single Relative Random Value Btw', text = 'OperateEvent1(event, {tgt}, OP_ADD, RandomValue(event, nil, {param1}, {param2}, {randomsingle}))', terms = 2, inteditor = true, range = { -127, 127 }, fullrange = true, bipolar = true, literal = true, nixnote = true }
local actionOperationFixed = { notation = '=', label = 'Set to Fixed Value', text = 'OperateEvent1(event, {tgt}, OP_FIXED, {param1})', terms = 1 }
local actionOperationLine = { notation = ':line', label = 'Ramp in Selection Range', text = 'LinearChangeOverSelection(event, {tgt}, event.projtime, {param1}, {param2}, {param3}, _context)', terms = 3, split = {{ inteditor = true }, { menu = true }, { inteditor = true }}, freeterm = true, param3 = te.lineParam3Tab }
local actionOperationRelLine = { notation = ':relline', label = 'Relative Ramp in Selection Range', text = 'OperateEvent1(event, {tgt}, OP_ADD, LinearChangeOverSelection(event, nil, event.projtime, {param1}, {param2}, {param3}, _context))', terms = 3, split = {{ inteditor = true }, { menu = true }, { inteditor = true }}, freeterm = true, fullrange = true, bipolar = true, param3 = te.lineParam3Tab }
local actionOperationScaleOff = { notation = ':scaleoffset', label = 'Scale + Offset', text = 'OperateEvent2(event, {tgt}, OP_SCALEOFF, {param1}, {param2})', terms = 2, split = {{ floateditor = true, norange = true }, { inteditor = true, bipolar = true }}, freeterm = true, literal = true, nixnote = true }
local actionOperationMirror = { notation = ':mirror', label = 'Mirror', text = 'Mirror(event, {tgt}, {param1})', terms = 1 }

local function positionMod(op)
  local newop = tableCopy(op)
  newop.menu = false
  newop.inteditor = false
  newop.floateditor = false
  newop.timedur = false
  newop.time = true
  newop.range = nil
  return newop
end

local function lengthMod(op)
  local newop = tableCopy(op)
  newop.menu = false
  newop.inteditor = false
  newop.floateditor = false
  newop.time = false
  newop.timedur = true
  newop.range = nil
  return newop
end

local actionPositionOperationEntries = {
  { notation = '+', label = 'Add', text = 'AddDuration(event, {tgt}, \'{param1}\', event.projtime, _context)', terms = 1, timedur = true, timearg = true },
  { notation = '-', label = 'Subtract', text = 'SubtractDuration(event, {tgt}, \'{param1}\', event.projtime, _context)', terms = 1, timedur = true, timearg = true },
  { notation = '*', label = 'Multiply (rel.)', text = 'MultiplyPosition(event, {tgt}, {param1}, {param2}, nil, _context)', terms = 2, split = {{ floateditor = true }, { menu = true }}, norange = true, literal = true },
  { notation = '/', label = 'Divide (rel.)', text = 'MultiplyPosition(event, {tgt}, {param1} ~= 0 and (1 / {param1}) or 0, {param2}, nil, _context)', terms = 2, split = {{ floateditor = true }, { menu = true }}, norange = true, literal = true },
  lengthMod(actionOperationRound),
  { notation = ':roundmusical', label = 'Quantize to Musical Value', text = 'QuantizeMusicalPosition(event, take, PPQ, {musicalparams})', terms = 2, split = {{ musical = true, showswing = true }, { floateditor = true, default = 100, percent = true }} },
  positionMod(actionOperationFixed),
  positionMod(actionOperationRandom), lengthMod(actionOperationRelRandom), lengthMod(actionOperationRelRandomSingle),
  { notation = ':tocursor', label = 'Move to Cursor', text = 'MoveToCursor(event, {tgt}, {param1})', terms = 1, menu = true },
  { notation = ':addlength', label = 'Add Length', text = 'AddLength(event, {tgt}, {param1}, _context)', terms = 1, menu = true },
  { notation = ':scaleoffset', label = 'Scale + Offset (rel.)', text = 'MultiplyPosition(event, {tgt}, {param1}, {param2}, \'{param3}\', _context)', terms = 3, split = {{}, { menu = true }, {}}, param3 = te.positionScaleOffsetParam3Tab },
  { notation = ':toitemstart', label = 'Move to Item Start', text = 'MoveToItemPos(event, {tgt}, 0, \'{param1}\', _context)', terms = 1, timedur = true, timearg = true },
  { notation = ':toitemend', label = 'Move to Item End', text = 'MoveToItemPos(event, {tgt}, 1, \'{param1}\', _context)', terms = 1, timedur = true, timearg = true },
}

local actionPositionMultParam2Menu = {
  { notation = '$itemrel', label = 'Item-Relative', text = 'nil'},
  { notation = '$firstrel', label = 'First-Event-Relative', text = '1'},
}

local actionLengthOperationEntries = {
  { notation = '+', label = 'Add', text = 'AddDuration(event, {tgt}, \'{param1}\', event.projlen, _context)', terms = 1, timedur = true, timearg = true },
  { notation = '-', label = 'Subtract', text = 'SubtractDuration(event, {tgt}, \'{param1}\', event.projlen, _context)', terms = 1, timedur = true, timearg = true },
  actionOperationMult, actionOperationDivide,
  lengthMod(actionOperationRound),
  { notation = ':roundlenmusical', label = 'Quantize Length to Musical Value', text = 'QuantizeMusicalLength(event, take, PPQ, {musicalparams})', terms = 2, split = {{ musical = true }, { floateditor = true, default = 100, percent = true }} },
  { notation = ':roundendmusical', label = 'Quantize Note-Off to Musical Value', text = 'QuantizeMusicalEndPos(event, take, PPQ, {musicalparams})', terms = 2, split = {{ musical = true, showswing = true }, { floateditor = true, default = 100, percent = true }} },
  lengthMod(actionOperationFixed),
  { notation = ':quantmusical', label = 'Set to Musical Length', text = 'SetMusicalLength(event, take, PPQ, {musicalparams})', terms = 1, musical = true },
  lengthMod(actionOperationRandom), lengthMod(actionOperationRelRandom), lengthMod(actionOperationRelRandomSingle),
  { notation = ':tocursor', label = 'Move to Cursor', text = 'MoveLengthToCursor(event, {tgt})', terms = 0 },
  { notation = ':scaleoffset', label = 'Scale + Offset', text = 'OperateEvent2(event, {tgt}, OP_SCALEOFF, {param1}, TimeFormatToSeconds(\'{param2}\', event.projtime, _context, true))', terms = 2, split = {{ floateditor = true, default = 1. }, { timedur = true }}, range = {}, timearg = true },
  { notation = ':toitemend', label = 'Extend to Item End', text = 'MoveToItemPos(event, {tgt}, 2, \'{param1}\', _context)', terms = 1, timedur = true, timearg = true },
}

local function channelMod(op)
  local newop = tableCopy(op)
  newop.literal = true
  newop.range = newop.bipolar and { -15, 15 } or { 0, 15 }
  return newop
end

local actionChannelOperationEntries = {
  channelMod(actionOperationPlus), channelMod(actionOperationMinus),
  actionOperationFixed,
  channelMod(actionOperationRandom), channelMod(actionOperationRelRandom), channelMod(actionOperationRelRandomSingle),
  channelMod(actionOperationLine), channelMod(actionOperationRelLine)
}

local actionTypeOperationEntries = {
  actionOperationFixed
}

local actionPropertyOperationEntries = {
  actionOperationFixed,
  { notation = ':addprop', label = 'Add Property', text = 'event.flags = event.flags | {param1}', terms = 1, menu = true },
  { notation = ':removeprop', label = 'Remove Property', text = 'event.flags = event.flags & ~({param1})', terms = 1, menu = true },
  { notation = ':ccsetcurve', label = 'Set CC Curve', text = 'CCSetCurve(take, event, {param1}, {param2})', terms = 2, split = {{ menu = true }, { floateditor = true, range = { -1, 1 }, default = 0, rangelabel = 'bezier' }}, freeterm = true, nooverride = true },
}

local actionPropertyParam1Entries = {
  { notation = '0', label = 'Clear', text = '0' },
  { notation = '1', label = 'Selected', text = '1' },
  { notation = '2', label = 'Muted', text = '2' },
  { notation = '3', label = 'Selected + Muted', text = '3' },
}

local actionPropertyAddRemParam1Entries = {
  { notation = '1', label = 'Selected', text = '1' },
  { notation = '2', label = 'Muted', text = '2' },
  { notation = '3', label = 'Selected + Muted', text = '3' },
}

local actionMoveToCursorParam1Entries = {
  { notation = '$alltakes', label = 'Relative Across All Takes', text = '0'},
  { notation = '$singletake', label = 'Take-Independent', text = '1'}
}

local actionAddLengthParam1Entries = {
  { notation = '$alltakes', label = 'Relative Across All Takes', text = '0'},
  { notation = '$singletake', label = 'Relative To First Note In Take', text = '1'},
  { notation = '$selection', label = 'Entire Selection In Take', text = '3'},
  { notation = '$note', label = 'Per Note', text = '2'},
}


local actionLineParam2Entries = te.param3LineEntries
-- {
--   { notation = '$lin', label = 'Linear', text = '0' },
--   { notation = '$exp', label = 'Exponential', text = '1' },
--   { notation = '$log', label = 'Logarithmic', text = '2' },
--   { notation = '$scurve', label = 'S-Curve', text = '3' }, -- needs tuning
-- }

local actionSubtypeOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationClamp, actionOperationRandom, actionOperationRelRandom, actionOperationRelRandomSingle,
  { notation = ':getvalue2', label = 'Use Value 2', text = 'OperateEvent1(event, {tgt}, OP_FIXED, GetMainValue(event))', terms = 0 }, -- note that this is different for AT and PB
  actionOperationMirror, actionOperationLine, actionOperationRelLine, actionOperationScaleOff
}

local actionVelocityOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationClamp, actionOperationRandom, actionOperationRelRandom, actionOperationRelRandomSingle,
  { notation = ':getvalue1', label = 'Use Value 1', text = 'OperateEvent1(event, {tgt}, OP_FIXED, GetSubtypeValue(event))', terms = 0 }, -- ?? note that this is different for AT and PB
  actionOperationMirror, actionOperationLine, actionOperationRelLine, actionOperationScaleOff
}

local actionNewEventOperationEntries = {
  { notation = ':newmidievent', label = 'Create New Event', text = 'CreateNewMIDIEvent()', terms = 2, newevent = true }
}

local NEWEVENT_POSITION_ATCURSOR = 1
-- local NEWEVENT_POSITION_RELCURSOR = 2
local NEWEVENT_POSITION_ITEMSTART = 2
local NEWEVENT_POSITION_ITEMEND = 3
local NEWEVENT_POSITION_ATPOSITION = 4

local newMIDIEventPositionEntries = {
  { notation = '$atcursor', label = 'At Edit Cursor', text = '1' },
  -- { notation = '$relcursor', label = 'Rel. Edit Cursor:', text = '2' },
  { notation = '$itemstart', label = 'Item Start', text = '2' },
  { notation = '$itemend', label = 'Item End', text = '3' },
  { notation = '$atposition', label = 'At Position', text = '4' },
}

local actionGenericOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationRandom, actionOperationRelRandom, actionOperationRelRandomSingle,
  actionOperationMirror, actionOperationLine, actionOperationRelLine, actionOperationScaleOff
}

local PARAM_TYPE_UNKNOWN = 0
local PARAM_TYPE_MENU = 1
local PARAM_TYPE_INTEDITOR = 2
local PARAM_TYPE_FLOATEDITOR = 3
local PARAM_TYPE_TIME = 4
local PARAM_TYPE_TIMEDUR = 5
local PARAM_TYPE_METRICGRID = 6
local PARAM_TYPE_MUSICAL = 7
local PARAM_TYPE_EVERYN = 8
local PARAM_TYPE_NEWMIDIEVENT = 9
local PARAM_TYPE_PARAM3 = 10
local PARAM_TYPE_EVENTSELECTOR = 11
local PARAM_TYPE_HIDDEN = 12

local EDITOR_TYPE_PITCHBEND = 100
local EDITOR_TYPE_PITCHBEND_BIPOLAR = 101
local EDITOR_TYPE_PERCENT = 102
local EDITOR_TYPE_PERCENT_BIPOLAR = 103
local EDITOR_TYPE_7BIT = 104
local EDITOR_TYPE_7BIT_NOZERO = 105
local EDITOR_TYPE_7BIT_BIPOLAR = 106
local EDITOR_TYPE_14BIT = 107
local EDITOR_TYPE_14BIT_BIPOLAR = 108
local EDITOR_TYPE_BITFIELD = 109

local MG_GRID_STRAIGHT = 0
local MG_GRID_DOTTED = 1
local MG_GRID_TRIPLET = 2
local MG_GRID_SWING = 3
local MG_GRID_SWING_REAPER = 0x8

-----------------------------------------------------------------------------
----------------------------- OPERATION FUNS --------------------------------

function GetValue(event, property, bipolar)
  if not property then return 0 end
  local is14bit = false
  if property == 'msg2' and event.chanmsg == 0xE0 then is14bit = true end
  local oldval = is14bit and ((event.msg3 << 7) + event.msg2) or event[property]
  if is14bit and bipolar then oldval = (oldval - (1 << 13)) end
  return oldval
end

function TestEvent1(event, property, op, param1)
  local val = GetValue(event, property)
  local retval = false

  if op == OP_EQ then
    retval = val == param1
  elseif op == OP_GT then
    retval = val > param1
  elseif op == OP_GTE then
    retval = val >= param1
  elseif op == OP_LT then
    retval = val < param1
  elseif op == OP_LTE then
    retval = val <= param1
  elseif op == OP_EQ_NOTE then
    retval = (GetEventType(event) == NOTE_TYPE) and (val % 12 == param1)
  end
  return retval
end

function EventIsSimilar(event, property, val, param1, param2)
  for _, e in ipairs(selectedEvents) do
    if e.chanmsg == event.chanmsg then -- a little hacky here
      local check = true
      if e.chanmsg == 0xB0 -- special case for real CC msgs, must match the CC#, as well
        and property ~= 'msg2'
        and e.msg2 ~= event.msg2
      then
        check = false
      end
      if check then
        local eval = GetValue(e, property)
        if val >= (eval - param1) and val <= (eval + param2) then
          return true
        end
      end
    end
  end
  return false
end

function TestEvent2(event, property, op, param1, param2)
  local val = GetValue(event, property)
  local retval = false

  if op == OP_INRANGE then
    retval = (val >= param1 and val <= param2)
  elseif op == OP_INRANGE_EXCL then
    retval = (val >= param1 and val < param2)
  elseif op == OP_EQ_SLOP then
    retval = (val >= (param1 - param2) and val <= (param1 + param2))
  elseif op == OP_SIMILAR then
    if EventIsSimilar(event, property, val, param1, param2) then return true end
  end
  return retval
end

function FindEveryN(event, evnParams)
  if not evnParams then return false end

  if evnParams.isBitField then return FindEveryNPattern(event, evnParams) end

  local param1 = evnParams.interval
  if not param1 or param1 <= 0 then return false end

  local count = event.count - 1
  count = count - (evnParams.offset and evnParams.offset or 0)
  return count % param1 == 0
end

function FindEveryNPattern(event, evnParams)
  if not (evnParams and evnParams.isBitField and evnParams.pattern) then return false end

  local patLen = #evnParams.pattern
  if patLen <= 0 then return false end

  local count = event.count - 1
  count = count - (evnParams.offset and evnParams.offset or 0)
  local index = (count % patLen) + 1

  if evnParams.pattern:sub(index, index) == '1' then
    return true
  end
  return false
end

function FindEveryNNote(event, evnParams, notenum)
  if GetEventType(event) ~= NOTE_TYPE then return false end
  if not evnParams then return false end

  if evnParams.isBitField then return FindEveryNNotePattern(event, evnParams, notenum) end

  local param1 = evnParams.interval
  if not param1 or param1 <= 0 then return false end

  local count = event.ncount - 1
  count = count - (evnParams.offset and evnParams.offset or 0)

  if count % param1 == 0 then
    if notenum >= 12 and event.msg2 == notenum then return true
    elseif notenum < 12 and event.msg2 % 12 == notenum then return true
    end
  end
  return false
end

function FindEveryNNotePattern(event, evnParams, notenum)
  if GetEventType(event) ~= NOTE_TYPE then return false end
  if not (evnParams and evnParams.isBitField and evnParams.pattern) then return false end

  local patLen = #evnParams.pattern
  if patLen <= 0 then return false end

  local param1 = evnParams.interval
  if not param1 or param1 <= 0 then return false end

  local count = event.ncount - 1
  count = count - (evnParams.offset and evnParams.offset or 0)
  local index = (count % patLen) + 1

  if evnParams.pattern:sub(index, index) == '1' then
    if notenum > 11 and event.msg2 == notenum then return true
    elseif notenum < 11 and event.msg2 % 12 == notenum then return true
    end
  end
  return false
end

local currentGrid = 0
local currentSwing = 0. -- -1. to 1

function GetGridUnitFromSubdiv(subdiv, PPQ, mgParams)
  local gridUnit
  local mgMods = GetMetricGridModifiers(mgParams)
  if subdiv >= 0 then
    gridUnit = PPQ * (subdiv * 4)
    if mgMods == MG_GRID_DOTTED then gridUnit = gridUnit * 1.5
    elseif mgMods == MG_GRID_TRIPLET then gridUnit = (gridUnit * 2 / 3) end
  else
    gridUnit = PPQ * currentGrid
  end
  return gridUnit
end

function EqualsMusicalLength(event, take, PPQ, mgParams)
  if not take then return false end

  if GetEventType(event) ~= NOTE_TYPE then return false end

  local subdiv = mgParams.param1
  local gridUnit = GetGridUnitFromSubdiv(subdiv, PPQ, mgParams)

  local preSlop = gridUnit * (mgParams.preSlopPercent / 100)
  local postSlop = gridUnit * (mgParams.postSlopPercent / 100)
  if postSlop == 0 then postSlop = 1 end

  local ppqlen = event.endppqpos - event.ppqpos
  return ppqlen >= gridUnit - preSlop and ppqlen <= gridUnit + postSlop
end

function SelectChordNote(event, chordNote)
  local wantsHigh, wantsLow, isString
  if type(chordNote) == 'string' then
    wantsHigh = chordNote == '$high'
    wantsLow = chordNote == '$low'
    isString = true
  end
  if wantsHigh then if event.chordTop then return true else return false end
  elseif wantsLow then if event.chordBottom then return true else return false end
  elseif isString then return false -- safety
  elseif event.chordIdx then
    if chordNote < 0 and event.chordIdx == event.chordCount + (chordNote + 1) then return true
    elseif event.chordIdx - 1 == chordNote then return true
    end
  end
  return false
end

function SetMusicalLength(event, take, PPQ, mgParams)
  if not take then return event.projlen end

  if GetEventType(event) ~= NOTE_TYPE then return event.projlen end

  local subdiv = mgParams.param1
  local gridUnit = GetGridUnitFromSubdiv(subdiv, PPQ, mgParams)

  local oldppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime)
  local newppqpos = oldppqpos + gridUnit
  local newprojpos = r.MIDI_GetProjTimeFromPPQPos(take, newppqpos)
  local newprojlen = newprojpos - event.projtime

  event.projlen = newprojlen
  return newprojlen
end

function QuantizeMusicalPosition(event, take, PPQ, mgParams)
  if not take then return event.projtime end

  local subdiv = mgParams.param1
  local strength = tonumber(mgParams.param2)

  local gridUnit = GetGridUnitFromSubdiv(subdiv, PPQ, mgParams)
  local useGridSwing = subdiv < 0 and currentSwing ~= 0

  if gridUnit == 0 then return event.projtime end

  local timeAdjust = GetTimeOffset()
  local oldppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime - timeAdjust)
  local som = r.MIDI_GetPPQPos_StartOfMeasure(take, oldppqpos)

  local ppqinmeasure = oldppqpos - som -- get the position from the start of the measure
  local newppqpos = som + (gridUnit * math.floor((ppqinmeasure / gridUnit) + 0.5))

  local mgMods, mgReaSwing = GetMetricGridModifiers(mgParams)

  if useGridSwing or (mgMods == MG_GRID_SWING and mgReaSwing) then
    local scale = useGridSwing and currentSwing or (mgParams.swing * 0.01)
    local half = gridUnit * 0.5
    local localpos = ppqinmeasure % (gridUnit * 2)
    if localpos >= gridUnit - half and localpos < gridUnit + half then
      newppqpos = newppqpos + (gridUnit * 0.5 * scale)
    end
  elseif mgMods == MG_GRID_SWING then
    local localpos = ppqinmeasure % (gridUnit * 2)
    if localpos >= gridUnit then
      local scale = ((mgParams.swing - 50) * 2) * 0.01 -- convert to -1. - 1. for scaling
      newppqpos = newppqpos + (gridUnit * scale)
    end
  end

  if strength and strength ~= 100 then
    local distance = newppqpos - oldppqpos
    local scaledDistance = distance * (strength / 100)
    newppqpos = oldppqpos + scaledDistance
  end
  local newprojpos = r.MIDI_GetProjTimeFromPPQPos(take, newppqpos) + timeAdjust

  event.projtime = newprojpos
  return newprojpos
end

function QuantizeMusicalLength(event, take, PPQ, mgParams)
  if not take then return event.projlen end

  local subdiv = mgParams.param1
  local strength = tonumber(mgParams.param2)

  local gridUnit = GetGridUnitFromSubdiv(subdiv, PPQ, mgParams)

  if gridUnit == 0 then return event.projtime end

  local timeAdjust = GetTimeOffset()
  local ppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime - timeAdjust)
  local endppqpos = r.MIDI_GetPPQPosFromProjTime(take, (event.projtime + event.projlen) - timeAdjust)
  local ppqlen = endppqpos - ppqpos

  local newppqlen = (gridUnit * math.floor((ppqlen / gridUnit) + 0.5))
  if newppqlen == 0 then newppqlen = gridUnit end

  if strength and strength ~= 100 then
    local distance = newppqlen - ppqlen
    local scaledDistance = distance * (strength / 100)
    newppqlen = ppqlen + scaledDistance
  end
  local newprojlen = (r.MIDI_GetProjTimeFromPPQPos(take, ppqpos + newppqlen) + timeAdjust) - event.projtime

  event.projlen = newprojlen
  return newprojlen
end

function QuantizeMusicalEndPos(event, take, PPQ, mgParams)
  if not take then return event.projlen end

  local subdiv = mgParams.param1
  local strength = tonumber(mgParams.param2)

  local gridUnit = GetGridUnitFromSubdiv(subdiv, PPQ, mgParams)
  local useGridSwing = subdiv < 0 and currentSwing ~= 0

  if gridUnit == 0 then return event.projtime end

  local timeAdjust = GetTimeOffset()
  local ppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime - timeAdjust)
  local endppqpos = r.MIDI_GetPPQPosFromProjTime(take, (event.projtime + event.projlen) - timeAdjust)
  local ppqlen = endppqpos - ppqpos

  local som = r.MIDI_GetPPQPos_StartOfMeasure(take, endppqpos)

  local ppqinmeasure = endppqpos - som -- get the position from the start of the measure

  local quant = (gridUnit * math.floor((ppqinmeasure / gridUnit) + 0.5))
  local newendppqpos = som + quant
  local newppqlen = newendppqpos - ppqpos
  if newppqlen < ppqlen * 0.5 then
    newendppqpos = som + quant + gridUnit
    newppqlen = newendppqpos - ppqpos
  end

  local mgMods, mgReaSwing = GetMetricGridModifiers(mgParams)

  if useGridSwing or (mgMods == MG_GRID_SWING and mgReaSwing) then
    local scale = useGridSwing and currentSwing or (mgParams.swing * 0.01)
    local half = gridUnit * 0.5
    local localpos = ppqinmeasure % (gridUnit * 2)
    if localpos >= gridUnit - half and localpos < gridUnit + half then
      newendppqpos = newendppqpos + (gridUnit * 0.5 * scale)
      newppqlen = newendppqpos - ppqpos
    end
  elseif mgMods == MG_GRID_SWING then
    local localpos = ppqinmeasure % (gridUnit * 2)
    if localpos >= gridUnit then
      local scale = ((mgParams.swing - 50) * 2) * 0.01 -- convert to -1. - 1. for scaling
      newendppqpos = newendppqpos + (gridUnit * scale)
      newppqlen = newendppqpos - ppqpos
    end
  end

  if strength and strength ~= 100 then
    local distance = newppqlen - ppqlen
    local scaledDistance = distance * (strength / 100)
    newppqlen = ppqlen + scaledDistance
  end
  local newprojlen = (r.MIDI_GetProjTimeFromPPQPos(take, ppqpos + newppqlen) + timeAdjust) - event.projtime

  event.projlen = newprojlen
  return newprojlen
end

function CursorPosition(event, property, cursorPosProj, which)
  local time = event[property]

  if which == CURSOR_LT then -- before
    return time < cursorPosProj
  elseif which == CURSOR_GT then -- after
    return time > cursorPosProj
  elseif which == CURSOR_AT then -- at
    return time == cursorPosProj
  elseif which == CURSOR_LTE then -- before/at
    return time <= cursorPosProj
  elseif which == CURSOR_GTE then -- after/at
    return time >= cursorPosProj
  elseif which == CURSOR_UNDER then
    if GetEventType(event) == NOTE_TYPE then
      local endtime = time + event.projlen
      return cursorPosProj >= time and cursorPosProj < endtime
    else
      return time == cursorPosProj
    end
  end
  return false
end

function UnderEditCursor(event, take, PPQ, cursorPosProj, param1, param2)
  local gridUnit = GetGridUnitFromSubdiv(param1, PPQ)
  local PPQPercent = gridUnit + (gridUnit * (param2 / 100))
  local cursorPPQPos = r.MIDI_GetPPQPosFromProjTime(take, cursorPosProj)
  local minRange = cursorPPQPos - PPQPercent
  local maxRange = cursorPPQPos + PPQPercent

  local time = event.ppqpos
  if time >= minRange and time < maxRange then return true end
  if GetEventType(event) == NOTE_TYPE then
    local endtime = event.endppqpos
    if time <= minRange and endtime > minRange then return true end
  end
  return false
end

function GetTimeSelectionStart()
  local ts_start, ts_end = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  return ts_start + GetTimeOffset()
end

function GetTimeSelectionEnd()
  local ts_start, ts_end = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  return ts_end + GetTimeOffset()
end

function CCHasCurve(take, event, ctype)
  if event.chanmsg < 0xA0 or event.chanmsg >= 0xF0 then return false end
  local rv, curveType = mu.MIDI_GetCCShape(take, event.idx)
  return rv and curveType == ctype
end

function CCSetCurve(take, event, ctype, bzext)
  if event.chanmsg < 0xA0 or event.chanmsg >= 0xF0 then return false end
  ctype = ctype < CC_CURVE_SQUARE and CC_CURVE_SQUARE or ctype > CC_CURVE_BEZIER and CC_CURVE_BEZIER or ctype
  event.setcurve = ctype
  event.setcurveext = ctype == CC_CURVE_BEZIER and bzext or 0
  return ctype
end

function ChanMsgToType(chanmsg)
  if chanmsg == 0x90 then return NOTE_TYPE
  elseif chanmsg == 0xF0 or chanmsg == 0x100 then return SYXTEXT_TYPE
  elseif chanmsg >= 0xA0 and chanmsg <= 0xEF then return CC_TYPE
  else return OTHER_TYPE
  end
end

function GetEventType(event)
  return ChanMsgToType(event.chanmsg)
end

function GetSubtypeValue(event)
  if GetEventType(event) == SYXTEXT_TYPE then return 0
  else return event.msg2 / 127
  end
end

function GetSubtypeValueName(event)
  if GetEventType(event) == SYXTEXT_TYPE then return 'devnull'
  else return 'msg2'
  end
end

function GetSubtypeValueLabel(typeIndex)
  if typeIndex == 1 then return 'Note #'
  elseif typeIndex == 2 then return 'Note #'
  elseif typeIndex == 3 then return 'CC #'
  elseif typeIndex == 4 then return 'Pgm #'
  elseif typeIndex == 5 then return 'Pressure Amount'
  elseif typeIndex == 6 then return 'PBnd'
  else return ''
  end
end

function GetMainValue(event)
  if event.chanmsg == 0xC0 or event.chanmsg == 0xD0 or event.chanmsg == 0xE0 then return 0
  elseif GetEventType(event) == SYXTEXT_TYPE then return 0
  else return event.msg3 / 127
  end
end

function GetMainValueName(event)
  if event.chanmsg == 0xC0 or event.chanmsg == 0xD0 or event.chanmsg == 0xE0 then return 'msg2'
  elseif GetEventType(event) == SYXTEXT_TYPE then return 'devnull'
  else return 'msg3'
  end
end

function GetMainValueLabel(typeIndex)
  if typeIndex == 1 then return 'Velocity'
  elseif typeIndex == 2 then return 'Pressure Amount'
  elseif typeIndex == 3 then return 'CC Value'
  elseif typeIndex == 4 then return 'Pgm # (aliased Value 1)'
  elseif typeIndex == 5 then return 'Channel Pressure Amount (aliased Value 1)'
  elseif typeIndex == 6 then return 'PBnd (aliased Value 1)'
  else return ''
  end
end

function GetTimeOffset(correctMeasures)
  local offset = r.GetProjectTimeOffset(0, false)
  if correctMeasures then
    local rv, measoff = r.get_config_var_string('projmeasoffs')
    if rv then
      local mo = tonumber(measoff)
      if mo then
        local qn1, qn2
        rv, qn1 = r.TimeMap_GetMeasureInfo(0, measoff)
        rv, qn2 = r.TimeMap_GetMeasureInfo(0, -1) -- 0 in the prefs interface is -1, go figure
        if qn1 and qn2 then
          local time1 = r.TimeMap2_QNToTime(0, qn1)
          local time2 = r.TimeMap2_QNToTime(0, qn2)
          offset = offset + (time2 - time1)
        end
      end
    end
  end
  return offset
end

function OnGrid(event, property, take, PPQ)
  if not take then return false end

  local grid, swing = currentGrid, currentSwing -- 1.0 is QN, 1.5 dotted, etc.
  local timeAdjust = GetTimeOffset()
  local ppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime - timeAdjust)
  local measppq = r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)
  local gridUnit = grid * PPQ
  local subMeas = math.floor((gridUnit * 2) + 0.5)
  local swingUnit = swing and math.floor((gridUnit + (swing * gridUnit * 0.5)) + 0.5) or nil

  local testppq = (ppqpos - measppq) % subMeas
  if testppq == 0 or (swingUnit and testppq % swingUnit == 0) then
    return true
  end
  return false
end

function InBarRange(take, PPQ, ppqpos, rangeStart, rangeEnd)
  if not take then return false end

  local tpos = r.MIDI_GetProjTimeFromPPQPos(take, ppqpos) + GetTimeOffset()
  local _, _, cml, _, cdenom = r.TimeMap2_timeToBeats(0, tpos)
  local beatPPQ = (4 / cdenom) * PPQ
  local measurePPQ = beatPPQ * cml

  local som = r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)
  local barpos = (ppqpos - som) / measurePPQ

  return barpos >= (rangeStart / 100) and barpos <= (rangeEnd / 100)
end

function InRazorArea(event, take)
  if not take then return false end

  local track = r.GetMediaItemTake_Track(take)
  if not track then return false end

  local item = r.GetMediaItemTake_Item(take)
  if not item then return false end

  local freemode = r.GetMediaTrackInfo_Value(track, 'I_FREEMODE')
  local itemTop = freemode ~= 0 and r.GetMediaItemInfo_Value(item, 'F_FREEMODE_Y') or nil
  local itemBottom = freemode ~= 0 and (itemTop + r.GetMediaItemInfo_Value(item, 'F_FREEMODE_H')) or nil

  local timeAdjust = GetTimeOffset()

  local ret, area = r.GetSetMediaTrackInfo_String(track, 'P_RAZOREDITS_EXT', '', false)
  if area ~= '' then
    local razors = {}
    for word in string.gmatch(area, '([^,]+)') do
      local terms = {}
      table.insert(razors, terms)
      for str in string.gmatch(word, '%S+') do
        table.insert(terms, str)
      end
    end

    for _, v in ipairs(razors) do
      local ct = #v
      local areaStart, areaEnd, areaTop, areaBottom
      if ct >= 3 then
        areaStart = tonumber(v[1]) + timeAdjust
        areaEnd = tonumber(v[2]) + timeAdjust
        if ct >= 5 and freemode ~= 0 then
          areaTop = tonumber(v[4])
          areaBottom = tonumber(v[5])
        end
        if event.projtime >= areaStart and event.projtime < areaEnd then
          if freemode ~= 0 and areaTop and areaBottom then
            if itemTop >= areaTop and itemBottom <= areaBottom then
              return true
            end
          else
            return true
          end
        end
      end
    end
  end
  return false
end

function IsNearEvent(event, take, PPQ, evSelParams, param2)
  local scale = tonumber(evSelParams.scaleStr)
  local gridUnit = GetGridUnitFromSubdiv(param2, PPQ)
  local PPQPercent = gridUnit + (gridUnit * (scale / 100))
  local minRange = event.ppqpos - PPQPercent
  local maxRange = event.ppqpos + PPQPercent

  for k, ev in ipairs(allEvents) do
    local sameEvent = false
    local ppqMatch = false
    local typeMatch = false
    local selMatch = false
    local muteMatch = false

    if ev.chanmsg == event.chanmsg
      and ev.idx == event.idx
    then
      sameEvent = true
    end

    if not sameEvent then
      if ev.ppqpos >= minRange
        and ev.ppqpos < maxRange
      then
        ppqMatch = true -- can we bail early once we're outside of a certain range?
      end
    end

    if ppqMatch then
      if evSelParams.chanmsg == 0x00
        or ev.chanmsg == evSelParams.chanmsg
      then
        typeMatch = true
      end
    end

    if typeMatch then
      if evSelParams.selected == -1
        or evSelParams.selected == 0 and not ev.selected
        or evSelParams.selected == 1 and ev.selected
      then
        selMatch = true
      end
    end

    if selMatch then
      if evSelParams.muted == -1
        or evSelParams.muted == 0 and not ev.muted
        or evSelParams.muted == 1 and ev.muted
      then
        muteMatch = true
      end
    end

    if muteMatch then
      if not evSelParams.useval1
        or ev.msg2 == evSelParams.msg2
      then
        return true
      end
    end
  end
  return false
end

function OnMetricGrid(take, PPQ, ppqpos, mgParams)
  if not take then return false end

  local subdiv = mgParams.param1
  local gridStr = mgParams.param2

  local gridLen = #gridStr
  local gridUnit = GetGridUnitFromSubdiv(subdiv, PPQ, mgParams)

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
  if wrapped ~= CACHED_WRAPPED then
    CACHED_WRAPPED = wrapped
    CACHED_METRIC = nil
  end
  local modPos = math.fmod(ppqpos, cycleLength)

  -- CACHED_METRIC is used to avoid iterating from the beginning each time
  -- although it assumes a single metric grid -- how to solve?

  local iter = 0
  while iter < 2 do
    local doRestart = false
    for i = (CACHED_METRIC and iter == 0) and CACHED_METRIC or 1, gridLen do
      local c = gridStr:sub(i, i)
      local trueStartRange = (gridUnit * (i - 1))
      local startRange = trueStartRange - preSlop
      local endRange = trueStartRange + postSlop
      local mod2 = modPos

      if modPos > cycleLength - preSlop then
        mod2 = modPos - cycleLength
        doRestart = true
      end

      if mod2 >= startRange and mod2 <= endRange then
        CACHED_METRIC = i
        return c ~= '0' and true or false
      end
    end
    iter = iter + 1
    if not doRestart then break end
  end
  return false
end

function InScale(event, scale, root)
  if GetEventType(event) ~= NOTE_TYPE then return false end

  local note = event.msg2 % 12
  note = note - root
  if note < 0 then note = note + 12 end
  for _, v in ipairs(scale) do
    if note == v then return true end
  end
  return false
end

-----------------------------------------------------------------------------
----------------------------- OPERATION FUNS --------------------------------

function SetValue(event, property, newval, bipolar)
  if not property then return newval end

  if property == 'chanmsg' then
    local oldtype = GetEventType(event)
    local newtype = ChanMsgToType(newval)
    if oldtype ~= newtype then
      if event.orig_type then
        if newval == event.orig_type then event.orig_type = nil end -- if multiple steps change and then unchange the type (edge case)
      else
        event.orig_type = oldtype -- will be compared against chanmsg before writing and Delete+New as necessary
      end
    end
  end

  local is14bit = false
  if property == 'msg2' and event.chanmsg == 0xE0 then is14bit = true end
  if is14bit then
    if bipolar then newval = newval + (1 << 13) end
    newval = newval < 0 and 0 or newval > ((1 << 14) - 1) and ((1 << 14) - 1) or newval
    newval = math.floor(newval + 0.5)
    event.msg2 = newval & 0x7F
    event.msg3 = (newval >> 7) & 0x7F
  else
    event[property] = newval
  end
  return newval
end

function OperateEvent1(event, property, op, param1)
  local bipolar = (op == OP_MULT or op == OP_DIV) and true or false
  local oldval = GetValue(event, property, bipolar)
  local newval = oldval

  if op == OP_ADD then
    newval = oldval + param1
  elseif op == OP_SUB then
    newval = oldval - param1
  elseif op == OP_MULT then
    newval = oldval * param1
  elseif op == OP_DIV then
    newval = param1 ~= 0 and (oldval / param1) or 0
  elseif op == OP_FIXED then
    newval = param1
  end
  return SetValue(event, property, newval, bipolar)
end

function OperateEvent2(event, property, op, param1, param2)
  local oldval = GetValue(event, property)
  local newval = oldval
  if op == OP_SCALEOFF then
    newval = (oldval * param1) + param2
  end
  return SetValue(event, property, newval)
end

-- TODO there might be multiple lines, each of which can only be processed ONCE
-- how to do this? could filter these lines out and then run the nme events separately from the rows
function CreateNewMIDIEvent()
end

function RandomValue(event, property, min, max, single)
  local oldval = GetValue(event, property)
  if event.firstlastevent then return oldval end

  local newval = oldval

  local rnd = single and single or math.random()

  newval = (rnd * (max - min)) + min
  if math.type(min) == 'integer' and math.type(max) == 'integer' then newval = math.floor(newval) end
  return SetValue(event, property, newval)
end

function ClampValue(event, property, low, high)
  local oldval = GetValue(event, property)
  local newval = oldval < low and low or oldval > high and high or oldval
  return SetValue(event, property, newval)
end

function QuantizeTo(event, property, quant)
  local oldval = GetValue(event, property)
  if quant == 0 then return oldval end
  local newval = quant * math.floor((oldval / quant) + 0.5)
  return SetValue(event, property, newval)
end

function Mirror(event, property, mirrorVal)
  local oldval = GetValue(event, property)
  local newval = mirrorVal - (oldval - mirrorVal)
  return SetValue(event, property, newval)
end

function LinearChangeOverSelection(event, property, projTime, p1, type, p2, mult, context)
  local firstTime = context.firstTime
  local lastTime = context.lastTime

  if firstTime ~= lastTime and projTime >= firstTime and projTime <= lastTime then
    local linearPos = (projTime - firstTime) / (lastTime - firstTime)
    local newval = projTime
    local scalePos = linearPos
    if type == 0 then
      -- done
    elseif type == 1 then -- exp
      scalePos = linearPos ^ mult
    elseif type == 2 then -- log
      local e3 = 2.718281828459045 ^ mult
      local ePos = (linearPos * (e3 - 1)) + 1 -- scale from 1 - e
      scalePos = math.log(ePos, e3)
    elseif type == 3 then -- s
      mult = mult <= -1 and -0.999999 or mult >= 1 and 0.999999 or mult
      scalePos = ((mult - 1) * ((2 * linearPos) - 1)) / (2 * ((4 * mult) * math.abs(linearPos - 0.5) - mult - 1)) + 0.5
    end
    newval = ((p2 - p1) * scalePos) + p1
    return SetValue(event, property, newval)
  end
  return SetValue(event, property, 0)
end

local addLengthFirstEventOffset
local addLengthFirstEventOffset_Take
local addLengthFirstEventStartTime

function AddLength(event, property, mode, context)
  if GetEventType(event) ~= NOTE_TYPE then return event.projtime end

  if mode == 3 then
    local lastNoteEnd = context.lastNoteEnd
    if not addLengthFirstEventStartTime then addLengthFirstEventStartTime = event.projtime end
    if not lastNoteEnd then lastNoteEnd = 0 end
    event.projtime = event.projtime + lastNoteEnd - addLengthFirstEventStartTime
    return event.projtime + lastNoteEnd
  elseif mode == 2 then
    event.projtime = event.projtime + event.projlen
    return event.projtime + event.projlen
  elseif mode == 1 then
    if not addLengthFirstEventOffset_Take then addLengthFirstEventOffset_Take = event.projlen end
    event.projtime = event.projtime + addLengthFirstEventOffset_Take
    return event.projtime + addLengthFirstEventOffset_Take
  end
  if not addLengthFirstEventOffset then addLengthFirstEventOffset = event.projlen end
  event.projtime = event.projtime + addLengthFirstEventOffset
  return event.projtime
end

local moveCursorFirstEventPosition
local moveCursorFirstEventPosition_Take

function MoveToCursor(event, property, mode)
  if mode == 1 then -- independent
    if not moveCursorFirstEventPosition_Take then moveCursorFirstEventPosition_Take = event.projtime end
    event.projtime = (event.projtime - moveCursorFirstEventPosition_Take) + r.GetCursorPositionEx(0) + GetTimeOffset()
    return event.projtime
  end
  if not moveCursorFirstEventPosition then moveCursorFirstEventPosition = event.projtime end
  event.projtime = (event.projtime - moveCursorFirstEventPosition) + r.GetCursorPositionEx(0) + GetTimeOffset()
  return event.projtime
end

-- need to think about this
-- function MoveNoteOffToCursor(event, mode)
--   if GetEventType(event) ~= NOTE_TYPE then return event.projlen end

--   if mode == 1 then -- independent
--     if not moveCursorFirstEventLength_Take then moveCursorFirstEventLength_Take = event.projtime end
--     return (event.projtime - moveCursorFirstEventLength_Take) + r.GetCursorPositionEx(0) + GetTimeOffset()
--   else
--     if not moveCursorFirstEventLength then moveCursorFirstEventLength = event.projtime end
--     return (event.projtime - moveCursorFirstEventLength) + r.GetCursorPositionEx(0) + GetTimeOffset()
--   end
-- end

function MoveLengthToCursor(event)
  if GetEventType(event) ~= NOTE_TYPE then return event.projlen end

  local cursorPos = r.GetCursorPositionEx(0) + GetTimeOffset()

  if event.projtime >= cursorPos then return event.projlen end

  event.projlen = cursorPos - event.projtime
  return event.projlen
end

function MoveToItemPos(event, property, way, offset, context)
  local take = context.take
  if not take then return event[property] end

  if GetEventType(event) ~= NOTE_TYPE and way == 2 then return event[property] end
  local item = r.GetMediaItemTake_Item(take)
  if item then
    if way == 0 then
      local targetPos = r.GetMediaItemInfo_Value(item, 'D_POSITION') + GetTimeOffset()
      local offsetTime = offset and LengthFormatToSeconds(offset, targetPos, context) or 0
      event[property] = targetPos + offsetTime
    elseif way == 1 or way == 2 then
      local targetPos = r.GetMediaItemInfo_Value(item, 'D_POSITION') + GetTimeOffset() + r.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local offsetTime = offset and LengthFormatToSeconds(offset, targetPos, context) or 0
      event[property] = way == 1 and (targetPos + offsetTime) or ((targetPos - event.projtime) + offsetTime)
    end
  end
  return event[property]
end

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

-- function SysexStringToBytes(input)
--   local result = {}
--   local currentByte = 0
--   local nibbleCount = 0
--   local count = 0

--   for hex in input:gmatch('%x+') do
--     for nibble in hex:gmatch('%x') do
--       currentByte = currentByte * 16 + tonumber(nibble, 16)
--       nibbleCount = nibbleCount + 1

--       if nibbleCount == 2 then
--         if count == 0 and currentByte == 0xF0 then
--         elseif currentByte == 0xF7 then
--           return table.concat(result)
--         else
--           table.insert(result, string.char(currentByte))
--         end
--         currentByte = 0
--         nibbleCount = 0
--       elseif nibbleCount == 1 and #hex == 1 then
--         -- Handle a single nibble in the middle of the string
--         table.insert(result, string.char(currentByte))
--         currentByte = 0
--         nibbleCount = 0
--       end
--     end
--   end

--   if nibbleCount == 1 then
--     -- Handle a single trailing nibble
--     currentByte = currentByte * 16
--     table.insert(result, string.char(currentByte))
--   end

--   return table.concat(result)
-- end

-- function SysexBytesToString(bytes)
--   local str = ''
--   for i = 1, string.len(bytes) do
--     str = str .. string.format('%02X', tonumber(string.byte(bytes, i)))
--     if i ~= string.len(bytes) then str = str .. ' ' end
--   end
--   return str
-- end

-- function NotationStringToString(notStr)
--   local a, b = string.find(notStr, 'TRAC ')
--   if a and b then return string.sub(notStr, b + 1) end
--   return notStr
-- end

-- function StringToNotationString(str)
--   local a, b = string.find(str, 'TRAC ')
--   if a and b then return str end
--   return 'TRAC ' .. str
-- end

-----------------------------------------------------------------------------
-------------------------------- THE GUTS -----------------------------------

---------------------------------------------------------------------------
--------------------------- BUNCH OF FUNCTIONS ----------------------------

-- function GetPPQ()
--   local qn1 = r.MIDI_GetProjQNFromPPQPos(take, 0)
--   local qn2 = qn1 + 1
--   return math.floor(r.MIDI_GetPPQPosFromProjQN(take, qn2) - r.MIDI_GetPPQPosFromProjQN(take, qn1))
-- end

-- function NeedsBBUConversion(name)
--   return wantsBBU and (name == 'ticks' or name == 'notedur' or name == 'selposticks' or name == 'seldurticks')
-- end

function BBTToPPQ(take, measures, beats, ticks, relativeppq, nosubtract)
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

  -- function PpqToLength(ppqpos, ppqlen)
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

function CalcMIDITime(take, e)
  local timeAdjust = GetTimeOffset()
  e.projtime = r.MIDI_GetProjTimeFromPPQPos(take, e.ppqpos) + timeAdjust
  if e.endppqpos then
    e.projlen = (r.MIDI_GetProjTimeFromPPQPos(take, e.endppqpos) + timeAdjust) - e.projtime
  else
    e.projlen = 0
  end
  e.measures, e.beats, e.beatsmax, e.ticks = PpqToTime(take, e.ppqpos, e.projtime)
end

---------------------------------------------------------------------------
--------------------------------- UTILITIES -------------------------------

function EnsureNumString(str, range)
  local num = tonumber(str)
  if not num then num = 0 end
  if range then
    if range[1] and num < range[1] then num = range[1] end
    if range[2] and num > range[2] then num = range[2] end
  end
  return tostring(num)
end

function TimeFormatClampPad(str, min, max, fmt, startVal)
  local num = tonumber(str)
  if not num then num = 0 end
  num = num + (startVal and startVal or 0)
  num = (min and num < min) and min or (max and num > max) and max or num
  return string.format(fmt, num), num
end

local TIME_FORMAT_UNKNOWN = 0
local TIME_FORMAT_MEASURES = 1
local TIME_FORMAT_MINUTES = 2
local TIME_FORMAT_HMSF = 3

function DetermineTimeFormatStringType(buf)
  if string.match(buf, '%d+') then
    local isMSF = false
    local isHMSF = false

    isHMSF = string.match(buf, '^%s-%d+:%d+:%d+:%d+')
    if isHMSF then return TIME_FORMAT_HMSF end

    isMSF = string.match(buf, '^%s-%d-:')
    if isMSF then return TIME_FORMAT_MINUTES end

    return TIME_FORMAT_MEASURES
  end
  return TIME_FORMAT_UNKNOWN
end

function LengthFormatRebuf(buf)
  local format = DetermineTimeFormatStringType(buf)
  if format == TIME_FORMAT_UNKNOWN then return DEFAULT_LENGTHFORMAT_STRING end

  local isneg = string.match(buf, '^%s*%-')

  if format == TIME_FORMAT_MEASURES then
    local absTicks = false
    local bars, beats, fraction, subfrac = string.match(buf, '(%d-)%.(%d+)%.(%d+)%.(%d+)')
    if not bars then
      bars, beats, fraction = string.match(buf, '(%d-)%.(%d+)%.(%d+)')
    end
    if not bars then
      bars, beats = string.match(buf, '(%d-)%.(%d+)')
    end
    if not bars then
      bars = string.match(buf, '(%d+)')
    end
    absTicks = string.match(buf, 't%s*$')

    if not bars or bars == '' then bars = 0 end
    bars = TimeFormatClampPad(bars, 0, nil, '%d')
    if not beats or beats == '' then beats = 0 end
    beats = TimeFormatClampPad(beats, 0, nil, '%d')

    if not fraction or fraction == '' then fraction = 0 end
    if absTicks and not subfrac then -- no range check on ticks
      return (isneg and '-' or '') .. bars .. '.' .. beats .. '.' .. fraction .. 't'
    else
      fraction = TimeFormatClampPad(fraction, 0, 99, '%02d')

      if not subfrac or subfrac == '' then subfrac = nil end
      if subfrac then
        subfrac = TimeFormatClampPad(subfrac, 0, 9, '%d')
      end
      return (isneg and '-' or '') .. bars .. '.' .. beats .. '.' .. fraction .. (subfrac and ('.' .. subfrac) or '')
    end
  elseif format == TIME_FORMAT_MINUTES then
    local minutes, seconds, fraction = string.match(buf, '(%d-):(%d+)%.(%d+)')
    local minutesVal, secondsVal
    if not minutes then
      minutes, seconds = string.match(buf, '(%d-):(%d+)')
      if not minutes then
        minutes = string.match(buf, '(%d-):')
      end
    end

    if not fraction or fraction == '' then fraction = 0 end
    fraction = TimeFormatClampPad(fraction, 0, 999, '%03d')
    seconds, secondsVal = TimeFormatClampPad(seconds, 0, nil, '%d')
    if secondsVal > 59 then
      minutesVal = math.floor(secondsVal / 60)
      seconds = string.format('%02d', secondsVal % 60)
    end
    if not minutes or minutes == '' then minutes = 0 end
    minutes = TimeFormatClampPad(minutes, 0, nil, '%d', minutesVal)
    return (isneg and '-' or '') .. minutes .. ':' .. seconds .. '.' .. fraction
  elseif format == TIME_FORMAT_HMSF then
    local hours, minutes, seconds, frames = string.match(buf, '(%d-):(%d-):(%d-):(%d+)')
    local hoursVal, minutesVal, secondsVal, framesVal
    local frate = r.TimeMap_curFrameRate(0)

    if not frames or frames == '' then frames = 0 end
    frames, framesVal = TimeFormatClampPad(frames, 0, nil, '%02d')
    if framesVal > frate then
      secondsVal = math.floor(framesVal / frate)
      frames = string.format('%03d', framesVal % frate)
    end
    if not seconds or seconds == '' then seconds = 0 end
    seconds, secondsVal = TimeFormatClampPad(seconds, 0, nil, '%02d', secondsVal)
    if secondsVal > 59 then
      minutesVal = math.floor(secondsVal / 60)
      seconds = string.format('%02d', secondsVal % 60)
    end
    if not minutes or minutes == '' then minutes = 0 end
    minutes, minutesVal = TimeFormatClampPad(minutes, 0, nil, '%02d', minutesVal)
    if minutesVal > 59 then
      hoursVal = math.floor(minutesVal / 60)
      minutes = string.format('%02d', minutesVal % 60)
    end
    if not hours or hours == '' then hours = 0 end
    hours = TimeFormatClampPad(hours, 0, nil, '%d', hoursVal)
    return (isneg and '-' or '') .. hours .. ':' .. minutes .. ':' .. seconds .. ':' .. frames
  end
  return DEFAULT_LENGTHFORMAT_STRING
end

function TimeFormatRebuf(buf)
  local format = DetermineTimeFormatStringType(buf)
  if format == TIME_FORMAT_UNKNOWN then return DEFAULT_TIMEFORMAT_STRING end

  local isneg = string.match(buf, '^%s*%-')

  if format == TIME_FORMAT_MEASURES then
    local absTicks = false
    local bars, beats, fraction, subfrac = string.match(buf, '(%d-)%.(%d+)%.(%d+)%.(%d+)')
    if not bars then
      bars, beats, fraction = string.match(buf, '(%d-)%.(%d+)%.(%d+)')
    end
    if not bars then
      bars, beats = string.match(buf, '(%d-)%.(%d+)')
    end
    if not bars then
      bars = string.match(buf, '(%d+)')
    end
    absTicks = string.match(buf, 't%s*$')

    if not bars or bars == '' then bars = 0 end
    bars = TimeFormatClampPad(bars, nil, nil, '%d')
    if not beats or beats == '' then beats = 1 end
    beats = TimeFormatClampPad(beats, 1, nil, '%d')

    if not fraction or fraction == '' then fraction = 0 end
    if absTicks and not subfrac then -- no range check on ticks
      return (isneg and '-' or '') .. bars .. '.' .. beats .. '.' .. fraction .. 't'
    else
      fraction = TimeFormatClampPad(fraction, 0, 99, '%02d')

      if not subfrac or subfrac == '' then subfrac = nil end
      if subfrac then
        subfrac = TimeFormatClampPad(subfrac, 0, 9, '%d')
      end
      return (isneg and '-' or '') .. bars .. '.' .. beats .. '.' .. fraction .. (subfrac and ('.' .. subfrac) or '')
    end
  elseif format == TIME_FORMAT_MINUTES then
    local minutes, seconds, fraction = string.match(buf, '(%d-):(%d+)%.(%d+)')
    local minutesVal, secondsVal, fractionVal
    if not minutes then
      minutes, seconds = string.match(buf, '(%d-):(%d+)')
      if not minutes then
        minutes = string.match(buf, '(%d-):')
      end
    end

    if not fraction or fraction == '' then fraction = 0 end
    fraction = TimeFormatClampPad(fraction, 0, 999, '%03d')
    seconds, secondsVal = TimeFormatClampPad(seconds, 0, nil, '%d')
    if secondsVal > 59 then
      minutesVal = math.floor(secondsVal / 60)
      seconds = string.format('%02d', secondsVal % 60)
    end
    if not minutes or minutes == '' then minutes = 0 end
    minutes = TimeFormatClampPad(minutes, 0, nil, '%d', minutesVal)
    return (isneg and '-' or '') .. minutes .. ':' .. seconds .. '.' .. fraction
  elseif format == TIME_FORMAT_HMSF then
    local hours, minutes, seconds, frames = string.match(buf, '(%d-):(%d-):(%d-):(%d+)')
    local hoursVal, minutesVal, secondsVal, framesVal
    local frate = r.TimeMap_curFrameRate(0)

    if not frames or frames == '' then frames = 0 end
    frames, framesVal = TimeFormatClampPad(frames, 0, nil, '%02d')
    if framesVal > frate then
      secondsVal = math.floor(framesVal / frate)
      frames = string.format('%02d', framesVal % frate)
    end
    if not seconds or seconds == '' then seconds = 0 end
    seconds, secondsVal = TimeFormatClampPad(seconds, 0, nil, '%02d', secondsVal)
    if secondsVal > 59 then
      minutesVal = math.floor(secondsVal / 60)
      seconds = string.format('%02d', secondsVal % 60)
    end
    if not minutes or minutes == '' then minutes = 0 end
    minutes, minutesVal = TimeFormatClampPad(minutes, 0, nil, '%02d', minutesVal)
    if minutesVal > 59 then
      hoursVal = math.floor(minutesVal / 60)
      minutes = string.format('%02d', minutesVal % 60)
    end
    if not hours or hours == '' then hours = 0 end
    hours = TimeFormatClampPad(hours, 0, nil, '%d', hoursVal)
    return (isneg and '-' or '') .. hours .. ':' .. minutes .. ':' .. seconds .. ':' .. frames
  end
  return DEFAULT_TIMEFORMAT_STRING
end

function FindTabsFromTarget(row)
  local condTab = {}
  local param1Tab = {}
  local param2Tab = {}
  local target = {}
  local condition = {}

  if not row or row.targetEntry < 1 then return condTab, param1Tab, param2Tab, target, condition end

  target = findTargetEntries[row.targetEntry]
  if not target then return condTab, param1Tab, param2Tab, {}, condition end

  local notation = target.notation
  if notation == '$position' then
    condTab = findPositionConditionEntries
    condition = condTab[row.conditionEntry]
    if condition then
      if condition.metricgrid then
        param1Tab = findMusicalParam1Entries
      elseif condition.notation == ':cursorpos' then
        param1Tab = findCursorParam1Entries
      elseif condition.notation == ':nearevent' then
        param1Tab = typeEntriesForEventSelector
        param2Tab = findPositionMusicalSlopEntries
      elseif condition.notation == ':undereditcursor' then
        param1Tab = findPositionMusicalSlopEntries
      end
    end
  elseif notation == '$length' then
    condTab = findLengthConditionEntries
    condition = condTab[row.conditionEntry]
    if condition then
      if string.match(condition.notation, ':eqmusical') then
        param1Tab = findMusicalParam1Entries
      end
    end
  elseif notation == '$channel' then
    condTab = findGenericConditionEntries
    param1Tab = findChannelParam1Entries
    param2Tab = findChannelParam1Entries
  elseif notation == '$type' then
    condTab = findTypeConditionEntries
    param1Tab = findTypeParam1Entries
  elseif notation == '$property' then
    condTab = findPropertyConditionEntries
    condition = condTab[row.conditionEntry]
    if condition and string.match(condition.notation, ':cchascurve') then
      param1Tab = findCCCurveParam1Entries
    else
      param1Tab = findPropertyParam1Entries
      param2Tab = findPropertyParam2Entries
    end
  -- elseif notation == '$value1' then
  -- elseif notation == '$value2' then
  -- elseif notation == '$velocity' then
  -- elseif notation == '$relvel' then
  elseif notation == '$lastevent' then
    condTab = findLastEventConditionEntries
    condition = condTab[row.conditionEntry]
    if condition then -- this could fail if we're called too early (before param tabs are needed)
      if string.match(condition.notation, 'everyN') then
        param1Tab = { }
      end
      if string.match(condition.notation, 'everyNnote$') then
        param2Tab = scaleRoots
      end
    end
  elseif notation == '$value1' then
    condTab = findValue1ConditionEntries
    condition = condTab[row.conditionEntry]
    if condition then -- this could fail if we're called too early (before param tabs are needed)
      if string.match(condition.notation, ':eqnote') then
        param1Tab = scaleRoots
      end
    end
  else
    condTab = findGenericConditionEntries
  end

  condition = condTab[row.conditionEntry]

  return condTab, param1Tab, param2Tab, target, condition and condition or {}
end

function GenerateMetricGridNotation(row)
  if not row.mg then return '' end
  local mgStr = '|'
  local mgMods, mgReaSwing = GetMetricGridModifiers(row.mg)
  mgStr = mgStr .. (mgMods == MG_GRID_SWING and (mgReaSwing and 'r' or 'm')
                    or mgMods == MG_GRID_TRIPLET and 't'
                    or mgMods == MG_GRID_DOTTED and 'd'
                    or '-')
  mgStr = mgStr .. (row.mg.wantsBarRestart and 'b' or '-')
  mgStr = mgStr .. string.format('|%0.2f|%0.2f', row.mg.preSlopPercent, row.mg.postSlopPercent)
  if mgMods == MG_GRID_SWING then
    mgStr = mgStr .. '|sw(' .. string.format('%0.2f', row.mg.swing) .. ')'
  end
  return mgStr
end

function SetMetricGridModifiers(mg, mgMods, mgReaSwing)
  local mods = mg.modifiers & 0x7
  local reaperSwing = mg.modifiers & MG_GRID_SWING_REAPER ~= 0
  if mg then
    mods = mgMods and (mgMods & 0x7) or mods
    if mgReaSwing ~= nil then reaperSwing = mgReaSwing end
    mg.modifiers = mods | (reaperSwing and MG_GRID_SWING_REAPER or 0)
  end
  return mods, reaperSwing
end

function GetMetricGridModifiers(mg)
  if mg then
    local mods = mg.modifiers & 0x7
    local reaperSwing = mg.modifiers & MG_GRID_SWING_REAPER ~= 0
    return mods, reaperSwing
  end
  return MG_GRID_STRAIGHT, false
end

function ParseMetricGridNotation(str)
  local mg = {}

  local fs, fe, mod, rst, pre, post, swing = string.find(str, '|([tdrm%-])([b-])|(.-)|(.-)|sw%((.-)%)$')
  if not (fs and fe) then
    fs, fe, mod, rst, pre, post = string.find(str, '|([tdrm%-])([b-])|(.-)|(.-)$')
  end
  if fs and fe then
    mg.modifiers =
      mod == 'r' and (MG_GRID_SWING | MG_GRID_SWING_REAPER) -- reaper
      or mod == 'm' and MG_GRID_SWING -- mpc
      or mod == 't' and MG_GRID_TRIPLET
      or mod == 'd' and MG_GRID_DOTTED
      or MG_GRID_STRAIGHT
    mg.wantsBarRestart = rst == 'b' and true or false
    mg.preSlopPercent = tonumber(pre)
    mg.postSlopPercent = tonumber(post)

    local reaperSwing = mg.modifiers & MG_GRID_SWING_REAPER ~= 0
    mg.swing = swing and tonumber(swing)
    if not mg.swing then mg.swing = reaperSwing and 0 or 50 end
    if reaperSwing then
      mg.swing = mg.swing < -100 and -100 or mg.swing > 100 and 100 or mg.swing
    else
      mg.swing = mg.swing < 0 and 0 or mg.swing > 100 and 100 or mg.swing
    end
  end
  return mg
end

function GenerateEveryNNotation(row)
  if not row.evn then return '' end
  local evn = row.evn
  local evnStr = (evn.isBitField and evn.pattern or tostring(evn.interval)) .. '|'
  evnStr = evnStr .. (evn.isBitField and 'b' or '-') .. '|'
  evnStr = evnStr .. evn.offset
  return evnStr
end

function ParseEveryNNotation(str)
  local evn = {}
  local fs, fe, patInt, flag, offset = string.find(str, '(%d+)|([b-])|(%d+)$')
  if not (fs and fe) then
    flag = ''
    offset = '0'
    fs, fe, patInt = string.find(str, '(%d+)')
  end
  if fs and fe then
    evn.isBitField = flag == 'b'
    evn.textEditorStr = patInt
    if evn.isBitField then evn.textEditorStr = evn.textEditorStr:gsub('[^0]', '1') end
    evn.pattern = evn.isBitField and evn.textEditorStr or '1'
    evn.interval = evn.isBitField and 1 or (tonumber(evn.textEditorStr) or 1)
    evn.offsetEditorStr = offset or '0'
    evn.offset = tonumber(evn.offsetEditorStr) or 0
  else
    evn.isBitField = false
    evn.textEditorStr = '1'
    evn.pattern = evn.textEditorStr
    evn.interval = 1
    evn.offsetEditorStr = '0'
    evn.offset = 0
  end
  return evn
end

function GenerateEventSelectorNotation(row)
  if not row.evsel then return '' end
  local evsel = row.evsel
  local evSelStr = string.format('%02X', evsel.chanmsg)
  evSelStr = evSelStr .. '|' .. evsel.channel
  evSelStr = evSelStr .. '|' .. evsel.selected
  evSelStr = evSelStr .. '|' .. evsel.muted
  if evsel.useval1 then
    evSelStr = evSelStr .. string.format('|%02X', evsel.msg2)
  end
  local scale = tonumber(evsel.scaleStr)
  if not scale then scale = 100 end
  if scale ~= 100 then
    evSelStr = evSelStr .. string.format('|%0.4f', scale):gsub("%.?0+$", "")
  end
  return evSelStr
end

function ParseEventSelectorNotation(str, row, paramTab)
  local evsel = {}
  local fs, fe, chanmsg, channel, selected, muted = string.find(str, '([0-9A-Fa-f]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)')
  local msg2, scale, savefe
  if fs and fe then
    savefe = fe
    evsel.chanmsg = tonumber(chanmsg:sub(1, 2), 16)
    evsel.channel = tonumber(channel)
    evsel.selected = tonumber(selected)
    evsel.muted = tonumber(muted)
    evsel.useval1 = false
    evsel.msg2 = 60
    evsel.scaleStr = '100'

    fs, fe, msg2 = string.find(str, '|([0-9A-Fa-f]+)', fe)
    if fs and fe then
      evsel.useval1 = true
      evsel.msg2 = tonumber(msg2:sub(1, 2), 16)
    end

    if not fe then fe = savefe end
    fs, fe, scale = string.find(str, '|([0-9.]+)', fe)
    if fs and fe then
      evsel.scaleStr = scale
    end

    for k, v in ipairs(paramTab) do
      if tonumber(v.text) == evsel.chanmsg then
        row.params[1].menuEntry = k
        break
      end
    end
    return evsel
  end
  return nil
end

function GenerateNewMIDIEventNotation(row)
  if not row.nme then return '' end
  local nme = row.nme
  local nmeStr = string.format('%02X%02X%02X', nme.chanmsg | nme.channel, nme.msg2, nme.msg3)
  nmeStr = nmeStr .. '|' .. ((nme.selected and 1 or 0) | (nme.muted and 2 or 0) | (nme.relmode and 4 or 0))
  nmeStr = nmeStr .. '|' .. nme.posText
  nmeStr = nmeStr .. '|' .. (nme.chanmsg == 0x90 and nme.durText or '0')
  nmeStr = nmeStr .. '|' .. string.format('%02X', (nme.chanmsg == 0x90 and tostring(nme.relvel) or '0'))
  return nmeStr
end

function ParseNewMIDIEventNotation(str, row, paramTab, index)
  if index == 1 then
    local nme = {}
    local fs, fe, msg, flags, pos, dur, relvel = string.find(str, '([0-9A-Fa-f]+)|(%d)|([0-9%.%-:t]+)|([0-9%.:t]+)|([0-9A-Fa-f]+)')
    if fs and fe then
      local status = tonumber(msg:sub(1, 2), 16)
      nme.chanmsg = status & 0xF0
      nme.channel = status & 0x0F
      nme.msg2 = tonumber(msg:sub(3, 4), 16)
      nme.msg3 = tonumber(msg:sub(5, 6), 16)
      local nflags = tonumber(flags)
      nme.selected = nflags & 0x01 ~= 0
      nme.muted = nflags & 0x02 ~= 0
      nme.relmode = nflags & 0x04 ~= 0
      nme.posText = pos
      nme.durText = dur
      nme.relvel = tonumber(relvel:sub(1, 2), 16)
      nme.posmode = NEWEVENT_POSITION_ATCURSOR

      for k, v in ipairs(paramTab) do
        if tonumber(v.text) == nme.chanmsg then
          row.params[1].menuEntry = k
          break
        end
      end
    else
      nme.chanmsg = 0x90
      nme.channel = 0
      nme.selected = true
      nme.muted = false
      nme.msg2 = 64
      nme.msg3 = 64
      nme.posText = DEFAULT_TIMEFORMAT_STRING
      nme.durText = '0.1.00'
      nme.relvel = 0
      nme.posmod = NEWEVENT_POSITION_ATCURSOR
      nme.relmode = false
    end
    row.nme = nme
  elseif index == 2 then
    if str == '$relcursor' then -- legacy
      str = '$atcursor'
      row.nme.relmode = true
    end

    for k, v in ipairs(paramTab) do
      if v.notation == str then
        row.params[2].menuEntry = k
        row.nme.posmode = k
        break
      end
    end
    if row.nme.posmode == NEWEVENT_POSITION_ATPOSITION then row.nme.relmode = false end -- ensure
  end
end

function GetParamType(src)
  return not src and PARAM_TYPE_UNKNOWN
    or src.menu and PARAM_TYPE_MENU
    or src.inteditor and PARAM_TYPE_INTEDITOR
    or src.floateditor and PARAM_TYPE_FLOATEDITOR
    or src.time and PARAM_TYPE_TIME
    or src.timedur and PARAM_TYPE_TIMEDUR
    or src.metricgrid and PARAM_TYPE_METRICGRID
    or src.musical and PARAM_TYPE_MUSICAL
    or src.everyn and PARAM_TYPE_EVERYN
    or src.newevent and PARAM_TYPE_NEWMIDIEVENT
    or src.param3 and PARAM_TYPE_PARAM3
    or src.eventselector and PARAM_TYPE_EVENTSELECTOR
    or src.hidden and PARAM_TYPE_HIDDEN
    or PARAM_TYPE_UNKNOWN
end

function GetParamTypesForRow(row, target, condOp)
  local paramType = GetParamType(condOp)
  if paramType == PARAM_TYPE_UNKNOWN then
    paramType = GetParamType(target)
  end
  if paramType == PARAM_TYPE_UNKNOWN then
    paramType = PARAM_TYPE_INTEDITOR
  end
  local split = { paramType, paramType }
  if row.params[3] then table.insert(split, paramType) end

  if condOp.split then
    local split1 = GetParamType(condOp.split[1])
    local split2 = GetParamType(condOp.split[2])
    local split3 = row.params[3] and GetParamType(condOp.split[3]) or nil
    if split1 ~= PARAM_TYPE_UNKNOWN then split[1] = split1 end
    if split2 ~= PARAM_TYPE_UNKNOWN then split[2] = split2 end
    if split3 and split3 ~= PARAM_TYPE_UNKNOWN then split[3] = split3 end
  end
  return split
end

function Check14Bit(paramType)
  local has14bit = false
  local hasOther = false
  if paramType == PARAM_TYPE_INTEDITOR then
    local hasTable = GetHasTable()
    has14bit = hasTable[0xE0] and true or false
    hasOther = (hasTable[0x90] or hasTable[0xA0] or hasTable[0xB0] or hasTable[0xD0] or hasTable[0xF0]) and true or false
  end
  return has14bit, hasOther
end

local function opIsBipolar(condOp, index)
  return condOp.bipolar or (condOp.split and condOp.split[index].bipolar)
end

function HandleMacroParam(row, target, condOp, paramTab, paramStr, index)
  local paramType
  local paramTypes = GetParamTypesForRow(row, target, condOp)
  paramType = paramTypes[index] or PARAM_TYPE_UNKNOWN

  local percent = string.match(paramStr, 'percent<(.-)>')
  if percent then
    local percentNum = tonumber(percent)
    if percentNum then
      local min = opIsBipolar(condOp, index) and -100 or 0
      percentNum = percentNum < min and min or percentNum > 100 and 100 or percentNum -- what about negative percents???
      row.params[index].percentVal = percentNum
      row.params[index].textEditorStr = string.format('%g', percentNum)
      return row.params[index].textEditorStr
    end
  end

  paramStr = string.gsub(paramStr, '^%s*(.-)%s*$', '%1') -- trim whitespace

  local isEveryN = paramType == PARAM_TYPE_EVERYN
  local isNewEvent = paramType == PARAM_TYPE_NEWMIDIEVENT
  local isEventSelector = paramType == PARAM_TYPE_EVENTSELECTOR

  if not (isEveryN or isNewEvent or isEventSelector) and #paramTab ~= 0 then
    for kk, vv in ipairs(paramTab) do
      local pa, pb
      if paramStr == vv.notation then
         pa = 1
         pb = vv.notation:len() + 1
      elseif vv.alias then
        for _, alias in ipairs(vv.alias) do
          if paramStr == alias then
            pa = 1
            pb = alias:len() + 1
            break
          end
        end
      else
        pa, pb = string.find(paramStr, vv.notation .. '[%W]')
      end
      if pa and pb then
        row.params[index].menuEntry = kk
        if paramType == PARAM_TYPE_METRICGRID or paramType == PARAM_TYPE_MUSICAL then
          row.mg = ParseMetricGridNotation(paramStr:sub(pb))
          row.mg.showswing = condOp.showswing or (condOp.split and condOp.split[index].showswing)
        end
        break
      end
    end
  elseif isEveryN then
    row.evn = ParseEveryNNotation(paramStr)
  elseif isNewEvent then
    ParseNewMIDIEventNotation(paramStr, row, paramTab, index)
  elseif isEventSelector then
    row.evsel = ParseEventSelectorNotation(paramStr, row, paramTab)
  elseif condOp.bitfield or (condOp.split and condOp.split[index] and condOp.split[index].bitfield) then
    row.params[index].textEditorStr = paramStr
  elseif paramType == PARAM_TYPE_INTEDITOR or paramType == PARAM_TYPE_FLOATEDITOR then
    local range = condOp.range and condOp.range or target.range
    local has14bit, hasOther = Check14Bit(paramType)
    if has14bit then
      if hasOther then range = opIsBipolar(condOp, index) and TransformerLib.PARAM_PERCENT_BIPOLAR_RANGE or TransformerLib.PARAM_PERCENT_RANGE
      else range = opIsBipolar(condOp, index) and TransformerLib.PARAM_PITCHBEND_BIPOLAR_RANGE or TransformerLib.PARAM_PITCHBEND_RANGE
      end
    end
    row.params[index].textEditorStr = EnsureNumString(paramStr, range)
  elseif paramType == PARAM_TYPE_TIME then
    row.params[index].timeFormatStr = TimeFormatRebuf(paramStr)
  elseif paramType == PARAM_TYPE_TIMEDUR then
    row.params[index].timeFormatStr = LengthFormatRebuf(paramStr)
  elseif paramType == PARAM_TYPE_METRICGRID
    or paramType == PARAM_TYPE_MUSICAL
    or paramType == PARAM_TYPE_EVERYN
    or paramType == PARAM_TYPE_NEWMIDIEVENT -- fallbacks or used?
    or paramType == PARAM_TYPE_PARAM3
    or paramType == PARAM_TYPE_HIDDEN
  then
    row.params[index].textEditorStr = paramStr
  end
  return paramStr
end

function GetParamPercentTerm(val, bipolar)
  local percent = val / 100 -- it's a percent coming from the system
  local min = bipolar and -100 or 0
  local max = 100
  if percent < min then percent = min end
  if percent > max then percent = max end
  return '(event.chanmsg == 0xE0 and math.floor((((1 << 14) - 1) * ' ..  percent .. ') + 0.5) or math.floor((((1 << 7) - 1) * ' .. percent .. ') + 0.5))'
end

function ProcessFindMacroRow(buf, boolstr)
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
  local condTab = FindTabsFromTarget(row)

  -- do we need some way to filter out extraneous (/) chars?
  for k, v in ipairs(condTab) do
    -- mu.post('testing ' .. buf .. ' against ' .. '/^%s*' .. v.notation .. '%s+/')
    local param1, param2, hasNot

    findstart, findend, hasNot = string.find(buf, '^%s-(!*)' .. v.notation .. '%s+', bufstart)
    if findstart and findend then
      row.conditionEntry = k
      row.isNot = hasNot == '!' and true or false
      bufstart = findend + 1
      condTab, param1Tab, param2Tab = FindTabsFromTarget(row)
      findstart, findend, param1 = string.find(buf, '^%s*([^%s%)]*)%s*', bufstart)
      if isValidString(param1) then
        bufstart = findend + 1
        param1 = HandleMacroParam(row, findTargetEntries[row.targetEntry], condTab[row.conditionEntry], param1Tab, param1, 1)
      end
      break
    else
      findstart, findend, hasNot, param1, param2 = string.find(buf, '^%s-(!*)' .. v.notation .. '%(([^,]-)[,%s]*([^,]-)%)', bufstart)
      if not (findstart and findend) then
        findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%(%s-%)', bufstart)
      end
      if findstart and findend then
        row.conditionEntry = k
        row.isNot = hasNot == '!' and true or false
        bufstart = findend + 1

        condTab, param1Tab, param2Tab = FindTabsFromTarget(row)
        if param2 and not isValidString(param1) then param1 = param2 param2 = nil end
        if isValidString(param1) then
          param1 = HandleMacroParam(row, findTargetEntries[row.targetEntry], condTab[row.conditionEntry], param1Tab, param1, 1)
          -- mu.post('param1', param1)
        end
        if isValidString(param2) then
          param2 = HandleMacroParam(row, findTargetEntries[row.targetEntry], condTab[row.conditionEntry], param2Tab, param2, 2)
          -- mu.post('param2', param2)
        end
        break
      -- else -- still not found, maybe an old thing (can be removed post-release)
      --   P(string.sub(buf, bufstart))
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
    AddFindRow(row)
    return true
  end

  mu.post('Error parsing criteria: ' .. buf)
  return false
end

function ProcessFindMacro(buf)
  local bufstart = 0
  local rowstart, rowend, boolstr = string.find(buf, '%s+(&&)%s+')
  if not (rowstart and rowend) then
    rowstart, rowend, boolstr = string.find(buf, '%s+(||)%s+')
  end
  while rowstart and rowend do
    local rowbuf = string.sub(buf, bufstart, rowend)
    -- mu.post('got row: ' .. rowbuf) -- process
    ProcessFindMacroRow(rowbuf, boolstr)
    bufstart = rowend + 1
    rowstart, rowend, boolstr = string.find(buf, '%s+(&&)%s+', bufstart)
    if not (rowstart and rowend) then
      rowstart, rowend, boolstr = string.find(buf, '%s+(||)%s+', bufstart)
    end
  end
  -- last iteration
  -- mu.post('last row: ' .. string.sub(buf, bufstart)) -- process
  ProcessFindMacroRow(string.sub(buf, bufstart))
end

function TimeFormatToSeconds(buf, baseTime, context, isLength)
  local format = DetermineTimeFormatStringType(buf)

  local isneg = string.match(buf, '^%s*%-')

  if format == TIME_FORMAT_MEASURES then
    local absTicks = false
    local tbars, tbeats, tfraction, tsubfrac = string.match(buf, '(%d+)%.(%d+)%.(%d+)%.(%d+)')
    if not tbars then
      tbars, tbeats, tfraction = string.match(buf, '(%d+)%.(%d+)%.(%d+)')
    end
    absTicks = string.match(buf, 't%s*$')

    local bars = tonumber(tbars)
    local beats = tonumber(tbeats)
    local fraction

    if absTicks then
      local ticks = tonumber(tfraction)
      if not ticks then ticks = 0 end
      ticks = ticks < 0 and 0 or ticks >= context.PPQ and context.PPQ - 1 or ticks
      fraction = math.floor(((ticks / context.PPQ) * 1000) + 0.5)
    else
      if not tsubfrac or tsubfrac == '' then tsubfrac = '0' end
      fraction = tonumber(tfraction .. tsubfrac)
    end
    local adjust = baseTime and baseTime or 0
    if not isLength then adjust = adjust - GetTimeOffset(true) end
    fraction = not fraction and 0 or fraction > 999 and 999 or fraction < 0 and 0 or fraction
    if baseTime then
      local retval, measures = r.TimeMap2_timeToBeats(0, baseTime)
      bars = (bars and bars or 0) + measures
      beats = (beats and beats or 0) + retval
    end
    if not isLength and beats and beats > 0 then beats = beats - 1 end
    if not beats then beats = 0 end
    return (r.TimeMap2_beatsToTime(0, beats + (fraction / 1000.), bars) - adjust) * (isneg and -1 or 1)
  elseif format == TIME_FORMAT_MINUTES then
    local tminutes, tseconds, tfraction = string.match(buf, '(%d+):(%d+)%.(%d+)')
    local minutes = tonumber(tminutes)
    local seconds = tonumber(tseconds)
    local fraction = tonumber(tfraction)
    fraction = not fraction and 0 or fraction > 999 and 999 or fraction < 0 and 0 or fraction
    return ((minutes * 60) + seconds + (fraction / 1000.)) * (isneg and -1 or 1)
  elseif format == TIME_FORMAT_HMSF then
    local thours, tminutes, tseconds, tframes = string.match(buf, '(%d+):(%d+):(%d+):(%d+)')
    local hours = tonumber(thours)
    local minutes = tonumber(tminutes)
    local seconds = tonumber(tseconds)
    local frames = tonumber(tframes) -- is this based on r.TimeMap_curFrameRate()?
    local frate = r.TimeMap_curFrameRate(0)
    -- fraction = not fraction and 0 or fraction > 99 and 99 or fraction < 0 and 0 or fraction
    return ((hours * 60 * 60) + (minutes * 60) + seconds + (frames / frate)) * (isneg and -1 or 1)
  end
  return 0
end

function LengthFormatToSeconds(buf, baseTime, context)
  return TimeFormatToSeconds(buf, baseTime, context, true)
end

function AddDuration(event, property, duration, baseTime, context)
  local adjustedTime = LengthFormatToSeconds(duration, baseTime, context)
  event[property] = baseTime + adjustedTime
  return event[property]
end

function SubtractDuration(event, property, duration, baseTime, context)
  local adjustedTime = LengthFormatToSeconds(duration, baseTime, context)
  event[property] = baseTime - adjustedTime
  return event[property]
end

-- uses a timeval for the offset so that we can get an offset relative to the new position
function MultiplyPosition(event, property, param, relative, offset, context)
  local take = context.take
  if not take then return event[property] end

  local item = r.GetMediaItemTake_Item(take)
  if not item then return event[property] end

  local scaledPosition
  if relative == 1 then -- first event
    local firstTime = context.firstTime
    local distanceFromStart = event.projtime - firstTime
    scaledPosition = firstTime + (distanceFromStart * param)
  else
    local itemStartPos = r.GetMediaItemInfo_Value(item, 'D_POSITION') + GetTimeOffset() -- item
    local distanceFromStart = event.projtime - itemStartPos
    scaledPosition = itemStartPos + (distanceFromStart * param)
  end
  scaledPosition = scaledPosition + (offset and LengthFormatToSeconds(offset, scaledPosition, context) or 0)

  event[property] = scaledPosition
  return scaledPosition
end

local context = {}
context.r = r
context.math = math

context.TestEvent1 = TestEvent1
context.TestEvent2 = TestEvent2
context.FindEveryN = FindEveryN
context.FindEveryNPattern = FindEveryNPattern
context.FindEveryNNote = FindEveryNNote
context.EqualsMusicalLength = EqualsMusicalLength
context.CursorPosition = CursorPosition
context.UnderEditCursor = UnderEditCursor
context.SelectChordNote = SelectChordNote

context.OP_EQ = OP_EQ
context.OP_GT = OP_GT
context.OP_GTE = OP_GTE
context.OP_LT = OP_LT
context.OP_LTE = OP_LTE
context.OP_INRANGE = OP_INRANGE
context.OP_INRANGE_EXCL = OP_INRANGE_EXCL
context.OP_EQ_SLOP = OP_EQ_SLOP
context.OP_SIMILAR = OP_SIMILAR
context.OP_EQ_NOTE = OP_EQ_NOTE

context.CURSOR_LT = CURSOR_LT
context.CURSOR_GT = CURSOR_GT
context.CURSOR_AT = CURSOR_AT
context.CURSOR_LTE = CURSOR_LTE
context.CURSOR_GTE = CURSOR_GTE
context.CURSOR_UNDER = CURSOR_UNDER

context.GetTimeOffset = GetTimeOffset

context.OperateEvent1 = OperateEvent1
context.OperateEvent2 = OperateEvent2
context.CreateNewMIDIEvent = CreateNewMIDIEvent
context.RandomValue = RandomValue
context.GetTimeSelectionStart = GetTimeSelectionStart
context.GetTimeSelectionEnd = GetTimeSelectionEnd
context.GetSubtypeValue = GetSubtypeValue
context.GetMainValue = GetMainValue
context.QuantizeTo = QuantizeTo
context.Mirror = Mirror
context.OnMetricGrid = OnMetricGrid
context.OnGrid = OnGrid
context.InBarRange = InBarRange
context.InRazorArea = InRazorArea
context.IsNearEvent = IsNearEvent
context.CCHasCurve = CCHasCurve
context.CCSetCurve = CCSetCurve
context.LinearChangeOverSelection = LinearChangeOverSelection
context.AddDuration = AddDuration
context.SubtractDuration = SubtractDuration
context.MultiplyPosition = MultiplyPosition
context.ClampValue = ClampValue
context.AddLength = AddLength
context.TimeFormatToSeconds = TimeFormatToSeconds
context.InScale = InScale
context.MoveToCursor = MoveToCursor
context.MoveLengthToCursor = MoveLengthToCursor
context.SetMusicalLength = SetMusicalLength
context.QuantizeMusicalPosition = QuantizeMusicalPosition
context.QuantizeMusicalLength = QuantizeMusicalLength
context.QuantizeMusicalEndPos = QuantizeMusicalEndPos
context.MoveToItemPos = MoveToItemPos

context.OP_ADD = OP_ADD
context.OP_SUB = OP_SUB
context.OP_MULT = OP_MULT
context.OP_DIV = OP_DIV
context.OP_FIXED = OP_FIXED
context.OP_SCALEOFF = OP_SCALEOFF

function DoProcessParams(row, target, condOp, paramType, paramTab, index, notation, takectx)
  local addMetricGridNotation = false
  local addEveryNNotation = false
  local addNewMIDIEventNotation = false
  local isParam3 = paramType == PARAM_TYPE_PARAM3
  local addEventSelectorNotation = false

  if paramType == PARAM_TYPE_METRICGRID
    or paramType == PARAM_TYPE_MUSICAL
    or paramType == PARAM_TYPE_EVERYN
    or paramType == PARAM_TYPE_NEWMIDIEVENT
    or paramType == PARAM_TYPE_EVENTSELECTOR
  then
    if index == 1 then
      if notation then
        if paramType == PARAM_TYPE_EVERYN then
          addEveryNNotation = true
        elseif paramType == PARAM_TYPE_NEWMIDIEVENT then
          addNewMIDIEventNotation = true
        elseif paramType == PARAM_TYPE_EVENTSELECTOR then
          addEventSelectorNotation = true
        else
          addMetricGridNotation = true
        end
      end
      paramType = PARAM_TYPE_MENU
    end
  end

  local percentFormat = 'percent<%0.4f>'
  local override = row.params[index].editorType
  local percentVal = row.params[index].percentVal
  local paramVal
  if condOp.terms < index then
    paramVal = ''
  elseif notation and override then
    if override == EDITOR_TYPE_BITFIELD then
      paramVal = row.params[index].textEditorStr
    elseif (override == EDITOR_TYPE_PERCENT or override == EDITOR_TYPE_PERCENT_BIPOLAR) then
      paramVal = string.format(percentFormat, percentVal and percentVal or tonumber(row.params[index].textEditorStr)):gsub("%.?0+$", "")
    elseif (override == EDITOR_TYPE_PITCHBEND or override == EDITOR_TYPE_PITCHBEND_BIPOLAR) then
      paramVal = string.format(percentFormat, percentVal and percentVal or (tonumber(row.params[index].textEditorStr) + (1 << 13)) / ((1 << 14) - 1) * 100):gsub("%.?0+$", "")
    elseif ((override == EDITOR_TYPE_14BIT or override == EDITOR_TYPE_14BIT_BIPOLAR)) then
      paramVal = string.format(percentFormat, percentVal and percentVal or (tonumber(row.params[index].textEditorStr) / ((1 << 14) - 1)) * 100):gsub("%.?0+$", "")
    elseif ((override == EDITOR_TYPE_7BIT
        or override == EDITOR_TYPE_7BIT_NOZERO
        or override == EDITOR_TYPE_7BIT_BIPOLAR))
      then
        paramVal = string.format(percentFormat, percentVal and percentVal or (tonumber(row.params[index].textEditorStr) / ((1 << 7) - 1)) * 100):gsub("%.?0+$", "")
    else
      mu.post('unknown override: ' .. override)
    end
  elseif (paramType == PARAM_TYPE_INTEDITOR or paramType == PARAM_TYPE_FLOATEDITOR) then
    paramVal = percentVal and string.format('%g', percentVal) or row.params[index].textEditorStr
  elseif paramType == PARAM_TYPE_TIME then
    paramVal = (notation or condOp.timearg) and row.params[index].timeFormatStr or tostring(TimeFormatToSeconds(row.params[index].timeFormatStr, nil, takectx))
  elseif paramType == PARAM_TYPE_TIMEDUR then
    paramVal = (notation or condOp.timearg) and row.params[index].timeFormatStr or tostring(LengthFormatToSeconds(row.params[index].timeFormatStr, nil, takectx))
  elseif paramType == PARAM_TYPE_METRICGRID
    or paramType == PARAM_TYPE_MUSICAL
    or paramType == PARAM_TYPE_EVERYN
    or paramType == PARAM_TYPE_PARAM3
    or override == EDITOR_TYPE_BITFIELD
    or paramType == PARAM_TYPE_HIDDEN
  then
    paramVal = row.params[index].textEditorStr
  elseif #paramTab ~= 0 then
    paramVal = notation and paramTab[row.params[index].menuEntry].notation or paramTab[row.params[index].menuEntry].text
  end

  if addMetricGridNotation then
    paramVal = paramVal .. GenerateMetricGridNotation(row)
  elseif addEveryNNotation then
    paramVal = GenerateEveryNNotation(row)
  elseif addNewMIDIEventNotation then
    paramVal = GenerateNewMIDIEventNotation(row)
  elseif addEventSelectorNotation then
    paramVal = GenerateEventSelectorNotation(row)
  end

  return paramVal
end

function ProcessParams(row, target, condOp, paramTabs, notation, takectx)
  local paramTypes = GetParamTypesForRow(row, target, condOp)

  local param1Val = DoProcessParams(row, target, condOp, paramTypes[1], paramTabs[1], 1, notation, takectx)
  local param2Val = DoProcessParams(row, target, condOp, paramTypes[2], paramTabs[2], 2, notation, takectx)
  local param3Val = row.params[3] and DoProcessParams(row, target, condOp, paramTypes[3], paramTabs[3], 3, notation, takectx) or nil

  return param1Val, param2Val, param3Val
end

  ---------------------------------------------------------------------------
  -------------------------------- FIND UTILS -------------------------------

function FindRowToNotation(row, index)
  local rowText = ''

  local _, param1Tab, param2Tab, curTarget, curCondition = FindTabsFromTarget(row)
  rowText = curTarget.notation .. ' ' .. (row.isNot and '!' or '') .. curCondition.notation
  local param1Val, param2Val
  local paramTypes = GetParamTypesForRow(row, curTarget, curCondition)

  param1Val, param2Val = ProcessParams(row, curTarget, curCondition, { param1Tab, param2Tab, {} }, true, { PPQ = 960 } )
  if paramTypes[1] == PARAM_TYPE_MENU then
    param1Val = (curCondition.terms > 0 and #param1Tab) and param1Tab[row.params[1].menuEntry].notation or nil
  end
  if paramTypes[2] == PARAM_TYPE_MENU then
    param2Val = (curCondition.terms > 1 and #param2Tab) and param2Tab[row.params[2].menuEntry].notation or nil
  end

  if string.match(curCondition.notation, '[!]*%:') then
    rowText = rowText .. '('
    if isValidString(param1Val) then
      rowText = rowText .. param1Val
      if isValidString(param2Val) then
        rowText = rowText .. ', ' .. param2Val
      end
    end
    rowText = rowText .. ')'
  else
    if isValidString(param1Val) then
      rowText = rowText .. ' ' .. param1Val -- no param2 val without a function
    end
  end

  if row.startParenEntry > 1 then rowText = startParenEntries[row.startParenEntry].notation .. ' ' .. rowText end
  if row.endParenEntry > 1 then rowText = rowText .. ' ' .. endParenEntries[row.endParenEntry].notation end

  if index and index ~= #findRowTable then
    rowText = rowText .. (row.booleanEntry == 2 and ' || ' or ' && ')
  end
  return rowText
end

function FindRowsToNotation()
  local notationString = ''
  for k, v in ipairs(findRowTable) do
    local rowText = FindRowToNotation(v, k)
    notationString = notationString .. rowText
  end
  -- mu.post('find macro: ' .. notationString)
  return notationString
end

function EventToIdx(event)
  return event.chanmsg + (event.chan and event.chan or 0)
end

function UpdateEventCount(event, counts, onlyNoteRow)
  local char
  if GetEventType(event) == NOTE_TYPE and not onlyNoteRow then
    event.count = counts.noteCount + 1
    counts.noteCount = event.count
  end
  -- also get counts for specific notes so that we can do rows as an option
  local eventIdx = EventToIdx(event)
  if not counts[eventIdx] then counts[eventIdx] = {} end
  local subIdx = event.msg2 and event.msg2 or 0 -- sysex/text
  if event.chanmsg >= 0xC0 then subIdx = 0 end
  if not counts[eventIdx][subIdx] then counts[eventIdx][subIdx] = 0 end
  local cname = GetEventType(event) == NOTE_TYPE and 'ncount' or 'count'
  event[cname] = counts[eventIdx][subIdx] + 1
  counts[eventIdx][subIdx] = event[cname]
end

function CalcChordPos(first, last)
  local chordPos = {}
  for i = first, last do
    if GetEventType(allEvents[i]) == NOTE_TYPE then
      table.insert(chordPos, allEvents[i])
    end
  end
  table.sort(chordPos, function(a, b) return a.msg2 < b.msg2 end)
  for ek, ev in ipairs(chordPos) do
    ev.chordIdx = ek
    ev.chordCount = #chordPos
    if ek == 1 then
      ev.chordBottom = true
    elseif ek == #chordPos then
      ev.chordTop = true
    end
  end
end

function RunFind(findFn, params, runFn)

  local wantsEventPreprocessing = params and params.wantsEventPreprocessing or false
  local getUnfound = params and params.wantsUnfound or false
  local hasTable = {}
  local found = {}
  local unfound = {}

  local firstTime = 0xFFFFFFFF
  local lastTime = -0xFFFFFFFF
  local lastNoteEnd = -0xFFFFFFFF

  if wantsEventPreprocessing then
    local firstNotePpq
    local firstNoteIndex
    local firstNoteCount = 0
    local prevEvents = {}
    local counts = {
      noteCount = 0
    }
    local take = params.take

    for k, event in ipairs(allEvents) do
      if GetEventType(event) == CC_TYPE or GetEventType(event) == SYXTEXT_TYPE then
        UpdateEventCount(event, counts)
      elseif GetEventType(event) == NOTE_TYPE then -- note event
        if take then
          local noteOnset = event.projtime
          local notePpq = r.MIDI_GetPPQPosFromProjTime(take, noteOnset)
          local matched = false
          local updateFirstNote = true
          if firstNotePpq then
            if notePpq >= firstNotePpq - (params.PPQ * 0.05) and notePpq <= firstNotePpq + (params.PPQ * 0.05) then
              if prevEvents[1] and prevEvents[2] then
                event.flags = event.flags | 4
                counts.noteCount = firstNoteCount
                event.count = counts.noteCount
                if prevEvents[1] then
                  prevEvents[1].flags = prevEvents[1].flags | 4
                  prevEvents[1].count = counts.noteCount
                end
                if prevEvents[2] then
                  prevEvents[2].flags = prevEvents[2].flags | 4
                  prevEvents[2].count = counts.noteCount
                end
                matched = true
              end

              prevEvents[2] = prevEvents[1]
              prevEvents[1] = event
              updateFirstNote = false
              firstNotePpq = (firstNotePpq + notePpq) / 2 -- running avg
            end
          end
          if not matched then
            if updateFirstNote then
              if k > 1 and (allEvents[k - 1].flags & 0x04 ~= 0) then
                CalcChordPos(firstNoteIndex, k - 1)
              end

              firstNotePpq = notePpq
              firstNoteIndex = k
              firstNoteCount = counts.noteCount + 1
              prevEvents[1] = event
              prevEvents[2] = nil
            end
          end
          UpdateEventCount(event, counts, matched)
        end
      end
    end
    if firstNoteIndex and (allEvents[firstNoteIndex].flags & 0x04 ~= 0) then
      CalcChordPos(firstNoteIndex, #allEvents)
    end
  end

  for _, event in ipairs(allEvents) do
    local matches = false
    if findFn and findFn(event, GetSubtypeValueName(event), GetMainValueName(event)) then -- event, _value1, _value2
      hasTable[event.chanmsg] = true
      if event.projtime < firstTime then firstTime = event.projtime end
      if event.projtime > lastTime then lastTime = event.projtime end
      if GetEventType(event) == NOTE_TYPE and event.projtime + event.projlen > lastNoteEnd then lastNoteEnd = event.projtime + event.projlen end
      table.insert(found, event)
      matches = true
    elseif getUnfound then
      table.insert(unfound, event)
    end
    if runFn then runFn(event, matches) end
  end

  found, unfound = HandleFindPostProcessing(found, unfound)

  -- it was a time selection, add a final event to make behavior predictable
  if params.addRangeEvents and params.findRange.frStart and params.findRange.frEnd then
    local frStart = params.findRange.frStart
    local frEnd = params.findRange.frEnd
    local firstLastEventsByType = {}
    for _, event in ipairs(found) do
      if GetEventType(event) == CC_TYPE then
        local eventIdx = EventToIdx(event)
        if not firstLastEventsByType[eventIdx] then firstLastEventsByType[eventIdx] = {} end
        if not firstLastEventsByType[eventIdx][event.msg2] then firstLastEventsByType[eventIdx][event.msg2] = {} end
        if not firstLastEventsByType[eventIdx][event.msg2].firstEvent then
          firstLastEventsByType[eventIdx][event.msg2].firstEvent = event
        end
        firstLastEventsByType[eventIdx][event.msg2].lastEvent = event
      end
    end
    for _, rData in pairs(firstLastEventsByType) do
      for _, rEvent in pairs(rData) do
        local newEvent
        newEvent = tableCopy(rEvent.firstEvent)
        newEvent.projtime = frStart
        newEvent.firstlastevent = true
        newEvent.orig_type = OTHER_TYPE
        table.insert(found, newEvent)
        newEvent = tableCopy(rEvent.lastEvent)
        newEvent.projtime = frEnd
        newEvent.firstlastevent = true
        newEvent.orig_type = OTHER_TYPE
        table.insert(found, newEvent)
      end
    end
  end

  local contextTab = {
    firstTime = firstTime,
    lastTime = lastTime,
    lastNoteEnd = lastNoteEnd,
    hasTable = hasTable,
    take = params and params.take,
    PPQ = (params and params.take) and mu.MIDI_GetPPQ(params.take) or 960,
    findRange = params and params.findRange,
    findFnString = params and params.findFnString,
    actionFnString = params and params.actionFnString,
  }

  return found, contextTab, getUnfound and unfound or nil
end

function FnStringToFn(fnString, errFn)
  local fn
  local success, pret, err = pcall(load, fnString, nil, nil, context)
  if success and pret then
    fn = pret()
    parserError = ''
  else
    if errFn then errFn(err) end
  end
  return success, fn
end

function ProcessFind(take, fromHasTable)

  local fnString = ''
  local wantsEventPreprocessing = false
  local rangeType = SELECT_TIME_SHEBANG
  local findRangeStart, findRangeEnd

  wantsTab = {}
  context.PPQ = take and mu.MIDI_GetPPQ(take) or 960

  local iterTab = {}
  for _, v in ipairs(findRowTable) do
    if not (v.except or v.disabled) then
      table.insert(iterTab, v)
    end
  end

  for k, v in ipairs(iterTab) do
    local row = v
    local condTab, param1Tab, param2Tab, curTarget, curCondition = FindTabsFromTarget(v)

    if #condTab == 0 then return end -- continue?

    local targetTerm = curTarget.text
    local condition = curCondition
    local conditionVal = condition.text
    if row.isNot then conditionVal = 'not ( ' .. conditionVal .. ' )' end
    local findTerm = ''

    -- this involves extra processing and is therefore only done if necessary
    if curTarget.notation == '$lastevent' then wantsEventPreprocessing = true
    elseif string.match(condition.notation, ':inchord') then wantsEventPreprocessing = true end

    local paramTerms = { ProcessParams(v, curTarget, condition, { param1Tab, param2Tab, {} }, false, context) }

    if curCondition.terms > 0 and paramTerms[1] == '' then return end

    local paramNums = { tonumber(paramTerms[1]), tonumber(paramTerms[2]), tonumber(paramTerms[3]) }
    if paramNums[1] and paramNums[2] and paramNums[2] < paramNums[1]
      and not curCondition.freeterm
    then
      local tmp = paramTerms[2]
      paramTerms[2] = paramTerms[1]
      paramTerms[1] = tmp
    end

    local paramTypes = GetParamTypesForRow(v, curTarget, condition)
    for i = 1, 2 do -- param3 for Find?
      if paramNums[i] and (paramTypes[i] == PARAM_TYPE_INTEDITOR or paramTypes[i] == PARAM_TYPE_FLOATEDITOR) and row.params[i].percentVal then
        paramTerms[i] = GetParamPercentTerm(paramNums[i], opIsBipolar(curCondition, i))
      end
    end

    -- wants
    if curTarget.notation == '$type' and condition.notation == '==' and not row.isNot then
      local typeType = param1Tab[row.params[1].menuEntry].notation
      if typeType == '$note' then wantsTab[0x90] = true
      elseif typeType == '$polyat' then wantsTab[0xA0] = true
      elseif typeType == '$cc' then wantsTab[0xB0] = true
      elseif typeType == '$pc' then wantsTab[0xC0] = true
      elseif typeType == '$at' then wantsTab[0xD0] = true
      elseif typeType == '$pb' then wantsTab[0xE0] = true
      elseif typeType == '$syx' then wantsTab[0xF0] = true
      end
    elseif curTarget.notation == '$type' and condition.notation == ':all' then
      for i = 9, 15 do
        wantsTab[i << 4] = true
      end
    end

    -- range processing

    if condition.timeselect then
      rangeType = rangeType | condition.timeselect
    end

    if curTarget.notation == '$position' and condition.notation == ':cursorpos' then
      local param1 = param1Tab[row.params[1].menuEntry]
      if param1 and param1.timeselect then
        rangeType = rangeType | param1.timeselect
      end
    end

    if curTarget.notation == '$position' and condition.timeselect == SELECT_TIME_RANGE then
      if condition.notation == ':intimesel' then
        local ts1 = GetTimeSelectionStart()
        local ts2 = GetTimeSelectionEnd()
        if not findRangeStart or ts1 < findRangeStart then findRangeStart = ts1 end
        if not findRangeEnd or ts2 > findRangeEnd then findRangeEnd = ts2 end
      end
    end

    -- substitutions

    findTerm = conditionVal
    findTerm = string.gsub(findTerm, '{tgt}', targetTerm)
    findTerm = string.gsub(findTerm, '{param1}', tostring(paramTerms[1]))
    findTerm = string.gsub(findTerm, '{param2}', tostring(paramTerms[2]))

    local isMetricGrid = paramTypes[1] == PARAM_TYPE_METRICGRID and true or false
    local isMusical = paramTypes[1] == PARAM_TYPE_MUSICAL and true or false
    local isEveryN = paramTypes[1] == PARAM_TYPE_EVERYN and true or false
    local isEventSelector = paramTypes[1] == PARAM_TYPE_EVENTSELECTOR and true or false

    if isMetricGrid or isMusical then
      local mgParams = tableCopy(row.mg)
      mgParams.param1 = paramNums[1]
      mgParams.param2 = paramTerms[2]
      findTerm = string.gsub(findTerm, isMetricGrid and '{metricgridparams}' or '{musicalparams}', serialize(mgParams))
    elseif isEveryN then
      local evnParams = tableCopy(row.evn)
      findTerm = string.gsub(findTerm, '{everyNparams}', serialize(evnParams))
    elseif isEventSelector then
      local evSelParams = tableCopy(row.evsel)
      findTerm = string.gsub(findTerm, '{eventselectorparams}', serialize(evSelParams))
    end

    if curTarget.cond then
      findTerm = curTarget.cond .. ' and ' .. findTerm
    end

    findTerm = string.gsub(findTerm, '^%s*(.-)%s*$', '%1')

    -- different approach, but false needs to be true for AND conditions
    -- and to do that, we need to know whether we're in and AND or OR clause
    -- and to do that, we need to perform more analysis, not sure if it's worth it
    -- if row.except or row.disabled then
    --   findTerm = '( false and ( ' .. findTerm .. ' ) )'
    -- end

    local startParen = row.startParenEntry > 1 and (startParenEntries[row.startParenEntry].text .. ' ') or ''
    local endParen = row.endParenEntry > 1 and (' ' .. endParenEntries[row.endParenEntry].text) or ''

    local rowStr = startParen .. '( ' .. findTerm .. ' )' .. endParen

    if k ~= #iterTab then
      rowStr = rowStr .. ' ' .. findBooleanEntries[row.booleanEntry].text
    end
    -- mu.post(k .. ': ' .. rowStr)

    fnString = fnString == '' and (' ' .. rowStr .. '\n') or (fnString .. ' ' .. rowStr .. '\n')
  end

  fnString = 'return function(event, _value1, _value2)\nreturn ' .. fnString .. '\nend'

  if DEBUGPOST then
    mu.post('======== FIND FUN ========')
    mu.post(fnString)
    mu.post('==========================')
  end

  local findFn

  context.take = take
  if take then currentGrid, currentSwing = r.MIDI_GetGrid(take) end -- 1.0 is QN, 1.5 dotted, etc.
  _, findFn = FnStringToFn(fnString, function(err)
    parserError = 'Fatal error: could not load selection criteria'
    if err then
      if string.match(err, '\'%)\' expected') then
        parserError = parserError .. ' (Unmatched Parentheses)'
      end
    end
  end)

  if not fromHasTable then dirtyFind = true end
  return findFn, wantsEventPreprocessing, { type = rangeType, frStart = findRangeStart, frEnd = findRangeEnd }, fnString
end

function ActionTabsFromTarget(row)
  local opTab = {}
  local param1Tab = {}
  local param2Tab = {}
  local target = {}
  local operation = {}

  if not row or row.targetEntry < 1 then return opTab, param1Tab, param2Tab, target, operation end

  target = actionTargetEntries[row.targetEntry]
  if not target then return opTab, param1Tab, param2Tab, {}, operation end

  local notation = target.notation
  if notation == '$position' then
    opTab = actionPositionOperationEntries
  elseif notation == '$length' then
    opTab = actionLengthOperationEntries
  elseif notation == '$channel' then
    opTab = actionChannelOperationEntries
  elseif notation == '$type' then
    opTab = actionTypeOperationEntries
  elseif notation == '$property' then
    opTab = actionPropertyOperationEntries
  elseif notation == '$value1' then
    opTab = actionSubtypeOperationEntries
  elseif notation == '$value2' then
    opTab = actionVelocityOperationEntries
  elseif notation == '$velocity' then
    opTab = actionVelocityOperationEntries
  elseif notation == '$relvel' then
    opTab = actionVelocityOperationEntries
  elseif notation == '$newevent' then
    opTab = actionNewEventOperationEntries
  else
    opTab = actionGenericOperationEntries
  end

  operation = opTab[row.operationEntry]
  if not operation then return opTab, param1Tab, param2Tab, target, {} end

  local opnota = operation.notation

  if opnota == ':line' or opnota == ':relline' then -- param3 operation
    param1Tab = { }
    param2Tab = actionLineParam2Entries
  elseif notation == '$position' then
    if opnota == ':tocursor' then
      param1Tab = actionMoveToCursorParam1Entries
    elseif opnota == ':addlength' then
      param1Tab = actionAddLengthParam1Entries
    elseif opnota == '*' or opnota == '/' then
      param2Tab = actionPositionMultParam2Menu
    elseif opnota == ':roundmusical' then
      param1Tab = findMusicalParam1Entries
    elseif opnota == ':scaleoffset' then -- param3 operation
      param1Tab = { }
      param2Tab = actionPositionMultParam2Menu
    end
  elseif notation == '$length' then
    if opnota == ':quantmusical'
    or opnota == ':roundlenmusical'
    or opnota == ':roundendmusical'
    then
      param1Tab = findMusicalParam1Entries
    end
  elseif notation == '$channel' then
    param1Tab = findChannelParam1Entries -- same as find
  elseif notation == '$type' then
    param1Tab = typeEntries
  elseif notation == '$property' then
    if opnota == '=' then
      param1Tab = actionPropertyParam1Entries
    elseif opnota == ':ccsetcurve' then
      param1Tab = findCCCurveParam1Entries
    else
      param1Tab = actionPropertyAddRemParam1Entries
    end
  elseif notation == '$newevent' then
    param1Tab = typeEntries -- no $syx
    param2Tab = newMIDIEventPositionEntries
  end

  return opTab, param1Tab, param2Tab, target, operation
end

function DefaultValueIfAny(row, operation, index)
  local param = nil
  local default = operation.split and operation.split[index].default or nil -- hack
  if default then
    param = tostring(default)
    row.params[index].textEditorStr = param
  end
  return param
end

function ProcessActionMacroRow(buf)
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

  local opTab, _, _, target = ActionTabsFromTarget(row) -- a little simpler than findTargets, no operation-based overrides (yet)
  if not (target and opTab) then
    mu.post('could not process action macro row: ' .. buf)
    return false
  end

  -- do we need some way to filter out extraneous (/) chars?
  for k, v in ipairs(opTab) do
    -- mu.post('testing ' .. buf .. ' against ' .. '/^%s*' .. v.notation .. '%s+/')
    local tryagain = true
    findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%s+', bufstart)
    if findstart and findend then
      local cachestart = bufstart
      row.operationEntry = k
      local _, param1Tab, _, _, operation = ActionTabsFromTarget(row)
      bufstart = findend + (buf[findend] ~= '(' and 1 or 0)

      local _, _, param1 = string.find(buf, '^%s*([^%s%()]*)%s*', bufstart)
      if isValidString(param1) then
        param1 = HandleMacroParam(row, target, operation, param1Tab, param1, 1)
        tryagain = false
      else
        if operation.terms == 0 then tryagain = false
        else bufstart = cachestart end
      end
      if not tryagain then
        row.params[1].textEditorStr = param1
        break
      end
    end
    if tryagain then
      local param1, param2, param3
      findstart, findend, param1, param2, param3 = string.find(buf, '^%s*' .. v.notation .. '%s*%(([^,]*)[,%s]*([^,]*)[,%s]*([^,]*)%)', bufstart)
      if not (findstart and findend) then
        findstart, findend, param1, param2 = string.find(buf, '^%s*' .. v.notation .. '%s*%(([^,]*)[,%s]*([^,]*)%)', bufstart)
      end
      if findstart and findend then
        row.operationEntry = k

        if param3 and v.param3 then
          row.params[3] = ParamInfo()
          for p3k, p3v in pairs(v.param3) do row.params[3][p3k] = p3v end
          row.params[3].textEditorStr = param3
        else
          row.params[3] = nil -- just to be safe
          param3 = nil
        end

        if row.params[3] and row.params[3].parser then row.params[3].parser(row, param1, param2, param3)
        else
          local _, param1Tab, param2Tab, _, operation = ActionTabsFromTarget(row)

          if param2 and not isValidString(param1) then param1 = param2 param2 = nil end
          if isValidString(param1) then
            param1 = HandleMacroParam(row, target, operation, param1Tab, param1, 1)
          else
            param1 = DefaultValueIfAny(row, operation, 1)
          end
          if isValidString(param2) then
            param2 = HandleMacroParam(row, target, operation, param2Tab, param2, 2)
          else
            param2 = DefaultValueIfAny(row, operation, 2)
          end
          if isValidString(param3) then
            row.params[3].textEditorStr = param3 -- very primitive
          end
          row.params[1].textEditorStr = param1
          row.params[2].textEditorStr = param2
        end

        -- mu.post(v.label .. ': ' .. (param1 and param1 or '') .. ' / ' .. (param2 and param2 or ''))
        break
      end
    end
  end

  if row.targetEntry ~= 0 and row.operationEntry ~= 0 then
    AddActionRow(row)
    return true
  end

  mu.post('Error parsing action: ' .. buf)
  return false
end

function ProcessActionMacro(buf)
  local bufstart = 0
  local rowstart, rowend = string.find(buf, '%s+(&&)%s+')
  while rowstart and rowend do
    local rowbuf = string.sub(buf, bufstart, rowend)
    -- mu.post('got row: ' .. rowbuf) -- process
    ProcessActionMacroRow(rowbuf)
    bufstart = rowend + 1
    rowstart, rowend = string.find(buf, '%s+(&&)%s+', bufstart)
  end
  -- last iteration
  -- mu.post('last row: ' .. string.sub(buf, bufstart)) -- process
  ProcessActionMacroRow(string.sub(buf, bufstart))
end


  ----------------------------------------------
  ---------------- ACTIONS TABLE ---------------
  ----------------------------------------------

local mediaItemCount
local mediaItemIndex
local enumTakesMode

function GetEnumTakesMode()
  return 1
  -- if not enumTakesMode then
  --   enumTakesMode = 0
  --   local rv, mevars = r.get_config_var_string('midieditor')
  --   if mevars then
  --     local mevarsVal = tonumber(mevars)
  --     enumTakesMode = mevarsVal & 1 ~= 0 and 0 or 1 -- project mode, set to 0 (false)
  --   end
  -- end
  -- return enumTakesMode
end

function GetNextTake()
  local take = nil
  local notation = findScopeTable[currentFindScope].notation
  if notation == '$midieditor' then
    local me = r.MIDIEditor_GetActive()
    if me then
      if not mediaItemCount then
        mediaItemCount = 0
        while me do
          local t = r.MIDIEditor_EnumTakes(me, mediaItemCount, GetEnumTakesMode())
          if not t then break end
          mediaItemCount = mediaItemCount + 1 -- we probably don't really need this iteration, but whatever
        end
        mediaItemIndex = 0
      end
      if mediaItemIndex < mediaItemCount then
        take = r.MIDIEditor_EnumTakes(me, mediaItemIndex, GetEnumTakesMode())
        mediaItemIndex = mediaItemIndex + 1
      end
    end
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

function InitializeTake(take)
  local onlySelected = false
  local onlyNotes = false
  local activeNoteRow = false
  allEvents = {}
  selectedEvents = {}
  mu.MIDI_InitializeTake(take) -- reset this each cycle
  if findScopeTable[currentFindScope].notation == '$midieditor' then
    if currentFindScopeFlags & FIND_SCOPE_FLAG_SELECTED_ONLY ~= 0 then
      if mu.MIDI_EnumSelEvts(take, -1) ~= -1 then
        onlySelected = true
      end
    end
    if currentFindScopeFlags & FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW ~= 0 then
      onlyNotes = true
      activeNoteRow = true
    end
  end

  local enumNotesFn = onlySelected and mu.MIDI_EnumSelNotes or mu.MIDI_EnumNotes
  local enumCCFn = onlySelected and mu.MIDI_EnumSelCC or mu.MIDI_EnumCC
  local enumTextSysexFn = onlySelected and mu.MIDI_EnumSelTextSysexEvts or mu.MIDI_EnumTextSysexEvts
  local activeRow = activeNoteRow and r.MIDIEditor_GetSetting_int(r.MIDIEditor_GetActive(), 'active_note_row') or nil

  local noteidx = enumNotesFn(take, -1)
  while noteidx ~= -1 do
    local e = { type = NOTE_TYPE, idx = noteidx }
    _, e.selected, e.muted, e.ppqpos, e.endppqpos, e.chan, e.pitch, e.vel, e.relvel = mu.MIDI_GetNote(take, noteidx)

    local doIt = not activeRow or e.pitch == activeRow

    if doIt then
      e.msg2 = e.pitch
      e.msg3 = e.vel
      e.notedur = e.endppqpos - e.ppqpos
      e.chanmsg = 0x90
      e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
      CalcMIDITime(take, e)
      table.insert(allEvents, e)
      if e.selected then table.insert(selectedEvents, e) end
    end
    noteidx = enumNotesFn(take, noteidx)
  end

  local ccidx = onlyNotes and -1 or enumCCFn(take, -1)
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
    CalcMIDITime(take, e)
    table.insert(allEvents, e)
    if e.selected then table.insert(selectedEvents, e) end
    ccidx = enumCCFn(take, ccidx)
  end

  local syxidx = onlyNotes and -1 or enumTextSysexFn(take, -1)
  while syxidx ~= -1 do
    local e = { type = SYXTEXT_TYPE, idx = syxidx }
    _, e.selected, e.muted, e.ppqpos, e.chanmsg, e.textmsg = mu.MIDI_GetTextSysexEvt(take, syxidx)
    e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
    if e.chanmsg ~- 0xF0 then
      e.msg2 = e.chanmsg
      e.chanmsg = 0x100
    end
    CalcMIDITime(take, e)
    table.insert(allEvents, e)
    if e.selected then table.insert(selectedEvents, e) end
    syxidx = enumTextSysexFn(take, syxidx)
  end

  table.sort(allEvents, function(a, b) return a.projtime < b.projtime end )
end

function ActionRowToNotation(row, index)
  local rowText = ''

  local _, _, _, _, curOperation = ActionTabsFromTarget(row)

  if row.params[3] and row.params[3].formatter then rowText = rowText .. row.params[3].formatter(row)
  else
    local param1Val, param2Val, param3Val
    rowText, param1Val, param2Val, param3Val = GetRowTextAndParameterValues(row)
    if string.match(curOperation.notation, '[!]*%:') then
      rowText = rowText .. '('
      if isValidString(param1Val) then
        rowText = rowText .. param1Val
        if isValidString(param2Val) then
          rowText = rowText .. ', ' .. param2Val
          if isValidString(param3Val) then
            rowText = rowText .. ', ' .. param3Val
          end
        end
      end
      rowText = rowText .. ')'
    else
      if isValidString(param1Val) then
        rowText = rowText .. ' ' .. param1Val -- no param2 val without a function
      end
    end
  end

  if index and index ~= #actionRowTable then
    rowText = rowText .. ' && '
  end
  return rowText
end

function ActionRowsToNotation()
  local notationString = ''
  for k, v in ipairs(actionRowTable) do
    local rowText = ActionRowToNotation(v, k)
    notationString = notationString .. rowText
  end
  -- mu.post('action macro: ' .. notationString)
  return notationString
end

function DeleteEventsInTake(take, eventTab, doTx)
  if doTx == true or doTx == nil then
    mu.MIDI_OpenWriteTransaction(take)
  end
  for _, event in ipairs(eventTab) do
    if GetEventType(event) == NOTE_TYPE then
      mu.MIDI_DeleteNote(take, event.idx)
    elseif GetEventType(event) == CC_TYPE then
      mu.MIDI_DeleteCC(take, event.idx)
    elseif GetEventType(event) == SYXTEXT_TYPE then
      mu.MIDI_DeleteTextSysexEvt(take, event.idx)
    end
  end
  if doTx == true or doTx == nil then
    mu.MIDI_CommitWriteTransaction(take, false, true)
  end
end

function DoFindPostProcessing(found, unfound)
  local wantsFront = currentFindPostProcessingInfo.flags & FIND_POSTPROCESSING_FLAG_FIRSTEVENT ~= 0
  local wantsBack = currentFindPostProcessingInfo.flags & FIND_POSTPROCESSING_FLAG_LASTEVENT ~= 0
  local newfound = {}

  if wantsFront then
    local num = currentFindPostProcessingInfo.front.count
    local offset = currentFindPostProcessingInfo.front.offset + 1
    for i = 1, #found do
      local f = found[i]
      if i >= offset and (i - offset) < num then
        table.insert(newfound, f)
      else
        table.insert(unfound, f)
      end
    end
  end
  if wantsBack then
    local num = currentFindPostProcessingInfo.back.count
    local offset = currentFindPostProcessingInfo.back.offset + 1
    local ii = 1
    for i = #found, 1, -1 do
      local f = found[i]
      if ii >= offset and (ii - offset) < num then
        table.insert(newfound, f)
      else
        table.insert(unfound, f)
      end
      ii = ii + 1
    end
  end
  if #newfound ~= 0 then found = newfound end
  return found
end

function HandleFindPostProcessing(found, unfound)
  if currentFindPostProcessingInfo.flags ~= FIND_POSTPROCESSING_FLAG_NONE then
    return DoFindPostProcessing(found, unfound)
  end
  return found, unfound
end

local CreateNewMIDIEvent_Once

function HandleCreateNewMIDIEvent(take, contextTab)
  if CreateNewMIDIEvent_Once then
    for i, row in ipairs(actionRowTable) do
      if row.nme and not row.disabled then
        local nme = row.nme

        -- magic

        local fnTab = {}
        for s in contextTab.actionFnString:gmatch("[^\r\n]+") do
          table.insert(fnTab, s)
        end
        for ii = 2, i + 1 do
          fnTab[ii] = nil
        end
        local fnString = ''
        for _, s in pairs(fnTab) do
          fnString = fnString .. s .. '\n'
        end

        local _, actionFn = FnStringToFn(fnString, function(err)
          if err then
            mu.post(err)
          end
          parserError = 'Error: could not load action description (New MIDI Event)'
        end)
        if actionFn then
          local timeAdjust = GetTimeOffset()
          local e = tableCopy(nme)
          local pos
          if nme.posmode == NEWEVENT_POSITION_ATCURSOR then
            pos = r.GetCursorPositionEx(0)
          elseif nme.posmode == NEWEVENT_POSITION_ITEMSTART then
            pos = r.GetMediaItemInfo_Value(r.GetMediaItemTake_Item(take), 'D_POSITION')
          elseif nme.posmode == NEWEVENT_POSITION_ITEMEND then
            local item = r.GetMediaItemTake_Item(take)
            pos = r.GetMediaItemInfo_Value(item, 'D_POSITION') + r.GetMediaItemInfo_Value(item, 'D_LENGTH')
          else
            pos = TimeFormatToSeconds(nme.posText, nil, context) - timeAdjust
          end

          if nme.posmode ~= NEWEVENT_POSITION_ATPOSITION and nme.relmode then
            pos = pos + LengthFormatToSeconds(nme.posText, pos, context)
          end

          local evType = GetEventType(e)

          e.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, pos) -- check for abs pos mode
          if evType == NOTE_TYPE then
            e.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, pos + LengthFormatToSeconds(nme.durText, pos, context))
          end
          e.chan = e.channel
          e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
          CalcMIDITime(take, e)

          actionFn(e, GetSubtypeValueName(e), GetMainValueName(e), contextTab)

          e.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, e.projtime - timeAdjust)
          if evType == NOTE_TYPE then
            e.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, (e.projtime - timeAdjust) + e.projlen)
            e.msg3 = e.msg3 < 1 and 1 or e.msg3
          end
          PostProcessSelection(e)
          e.muted = (e.flags & 2) ~= 0

          if evType == NOTE_TYPE then
            mu.MIDI_InsertNote(take, e.selected, e.muted, e.ppqpos, e.endppqpos, e.chan, e.msg2, e.msg3, e.relvel)
          elseif evType == CC_TYPE then
            mu.MIDI_InsertCC(take, e.selected, e.muted, e.ppqpos, e.chanmsg, e.chan, e.msg2, e.msg3)
          end
        end
      end
    end
    CreateNewMIDIEvent_Once = nil
  end
end

function InsertEventsIntoTake(take, eventTab, actionFn, contextTab, doTx)
  if doTx == true or doTx == nil then
    mu.MIDI_OpenWriteTransaction(take)
  end
  PreProcessSelection(take)
  for _, event in ipairs(eventTab) do
    local timeAdjust = GetTimeOffset()
    actionFn(event, GetSubtypeValueName(event), GetMainValueName(event), contextTab) -- event, _value1, _value2, _context
    event.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime - timeAdjust)
    PostProcessSelection(event)
    event.muted = (event.flags & 2) ~= 0
    if GetEventType(event) == NOTE_TYPE then
      if event.projlen <= 0 then event.projlen = 1 / context.PPQ end
      event.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, (event.projtime - timeAdjust) + event.projlen)
      event.msg3 = event.msg3 < 1 and 1 or event.msg3 -- do not turn off the note
      mu.MIDI_InsertNote(take, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.msg2, event.msg3, event.relvel)
    elseif GetEventType(event) == CC_TYPE then
      local rv, newidx = mu.MIDI_InsertCC(take, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3)
      if rv and event.setcurve then
        mu.MIDI_SetCCShape(take, newidx, event.setcurve, event.setcurveext)
      end
    elseif GetEventType(event) == SYXTEXT_TYPE then
      mu.MIDI_InsertTextSysexEvt(take, event.selected, event.muted, event.ppqpos, event.chanmsg == 0xF0 and event.chanmsg or event.msg2, event.textmsg)
    end
  end
  HandleCreateNewMIDIEvent(take, contextTab)
  if doTx == true or doTx == nil then
    mu.MIDI_CommitWriteTransaction(take, false, true)
  end
end

function SelectEntriesInTake(take, eventTab, wantsSelect)
  for _, event in ipairs(eventTab) do
    event.selected = wantsSelect
    SetEntrySelectionInTake(take, event)
  end
end

function SetEntrySelectionInTake(take, event)
  if GetEventType(event) == NOTE_TYPE then
    mu.MIDI_SetNote(take, event.idx, event.selected, nil, nil, nil, nil, nil, nil, nil)
  elseif GetEventType(event) == CC_TYPE then
    mu.MIDI_SetCC(take, event.idx, event.selected, nil, nil, nil, nil, nil, nil)
  elseif GetEventType(event) == SYXTEXT_TYPE then
    mu.MIDI_SetTextSysexEvt(take, event.idx, event.selected, nil, nil, nil, nil)
  end
end

function PreProcessSelection(take)
  local notation = actionScopeFlagsTable[currentActionScopeFlags].notation
  if notation == '$invertselect' then -- doesn't exist anymore
    mu.MIDI_SelectAll(take, true) -- select all
  elseif notation == '$exclusiveselect' then
    mu.MIDI_SelectAll(take, false) -- deselect all
  end
end

function PostProcessSelection(event)
  local notation = actionScopeFlagsTable[currentActionScopeFlags].notation
  if notation == '$addselect'
    or notation == '$exclusiveselect'
  then
    event.selected = true
  elseif notation == '$invertselect' -- doesn't exist anymore
    or notation == '$unselect' -- but this one does
  then
    event.selected = false
  else
    event.selected = (event.flags & 1) ~= 0
  end
end

function TransformEntryInTake(take, eventTab, actionFn, contextTab, replace)
  local replaceTab = replace and {} or nil
  local timeAdjust = GetTimeOffset()

  for _, event in ipairs(eventTab) do
    local eventType = GetEventType(event)
    actionFn(event, GetSubtypeValueName(event), GetMainValueName(event), contextTab)
    event.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime - timeAdjust)
    PostProcessSelection(event)
    event.muted = (event.flags & 2) ~= 0
    if eventType == NOTE_TYPE then
      if (not event.projlen or event.projlen <= 0) then event.projlen = 1 / context.PPQ end
      event.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, (event.projtime - timeAdjust) + event.projlen)
      event.msg3 = event.msg3 < 1 and 1 or event.msg3 -- do not turn off the note
    end

    if replace then
      local eventIdx = EventToIdx(event)
      local replaceData = replaceTab[eventIdx]
      if not replaceData then
        replaceTab[eventIdx] = {}
        replaceData = replaceTab[eventIdx]
      end
      local eventData = replaceData
      if eventType == CC_TYPE then
        eventData = replaceData[event.msg2]
        if not eventData then
          replaceData[event.msg2] = {}
          eventData = replaceData[event.msg2]
        end
      end
      table.insert(eventData, event.ppqpos)
      if not eventData.startPpq or event.ppqpos < eventData.startPpq then eventData.startPpq = event.ppqpos end
      if not eventData.endPpq or event.ppqpos > eventData.endPpq then eventData.endPpq = event.ppqpos end
    end
  end

  mu.MIDI_OpenWriteTransaction(take)
  if replace then
    local grid = currentGrid
    local PPQ = mu.MIDI_GetPPQ(take)
    local gridSlop = math.floor(((PPQ * grid) * 0.5) + 0.5)
    local rangeType = contextTab.findRange.type

    for _, event in ipairs(replace) do
      local eventType = GetEventType(event)
      local eventIdx = EventToIdx(event)
      local eventData
      local replaceData = replaceTab[eventIdx]
      if replaceData then
        if eventType == CC_TYPE then eventData = replaceData[event.msg2]
        else eventData = replaceData
        end
      end
      if eventData and rangeType then
        if (rangeType == SELECT_TIME_SHEBANG)
          or (rangeType & SELECT_TIME_RANGE ~= 0)
        then
          if (not (rangeType & SELECT_TIME_MINRANGE ~= 0) or event.ppqpos >= (eventData.startPpq - gridSlop))
            and (not (rangeType & SELECT_TIME_MAXRANGE ~= 0) or event.ppqpos <= (eventData.endPpq + gridSlop))
          then
            if eventType == NOTE_TYPE then mu.MIDI_DeleteNote(take, event.idx)
            elseif eventType == CC_TYPE then mu.MIDI_DeleteCC(take, event.idx)
            elseif eventType == SYXTEXT_TYPE then mu.MIDI_DeleteTextSysexEvt(take, event.idx)
            end
          end
        elseif rangeType == SELECT_TIME_INDIVIDUAL then
          for _, v in ipairs(eventData) do
            if event.ppqpos >= (v - gridSlop) and event.ppqpos <= (v + gridSlop) then
              if eventType == NOTE_TYPE then mu.MIDI_DeleteNote(take, event.idx)
              elseif eventType == CC_TYPE then mu.MIDI_DeleteCC(take, event.idx)
              elseif eventType == SYXTEXT_TYPE then mu.MIDI_DeleteTextSysexEvt(take, event.idx)
              end
              break
            end
          end
        end
      end
    end
  end

  PreProcessSelection(take)
  for _, event in ipairs(eventTab) do
    local eventType = GetEventType(event)
    -- handle insert, also type changes
    if eventType == NOTE_TYPE then
      if not event.orig_type or event.orig_type == NOTE_TYPE then
        mu.MIDI_SetNote(take, event.idx, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.msg2, event.msg3, event.relvel)
      else
        mu.MIDI_InsertNote(take, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.msg2, event.msg3, event.relvel)
        if event.orig_type == CC_TYPE then
          mu.MIDI_DeleteCC(take, event.idx)
        elseif event.orig_type == SYXTEXT_TYPE then
          mu.MIDI_DeleteTextSysexEvt(take, event.idx)
        end
      end
    elseif eventType == CC_TYPE then
      if not event.orig_type or event.orig_type == CC_TYPE then
        mu.MIDI_SetCC(take, event.idx, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3)
        if event.setcurve then
          mu.MIDI_SetCCShape(take, event.idx, event.setcurve, event.setcurveext)
        end
      else
        local rv, newidx = mu.MIDI_InsertCC(take, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3)
        if rv and event.setcurve then
          mu.MIDI_SetCCShape(take, newidx, event.setcurve, event.setcurveext)
        end
        if event.orig_type == NOTE_TYPE then
          mu.MIDI_DeleteNote(take, event.idx)
        elseif event.orig_type == SYXTEXT_TYPE then
          mu.MIDI_DeleteTextSysexEvt(take, event.idx)
        end
      end
    elseif eventType == SYXTEXT_TYPE then
      if not event.orig_type or event.orig_type == SYXTEXT_TYPE then
        mu.MIDI_SetTextSysexEvt(take, event.idx, event.selected, event.muted, event.ppqpos, event.chanmsg == 0xF0 and event.chanmsg or event.msg2, event.textmsg)
      else
        if event.orig_type == NOTE_TYPE then
          mu.MIDI_DeleteNote(take, event.idx)
        elseif event.orig_type == CC_TYPE then
          mu.MIDI_DeleteCC(take, event.idx)
        end
      end
    end
  end
  HandleCreateNewMIDIEvent(take, contextTab)
  mu.MIDI_CommitWriteTransaction(take, false, true)
end

function NewTakeInNewTrack(take)
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

function NewTakeInNewLane(take)
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

function GrabAllTakes()
  enumTakesMode = nil -- refresh

  local take = GetNextTake()
  if not take then return {} end

  local takes = {}
  local activeTake

  local activeEditor = r.MIDIEditor_GetActive()
  if activeEditor then
    activeTake = r.MIDIEditor_GetTake(activeEditor)
  end

  while take do
    local _, _, _, ppqpos = r.MIDI_GetEvt(take, 0)
    local projTime = r.MIDI_GetProjTimeFromPPQPos(take, ppqpos) + GetTimeOffset()
    local active = take == activeTake and true or false
    table.insert(takes, { take = take, firstTime = projTime, active = active })
    take = GetNextTake()
  end
  table.sort(takes, function(a, b)
      if a.active then return true
      elseif b.active then return false
      else return a.firstTime < b.firstTime
      end
    end)
  return takes
end

function ProcessActionForTake(take)
  local fnString = ''

  context.PPQ = take and mu.MIDI_GetPPQ(take) or 960

  local iterTab = {}
  for _, v in ipairs(actionRowTable) do
    if not (v.except or v.disabled) then
      table.insert(iterTab, v)
    end
  end

  for k, v in ipairs(iterTab) do
    local row = v
    local opTab, param1Tab, param2Tab, curTarget, curOperation = ActionTabsFromTarget(v)

    if #opTab == 0 then return end -- continue?

    local targetTerm = curTarget.text
    local operation = curOperation
    local operationVal = operation.text
    local actionTerm = ''

    local paramTerms = { ProcessParams(v, curTarget, curOperation, { param1Tab, param2Tab, {} }, false, context) }

    if paramTerms[1] == '' and curOperation.terms ~= 0 then return end

    local paramNums = { tonumber(paramTerms[1]), tonumber(paramTerms[2]), tonumber(paramTerms[3]) }
    if paramNums[1] and paramNums[2] and paramNums[2] < paramNums[1]
      and not curOperation.freeterm
    then
      local tmp = paramTerms[2]
      paramTerms[2] = paramTerms[1]
      paramTerms[1] = tmp
    end

    local paramTypes = GetParamTypesForRow(v, curTarget, curOperation)
    for i = 1, 3 do -- param3
      if paramNums[i] and (paramTypes[i] == PARAM_TYPE_INTEDITOR or paramTypes[i] == PARAM_TYPE_FLOATEDITOR) and row.params[i].percentVal then
        paramTerms[i] = GetParamPercentTerm(paramNums[i], opIsBipolar(curOperation, i))
      end
    end

    -- always sub
    actionTerm = operationVal
    actionTerm = string.gsub(actionTerm, '{tgt}', targetTerm)
    actionTerm = string.gsub(actionTerm, '{param1}', tostring(paramTerms[1]))
    actionTerm = string.gsub(actionTerm, '{param2}', tostring(paramTerms[2]))
    if curOperation.notation == ':relrandomsingle' then
      actionTerm = string.gsub(actionTerm, '{randomsingle}', tostring(math.random()))
    end
    if row.params[3] and isValidString(row.params[3].textEditorStr) then
      actionTerm = string.gsub(actionTerm, '{param3}', row.params[3].funArg and row.params[3].funArg(row, curTarget, curOperation, paramTerms[3]) or row.params[3].textEditorStr)
    end

    local isMusical = paramTypes[1] == PARAM_TYPE_MUSICAL and true or false
    if isMusical then
      local mgParams = tableCopy(row.mg)
      mgParams.param1 = paramNums[1]
      mgParams.param2 = paramTerms[2]
      actionTerm = string.gsub(actionTerm, '{musicalparams}', serialize(mgParams))
    end

    local isNewMIDIEvent = paramTypes[1] == PARAM_TYPE_NEWMIDIEVENT and true or false
    if isNewMIDIEvent then
      -- local nmeParams = tableCopy(row.nme)
      CreateNewMIDIEvent_Once = true
      -- actionTerm = string.gsub(actionTerm, '{neweventparams}', serialize(nmeParams))
    end

    actionTerm = string.gsub(actionTerm, '^%s*(.-)%s*$', '%1') -- trim whitespace

    local rowStr = actionTerm
    if curTarget.cond then
      rowStr = 'if ' .. curTarget.cond .. ' then ' .. rowStr .. ' end'
    end
    -- mu.post(k .. ': ' .. rowStr)

    fnString = fnString == '' and (' ' .. rowStr .. '\n') or (fnString .. ' ' .. rowStr .. '\n')
  end

  fnString = 'return function(event, _value1, _value2, _context)\n' .. fnString .. '\n return event' .. '\nend'

  if DEBUGPOST then
    mu.post('======== ACTION FUN ========')
    mu.post(fnString)
    mu.post('============================')
  end

  return fnString
end

function ItemInTable(it, t)
  for i = 1, #t do
    if it == t[i] then return true end
  end
  return false
end

function ProcessAction(execute, fromScript)
  mediaItemCount = nil
  mediaItemIndex = nil

  if fromScript
    and findScopeTable[currentFindScope].notation == '$midieditor'
  then
    local _, _, sectionID = r.get_action_context()
    local canOverride = true

    -- experimental support for main-context selection consideration
    -- IF the active MIDI Editor
    if sectionID == 0 then
      local found = false
      local meTakes = {}
      local me = r.MIDIEditor_GetActive()
      if me then
        local selCount = r.CountSelectedMediaItems(0)
        if selCount > 0 then
          local ec = 0
          while true do
            local etake = r.MIDIEditor_EnumTakes(me, ec, GetEnumTakesMode())
            if not etake then break end
            table.insert(meTakes, etake)
            ec = ec + 1
          end
          if #meTakes ~= 0 then
            found = true -- assume it works
            for i = 0, selCount - 1 do
              local item = r.GetSelectedMediaItem(0, i)
              if item then
                local itake = r.GetActiveTake(item)
                if not ItemInTable(itake, meTakes) then
                  found = false
                  break
                end
              end
            end
          end
        end
      end
      if not found then
        currentFindScope = 2 -- '$selected'
      else
        canOverride = false
      end
    end

    if sectionID == 0
      and scriptIgnoreSelectionInArrangeView
      and currentFindScopeFlags ~= FIND_SCOPE_FLAG_NONE
      and canOverride
    then
      currentFindScopeFlags = FIND_SCOPE_FLAG_NONE -- eliminate all find scope flags
    end
  end

  local takes = GrabAllTakes()
  if #takes == 0 then return end

  CACHED_METRIC = nil
  CACHED_WRAPPED = nil
  SOM = nil

  moveCursorFirstEventPosition = nil
  addLengthFirstEventOffset = nil

  -- fast early return after sanity check
  if not execute then
    local findFn = ProcessFind()
    if findFn then
      local fnString = ProcessActionForTake()
      if fnString then
        FnStringToFn(fnString, function(err)
          if err then
            mu.post(err)
          end
          parserError = 'Fatal error: could not load action description'
        end)
      else
        parserError = 'Fatal error: could not load action description'
      end
    end
    return
  end

  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)

  for _, v in ipairs(takes) do
    local take = v.take
    InitializeTake(take)

    moveCursorFirstEventPosition_Take = nil
    addLengthFirstEventOffset_Take = nil
    addLengthFirstEventStartTime = nil

    local actionFn
    local actionFnString
    local findFn, wantsEventPreprocessing, findRange, findFnString = ProcessFind(take, nil)
    if findFn then
      actionFnString = ProcessActionForTake(take)
      if actionFnString then
        _, actionFn = FnStringToFn(actionFnString, function(err)
          if err then
            mu.post(err)
          end
          parserError = 'Fatal error: could not load action description'
        end)
      else
        parserError = 'Fatal error: could not load action description'
      end
    end

    if findFn and actionFn then
      local function canProcess(found)
        return #found ~=0 or CreateNewMIDIEvent_Once
      end

      local notation = actionScopeTable[currentActionScope].notation
      local defParams = {
        wantsEventPreprocessing = wantsEventPreprocessing,
        findRange = findRange,
        take = take,
        PPQ = context.PPQ,
        findFnString = findFnString,
        actionFnString = actionFnString,
      }
      local selectonly = actionScopeTable[currentActionScope].selectonly
      local extentsstate = mu.CORRECT_EXTENTS
      mu.CORRECT_EXTENTS = not selectonly and extentsstate or false
      if notation == '$select' then
        mu.MIDI_OpenWriteTransaction(take)
        local found = RunFind(findFn, defParams)
        mu.MIDI_SelectAll(take, false)
        SelectEntriesInTake(take, found, true)
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$selectadd' then
        mu.MIDI_OpenWriteTransaction(take)
        RunFind(findFn, defParams,
          function(event, matches)
            if matches then
              event.selected = true
              SetEntrySelectionInTake(take, event)
            end
          end)
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$invertselect' then
        mu.MIDI_OpenWriteTransaction(take)
        local found = RunFind(findFn, defParams)
        mu.MIDI_SelectAll(take, true)
        SelectEntriesInTake(take, found, false)
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$deselect' then
        mu.MIDI_OpenWriteTransaction(take)
        RunFind(findFn, defParams,
          function(event, matches)
            if matches then
              event.selected = false
              SetEntrySelectionInTake(take, event)
            end
          end)
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$transform' then
        local found, contextTab = RunFind(findFn, defParams)
        if canProcess(found) then
          TransformEntryInTake(take, found, actionFn, contextTab) -- could use runFn
        end
      elseif notation == '$replace' then
        local repParams = tableCopy(defParams)
        repParams.wantsUnfound = true
        repParams.addRangeEvents = true
        local found, contextTab, unfound = RunFind(findFn, repParams)
        if canProcess(found) then
          TransformEntryInTake(take, found, actionFn, contextTab, unfound) -- could use runFn
        end
      elseif notation == '$copy' then
        local found, contextTab = RunFind(findFn, defParams)
        if canProcess(found) then
          local newtake = NewTakeInNewTrack(take)
          if newtake then
            InsertEventsIntoTake(newtake, found, actionFn, contextTab)
          end
        end
      elseif notation == '$copylane' then
        if te.isREAPER7() then
          local found, contextTab = RunFind(findFn, defParams)
          if canProcess(found) then
            local newtake = NewTakeInNewLane(take)
            if newtake then
              InsertEventsIntoTake(newtake, found, actionFn, contextTab)
            end
          end
        end
      elseif notation == '$insert' then
        local found, contextTab = RunFind(findFn, defParams)
        if canProcess(found) then
          InsertEventsIntoTake(take, found, actionFn, contextTab) -- could use runFn
        end
      elseif notation == '$insertexclusive' then
        local ieParams = tableCopy(defParams)
        ieParams.wantsUnfound = true
        local found, contextTab, unfound = RunFind(findFn, ieParams)
        mu.MIDI_OpenWriteTransaction(take)
        if canProcess(found) then
          InsertEventsIntoTake(take, found, actionFn, contextTab, false)
          if unfound and #unfound ~=0 then
            DeleteEventsInTake(take, unfound, false)
          end
        end
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$extracttrack' then
        local found, contextTab = RunFind(findFn, defParams)
        if canProcess(found) then
          local newtake = NewTakeInNewTrack(take)
          if newtake then
            InsertEventsIntoTake(newtake, found, actionFn, contextTab)
          end
          DeleteEventsInTake(take, found)
        end
      elseif notation == '$extractlane' then
        if te.isREAPER7() then
          local found, contextTab = RunFind(findFn, defParams)
          if canProcess(found) then
            local newtake = NewTakeInNewLane(take)
            if newtake then
              InsertEventsIntoTake(newtake, found, actionFn, contextTab)
            end
            DeleteEventsInTake(take, found)
          end
        end
      elseif notation == '$delete' then
        local found = RunFind(findFn, defParams)
        if #found ~= 0 then
          DeleteEventsInTake(take, found) -- could use runFn
        end
      end
      mu.CORRECT_EXTENTS = extentsstate
    end
  end

  r.PreventUIRefresh(-1)
  r.Undo_EndBlock2(0, 'Transformer: ' .. actionScopeTable[currentActionScope].label, -1)
end

function SetPresetNotesBuffer(buf)
  libPresetNotesBuffer = buf
end

function GetCurrentPresetState()
  local fsFlags
  if findScopeTable[currentFindScope].notation == '$midieditor' then
    fsFlags = {} -- not pretty
    if currentFindScopeFlags & FIND_SCOPE_FLAG_SELECTED_ONLY ~= 0 then table.insert(fsFlags, '$selectedonly') end
    if currentFindScopeFlags & FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW ~= 0 then table.insert(fsFlags, '$activenoterow') end
  end

  local ppInfo
  if currentFindPostProcessingInfo.flags ~= FIND_POSTPROCESSING_FLAG_NONE then
    local ppFlags = currentFindPostProcessingInfo.flags
    ppInfo = tableCopy(currentFindPostProcessingInfo)
    ppInfo.flags = {}
    if ppFlags & FIND_POSTPROCESSING_FLAG_FIRSTEVENT ~= 0 then table.insert(ppInfo.flags, '$firstevent') end
    if ppFlags & FIND_POSTPROCESSING_FLAG_LASTEVENT ~= 0 then table.insert(ppInfo.flags, '$lastevent') end
  end

  local presetTab = {
    findScope = findScopeTable[currentFindScope].notation,
    findScopeFlags = fsFlags,
    findMacro = FindRowsToNotation(),
    findPostProcessing = ppInfo,
    actionScope = actionScopeTable[currentActionScope].notation,
    actionMacro = ActionRowsToNotation(),
    actionScopeFlags = actionScopeFlagsTable[currentActionScopeFlags].notation,
    notes = libPresetNotesBuffer,
    scriptIgnoreSelectionInArrangeView = false
  }
  return presetTab
end

function SavePreset(pPath, scriptTab)
  local f = io.open(pPath, 'wb')
  local saved = false
  local wantsScript = scriptTab.script
  local ignoreSelectionInArrangeView = wantsScript and scriptTab.ignoreSelectionInArrangeView
  local scriptPrefix = scriptTab.scriptPrefix

  if f then
    local presetTab = GetCurrentPresetState()
    presetTab.scriptIgnoreSelectionInArrangeView = ignoreSelectionInArrangeView
    f:write(serialize(presetTab) .. '\n')
    f:close()
    saved = true
  end

  local scriptPath

  if saved and wantsScript then
    saved = false

    local fPath, fName = pPath:match('^(.*[/\\])(.*)$')
    if fPath and fName then
      local fRoot = fName:match('(.*)%.')
      if fRoot then
        scriptPath = fPath .. scriptPrefix .. fRoot .. '.lua'
        f = io.open(scriptPath, 'wb')
        if f then
          f:write('package.path = reaper.GetResourcePath() .. "/Scripts/sockmonkey72 Scripts/MIDI Editor/Transformer/?.lua"\n')
          f:write('local tx = require("TransformerLib")\n')
          f:write('local thisPath = debug.getinfo(1, "S").source:match [[^@?(.*[\\/])[^\\/]-$]]\n')
          f:write('tx.loadPreset(thisPath .. "' .. fName .. '")\n')
          f:write('tx.processAction(true, true)\n')
          f:close()
          saved = true
        end
      end
    end
  end
  return saved, scriptPath
end

local undoTable = {}
local undoPointer = 0
local undoSuspended = false

function SuspendUndo()
  undoSuspended = true
end

function ResumeUndo()
  undoSuspended = false
end

function CreateUndoStep(state)
  if undoSuspended then return end
  while undoPointer > 1 do
    table.remove(undoTable, 1)
    undoPointer = undoPointer - 1
  end
  table.insert(undoTable, 1, state and state or GetCurrentPresetState())
  undoPointer = 1
end

function LoadPresetFromTable(presetTab)
  currentFindScopeFlags = FIND_SCOPE_FLAG_NONE -- do this first (FindScopeFromNotation() may populate it)
  currentFindScope = FindScopeFromNotation(presetTab.findScope)
  local fsFlags = presetTab.findScopeFlags -- not pretty
  if fsFlags then
    for _, v in ipairs(fsFlags) do
      currentFindScopeFlags = currentFindScopeFlags | FindScopeFlagFromNotation(v)
    end
  end
  if presetTab.findPostProcessing then
    local ppFlags = presetTab.findPostProcessing.flags
    currentFindPostProcessingInfo = tableCopy(presetTab.findPostProcessing)
    currentFindPostProcessingInfo.flags = FIND_POSTPROCESSING_FLAG_NONE
    if ppFlags then
      for _, v in ipairs(ppFlags) do
        currentFindPostProcessingInfo.flags = currentFindPostProcessingInfo.flags | FindPostProcessingFlagFromNotation(v)
      end
    end
  end
  currentActionScope = ActionScopeFromNotation(presetTab.actionScope)
  currentActionScopeFlags = ActionScopeFlagsFromNotation(presetTab.actionScopeFlags)
  findRowTable = {}
  ProcessFindMacro(presetTab.findMacro)
  actionRowTable = {}
  ProcessActionMacro(presetTab.actionMacro)
  scriptIgnoreSelectionInArrangeView = presetTab.scriptIgnoreSelectionInArrangeView
  return presetTab.notes
end

function LoadPreset(pPath)
  local f = io.open(pPath, 'r')
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
      if isValidString(tabStr) then
        local presetTab = deserialize(tabStr)
        if presetTab then
          local notes = LoadPresetFromTable(presetTab)
          dirtyFind = true
          return true, notes, presetTab.scriptIgnoreSelectionInArrangeView
        end
      end
    end
  end
  return false, nil
end

-- literal means (-16394/0) - 16393, otherwise it's -8192 - 8191 and needs to be shifted
function PitchBendTo14Bit(val, literal)
  if not literal then
    if val < 0 then val = val + (1 << 13) else val = val + ((1 << 13) - 1) end
  end
  return (val / ((1 << 14) - 1)) * 100
end

function SetRowParam(row, index, paramType, editorType, strVal, range, literal)
  local isMetricOrMusical = (paramType == PARAM_TYPE_METRICGRID or paramType == PARAM_TYPE_MUSICAL)
  local isNewMIDIEvent = paramType == PARAM_TYPE_NEWMIDIEVENT
  local isBitField = editorType == EDITOR_TYPE_BITFIELD
  row.params[index].textEditorStr = (isMetricOrMusical or isBitField or isNewMIDIEvent) and strVal or EnsureNumString(strVal, range)
  if (isMetricOrMusical or isBitField or isNewMIDIEvent) or not editorType then
    row.params[index].percentVal = nil
    -- nothing
  else
    local val = tonumber(row.params[index].textEditorStr)
    if editorType == EDITOR_TYPE_PERCENT or editorType == EDITOR_TYPE_PERCENT_BIPOLAR then
      row.params[index].percentVal = literal and nil or val
    elseif editorType == EDITOR_TYPE_PITCHBEND or editorType == EDITOR_TYPE_PITCHBEND_BIPOLAR then
      row.params[index].percentVal = PitchBendTo14Bit(val, literal or editorType == EDITOR_TYPE_PITCHBEND_BIPOLAR)
    elseif editorType == EDITOR_TYPE_7BIT or editorType == EDITOR_TYPE_7BIT_NOZERO or editorType == EDITOR_TYPE_7BIT_BIPOLAR then
      row.params[index].percentVal = (val / ((1 << 7) - 1)) * 100
    end
  end
end

function GetRowParamRange(row, target, condOp, paramType, editorType, idx)
  local range = ((condOp.split and condOp.split[idx].norange) or condOp.norange) and {}
                  or (condOp.split and condOp.split[idx].range) and condOp.split[idx].range
                  or condOp.range and condOp.range
                  or target.range
  local bipolar = false

  if condOp.percent or (condOp.split and condOp.split[idx].percent) then range = TransformerLib.EDITOR_PERCENT_RANGE
  elseif editorType == EDITOR_TYPE_PITCHBEND then range = TransformerLib.EDITOR_PITCHBEND_RANGE
  elseif editorType == EDITOR_TYPE_PITCHBEND_BIPOLAR then range = TransformerLib.EDITOR_PITCHBEND_BIPOLAR_RANGE bipolar = true
  elseif editorType == EDITOR_TYPE_PERCENT then range = TransformerLib.EDITOR_PERCENT_RANGE
  elseif editorType == EDITOR_TYPE_PERCENT_BIPOLAR then range = TransformerLib.EDITOR_PERCENT_BIPOLAR_RANGE bipolar = true
  elseif editorType == EDITOR_TYPE_7BIT then range = TransformerLib.EDITOR_7BIT_RANGE
  elseif editorType == EDITOR_TYPE_7BIT_BIPOLAR then range = TransformerLib.EDITOR_7BIT_BIPOLAR_RANGE bipolar = true
  elseif editorType == EDITOR_TYPE_7BIT_NOZERO then range = TransformerLib.EDITOR_7BIT_NOZERO_RANGE
  elseif editorType == EDITOR_TYPE_14BIT then range = TransformerLib.EDITOR_14BIT_RANGE
  elseif editorType == EDITOR_TYPE_14BIT_BIPOLAR then range = TransformerLib.EDITOR_14BIT_BIPOLAR_RANGE bipolar = true
  end

  if range and #range == 0 then range = nil end
  return range, bipolar
end

function GetRowTextAndParameterValues(row)
  local _, param1Tab, param2Tab, curTarget, curOperation = ActionTabsFromTarget(row)
  local rowText = curTarget.notation .. ' ' .. curOperation.notation

  local paramTypes = GetParamTypesForRow(row, curTarget, curOperation)

  local param1Val, param2Val, param3Val = ProcessParams(row, curTarget, curOperation, { param1Tab, param2Tab, {} }, true, { PPQ = 960 } )
  if paramTypes[1] == PARAM_TYPE_MENU then
    param1Val = (curOperation.terms > 0 and #param1Tab) and param1Tab[row.params[1].menuEntry].notation or nil
  end
  if paramTypes[2] == PARAM_TYPE_MENU then
    param2Val = (curOperation.terms > 1 and #param2Tab) and param2Tab[row.params[2].menuEntry].notation or nil
  end
  return rowText, param1Val, param2Val, param3Val
end

function HandlePercentString(strVal, row, target, condOp, paramType, editorType, index, range, bipolar)
  if not range then
    range, bipolar = GetRowParamRange(row, target, condOp, paramType, editorType, index)
  end

  if range and range[1] and range[2] and row.params[index].percentVal then
    local percentVal = row.params[index].percentVal / 100
    local scaledVal
    if editorType == EDITOR_TYPE_PITCHBEND and condOp.literal then
      scaledVal = percentVal * ((1 << 14) - 1)
    elseif bipolar then
      scaledVal = percentVal * range[2]
    else
      scaledVal = (percentVal * (range[2] - range[1])) + range[1]
    end
    if paramType == PARAM_TYPE_INTEDITOR then
      scaledVal = math.floor(scaledVal + 0.5)
    end
    strVal = tostring(scaledVal)
  end
  return strVal
end

function Update(action, wantsState)
  if not action then
    ProcessFind()
  else
    ProcessAction()
  end

  local nowState = GetCurrentPresetState()
  CreateUndoStep(nowState)
  return wantsState and nowState or nil
end

local lastHasTable = {}

function GetHasTable()
  local fresh = false
  if dirtyFind then
    local hasTable = {}

    mediaItemCount = nil
    mediaItemIndex = nil

    local takes = GrabAllTakes()

    CACHED_METRIC = nil
    CACHED_WRAPPED = nil
    SOM = nil

    local count = 0

    for _, v in ipairs(takes) do
      InitializeTake(v.take)
      local findFn, _, findRange = ProcessFind(v.take, true)
      local _, contextTab = RunFind(findFn, { wantsEventPreprocessing = true, findRange = findRange, take = v.take, PPQ = mu.MIDI_GetPPQ(v.take) })
      local tab = contextTab.hasTable
      for kk, vv in pairs(tab) do
        if vv == true then
          hasTable[kk] = true
          count = count + 1
        end
      end
    end

    if count == 0 then
      for kk, vv in pairs(wantsTab) do
        if vv == true then
          hasTable[kk] = true
          count = count + 1
        end
      end
    end

    if count == 0 then
      hasTable[0x90] = true -- if there's really nothing, just display as if it's notes-only
      count = count + 1
    end

    hasTable._size = count
    dirtyFind = false
    lastHasTable = hasTable
    fresh = true
  end
  return lastHasTable, fresh
end

TransformerLib.findScopeTable = findScopeTable
TransformerLib.currentFindScope = function() return currentFindScope end
TransformerLib.setCurrentFindScope = function(val)
  currentFindScope = val < 1 and 1 or val > #findScopeTable and #findScopeTable or val
end
TransformerLib.getFindScopeFlags = function() return currentFindScopeFlags end
TransformerLib.setFindScopeFlags = function(flags)
  currentFindScopeFlags = flags
end
TransformerLib.getFindPostProcessingInfo = function() return currentFindPostProcessingInfo end
TransformerLib.setFindPostProcessingInfo = function(info)
  currentFindPostProcessingInfo = info -- could add error checking, but nope
end
TransformerLib.clearFindPostProcessingInfo = ClearFindPostProcessingInfo
TransformerLib.actionScopeTable = actionScopeTable
TransformerLib.currentActionScope = function() return currentActionScope end
TransformerLib.setCurrentActionScope = function(val)
  currentActionScope = val < 1 and 1 or val > #actionScopeTable and #actionScopeTable or val
end
TransformerLib.actionScopeFlagsTable = actionScopeFlagsTable
TransformerLib.currentActionScopeFlags = function() return currentActionScopeFlags end
TransformerLib.setCurrentActionScopeFlags = function(val)
  currentActionScopeFlags = val < 1 and 1 or val > #actionScopeFlagsTable and #actionScopeFlagsTable or val
end

TransformerLib.ParamInfo = ParamInfo

TransformerLib.FindRow = FindRow
TransformerLib.findRowTable = function() return findRowTable end
TransformerLib.clearFindRows = function() findRowTable = {} end

TransformerLib.startParenEntries = startParenEntries
TransformerLib.endParenEntries = endParenEntries
TransformerLib.findBooleanEntries = findBooleanEntries
TransformerLib.findTimeFormatEntries = findTimeFormatEntries

TransformerLib.ActionRow = ActionRow
TransformerLib.actionRowTable = function() return actionRowTable end
TransformerLib.clearActionRows = function() actionRowTable = {} end

TransformerLib.findTargetEntries = findTargetEntries
TransformerLib.actionTargetEntries = actionTargetEntries

TransformerLib.getSubtypeValueLabel = GetSubtypeValueLabel
TransformerLib.getMainValueLabel = GetMainValueLabel

TransformerLib.processFindMacro = ProcessFindMacro
TransformerLib.processActionMacro = ProcessActionMacro

TransformerLib.processFind = ProcessFind
TransformerLib.processAction = ProcessAction

TransformerLib.savePreset = SavePreset
TransformerLib.loadPreset = LoadPreset

TransformerLib.timeFormatRebuf = TimeFormatRebuf
TransformerLib.lengthFormatRebuf = LengthFormatRebuf

TransformerLib.getParamTypesForRow = GetParamTypesForRow
TransformerLib.findTabsFromTarget = FindTabsFromTarget
TransformerLib.actionTabsFromTarget = ActionTabsFromTarget
TransformerLib.findRowToNotation = FindRowToNotation
TransformerLib.actionRowToNotation = ActionRowToNotation

TransformerLib.setRowParam = SetRowParam
TransformerLib.getRowParamRange = GetRowParamRange

TransformerLib.getHasTable = GetHasTable

TransformerLib.setEditorTypeForRow = function(row, idx, type)
  row.params[idx].editorType = type
end

TransformerLib.getFindScopeFlagLabel = function()
  local label = ''
  if currentFindScopeFlags & FIND_SCOPE_FLAG_SELECTED_ONLY ~= 0 then
    label = label .. (label ~= '' and ' + ' or '') .. 'Selected'
  end
  if currentFindScopeFlags & FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW ~= 0 then
    label = label .. (label ~= '' and ' + ' or '') .. 'NoteRow'
  end
  if label == '' then label = 'None' end
  return label
end

TransformerLib.getFindPostProcessingLabel = function()
  local label = ''
  local flags = currentFindPostProcessingInfo.flags
  if flags & FIND_POSTPROCESSING_FLAG_FIRSTEVENT ~= 0 then
    label = label .. (label ~= '' and ' + ' or '') .. 'First'
  end
  if flags & FIND_POSTPROCESSING_FLAG_LASTEVENT ~= 0 then
    label = label .. (label ~= '' and ' + ' or '') .. 'Last'
  end
  if label == '' then label = 'None' end
  return label
end

local function makeDefaultMetricGrid(row, data)
  local isMetric = data.isMetric
  local metricLastUnit = data.metricLastUnit
  local musicalLastUnit = data.musicalLastUnit
  local metricLastBarRestart = data.metricLastBarRestart

  row.params[1].menuEntry = isMetric and metricLastUnit or musicalLastUnit
  -- row.params[2].textEditorStr = '0' -- don't overwrite defaults
  row.mg = {
    wantsBarRestart = metricLastBarRestart,
    preSlopPercent = 0,
    postSlopPercent = 0,
    modifiers = 0
  }
  return row.mg
end

local function makeDefaultEveryN(row)
  row.params[1].menuEntry = 1
  -- row.params[2].textEditorStr = '0' -- don't overwrite defaults
  row.evn = {
    pattern = '1',
    interval = 1,
    offset = 0,
    textEditorStr = '1',
    offsetEditorStr = '0',
    isBitField = false
  }
  return row.evn
end

local function makeDefaultNewMIDIEvent(row)
  row.params[1].menuEntry = 1
  row.params[2].menuEntry = 1
  row.nme = {
    chanmsg = 0x90,
    channel = 0,
    selected = true,
    muted = false,
    msg2 = 60,
    msg3 = 64,
    posText = DEFAULT_TIMEFORMAT_STRING,
    durText = '0.1.00', -- one beat long as a default?
    relvel = 0,
    projtime = 0,
    projlen = 1,
    posmode = NEWEVENT_POSITION_ATCURSOR,
  }
end

local function makeDefaultEventSelector(row)
  row.params[1].menuEntry = 1
  row.params[2].menuEntry = 4 -- $1/16
  row.evsel = {
    chanmsg = 0x00,
    channel = -1,
    selected = -1,
    muted = -1,
    useval1 = false,
    msg2 = 60,
    scale = 100,
    scaleStr = '100'
  }
end

TransformerLib.FIND_SCOPE_FLAG_NONE = FIND_SCOPE_FLAG_NONE
TransformerLib.FIND_SCOPE_FLAG_SELECTED_ONLY = FIND_SCOPE_FLAG_SELECTED_ONLY
TransformerLib.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW = FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW

TransformerLib.FIND_POSTPROCESSING_FLAG_NONE = FIND_POSTPROCESSING_FLAG_NONE
TransformerLib.FIND_POSTPROCESSING_FLAG_FIRSTEVENT = FIND_POSTPROCESSING_FLAG_FIRSTEVENT
TransformerLib.FIND_POSTPROCESSING_FLAG_LASTEVENT = FIND_POSTPROCESSING_FLAG_LASTEVENT

TransformerLib.PARAM_TYPE_UNKNOWN = PARAM_TYPE_UNKNOWN
TransformerLib.PARAM_TYPE_MENU = PARAM_TYPE_MENU
TransformerLib.PARAM_TYPE_INTEDITOR = PARAM_TYPE_INTEDITOR
TransformerLib.PARAM_TYPE_FLOATEDITOR = PARAM_TYPE_FLOATEDITOR
TransformerLib.PARAM_TYPE_TIME = PARAM_TYPE_TIME
TransformerLib.PARAM_TYPE_TIMEDUR = PARAM_TYPE_TIMEDUR
TransformerLib.PARAM_TYPE_METRICGRID = PARAM_TYPE_METRICGRID
TransformerLib.PARAM_TYPE_MUSICAL = PARAM_TYPE_MUSICAL
TransformerLib.PARAM_TYPE_EVERYN = PARAM_TYPE_EVERYN
TransformerLib.PARAM_TYPE_NEWMIDIEVENT = PARAM_TYPE_NEWMIDIEVENT
TransformerLib.PARAM_TYPE_PARAM3 = PARAM_TYPE_PARAM3
TransformerLib.PARAM_TYPE_EVENTSELECTOR = PARAM_TYPE_EVENTSELECTOR
TransformerLib.PARAM_TYPE_HIDDEN = PARAM_TYPE_HIDDEN

TransformerLib.EDITOR_TYPE_PITCHBEND = EDITOR_TYPE_PITCHBEND
TransformerLib.EDITOR_PITCHBEND_RANGE = { -(1 << 13), (1 << 13) - 1 }
TransformerLib.EDITOR_TYPE_PITCHBEND_BIPOLAR = EDITOR_TYPE_PITCHBEND_BIPOLAR
TransformerLib.EDITOR_PITCHBEND_BIPOLAR_RANGE = { -((1 << 14) - 1), (1 << 14) - 1 }
TransformerLib.EDITOR_TYPE_PERCENT = EDITOR_TYPE_PERCENT
TransformerLib.EDITOR_PERCENT_RANGE = { 0, 100 }
TransformerLib.EDITOR_TYPE_PERCENT_BIPOLAR = EDITOR_TYPE_PERCENT_BIPOLAR
TransformerLib.EDITOR_PERCENT_BIPOLAR_RANGE = { -100, 100 }
TransformerLib.EDITOR_TYPE_14BIT = EDITOR_TYPE_14BIT
TransformerLib.EDITOR_14BIT_RANGE = { 0, (1 << 14) - 1 }
TransformerLib.EDITOR_TYPE_14BIT_BIPOLAR = EDITOR_TYPE_14BIT_BIPOLAR
TransformerLib.EDITOR_14BIT_BIPOLAR_RANGE = { -((1 << 14) - 1), (1 << 14) - 1 }
TransformerLib.EDITOR_TYPE_7BIT = EDITOR_TYPE_7BIT
TransformerLib.EDITOR_7BIT_RANGE = { 0, (1 << 7) - 1 }
TransformerLib.EDITOR_TYPE_7BIT_NOZERO = EDITOR_TYPE_7BIT_NOZERO
TransformerLib.EDITOR_7BIT_NOZERO_RANGE = { 1, (1 << 7) - 1 }
TransformerLib.EDITOR_TYPE_7BIT_BIPOLAR = EDITOR_TYPE_7BIT_BIPOLAR
TransformerLib.EDITOR_7BIT_BIPOLAR_RANGE = { -((1 << 7) - 1), (1 << 7) - 1 }
TransformerLib.EDITOR_TYPE_BITFIELD = EDITOR_TYPE_BITFIELD

TransformerLib.NEWEVENT_POSITION_ATCURSOR = NEWEVENT_POSITION_ATCURSOR
TransformerLib.NEWEVENT_POSITION_ATPOSITION = NEWEVENT_POSITION_ATPOSITION

TransformerLib.setUpdateItemBoundsOnEdit = function(v) mu.CORRECT_EXTENTS = v and true or false end

TransformerLib.makeDefaultMetricGrid = makeDefaultMetricGrid
TransformerLib.makeDefaultEveryN = makeDefaultEveryN
TransformerLib.makeDefaultNewMIDIEvent = makeDefaultNewMIDIEvent
TransformerLib.makeParam3 = function(row)
  local _, _, _, target, operation = ActionTabsFromTarget(row)
  if target.notation == '$position' and operation.notation == ':scaleoffset' then
    te.makeParam3PositionScaleOffset(row)
  elseif operation.notation == ':line' or operation.notation == ':relline' then
    te.makeParam3Line(row)
  end
end
TransformerLib.makeDefaultEventSelector = makeDefaultEventSelector

TransformerLib.startup = startup
TransformerLib.mu = mu
TransformerLib.handlePercentString = HandlePercentString
TransformerLib.isANote = function(target, condOp)
  local isNote = target.notation == '$value1' and not condOp.nixnote
  if isNote then
    local hasTable = GetHasTable()
    isNote = hasTable._size == 1 and hasTable[0x90]
  end
  return isNote
end

TransformerLib.MG_GRID_STRAIGHT = MG_GRID_STRAIGHT
TransformerLib.MG_GRID_DOTTED = MG_GRID_DOTTED
TransformerLib.MG_GRID_TRIPLET = MG_GRID_TRIPLET
TransformerLib.MG_GRID_SWING = MG_GRID_SWING
TransformerLib.GetMetricGridModifiers = GetMetricGridModifiers
TransformerLib.SetMetricGridModifiers = SetMetricGridModifiers

TransformerLib.typeEntriesForEventSelector = typeEntriesForEventSelector
TransformerLib.setPresetNotesBuffer = SetPresetNotesBuffer
TransformerLib.update = Update
TransformerLib.loadPresetFromTable = LoadPresetFromTable

TransformerLib.hasUndoSteps = function()
  local undoStackLen = #undoTable
  if undoStackLen > 1 and undoPointer < undoStackLen then
    return true
  end
  return false
end

TransformerLib.hasRedoSteps = function()
  local undoStackLen = #undoTable
  if undoStackLen > 1 and undoPointer > 1 then
    return true
  end
  return false
end

TransformerLib.popUndo = function()
  local undoStackLen = #undoTable
  if undoStackLen > 1 and undoPointer < undoStackLen then
    undoPointer = undoPointer + 1
    return undoTable[undoPointer]
  end
  return nil
end

TransformerLib.popRedo = function()
  local undoStackLen = #undoTable
  if undoStackLen > 1 and undoPointer > 1 then
    undoPointer = undoPointer - 1
    return undoTable[undoPointer]
  end
  return nil
end

TransformerLib.createUndoStep = CreateUndoStep
TransformerLib.clearUndo = function()
  undoTable = {}
  undoPointer = 0
  CreateUndoStep()
end

TransformerLib.suspendUndo = SuspendUndo
TransformerLib.resumeUndo = ResumeUndo

return TransformerLib

-----------------------------------------------------------------------------
----------------------------------- FIN -------------------------------------
