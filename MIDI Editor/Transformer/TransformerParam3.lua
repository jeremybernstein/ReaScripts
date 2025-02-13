--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Param3 = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

Shared = Shared or {} -- Use an existing table or create a new one

local mu = Shared.mu

local tg = require 'TransformerGlobal'
local gdefs = require 'TransformerGeneralDefs'

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

-- param3Formatter
local function param3FormatPositionScaleOffset(row)
  -- reverse p2 and p3, another param3 user might need to do weirder stuff
  local rowText, param1Val, param2Val = Shared.getRowTextAndParameterValues(row)
  rowText = rowText .. '('
  if tg.isValidString(param1Val) then
    rowText = rowText .. param1Val
    if row.params[3] and tg.isValidString(row.params[3].textEditorStr) then
      rowText = rowText .. ', ' .. row.params[3].textEditorStr
      if tg.isValidString(param2Val) then
        rowText = rowText .. ', ' .. param2Val
      end
    end
  end
  rowText = rowText .. ')'
  return rowText
end

-- param3Parser
local function param3ParsePositionScaleOffset(row, param1, param2, param3)
  local _, param1Tab, param2Tab, target, condOp = Shared.actionTabsFromTarget(row)
  if param2 and not tg.isValidString(param1) then param1 = param2 param2 = nil end
  if tg.isValidString(param1) then
    param1 = Shared.handleMacroParam(row, target, condOp, param1Tab, param1, 1)
  else
    param1 = Shared.defaultValueIfAny(row, condOp, 1)
  end
  if tg.isValidString(param3) then
    local tmp = param2
    param2 = param3
    param3 = tmp
  end
  if tg.isValidString(param2) then
    param2 = Shared.handleMacroParam(row, target, condOp, param2Tab, param2, 2)
  else
    param2 = Shared.defaultValueIfAny(row, condOp, 2)
  end

  row.params[1].textEditorStr = param1
  row.params[2].textEditorStr = param2
  row.params[3].textEditorStr = Shared.lengthFormatRebuf(param3)
end

local function param3PositionScaleOffsetMenuLabel(row)
  if not tg.isValidString(row.params[3].textEditorStr) then
    row.params[3].textEditorStr = gdefs.DEFAULT_LENGTHFORMAT_STRING
  end
  return '* ' .. row.params[1].textEditorStr .. ' + ' .. row.params[3].textEditorStr
end

local positionScaleOffsetParam3Tab = {
  formatter = param3FormatPositionScaleOffset,
  parser = param3ParsePositionScaleOffset,
  menuLabel = param3PositionScaleOffsetMenuLabel,
}

local function makeParam3PositionScaleOffset(row)
  row.params[1].menuEntry = 1
  row.params[2].menuEntry = 1
  row.params[1].textEditorStr = '1' -- default
  row.params[3] = tg.ParamInfo()
  for k, v in pairs(positionScaleOffsetParam3Tab) do row.params[3][k] = v end
  row.params[3].textEditorStr = gdefs.DEFAULT_LENGTHFORMAT_STRING
end

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

local function param3FormatLine(row)
  -- reverse p2 and p3, another param3 user might need to do weirder stuff
  local rowText, param1Val, param2Val, param3Val = Shared.getRowTextAndParameterValues(row)
  rowText = rowText .. '('
  if tg.isValidString(param1Val) then
    rowText = rowText .. param1Val
    if tg.isValidString(param3Val) then
      rowText = rowText .. ', ' .. param3Val
      if tg.isValidString(param2Val) then
        rowText = rowText .. ', ' .. param2Val .. '|' .. string.format('%0.2f', row.params[3].mod and row.params[3].mod or 2)
      end
    end
  end
  rowText = rowText .. ')'
  return rowText
end

local param3LineEntries = { -- share these with the Lib
  { notation = '$lin', label = 'Linear', text = '0' },
  { notation = '$exp', label = 'Exponential', text = '1' },
  { notation = '$log', label = 'Logarithmic', text = '2' },
  { notation = '$scurve', label = 'S-Curve', text = '3' }, -- needs tuning
  -- { notation = '$table', label = 'Lookup Table', text = '3' },
}

local function param3Line2Range(type, mod)
  local typeidx
  if not type then type = '$lin' end
  for k, v in ipairs(param3LineEntries) do
    if v.notation == type then
      typeidx = k
      break
    end
  end
  if not typeidx then typeidx = 1 end

  local modrange = { 0, nil }
  if typeidx >= 4 then modrange = { -1, 1 } end

  if mod then
    mod = (modrange[1] and mod < modrange[1]) and modrange[1] or (modrange[2] and mod > modrange[2]) and modrange[2] or mod
  end

  return modrange, mod
