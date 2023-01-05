-- @description MIDI Utils API
-- @version 0.1.5
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

  See the Readme.txt document in the MIDIUtils/ subdirectory for full documentation,
  or view the latest version online: https://raw.githubusercontent.com/jeremybernstein/ReaScripts/main/MIDI/MIDIUtils/Readme.txt

--]]

local r = reaper
local MIDIUtils = {}

MIDIUtils.ENFORCE_ARGS = true -- turn off for efficiency
MIDIUtils.CORRECT_OVERLAPS = false
MIDIUtils.CORRECT_OVERLAPS_FAVOR_SELECTION = false

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
local configVarCache = {}

local OnError = function (err)
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
end

local function CheckDependencies(scriptName)
  -- no dependencies at the moment
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

local function ReadREAPERConfigVar_Int(name)
  if configVarCache[name] then return configVarCache[name] end
  for line in io.lines(r.GetResourcePath()..'/reaper.ini') do
    local match = string.match(line, name..'='..'(%d+)$')
    if match then
      match = math.floor(match)
      configVarCache[name] = match
      return match
    end
  end
  return nil
end

-----------------------------------------------------------------------------

MIDIUtils.post = function(...)
  return select(2, xpcall(post, OnError, ...))
end

MIDIUtils.p = MIDIUtils.post

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

local DEBUG_CLASS = false -- enable to check whether we're using known object properties

local function class(base, setup, init) -- http://lua-users.org/wiki/SimpleLuaClasses
  local c = {}    -- a new class instance
  if not init and type(base) == 'function' then
    init = base
    base = nil
  elseif type(base) == 'table' then
   -- our new class is a shallow copy of the base class!
    for i, v in pairs(base) do
      c[i] = v
    end
    c._base = base
  end
  if DEBUG_CLASS then
    c.names = {}
    if setup then
      for i, v in pairs(setup) do
        c.names[i] = true
      end
    end
    -- this isn't working quite right, bezier
    c.__newindex = function(table, key, value)
      local found = false
      if table.names[key] then found = true
      else
        local m = getmetatable(table)
        while (m) do
          if m.names[key] then found = true break end
          m = m._base
        end
      end
      if not found then
        error("unknown property: ".. key)
      else rawset(table, key, value)
      end
    end
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

local Event = class(nil, { ppqpos = 0, offset = 0, flags = 0, msg1 = 0, msg2 = 0, msg3 = 0, chanmsg = 0, chan = 0, msg = '', MIDI = '', recalcMIDI = false, MIDIidx = 0, delete = false })
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
function Event:IsSelected() return self.flags & 1 ~= 0 end

function Event:SetMIDIString(msg)
  self.msg = self:PurifyMsg(msg)
  return self:GetMIDIString()
end

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

local NoteOnEvent = class(ChannelEvent, { endppqpos = 0, noteOffIdx = 0, idx = 0 })
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

local NoteOffEvent = class(ChannelEvent, { noteOnIdx = 0 })
function NoteOffEvent:init(ppqpos, offset, flags, msg, MIDI)
  ChannelEvent.init(self, ppqpos, offset, flags, msg, MIDI)
  self.noteOnIdx = -1
end

function NoteOffEvent:type() return NOTEOFF_TYPE end

-----------------------------------------------------------------------------
----------------------------------- CC EVENT --------------------------------

local CCEvent = class(ChannelEvent, { hasBezier = false, idx = 0 })
function CCEvent:init(ppqpos, offset, flags, msg, MIDI, count)
  ChannelEvent.init(self, ppqpos, offset, flags, msg, MIDI)
  self.hasBezier = false
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
------------------------------- ALLEVT EVENT -------------------------------

local AllEvtEvent = class(Event)
function AllEvtEvent:init(ppqpos, offset, flags, msg, MIDI, count)
  Event.init(self, ppqpos, offset, flags, msg, MIDI)
end
function AllEvtEvent:IsAllEvt() return true end

-----------------------------------------------------------------------------
------------------------------- TEXTSYX EVENT -------------------------------

