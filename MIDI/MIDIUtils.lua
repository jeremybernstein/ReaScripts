-- @description MIDI Utils API
-- @version 0.1.0-beta.1
-- @author sockmonkey72
-- @about
--   # MIDI Utils API
--   Drop-in replacement for REAPER's high-level MIDI API
-- @changelog
--   - initial
-- @provides
--   [nomain] MIDIUtils.lua
--   {MIDIUtils}/*

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
local BEZIER_TYPE = 5
local OTHER_TYPE = 6

local MIDIEvents = {}
local bezTable = {}

local noteEvents = {}
local ccEvents = {}
local syxEvents = {}

local enumNoteIdx = 0
local enumCCIdx = 0
local enumSyxIdx = 0
local enumAllIdx = 0
local enumAllLastCt = -1

local MIDIStringTail = ''
local activeTake
local openTransaction

local OnError = function (err)
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
end

local function CheckDependencies(scriptName)
  if not r.APIExists('SNM_GetIntConfigVar') then
    r.ShowConsoleMsg(scriptName .. ' requires the \'SWS\' extension (install from https://www.sws-extension.org)\n')
    return false
  end
  return true
end

-----------------------------------------------------------------------------

MIDIUtils.SetOnError = function(fn)
  OnError = fn
end

MIDIUtils.CheckDependencies = function(scriptName)
  return select(2, xpcall(CheckDependencies, OnError, scriptName))
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

local function TypeFromBytes(b1, b2)
  if b1 == 0xFF then return META_TYPE, 0xFF
  elseif b1 == 0xF0 then return SYSEX_TYPE, 0xF0
  elseif (b1 >= 0x90 and b1 < 0xA0 and b2 ~= 0) then return NOTE_TYPE, 0x90
  elseif (b1 >= 0x80 and b1 < 0xA0) then return NOTEOFF_TYPE, 0x80
  elseif (b1 >= 0xA0 and b1 < 0xF0) then return CC_TYPE, b1 & 0xF0
  else return OTHER_TYPE, 0
  end
end

local function FlagsFromSelMute(selected, muted)
  return selected and muted and 3 or selected and 1 or muted and 2 or 0
end

-----------------------------------------------------------------------------
----------------------------------- OOP -------------------------------------

local function class(base, init) -- http://lua-users.org/wiki/SimpleLuaClasses
  local c = {}    -- a new class instance
  if not init and type(base) == 'function' then
    init = base
    base = nil
  elseif type(base) == 'table' then
   -- our new class is a shallow copy of the base class!
    for i,v in pairs(base) do
      c[i] = v
    end
    c._base = base
  end
  -- the class will be the metatable for all its objects,
  -- and they will look up their methods in it.
  c.__index = c

  -- expose a constructor which can be called by <classname>(<args>)
  local mt = {}
  mt.__call = function(class_tbl, ...)
  local obj = {}
  setmetatable(obj, c)
  if class_tbl.init then
    class_tbl.init(obj,...)
  else
    -- make sure that any stuff from the base class is initialized!
    if base and base.init then
      base.init(obj, ...)
    end
  end
  return obj
  end
  c.init = init
  c.is_a = function(self, klass)
    local m = getmetatable(self)
    while m do
      if m == klass then return true end
      m = m._base
    end
    return false
  end
  setmetatable(c, mt)
  return c
end

-----------------------------------------------------------------------------
----------------------------------- EVENT -----------------------------------

local Event = class()
function Event:init(ppqpos, offset, flags, msg, MIDI)
  self.ppqpos = ppqpos
  self.offset = offset
  self.flags = flags

  self.msg1 = (msg and msg:byte(1)) or 0
  self.msg2 = (msg and msg:byte(2)) or 0
  self.msg3 = (msg and msg:byte(3)) or 0

  _, self.chanmsg = TypeFromBytes(self.msg1, self.msg2)
  self.chan = self:IsChannelEvt() and self.msg1 & 0x0F or 0

  self.msg = self:PurifyMsg(msg)
  if self:IsChannelEvt() then msg = self.msg end

  self.MIDI = MIDI
  if not self.MIDI and msg and self.offset and self.flags then
    self.MIDI = string.pack('i4Bs4', self.offset, self.flags, msg)
  end
  if not self.MIDI then self.recalcMIDI = true end
end

function Event:PurifyMsg(msg)
  return msg
end

function Event:IsChannelEvt() return false end
function Event:IsAllEvt() return false end

function Event:GetMIDIString()
  return self.msg
end

function Event:type() return OTHER_TYPE end

local UnknownEvent = class(Event)
function UnknownEvent:init(ppqpos, offset, flags, msg, MIDI)
  Event.init(self, ppqpos, offset, flags, msg, MIDI)
  self.chanmsg = 0
  self.chan = 0
  self.msg2 = 0
  self.msg3 = 0
end

-----------------------------------------------------------------------------
------------------------------- CHANNEL EVENT -------------------------------

local ChannelEvent = class(Event)
function ChannelEvent:init(ppqpos, offset, flags, msg, MIDI)
  Event.init(self, ppqpos, offset, flags, msg, MIDI)
end
-- function ChannelEvent:init(ppqpos, offset, flags, msg, MIDI)
--   Event.init(self, ppqpos, offset, flags, msg, MIDI)
-- end
function ChannelEvent:IsChannelEvt() return true end
function ChannelEvent:IsAllEvt() return true end

-----------------------------------------------------------------------------
-------------------------------- NOTEON EVENT -------------------------------

local NoteOnEvent = class(ChannelEvent)
function NoteOnEvent:init(ppqpos, offset, flags, msg, MIDI, count)
  ChannelEvent.init(self, ppqpos, offset, flags, msg, MIDI)
  self.endppqpos = -1
  self.noteOffIdx = -1
  if count == nil or count then
    self.idx = #noteEvents
    table.insert(noteEvents, self)
  end
end

function NoteOnEvent:type() return NOTE_TYPE end

-----------------------------------------------------------------------------
-------------------------------- NOTEOFF EVENT ------------------------------

local NoteOffEvent = class(ChannelEvent)
function NoteOffEvent:init(ppqpos, offset, flags, msg, MIDI)
  ChannelEvent.init(self, ppqpos, offset, flags, msg, MIDI)
  self.noteOnIdx = -1
end

function NoteOffEvent:type() return NOTEOFF_TYPE end

-----------------------------------------------------------------------------
----------------------------------- CC EVENT --------------------------------

local CCEvent = class(ChannelEvent)
function CCEvent:init(ppqpos, offset, flags, msg, MIDI, count)
  ChannelEvent.init(self, ppqpos, offset, flags, msg, MIDI)
  self.bezIdx = 0
  if count == nil or count then
    self.idx = #ccEvents
    table.insert(ccEvents, self)
  end
end

function CCEvent:GetMIDIString()
  if self.msg:len() == 2 then
    return self.msg..string.char(0)
  end
  return self.msg
end

function CCEvent:PurifyMsg(msg)
  local msglen = msg:len()
  if (self.chanmsg == 0xC0 or self.chanmsg == 0xD0) and msglen > 2 then
    self.msg3 = 0
    msg = msg:sub(1, 2) -- truncate 3rd byte
  elseif (self.chanmsg ~= 0xC0 and self.chanmsg ~= 0xD0) and msglen < 3 then
    for i = msglen, 2 do
      msg = msg..string.char(0) -- if it's a 3-byte message with a 2-byte payload, just stick a 0 on the end
    end
  end
  return msg
end

function CCEvent:type() return CC_TYPE end

-----------------------------------------------------------------------------
------------------------------- TEXTSYX EVENT -------------------------------

local TextSysexEvent = class(Event)
function TextSysexEvent:init(ppqpos, offset, flags, msg, MIDI, count)
  Event.init(self, ppqpos, offset, flags, msg, MIDI)
  if count == nil or count then
    self.idx = #syxEvents
    table.insert(syxEvents, self)
  end
end
function TextSysexEvent:IsAllEvt() return true end

-----------------------------------------------------------------------------
--------------------------------- SYSEX EVENT -------------------------------

local SysexEvent = class(TextSysexEvent)
function SysexEvent:init(ppqpos, offset, flags, msg, MIDI, count)
  TextSysexEvent.init(self, ppqpos, offset, flags, msg, MIDI, count)
  self.msg2 = 0
  self.msg3 = 0
end

function SysexEvent:GetMIDIString()
  return string.char(0xF0)..self.msg..string.char(0xF7)
end

function SysexEvent:PurifyMsg(msg)
  if msg:byte(1) == 0xF0 then msg = string.sub(msg, 2) end
  if msg:byte(msg:len()) == 0xF7 then msg = string.sub(msg, 1, -2) end
  return msg
end

function SysexEvent:type() return SYSEX_TYPE end

-----------------------------------------------------------------------------
--------------------------------- META EVENT --------------------------------

local MetaEvent = class(TextSysexEvent)
function MetaEvent:init(ppqpos, offset, flags, msg, MIDI, count)
  TextSysexEvent.init(self, ppqpos, offset, flags, msg, MIDI, count)
  self.msg3 = 0
end

function MetaEvent:GetMIDIString()
  return string.char(0xFF)..string.char(self.msg2)..self.msg
end

function MetaEvent:PurifyMsg(msg)
  if msg:byte(1) == 0xFF then msg = string.sub(msg, 3) end -- just going to assume that this message conforms w b2 == type
  return msg
end

function MetaEvent:type() return META_TYPE end

-----------------------------------------------------------------------------
-------------------------------- BEZIER EVENT -------------------------------

local BezierEvent = class(Event)
function BezierEvent:init(ppqpos, offset, flags, msg, MIDI)
  Event.init(self, ppqpos, offset, flags, msg, MIDI)
  self.ccIdx = #MIDIEvents - 1 -- previous event
end

function BezierEvent:type() return BEZIER_TYPE end

-----------------------------------------------------------------------------
-------------------------------- EVENT FACTORY ------------------------------

local function MakeEvent(ppqpos, offset, flags, msg, MIDI, count)
  if msg then
    local b1 = msg:byte(1)
    local b2 = msg:byte(2)
    local type = TypeFromBytes(b1, b2)
    if type == NOTE_TYPE then
      return NoteOnEvent(ppqpos, offset, flags, msg, MIDI, count)
    elseif type == NOTEOFF_TYPE then
      return NoteOffEvent(ppqpos, offset, flags, msg, MIDI)
    elseif type == CC_TYPE then
      return CCEvent(ppqpos, offset, flags, msg, MIDI, count)
    elseif type == SYSEX_TYPE then
      return SysexEvent(ppqpos, offset, flags, msg, MIDI, count)
    elseif type == META_TYPE then
      if b2 == 15 and string.sub(msg, 3, 7) == 'CCBZ ' then
        return BezierEvent(ppqpos, offset, flags, msg, MIDI)
      else
        return MetaEvent(ppqpos, offset, flags, msg, MIDI, count)
      end
    else
      return UnknownEvent(ppqpos, offset, flags, msg, MIDI)
    end
  end
end

-----------------------------------------------------------------------------
----------------------------------- PARSE -----------------------------------

local function Reset()
  MIDIEvents = {}
  bezTable = {}
  enumNoteIdx = 0
  enumCCIdx = 0
  enumSyxIdx = 0
  enumAllIdx = 0
  enumAllLastCt = -1
  MIDIStringTail = ''
  activeTake = nil
  openTransaction = nil

  noteEvents = {}
  ccEvents = {}
  syxEvents = {}
end

local function InsertMIDIEvent(event)
  table.insert(MIDIEvents, event)
  event.MIDIidx = #MIDIEvents
  return event, #MIDIEvents
end

local function ReplaceMIDIEvent(event, newEvent)
  newEvent.idx = event.idx
  newEvent.MIDIidx = event.MIDIidx
  MIDIEvents[event.MIDIidx] = newEvent
  if newEvent.idx then
    if newEvent:is_a(NoteOnEvent) then noteEvents[newEvent.idx + 1] = newEvent
    elseif newEvent:is_a(CCEvent) then ccEvents[newEvent.idx + 1] = newEvent
    elseif newEvent:is_a(TextSysexEvent) then syxEvents[newEvent.idx + 1] = newEvent
    end
  end
  return newEvent
end

local function GetEvents(take)
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

    ppqTime = ppqTime + offset -- current PPQ time for this event

    -- next step is to subclass the individual types, but this is ok for now
    local event = InsertMIDIEvent(MakeEvent(ppqTime, offset, flags, msg, MIDIString:sub(stringPos, newStringPos - 1)))
    if event:is_a(NoteOnEvent) then
      table.insert(noteOns, { chan = event.chan, pitch = event.msg2, flags = event.flags, ppqpos = event.ppqpos, index = #MIDIEvents })
    elseif event:is_a(NoteOffEvent) then
      for k, v in spairs(noteOns, function(t, a, b) return t[a].ppqpos < t[b].ppqpos end) do
        if v.chan == event.chan and v.pitch == event.msg2 and v.flags == event.flags then
          local noteon = MIDIEvents[v.index]
          event.noteOnIdx = k
          noteon.noteOffIdx = #MIDIEvents
          noteon.endppqpos = event.ppqpos
          noteOns[k] = nil -- remove it
          break
        end
      end
    end
    stringPos = newStringPos
  end
  MIDIStringTail = MIDIString:sub(-12)
  return true
end

-----------------------------------------------------------------------------
---------------------------------- BASICS -----------------------------------

function EnsureTake(take)
  if take ~= activeTake then
    GetEvents(take)
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

local function MIDI_InitializeTake(take, enforceargs)
  GetEvents(take)
end

local function MIDI_CountEvts(take)
  EnsureTake(take)
  return true, #noteEvents, #ccEvents, #syxEvents
end

-- cache this, or store it in the event for faster lookup?
local function MIDI_CountAllEvts(take)
  EnsureTake(take)
  local allcnt = 0
  for _, event in ipairs(MIDIEvents) do
    if event:IsAllEvt() then allcnt = allcnt + 1 end
  end
  return allcnt
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_InitializeTake = function(take, enforceargs)
  if enforceargs ~= nil then MIDIUtils.ENFORCE_ARGS = enforceargs end
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(enforceargs, 'boolean', true)
  )
  return select(2, xpcall(MIDI_InitializeTake, OnError, take, enforceargs))
end

MIDIUtils.MIDI_CountEvts = function(take)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*')
  )
  return select(2, xpcall(MIDI_CountEvts, OnError, take))
end

MIDIUtils.MIDI_CountAllEvts = function(take)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*')
  )
  return select(2, xpcall(MIDI_CountAllEvts, OnError, take))
end

-----------------------------------------------------------------------------
------------------------------- TRANSACTIONS --------------------------------

local function MIDI_OpenWriteTransaction(take)
  EnsureTake(take)
  openTransaction = take
end

local function MIDI_CommitWriteTransaction(take, refresh)
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
    elseif event.recalcMIDI then
      local MIDIStr = ''
      if event:IsChannelEvt() then
        local b1 = string.char(event.chanmsg | event.chan)
        local b2 = string.char(event.msg2)
        local b3 = string.char(event.msg3)
        event.msg = event:PurifyMsg(table.concat({ b1, b2, b3 }))
        MIDIStr = event.msg
      elseif event:is_a(SysexEvent) or event:is_a(MetaEvent) then
        MIDIStr = event:GetMIDIString()
      else
        MIDIStr = event.msg -- not sure what to do here, there don't appear to really be OTHER_TYPE events in the wild
      end
      event.MIDI = string.pack('i4Bs4', event.offset, event.flags, MIDIStr)
    end
    newMIDIString = newMIDIString .. event.MIDI

    -- only do this if the bezEvent is in the aux table, otherwise we'll get it on the next loop
    if event:is_a(CCEvent) and event.bezIdx and event.bezIdx < 0 then
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

MIDIUtils.MIDI_OpenWriteTransaction = function(take)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*')
  )
  return select(2, xpcall(MIDI_OpenWriteTransaction, OnError, take))
end

MIDIUtils.MIDI_CommitWriteTransaction = function(take, refresh)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(refresh, 'boolean', true)
  )
  return select(2, xpcall(MIDI_CommitWriteTransaction, OnError, take, refresh))
end

-----------------------------------------------------------------------------
----------------------------------- NOTES -----------------------------------

local function MIDI_GetNote(take, idx)
  EnsureTake(take)
  local event = noteEvents[idx + 1]
  if event and event:is_a(NoteOnEvent) and event.idx == idx and not event.delete then
    return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false,
      event.ppqpos, event.endppqpos, event.chan, event.msg2, event.msg3
  end
  return false, false, false, 0, 0, 0, 0, 0
end

local function AdjustNoteOff(noteoff, param, val)
  noteoff[param] = val
  noteoff.recalcMIDI = true
end

local function MIDI_SetNote(take, idx, selected, muted, ppqpos, endppqpos, chan, pitch, vel)
  if not EnsureTransaction(take) then return false end
  local rv = false
  local event = noteEvents[idx + 1]
  if event and event:is_a(NoteOnEvent) and event.idx == idx and not event.delete then
    local noteoff = MIDIEvents[event.noteOffIdx]
    --if not noteoff then r.ShowConsoleMsg('not noteoff in setnote\n') end

    if selected ~= nil then
      if selected then event.flags = event.flags | 1
      else event.flags = event.flags & ~1 end
      AdjustNoteOff(noteoff, 'selected', event.flags)
    end
    if muted ~= nil then
      if muted then event.flags = event.flags | 2
      else event.flags = event.flags & ~2 end
      AdjustNoteOff(noteoff, 'muted', event.flags)
    end
    if ppqpos then
      local diff = ppqpos - event.ppqpos
      event.ppqpos = ppqpos -- bounds checking?
      AdjustNoteOff(noteoff, 'ppqpos', noteoff.ppqpos + diff)
    end
    if endppqpos then
      AdjustNoteOff(noteoff, 'ppqpos', endppqpos)
    end
    if chan then
      event.chan = chan & 0x0F
      AdjustNoteOff(noteoff, 'chan', event.chan)
    end
    if pitch then
      event.msg2 = pitch & 0x7F
      AdjustNoteOff(noteoff, 'msg2', event.msg2)
    end
    if vel then
      event.msg3 = vel & 0x7F
      if event.msg3 < 1 then event.msg3 = 1 end
    end
    event.recalcMIDI = true
    rv = true
  end
  return rv
end

local function MIDI_InsertNote(take, selected, muted, ppqpos, endppqpos, chan, pitch, vel)
  if not EnsureTransaction(take) then return false end
  local lastEvent = MIDIEvents[#MIDIEvents]
  local newNoteOn = NoteOnEvent(ppqpos,
                                ppqpos - (lastEvent and lastEvent.ppqpos or 0),
                                FlagsFromSelMute(selected, muted),
                                table.concat({
                                  string.char(0x90 | (chan & 0xF)),
                                  string.char(pitch & 0x7F),
                                  string.char(vel & 0x7F)
                                }))
  newNoteOn.endppqpos = endppqpos
  newNoteOn.noteOffIdx = -1
  InsertMIDIEvent(newNoteOn)

  local newNoteOff = NoteOffEvent(endppqpos,
                                  endppqpos - ppqpos,
                                  newNoteOn.flags,
                                  table.concat({
                                    string.char(0x80 | newNoteOn.chan),
                                    string.char(newNoteOn.msg2),
                                    string.char(0)
                                  }))
  newNoteOff.noteOnIdx = #MIDIEvents
  _, newNoteOn.noteOffIdx = InsertMIDIEvent(newNoteOff)
  return true, newNoteOn.idx
end

local function MIDI_DeleteNote(take, idx)
  if not EnsureTransaction(take) then return false end
  local event = noteEvents[idx + 1]
  if event and event:is_a(NoteOnEvent) and event.idx == idx then
    event.delete = true
    MIDIEvents[event.noteOffIdx].delete = true
    return true
  end
  return false
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_GetNote = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_GetNote, OnError, take, idx))
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
  return select(2, xpcall(MIDI_SetNote, OnError, take, idx, selected, muted, ppqpos, endppqpos, chan, pitch, vel))
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
  return select(2, xpcall(MIDI_InsertNote, OnError, take, selected, muted, ppqpos, endppqpos, chan, pitch, vel))
end

MIDIUtils.MIDI_DeleteNote = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_DeleteNote, OnError, take, idx))
end

-----------------------------------------------------------------------------
---------------------------------- BEZIER -----------------------------------

local function FindBezierData(idx, event)
  local bezEvent
  local bezIdx = idx + 1
  if event:is_a(CCEvent) and bezIdx <= #MIDIEvents then
    bezEvent = MIDIEvents[bezIdx]
  end
  if not (bezEvent and bezEvent:is_a(BezierEvent)) then
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

local function GetBezierData(idx, event)
  local rv, bezEvent = FindBezierData(idx, event)
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

local function SetBezierData(idx, event, beztype, beztension)
  local bezMsg = table.concat({
    string.char(0xFF),
    string.char(0xF),
    'CCBZ ',
    string.char(beztype), -- should be 0
    string.pack('f', beztension)
  })
  local rv, bezEvent, bezIdx = FindBezierData(idx, event)
  if rv and bezEvent then
    bezEvent.msg = bezMsg -- update in place
    bezEvent.MIDI = string.pack('i4Bs4', bezEvent.offset, bezEvent.flags, bezEvent.msg)
    event.bezIdx = bezIdx -- negative in aux table, positive in MIDIEvents
    return true
  else
    bezEvent = BezierEvent(event.ppqpos, 0, 0, bezMsg)
    bezEvent.ccPos = idx
    table.insert(bezTable, bezEvent)
    event.bezIdx = -(#bezTable)
    return true
  end
  return false
end

local function DeleteBezierData(idx, event)
  local rv, bezEvent, bezIdx = FindBezierData(idx, event)
  if rv and bezEvent and bezIdx then
    rv = false
    if bezIdx > 0 then bezEvent.delete = true
    elseif bezIdx < 0 then
      bezIdx = math.abs(bezIdx)
      for _, ev in ipairs(MIDIEvents) do
        if ev:is_a(CCEvent) and ev.idx == bezEvent.ccIdx and ev.bezIdx == bezIdx then
          ev.bezIdx = nil
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

local function MIDI_GetCC(take, idx)
  EnsureTake(take)
  local event = ccEvents[idx + 1]
  if event and event:is_a(CCEvent) and event.idx == idx and not event.delete then
    return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false,
      event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3
  end
  return false, false, false, 0, 0, 0, 0, 0
end

local function MIDI_SetCC(take, idx, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
  if not EnsureTransaction(take) then return false end
  local rv = false
  local event = ccEvents[idx + 1]
  if event and event:is_a(CCEvent) and event.idx == idx and not event.delete then
    if selected ~= nil then
      if selected then event.flags = event.flags | 1
      else event.flags = event.flags & ~1 end
    end
    if muted ~= nil then
      if muted then event.flags = event.flags | 2
      else event.flags = event.flags & ~2 end
    end
    if ppqpos then
      event.ppqpos = ppqpos -- bounds checking?
    end
    if chanmsg then
      event.chanmsg = chanmsg < 0xA0 or chanmsg >= 0xF0 and 0xB0 or chanmsg & 0xF0
    end
    if chan then
      event.chan = chan & 0x0F
    end
    if msg2 then
      event.msg2 = msg2 & 0x7F
    end
    if msg3 then
      event.msg3 = msg3 & 0x7F
      if chanmsg == 0xC0 or chanmsg == 0xD0 then event.msg3 = 0 end
    end
    event.recalcMIDI = true
    rv = true
  end
  return rv
end

local function MIDI_GetCCShape(take, idx)
  EnsureTake(take)
  local event = ccEvents[idx + 1]
  if event and event:is_a(CCEvent) and event.idx == idx and not event.delete then
    local rv, _, bztension = GetBezierData(event.MIDIidx, event)
    return true, ((event.flags & 0xF0) >> 4) & 7, rv and bztension or 0.
  end
  return false, 0, 0.
end

local function MIDI_SetCCShape(take, idx, shape, beztension)
  EnsureTransaction(take)
  local event = ccEvents[idx + 1]
  if event and event:is_a(CCEvent) and event.idx == idx and not event.delete then
    local MIDIidx = event.MIDIidx
    event.flags = event.flags & ~0xF0
    -- flag high 4 bits for CC shape: &16=linear, &32=slow start/end, &16|32=fast start, &64=fast end, &64|16=bezier
    event.flags = event.flags | ((shape & 0x7) << 4)
    event.recalcMIDI = true
    if shape == 5 and beztension then
      return SetBezierData(MIDIidx, event, 0, beztension)
    else
      DeleteBezierData(MIDIidx, event)
    end
    return true
  end
  return false
end

local function MIDI_InsertCC(take, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
  if not EnsureTransaction(take) then return false end
  local lastEvent = MIDIEvents[#MIDIEvents]
  chanmsg = chanmsg < 0xA0 or chanmsg >= 0xF0 and 0xB0 or chanmsg
  local newFlags = FlagsFromSelMute(selected, muted)
  local defaultCCShape = r.SNM_GetIntConfigVar('midiccenv', -1)
  if defaultCCShape ~= 0 then
    defaultCCShape = defaultCCShape & 7
    if defaultCCShape >= 0 and defaultCCShape <= 5 then
      newFlags = newFlags | (defaultCCShape << 4)
    end
  end

  local newCC = CCEvent(ppqpos,
                        ppqpos - lastEvent.ppqpos,
                        newFlags,
                        table.concat({
                          string.char((chanmsg & 0xF0) | (chan & 0xF)),
                          string.char(msg2 & 0x7F),
                          string.char(msg3 & 0x7F)
                        }))
  InsertMIDIEvent(newCC)
  return true, newCC.idx
end

local function MIDI_DeleteCC(take, idx)
  if not EnsureTransaction(take) then return false end
  local event = ccEvents[idx + 1]
  if event and event:is_a(CCEvent) and event.idx == idx then
    event.delete = true
    DeleteBezierData(event.MIDIidx, event)
    return true
  end
  return false
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_GetCC = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_GetCC, OnError, take, idx))
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
  return select(2, xpcall(MIDI_SetCC, OnError, take, idx, selected, muted, ppqpos, chanmsg, chan, msg2, msg3))
end

MIDIUtils.MIDI_GetCCShape = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_GetCCShape, OnError, take, idx))
end

MIDIUtils.MIDI_SetCCShape = function(take, idx, shape, beztension)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number'),
    MakeTypedArg(shape, 'number'),
    MakeTypedArg(beztension, 'number', true)
  )
  return select(2, xpcall(MIDI_SetCCShape, OnError, take, idx, shape, beztension))
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
  return select(2, xpcall(MIDI_InsertCC, OnError, take, selected, muted, ppqpos, chanmsg, chan, msg2, msg3))
end

MIDIUtils.MIDI_DeleteCC = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_DeleteCC, OnError, take, idx))
end

-----------------------------------------------------------------------------
-------------------------------- TEXT / SYSEX -------------------------------

local function GetMIDIStringForTextSysex(type, msg)
  local newMsg = msg
  if type == -1 then
    newMsg = string.char(0xF0)..msg..string.char(0xF7)
  elseif type >= 1 and type <= 15 then
    newMsg = string.char(0xFF)..string.char(type)..msg
  end
  return newMsg
end

local function MIDI_GetTextSysexEvt(take, idx)
  EnsureTake(take)
  local event = syxEvents[idx + 1]
  if event and (event:is_a(SysexEvent) or event:is_a(MetaEvent)) and event.idx == idx and not event.delete then
    return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false, event.ppqpos,
    event.chanmsg == 0xF0 and -1 or event.chanmsg == 0xFF and event.msg2 or 0, event.msg
  end
  return false, false, false, 0, 0, ''
end

local function MIDI_SetTextSysexEvt(take, idx, selected, muted, ppqpos, type, msg)
  if not EnsureTransaction(take) then return false end
  local rv = false
  local event = syxEvents[idx + 1]
  if event and (event:is_a(SysexEvent) or event:is_a(MetaEvent)) and event.idx == idx and not event.delete then
    if selected ~= nil then
      if selected then event.flags = event.flags | 1
      else event.flags = event.flags & ~1 end
    end
    if muted ~= nil then
      if muted then event.flags = event.flags | 2
      else event.flags = event.flags & ~2 end
    end
    if ppqpos then
      event.ppqpos = ppqpos
    end
    if type and msg then
      local newEvt = MakeEvent(event.ppqpos, event.offset, event.flags, GetMIDIStringForTextSysex(type, msg), nil, false)
      event = ReplaceMIDIEvent(event, newEvt)
    end
    event.recalcMIDI = true
    rv = true
  end
  return rv
end

local function MIDI_InsertTextSysexEvt(take, selected, muted, ppqpos, type, bytestr)
  if not EnsureTransaction(take) then return false end
  local lastEvent = MIDIEvents[#MIDIEvents]
  local newTextSysex = MakeEvent(ppqpos,
                                 ppqpos - lastEvent.ppqpos,
                                 FlagsFromSelMute(selected, muted),
                                 GetMIDIStringForTextSysex(type, bytestr))
  InsertMIDIEvent(newTextSysex)
  return true, newTextSysex.idx
end

local function MIDI_DeleteTextSysexEvt(take, idx)
  if not EnsureTransaction(take) then return false end
  local event = syxEvents[idx + 1]
  if event and (event:is_a(SysexEvent) or event:is_a(MetaEvent)) and event.idx == idx then
    event.delete = true
    return true
  end
  return false
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_GetTextSysexEvt = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_GetTextSysexEvt, OnError, take, idx))
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
  return select(2, xpcall(MIDI_SetTextSysexEvt, OnError, take, idx, selected, muted, ppqpos, type, msg))
end

MIDIUtils.MIDI_InsertTextSysexEvt = function(take, selected, muted, ppqpos, type, bytestr)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(selected, 'boolean'),
    MakeTypedArg(muted, 'boolean'),
    MakeTypedArg(ppqpos, 'number'),
    MakeTypedArg(type, 'number'),
    MakeTypedArg(bytestr, 'string')
  )
  return select(2, xpcall(MIDI_InsertTextSysexEvt, OnError, take, selected, muted, ppqpos, type, bytestr))
end

MIDIUtils.MIDI_DeleteTextSysexEvt = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_DeleteTextSysexEvt, OnError, take, idx))
end

-----------------------------------------------------------------------------
------------------------------------ EVTS -----------------------------------

-- these operate just on the raw index into the array, not based on type
local function MIDI_GetEvt(take, idx)
  EnsureTake(take)
  local allcnt = 0
  for _, event in ipairs(MIDIEvents) do
    if event:IsAllEvt() then
      if idx == allcnt then
        return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false, event.ppqpos, event:GetMIDIString()
      end
      allcnt = allcnt + 1
    end
  end
  return false, false, false, 0, ''
end

local function MIDI_SetEvt(take, idx, selected, muted, ppqpos, msg)
  if not EnsureTransaction(take) then return false end

  local allcnt = 0
  for _, event in ipairs(MIDIEvents) do
    if event:IsAllEvt() then
      if idx == allcnt then
        if selected ~= nil then
          if selected then event.flags = event.flags | 1
          else event.flags = event.flags & ~1 end
        end
        if muted ~= nil then
          if muted then event.flags = event.flags | 2
          else event.flags = event.flags & ~2 end
        end
        if ppqpos then
          event.ppqpos = ppqpos
          end
        if msg then -- the problem here is that we could mess up the numbering
          local newEvt = MakeEvent(event.ppqpos, event.offset, event.flags, msg, nil, false)
          event = ReplaceMIDIEvent(event, newEvt)
        end
        event.recalcMIDI = true
        return true
      end
      allcnt = allcnt + 1
    end
  end
  return false
end

-- TODO: this is not 100% complete, in that it doesn't hook stuff up (noteoffs for noteons, bezier curves for CC events)
-- OTOH, ... WTFC -- if you're using this function, you know what you're doing
local function MIDI_InsertEvt(take, selected, muted, ppqpos, bytestr)
  if not EnsureTransaction(take) then return false end
  local newFlags = FlagsFromSelMute(selected, muted)
  local newOffset = ppqpos - MIDIEvents[#MIDIEvents].ppqpos
  local newEvt = MakeEvent(ppqpos, newOffset, newFlags, bytestr)
  InsertMIDIEvent(newEvt)

  local allcnt = 0
  for _, event in ipairs(MIDIEvents) do
    if event:IsAllEvt() then
      if event == newEvt then
        return true, allcnt
      end
      allcnt = allcnt + 1
    end
  end
  return false
end

local function MIDI_DeleteEvt(take, idx)
  if not EnsureTransaction(take) then return false end
  local allcnt = 0
  for _, event in ipairs(MIDIEvents) do
    if event:IsAllEvt() then
      if idx == allcnt then
        event.delete = true
        return true
      end
      allcnt = allcnt + 1
    end
  end
  return false
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_GetEvt = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_GetEvt, OnError, take, idx))
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
  return select(2, xpcall(MIDI_SetEvt, OnError, take, idx, selected, muted, ppqpos, msg))
end

MIDIUtils.MIDI_InsertEvt = function(take, selected, muted, ppqpos, bytestr)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(selected, 'boolean'),
    MakeTypedArg(muted, 'muted'),
    MakeTypedArg(ppqpos, 'number'),
    MakeTypedArg(bytestr, 'str')
  )
  return select(2, xpcall(MIDI_InsertEvt, OnError, take, selected, muted, ppqpos, bytestr))
end

MIDIUtils.MIDI_DeleteEvt = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_DeleteEvt, OnError, take, idx))
end

-----------------------------------------------------------------------------
------------------------------------ ENUM -----------------------------------

local function EnumNotesImpl(take, idx, selectedOnly)
  if idx < 0 then enumNoteIdx = 0 end
  for i = enumNoteIdx > 0 and enumNoteIdx + 1 or 1, #MIDIEvents do
    local event = MIDIEvents[i]
    if event and event:is_a(NoteOnEvent) and (not selectedOnly or event.flags & 1 ~= 0) then
      enumNoteIdx = i
      return event.idx
    end
  end
  enumNoteIdx = 0
  return -1
end

local function MIDI_EnumNotes(take, idx)
  EnsureTake(take)
  return EnumNotesImpl(take, idx, false)
end

local function MIDI_EnumSelNotes(take, idx)
  EnsureTake(take)
  return EnumNotesImpl(take, idx, true)
end

local function EnumCCImpl(take, idx, selectedOnly)
  if idx == -1 then enumCCIdx = 0 end
  for i = enumCCIdx > 0 and enumCCIdx + 1 or 1, #MIDIEvents do
    local event = MIDIEvents[i]
    if event:is_a(CCEvent) and (not selectedOnly or event.flags & 1 ~= 0) then
      enumCCIdx = i
      return event.idx
    end
  end
  enumCCIdx = 0
  return -1
end

local function MIDI_EnumCC(take, idx)
  EnsureTake(take)
  return EnumCCImpl(take, idx, false)
end

local function MIDI_EnumSelCC(take, idx)
  EnsureTake(take)
  return EnumCCImpl(take, idx, true)
end

local function EnumTextSysexImpl(take, idx, selectedOnly)
  if idx < 0 then enumSyxIdx = 0 end
  for i = enumSyxIdx > 0 and enumSyxIdx + 1 or 1, #MIDIEvents do
    local event = MIDIEvents[i]
    if (event:is_a(SysexEvent) or event:is_a(MetaEvent)) and (not selectedOnly or event.flags & 1 ~= 0) then
      enumSyxIdx = i
      return event.idx
    end
  end
  enumSyxIdx = 0
  return -1
end

local function MIDI_EnumTextSysexEvts(take, idx)
  EnsureTake(take)
  return EnumTextSysexImpl(take, idx, false)
end

local function MIDI_EnumSelTextSysexEvts(take, idx)
  EnsureTake(take)
  return EnumTextSysexImpl(take, idx, true)
end

local function EnumEvtsImpl(take, idx, selectedOnly)
  if idx < 0 then
    enumAllIdx = 0
    enumAllLastCt = -1
  end
  enumAllIdx = enumAllIdx > 0 and enumAllIdx + 1 or 1

  local allcnt = enumAllLastCt < 0 and 0 or enumAllLastCt
  for k = enumAllIdx, #MIDIEvents do
    local event = MIDIEvents[k]
    if event and event:IsAllEvt() then
      if not selectedOnly or event.flags & 1 ~= 0 then
        enumAllIdx = k
        enumAllLastCt = allcnt + 1
        return allcnt
      end
      allcnt = allcnt + 1
    end
  end
  enumAllIdx = 0
  enumAllLastCt = -1
  return -1
end

local function MIDI_EnumEvts(take, idx)
  EnsureTake(take)
  return EnumEvtsImpl(take, idx, false)
end

local function MIDI_EnumSelEvts(take, idx)
  EnsureTake(take)
  return EnumEvtsImpl(take, idx, true)
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_EnumNotes = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_EnumNotes, OnError, take, idx))
end

MIDIUtils.MIDI_EnumSelNotes = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_EnumSelNotes, OnError, take, idx))
end

MIDIUtils.MIDI_EnumCC = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_EnumCC, OnError, take, idx))
end

MIDIUtils.MIDI_EnumSelCC = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_EnumSelCC, OnError, take, idx))
end

MIDIUtils.MIDI_EnumTextSysexEvts = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_EnumTextSysexEvts, OnError, take, idx))
end

MIDIUtils.MIDI_EnumSelTextSysexEvts = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_EnumSelTextSysexEvts, OnError, take, idx))
end

MIDIUtils.MIDI_EnumEvts = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_EnumEvts, OnError, take, idx))
end

MIDIUtils.MIDI_EnumSelEvts = function(take, idx)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number')
  )
  return select(2, xpcall(MIDI_EnumSelEvts, OnError, take, idx))
end

-----------------------------------------------------------------------------
------------------------------------ MISC -----------------------------------

local noteNames = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }

local function MIDI_NoteNumberToNoteName(notenum, names)
  notenum = math.abs(notenum) % 128
  names = names or noteNames
  local notename = names[notenum % 12 + 1]
  local octave = math.floor((notenum / 12)) - 1
  local noteOffset = r.SNM_GetIntConfigVar('midioctoffs', -0xFF) - 1 -- 1 == 0 in the interface (C4)
  if noteOffset ~= -0xFF then
    octave = octave + noteOffset
  end
  return notename..octave
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_NoteNumberToNoteName = function(notenum, names)
  EnforceArgs(
    MakeTypedArg(notenum, 'number'),
    MakeTypedArg(names, 'table', true)
  )
  return select(2, xpcall(MIDI_NoteNumberToNoteName, OnError, notenum, names))
end

-----------------------------------------------------------------------------
----------------------------------- EXPORT ----------------------------------

return MIDIUtils