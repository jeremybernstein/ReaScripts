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

-- early-load glob for cache (before MIDIUtils)
local glob_early = require 'TransformerGlobal'
glob_early.initCache() -- cached C library values (constant for session) -- cached for loop iteration (perf)

if DEBUG then
  package.path = glob_early.cache.resourcePath .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
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

Shared = Shared or {} -- Use an existing table or create a new one
Shared.mu = mu -- must be defined before TransformerParam3 is required

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

-- Range constants for parameter handling
TransformerLib.PARAM_PERCENT_RANGE = { 0, 100 }
TransformerLib.PARAM_PERCENT_BIPOLAR_RANGE = { -100, 100 }
TransformerLib.PARAM_PITCHBEND_RANGE = { 0, 16383 }
TransformerLib.PARAM_PITCHBEND_BIPOLAR_RANGE = { -8192, 8191 }

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. '?.lua;' -- GET DIRECTORY FOR REQUIRE
local tg = require 'TransformerGlobal'
local p3 = require 'TransformerParam3'

local gdefs = require 'TransformerGeneralDefs'
local fdefs = require 'TransformerFindDefs'
local adefs = require 'TransformerActionDefs'

local mgdefs = require 'types/TransformerMetricGrid'
local evndefs = require 'types/TransformerEveryN'
local nmedefs = require 'types/TransformerNewMIDIEvent'
local evseldefs = require 'types/TransformerEventSelector'
local ffuns = require 'TransformerFindFuns'
local afuns = require 'TransformerActionFuns'

local TypeRegistry = require 'TransformerTypeRegistry'
require 'types/TransformerQuantizeType' -- registers quantize type
local TimeUtils = require 'TransformerTimeUtils'
local Notation = require 'TransformerNotation'
require 'types/TransformerTimeType' -- registers 'time' and 'timedur' types
require 'types/TransformerNumericType' -- registers 'inteditor' and 'floateditor' types
require 'types/TransformerMenuType' -- registers 'menu', 'param3', and 'hidden' types

-- Register shims for existing types (Phase 26: no behavior change)
-- Shims delegate to existing modules; renderUI = nil signals "use legacy"
TypeRegistry.register({
  name = 'everyn',
  detectType = function(src) return src and src.everyn == true end,
  parseNotation = evndefs.parseEveryNNotation,
  generateNotation = evndefs.generateEveryNNotation,
  makeDefault = evndefs.makeDefaultEveryN,
  renderUI = evndefs.renderUI,
})

TypeRegistry.register({
  name = 'newmidievent',
  detectType = function(src) return src and src.newevent == true end,
  parseNotation = nmedefs.parseNewMIDIEventNotation,
  generateNotation = nmedefs.generateNewMIDIEventNotation,
  makeDefault = nmedefs.makeDefaultNewMIDIEvent,
  renderUI = nmedefs.renderUI,
})

TypeRegistry.register({
  name = 'eventselector',
  detectType = function(src) return src and src.eventselector == true end,
  parseNotation = evseldefs.parseEventSelectorNotation,
  generateNotation = evseldefs.generateEventSelectorNotation,
  makeDefault = evseldefs.makeDefaultEventSelector,
  renderUI = evseldefs.renderUI,
})

TypeRegistry.register({
  name = 'metricgrid',
  detectType = function(src) return src and src.metricgrid == true end,
  parseNotation = mgdefs.parseMetricGridNotation,
  generateNotation = mgdefs.generateMetricGridNotation,
  makeDefault = function(row, data) return mgdefs.makeDefaultMetricGrid(row, data) end,
  renderUI = mgdefs.renderUI,
})

TypeRegistry.register({
  name = 'musical',
  detectType = function(src) return src and src.musical == true end,
  parseNotation = mgdefs.parseMetricGridNotation,
  generateNotation = mgdefs.generateMetricGridNotation,
  makeDefault = function(row, data) return mgdefs.makeDefaultMetricGrid(row, data) end,
  renderUI = mgdefs.renderUI,
})

-- quantize type now self-registers via TransformerQuantizeType.lua (Phase 27)

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

Shared.parserError = ''

local dirtyFind = false
local wantsTab = {}

local allEvents = {}
Shared.allEvents = function()
  return allEvents
end

local selectedEvents = {}
Shared.selectedEvents = function()
  return selectedEvents
end

local libPresetNotesBuffer = ''

-----------------------------------------------------------------------------
------------------------------- TRANSFORMER ---------------------------------

local currentFindScopeFlags = fdefs.FIND_SCOPE_FLAG_NONE
local currentFindScope, fsf = fdefs.findScopeFromNotation()
if fsf then currentFindScopeFlags = fsf end

local currentFindPostProcessingInfo

local function clearFindPostProcessingInfo()
  currentFindPostProcessingInfo = {
    flags = fdefs.FIND_POSTPROCESSING_FLAG_NONE,
    front = { count = 1, offset = 0 },
    back = { count = 1, offset = 0 },
  }
end
clearFindPostProcessingInfo()

local currentActionScope = adefs.actionScopeFromNotation()
local currentActionScopeFlags = adefs.actionScopeFlagsFromNotation()
local currentStripRepetitions = false

local scriptIgnoreSelectionInArrangeView = false

-----------------------------------------------------------------------------
----------------------------- OPERATION FUNS --------------------------------

-- forward declarations
local getHasTable
-- end forward declarations

-- TimeUtils delegation (local aliases for internal use)
local getTimeOffset = TimeUtils.getTimeOffset
local calcMIDITime = TimeUtils.calcMIDITime
local lengthFormatRebuf = TimeUtils.lengthFormatRebuf
local timeFormatRebuf = TimeUtils.timeFormatRebuf
local determineTimeFormatStringType = TimeUtils.determineTimeFormatStringType
local TIME_FORMAT_MEASURES = TimeUtils.TIME_FORMAT_MEASURES
local TIME_FORMAT_MINUTES = TimeUtils.TIME_FORMAT_MINUTES
local TIME_FORMAT_HMSF = TimeUtils.TIME_FORMAT_HMSF

-- Shared table delegation (backward compat)
Shared.getTimeOffset = TimeUtils.getTimeOffset
Shared.calcMIDITime = TimeUtils.calcMIDITime
Shared.lengthFormatRebuf = TimeUtils.lengthFormatRebuf

local gridInfo = { currentGrid = 0, currentSwing = 0. } -- swing is -1. to 1
Shared.gridInfo = function()
  return gridInfo
end

-- range filter grid override (set by Quantize dialog preset)
local rangeFilterGridOverride = nil
Shared.setRangeFilterGrid = function(grid)
  rangeFilterGridOverride = grid
end
Shared.getRangeFilterGrid = function()
  return rangeFilterGridOverride
end

local function getGridUnitFromSubdiv(subdiv, PPQ, mgParams)
  local gridUnit
  local mgMods = mgdefs.getMetricGridModifiers(mgParams)
  if subdiv and subdiv >= 0 then
    gridUnit = PPQ * (subdiv * 4)
    if mgMods == gdefs.MG_GRID_DOTTED then gridUnit = gridUnit * 1.5
    elseif mgMods == gdefs.MG_GRID_TRIPLET then gridUnit = (gridUnit * 2 / 3) end
  else
    gridUnit = PPQ * Shared.gridInfo().currentGrid
  end
  return gridUnit
end
Shared.getGridUnitFromSubdiv = getGridUnitFromSubdiv

local function getValue(event, property, bipolar)
  if not property then return 0 end
  local is14bit = false
  if property == 'msg2' and event.chanmsg == 0xE0 then is14bit = true end
  local oldval = is14bit and ((event.msg3 << 7) + event.msg2) or event[property]
  if is14bit and bipolar then oldval = (oldval - (1 << 13)) end
  return oldval
end
Shared.getValue = getValue

local function chanMsgToType(chanmsg)
  if chanmsg == 0x90 then return gdefs.NOTE_TYPE
  elseif chanmsg == 0xF0 or chanmsg == 0x100 then return gdefs.SYXTEXT_TYPE
  elseif chanmsg >= 0xA0 and chanmsg <= 0xEF then return gdefs.CC_TYPE
  else return gdefs.OTHER_TYPE
  end
end
Shared.chanMsgToType = chanMsgToType

local function getEventType(event)
  return chanMsgToType(event.chanmsg)
end
Shared.getEventType = getEventType

local addLengthInfo = { addLengthFirstEventOffset = nil, addLengthFirstEventOffset_Take = nil, addLengthFirstEventStartTime = nil }
Shared.addLengthInfo = function()
  return addLengthInfo
end

local moveCursorInfo = { moveCursorFirstEventPosition = nil, moveCursorFirstEventPosition_Take = nil }
Shared.moveCursorInfo = function()
  return moveCursorInfo
end

local function isANote(target, condOp, paramType, index)
  local isNote = target.notation == '$value1'
    and paramType ~= gdefs.PARAM_TYPE_FLOATEDITOR
    and not condOp.nixnote
    and not (condOp.split and condOp.split[index] and condOp.split[index].nixnote)
  if isNote then
    local hasTable = getHasTable()
    isNote = hasTable._size == 1 and hasTable[0x90]
  end
  return isNote
end
Shared.isANote = isANote

-- Context Object Pattern (Phase 35)
local TransformerContext = tg.class()

function TransformerContext:init()
  -- per-execution state (mirrors module-level locals)
  self._allEvents = {}
  self._selectedEvents = {}
  self._gridInfo = { currentGrid = 0, currentSwing = 0. }
  self._addLengthInfo = { addLengthFirstEventOffset = nil, addLengthFirstEventOffset_Take = nil, addLengthFirstEventStartTime = nil }
  self._moveCursorInfo = { moveCursorFirstEventPosition = nil, moveCursorFirstEventPosition_Take = nil }
  self._rangeFilterGridOverride = nil
  self._contextInfo = nil
end

-- Accessor methods (same interface as current Shared.*)
function TransformerContext:allEvents()
  return self._allEvents
end

function TransformerContext:selectedEvents()
  return self._selectedEvents
end

function TransformerContext:gridInfo()
  return self._gridInfo
end

function TransformerContext:addLengthInfo()
  return self._addLengthInfo
end

function TransformerContext:moveCursorInfo()
  return self._moveCursorInfo
end

function TransformerContext:setRangeFilterGrid(grid)
  self._rangeFilterGridOverride = grid
end

function TransformerContext:getRangeFilterGrid()
  return self._rangeFilterGridOverride
end

function TransformerContext:getContextInfo()
  return self._contextInfo
end

function TransformerContext:setContextInfo(info)
  self._contextInfo = info
end

-- Delegate methods for functions that need context
-- These call the module-level functions defined above
function TransformerContext:getValue(event, property, bipolar)
  return getValue(event, property, bipolar)
end

function TransformerContext:getGridUnitFromSubdiv(subdiv, PPQ, mgParams)
  return getGridUnitFromSubdiv(subdiv, PPQ, mgParams)
end

function TransformerContext:chanMsgToType(chanmsg)
  return chanMsgToType(chanmsg)
end

function TransformerContext:getEventType(event)
  return getEventType(event)
end

function TransformerContext:getSubtypeValueName(event)
  return getSubtypeValueName(event)
end

function TransformerContext:getMainValueName(event)
  return getMainValueName(event)
end

function TransformerContext:isANote(target, condOp, paramType, index)
  return isANote(target, condOp, paramType, index)
end

-- Global context instance (Phase 35 migration bridge)
local globalCtx = TransformerContext()

-- Deprecation tracking (warns once per key per session)
local sharedAccessWarnings = {}
local SHARED_DEPRECATION_ENABLED = true -- set false to silence during dev

-- Shared proxy for deprecation warnings
local SharedProxy = {}
local SharedMT = {
  __index = function(t, key)
    local value = rawget(t, key)
    if value and SHARED_DEPRECATION_ENABLED and not sharedAccessWarnings[key] then
      sharedAccessWarnings[key] = true
      local info = debug.getinfo(2, 'Sl')
      local source = info and info.source and info.source:match('([^/\\]+)$') or '?'
      local line = info and info.currentline or 0
      mu.post(string.format('[DEPRECATION] Shared.%s used at %s:%d (migrate to ctx)', key, source, line))
    end
    return value
  end,
  __newindex = function(t, key, value)
    rawset(t, key, value)
  end
}
setmetatable(SharedProxy, SharedMT)

-- SharedProxy delegates to globalCtx (backward compat)
SharedProxy.mu = mu
SharedProxy.parserError = ''

