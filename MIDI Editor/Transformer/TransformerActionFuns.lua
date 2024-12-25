--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local ActionFuns = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

Shared = Shared or {} -- Use an existing table or create a new one

local r = reaper
local gdefs = require 'TransformerGeneralDefs'
local adefs = require 'TransformerActionDefs'

local mgdefs = require 'TransformerMetricGrid'

local function setMusicalLength(event, take, PPQ, mgParams)
  if not take then return event.projlen end

  if Shared.getEventType(event) ~= gdefs.NOTE_TYPE then return event.projlen end

  local subdiv = mgParams.param1
  local gridUnit = Shared.getGridUnitFromSubdiv(subdiv, PPQ, mgParams)

  local oldppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime)
  local newppqpos = oldppqpos + gridUnit
  local newprojpos = r.MIDI_GetProjTimeFromPPQPos(take, newppqpos)
  local newprojlen = newprojpos - event.projtime

  event.projlen = newprojlen
  return newprojlen
end

local function quantizeMusicalPosition(event, take, PPQ, mgParams)
  if not take then return event.projtime end

  local subdiv = mgParams.param1
  local strength = tonumber(mgParams.param2)

  local gridUnit = Shared.getGridUnitFromSubdiv(subdiv, PPQ, mgParams)
  local useGridSwing = subdiv < 0 and Shared.gridInfo().currentSwing ~= 0

  if gridUnit == 0 then return event.projtime end

  local timeAdjust = Shared.getTimeOffset()
  local oldppqpos = r.MIDI_GetPPQPosFromProjTime(take, event.projtime - timeAdjust)
  local som = r.MIDI_GetPPQPos_StartOfMeasure(take, oldppqpos)

  local ppqinmeasure = oldppqpos - som -- get the position from the start of the measure
  local newppqpos = som + (gridUnit * math.floor((ppqinmeasure / gridUnit) + 0.5))

  local mgMods, mgReaSwing = mgdefs.getMetricGridModifiers(mgParams)

  if useGridSwing or (mgMods == gdefs.MG_GRID_SWING and mgReaSwing) then
    local scale = useGridSwing and Shared.gridInfo().currentSwing or (mgParams.swing * 0.01)
    local half = gridUnit * 0.5
    local localpos = ppqinmeasure % (gridUnit * 2)
    if localpos >= gridUnit - half and localpos < gridUnit + half then
      newppqpos = newppqpos + (gridUnit * 0.5 * scale)
    end
  elseif mgMods == gdefs.MG_GRID_SWING then
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

local function quantizeMusicalLength(event, take, PPQ, mgParams)
  if not take then return event.projlen end

  local subdiv = mgParams.param1
  local strength = tonumber(mgParams.param2)

  local gridUnit = Shared.getGridUnitFromSubdiv(subdiv, PPQ, mgParams)

  if gridUnit == 0 then return event.projtime end

  local timeAdjust = Shared.getTimeOffset()
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

local function quantizeMusicalEndPos(event, take, PPQ, mgParams)
  if not take then return event.projlen end

  local subdiv = mgParams.param1
  local strength = tonumber(mgParams.param2)

  local gridUnit = Shared.getGridUnitFromSubdiv(subdiv, PPQ, mgParams)
  local useGridSwing = subdiv < 0 and Shared.gridInfo().currentSwing ~= 0

  if gridUnit == 0 then return event.projtime end

  local timeAdjust = Shared.getTimeOffset()
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

  local mgMods, mgReaSwing = mgdefs.getMetricGridModifiers(mgParams)

  if useGridSwing or (mgMods == gdefs.MG_GRID_SWING and mgReaSwing) then
    local scale = useGridSwing and Shared.gridInfo().currentSwing or (mgParams.swing * 0.01)
    local half = gridUnit * 0.5
    local localpos = ppqinmeasure % (gridUnit * 2)
    if localpos >= gridUnit - half and localpos < gridUnit + half then
      newendppqpos = newendppqpos + (gridUnit * 0.5 * scale)
      newppqlen = newendppqpos - ppqpos
    end
  elseif mgMods == gdefs.MG_GRID_SWING then
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

local function setValue(event, property, newval, bipolar)
  if not property then return newval end

  if property == 'chanmsg' then
    local oldtype = Shared.getEventType(event)
    local newtype = Shared.chanMsgToType(newval)
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