local TextSysexEvent = class(AllEvtEvent, { idx = 0 })
function TextSysexEvent:init(ppqpos, offset, flags, msg, MIDI, count)
  AllEvtEvent.init(self, ppqpos, offset, flags, msg, MIDI)
  if count == nil or count then
    self.idx = #syxEvents
    table.insert(syxEvents, self)
  end
end

-----------------------------------------------------------------------------
--------------------------------- SYSEX EVENT -------------------------------

local SysexEvent = class(TextSysexEvent)
function SysexEvent:init(ppqpos, offset, flags, msg, MIDI, count)
  TextSysexEvent.init(self, ppqpos, offset, flags, msg, MIDI, count)
  self.msg2 = 0
  self.msg3 = 0
end

function SysexEvent:GetMIDIString()
  return self.msg == '' and '' or string.char(0xF0)..self.msg..string.char(0xF7)
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
  return self.msg == '' and '' or string.char(0xFF)..string.char(self.msg2)..self.msg
end

function MetaEvent:PurifyMsg(msg)
  if msg:byte(1) == 0xFF then msg = string.sub(msg, 3) end -- just going to assume that this message conforms w b2 == type
  return msg
end

function MetaEvent:type() return META_TYPE end

-----------------------------------------------------------------------------
-------------------------------- BEZIER EVENT -------------------------------

local BezierEvent = class(Event, { ccIdx = 0 })
function BezierEvent:init(ppqpos, offset, flags, msg, MIDI)
  Event.init(self, ppqpos, offset, flags, msg, MIDI)
  self.ccIdx = #ccEvents - 1 -- previous event, ignore if -1
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
  if event:is_a(BezierEvent) then -- special case for BezierEvents
    bezTable[event.ccIdx + 1] = event
    ccEvents[event.ccIdx + 1].hasBezier = true
    return nil, #MIDIEvents
  else
    table.insert(MIDIEvents, event)
    event.MIDIidx = #MIDIEvents
    return event, #MIDIEvents
  end
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

    -- TODO: don't add bezier events to the main table, put all in the aux table for simplicity
    local event = InsertMIDIEvent(MakeEvent(ppqTime, offset, flags, msg, MIDIString:sub(stringPos, newStringPos - 1)))
    if event then
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
------------------------------ OVERLAP CORRECT ------------------------------

local function CorrectOverlapForEvent(take, testEvent, selectedEvent, favorSelection)
  local modified = false
  if testEvent.chan == selectedEvent.chan
    and testEvent.msg2 == selectedEvent.msg2
  then
    if testEvent.endppqpos >= selectedEvent.ppqpos and testEvent.endppqpos <= selectedEvent.endppqpos then
      MIDIUtils.MIDI_SetNote(take, testEvent.idx, nil, nil, nil, selectedEvent.ppqpos, nil, nil, nil)
      modified = true
    elseif testEvent.ppqpos >= selectedEvent.ppqpos and testEvent.ppqpos <= selectedEvent.endppqpos then
      if favorSelection then
        MIDIUtils.MIDI_SetNote(take, testEvent.idx, nil, nil, selectedEvent.endppqpos, nil, nil, nil, nil)
      else
        MIDIUtils.MIDI_SetNote(take, selectedEvent.idx, nil, nil, nil, testEvent.ppqpos, nil, nil, nil)
      end
      modified = true
    end

    if testEvent.endppqpos - testEvent.ppqpos < 1 then
      testEvent.delete = true
    end
  end
  return modified
end

local function DoCorrectOverlaps(take, event, favorSelection)
-- look backward
  local idx = event.idx + 1
  for i = idx - 1, 1, -1 do
    if CorrectOverlapForEvent(take, noteEvents[i], event, favorSelection) then break end
  end
  -- look forward
  for i = idx + 1, #noteEvents do
    if CorrectOverlapForEvent(take, noteEvents[i], event, favorSelection) then break end
  end
end

local function CorrectOverlaps(take, favorSelection)
  if not EnsureTransaction(take) then return false end
  for _, event in ipairs(noteEvents) do
    if event:IsSelected() then
      DoCorrectOverlaps(take, event, favorSelection)
    end
  end
  return true
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_CorrectOverlaps = function (take, favorSelection)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(favorSelection, 'boolean', true)
  )
  return select(2, xpcall(CorrectOverlaps, OnError, take, favorSelection or false))