SharedProxy.allEvents = function() return globalCtx:allEvents() end
SharedProxy.selectedEvents = function() return globalCtx:selectedEvents() end
SharedProxy.gridInfo = function() return globalCtx:gridInfo() end
SharedProxy.addLengthInfo = function() return globalCtx:addLengthInfo() end
SharedProxy.moveCursorInfo = function() return globalCtx:moveCursorInfo() end
SharedProxy.setRangeFilterGrid = function(grid) globalCtx:setRangeFilterGrid(grid) end
SharedProxy.getRangeFilterGrid = function() return globalCtx:getRangeFilterGrid() end
SharedProxy.getValue = getValue
SharedProxy.getGridUnitFromSubdiv = getGridUnitFromSubdiv
SharedProxy.chanMsgToType = chanMsgToType
SharedProxy.getEventType = getEventType
SharedProxy.getSubtypeValueName = getSubtypeValueName
SharedProxy.getMainValueName = getMainValueName
SharedProxy.isANote = isANote
-- TimeUtils delegation
SharedProxy.getTimeOffset = TimeUtils.getTimeOffset
SharedProxy.calcMIDITime = TimeUtils.calcMIDITime
SharedProxy.lengthFormatRebuf = TimeUtils.lengthFormatRebuf
-- fnStringToFn will be added after it's defined (line ~1110)

-- Replace Shared table with proxy (keeps existing assignments but adds deprecation tracking)
for k, v in pairs(Shared) do
  SharedProxy[k] = v
end
Shared = SharedProxy

---------------------------------------------------------------

local function getTimeSelectionStart()
  local ts_start = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  return ts_start + getTimeOffset()
end

local function getTimeSelectionEnd()
  local _, ts_end = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  return ts_end + getTimeOffset()
end

local function getSubtypeValue(event)
  if getEventType(event) == gdefs.SYXTEXT_TYPE then return 0
  else return event.msg2 / 127
  end
end

local function getSubtypeValueName(event)
  if getEventType(event) == gdefs.SYXTEXT_TYPE then return 'devnull'
  else return 'msg2'
  end
end
Shared.getSubtypeValueName = getSubtypeValueName

local function getSubtypeValueLabel(typeIndex)
  if typeIndex == 1 then return 'Note #'
  elseif typeIndex == 2 then return 'Note #'
  elseif typeIndex == 3 then return 'CC #'
  elseif typeIndex == 4 then return 'Pgm #'
  elseif typeIndex == 5 then return 'Pressure Amount'
  elseif typeIndex == 6 then return 'PBnd'
  else return ''
  end
end

local function getMainValue(event)
  if event.chanmsg == 0xC0 or event.chanmsg == 0xD0 or event.chanmsg == 0xE0 then return 0
  elseif getEventType(event) == gdefs.SYXTEXT_TYPE then return 0
  else return event.msg3 / 127
  end
end

local function getMainValueName(event)
  if event.chanmsg == 0xC0 or event.chanmsg == 0xD0 or event.chanmsg == 0xE0 then return 'msg2'
  elseif getEventType(event) == gdefs.SYXTEXT_TYPE then return 'devnull'
  else return 'msg3'
  end
end
Shared.getMainValueName = getMainValueName

local function getMainValueLabel(typeIndex)
  if typeIndex == 1 then return 'Velocity'
  elseif typeIndex == 2 then return 'Pressure Amount'
  elseif typeIndex == 3 then return 'CC Value'
  elseif typeIndex == 4 then return 'Pgm # (aliased Value 1)'
  elseif typeIndex == 5 then return 'Channel Pressure Amount (aliased Value 1)'
  elseif typeIndex == 6 then return 'PBnd (aliased Value 1)'
  else return ''
  end
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

  -- function PpqToLength(ppqpos, ppqlen)
  --   -- REAPER, why is this so difficult?
  --   -- get the PPQ position of the nearest measure start (to ensure that we're dealing with round values)
  --   local _, startMeasures, _, startBeats = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)))
  --   local startPPQ = bbtToPPQ(nil, math.floor(startBeats))

  --   -- now we need the nearest measure start to the end position
  --   local _, endMeasuresSOM, _, endBeatsSOM = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, r.MIDI_GetPPQPos_StartOfMeasure(take, startPPQ + ppqlen)))
  --   -- and the actual end position
  --   local _, endMeasures, _, endBeats = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, startPPQ + ppqlen))

  --   local measures = endMeasures - startMeasures -- measures from start to end
  --   local beats = math.floor(endBeats - endBeatsSOM) -- beats from the SOM (only this measure)
  --   local endBeats_PPQ = bbtToPPQ(nil,  math.floor(endBeats)) -- ppq location of the beginning of this beat
  --   local ticks = math.floor((startPPQ + ppqlen) - endBeats_PPQ) -- finally the ticks
  --   return measures, beats, ticks
  -- end

---------------------------------------------------------------------------
--------------------------------- UTILITIES -------------------------------

local function findTabsFromTarget(row)
  local condTab = {}
  local param1Tab = {}
  local param2Tab = {}
  local target = {}
  local condition = {}

  if not row or row.targetEntry < 1 then return condTab, param1Tab, param2Tab, target, condition end

  target = fdefs.findTargetEntries[row.targetEntry]
  if not target then return condTab, param1Tab, param2Tab, {}, condition end

  local notation = target.notation
  if notation == '$position' then
    condTab = fdefs.findPositionConditionEntries
    condition = condTab[row.conditionEntry]
    if condition then
      if condition.metricgrid then
        param1Tab = fdefs.findMusicalParam1Entries
      elseif condition.notation == ':cursorpos' then
        param1Tab = fdefs.findCursorParam1Entries
      elseif condition.notation == ':nearevent' then
        param1Tab = fdefs.typeEntriesForEventSelector
        param2Tab = fdefs.findPositionMusicalSlopEntries
      elseif condition.notation == ':undereditcursor' then
        param1Tab = fdefs.findPositionMusicalSlopEntries
      elseif condition.notation == ':onmetronome' then
        param1Tab = fdefs.findPositionMetronomeEntries
      end
    end
  elseif notation == '$length' then
    condTab = fdefs.findLengthConditionEntries
    condition = condTab[row.conditionEntry]
    if condition then
      if string.match(condition.notation, ':eqmusical') then
        param1Tab = fdefs.findMusicalParam1Entries
      end
    end
  elseif notation == '$channel' then
    condTab = fdefs.findGenericConditionEntries
    param1Tab = fdefs.findChannelParam1Entries
    param2Tab = fdefs.findChannelParam1Entries
  elseif notation == '$type' then
    condTab = fdefs.findTypeConditionEntries
    param1Tab = fdefs.findTypeParam1Entries
  elseif notation == '$property' then
    condTab = fdefs.findPropertyConditionEntries
    condition = condTab[row.conditionEntry]
    if condition and string.match(condition.notation, ':cchascurve') then
      param1Tab = fdefs.findCCCurveParam1Entries
    else
      param1Tab = fdefs.findPropertyParam1Entries
      param2Tab = fdefs.findPropertyParam2Entries
    end
  -- elseif notation == '$value1' then
  -- elseif notation == '$value2' then
  -- elseif notation == '$velocity' then
  -- elseif notation == '$relvel' then
  elseif notation == '$lastevent' then
    condTab = fdefs.findLastEventConditionEntries
    condition = condTab[row.conditionEntry]
    if condition then -- this could fail if we're called too early (before param tabs are needed)
      if string.match(condition.notation, 'everyN') then
        param1Tab = { }
      end
      if string.match(condition.notation, 'everyNnote$') then
        param2Tab = fdefs.scaleRoots
      end
    end
  elseif notation == '$value1' then
    condTab = fdefs.findValue1ConditionEntries
    condition = condTab[row.conditionEntry]
    if condition then -- this could fail if we're called too early (before param tabs are needed)
      if string.match(condition.notation, ':eqnote') then
        param1Tab = fdefs.scaleRoots
      end
    end
  else
    condTab = fdefs.findGenericConditionEntries
  end

  condition = condTab[row.conditionEntry]

  return condTab, param1Tab, param2Tab, target, condition and condition or {}
end

local function getParamType(src)
  -- Check registry first (REG-02)
  local typeName = TypeRegistry.detectType(src)
  if typeName then
    -- Map registered type to PARAM_TYPE constant for backward compat
    local typeMapping = {
      quantize = gdefs.PARAM_TYPE_QUANTIZE,
      everyn = gdefs.PARAM_TYPE_EVERYN,
      newmidievent = gdefs.PARAM_TYPE_NEWMIDIEVENT,
      eventselector = gdefs.PARAM_TYPE_EVENTSELECTOR,
      metricgrid = gdefs.PARAM_TYPE_METRICGRID,
      musical = gdefs.PARAM_TYPE_METRICGRID, -- unified: musical detection routes to METRICGRID
      time = gdefs.PARAM_TYPE_TIME,
      timedur = gdefs.PARAM_TYPE_TIMEDUR,
      inteditor = gdefs.PARAM_TYPE_INTEDITOR,
      floateditor = gdefs.PARAM_TYPE_FLOATEDITOR,
      menu = gdefs.PARAM_TYPE_MENU,
      param3 = gdefs.PARAM_TYPE_PARAM3,
      hidden = gdefs.PARAM_TYPE_HIDDEN,
    }
    if typeMapping[typeName] then
      return typeMapping[typeName]
    end
  end

  -- Legacy detection chain (preserved for backward compat)
  return not src and gdefs.PARAM_TYPE_UNKNOWN
    or (src.metricgrid or src.musical) and gdefs.PARAM_TYPE_METRICGRID
    or src.everyn and gdefs.PARAM_TYPE_EVERYN
    or src.newevent and gdefs.PARAM_TYPE_NEWMIDIEVENT
    or src.eventselector and gdefs.PARAM_TYPE_EVENTSELECTOR
    or src.quantize and gdefs.PARAM_TYPE_QUANTIZE
    or gdefs.PARAM_TYPE_UNKNOWN
end

local function getParamTypesForRow(row, target, condOp)
  local paramType = getParamType(condOp)
  if paramType == gdefs.PARAM_TYPE_UNKNOWN then
    paramType = getParamType(target)
  end
  if paramType == gdefs.PARAM_TYPE_UNKNOWN then
    paramType = gdefs.PARAM_TYPE_INTEDITOR
  end
  local split = { paramType, paramType }
  if row.params[3] then table.insert(split, paramType) end

  if condOp.split then
    local split1 = getParamType(condOp.split[1])
    local split2 = getParamType(condOp.split[2])
    local split3 = row.params[3] and getParamType(condOp.split[3]) or nil
    if split1 ~= gdefs.PARAM_TYPE_UNKNOWN then split[1] = split1 end
    if split2 ~= gdefs.PARAM_TYPE_UNKNOWN then split[2] = split2 end
    if split3 and split3 ~= gdefs.PARAM_TYPE_UNKNOWN then split[3] = split3 end
  end
  return split
end

local function check14Bit(paramType)
  local has14bit = false
  local hasOther = false
  if paramType == gdefs.PARAM_TYPE_INTEDITOR then
    local hasTable = getHasTable()
    has14bit = hasTable[0xE0] and true or false
    hasOther = (hasTable[0x90] or hasTable[0xA0] or hasTable[0xB0] or hasTable[0xD0] or hasTable[0xF0]) and true or false
  end
  return has14bit, hasOther
end

local function opIsBipolar(condOp, index)
  return condOp.bipolar or (condOp.split and condOp.split[index].bipolar)
end

local function timeFormatToSeconds(buf, baseTime, context, isLength)
  local format = determineTimeFormatStringType(buf)

  local isneg = string.match(buf, '^%s*%-')

  if format == TIME_FORMAT_MEASURES then
    local tbars, tbeats, tfraction, tsubfrac = string.match(buf, '(%d+)%.(%d+)%.(%d+)%.(%d+)')
    if not tbars then
      tbars, tbeats, tfraction = string.match(buf, '(%d+)%.(%d+)%.(%d+)')
    end
    local absTicks = string.match(buf, 't%s*$')

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
    if not isLength then adjust = adjust - getTimeOffset(true) end
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
Shared.timeFormatToSeconds = timeFormatToSeconds

local function lengthFormatToSeconds(buf, baseTime, context)
  return timeFormatToSeconds(buf, baseTime, context, true)
end
Shared.lengthFormatToSeconds = lengthFormatToSeconds

local context = {}
context.r = r
context.math = math

context.TestEvent1 = ffuns.testEvent1
context.TestEvent2 = ffuns.testEvent2
context.FindEveryN = ffuns.findEveryN
context.FindEveryNPattern = ffuns.findEveryNPattern
context.FindEveryNNote = ffuns.findEveryNNote
context.EqualsMusicalLength = ffuns.equalsMusicalLength
context.CursorPosition = ffuns.cursorPosition
context.UnderEditCursor = ffuns.underEditCursor
context.SelectChordNote = ffuns.selectChordNote
context.OnMetricGrid = ffuns.onMetricGrid
context.OnGrid = ffuns.onGrid
context.InBarRange = ffuns.inBarRange
context.InGridRange = ffuns.inGridRange
context.InRazorArea = ffuns.inRazorArea
context.IsNearEvent = ffuns.isNearEvent
context.InScale = ffuns.inScale
context.CCHasCurve = ffuns.ccHasCurve
context.OnMetronome = ffuns.onMetronome
context.InTakeRange = ffuns.inTakeRange
context.InTimeSelectionRange = ffuns.inTimeSelectionRange

