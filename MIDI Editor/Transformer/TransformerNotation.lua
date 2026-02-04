--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Notation = {}

local r = reaper

local gdefs = require 'TransformerGeneralDefs'
local fdefs = require 'TransformerFindDefs'
local adefs = require 'TransformerActionDefs'
local tg = require 'TransformerGlobal'
local mu = require 'MIDIUtils'
local TimeUtils = require 'TransformerTimeUtils'
local mgdefs = require 'types/TransformerMetricGrid'
local evndefs = require 'types/TransformerEveryN'
local nmedefs = require 'types/TransformerNewMIDIEvent'
local evseldefs = require 'types/TransformerEventSelector'

----------------------------------------------------------------------------------------
-- INTERNAL HELPERS

local function handleMacroParam(row, target, condOp, paramTab, paramStr, index, helpers)
  local paramType
  local paramTypes = helpers.getParamTypesForRow(row, target, condOp)
  paramType = paramTypes[index] or gdefs.PARAM_TYPE_UNKNOWN

  local percent = string.match(paramStr, 'percent<(.-)>')
  if percent then
    local percentNum = tonumber(percent)
    if percentNum then
      local min = helpers.opIsBipolar(condOp, index) and -100 or 0
      percentNum = percentNum < min and min or percentNum > 100 and 100 or percentNum -- what about negative percents???
      row.params[index].percentVal = percentNum
      row.params[index].textEditorStr = string.format('%g', percentNum)
      return row.params[index].textEditorStr
    end
  end

  paramStr = string.gsub(paramStr, '^%s*(.-)%s*$', '%1') -- trim whitespace

  local isEveryN = paramType == gdefs.PARAM_TYPE_EVERYN
  local isNewEvent = paramType == gdefs.PARAM_TYPE_NEWMIDIEVENT
  local isEventSelector = paramType == gdefs.PARAM_TYPE_EVENTSELECTOR

  if not (isEveryN or isNewEvent or isEventSelector) and #paramTab ~= 0 then
    for kk, vv in ipairs(paramTab) do
      local pa, pb
      if paramStr == vv.notation then
         pa = 1
         pb = vv.notation:len() + 1
      elseif vv.alias then
        for _, alias in ipairs(vv.alias) do
          if paramStr == alias then
            pa = 1
            pb = alias:len() + 1
            break
          end
        end
      else
        pa, pb = string.find(paramStr, vv.notation .. '[%W]')
      end
      if pa and pb then
        row.params[index].menuEntry = kk
        if paramType == gdefs.PARAM_TYPE_METRICGRID or paramType == gdefs.PARAM_TYPE_MUSICAL then
          row.mg = mgdefs.parseMetricGridNotation(paramStr:sub(pb))
          row.mg.showswing = condOp.showswing or (condOp.split and condOp.split[index].showswing)
          row.mg.showround = condOp.showround or (condOp.split and condOp.split[index].showround)
        end
        break
      end
    end
  elseif isEveryN then
    row.evn = evndefs.parseEveryNNotation(paramStr)
  elseif isNewEvent then
    nmedefs.parseNewMIDIEventNotation(paramStr, row, paramTab, index)
  elseif isEventSelector then
    row.evsel = evseldefs.parseEventSelectorNotation(paramStr, row, paramTab)
  elseif condOp.bitfield or (condOp.split and condOp.split[index] and condOp.split[index].bitfield) then
    row.params[index].textEditorStr = paramStr
  elseif paramType == gdefs.PARAM_TYPE_INTEDITOR or paramType == gdefs.PARAM_TYPE_FLOATEDITOR then
    local range = condOp.range and condOp.range or target.range
    local has14bit, hasOther = helpers.check14Bit(paramType)
    if has14bit then
      if hasOther then range = helpers.opIsBipolar(condOp, index) and helpers.PARAM_PERCENT_BIPOLAR_RANGE or helpers.PARAM_PERCENT_RANGE
      else range = helpers.opIsBipolar(condOp, index) and helpers.PARAM_PITCHBEND_BIPOLAR_RANGE or helpers.PARAM_PITCHBEND_RANGE
      end
    end
    row.params[index].textEditorStr = tg.ensureNumString(paramStr, range)
  elseif paramType == gdefs.PARAM_TYPE_TIME then
    row.params[index].timeFormatStr = TimeUtils.timeFormatRebuf(paramStr)
  elseif paramType == gdefs.PARAM_TYPE_TIMEDUR then
    row.params[index].timeFormatStr = TimeUtils.lengthFormatRebuf(paramStr)
  elseif paramType == gdefs.PARAM_TYPE_METRICGRID
    or paramType == gdefs.PARAM_TYPE_MUSICAL
    or paramType == gdefs.PARAM_TYPE_EVERYN
    or paramType == gdefs.PARAM_TYPE_NEWMIDIEVENT -- fallbacks or used?
    or paramType == gdefs.PARAM_TYPE_PARAM3
    or paramType == gdefs.PARAM_TYPE_HIDDEN
    or paramType == gdefs.PARAM_TYPE_QUANTIZE
  then
    row.params[index].textEditorStr = paramStr
  end
  return paramStr
