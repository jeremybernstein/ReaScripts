-- @description sockmonkey72_Create crossfade under mouse cursor
-- @author sockmonkey72
-- @version 1.4
-- @about
--   # Creates a crossfade under the mouse cursor (if possible)
-- @provides
--   [main] sockmonkey72_CreateCrossfadeUnderMouseCursor.lua
--   [main] sockmonkey72_CreateCrossfadeUnderMouseCursor_Config.lua
-- @changelog
--   add razor support (cursor in razor uses the razor area for the crossfade generation)
--   add time selection support (cursor in time selection uses the time selection area for the crossfade generation)
--   razor/timesel support can be optionally disabled in the Config script (on by default)

-- thanks to amagalma for some great examples of how it's done

------------------------------------------------------------------------------------------

local r = reaper
local ok = false

------------------------------------------------------------------------------------------

------------------------------------------------------------------------------------------

local debug = false

local function post(...)
  if not debug then return end
  local args = {...}
  local str = ''
  for i = 1, #args do
    local v = args[i]
    str = str .. (i ~= 1 and ', ' or '') .. (v ~= nil and tostring(v) or '<nil>')
  end
  str = str .. '\n'
  r.ShowConsoleMsg(str)
end

------------------------------------------------------------------------------------------

local some_tiny_amount = 0.0001 -- needed to prev_ent edge overlap

local xfadeshape = -1
if xfadeshape < 0 or xfadeshape > 7 then
  xfadeshape = tonumber(({reaper.get_config_var_string( 'defxfadeshape' )})[2]) or 7
end

local xfadetime

local use_grid = false
local use_time = false
local grid_scale = 0.5
local time_abs = 0.01

local xgrid = r.GetExtState('sm72_CreateCrossfade', 'GridWidth')
xgrid = tonumber(xgrid)
if xgrid and xgrid ~= 0 then
  grid_scale = xgrid
  use_grid = true
else
  local xtime = r.GetExtState('sm72_CreateCrossfade', 'TimeWidth')
  xtime = tonumber(xtime)
  if xtime and xtime ~= 0 then
    time_abs = xtime
    use_time = true
  end
end

local justification = r.GetExtState('sm72_CreateCrossfade', 'Justification')
justification = tonumber(justification)
if not justification then justification = -1 end
justification = justification < 0 and -1 or justification > 0 and 1 or 0

local ignore_extents = r.GetExtState('sm72_CreateCrossfade', 'IgnoreExtents')
ignore_extents = tonumber(ignore_extents)
if not ignore_extents then ignore_extents = 0 end
ignore_extents = ignore_extents ~= 0 and 1 or 0

if use_grid then
  local retval, division = r.GetSetProjectGrid(0, false, 0, 0, 0)
  if retval ~= 0 then
    xfadetime = r.TimeMap2_QNToTime(0, division * 4) * grid_scale
  end
elseif use_time then
  xfadetime = time_abs
end

if not xfadetime then
  xfadetime = (tonumber(({r.get_config_var_string( 'defsplitxfadelen' )})[2]) or 0.01) * 2
end

local fadelen = xfadetime -- override here if you want

------------------------------------------------------------------------------------------

