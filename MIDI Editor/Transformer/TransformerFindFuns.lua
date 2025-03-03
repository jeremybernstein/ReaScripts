--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local FindFuns = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

Shared = Shared or {} -- Use an existing table or create a new one

local r = reaper
local gdefs = require 'TransformerGeneralDefs'
local fdefs = require 'TransformerFindDefs'

local function testEvent1(event, property, op, param1)
  local val = Shared.getValue(event, property)
  local retval = false

  if op == fdefs.OP_EQ then
    retval = val == param1
  elseif op == fdefs.OP_GT then
    retval = val > param1
  elseif op == fdefs.OP_GTE then
    retval = val >= param1
  elseif op == fdefs.OP_LT then
    retval = val < param1
  elseif op == fdefs.OP_LTE then
    retval = val <= param1
  elseif op == fdefs.OP_EQ_NOTE then
    retval = (Shared.getEventType(event) == gdefs.NOTE_TYPE) and (val % 12 == param1)
  end
  return retval
end

local function eventIsSimilar(event, property, val, param1, param2)
  for _, e in ipairs(Shared.selectedEvents()) do
    if e.chanmsg == event.chanmsg then -- a little hacky here
      local check = true
      if e.chanmsg == 0xB0 -- special case for real CC msgs, must match the CC#, as well
        and property ~= 'msg2'
        and e.msg2 ~= event.msg2
      then
        check = false
      end
      if check then
        local eval = Shared.getValue(e, property)
        if val >= (eval - param1) and val <= (eval + param2) then
          return true
        end
      end
    end
  end
  return false
end

local function testEvent2(event, property, op, param1, param2)
  local val = Shared.getValue(event, property)
  local retval = false

  if op == fdefs.OP_INRANGE then
    retval = (val >= param1 and val <= param2)
  elseif op == fdefs.OP_INRANGE_EXCL then
    retval = (val >= param1 and val < param2)
  elseif op == fdefs.OP_EQ_SLOP then
    retval = (val >= (param1 - param2) and val <= (param1 + param2))
  elseif op == fdefs.OP_SIMILAR then
    if eventIsSimilar(event, property, val, param1, param2) then return true end
  end
  return retval
end

local function findEveryNPattern(event, evnParams)
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

local function findEveryN(event, evnParams)
  if not evnParams then return false end

  if evnParams.isBitField then return findEveryNPattern(event, evnParams) end

  local param1 = evnParams.interval
  if not param1 or param1 <= 0 then return false end

  local count = event.count - 1
  count = count - (evnParams.offset and evnParams.offset or 0)
  return count % param1 == 0
end

local function findEveryNNotePattern(event, evnParams, notenum)
  if Shared.getEventType(event) ~= gdefs.NOTE_TYPE then return false end
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

local function findEveryNNote(event, evnParams, notenum)
  if Shared.getEventType(event) ~= gdefs.NOTE_TYPE then return false end
  if not evnParams then return false end

  if evnParams.isBitField then return findEveryNNotePattern(event, evnParams, notenum) end

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

local function equalsMusicalLength(event, take, PPQ, mgParams)
  if not take then return false end

  if Shared.getEventType(event) ~= gdefs.NOTE_TYPE then return false end

  local subdiv = mgParams.param1
  local gridUnit = Shared.getGridUnitFromSubdiv(subdiv, PPQ, mgParams)

  local preSlop = gridUnit * (mgParams.preSlopPercent / 100)
  local postSlop = gridUnit * (mgParams.postSlopPercent / 100)
  if postSlop == 0 then postSlop = 1 end

  local ppqlen = event.endppqpos - event.ppqpos
  return ppqlen >= gridUnit - preSlop and ppqlen <= gridUnit + postSlop
end

local function selectChordNote(event, chordNote)
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

local function cursorPosition(event, property, cursorPosProj, which)
  local time = event[property]

  if which == fdefs.CURSOR_LT then -- before
    return time < cursorPosProj
  elseif which == fdefs.CURSOR_GT then -- after
    return time > cursorPosProj
  elseif which == fdefs.CURSOR_AT then -- at
    return time == cursorPosProj
  elseif which == fdefs.CURSOR_LTE then -- before/at
    return time <= cursorPosProj
  elseif which == fdefs.CURSOR_GTE then -- after/at
    return time >= cursorPosProj
  elseif which == fdefs.CURSOR_UNDER then
    if Shared.getEventType(event) == gdefs.NOTE_TYPE then
      local endtime = time + event.projlen
      return cursorPosProj >= time and cursorPosProj < endtime
    else
      return time == cursorPosProj
    end
  end
  return false
