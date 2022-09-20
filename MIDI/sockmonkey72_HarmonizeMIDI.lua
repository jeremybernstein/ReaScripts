-- @description Harmonize MIDI
-- @version 1.3
-- @author sockmonkey72
-- @about
--   # Harmonize MIDI
--   Chromatic doubling at specified intervals (item/take, razor edit or MIDI Editor).
-- @changelog
--   initial upload
-- @provides
--   {HarmonizeMIDI}/*
--   [main=main,midi_editor] sockmonkey72_HarmonizeMIDI.lua
--   [main=main,midi_editor] sockmonkey72_HarmonizeMIDIUsingLastSetting.lua

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "HarmonizeMIDI/HarmonizeMIDIUtils"

local reaper = reaper

defaultIntervals = "12,,"
if reaper.HasExtState("sockmonkey72_HarmonizeMIDI", "intervals") then
  defaultIntervals = reaper.GetExtState("sockmonkey72_HarmonizeMIDI", "intervals")
end

local rv, retvals_csv = reaper.GetUserInputs("Harmonize MIDI", 3, "Interval 1, Interval 2, Interval 3", defaultIntervals)

if rv ~= true then return end

reaper.SetExtState("sockmonkey72_HarmonizeMIDI", "intervals", retvals_csv, true)

local valid, intervals = ProcessArgs(retvals_csv)
if not valid then return end

DoHarmonizeMIDI(intervals)
