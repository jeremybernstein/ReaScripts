--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "NudgeMIDI/NudgeMIDIUtils"

local reaper = reaper

local defaultNudge = "10"
if reaper.HasExtState("sockmonkey72_NudgeMIDI", "ticks") then
  defaultNudge = reaper.GetExtState("sockmonkey72_NudgeMIDI", "ticks")
end

local nudge = tonumber(defaultNudge)
if nudge then
  nudge = math.abs(math.floor(nudge))
else
  return
end

if Setup(-nudge, true) then
  Nudge()
end
