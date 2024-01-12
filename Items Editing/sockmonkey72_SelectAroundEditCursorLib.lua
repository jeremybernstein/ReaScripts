--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

local saec = {}

local function TestItem(item, position, isAfter, includeUnderCursor)
    local starttime = r.GetMediaItemInfo_Value(item, 'D_POSITION')
    local duration = r.GetMediaItemInfo_Value(item, 'D_LENGTH')

    local select = false

    if (isAfter and starttime >= position)
        or (not isAfter and starttime + duration < position)
    then
        select = true
    end
    if not select then
        if includeUnderCursor then
            if (isAfter and starttime + duration >= position)
                or (not isAfter and starttime < position)
            then
                select = true
            end
        end
    end
    return select
end

local function SelectAroundEditCursor(isAfter, includeUnderCursor, track)
    r.PreventUIRefresh(1)

    r.Main_OnCommandEx(40289, 0, 0) -- unselect all items

    -- -- unselect all
    -- local ct = r.CountSelectedMediaItems(0)
    -- for i = ct - 1, 0, -1 do
    --     local item = r.GetSelectedMediaItem(0, i)
    --     if item then
    --         r.SetMediaItemSelected(item, false)
    --     end
    -- end

    local position = r.GetCursorPositionEx(0)

    if not track then
        ct = r.CountMediaItems(0)
        for i = 0, ct -1 do
            local item = r.GetMediaItem(0, i)
            if item then
                local select = TestItem(item, position, isAfter, includeUnderCursor)
                if select then
                    r.SetMediaItemSelected(item, true)
                end
            end
        end
    else
        ct = r.CountTrackMediaItems(track)
        for i = 0, ct -1 do
            local item = r.GetTrackMediaItem(track, i)
            if item then
                local select = TestItem(item, position, isAfter, includeUnderCursor)
                if select then
                    r.SetMediaItemSelected(item, true)
                end
            end
        end

    end

    r.PreventUIRefresh(-1)

    r.UpdateArrange()
end

saec.SelectAroundEditCursor = SelectAroundEditCursor
return saec