context.OP_EQ = fdefs.OP_EQ
context.OP_GT = fdefs.OP_GT
context.OP_GTE = fdefs.OP_GTE
context.OP_LT = fdefs.OP_LT
context.OP_LTE = fdefs.OP_LTE
context.OP_INRANGE = fdefs.OP_INRANGE
context.OP_INRANGE_EXCL = fdefs.OP_INRANGE_EXCL
context.OP_EQ_SLOP = fdefs.OP_EQ_SLOP
context.OP_SIMILAR = fdefs.OP_SIMILAR
context.OP_EQ_NOTE = fdefs.OP_EQ_NOTE

context.CURSOR_LT = fdefs.CURSOR_LT
context.CURSOR_GT = fdefs.CURSOR_GT
context.CURSOR_AT = fdefs.CURSOR_AT
context.CURSOR_LTE = fdefs.CURSOR_LTE
context.CURSOR_GTE = fdefs.CURSOR_GTE
context.CURSOR_UNDER = fdefs.CURSOR_UNDER

context.OperateEvent1 = afuns.operateEvent1
context.OperateEvent2 = afuns.operateEvent2
context.CreateNewMIDIEvent = afuns.createNewMIDIEvent
context.RandomValue = afuns.randomValue
context.QuantizeTo = afuns.quantizeTo
context.Mirror = afuns.mirror
context.Threshold = afuns.threshold
context.LinearChangeOverSelection = afuns.linearChangeOverSelection
context.ScaledRampOverSelection = afuns.scaledRampOverSelection
context.ClampValue = afuns.clampValue
context.AddLength = afuns.addLength
context.MoveToCursor = afuns.moveToCursor
context.MoveLengthToCursor = afuns.moveLengthToCursor
context.SetMusicalLength = afuns.setMusicalLength
context.QuantizeMusicalPosition = afuns.quantizeMusicalPosition
context.QuantizeMusicalLength = afuns.quantizeMusicalLength
context.QuantizeMusicalEndPos = afuns.quantizeMusicalEndPos
context.quantizeGroovePosition = afuns.quantizeGroovePosition
context.quantizeGrooveLength = afuns.quantizeGrooveLength
context.quantizeGrooveEndPos = afuns.quantizeGrooveEndPos
-- QuantizeMIDI dispatcher for integrated Quantize action (routes by targetIndex)
context.QuantizeMIDI = function(event, take, PPQ, params)
  local target = params.targetIndex or 0
  if target == 0 then -- position only
    return afuns.quantizeMusicalPosition(event, take, PPQ, params)
  elseif target == 1 then -- position + end
    afuns.quantizeMusicalPosition(event, take, PPQ, params)
    return afuns.quantizeMusicalEndPos(event, take, PPQ, params)
  elseif target == 2 then -- position + length
    afuns.quantizeMusicalPosition(event, take, PPQ, params)
    return afuns.quantizeMusicalLength(event, take, PPQ, params)
  elseif target == 3 then -- end only
    return afuns.quantizeMusicalEndPos(event, take, PPQ, params)
  elseif target == 4 then -- length only
    return afuns.quantizeMusicalLength(event, take, PPQ, params)
  end
  return afuns.quantizeMusicalPosition(event, take, PPQ, params)
end
context.MoveToItemPos = afuns.moveToItemPos
context.CCSetCurve = afuns.ccSetCurve
context.AddDuration = afuns.addDuration
context.SubtractDuration = afuns.subtractDuration
context.MultiplyPosition = afuns.multiplyPosition

context.GetMainValue = getMainValue
context.GetSubtypeValue = getSubtypeValue
context.GetTimeOffset = getTimeOffset
context.GetTimeSelectionStart = getTimeSelectionStart
context.GetTimeSelectionEnd = getTimeSelectionEnd
context.TimeFormatToSeconds = timeFormatToSeconds

context.OP_ADD = adefs.OP_ADD
context.OP_SUB = adefs.OP_SUB
context.OP_MULT = adefs.OP_MULT
context.OP_DIV = adefs.OP_DIV
context.OP_FIXED = adefs.OP_FIXED
context.OP_SCALEOFF = adefs.OP_SCALEOFF
context.OP_SCALEAROUND = adefs.OP_SCALEAROUND

local function doProcessParams(row, target, condOp, paramType, paramTab, index, notation, takectx)
  local addMetricGridNotation = false
  local addEveryNNotation = false
  local addNewMIDIEventNotation = false
  local addEventSelectorNotation = false
  local addQuantizeNotation = false

  if paramType == gdefs.PARAM_TYPE_METRICGRID
    or paramType == gdefs.PARAM_TYPE_MUSICAL
    or paramType == gdefs.PARAM_TYPE_EVERYN
    or paramType == gdefs.PARAM_TYPE_NEWMIDIEVENT
    or paramType == gdefs.PARAM_TYPE_EVENTSELECTOR
    or paramType == gdefs.PARAM_TYPE_QUANTIZE
  then
    if index == 1 then
      if notation then
        if paramType == gdefs.PARAM_TYPE_EVERYN then
          addEveryNNotation = true
        elseif paramType == gdefs.PARAM_TYPE_NEWMIDIEVENT then
          addNewMIDIEventNotation = true
        elseif paramType == gdefs.PARAM_TYPE_EVENTSELECTOR then
          addEventSelectorNotation = true
        elseif paramType == gdefs.PARAM_TYPE_QUANTIZE then
          addQuantizeNotation = true
        else
          addMetricGridNotation = true
        end
      end
      paramType = gdefs.PARAM_TYPE_MENU
    end
  end

  local percentFormat = 'percent<%0.4f>'
  local override = row.params[index].editorType
  local percentVal = row.params[index].percentVal
  local paramVal
  if condOp.terms < index then
    paramVal = ''
  elseif notation and override then
    if override == gdefs.EDITOR_TYPE_BITFIELD then
      paramVal = row.params[index].textEditorStr
    elseif (override == gdefs.EDITOR_TYPE_PERCENT or override == gdefs.EDITOR_TYPE_PERCENT_BIPOLAR) then
      paramVal = string.format(percentFormat, percentVal and percentVal or tonumber(row.params[index].textEditorStr)):gsub('%.?0+$', '')
    elseif (override == gdefs.EDITOR_TYPE_PITCHBEND or override == gdefs.EDITOR_TYPE_PITCHBEND_BIPOLAR) then
      paramVal = string.format(percentFormat, percentVal and percentVal or (tonumber(row.params[index].textEditorStr) + (1 << 13)) / ((1 << 14) - 1) * 100):gsub('%.?0+$', '')
    elseif ((override == gdefs.EDITOR_TYPE_14BIT or override == gdefs.EDITOR_TYPE_14BIT_BIPOLAR)) then
      paramVal = string.format(percentFormat, percentVal and percentVal or (tonumber(row.params[index].textEditorStr) / ((1 << 14) - 1)) * 100):gsub('%.?0+$', '')
    elseif ((override == gdefs.EDITOR_TYPE_7BIT
        or override == gdefs.EDITOR_TYPE_7BIT_NOZERO
        or override == gdefs.EDITOR_TYPE_7BIT_BIPOLAR))
      then
        paramVal = string.format(percentFormat, percentVal and percentVal or (tonumber(row.params[index].textEditorStr) / ((1 << 7) - 1)) * 100):gsub('%.?0+$', '')
    else
      mu.post('unknown override: ' .. override)
    end
  elseif (paramType == gdefs.PARAM_TYPE_INTEDITOR or paramType == gdefs.PARAM_TYPE_FLOATEDITOR) then
    paramVal = percentVal and string.format('%g', percentVal) or row.params[index].textEditorStr
  elseif paramType == gdefs.PARAM_TYPE_TIME then
    paramVal = (notation or condOp.timearg) and row.params[index].timeFormatStr or tostring(timeFormatToSeconds(row.params[index].timeFormatStr, nil, takectx))
  elseif paramType == gdefs.PARAM_TYPE_TIMEDUR then
    paramVal = (notation or condOp.timearg) and row.params[index].timeFormatStr or tostring(lengthFormatToSeconds(row.params[index].timeFormatStr, nil, takectx))
  elseif paramType == gdefs.PARAM_TYPE_METRICGRID
    or paramType == gdefs.PARAM_TYPE_MUSICAL
    or paramType == gdefs.PARAM_TYPE_EVERYN
    or paramType == gdefs.PARAM_TYPE_PARAM3
    or override == gdefs.EDITOR_TYPE_BITFIELD
    or paramType == gdefs.PARAM_TYPE_HIDDEN
  then
    paramVal = row.params[index].textEditorStr
  elseif #paramTab ~= 0 then
    paramVal = notation and paramTab[row.params[index].menuEntry].notation or paramTab[row.params[index].menuEntry].text
  end

  if addMetricGridNotation then
    paramVal = paramVal .. mgdefs.generateMetricGridNotation(row)
  elseif addEveryNNotation then
    paramVal = evndefs.generateEveryNNotation(row)
  elseif addNewMIDIEventNotation then
    paramVal = nmedefs.generateNewMIDIEventNotation(row)
  elseif addEventSelectorNotation then
    paramVal = evseldefs.generateEventSelectorNotation(row)
  elseif addQuantizeNotation then
    paramVal = '' -- quantize uses child window config, no inline notation needed
  end

  return paramVal
end

local function processParams(row, target, condOp, paramTabs, notation, takectx)
  local paramTypes = getParamTypesForRow(row, target, condOp)

  local param1Val = doProcessParams(row, target, condOp, paramTypes[1], paramTabs[1], 1, notation, takectx)
  local param2Val = doProcessParams(row, target, condOp, paramTypes[2], paramTabs[2], 2, notation, takectx)
  local param3Val = row.params[3] and doProcessParams(row, target, condOp, paramTypes[3], paramTabs[3], 3, notation, takectx) or nil

  return param1Val, param2Val, param3Val
end

  ---------------------------------------------------------------------------
  -------------------------------- FIND UTILS -------------------------------


local function eventToIdx(event)
  return event.chanmsg + (event.chan and event.chan or 0)
end

local function updateEventCount(event, counts, onlyNoteRow)
  if getEventType(event) == gdefs.NOTE_TYPE and not onlyNoteRow then
    event.count = counts.noteCount + 1
    counts.noteCount = event.count
  end
  -- also get counts for specific notes so that we can do rows as an option
  local eventIdx = eventToIdx(event)
  if not counts[eventIdx] then counts[eventIdx] = {} end
  local subIdx = event.msg2 and event.msg2 or 0 -- sysex/text
  if event.chanmsg >= 0xC0 then subIdx = 0 end
  if not counts[eventIdx][subIdx] then counts[eventIdx][subIdx] = 0 end
  local cname = getEventType(event) == gdefs.NOTE_TYPE and 'ncount' or 'count'
  event[cname] = counts[eventIdx][subIdx] + 1
  counts[eventIdx][subIdx] = event[cname]
end

local function calcChordPos(first, last)
  local chordPos = {}
  for i = first, last do
    if getEventType(allEvents[i]) == gdefs.NOTE_TYPE then
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

local function doFindPostProcessing(found, unfound)
  local wantsFront = currentFindPostProcessingInfo.flags & fdefs.FIND_POSTPROCESSING_FLAG_FIRSTEVENT ~= 0
  local wantsBack = currentFindPostProcessingInfo.flags & fdefs.FIND_POSTPROCESSING_FLAG_LASTEVENT ~= 0
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

local function handleFindPostProcessing(found, unfound)
  if currentFindPostProcessingInfo.flags ~= fdefs.FIND_POSTPROCESSING_FLAG_NONE then
    return doFindPostProcessing(found, unfound)
  end
  return found, unfound
end

local function makeContextInfo(take, ctx)
  if take then
    local info = {
      take = take,
      tsInfo = {
        tsStart = getTimeSelectionStart(),
        tsEnd = getTimeSelectionEnd(),
      },
      takeInfo = {
        takeStart = r.GetMediaItemInfo_Value(r.GetMediaItemTake_Item(take), 'D_POSITION') + getTimeOffset(),
        takeEnd = nil, -- set below
      },
    }
    info.takeInfo.takeEnd = r.GetMediaItemInfo_Value(r.GetMediaItemTake_Item(take), 'D_LENGTH') + info.takeInfo.takeStart

    if ctx then
      ctx:setContextInfo(info)
    else
      Shared.contextInfo = info
    end
  end
end

