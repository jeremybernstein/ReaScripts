--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local reaper = reaper

function CCLookForward(sourceMsg, sourcePPQ, sourceMIDIString, sourceStringPos, nudge)
  local deletePos = {}
  local ppqTime = sourcePPQ
  local stringPos = sourceStringPos

  while stringPos < sourceMIDIString:len() - 12 do
    local offset, flags, msg, newStringPos = string.unpack("i4Bs4", sourceMIDIString, stringPos)
    local selected = flags & 1 ~= 0
    local isCC = msg:byte(1) & 0xF0 == 0xB0
    local isPB = msg:byte(1) & 0xF0 == 0xE0

    ppqTime = ppqTime + offset
    local diff = ppqTime - (sourcePPQ + nudge)
    if not selected and diff <= nudge then
      if isPB or (isCC and msg:byte(2) == sourceMsg:byte(2)) then -- same CC or PB
        deletePos[#deletePos + 1] = stringPos -- mark this for deletion later
        --reaper.ShowConsoleMsg("deleting")
        --break
      end
    else
      break -- out of the nudge zone
    end
    stringPos = newStringPos
  end

  return nudge, deletePos
end

function CCLookBackward(sourceMsg, sourcePPQ, events, nudge)
  for i = #events.ppq, 1, -1 do
    local event = events.ppq[i]
    local selected = event.selected
    if event.msg ~= "" then
      local isCC = event.msg:byte(1) & 0xF0 == 0xB0
      local isPB = event.msg:byte(1) & 0xF0 == 0xE0

      local diff = (sourcePPQ + nudge) - event.ppq
      if not selected and diff <= 0 and diff >= nudge then
        if isPB or (isCC and event.msg:byte(2) == sourceMsg:byte(2)) then -- same CC pr PB
          local offset, flags, msg = string.unpack("i4Bs4", events.midi[i], 1)
          events.midi[i] = string.pack("i4Bs4", offset, 0, "")
          event.msg = ""
          -- break
        end
      else
        break -- out of the nudge zone
      end
    end
  end

  return nudge, false -- never delete the source
end

function NoteLookForward(sourceMsg, sourcePPQ, sourceMIDIString, sourceStringPos, nudge)
  local adjustedNudge = nudge
  local deletePos = {}

  local stringPos = sourceStringPos

  local sourceNoteOn = sourceMsg:byte(1) & 0xF0 == 0x90
  local sourceNoteOff = sourceMsg:byte(1) & 0xF0 == 0x80

  if sourceNoteOn and sourceMsg:byte(3) == 0 then
    sourceNoteOff = true
    sourceNoteOn = false
  end

  local ppqTime = sourcePPQ

  local lastNoteOff = -1

  while stringPos < sourceMIDIString:len() - 12 do
    local offset, flags, msg, newStringPos = string.unpack("i4Bs4", sourceMIDIString, stringPos)
    local selected = flags & 1 ~= 0
    local noteOn = msg:byte(1) & 0xF0 == 0x90
    local noteOff = msg:byte(1) & 0xF0 == 0x80

    if noteOn and msg:byte(3) == 0 then
      noteOff = true
      noteOn = false
    end

    ppqTime = ppqTime + offset
    local diff = ppqTime - (sourcePPQ + nudge)
    if diff <= nudge then
      if (not selected or noteOff)
        and (noteOn or noteOff)
        and msg:byte(2) == sourceMsg:byte(2)
      then -- same note
        if noteOff then -- if we hit an unselected noteoff first, it's bogus and needs to be deleted
          if not selected then deletePos[#deletePos + 1] = stringPos -- mark this for deletion later
          else lastNoteOff = stringPos end
        elseif noteOn then
          if sourceNoteOn then -- delete the source
            if lastNoteOff ~= -1 then deletePos[#deletePos + 1] = lastNoteOff end -- and delete the associated note-off
          elseif sourceNoteOff then
            adjustedNudge = diff <= -nudge and 0 or (diff <= 0 and nudge - -diff or nudge)
          end
          break
        end
      end
    else
      break -- we're out of the nudge zone
    end
    stringPos = newStringPos
  end
  return adjustedNudge, deletePos
end

function NoteLookBackward(sourceMsg, sourcePPQ, events, nudge)
  local adjustedNudge = nudge
  local deleteIt = false

  local sourceNoteOn = sourceMsg:byte(1) & 0xF0 == 0x90
  local sourceNoteOff = sourceMsg:byte(1) & 0xF0 == 0x80

  if sourceNoteOn and sourceMsg:byte(3) == 0 then
    sourceNoteOff = true
    sourceNoteOn = false
  end

  for i = #events.ppq, 1, -1 do
    local event = events.ppq[i]
    local selected = event.selected
    if event.msg ~= "" then
      local noteOn = event.msg:byte(1) & 0xF0 == 0x90
      local noteOff = event.msg:byte(1) & 0xF0 == 0x80

      if noteOn and event.msg:byte(3) == 0 then
        noteOff = true
        noteOn = false
      end

      local diff = (sourcePPQ + nudge) - event.ppq
      if diff <= 0 and diff >= nudge then
        if not selected and (noteOn or noteOff) and event.msg:byte(2) == sourceMsg:byte(2) then -- same note
          if noteOn then -- if we hit a noteon first, it's something weird, delete it and keep searching
            local offset, flags, msg = string.unpack("i4Bs4", events.midi[i], 1)
            events.midi[i] = string.pack("i4Bs4", offset, 0, "")
            event.msg = ""
            deleteIt = true
          elseif noteOff then
            if sourceNoteOn then
              adjustedNudge = diff <= nudge and 0 or (diff <= nudge and nudge or nudge + -diff)
            elseif sourceNoteOff then
              deleteIt = true
              for j = i + 1, 1, -1 do -- it's the event in front of this one
                local ev = events.ppq[j]
                local status = ev.msg:byte(1) & 0xF0
                if ev.selected and status == 0x90 and ev.msg:byte(3) ~= 0
                  and ev.msg:byte(2) == sourceMsg:byte(2)
                then
                   -- matching note-on for the note-off to delete, we need to delete it, too
                   local offset, flags, msg = string.unpack("i4Bs4", events.midi[j], 1)
                   events.midi[j] = string.pack("i4Bs4", offset, 0, "")
                   ev.msg = ""
                end
              end
            end
            break
          end
        end
      else
        break -- out of the nudge zone
      end
    end
  end
  return adjustedNudge, deleteIt
end

function LookForward(sourceMsg, sourcePPQ, sourceMIDIString, sourceStringPos, nudge)
    local isCC = sourceMsg:byte(1) & 0xF0 == 0xB0
    local isPB = sourceMsg:byte(1) & 0xF0 == 0xE0
    local noteOn = sourceMsg:byte(1) & 0xF0 == 0x90
    local noteOff = sourceMsg:byte(1) & 0xF0 == 0x80

    if noteOn or noteOff then
      return NoteLookForward(sourceMsg, sourcePPQ, sourceMIDIString, sourceStringPos, nudge)
    elseif isCC or isPB then
      return CCLookForward(sourceMsg, sourcePPQ, sourceMIDIString, sourceStringPos, nudge)
    end
    return 0, {}
end

function LookBackward(sourceMsg, sourcePPQ, events, nudge)
    local isCC = sourceMsg:byte(1) & 0xF0 == 0xB0
    local isPB = sourceMsg:byte(1) & 0xF0 == 0xE0
    local noteOn = sourceMsg:byte(1) & 0xF0 == 0x90
    local noteOff = sourceMsg:byte(1) & 0xF0 == 0x80

    if noteOn or noteOff then
      return NoteLookBackward(sourceMsg, sourcePPQ, events, nudge)
    elseif isCC or isPB then
      return CCLookBackward(sourceMsg, sourcePPQ, events, nudge)
    end
    return 0, false
end

function GetPrevNextGridPos(take, ppqpos, prev)
  local qnsom = reaper.MIDI_GetProjQNFromPPQPos(take, reaper.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos))
  local qnpos = reaper.MIDI_GetProjQNFromPPQPos(take, ppqpos)
  local intg = math.floor(qnpos)
  local frac = qnpos - intg
  local grid = reaper.MIDI_GetGrid(take)

  if grid > 1 then
    intg = math.floor(intg / grid) * grid
  end

  local newpqpos
  if prev then
    newpqpos = intg + math.floor(frac / grid) * grid
  else
    newqnpos = intg + (math.floor(frac / grid) + 1) * grid
  end
  return reaper.MIDI_GetPPQPosFromProjQN(take, newpqpos)
end

function GetPreviousGridPosition(take, ppqpos)
  return GetPrevNextGridPos(take, ppqpos, true)
end

function GetNextGridPosition(take, ppqpos)
  return GetPrevNextGridPos(take, ppqpos, false)
end

function ExtendItem(take, nudge, PPQEvents)
  local itemPos = reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), "D_POSITION")
  local itemLen = reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), "D_LENGTH")
  local thePPQ = 0
  local theDiffPPQ = 0

  if nudge > 0 then
    local endPosInPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, itemPos + itemLen)
    for i = #PPQEvents, 1, -1 do
      if PPQEvents[i].selected and PPQEvents[i].msg ~= "" then
        thePPQ = PPQEvents[i].ppq
        break
      end
    end
    theDiffPPQ = endPosInPPQ - thePPQ
    if theDiffPPQ < 0 and theDiffPPQ < math.abs(nudge) then
      -- local newEndPos = reaper.MIDI_GetProjTimeFromPPQPos(take, GetNextGridPosition(take, endPosInPPQ + -(theDiffPPQ - math.abs(nudge))))
      local newEndPos = reaper.MIDI_GetProjTimeFromPPQPos(take, endPosInPPQ + -(theDiffPPQ - math.abs(nudge)))
      reaper.SetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), "D_LENGTH", newEndPos - itemPos)
    end
  else
    local startPosInPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, itemPos)
    for i = 1, #PPQEvents do
      if PPQEvents[i].selected and PPQEvents[i].msg ~= "" then
        thePPQ = PPQEvents[i].ppq
        break
      end
    end
    theDiffPPQ = thePPQ - startPosInPPQ
    if theDiffPPQ < 0 and theDiffPPQ < math.abs(nudge) then
      -- local gridppq = GetPreviousGridPosition(take, startPosInPPQ + (theDiffPPQ - math.abs(nudge)))
      local notepos = reaper.MIDI_GetProjTimeFromPPQPos(take, startPosInPPQ + (theDiffPPQ - math.abs(nudge)))
      -- local newStartPos = reaper.MIDI_GetProjTimeFromPPQPos(take, gridppq)
      local newStartPos = reaper.MIDI_GetProjTimeFromPPQPos(take, startPosInPPQ + (theDiffPPQ - math.abs(nudge)))
      reaper.SetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), "D_POSITION", newStartPos)
      local newLen = (itemPos + itemLen) - newStartPos
      reaper.SetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), "D_LENGTH", newLen)

      --reaper.MIDI_SetItemExtents(reaper.GetMediaItemTake_Item(take), reaper.MIDI_GetProjQNFromPPQPos(take, gridppq), reaper.MIDI_GetProjQNFromPPQPos(take, startPosInPPQ + reaper.MIDI_GetPPQPosFromProjTime(take, itemPos + newLen)))

      -- reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", newStartPos - notepos)
      -- reaper.ShowConsoleMsg("D_STARTOFFS: " .. notepos-newStartPos .. "\n")
    end
  end
