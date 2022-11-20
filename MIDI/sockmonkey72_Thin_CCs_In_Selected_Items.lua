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
reaper.Undo_BeginBlock2(0)
for i = 0, numSelItems do
  local item = reaper.GetSelectedMediaItem(0, i)
  if item then
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local tt = GenerateEventListFromAllEvents(take, function (me) return true end)

      local hasEvents = PrepareList({ events = tt })
      if not hasEvents then return end

      PerformReductionForAllEvents({ events = tt }, take)
      reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), item)
    end
  end
end
reaper.Undo_EndBlock2(0, "Thin CCs In Selected Items", -1)