local function runFind(findFn, params, runFn)

  local wantsEventPreprocessing = params and params.wantsEventPreprocessing or false
  local getUnfound = params and params.wantsUnfound or false
  local hasTable = {}
  local found = {}
  local unfound = {}

  local firstTime = 0xFFFFFFFF
  local lastTime = -0xFFFFFFFF
  local lastNoteEnd = -0xFFFFFFFF

  makeContextInfo(params.take)

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
      if getEventType(event) == gdefs.CC_TYPE or getEventType(event) == gdefs.SYXTEXT_TYPE then
        updateEventCount(event, counts)
      elseif getEventType(event) == gdefs.NOTE_TYPE then -- note event
        if take then
          local noteOnset = event.projtime
          local notePpq = r.MIDI_GetPPQPosFromProjTime(take, noteOnset)
          local matched = false
          local updateFirstNote = true
          local notesInChord = tg.getNotesInChord()

          if firstNotePpq then
            if notePpq >= firstNotePpq - (params.PPQ * 0.05) and notePpq <= firstNotePpq + (params.PPQ * 0.05) then
              local isChord = true
              for i = 1, notesInChord - 1 do
                if not prevEvents[i] then isChord = false break end
              end
              if isChord then
                event.flags = event.flags | 4
                counts.noteCount = firstNoteCount
                event.count = counts.noteCount
                for i = 1, notesInChord - 1 do
                  prevEvents[i].flags = prevEvents[i].flags | 4
                  prevEvents[i].count = counts.noteCount
                end
                matched = true
              end

              for i = notesInChord - 1, 2, -1 do
                prevEvents[i] = prevEvents[i - 1]
              end
              prevEvents[1] = event
              updateFirstNote = false
              firstNotePpq = (firstNotePpq + notePpq) / 2 -- running avg
            end
          end
          if not matched then
            if updateFirstNote then
              if k > 1 and (allEvents[k - 1].flags & 0x04 ~= 0) then
                calcChordPos(firstNoteIndex, k - 1)
              end

              firstNotePpq = notePpq
              firstNoteIndex = k
              firstNoteCount = counts.noteCount + 1
              prevEvents = { event }
            end
          end
          updateEventCount(event, counts, matched)
        end
      end
    end
    if firstNoteIndex and (allEvents[firstNoteIndex].flags & 0x04 ~= 0) then
      calcChordPos(firstNoteIndex, #allEvents)
    end
  end

  for _, event in ipairs(allEvents) do
    local matches = false
    if findFn and findFn(event, getSubtypeValueName(event), getMainValueName(event)) then -- event, _value1, _value2
      hasTable[event.chanmsg] = true
      if event.projtime < firstTime then firstTime = event.projtime end
      if event.projtime > lastTime then lastTime = event.projtime end
      if getEventType(event) == gdefs.NOTE_TYPE and event.projtime + event.projlen > lastNoteEnd then lastNoteEnd = event.projtime + event.projlen end
      table.insert(found, event)
      matches = true
    elseif getUnfound then
      table.insert(unfound, event)
    end
    if runFn then runFn(event, matches) end
  end

  found, unfound = handleFindPostProcessing(found, unfound)

  -- it was a time selection, add a final event to make behavior predictable
  if params.addRangeEvents and params.findRange.frStart and params.findRange.frEnd then
    local frStart = params.findRange.frStart
    local frEnd = params.findRange.frEnd
    local firstLastEventsByType = {}
    for _, event in ipairs(found) do
      if getEventType(event) == gdefs.CC_TYPE then
        local eventIdx = eventToIdx(event)
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
        newEvent = tg.tableCopy(rEvent.firstEvent)
        newEvent.projtime = frStart
        newEvent.firstlastevent = true
        newEvent.orig_type = gdefs.OTHER_TYPE
        table.insert(found, newEvent)
        newEvent = tg.tableCopy(rEvent.lastEvent)
        newEvent.projtime = frEnd
        newEvent.firstlastevent = true
        newEvent.orig_type = gdefs.OTHER_TYPE
        table.insert(found, newEvent)
      end
    end
  end

  Shared.contextInfo = nil

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

local function fnStringToFn(fnString, errFn, ctx)
  local fn
  -- Add ctx to context table for generated code
  local execContext = context
  if ctx then
    execContext = setmetatable({ ctx = ctx }, { __index = context })
  end
  local success, pret, err = pcall(load, fnString, nil, nil, execContext)
  if success and pret then
    fn = pret()
    Shared.parserError = ''
  else
    if errFn then errFn(err) end
  end
  return success, fn
end
Shared.fnStringToFn = fnStringToFn

local function processFind(take, fromHasTable, ctx)
  -- Create or use provided context
  ctx = ctx or globalCtx

  -- Sync module-level locals TO context via reference assignment
  -- (ctx fields point to SAME tables as module locals - read-only bridge during Phase 35)
  -- No sync-back needed: mutations to ctx._allEvents mutate allEvents directly
  ctx._allEvents = allEvents
  ctx._selectedEvents = selectedEvents

  local fnString = ''
  local wantsEventPreprocessing = false
  local rangeType = fdefs.SELECT_TIME_SHEBANG
  local findRangeStart, findRangeEnd

  wantsTab = {}
  context.PPQ = take and mu.MIDI_GetPPQ(take) or 960

  local iterTab = {}
  for _, v in ipairs(fdefs.findRowTable()) do
    if not (v.except or v.disabled) then
      table.insert(iterTab, v)
    end
  end

  for k, v in ipairs(iterTab) do
    local row = v
    local condTab, param1Tab, param2Tab, curTarget, curCondition = findTabsFromTarget(v)

    if #condTab == 0 then return end -- continue?

    local targetTerm = curTarget.text
    local condition = curCondition
    local conditionVal = condition.text
    if row.isNot then conditionVal = 'not ( ' .. conditionVal .. ' )' end

    -- this involves extra processing and is therefore only done if necessary
    if curTarget.notation == '$lastevent' then wantsEventPreprocessing = true
    elseif string.match(condition.notation, ':inchord') then wantsEventPreprocessing = true end

    local paramTerms = { processParams(v, curTarget, condition, { param1Tab, param2Tab, {} }, false, context) }

    if curCondition.terms > 0 and paramTerms[1] == '' then return end

    local paramNums = { tonumber(paramTerms[1]), tonumber(paramTerms[2]), tonumber(paramTerms[3]) }
    if paramNums[1] and paramNums[2] and paramNums[2] < paramNums[1]
      and not curCondition.freeterm
    then
      local tmp = paramTerms[2]
      paramTerms[2] = paramTerms[1]
      paramTerms[1] = tmp
    end

    local paramTypes = getParamTypesForRow(v, curTarget, condition)
    for i = 1, 2 do -- param3 for Find?
      if paramNums[i] and (paramTypes[i] == gdefs.PARAM_TYPE_INTEDITOR or paramTypes[i] == gdefs.PARAM_TYPE_FLOATEDITOR) and row.params[i].percentVal then
        paramTerms[i] = getParamPercentTerm(paramNums[i], opIsBipolar(curCondition, i))
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

    if curTarget.notation == '$position' and condition.timeselect == fdefs.SELECT_TIME_RANGE then
      if condition.notation == ':intimesel' then
        local ts1 = getTimeSelectionStart()
        local ts2 = getTimeSelectionEnd()
        if not findRangeStart or ts1 < findRangeStart then findRangeStart = ts1 end
        if not findRangeEnd or ts2 > findRangeEnd then findRangeEnd = ts2 end
      end
    end

    -- substitutions

    findTerm = conditionVal
    findTerm = string.gsub(findTerm, '{tgt}', targetTerm)
    findTerm = string.gsub(findTerm, '{param1}', tostring(paramTerms[1]))
    findTerm = string.gsub(findTerm, '{param2}', tostring(paramTerms[2]))

    local isMetricOrMusical = paramTypes[1] == gdefs.PARAM_TYPE_METRICGRID
    local isEveryN = paramTypes[1] == gdefs.PARAM_TYPE_EVERYN and true or false
    local isEventSelector = paramTypes[1] == gdefs.PARAM_TYPE_EVENTSELECTOR and true or false

    if isMetricOrMusical then
      local mgParams = tg.tableCopy(row.mg)
      mgParams.param1 = paramNums[1]
      mgParams.param2 = paramTerms[2]
      -- use condition definition flags for placeholder selection (NOT param type)
      -- condition.metricgrid = true for :onmetricgrid (uses {metricgridparams})
      -- condition.musical = true for :eqmusical (uses {musicalparams})
      local placeholder = condition.metricgrid and '{metricgridparams}' or '{musicalparams}'
      findTerm = string.gsub(findTerm, placeholder, tg.serialize(mgParams))
    elseif isEveryN then
      local evnParams = tg.tableCopy(row.evn)
      findTerm = string.gsub(findTerm, '{everyNparams}', tg.serialize(evnParams))
    elseif isEventSelector then
      local evSelParams = tg.tableCopy(row.evsel)
      findTerm = string.gsub(findTerm, '{eventselectorparams}', tg.serialize(evSelParams))
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

    local startParen = row.startParenEntry > 1 and (fdefs.startParenEntries[row.startParenEntry].text .. ' ') or ''
    local endParen = row.endParenEntry > 1 and (' ' .. fdefs.endParenEntries[row.endParenEntry].text) or ''

    local rowStr = startParen .. '( ' .. findTerm .. ' )' .. endParen

    if k ~= #iterTab then
      rowStr = rowStr .. ' ' .. fdefs.findBooleanEntries[row.booleanEntry].text
    end
    -- mu.post(k .. ': ' .. rowStr)

    fnString = fnString == '' and (' ' .. rowStr .. '\n') or (fnString .. ' ' .. rowStr .. '\n')
  end

  fnString = 'return function(event, _value1, _value2)\nreturn ' .. fnString .. '\nend'

  -- catch unsubstituted placeholders (regression guard)
  local placeholder = fnString:match('{%w+}')
  if placeholder then
    local err = 'Unsubstituted placeholder in generated find code: ' .. placeholder
    mu.post(err)
    Shared.parserError = err
    return nil
  end

  if DEBUGPOST then
    mu.post('======== FIND FUN ========')
    mu.post(fnString)
    mu.post('==========================')
  end

  local findFn

  context.take = take
  if take then
    local cg, cs = r.MIDI_GetGrid(take)
    ctx:gridInfo().currentGrid = cg or 0
    ctx:gridInfo().currentSwing = cs or 0
  end -- 1.0 is QN, 1.5 dotted, etc.
  _, findFn = fnStringToFn(fnString, function(err)
    Shared.parserError = 'Fatal error: could not load selection criteria'
    if err then
      if string.match(err, '\'%)\' expected') then
        Shared.parserError = Shared.parserError .. ' (Unmatched Parentheses)'
      end
    end
  end, ctx)

  if not fromHasTable then dirtyFind = true end
  return findFn, wantsEventPreprocessing, { type = rangeType, frStart = findRangeStart, frEnd = findRangeEnd }, fnString
end

local function actionTabsFromTarget(row)
  local opTab = {}
  local param1Tab = {}
  local param2Tab = {}
  local target = {}
  local operation = {}

  if not row or row.targetEntry < 1 then return opTab, param1Tab, param2Tab, target, operation end

  target = adefs.actionTargetEntries[row.targetEntry]
  if not target then return opTab, param1Tab, param2Tab, {}, operation end

  local notation = target.notation
  if notation == '$position' then
    opTab = adefs.actionPositionOperationEntries
  elseif notation == '$length' then
    opTab = adefs.actionLengthOperationEntries
  elseif notation == '$channel' then
    opTab = adefs.actionChannelOperationEntries
  elseif notation == '$type' then
    opTab = adefs.actionTypeOperationEntries
  elseif notation == '$property' then
    opTab = adefs.actionPropertyOperationEntries
  elseif notation == '$value1' then
    opTab = adefs.actionSubtypeOperationEntries
  elseif notation == '$value2' then
    opTab = adefs.actionVelocityOperationEntries
  elseif notation == '$velocity' then
    opTab = adefs.actionVelocityOperationEntries
  elseif notation == '$relvel' then
    opTab = adefs.actionVelocityOperationEntries
  elseif notation == '$newevent' then
    opTab = adefs.actionNewEventOperationEntries
  elseif notation == '$quantize' then
    opTab = adefs.actionQuantizeOperationEntries
  else
    opTab = adefs.actionGenericOperationEntries
  end

  operation = opTab[row.operationEntry]
  if not operation then return opTab, param1Tab, param2Tab, target, {} end

  local opnota = operation.notation

  if opnota == ':line'
    or opnota == ':relline'
    or opnota == ':rampscale'
  then -- param3 operation
    param1Tab = { }
    param2Tab = adefs.actionLineParam2Entries
  elseif notation == '$position' then
    if opnota == ':tocursor' then
      param1Tab = adefs.actionMoveToCursorParam1Entries
    elseif opnota == ':addlength' then
      param1Tab = adefs.actionAddLengthParam1Entries
    elseif opnota == '*' or opnota == '/' then
      param2Tab = adefs.actionPositionMultParam2Menu
    elseif opnota == ':roundmusical' then
      param1Tab = fdefs.findMusicalParam1Entries
    elseif opnota == ':scaleoffset' then -- param3 operation
      param1Tab = { }
      param2Tab = adefs.actionPositionMultParam2Menu
    end
  elseif notation == '$length' then
    if opnota == ':quantmusical'
      or opnota == ':roundlenmusical'
      or opnota == ':roundendmusical'
    then
      param1Tab = fdefs.findMusicalParam1Entries
    end
  elseif notation == '$channel' then
    param1Tab = fdefs.findChannelParam1Entries -- same as find
  elseif notation == '$type' then
    param1Tab = fdefs.typeEntries
  elseif notation == '$property' then
    if opnota == '=' then
      param1Tab = adefs.actionPropertyParam1Entries
    elseif opnota == ':ccsetcurve' then
      param1Tab = fdefs.findCCCurveParam1Entries
    else
      param1Tab = adefs.actionPropertyAddRemParam1Entries
    end
  elseif notation == '$newevent' then
    param1Tab = fdefs.typeEntries -- no $syx
    param2Tab = adefs.newMIDIEventPositionEntries
  elseif notation == '$quantize' then
    param1Tab = { }
    param2Tab = { }
  end

  return opTab, param1Tab, param2Tab, target, operation
end
Shared.actionTabsFromTarget = actionTabsFromTarget

local function defaultValueIfAny(row, operation, index)
  local param = nil
  local default = operation.split and operation.split[index].default or nil -- hack
  if default then
    param = tostring(default)
    row.params[index].textEditorStr = param
  end
  return param
end
Shared.defaultValueIfAny = defaultValueIfAny

----------------------------------------------------------------------------------------
-- NOTATION DELEGATION (Phase 34)

-- Helper table for Notation module (contains functions needed by notation parsing)
local notationHelpers = {
  findTabsFromTarget = findTabsFromTarget,
  actionTabsFromTarget = actionTabsFromTarget,
  getParamTypesForRow = getParamTypesForRow,
  opIsBipolar = opIsBipolar,
  check14Bit = check14Bit,
  processParams = processParams,
  defaultValueIfAny = defaultValueIfAny,
  PARAM_PERCENT_RANGE = TransformerLib.PARAM_PERCENT_RANGE,
  PARAM_PERCENT_BIPOLAR_RANGE = TransformerLib.PARAM_PERCENT_BIPOLAR_RANGE,
  PARAM_PITCHBEND_RANGE = TransformerLib.PARAM_PITCHBEND_RANGE,
  PARAM_PITCHBEND_BIPOLAR_RANGE = TransformerLib.PARAM_PITCHBEND_BIPOLAR_RANGE,
}

-- Local wrapper functions (for internal callers)
local function processFindMacro(buf)
  return Notation.processFindMacro(buf, notationHelpers)
end

local function processActionMacro(buf)
  return Notation.processActionMacro(buf, notationHelpers)
end

local function findRowToNotation(row, index)
  return Notation.findRowToNotation(row, index, notationHelpers)
end

local function findRowsToNotation()
  return Notation.findRowsToNotation(notationHelpers)
end

local function actionRowToNotation(row, index)
  return Notation.actionRowToNotation(row, index, notationHelpers)
end

local function actionRowsToNotation()
  return Notation.actionRowsToNotation(notationHelpers)
end

local function getParamPercentTerm(val, bipolar)
  return Notation.getParamPercentTerm(val, bipolar)
end

-- Shared table delegations (for TransformerParam3 backward compat)
Shared.handleMacroParam = function(row, target, condOp, paramTab, paramStr, index)
  return Notation.handleMacroParam(row, target, condOp, paramTab, paramStr, index, notationHelpers)
end

Shared.getRowTextAndParameterValues = function(row)
  return Notation.getRowTextAndParameterValues(row, notationHelpers)
end

  ----------------------------------------------
  ---------------- ACTIONS TABLE ---------------
  ----------------------------------------------

local mediaItemCount
local mediaItemIndex
local enumTakesMode

local function getEnumTakesMode()
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

local function getNextTake()
  local take = nil
  local notation = fdefs.findScopeTable[currentFindScope].notation
  if notation == '$midieditor' then
    local me = r.MIDIEditor_GetActive()
    if me then
      if not mediaItemCount then
        mediaItemCount = 0
        while me do
          local t = r.MIDIEditor_EnumTakes(me, mediaItemCount, getEnumTakesMode() == 1)
          if not t then break end
          mediaItemCount = mediaItemCount + 1 -- we probably don't really need this iteration, but whatever
        end
        mediaItemIndex = 0
      end
      if mediaItemIndex < mediaItemCount then
        take = r.MIDIEditor_EnumTakes(me, mediaItemIndex, getEnumTakesMode() == 1)
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

local function initializeTake(take)
  local onlySelected = false
  local onlyNotes = false
  local activeNoteRow = false
  allEvents = {}
  selectedEvents = {}
  mu.MIDI_InitializeTake(take) -- reset this each cycle
  if fdefs.findScopeTable[currentFindScope].notation == '$midieditor' then
    if currentFindScopeFlags & fdefs.FIND_SCOPE_FLAG_SELECTED_ONLY ~= 0 then
      if mu.MIDI_EnumSelEvts(take, -1) ~= -1 then
        onlySelected = true
      end
    end
    if currentFindScopeFlags & fdefs.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW ~= 0 then
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
    local e = { type = gdefs.NOTE_TYPE, idx = noteidx }
    _, e.selected, e.muted, e.ppqpos, e.endppqpos, e.chan, e.pitch, e.vel, e.relvel = mu.MIDI_GetNote(take, noteidx)

    local doIt = not activeRow or e.pitch == activeRow

    if doIt then
      e.msg2 = e.pitch
      e.msg3 = e.vel
      e.notedur = e.endppqpos - e.ppqpos
      e.chanmsg = 0x90
      e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
      calcMIDITime(take, e)
      table.insert(allEvents, e)
      if e.selected then table.insert(selectedEvents, e) end
    end
    noteidx = enumNotesFn(take, noteidx)
  end

  local ccidx = onlyNotes and -1 or enumCCFn(take, -1)
  while ccidx ~= -1 do
    local e = { type = gdefs.CC_TYPE, idx = ccidx }
    _, e.selected, e.muted, e.ppqpos, e.chanmsg, e.chan, e.msg2, e.msg3 = mu.MIDI_GetCC(take, ccidx)

    if e.chanmsg == 0xE0 then
      e.ccnum = gdefs.INVALID
      e.ccval = ((e.msg3 << 7) + e.msg2) - (1 << 13)
    elseif e.chanmsg == 0xD0 then
      e.ccnum = gdefs.INVALID
      e.ccval = e.msg2
    else
      e.ccnum = e.msg2
      e.ccval = e.msg3
    end
    e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
    calcMIDITime(take, e)
    table.insert(allEvents, e)
    if e.selected then table.insert(selectedEvents, e) end
    ccidx = enumCCFn(take, ccidx)
  end

  local syxidx = onlyNotes and -1 or enumTextSysexFn(take, -1)
  while syxidx ~= -1 do
    local e = { type = gdefs.SYXTEXT_TYPE, idx = syxidx }
    _, e.selected, e.muted, e.ppqpos, e.chanmsg, e.textmsg = mu.MIDI_GetTextSysexEvt(take, syxidx)
    e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
    if e.chanmsg ~- 0xF0 then
      e.msg2 = e.chanmsg
      e.chanmsg = 0x100
    end
    calcMIDITime(take, e)
    table.insert(allEvents, e)
    if e.selected then table.insert(selectedEvents, e) end
    syxidx = enumTextSysexFn(take, syxidx)
  end

  table.sort(allEvents, function(a, b) return a.projtime < b.projtime end )
end


local function deleteEventsInTake(take, eventTab, doTx)
  if doTx == true or doTx == nil then
    mu.MIDI_OpenWriteTransaction(take)
  end
  for _, event in ipairs(eventTab) do
    if getEventType(event) == gdefs.NOTE_TYPE then
      mu.MIDI_DeleteNote(take, event.idx)
    elseif getEventType(event) == gdefs.CC_TYPE then
      mu.MIDI_DeleteCC(take, event.idx)
    elseif getEventType(event) == gdefs.SYXTEXT_TYPE then
      mu.MIDI_DeleteTextSysexEvt(take, event.idx)
    end
  end
  if doTx == true or doTx == nil then
    mu.MIDI_CommitWriteTransaction(take, false, true)
  end
end

local function postProcessSelection(event)
  local notation = adefs.actionScopeFlagsTable[currentActionScopeFlags].notation
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
Shared.postProcessSelection = postProcessSelection

local function preProcessSelection(take)
  local notation = adefs.actionScopeFlagsTable[currentActionScopeFlags].notation
  if notation == '$invertselect' then -- doesn't exist anymore
    mu.MIDI_SelectAll(take, true) -- select all
  elseif notation == '$exclusiveselect' then
    mu.MIDI_SelectAll(take, false) -- deselect all
  end
end

local function handleRepetitions(prevEvents, event)
  if currentStripRepetitions then
    if prevEvents[event.chan] then
      local pEv = prevEvents[event.chan][event.chanmsg]
      if pEv
        and event.msg2 == pEv.msg2
        and event.msg3 == pEv.msg3
      then
        event.delete = true
      end
    end
    prevEvents[event.chan] = prevEvents[event.chan] or {}
    prevEvents[event.chan][event.chanmsg] = event
  end
end

local function insertEventsIntoTake(take, eventTab, actionFn, contextTab, doTx)
  if doTx == true or doTx == nil then
    mu.MIDI_OpenWriteTransaction(take)
  end

  local prevEvents = {}

  preProcessSelection(take)
  for _, event in ipairs(eventTab) do
    local timeAdjust = getTimeOffset()
    actionFn(event, getSubtypeValueName(event), getMainValueName(event), contextTab) -- event, _value1, _value2, _context
    event.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime - timeAdjust)
    postProcessSelection(event)
    event.muted = (event.flags & 2) ~= 0
    if getEventType(event) == gdefs.NOTE_TYPE then
      if event.projlen <= 0 then event.projlen = 1 / context.PPQ end
      event.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, (event.projtime - timeAdjust) + event.projlen)
      event.msg3 = event.msg3 < 1 and 1 or event.msg3 -- do not turn off the note
      mu.MIDI_InsertNote(take, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.msg2, event.msg3, event.relvel)
    elseif getEventType(event) == gdefs.CC_TYPE then
      handleRepetitions(prevEvents, event)
      if event.delete then
        -- drop it
      else
        local rv, newidx = mu.MIDI_InsertCC(take, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3)
        if rv and event.setcurve then
          mu.MIDI_SetCCShape(take, newidx, event.setcurve, event.setcurveext)
        end
      end
    elseif getEventType(event) == gdefs.SYXTEXT_TYPE then
      mu.MIDI_InsertTextSysexEvt(take, event.selected, event.muted, event.ppqpos, event.chanmsg == 0xF0 and event.chanmsg or event.msg2, event.textmsg)
    end
  end
  nmedefs.handleCreateNewMIDIEvent(take, contextTab, context)
  if doTx == true or doTx == nil then
    mu.MIDI_CommitWriteTransaction(take, false, true)
  end
