--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

-- TODO: how do we want to go about filtering 14-bit CCs??

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. '?.lua;' -- GET DIRECTORY FOR REQUIRE
local reduce = require 'RamerDouglasPeucker'

local lastMIDIMessage = ''
local MIDIEvents = {}

local defaultReduction = 5
local defaultPbscale = 10

function GenerateEventListFromAllEvents(take, fun)
  local events = {}
  local stringPos = 1 -- Position inside MIDIString while parsing
  local ppqpos = 0

  local pbSnap = 0
  if reaper.MIDIEditorFlagsForTrack then -- v7
    _, pbSnap = reaper.MIDIEditorFlagsForTrack(reaper.GetMediaItemTake_Track(take), 0, 0, false)
  end

  MIDIEvents = {}

  local _, MIDIString = reaper.MIDI_GetAllEvts(take, '') -- empty string for backward compatibility with older REAPER versions
  while stringPos < MIDIString:len() - 12 do -- -12 to exclude final All-Notes-Off message
    local offset, flags, msg, newStringPos = string.unpack('i4Bs4', MIDIString, stringPos)

    ppqpos = ppqpos + offset

    MIDIEvents[#MIDIEvents + 1] = { ppqpos = ppqpos, offset = offset, flags = flags, msg = msg }

    if fun(MIDIEvents[#MIDIEvents]) == true then
      local b1 = msg:byte(1)
      local status = b1 & 0xF0
      if status >= 0xA0 and status <= 0xF0 then
        MIDIEvents[#MIDIEvents].wantsdelete = 1 -- we will delete this point before rewriting
        AddPointToList({ events = events }, { idx = -1, src = #MIDIEvents, ppqpos = ppqpos, chanmsg = b1 & 0xF0, chan = b1 & 0x0F, msg2 = msg:byte(2), msg3 = msg:byte(3), selected = (flags & 1 ~= 0) and true or false, muted = (flags & 2 ~= 0) and true or false, shape = (flags & 0xF0) >> 4 }, pbSnap)
      end
    end
    stringPos = newStringPos
  end
  lastMIDIMessage = MIDIString:sub(-12)
  return { events = events }
end

function GenerateEventListFromFilteredEvents(take, fun)
  local eventlist = { events = {}, todelete = { maxidx = 0 } }
  local wants = GetVisibleCCs(take)

  local pbSnap = 0
  if reaper.MIDIEditorFlagsForTrack then -- v7
    _, pbSnap = reaper.MIDIEditorFlagsForTrack(reaper.GetMediaItemTake_Track(take), 0, 0, false)
  end

  local _, _, ccevtcnt = reaper.MIDI_CountEvts(take) -- only filtered events
  for idx = 0, ccevtcnt - 1 do
    local event = { idx = idx }
    _, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3 = reaper.MIDI_GetCC(take, idx)
    _, event.shape = reaper.MIDI_GetCCShape(take, idx)
    if fun(event) == true then
      for _, v in pairs(wants) do
        if ((v.status & 0xF0) == event.chanmsg)
          and ((event.chanmsg == 0xB0 and v.which == event.msg2) or true)
        then
          AddPointToList(eventlist, event, pbSnap)
          break
        end
      end
    end
  end
  return eventlist
end

function GetReduction()
  if not reduction then
    if reaper.HasExtState('sockmonkey72_ThinCCs', 'level') then
      reduction = tonumber(reaper.GetExtState('sockmonkey72_ThinCCs', 'level'))
    end
    if not reduction then reduction = defaultReduction end
  end
  return reduction
end

function AddPointToList(eventlist, event, pbSnap)
  local curlist = nil

  local status = event.chanmsg & 0xF0
  if status < 0xA0  or status >= 0xF0 then return end

  local is3byte = status == 0xA0 or status == 0xB0
  local is2byte = status == 0xC0 or status == 0xD0
  local isPB = status == 0xE0
  local isSnapped = isPB and pbSnap ~= 0

  status = event.chanmsg | event.chan

  for _, v in pairs(eventlist.events) do
    local which = (is2byte or isPB) and 0 or event.msg2
    if v.status == status and v.which == which then
      curlist = v.points
      break
    end
  end
  if not curlist then
    local entry = { status = status, which = (is2byte or isPB) and 0 or event.msg2, points = {} }
    eventlist.events[#eventlist.events + 1] = entry
    curlist = entry.points
  end

  if curlist then
    local value = is2byte and event.msg2 or event.msg3
    if #curlist > 0 and (isSnapped or curlist[#curlist].shape == 0) then -- previous was square, add a point
      curlist[#curlist + 1] = { ppqpos = event.ppqpos - 1, value = curlist[#curlist].value, idx = -1, selected = curlist[#curlist].selected, muted = curlist[#curlist].muted, shape = event.shape, src = event.src }
    end
    curlist[#curlist + 1] = { ppqpos = event.ppqpos, value = value, idx = event.idx, selected = event.selected, muted = event.muted, shape = event.shape, src = event.src }
    if isPB then
      curlist[#curlist].value = event.msg2 | (event.msg3 << 7)
    end
    if eventlist.todelete then
      eventlist.todelete[event.idx] = 1
      eventlist.todelete.maxidx = event.idx
    end
  end
end

function PrepareList(eventlist)
  -- exclude tables with fewer than 3 points
  for _, v in pairs(eventlist.events) do
    if #v.points < 3 then
      for _, p in pairs(v.points) do
        if eventlist.todelete then
          if p.idx >= 0 then
            eventlist.todelete[p.idx] = nil
          end
        end
        if p.src then
          MIDIEvents[p.src].wantsdelete = nil
        end
      end
      v.points = {}
    end
  end

  local hasEvents = false
  for _, v in pairs(eventlist.events) do
    if #v.points > 0 then
      hasEvents = true
      break
    end
  end

  return hasEvents
end

function DoReduction(events, take)
  local newevents = {}

  local reduction = GetReduction()
  local pbscale

  if reaper.HasExtState('sockmonkey72_ThinCCs', 'pbscale') then
    pbscale = tonumber(reaper.GetExtState('sockmonkey72_ThinCCs', 'pbscale'))
  end
  if not pbscale then pbscale = defaultPbscale end

  if reaper.MIDIEditorFlagsForTrack then -- v7
    local _, pbSnap = reaper.MIDIEditorFlagsForTrack(reaper.GetMediaItemTake_Track(take), 0, 0, false)
    if pbSnap ~= 0 then pbscale = 1 end -- don't reduce snapped events into lines if possible
  end

  -- iterate, reduce points
  for _, v in pairs(events) do
    local status = v.status & 0xF0
    local is3byte = status == 0xA0 or status == 0xB0
    local is2byte = status == 0xC0 or status == 0xD0
    local isPB = status == 0xE0

    reduction = isPB and reduction * pbscale or reduction

    local newpoints = reduce(v.points, reduction, false, 'ppqpos', 'value')
    for _, p in pairs(newpoints) do
      local b2 = is2byte and p.value or v.which
      local b3 = is2byte and 0 or p.value
      if isPB then
        b2 = p.value & 0x7F
        b3 = (p.value >> 7) & 0x7F
      end

      local flags = p.shape << 4
      if p.muted == true then flags = flags | 2 end
      if p.selected == true then flags = flags | 1 end

      newevents[#newevents + 1] = { ppqpos = p.ppqpos, flags = flags, b1 = v.status, b2 = b2, b3 = b3 }
    end
  end
  return newevents
end

function PerformReduction(eventlist, take)
  reaper.MIDI_DisableSort(take)

  -- reverse iterate, delete points
  for i = eventlist.todelete.maxidx, 0, -1 do
    if eventlist.todelete[i] then
      reaper.MIDI_DeleteCC(take, i)
    end
  end

  reaper.MIDI_Sort(take)
  reaper.MIDI_DisableSort(take)

  reaper.MIDIEditor_OnCommand(reaper.MIDIEditor_GetActive(), 40671) -- unselect all CC events

  local reduced = DoReduction(eventlist.events, take)
  for _, p in pairs(reduced) do
    reaper.MIDI_InsertCC(take, 1, (p.flags & 2 ~= 0) and true or false, p.ppqpos, p.b1 & 0xF0, p.b1 & 0xF, p.b2, p.b3)
  end

  reaper.MIDI_Sort(take)
  reaper.MIDIEditor_OnCommand(reaper.MIDIEditor_GetActive(), 42080) -- set selected points to linear
end

function PerformReductionForAllEvents(eventlist, take)
  if #MIDIEvents == 0 then return end

  local reduced = DoReduction(eventlist.events, take)
  table.sort(reduced, function (e1, e2) return e1.ppqpos < e2.ppqpos end) -- sort by ppqpos

  -- apply negative offset
  reaper.MIDI_DisableSort(take)
  local lastppq = MIDIEvents[#MIDIEvents].ppqpos
  MIDIEvents[#MIDIEvents + 1] = { ppqpos = 0, offset = -lastppq, flags = 0, msg = '' }

  -- insert new events (now in eventlist.events) -- they are sorted by ppqpos
  lastppq = 0
  for _, v in pairs(reduced) do
    MIDIEvents[#MIDIEvents + 1] = { ppqpos = v.ppqpos, offset = v.ppqpos - lastppq, flags = v.flags, msg = table.concat({string.char(v.b1), string.char(v.b2), string.char(v.b3)}) }
    lastppq = v.ppqpos
  end

  -- write the raw MIDI table
  local MIDIData = {}
  for _, v in pairs(MIDIEvents) do
    if v.wantsdelete == 1 then
      MIDIData[#MIDIData + 1] = string.pack('i4Bs4', v.offset, 0, '')
    else
      MIDIData[#MIDIData + 1] = string.pack('i4Bs4', v.offset, v.flags, v.msg)
    end
  end

  reaper.MIDI_SetAllEvts(take, table.concat(MIDIData) .. lastMIDIMessage)
  reaper.MIDI_Sort(take)
end

function GetVisibleCCs(take)
  local wants = {}
  local item = reaper.GetMediaItemTake_Item(take)

  if item then
    local _, str = reaper.GetItemStateChunk(item, '', false)
    -- reaper.ShowConsoleMsg('str: '..str..'\n')
    local lanes = {}
    local i = 0
    while true do
      local index, _, idx = string.find(str, 'VELLANE (%d+)', i + 1)
      if index == nil then break end
      i = index
      -- reaper.ShowConsoleMsg('idx: '..idx..'\n')
      table.insert(lanes, tonumber(idx))
    end

    -- this is unnecessary, REAPER only provides filtered events via the MIDI_CountEvts/MIDI_GetCC API
    -- you can use MIDI_GetAllEvts to see filtered events, so adapting the main time selection
    -- script to operate on all evts.
    -- local _, _, filterchan, filteractive = string.find(str, 'EVTFILTER (%-?%d+)%s+%-?%d+%s+%-?%d+%s+%-?%d+%s+%-?%d+%s+%-?%d+%s+(%-?%d+)')
    -- fchan = tonumber(filterchan)
    -- if fchan > 0 then
    --   if tonumber(filteractive) == 0 then
    --     fchan = 0
    --   end
    -- end

    for _, v in pairs(lanes) do
      local status = 0
      local which = 0
      if v >= 0 and v <= 127 then
        status = 0xB0 -- CC
        which = v
      elseif v == 168 then
        status = 0xA0 -- poly aftertouch
      elseif v == 128 then status = 0xE0 -- pitch bend
      elseif v == 129 then status = 0xC0 -- program change
      elseif v == 130 then status = 0xD0 -- channel pressure
      end
      if status ~= 0 then
        wants[#wants + 1] = { status = status, which = which }
      end
    end
  end
  return wants
end