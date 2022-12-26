--[[
   * Author: sockmonkey72 / Jeremy Bernstein
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[

USAGE:

  -- get the package path to MIDIUtils in my repository
  package.path = reaper.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI Editor/MIDIUtils/?.lua'
  local mu = require 'MIDIUtils'
  mu.ENFORCE_ARGS = false -- true by default, enabling argument type-checking, turn off for 'production' code

  if not mu.CheckDependencies('My Script') then return end -- return early if something is missing

  local take = reaper.MIDIEditor_GetTake(MIDIEditor_GetActive())
  if not take then return end

  mu.MIDI_InitializeTake(take) -- acquire events from take (can pass true/false as 2nd arg to enable/disable ENFORCE_ARGS)
  mu.MIDI_OpenWriteTransaction(take) -- inform the library that we'll be writing to this take
  mu.MIDI_InsertNote(take, true, false, 960, 1920, 0, 64, 64) -- insert a note
  mu.MIDI_InsertCC(take, true, false, 960, 0xB0, 0, 1, 64) -- insert a CC (using default CC curve)
  local _, newidx = mu.MIDI_InsertCC(take, true, false, 1200, 0xB0, 0, 1, 96) -- insert a CC, get new index (using default CC curve)
  mu.MIDI_InsertCC(take, true, false, 1440, 0xB0, 0, 1, 127) -- insert another CC (using default CC curve)
  mu.MIDI_SetCCShape(take, newidx, 5, 0.66) -- change the CC shape of the 2nd CC to bezier with a 0.66 tension
  mu.MIDI_CommitWriteTransaction(take) -- commit the transaction to the take
                                      -- by default, this won't reacquire the MIDI events and update the
                                      -- take data in memory, pass 'true' as a 2nd argument if you want that

  reaper.MarkTrackItemsDirty(r.GetMediaItemTake_Track(take), r.GetMediaItemTake_Item(take))

  -- API 'Write' operations don't write back to REAPER until MIDI_CommitWriteTransaction() is called.
  -- API 'Read' operations are based on the data in memory, not the data in the take. If updates are
  --   potentially occuring in REAPER 'behind the back' of the API (such as in a defer script), call
  --   MIDI_InitializeTake() every frame, or whenever you need to resync the in-memory data with the
  --   actual state of the take in REAPER.
  -- 'Read' operations don't require a transaction, and will generally trigger a MIDI_InitializeTake(take)
  --   event slurp if the requested take isn't already in memory.
  -- Function return values, etc. should match the REAPER Reascript API with the exception of the MIDI_InsertXXX
  --   functions, which return the new note/CC index, in addition to a boolean (simplifies adjusting
  --   curves after the fact, for instance)

--]]

local r = reaper
local MIDIUtils = {}

MIDIUtils.ENFORCE_ARGS = true -- turn off for efficiency

local NOTE_TYPE = 0
local NOTEOFF_TYPE = 1
local CC_TYPE = 2
local SYSEX_TYPE = 3
local META_TYPE = 4
local OTHER_TYPE = 5

local MIDIEvents = {}
local bezTable = {}

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

MIDIUtils.CheckDependencies = function(scriptName)
  if not r.APIExists('SNM_GetIntConfigVar') then
    r.ShowConsoleMsg(scriptName .. ' requires the \'SWS\' extension (install from https://www.sws-extension.org)\n')
    return false
  end
  return true
end

-----------------------------------------------------------------------------
-------------------------------- UTILITIES ----------------------------------

local function post(...)
  local args = {...}
  local str = ''
  for i, v in ipairs(args) do
    str = str .. (i ~= 1 and ', ' or '') .. tostring(v)
  end
  str = str .. '\n'
  r.ShowConsoleMsg(str)
end

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

-----------------------------------------------------------------------------
------------------------------- ARG CHECKING --------------------------------

-- Print contents of `tbl`, with indentation.
-- `indent` sets the initial level of indentation.
local function tprint (tbl, indent)
  if not indent then indent = 0 end
  for k, v in pairs(tbl) do
    local formatting = string.rep("  ", indent) .. k .. ": "
    if type(v) == "table" then
      post(formatting)
      tprint(v, indent+1)
    elseif type(v) == 'boolean' then
      post(formatting .. tostring(v))
    else
      post(formatting .. v)
    end
  end
end

function EnforceArgs(...)
  if not MIDIUtils.ENFORCE_ARGS then return true end
  local fnName = debug.getinfo(2).name
  local args = table.pack(...)
  for i = 1, args.n do
    if args[i].val == nil and not args[i].optional then
      error(fnName..': invalid or missing argument #'..i, 3)
      return false
    elseif type(args[i].val) ~= args[i].type and not args[i].optional then
      error(fnName..': bad type for argument #'..i..
        ', expected \''..args[i].type..'\', got \''..type(args[i].val)..'\'', 3)
      return false
    elseif args[i].reapertype and not r.ValidatePtr(args[i].val, args[i].reapertype) then
      error(fnName..': bad type for argument #'..i..
        ', expected \''..args[i].reapertype..'\'', 3)
      return false
    end
  end
  return true
end

function MakeTypedArg(val, type, optional, reapertype)
  if not MIDIUtils.ENFORCE_ARGS then return {} end
  local typedArg = {
    type = type,
    val = val,
    optional = optional
  }
  if reapertype then typedArg.reapertype = reapertype end
  return typedArg
end

-----------------------------------------------------------------------------
---------------------------------- BASICS -----------------------------------

function EnsureTake(take)
  if take ~= activeTake then
    MIDIUtils.MIDI_GetEvents(take)
    activeTake = take
  end
end

function EnsureTransaction(take)
  if openTransaction ~= take then
    post('MIDIUtils: cannot modify MIDI stream without an open WRITE transaction for this take')
    return false
  end
  return true
end

-----------------------------------------------------------------------------
------------------------------------ API ------------------------------------

MIDIUtils.MIDI_InitializeTake = function(take, enforceargs)
  if enforceargs ~= nil then MIDIUtils.ENFORCE_ARGS = enforceargs end
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(enforceargs, 'boolean', true)
  )
  MIDIUtils.MIDI_GetEvents(take)
