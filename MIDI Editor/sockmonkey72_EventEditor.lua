-- @description MIDI Event Editor
-- @version 1.4
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
--   - MIDIUtils update (redux)
-- @provides
--   EventEditor/MIDIUtils.lua https://raw.githubusercontent.com/jeremybernstein/ReaScripts/main/MIDI/MIDIUtils.lua
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_EventEditor.lua

-----------------------------------------------------------------------------
----------------------------------- TODO ------------------------------------

-- TODO
-- - CLEANUP
-- - [ ] transform menu: invert, retrograde (can use selection for center point), quantize?
-- - [ ] help text describing keyboard shortcuts

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

local r = reaper

-- package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'EventEditor/?.lua'
local mu = require 'MIDIUtils'
mu.ENFORCE_ARGS = false -- turn off type checking
mu.CORRECT_OVERLAPS = false -- manual correction

local function fileExists(name)
  local f = io.open(name,'r')
  if f ~= nil then io.close(f) return true else return false end
end

local canStart = true

local imGuiPath = r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua'
if not fileExists(imGuiPath) then
  mu.post('MIDI Event Editor requires \'ReaImGui\' 0.8+ (install from ReaPack)\n')
  canStart = false
end

if not r.APIExists('JS_Mouse_GetState') then
  mu.post('MIDI Event Editor requires the \'js_ReaScriptAPI\' extension (install from ReaPack)\n')
  canStart = false
end

if not mu.CheckDependencies('MIDI Event Editor') then
  canStart = false
end

if not canStart then return end

