--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local ActionDefs = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

local tg = require 'TransformerGlobal'
local p3 = require 'TransformerParam3'

local ActionRow = tg.class(nil, {})

function ActionRow:init()
  self.targetEntry = 1
  self.operationEntry = 1
  self.params = {
    tg.ParamInfo(),
    tg.ParamInfo()
  }
end

local actionRowTable = {}

local function addActionRow(row)
  table.insert(actionRowTable, #actionRowTable+1, row and row or ActionRow())
end

local actionTargetEntries = {
  { notation = '$position', label = 'Position', text = '\'projtime\'', time = true },
  { notation = '$length', label = 'Length', text = '\'projlen\'', timedur = true, cond = 'event.chanmsg == 0x90' },
  { notation = '$channel', label = 'Channel', text = '\'chan\'', menu = true },
  { notation = '$type', label = 'Type', text = '\'chanmsg\'', menu = true },
  { notation = '$property', label = 'Property', text = '\'flags\'', menu = true },
  { notation = '$value1', label = 'Value 1', text = '_value1', inteditor = true, range = {0, 127} },
  { notation = '$value2', label = 'Value 2', text = '_value2', inteditor = true, range = {0, 127} },
  { notation = '$velocity', label = 'Velocity (Notes)', text = '\'msg3\'', inteditor = true, cond = 'event.chanmsg == 0x90', range = {1, 127} },
  { notation = '$relvel', label = 'Release Velocity (Notes)', text = '\'relvel\'', inteditor = true, cond = 'event.chanmsg == 0x90', range = {0, 127} },
  { notation = '$newevent', label = 'Create Event', text = '\'\'', newevent = true },
}
actionTargetEntries.targetTable = true

local OP_ADD = 1
local OP_SUB = 2
local OP_MULT = 3
local OP_DIV = 4
local OP_FIXED = 5
local OP_SCALEOFF = 6

local actionOperationPlus = { notation = '+', label = 'Add', text = 'OperateEvent1(event, {tgt}, OP_ADD, {param1})', terms = 1, inteditor = true, fullrange = true, literal = true, nixnote = true }
local actionOperationMinus = { notation = '-', label = 'Subtract', text = 'OperateEvent1(event, {tgt}, OP_SUB, {param1})', terms = 1, inteditor = true, fullrange = true, literal = true, nixnote = true }
local actionOperationMult = { notation = '*', label = 'Multiply', text = 'OperateEvent1(event, {tgt}, OP_MULT, {param1})', terms = 1, floateditor = true, norange = true, literal = true, nixnote = true }
local actionOperationDivide = { notation = '/', label = 'Divide By', text = 'OperateEvent1(event, {tgt}, OP_DIV, {param1})', terms = 1, floateditor = true, norange = true, literal = true, nixnote = true }
local actionOperationRound = { notation = ':round', label = 'Round By', text = 'QuantizeTo(event, {tgt}, {param1})', terms = 1, inteditor = true, literal = true }
local actionOperationFloor = { notation = ':floor', label = 'Round By (Down)', text = 'QuantizeTo(event, {tgt}, {param1}, true)', terms = 1, inteditor = true, literal = true }
local actionOperationClamp = { notation = ':clamp', label = 'Clamp Between', text = 'ClampValue(event, {tgt}, {param1}, {param2})', terms = 2, inteditor = true }
local actionOperationRandom = { notation = ':random', label = 'Random Values Btw', text = 'RandomValue(event, {tgt}, {param1}, {param2})', terms = 2, inteditor = true }
local actionOperationRelRandom = { notation = ':relrandom', label = 'Relative Random Values Btw', text = 'OperateEvent1(event, {tgt}, OP_ADD, RandomValue(event, nil, {param1}, {param2}))', terms = 2, inteditor = true, range = { -127, 127 }, fullrange = true, bipolar = true, literal = true, nixnote = true }
local actionOperationRelRandomSingle = { notation = ':relrandomsingle', label = 'Single Relative Random Value Btw', text = 'OperateEvent1(event, {tgt}, OP_ADD, RandomValue(event, nil, {param1}, {param2}, {randomsingle}))', terms = 2, inteditor = true, range = { -127, 127 }, fullrange = true, bipolar = true, literal = true, nixnote = true }
local actionOperationFixed = { notation = '=', label = 'Set to Fixed Value', text = 'OperateEvent1(event, {tgt}, OP_FIXED, {param1})', terms = 1 }
local actionOperationLine = { notation = ':line', label = 'Ramp in Selection Range', text = 'LinearChangeOverSelection(event, {tgt}, event.projtime, {param1}, {param2}, {param3}, _context)', terms = 3, split = {{ inteditor = true }, { menu = true }, { inteditor = true }}, freeterm = true, param3 = p3.lineParam3Tab }
local actionOperationRelLine = { notation = ':relline', label = 'Relative Ramp in Selection Range', text = 'OperateEvent1(event, {tgt}, OP_ADD, LinearChangeOverSelection(event, nil, event.projtime, {param1}, {param2}, {param3}, _context))', terms = 3, split = {{ inteditor = true }, { menu = true }, { inteditor = true }}, freeterm = true, fullrange = true, bipolar = true, param3 = p3.lineParam3Tab }
local actionOperationScaleOff = { notation = ':scaleoffset', label = 'Scale + Offset', text = 'OperateEvent2(event, {tgt}, OP_SCALEOFF, {param1}, {param2})', terms = 2, split = {{ floateditor = true, norange = true }, { inteditor = true, bipolar = true }}, freeterm = true, literal = true, nixnote = true }
local actionOperationMirror = { notation = ':mirror', label = 'Mirror', text = 'Mirror(event, {tgt}, {param1})', terms = 1 }
local actionOperationThresh = { notation = ':thresh', label = 'Threshold', text = 'Threshold(event, {tgt}, {param1}, {param2}, {param3})', terms = 3, freeterm = true, param3 = p3.threshParam3Tab, inteditor = true, split = {{ default = 64 }, { default = 0 }, { default = 127 }} }

local function positionMod(op)
  local newop = tg.tableCopy(op)
  newop.menu = false
  newop.inteditor = false
  newop.floateditor = false
  newop.timedur = false
  newop.time = true
  newop.range = nil
  return newop
end

local function lengthMod(op)
  local newop = tg.tableCopy(op)
  newop.menu = false
  newop.inteditor = false
  newop.floateditor = false
  newop.time = false
  newop.timedur = true
  newop.range = nil
  return newop
end

local actionPositionOperationEntries = {
  { notation = '+', label = 'Add', text = 'AddDuration(event, {tgt}, \'{param1}\', event.projtime, _context)', terms = 1, timedur = true, timearg = true },
  { notation = '-', label = 'Subtract', text = 'SubtractDuration(event, {tgt}, \'{param1}\', event.projtime, _context)', terms = 1, timedur = true, timearg = true },
  { notation = '*', label = 'Multiply (rel.)', text = 'MultiplyPosition(event, {tgt}, {param1}, {param2}, nil, _context)', terms = 2, split = {{ floateditor = true }, { menu = true }}, norange = true, literal = true },
  { notation = '/', label = 'Divide (rel.)', text = 'MultiplyPosition(event, {tgt}, {param1} ~= 0 and (1 / {param1}) or 0, {param2}, nil, _context)', terms = 2, split = {{ floateditor = true }, { menu = true }}, norange = true, literal = true },
  lengthMod(actionOperationRound),
  lengthMod(actionOperationFloor),
  { notation = ':roundmusical', label = 'Quantize to Musical Value', text = 'QuantizeMusicalPosition(event, take, PPQ, {musicalparams})', terms = 2, split = {{ musical = true, showswing = true, showround = true }, { floateditor = true, default = 100, percent = true }} },
  positionMod(actionOperationFixed),
  positionMod(actionOperationRandom), lengthMod(actionOperationRelRandom), lengthMod(actionOperationRelRandomSingle),
  { notation = ':tocursor', label = 'Move to Cursor', text = 'MoveToCursor(event, {tgt}, {param1})', terms = 1, menu = true },
  { notation = ':addlength', label = 'Add Length', text = 'AddLength(event, {tgt}, {param1}, _context)', terms = 1, menu = true },
  { notation = ':scaleoffset', label = 'Scale + Offset (rel.)', text = 'MultiplyPosition(event, {tgt}, {param1}, {param2}, \'{param3}\', _context)', terms = 3, split = {{}, { menu = true }, {}}, param3 = p3.positionScaleOffsetParam3Tab },
  { notation = ':toitemstart', label = 'Move to Item Start', text = 'MoveToItemPos(event, {tgt}, 0, \'{param1}\', _context)', terms = 1, timedur = true, timearg = true },
  { notation = ':toitemend', label = 'Move to Item End', text = 'MoveToItemPos(event, {tgt}, 1, \'{param1}\', _context)', terms = 1, timedur = true, timearg = true },
  { notation = ':rampscale', label = 'Ramped Scale', text = 'ScaledRampOverSelection(event, {tgt}, event.projtime, {param1}, {param2}, {param3}, _context)', terms = 3, split = {{ floateditor = true, default = 1., range = { 0., nil } }, { menu = true }, { floateditor = true, default = 1., range = { 0., nil } }}, literal = true, freeterm = true, param3 = p3.lineParam3Tab },
}

local actionPositionMultParam2Menu = {
  { notation = '$itemrel', label = 'Item-Relative', text = 'nil'},
  { notation = '$firstrel', label = 'First-Event-Relative', text = '1'},
}

local actionLengthOperationEntries = {
  { notation = '+', label = 'Add', text = 'AddDuration(event, {tgt}, \'{param1}\', event.projlen, _context)', terms = 1, timedur = true, timearg = true },
  { notation = '-', label = 'Subtract', text = 'SubtractDuration(event, {tgt}, \'{param1}\', event.projlen, _context)', terms = 1, timedur = true, timearg = true },
  actionOperationMult, actionOperationDivide,
  lengthMod(actionOperationRound),
  lengthMod(actionOperationFloor),
  { notation = ':roundlenmusical', label = 'Quantize Length to Musical Value', text = 'QuantizeMusicalLength(event, take, PPQ, {musicalparams})', terms = 2, split = {{ musical = true, showround = true }, { floateditor = true, default = 100, percent = true }} },
  { notation = ':roundendmusical', label = 'Quantize Note-Off to Musical Value', text = 'QuantizeMusicalEndPos(event, take, PPQ, {musicalparams})', terms = 2, split = {{ musical = true, showswing = true, showround = true }, { floateditor = true, default = 100, percent = true }} },
  lengthMod(actionOperationFixed),
  { notation = ':quantmusical', label = 'Set to Musical Length', text = 'SetMusicalLength(event, take, PPQ, {musicalparams})', terms = 1, musical = true },
  lengthMod(actionOperationRandom), lengthMod(actionOperationRelRandom), lengthMod(actionOperationRelRandomSingle),
  { notation = ':tocursor', label = 'Move to Cursor', text = 'MoveLengthToCursor(event, {tgt})', terms = 0 },
  { notation = ':scaleoffset', label = 'Scale + Offset', text = 'OperateEvent2(event, {tgt}, OP_SCALEOFF, {param1}, TimeFormatToSeconds(\'{param2}\', event.projtime, _context, true))', terms = 2, split = {{ floateditor = true, default = 1. }, { timedur = true }}, range = {}, timearg = true },
  { notation = ':toitemend', label = 'Extend to Item End', text = 'MoveToItemPos(event, {tgt}, 2, \'{param1}\', _context)', terms = 1, timedur = true, timearg = true },
  { notation = ':rampscale', label = 'Ramped Scale', text = 'ScaledRampOverSelection(event, {tgt}, event.projtime, {param1}, {param2}, {param3}, _context)', terms = 3, split = {{ floateditor = true, default = 1., range = { 0., nil } }, { menu = true }, { floateditor = true, default = 1., range = { 0., nil } }}, literal = true, freeterm = true, param3 = p3.lineParam3Tab },
}

local function channelMod(op)
  local newop = tg.tableCopy(op)
  newop.literal = true
  newop.range = newop.bipolar and { -15, 15 } or { 0, 15 }
  return newop
end

local function channelModRerange(tab, ranges)
  local newTab = tg.tableCopy(channelMod(tab))
  newTab.preEdit = function(val)
    local numval = tonumber(val)
    if numval then
      return tostring(numval + 1)
    end
    return val
  end
  newTab.postEdit = function(val)
    local numval = tonumber(val)
    if numval then
      return tostring(numval - 1)
    end
    return val
  end
  newTab.rangelabel = ranges or { '1 - 16', '1 - 16' }
  return newTab
end

local actionChannelOperationEntries = {
  channelMod(actionOperationPlus), channelMod(actionOperationMinus),
  actionOperationFixed,
  channelModRerange(actionOperationRandom, nil),
  channelMod(actionOperationRelRandom), channelMod(actionOperationRelRandomSingle),
  channelModRerange(actionOperationLine, { '1 - 16', nil, '1 - 16' }), channelMod(actionOperationRelLine)
}
local actionTypeOperationEntries = {
  actionOperationFixed
}

local actionPropertyOperationEntries = {
  actionOperationFixed,
  { notation = ':addprop', label = 'Add Property', text = 'event.flags = event.flags | {param1}', terms = 1, menu = true },
  { notation = ':removeprop', label = 'Remove Property', text = 'event.flags = event.flags & ~({param1})', terms = 1, menu = true },
  { notation = ':ccsetcurve', label = 'Set CC Curve', text = 'CCSetCurve(take, event, {param1}, {param2})', terms = 2, split = {{ menu = true }, { floateditor = true, range = { -1, 1 }, default = 0, rangelabel = 'bezier' }}, freeterm = true, nooverride = true },
}

local actionPropertyParam1Entries = {
  { notation = '0', label = 'Clear', text = '0' },
  { notation = '1', label = 'Selected', text = '1' },
  { notation = '2', label = 'Muted', text = '2' },
  { notation = '3', label = 'Selected + Muted', text = '3' },
}

local actionPropertyAddRemParam1Entries = {
  { notation = '1', label = 'Selected', text = '1' },
  { notation = '2', label = 'Muted', text = '2' },
  { notation = '3', label = 'Selected + Muted', text = '3' },
}

local actionMoveToCursorParam1Entries = {
  { notation = '$alltakes', label = 'Relative Across All Takes', text = '0'},
  { notation = '$singletake', label = 'Take-Independent', text = '1'}
}

local actionAddLengthParam1Entries = {
  { notation = '$alltakes', label = 'Relative Across All Takes', text = '0'},
  { notation = '$singletake', label = 'Relative To First Note In Take', text = '1'},
  { notation = '$selection', label = 'Entire Selection In Take', text = '3'},
  { notation = '$note', label = 'Per Note', text = '2'},
}

local actionLineParam2Entries = p3.param3LineEntries
-- {
--   { notation = '$lin', label = 'Linear', text = '0' },
--   { notation = '$exp', label = 'Exponential', text = '1' },
--   { notation = '$log', label = 'Logarithmic', text = '2' },
--   { notation = '$scurve', label = 'S-Curve', text = '3' }, -- needs tuning
-- }

local actionSubtypeOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationClamp, actionOperationRandom, actionOperationRelRandom, actionOperationRelRandomSingle,
  { notation = ':getvalue2', label = 'Use Value 2', text = 'OperateEvent1(event, {tgt}, OP_FIXED, GetMainValue(event))', terms = 0 }, -- note that this is different for AT and PB
  actionOperationMirror, actionOperationThresh, actionOperationLine, actionOperationRelLine, actionOperationScaleOff
}

local actionVelocityOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationClamp, actionOperationRandom, actionOperationRelRandom, actionOperationRelRandomSingle,
  { notation = ':getvalue1', label = 'Use Value 1', text = 'OperateEvent1(event, {tgt}, OP_FIXED, GetSubtypeValue(event))', terms = 0 }, -- ?? note that this is different for AT and PB
  actionOperationMirror, actionOperationThresh, actionOperationLine, actionOperationRelLine, actionOperationScaleOff
}

local actionNewEventOperationEntries = {
  { notation = ':newmidievent', label = 'Create New Event', text = 'CreateNewMIDIEvent()', terms = 2, newevent = true }
}

local NEWEVENT_POSITION_ATCURSOR = 1
local NEWEVENT_POSITION_ITEMSTART = 2
local NEWEVENT_POSITION_ITEMEND = 3
local NEWEVENT_POSITION_ATPOSITION = 4

local newMIDIEventPositionEntries = {
  { notation = '$atcursor', label = 'At Edit Cursor', text = '1' },
  -- { notation = '$relcursor', label = 'Rel. Edit Cursor:', text = '2' },
  { notation = '$itemstart', label = 'Item Start', text = '2' },
  { notation = '$itemend', label = 'Item End', text = '3' },
  { notation = '$atposition', label = 'At Position', text = '4' },
}