end

-----------------------------------------------------------------------------
----------------------------------- PARSE -----------------------------------

local function Reset()
  MIDIEvents = {}
  bezTable = {}
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

MIDIUtils.MIDI_GetEvents = function(take)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*')
  )
  local ppqTime = 0
  local stringPos = 1
  local noteOns = {}

  local rv, MIDIString = r.MIDI_GetAllEvts(take)
  if rv and MIDIString then
    Reset()
    activeTake = take
  end

  while stringPos < MIDIString:len() - 12 do -- -12 to exclude final All-Notes-Off message
    local offset, flags, msg, newStringPos = string.unpack('i4Bs4', MIDIString, stringPos)
    if not (msg and newStringPos) then return false end

    local selected = flags & 1 ~= 0
    local msg1 = msg:byte(1)
    local chanmsg = msg1 & 0xF0
    local chan = msg1 & 0xF
    local msg2 = msg:byte(2)
    local msg3 = msg:byte(3)

    ppqTime = ppqTime + offset -- current PPQ time for this event

    table.insert(MIDIEvents, { MIDI = MIDIString:sub(stringPos, newStringPos - 1), ppqpos = ppqTime, offset = offset, flags = flags, msg = msg })

    local event = MIDIEvents[#MIDIEvents]
    if chanmsg >= 0x80 and chanmsg < 0xF0 then -- note & CC events
      event.chanmsg = chanmsg
      event.chan = chan
      event.msg2 = msg2
      event.msg3 = msg3
      if chanmsg == 0x90 or chanmsg == 0x80 then -- note on/off
        if chanmsg == 0x90 and event.msg3 ~= 0 then -- note on
          event.type = NOTE_TYPE
          event.idx = noteCount
          noteCount = noteCount + 1
          event.noteOffIdx = -1
          event.endppqpos = -1
          table.insert(noteOns, { chan = chan, pitch = event.msg2, flags = flags, ppqpos = event.ppqpos, index = #MIDIEvents })
        else
          event.type = NOTEOFF_TYPE
          event.noteOnIdx = -1
          -- sorted iterator, ensure that we get the _first_ note on for this note off
          for k, v in spairs(noteOns, function(t, a, b) return t[a].ppqpos < t[b].ppqpos end) do
            if v.chan == event.chan and v.pitch == event.msg2 and v.flags == event.flags then
              local noteon = MIDIEvents[v.index]
              event.noteOnIdx = v.idx
              noteon.noteOffIdx = #MIDIEvents
              noteon.endppqpos = event.ppqpos
              noteOns[k] = nil -- remove it
              break
            end
          end
        end
      elseif chanmsg >= 0xA0 and chanmsg < 0xF0 then
        event.type = CC_TYPE
        event.idx = ccCount
        ccCount = ccCount + 1
      end
    elseif msg1 == 0xF0 then
      event.type = SYSEX_TYPE
      event.idx = evtCount
      evtCount = evtCount + 1
    elseif msg1 == 0xFF then
      event.type = META_TYPE
      event.idx = evtCount
      event.chanmsg = 0xFF
      event.msg2 = event.msg:byte(2) -- 1-14=text, 15='reaper notation' or bezier
      evtCount = evtCount + 1
    else
      event.type = OTHER_TYPE
      event.idx = evtCount
      event.chanmsg = 0
      evtCount = evtCount + 1
    end
    stringPos = newStringPos
  end
  MIDIStringTail = MIDIString:sub(-12)
  return true
end

local function getEventMIDIString(event)
  local str = event.msg
  if event.type == SYSEX_TYPE then
    str = table.concat({
      string.char(0xF0),
      event.msg,
      string.char(0xF7)
    })
  end
  return str
end

MIDIUtils.MIDI_CountEvts = function(take)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*')
  )
  EnsureTake(take)
  return true, noteCount, ccCount, evtCount
end

MIDIUtils.MIDI_CountAllEvts = function(take)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*')
  )
  EnsureTake(take)
  return #MIDIEvents
end

-----------------------------------------------------------------------------
------------------------------- TRANSACTIONS --------------------------------

MIDIUtils.MIDI_OpenWriteTransaction = function(take)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*')
  )
  EnsureTake(take)
  openTransaction = take
