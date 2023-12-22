--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

local grid = r.GetExtState('sm72_CreateCrossfade', 'GridWidth')
local time = r.GetExtState('sm72_CreateCrossfade', 'TimeWidth')
local in_csv = '0.5,0'

grid = tonumber(grid)
if grid and grid ~= 0 then
    in_csv = grid..',0'
else
    time = tonumber(time)
    if time then
        in_csv = '0,'..time
    end
end

local retval, out_csv = r.GetUserInputs('Configure "Create crossfade"', 2, 'Grid Scale: 0=ignore,Time (sec): 0=ignore', in_csv)
if retval then
    grid, time = out_csv:match('([^,]+),([^,]+)')

    grid = tonumber(grid)
    if grid and grid ~= 0 then
        r.SetExtState('sm72_CreateCrossfade', 'GridWidth', tostring(grid), true)
        r.SetExtState('sm72_CreateCrossfade', 'TimeWidth', 0, true)
    else
        time = tonumber(time)
        if time then
            r.SetExtState('sm72_CreateCrossfade', 'TimeWidth', tostring(time), true)
            r.SetExtState('sm72_CreateCrossfade', 'GridWidth', 0, true)
        else
            r.DeleteExtState('sm72_CreateCrossfade', 'GridWidth', true)
            r.DeleteExtState('sm72_CreateCrossfade', 'TimeWidth', true)
        end
    end
end