end

local function setEntrySelectionInTake(take, event)
  if getEventType(event) == gdefs.NOTE_TYPE then
    mu.MIDI_SetNote(take, event.idx, event.selected, nil, nil, nil, nil, nil, nil, nil)
  elseif getEventType(event) == gdefs.CC_TYPE then
    mu.MIDI_SetCC(take, event.idx, event.selected, nil, nil, nil, nil, nil, nil)
  elseif getEventType(event) == gdefs.SYXTEXT_TYPE then
    mu.MIDI_SetTextSysexEvt(take, event.idx, event.selected, nil, nil, nil, nil)
  end
end

local function selectEntriesInTake(take, eventTab, wantsSelect)
  for _, event in ipairs(eventTab) do
    event.selected = wantsSelect
    setEntrySelectionInTake(take, event)
  end
end

local function transformEntryInTake(take, eventTab, actionFn, contextTab, replace)
  local replaceTab = replace and {} or nil
  local timeAdjust = getTimeOffset()

  local prevEvents = {}

  for _, event in ipairs(eventTab) do
    local eventType = getEventType(event)
    actionFn(event, getSubtypeValueName(event), getMainValueName(event), contextTab)
    event.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime - timeAdjust)
    postProcessSelection(event)
    event.muted = (event.flags & 2) ~= 0
    if eventType == gdefs.NOTE_TYPE then
      if (not event.projlen or event.projlen <= 0) then event.projlen = 1 / context.PPQ end
      event.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, (event.projtime - timeAdjust) + event.projlen)
      event.msg3 = event.msg3 < 1 and 1 or event.msg3 -- do not turn off the note
    end

    if replace then
      local eventIdx = eventToIdx(event)
      local replaceData = replaceTab[eventIdx]
      if not replaceData then
        replaceTab[eventIdx] = {}
        replaceData = replaceTab[eventIdx]
      end
      local eventData = replaceData
      if eventType == gdefs.CC_TYPE then
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

    if eventType == gdefs.CC_TYPE then
      handleRepetitions(prevEvents, event)
    end
  end

  mu.MIDI_OpenWriteTransaction(take)
  if replace then
    local grid = Shared.gridInfo().currentGrid
    local PPQ = mu.MIDI_GetPPQ(take)
    local gridSlop = math.floor(((PPQ * grid) * 0.5) + 0.5)
    local rangeType = contextTab.findRange.type

    for _, event in ipairs(replace) do
      local eventType = getEventType(event)
      local eventIdx = eventToIdx(event)
      local eventData
      local replaceData = replaceTab[eventIdx]
      if replaceData then
        if eventType == gdefs.CC_TYPE then eventData = replaceData[event.msg2]
        else eventData = replaceData
        end
      end
      if eventData and rangeType then
        if (rangeType == fdefs.SELECT_TIME_SHEBANG)
          or (rangeType & fdefs.SELECT_TIME_RANGE ~= 0)
        then
          if (not (rangeType & fdefs.SELECT_TIME_MINRANGE ~= 0) or event.ppqpos >= (eventData.startPpq - gridSlop))
            and (not (rangeType & fdefs.SELECT_TIME_MAXRANGE ~= 0) or event.ppqpos <= (eventData.endPpq + gridSlop))
          then
            if eventType == gdefs.NOTE_TYPE then mu.MIDI_DeleteNote(take, event.idx)
            elseif eventType == gdefs.CC_TYPE then mu.MIDI_DeleteCC(take, event.idx)
            elseif eventType == gdefs.SYXTEXT_TYPE then mu.MIDI_DeleteTextSysexEvt(take, event.idx)
            end
          end
        elseif rangeType == fdefs.SELECT_TIME_INDIVIDUAL then
          for _, v in ipairs(eventData) do
            if event.ppqpos >= (v - gridSlop) and event.ppqpos <= (v + gridSlop) then
              if eventType == gdefs.NOTE_TYPE then mu.MIDI_DeleteNote(take, event.idx)
              elseif eventType == gdefs.CC_TYPE then mu.MIDI_DeleteCC(take, event.idx)
              elseif eventType == gdefs.SYXTEXT_TYPE then mu.MIDI_DeleteTextSysexEvt(take, event.idx)
              end
              break
            end
          end
        end
      end
    end
  end

  preProcessSelection(take)
  for _, event in ipairs(eventTab) do
    local eventType = getEventType(event)
    -- handle insert, also type changes
    if eventType == gdefs.NOTE_TYPE then
      if not event.orig_type or event.orig_type == gdefs.NOTE_TYPE then
        mu.MIDI_SetNote(take, event.idx, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.msg2, event.msg3, event.relvel)
      else
        mu.MIDI_InsertNote(take, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.msg2, event.msg3, event.relvel)
        if event.orig_type == gdefs.CC_TYPE then
          mu.MIDI_DeleteCC(take, event.idx)
        elseif event.orig_type == gdefs.SYXTEXT_TYPE then
          mu.MIDI_DeleteTextSysexEvt(take, event.idx)
        end
      end
    elseif eventType == gdefs.CC_TYPE then
      if event.delete then
        mu.MIDI_DeleteCC(take, event.idx)
      elseif not event.orig_type or event.orig_type == gdefs.CC_TYPE then
        mu.MIDI_SetCC(take, event.idx, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3)
        if event.setcurve then
          mu.MIDI_SetCCShape(take, event.idx, event.setcurve, event.setcurveext)
        end
      else
        local rv, newidx = mu.MIDI_InsertCC(take, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3)
        if rv and event.setcurve then
          mu.MIDI_SetCCShape(take, newidx, event.setcurve, event.setcurveext)
        end
        if event.orig_type == gdefs.NOTE_TYPE then
          mu.MIDI_DeleteNote(take, event.idx)
        elseif event.orig_type == gdefs.SYXTEXT_TYPE then
          mu.MIDI_DeleteTextSysexEvt(take, event.idx)
        end
      end
    elseif eventType == gdefs.SYXTEXT_TYPE then
      if not event.orig_type or event.orig_type == gdefs.SYXTEXT_TYPE then
        mu.MIDI_SetTextSysexEvt(take, event.idx, event.selected, event.muted, event.ppqpos, event.chanmsg == 0xF0 and event.chanmsg or event.msg2, event.textmsg)
      else
        if event.orig_type == gdefs.NOTE_TYPE then
          mu.MIDI_DeleteNote(take, event.idx)
        elseif event.orig_type == gdefs.CC_TYPE then
          mu.MIDI_DeleteCC(take, event.idx)
        end
      end
    end
  end
  nmedefs.handleCreateNewMIDIEvent(take, contextTab, context)
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