end

MIDIUtils.MIDI_CommitWriteTransaction = function(take, refresh)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(refresh, 'boolean', true)
  )
  if not EnsureTransaction(take) then return false end

  local newMIDIString = ''
  local ppqPos = 0
  for k, event in ipairs(MIDIEvents) do
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
      local MIDIStr = ''
      if event.type == NOTE_TYPE or event.type == NOTEOFF_TYPE or event.type == CC_TYPE then
        local b1 = string.char(event.chanmsg | event.chan)
        local b2 = string.char(event.msg2)
        local b3 = string.char(event.msg3)
        event.msg = table.concat({ b1, b2, b3 })
        MIDIStr = event.msg
      elseif event.type == SYSEX_TYPE or event.type == META_TYPE then
        MIDIStr = getEventMIDIString(event)
      elseif event.type == OTHER_TYPE then
        MIDIStr = event.msg -- not sure what to do here, there don't appear to really be OTHER_TYPE events in the wild
      end
      event.MIDI = string.pack('i4Bs4', event.offset, event.flags, MIDIStr)
    end
    newMIDIString = newMIDIString .. event.MIDI

    -- only do this if the bezEvent is in the aux table, otherwise we'll get it on the next loop
    if event.type == CC_TYPE and event.bezIdx and event.bezIdx < 0 then
      local bezIdx = math.abs(event.bezIdx)
      if bezIdx <= #bezTable then
        local bezEvent = bezTable[bezIdx]
        if bezEvent and bezEvent.ccPos == k then
          local bezString = bezEvent.MIDI --string.pack('i4Bs4', bezEvent.offset, bezEvent.flags, bezEvent.msg)
          newMIDIString = newMIDIString .. bezString
        end
      end
    end

  end

  r.MIDI_DisableSort(take)
  r.MIDI_SetAllEvts(take, newMIDIString .. MIDIStringTail)
  r.MIDI_Sort(take)
  openTransaction = nil

  if refresh then MIDIUtils.MIDI_InitializeTake(take) end -- update the tables based on the new data
  return true
