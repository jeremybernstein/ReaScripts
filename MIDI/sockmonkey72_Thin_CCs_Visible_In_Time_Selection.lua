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
  local ppqstart = reaper.MIDI_GetPPQPosFromProjTime(take, starttime)
  local ppqend = reaper.MIDI_GetPPQPosFromProjTime(take, endtime)

  local eventlist = GenerateEventListFromFilteredEvents(take, function (ev) return ev.ppqpos >= ppqstart and ev.ppqpos <= ppqend end)

  local hasEvents = PrepareList(eventlist)
  if not hasEvents then return end

  reaper.Undo_BeginBlock2(0)
  PerformReduction(eventlist, take)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), reaper.GetMediaItemTake_Item(take))
  reaper.Undo_EndBlock2(0, "Thin Visible CCs In Time Selection", -1)
end
