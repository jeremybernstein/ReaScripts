--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local EveryN = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

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

EveryN.generateEveryNNotation = generateEveryNNotation
EveryN.parseEveryNNotation = parseEveryNNotation
EveryN.makeDefaultEveryN = makeDefaultEveryN

return EveryN