end

local function param3ParseLine(row, param1, param2, param3)
  local _, param1Tab, param2Tab, target, condOp = Shared.actionTabsFromTarget(row)
  local p2tmp = param2
  if param2 and not tg.isValidString(param1) then param1 = param2 param2 = nil end
  if tg.isValidString(param1) then
    param1 = Shared.handleMacroParam(row, target, condOp, param1Tab, param1, 1)
  else
    param1 = Shared.defaultValueIfAny(row, condOp, 1)
  end
  local mult
  if tg.isValidString(param3) then
    local fs, fe, type, multf = string.find(param3, '(.*)|(.*)')
    param2 = type and type or '$lin'
    mult = multf
  else
    param2 = '$lin'
    mult = 0
  end
  row.params[3].modrange, row.params[3].mod = param3Line2Range(param2, tonumber(mult) or 2.)
  param3 = p2tmp

  if tg.isValidString(param2) then
    param2 = Shared.handleMacroParam(row, target, condOp, param2Tab, param2, 2)
  else
    param2 = Shared.defaultValueIfAny(row, condOp, 2)
  end
  param3 = Shared.handleMacroParam(row, target, condOp, {}, param3, 3)
  row.params[1].textEditorStr = param1
  row.params[2].textEditorStr = param2
  if tg.isValidString(param3) then
    row.params[3].textEditorStr = param3
  end
end

local function param3LineMenuLabel(row, target, condOp, newHasTable)
  if not tg.isValidString(row.params[3].textEditorStr) then
    row.params[3].textEditorStr = '0'
  end

  if newHasTable then
    row.params[1].textEditorStr = Shared.handlePercentString(row.params[1].textEditorStr, row, target, condOp, gdefs.PARAM_TYPE_INTEDITOR, row.params[1].editorType, 1)
    row.params[3].textEditorStr = Shared.handlePercentString(row.params[3].textEditorStr, row, target, condOp, gdefs.PARAM_TYPE_INTEDITOR, row.params[1].editorType, 3)
  end

  local note1 = row.params[1].noteName
  local note3 = row.params[3].noteName
  if row.dirty or not (note1 and note3) then
    if Shared.isANote(target, condOp) then
      note1 = mu.MIDI_NoteNumberToNoteName(tonumber(row.params[1].textEditorStr))
      row.params[1].noteName = note1
      note3 = mu.MIDI_NoteNumberToNoteName(tonumber(row.params[3].textEditorStr))
      row.params[3].noteName = note3
    else
      row.params[1].noteName = nil
      row.params[3].noteName = nil
    end
  end

  return row.params[1].textEditorStr .. (note1 and ' [' .. note1 .. ']' or '') .. ' / ' .. row.params[3].textEditorStr .. (note3 and ' [' .. note3 .. ']' or '')
end

local function param3LineFunArg(row, target, condOp, param3Term)
  if not row.params[3].mod then row.params[3].mod = 2 end
  return param3Term .. ', ' .. row.params[3].mod
end

local function param3LineParamProc(row, idx, val)
  row.params[3].modrange, row.params[3].mod = param3Line2Range(param3LineEntries[val].notation, row.params[3].mod)
  if val == 4 and row.params[2].menuEntry ~= 4 then row.params[3].mod = 0.5 end
end

local lineParam3Tab = {
    formatter = param3FormatLine,
    parser = param3ParseLine,
    menuLabel = param3LineMenuLabel,
    funArg = param3LineFunArg,
    paramProc = param3LineParamProc,
}

local function makeParam3Line(row)
  row.params[1].menuEntry = 1 -- unused
  row.params[2].menuEntry = 1 -- this is the curve type menu
  row.params[1].textEditorStr = '0'
  row.params[3] = tg.ParamInfo()
  for k, v in pairs(lineParam3Tab) do row.params[3][k] = v end
  row.params[3].textEditorStr = '0'
  row.params[3].mod = 2. -- curve type mod, a param4
  row.params[3].modrange = { 0, nil }
end

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

Param3.positionScaleOffsetParam3Tab = positionScaleOffsetParam3Tab
Param3.makeParam3PositionScaleOffset = makeParam3PositionScaleOffset
Param3.lineParam3Tab = lineParam3Tab
Param3.makeParam3Line = makeParam3Line
Param3.param3LineEntries = param3LineEntries

return Param3
