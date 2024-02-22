--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local reaper = reaper

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "ThinCCs/ThinCCUtils"

local REs = {}
local trackCount = reaper.CountTracks(0)
local firstTrack = -1
local lastTrack = -1

for i = 0, trackCount-1 do
  local track = reaper.GetTrack(0, i)
  if track and reaper.IsTrackVisible(track, false) then
    local rv, razorEdits = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
    if rv == true and razorEdits ~= "" then
      if firstTrack == -1 then firstTrack = i
      else lastTrack = i end

      local count = 0
      for str in string.gmatch(razorEdits, "([^%s]+)") do
        if count % 3 == 0 then
          local value = tonumber(str)
          REs[#REs + 1] = { track = track, starttime = value }
        elseif count % 3 == 1 then
          local value = tonumber(str)
          REs[#REs].endtime = value
        end
        count = count + 1
      end
    end
  end
end

reaper.Undo_BeginBlock2(0)
if #REs ~= 0 then
  for _, v in pairs(REs) do
    local track = v.track
    local itemcount = reaper.CountTrackMediaItems(track)

    for i = 0, itemcount - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local take = reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then
        local itempos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local itemlen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local additem = false
        local canbreak = false

        if (v.starttime < itempos and v.endtime < itempos) or (v.starttime > itempos + itemlen) then
          additem = false
        elseif v.starttime >= itempos and v.endtime <= itempos + itemlen then
          additem = true
          canbreak = true -- special case
        else
          additem = true
        end

        --reaper.ShowConsoleMsg("additem? " .. (additem and "yes" or "no") .. " v.start: " .. v.starttime .. " v.end: " .. v.endtime .. "\n")

        local eventlist = GenerateEventListFromAllEvents(take,
          function (me)
            local projtime = reaper.MIDI_GetProjTimeFromPPQPos(take, me.ppqpos)
            return (additem == true and projtime >= v.starttime and projtime <= v.endtime)
          end)

        local hasEvents = PrepareList(eventlist)
        if hasEvents then
          PerformReductionForAllEvents(eventlist, take)
          reaper.MarkTrackItemsDirty(track, item)
        end
      end
      if canbreak == true then break end
    end
  end
else
  local numSelItems = reaper.CountSelectedMediaItems(0)
  for i = 0, numSelItems do
    local item = reaper.GetSelectedMediaItem(0, i)
    if item then
      local take = reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then
        local eventlist = GenerateEventListFromAllEvents(take, function (me) return true end)

        local hasEvents = PrepareList(eventlist)
        if not hasEvents then return end

        PerformReductionForAllEvents(eventlist, take)
        reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), item)
      end
    end
  end
end
reaper.Undo_EndBlock2(0, "Thin CCs In Selected Items", -1)