local function grabAllTakes()
  enumTakesMode = nil -- refresh

  local take = getNextTake()
  if not take then return {} end

  local takes = {}
  local activeTake

  local activeEditor = r.MIDIEditor_GetActive()
  if activeEditor then
    activeTake = r.MIDIEditor_GetTake(activeEditor)
  end

  while take do
    local _, _, _, ppqpos = r.MIDI_GetEvt(take, 0)
    local projTime = r.MIDI_GetProjTimeFromPPQPos(take, ppqpos) + getTimeOffset()
    local active = take == activeTake and true or false
    table.insert(takes, { take = take, firstTime = projTime, active = active })
    take = getNextTake()
  end
  table.sort(takes, function(a, b)
      if a.active then return true
      elseif b.active then return false
      else return a.firstTime < b.firstTime
      end
    end)
  return takes
end

local function processActionForTake(take, ctx)
  -- ctx is optional for backward compat
  ctx = ctx or globalCtx

  local fnString = ''

  context.PPQ = take and mu.MIDI_GetPPQ(take) or 960

  local iterTab = {}
  for _, v in ipairs(adefs.actionRowTable()) do
    if not (v.except or v.disabled) then
      table.insert(iterTab, v)
    end
  end

  for k, v in ipairs(iterTab) do
    local row = v
    local opTab, param1Tab, param2Tab, curTarget, curOperation = actionTabsFromTarget(v)

    if #opTab == 0 then return end -- continue?

    local targetTerm = curTarget.text
    local operation = curOperation
    local operationVal = operation.text

    local paramTerms = { processParams(v, curTarget, curOperation, { param1Tab, param2Tab, {} }, false, context) }

    if paramTerms[1] == '' and curOperation.terms ~= 0 then return end

    local paramNums = { tonumber(paramTerms[1]), tonumber(paramTerms[2]), tonumber(paramTerms[3]) }
    if paramNums[1] and paramNums[2] and paramNums[2] < paramNums[1]
      and not curOperation.freeterm
    then
      local tmp = paramTerms[2]
      paramTerms[2] = paramTerms[1]
      paramTerms[1] = tmp
    end

    local paramTypes = getParamTypesForRow(v, curTarget, curOperation)
    for i = 1, 3 do -- param3
      if paramNums[i] and (paramTypes[i] == gdefs.PARAM_TYPE_INTEDITOR or paramTypes[i] == gdefs.PARAM_TYPE_FLOATEDITOR) and row.params[i].percentVal then
        paramTerms[i] = getParamPercentTerm(paramNums[i], opIsBipolar(curOperation, i))
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
    if row.params[3] and tg.isValidString(row.params[3].textEditorStr) then
      actionTerm = string.gsub(actionTerm, '{param3}', row.params[3].funArg and row.params[3].funArg(row, curTarget, curOperation, paramTerms[3]) or row.params[3].textEditorStr)
    end

    -- musical operations have operation.musical = true OR operation.split[1].musical = true
    -- after unification, paramTypes[1] is METRICGRID for both musical and metricgrid types
    -- check both top-level and split[1] for musical flag
    local opMusical = operation.musical or (operation.split and operation.split[1] and operation.split[1].musical)
    local isMusicalAction = paramTypes[1] == gdefs.PARAM_TYPE_METRICGRID and opMusical
    if isMusicalAction then
      local mgParams = row.mg and tg.tableCopy(row.mg) or {}
      mgParams.param1 = paramNums[1] or -1  -- default to REAPER grid if notation parsing failed
      mgParams.param2 = paramTerms[2] or '100'  -- default to 100% strength
      mgParams.modifiers = mgParams.modifiers or 0  -- ensure modifiers exists
      mgParams.swing = mgParams.swing or 50  -- default swing value
      mgParams.roundmode = mgParams.roundmode or 'round'  -- default round mode

      -- inject groove data from quantizeParams (Phase 23 gap closure)
      if row.quantizeParams and row.quantizeParams.grooveData then
        mgParams.isGroove = true
        mgParams.groove = {
          data = row.quantizeParams.grooveData,
          direction = row.quantizeParams.grooveDirection or 0,
          velStrength = row.quantizeParams.grooveVelStrength or 0,
          toleranceMin = row.quantizeParams.grooveToleranceMin or 0,
          toleranceMax = row.quantizeParams.grooveToleranceMax or 100,
        }
      end

      local serialized = tg.serialize(mgParams)
      -- use function replacement to avoid % escape issues in serialized data
      actionTerm = string.gsub(actionTerm, '{musicalparams}', function() return serialized end)
    end

    -- handle quantize via type's codeTemplate (Phase 27)
    -- detectType checks for src.quantize == true; curTarget (action def from ActionDefs)
    -- has this flag, not row.params[1] (param data)
    local isQuantize = paramTypes[1] == gdefs.PARAM_TYPE_QUANTIZE and true or false
    if isQuantize then
      local _, typeDef = TypeRegistry.detectType(curTarget)
      if typeDef and typeDef.codeTemplate then
        local code
        if type(typeDef.codeTemplate) == 'function' then
          code = typeDef.codeTemplate(row, ctx)
        else
          code = typeDef.codeTemplate
        end
        actionTerm = code
      end
    end

    local isNewMIDIEvent = paramTypes[1] == gdefs.PARAM_TYPE_NEWMIDIEVENT and true or false
    if isNewMIDIEvent then
      -- local nmeParams = tg.tableCopy(row.nme)
      Shared.createNewMIDIEvent_Once = true
      -- actionTerm = string.gsub(actionTerm, '{neweventparams}', tg.serialize(nmeParams))
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

  -- catch unsubstituted placeholders (regression guard)
  local placeholder = fnString:match('{%w+}')
  if placeholder then
    local err = 'Unsubstituted placeholder in generated action code: ' .. placeholder
    mu.post(err)
    Shared.parserError = err
    return nil
  end

  if DEBUGPOST then
    mu.post('======== ACTION FUN ========')
    mu.post(fnString)
    mu.post('============================')
  end

  return fnString
end

local function itemInTable(it, t)
  for i = 1, #t do
    if it == t[i] then return true end
  end
  return false
end

