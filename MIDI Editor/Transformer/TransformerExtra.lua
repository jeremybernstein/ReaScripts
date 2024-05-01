--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Extra = {}
local tx

local function initExtra(txlib)
  tx = txlib
end

local function tableCopy(obj, seen)
  if type(obj) ~= 'table' then return obj end
  if seen and seen[obj] then return seen[obj] end
  local s = seen or {}
  local res = setmetatable({}, getmetatable(obj))
  s[obj] = res
  for k, v in pairs(obj) do res[tableCopy(k, s)] = tableCopy(v, s) end
  return res
end

local function isValidString(str)
  return str ~= nil and str ~= ''
end

local function spairs(t, order) -- sorted iterator (https://stackoverflow.com/questions/15706270/sort-a-table-in-lua)
  -- collect the keys
  local keys = {}
  for k in pairs(t) do keys[#keys+1] = k end
  -- if order function given, sort by it by passing the table and keys a, b,
  -- otherwise just sort the keys
  if order then
    table.sort(keys, function(a,b) return order(t, a, b) end)
  else
    table.sort(keys)
  end
  -- return the iterator function
  local i = 0
  return function()
    i = i + 1
    if keys[i] then
      return keys[i], t[keys[i]]
    end
  end
end

local function deserialize(str)
  local f, err = load('return ' .. str)
  if not f then P(err) end
  return f ~= nil and f() or nil
end

local function orderByKey(t, a, b)
  return a < b
end

local function serialize(val, name, skipnewlines, depth)
  skipnewlines = skipnewlines or false
  depth = depth or 0
  local tmp = string.rep(' ', depth)
  if name then
    if type(name) == 'number' and math.floor(name) == name then
      name = '[' .. name .. ']'
    elseif not string.match(name, '^[a-zA-z_][a-zA-Z0-9_]*$') then
      name = string.gsub(name, "'", "\\'")
      name = "['".. name .. "']"
    end
    tmp = tmp .. name .. ' = '
  end
  if type(val) == 'table' then
    tmp = tmp .. '{' .. (not skipnewlines and '\n' or '')
    for k, v in spairs(val, orderByKey) do
      tmp =  tmp .. serialize(v, k, skipnewlines, depth + 1) .. ',' .. (not skipnewlines and '\n' or '')
    end
    tmp = tmp .. string.rep(' ', depth) .. '}'
  elseif type(val) == 'number' then
    tmp = tmp .. tostring(val)
  elseif type(val) == 'string' then
    tmp = tmp .. string.format('%q', val)
  elseif type(val) == 'boolean' then
    tmp = tmp .. (val and 'true' or 'false')
  else
    tmp = tmp .. '"[unknown datatype:' .. type(val) .. ']"'
  end
  return tmp
end

-- param3Formatter
local function param3FormatPositionScaleOffset(row)
  -- reverse p2 and p3, another param3 user might need to do weirder stuff
  local rowText, param1Val, param2Val = GetRowTextAndParameterValues(row)
  rowText = rowText .. '('
  if isValidString(param1Val) then
    rowText = rowText .. param1Val
    if row.params[3] and isValidString(row.params[3].textEditorStr) then
      rowText = rowText .. ', ' .. row.params[3].textEditorStr
      if isValidString(param2Val) then
        rowText = rowText .. ', ' .. param2Val
      end
    end
  end
  rowText = rowText .. ')'
  return rowText
end

-- param3Parser
local function param3ParsePositionScaleOffset(row, param1, param2, param3)
  local _, param1Tab, param2Tab, target, condOp = ActionTabsFromTarget(row)
  if param2 and not isValidString(param1) then param1 = param2 param2 = nil end
  if isValidString(param1) then
    param1 = HandleMacroParam(row, target, condOp, param1Tab, param1, 1)
  else
    param1 = DefaultValueIfAny(row, condOp, 1)
  end
  if isValidString(param3) then
    local tmp = param2
    param2 = param3
    param3 = tmp
  end
  if isValidString(param2) then
    param2 = HandleMacroParam(row, target, condOp, param2Tab, param2, 2)
  else
    param2 = DefaultValueIfAny(row, condOp, 2)
  end

  row.params[1].textEditorStr = param1
  row.params[2].textEditorStr = param2
  row.params[3].textEditorStr = LengthFormatRebuf(param3)
end

local function param3PositionScaleOffsetMenuLabel(row)
  if not isValidString(row.params[3].textEditorStr) then
    row.params[3].textEditorStr = tx.DEFAULT_LENGTHFORMAT_STRING
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
  row.params[3] = tx.ParamInfo()
  for k, v in pairs(positionScaleOffsetParam3Tab) do row.params[3][k] = v end
  row.params[3].textEditorStr = tx.DEFAULT_LENGTHFORMAT_STRING
end

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

local function param3FormatLine(row)
  -- reverse p2 and p3, another param3 user might need to do weirder stuff
  local rowText, param1Val, param2Val, param3Val = GetRowTextAndParameterValues(row)
  rowText = rowText .. '('
  if isValidString(param1Val) then
    rowText = rowText .. param1Val
    if isValidString(param3Val) then
      rowText = rowText .. ', ' .. param3Val
      if isValidString(param2Val) then
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
  local _, param1Tab, param2Tab, target, condOp = ActionTabsFromTarget(row)
  local p2tmp = param2
  if param2 and not isValidString(param1) then param1 = param2 param2 = nil end
  if isValidString(param1) then
    param1 = HandleMacroParam(row, target, condOp, param1Tab, param1, 1)
  else
    param1 = DefaultValueIfAny(row, condOp, 1)
  end
  if isValidString(param3) then
    local fs, fe, type, mult = string.find(param3, '(.*)|(.*)')
    param2 = type and type or '$lin'
    row.params[3].modrange, row.params[3].mod = param3Line2Range(param2, tonumber(mult) or 2.)
    param3 = p2tmp
  end
  if isValidString(param2) then
    param2 = HandleMacroParam(row, target, condOp, param2Tab, param2, 2)
  else
    param2 = DefaultValueIfAny(row, condOp, 2)
  end
  param3 = HandleMacroParam(row, target, condOp, {}, param3, 3)

  row.params[1].textEditorStr = param1
  row.params[2].textEditorStr = param2
  row.params[3].textEditorStr = param3
end

local function param3LineMenuLabel(row, target, condOp)
  if not isValidString(row.params[3].textEditorStr) then
    row.params[3].textEditorStr = '0'
  end

  if NewHasTable then
    row.params[1].textEditorStr = HandlePercentString(row.params[1].textEditorStr, row, target, condOp, tx.PARAM_TYPE_INTEDITOR, row.params[1].editorType, 1)
    row.params[3].textEditorStr = HandlePercentString(row.params[3].textEditorStr, row, target, condOp, tx.PARAM_TYPE_INTEDITOR, row.params[1].editorType, 3)
  end

  local note1 = row.params[1].noteName
  local note3 = row.params[3].noteName
  if row.dirty or not (note1 and note3) then
    if tx.isANote(target, condOp) then
      note1 = tx.mu.MIDI_NoteNumberToNoteName(tonumber(row.params[1].textEditorStr))
      row.params[1].noteName = note1
      note3 = tx.mu.MIDI_NoteNumberToNoteName(tonumber(row.params[3].textEditorStr))
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
  row.params[3] = tx.ParamInfo()
  for k, v in pairs(lineParam3Tab) do row.params[3][k] = v end
  row.params[3].textEditorStr = '0'
  row.params[3].mod = 2. -- curve type mod, a param4
  row.params[3].modrange = { 0, nil }
end

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

Extra.initExtra = initExtra
Extra.positionScaleOffsetParam3Tab = positionScaleOffsetParam3Tab
Extra.makeParam3PositionScaleOffset = makeParam3PositionScaleOffset
Extra.lineParam3Tab = lineParam3Tab
Extra.makeParam3Line = makeParam3Line
Extra.param3LineEntries = param3LineEntries

-- put these things in the global table so we can call them from anywhere
_G['tableCopy'] = tableCopy
_G['isValidString'] = isValidString
_G['spairs'] = spairs
_G['serialize'] = serialize
_G['deserialize'] = deserialize

return Extra
