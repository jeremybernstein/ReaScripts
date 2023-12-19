-- @description Toggle Time Selection
-- @author sockmonkey72
-- @version 1.0
-- @changelog 1.0 initial upload
-- @about Cache your time selection and disable it, or restore that cached time selection

local r = reaper

local startp, endp = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
local onoff = false

r.Undo_BeginBlock2(0)

if startp == endp then -- restore
    local rv, timeval = r.GetProjExtState(0, 'sockmonkey72', 'ToggleTimeSelection')
    if rv then
        startp, endp = timeval:match('([^,]+),([^,]+)')
        startp = tonumber(startp)
        endp = tonumber(endp)
        if startp and endp then
            r.GetSet_LoopTimeRange2(0, true, false, startp, endp, false)
            onoff = true
        end
    end
else -- save
    r.SetProjExtState(0, 'sockmonkey72', 'ToggleTimeSelection', startp..','..endp)
    r.Main_OnCommandEx(40020, 0, 0) -- Time selection: Remove (unselect) time selection and loop points (40635 is just time selection)
end

r.Undo_EndBlock2(0, 'Toggle Time Selection ('.. (onoff and 'On' or 'Off') ..')', -1)

-- r.ShowConsoleMsg(startp..", "..endp.."\n")