end

local function getParamPercentTerm(val, bipolar)
  local percent = val / 100 -- it's a percent coming from the system
  local min = bipolar and -100 or 0
  local max = 100
  if percent < min then percent = min end
  if percent > max then percent = max end
  return '(event.chanmsg == 0xE0 and math.floor((((1 << 14) - 1) * ' ..  percent .. ') + 0.5) or math.floor((((1 << 7) - 1) * ' .. percent .. ') + 0.5))'
end

local function processFindMacroRow(buf, boolstr, helpers)
  local row = fdefs.FindRow()
  local bufstart = 0
  local findstart, findend, parens = string.find(buf, '^%s*(%(+)%s*')

  row.targetEntry = 0
  row.conditionEntry = 0

  if findstart and findend and parens ~= '' then
    parens = string.sub(parens, 0, 3)
    for k, v in ipairs(fdefs.startParenEntries) do
      if v.notation == parens then
        row.startParenEntry = k
        break
      end
    end
    bufstart = findend + 1
  end
  for k, v in ipairs(fdefs.findTargetEntries) do
    findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%s+', bufstart)
    if findstart and findend then
      row.targetEntry = k
      bufstart = findend + 1
      -- mu.post('found target: ' .. v.label)
      break
    end
  end

  if row.targetEntry < 1 then return end

  local param1Tab, param2Tab
  local condTab = helpers.findTabsFromTarget(row)

  -- do we need some way to filter out extraneous (/) chars?
  for k, v in ipairs(condTab) do
    -- mu.post('testing ' .. buf .. ' against ' .. '/^%s*' .. v.notation .. '%s+/')
    local param1, param2, hasNot

    findstart, findend, hasNot = string.find(buf, '^%s-(!*)' .. v.notation .. '%s+', bufstart)
    if findstart and findend then
      row.conditionEntry = k
      row.isNot = hasNot == '!' and true or false
      bufstart = findend + 1
      condTab, param1Tab, param2Tab = helpers.findTabsFromTarget(row)
      findstart, findend, param1 = string.find(buf, '^%s*([^%s%)]*)%s*', bufstart)
      if tg.isValidString(param1) then
        bufstart = findend + 1
        param1 = handleMacroParam(row, fdefs.findTargetEntries[row.targetEntry], condTab[row.conditionEntry], param1Tab, param1, 1, helpers)
      end
      break
    else
      findstart, findend, hasNot, param1, param2 = string.find(buf, '^%s-(!*)' .. v.notation .. '%(([^,]-)[,%s]*([^,]-)%)', bufstart)
      if not (findstart and findend) then
        findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%(%s-%)', bufstart)
      end
      if findstart and findend then
        row.conditionEntry = k
        row.isNot = hasNot == '!' and true or false
        bufstart = findend + 1

        condTab, param1Tab, param2Tab = helpers.findTabsFromTarget(row)
        if param2 and not tg.isValidString(param1) then param1 = param2 param2 = nil end
        if tg.isValidString(param1) then
          param1 = handleMacroParam(row, fdefs.findTargetEntries[row.targetEntry], condTab[row.conditionEntry], param1Tab, param1, 1, helpers)
          -- mu.post('param1', param1)
        end
        if tg.isValidString(param2) then
          param2 = handleMacroParam(row, fdefs.findTargetEntries[row.targetEntry], condTab[row.conditionEntry], param2Tab, param2, 2, helpers)
          -- mu.post('param2', param2)
        end
        break
      -- else -- still not found, maybe an old thing (can be removed post-release)
      --   P(string.sub(buf, bufstart))
      end
    end
  end

  findstart, findend, parens = string.find(buf, '^%s*(%)+)%s*', bufstart)
  if findstart and findend and parens ~= '' then
    parens = string.sub(parens, 0, 3)
    for k, v in ipairs(fdefs.endParenEntries) do
      if v.notation == parens then
        row.endParenEntry = k
        break
      end
    end
    bufstart = findend + 1
  end

  if row.targetEntry ~= 0 and row.conditionEntry ~= 0 then
    if boolstr == '||' then row.booleanEntry = 2 end
    fdefs.addFindRow(row)
    return true
  end

  mu.post('Error parsing criteria: ' .. buf)
  return false
