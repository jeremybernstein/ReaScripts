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

NewMIDIEvent.generateNewMIDIEventNotation = generateNewMIDIEventNotation
NewMIDIEvent.parseNewMIDIEventNotation = parseNewMIDIEventNotation
NewMIDIEvent.makeDefaultNewMIDIEvent = makeDefaultNewMIDIEvent
NewMIDIEvent.handleCreateNewMIDIEvent = handleCreateNewMIDIEvent

return NewMIDIEvent
