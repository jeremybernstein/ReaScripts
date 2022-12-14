--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "HarmonizeMIDI/HarmonizeMIDIUtils"

local reaper = reaper

defaultIntervals = "12,,"
if reaper.HasExtState("sockmonkey72_HarmonizeMIDI", "intervals") then
  defaultIntervals = reaper.GetExtState("sockmonkey72_HarmonizeMIDI", "intervals")
end

local valid, intervals = ProcessArgs(defaultIntervals)
if not valid then return end

DoHarmonizeMIDI(intervals)


