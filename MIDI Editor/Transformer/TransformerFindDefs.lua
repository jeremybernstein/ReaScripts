--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local FindDefs = {}

-----------------------------------------------------------------------------
-----------------------------------------------------------------------------

local tg = require 'TransformerGlobal'

local FindRow = tg.class(nil, {})

function FindRow:init()
  self.targetEntry = 1
  self.conditionEntry = 1
  self.timeFormatEntry = 1
  self.booleanEntry = 1
  self.startParenEntry = 1
  self.endParenEntry = 1

  self.params = {
    tg.ParamInfo(),
    tg.ParamInfo()
  }
  self.isNot = false
  self.except = nil
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
local findConditionSimilarSlop = { notation = ':similar', label = 'Similar to Selection', text = 'TestEvent2(event, {tgt}, OP_SIMILAR, {param1}, {param2})', terms = 2, fullrange = true, literal = true, freeterm = true, rangelabel = { 'pre-slop', 'post-slop' }, nixnote = true }

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

local function findConditionAddSelectRange(t, r)
  local tt = tg.tableCopy(t)
  tt.timeselect = r
  return tt
end

local findConditionSimilarSlopTime = tg.tableCopy(findConditionSimilarSlop)
findConditionSimilarSlopTime.timedur = true

local SELECT_TIME_SHEBANG = 0
local SELECT_TIME_MINRANGE = 1
local SELECT_TIME_MAXRANGE = 2
local SELECT_TIME_RANGE = 3
local SELECT_TIME_INDIVIDUAL = 4

