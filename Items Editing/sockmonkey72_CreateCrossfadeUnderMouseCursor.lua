-- @description sockmonkey72_Create crossfade under mouse cursor
-- @author sockmonkey72
-- @version 1.0
-- @about
--   # Creates a crossfade under the mouse cursor (if possible)
-- @provides
--   [main] sockmonkey72_CreateCrossfadeUnderMouseCursor.lua
--   [main] sockmonkey72_CreateCrossfadeUnderMouseCursor_Config.lua

------------------------------------------------------------------------------------------

local r = reaper
local ok = false

local xfadeshape = -1
if xfadeshape < 0 or xfadeshape > 7 then
  xfadeshape = tonumber(({reaper.get_config_var_string( "defxfadeshape" )})[2]) or 7
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

if use_grid then
  local retval, division = r.GetSetProjectGrid(0, false, 0, 0, 0)
  if retval ~= 0 then
    xfadetime = r.TimeMap2_QNToTime(0, division * 4) * grid_scale
  end
elseif use_time then
  xfadetime = time_abs
end

if not xfadetime then
  xfadetime = (tonumber(({r.get_config_var_string( "defsplitxfadelen" )})[2]) or 0.01) * 2
end

local fadelen = xfadetime -- override here if you want
------------------------------------------------------------------------------------------

local function post(...)
  local args = {...}
  local str = ''
  for i = 1, #args do
    local v = args[i]
    str = str .. (i ~= 1 and ', ' or '') .. (v ~= nil and tostring(v) or '<nil>')
  end
  str = str .. '\n'
  r.ShowConsoleMsg(str)
end

local retval, segment, details = r.BR_GetMouseCursorContext()
if retval == "arrange" and segment == "track" and details == "item" then
  local item = r.BR_GetMouseCursorContext_Item()
  local pos = r.BR_GetMouseCursorContext_Position()
  local track = r.BR_GetMouseCursorContext_Track()
  local item_cnt = r.CountTrackMediaItems( track )
  local itemstart = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local itemend = itemstart + r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local fixedlane = r.GetMediaTrackInfo_Value(track, 'I_FREEMODE') == 2
  local itemlane
  local item2, what
  local prevstart, prevend, prevlane
  local nextstart, nextend, nextlane
  local item2start, item2end

  local previtem, nextitem

  if fixedlane then
    itemlane = r.GetMediaItemInfo_Value(item, 'I_FIXEDLANE')
  end

  for i = 0, item_cnt - 1 do -- find the previous item
    local item_chk = r.GetTrackMediaItem(track, i)
    if item_chk == item then
      if i > 0 then
        previtem = r.GetTrackMediaItem(track, i - 1)
        if fixedlane then
          prevlane = r.GetMediaItemInfo_Value(previtem, 'I_FIXEDLANE')
        end
        prevstart = r.GetMediaItemInfo_Value(previtem, "D_POSITION")
        prevend = prevstart + r.GetMediaItemInfo_Value(previtem, "D_LENGTH")
      end
      if (i < item_cnt - 1) then
        nextitem = r.GetTrackMediaItem(track, i + 1)
        if fixedlane then
          nextlane = r.GetMediaItemInfo_Value(nextitem, 'I_FIXEDLANE')
        end
        nextstart = r.GetMediaItemInfo_Value(nextitem, "D_POSITION")
        nextend = nextstart + r.GetMediaItemInfo_Value(nextitem, "D_LENGTH")
      end
      break
    end
  end

  local previtemvalid = previtem and (not fixedlane or prevlane == itemlane)
  local nextitemvalid = nextitem and (not fixedlane or nextlane == itemlane)

  if previtemvalid and pos >= prevstart and pos <= prevend then
    item2 = previtem
    item2start = prevstart
    item2end = prevend
    what = "itemStart"
    -- post('itemstart')
  end
  if not item2 and nextitemvalid and pos >= nextstart and pos <= nextend then
    item2 = nextitem
    item2start = nextstart
    item2end = nextend
    what = "itemEnd"
    -- post('itemend')
  end
  -- can this be consolidated into above, or could we miss extreme overlap situations?
  if not item2 then
    local halftime = itemstart + ((itemend - itemstart) / 2)
    if previtemvalid and pos <= halftime then
      item2 = previtem
      item2start = prevstart
      item2end = prevend
      what = "itemStart"
      -- post('itemstart (first half)')
    elseif nextitemvalid and pos > halftime then
      item2 = nextitem
      item2start = nextstart
      item2end = nextend
      what = "itemEnd"
      -- post('itemend (last half)')
    end
  end

  if item2 then
    -- verify that the items are close enough to crossfade (not sure if this check is necessary or correct, though)
    if (what == "itemStart" and itemstart - item2end <= fadelen)
      or (what == "itemEnd" and item2start - itemend <= fadelen)
    then
      ok = true
    end
  end

  if ok then -- clear crossfade
    r.Undo_BeginBlock2(0)

    if what == "itemStart" then
      if itemstart > item2end - fadelen then
        r.BR_SetItemEdges(item, item2end - fadelen, itemend)
      elseif itemstart < item2end then
        fadelen = item2end - itemstart
      end
      r.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", fadelen)
      if item2end < itemstart - fadelen then
        r.BR_SetItemEdges(item2, item2start, itemstart - fadelen)
      end
      r.SetMediaItemInfo_Value(item2, "D_FADEOUTLEN_AUTO", fadelen)
    elseif what == "itemEnd" then
      if item2start > itemend - fadelen then
        r.BR_SetItemEdges(item2, itemend - fadelen, item2end)
      elseif item2start < itemend then
        fadelen = itemend - item2start
      end
      r.SetMediaItemInfo_Value(item2, "D_FADEINLEN_AUTO", fadelen)
      if itemend < item2start - fadelen then
        r.BR_SetItemEdges(item, itemstart, item2start - fadelen)
      end
      r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", fadelen)
    end
    r.UpdateArrange()
  end

  r.Undo_EndBlock2(0, 'Create crossfade under mouse cursor', -1)
end
