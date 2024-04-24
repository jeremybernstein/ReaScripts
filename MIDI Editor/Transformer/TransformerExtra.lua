local Extra = {}

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
    local DEFAULT_LENGTHFORMAT_STRING = '0.0.00'
    row.params[3].textEditorStr = DEFAULT_LENGTHFORMAT_STRING
  end
  return '* ' .. row.params[1].textEditorStr .. ' + ' .. row.params[3].textEditorStr
end

local positionScaleOffsetParam3Tab = {
  formatter = param3FormatPositionScaleOffset,
  parser = param3ParsePositionScaleOffset,
  menuLabel = param3PositionScaleOffsetMenuLabel,
}

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
    if fs and fe then
      param2 = type
      row.params[3].mod = tonumber(mult) or 2.
    else
      param2 = '$lin'
      row.params[3].mod = 2.
    end
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

local lastHasTable

local function param3LineMenuLabel(row, target, condOp)
  if not isValidString(row.params[3].textEditorStr) then
    row.params[3].textEditorStr = '0'
  end

  local hasTable, fresh = GetHasTable()
  if hasTable ~= lastHasTable or fresh then
    row.params[1].textEditorStr = HandlePercentString(row.params[1].textEditorStr, row, target, condOp, 2, row.params[1].editorType, 1)
    row.params[3].textEditorStr = HandlePercentString(row.params[3].textEditorStr, row, target, condOp, 2, row.params[1].editorType, 3)
    lastHasTable = hasTable
  end

  return row.params[1].textEditorStr .. ' / ' .. row.params[3].textEditorStr
end

local function param3LineFunArg(row, target, condOp)
  if not row.params[3].mod then row.params[3].mod = 2 end
  local param2 = row.params[3].textEditorStr
  local param2Num = tonumber(param2) or 0
  if row.params[3].percentVal then
      param2 = GetParamPercentTerm(param2Num, condOp.bipolar)
  end
  return param2 .. ', ' .. row.params[3].mod
end

local lineParam3Tab = {
    formatter = param3FormatLine,
    parser = param3ParseLine,
    menuLabel = param3LineMenuLabel,
    funArg = param3LineFunArg,
}

Extra.tableCopy = tableCopy
Extra.isValidString = isValidString
Extra.spairs = spairs
Extra.deserialize = deserialize
Extra.serialize = serialize
Extra.isValidString = isValidString
Extra.positionScaleOffsetParam3Tab = positionScaleOffsetParam3Tab
Extra.lineParam3Tab = lineParam3Tab

return Extra