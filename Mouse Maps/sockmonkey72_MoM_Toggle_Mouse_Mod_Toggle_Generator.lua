--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

-- this script only exists for naming/discovery reasons
-- all it does is launch the real script

local r = reaper
local scriptID = 'sockmonkey72_MouseMapFactory.lua'
local filePath = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. scriptID
dofile(filePath)
