--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

r.Undo_BeginBlock2(0)
r.PreventUIRefresh(1)

local ct = r.CountSelectedMediaItems(0)
for i = ct - 1, 0, -1 do
    local item = r.GetSelectedMediaItem(0, i)
    if item then
        r.SetMediaItemSelected(item, false)
    end
end

local position = r.GetCursorPositionEx(0)

ct = r.CountMediaItems(0)
for i = 0, ct -1 do
    local item = r.GetMediaItem(0, i)
    if item then
        local starttime = r.GetMediaItemInfo_Value(item, 'D_POSITION')
        if starttime >= position then
            r.SetMediaItemSelected(item, true)
        -- else
        --      local duration = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
        --      if starttime + duration >= position then
        --         r.SetMediaItemSelected(item, true)
        --      end
        end
    end
end

r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock2(0, "Select all items after edit cursor", -1)