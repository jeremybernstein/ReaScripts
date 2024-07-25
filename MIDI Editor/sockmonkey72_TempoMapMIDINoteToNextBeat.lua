--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
local tm = require "TempoMap/TempoMapUtils"
if not tm then return end

local infoTab = tm.GetReference()
if not infoTab then return end

local timePosStr = tm.CalcNextBeat(infoTab.projPos)
local timePos = r.parse_timestr_pos(timePosStr, 1)

if tm.ValidateTargetTime(timePos, infoTab) then
    tm.ProcessToTargetTime(timePos, infoTab)
end

