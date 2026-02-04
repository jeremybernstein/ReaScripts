--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local EventSelector = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

Shared = Shared or {} -- Use an existing table or create a new one

local function generateEventSelectorNotation(row)
  if not row.evsel then return '' end
  local evsel = row.evsel
  local evSelStr = string.format('%02X', evsel.chanmsg)
  evSelStr = evSelStr .. '|' .. evsel.channel
  evSelStr = evSelStr .. '|' .. evsel.selected
  evSelStr = evSelStr .. '|' .. evsel.muted
  if evsel.useval1 then
    evSelStr = evSelStr .. string.format('|%02X', evsel.msg2)
  end
  local scale = tonumber(evsel.scaleStr)
  if not scale then scale = 100 end
  if scale ~= 100 then
    evSelStr = evSelStr .. string.format('|%0.4f', scale):gsub("%.?0+$", "")
  end
  return evSelStr
end

local function parseEventSelectorNotation(str, row, paramTab)
  local evsel = {}
  local fs, fe, chanmsg, channel, selected, muted = string.find(str, '([0-9A-Fa-f]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)')
  local msg2, scale, savefe
  if fs and fe then
    savefe = fe
    evsel.chanmsg = tonumber(chanmsg:sub(1, 2), 16)
    evsel.channel = tonumber(channel)
    evsel.selected = tonumber(selected)
    evsel.muted = tonumber(muted)
    evsel.useval1 = false
    evsel.msg2 = 60
    evsel.scaleStr = '100'

    fs, fe, msg2 = string.find(str, '|([0-9A-Fa-f]+)', fe)
    if fs and fe then
      evsel.useval1 = true
      evsel.msg2 = tonumber(msg2:sub(1, 2), 16)
    end

    if not fe then fe = savefe end
    fs, fe, scale = string.find(str, '|([0-9.]+)', fe)
    if fs and fe then
      evsel.scaleStr = scale
    end

    for k, v in ipairs(paramTab) do
      if tonumber(v.text) == evsel.chanmsg then
        row.params[1].menuEntry = k
        break
      end
    end
    return evsel
  end
  return nil
end

local function makeDefaultEventSelector(row)
  row.params[1].menuEntry = 1
  row.params[2].menuEntry = 4 -- $1/16
  row.evsel = {
    chanmsg = 0x00,
    channel = -1,
    selected = -1,
    muted = -1,
    useval1 = false,
    msg2 = 60,
    scale = 100,
    scaleStr = '100'
  }
end

----------------------------------------------------------------------------------------
-------------------------------- UI RENDERING --------------------------------------

-- Map chanmsg to human-readable name
local function chanMsgToName(chanmsg)
  return chanmsg == 0x00 and 'Any'
    or chanmsg == 0x90 and 'Note'
    or chanmsg == 0xA0 and 'Poly Pressure'
    or chanmsg == 0xB0 and 'Controller'
    or chanmsg == 0xC0 and 'Program Change'
    or chanmsg == 0xD0 and 'Aftertouch'
    or chanmsg == 0xE0 and 'Pitch Bend'
    or chanmsg == 0xF0 and 'System Exclusive'
    or chanmsg == 0x100 and 'Text'
    or 'Unknown'
end

-- Generate label for param1: "Type [Channel] (Val1)" if useval1
-- For param2: handled inline as "Scale: X%"
local function generateEventSelectorLabel(row, options)
  local evsel = row.evsel
  local label = chanMsgToName(evsel.chanmsg)
    .. ' [' .. (evsel.channel == -1 and 'Any' or tostring(evsel.channel + 1)) .. ']'

  -- val1 shown only for types that support it and when useval1 is true
  local useVal1 = evsel.chanmsg ~= 0x00 and evsel.chanmsg < 0xD0 and evsel.useval1
  if useVal1 then
    local val1Str
    -- show note name for notes if mu available
    if evsel.chanmsg == 0x90 and options and options.noteNumberToNoteName then
      val1Str = options.noteNumberToNoteName(evsel.msg2) or tostring(evsel.msg2)
    else
      val1Str = tostring(evsel.msg2)
    end
    label = label .. ' (' .. val1Str .. ')'
  end

  return label
end

