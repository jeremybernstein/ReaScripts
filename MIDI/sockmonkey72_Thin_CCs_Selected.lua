-- @description Thin MIDI CC Events
-- @version 1.6.0
-- @author sockmonkey72
-- @about
--   # Thin MIDI CC Events
--   Reduce density of MIDI CC events
-- @changelog
--   - add 'main' context script for reducing selected items
--   - add new script for only affecting visible items, versus all items in time selection
--   - fix undo
-- @provides
--   {ThinCCs}/*
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Thin_CCs_Selected.lua
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Thin_CCs_In_Time_Selection.lua
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Thin_CCs_Setup.lua
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Thin_CCs_Visible_In_Time_Selection.lua
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Thin_CCs_All.lua
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Thin_CCs_All_Visible.lua
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Thin_CCs_In_Lane_Under_Mouse.lua
--   [main=main] sockmonkey72_Thin_CCs_In_Selected_Items.lua

local reaper = reaper

local _, _, sectionID = reaper.get_action_context()
-- ---------------- MIDI Editor ---------- Event List ------- Inline Editor
local isME = sectionID == 32060 or sectionID == 32061 or sectionID == 32062
if not isME then return end

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "ThinCCs/ThinCCUtils"

local take = reaper.MIDIEditor_GetTake(reaper.MIDIEditor_GetActive())
if take then
  local eventlist = { events = {}, todelete = { maxidx = 0 }}
  local idx = reaper.MIDI_EnumSelCC(take, -1)

  while idx >= 0 do
    local event = { idx = idx }
    _, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3 = reaper.MIDI_GetCC(take, idx)
    _, event.shape = reaper.MIDI_GetCCShape(take, idx)
    if event.selected then -- overkill here, but I'm owning it
      AddPointToList(eventlist, event)
    end
    idx = reaper.MIDI_EnumSelCC(take, idx)
  end

  local hasEvents = PrepareList(eventlist)
  if not hasEvents then return end

  reaper.Undo_BeginBlock2(0)
  PerformReduction(eventlist, take)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), reaper.GetMediaItemTake_Item(take))
  reaper.Undo_EndBlock2(0, "Thin Selected CCs", -1)
end