end

-----------------------------------------------------------------------------
------------------------------- TRANSACTIONS --------------------------------

local function MIDI_OpenWriteTransaction(take)
  EnsureTake(take)
  openTransaction = take
end

local function MIDI_CommitWriteTransaction(take, refresh, dirty)
  if not EnsureTransaction(take) then return false end

  if MIDIUtils.CORRECT_OVERLAPS then
    CorrectOverlaps(take, MIDIUtils.CORRECT_OVERLAPS_FAVOR_SELECTION)
  end
  local newMIDIString = ''
  local lastPPQPos = 0
  -- iterate sorted to avoid (REAPER Inline MIDI Editor) problems with offset calculation
  for _, event in spairs(MIDIEvents, function(t, a, b) return t[a].ppqpos < t[b].ppqpos end) do
    event.offset = event.ppqpos - lastPPQPos
    lastPPQPos = event.ppqpos
    local MIDIStr = event:GetMIDIString()
    if event.delete then
      event.flags = 0
      MIDIStr = event:SetMIDIString('')
    elseif event.recalcMIDI then
      if event:IsChannelEvt() then
        local b1 = string.char(event.chanmsg | event.chan)
        local b2 = string.char(event.msg2)
        local b3 = string.char(event.msg3)
        MIDIStr = event:SetMIDIString(table.concat({ b1, b2, b3 }))
      end
    end
    event.MIDI = string.pack('i4Bs4', event.offset, event.flags, MIDIStr)
    newMIDIString = newMIDIString .. event.MIDI

    -- handle any BezierEvents
    if event:is_a(CCEvent) and event.hasBezier then
      local bezEvent = bezTable[event.idx + 1]
      if bezEvent and bezEvent.ccIdx == event.idx then
        local bezString = bezEvent.MIDI --string.pack('i4Bs4', bezEvent.offset, bezEvent.flags, bezEvent.msg)
        newMIDIString = newMIDIString .. bezString
      end
    end
  end

  r.MIDI_DisableSort(take)
  r.MIDI_SetAllEvts(take, newMIDIString .. MIDIStringTail)
  r.MIDI_Sort(take)
  openTransaction = nil

  if refresh then MIDIUtils.MIDI_InitializeTake(take) end -- update the tables based on the new data
  if dirty then r.MarkTrackItemsDirty(r.GetMediaItemTake_Track(take), r.GetMediaItemTake_Item(take)) end

  return true
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_OpenWriteTransaction = function(take)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*')
  )
  return select(2, xpcall(MIDI_OpenWriteTransaction, OnError, take))
end

MIDIUtils.MIDI_CommitWriteTransaction = function(take, refresh, dirty)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(refresh, 'boolean', true),
    MakeTypedArg(dirty, 'boolean', true)
  )
  return select(2, xpcall(MIDI_CommitWriteTransaction, OnError, take, refresh, dirty))
end

-----------------------------------------------------------------------------
----------------------------------- NOTES -----------------------------------

local function MIDI_GetNote(take, idx)
  EnsureTake(take)
  local event = noteEvents[idx + 1]
  if event and event:is_a(NoteOnEvent) and event.idx == idx and not event.delete then
    local noteoff = MIDIEvents[event.noteOffIdx]
    return true, event.flags & 1 ~= 0 and true or false, event.flags & 2 ~= 0 and true or false,
      event.ppqpos, event.endppqpos, event.chan, event.msg2, event.msg3, noteoff and noteoff.msg3 or 0
  end
  return false, false, false, 0, 0, 0, 0, 0
end

local function AdjustNoteOff(noteoff, param, val)
  noteoff[param] = val
  noteoff.recalcMIDI = true
end

