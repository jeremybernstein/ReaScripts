--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local NewMIDIEvent = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

Shared = Shared or {} -- Use an existing table or create a new one

local r = reaper

local tg = require 'TransformerGlobal'
local gdefs = require 'TransformerGeneralDefs'
local adefs = require 'TransformerActionDefs'

local function generateNewMIDIEventNotation(row)
  if not row.nme then return '' end
  local nme = row.nme
  local nmeStr = string.format('%02X%02X%02X', nme.chanmsg | nme.channel, nme.msg2, nme.msg3)
  nmeStr = nmeStr .. '|' .. ((nme.selected and 1 or 0) | (nme.muted and 2 or 0) | (nme.relmode and 4 or 0))
  nmeStr = nmeStr .. '|' .. nme.posText
  nmeStr = nmeStr .. '|' .. (nme.chanmsg == 0x90 and nme.durText or '0')
  nmeStr = nmeStr .. '|' .. string.format('%02X', (nme.chanmsg == 0x90 and tostring(nme.relvel) or '0'))
  return nmeStr
end

local function parseNewMIDIEventNotation(str, row, paramTab, index)
  if index == 1 then
    local nme = {}
    local fs, fe, msg, flags, pos, dur, relvel = string.find(str, '([0-9A-Fa-f]+)|(%d)|([0-9%.%-:t]+)|([0-9%.:t]+)|([0-9A-Fa-f]+)')
    if fs and fe then
      local status = tonumber(msg:sub(1, 2), 16)
      nme.chanmsg = status & 0xF0
      nme.channel = status & 0x0F
      nme.msg2 = tonumber(msg:sub(3, 4), 16)
      nme.msg3 = tonumber(msg:sub(5, 6), 16)
      local nflags = tonumber(flags)
      nme.selected = nflags & 0x01 ~= 0
      nme.muted = nflags & 0x02 ~= 0
      nme.relmode = nflags & 0x04 ~= 0
      nme.posText = pos
      nme.durText = dur
      nme.relvel = tonumber(relvel:sub(1, 2), 16)
      nme.posmode = adefs.NEWEVENT_POSITION_ATCURSOR

      for k, v in ipairs(paramTab) do
        if tonumber(v.text) == nme.chanmsg then
          row.params[1].menuEntry = k
          break
        end
      end
    else
      nme.chanmsg = 0x90
      nme.channel = 0
      nme.selected = true
      nme.muted = false
      nme.msg2 = 64
      nme.msg3 = 64
      nme.posText = gdefs.DEFAULT_TIMEFORMAT_STRING
      nme.durText = '0.1.00'
      nme.relvel = 0
      nme.posmod = adefs.NEWEVENT_POSITION_ATCURSOR
      nme.relmode = false
    end
    row.nme = nme
  elseif index == 2 then
    if str == '$relcursor' then -- legacy
      str = '$atcursor'
      row.nme.relmode = true
    end

    for k, v in ipairs(paramTab) do
      if v.notation == str then
        row.params[2].menuEntry = k
        row.nme.posmode = k
        break
      end
    end
    if row.nme.posmode == adefs.NEWEVENT_POSITION_ATPOSITION then row.nme.relmode = false end -- ensure
  end
end

local function makeDefaultNewMIDIEvent(row)
  row.params[1].menuEntry = 1
  row.params[2].menuEntry = 1
  row.nme = {
    chanmsg = 0x90,
    channel = 0,
    selected = true,
    muted = false,
    msg2 = 60,
    msg3 = 64,
    posText = gdefs.DEFAULT_TIMEFORMAT_STRING,
    durText = '0.1.00', -- one beat long as a default?
    relvel = 0,
    projtime = 0,
    projlen = 1,
    posmode = adefs.NEWEVENT_POSITION_ATCURSOR,
  }
end

