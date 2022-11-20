--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local reaper = reaper

local _, _, sectionID = reaper.get_action_context()
-- ---------------- MIDI Editor ---------- Event List ------- Inline Editor
local isME = sectionID == 32060 or sectionID == 32061 or sectionID == 32062
if not isME then return end

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "ThinCCs/ThinCCUtils"

local starttime, endtime = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
if starttime == endtime then return end -- no time selection

local take = reaper.MIDIEditor_GetTake(reaper.MIDIEditor_GetActive())
if take then
  local tt = {}
  local dt = { maxidx = 0 }
  local wants = {}
  local fchan = 0

  local item = reaper.GetMediaItemTake_Item(take)
  if item then
    local _, str = reaper.GetItemStateChunk(item, "", false)
    -- reaper.ShowConsoleMsg("str: "..str.."\n")
    local lanes = {}
    local i = 0
    while true do
      local index, _, idx = string.find(str, "VELLANE (%d+)", i + 1)
      if index == nil then break end
      i = index
      table.insert(lanes, tonumber(idx))
    end
    -- this is unnecessary, REAPER only provides filtered events via the MIDI_CountEvts/MIDI_GetCC API
    -- you can use MIDI_GetAllEvts to see filtered events, so adapting the main time selection
    -- script to operate on all evts.
    -- local _, _, filterchan, filteractive = string.find(str, "EVTFILTER (%-?%d+)%s+%-?%d+%s+%-?%d+%s+%-?%d+%s+%-?%d+%s+%-?%d+%s+(%-?%d+)")
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
        status = 0xB0
        which = v
      elseif v == 128 then status = 0xE0
      elseif v == 129 then status = 0xC0
      elseif v == 130 then status = 0xD0
      end
      if status ~= 0 then
        wants[#wants + 1] = { status = status | (fchan > 0 and fchan - 1 or 0), which = which }
      end
    end
  end

  local _, _, ccevtcnt = reaper.MIDI_CountEvts(take) -- only filtered events

  local ppqstart = reaper.MIDI_GetPPQPosFromProjTime(take, starttime)
  local ppqend = reaper.MIDI_GetPPQPosFromProjTime(take, endtime)

  for idx = 0, ccevtcnt - 1 do
    local event = { idx = idx }
    _, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3 = reaper.MIDI_GetCC(take, idx)
    _, event.shape = reaper.MIDI_GetCCShape(take, idx)
    if event.ppqpos >= ppqstart and event.ppqpos <= ppqend then
      local status = event.chanmsg | event.chan
      for _, v in pairs(wants) do
        if (fchan > 0 and (v.status == status) or ((v.status & 0xF0) == (status & 0xF0)))
          and (status == 0xB0 and (v.which == event.msg2) or true)
        then
          AddPointToList({ events = tt, todelete = dt }, event)
          break
        end
      end
    end
  end

  local hasEvents = PrepareList({ events = tt, todelete = dt })
  if not hasEvents then return end

  reaper.Undo_BeginBlock2(0)
  PerformReduction({ events = tt, todelete = dt }, take)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), reaper.GetMediaItemTake_Item(take))
  reaper.Undo_EndBlock2(0, "Thin Visible CCs In Time Selection", -1)
end
