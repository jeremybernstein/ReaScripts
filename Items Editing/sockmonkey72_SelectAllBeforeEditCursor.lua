-- @description sockmonkey72_Select items before/after edit cursor
-- @author sockmonkey72
-- @version 1.1
-- @about
--   # A small set of scripts to select items before/after the edit cursor
-- @provides
--   [main] sockmonkey72_SelectAllBeforeEditCursor.lua
--   [main] sockmonkey72_SelectAllAfterEditCursor.lua
--   [main] sockmonkey72_SelectAllEndingBeforeEditCursor.lua
--   [main] sockmonkey72_SelectAllOverlappingAndAfterEditCursor.lua
--   sockmonkey72_SelectAroundEditCursorLib.lua
-- @changelog
--   refactor, add lib to permit future expansion

local r = reaper

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'/?.lua'
local saec = require 'sockmonkey72_SelectAroundEditCursorLib'

r.Undo_BeginBlock2(0)

saec.SelectAroundEditCursor(false, true)

r.Undo_EndBlock2(0, "Select all items before edit cursor", -1)