end

local function processActionMacroRow(buf, helpers)
  local row = adefs.ActionRow()
  local bufstart = 0
  local findstart, findend

  row.targetEntry = 0
  row.operationEntry = 0

  for k, v in ipairs(adefs.actionTargetEntries) do
    findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%s*', bufstart)
    if findstart and findend then
      row.targetEntry = k
      bufstart = findend + 1
      break
    end
  end

  if row.targetEntry < 1 then return end

  local opTab, _, _, target = helpers.actionTabsFromTarget(row) -- a little simpler than findTargets, no operation-based overrides (yet)
  if not (target and opTab) then
    mu.post('could not process action macro row: ' .. buf)
    return false
  end

  -- do we need some way to filter out extraneous (/) chars?
  for k, v in ipairs(opTab) do
    -- mu.post('testing ' .. buf .. ' against ' .. '/^%s*' .. v.notation .. '%s+/')
    local tryagain = true
    findstart, findend = string.find(buf, '^%s*' .. v.notation .. '%s+', bufstart)
    if findstart and findend then
      local cachestart = bufstart
      row.operationEntry = k
      local _, param1Tab, _, _, operation = helpers.actionTabsFromTarget(row)
      bufstart = findend + (buf[findend] ~= '(' and 1 or 0)

      local _, _, param1 = string.find(buf, '^%s*([^%s%()]*)%s*', bufstart)
      if tg.isValidString(param1) then
        param1 = handleMacroParam(row, target, operation, param1Tab, param1, 1, helpers)
        tryagain = false
      else
        if operation.terms == 0 then tryagain = false
        else bufstart = cachestart end
      end
      if not tryagain then
        row.params[1].textEditorStr = param1
        break
      end
    end
    if tryagain then
      local param1, param2, param3
      findstart, findend, param1, param2, param3 = string.find(buf, '^%s*' .. v.notation .. '%s*%(([^,]*)[,%s]*([^,]*)[,%s]*([^,]*)%)', bufstart)
      if not (findstart and findend) then
        findstart, findend, param1, param2 = string.find(buf, '^%s*' .. v.notation .. '%s*%(([^,]*)[,%s]*([^,]*)%)', bufstart)
      end
      if findstart and findend then
        row.operationEntry = k

        if param3 and v.param3 then
          row.params[3] = tg.ParamInfo()
          for p3k, p3v in pairs(v.param3) do row.params[3][p3k] = p3v end
          row.params[3].textEditorStr = param3
        else
          row.params[3] = nil -- just to be safe
          param3 = nil
        end

        if row.params[3] and row.params[3].parser then row.params[3].parser(row, param1, param2, param3)
        else
          local _, param1Tab, param2Tab, _, operation = helpers.actionTabsFromTarget(row)

          if param2 and not tg.isValidString(param1) then param1 = param2 param2 = nil end
          if tg.isValidString(param1) then
            param1 = handleMacroParam(row, target, operation, param1Tab, param1, 1, helpers)
          else
            param1 = helpers.defaultValueIfAny(row, operation, 1)
          end
          if tg.isValidString(param2) then
            param2 = handleMacroParam(row, target, operation, param2Tab, param2, 2, helpers)
          else
            param2 = helpers.defaultValueIfAny(row, operation, 2)
          end
          if tg.isValidString(param3) then
            row.params[3].textEditorStr = param3 -- very primitive
          end
          row.params[1].textEditorStr = param1
          row.params[2].textEditorStr = param2
        end

        -- mu.post(v.label .. ': ' .. (param1 and param1 or '') .. ' / ' .. (param2 and param2 or ''))
        break
      end
    end
  end

  if row.targetEntry ~= 0 and row.operationEntry ~= 0 then
    adefs.addActionRow(row)
    return true
  end

  mu.post('Error parsing action: ' .. buf)
  return false
