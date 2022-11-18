--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

-- TODO: how do we want to go about filtering 14-bit CCs??

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
local reduce = require "RamerDouglasPeucker"

function AddPointToList(eventlist, event)
  local curlist = nil

  local status = event.chanmsg & 0xF0
  if status < 0xA0  or status >= 0xF0 then return end

  local is3byte = status == 0xA0 or status == 0xB0
  local is2byte = status == 0xC0 or status == 0xD0
  local isPB = status == 0xE0

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
    if #curlist > 0 and curlist[#curlist].shape == 0 then -- previous was square, add a point
      curlist[#curlist + 1] = { ppqpos = event.ppqpos - 1, value = curlist[#curlist].value, idx = -1, selected = curlist[#curlist].selected, muted = curlist[#curlist].muted, shape = event.shape }
    end
    curlist[#curlist + 1] = { ppqpos = event.ppqpos, value = is2byte and event.msg2 or event.msg3, idx = event.idx, selected = event.selected, muted = event.muted, shape = event.shape }
    if isPB then
      curlist[#curlist].value = event.msg2 | (event.msg3 << 7)
    end
    eventlist.todelete[event.idx] = 1
    eventlist.todelete.maxidx = event.idx
  end
end

function PrepareList(eventlist)
  -- exclude tables with fewer than 3 points
  for _, v in pairs(eventlist.events) do
    if #v.points < 3 then
      for _, p in pairs(v.points) do
        if p.idx >= 0 then
          eventlist.todelete[p.idx] = nil
        end
      end
      v.points = {}
    end
  end

  local hasEvents = false
  for i = 1, eventlist.todelete.maxidx do
    if eventlist.todelete[i] then
      hasEvents = true
      break
    end
  end

  return hasEvents
end

function PerformReduction(eventlist, take)

  local defaultReduction = "10"
  if reaper.HasExtState("sockmonkey72_ThinCCs", "level") then
    defaultReduction = reaper.GetExtState("sockmonkey72_ThinCCs", "level")
  end
  local reduction = tonumber(defaultReduction)

  reaper.MIDI_DisableSort(take)

  -- reverse iterate, delete points
  for i = eventlist.todelete.maxidx, 1, -1 do
    if eventlist.todelete[i] then
      reaper.MIDI_DeleteCC(take, i)
    end
  end

  reaper.MIDI_Sort(take)
  reaper.MIDI_DisableSort(take)

  reaper.MIDIEditor_OnCommand(reaper.MIDIEditor_GetActive(), 40671) -- unselect all CC events

  -- iterate, reduce points
  for _, v in pairs(eventlist.events) do
    local status = v.status & 0xF0
    local is3byte = status == 0xA0 or status == 0xB0
    local is2byte = status == 0xC0 or status == 0xD0
    local isPB = status == 0xE0

    local newpoints = reduce(v.points, reduction, false, "ppqpos", "value")
    for _, p in pairs(newpoints) do
      local b2 = is2byte and p.value or v.which
      local b3 = is2byte and 0 or p.value
      if isPB then
        b2 = p.value & 0x7F
        b3 = (p.value >> 7) & 0x7F
      end
      reaper.MIDI_InsertCC(take, 1, p.muted, p.ppqpos, v.status & 0xF0, v.status & 0xF, b2, b3)
    end
  end

  reaper.MIDI_Sort(take)

  reaper.MIDIEditor_OnCommand(reaper.MIDIEditor_GetActive(), 42080) -- set selected points to linear
end