dofile(r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8')

local scriptID = 'sockmonkey72_EventEditor'

local ctx = r.ImGui_CreateContext(scriptID)
r.ImGui_SetConfigVar(ctx, r.ImGui_ConfigVar_DockingWithShift(), 1) -- TODO docking

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local FONTSIZE_LARGE = 13
local FONTSIZE_SMALL = 11
local DEFAULT_WIDTH = 68 * FONTSIZE_LARGE
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
local processTimeout

local OVERLAP_MANUAL = 0
local OVERLAP_AUTO = 1
local OVERLAP_TIMEOUT = 2

local wantsOverlapCorrection = OVERLAP_AUTO
local overlapCorrectionTimeout = 1000 -- (ms)
local overlapFavorsSelected = false
local disabledAutoOverlap = false
local wantsBBU = false
local reverseScroll = false
local dockID = 0

local OP_ABS = 0
local OP_ADD = string.byte('+', 1)
local OP_SUB = string.byte('-', 1)
local OP_MUL = string.byte('*', 1)
local OP_DIV = string.byte('/', 1)
local OP_SCL = string.byte('.', 1)

local dataTypes = {}
dataTypes[0x90] = { val = 0x90, label = 'Note', exists = false }
dataTypes[0xA0] = { val = 0xA0, label = 'PolyAT', exists = false }
dataTypes[0xB0] = { val = 0xB0, label = 'CC', exists = false }
dataTypes[0xC0] = { val = 0xC0, label = 'PrgCh', exists = false }
dataTypes[0xD0] = { val = 0xD0, label = 'ChanAT', exists = false }
dataTypes[0xE0] = { val = 0xE0, label = 'Pitch', exists = false }

dataTypes[-1] = { val = -1, label = 'Sysex', exists = false }
dataTypes[1] = { val = 1, label = 'Text', exists = false }
dataTypes[15] = { val = 15, label = 'Notation', exists = false }

local textTypes = {}
textTypes[1] = { val = 1, label = 'Text', exists = false }
textTypes[2] = { val = 2, label = 'Copyright', exists = false }
textTypes[3] = { val = 3, label = 'TrckName', exists = false }
textTypes[4] = { val = 4, label = 'InstName', exists = false }
textTypes[5] = { val = 5, label = 'Lyrics', exists = false }
textTypes[6] = { val = 6, label = 'Marker', exists = false }
textTypes[7] = { val = 7, label = 'CuePoint', exists = false }
textTypes[8] = { val = 8, label = 'PrgName', exists = false }
textTypes[9] = { val = 9, label = 'DevName', exists = false }

local unusedTextTypes = {}
unusedTextTypes[10] = { val = 10, label = 'REAPER10', exists = false }
unusedTextTypes[11] = { val = 11, label = 'REAPER11', exists = false }
unusedTextTypes[12] = { val = 12, label = 'REAPER12', exists = false }
unusedTextTypes[13] = { val = 13, label = 'REAPER13', exists = false }
unusedTextTypes[14] = { val = 14, label = 'REAPER14', exists = false }

local selectedNotes = {} -- interframe cache
local isClosing = false

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

local function handleExtState()
  overlapFavorsSelected = r.GetExtState(scriptID, 'overlapFavorsSelected') == '1'
  wantsBBU = r.GetExtState(scriptID, 'bbu') == '1'
  reverseScroll = r.GetExtState(scriptID, 'reverseScroll') == '1'
  dockID = 0
  if r.HasExtState(scriptID, 'dockID') then
    local str = r.GetExtState(scriptID, 'dockID')
    if str then dockID = tonumber(str) end
  end

  if r.HasExtState(scriptID, 'wantsOverlapCorrection') then
    local wants = r.GetExtState(scriptID, 'wantsOverlapCorrection')
    wantsOverlapCorrection = wants == '1' and OVERLAP_AUTO or wants == '2' and OVERLAP_TIMEOUT or wants == '0' and OVERLAP_MANUAL or OVERLAP_AUTO
  end
  if r.HasExtState(scriptID, 'overlapCorrectionTimeout') then
    local timeout = tonumber(r.GetExtState(scriptID, 'overlapCorrectionTimeout'))
    if timeout then
      timeout = timeout < 100 and 100 or timeout > 5000 and 5000 or timeout
      overlapCorrectionTimeout = math.floor(timeout)
    end
  end
end

local function prepRandomShit()
  -- remove deprecated ExtState entries
  if r.HasExtState(scriptID, 'correctOverlaps') then
    r.DeleteExtState(scriptID, 'correctOverlaps', true)
  end
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
  local NOTE_TYPE = 0
  local CC_TYPE = 1
  local SYXTEXT_TYPE = 2
  local NOTE_FILTER = 0x90
  local changedParameter = nil
  local allEvents = {}
  local selectedEvents = {}
  local newNotes = {}
  local userValues = {}
  local union = {} -- determine a filter and calculate the union of selected values
  local PPQ
  local vx, vy = r.ImGui_GetWindowPos(ctx)
  local activeFieldName
  local pitchDirection = 0
  local touchedEvents = {}
  local handledEscape = false
  local correctOverlapsNow = false

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
    local startPPQ = BBTToPPQ(nil, math.floor(startBeats))

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

  local function chanmsgToType(chanmsg)
    local type = chanmsg
    if type and type >= 1 and type <= #textTypes then type = 1 end
    return type
  end

  local function unionEntry(name, val, entry)
    if chanmsgToType(entry.chanmsg) == popupFilter then
      if not union[name] then union[name] = val
      elseif union[name] ~= val then union[name] = INVALID end
    end
  end

  local function commonUnionEntries(e)
    for _, v in ipairs(commonEntries) do
      unionEntry(v, e[v], e)
    end

    if chanmsgToType(e.chanmsg) == popupFilter then
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

  local function makeStringVal(name, str)
    userValues[name] = { operation = OP_ABS, opval = str }
    return true
  end

  local function makeSysexVal(name, str)
    userValues[name] = { operation = OP_ABS, opval = sysexStringToBytes(str) }
    return true
  end

  local function makeNotationVal(name, str)
    userValues[name] = { operation = OP_ABS, opval = stringToNotationString(str) }
    return true
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

    if name == 'textmsg' then
      if userValues.texttype.opval == -1 then
        return makeSysexVal(name, str)
      elseif userValues.texttype.opval == 15 then
        return makeNotationVal(name, str)
      elseif popupFilter < 0x80 then
        return makeStringVal(name, str)
      end
    end

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
        local type = chanmsgToType(v.chanmsg)
        if type == popupFilter then
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

    local text
    local lo, hi = getCurrentRangeForDisplay(name)
    if lo ~= hi then
      text = '['..lo..'-'..hi..']'
    elseif name == 'pitch' then
      text = '<'..mu.MIDI_NoteNumberToNoteName(lo)..'>'
    end
    if text then
      local ix, iy = currentRect.left, currentRect.bottom
      r.ImGui_PushFont(ctx, fontInfo.small)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFBF)
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
    local nextwid = wid and (wid * canvasScale) or (DEFAULT_ITEM_WIDTH * canvasScale)
    r.ImGui_SetNextItemWidth(ctx, nextwid)
    r.ImGui_SetCursorPosX(ctx, (currentRect.right - vx) + (2 * canvasScale) + (more and (4 * canvasScale) or 0))

    r.ImGui_PushFont(ctx, fontInfo.large)

    local val = userValues[name].opval
    if val ~= INVALID then
      if (name == 'chan' or name == 'beats') then val = val + 1
      elseif needsBBUConversion(name) then val = math.floor((val / PPQ) * 100)
      elseif name == 'texttype' then
        if textTypes[userValues[name].opval] then
          r.ImGui_Button(ctx, textTypes[userValues[name].opval].label, nextwid)

          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

          if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
            r.ImGui_OpenPopup(ctx, 'texttype menu')
            activeFieldName = name
            focusKeyboardHere = name
          end

          if r.ImGui_BeginPopup(ctx, 'texttype menu') then
            if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
              if r.ImGui_IsPopupOpen(ctx, 'texttype menu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
                r.ImGui_CloseCurrentPopup(ctx)
                handledEscape = true
              end
            end
            for i = 1, #textTypes do
              local rv, selected = r.ImGui_Selectable(ctx, textTypes[i].label)
              if rv and selected then
                val = textTypes[i].val
                changedParameter = name
                userValues[name] = { operation = OP_ABS, opval = val }
                canProcess = true
              end
            end
            r.ImGui_EndPopup(ctx)
          end
          currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
          currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
          generateLabel(label)
          registerItem(name, false, false)
          r.ImGui_PopStyleColor(ctx)
        end
        r.ImGui_PopFont(ctx)
        r.ImGui_EndGroup(ctx)
        return
      elseif name == 'textmsg' then
        if popupFilter == -1 then
          val = sysexBytesToString(val)
        elseif popupFilter == 15 then
          val = notationStringToString(val)
        end
      end
    end

    local str = val ~= INVALID and tostring(val) or '-'
    if focusKeyboardHere == name then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x77FFFF3F)
      -- r.ImGui_SetKeyboardFocusHere(ctx) -- we could reactivate the input field, but it's pretty good as-is
    end

    local flags = r.ImGui_InputTextFlags_AutoSelectAll()
    if name == 'textmsg' then
      if popupFilter == -1 then
        flags = flags + 0 --r.ImGui_InputTextFlags_CharsHexadecimal()
      end
    else
      flags = flags + r.ImGui_InputTextFlags_CharsNoBlank() + r.ImGui_InputTextFlags_CharsDecimal()
    end
    local rt, nstr = r.ImGui_InputText(ctx, genItemID(name), str, flags)
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

  function performOperation(name, e, valname)
    if name == 'ppqpos' or name == 'endppqpos' then return performTimeSelectionOperation(name, e) end

    local op = userValues[name]
    if op then
      return doPerformOperation(name, e[valname and valname or name], op.operation, op.opval, op.opval2)
    end
    return false, INVALID
  end

  local function getEventValue(name, e, valname)
    local rv, val = performOperation(name, e, valname)
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
      elseif name == 'texttype' then
        if e.chanmsg == 1 then
          return (val < 1 and 1 or val > #textTypes and #textTypes or val)
        end
        return val
      elseif name == 'textmsg' then return val
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
    if chanmsgToType(e.chanmsg) ~= popupFilter then return {} end

    e.measures = getEventValue('measures', e)
    e.beats = getEventValue('beats', e)
    e.ticks = getEventValue('ticks', e)
    if popupFilter == NOTE_FILTER then
      e.chan = getEventValue('chan', e)
      e.pitch = getEventValue('pitch', e)
      e.vel = getEventValue('vel', e)
      e.notedur = getEventValue('notedur', e)
    elseif popupFilter >= 0x80 then
      e.chan = getEventValue('chan', e)
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
    else
      e.chanmsg = getEventValue('texttype', e, 'chanmsg')
      e.textmsg = getEventValue('textmsg', e)
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
  --handleExtState()

  ---------------------------------------------------------------------------
  ------------------------------ ITERATE EVENTS -----------------------------

  mu.MIDI_InitializeTake(take) -- reset this each cycle
  local _, notecnt, cccnt, syxcnt = mu.MIDI_CountEvts(take)
  local selnotecnt = 0
  local selcccnt = 0
  local selsyxcnt = 0
  local noteidx = mu.MIDI_EnumNotes(take, -1)
  while noteidx ~= -1 do
    local e = { type = NOTE_TYPE, idx = noteidx }
    _, e.selected, e.muted, e.ppqpos, e.endppqpos, e.chan, e.pitch, e.vel = mu.MIDI_GetNote(take, noteidx)
    e.notedur = e.endppqpos - e.ppqpos
    e.chanmsg = 0x90
    if e.selected then
      calcMIDITime(e)
      selnotecnt = selnotecnt + 1
      table.insert(selectedEvents, e)
      table.insert(newNotes, e.idx)
    end
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
    if e.selected then
      calcMIDITime(e)
      selcccnt = selcccnt + 1
      table.insert(selectedEvents, e)
    end
    table.insert(allEvents, e)
    ccidx = mu.MIDI_EnumCC(take, ccidx)
  end

  local syxidx = mu.MIDI_EnumSelTextSysexEvts(take, -1)
  while syxidx ~= -1 do
    local e = { type = SYXTEXT_TYPE, idx = syxidx }
    _, e.selected, e.muted, e.ppqpos, e.chanmsg, e.textmsg = mu.MIDI_GetTextSysexEvt(take, syxidx)
    if e.selected then
      calcMIDITime(e)
      selsyxcnt = selsyxcnt + 1
      table.insert(selectedEvents, e)
    end
    table.insert(allEvents, e)
    syxidx = mu.MIDI_EnumSelTextSysexEvts(take, syxidx)
  end

  -- this determines if we need to switch the view back
  -- to notes (did the note selection change?)
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

  if #selectedEvents == 0 or not (selnotecnt > 0 or selcccnt > 0 or selsyxcnt > 0) then
    titleBarText = DEFAULT_TITLEBAR_TEXT..': No selection' -- (PPQ='..PPQ..')' -- does PPQ make sense here?
    return
  end

  ---------------------------------------------------------------------------
  ------------------------------ TITLEBAR TEXT ------------------------------

  local selectedText = ''
  if selnotecnt > 0 then selectedText = selectedText..selnotecnt..' of '..notecnt..' note(s) selected' end
  if selcccnt > 0 and selnotecnt > 0 then selectedText = selectedText..' :: ' end
  if selcccnt > 0 then selectedText = selectedText..selcccnt..' of '..cccnt..' CC(s) selected' end
  if selsyxcnt > 0 and (selnotecnt > 0 or selcccnt > 0) then selectedText = selectedText..' :: ' end
  if selsyxcnt > 0 then selectedText = selectedText..selsyxcnt..' of '..syxcnt..' Sysex/Text event(s) selected' end
  if selectedText ~= '' then selectedText = ': '..selectedText end
  titleBarText = DEFAULT_TITLEBAR_TEXT..selectedText..' (PPQ='..PPQ..')' --..' DPI=('..r.ImGui_GetWindowDpiScale(ctx)..')'

  ---------------------------------------------------------------------------
  ------------------------------ SETUP FILTER -------------------------------

  for _, type in pairs(dataTypes) do
    type.exists = false
  end

  for _, v in ipairs(selectedEvents) do
    if v.chanmsg and v.chanmsg ~= 0 then
      local type = chanmsgToType(v.chanmsg)
      dataTypes[type].exists = true
    end
  end
  if popupFilter ~= 0 and not dataTypes[popupFilter].exists then popupFilter = 0 end
  if popupFilter == 0 then
    for _, v in ipairs(selectedEvents) do
      if v.chanmsg and v.chanmsg ~= 0 then
        local type = chanmsgToType(v.chanmsg)
        popupFilter = type
        break
      end
    end
  end
  popupLabel = dataTypes[popupFilter].label
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
    elseif v.type == SYXTEXT_TYPE then
      unionEntry('texttype', v.chanmsg, v)
      unionEntry('textmsg', v.textmsg, v)
    end
  end
  if union.selposticks == -INVALID then union.selposticks = INVALID end
  union.seldurticks = union.selposticks == INVALID and INVALID or union.selendticks - union.selposticks

  ---------------------------------------------------------------------------
  -------------------------------- POPUP MENU -------------------------------

  r.ImGui_NewLine(ctx)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
  r.ImGui_Button(ctx, popupLabel, DEFAULT_ITEM_WIDTH * canvasScale * 1.5)

  -- cache the positions to generate next box position
  currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
  currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
  currentRect.right = currentRect.right + 20 * canvasScale -- add some spacing after the button

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'main menu')
  end

  local bail = false
  if r.ImGui_BeginPopup(ctx, 'main menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      if r.ImGui_IsPopupOpen(ctx, 'main menu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
        r.ImGui_CloseCurrentPopup(ctx)
        handledEscape = true
      end
    end
    r.ImGui_PushFont(ctx, fontInfo.small)
    for _, type in pairs(dataTypes) do
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

    if r.ImGui_BeginMenu(ctx, "Overlap Protection") then
      local rv, v = r.ImGui_RadioButtonEx(ctx, 'Overlap Protection Always On', wantsOverlapCorrection == OVERLAP_AUTO and 1 or 0, 1)
      if rv and v == 1 then
        r.SetExtState(scriptID, 'wantsOverlapCorrection', '1', true)
        wantsOverlapCorrection = OVERLAP_AUTO
        -- r.ImGui_CloseCurrentPopup(ctx)
      end

      rv, v = r.ImGui_RadioButtonEx(ctx, 'Overlap Protection After Timeout', wantsOverlapCorrection == OVERLAP_TIMEOUT and 2 or 0, 2)
      if rv and v == 2 then
        r.SetExtState(scriptID, 'wantsOverlapCorrection', '2', true)
        wantsOverlapCorrection = OVERLAP_TIMEOUT
        -- r.ImGui_CloseCurrentPopup(ctx)
      end

      if wantsOverlapCorrection ~= OVERLAP_TIMEOUT then
        r.ImGui_BeginDisabled(ctx)
      end
      r.ImGui_Indent(ctx)
      r.ImGui_SetNextItemWidth(ctx, (DEFAULT_ITEM_WIDTH / 1.75) * canvasScale)
      rv, v = r.ImGui_InputText(ctx, 'ms Timeout', overlapCorrectionTimeout, r.ImGui_InputTextFlags_EnterReturnsTrue()
                                                                           + r.ImGui_InputTextFlags_CharsDecimal())
      if rv then
        v = tonumber(v)
        if v then
          r.SetExtState(scriptID, 'overlapCorrectionTimeout', tostring(math.floor(v)), true)
        end
        -- r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_Unindent(ctx)
      if wantsOverlapCorrection ~= OVERLAP_TIMEOUT then
        r.ImGui_EndDisabled(ctx)
      end

      rv, v = r.ImGui_RadioButtonEx(ctx, 'Overlap Protection Off (Manual)', wantsOverlapCorrection == OVERLAP_MANUAL and 3 or 0, 3)
      if rv and v == 3 then
        r.SetExtState(scriptID, 'wantsOverlapCorrection', '0', true)
        wantsOverlapCorrection = OVERLAP_MANUAL
        -- r.ImGui_CloseCurrentPopup(ctx)
      end
      if wantsOverlapCorrection ~= OVERLAP_MANUAL then
        r.ImGui_BeginDisabled(ctx)
      end
      r.ImGui_Indent(ctx)
      -- rv = r.ImGui_Button(ctx, 'Now')

      rv = r.ImGui_SmallButton(ctx, 'Now')
      if rv then
        correctOverlapsNow = true
      end
      r.ImGui_Unindent(ctx)
      if wantsOverlapCorrection ~= OVERLAP_MANUAL then
        r.ImGui_EndDisabled(ctx)
      end

      r.ImGui_Separator(ctx)
      rv, v = r.ImGui_Checkbox(ctx, 'Overlap Correction Favors Selection', overlapFavorsSelected)
      if rv then
        r.SetExtState(scriptID, 'overlapFavorsSelected', v and '1' or '0', true)
        overlapFavorsSelected = v
        -- r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_EndMenu(ctx)
    end

    local rv, v = r.ImGui_Checkbox(ctx, 'Use Bars.Beats.Percent Format ', wantsBBU)
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

  local function makeTextValueEntry(name)
    return { operation = OP_ABS, opval = (union[name] and union[name] ~= INVALID) and union[name] or INVALID }
  end

  local function makePopupEntry(name)
    return { operation = OP_ABS, opval = (union[name] and union[name] ~= INVALID) and union[name] or INVALID }
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
  elseif popupFilter >= 0x80 then
    userValues.ccnum = makeValueEntry('ccnum')
    userValues.ccval = makeValueEntry('ccval')
    userValues.chanmsg = makeValueEntry('chanmsg')
  else
    userValues.texttype = makePopupEntry('texttype')
    userValues.textmsg = makeTextValueEntry('textmsg')
  end

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE GEN ------------------------------

  -- requires userValues, above

  canProcess = false

  makeTextInput('measures', 'Bars')
  makeTextInput('beats', 'Beats')
  makeTextInput('ticks', wantsBBU and 'Percent' or 'Ticks')

  if popupFilter == NOTE_FILTER then
    makeTextInput('chan', 'Chan', true)
    makeTextInput('pitch', 'Pitch')
    makeTextInput('vel', 'Velocity')
    makeTextInput('notedur', 'Length '..(wantsBBU and '(beat %)' or '(ticks)'), true, DEFAULT_ITEM_WIDTH * 2)
  elseif popupFilter >= 0x80 then
    makeTextInput('chan', 'Chan', true)
    if not cc2byte then makeTextInput('ccnum', 'Ctrlr') end
    makeTextInput('ccval', 'Value')
  elseif popupFilter == -1 or popupFilter > #textTypes then
    makeTextInput('textmsg', 'Message', true, DEFAULT_ITEM_WIDTH * 5.1)
  else
    makeTextInput('texttype', 'Type', true, DEFAULT_ITEM_WIDTH * 1.25)
    makeTextInput('textmsg', 'Message', true, DEFAULT_ITEM_WIDTH * 3.75)
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
  if not handledEscape and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
    if focusKeyboardHere then focusKeyboardHere = nil
    else
      isClosing = true
      return
    end
  end

  local arrowAdjust = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_UpArrow()) and 1
                   or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_DownArrow()) and -1
                   or 0
  if arrowAdjust ~= 0 and (activeFieldName or focusKeyboardHere) then
    for _, hitTest in ipairs(itemBounds) do
      if (hitTest.name == focusKeyboardHere
          or hitTest.name == activeFieldName)
        and hitTest.name ~= 'textmsg'
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
        and hitTest.name ~= 'textmsg'
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

  local enableAutoTimeout = false
  if not canProcess and processTimeout and wantsOverlapCorrection == OVERLAP_TIMEOUT then
    local curtime = r.time_precise() * 1000
    if curtime - processTimeout > overlapCorrectionTimeout then
      correctOverlapsNow = true
      processTimeout = nil
      enableAutoTimeout = true
    end
  end

  if canProcess or correctOverlapsNow then
    r.Undo_BeginBlock2(0)

    local _, _, sectionID = r.get_action_context()
    local autoOverlap = r.GetToggleCommandStateEx(sectionID, 40681)
    if autoOverlap == 1 then
      gooseAutoOverlap()
    end
    local item = r.GetMediaItemTake_Item(take)
    local item_extents = getItemExtents(item)

    mu.MIDI_OpenWriteTransaction(take)

    for _, v in ipairs(selectedEvents) do
      local type = chanmsgToType(v.chanmsg)
      if popupFilter == type then
        updateValuesForEvent(v) -- first update the values
        correctItemExtents(item_extents, v)
      end
    end

    updateItemExtents(item_extents)

    if wantsOverlapCorrection == OVERLAP_AUTO or correctOverlapsNow then
      correctOverlapsNow = true
    end

    local recalced = recalcEventTimes or recalcSelectionTimes
    for _, v in ipairs(selectedEvents) do
      local type = chanmsgToType(v.chanmsg)
      if popupFilter == type then
        local ppqpos = recalced and v.ppqpos or nil
        if popupFilter == NOTE_FILTER then
          local endppqpos = recalced and v.endppqpos or nil
          local chan = changedParameter == 'chan' and v.chan or nil
          local pitch = changedParameter == 'pitch' and v.pitch or nil
          local vel = changedParameter == 'vel' and v.vel or nil
          if v.delete then
            mu.MIDI_DeleteNote(take, v.idx)
          elseif v.touched then
            mu.MIDI_SetNote(take, v.idx, nil, nil, v.ppqpos, v.endppqpos, nil, nil, nil)
          else
            mu.MIDI_SetNote(take, v.idx, nil, nil, ppqpos, endppqpos, chan, pitch, vel)
          end
        elseif popupFilter >= 0x80 then
          local chan = changedParameter == 'chan' and v.chan or nil
          local msg2 = (changedParameter == 'ccnum' or changedParameter == 'ccval') and v.msg2 or nil
          local msg3 = (changedParameter == 'ccnum' or changedParameter == 'ccval') and v.msg3 or nil
          mu.MIDI_SetCC(take, v.idx, nil, nil, ppqpos, nil, chan, msg2, msg3)
        else
          local dotypemsg = (changedParameter == 'texttype' or changedParameter == 'textmsg')
          local texttype = dotypemsg and v.chanmsg or nil
          local textmsg = dotypemsg and v.textmsg or nil
          mu.MIDI_SetTextSysexEvt(take, v.idx, nil, nil, ppqpos, texttype, textmsg)
        end
      end
    end

    if correctOverlapsNow then mu.MIDI_CorrectOverlaps(take, overlapFavorsSelected) end

    mu.MIDI_CommitWriteTransaction(take) -- sorts
    if canProcess and popupFilter == NOTE_FILTER then
      processTimeout = r.time_precise() * 1000
    else
      processTimeout = nil
    end

    if correctOverlapsNow then
      r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40659) -- correct overlaps (always run)
    end

    r.MarkTrackItemsDirty(r.GetMediaItemTake_Track(take), item)

    if autoOverlap == 1 or enableAutoTimeout then
      if not (wantsOverlapCorrection == OVERLAP_TIMEOUT and processTimeout) then
        gooseAutoOverlap()
      end
    end

    local undoText
    if not canProcess and correctOverlapsNow then
      undoText = 'Correct Overlapping Notes'
    else
      if popupFilter == NOTE_FILTER then
        undoText = 'Edit Note(s)'
      elseif popupFilter >= 0x80 then
        undoText = 'Edit CC(s)'
      else
        undoText = 'Edit Sysex/Text Event(s)'
      end
    end
    r.Undo_EndBlock2(0, undoText, -1)
  end
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

  local newFontSize = math.floor(fontInfo[name..'DefaultSize'] * canvasScale)
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
  local winheight = r.ImGui_GetFrameHeightWithSpacing(ctx) * 4
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

  -- -- I want to only show the window if a MIDI editor is frontmost, this doesn't work yet
  -- if not r.ImGui_IsWindowFocused(ctx) then
  --   local hwnd = r.MIDIEditor_GetActive()
  --   if not hwnd or r.JS_Window_GetFocus() ~= hwnd then
  --     mu.post(hwnd and 'no match' or 'no hwnd')
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
