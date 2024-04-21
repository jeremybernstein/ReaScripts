--[[
   * Author: sockmonkey72 / smandrap
   * Licence: MIT
   * Version: 1.01
   * NoIndex: true
--]]

local DELETE_EMPTY = false

local reaper = reaper
reaper.set_action_options(5)
local swsok = reaper.CF_GetSWSVersion and true or false

local playstate = reaper.GetPlayState()
local prev_selitems = {}

local GetPlayState = reaper.GetPlayState


local function RemoveEmptyTake(item, take)
  if reaper.MIDI_CountEvts(take) == 0 then
    reaper.NF_DeleteTakeFromItem(item, reaper.GetMediaItemTakeInfo_Value(take, 'IP_TAKENUMBER'))
  end
  if reaper.CountTakes(item) == 0 then
    reaper.DeleteTrackMediaItem(reaper.GetMediaItemTrack(item), item)
  end
end

local function table_delete(t)
  for i = 0, #t do t[i] = nil end
end

local function ExtendRecordedMidiItems()
  if reaper.GetSelectedMediaItem(0, 0) == prev_selitems[1] then return end
  local selectedItems = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    selectedItems[#selectedItems + 1] = reaper.GetSelectedMediaItem(0, i)
  end

  for i = 1, #selectedItems do
    local item = selectedItems[i]
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      if DELETE_EMPTY and swsok then RemoveEmptyTake(item, take) end
      if reaper.ValidatePtr(item, "MediaItem*") then
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

        local _, startMeasures = reaper.TimeMap2_timeToBeats(0, pos)
        local endBeats, endMeasures, endCml = reaper.TimeMap2_timeToBeats(0, pos + len)
        if endBeats < 0.00001 then
          endCml = 0
        end
        local startOfMeasure = reaper.TimeMap2_beatsToTime(0, 0, startMeasures)
        local endOfMeasure = reaper.TimeMap2_beatsToTime(0, endCml, endMeasures)

        reaper.MIDI_SetItemExtents(item, reaper.TimeMap2_timeToQN(0, startOfMeasure),
          reaper.TimeMap2_timeToQN(0, endOfMeasure))
        reaper.MarkTrackItemsDirty(reaper.GetMediaItem_Track(item), item)
      end
    end
  end
end

local function main()
  local new_playstate = GetPlayState()
  if playstate ~= 5 and new_playstate == 5 then
    for i = 0, reaper.CountSelectedMediaItems(0) do
      prev_selitems[#prev_selitems + 1] = reaper.GetSelectedMediaItem(0, i)
    end
  end
  if playstate == 5 and new_playstate ~= 5 then
    local recmode = reaper.GetToggleCommandState(40253) + reaper.GetToggleCommandState(40076)
    if recmode == 0 then ExtendRecordedMidiItems() end
  end

  playstate = new_playstate
  reaper.defer(main)
end

local function Exit()
  reaper.set_action_options(8)
end

reaper.atexit(Exit)
main()
