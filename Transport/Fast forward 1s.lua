-- @description Fast forward 1 second
-- @author sockmonkey72
-- @version 1.0
-- @changelog 1.0 initial upload

amount = 1. -- 1 second

now = reaper.GetPlayStateEx(0) % 2 == 0 and reaper.GetCursorPositionEx(0) or reaper.GetPlayPositionEx(0)
now = now + amount
reaper.SetEditCurPos2(0, now, true, true)