end

----------------------------------------------------------------------------------------
-- PUBLIC API

function Notation.processFindMacro(buf, helpers)
  local bufstart = 0
  local rowstart, rowend, boolstr = string.find(buf, '%s+(&&)%s+')
  if not (rowstart and rowend) then
    rowstart, rowend, boolstr = string.find(buf, '%s+(||)%s+')
  end
  while rowstart and rowend do
    local rowbuf = string.sub(buf, bufstart, rowend)
    -- mu.post('got row: ' .. rowbuf) -- process
    processFindMacroRow(rowbuf, boolstr, helpers)
    bufstart = rowend + 1
    rowstart, rowend, boolstr = string.find(buf, '%s+(&&)%s+', bufstart)
    if not (rowstart and rowend) then
      rowstart, rowend, boolstr = string.find(buf, '%s+(||)%s+', bufstart)
    end
  end
  -- last iteration
  -- mu.post('last row: ' .. string.sub(buf, bufstart)) -- process
  processFindMacroRow(string.sub(buf, bufstart), nil, helpers)
end

function Notation.processActionMacro(buf, helpers)
  local bufstart = 0
  local rowstart, rowend = string.find(buf, '%s+(&&)%s+')
  while rowstart and rowend do
    local rowbuf = string.sub(buf, bufstart, rowend)
    processActionMacroRow(rowbuf, helpers)
    bufstart = rowend + 1
    rowstart, rowend = string.find(buf, '%s+(&&)%s+', bufstart)
  end
  processActionMacroRow(string.sub(buf, bufstart), helpers)
end