local function processAction(execute, fromScript, skipUndo, ctx)
  -- Create or use provided context
  ctx = ctx or globalCtx

  mediaItemCount = nil
  mediaItemIndex = nil

  if fromScript
    and fdefs.findScopeTable[currentFindScope].notation == '$midieditor'
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
            local etake = r.MIDIEditor_EnumTakes(me, ec, getEnumTakesMode() == 1)
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
                if not itemInTable(itake, meTakes) then
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
      and currentFindScopeFlags ~= fdefs.FIND_SCOPE_FLAG_NONE
      and canOverride
    then
      currentFindScopeFlags = fdefs.FIND_SCOPE_FLAG_NONE -- eliminate all find scope flags
    end
  end

  local takes = grabAllTakes()
  if #takes == 0 then return end

  Shared.createNewMIDIEvent_Once = nil
  Shared.cachedMetric = nil
  Shared.cachedWrapped = nil
  Shared.cachedSOM = nil

  Shared.moveCursorInfo().moveCursorFirstEventPosition = nil
  Shared.addLengthInfo().addLengthFirstEventOffset = nil

  -- fast early return after sanity check
  if not execute then
    local findFn = processFind(nil, nil, ctx)
    if findFn then
      local fnString = processActionForTake(nil, ctx)
      if fnString then
        fnStringToFn(fnString, function(err)
          if err then
            mu.post(err)
          end
          Shared.parserError = 'Fatal error: could not load action description'
        end, ctx)
      else
        Shared.parserError = 'Fatal error: could not load action description'
      end
    end
    return
  end

  if not skipUndo then
    r.Undo_BeginBlock2(0)
  end
  r.PreventUIRefresh(1)

  for _, v in ipairs(takes) do
    local take = v.take
    initializeTake(take)

    makeContextInfo(take, ctx)

    ctx:moveCursorInfo().moveCursorFirstEventPosition_Take = nil
    ctx:addLengthInfo().addLengthFirstEventOffset_Take = nil
    ctx:addLengthInfo().addLengthFirstEventStartTime = nil

    local actionFn
    local actionFnString
    local findFn, wantsEventPreprocessing, findRange, findFnString = processFind(take, nil, ctx)
    if findFn then
      actionFnString = processActionForTake(take, ctx)
      if actionFnString then
        _, actionFn = fnStringToFn(actionFnString, function(err)
          if err then
            mu.post(err)
          end
          Shared.parserError = 'Fatal error: could not load action description'
        end, ctx)
      else
        Shared.parserError = 'Fatal error: could not load action description'
      end
    end

    if findFn and actionFn then
      local function canProcess(found)
        return #found ~=0 or Shared.createNewMIDIEvent_Once
      end

      local notation = adefs.actionScopeTable[currentActionScope].notation
      local defParams = {
        wantsEventPreprocessing = wantsEventPreprocessing,
        findRange = findRange,
        take = take,
        PPQ = context.PPQ,
        findFnString = findFnString,
        actionFnString = actionFnString,
      }
      local selectonly = adefs.actionScopeTable[currentActionScope].selectonly
      local extentsstate = mu.CORRECT_EXTENTS
      mu.CORRECT_EXTENTS = not selectonly and extentsstate or false
      if notation == '$select' then
        mu.MIDI_OpenWriteTransaction(take)
        local found = runFind(findFn, defParams)
        mu.MIDI_SelectAll(take, false)
        selectEntriesInTake(take, found, true)
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$selectadd' then
        mu.MIDI_OpenWriteTransaction(take)
        runFind(findFn, defParams,
          function(event, matches)
            if matches then
              event.selected = true
              setEntrySelectionInTake(take, event)
            end
          end)
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$invertselect' then
        mu.MIDI_OpenWriteTransaction(take)
        local found = runFind(findFn, defParams)
        mu.MIDI_SelectAll(take, true)
        selectEntriesInTake(take, found, false)
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$deselect' then
        mu.MIDI_OpenWriteTransaction(take)
        runFind(findFn, defParams,
          function(event, matches)
            if matches then
              event.selected = false
              setEntrySelectionInTake(take, event)
            end
          end)
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$transform' then
        local found, contextTab = runFind(findFn, defParams)
        if canProcess(found) then
          transformEntryInTake(take, found, actionFn, contextTab) -- could use runFn
        end
      elseif notation == '$replace' then
        local repParams = tg.tableCopy(defParams)
        repParams.wantsUnfound = true
        repParams.addRangeEvents = true
        local found, contextTab, unfound = runFind(findFn, repParams)
        if canProcess(found) then
          transformEntryInTake(take, found, actionFn, contextTab, unfound) -- could use runFn
        end
      elseif notation == '$copy' then
        local found, contextTab = runFind(findFn, defParams)
        if canProcess(found) then
          local newtake = newTakeInNewTrack(take)
          if newtake then
            insertEventsIntoTake(newtake, found, actionFn, contextTab)
          end
        end
      elseif notation == '$copylane' then
        if tg.isREAPER7() then
          local found, contextTab = runFind(findFn, defParams)
          if canProcess(found) then
            local newtake = newTakeInNewLane(take)
            if newtake then
              insertEventsIntoTake(newtake, found, actionFn, contextTab)
            end
          end
        end
      elseif notation == '$insert' then
        local found, contextTab = runFind(findFn, defParams)
        if canProcess(found) then
          insertEventsIntoTake(take, found, actionFn, contextTab) -- could use runFn
        end
      elseif notation == '$insertexclusive' then
        local ieParams = tg.tableCopy(defParams)
        ieParams.wantsUnfound = true
        local found, contextTab, unfound = runFind(findFn, ieParams)
        mu.MIDI_OpenWriteTransaction(take)
        if canProcess(found) then
          insertEventsIntoTake(take, found, actionFn, contextTab, false)
          if unfound and #unfound ~=0 then
            deleteEventsInTake(take, unfound, false)
          end
        end
        mu.MIDI_CommitWriteTransaction(take, false, true)
      elseif notation == '$extracttrack' then
        local found, contextTab = runFind(findFn, defParams)
        if canProcess(found) then
          local newtake = newTakeInNewTrack(take)
          if newtake then
            insertEventsIntoTake(newtake, found, actionFn, contextTab)
          end
          deleteEventsInTake(take, found)
        end
      elseif notation == '$extractlane' then
        if tg.isREAPER7() then
          local found, contextTab = runFind(findFn, defParams)
          if canProcess(found) then
            local newtake = newTakeInNewLane(take)
            if newtake then
              insertEventsIntoTake(newtake, found, actionFn, contextTab)
            end
            deleteEventsInTake(take, found)
          end
        end
      elseif notation == '$delete' then
        local found = runFind(findFn, defParams)
        if #found ~= 0 then
          deleteEventsInTake(take, found) -- could use runFn
        end
      end
      mu.CORRECT_EXTENTS = extentsstate
    end
    Shared.contextInfo = nil
  end

  r.PreventUIRefresh(-1)
  if not skipUndo then
    r.Undo_EndBlock2(0, 'Transformer: ' .. adefs.actionScopeTable[currentActionScope].label, -1)
  end
end

local function setPresetNotesBuffer(buf)
  libPresetNotesBuffer = buf
end

local function getCurrentPresetState()
  local fsFlags
  if fdefs.findScopeTable[currentFindScope].notation == '$midieditor' then
    fsFlags = {} -- not pretty
    if currentFindScopeFlags & fdefs.FIND_SCOPE_FLAG_SELECTED_ONLY ~= 0 then table.insert(fsFlags, '$selectedonly') end
    if currentFindScopeFlags & fdefs.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW ~= 0 then table.insert(fsFlags, '$activenoterow') end
  end

  local ppInfo
  if currentFindPostProcessingInfo.flags ~= fdefs.FIND_POSTPROCESSING_FLAG_NONE then
    local ppFlags = currentFindPostProcessingInfo.flags
    ppInfo = tg.tableCopy(currentFindPostProcessingInfo)
    ppInfo.flags = {}
    if ppFlags & fdefs.FIND_POSTPROCESSING_FLAG_FIRSTEVENT ~= 0 then table.insert(ppInfo.flags, '$firstevent') end
    if ppFlags & fdefs.FIND_POSTPROCESSING_FLAG_LASTEVENT ~= 0 then table.insert(ppInfo.flags, '$lastevent') end
  end

  -- serialize action rows with structured data (for quantizeParams)
  local actionRows = {}
  for k, v in ipairs(adefs.actionRowTable()) do
    local row = {
      targetEntry = v.targetEntry,
      operationEntry = v.operationEntry,
    }
    if v.quantizeParams then
      row.quantizeParams = tg.tableCopy(v.quantizeParams)
      -- convert grooveFilePath to portable format for cross-system compatibility
      if row.quantizeParams.grooveFilePath then
        row.quantizeParams.grooveFilePath = tg.toPortablePath(row.quantizeParams.grooveFilePath)
      end
    end
    table.insert(actionRows, row)
  end

  local presetTab = {
    findScope = fdefs.findScopeTable[currentFindScope].notation,
    findScopeFlags = fsFlags,
    findMacro = findRowsToNotation(),
    findPostProcessing = ppInfo,
    actionScope = adefs.actionScopeTable[currentActionScope].notation,
    actionMacro = actionRowsToNotation(),
    actionRows = actionRows,
    actionScopeFlags = adefs.actionScopeFlagsTable[currentActionScopeFlags].notation,
    notes = libPresetNotesBuffer,
    scriptIgnoreSelectionInArrangeView = false,
    notesInChord = tg.getNotesInChord(),
    stripRepetitions = currentStripRepetitions
  }
  return presetTab
end

local function savePreset(pPath, scriptTab)
  local f = io.open(pPath, 'wb')
  local saved = false
  local wantsScript = scriptTab.script
  local ignoreSelectionInArrangeView = wantsScript and scriptTab.ignoreSelectionInArrangeView
  local scriptPrefix = scriptTab.scriptPrefix

  if f then
    local presetTab = getCurrentPresetState()
    presetTab.scriptIgnoreSelectionInArrangeView = ignoreSelectionInArrangeView
    f:write(tg.serialize(presetTab) .. '\n')
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

local function suspendUndo()
  undoSuspended = true
end

local function resumeUndo()
  undoSuspended = false
end

local function createUndoStep(state)
  if undoSuspended then return end
  while undoPointer > 1 do
    table.remove(undoTable, 1)
    undoPointer = undoPointer - 1
  end
  table.insert(undoTable, 1, state and state or getCurrentPresetState())
  undoPointer = 1
end

local function loadPresetFromTable(presetTab)
  -- set range filter grid override if present (from Quantize dialog)
  Shared.setRangeFilterGrid(presetTab.rangeFilterGrid)

  currentFindScopeFlags = fdefs.FIND_SCOPE_FLAG_NONE -- do this first (FindScopeFromNotation() may populate it)
  currentFindScope = fdefs.findScopeFromNotation(presetTab.findScope)
  local fsFlags = presetTab.findScopeFlags -- not pretty
  if fsFlags then
    for _, v in ipairs(fsFlags) do
      currentFindScopeFlags = currentFindScopeFlags | fdefs.findScopeFlagFromNotation(v)
    end
  end
  if presetTab.findPostProcessing then
    local ppFlags = presetTab.findPostProcessing.flags
    currentFindPostProcessingInfo = tg.tableCopy(presetTab.findPostProcessing)
    currentFindPostProcessingInfo.flags = fdefs.FIND_POSTPROCESSING_FLAG_NONE
    if ppFlags then
      for _, v in ipairs(ppFlags) do
        currentFindPostProcessingInfo.flags = currentFindPostProcessingInfo.flags | fdefs.findPostProcessingFlagFromNotation(v)
      end
    end
  end
  currentActionScope = adefs.actionScopeFromNotation(presetTab.actionScope)
  currentActionScopeFlags = adefs.actionScopeFlagsFromNotation(presetTab.actionScopeFlags)
  fdefs.clearFindRowTable()
  processFindMacro(presetTab.findMacro)
  adefs.clearActionRowTable()
  processActionMacro(presetTab.actionMacro)

  -- restore quantizeParams from structured actionRows (if present)
  if presetTab.actionRows then
    local actionRowTable = adefs.actionRowTable()
    for k, presetRow in ipairs(presetTab.actionRows) do
      if actionRowTable[k] and presetRow.quantizeParams then
        actionRowTable[k].quantizeParams = tg.tableCopy(presetRow.quantizeParams)
        -- convert portable grooveFilePath back to absolute
        if actionRowTable[k].quantizeParams.grooveFilePath then
          actionRowTable[k].quantizeParams.grooveFilePath = tg.fromPortablePath(actionRowTable[k].quantizeParams.grooveFilePath)
        end
      end
    end
  end

  scriptIgnoreSelectionInArrangeView = presetTab.scriptIgnoreSelectionInArrangeView
  tg.setNotesInChord(presetTab.notesInChord)
  currentStripRepetitions = presetTab.stripRepetitions
  return presetTab.notes
end

local function loadPreset(pPath)
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
      if tg.isValidString(tabStr) then
        local presetTab = tg.deserialize(tabStr)
        if presetTab then
          local notes = loadPresetFromTable(presetTab)
          dirtyFind = true
          return true, notes, presetTab.scriptIgnoreSelectionInArrangeView
        end
      end
    end
  end
  return false, nil
end

-- literal means (-16394/0) - 16393, otherwise it's -8192 - 8191 and needs to be shifted
local function pitchBendTo14Bit(val, literal)
  if not literal then
    if val < 0 then val = val + (1 << 13) else val = val + ((1 << 13) - 1) end
  end
  return (val / ((1 << 14) - 1)) * 100
end

