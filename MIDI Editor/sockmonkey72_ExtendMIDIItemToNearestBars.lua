-- @description Extend MIDI Item to Nearest Bars
-- @version 1.0.4
-- @author sockmonkey72
-- @about
--   # Extend MIDI Item to Nearest Bars
--   Extend both ends of a MIDI item to the nearest full measure. The item can only get larger.
-- @changelog
--   resident (smandrap): fix previously selected media items getting extended if nothing was recorded on Rec/stop
-- @provides
--   [main=main] sockmonkey72_ExtendMIDIItemToNearestBars.lua
--   [main=main] sockmonkey72_ExtendRecordedMIDIItemsToNearestMeasureResident.lua

local reaper = reaper

reaper.Undo_BeginBlock2(0)
local selectedItems = reaper.CountSelectedMediaItems(0)
for i = 0, selectedItems - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  take = reaper.GetActiveTake(item)
  if take and reaper.TakeIsMIDI(take) then
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    local _, startMeasures = reaper.TimeMap2_timeToBeats(0, pos)
    local endBeats, endMeasures, endCml = reaper.TimeMap2_timeToBeats(0, pos + len)
    if endBeats < 0.00001 then
      endCml = 0
    end
    local startOfMeasure = reaper.TimeMap2_beatsToTime(0, 0, startMeasures)
    local endOfMeasure = reaper.TimeMap2_beatsToTime(0, endCml, endMeasures)

    reaper.MIDI_SetItemExtents(item, reaper.TimeMap2_timeToQN(0, startOfMeasure), reaper.TimeMap2_timeToQN(0, endOfMeasure))
    reaper.MarkTrackItemsDirty(reaper.GetMediaItem_Track(item), item)
  end
end
reaper.Undo_EndBlock2(0, "Resize MIDI Item(s)", -1)