local retval, segment, details = r.BR_GetMouseCursorContext()
if retval == 'arrange' and segment == 'track' and details == 'item' then
  local item = r.BR_GetMouseCursorContext_Item()
  local pos = r.BR_GetMouseCursorContext_Position()
  local track = r.BR_GetMouseCursorContext_Track()
  local item_cnt = r.CountTrackMediaItems( track )
  local item_start = r.GetMediaItemInfo_Value(item, 'D_POSITION')
  local item_end = item_start + r.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local what

  local fixedlane = r.GetMediaTrackInfo_Value(track, 'I_FREEMODE') == 2
  local itemlane

  if fixedlane then
    itemlane = r.GetMediaItemInfo_Value(item, 'I_FIXEDLANE')
  end

  local function wants_use_extents(pos)
    if ignore_extents ~= 0 then return false, nil, nil end

    -- cursor in time selection
    local ts_start, ts_end = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    if ts_start ~= ts_end then
      if pos >= ts_start and pos <= ts_end then
        return true, ts_start, ts_end
      end
    end

    -- cursor in razor edit
    local _, area = reaper.GetSetMediaTrackInfo_String(track, 'P_RAZOREDITS', '', false)
    if area ~= '' then
      for area_start, area_end, _ in area:gmatch('(%S+) (%S+) (%S+)') do
        area_start = tonumber(area_start)
        area_end = tonumber(area_end)
        if area_start and area_end and pos >= area_start and pos <= area_end then
          return true, area_start, area_end
        end
      end
    end
    return false, nil, nil
  end

  local use_extents, extents_start, extents_end = wants_use_extents(pos)

  local function test_extents(s, e)
    if not use_extents then return true end

    return
      (s >= extents_start and s <= extents_end)
      or (e >= extents_start and e <= extents_end)
  end

  local prev_item
  local prev_start, prev_end, prev_lane
  local next_item
  local next_start, next_end, next_lane

  for i = 0, item_cnt - 1 do -- find the prev_ious item
    local item_chk = r.GetTrackMediaItem(track, i)
    if item_chk == item then
      if i > 0 then
        prev_item = r.GetTrackMediaItem(track, i - 1)
        if fixedlane then
          prev_lane = r.GetMediaItemInfo_Value(prev_item, 'I_FIXEDLANE')
        end
        prev_start = r.GetMediaItemInfo_Value(prev_item, 'D_POSITION')
        prev_end = prev_start + r.GetMediaItemInfo_Value(prev_item, 'D_LENGTH')
        if not test_extents(prev_start, prev_end) then
          prev_item = nil
        end
      end
      if (i < item_cnt - 1) then
        next_item = r.GetTrackMediaItem(track, i + 1)
        if fixedlane then
          next_lane = r.GetMediaItemInfo_Value(next_item, 'I_FIXEDLANE')
        end
        next_start = r.GetMediaItemInfo_Value(next_item, 'D_POSITION')
        next_end = next_start + r.GetMediaItemInfo_Value(next_item, 'D_LENGTH')
        if not test_extents(next_start, next_end) then
          next_item = nil
        end
      end
      break
    end
  end

  local prev_item_valid = prev_item and (not fixedlane or prev_lane == itemlane)
  local next_item_valid = next_item and (not fixedlane or next_lane == itemlane)

  if use_extents and prev_item and next_item then return end -- bail, the extent encompasses too many items

  -- check for an existing overlap of the items
  if prev_item_valid and pos >= prev_start and pos <= prev_end then
    what = 'itemStart'
    post('itemStart')
  end
  if not what and next_item_valid and pos >= next_start and pos <= next_end then
    what = 'itemEnd'
    post('itemEnd')
  end

  -- no overlap? then let's figure out which side the mouse is on
  -- disabled the one-choice optimization, I don't think it feels right
  if not what then
    local halftime = item_start + ((item_end - item_start) / 2)
    if prev_item_valid and (pos <= halftime) then -- or (not next_itemvalid and pos <= item_end)) then
      what = 'itemStart'
      post('itemStart (first half)')
    elseif next_item_valid and (pos > halftime) then -- or (not prev_itemvalid and pos >= item_start)) then
      what = 'itemEnd'
      post('itemEnd (last half)')
    end
  end

  local item_l, item_l_start, item_l_end
  local item_r, item_r_start, item_r_end

  if what == 'itemStart' then
    item_l = prev_item
    item_l_start = prev_start
    item_l_end = prev_end
    item_r = item
    item_r_start = item_start
    item_r_end = item_end
  elseif what == 'itemEnd' then
    item_l = item
    item_l_start = item_start
    item_l_end = item_end
    item_r = next_item
    item_r_start = next_start
    item_r_end = next_end
  end

  if item_l and item_r then
    if item_r_start - item_l_end <= fadelen then
      ok = true
    end
  end

------------------------------------------------------------------------------------------

  if ok then -- create crossfade
    local justlen = justification == -1 and fadelen or justification == 0 and fadelen * 0.5 or 0

    r.Undo_BeginBlock2(0)

    local newstart = item_r_start

    if use_extents then
      local extent_adjusted_end = extents_end > item_r_end and item_r_end or extents_end
      local extent_adjusted_start = extents_start < item_l_start and item_l_start or extents_start
      fadelen = extent_adjusted_end - extent_adjusted_start
      r.BR_SetItemEdges(item_r, extent_adjusted_start + some_tiny_amount, item_r_end)
      r.BR_SetItemEdges(item_l, item_l_start, extent_adjusted_end - some_tiny_amount)
    elseif item_r_start > item_l_end - justlen then
      newstart = item_l_end - justlen
      if newstart < item_l_start then
        newstart = item_l_start + some_tiny_amount
      end
      r.BR_SetItemEdges(item_r, newstart, item_r_end)
    elseif item_r_start < item_l_end then
      fadelen = item_l_end - item_r_start
    end

    r.SetMediaItemInfo_Value(item_r, 'D_FADEINLEN_AUTO', fadelen)

    local newend = newstart + fadelen

    if not use_extents
      and item_l_end < newend
    then
      if item_r_end < newend then
        newend = item_r_end - some_tiny_amount
      end
      r.BR_SetItemEdges(item_l, item_l_start, newend)
    end

    r.SetMediaItemInfo_Value(item_l, 'D_FADEOUTLEN_AUTO', fadelen)

    r.UpdateArrange()

    r.Undo_EndBlock2(0, 'Create crossfade under mouse cursor', -1)

  end

end
