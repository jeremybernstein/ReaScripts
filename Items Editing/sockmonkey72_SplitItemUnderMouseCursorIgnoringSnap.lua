-- @description Split item under mouse cursor ignoring snap
-- @author sockmonkey72
-- @version 1.0
-- @about
--   # Splits the item under the mouse cursor, ignoring snap.
-- @provides
--   [main] sockmonkey72_SplitItemUnderMouseCursorIgnoringSnap.lua
-- @changelog
--   initial

local r = reaper

r.Undo_BeginBlock2(0)
r.PreventUIRefresh(1)
local state = r.GetToggleCommandStateEx(0, 1157)
if state ~= 0 then r.Main_OnCommandEx(1157, 0, 0) end
r.Main_OnCommandEx(42575, 0,0)
if state ~= 0 then r.Main_OnCommandEx(1157, 0, 0) end
local pos = r.BR_PositionAtMouseCursor(false)
r.SetEditCurPos2(0, pos, false, false)
r.PreventUIRefresh(-1)
r.Undo_EndBlock2(0, "Split item under mouse (ignoring snap)", -1)
