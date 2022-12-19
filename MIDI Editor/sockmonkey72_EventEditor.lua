-- @description MIDI Event Editor
-- @version 1.1.0-beta.1
-- @author sockmonkey72
-- @about
--   # MIDI Event Editor
--   One-line MIDI event editor
--
--   The Math Operators ()+, -, *, /) can be used to calculate relative values, also on multi-selected values.
--
--   The Range Operator (.) can be used to scale a selection from its current range to the specified target range
--   (for example: .20-80 will scale the selected events to the range 20-80).
--
--   When setting negative absolute values for pitch bend, use --VALUE (instead of -VALUE, which will use the
--   '-' Math Operator)
-- @changelog
--   - initial
-- @provides
--   {MIDIUtils}/*
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_EventEditor.lua

-----------------------------------------------------------------------------
----------------------------------- TODO ------------------------------------

-- TODO
-- - [x] arrow up/down to change active item (how would I do this so that changes can be seen?)
--   [see commented code for focusKeyboardHere for current attempts on this]
-- - [ ] transform menu: invert, retrograde (can use selection for center point), quantize?
-- - [ ] help text describing keyboard shortcuts

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

local r = reaper

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. '?.lua;' -- GET DIRECTORY FOR REQUIRE
local s = require 'MIDIUtils/MIDIUtils'

local function post(...)
  local args = {...}
  local str = ''
  for i, v in ipairs(args) do
    str = str .. (i ~= 1 and ', ' or '') .. tostring(v)
  end
  str = str .. '\n'
  r.ShowConsoleMsg(str)
end

local function fileExists(name)
  local f = io.open(name,'r')
  if f ~= nil then io.close(f) return true else return false end
end

local canStart = true

local imGuiPath = r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua'
if not fileExists(imGuiPath) then
  post('MIDI Event Editor requires \'ReaImGui\' 0.8+ (install from ReaPack)\n')
  canStart = false
end

if not r.APIExists('JS_Mouse_GetState') then
  post('MIDI Event Editor requires the \'js_ReaScriptAPI\' extension (install from ReaPack)\n')
  canStart = false
end

if not s.CheckDependencies('MIDI Event Editor') then
  canStart = false
end

if not canStart then return end

dofile(r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8')

local scriptID = 'sockmonkey72_EventEditor'

local ctx = r.ImGui_CreateContext(scriptID) --, r.ImGui_ConfigFlags_DockingEnable()) -- TODO docking
--r.ImGui_SetConfigVar(ctx, r.ImGui_ConfigVar_DockingWithShift(), 1) -- TODO docking

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local FONTSIZE_LARGE = 13
local FONTSIZE_SMALL = 11
local DEFAULT_WIDTH = 64 * FONTSIZE_LARGE
local DEFAULT_HEIGHT = 7 * FONTSIZE_LARGE
local DEFAULT_ITEM_WIDTH = 60

local windowInfo
local fontInfo

local commonEntries = { 'measures', 'beats', 'ticks', 'chan' }
local scaleOpWhitelist = { 'pitch', 'channel', 'vel', 'notedur', 'ccnum', 'ccval' }

local INVALID = -0xFFFFFFFF

local popupFilter = 0x90 -- note default
local canvasScale = 1.0
local DEFAULT_TITLEBAR_TEXT = 'Event Editor'
local titleBarText = DEFAULT_TITLEBAR_TEXT
local rewriteIDForAFrame
local focusKeyboardHere

local OP_ABS = 0
local OP_ADD = string.byte('+', 1)
local OP_SUB = string.byte('-', 1)
local OP_MUL = string.byte('*', 1)
local OP_DIV = string.byte('/', 1)
local OP_SCL = string.byte('.', 1)

local ccTypes = {}
ccTypes[0x90] = { val = 0x90, label = 'Note', exists = false }
ccTypes[0xA0] = { val = 0xA0, label = 'PolyAT', exists = false }
ccTypes[0xB0] = { val = 0xB0, label = 'CC', exists = false }
ccTypes[0xC0] = { val = 0xC0, label = 'PrgCh', exists = false }
ccTypes[0xD0] = { val = 0xD0, label = 'ChanAT', exists = false }
ccTypes[0xE0] = { val = 0xE0, label = 'Pitch', exists = false }

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

local function prepRandomShit()
  -- remove deprecated ExtState entries
  if r.HasExtState(scriptID, 'correctOverlaps') then
    r.DeleteExtState(scriptID, 'correctOverlaps', true)
  end
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

  windowInfo.defaultWidth = 64 * fontInfo.largeDefaultSize
  windowInfo.defaultHeight = 7 * fontInfo.smallDefaultSize
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

-----------------------------------------------------------------------------
-------------------------------- THE GUTS -----------------------------------

local ppqToTime -- forward declaration to avoid vs.code warning
local performOperation -- forward declaration
local doPerformOperation -- forward declaration

local done = false

local function windowFn()
  ---------------------------------------------------------------------------
  ---------------------------------- GET TAKE -------------------------------

  local take = r.MIDIEditor_GetTake(r.MIDIEditor_GetActive())
  if not take then return end

  ---------------------------------------------------------------------------
  --------------------------- BUNCH OF VARIABLES ----------------------------

  local canProcess = false
  local popupLabel = 'Note'
  local cc2byte = false
  local hasNotes = false
  local hasCCs = false
  local NOTE_TYPE = s.NOTE_TYPE
  local NOTEOFF_TYPE = s.NOTEOFF_TYPE
  local CC_TYPE = s.CC_TYPE
  local NOTE_FILTER = 0x90
  local changedParameter = nil
  local overlapFavorsSelected = r.GetExtState(scriptID, 'overlapFavorsSelected') == '1'
  local wantsBBU = r.GetExtState(scriptID, 'bbu') == '1'
  local reverseScroll = r.GetExtState(scriptID, 'reverseScroll') == '1'
  local allEvents = {}
  local selectedEvents = {}
  local selectedNotes = {}
  local newNotes = {}
  local userValues = {}
  local union = {} -- determine a filter and calculate the union of selected values
  local PPQ
  local vx, vy = r.ImGui_GetWindowPos(ctx)
  local activeFieldName
  local pitchDirection = 0
  local touchedEvents = {}

  ---------------------------------------------------------------------------
  --------------------------- BUNCH OF FUNCTIONS ----------------------------

  local function getPPQ()
    local qn1 = r.MIDI_GetProjQNFromPPQPos(take, 0)
    local qn2 = qn1 + 1
    return math.floor(r.MIDI_GetPPQPosFromProjQN(take, qn2) - r.MIDI_GetPPQPosFromProjQN(take, qn1))
  end

  local function needsBBUConversion(name)
    return wantsBBU and (name == 'ticks' or name == 'notedur' or name == 'selposticks' or name == 'seldurticks')
  end

  local function BBTToPPQ(measures, beats, ticks, relativeppq, nosubtract)
    if not measures then measures = 0 end
    if not beats then beats = 0 end
    if not ticks then ticks = 0 end
    if relativeppq then
      local relMeasures, relBeats, _, relTicks = ppqToTime(relativeppq)
      measures = measures + relMeasures
      beats = beats + relBeats
      ticks = ticks + relTicks
    end
    local ppqpos = r.MIDI_GetPPQPosFromProjTime(take, r.TimeMap2_beatsToTime(0, beats, measures)) + ticks
    if relativeppq and not nosubtract then ppqpos = ppqpos - relativeppq end
    return math.floor(ppqpos)
  end

  function ppqToTime(ppqpos)
    local _, posMeasures, cml, posBeats = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, ppqpos))
    local _, posMeasuresSOM, _, posBeatsSOM = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)))

    local measures = posMeasures
    local beats = math.floor(posBeats - posBeatsSOM)
    local beatsmax = math.floor(cml)
    local posBeats_PPQ = BBTToPPQ(nil, math.floor(posBeats))
    local ticks = math.floor(ppqpos - posBeats_PPQ)
    return measures, beats, beatsmax, ticks
  end

  local function ppqToLength(ppqpos, ppqlen)
    -- REAPER, why is this so difficult?
    -- get the PPQ position of the nearest measure start (to ensure that we're dealing with round values)
    local _, startMeasures, _, startBeats = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)))
    local startPPQ = BBTToPPQ(nil,  math.floor(startBeats))

    -- now we need the nearest measure start to the end position
    local _, endMeasuresSOM, _, endBeatsSOM = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, r.MIDI_GetPPQPos_StartOfMeasure(take, startPPQ + ppqlen)))
    -- and the actual end position
    local _, endMeasures, _, endBeats = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, startPPQ + ppqlen))

    local measures = endMeasures - startMeasures -- measures from start to end
    local beats = math.floor(endBeats - endBeatsSOM) -- beats from the SOM (only this measure)
    local endBeats_PPQ = BBTToPPQ(nil,  math.floor(endBeats)) -- ppq location of the beginning of this beat
    local ticks = math.floor((startPPQ + ppqlen) - endBeats_PPQ) -- finally the ticks
    return measures, beats, ticks
  end

  local function calcMIDITime(e)
    e.measures, e.beats, e.beatsmax, e.ticks = ppqToTime(e.ppqpos)
  end

  local function unionEntry(name, val, entry)
    if entry.chanmsg == popupFilter then
      if not union[name] then union[name] = val
      elseif union[name] ~= val then union[name] = INVALID end
    end
  end

  local function commonUnionEntries(e)
    for _, v in ipairs(commonEntries) do
      unionEntry(v, e[v], e)
    end

    if e.chanmsg == popupFilter then
      if e.ppqpos < union.selposticks then union.selposticks = e.ppqpos end
      if e.type == NOTE_TYPE then
        if e.endppqpos > union.selendticks then union.selendticks = e.endppqpos end
      else
        if e.ppqpos > union.selendticks then union.selendticks = e.ppqpos end
      end
    end
  end

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE FUNS -----------------------------

  local itemBounds = {}
  local ranges = {}
  local currentRect = {}

  local recalcEventTimes = false
  local recalcSelectionTimes = false

  local function genItemID(name)
    local itemID = '##'..name
    if rewriteIDForAFrame == name then
      itemID = itemID..'_inactive'
      rewriteIDForAFrame = nil
    end
    return itemID
  end

  local function registerItem(name, recalcEvent, recalcSelection)
    local ix1, ix2 = currentRect.left, currentRect.right
    local iy1, iy2 = currentRect.top, currentRect.bottom
    table.insert(itemBounds, { name = name,
                               hitx = { ix1 - vx, ix2 - vx },
                               hity = { iy1 - vy, iy2 - vy },
                               recalcEvent = recalcEvent and true or false,
                               recalcSelection = recalcSelection and true or false
                             })
  end

  local function stringToValue(name, str, op)
    local val = tonumber(str)
    if val then
      if (not op or op == OP_ABS)
        and (name == 'chan' or name == 'beats')
      then
          val = val - 1
      elseif (wantsBBU
        and (not op or op == OP_ABS or op == OP_ADD or op == OP_SUB)
        and (name == 'ticks' or name == 'notedur'))
      then
        val = math.floor((val * 0.01) * PPQ)
      end
      return val
    end
    return nil
  end

  local function makeVal(name, str, op)
    local val = stringToValue(name, str, op)
    if val then
      userValues[name] = { operation = op and op or OP_ABS, opval = val }
      return true
    end
    return false
  end

  local function paramCanScale(name)
    local canscale = false
    for _, v in ipairs(scaleOpWhitelist) do
      if name == v then
        canscale = true
        break
      end
    end
    return canscale
  end

  local function processString(name, str)
    local char = str:byte(1)
    local val

    -- special case for setting negative numbers for pitch bend
    if name == 'ccval' and popupFilter == 0xE0 and char == OP_SUB then
      if str:byte(2) == OP_SUB then -- two '--' means 'set' for negative pitch bend
        return makeVal(name, str:sub(2))
      end
    end

    if char == OP_SCL then
      if not paramCanScale(name) then return false end

      local first, second = str:sub(2):match('([-+]?%d+)[%s%-]+([-+]?%d+)')
      if first and second then
        if needsBBUConversion(name) then
          first = (first * 0.01) * PPQ
          second = (second * 0.01) * PPQ
        end
        userValues[name] = { operation = char, opval = first, opval2 = second }
        return true
      else return false
      end
    elseif char == OP_ADD or char == OP_SUB or char == OP_MUL or char == OP_DIV then
      if makeVal(name, str:sub(2), char) then return true end
    end

    return makeVal(name, str)
  end

  local function isTimeValue(name)
    if name == 'measures' or name == 'beats' or name == 'ticks' or name == 'notedur' then
      return true
    end
    return false
  end

  local function getCurrentRange(name)
    if not ranges[name] then
      local rangeLo = 0xFFFF
      local rangeHi = -0xFFFF
      for _, v in ipairs(selectedEvents) do
        if v.chanmsg == popupFilter then
          if v[name] and v[name] ~= INVALID then
            if v[name] < rangeLo then rangeLo = v[name] end
            if v[name] > rangeHi then rangeHi = v[name] end
          end
        end
      end
      ranges[name] = { lo = math.floor(rangeLo), hi = math.floor(rangeHi) }
    end
    return ranges[name].lo, ranges[name].hi
  end

  local function getCurrentRangeForDisplay(name)
    local lo, hi = getCurrentRange(name)
    if needsBBUConversion(name) then
      lo = math.floor((lo / PPQ) * 100)
      hi = math.floor((hi / PPQ) * 100)
    end
    return lo, hi
  end

  local function generateLabel(label)
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
  end

  local function generateRangeLabel(name)

    if not paramCanScale(name) then return end

    local lo, hi = getCurrentRangeForDisplay(name)
    if lo ~= hi then
      local ix, iy = currentRect.left, currentRect.bottom
      r.ImGui_PushFont(ctx, fontInfo.small)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFBF)
      local text =  '['..lo..'-'..hi..']'
      local tw, th = r.ImGui_CalcTextSize(ctx, text)
      local fp = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()) / 2
      local minx = ix
      local miny = iy + 3
      r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(ctx), minx - fp, miny - fp, minx + tw + fp + 2, miny + th + fp + 2, 0x333355BF)
      minx = minx - vx
      miny = miny - vy
      r.ImGui_SetCursorPos(ctx, minx + 1, miny + 2)
      r.ImGui_Text(ctx, text)
      r.ImGui_PopStyleColor(ctx)
      r.ImGui_PopFont(ctx)
    end
  end

  local function kbdEntryIsCompleted()
    return (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
            or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Tab())
            or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter()))
  end

  local function makeTextInput(name, label, more, wid)
    local timeval = isTimeValue(name)
    r.ImGui_SameLine(ctx)
    r.ImGui_BeginGroup(ctx)
    r.ImGui_SetNextItemWidth(ctx, wid and (wid * canvasScale) or (DEFAULT_ITEM_WIDTH * canvasScale))
    r.ImGui_SetCursorPosX(ctx, (currentRect.right - vx) + (2 * canvasScale) + (more and (4 * canvasScale) or 0))

    r.ImGui_PushFont(ctx, fontInfo.large)

    local val = userValues[name].opval
    if val ~= INVALID then
      if (name == 'chan' or name == 'beats') then val = val + 1
      elseif needsBBUConversion(name) then val = math.floor((val / PPQ) * 100)
      end
    end

    local str = val ~= INVALID and tostring(val) or '-'
    if focusKeyboardHere == name then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x77FFFF3F)
      -- r.ImGui_SetKeyboardFocusHere(ctx) -- we could reactivate the input field, but it's pretty good as-is
    end

    local rt, nstr = r.ImGui_InputText(ctx, genItemID(name), str, r.ImGui_InputTextFlags_CharsNoBlank()
                                                                + r.ImGui_InputTextFlags_CharsDecimal()
                                                                + r.ImGui_InputTextFlags_AutoSelectAll())
    if rt and kbdEntryIsCompleted() then
      if processString(name, nstr) then
        if timeval then recalcEventTimes = true else canProcess = true end
      end
      changedParameter = name
    end

    if focusKeyboardHere == name then
      r.ImGui_PopStyleColor(ctx)
    end

    currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
    currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
    r.ImGui_PopFont(ctx)
    registerItem(name, timeval)
    generateLabel(label)
    generateRangeLabel(name)
    r.ImGui_EndGroup(ctx)

    if r.ImGui_IsItemActive(ctx) then activeFieldName = name focusKeyboardHere = name end
  end

  local function generateUnitsLabel(name)

    local ix, iy = currentRect.left, currentRect.bottom
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFBF)
    local text =  '(bars.beats.'..(wantsBBU and 'percent' or 'ticks')..')'
    local tw, th = r.ImGui_CalcTextSize(ctx, text)
    local fp = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()) / 2
    local minx = ix
    local miny = iy + 3
    r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(ctx), minx - fp, miny - fp, minx + tw + fp + 2, miny + th + fp + 2, 0x333355BF)
    minx = minx - vx
    miny = miny - vy
    r.ImGui_SetCursorPos(ctx, minx + 1, miny + 2)
    r.ImGui_Text(ctx, text)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopFont(ctx)
  end

  local function timeStringToTime(timestr, ispos)
    local a = 1
    local dots = {}
    repeat
      a = timestr:find('%.', a)
      if a then
        table.insert(dots, a)
        a = a + 1
      end
    until not a

    local nums = {}
    if #dots ~= 0 then
        local str = timestr:sub(1, dots[1] - 1)
        table.insert(nums, str)
        for k, v in ipairs(dots) do
            str = timestr:sub(v + 1, k ~= #dots and dots[k + 1] - 1 or nil)
            table.insert(nums, str)
        end
    end

    if #nums == 0 then table.insert(nums, timestr) end

    local measures = (not nums[1] or nums[1] == '') and 0 or tonumber(nums[1])
    measures = measures and math.floor(measures) or 0
    local beats = (not nums[2] or nums[2] == '') and (ispos and 1 or 0) or tonumber(nums[2])
    beats = beats and math.floor(beats) or 0

    local ticks
    if wantsBBU then
      local units = (not nums[3] or nums[3] == '') and 0 or tonumber(nums[3])
      ticks = math.floor((units * 0.01) * PPQ)
    else
      ticks = (not nums[3] or nums[3] == '') and 0 or tonumber(nums[3])
      ticks = ticks and math.floor(ticks) or 0
     end

    if ispos then
      beats = beats - 1
      if beats < 0 then beats = 0 end
    end

    return measures, beats, ticks
  end

  local function parseTimeString(name, str)
    local ppqpos = nil
    local measures, beats, ticks = timeStringToTime(str, name == 'selposticks')
    if measures and beats and ticks then
      if name == 'selposticks' then
        ppqpos = BBTToPPQ(measures, beats, ticks)
      elseif name == 'seldurticks' then
        ppqpos = BBTToPPQ(measures, beats, ticks, union.selposticks)
      else return nil
      end
    end
    return math.floor(ppqpos)
  end

  local function processTimeString(name, str)
    local char = str:byte(1)
    local ppqpos = nil

    if char == OP_SCL then str = '0'..str end

    if char == OP_ADD or char == OP_SUB or char == OP_MUL or char == OP_DIV then
      if char == OP_ADD or char == OP_SUB then
        local measures, beats, ticks = timeStringToTime(str:sub(2), false)
        if measures and beats and ticks then
          local opand = BBTToPPQ(measures, beats, ticks, union.selposticks)
          _, ppqpos = doPerformOperation(nil, union[name], char, opand)
        end
      end
      if not ppqpos then
        _, ppqpos = doPerformOperation(nil, union[name], char, tonumber(str:sub(2)))
      end
    else
      ppqpos = parseTimeString(name, str)
    end
    if ppqpos then
      userValues[name] = { operation = OP_ABS, opval = ppqpos }
      return true
    end
    return false
  end

  local function makeTimeInput(name, label, more, wid)
    r.ImGui_SameLine(ctx)
    r.ImGui_BeginGroup(ctx)
    r.ImGui_SetNextItemWidth(ctx, wid and (wid * canvasScale) or (DEFAULT_ITEM_WIDTH * canvasScale))
    r.ImGui_SetCursorPosX(ctx, (currentRect.right - vx) + (2 * canvasScale) + (more and (4 * canvasScale) or 0))

    r.ImGui_PushFont(ctx, fontInfo.large)

    local beatsOffset = name == 'seldurticks' and 0 or 1
    local val = userValues[name].opval

    local str = '-'

    if val ~= INVALID then
      local measures, beats, ticks
      if name == 'seldurticks' then
        measures, beats, ticks = ppqToLength(userValues.selposticks.opval, userValues.seldurticks.opval)
      else
        measures, beats, _, ticks = ppqToTime(userValues[name].opval)
      end
      if wantsBBU then
        str = measures..'.'..(beats + beatsOffset)..'.'..string.format('%.3f', (ticks / PPQ)):sub(3, -2)
      else
        str = measures..'.'..(beats + beatsOffset)..'.'..ticks
      end
    end

    if focusKeyboardHere == name then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x77FFFF3F)
    end

    local rt, nstr = r.ImGui_InputText(ctx, genItemID(name), str, r.ImGui_InputTextFlags_CharsNoBlank()
                                                                + r.ImGui_InputTextFlags_CharsDecimal()
                                                                + r.ImGui_InputTextFlags_AutoSelectAll())
    if rt and kbdEntryIsCompleted() then
      if processTimeString(name, nstr) then
        recalcSelectionTimes = true
        changedParameter = name
      end
    end

    if focusKeyboardHere == name then
      r.ImGui_PopStyleColor(ctx)
    end

    currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
    currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
    r.ImGui_PopFont(ctx)
    registerItem(name, false, true)
    generateLabel(label)
    generateUnitsLabel()
    -- generateRangeLabel(name) -- no range support
    r.ImGui_EndGroup(ctx)

    if r.ImGui_IsItemActive(ctx) then activeFieldName = name focusKeyboardHere = name end
  end

  ---------------------------------------------------------------------------
  ----------------------------- PROCESSING FUNS -----------------------------

  local cachedSelPosTicks = nil
  local cachedSelDurTicks = nil

  local function performTimeSelectionOperation(name, e)
    local rv = true
    if changedParameter == 'seldurticks' then
      local newdur = cachedSelDurTicks
      if not newdur then
        local event = { seldurticks = union.seldurticks }
        rv, newdur = performOperation('seldurticks', event)
        if rv and newdur < 1 then newdur = 1 end
        cachedSelDurTicks = newdur
      end
      if rv then
        local inlo, inhi = union.selposticks, union.selendticks
        local outlo, outhi = union.selposticks, union.selposticks + newdur
        local oldppq = name == 'endppqpos' and e.endppqpos or e.ppqpos
        local newppq = math.floor(((oldppq - inlo) / (inhi - inlo)) * (outhi - outlo) + outlo)
        return true, newppq
      end
    elseif changedParameter == 'selposticks' then
      local newpos = cachedSelPosTicks
      if not newpos then
        local event = { selposticks = union.selposticks }
        rv, newpos = performOperation('selposticks', event)
        cachedSelPosTicks = newpos
      end
      if rv then
        local oldppq = name == 'endppqpos' and e.endppqpos or e.ppqpos
        local newppq = oldppq + (newpos - union.selposticks)
        return true, newppq
      end
    end
    return false, INVALID
  end

  function doPerformOperation(name, baseval, op, opval, opval2)
    local plusone = 0
    if (op == OP_MUL or op == OP_DIV) and (name == 'chan' or name == 'beats') then
      plusone = 1
    end
    if op == OP_ABS then
      if opval ~= INVALID then return true, opval
      else return true, baseval end
    elseif op == OP_ADD then
      return true, baseval + opval
    elseif op == OP_SUB then
      return true, baseval - opval
    elseif op == OP_MUL then
      return true, ((baseval + plusone) * opval) - plusone
    elseif op == OP_DIV then
      return true, ((baseval + plusone) / opval) - plusone
    elseif op == OP_SCL and name and opval2 then
      local inlo, inhi = getCurrentRange(name)
      local outlo, outhi = opval, opval2
      local inrange = inhi - inlo
      if inrange ~= 0 then
        local valnorm = (baseval - inlo) / (inhi - inlo)
        local valscaled = (valnorm * (opval2 - opval)) + opval
        return true, valscaled
      else return false, INVALID
      end
    end
    return false, INVALID
  end

  function performOperation(name, e)
    if name == 'ppqpos' or name == 'endppqpos' then return performTimeSelectionOperation(name, e) end

    local op = userValues[name]
    if op then
      return doPerformOperation(name, e[name], op.operation, op.opval, op.opval2)
    end
    return false, INVALID
  end

  local function getEventValue(name, e, vals)
    local rv, val = performOperation(name, e)
    if rv then
      if name == 'chan' then val = val < 0 and 0 or val > 15 and 15 or val
      elseif name == 'measures' or name == 'beats' or name == 'ticks' then val = val
      elseif name == 'vel' then val = val < 1 and 1 or val > 127 and 127 or val
      elseif name == 'pitch' or name == 'ccnum' then val = val < 0 and 0 or val > 127 and 127 or val
      elseif name == 'ccval' then
        if e.chanmsg == 0xE0 then val = val < -(1<<13) and -(1<<13) or val > ((1<<13) - 1) and ((1<<13) - 1) or val
        else val = val < 0 and 0 or val > 127 and 127 or val
        end
      elseif name == 'ppqpos' or name == 'endppqpos' then val = val
      else val = val < 0 and 0 or val
      end

      if name == 'pitch' and changedParameter == 'pitch' then
        local dir = val < e.pitch and -1 or val > e.pitch and 1 or 0
        if pitchDirection == 0 and val ~= 0 then pitchDirection = dir end
      end

      return math.floor(val)
    end
    return INVALID
  end

  local function updateValuesForEvent(e)
    if e.chanmsg ~= popupFilter then return {} end

    e.measures = getEventValue('measures', e)
    e.beats = getEventValue('beats', e)
    e.ticks = getEventValue('ticks', e)
    e.chan = getEventValue('chan', e)
    if popupFilter == NOTE_FILTER then
      e.pitch = getEventValue('pitch', e)
      e.vel = getEventValue('vel', e)
      e.notedur = getEventValue('notedur', e)
    elseif popupFilter ~= 0 then
      e.ccnum = getEventValue('ccnum', e)
      e.ccval = getEventValue('ccval', e)
      if e.chanmsg == 0xA0 then
        e.msg2 = e.ccval
        e.msg3 = 0
      elseif e.chanmsg == 0xE0 then
        e.ccval = e.ccval + (1<<13)
        if e.ccval > ((1<<14) - 1) then e.ccval = ((1<<14) - 1) end
        e.msg2 = e.ccval & 0x7F
        e.msg3 = (e.ccval >> 7) & 0x7F
      else
        e.msg2 = e.ccnum
        e.msg3 = e.ccval
      end
    end
    if recalcEventTimes then
      e.ppqpos = BBTToPPQ(e.measures, e.beats, e.ticks)
      if popupFilter == NOTE_FILTER then
        e.endppqpos = e.ppqpos + e.notedur
      end
    end
    if recalcSelectionTimes then
      e.ppqpos = getEventValue('ppqpos', e)
      if popupFilter == NOTE_FILTER then
        e.endppqpos = getEventValue('endppqpos', e)
        e.notedur = e.endppqpos - e.ppqpos
      end
    end
  end

  -- manual overlap protection for prioritizing selected items
  local function correctOverlapForEvent(testEvent, selectedEvent)
    local modified = 0
    if testEvent.type == NOTE_TYPE
      and testEvent.chan == selectedEvent.chan
      and testEvent.pitch == selectedEvent.pitch
    then
      local saveppq, saveendppq = selectedEvent.ppqpos, selectedEvent.endppqpos
      if testEvent.ppqpos > selectedEvent.ppqpos and testEvent.ppqpos < selectedEvent.endppqpos then
        --selectedEvent.endppqpos = testEvent.ppqpos
        testEvent.ppqpos = selectedEvent.endppqpos -- again, the opposite
        table.insert(touchedEvents, testEvent)
        modified = modified + 1
      end
      if testEvent.endppqpos > selectedEvent.ppqpos and testEvent.endppqpos < selectedEvent.endppqpos then
        --selectedEvent.ppqpos = testEvent.endppqpos
        testEvent.endppqpos = selectedEvent.ppqpos -- just the opposite
        table.insert(touchedEvents, testEvent)
        modified = modified + 1
      end
      if modified == 2 then -- it's in the middle, don't change it
        modified = 0
        --selectedEvent.ppqpos, selectedEvent.endppqpos = saveppq, saveendppq
      end
    end
    return modified ~= 0
  end

  local function correctOverlaps(event)
    -- find input event
    local idx
    for i = 1, #allEvents do
      if allEvents[i].type == event.type and allEvents[i].idx == event.idx then
        idx = i
        break
      end
    end

    if not idx then return end

    -- look backward
    for i = idx - 1, 1, -1 do
      if correctOverlapForEvent(allEvents[i], event) then break end
    end
    -- look forward
    for i = idx + 1, #allEvents do
      if correctOverlapForEvent(allEvents[i], event) then break end
    end
  end

  -- item extents management, currently disabled
  local function getItemExtents(item)
    local item_pos = r.GetMediaItemInfo_Value(item, 'D_POSITION')
    local item_len = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local extents = {}
    extents.item = item
    extents.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, item_pos)
    extents.ppqpos_cache = extents.ppqpos
    extents.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, item_pos + item_len)
    extents.endppqpos_cache = extents.endppqpos
    extents.ppqpos_changed = false
    extents.endppqpos_changed = false
    return extents
  end

  local function correctItemExtents(extents, v)
    if v.ppqpos < extents.ppqpos then
      extents.ppqpos = v.ppqpos
      extents.ppqpos_changed = true
    end
    if v.type == NOTE_TYPE and v.endppqpos > extents.endppqpos then
      extents.endppqpos = v.endppqpos
      extents.endppqpos_changed = true
    end
  end

  local function updateItemExtents(extents)
    if extents.ppqpos_changed or extents.endppqpos_changed then
      -- to nearest beat
      local extentStart = r.MIDI_GetProjQNFromPPQPos(take, extents.ppqpos)
      if extents.ppqpos_changed then
        extentStart = math.floor(extentStart) -- extent to previous beat
        extents.ppqpos = r.MIDI_GetPPQPosFromProjQN(take, extentStart) -- write it back, we need it below
      end
      local extentEnd = r.MIDI_GetProjQNFromPPQPos(take, extents.endppqpos)
      if extents.endppqpos_changed then
        extentEnd = math.floor(extentEnd + 1) -- extend to next beat
        extents.endppqpos = r.MIDI_GetPPQPosFromProjQN(take, extentEnd) -- write it back, we need it below
      end
      r.MIDI_SetItemExtents(extents.item, extentStart, extentEnd)
    end
  end

  ---------------------------------------------------------------------------
  ----------------------------------- ENDFN ---------------------------------

  ---------------------------------------------------------------------------
  ---------------------------------------------------------------------------

  ---------------------------------------------------------------------------
  ----------------------------------- SETUP ---------------------------------

  PPQ = getPPQ()

  titleBarText = DEFAULT_TITLEBAR_TEXT..' (PPQ='..PPQ..')' --..' DPI=('..r.ImGui_GetWindowDpiScale(ctx)..')'

  ---------------------------------------------------------------------------
  ------------------------------ ITERATE EVENTS -----------------------------

  s.Reset() -- reset this each cycle
  local _, notecnt, cccnt = s.MIDI_CountEvts(take)
  for noteidx = 0, notecnt - 1 do
    local e = { type = NOTE_TYPE, idx = noteidx }
    _, e.selected, e.muted, e.ppqpos, e.endppqpos, e.chan, e.pitch, e.vel = s.MIDI_GetNote(take, noteidx)
    e.notedur = e.endppqpos - e.ppqpos
    e.chanmsg = 0x90
    if e.selected then
      calcMIDITime(e)
      hasNotes = true
      table.insert(selectedEvents, e)
      table.insert(newNotes, e.idx)
    end
    table.insert(allEvents, e)
  end

  for ccidx = 0, cccnt - 1 do
    local e = { type = CC_TYPE, idx = ccidx }
    _, e.selected, e.muted, e.ppqpos, e.chanmsg, e.chan, e.msg2, e.msg3 = s.MIDI_GetCC(take, ccidx)

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
    if e.selected then
      calcMIDITime(e)
      hasCCs = true
      table.insert(selectedEvents, e)
    end
    table.insert(allEvents, e)
  end

  local resetFilter = false
  if #newNotes ~= #selectedNotes then resetFilter = true
  else
    for _, v in ipairs(newNotes) do
      local foundit = false
      for _, n in ipairs(selectedNotes) do
        if n == v then
          foundit = true
          break
        end
      end
      if not foundit then
        resetFilter = true
        break
      end
    end
  end
  if resetFilter then popupFilter = 0x90 end
  selectedNotes = newNotes

  if #selectedEvents == 0 or not (hasNotes or hasCCs) then return end

  ---------------------------------------------------------------------------
  ------------------------------ SETUP FILTER -------------------------------

  for _, type in pairs(ccTypes) do
    type.exists = false
  end

  for _, v in ipairs(selectedEvents) do
    if v.chanmsg and v.chanmsg ~= 0 then ccTypes[v.chanmsg].exists = true end
  end
  if popupFilter ~= 0 and not ccTypes[popupFilter].exists then popupFilter = 0 end
  if popupFilter == 0 then
    for _, v in ipairs(selectedEvents) do
      if v.chanmsg and v.chanmsg ~= 0 then
        popupFilter = v.chanmsg
        break
      end
    end
  end
  popupLabel = ccTypes[popupFilter].label
  if popupFilter == 0xD0 or popupFilter == 0xE0 then cc2byte = true end

  ---------------------------------------------------------------------------
  -------------------------------- CALC UNION -------------------------------

  -- this requires the popupFilter, just above

  union.selposticks = -INVALID
  union.selendticks = INVALID
  for _, v in ipairs(selectedEvents) do
    commonUnionEntries(v)
    if v.type == NOTE_TYPE then
      unionEntry('notedur', v.notedur, v)
      unionEntry('pitch', v.pitch, v)
      unionEntry('vel', v.vel, v)
    elseif v.type == CC_TYPE then
      unionEntry('chanmsg', v.chanmsg, v)
      unionEntry('ccnum', v.ccnum, v)
      unionEntry('ccval', v.ccval, v)
    end
  end
  if union.selposticks == -INVALID then union.selposticks = INVALID end
  union.seldurticks = union.selposticks == INVALID and INVALID or union.selendticks - union.selposticks

  ---------------------------------------------------------------------------
  -------------------------------- POPUP MENU -------------------------------

  r.ImGui_NewLine(ctx)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
  r.ImGui_Button(ctx, popupLabel)

  -- cache the positions to generate next box position
  currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
  currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
  currentRect.right = currentRect.right + 20 * canvasScale -- add some spacing after the button

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'context menu')
  end

  local bail = false
  if r.ImGui_BeginPopup(ctx, 'context menu') then
    r.ImGui_PushFont(ctx, fontInfo.small)
    for _, type in pairs(ccTypes) do
      if type.exists then
        local rv, selected = r.ImGui_Selectable(ctx, type.label)
        if rv and selected then
          popupFilter = type.val
          bail = true
        end
        r.ImGui_Spacing(ctx)
      end
    end
    r.ImGui_Separator(ctx)
    local rv, v = r.ImGui_Checkbox(ctx, 'Overlap Correction Favors Selected', overlapFavorsSelected)
    if rv then
      r.SetExtState(scriptID, 'overlapFavorsSelected', v and '1' or '0', true)
      overlapFavorsSelected = v
      r.ImGui_CloseCurrentPopup(ctx)
    end
    rv, v = r.ImGui_Checkbox(ctx, 'Use Bars.Beats.Percent Format ', wantsBBU)
    if rv then
      r.SetExtState(scriptID, 'bbu', v and '1' or '0', true)
      wantsBBU = v
      r.ImGui_CloseCurrentPopup(ctx)
    end
    rv, v = r.ImGui_Checkbox(ctx, 'Reverse Scroll Direction', reverseScroll)
    if rv then
      r.SetExtState(scriptID, 'reverseScroll', v and '1' or '0', true)
      reverseScroll = v
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_SetNextItemWidth(ctx, (DEFAULT_ITEM_WIDTH / 2) * canvasScale)
    rv, v = r.ImGui_InputText(ctx, 'Base Font Size', FONTSIZE_LARGE, r.ImGui_InputTextFlags_EnterReturnsTrue()
                                                                   + r.ImGui_InputTextFlags_CharsDecimal())
    if rv then
      v = processBaseFontUpdate(tonumber(v))
      r.SetExtState(scriptID, 'baseFont', tostring(v), true)
      r.ImGui_CloseCurrentPopup(ctx)
    end

    r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end

  r.ImGui_PopStyleColor(ctx)

  if bail then return end

  ---------------------------------------------------------------------------
  -------------------------------- USER VALUES ------------------------------

  local function makeValueEntry(name)
    return { operation = OP_ABS, opval = (union[name] and union[name] ~= INVALID) and math.floor(union[name]) or INVALID }
  end

  local function commonValueEntries()
    for _, v in ipairs(commonEntries) do
      userValues[v] = makeValueEntry(v)
    end
    userValues.selposticks = { operation = OP_ABS, opval = union.selposticks }
    userValues.seldurticks = { operation = OP_ABS, opval = union.seldurticks }
  end

  commonValueEntries()
  if popupFilter == NOTE_FILTER then
    userValues.pitch = makeValueEntry('pitch')
    userValues.vel = makeValueEntry('vel')
    userValues.notedur = makeValueEntry('notedur')
  elseif popupFilter ~= 0 then
    userValues.ccnum = makeValueEntry('ccnum')
    userValues.ccval = makeValueEntry('ccval')
    userValues.chanmsg = makeValueEntry('chanmsg')
  end

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE GEN ------------------------------

  -- requires userValues, above

  canProcess = false

  makeTextInput('measures', 'Bars')
  makeTextInput('beats', 'Beats')
  makeTextInput('ticks', wantsBBU and 'Percent' or 'Ticks')
  makeTextInput('chan', 'Chan', true)

  if popupFilter == NOTE_FILTER then
    makeTextInput('pitch', 'Pitch')
    makeTextInput('vel', 'Velocity')
    makeTextInput('notedur', 'Length '..(wantsBBU and '(beat %)' or '(ticks)'), true, DEFAULT_ITEM_WIDTH * 2)
  elseif popupFilter ~= 0 then
    if not cc2byte then makeTextInput('ccnum', 'Ctrlr') end
    makeTextInput('ccval', 'Value')
  end

  makeTimeInput('selposticks', 'Sel. Position', true, DEFAULT_ITEM_WIDTH * 2)
  makeTimeInput('seldurticks', 'Sel. Duration', true, DEFAULT_ITEM_WIDTH * 2)

  ---------------------------------------------------------------------------
  ------------------------------- MOD KEYS ------------------------------

  -- note that the mod is only captured if the window is explicitly focused
  -- with a click. not sure how to fix this yet. TODO
  -- local mods = r.ImGui_GetKeyMods(ctx)
  -- local shiftdown = mods & r.ImGui_Mod_Shift() ~= 0

  -- current 'fix' is using the JS extension
  local mods = r.JS_Mouse_GetState(24) -- shift key
  local shiftdown = mods & 8 ~= 0
  local optdown = mods & 16 ~= 0
  local PPQCent = math.floor(PPQ * 0.01) -- for BBU conversion

  ---------------------------------------------------------------------------
  ------------------------------- ARROW KEYS ------------------------------

  -- escape key kills our arrow key focus
  if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then focusKeyboardHere = nil end

  local arrowAdjust = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_UpArrow()) and 1
                   or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_DownArrow()) and -1
                   or 0
  if arrowAdjust ~= 0 and (activeFieldName or focusKeyboardHere) then
    for _, hitTest in ipairs(itemBounds) do
      if hitTest.name == focusKeyboardHere
        or hitTest.name == activeFieldName
      then
        if hitTest.recalcSelection and optdown then
          arrowAdjust = arrowAdjust * PPQ -- beats instead of ticks
        elseif needsBBUConversion(hitTest.name) then
          arrowAdjust = arrowAdjust * PPQCent
        end

        userValues[hitTest.name].operation = OP_ADD
        userValues[hitTest.name].opval = arrowAdjust
        changedParameter = hitTest.name
        if hitTest.recalcEvent then recalcEventTimes = true
        elseif hitTest.recalcSelection then recalcSelectionTimes = true
        else canProcess = true end
        if hitTest.name == activeFieldName then
          rewriteIDForAFrame = hitTest.name
          focusKeyboardHere = hitTest.name
        end
        break
      end
    end
  end

  ---------------------------------------------------------------------------
  ------------------------------- MOUSE SCROLL ------------------------------

  local vertMouseWheel = r.ImGui_GetMouseWheel(ctx)
  local mScrollAdjust = vertMouseWheel > 0 and -1 or vertMouseWheel < 0 and 1 or 0
  if reverseScroll then mScrollAdjust = mScrollAdjust * -1 end

  local posx, posy = r.ImGui_GetMousePos(ctx)
  posx = posx - vx
  posy = posy - vy
  if mScrollAdjust ~= 0 then
    if shiftdown then
      mScrollAdjust = mScrollAdjust * 3
    end

    for _, hitTest in ipairs(itemBounds) do
      if userValues[hitTest.name].operation == OP_ABS -- and userValues[hitTest.name].opval ~= INVALID
        and posy > hitTest.hity[1] and posy < hitTest.hity[2]
        and posx > hitTest.hitx[1] and posx < hitTest.hitx[2]
      then
        if hitTest.name == activeFieldName then
          rewriteIDForAFrame = activeFieldName
        end

        if hitTest.name == 'ticks' and shiftdown then
          mScrollAdjust = mScrollAdjust > 1 and 5 or -5
        elseif hitTest.name == 'notedur' and shiftdown then
          mScrollAdjust = mScrollAdjust > 1 and 10 or -10
        end

        if hitTest.recalcSelection and optdown then
          mScrollAdjust = mScrollAdjust * PPQ -- beats instead of ticks
        elseif needsBBUConversion(hitTest.name) then
          mScrollAdjust = mScrollAdjust * PPQCent
        end

        userValues[hitTest.name].operation = OP_ADD
        userValues[hitTest.name].opval = mScrollAdjust
        changedParameter = hitTest.name
        if hitTest.recalcEvent then recalcEventTimes = true
        elseif hitTest.recalcSelection then recalcSelectionTimes = true
        else canProcess = true end
        break
      end
    end
  end

  if recalcEventTimes or recalcSelectionTimes then canProcess = true end

  ---------------------------------------------------------------------------
  ------------------------------- PROCESSING --------------------------------

  if canProcess then
    r.Undo_BeginBlock2(0)

    local _, _, sectionID = r.get_action_context()
    local autoOverlap = r.GetToggleCommandStateEx(sectionID, 40681)
    if autoOverlap == 1 then
      -- r.SetToggleCommandState(sectionID, 40681, 0) -- this doesn't work
      r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40681) -- but this does
    end
    local item = r.GetMediaItemTake_Item(take)
    local item_extents = getItemExtents(item)

    s.MIDI_OpenSetTransaction(take) -- disables sort

    for _, v in ipairs(selectedEvents) do
      if popupFilter == v.chanmsg then
        updateValuesForEvent(v) -- first update the values
        correctItemExtents(item_extents, v)
      end
    end

    updateItemExtents(item_extents)

    -- we shifted the extents backward, we'll need to offset any values by that amount
    local extents_offset = 0
    if item_extents.ppqpos_cache > item_extents.ppqpos then
      extents_offset = item_extents.ppqpos_cache - item_extents.ppqpos
    end

    if overlapFavorsSelected then
      for _, v in ipairs(selectedEvents) do
        correctOverlaps(v) -- then perform overlap correction etc.
      end
      if #touchedEvents > 0 then
        for _, t in ipairs(touchedEvents) do
          t.touched = true
          table.insert(selectedEvents, t)
        end
      end
    end

    local recalced = recalcEventTimes or recalcSelectionTimes
    for _, v in ipairs(selectedEvents) do
      if popupFilter == v.chanmsg then
        if popupFilter == NOTE_FILTER then
          local ppqpos = recalced and v.ppqpos or nil
          local endppqpos = recalced and v.endppqpos or nil
          if ppqpos and extents_offset ~= 0 then
            ppqpos = ppqpos + extents_offset
            endppqpos = endppqpos + extents_offset
          end
          local chan = changedParameter == 'chan' and v.chan or nil
          local pitch = changedParameter == 'pitch' and v.pitch or nil
          local vel = changedParameter == 'vel' and v.vel or nil
          if v.touched then
            s.MIDI_SetNote(take, v.idx, nil, nil, v.ppqpos, v.endppqpos, nil, nil, nil)
          else
            s.MIDI_SetNote(take, v.idx, nil, nil, ppqpos, endppqpos, chan, pitch, vel)
          end
        elseif popupFilter ~= 0 then
          local ppqpos = recalced and v.ppqpos or nil
          if ppqpos and extents_offset ~= 0 then
            ppqpos = ppqpos + extents_offset
          end
          local chan = changedParameter == 'chan' and v.chan or nil
          local msg2 = (changedParameter == 'ccnum' or changedParameter == 'ccval') and v.msg2 or nil
          local msg3 = (changedParameter == 'ccnum' or changedParameter == 'ccval') and v.msg3 or nil
          s.MIDI_SetCC(take, v.idx, nil, nil, ppqpos, nil, chan, msg2, msg3)
        end
      end
    end

    s.MIDI_CommitSetTransaction(take) -- sorts

    --r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40659) -- correct overlaps (always run)

    r.MarkTrackItemsDirty(r.GetMediaItemTake_Track(take), item)

    if autoOverlap == 1 then
      -- r.SetToggleCommandState(sectionID, 40681, 1) -- restore state if disabled (doesn't work)
      r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40681) -- but this does
    end

    r.Undo_EndBlock2(0, 'Edit CC(s)', -1)
  end
end

-----------------------------------------------------------------------------
--------------------------------- CLEANUP -----------------------------------

local function doClose()
  r.ImGui_Detach(ctx, fontInfo.large)
  r.ImGui_Detach(ctx, fontInfo.small)
  r.ImGui_DestroyContext(ctx)
  ctx = nil
end

local function onCrash(err)
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
end

-----------------------------------------------------------------------------
----------------------------- WSIZE/FONTS JUNK ------------------------------

local function updateWindowPosition()
  local curWindowWidth, curWindowHeight = r.ImGui_GetWindowSize(ctx)
  local curWindowLeft, curWindowTop = r.ImGui_GetWindowPos(ctx)

  if not windowInfo.wantsResize
    and (windowInfo.wantsResizeUpdate
      or curWindowWidth ~= windowInfo.width
      or curWindowHeight ~= windowInfo.height
      or curWindowLeft ~= windowInfo.left
      or curWindowTop ~= windowInfo.top)
  then
    r.SetExtState(scriptID, 'windowRect', math.floor(curWindowLeft)..','..math.floor(curWindowTop)..','..math.floor(curWindowWidth)..','..math.floor(curWindowHeight), true)
    windowInfo.left, windowInfo.top, windowInfo.width, windowInfo.height = curWindowLeft, curWindowTop, curWindowWidth, curWindowHeight
    windowInfo.wantsResizeUpdate = false
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

  local newFontSize = math.floor(fontInfo[name..'DefaultSize'] * canvasScale)
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
  r.ImGui_SetNextWindowSize(ctx, windowInfo.width, windowInfo.height, windowSizeFlag)
  r.ImGui_SetNextWindowPos(ctx, windowInfo.left, windowInfo.top, windowSizeFlag)
  if windowInfo.wantsResize then
    windowInfo.wantsResize = false
    windowInfo.wantsResizeUpdate = true
  end

  r.ImGui_SetNextWindowBgAlpha(ctx, 1.0)
  -- r.ImGui_SetNextWindowDockID(ctx, -1)--, r.ImGui_Cond_FirstUseEver()) -- TODO docking

  r.ImGui_PushFont(ctx, fontInfo.large)
  local winheight = r.ImGui_GetFrameHeightWithSpacing(ctx) * 4
  r.ImGui_SetNextWindowSizeConstraints(ctx, windowInfo.defaultWidth, winheight, windowInfo.defaultWidth * 3, winheight)
  r.ImGui_PopFont(ctx)

  r.ImGui_PushFont(ctx, fontInfo.small)
  local visible, open = r.ImGui_Begin(ctx, titleBarText, true,
                                        r.ImGui_WindowFlags_TopMost()
                                      + r.ImGui_WindowFlags_NoScrollWithMouse()
                                      + r.ImGui_WindowFlags_NoScrollbar()
                                      + r.ImGui_WindowFlags_NoSavedSettings())
  r.ImGui_PopFont(ctx)

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

local isClosing = false

local function loop()

  -- -- I want to only show the window if a MIDI editor is frontmost, this doesn't work yet
  -- if not r.ImGui_IsWindowFocused(ctx) then
  --   local hwnd = r.MIDIEditor_GetActive()
  --   if not hwnd or r.JS_Window_GetFocus() ~= hwnd then
  --     post(hwnd and 'no match' or 'no hwnd')
  --     r.ImGui_IsWindowAppearing(ctx) -- keep the ctx alive
  --     r.defer(function() xpcall(loop, onCrash) end)
  --     return
  --   end
  -- end

  --local wscale = windowWidth / windowInfo.defaultWidth
  --local hscale =  windowHeight / windowInfo.defaultHeight

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

    -- ww, wh = r.ImGui_Viewport_GetSize(r.ImGui_GetWindowViewport(ctx)) -- TODO docking
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