local function setRowParam(row, index, paramType, editorType, strVal, range, literal)
  local isMetricOrMusical = (paramType == gdefs.PARAM_TYPE_METRICGRID or paramType == gdefs.PARAM_TYPE_MUSICAL)
  local isNewMIDIEvent = paramType == gdefs.PARAM_TYPE_NEWMIDIEVENT
  local isBitField = editorType == gdefs.EDITOR_TYPE_BITFIELD
  local isQuantize = paramType == gdefs.PARAM_TYPE_QUANTIZE
  local isSpecial = (isMetricOrMusical or isBitField or isNewMIDIEvent or isQuantize)

  -- here is where range is enforced after text entry (in ensureNumString)
  row.params[index].textEditorStr = isSpecial and strVal or tg.ensureNumString(strVal, range)
  if isSpecial or not editorType then
    row.params[index].percentVal = nil
    -- nothing
  else
    local val = tonumber(row.params[index].textEditorStr)
    if editorType == gdefs.EDITOR_TYPE_PERCENT or editorType == gdefs.EDITOR_TYPE_PERCENT_BIPOLAR then
      row.params[index].percentVal = literal and nil or val
    elseif editorType == gdefs.EDITOR_TYPE_PITCHBEND or editorType == gdefs.EDITOR_TYPE_PITCHBEND_BIPOLAR then
      row.params[index].percentVal = pitchBendTo14Bit(val, literal or editorType == gdefs.EDITOR_TYPE_PITCHBEND_BIPOLAR)
    elseif editorType == gdefs.EDITOR_TYPE_7BIT or editorType == gdefs.EDITOR_TYPE_7BIT_NOZERO or editorType == gdefs.EDITOR_TYPE_7BIT_BIPOLAR then
      row.params[index].percentVal = (val / ((1 << 7) - 1)) * 100
    end
  end
end

local function getRowParamRange(row, target, condOp, paramType, editorType, idx)
  local range = ((condOp.split and condOp.split[idx].norange) or condOp.norange) and {}
                  or (condOp.split and condOp.split[idx].range) and condOp.split[idx].range
                  or condOp.range and condOp.range
                  or target.range
  local bipolar = false

  if condOp.percent or (condOp.split and condOp.split[idx].percent) then range = gdefs.EDITOR_PERCENT_RANGE
  elseif editorType == gdefs.EDITOR_TYPE_PITCHBEND then range = gdefs.EDITOR_PITCHBEND_RANGE
  elseif editorType == gdefs.EDITOR_TYPE_PITCHBEND_BIPOLAR then range = gdefs.EDITOR_PITCHBEND_BIPOLAR_RANGE bipolar = true
  elseif editorType == gdefs.EDITOR_TYPE_PERCENT then range = gdefs.EDITOR_PERCENT_RANGE
  elseif editorType == gdefs.EDITOR_TYPE_PERCENT_BIPOLAR then range = gdefs.EDITOR_PERCENT_BIPOLAR_RANGE bipolar = true
  elseif editorType == gdefs.EDITOR_TYPE_7BIT then range = gdefs.EDITOR_7BIT_RANGE
  elseif editorType == gdefs.EDITOR_TYPE_7BIT_BIPOLAR then range = gdefs.EDITOR_7BIT_BIPOLAR_RANGE bipolar = true
  elseif editorType == gdefs.EDITOR_TYPE_7BIT_NOZERO then range = gdefs.EDITOR_7BIT_NOZERO_RANGE
  elseif editorType == gdefs.EDITOR_TYPE_14BIT then range = gdefs.EDITOR_14BIT_RANGE
  elseif editorType == gdefs.EDITOR_TYPE_14BIT_BIPOLAR then range = gdefs.EDITOR_14BIT_BIPOLAR_RANGE bipolar = true
  end

  if range and #range == 0 then range = nil end
  return range, bipolar
end

local function handlePercentString(strVal, row, target, condOp, paramType, editorType, index, range, bipolar)
  if not range then
    range, bipolar = getRowParamRange(row, target, condOp, paramType, editorType, index)
  end

  if range and range[1] and range[2] and row.params[index].percentVal then
    local percentVal = row.params[index].percentVal / 100
    local scaledVal
    if editorType == gdefs.EDITOR_TYPE_PITCHBEND and condOp.literal then
      scaledVal = percentVal * ((1 << 14) - 1)
    elseif bipolar then
      scaledVal = percentVal * range[2]
    else
      scaledVal = (percentVal * (range[2] - range[1])) + range[1]
    end
    if paramType == gdefs.PARAM_TYPE_INTEDITOR then
      scaledVal = math.floor(scaledVal + 0.5)
    end
    strVal = tostring(scaledVal)
  end
  return strVal
end
Shared.handlePercentString = handlePercentString

local function update(action, wantsState)
  if not action then
    processFind()
  else
    processAction()
  end

  local nowState = getCurrentPresetState()
  createUndoStep(nowState)
  return wantsState and nowState or nil
end

local lastHasTable = {}

-- local
getHasTable = function()
  local fresh = false
  if dirtyFind then
    local hasTable = {}

    mediaItemCount = nil
    mediaItemIndex = nil

    local takes = grabAllTakes()

    Shared.cachedMetric = nil
    Shared.cachedWrapped = nil
    Shared.cachedSOM = nil

    local count = 0

    for _, v in ipairs(takes) do
      initializeTake(v.take)
      local findFn, _, findRange = processFind(v.take, true)
      local _, contextTab = runFind(findFn, { wantsEventPreprocessing = true, findRange = findRange, take = v.take, PPQ = mu.MIDI_GetPPQ(v.take) })
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

TransformerLib.findScopeTable = fdefs.findScopeTable
TransformerLib.currentFindScope = function() return currentFindScope end
TransformerLib.setCurrentFindScope = function(val)
  currentFindScope = val < 1 and 1 or val > #fdefs.findScopeTable and #fdefs.findScopeTable or val
end
TransformerLib.getFindScopeFlags = function() return currentFindScopeFlags end
TransformerLib.setFindScopeFlags = function(flags)
  currentFindScopeFlags = flags
end
TransformerLib.getFindPostProcessingInfo = function() return currentFindPostProcessingInfo end
TransformerLib.setFindPostProcessingInfo = function(info)
  currentFindPostProcessingInfo = info -- could add error checking, but nope
end
TransformerLib.clearFindPostProcessingInfo = clearFindPostProcessingInfo
TransformerLib.actionScopeTable = adefs.actionScopeTable
TransformerLib.currentActionScope = function() return currentActionScope end
TransformerLib.setCurrentActionScope = function(val)
  currentActionScope = val < 1 and 1 or val > #adefs.actionScopeTable and #adefs.actionScopeTable or val
end
TransformerLib.actionScopeFlagsTable = adefs.actionScopeFlagsTable
TransformerLib.currentActionScopeFlags = function() return currentActionScopeFlags end
TransformerLib.setCurrentActionScopeFlags = function(val)
  currentActionScopeFlags = val < 1 and 1 or val > #adefs.actionScopeFlagsTable and #adefs.actionScopeFlagsTable or val
end

TransformerLib.FindRow = fdefs.FindRow
TransformerLib.findRowTable = function() return fdefs.findRowTable() end
TransformerLib.clearFindRows = function() fdefs.clearFindRowTable() end

TransformerLib.startParenEntries = fdefs.startParenEntries
TransformerLib.endParenEntries = fdefs.endParenEntries
TransformerLib.findBooleanEntries = fdefs.findBooleanEntries
TransformerLib.findTimeFormatEntries = fdefs.findTimeFormatEntries

TransformerLib.ActionRow = adefs.ActionRow
TransformerLib.actionRowTable = function() return adefs.actionRowTable() end
TransformerLib.clearActionRows = function() adefs.clearActionRowTable() end

TransformerLib.findTargetEntries = fdefs.findTargetEntries
TransformerLib.actionTargetEntries = adefs.actionTargetEntries

TransformerLib.getSubtypeValueLabel = getSubtypeValueLabel
TransformerLib.getMainValueLabel = getMainValueLabel

TransformerLib.processFindMacro = processFindMacro
TransformerLib.processActionMacro = processActionMacro

TransformerLib.processFind = processFind
TransformerLib.processAction = processAction
TransformerLib.processActionForTake = processActionForTake

TransformerLib.savePreset = savePreset
TransformerLib.loadPreset = loadPreset

TransformerLib.timeFormatRebuf = timeFormatRebuf
TransformerLib.lengthFormatRebuf = lengthFormatRebuf

TransformerLib.getParamTypesForRow = getParamTypesForRow
TransformerLib.findTabsFromTarget = findTabsFromTarget
TransformerLib.check14Bit = check14Bit
TransformerLib.actionTabsFromTarget = actionTabsFromTarget
TransformerLib.findRowToNotation = findRowToNotation
TransformerLib.actionRowToNotation = actionRowToNotation

TransformerLib.setRowParam = setRowParam
TransformerLib.getRowParamRange = getRowParamRange

TransformerLib.getHasTable = getHasTable

TransformerLib.setEditorTypeForRow = function(row, idx, type)
  row.params[idx].editorType = type
end

TransformerLib.getFindScopeFlagLabel = function()
  local label = ''
  if currentFindScopeFlags & fdefs.FIND_SCOPE_FLAG_SELECTED_ONLY ~= 0 then
    label = label .. (label ~= '' and ' + ' or '') .. 'Selected'
  end
  if currentFindScopeFlags & fdefs.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW ~= 0 then
    label = label .. (label ~= '' and ' + ' or '') .. 'NoteRow'
  end
  if label == '' then label = 'None' end
  return label
end

TransformerLib.getFindPostProcessingLabel = function()
  local label = ''
  local flags = currentFindPostProcessingInfo.flags
  if flags & fdefs.FIND_POSTPROCESSING_FLAG_FIRSTEVENT ~= 0 then
    label = label .. (label ~= '' and ' + ' or '') .. 'First'
  end
  if flags & fdefs.FIND_POSTPROCESSING_FLAG_LASTEVENT ~= 0 then
    label = label .. (label ~= '' and ' + ' or '') .. 'Last'
  end
  if label == '' then label = 'None' end
  return label
end

TransformerLib.FIND_SCOPE_FLAG_NONE = fdefs.FIND_SCOPE_FLAG_NONE
TransformerLib.FIND_SCOPE_FLAG_SELECTED_ONLY = fdefs.FIND_SCOPE_FLAG_SELECTED_ONLY
TransformerLib.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW = fdefs.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW

TransformerLib.FIND_POSTPROCESSING_FLAG_NONE = fdefs.FIND_POSTPROCESSING_FLAG_NONE
TransformerLib.FIND_POSTPROCESSING_FLAG_FIRSTEVENT = fdefs.FIND_POSTPROCESSING_FLAG_FIRSTEVENT
TransformerLib.FIND_POSTPROCESSING_FLAG_LASTEVENT = fdefs.FIND_POSTPROCESSING_FLAG_LASTEVENT

TransformerLib.NEWEVENT_POSITION_ATCURSOR = adefs.NEWEVENT_POSITION_ATCURSOR
TransformerLib.NEWEVENT_POSITION_ATPOSITION = adefs.NEWEVENT_POSITION_ATPOSITION

TransformerLib.setUpdateItemBoundsOnEdit = function(v) mu.CORRECT_EXTENTS = v and true or false end

TransformerLib.makeDefaultMetricGrid = mgdefs.makeDefaultMetricGrid
TransformerLib.makeDefaultEveryN = evndefs.makeDefaultEveryN
TransformerLib.makeDefaultNewMIDIEvent = nmedefs.makeDefaultNewMIDIEvent
TransformerLib.makeParam3 = function(row)
  local _, _, _, target, operation = actionTabsFromTarget(row)
  if target.notation == '$position'
    and operation.notation == ':scaleoffset'
  then
    p3.makeParam3PositionScaleOffset(row)
  elseif operation.notation == ':line'
    or operation.notation == ':relline'
    or operation.notation == ':rampscale'
  then
    p3.makeParam3Line(row, operation.notation == ':rampscale')
  elseif operation.notation == ':thresh' then
    p3.makeParam3Thresh(row, target)
  end
end
TransformerLib.makeDefaultEventSelector = evseldefs.makeDefaultEventSelector

TransformerLib.startup = startup
TransformerLib.mu = mu
TransformerLib.handlePercentString = handlePercentString

TransformerLib.getMetricGridModifiers = mgdefs.getMetricGridModifiers
TransformerLib.setMetricGridModifiers = mgdefs.setMetricGridModifiers

TransformerLib.typeEntriesForEventSelector = fdefs.typeEntriesForEventSelector
TransformerLib.setPresetNotesBuffer = setPresetNotesBuffer
TransformerLib.update = update
TransformerLib.loadPresetFromTable = loadPresetFromTable

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

TransformerLib.createUndoStep = createUndoStep
TransformerLib.clearUndo = function()
  undoTable = {}
  undoPointer = 0
  createUndoStep()
end

TransformerLib.suspendUndo = suspendUndo
TransformerLib.resumeUndo = resumeUndo

TransformerLib.isANote = isANote

TransformerLib.getWantsStripRepetitions = function() return currentStripRepetitions end
TransformerLib.setWantsStripRepetitions = function(way) currentStripRepetitions = way and true or false end

TransformerLib.TypeRegistry = TypeRegistry

TransformerLib.TransformerContext = TransformerContext
TransformerLib.getGlobalContext = function() return globalCtx end

return TransformerLib

-----------------------------------------------------------------------------
----------------------------------- FIN -------------------------------------