-- Popup render for param1: channel, useval1, val1, selected, muted
local function renderEventSelectorParam1Popup(ctx, ImGui, row, options)
  local evsel = row.evsel
  local onChange = options.onChange or function() end
  local styleColors = options.styleColors or {}
  local currentFontWidth = options.currentFontWidth or 7
  local currentFrameHeight = options.currentFrameHeight or 20
  local DEFAULT_ITEM_WIDTH = options.defaultWidth or 150
  local dontCloseXPos = options.dontCloseXPos

  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, styleColors.hoverAlpha or 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, styleColors.activeAlpha or 0)

  ImGui.Separator(ctx)
  ImGui.AlignTextToFramePadding(ctx)

  -- channel list (Any + 1-16)
  ImGui.Text(ctx, 'Chan.')
  ImGui.SameLine(ctx)

  if dontCloseXPos then ImGui.SetCursorPosX(ctx, dontCloseXPos) end

  if ImGui.BeginListBox(ctx, '##chanList', currentFontWidth * 10, currentFrameHeight * 3) then
    local rv = ImGui.MenuItem(ctx, 'Any', nil, evsel.channel == -1)
    if rv then
      if evsel.channel == -1 then ImGui.CloseCurrentPopup(ctx) end
      evsel.channel = -1
      onChange()
    end

    for i = 1, 16 do
      rv = ImGui.MenuItem(ctx, tostring(i), nil, evsel.channel == i - 1)
      if rv then
        if evsel.channel == i - 1 then ImGui.CloseCurrentPopup(ctx) end
        evsel.channel = i - 1
        onChange()
      end
    end
    ImGui.EndListBox(ctx)
  end

  local saveNextLineY = ImGui.GetCursorPosY(ctx)

  ImGui.SameLine(ctx)

  -- useval1 checkbox (disabled for certain types)
  local disableUseVal1 = evsel.chanmsg == 0x00 or evsel.chanmsg >= 0xD0
  local saveX, saveY = ImGui.GetCursorPos(ctx)
  if disableUseVal1 then
    ImGui.BeginDisabled(ctx)
  end
  local rv, sel = ImGui.Checkbox(ctx, 'Use Val1?', evsel.useval1)
  if rv then
    evsel.useval1 = sel
    onChange()
  end
  if disableUseVal1 then
    ImGui.EndDisabled(ctx)
  end

  -- val1 input
  local isNote = evsel.chanmsg == 0x90
  local disableVal1 = disableUseVal1 or not evsel.useval1
  if disableVal1 then
    ImGui.BeginDisabled(ctx)
  end
  ImGui.SetCursorPos(ctx, saveX, saveY + currentFrameHeight * 1.5)
  ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
  local byte1Txt = tostring(evsel.msg2)
  rv, byte1Txt = ImGui.InputText(ctx, '##Val1', byte1Txt, ImGui.InputTextFlags_CharsDecimal + ImGui.InputTextFlags_CharsNoBlank)
  if rv then
    local nummy = tonumber(byte1Txt) or 0
    evsel.msg2 = nummy < 0 and 0 or nummy > 127 and 127 or nummy
    onChange()
  end
  if isNote and options.noteNumberToNoteName then
    local noteName = options.noteNumberToNoteName(evsel.msg2)
    if noteName then
      ImGui.SameLine(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.TextColored(ctx, 0x7FFFFFCF, '[' .. noteName .. ']')
    end
  end
  if disableVal1 then
    ImGui.EndDisabled(ctx)
  end

  ImGui.SetCursorPosY(ctx, saveNextLineY)
  ImGui.Separator(ctx)

  -- selected list (Any/Unselected/Selected)
  ImGui.Text(ctx, 'Sel.')
  ImGui.SameLine(ctx)

  if dontCloseXPos then ImGui.SetCursorPosX(ctx, dontCloseXPos) end

  if ImGui.BeginListBox(ctx, '##selList', currentFontWidth * 14, currentFrameHeight * 3) then
    rv = ImGui.MenuItem(ctx, 'Any', nil, evsel.selected == -1)
    if rv then
      if evsel.selected == -1 then ImGui.CloseCurrentPopup(ctx) end
      evsel.selected = -1
      onChange()
    end

    rv = ImGui.MenuItem(ctx, 'Unselected', nil, evsel.selected == 0)
    if rv then
      if evsel.selected == 0 then ImGui.CloseCurrentPopup(ctx) end
      evsel.selected = 0
      onChange()
    end

    rv = ImGui.MenuItem(ctx, 'Selected', nil, evsel.selected == 1)
    if rv then
      if evsel.selected == 1 then ImGui.CloseCurrentPopup(ctx) end
      evsel.selected = 1
      onChange()
    end
    ImGui.EndListBox(ctx)
  end

  ImGui.SameLine(ctx)

  -- muted list (Any/Unmuted/Muted)
  ImGui.Text(ctx, 'Muted')
  ImGui.SameLine(ctx)

  if ImGui.BeginListBox(ctx, '##muteList', currentFontWidth * 12, currentFrameHeight * 3) then
    rv = ImGui.MenuItem(ctx, 'Any', nil, evsel.muted == -1)
    if rv then
      if evsel.muted == -1 then ImGui.CloseCurrentPopup(ctx) end
      evsel.muted = -1
      onChange()
    end

    rv = ImGui.MenuItem(ctx, 'Unmuted', nil, evsel.muted == 0)
    if rv then
      if evsel.muted == 0 then ImGui.CloseCurrentPopup(ctx) end
      evsel.muted = 0
      onChange()
    end

    rv = ImGui.MenuItem(ctx, 'Muted', nil, evsel.muted == 1)
    if rv then
      if evsel.muted == 1 then ImGui.CloseCurrentPopup(ctx) end
      evsel.muted = 1
      onChange()
    end
    ImGui.EndListBox(ctx)
  end

  ImGui.PopStyleColor(ctx, 2)
end

-- Popup render for param2: scale percent input
local function renderEventSelectorParam2Popup(ctx, ImGui, row, options)
  local evsel = row.evsel
  local onChange = options.onChange or function() end
  local styleColors = options.styleColors or {}
  local DEFAULT_ITEM_WIDTH = options.defaultWidth or 150

  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, styleColors.hoverAlpha or 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, styleColors.activeAlpha or 0)

  ImGui.Separator(ctx)
  ImGui.AlignTextToFramePadding(ctx)

  ImGui.Text(ctx, '+- % of unit')
  ImGui.SameLine(ctx)

  ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
  local rv, buf = ImGui.InputText(ctx, '##eventSelectorParam2', evsel.scaleStr,
    ImGui.InputTextFlags_CharsDecimal + ImGui.InputTextFlags_CharsNoBlank)
  if rv then
    local scale = tonumber(buf)
    scale = scale == nil and 100 or scale < 0 and 0 or scale > 100 and 100 or scale
    evsel.scaleStr = tostring(scale)
    onChange()
  end

  ImGui.PopStyleColor(ctx, 2)
