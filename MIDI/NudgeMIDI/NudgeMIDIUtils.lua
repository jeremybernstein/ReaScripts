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
    if (not selected or noteOff) and diff <= nudge then
      if (noteOn or noteOff) and msg:byte(2) == sourceMsg:byte(2) then -- same note
        if noteOff then
          if sourceNoteOn then
            deletePos[#deletePos + 1] = stringPos -- mark this for deletion later
            break
          end
        elseif noteOn then
          if sourceNoteOff then
            adjustedNudge = diff <= -nudge and 0 or (diff <= 0 and nudge - -diff or nudge)
            break
          end
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
      if (not selected or noteOn) and diff <= 0 and diff >= nudge then
        if (noteOn or noteOff) and event.msg:byte(2) == sourceMsg:byte(2) then -- same note
          if noteOn then
            if sourceNoteOff then
              -- delete it
              local offset, flags, msg = string.unpack("i4Bs4", events.midi[i], 1)
              events.midi[i] = string.pack("i4Bs4", offset, 0, "")
              event.msg = ""
              deleteIt = true
              break
            end
          elseif noteOff then
            if sourceNoteOn then
              adjustedNudge = diff <= nudge and 0 or (diff <= nudge and nudge or nudge + -diff)
              break
            end
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

function NudgeSelectedEvents(take, nudge)
  local rv, MIDIString = reaper.MIDI_GetAllEvts(take)

  local stringPos = 1 -- Position inside MIDIString while parsing

  local PPQEvents = {}
  local MIDIEvents = {}
  local ppqTime = 0;
  local toDelete = {}

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
          if nudgeIt then
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

function OnExit()
  for _, v in pairs(_held) do
    reaper.JS_VKeys_Intercept(v, -1) -- Unblock the key
  end
  reaper.Undo_BeginBlock2(0)
  if _totalNudge < 0 then _totalNudge = -_totalNudge end
  reaper.Undo_EndBlock2(0, "Nudge " .. (_nudge > 0 and "Forward " or "Backward ") .. _totalNudge .. " ticks", -1) -- message ignored in defer apparently
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

  reaper.defer(DoIt)
end

function DoItFirstTime()
  if #_held == 0 then return
  else
    reaper.defer(DoIt)
  end
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

    if keyrepeat then
      local state = reaper.JS_VKeys_GetState(0)
      for i = 1, #state do
        local abyte = state:byte(i)
        if abyte and abyte == 1 then -- abyte ~= 0 then
          _held[#_held + 1] = i
          reaper.JS_VKeys_Intercept(i, 1) -- Block the key, else REAPER will run script again.
        end
      end
    end
    return true
  end
  return false
end

function Nudge()
  DoIt()
end


