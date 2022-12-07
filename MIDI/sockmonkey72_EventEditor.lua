--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

dofile(r.GetResourcePath() ..
       '/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8')

local ctx = r.ImGui_CreateContext('sockmonkey72_Event_Editor')
local sans_serif = r.ImGui_CreateFont('sans-serif', 13)
local sans_serif_small = r.ImGui_CreateFont('sans-serif', 11)
r.ImGui_Attach(ctx, sans_serif)
r.ImGui_Attach(ctx, sans_serif_small)

local commonEntries = { 'measures', 'beats', 'ticks', 'chan' }
local scaleOpWhitelist = { 'pitch', 'channel', 'vel', 'notedur', 'ccnum', 'ccval' }

local INVALID = -0xFFFF
local selectedNotes = {}
local popupFilter = 0x90 -- note default
local canvas_scale = 1.0
local DEFAULT_ITEM_WIDTH = 60

function paramCanScale(name)
  local canscale = false
  for _, v in pairs(scaleOpWhitelist) do
    if name == v then
      canscale = true
      break
    end
  end
  return canscale
end

local function myWindow()
  local rv
  local popupLabel = 'Note'
  local cc2byte = false
  local hasNotes = false
  local hasCCs = false
  local NOTE_TYPE = 0
  local CC_TYPE = 1
  local NOTE_FILTER = 0x90
  local changedParameter = nil

  local events = {}

  local take = r.MIDIEditor_GetTake(r.MIDIEditor_GetActive())
  if not take then return end

  function ppqToTime(ppqpos)
    local ppqmeasurepos = r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)
    local _, measures, cml, fullbeats = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, ppqpos))
    --rv, text = r.ImGui_InputText(ctx, 'text field', text)
    local _, som, _, sombeats = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, ppqmeasurepos))

    local beats = math.floor(fullbeats - sombeats)
    local beatsmax = math.floor(cml)
    local qtime = r.TimeMap2_beatsToTime(0, math.floor(fullbeats))
    local ppqbeatpos = r.MIDI_GetPPQPosFromProjTime(take, qtime)
    local ticks = math.floor(ppqpos - ppqbeatpos)
    return measures, beats, beatsmax, ticks
  end

  function calcMIDITime(e)
    e.measures, e.beats, e.beatsmax, e.ticks = ppqToTime(e.ppqpos)
  end

  local newNotes = {}
  local noteidx = r.MIDI_EnumSelNotes(take, -1)
  if noteidx > -1 then
    while noteidx > -1 do
      events[#events + 1] = { type = NOTE_TYPE, idx = noteidx }
      local e = events[#events]
      _, e.selected, e.muted, e.ppqpos, e.endppqpos, e.chan, e.pitch, e.vel = r.MIDI_GetNote(take, noteidx)
      calcMIDITime(e)
      e.notedur = e.endppqpos - e.ppqpos
      e.chanmsg = 0x90
      hasNotes = true
      table.insert(newNotes, e.idx)
      noteidx = r.MIDI_EnumSelNotes(take, noteidx)
    end
  end

  local ccidx = r.MIDI_EnumSelCC(take, -1)
  while ccidx > -1 do
    events[#events + 1] = { type = CC_TYPE, idx = ccidx }
    local e = events[#events]
    _, e.selected, e.muted, e.ppqpos, e.chanmsg, e.chan, e.msg2, e.msg3 = r.MIDI_GetCC(take, ccidx)
    if e.chanmsg == 0xE0 then
      e.ccnum = INVALID
      e.ccval = ((e.msg3 << 7) + e.msg2) - (1 << 13)
    elseif e.chanmsg == 0xD0 then
      e.ccnum = INVALID
      e.ccval = e.msg2
    else
      e.ccnum = e.msg2
      e.ccval = e.msg3
    end
    calcMIDITime(e)
    hasCCs = true
    ccidx = r.MIDI_EnumSelCC(take, ccidx)
  end

  local resetFilter = false
  if #newNotes ~= #selectedNotes then resetFilter = true
  else
    for _, v in pairs(newNotes) do
      local foundit = false
      for _, n in pairs(selectedNotes) do
        if n == v then
          foundit = true
          break
        end
      end
      if not foundit then
        resetFilter = true
        break
      end
    end
  end
  if resetFilter then popupFilter = 0x90 end
  selectedNotes = newNotes

  if #events == 0 then return end

  local OP_ABS = 0
  local OP_ADD = string.byte('+', 1)
  local OP_SUB = string.byte('-', 1)
  local OP_MUL = string.byte('*', 1)
  local OP_DIV = string.byte('/', 1)
  local OP_SCL = string.byte('.', 1)

  -- determine a filter and calculation the union
  local union = {}

  local ccTypes = {}
  ccTypes[0x90] = { val = 0x90, label = 'Note', exists = false }
  ccTypes[0xA0] = { val = 0xA0, label = 'PolyAT', exists = false }
  ccTypes[0xB0] = { val = 0xB0, label = 'CC', exists = false }
  ccTypes[0xC0] = { val = 0xC0, label = 'PrgCh', exists = false }
  ccTypes[0xD0] = { val = 0xD0, label = 'ChanAT', exists = false }
  ccTypes[0xE0] = { val = 0xE0, label = 'Pitch', exists = false }

  for _, v in pairs(events) do
    ccTypes[v.chanmsg].exists = true
  end
  if popupFilter ~= 0 and not ccTypes[popupFilter].exists then popupFilter = 0 end
  if popupFilter == 0 then
    popupFilter = events[1].chanmsg
  end
  popupLabel = ccTypes[popupFilter].label
  if popupFilter == 0xD0 or popupFilter == 0xE0 then cc2byte = true end

  function unionEntry(name, val, entry)
    if entry.chanmsg == popupFilter then
      if not union[name] then union[name] = val
      elseif union[name] ~= val then union[name] = INVALID end
    end
  end

  function commonUnionEntries(e)
    for _, v in pairs(commonEntries) do
      unionEntry(v, e[v], e)
    end

    if e.chanmsg == popupFilter then
      if e.ppqpos < union.selposticks then union.selposticks = e.ppqpos end
      if e.ppqpos > union.selendticks then union.selendticks = e.ppqpos end
    end
  end

  union.selposticks = -INVALID
  union.selendticks = INVALID
  for _, v in pairs(events) do
    commonUnionEntries(v)
    if v.type == NOTE_TYPE then
      unionEntry('notedur', v.notedur, v)
      unionEntry('pitch', v.pitch, v)
      unionEntry('vel', v.vel, v)
    elseif v.type == CC_TYPE then
      unionEntry('chanmsg', v.chanmsg, v)
      unionEntry('ccnum', v.ccnum, v)
      unionEntry('ccval', v.ccval, v)
    end
  end
  if union.selposticks == -INVALID then union.selposticks = INVALID end
  union.seldurticks = union.selendticks - union.selposticks

  r.ImGui_NewLine(ctx)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvas_scale)
  r.ImGui_Button(ctx, popupLabel)

  -- cache the positions to generate next box position
  local currentRect = {}
  local vx, vy = r.ImGui_GetWindowPos(ctx)
  currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
  currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
  currentRect.right = currentRect.right + 20 * canvas_scale -- add some spacing after the button

  local hasTypes = false
  local typeCt = 0
  for _, v in pairs(ccTypes) do
    if v.exists then typeCt = typeCt + 1 end
    if typeCt > 1 then
      hasTypes = true
      break
    end
  end

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if (hasTypes and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, "context menu")
  end

  local bail = false
  if r.ImGui_BeginPopup(ctx, "context menu") then
    r.ImGui_PushFont(ctx, sans_serif_small)
    for _, v in pairs(ccTypes) do
      if v.exists then
        local rv, selected = r.ImGui_Selectable(ctx, v.label)
        if rv and selected then
          popupFilter = v.val
          bail = true
        end
      end
    end
    r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end

  r.ImGui_PopStyleColor(ctx)

  if bail then return end

  local values = {}

  function makeValueEntry(name)
    return { operation = OP_ABS, opval = (union[name] and union[name] ~= INVALID) and math.floor(union[name]) or INVALID }
  end

  function commonValueEntries()
    for _, v in pairs(commonEntries) do
      values[v] = makeValueEntry(v)
    end
    values.selposticks = { operation = OP_ABS, opval = union.selposticks }
    values.seldurticks = { operation = OP_ABS, opval = union.seldurticks }
  end

  commonValueEntries()
  if popupFilter == NOTE_FILTER then
    values.pitch = makeValueEntry('pitch')
    values.vel = makeValueEntry('vel')
    values.notedur = makeValueEntry('notedur')
  elseif popupFilter ~= 0 then
    values.ccnum = makeValueEntry('ccnum')
    values.ccval = makeValueEntry('ccval')
    values.chanmsg = makeValueEntry('chanmsg')
  end

  local inputs = {}
  local recalcEventTimes = false
  local recalcSelectionTimes = false

  function registerItem(name, recalc)
    local ix1, ix2 = currentRect.left, currentRect.right
    local iy1, iy2 = currentRect.top, currentRect.bottom
    inputs[#inputs + 1] = { name = name, hitx = { ix1 - vx, ix2 - vx }, hity = { iy1 - vy, iy2 - vy }, recalc = recalc and true or false }
  end

  function makeVal(name, str, op)
    local val = tonumber(str)
    if val then
      if name == 'chan' or name == 'beats' then val = val - 1 end
      values[name] = { operation = op and op or OP_ABS, opval = val }
      return true
    end
    return false
  end

  function processString(name, str)
    local char = str:byte(1)
    local val

    -- special case for setting negative numbers for pitch bend
    if name == 'ccval' and popupFilter == 0xE0 and char == OP_SUB then
      if str:byte(2) == OP_SUB then -- two '--' means 'set' for negative pitch bend
        return makeVal(name, str:sub(2))
      end
    end

    if char == OP_SCL then
      if not paramCanScale(name) then return false end

      local first, second = str:sub(2):match("(%d+)[%s%-]+(%d+)")
      if first and second then
        values[name] = { operation = char, opval = first, opval2 = second }
        return true
      else return false
      end
    elseif char == OP_ADD or char == OP_SUB or char == OP_MUL or char == OP_DIV then
      if makeVal(name, str:sub(2), char) then return true end
    end

    return makeVal(name, str)
  end

  function isTimeValue(name)
    if name == 'measures' or name == 'beats' or name == 'ticks' or name == 'notedur' then
      return true
    end
    return false
  end

  local ranges = {}

  function getCurrentRange(name)
    if not ranges[name] then
      local rangeLo = 0xFFFF
      local rangeHi = -0xFFFF
      for _, v in pairs(events) do
        if v.chanmsg == popupFilter then
          if v[name] and v[name] ~= INVALID then
            if v[name] < rangeLo then rangeLo = v[name] end
            if v[name] > rangeHi then rangeHi = v[name] end
          end
        end
      end
      ranges[name] = { lo = math.floor(rangeLo), hi = math.floor(rangeHi) }
    end
    return ranges[name].lo, ranges[name].hi
  end

  function generateLabel(label)
    local ix, iy = currentRect.left, currentRect.top
    r.ImGui_PushFont(ctx, sans_serif_small)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFEF)
    local tw, th = r.ImGui_CalcTextSize(ctx, label)
    local fp = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()) / 2
    local minx = ix + 2
    local miny = iy - r.ImGui_GetTextLineHeight(ctx) - 3
    r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(ctx), minx - fp, miny - fp, minx + tw + fp + 2, miny + th + fp + 1, 0xFFFFFF2F)
    minx = minx - vx
    miny = miny - vy
    r.ImGui_SetCursorPos(ctx, minx + 1, miny)
    r.ImGui_Text(ctx, label)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopFont(ctx)
  end

  local range = {}

  function generateRangeLabel(name)

    if not paramCanScale(name) then return end

    local lo, hi = getCurrentRange(name)
    if lo ~= hi then
      local ix, iy = currentRect.left, currentRect.bottom
      r.ImGui_PushFont(ctx, sans_serif_small)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFBF)
      local text =  '['..lo..'-'..hi..']'
      local tw, th = r.ImGui_CalcTextSize(ctx, text)
      local fp = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()) / 2
      local minx = ix
      local miny = iy + 3
      r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(ctx), minx - fp, miny - fp, minx + tw + fp + 2, miny + th + fp + 2, 0x333355BF)
      minx = minx - vx
      miny = miny - vy
      r.ImGui_SetCursorPos(ctx, minx + 1, miny + 2)
      r.ImGui_Text(ctx, text)
      r.ImGui_PopStyleColor(ctx)
      r.ImGui_PopFont(ctx)
    end
  end

  function makeTextInput(name, label, more, wid)
    local timeval = isTimeValue(name)
    r.ImGui_SameLine(ctx)
    r.ImGui_BeginGroup(ctx)
    r.ImGui_SetNextItemWidth(ctx, wid and (wid * canvas_scale) or (DEFAULT_ITEM_WIDTH * canvas_scale))
    r.ImGui_SetCursorPosX(ctx, (currentRect.right - vx) + (2 * canvas_scale) + (more and (4 * canvas_scale) or 0))

    r.ImGui_PushFont(ctx, sans_serif)

    local val = values[name].opval
    if ((name == 'chan' or name == 'beats') and val ~= INVALID) then val = val + 1 end
    local str = val ~= INVALID and tostring(val) or "-"
    local rt, nstr = r.ImGui_InputText(ctx, '##'..name, str, r.ImGui_InputTextFlags_EnterReturnsTrue() + r.ImGui_InputTextFlags_CharsNoBlank() + r.ImGui_InputTextFlags_CharsDecimal() + r.ImGui_InputTextFlags_AutoSelectAll())
    if rt then
      if processString(name, nstr) then
        if timeval then recalcEventTimes = true else rv = true end
      end
      changedParameter = name
    end
    currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
    currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
    r.ImGui_PopFont(ctx)
    registerItem(name, timeval)
    generateLabel(label)
    generateRangeLabel(name)
    r.ImGui_EndGroup(ctx)
  end

  function timeStringToTime(timestr)
    local a = 1
    local dots = {}
    repeat
      a = timestr:find('%.', a)
      if a then
        table.insert(dots, a)
        a = a + 1
      end
    until not a

    local nums = {}
    if #dots ~= 0 then
        local str = timestr:sub(1, dots[1] - 1)
        table.insert(nums, str)
        for k, v in pairs(dots) do
            str = timestr:sub(v + 1, k ~= #dots and dots[k + 1] - 1 or nil)
            table.insert(nums, str)
        end
    end

    if #nums == 0 then table.insert(nums, timestr) end

    local measures = (not nums[1] or nums[1] == '') and 0 or math.floor(tonumber(nums[1]))
    local beats = (not nums[2] or nums[2] == '') and 0 or math.floor(tonumber(nums[2]))
    local ticks = (not nums[3] or nums[3] == '') and 0 or math.floor(tonumber(nums[3]))

    return measures, beats, ticks
  end

  function BBQToPPQ(measures, beats, ticks, relativeppq, nosubtract)
    if relativeppq then
      local relMeasures, relBeats, _, relTicks = ppqToTime(relativeppq)
      measures = measures + relMeasures
      beats = beats + relBeats
      ticks = ticks + relTicks
    end
    local ppqpos = r.MIDI_GetPPQPosFromProjTime(take, r.TimeMap2_beatsToTime(0, beats, measures)) + ticks
    if relativeppq and not nosubtract then ppqpos = ppqpos - relativeppq end
    return math.floor(ppqpos)
  end

  function parseTimeString(name, str)
    local ppqpos = nil
    local measures, beats, ticks = timeStringToTime(str)
    if measures and beats and ticks then
      local timebeats
      if name == 'selposticks' then
        ppqpos = BBQToPPQ(measures, beats, ticks)
      elseif name == 'seldurticks' then
        ppqpos = BBQToPPQ(measures, beats, ticks, union.selposticks)
      else return nil
      end
      -- r.ShowConsoleMsg('timebeats: '..timebeats..'\n')
      -- r.ShowConsoleMsg('ppqpos: '..ppqpos..'\n')
    else
    end
    return math.floor(ppqpos)
  end

  function processTimeString(name, str)
    local char = str:byte(1)
    local ppqpos = nil

    if char == OP_SCL then str = '0'..str end

    if char == OP_ADD or char == OP_SUB or char == OP_MUL or char == OP_DIV then
      if char == OP_ADD or char == OP_SUB then
        local measures, beats, ticks = timeStringToTime(str:sub(2))
        if measures and beats and ticks then
          local opand = BBQToPPQ(measures, beats, ticks, union.selposticks)
          _, ppqpos = doPerformOperation(nil, union[name], char, opand)
          --ppqpos = ppqpos - union.selposticks
        end
      end
      if not ppqpos then
        _, ppqpos = doPerformOperation(nil, union[name], char, tonumber(str:sub(2)))
      end
    else
      ppqpos = parseTimeString(name, str)
    end
    if ppqpos then
      values[name] = { operation = OP_ABS, opval = ppqpos }
      return true
    end
    return false
  end

  function makeTimeInput(name, label, more, wid)
    r.ImGui_SameLine(ctx)
    r.ImGui_BeginGroup(ctx)
    r.ImGui_SetNextItemWidth(ctx, wid and (wid * canvas_scale) or (DEFAULT_ITEM_WIDTH * canvas_scale))
    r.ImGui_SetCursorPosX(ctx, (currentRect.right - vx) + (2 * canvas_scale) + (more and (4 * canvas_scale) or 0))

    r.ImGui_PushFont(ctx, sans_serif)

    local measuresOffset = name == 'seldurticks' and -1 or 0
    local beatsOffset = name == 'seldurticks' and 0 or 1
    local val = values[name].opval
    local measures, beats, _, ticks = ppqToTime(values[name].opval)
    local str = (measures + measuresOffset)..'.'..(beats + beatsOffset)..'.'..ticks
    local rt, nstr = r.ImGui_InputText(ctx, '##'..name, str, r.ImGui_InputTextFlags_EnterReturnsTrue() + r.ImGui_InputTextFlags_CharsNoBlank() + r.ImGui_InputTextFlags_CharsDecimal() + r.ImGui_InputTextFlags_AutoSelectAll())
    if rt then
      if processTimeString(name, nstr) then
        recalcSelectionTimes = true
        changedParameter = name
      end
    end
    currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
    currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
    r.ImGui_PopFont(ctx)
    -- registerItem(name, true)
    generateLabel(label)
    -- generateRangeLabel(name) -- GenerateTimeRangeLabel?
    r.ImGui_EndGroup(ctx)
  end

  rv = false

  makeTextInput('measures', 'Bars')
  makeTextInput('beats', 'Beats')
  makeTextInput('ticks', 'Ticks')
  makeTextInput('chan', 'Chan', true)

  if popupFilter == NOTE_FILTER then
    makeTextInput('pitch', 'Pitch')
    makeTextInput('vel', 'Velocity')
    makeTextInput('notedur', 'Length (ticks)', true, DEFAULT_ITEM_WIDTH * 2)
  elseif popupFilter ~= 0 then
    if not cc2byte then makeTextInput('ccnum', 'Ctrlr') end
    makeTextInput('ccval', 'Value')
  end

  makeTimeInput('selposticks', 'Sel. Position', true, DEFAULT_ITEM_WIDTH * 2)
  makeTimeInput('seldurticks', 'Sel. Duration', true, DEFAULT_ITEM_WIDTH * 2)

  local v, _ = r.ImGui_GetMouseWheel(ctx)
  local adjust = v > 0 and -1 or v < 0 and 1 or 0

  local posx, posy = r.ImGui_GetMousePos(ctx)
  posx = posx - vx
  posy = posy - vy
  if adjust ~= 0 then
    local mods = r.ImGui_GetKeyMods(ctx)
    local shiftdown = mods & r.ImGui_Mod_Shift() ~= 0
    if shiftdown then
      adjust = adjust * 3
    end
    for _, v in pairs(inputs) do
      if values[v.name].operation == OP_ABS and values[v.name].opval ~= INVALID
      and posy > v.hity[1] and posy < v.hity[2]
      and posx > v.hitx[1] and posx < v.hitx[2]
      then
        if v.name == 'ticks' and shiftdown then
          adjust = adjust > 1 and 5 or -5
        elseif v.name == 'notedur' and shiftdown then
          adjust = adjust > 1 and 10 or -10
        end

        values[v.name].opval = values[v.name].opval + adjust
        if v.recalc then recalcEventTimes = true
        else rv = true end

        break
      end
    end
  end

  if recalcEventTimes or recalcSelectionTimes then rv = true end

  local cachedSelPosTicks = nil
  local cachedSelDurTicks = nil

  function performTimeSelectionOperation(e)
    local rv = true
    if changedParameter == 'seldurticks' then
      local newdur = cachedSelDurTicks
      if not newdur then
        local event = { seldurticks = union.seldurticks }
        rv, newdur = performOperation('seldurticks', event)
        cachedSelDurTicks = newdur
      end
      if rv then
        local inlo, inhi = union.selposticks, union.selendticks
        local outlo, outhi = union.selposticks, union.selposticks + newdur
        local newppq = math.floor(((e.ppqpos - inlo) / (inhi - inlo)) * (outhi - outlo) + outlo)
        -- r.ShowConsoleMsg('newppq from seldur: '..newppq..'\n')
        return true, newppq
      end
    elseif changedParameter == 'selposticks' then
      local newpos = cachedSelPosTicks
      if not newpos then
        local event = { selposticks = union.selposticks }
        rv, newpos = performOperation('selposticks', event)
        cachedSelPosTicks = newpos
      end
      if rv then
        local newppq = e.ppqpos + (newpos - union.selposticks)
        -- r.ShowConsoleMsg('newppq from selpos: '..newppq..'\n')
        return true, newppq
      end
    end
    return false, INVALID
  end

  function doPerformOperation(name, baseval, op, opval, opval2)
    if op == OP_ABS then
      if opval ~= INVALID then return true, opval
      else return true, baseval end
    elseif op == OP_ADD then
      return true, baseval + opval
    elseif op == OP_SUB then
      return true, baseval - opval
    elseif op == OP_MUL then
      return true, baseval * opval
    elseif op == OP_DIV then
      return true, baseval / opval
    elseif op == OP_SCL and name and opval2 then
      local inlo, inhi = getCurrentRange(name)
      local inrange = inhi - inlo
      if inrange ~= 0 then
        local valnorm = (baseval - inlo) / (inhi - inlo)
        local valscaled = (valnorm * (opval2 - opval)) + opval
        return true, valscaled
      else return false, INVALID
      end
    end
    return false, INVALID
  end

  function performOperation(name, e)
    if name == 'ppqpos' then return performTimeSelectionOperation(e) end

    local op = values[name]
    if op then
      return doPerformOperation(name, e[name], op.operation, op.opval, op.opval2)
    end
    return false, INVALID
  end

  function getEventValue(name, e, vals)
    local rv, val = performOperation(name, e)
    if rv then
      if name == 'chan' then val = val < 0 and 0 or val > 15 and 15 or val
      elseif name == 'beats' then val = val < 0 and 0 or val >= e.beatsmax and e.beatsmax - 1 or val
      elseif name == 'pitch' or name == 'vel' or name == 'ccnum' then val = val < 0 and 0 or val > 127 and 127 or val
      elseif name == 'ccval' then
        if e.chanmsg == 0xE0 then val = val < -(1<<13) and -(1<<13) or val > ((1<<13) - 1) and ((1<<13) - 1) or val
        else val = val < 0 and 0 or val > 127 and 127 or val
        end
      else val = val < 0 and 0 or val
      end
      return math.floor(val)
    end
    return INVALID
  end

  function getValuesForEvent(e)
    local vals = {}
    if e.chanmsg ~= popupFilter then return {} end

    vals.measures = getEventValue('measures', e)
    vals.beats = getEventValue('beats', e)
    vals.ticks = getEventValue('ticks', e)
    vals.chan = getEventValue('chan', e)
    if popupFilter == NOTE_FILTER then
      vals.pitch = getEventValue('pitch', e)
      vals.vel = getEventValue('vel', e)
      vals.notedur = getEventValue('notedur', e)
    elseif popupFilter ~= 0 then
      vals.ccnum = getEventValue('ccnum', e)
      vals.ccval = getEventValue('ccval', e)
      if e.chanmsg == 0xA0 then
        vals.msg2 = ccval
        vals.msg3 = 0
      elseif e.chanmsg == 0xE0 then
        vals.ccval = vals.ccval + (1<<13)
        if vals.ccval > ((1<<14) - 1) then vals.ccval = ((1<<14) - 1) end
        vals.msg2 = vals.ccval & 0x7F
        vals.msg3 = (vals.ccval >> 7) & 0x7F
      else
        vals.msg2 = vals.ccnum
        vals.msg3 = vals.ccval
      end
    end
    if recalcSelectionTimes then
      vals.ppqpos = getEventValue('ppqpos', e)
    end
    return vals
  end

  if rv then
    r.Undo_BeginBlock2(0)
    r.MIDI_DisableSort(take)
    for _, v in pairs(events) do
      if popupFilter == v.chanmsg then
        local vals = getValuesForEvent(v)
        local newstartppq = INVALID
        if recalcEventTimes then
          local timebeats = r.TimeMap2_beatsToTime(0, vals.beats, vals.measures)
          newstartppq = r.MIDI_GetPPQPosFromProjTime(take, timebeats) + vals.ticks
        end
        if recalcSelectionTimes then
          newstartppq = vals.ppqpos
        end
        local vppqpos = newstartppq ~= INVALID and newstartppq or v.ppqpos
        if popupFilter == NOTE_FILTER then
          local vendppqpos = vppqpos + vals.notedur or nil
          r.MIDI_SetNote(take, v.idx, v.selected, v.muted, vppqpos, vendppqpos, vals.chan, vals.pitch, vals.vel)
        elseif popupFilter ~= 0 then
          r.MIDI_SetCC(take, v.idx, v.selected, v.muted, vppqpos, v.chanmsg, vals.chan, vals.msg2, vals.msg3)
        end
      end
    end
    r.MIDI_Sort(take)
    r.MarkTrackItemsDirty(r.GetMediaItemTake_Track(take), r.GetMediaItemTake_Item(take))
    r.Undo_EndBlock2(0, "Edit CC(s)", -1)
  end
end

local font_size = 13
local font_size_small = 11
local DEFAULT_WIDTH = 825
local DEFAULT_HEIGHT = 89
local ww = DEFAULT_WIDTH
local wh = DEFAULT_HEIGHT

local function loop()

  --local wscale = ww / DEFAULT_WIDTH
  --local hscale =  wh / DEFAULT_HEIGHT
  canvas_scale = ww / DEFAULT_WIDTH
  if canvas_scale > 1.5 then canvas_scale = 1.5 end

  local new_font_size = math.floor(13 * canvas_scale)
  local new_font_size_small = math.floor(11 * canvas_scale)

  if font_size ~= new_font_size then
    if sans_serif then r.ImGui_Detach(ctx, sans_serif) end
    sans_serif = r.ImGui_CreateFont('sans-serif', new_font_size)
    r.ImGui_Attach(ctx, sans_serif)
    font_size = new_font_size
  end

  if font_size_small ~= new_font_size_small then
    if sans_serif_small then r.ImGui_Detach(ctx, sans_serif_small) end
    sans_serif_small = r.ImGui_CreateFont('sans-serif', new_font_size_small)
    r.ImGui_Attach(ctx, sans_serif_small)
    font_size_small = new_font_size_small
  end

  r.ImGui_PushFont(ctx, sans_serif)

  r.ImGui_SetNextWindowSize(ctx, ww, wh, r.ImGui_Cond_FirstUseEver())
  r.ImGui_SetNextWindowBgAlpha(ctx, 1.0)

  local winheight = r.ImGui_GetFrameHeight(ctx) * 4.6
  r.ImGui_SetNextWindowSizeConstraints(ctx, DEFAULT_WIDTH, winheight, DEFAULT_WIDTH * 3, winheight)

  local visible, open = r.ImGui_Begin(ctx, 'Event Editor', true, r.ImGui_WindowFlags_TopMost() + r.ImGui_WindowFlags_NoScrollWithMouse() + r.ImGui_WindowFlags_NoScrollbar()) -- + r.ImGui_WindowFlags_NoResize())
  if visible then
    local modKey = r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_Shortcut()
    local modShiftKey = r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_Shortcut() + r.ImGui_Mod_Shift()
    if modKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then
      r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40013)
    elseif modShiftKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then
      r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40014)
    end
    myWindow()
    ww, wh = r.ImGui_GetWindowSize(ctx)
    r.ImGui_End(ctx)
  end
  r.ImGui_PopFont(ctx)

  if open then
    r.defer(loop)
  end
end

r.defer(loop)