end

local function underEditCursor(event, take, PPQ, cursorPosProj, param1, param2)
  local gridUnit = Shared.getGridUnitFromSubdiv(param1, PPQ)
  local PPQPercent = gridUnit + (gridUnit * (param2 / 100))
  local cursorPPQPos = r.MIDI_GetPPQPosFromProjTime(take, cursorPosProj)
  local minRange = cursorPPQPos - PPQPercent
  local maxRange = cursorPPQPos + PPQPercent

  local time = event.ppqpos
  if time >= minRange and time < maxRange then return true end
  if Shared.getEventType(event) == gdefs.NOTE_TYPE then
    local endtime = event.endppqpos
    if time <= minRange and endtime > minRange then return true end
  end
  return false
end

local function isNearEvent(event, take, PPQ, evSelParams, param2)
  local scale = tonumber(evSelParams.scaleStr)
  local gridUnit = Shared.getGridUnitFromSubdiv(param2, PPQ)
  local PPQPercent = gridUnit * (scale / 100)
  local minRange = event.ppqpos - PPQPercent
  local maxRange = event.ppqpos + PPQPercent

  for k, ev in ipairs(Shared.allEvents()) do
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

local function onMetricGrid(take, PPQ, event, mgParams)
  if not take then return false end

  local ppqpos = event.ppqpos

  local subdiv = mgParams.param1
  local gridStr = mgParams.param2

  local gridLen = #gridStr
  local gridUnit = Shared.getGridUnitFromSubdiv(subdiv, PPQ, mgParams)

  local cycleLength = gridUnit * gridLen
  local som = r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)
  local preSlop = gridUnit * (mgParams.preSlopPercent / 100)
  local postSlop = gridUnit * (mgParams.postSlopPercent / 100)
  if postSlop == 0 then postSlop = 1 end

  -- handle cycle lengths > measure
  if mgParams.wantsBarRestart then
    if not Shared.cachedSOM then Shared.cachedSOM = som end
    if som ~= Shared.cachedSOM
      or som - Shared.cachedSOM > cycleLength
    then
      Shared.cachedSOM = som
      Shared.cachedMetric = nil
      Shared.cachedWrapped = nil
    end
    ppqpos = ppqpos - Shared.cachedSOM
  end

  local wrapped = math.floor(ppqpos / cycleLength)
  if wrapped ~= Shared.cachedWrapped then
    Shared.cachedWrapped = wrapped
    Shared.cachedMetric = nil
  end
  local modPos = math.fmod(ppqpos, cycleLength)

  -- Shared.cachedMetric is used to avoid iterating from the beginning each time
  -- although it assumes a single metric grid -- how to solve?

  local iter = 0
  while iter < 2 do
    local doRestart = false
    for i = (Shared.cachedMetric and iter == 0) and Shared.cachedMetric or 1, gridLen do
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
        Shared.cachedMetric = i
        return c ~= '0' and true or false
      end
    end
    iter = iter + 1
    if not doRestart then break end
  end
  return false
end

local function onMetronome(event, take, PPQ, param1, param2)
  local projtime = r.MIDI_GetProjTimeFromPPQPos(take, event.ppqpos)
  local tsDenom, metroStr = r.TimeMap_GetMetronomePattern(0, projtime, 'EXTENDED')
  local slop = param2 / 100

  local tsNum = #metroStr
  local beatPPQ = (4 / tsDenom) * PPQ
  local measppq = r.MIDI_GetPPQPos_StartOfMeasure(take, event.ppqpos)
  for i = 1, tsNum do
    -- Shared.mu.post(slop, param1, param2, metroStr:sub(i, i), event.ppqpos)
    local tgtPPQ = measppq + ((i - 1) * beatPPQ)
    local slopPPQ = slop * beatPPQ
    if metroStr:sub(i, i) == param1
      and event.ppqpos >= tgtPPQ - slopPPQ
      and event.ppqpos <= tgtPPQ + slopPPQ
    then
      return true
    end
  end
  return false
end

local function inScale(event, scale, root)
  if Shared.getEventType(event) ~= gdefs.NOTE_TYPE then return false end

  local note = event.msg2 % 12
  note = note - root
  if note < 0 then note = note + 12 end
  for _, v in ipairs(scale) do
    if note == v then return true end
  end
  return false