end

function NudgeSelectedEvents(take, nudge)
  local rv, MIDIString = reaper.MIDI_GetAllEvts(take, "") -- empty string for backward compatibility with older REAPER versions

  local stringPos = 1 -- Position inside MIDIString while parsing

  local PPQEvents = {}
  local MIDIEvents = {}
  local ppqTime = 0;
  local startOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local toDelete = {}

  -- if startOffset ~= 0 then
  --   local startPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), "D_POSITION") + startOffset)
  --   ppqTime = ppqTime + startPPQ
  --   reaper.ShowConsoleMsg("startPPQ: " .. startPPQ .. "\n")
  -- end


  while stringPos < MIDIString:len() - 12 do -- -12 to exclude final All-Notes-Off message
    local offset, flags, msg, newStringPos = string.unpack("i4Bs4", MIDIString, stringPos)
    local selected = flags & 1 ~= 0
    local nudgeIt = nudge
    local deleteIt = false
    local isCC = msg:byte(1) & 0xF0 == 0xB0
    local isPB = msg:byte(1) & 0xF0 == 0xE0
    local noteOn = msg:byte(1) & 0xF0 == 0x90
    local noteOff = msg:byte(1) & 0xF0 == 0x80

    ppqTime = ppqTime + offset -- current PPQ time for this event

    for k, sp in pairs(toDelete) do
      if sp == stringPos then
        toDelete[k] = nil
        deleteIt = true
        break
      end
    end

    if not deleteIt then
      if selected
        and (noteOn or noteOff or isCC or isPB) -- note & CC events
      then -- look forward
        if nudge > 0 then
          local needsDelete
          nudgeIt, needsDelete = LookForward(msg, ppqTime, MIDIString, newStringPos, nudge)
          if needsDelete and #needsDelete ~= 0 then
            for _, v in pairs(needsDelete) do
              toDelete[#toDelete + 1] = v
            end
           if not isCC and not isPB then deleteIt = true end -- don't delete the source event for CCs
          end
        else
          nudgeIt, deleteIt = LookBackward(msg, ppqTime, { midi = MIDIEvents, ppq = PPQEvents }, nudge)
        end

        if not deleteIt then
          MIDIEvents[#MIDIEvents + 1] = string.pack("i4Bs4", offset + nudgeIt, flags, msg)
          PPQEvents[#PPQEvents + 1] = { ppq = ppqTime + nudgeIt, selected = selected, msg = msg }
          if nudgeIt ~= 0 then
            MIDIEvents[#MIDIEvents + 1] = string.pack("i4Bs4", -nudgeIt, 0, "")
            PPQEvents[#PPQEvents + 1] = { ppq = ppqTime - nudgeIt, selected = false, msg = "" }
          end
        end
      else
        MIDIEvents[#MIDIEvents + 1] = string.sub(MIDIString, stringPos, newStringPos - 1)
        PPQEvents[#PPQEvents + 1] = { ppq = ppqTime, selected = selected, msg = msg }
      end
    end

    if deleteIt then
      MIDIEvents[#MIDIEvents + 1] = string.pack("i4Bs4", offset, 0, "")
      PPQEvents[#PPQEvents + 1] = { ppq = ppqTime, selected = false, msg = "" }
    end

    stringPos = newStringPos
  end

  reaper.MIDI_SetAllEvts(take, table.concat(MIDIEvents) .. MIDIString:sub(-12))
  reaper.MIDI_Sort(take)

  ExtendItem(take, nudge, PPQEvents)

  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), reaper.GetMediaItemTake_Item(take))
end

function IsMIDIEditor()
  local _, _, sectionID = reaper.get_action_context()
  -- ---------------- MIDI Editor ---------- Event List ------- Inline Editor
  return sectionID == 32060 or sectionID == 32061 or sectionID == 32062
end

local _nudge = 0
local _take = nil
local _totalNudge = 0
local _held = {}
local _startTime = 0

function InterceptKeys()
  local state = reaper.JS_VKeys_GetState(0)
  for i = 1, #state do
    local abyte = state:byte(i)
    if abyte and abyte == 1 then -- abyte ~= 0 then
      _held[#_held + 1] = i
      reaper.JS_VKeys_Intercept(i, 1) -- Block the key, else REAPER will run script again.
    end
  end
end

function ReleaseKeys()
  for _, v in pairs(_held) do
    reaper.JS_VKeys_Intercept(v, -1) -- Unblock the key
  end
end

function OnExit()
  ReleaseKeys()
  reaper.Undo_BeginBlock2(0)
  if _totalNudge < 0 then _totalNudge = -_totalNudge end
  reaper.Undo_EndBlock2(0, "Nudge " .. (_nudge > 0 and "Forward " or "Backward ") .. _totalNudge .. " ticks", -1) -- message ignored in defer apparently
end

function OnCrash(err)
  reaper.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
  ReleaseKeys()
end

function DoIt()
  if _startTime == 0 or reaper.time_precise() - _startTime > 0.5 then
    NudgeSelectedEvents(_take, _nudge)
    _totalNudge = _totalNudge + _nudge
    if _startTime == 0 then
      _startTime = reaper.time_precise()
    end
  end

  local done = false
  if #_held == 0 then
    return
  else
    local state = reaper.JS_VKeys_GetState(0)
    for _, v in pairs(_held) do
      local abyte = state:byte(v)
      if abyte ~= 1 then
        return
      end
    end
  end

  reaper.defer(function() xpcall(DoIt, OnCrash) end)
end

function GetActiveMIDIEditorTake()
  if IsMIDIEditor() then
    local hwnd = reaper.MIDIEditor_GetActive()
    if hwnd then
      local take = reaper.MIDIEditor_GetTake(hwnd)
      return take
    end
  end
  return nil
end

function Setup(nudge, keyrepeat)
  _take = GetActiveMIDIEditorTake()
  if _take then
    _nudge = nudge
    reaper.atexit(OnExit)

    if keyrepeat and reaper.APIExists("JS_VKeys_GetState") then
      InterceptKeys()
    end
    return true
  end
  return false
end

function Nudge()
  xpcall(DoIt, OnCrash)
end


