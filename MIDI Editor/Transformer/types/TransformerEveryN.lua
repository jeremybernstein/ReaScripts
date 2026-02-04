--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local EveryN = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

local tg = require 'TransformerGlobal'

local function generateEveryNNotation(row)
  if not row.evn then return '' end
  local evn = row.evn
  local evnStr = (evn.isBitField and evn.pattern or tostring(evn.interval)) .. '|'
  evnStr = evnStr .. (evn.isBitField and 'b' or '-') .. '|'
  evnStr = evnStr .. evn.offset
  return evnStr
end

local function parseEveryNNotation(str)
  local evn = {}
  local fs, fe, patInt, flag, offset = string.find(str, '(%d+)|([b-])|(%d+)$')
  if not (fs and fe) then
    flag = ''
    offset = '0'
    fs, fe, patInt = string.find(str, '(%d+)')
  end
  if fs and fe then
    evn.isBitField = flag == 'b'
    evn.textEditorStr = patInt
    if evn.isBitField then evn.textEditorStr = evn.textEditorStr:gsub('[^0]', '1') end
    evn.pattern = evn.isBitField and evn.textEditorStr or '1'
    evn.interval = evn.isBitField and 1 or (tonumber(evn.textEditorStr) or 1)
    evn.offsetEditorStr = offset or '0'
    evn.offset = tonumber(evn.offsetEditorStr) or 0
  else
    evn.isBitField = false
    evn.textEditorStr = '1'
    evn.pattern = evn.textEditorStr
    evn.interval = 1
    evn.offsetEditorStr = '0'
    evn.offset = 0
  end
  return evn
end

local function makeDefaultEveryN(row)
  row.params[1].menuEntry = 1
  -- row.params[2].textEditorStr = '0' -- don't overwrite defaults
  row.evn = {
    pattern = '1',
    interval = 1,
    offset = 0,
    textEditorStr = '1',
    offsetEditorStr = '0',
    isBitField = false
  }
  return row.evn
end

----------------------------------------------------------------------------------------
-- UI rendering
----------------------------------------------------------------------------------------

-- generate display label for everyn inline display
-- format: (b) prefix if bitfield + pattern/interval + [offset] suffix if non-zero
local function generateEveryNLabel(row)
  local evn = row.evn
  if not evn then return '' end
  return (evn.isBitField and '(b) ' or '')
    .. evn.textEditorStr
    .. (evn.offset ~= 0 and (' [' .. evn.offset .. ']') or '')
end

-- popup content for everyn param configuration
-- relocated from sockmonkey72_Transformer.lua everyNActionParam1Special
local function renderEveryNPopup(ctx, ImGui, row, options)
  local evn = row.evn
  local onChange = options.onChange or function() end
  local styleColors = options.styleColors or {}
  local DEFAULT_ITEM_WIDTH = options.defaultWidth or 60
  local completionKeyPress = options.completionKeyPress or function() return false end
  local kbdEntryIsCompleted = options.kbdEntryIsCompleted or function(r) return r end
  local fontInfo = options.fontInfo or {}
  local inputFlag = options.inputFlag or 0
  local bitFieldCallback = options.bitFieldCallback
  local numbersOnlyCallback = options.numbersOnlyCallback

  local deactivated = false

  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, styleColors.hoverAlpha or 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, styleColors.activeAlpha or 0)

  ImGui.AlignTextToFramePadding(ctx)

  ImGui.Text(ctx, evn.isBitField and 'Pattern' or 'Interval')
  ImGui.SameLine(ctx)

  local saveX = ImGui.GetCursorPosX(ctx)
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  if evn.isBitField then evn.textEditorStr = evn.textEditorStr:gsub('[2-9]', '1')
  else evn.textEditorStr = tostring(tonumber(evn.textEditorStr))
  end
  ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 1.5)
  local rv, buf = ImGui.InputText(ctx, '##everyNentry', evn.textEditorStr,
    inputFlag | ImGui.InputTextFlags_CallbackCharFilter,
    evn.isBitField and bitFieldCallback or numbersOnlyCallback)
  if ImGui.IsItemDeactivated(ctx) then deactivated = true end
  if kbdEntryIsCompleted(rv) then
    if tg.isValidString(buf) then
      evn.textEditorStr = buf
      if evn.isBitField then
        evn.pattern = evn.textEditorStr
      else
        evn.interval = tonumber(evn.textEditorStr)
      end
      onChange()
    end
  end

  ImGui.SameLine(ctx)

  if fontInfo.smaller then
    ImGui.PushFont(ctx, fontInfo.smaller)
  end
  local yCache = ImGui.GetCursorPosY(ctx)
  local _, smallerHeight = ImGui.CalcTextSize(ctx, '0')
  ImGui.SetCursorPosY(ctx, yCache + ((ImGui.GetFrameHeight(ctx) - smallerHeight) / 2))
  local selected
  rv, selected = ImGui.Checkbox(ctx, 'Bitfield', evn.isBitField)
  if rv then
    evn.isBitField = selected
    onChange()
  end
  if fontInfo.smaller then
    ImGui.PopFont(ctx)
  end

  ImGui.Separator(ctx)

  ImGui.Text(ctx, 'Offset')
  ImGui.SameLine(ctx)

  ImGui.SetCursorPosX(ctx, saveX)
  ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 1.5)
  rv, buf = ImGui.InputText(ctx, '##everyNoffset', evn.offsetEditorStr,
    ImGui.InputTextFlags_CallbackCharFilter, numbersOnlyCallback)
  if ImGui.IsItemDeactivated(ctx) then deactivated = true end
  if kbdEntryIsCompleted(rv) then
    if tg.isValidString(buf) then
      evn.offsetEditorStr = buf
      evn.offset = tonumber(evn.offsetEditorStr)
      onChange()
    end
  end

  if not ImGui.IsAnyItemActive(ctx) and not deactivated then
    if completionKeyPress() then
      ImGui.CloseCurrentPopup(ctx)
    end
  end

  ImGui.PopStyleColor(ctx, 2)
end

-- renderUI for everyn param type
-- returns widget definitions for host to render
local function renderUI(ctx, ImGui, row, index, options)
  if index ~= 1 then return nil end  -- only param[1] has special UI

  row.evn = row.evn or makeDefaultEveryN(row)
  local label = generateEveryNLabel(row)

  return {
    {
      widget = 'text',
      value = label,
    },
    {
      widget = 'button',
      label = '...',
      onClick = function()
        if options and options.onOpenPopup then
          options.onOpenPopup('everyN_' .. (options.rowIndex or 0), row, function()
            renderEveryNPopup(ctx, ImGui, row, options)
          end)
        end
      end,
    }
  }
end

EveryN.generateEveryNNotation = generateEveryNNotation
EveryN.parseEveryNNotation = parseEveryNNotation
EveryN.makeDefaultEveryN = makeDefaultEveryN
EveryN.renderUI = renderUI
EveryN.renderEveryNPopup = renderEveryNPopup
EveryN.generateEveryNLabel = generateEveryNLabel

return EveryN