end

-----------------------------------------------------------------------------
----------------------------------- NOTES -----------------------------------

MIDIUtils.MIDI_GetNote = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  EnsureTake(take)
  for _, event in ipairs(MIDIEvents) do
    if event.type == NOTE_TYPE and event.idx == idx then
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
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number'),
    MakeTypedArg(selected, 'boolean', true),
    MakeTypedArg(muted, 'boolean', true),
    MakeTypedArg(ppqpos, 'number', true),
    MakeTypedArg(endppqpos, 'number', true),
    MakeTypedArg(chan, 'number', true),
    MakeTypedArg(pitch, 'number', true),
    MakeTypedArg(vel, 'number', true)
  )
  if not EnsureTransaction(take) then return false end
  local rv = false
  for _, event in ipairs(MIDIEvents) do
    if event.type == NOTE_TYPE and event.idx == idx then
      local noteoff = MIDIEvents[event.noteOffIdx]
      --if not noteoff then r.ShowConsoleMsg('not noteoff in setnote\n') end

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

MIDIUtils.MIDI_InsertNote = function(take, selected, muted, ppqpos, endppqpos, chan, pitch, vel)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(selected, 'boolean'),
    MakeTypedArg(muted, 'boolean'),
    MakeTypedArg(ppqpos, 'number'),
    MakeTypedArg(endppqpos, 'number'),
    MakeTypedArg(chan, 'number'),
    MakeTypedArg(pitch, 'number'),
    MakeTypedArg(vel, 'number')
  )

  if not EnsureTransaction(take) then return false end
  local lastEvent = MIDIEvents[#MIDIEvents]
  local newNoteOn = {
    type = NOTE_TYPE,
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
    type = NOTEOFF_TYPE,
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

MIDIUtils.MIDI_DeleteNote = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  if not EnsureTransaction(take) then return false end
  for _, event in ipairs(MIDIEvents) do
    if event.type == NOTE_TYPE and event.idx == idx then
      event.delete = true
      MIDIEvents[event.noteOffIdx].delete = true
      return true
    end
  end
  return false
end

-----------------------------------------------------------------------------
---------------------------------- BEZIER -----------------------------------

local function findBezierData(idx, event)
  local bezEvent
  local bezIdx = idx + 1
  if event.type == CC_TYPE and bezIdx <= #MIDIEvents then
    bezEvent = MIDIEvents[bezIdx]
  end
  if not (bezEvent and bezEvent.type == META_TYPE and bezEvent.msg2 == 0xF) then
    bezEvent = nil
    for k, v in ipairs(bezTable) do
      if v.ccIdx == idx then
        bezEvent = v
        bezIdx = -k
        break
      end
    end
  end
  if bezEvent then return true, bezEvent, bezIdx
  else return false
  end
end

local function getBezierData(idx, event)
  local rv, bezEvent = findBezierData(idx, event)
  if rv and bezEvent then
    local metadata = string.sub(bezEvent.msg, 3)
    if string.sub(metadata, 1, 5) == 'CCBZ ' then
      local beztype = metadata:byte(6)
      local beztension = string.unpack('f', string.sub(metadata, 7))
      return true, beztype, beztension
    end
  end
  return false
end

local function setBezierData(idx, event, beztype, beztension)
  local rv, bezEvent, bezIdx = findBezierData(idx, event)
  if not rv then
    bezEvent = {
      type = META_TYPE,
      ppqpos = event.ppqpos,
      chanmsg = 0xFF,
      chan = 0,
      msg2 = 0xF,
      msg3 = 0,
      offset = 0,
      flags = 0,
      ccPos = idx,
      msg = nil,
      MIDI = nil
    }
    table.insert(bezTable, bezEvent)
    bezIdx = -(#bezTable)
  end

  if bezEvent then
    bezEvent.msg = table.concat({
      string.char(0xFF),
      string.char(0xF),
      'CCBZ ',
      string.char(beztype), -- should be 0
      string.pack('f', beztension)
    })
    bezEvent.MIDI = string.pack('i4Bs4', bezEvent.offset, bezEvent.flags, bezEvent.msg)
    event.bezIdx = bezIdx -- negative in aux table, positive in MIDIEvents
    return true
  end
  return false
end

local function deleteBezierData(idx, event)
  local rv, bezEvent, bezIdx = findBezierData(idx, event)
  if rv and bezEvent and bezIdx then
    rv = false
    if bezIdx > 0 then bezEvent.delete = true
    elseif bezIdx < 0 then
      bezIdx = math.abs(bezIdx)
      for _, event in ipairs(MIDIEvents) do
        if event.type == CC_TYPE and event.idx == bezEvent.ccIdx and event.bezIdx == bezIdx then
          event.bezIdx = nil
          table.remove(bezTable, bezIdx)
          rv = true
          break
        end
      end
    end
  end
  return rv
end

-----------------------------------------------------------------------------
------------------------------------ CCS ------------------------------------

MIDIUtils.MIDI_GetCC = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  EnsureTake(take)
  for _, event in ipairs(MIDIEvents) do
    if event.type == CC_TYPE and event.idx == idx then
      return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false,
        event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3
    end
  end
  return false
end

MIDIUtils.MIDI_SetCC = function(take, idx, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number'),
    MakeTypedArg(selected, 'boolean', true),
    MakeTypedArg(muted, 'boolean', true),
    MakeTypedArg(ppqpos, 'number', true),
    MakeTypedArg(chanmsg, 'number', true),
    MakeTypedArg(chan, 'number', true),
    MakeTypedArg(msg2, 'number', true),
    MakeTypedArg(msg3, 'number', true)
  )
  if not EnsureTransaction(take) then return false end
  local rv = false
  for i, event in ipairs(MIDIEvents) do
    if event.type == CC_TYPE and event.idx == idx then
      if selected then
        if selected ~= 0 then event.flags = event.flags | 1
        else event.flags = event.flags & ~1 end
      end
      if muted then
        if muted ~= 0 then event.flags = event.flags | 2
        else event.flags = event.flags & ~2 end
      end
      if ppqpos then
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
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  EnsureTake(take)
  for k, event in ipairs(MIDIEvents) do
    if event.type == CC_TYPE and event.idx == idx then
      local rv, _, bztension = getBezierData(k, event)
      return true, ((event.flags & 0xF0) >> 4) & 7, rv and bztension or 0.
    end
  end
  return false
end

MIDIUtils.MIDI_SetCCShape = function(take, idx, shape, beztension)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number'),
    MakeTypedArg(shape, 'number'),
    MakeTypedArg(beztension, 'number', true)
  )
  EnsureTransaction(take)
  for k, event in ipairs(MIDIEvents) do
    if event.type == CC_TYPE and event.idx == idx then
      event.flags = event.flags & ~0xF0
      -- flag high 4 bits for CC shape: &16=linear, &32=slow start/end, &16|32=fast start, &64=fast end, &64|16=bezier
      event.flags = event.flags | ((shape & 0x7) << 4)
      event.recalc = true
      if shape == 5 and beztension then
        return setBezierData(k, event, 0, beztension)
      else
        deleteBezierData(k, event)
      end
      return true
    end
  end
  return false
end

MIDIUtils.MIDI_InsertCC = function(take, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(selected, 'boolean'),
    MakeTypedArg(muted, 'boolean'),
    MakeTypedArg(ppqpos, 'number'),
    MakeTypedArg(chanmsg, 'number'),
    MakeTypedArg(chan, 'number'),
    MakeTypedArg(msg2, 'number'),
    MakeTypedArg(msg3, 'number')
  )

  if not EnsureTransaction(take) then return false end
  local lastEvent = MIDIEvents[#MIDIEvents]
  local newCC = {
    type = CC_TYPE,
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

MIDIUtils.MIDI_DeleteCC = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  if not EnsureTransaction(take) then return false end
  for _, event in ipairs(MIDIEvents) do
    if event.type == CC_TYPE and event.idx == idx then
      event.delete = true
      return true
    end
  end
  return false
end

-----------------------------------------------------------------------------
-------------------------------- TEXT / SYSEX -------------------------------

MIDIUtils.MIDI_GetTextSysexEvt = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  EnsureTake(take)
  for _, event in ipairs(MIDIEvents) do
    if (event.type == SYSEX_TYPE or event.type == META_TYPE or event.type == OTHER_TYPE) and event.idx == idx then
      return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false, event.ppqpos,
      event.chanmsg == 0xF0 and -1 or event.chanmsg == 0xFF and event.msg2 or -2, event.msg
    end
  end
  return false
end

function purifyMsg(event, msg)
  if event.type == SYSEX_TYPE then
    if msg:byte(1) == 0xF0 then msg = string.sub(msg, 2) end
    if msg:byte(msg:len()) == 0xF7 then msg = string.sub(msg, 1, -2) end
  end
  return msg
end

MIDIUtils.MIDI_SetTextSysexEvt = function(take, idx, selected, muted, ppqpos, type, msg)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number'),
    MakeTypedArg(selected, 'boolean', true),
    MakeTypedArg(muted, 'boolean', true),
    MakeTypedArg(ppqpos, 'number', true),
    MakeTypedArg(type, 'number', true),
    MakeTypedArg(msg, 'string', true)
  )
  if not EnsureTransaction(take) then return false end
  local rv = false
  for _, event in ipairs(MIDIEvents) do
    if (event.type == SYSEX_TYPE or event.type == META_TYPE or event.type == OTHER_TYPE) and event.idx == idx then
      if selected then
        if selected ~= 0 then event.flags = event.flags | 1
        else event.flags = event.flags & ~1 end
      end
      if muted then
        if muted ~= 0 then event.flags = event.flags | 2
        else event.flags = event.flags & ~2 end
      end
      if ppqpos then
        event.ppqpos = ppqpos
      end
      if type then
        local type = type
        event.chanmsg = type == -1 and 0xF0 or (type >= 1 and type <= 15) and 0xFF or 0
      end
      if msg then
        event.msg = purifyMsg(event, msg)
      end
      event.recalc = true
      rv = true
      break
    end
  end
  return rv
end

MIDIUtils.MIDI_InsertTextSysexEvt = function(take, selected, muted, ppqpos, type, bytestr)
  if not EnsureTransaction(take) then return false end
  local lastEvent = MIDIEvents[#MIDIEvents]
  local newTextSysex = {
    type = type == -1 and SYSEX_TYPE or (type >= 1 and type <= 15) and META_TYPE or OTHER_TYPE,
    offset = ppqpos - lastEvent.ppqpos,
    flags = selected and muted and 3 or selected and 1 or muted and 2 or 0,
    ppqpos = ppqpos,
    chan = 0,
    msg2 = 0,
    msg3 = 0,
    idx = evtCount
  }
  evtCount = evtCount + 1
  newTextSysex.msg = purifyMsg(newTextSysex, bytestr)
  newTextSysex.chanmsg = newTextSysex.type == SYSEX_TYPE and 0xF0 or newTextSysex.type == META_TYPE and 0xFF or 0

  if newTextSysex.type == SYSEX_TYPE then
    local msg = bytestr
    if msg:byte(1) == 0xF0 then msg = string.sub(msg, 2) end
    if msg:byte(msg:len()) == 0xF7 then msg = string.sub(msg, 1, -2) end
    newTextSysex.msg = msg
  end

  local MIDIStr = getEventMIDIString(newTextSysex)
  newTextSysex.MIDI = string.pack('i4Bs4', newTextSysex.offset, newTextSysex.flags, MIDIStr)
  table.insert(MIDIEvents, newTextSysex)
  return true, newTextSysex.idx
end

MIDIUtils.MIDI_DeleteTextSysexEvt = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  if not EnsureTransaction(take) then return false end
  for i, event in ipairs(MIDIEvents) do
    if (event.type == SYSEX_TYPE or event.type == META_TYPE or event.type == OTHER_TYPE) and event.idx == idx then
      event.delete = true
      return true
    end
  end
  return false
end

-----------------------------------------------------------------------------
------------------------------------ EVTS -----------------------------------

-- these operate just on the raw index into the array, not based on type
MIDIUtils.MIDI_GetEvt = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  EnsureTake(take)
  if idx >= 1 and idx <= #MIDIEvents then
    local event = MIDIEvents[idx]
    if event then
      return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false, event.ppqpos, event.msg
    end
  end
  return false
end

local function typeFromBytes(b1, b2)
  local type = b1 == 0xFF and META_TYPE
    or b1 <= 0x7F and SYSEX_TYPE
    or (b1 >= 0x90 and b1 < 0xA0 and b2 ~= 0) and NOTE_TYPE
    or (b1 >= 0x80 and b1 < 0xA0) and NOTEOFF_TYPE
    or (b1 >= 0xA0 and b1 < 0xF0) and CC_TYPE
    or OTHER_TYPE
  return type
end

MIDIUtils.MIDI_SetEvt = function(take, idx, selected, muted, ppqpos, msg)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number'),
    MakeTypedArg(selected, 'boolean', true),
    MakeTypedArg(muted, 'boolean', true),
    MakeTypedArg(ppqpos, 'number', true),
    MakeTypedArg(msg, 'string', true)
  )
  if not EnsureTransaction(take) then return false end
  if idx >= 1 and idx <= #MIDIEvents then
    local event = MIDIEvents[idx]
    if event then
      if selected then
        if selected ~= 0 then event.flags = event.flags | 1
        else event.flags = event.flags & ~1 end
      end
      if muted then
        if muted ~= 0 then event.flags = event.flags | 2
        else event.flags = event.flags & ~2 end
      end
      if ppqpos then
        event.ppqpos = ppqpos
      end
      if msg then
        event.type = typeFromBytes(msg:byte(1), msg:byte(2))
        event.msg = purifyMsg(event, msg)
      end
      event.recalc = true
      return true
    end
  end
  return false
end

MIDIUtils.MIDI_DeleteEvt = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  if not EnsureTransaction(take) then return false end
  if idx >= 1 and idx <= #MIDIEvents then
    local event = MIDIEvents[idx]
    if event then
      event.delete = true
      return true
    end
  end
  return false
end

-- TODO: this is not 100% complete, in that it doesn't hook stuff up (noteoffs for noteons, bezier curves for CC events)
-- OTOH, ... WTFC -- if you're using this function, you know what you're doing
MIDIUtils.MIDI_InsertEvt = function(take, selected, muted, ppqpos, bytestr)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(selected, 'boolean'),
    MakeTypedArg(muted, 'muted'),
    MakeTypedArg(ppqpos, 'number'),
    MakeTypedArg(bytestr, 'str')
  )
  if not EnsureTransaction(take) then return false end
  local b1 = bytestr:byte(1)
  local b2 = bytestr:byte(2)
  local b3 = bytestr:byte(3)
  local type = typeFromBytes(b1, b2)
  local newEvt = {
    type = type,
    ppqpos = ppqpos,
    offset = ppqpos - MIDIEvents[#MIDIEvents].ppqpos,
    flags = selected and muted and 3 or selected and 1 or muted and 2 or 0,
    MIDI = nil,
    chanmsg = type == META_TYPE and 0xFF or type == SYSEX_TYPE and 0xF0 or (b1 & 0xF0),
    chan = type == NOTE_TYPE or type == CC_TYPE or type == NOTEOFF_TYPE and (b1 & 0x0F) or 0,
    msg2 = type == NOTE_TYPE or type == CC_TYPE or type == NOTEOFF_TYPE or type == META_TYPE and b2 or 0,
    msg3 = type == NOTE_TYPE or type == CC_TYPE or type == NOTEOFF_TYPE and b3 or 0
  }
  newEvt.msg = purifyMsg(newEvt, bytestr)
  newEvt.MIDI = string.pack('i4Bs4', newEvt.offset, newEvt.flags, getEventMIDIString(newEvt.msg))
  table.insert(MIDIEvents, newEvt)
  return true, #MIDIEvents
end

-----------------------------------------------------------------------------
------------------------------------ ENUM -----------------------------------

MIDIUtils.MIDI_EnumSelNotes = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  EnsureTake(take)
  if idx < 0 then enumNoteIdx = 0 end
  for i = enumNoteIdx > 0 and enumNoteIdx + 1 or 1, #MIDIEvents do
    local event = MIDIEvents[i]
    if event and event.type == NOTE_TYPE and event.flags & 1 ~= 0 then
      enumNoteIdx = i
      return event.idx
    end
  end
  enumNoteIdx = 0
  return -1
end

MIDIUtils.MIDI_EnumSelCC = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  EnsureTake(take)
  if idx == -1 then enumCCIdx = 0 end
  for i = enumCCIdx > 0 and enumCCIdx + 1 or 1, #MIDIEvents do
    local event = MIDIEvents[i]
    if event.type == CC_TYPE and event.flags & 1 ~= 0 then
      enumCCIdx = i
      return event.idx
    end
  end
  enumCCIdx = 0
  return -1
end

MIDIUtils.MIDI_EnumSelTextSysexEvts = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  EnsureTake(take)
  if idx < 0 then enumSyxIdx = 0 end
  for i = enumSyxIdx > 0 and enumSyxIdx + 1 or 1, #MIDIEvents do
    local event = MIDIEvents[i]
    if (event.type == SYSEX_TYPE or event.type == META_TYPE or event.type == OTHER_TYPE) and event.flags & 1 ~= 0 then
      enumSyxIdx = i
      return event.idx
    end
  end
  enumSyxIdx = 0
  return -1
end

MIDIUtils.MIDI_EnumSelEvts = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  EnsureTake(take)
  if idx < 0 then enumAllIdx = 0 end
  for i = enumAllIdx > 0 and enumAllIdx + 1 or 1, #MIDIEvents do
    local event = MIDIEvents[i]
    if event.flags & 1 ~= 0 then
      enumAllIdx = i
      return i
    end
  end
  enumAllIdx = 0
  return -1
end

local noteNames = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }

MIDIUtils.MIDI_NoteNumberToNoteName = function(notenum)
  notenum = math.abs(notenum) % 128
  local notename = noteNames[notenum % 12 + 1]
  local octave = math.floor((notenum / 12)) - 1
  local noteOffset = r.SNM_GetIntConfigVar('midioctoffs', -0xFF) - 1 -- 1 == 0 in the interface (C4)
  if noteOffset ~= 0xFF then
    octave = octave + noteOffset
  end
  return notename..octave
end

-----------------------------------------------------------------------------
----------------------------------- EXPORT ----------------------------------

MIDIUtils.NOTE_TYPE = NOTE_TYPE
MIDIUtils.NOTEOFF_TYPE = NOTEOFF_TYPE
MIDIUtils.CC_TYPE = CC_TYPE
MIDIUtils.SYSEX_TYPE = SYSEX_TYPE
MIDIUtils.META_TYPE = META_TYPE
MIDIUtils.OTHER_TYPE = OTHER_TYPE

return MIDIUtils