local actionGenericOperationEntries = {
  actionOperationPlus, actionOperationMinus, actionOperationMult, actionOperationDivide,
  actionOperationRound, actionOperationFixed, actionOperationRandom, actionOperationRelRandom, actionOperationRelRandomSingle,
  actionOperationMirror, actionOperationThresh, actionOperationLine, actionOperationRelLine, actionOperationScaleOff
}

ActionDefs.ActionRow = ActionRow
ActionDefs.actionRowTable = function() return actionRowTable end
ActionDefs.addActionRow = addActionRow
ActionDefs.clearActionRowTable = function() actionRowTable = {} end
ActionDefs.actionTargetEntries = actionTargetEntries
ActionDefs.actionPositionOperationEntries = actionPositionOperationEntries
ActionDefs.actionPositionMultParam2Menu = actionPositionMultParam2Menu
ActionDefs.actionLengthOperationEntries = actionLengthOperationEntries
ActionDefs.actionChannelOperationEntries = actionChannelOperationEntries
ActionDefs.actionTypeOperationEntries = actionTypeOperationEntries
ActionDefs.actionPropertyOperationEntries = actionPropertyOperationEntries
ActionDefs.actionPropertyParam1Entries = actionPropertyParam1Entries
ActionDefs.actionPropertyAddRemParam1Entries = actionPropertyAddRemParam1Entries
ActionDefs.actionMoveToCursorParam1Entries = actionMoveToCursorParam1Entries
ActionDefs.actionAddLengthParam1Entries = actionAddLengthParam1Entries
ActionDefs.actionLineParam2Entries = actionLineParam2Entries
ActionDefs.actionSubtypeOperationEntries = actionSubtypeOperationEntries
ActionDefs.actionVelocityOperationEntries = actionVelocityOperationEntries
ActionDefs.actionNewEventOperationEntries = actionNewEventOperationEntries
ActionDefs.newMIDIEventPositionEntries = newMIDIEventPositionEntries
ActionDefs.actionGenericOperationEntries = actionGenericOperationEntries

