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

-----------------------------------------------------------------------------
-- Chunk parsing helpers
-----------------------------------------------------------------------------

-- parse CFGEDITVIEW from take chunk
-- returns: leftmostTick, horzZoom, topPitch, pixelsPerPitch (all numbers or nil)
function Analyze.parseCFGEDITVIEW(takeChunk)
  local leftmostTick, horzZoom, topPitch, pixelsPerPitch =
    takeChunk:match('\nCFGEDITVIEW (%S+) (%S+) (%S+) (%S+)')

  if leftmostTick then
    leftmostTick = math.floor(tonumber(leftmostTick) + 0.5)
    horzZoom = tonumber(horzZoom)
    topPitch = 127 - tonumber(topPitch)
    pixelsPerPitch = tonumber(pixelsPerPitch)
  end

  return leftmostTick, horzZoom, topPitch, pixelsPerPitch
end

-- parse CFGEDIT from take chunk
-- returns: activeChannel, showNoteRows, timeBase
function Analyze.parseCFGEDIT(takeChunk)
  local activeChannel, showNoteRows, timeBase =
    takeChunk:match('\nCFGEDIT %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+) (%S+)')

  activeChannel = tonumber(activeChannel) or 0
  showNoteRows = tonumber(showNoteRows)
  -- timeBase: '0' or '4' = beats, else time
  timeBase = (timeBase == '0' or timeBase == '4') and 'beats' or 'time'

  return activeChannel, showNoteRows, timeBase
end

-- parse EVTFILTER from take chunk
-- returns: multiChanFilter (number or nil if filtering disabled)
function Analyze.parseEVTFILTER(takeChunk)
  local multiChanFilter, filterChannel, filterEnabled =
    takeChunk:match('\nEVTFILTER (%S+) %S+ %S+ %S+ %S+ (%S+) (%S+)')

  multiChanFilter = tonumber(multiChanFilter)
  filterEnabled = tonumber(filterEnabled)

  if filterEnabled ~= 0 and multiChanFilter ~= 0 then
    return multiChanFilter
  end
  return nil
end

-- parse VELLANE entries from take chunk
-- returns array of lane info tables
-- helper: convertCCType function to convert chunk lane type to API type
function Analyze.parseVELLANES(takeChunk, convertCCType, ccTypeToRange)
  local lanes = {}

  for vellaneStr in takeChunk:gmatch('\nVELLANE [^\n]+') do
    local laneType, height, inlineHeight, scroll, zoom =
      vellaneStr:match('VELLANE (%S+) (%d+) (%d+) (%S+) (%S+)')

    scroll = tonumber(scroll) or 0
    zoom = tonumber(zoom) or 1
    laneType = convertCCType(tonumber(laneType))
    height = tonumber(height)
    inlineHeight = tonumber(inlineHeight)

    if laneType and height and inlineHeight then
      table.insert(lanes, {
        VELLANE = vellaneStr,
        type = laneType,
        range = ccTypeToRange(laneType),
        height = height,
        inlineHeight = inlineHeight,
        scroll = scroll,
        zoom = zoom
      })
    end
  end

  return lanes
end

-- extract take chunk from item chunk by take number
-- returns: takeChunk string or nil
function Analyze.extractTakeChunk(itemChunk, takeNum)
  local takeChunkStartPos = 1
  for t = 1, takeNum do
    takeChunkStartPos = itemChunk:find('\nTAKE[^\n]-\nNAME', takeChunkStartPos + 1)
    if not takeChunkStartPos then return nil end
  end
  local takeChunkEndPos = itemChunk:find('\nTAKE[^\n]-\nNAME', takeChunkStartPos + 1)
  return itemChunk:sub(takeChunkStartPos, takeChunkEndPos)
end

return Analyze