local function operateEvent1(event, property, op, param1)
  local bipolar = (op == adefs.OP_MULT or op == adefs.OP_DIV) and true or false
  local oldval = Shared.getValue(event, property, bipolar)
  local newval = oldval

  if op == adefs.OP_ADD then
    newval = oldval + param1
  elseif op == adefs.OP_SUB then
    newval = oldval - param1
  elseif op == adefs.OP_MULT then
    newval = oldval * param1
  elseif op == adefs.OP_DIV then
    newval = param1 ~= 0 and (oldval / param1) or 0
  elseif op == adefs.OP_FIXED then
    newval = param1
  end
  return setValue(event, property, newval, bipolar)
end

local function operateEvent2(event, property, op, param1, param2)
  local oldval = Shared.getValue(event, property)
  local newval = oldval
  if op == adefs.OP_SCALEOFF then
    newval = (oldval * param1) + param2
  end
  return setValue(event, property, newval)
end

-- TODO there might be multiple lines, each of which can only be processed ONCE
-- how to do this? could filter these lines out and then run the nme events separately from the rows
local function createNewMIDIEvent()
end

local function randomValue(event, property, min, max, single)
  local oldval = Shared.getValue(event, property)
  if event.firstlastevent then return oldval end

  local newval = oldval

  local rnd = single and single or math.random()

  newval = (rnd * (max - min)) + min
  if math.type(min) == 'integer' and math.type(max) == 'integer' then newval = math.floor(newval) end
  return setValue(event, property, newval)
end

local function clampValue(event, property, low, high)
  local oldval = Shared.getValue(event, property)
  local newval = oldval < low and low or oldval > high and high or oldval
  return setValue(event, property, newval)
end

local function quantizeTo(event, property, quant)
  local oldval = Shared.getValue(event, property)
  if quant == 0 then return oldval end
  local newval = quant * math.floor((oldval / quant) + 0.5)
  return setValue(event, property, newval)
end

local function mirror(event, property, mirrorVal)
  local oldval = Shared.getValue(event, property)
  local newval = mirrorVal - (oldval - mirrorVal)
  return setValue(event, property, newval)
end

local function linearChangeOverSelection(event, property, projTime, p1, type, p2, mult, context)
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
    return setValue(event, property, newval)
  end
  return setValue(event, property, 0)
end

local function addLength(event, property, mode, context)
  if Shared.getEventType(event) ~= gdefs.NOTE_TYPE then return event.projtime end

  if mode == 3 then
    local lastNoteEnd = context.lastNoteEnd
    if not Shared.addLengthInfo().addLengthFirstEventStartTime then Shared.addLengthInfo().addLengthFirstEventStartTime = event.projtime end
    if not lastNoteEnd then lastNoteEnd = 0 end
    event.projtime = event.projtime + lastNoteEnd - Shared.addLengthInfo().addLengthFirstEventStartTime
    return event.projtime + lastNoteEnd
  elseif mode == 2 then
    event.projtime = event.projtime + event.projlen
    return event.projtime + event.projlen
  elseif mode == 1 then
    if not Shared.addLengthInfo().addLengthFirstEventOffset_Take then Shared.addLengthInfo().addLengthFirstEventOffset_Take = event.projlen end
    event.projtime = event.projtime + Shared.addLengthInfo().addLengthFirstEventOffset_Take
    return event.projtime + Shared.addLengthInfo().addLengthFirstEventOffset_Take
  end
  if not Shared.addLengthInfo().addLengthFirstEventOffset then Shared.addLengthInfo().addLengthFirstEventOffset = event.projlen end
  event.projtime = event.projtime + Shared.addLengthInfo().addLengthFirstEventOffset
  return event.projtime
end

local function moveToCursor(event, property, mode)
  if mode == 1 then -- independent
    if not Shared.moveCursorInfo().moveCursorFirstEventPosition_Take then Shared.moveCursorInfo().moveCursorFirstEventPosition_Take = event.projtime end
    event.projtime = (event.projtime - Shared.moveCursorInfo().moveCursorFirstEventPosition_Take) + r.GetCursorPositionEx(0) + Shared.getTimeOffset()
    return event.projtime
  end
  if not Shared.moveCursorInfo().moveCursorFirstEventPosition then Shared.moveCursorInfo().moveCursorFirstEventPosition = event.projtime end
  event.projtime = (event.projtime - Shared.moveCursorInfo().moveCursorFirstEventPosition) + r.GetCursorPositionEx(0) + Shared.getTimeOffset()
  return event.projtime
end

-- need to think about this
-- function MoveNoteOffToCursor(event, mode)
--   if Shared.getEventType(event) ~= gdefs.NOTE_TYPE then return event.projlen end

