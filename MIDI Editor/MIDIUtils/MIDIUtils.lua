--[[
   * Author: sockmonkey72 / Jeremy Bernstein
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[

USAGE:

  local s = require 'MIDIUtils' -- however you locate the file, the functions are acquired like this

  if not s.CheckDependencies('My Script') then return end -- return early if something is missing

  local take = reaper.MIDIEditor_GetTake(MIDIEditor_GetActive())
  if not take then return end

  s.MIDI_InitializeTake(take) -- acquire events from take
  s.MIDI_OpenWriteTransaction(take) -- inform the library that we'll be writing to this take (disables sorting)
  s.MIDI_InsertNote(take, true, false, 960, 1920, 0, 64, 64) -- insert a note
  s.MIDI_InsertCC(take, true, false, 960, 0xB0, 0, 1, 64) -- insert a CC (using default CC curve)
  local _, newidx = s.MIDI_InsertCC(take, true, false, 1200, 0xB0, 0, 1, 96) -- insert a CC, get new index (using default CC curve)
  s.MIDI_InsertCC(take, true, false, 1440, 0xB0, 0, 1, 127) -- insert another CC (using default CC curve)
  s.MIDI_SetCCShape(take, newidx, 0, 0) -- change the CC shape of the 2nd CC to square
  s.MIDI_CommitWriteTransaction(take) -- commit the transaction to the take and re-enable sorting

  reaper.MarkTrackItemsDirty(r.GetMediaItemTake_Track(take), r.GetMediaItemTake_Item(take))

  -- 'Read' operations don't require a transaction, and will generally trigger a MIDI_InitializeTake(take)
  --   event slurp if the requested take isn't already in memory.
  -- Function return values, etc. should match the REAPER Reascript API with the exception of MIDI_InsertNote
  --   and MIDI_InsertCC which return the new note/CC index, in addition to a boolean (simplifies adjusting
  --   curves after the fact)
  -- Bezier curves are currently unsupported
  -- Sysex, text, meta events are currently unsupported

--]]

local r = reaper
local MIDIUtils = {}

MIDIUtils.NOTE_TYPE = 0
MIDIUtils.NOTEOFF_TYPE = 1
MIDIUtils.CC_TYPE = 2

local MIDIEvents = {}
local noteCount = 0
local ccCount = 0
local evtCount = 0
local enumNoteIdx = 0
local enumCCIdx = 0
local enumSyxIdx = 0
local enumAllIdx = 0

local MIDIStringTail = ''
local activeTake
local openTransaction

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

MIDIUtils.CheckDependencies = function(scriptName)
  if not r.APIExists('SNM_GetIntConfigVar') then
    r.ShowConsoleMsg(scriptName .. ' requires the \'SWS\' extension (install from https://www.sws-extension.org)\n')
    return false
  end
  return true
end

MIDIUtils.Reset = function()
  MIDIEvents = {}
  noteCount = 0
  ccCount = 0
  evtCount = 0
  enumNoteIdx = 0
  enumCCIdx = 0
  enumSyxIdx = 0
  enumAllIdx = 0
  MIDIStringTail = ''
  activeTake = nil
  openTransaction = nil
end

MIDIUtils.MIDI_InitializeTake = function(take)
  MIDIUtils.MIDI_GetEvents(take)
end

MIDIUtils.MIDI_GetEvents = function(take)
  local ppqTime = 0
  local stringPos = 1
  local noteOns = {}

  local rv, MIDIString = r.MIDI_GetAllEvts(take)
  if rv and MIDIString then
    MIDIUtils.Reset()
    activeTake = take
  end

  while stringPos < MIDIString:len() - 12 do -- -12 to exclude final All-Notes-Off message
    local offset, flags, msg, newStringPos = string.unpack('i4Bs4', MIDIString, stringPos)
    if not (msg and newStringPos) then return false end

    local selected = flags & 1 ~= 0
    local chanmsg = msg:byte(1) & 0xF0
    local chan = msg:byte(1) & 0xF
    local msg2 = msg:byte(2)
    local msg3 = msg:byte(3)

    ppqTime = ppqTime + offset -- current PPQ time for this event

    -- could also index events by stringPos for easier finding later?
    table.insert(MIDIEvents, { MIDI = MIDIString:sub(stringPos, newStringPos - 1), ppqpos = ppqTime, offset = offset, flags = flags, msg = msg })

    if chanmsg >= 0x80 and chanmsg < 0xF0 then -- note & CC events
      local event = MIDIEvents[#MIDIEvents]
      event.chanmsg = chanmsg
      event.chan = chan
      event.msg2 = msg2
      event.msg3 = msg3
      if chanmsg == 0x90 or chanmsg == 0x80 then -- note on/off
        if chanmsg == 0x90 and event.msg3 ~= 0 then -- note on
          event.type = MIDIUtils.NOTE_TYPE
          event.idx = noteCount
          noteCount = noteCount + 1
          event.noteOffIdx = -1
          event.endppqpos = -1
          table.insert(noteOns, { chan = chan, pitch = event.msg2, ppqpos = event.ppqpos, idx = #MIDIEvents })
        else
          event.type = MIDIUtils.NOTEOFF_TYPE
          event.noteOnPos = -1 -- find last noteon for this pitch/chan
          -- sorted iterator, ensure that we get the _first_ note on for this note off
          for k, v in spairs(noteOns, function(t, a, b) return t[a].ppqpos < t[b].ppqpos end) do
            if v.chan == event.chan and v.pitch == event.msg2 then
              local noteon = MIDIEvents[v.idx]
              event.noteOnIdx = v.idx
              noteon.noteOffIdx = #MIDIEvents
              noteon.endppqpos = event.ppqpos
              noteOns[k] = nil -- remove it
              break
            end
          end
        end
      elseif chanmsg >= 0xA0 and chanmsg < 0xF0 then
        event.type = MIDIUtils.CC_TYPE
        event.idx = ccCount
        ccCount = ccCount + 1
      end
    end
    stringPos = newStringPos
  end
  MIDIStringTail = MIDIString:sub(-12)
  return true
end

MIDIUtils.MIDI_OpenWriteTransaction = function(take)
  r.MIDI_DisableSort(take)
  openTransaction = take
end

MIDIUtils.MIDI_CommitWriteTransaction = function(take)
  if not EnsureTransaction(take) then return end
  local newMIDIString = ''
  local ppqPos = 0
  for _, event in ipairs(MIDIEvents) do
    if ppqPos == 0 and event.ppqpos ~= event.offset then event.offset = event.ppqpos end -- special case for first event
    ppqPos = ppqPos + event.offset
    if ppqPos ~= event.ppqpos then
      local offsetEvent = string.pack('i4Bs4', event.ppqpos - ppqPos, 0, '')
      newMIDIString = newMIDIString .. offsetEvent
      ppqPos = event.ppqpos
    end
    if event.delete then
      event.MIDI = string.pack('i4Bs4', event.offset, 0, '')
    elseif event.recalc then
      local b1 = string.char(event.chanmsg | event.chan)
      local b2 = string.char(event.msg2)
      local b3 = string.char(event.msg3)
      event.msg = table.concat({ b1, b2, b3 })
      event.MIDI = string.pack('i4Bs4', event.offset, event.flags, event.msg)
    end
    newMIDIString = newMIDIString .. event.MIDI
  end

  for _, event in ipairs(MIDIEvents) do
    if event.type == MIDIUtils.NOTE_TYPE then
      if not event.noteOffIdx or not MIDIEvents[event.noteOffIdx] or MIDIEvents[event.noteOffIdx].msg2 ~= event.msg2 or event.delete ~= MIDIEvents[event.noteOffIdx].delete then
        r.ShowConsoleMsg('missing note off\n')
      end
    end
  end

  r.MIDI_SetAllEvts(take, newMIDIString .. MIDIStringTail)
  r.MIDI_Sort(take)
  openTransaction = nil
end

function EnsureTake(take)
  if take ~= activeTake then
    MIDIUtils.MIDI_GetEvents(take)
    activeTake = take
  end
end

function EnsureTransaction(take)
  if openTransaction ~= take then
    r.ShowConsoleMsg('MIDIUtils: cannot modify MIDI stream without an open WRITE transaction for this take\n')
    return false
  end
  return true
end

MIDIUtils.MIDI_CountEvts = function(take)
  EnsureTake(take)
  return true, noteCount, ccCount, evtCount
end

MIDIUtils.MIDI_GetNote = function(take, idx)
  EnsureTake(take)
  for _, event in ipairs(MIDIEvents) do
    if event.type == MIDIUtils.NOTE_TYPE and event.idx == idx then
      return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false,
        event.ppqpos, event.endppqpos, event.chan, event.msg2, event.msg3
    end
  end
  return false
end

local function MIDI_AdjustNoteOff(noteoff, param, val)
  noteoff[param] = val
  noteoff.recalc = true
end

MIDIUtils.MIDI_SetNote = function(take, idx, selected, muted, ppqpos, endppqpos, chan, pitch, vel)
  if not EnsureTransaction(take) then return end
  local rv = false
  for i, event in ipairs(MIDIEvents) do
    if event.type == MIDIUtils.NOTE_TYPE and event.idx == idx then
      local noteoff = MIDIEvents[event.noteOffIdx]
      if not noteoff then r.ShowConsoleMsg('not noteoff in setnote\n') end

      if selected then
        if selected ~= 0 then event.flags = event.flags | 1
        else event.flags = event.flags & ~1 end
        MIDI_AdjustNoteOff(noteoff, 'selected', event.flags)
      end
      if muted then
        if muted ~= 0 then event.flags = event.flags | 2
        else event.flags = event.flags & ~2 end
        MIDI_AdjustNoteOff(noteoff, 'muted', event.flags)
      end
      if ppqpos then
        local diff = ppqpos - event.ppqpos
        event.ppqpos = ppqpos -- bounds checking?
        MIDI_AdjustNoteOff(noteoff, 'ppqpos', noteoff.ppqpos + diff)
      end
      if endppqpos then
        MIDI_AdjustNoteOff(noteoff, 'ppqpos', endppqpos)
      end
      if chan then
        event.chan = chan > 15 and 15 or chan < 0 and 0 or chan
        MIDI_AdjustNoteOff(noteoff, 'chan', event.chan)
      end
      if pitch then
        event.msg2 = pitch > 127 and 127 or pitch < 0 and 0 or pitch
        MIDI_AdjustNoteOff(noteoff, 'msg2', event.msg2)
      end
      if vel then
        event.msg3 = vel > 127 and 127 or vel < 1 and 1 or vel
      end
      event.recalc = true
      rv = true
      break
    end
  end
  return rv
end

MIDIUtils.MIDI_GetCC = function(take, idx)
  EnsureTake(take)
  for _, event in ipairs(MIDIEvents) do
    if event.type == MIDIUtils.CC_TYPE and event.idx == idx then
      return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false,
        event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3
    end
  end
  return false
end

MIDIUtils.MIDI_SetCC = function(take, idx, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
  if not EnsureTransaction(take) then return false end
  local rv = false
  for i, event in ipairs(MIDIEvents) do
    if event.type == MIDIUtils.CC_TYPE and event.idx == idx then
      if selected then
        if selected ~= 0 then event.flags = event.flags | 1
        else event.flags = event.flags & ~1 end
      end
      if muted then
        if muted ~= 0 then event.flags = event.flags | 2
        else event.flags = event.flags & ~2 end
      end
      if ppqpos then
        local diff = ppqpos - event.ppqpos
        event.ppqpos = ppqpos -- bounds checking?
      end
      if chanmsg then
        event.chanmsg = chanmsg < 0xA0 or chanmsg >= 0xF0 and 0xB0 or chanmsg
      end
      if chan then
        event.chan = chan > 15 and 15 or chan < 0 and 0 or chan
      end
      if msg2 then
        event.msg2 = msg2 > 127 and 127 or msg2 < 0 and 0 or msg2
      end
      if msg3 then
        event.msg3 = msg3 > 127 and 127 or msg3 < 1 and 1 or msg3
      end
      event.recalc = true
      rv = true
      break
    end
  end
  return rv
end

MIDIUtils.MIDI_GetCCShape = function(take, idx)
  EnsureTake(take)
  for _, v in ipairs(MIDIEvents) do
    if v.type == MIDIUtils.CC_TYPE and v.idx == idx then
      return true, ((v.flags & 0xF0) >> 4) & 7, 0.
    end
  end
  return false
end

MIDIUtils.MIDI_SetCCShape = function(take, idx, shape, beztension)
  EnsureTransaction(take)
  for _, v in ipairs(MIDIEvents) do
    if v.type == MIDIUtils.CC_TYPE and v.idx == idx then
      v.flags = v.flags & ~0xF0
      -- flag high 4 bits for CC shape: &16=linear, &32=slow start/end, &16|32=fast start, &64=fast end, &64|16=bezier
      v.flags = v.flags | ((shape & 0x7) << 4)
      v.recalc = true
      if beztension and beztension ~= 0 then
        -- write this to an auxilliary table and insert on commit
        r.ShowConsoleMsg('MIDI_SetCCShape: bezier tension is not yet supported\n')
      end
      return true
    end
  end
  return false
end

MIDIUtils.MIDI_SetEvt = function(take, idx, selected, muted, ppqpos, msg)
  r.ShowConsoleMsg('MIDI_SetEvt is not yet supported\n')
  return false
end

MIDIUtils.MIDI_EnumSelNotes = function(take, idx)
  EnsureTake(take)
  if idx < 0 then enumNoteIdx = 0 end
  for i = enumNoteIdx > 0 and enumNoteIdx + 1 or 1, #MIDIEvents do
    local event = MIDIEvents[i]
    if event.type == MIDIUtils.NOTE_TYPE and event.flags & 1 ~= 0 then
      enumNoteIdx = i
      return event.idx
    end
  end
  enumNoteIdx = 0
  return -1
end

MIDIUtils.MIDI_EnumSelCC = function(take, idx)
  EnsureTake(take)
  if idx == -1 then enumCCIdx = 0 end
  for i = enumCCIdx > 0 and enumCCIdx + 1 or 1, #MIDIEvents do
    local event = MIDIEvents[i]
    if event.type == MIDIUtils.CC_TYPE and event.flags & 1 ~= 0 then
      enumCCIdx = i
      return event.idx
    end
  end
  enumCCIdx = 0
  return -1
end

MIDIUtils.MIDI_EnumSelEvts = function(take, idx)
  r.ShowConsoleMsg('MIDI_EnumSelEvts is not yet supported\n')
  return -1
end

MIDIUtils.MIDI_EnumSelTextSysexEvts = function(take, idx)
  r.ShowConsoleMsg('MIDI_EnumSelTextSysexEvts is not yet supported\n')
  return -1
end

MIDIUtils.MIDI_DeleteNote = function(take, idx)
  if not EnsureTransaction(take) then return end
  for _, v in ipairs(MIDIEvents) do
    if v.type == MIDIUtils.NOTE_TYPE and v.idx == idx then
      v.delete = true
      MIDIEvents[v.noteOffIdx].delete = true
      return true
    end
  end
  return false
end

MIDIUtils.MIDI_DeleteCC = function(take, idx)
  if not EnsureTransaction(take) then return end
  for _, v in ipairs(MIDIEvents) do
    if v.type == MIDIUtils.CC_TYPE and v.idx == idx then
      v.delete = true
      return true
    end
  end
  return false
end

MIDIUtils.MIDI_DeleteEvt = function(take, idx)
  r.ShowConsoleMsg('MIDI_DeleteEvt is not yet supported\n')
  return false
end

MIDIUtils.MIDI_InsertNote = function(take, selected, muted, ppqpos, endppqpos, chan, pitch, vel)
  if not EnsureTransaction(take) then return end
  local lastEvent = MIDIEvents[#MIDIEvents]
  local newNoteOn = {
    type = MIDIUtils.NOTE_TYPE,
    offset = ppqpos - (lastEvent and lastEvent.ppqpos or 0),
    flags = selected and muted and 3 or selected and 1 or muted and 2 or 0,
    ppqpos = ppqpos,
    endppqpos = endppqpos,
    chanmsg = 0x90,
    chan = chan,
    msg2 = pitch,
    msg3 = vel,
    idx = noteCount,
    noteOffIdx = -1
  }
  noteCount = noteCount + 1
  newNoteOn.chan = newNoteOn.chan & 0xF
  newNoteOn.msg2 = newNoteOn.msg2 & 0x7F
  newNoteOn.msg3 = newNoteOn.msg3 & 0x7F
  newNoteOn.msg = table.concat({
    string.char(newNoteOn.chanmsg | newNoteOn.chan),
    string.char(newNoteOn.msg2),
    string.char(newNoteOn.msg3)
  })
  newNoteOn.MIDI = string.pack('i4Bs4', newNoteOn.offset, newNoteOn.flags, newNoteOn.msg)
  table.insert(MIDIEvents, newNoteOn)

  local newNoteOff = {
    type = MIDIUtils.NOTEOFF_TYPE,
    offset = endppqpos - ppqpos,
    flags = newNoteOn.flags,
    ppqpos = endppqpos,
    chanmsg = 0x80,
    chan = newNoteOn.chan,
    msg2 = newNoteOn.msg2,
    msg3 = 0,
    noteOnIdx = #MIDIEvents
  }
  newNoteOff.msg = table.concat({
    string.char(newNoteOff.chanmsg | newNoteOff.chan),
    string.char(newNoteOff.msg2),
    string.char(newNoteOff.msg3)
  })
  newNoteOff.MIDI = string.pack('i4Bs4', newNoteOff.offset, newNoteOff.flags, newNoteOff.msg)
  table.insert(MIDIEvents, newNoteOff)

  newNoteOn.noteOffIdx = #MIDIEvents

  return true, newNoteOn.idx
end

MIDIUtils.MIDI_InsertCC = function(take, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
  if not EnsureTransaction(take) then return end
  local lastEvent = MIDIEvents[#MIDIEvents]
  local newCC = {
    type = MIDIUtils.CC_TYPE,
    offset = ppqpos - lastEvent.ppqpos,
    flags = selected and muted and 3 or selected and 1 or muted and 2 or 0,
    ppqpos = ppqpos,
    chanmsg = chanmsg,
    chan = chan,
    msg2 = msg2,
    msg3 = msg3,
    idx = ccCount
  }
  ccCount = ccCount + 1

  local defaultCCShape = r.SNM_GetIntConfigVar('midiccenv', -1)
  if defaultCCShape ~= 0 then
    defaultCCShape = defaultCCShape & 7
    if defaultCCShape >= 0 and defaultCCShape <= 5 then
      newCC.flags = newCC.flags | (defaultCCShape << 4)
    end
  end

  newCC.chanmsg = newCC.chanmsg < 0xA0 or newCC.chanmsg >= 0xF0 and 0xB0 or newCC.chanmsg
  newCC.chan = newCC.chan & 0xF
  newCC.msg2 = newCC.msg2 & 0x7F
  newCC.msg3 = newCC.msg3 & 0x7F

  newCC.msg = table.concat({
    string.char(newCC.chanmsg | newCC.chan),
    string.char(newCC.msg2),
    string.char(newCC.msg3)
  })
  newCC.MIDI = string.pack('i4Bs4', newCC.offset, newCC.flags, newCC.msg)
  table.insert(MIDIEvents, newCC)
  return true, newCC.idx
end

MIDIUtils.MIDI_InsertTextSysexEvt = function(take, selected, muted, ppqpos, type, bytestr)
  r.ShowConsoleMsg('MIDI_InsertTextSysexEvt is not yet supported\n')
  return false
end

return MIDIUtils