local function handleCreateNewMIDIEvent(take, contextTab, context)
  if Shared.createNewMIDIEvent_Once then
    for i, row in ipairs(adefs.actionRowTable()) do
      if row.nme and not row.disabled then
        local nme = row.nme

        -- magic

        local fnTab = {}
        for s in contextTab.actionFnString:gmatch("[^\r\n]+") do
          table.insert(fnTab, s)
        end
        for ii = 2, i + 1 do
          fnTab[ii] = nil
        end
        local fnString = ''
        for _, s in pairs(fnTab) do
          fnString = fnString .. s .. '\n'
        end

        local _, actionFn = Shared.fnStringToFn(fnString, function(err)
          if err then
            Shared.mu.post(err)
          end
          Shared.parserError = 'Error: could not load action description (New MIDI Event)'
        end)
        if actionFn then
          local timeAdjust = Shared.getTimeOffset()
          local e = tg.tableCopy(nme)
          local pos
          if nme.posmode == adefs.NEWEVENT_POSITION_ATCURSOR then
            pos = r.GetCursorPositionEx(0)
          elseif nme.posmode == adefs.NEWEVENT_POSITION_ITEMSTART then
            pos = r.GetMediaItemInfo_Value(r.GetMediaItemTake_Item(take), 'D_POSITION')
          elseif nme.posmode == adefs.NEWEVENT_POSITION_ITEMEND then
            local item = r.GetMediaItemTake_Item(take)
            pos = r.GetMediaItemInfo_Value(item, 'D_POSITION') + r.GetMediaItemInfo_Value(item, 'D_LENGTH')
          else
            pos = Shared.timeFormatToSeconds(nme.posText, nil, context) - timeAdjust
          end

          if nme.posmode ~= adefs.NEWEVENT_POSITION_ATPOSITION and nme.relmode then
            pos = pos + Shared.lengthFormatToSeconds(nme.posText, pos, context)
          end

          local evType = Shared.getEventType(e)

          e.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, pos) -- check for abs pos mode
          if evType == gdefs.NOTE_TYPE then
            e.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, pos + Shared.lengthFormatToSeconds(nme.durText, pos, context))
          end
          e.chan = e.channel
          e.flags = (e.muted and 2 or 0) | (e.selected and 1 or 0)
          Shared.calcMIDITime(take, e)

          actionFn(e, Shared.getSubtypeValueName(e), Shared.getMainValueName(e), contextTab)

          e.ppqpos = r.MIDI_GetPPQPosFromProjTime(take, e.projtime - timeAdjust)
          if evType == gdefs.NOTE_TYPE then
            e.endppqpos = r.MIDI_GetPPQPosFromProjTime(take, (e.projtime - timeAdjust) + e.projlen)
            e.msg3 = e.msg3 < 1 and 1 or e.msg3
          end
          Shared.postProcessSelection(e)
          e.muted = (e.flags & 2) ~= 0

          if evType == gdefs.NOTE_TYPE then
            Shared.mu.MIDI_InsertNote(take, e.selected, e.muted, e.ppqpos, e.endppqpos, e.chan, e.msg2, e.msg3, e.relvel)
          elseif evType == gdefs.CC_TYPE then
            Shared.mu.MIDI_InsertCC(take, e.selected, e.muted, e.ppqpos, e.chanmsg, e.chan, e.msg2, e.msg3)
          end
        end
      end
    end
    Shared.createNewMIDIEvent_Once = nil
  end
end

----------------------------------------------------------------------------------------
-------------------------------- UI RENDERING --------------------------------------

-- Generate label for param1: "Type: val1/val2 [duration]"
-- or param2: "PositionMode +/- offset"
local function generateNewMIDIEventLabel(row, index, options)
  local nme = row.nme
  local paramTab = options and options.paramTab or {}

  if index == 1 then
    local entry = paramTab[row.params[1].menuEntry]
    local label = entry and entry.label or 'Note'
    label = label .. ': ' .. nme.msg2

    -- two-byte messages (program change, aftertouch) omit val2
    local twobyte = nme.chanmsg >= 0xC0 and nme.chanmsg < 0xE0
    if not twobyte then
      -- pitch bend shows 14-bit combined value
      if nme.chanmsg == 0xE0 then
        local pb14 = ((nme.msg3 << 7) | nme.msg2) - (1 << 13)
        label = label .. '/' .. pb14
      else
        label = label .. '/' .. nme.msg3
      end
    end

    -- duration for notes only
    if nme.chanmsg == 0x90 then
      label = label .. ' [' .. nme.durText .. ']'
    end
    return label

  elseif index == 2 then
    local entry = paramTab[row.params[2].menuEntry]
    local label = entry and entry.label or 'At Cursor'
    local absPos = nme.posmode == adefs.NEWEVENT_POSITION_ATPOSITION
    local isRel = nme.relmode and not absPos

    if absPos or nme.relmode then
      local isRelNeg = isRel and nme.posText:sub(1,1) == '-'
      local posText = isRelNeg and nme.posText:sub(2) or nme.posText
      label = label .. (isRelNeg and ' - ' or isRel and ' + ' or ': ') .. posText
    end
    return label
  end

  return ''