ActionDefs.OP_ADD = OP_ADD
ActionDefs.OP_SUB = OP_SUB
ActionDefs.OP_MULT = OP_MULT
ActionDefs.OP_DIV = OP_DIV
ActionDefs.OP_FIXED = OP_FIXED
ActionDefs.OP_SCALEOFF = OP_SCALEOFF
ActionDefs.NEWEVENT_POSITION_ATCURSOR = NEWEVENT_POSITION_ATCURSOR
ActionDefs.NEWEVENT_POSITION_ITEMSTART = NEWEVENT_POSITION_ITEMSTART
ActionDefs.NEWEVENT_POSITION_ITEMEND = NEWEVENT_POSITION_ITEMEND
ActionDefs.NEWEVENT_POSITION_ATPOSITION = NEWEVENT_POSITION_ATPOSITION

local actionScopeTable = {
  { notation = '$select', label = 'Select', selectonly = true },
  { notation = '$selectadd', label = 'Add To Selection', selectonly = true },
  { notation = '$invertselect', label = 'Inverted Select', selectonly = true },
  { notation = '$deselect', label = 'Deselect', selectonly = true },
  { notation = '$transform', label = 'Transform' },
  { notation = '$replace', label = 'Transform & Replace' },
  { notation = '$copy', label = 'Transform to Track' },
  { notation = '$copylane', label = 'Transform to Lane', disable = not tg.isREAPER7() },
  { notation = '$insert', label = 'Insert' },
  { notation = '$insertexclusive', label = 'Insert Exclusive' },
  { notation = '$extracttrack', label = 'Extract to Track' },
  { notation = '$extractlane', label = 'Extract to Lane', disable = not tg.isREAPER7() },
  { notation = '$delete', label = 'Delete' },
}

local function actionScopeFromNotation(notation)
  if tg.isValidString(notation) then
    for k, v in ipairs(actionScopeTable) do
      if v.notation == notation then
        return k
      end
    end
  end
  return actionScopeFromNotation('$select') -- default
end

local actionScopeFlagsTable = {
  { notation = '$none', label = 'Do Nothing' },
  { notation = '$addselect', label = 'Add To Existing Selection' },
  { notation = '$exclusiveselect', label = 'Exclusive Select' },
  { notation = '$unselect', label = 'Deselect Transformed Events' }
  -- { notation = '$invertselect', label = 'Deselect Transformed Events (Selecting Others)' }, -- not so useful
}

local function actionScopeFlagsFromNotation(notation)
  if tg.isValidString(notation) then
    for k, v in ipairs(actionScopeFlagsTable) do
      if v.notation == notation then
        return k
      end
    end
  end
  return actionScopeFlagsFromNotation('$none') -- default
end

ActionDefs.actionScopeTable = actionScopeTable
ActionDefs.actionScopeFromNotation = actionScopeFromNotation
ActionDefs.actionScopeFlagsTable = actionScopeFlagsTable
ActionDefs.actionScopeFlagsFromNotation = actionScopeFlagsFromNotation

return ActionDefs
