--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

-- "Thin CCs In Last Clicked Lane" contributed by smandrap

local reaper = reaper

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "ThinCCs/ThinCCUtils"

local me = reaper.MIDIEditor_GetActive()
local take = reaper.MIDIEditor_GetTake(me)
if take then

  local ccLane = reaper.MIDIEditor_GetSetting_int(me, "last_clicked_cc_lane")

  local matchLane = 0
  if ccLane >= 0 and ccLane <= 127 then matchLane = 0xB0 -- CC
  elseif ccLane == 0x201 then matchLane = 0xE0 -- pitch bend
  elseif ccLane == 0x202 then matchLane = 0xC0 -- program change
  elseif ccLane == 0x203 then matchLane = 0xD0 -- channel pressure
  end
  if matchLane == 0 then return end

  local eventlist = GenerateEventListFromFilteredEvents(take, function (ev)
    if ev.chanmsg == matchLane then
        if matchLane == 0xB0 then
            return ev.msg2 == ccLane
        else return true
        end
    end
  end)

  local hasEvents = PrepareList(eventlist)
  if not hasEvents then return end

  reaper.Undo_BeginBlock2(0)
  PerformReduction(eventlist, take)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), reaper.GetMediaItemTake_Item(take))
  reaper.Undo_EndBlock2(0, "Thin CCs in last clicked lane", -1)
end