end

-- Popup render for param1: channel, selected, muted, val1, val2, duration, relvel
local function renderNewMIDIEventParam1Popup(ctx, ImGui, row, options)
  local nme = row.nme
  local onChange = options.onChange or function() end
  local styleColors = options.styleColors or {}
  local currentFontWidth = options.currentFontWidth or 7
  local currentFrameHeight = options.currentFrameHeight or 20
  local DEFAULT_ITEM_WIDTH = options.defaultWidth or 150
  local scaled = options.scaled or function(x) return x end

  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, styleColors.hoverAlpha or 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, styleColors.activeAlpha or 0)

  ImGui.Separator(ctx)
  ImGui.AlignTextToFramePadding(ctx)

  -- channel list (1-16)
  ImGui.Text(ctx, 'Channel')
  ImGui.SameLine(ctx)

  if ImGui.BeginListBox(ctx, '##chanList', currentFontWidth * 10, currentFrameHeight * 3) then
    for i = 1, 16 do
      local rv = ImGui.MenuItem(ctx, tostring(i), nil, nme.channel == i - 1)
      if rv then
        if nme.channel == i - 1 then ImGui.CloseCurrentPopup(ctx) end
        nme.channel = i - 1
        onChange()
      end
    end
    ImGui.EndListBox(ctx)
  end

  ImGui.SameLine(ctx)

  local saveX, saveY = ImGui.GetCursorPos(ctx)
  saveX = saveX + scaled(20)
  saveY = saveY + currentFrameHeight * 0.5

  ImGui.SetCursorPos(ctx, saveX, saveY)

  -- selected checkbox
  local rv, sel = ImGui.Checkbox(ctx, 'Sel?', nme.selected)
  if rv then
    nme.selected = sel
    onChange()
  end

  ImGui.SetCursorPos(ctx, saveX, saveY + (currentFrameHeight * 1.1))

  -- muted checkbox
  rv, sel = ImGui.Checkbox(ctx, 'Mute?', nme.muted)
  if rv then
    nme.muted = sel
    onChange()
  end

  ImGui.SetCursorPosY(ctx, saveY + (currentFrameHeight * 2.7))
  ImGui.Separator(ctx)

  local isNote = nme.chanmsg == 0x90
  local twobyte = nme.chanmsg >= 0xC0
  local is14 = nme.chanmsg == 0xE0

  -- val1 input (14-bit for pitch bend)
  ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
  local byte1Txt = is14 and tostring((nme.msg3 << 7 | nme.msg2) - (1 << 13)) or tostring(nme.msg2)
  rv, byte1Txt = ImGui.InputText(ctx, 'Val1', byte1Txt, ImGui.InputTextFlags_CharsDecimal + ImGui.InputTextFlags_CharsNoBlank)
  if rv then
    local nummy = tonumber(byte1Txt) or 0
    if is14 then
      if nummy < -8192 then nummy = -8192 elseif nummy > 8191 then nummy = 8191 end
      nummy = nummy + (1 << 13)
      nme.msg2 = nummy & 0x7F
      nme.msg3 = nummy >> 7 & 0x7F
    else
      nme.msg2 = nummy < 0 and 0 or nummy > 127 and 127 or nummy
    end
    onChange()
  end

  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + DEFAULT_ITEM_WIDTH * 0.25)

  -- val2 input (disabled for 2-byte or 14-bit)
  if is14 or twobyte then ImGui.BeginDisabled(ctx) end
  ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
  local byte2Txt = (is14 or twobyte) and '0' or tostring(nme.msg3)
  rv, byte2Txt = ImGui.InputText(ctx, 'Val2', byte2Txt, ImGui.InputTextFlags_CharsDecimal + ImGui.InputTextFlags_CharsNoBlank)
  if rv then
    local nummy = tonumber(byte2Txt) or 0
    if not (is14 or twobyte) then
      local min = isNote and 1 or 0
      nme.msg3 = nummy < min and min or nummy > 127 and 127 or nummy
      onChange()
    end
  end
  if is14 or twobyte then ImGui.EndDisabled(ctx) end

  -- duration and relvel for notes only
  if nme.chanmsg == 0x90 then
    ImGui.Separator(ctx)

    ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH)
    local durRv
    durRv, nme.durText = ImGui.InputText(ctx, 'Dur.', nme.durText, 0)
    if durRv then
      if options.lengthFormatRebuf then
        nme.durText = options.lengthFormatRebuf(nme.durText)
      end
      onChange()
    end

    ImGui.SameLine(ctx)

    ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
    local relVelTxt = tostring(nme.relvel)
    rv, relVelTxt = ImGui.InputText(ctx, 'RelVel', relVelTxt, ImGui.InputTextFlags_CharsDecimal + ImGui.InputTextFlags_CharsNoBlank)
    if rv then
      nme.relvel = tonumber(relVelTxt) or 0
      nme.relvel = nme.relvel < 0 and 0 or nme.relvel > 127 and 127 or nme.relvel
      onChange()
    end
  end

  ImGui.PopStyleColor(ctx, 2)
