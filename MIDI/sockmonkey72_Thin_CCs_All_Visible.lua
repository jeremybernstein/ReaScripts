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

local take = reaper.MIDIEditor_GetTake(reaper.MIDIEditor_GetActive())
if take then
  local eventlist = GenerateEventListFromFilteredEvents(take, function (ev) return true end)

  local hasEvents = PrepareList(eventlist)
  if not hasEvents then return end

  reaper.Undo_BeginBlock2(0)
  PerformReduction(eventlist, take)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), reaper.GetMediaItemTake_Item(take))
  reaper.Undo_EndBlock2(0, "Thin Visible CCs In Editor Item", -1)
end
