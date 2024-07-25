-- @description Tempo-Map MIDI Note to Beat
-- @version 0.0.1
-- @author sockmonkey72
-- @about
--   # Tempo-Map MIDI Note to Beat
--   Assign a beat time to the first selected note found in the selected items.
--   A tempo change will be inserted (or adjusted) to ensure that the note falls
--   at precisely that beat time. If the item is not properly timebased (the item
--   must have timebase = time; the media must have 'Ignore Project Tempo' enabled)
--   these adjustments will also be made, along with a split at the previous tempo
--   marker, if necessary.
-- @changelog
--   - initial
-- @provides
--   {TempoMap}/*
--   [main=midi_editor,midi_inlineeditor,midi_eventlisteditor] sockmonkey72_TempoMapMIDINoteToBeatPrompt.lua
--   [main=midi_editor,midi_inlineeditor,midi_eventlisteditor] sockmonkey72_TempoMapMIDINoteToPrevBeat.lua
--   [main=midi_editor,midi_inlineeditor,midi_eventlisteditor] sockmonkey72_TempoMapMIDINoteToNextBeat.lua
--   [main=midi_editor,midi_inlineeditor,midi_eventlisteditor] sockmonkey72_TempoMapMIDINoteToPrevMeasure.lua
--   [main=midi_editor,midi_inlineeditor,midi_eventlisteditor] sockmonkey72_TempoMapMIDINoteToNextMeasure.lua

local r = reaper

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
local tm = require "TempoMap/TempoMapUtils"
if not tm then return end

local infoTab = tm.GetReference()
if not infoTab then return end

local timePosStr = tm.CalcPrevBeat(infoTab.projPos)

local success
success, timePosStr = r.GetUserInputs('Target Position', 1, 'Target (meas.beat.frac)', timePosStr)
if not success then return end

local timePos = r.parse_timestr_pos(timePosStr, 1)

if tm.ValidateTargetTime(timePos, infoTab) then
    tm.ProcessToTargetTime(timePos, infoTab)
end