end

-- Popup render for param2: position text, relative mode
local function renderNewMIDIEventParam2Popup(ctx, ImGui, row, options)
  local nme = row.nme
  local onChange = options.onChange or function() end
  local styleColors = options.styleColors or {}
  local DEFAULT_ITEM_WIDTH = options.defaultWidth or 150
  local currentFontWidth = options.currentFontWidth or 7

  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, styleColors.hoverAlpha or 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, styleColors.activeAlpha or 0)

  ImGui.Separator(ctx)
  ImGui.AlignTextToFramePadding(ctx)

  local xPos = ImGui.GetCursorPosX(ctx)
  ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH)

  local absPos = nme.posmode == adefs.NEWEVENT_POSITION_ATPOSITION
  local isRel = nme.relmode and not absPos
  local disableNumbox = not isRel and not absPos

  if disableNumbox then ImGui.BeginDisabled(ctx) end
  local label = not absPos and 'Pos+-' or 'Pos.'
  local rv
  rv, nme.posText = ImGui.InputText(ctx, label, nme.posText, 0)
  if rv then
    if isRel then
      if options.lengthFormatRebuf then
        nme.posText = options.lengthFormatRebuf(nme.posText)
      end
    else
      if options.timeFormatRebuf then
        nme.posText = options.timeFormatRebuf(nme.posText)
      end
    end
    onChange()
  end
  if disableNumbox then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, xPos + DEFAULT_ITEM_WIDTH + (currentFontWidth * 7))

  -- relative mode checkbox (disabled when at absolute position)
  local disableCheckbox = absPos
  if disableCheckbox then ImGui.BeginDisabled(ctx) end
  local relval
  rv, relval = ImGui.Checkbox(ctx, 'Relative', nme.relmode)
  if rv then
    nme.relmode = relval
    onChange()
  end
  if disableCheckbox then ImGui.EndDisabled(ctx) end

  ImGui.PopStyleColor(ctx, 2)
end

-- Main renderUI function for newmidievent type
local function renderUI(ctx, ImGui, row, index, options)
  row.nme = row.nme or (function()
    makeDefaultNewMIDIEvent(row)
    return row.nme
  end)()

  local label = generateNewMIDIEventLabel(row, index, options)
  local popupName = 'newMIDIEvent_param' .. index .. '_' .. (options.rowIndex or 0)

  local renderFn = index == 1
    and function() renderNewMIDIEventParam1Popup(ctx, ImGui, row, options) end
    or function() renderNewMIDIEventParam2Popup(ctx, ImGui, row, options) end

  return {
    {
      widget = 'button',
      label = label,
      onClick = function()
        if options and options.onOpenPopup then
          options.onOpenPopup(popupName, row, renderFn)
        end
      end,
    }
  }
end

NewMIDIEvent.generateNewMIDIEventNotation = generateNewMIDIEventNotation
NewMIDIEvent.parseNewMIDIEventNotation = parseNewMIDIEventNotation
NewMIDIEvent.makeDefaultNewMIDIEvent = makeDefaultNewMIDIEvent
NewMIDIEvent.handleCreateNewMIDIEvent = handleCreateNewMIDIEvent
NewMIDIEvent.renderUI = renderUI
NewMIDIEvent.renderNewMIDIEventParam1Popup = renderNewMIDIEventParam1Popup
NewMIDIEvent.renderNewMIDIEventParam2Popup = renderNewMIDIEventParam2Popup

return NewMIDIEvent