end

-- Main renderUI function for eventselector type
local function renderUI(ctx, ImGui, row, index, options)
  row.evsel = row.evsel or (function()
    makeDefaultEventSelector(row)
    return row.evsel
  end)()

  if index == 1 then
    local label = generateEventSelectorLabel(row, options)
    return {
      {
        widget = 'button',
        label = label,
        onClick = function()
          if options and options.onOpenPopup then
            options.onOpenPopup('eventSelector_param1_' .. (options.rowIndex or 0), row, function()
              renderEventSelectorParam1Popup(ctx, ImGui, row, options)
            end)
          end
        end,
      }
    }
  elseif index == 2 then
    return {
      {
        widget = 'button',
        label = 'Scale: ' .. (row.evsel.scaleStr or '100') .. '%',
        onClick = function()
          if options and options.onOpenPopup then
            options.onOpenPopup('eventSelector_param2_' .. (options.rowIndex or 0), row, function()
              renderEventSelectorParam2Popup(ctx, ImGui, row, options)
            end)
          end
        end,
      }
    }
  end

  return nil
end

EventSelector.generateEventSelectorNotation = generateEventSelectorNotation
EventSelector.parseEventSelectorNotation = parseEventSelectorNotation
EventSelector.makeDefaultEventSelector = makeDefaultEventSelector
EventSelector.chanMsgToName = chanMsgToName
EventSelector.renderUI = renderUI
EventSelector.renderEventSelectorParam1Popup = renderEventSelectorParam1Popup
EventSelector.renderEventSelectorParam2Popup = renderEventSelectorParam2Popup

return EventSelector