--   if mode == 1 then -- independent
--     if not Shared.moveCursorInfo().moveCursorFirstEventLength_Take then Shared.moveCursorInfo().moveCursorFirstEventLength_Take = event.projtime end
--     return (event.projtime - Shared.moveCursorInfo().moveCursorFirstEventLength_Take) + r.GetCursorPositionEx(0) + Shared.getTimeOffset()
--   else
--     if not Shared.moveCursorInfo().moveCursorFirstEventLength then Shared.moveCursorInfo().moveCursorFirstEventLength = event.projtime end
--     return (event.projtime - Shared.moveCursorInfo().moveCursorFirstEventLength) + r.GetCursorPositionEx(0) + Shared.getTimeOffset()
--   end
-- end

local function moveLengthToCursor(event)
  if Shared.getEventType(event) ~= gdefs.NOTE_TYPE then return event.projlen end

  local cursorPos = r.GetCursorPositionEx(0) + Shared.getTimeOffset()

  if event.projtime >= cursorPos then return event.projlen end

  event.projlen = cursorPos - event.projtime
  return event.projlen
end

local function moveToItemPos(event, property, way, offset, context)
  local take = context.take
  if not take then return event[property] end

  if Shared.getEventType(event) ~= gdefs.NOTE_TYPE and way == 2 then return event[property] end
  local item = r.GetMediaItemTake_Item(take)
  if item then
    if way == 0 then
      local targetPos = r.GetMediaItemInfo_Value(item, 'D_POSITION') + Shared.getTimeOffset()
      local offsetTime = offset and Shared.lengthFormatToSeconds(offset, targetPos, context) or 0
      event[property] = targetPos + offsetTime
    elseif way == 1 or way == 2 then
      local targetPos = r.GetMediaItemInfo_Value(item, 'D_POSITION') + Shared.getTimeOffset() + r.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local offsetTime = offset and Shared.lengthFormatToSeconds(offset, targetPos, context) or 0
      event[property] = way == 1 and (targetPos + offsetTime) or ((targetPos - event.projtime) + offsetTime)
    end
  end
  return event[property]
end

local function ccSetCurve(take, event, ctype, bzext)
  if event.chanmsg < 0xA0 or event.chanmsg >= 0xF0 then return false end
  ctype = ctype < gdefs.CC_CURVE_SQUARE and gdefs.CC_CURVE_SQUARE or ctype > gdefs.CC_CURVE_BEZIER and gdefs.CC_CURVE_BEZIER or ctype
  event.setcurve = ctype
  event.setcurveext = ctype == gdefs.CC_CURVE_BEZIER and bzext or 0
  return ctype
end

local function addDuration(event, property, duration, baseTime, context)
  local adjustedTime = Shared.lengthFormatToSeconds(duration, baseTime, context)
  event[property] = baseTime + adjustedTime
  return event[property]
end

local function subtractDuration(event, property, duration, baseTime, context)
  local adjustedTime = Shared.lengthFormatToSeconds(duration, baseTime, context)
  event[property] = baseTime - adjustedTime
  return event[property]
end

-- uses a timeval for the offset so that we can get an offset relative to the new position
local function multiplyPosition(event, property, param, relative, offset, context)
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
    local itemStartPos = r.GetMediaItemInfo_Value(item, 'D_POSITION') + Shared.getTimeOffset() -- item
    local distanceFromStart = event.projtime - itemStartPos
    scaledPosition = itemStartPos + (distanceFromStart * param)
  end
  scaledPosition = scaledPosition + (offset and Shared.lengthFormatToSeconds(offset, scaledPosition, context) or 0)

  event[property] = scaledPosition
  return scaledPosition
end

ActionFuns.setMusicalLength = setMusicalLength
ActionFuns.quantizeMusicalPosition = quantizeMusicalPosition
ActionFuns.quantizeMusicalLength = quantizeMusicalLength
ActionFuns.quantizeMusicalEndPos = quantizeMusicalEndPos
ActionFuns.setValue = setValue
ActionFuns.operateEvent1 = operateEvent1
ActionFuns.operateEvent2 = operateEvent2
ActionFuns.randomValue = randomValue
ActionFuns.createNewMIDIEvent = createNewMIDIEvent
ActionFuns.clampValue = clampValue
ActionFuns.quantizeTo = quantizeTo
ActionFuns.mirror = mirror
ActionFuns.linearChangeOverSelection = linearChangeOverSelection
ActionFuns.addLength = addLength
ActionFuns.moveToCursor = moveToCursor
ActionFuns.moveLengthToCursor = moveLengthToCursor
ActionFuns.moveToItemPos = moveToItemPos
ActionFuns.ccSetCurve = ccSetCurve
ActionFuns.addDuration = addDuration
ActionFuns.subtractDuration = subtractDuration
ActionFuns.multiplyPosition = multiplyPosition

return ActionFuns