local findPositionConditionEntries = {
  findConditionAddSelectRange(findConditionEqual, SELECT_TIME_INDIVIDUAL),
  { notation = ':eqslop', label = 'Equal (Slop)', text = 'TestEvent2(event, {tgt}, OP_EQ_SLOP, {param1}, {param2})', terms = 2, split = { { time = true }, { timedur = true } }, freeterm = true, timeselect = SELECT_TIME_RANGE },
  findConditionAddSelectRange(findConditionGreaterThan, SELECT_TIME_MINRANGE),
  findConditionAddSelectRange(findConditionGreaterThanEqual, SELECT_TIME_MINRANGE),
  findConditionAddSelectRange(findConditionLessThan, SELECT_TIME_MAXRANGE),
  findConditionAddSelectRange(findConditionLessThanEqual, SELECT_TIME_MAXRANGE),
  findConditionAddSelectRange(findConditionInRange, SELECT_TIME_RANGE),
  findConditionAddSelectRange(findConditionInRangeExcl, SELECT_TIME_RANGE),
  findConditionAddSelectRange(findConditionSimilarSlopTime, SELECT_TIME_INDIVIDUAL),
  { notation = ':ongrid', label = 'On Grid', text = 'OnGrid(event, {tgt}, take, PPQ)', terms = 0, timeselect = SELECT_TIME_INDIVIDUAL },
  { notation = ':inbarrange', label = 'Inside Bar Range %', text = 'InBarRange(take, PPQ, event, {param1}, {param2})', terms = 2, split = {{ floateditor = true, percent = true }, { floateditor = true, percent = true, default = 100 }}, timeselect = SELECT_TIME_RANGE },
  { notation = ':onmetricgrid', label = 'On Metric Grid', text = 'OnMetricGrid(take, PPQ, event, {metricgridparams})', terms = 2, metricgrid = true, split = {{ }, { bitfield = true, default = '0', rangelabel = 'bitfield' }}, timeselect = SELECT_TIME_INDIVIDUAL },
  { notation = ':cursorpos', label = 'Cursor Position', text = 'CursorPosition(event, {tgt}, r.GetCursorPositionEx(0) + GetTimeOffset(), {param1})', terms = 1, menu = true, notnot = true },
  { notation = ':undereditcursor', label = 'Under Edit Cursor (Slop)', text = 'UnderEditCursor(event, take, PPQ, r.GetCursorPositionEx(0), {param1}, {param2})', terms = 2, split = { { menu = true, default = 4 }, { hidden = true, literal = true } }, freeterm = true },
  { notation = ':intimesel', label = 'Inside Time Selection', text = 'TestEvent2(event, {tgt}, OP_INRANGE_EXCL, GetTimeSelectionStart(), GetTimeSelectionEnd())', terms = 0, timeselect = SELECT_TIME_RANGE },
  { notation = ':inrazor', label = 'Inside Razor Area', text = 'InRazorArea(event, take)', terms = 0, timeselect = SELECT_TIME_RANGE },
  { notation = ':nearevent', label = 'Is Near Event', text = 'IsNearEvent(event, take, PPQ, {eventselectorparams}, {param2})', terms = 2, split = {{ eventselector = true }, { menu = true, default = 4 }}, freeterm = true },
  { notation = ':onmetronome', label = 'On Metronome Tick', text = 'OnMetronome(event, take, PPQ, {param1}, {param2})', terms = 2, split = {{ menu = true, default = 1 }, { floateditor = true, percent = true }}, freeterm = true },
  { notation = ':intakerange', label = 'In Take Range %', text = 'InTakeRange(take, event, {param1}, {param2})', terms = 2, split = {{ floateditor = true, percent = true }, { floateditor = true, percent = true, default = 100 }}, timeselect = SELECT_TIME_RANGE },
  { notation = ':intimeselrange', label = 'In Time Selection Range %', text = 'InTimeSelectionRange(take, event, {param1}, {param2})', terms = 2, split = {{ floateditor = true, percent = true }, { floateditor = true, percent = true, default = 100 }}, timeselect = SELECT_TIME_RANGE },
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

local findPositionMetronomeEntries = {
  { notation = '$a', label = 'A', text = '\'A\'' },
  { notation = '$b', label = 'B', text = '\'B\'' },
  { notation = '$c', label = 'C', text = '\'C\'' },
  { notation = '$d', label = 'D', text = '\'D\'' },
}

local findTypeParam1Entries = tg.tableCopy(typeEntries)
table.insert(findTypeParam1Entries, { notation = '$syx', label = 'System Exclusive', text = '0xF0' })
table.insert(findTypeParam1Entries, { notation = '$txt', label = 'Text', text = '0x100' }) -- special case; these need a new chanmsg

local typeEntriesForEventSelector = tg.tableCopy(typeEntries)
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

local findPositionMusicalSlopEntries = tg.tableCopy(findMusicalParam1Entries)
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

FindDefs.FindRow = FindRow
FindDefs.findRowTable = function() return findRowTable end
FindDefs.addFindRow = addFindRow
FindDefs.clearFindRowTable = function() findRowTable = {} end
FindDefs.startParenEntries = startParenEntries
FindDefs.endParenEntries = endParenEntries
FindDefs.findTargetEntries = findTargetEntries
FindDefs.findGenericConditionEntries = findGenericConditionEntries
FindDefs.findValue1ConditionEntries = findValue1ConditionEntries
FindDefs.findLastEventConditionEntries = findLastEventConditionEntries
FindDefs.findPositionConditionEntries = findPositionConditionEntries
FindDefs.findLengthConditionEntries = findLengthConditionEntries
FindDefs.findTypeConditionEntries = findTypeConditionEntries
FindDefs.findPropertyConditionEntries = findPropertyConditionEntries
FindDefs.findTypeParam1Entries = findTypeParam1Entries
FindDefs.typeEntries = typeEntries
FindDefs.typeEntriesForEventSelector = typeEntriesForEventSelector
FindDefs.findChannelParam1Entries = findChannelParam1Entries
FindDefs.findTimeFormatEntries = findTimeFormatEntries
FindDefs.findCursorParam1Entries = findCursorParam1Entries
FindDefs.findBooleanEntries = findBooleanEntries
-- FindDefs.nornsScales = nornsScales
FindDefs.scaleRoots = scaleRoots
FindDefs.findCCCurveParam1Entries = findCCCurveParam1Entries
FindDefs.findPropertyParam1Entries = findPropertyParam1Entries
FindDefs.findPropertyParam2Entries = findPropertyParam2Entries
FindDefs.findMusicalParam1Entries = findMusicalParam1Entries
FindDefs.findPositionMusicalSlopEntries = findPositionMusicalSlopEntries
FindDefs.findPositionMetronomeEntries = findPositionMetronomeEntries

FindDefs.OP_EQ = OP_EQ
FindDefs.OP_GT = OP_GT
FindDefs.OP_GTE = OP_GTE
FindDefs.OP_LT = OP_LT
FindDefs.OP_LTE = OP_LTE
FindDefs.OP_INRANGE = OP_INRANGE
FindDefs.OP_INRANGE_EXCL = OP_INRANGE_EXCL
FindDefs.OP_EQ_SLOP = OP_EQ_SLOP
FindDefs.OP_SIMILAR = OP_SIMILAR
FindDefs.OP_EQ_NOTE = OP_EQ_NOTE
FindDefs.CURSOR_LT = CURSOR_LT
FindDefs.CURSOR_GT = CURSOR_GT
FindDefs.CURSOR_AT = CURSOR_AT
FindDefs.CURSOR_LTE = CURSOR_LTE
FindDefs.CURSOR_GTE = CURSOR_GTE
FindDefs.CURSOR_UNDER = CURSOR_UNDER
FindDefs.SELECT_TIME_SHEBANG = SELECT_TIME_SHEBANG
FindDefs.SELECT_TIME_MINRANGE = SELECT_TIME_MINRANGE
FindDefs.SELECT_TIME_MAXRANGE = SELECT_TIME_MAXRANGE
FindDefs.SELECT_TIME_RANGE = SELECT_TIME_RANGE
FindDefs.SELECT_TIME_INDIVIDUAL = SELECT_TIME_INDIVIDUAL

local findScopeTable = {
  { notation = '$everywhere', label = 'Everywhere' },
  { notation = '$selected', label = 'Selected Items' },
  { notation = '$midieditor', label = 'Active MIDI Editor' },
  -- { notation = '$midieditorselected', label = 'Active MIDI Editor / Selected Events' }
}

local FIND_SCOPE_FLAG_NONE = 0x00
local FIND_SCOPE_FLAG_SELECTED_ONLY = 0x01
local FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW = 0x02

local function findScopeFromNotation(notation)
  if notation then
    if notation == '$midieditorselected' then
      return findScopeFromNotation('$midieditor'), FIND_SCOPE_FLAG_SELECTED_ONLY
    end
    for k, v in ipairs(findScopeTable) do
      if v.notation == notation then
        return k
      end
    end
  end
  return findScopeFromNotation('$midieditor') -- default
end

local findScopeFlagsTable = {
  { notation = '$selectedonly', label = 'Selected Events', flag = FIND_SCOPE_FLAG_SELECTED_ONLY },
  { notation = '$activenoterow', label = 'Active Note Row (notes only)', flag = FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW },
}

local function findScopeFlagFromNotation(notation)
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

local findPostProcessingTable = {
  { notation = '$firstevent', flag = FIND_POSTPROCESSING_FLAG_FIRSTEVENT },
  { notation = '$lastevent', flag = FIND_POSTPROCESSING_FLAG_LASTEVENT },
}

local function findPostProcessingFlagFromNotation(notation)
  if notation then
    for _, v in ipairs(findPostProcessingTable) do
      if v.notation == notation then
        return v.flag
      end
    end
  end
  return FIND_POSTPROCESSING_FLAG_NONE -- default
end

FindDefs.findScopeTable = findScopeTable
-- FindDefs.findScopeFlagsTable = findScopeFlagsTable
FindDefs.findScopeFromNotation = findScopeFromNotation
FindDefs.findScopeFlagFromNotation = findScopeFlagFromNotation
-- FindDefs.findPostProcessingTable = findPostProcessingTable
FindDefs.findPostProcessingFlagFromNotation = findPostProcessingFlagFromNotation

FindDefs.FIND_SCOPE_FLAG_NONE = FIND_SCOPE_FLAG_NONE
FindDefs.FIND_SCOPE_FLAG_SELECTED_ONLY = FIND_SCOPE_FLAG_SELECTED_ONLY
FindDefs.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW = FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW
FindDefs.FIND_POSTPROCESSING_FLAG_NONE = FIND_POSTPROCESSING_FLAG_NONE
FindDefs.FIND_POSTPROCESSING_FLAG_FIRSTEVENT = FIND_POSTPROCESSING_FLAG_FIRSTEVENT
FindDefs.FIND_POSTPROCESSING_FLAG_LASTEVENT = FIND_POSTPROCESSING_FLAG_LASTEVENT


return FindDefs