local function MIDI_SetNote(take, idx, selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel)
  if not EnsureTransaction(take) then return false end
  local rv = false
  local event = noteEvents[idx + 1]
  if event and event:is_a(NoteOnEvent) and event.idx == idx and not event.delete then
    local noteoff = MIDIEvents[event.noteOffIdx]
    --if not noteoff then r.ShowConsoleMsg('not noteoff in setnote\n') end

    if selected ~= nil then
      if selected then event.flags = event.flags | 1
      else event.flags = event.flags & ~1 end
      AdjustNoteOff(noteoff, 'flags', event.flags)
    end
    if muted ~= nil then
      if muted then event.flags = event.flags | 2
      else event.flags = event.flags & ~2 end
      AdjustNoteOff(noteoff, 'flags', event.flags)
    end
    if ppqpos then
      local diff = ppqpos - event.ppqpos
      event.ppqpos = ppqpos
    end
    if endppqpos then
      AdjustNoteOff(noteoff, 'ppqpos', endppqpos)
      event.endppqpos = noteoff.ppqpos
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
    if relvel then
      AdjustNoteOff(noteoff, 'msg3', relvel & 0x7F)
    end
    event.recalcMIDI = true
    rv = true
  end
  return rv
end

local function MIDI_InsertNote(take, selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel)
  if not EnsureTransaction(take) then return false end
  local lastEventPPQ = #MIDIEvents ~= 0 and MIDIEvents[#MIDIEvents].ppqpos or 0
  local newNoteOn = NoteOnEvent(ppqpos,
                                ppqpos - lastEventPPQ,
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
                                    string.char(relvel and (relvel & 0x7F) or 0)
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

MIDIUtils.MIDI_SetNote = function(take, idx, selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(idx, 'number'),
    MakeTypedArg(selected, 'boolean', true),
    MakeTypedArg(muted, 'boolean', true),
    MakeTypedArg(ppqpos, 'number', true),
    MakeTypedArg(endppqpos, 'number', true),
    MakeTypedArg(chan, 'number', true),
    MakeTypedArg(pitch, 'number', true),
    MakeTypedArg(vel, 'number', true),
    MakeTypedArg(relvel, 'number', true)
  )
  return select(2, xpcall(MIDI_SetNote, OnError, take, idx, selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel))
end

MIDIUtils.MIDI_InsertNote = function(take, selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*'),
    MakeTypedArg(selected, 'boolean'),
    MakeTypedArg(muted, 'boolean'),
    MakeTypedArg(ppqpos, 'number'),
    MakeTypedArg(endppqpos, 'number'),
    MakeTypedArg(chan, 'number'),
    MakeTypedArg(pitch, 'number'),
    MakeTypedArg(vel, 'number'),
    MakeTypedArg(relvel, 'number', true)
  )
  return select(2, xpcall(MIDI_InsertNote, OnError, take, selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel))
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
  if event.hasBezier then
    bezEvent = bezTable[event.idx + 1]
  --  if not bezEvent then
  --   -- this would be catastrophic, but just for debugging
  --   for k, v in pairs(bezTable) do -- use pairs, indices may be non-contiguous
  --     if v.ccIdx == idx then
  --       bezEvent = v
  --       event.hasBezier = true
  --       break
  --     end
  --   end
  end
  if bezEvent then return true, bezEvent end
  return false
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
  local rv, bezEvent = FindBezierData(idx, event)
  if rv and bezEvent then
    bezEvent.msg = bezMsg -- update in place
    bezEvent.MIDI = string.pack('i4Bs4', bezEvent.offset, bezEvent.flags, bezEvent.msg)
    bezEvent.ccIdx = idx
    event.hasBezier = true
    return true
  else
    bezEvent = BezierEvent(event.ppqpos, 0, 0, bezMsg)
    bezEvent.ccIdx = idx
    bezTable[idx + 1] = bezEvent
    event.hasBezier = true
    return true
  end
  return false
end

local function DeleteBezierData(idx, event)
  local rv, bezEvent = FindBezierData(idx, event)
  if rv and bezEvent then
    rv = false
    local ev = ccEvents[bezEvent.ccIdx + 1]
    if ev:is_a(CCEvent) and ev.idx == bezEvent.ccIdx and ev.hasBezier then
      bezTable[ev.idx + 1] = nil
      ev.hasBezier = false
      rv = true
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
    local rv, _, bztension = GetBezierData(idx, event)
    return true, ((event.flags & 0xF0) >> 4) & 7, rv and bztension or 0.
  end
  return false, 0, 0.
end

local function MIDI_SetCCShape(take, idx, shape, beztension)
  EnsureTransaction(take)
  local event = ccEvents[idx + 1]
  if event and event:is_a(CCEvent) and event.idx == idx and not event.delete then
    event.flags = event.flags & ~0xF0
    -- flag high 4 bits for CC shape: &16=linear, &32=slow start/end, &16|32=fast start, &64=fast end, &64|16=bezier
    event.flags = event.flags | ((shape & 0x7) << 4)
    event.recalcMIDI = true
    if shape == 5 and beztension then
      return SetBezierData(idx, event, 0, beztension)
    else
      DeleteBezierData(idx, event)
    end
    return true
  end
  return false
end

local function MIDI_InsertCC(take, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
  if not EnsureTransaction(take) then return false end
  local lastEventPPQ = #MIDIEvents ~= 0 and MIDIEvents[#MIDIEvents].ppqpos or 0
  chanmsg = chanmsg < 0xA0 or chanmsg >= 0xF0 and 0xB0 or chanmsg
  local newFlags = FlagsFromSelMute(selected, muted)
  local defaultCCShape = ReadREAPERConfigVar_Int('midiccenv') or 0
  if defaultCCShape ~= -1 then
    defaultCCShape = defaultCCShape & 7
    if defaultCCShape >= 0 and defaultCCShape <= 5 then
      newFlags = newFlags | (defaultCCShape << 4)
    end
  end

  local newCC = CCEvent(ppqpos,
                        ppqpos - lastEventPPQ,
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
    DeleteBezierData(idx, event)
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
  local lastEventPPQ = #MIDIEvents ~= 0 and MIDIEvents[#MIDIEvents].ppqpos or 0
  local newTextSysex = MakeEvent(ppqpos,
                                 ppqpos - lastEventPPQ,
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
  local lastEventPPQ = #MIDIEvents ~= 0 and MIDIEvents[#MIDIEvents].ppqpos or 0
  local newOffset = ppqpos - lastEventPPQ
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
  local noteOffset = ReadREAPERConfigVar_Int('midioctoffs') or -0xFF
  if noteOffset ~= -0xFF then
    noteOffset = noteOffset - 1 -- 1 == 0 in the interface (C4)
    octave = octave + noteOffset
  end
  return notename..octave
end

local function MIDI_DebugInfo(take)
  EnsureTake(take)
  local noteon = 0
  local noteoff = 0
  local cc = 0
  local sysex = 0
  local text = 0
  local bezier = 0
  local unknown = 0
  for _, event in ipairs(MIDIEvents) do
    if event:is_a(NoteOnEvent) then noteon = noteon + 1
    elseif event:is_a(NoteOffEvent) then noteoff = noteoff + 1
    elseif event:is_a(CCEvent) then
      cc = cc + 1
      local _, bezEvt = FindBezierData(event.idx, event)
      if bezEvt then
        bezier = bezier + 1
      end
    elseif event:is_a(SysexEvent) then sysex = sysex + 1
    elseif event:is_a(MetaEvent) then text = text + 1
    elseif event:is_a(BezierEvent) then bezier = bezier + 1
    else unknown = unknown + 1
    end
  end
  return noteon, noteoff, cc, sysex, text, bezier, unknown
end

-----------------------------------------------------------------------------

MIDIUtils.MIDI_NoteNumberToNoteName = function(notenum, names)
  EnforceArgs(
    MakeTypedArg(notenum, 'number'),
    MakeTypedArg(names, 'table', true)
  )
  return select(2, xpcall(MIDI_NoteNumberToNoteName, OnError, notenum, names))
end

MIDIUtils.MIDI_DebugInfo = function(take)
  EnforceArgs(
    MakeTypedArg(take, 'userdata', false, 'MediaItem_Take*')
  )
  return select(2, xpcall(MIDI_DebugInfo, OnError, take))
end

-----------------------------------------------------------------------------
----------------------------------- EXPORT ----------------------------------

return MIDIUtils
