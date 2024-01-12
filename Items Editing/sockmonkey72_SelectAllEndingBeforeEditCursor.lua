--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'/?.lua'
local saec = require 'sockmonkey72_SelectAroundEditCursorLib'

r.Undo_BeginBlock2(0)

saec.SelectAroundEditCursor(false, false)

r.Undo_EndBlock2(0, "Select all items before edit cursor", -1)