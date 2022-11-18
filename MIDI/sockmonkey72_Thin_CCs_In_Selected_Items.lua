--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local reaper = reaper

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "ThinCCs/ThinCCUtils"

local numSelItems = reaper.CountSelectedMediaItems(0)
for i = 0, numSelItems do
  local item = reaper.GetMediaItem(0, i)
  if item then
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local tt = {}
      local dt = { maxidx = 0 }
      local _, _, ccevtcnt = reaper.MIDI_CountEvts(take)

      for idx = 0, ccevtcnt - 1 do
        local event = { idx = idx }
        _, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3 = reaper.MIDI_GetCC(take, idx)
        _, event.shape = reaper.MIDI_GetCCShape(take, idx)
        AddPointToList({ events = tt, todelete = dt }, event)
      end

      local hasEvents = PrepareList({ events = tt, todelete = dt })
      if not hasEvents then return end

      reaper.Undo_BeginBlock2(0)
      PerformReduction({ events = tt, todelete = dt }, take)

      -- from the ME, we need to set all of the events to linear now because
      -- the built-in functionality won't work if there's no open ME
      reaper.MIDI_DisableSort(take)
      for idx = 0, ccevtcnt - 1 do
        reaper.MIDI_SetCCShape(take, idx, 1, 0)
      end
      reaper.MIDI_Sort(take)

      reaper.Undo_EndBlock2(0, "Thin CCs In Selected Items", -1)
    end
  end
end