end

local function onGrid(event, property, take, PPQ)
  if not take then return false end

  local grid, swing = Shared.gridInfo().currentGrid, Shared.gridInfo().currentSwing -- 1.0 is QN, 1.5 dotted, etc.
  local timeAdjust = Shared.getTimeOffset()
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

local function inBarRange(take, PPQ, event, rangeStart, rangeEnd)
  if not take then return false end

  local tpos = event.projtime
  local _, _, cml, _, cdenom = r.TimeMap2_timeToBeats(0, tpos)
  local beatPPQ = (4 / cdenom) * PPQ
  local measurePPQ = beatPPQ * cml

  local som = r.MIDI_GetPPQPos_StartOfMeasure(take, event.ppqpos)
  local barpos = (event.ppqpos - som) / measurePPQ

  return barpos >= (rangeStart / 100) and barpos < (rangeEnd / 100)
end

local function inTakeRange(take, event, rangeStart, rangeEnd)
  if not take then return false end

  local takeStart = Shared.contextInfo.takeInfo.takeStart
  local takeEnd = Shared.contextInfo.takeInfo.takeEnd

  local norm = (event.projtime - takeStart) / (takeEnd - takeStart)
  local normend

  if Shared.getEventType(event) == gdefs.NOTE_TYPE then
    local projend = event.projtime + event.projlen
    normend = (projend - takeStart) / (takeEnd - takeStart)
  end

  return (norm >= (rangeStart / 100) and norm < (rangeEnd / 100))
    or (normend and normend >= (rangeStart / 100) and normend < (rangeEnd / 100))
end

local function inTimeSelectionRange(take, event, rangeStart, rangeEnd)
  if not take then return false end

  local tsStart = Shared.contextInfo.tsInfo.tsStart
  local tsEnd = Shared.contextInfo.tsInfo.tsEnd

  local norm = (event.projtime - tsStart) / (tsEnd - tsStart)
  local normend

  if Shared.getEventType(event) == gdefs.NOTE_TYPE then
    local projend = event.projtime + event.projlen
    normend = (projend - tsStart) / (tsEnd - tsStart)
  end

  return (norm >= (rangeStart / 100) and norm < (rangeEnd / 100))
    or (normend and normend >= (rangeStart / 100) and normend < (rangeEnd / 100))
end

local function inRazorArea(event, take)
  if not take then return false end

  local track = r.GetMediaItemTake_Track(take)
  if not track then return false end

  local item = r.GetMediaItemTake_Item(take)
  if not item then return false end

  local freemode = r.GetMediaTrackInfo_Value(track, 'I_FREEMODE')
  local itemTop = freemode ~= 0 and r.GetMediaItemInfo_Value(item, 'F_FREEMODE_Y') or nil
  local itemBottom = freemode ~= 0 and (itemTop + r.GetMediaItemInfo_Value(item, 'F_FREEMODE_H')) or nil

  local timeAdjust = Shared.getTimeOffset()

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

local function ccHasCurve(take, event, ctype)
  if event.chanmsg < 0xA0 or event.chanmsg >= 0xF0 then return false end
  local rv, curveType = Shared.mu.MIDI_GetCCShape(take, event.idx)
  return rv and curveType == ctype
end

FindFuns.testEvent1 = testEvent1
FindFuns.eventIsSimilar = eventIsSimilar
FindFuns.testEvent2 = testEvent2
FindFuns.findEveryNPattern = findEveryNPattern
FindFuns.findEveryN = findEveryN
FindFuns.findEveryNNotePattern = findEveryNNotePattern
FindFuns.findEveryNNote = findEveryNNote
FindFuns.equalsMusicalLength = equalsMusicalLength
FindFuns.selectChordNote = selectChordNote
FindFuns.cursorPosition = cursorPosition
FindFuns.underEditCursor = underEditCursor
FindFuns.isNearEvent = isNearEvent
FindFuns.onMetricGrid = onMetricGrid
FindFuns.onMetronome = onMetronome
FindFuns.inScale = inScale
FindFuns.onGrid = onGrid
FindFuns.inBarRange = inBarRange
FindFuns.inRazorArea = inRazorArea
FindFuns.ccHasCurve = ccHasCurve
FindFuns.inTakeRange = inTakeRange
FindFuns.inTimeSelectionRange = inTimeSelectionRange

return FindFuns
