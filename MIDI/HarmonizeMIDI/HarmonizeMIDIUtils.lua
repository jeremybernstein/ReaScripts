--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local reaper = reaper
local intervals_

function fromCSV(s) -- stolen from http://lua-users.org/wiki/CsvUtils
  s = s .. ',' -- ending comma
  local t = {} -- table to collect fields
  local fieldstart = 1
  repeat
    -- next field is quoted? (start with `"'?)
    if string.find(s, '^"', fieldstart) then
      local a, c
      local i  = fieldstart
      repeat
        -- find closing quote
        a, i, c = string.find(s, '"("?)', i+1)
      until c ~= '"'    -- quote not followed by quote?
      if not i then error('unmatched "') end
      local f = string.sub(s, fieldstart+1, i-1)
      table.insert(t, (string.gsub(f, '""', '"')))
      fieldstart = string.find(s, ',', i) + 1
    else -- unquoted; find next comma
      local nexti = string.find(s, ',', fieldstart)
      table.insert(t, string.sub(s, fieldstart, nexti-1))
      fieldstart = nexti + 1
    end
  until fieldstart > string.len(s)
  return t
end

function ProcessArgs(csv)
  local valid = false
  local intervals = fromCSV(csv)
  for key, val in pairs(intervals) do
    local interval = tonumber(val)
    if interval and interval ~= 0 then
      valid = true
      intervals[key] = interval
    else
      intervals[key] = 0
    end
  end
  return valid, intervals
end

function ProcessTake(take, onlySelected, areaStart, areaEnd)
  local intervals = intervals_
  local rv, MIDIstring = reaper.MIDI_GetAllEvts(take)

  local MIDIlen = MIDIstring:len()
  local stringPos = 1 -- Position inside MIDIstring while parsing

  local MIDIEvents = {}
  local ppqTime = 0;

  while stringPos < MIDIlen - 12 do -- -12 to exclude final All-Notes-Off message
    local offset, flags, msg, newStringPos = string.unpack("i4Bs4", MIDIstring, stringPos)

    MIDIEvents[#MIDIEvents + 1] = string.sub(MIDIstring, stringPos, newStringPos - 1)
    ppqTime = ppqTime + offset
    if not onlySelected or (flags & 1 ~= 0) then
      if msg:byte(1) & 0xF0 == 0x90
        or msg:byte(1) & 0xF0 == 0x80
      then
        doit = false
        if not (areaStart and areaEnd) then doit = true
        else
          projTime = reaper.MIDI_GetProjTimeFromPPQPos(take, ppqTime)
          if projTime >= areaStart and projTime <= areaEnd then doit = true end
        end

        if doit then
          for _, interval in pairs(intervals) do
            if interval ~= 0 then
              local b1, b2, b3, bPos = string.unpack("BBB", msg)
              MIDIEvents[#MIDIEvents + 1] = string.pack("i4Bs4", 0, flags, table.concat({string.char(b1), string.char(b2 + interval), string.char(b3)}))
            end
          end
        end
      end
    end
    stringPos = newStringPos
  end

  reaper.MIDI_SetAllEvts(take, table.concat(MIDIEvents) .. MIDIstring:sub(-12))
  reaper.MIDI_Sort(take)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), reaper.GetMediaItemTake_Item(take))
end

function GetItemsInRange(track, areaStart, areaEnd)
  local items = {}
  local itemCount = reaper.CountTrackMediaItems(track)
  for k = 0, itemCount - 1 do
    local item = reaper.GetTrackMediaItem(track, k)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local itemEndPos = pos+length

    --check if item is in area bounds
    if (itemEndPos > areaStart and itemEndPos <= areaEnd) or
      (pos >= areaStart and pos < areaEnd) or
      (pos <= areaStart and itemEndPos >= areaEnd) then
        table.insert(items,item)
    end
  end

  return items
end

function GetRazorEdits()
  local trackCount = reaper.CountTracks(0)
  local areaMap = {}
  for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    local ret, area = reaper.GetSetMediaTrackInfo_String(track, 'P_RAZOREDITS', '', false)
    if area ~= '' then
      --PARSE STRING
      local str = {}
      for j in string.gmatch(area, "%S+") do
        table.insert(str, j)
      end

      --FILL AREA DATA
      local j = 1
      while j <= #str do
        --area data
        local areaStart = tonumber(str[j])
        local areaEnd = tonumber(str[j+1])
        local GUID = str[j+2]
        local isEnvelope = GUID ~= '""'

        --get item/envelope data
        local items = {}
        local envelopeName, envelope
        local envelopePoints

        if not isEnvelope then
          items = GetItemsInRange(track, areaStart, areaEnd)
        else
        end

        local areaData = {
          areaStart = areaStart,
          areaEnd = areaEnd,

          track = track,
          items = items,

          --envelope data
          isEnvelope = isEnvelope,
        }

        if not includeEnvelopes or isEnvelope then
          table.insert(areaMap, areaData)
        end
        j = j + 3
      end
    end
  end

  return areaMap
end

function DoHarmonizeMIDI(intervals)
  _, _, sectionID = reaper.get_action_context()
  -- ---------------- MIDI Editor ---------- Event List ------- Inline Editor
  local isME = sectionID == 32060 or sectionID == 32061 or sectionID == 32062

  intervals_ = intervals

  reaper.Undo_BeginBlock2(0)

  if isME then
    local hwnd = reaper.MIDIEditor_GetActive()
    if hwnd then
      local take = reaper.MIDIEditor_GetTake(hwnd)
      if take then
        ProcessTake(take, true)
      end
    end
  else
    local areaMap = GetRazorEdits()
    if #areaMap > 0 then
      for _, areaData in pairs(areaMap) do
        for _, item in pairs(areaData.items) do
          local take = reaper.GetActiveTake(item)
          if take then
            if reaper.TakeIsMIDI(take) then
              ProcessTake(take, false, areaData.areaStart, areaData.areaEnd)
            end
          end
        end
      end
    else
      local selectedItems = reaper.CountSelectedMediaItems(0)
      for i = 0, selectedItems - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        if item then
          local take = reaper.GetActiveTake(item)
          if take then
            if reaper.TakeIsMIDI(take) then
              ProcessTake(take)
            end
          end
        end
      end
    end
  end

  local first = true
  local intervalStr = ""
  for _, interval in pairs(intervals) do
    intervalStr = intervalStr .. (first and "" or ", ") .. (interval > 0 and "+" or "") .. tostring(interval)
    first = false
  end

  reaper.Undo_EndBlock2(0,  "Harmonize MIDI (" .. intervalStr .. ")", -1)

  reaper.UpdateArrange()
end