function Notation.findRowToNotation(row, index, helpers)
  local rowText = ''

  local _, param1Tab, param2Tab, curTarget, curCondition = helpers.findTabsFromTarget(row)
  rowText = curTarget.notation .. ' ' .. (row.isNot and '!' or '') .. curCondition.notation
  local param1Val, param2Val
  local paramTypes = helpers.getParamTypesForRow(row, curTarget, curCondition)

  param1Val, param2Val = helpers.processParams(row, curTarget, curCondition, { param1Tab, param2Tab, {} }, true, { PPQ = 960 } )
  if paramTypes[1] == gdefs.PARAM_TYPE_MENU then
    param1Val = (curCondition.terms > 0 and #param1Tab) and param1Tab[row.params[1].menuEntry].notation or nil
  end
  if paramTypes[2] == gdefs.PARAM_TYPE_MENU then
    param2Val = (curCondition.terms > 1 and #param2Tab) and param2Tab[row.params[2].menuEntry].notation or nil
  end

  if string.match(curCondition.notation, '[!]*%:') then
    rowText = rowText .. '('
    if tg.isValidString(param1Val) then
      rowText = rowText .. param1Val
      if tg.isValidString(param2Val) then
        rowText = rowText .. ', ' .. param2Val
      end
    end
    rowText = rowText .. ')'
  else
    if tg.isValidString(param1Val) then
      rowText = rowText .. ' ' .. param1Val -- no param2 val without a function
    end
  end

  if row.startParenEntry > 1 then rowText = fdefs.startParenEntries[row.startParenEntry].notation .. ' ' .. rowText end
  if row.endParenEntry > 1 then rowText = rowText .. ' ' .. fdefs.endParenEntries[row.endParenEntry].notation end

  if index and index ~= #fdefs.findRowTable() then
    rowText = rowText .. (row.booleanEntry == 2 and ' || ' or ' && ')
  end
  return rowText
end

function Notation.findRowsToNotation(helpers)
  local notationString = ''
  for k, v in ipairs(fdefs.findRowTable()) do
    local rowText = Notation.findRowToNotation(v, k, helpers)
    notationString = notationString .. rowText
  end
  -- mu.post('find macro: ' .. notationString)
  return notationString
end

function Notation.getRowTextAndParameterValues(row, helpers)
  local _, param1Tab, param2Tab, curTarget, curOperation = helpers.actionTabsFromTarget(row)
  local rowText = curTarget.notation .. ' ' .. curOperation.notation

  local paramTypes = helpers.getParamTypesForRow(row, curTarget, curOperation)

  local param1Val, param2Val, param3Val = helpers.processParams(row, curTarget, curOperation, { param1Tab, param2Tab, {} }, true, { PPQ = 960 } )
  if paramTypes[1] == gdefs.PARAM_TYPE_MENU then
    param1Val = (curOperation.terms > 0 and #param1Tab) and param1Tab[row.params[1].menuEntry].notation or nil
  end
  if paramTypes[2] == gdefs.PARAM_TYPE_MENU then
    param2Val = (curOperation.terms > 1 and #param2Tab) and param2Tab[row.params[2].menuEntry].notation or nil
  end
  return rowText, param1Val, param2Val, param3Val
end

function Notation.actionRowToNotation(row, index, helpers)
  local rowText = ''

  local _, _, _, _, curOperation = helpers.actionTabsFromTarget(row)

  if row.params[3] and row.params[3].formatter then rowText = rowText .. row.params[3].formatter(row)
  else
    local param1Val, param2Val, param3Val
    rowText, param1Val, param2Val, param3Val = Notation.getRowTextAndParameterValues(row, helpers)
    if string.match(curOperation.notation, '[!]*%:') then
      rowText = rowText .. '('
      if tg.isValidString(param1Val) then
        rowText = rowText .. param1Val
        if tg.isValidString(param2Val) then
          rowText = rowText .. ', ' .. param2Val
          if tg.isValidString(param3Val) then
            rowText = rowText .. ', ' .. param3Val
          end
        end
      end
      rowText = rowText .. ')'
    else
      if tg.isValidString(param1Val) then
        rowText = rowText .. ' ' .. param1Val -- no param2 val without a function
      end
    end
  end

  if index and index ~= #adefs.actionRowTable() then
    rowText = rowText .. ' && '
  end
  return rowText
end

function Notation.actionRowsToNotation(helpers)
  local notationString = ''
  for k, v in ipairs(adefs.actionRowTable()) do
    local rowText = Notation.actionRowToNotation(v, k, helpers)
    notationString = notationString .. rowText
  end
  -- mu.post('action macro: ' .. notationString)
  return notationString
end

function Notation.handleMacroParam(row, target, condOp, paramTab, paramStr, index, helpers)
  return handleMacroParam(row, target, condOp, paramTab, paramStr, index, helpers)
end

function Notation.getParamPercentTerm(val, bipolar)
  return getParamPercentTerm(val, bipolar)
end

return Notation
