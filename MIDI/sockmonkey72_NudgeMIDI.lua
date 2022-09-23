-- @description Nudge MIDI
-- @version 1.1
-- @author sockmonkey72
-- @about
--   # Nudge MIDI
--   MIDI Editor script to nudge MIDI note, CC and pitch bend events. Thanks to Stevie for the inspiration.
--   The main script will present a dialog to set a nudge amount in ticks
--   The two 'UsingLastSetting' scripts will use that value for 'faceless' nudging
--   left or right using the previously set value
--   Note that notes and CCs/pitch bend messages work slightly differently. Notes will be truncated and
--    eventually deleted if they collide with another note to the left or right.
--   CCs and pitch bend messages will simply delete anything in their path.
--   If you associate these actions with keyboard shortcuts, you can hold the key down for a repeated nudge
--   with consolidated undo points (requires js_ReaScriptAPI extension: https://forum.cockos.com/showthread.php?t=212174).
-- @changelog
--   initial
-- @provides
--   {NudgeMIDI}/*
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_NudgeMIDI.lua
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_NudgeMIDIForwardUsingLastSetting.lua
--   [main=midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_NudgeMIDIBackwardUsingLastSetting.lua

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "NudgeMIDI/NudgeMIDIUtils"

local reaper = reaper

local defaultNudge = "10"
if reaper.HasExtState("sockmonkey72_NudgeMIDI", "ticks") then
  defaultNudge = reaper.GetExtState("sockmonkey72_NudgeMIDI", "ticks")
end

local rv, retvals_csv = reaper.GetUserInputs("Nudge MIDI", 1, "Ticks", defaultNudge)

if rv ~= true then return end

reaper.SetExtState("sockmonkey72_NudgeMIDI", "ticks", retvals_csv, true)

local nudge = tonumber(retvals_csv)
if nudge then
  nudge = math.floor(nudge)
else
  return
end

if Setup(nudge, false) then
  Nudge()
end
