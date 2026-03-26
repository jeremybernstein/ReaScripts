--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  MIDI Editor state analysis utilities.

  Extracts viewport state from MIDI editor chunk data:
  - Lane geometry (CC lanes, note area)
  - Scroll/zoom positions
  - Visible note rows (for custom note order)

  Pure functions where possible, explicit params.
]]

local Analyze = {}

local r = reaper

-----------------------------------------------------------------------------
-- Lane visibility calculation
-----------------------------------------------------------------------------

-- calculate visible value range with margins for a CC lane
-- based on scroll (0-1), zoom (1-8), and lane geometry
-- returns: visibleMin, visibleMax, topMarginPixels, bottomMarginPixels
function Analyze.calculateVisibleRangeWithMargin(scroll, zoom, marginSize, viewHeight, minValue, maxValue)
  minValue = minValue or 0
  maxValue = maxValue or 127

  local valueRange = maxValue - minValue
  local logicalValueHeight = (viewHeight - 2 * marginSize) * zoom
  local totalLogicalHeight = logicalValueHeight + 2 * marginSize

  local center = scroll * (totalLogicalHeight - viewHeight) + viewHeight / 2
  local visibleStart = center - viewHeight / 2
  local visibleEnd = center + viewHeight / 2

  local bottomMarginStart = totalLogicalHeight - marginSize
  local bottomMarginEnd = totalLogicalHeight
  local topMarginStart = 0
  local topMarginEnd = marginSize

  local marginBottomVisible = math.max(0, math.min(visibleEnd, bottomMarginEnd) - math.max(visibleStart, bottomMarginStart))
  local marginTopVisible = math.max(0, math.min(visibleEnd, topMarginEnd) - math.max(visibleStart, topMarginStart))

  local visibleValueStart = math.max(visibleStart - marginSize, 0)
  local visibleValueEnd = math.min(visibleEnd - marginSize, logicalValueHeight)

  local visibleMin = maxValue - (visibleValueEnd / logicalValueHeight) * valueRange
  local visibleMax = maxValue - (visibleValueStart / logicalValueHeight) * valueRange

  return visibleMin, visibleMax, marginTopVisible, marginBottomVisible
end

-----------------------------------------------------------------------------
-- Note row visibility
-----------------------------------------------------------------------------

-- get list of visible note rows based on editor mode
-- mode: 0=show all, 1=hide unused, 2=hide unused+unnamed, 3=custom
-- chunk: track state chunk (for custom order)
-- hwnd: MIDI editor HWND (for modes 1,2 which probe via API)
function Analyze.getVisibleNoteRows(hwnd, mode, chunk)
  local visible_rows = {}

  if mode == 0 then
    -- show all: return 0-127
    for n = 0, 127 do visible_rows[n + 1] = n end
  elseif mode == 3 then
    -- custom order: parse from track chunk
    local note_order
    if chunk then
      note_order = chunk:match('CUSTOM_NOTE_ORDER (.-)\n')
    end
    if note_order then
      for value in (note_order .. ' '):gmatch('(.-) ') do
        visible_rows[#visible_rows + 1] = tonumber(value)
      end
    else
      for n = 0, 127 do visible_rows[n + 1] = n end
    end
  else
    -- mode 1 or 2: probe via API (hide unused / hide unused+unnamed)
    local GetSetting = r.MIDIEditor_GetSetting_int
    local SetSetting = r.MIDIEditor_SetSetting_int
    local key = 'active_note_row'

    local prev_row = GetSetting(hwnd, key)
    local highest_row = -1

    for i = 0, 127 do
      SetSetting(hwnd, key, i)
      local row = GetSetting(hwnd, key)
      if row > highest_row then
        highest_row = row
        visible_rows[#visible_rows + 1] = row
      end
    end

    SetSetting(hwnd, key, prev_row)
  end

  return visible_rows
end

return Analyze
