--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Helper = {}

local r = reaper

local classes = require 'MIDIRazorEdits_Classes'

local TimeValueExtents = classes.TimeValueExtents
local GLOBAL_PREF_SLOP = 10 -- ticks

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
_G.spairs = spairs

local function deserialize(str)
  local f, err = load('return ' .. str)
  if not f then r.ShowConsoleMsg(err .. '\n') end
  return f ~= nil and f() or nil
end
_G.deserialize = deserialize

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
  local type = type(val)
  if type == 'table' then
    tmp = tmp .. '{' .. (not skipnewlines and '\n' or '')
    for k, v in spairs(val, orderByKey) do
      tmp =  tmp .. serialize(v, k, skipnewlines, depth + 1) .. ',' .. (not skipnewlines and '\n' or '')
    end
    tmp = tmp .. string.rep(' ', depth) .. '}'
  elseif type == 'number' then
    tmp = tmp .. tostring(val)
  elseif type == 'string' then
    tmp = tmp .. string.format('%q', val)
  elseif type == 'boolean' then
    tmp = tmp .. (val and 'true' or 'false')
  else
    tmp = tmp .. '"[unknown datatype:' .. type .. ']"'
  end
  return tmp
end
_G.serialize = serialize

----------------------------------------------------------
--------- BASE64 LIB from http://lua-users.org/wiki/BaseSixtyFour

-- character table string
local bt = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- encoding
local function b64enc(data)
  return ((data:gsub('.', function(x)
    local r,b='',x:byte()
    for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
    return r;
  end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if (#x < 6) then return '' end
    local c=0
    for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
    return bt:sub(c+1,c+1)
  end)..({ '', '==', '=' })[#data%3+1])
end

-- decoding
local function b64dec(data)
  data = string.gsub(data, '[^'..bt..'=]', '')
  return (data:gsub('.', function(x)
    if (x == '=') then return '' end
    local r,f='',(bt:find(x)-1)
    for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
    return r;
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if (#x ~= 8) then return '' end
    local c=0
    for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
    return string.char(c)
  end))
end

_G.toExtStateString = function(tab)
  return next(tab) ~= nil and b64enc(serialize(tab)) or nil
end

_G.fromExtStateString = function(b64str)
  return deserialize(b64dec(b64str))
end

------------------------------------------------

-- Direction constants
local Direction = {
  LEFT = 'LEFT',
  RIGHT = 'RIGHT',
  UP = 'UP',
  DOWN = 'DOWN',
  LEFT_UP = 'LEFT_UP',
  LEFT_DOWN = 'LEFT_DOWN',
  RIGHT_UP = 'RIGHT_UP',
  RIGHT_DOWN = 'RIGHT_DOWN'
}

local function dragDirectionToString(dragDirection)
  if dragDirection then
    if dragDirection.left then
      if dragDirection.top then return 'LEFT_UP'
      elseif dragDirection.bottom then return 'LEFT_DOWN'
      else return 'LEFT'
      end
    end

    if dragDirection.right then
      if dragDirection.top then return 'RIGHT_UP'
      elseif dragDirection.bottom then return 'RIGHT_DOWN'
      else return 'RIGHT'
      end
    end

    if dragDirection.top then return 'UP' end
    if dragDirection.bottom then return 'DOWN' end
  end
  return nil
end

-- Helper function to get a rect's center coordinates
local function getRectCenter(rect)
  return (rect.x1 + rect.x2) / 2, (rect.y1 + rect.y2) / 2
end

-- Comparison functions for each direction
local compareFuncs = {
  [Direction.LEFT] = function(area1, area2)
      local center1_x = (area1.logicalRect.x1 + area1.logicalRect.x2) / 2
      local center2_x = (area2.logicalRect.x1 + area2.logicalRect.x2) / 2
      return center1_x < center2_x
  end,

  [Direction.RIGHT] = function(area1, area2)
      local center1_x = (area1.logicalRect.x1 + area1.logicalRect.x2) / 2
      local center2_x = (area2.logicalRect.x1 + area2.logicalRect.x2) / 2
      return center1_x > center2_x
  end,

  [Direction.UP] = function(area1, area2)
      local center1_y = (area1.logicalRect.y1 + area1.logicalRect.y2) / 2
      local center2_y = (area2.logicalRect.y1 + area2.logicalRect.y2) / 2
      return center1_y < center2_y
  end,

  [Direction.DOWN] = function(area1, area2)
      local center1_y = (area1.logicalRect.y1 + area1.logicalRect.y2) / 2
      local center2_y = (area2.logicalRect.y1 + area2.logicalRect.y2) / 2
      return center1_y > center2_y
  end,

  [Direction.LEFT_UP] = function(area1, area2)
      local center1_x, center1_y = getRectCenter(area1.logicalRect)
      local center2_x, center2_y = getRectCenter(area2.logicalRect)
      if center1_x ~= center2_x then
          return center1_x < center2_x
      end
      return center1_y < center2_y
  end,

  [Direction.LEFT_DOWN] = function(area1, area2)
      local center1_x, center1_y = getRectCenter(area1.logicalRect)
      local center2_x, center2_y = getRectCenter(area2.logicalRect)
      if center1_x ~= center2_x then
          return center1_x < center2_x
      end
      return center1_y > center2_y
  end,

  [Direction.RIGHT_UP] = function(area1, area2)
      local center1_x, center1_y = getRectCenter(area1.logicalRect)
      local center2_x, center2_y = getRectCenter(area2.logicalRect)
      if center1_x ~= center2_x then
          return center1_x > center2_x
      end
      return center1_y < center2_y
  end,

  [Direction.RIGHT_DOWN] = function(area1, area2)
      local center1_x, center1_y = getRectCenter(area1.logicalRect)
      local center2_x, center2_y = getRectCenter(area2.logicalRect)
      if center1_x ~= center2_x then
          return center1_x > center2_x
      end
      return center1_y > center2_y
  end
}

local function sortAreas(areas, direction)
  if not compareFuncs[direction] then
    r.ShowConsoleMsg('Invalid direction: '  .. tostring(direction) .. '\n')
  end

  -- Create a copy of the input table to avoid modifying the original
  local sortedAreas = {}
  for i, area in ipairs(areas) do
    sortedAreas[i] = area
  end

  -- Sort using table.sort with the appropriate comparison function
  table.sort(sortedAreas, compareFuncs[direction])

  return sortedAreas
end

----------------------------------------------------

local os = r.GetOS()
local is_windows = os:match('Win')
local is_macos = os:match('OS')
local is_linux = os:match('Other')

local function getDPIScale()
  local rv, rScale = r.get_config_var_string('uiscale')
  local uiScale = tonumber(rScale)

  if not uiScale then uiScale = 1 end
  if is_macos then return uiScale end

  local piano_pane_unscaled_w = is_windows and 128 or is_macos and 145 or 161 -- macos is maybe 144?

  local editor_hwnd = r.MIDIEditor_GetActive() -- called before we are initialized
  local piano_pane = r.JS_Window_FindChildByID(editor_hwnd, 1003)
  local _, piano_pane_w = r.JS_Window_GetClientSize(piano_pane)

  local editor_scale = piano_pane_w / piano_pane_unscaled_w
  -- Round to steps of 0.01
  editor_scale = math.floor(editor_scale / 0.01 + 0.01) * 0.01
  return editor_scale
end

----------------------------------------------------

local function ccTypeToChanmsg(ccType)
  if not ccType then return nil, nil end

  local tLanes = {[0x200] = 0x90, -- Velocity
                  [0x201] = 0xE0, -- Pitch
                  [0x202] = 0xC0, -- Program select
                  [0x203] = 0xD0, -- Channel pressure
                  [0x204] = 0, -- Bank/program
                  [0x205] = 0, -- Text
                  [0x206] = 0xF0, -- Sysex
                  [0x207] = 0x90, -- Off velocity
                  [0x208] = 0, -- Notation
                  [0x209] = 0xA0, -- Poly Aftertouch -- v7.29+dev0103
                  [0x210] = 0, -- Media Item lane
                  }
  if type(ccType) == 'number' and 256 <= ccType and ccType <= 287 then
    return 0xB0, -1 -- 14 bit CC range from 256-287 in API
  else
    if tLanes[ccType] then return tLanes[ccType]
    else return 0xB0, (ccType >= 0 and ccType < 128) and ccType or nil
    end
  end
end

local function ccTypeToRange(ccType)
  if not ccType then return 0 end

  local max = 127

  if ccType == 0x201 then max = (1 << 14) - 1 -- pitch bend
  elseif ccType == 0x206 or ccType == 0x208 or ccType >= 0x210 then max = 1
  end

  if type(ccType) == 'number' and 256 <= ccType and ccType <= 287 then
    return (1 << 14) - 1 -- 14 bit CC range from 256-287 in API -- TODO: I guess only if the pref is set to display this as a single 14-bit number?
  end
  return max
end

-- Lane numbers as used in the chunk's VELLANE field differ from those returned by API functions
--    such as MIDIEditor_GetSetting_int(editor, 'last_clicked').
--[[   last_clicked_cc_lane: returns 0-127=CC, 0x100|(0-31)=14-bit CC,
       0x200=velocity, 0x201=pitch, 0x202=program, 0x203=channel pressure,
       0x204=bank/program select, 0x205=text, 0x206=sysex, 0x207=off velocity]]
local function convertCCTypeChunkToAPI(lane)
local tLanes = {[ -1] = 0x200, -- Velocity
                [128] = 0x201, -- Pitch
                [129] = 0x202, -- Program select
                [130] = 0x203, -- Channel pressure
                [131] = 0x204, -- Bank/program
                [132] = 0x205, -- Text
                [133] = 0x206, -- Sysex
                [167] = 0x207, -- Off velocity
                [166] = 0x208, -- Notation
                [168] = 0x209, -- Poly Aftertouch -- v7.29+dev0103
                [ -2] = 0x210, -- Media Item lane
                }
if type(lane) == 'number' and 134 <= lane and lane <= 165 then
  return (lane + 122) -- 14 bit CC range from 256-287 in API
else
  return (tLanes[lane] or lane) -- If 7bit CC, number remains the same
end
end

----------------------------------------------------

local function hashValue(value)
  local t = type(value)
  if t == "number" then
    return value
  end
  if t ~= "table" then
    return tostring(value)
  end

  local parts = {}
  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for i = 1, #keys do
    local k = keys[i]
    parts[i] = k .. ":" .. hashValue(value[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function addUnique(t, value)
  if not (t and value) then return false end
  local mt = getmetatable(t)
  if not mt then
    mt = {_hashes = {}}
    setmetatable(t, mt)
  end
  local hash = hashValue(value)
  if not mt._hashes[hash] then
    t[#t + 1] = value
    mt._hashes[hash] = true
    return true
  end
  return false
end

local function inUniqueTab(t, value)
  if not (t and value) then return false end
  local mt = getmetatable(t)
  if not mt then return false end
  local hash = hashValue(value)
  return mt._hashes[hash] and true or false
end

----------------------------------------------------

local function getNoteSegments(areas, itemInfo, ppqpos, endppqpos, pitch, onlyArea)
  local max, min = math.max, math.min
  local intersecting_areas = {}

  local function checkAreaIntersection(area)
    -- Keep the original positions table approach to maintain same behavior
    local positions = {
      {
        bottom = area.timeValue.vals.min,
        top = area.timeValue.vals.max,
        left = area.timeValue.ticks.min - itemInfo.offsetPPQ,
        right = area.timeValue.ticks.max - itemInfo.offsetPPQ - 1
      }
    }
    if area.unstretchedTimeValue then
      table.insert(positions, 1, {
        bottom = area.unstretchedTimeValue.vals.min,
        top = area.unstretchedTimeValue.vals.max,
        left = area.unstretchedTimeValue.ticks.min - itemInfo.offsetPPQ,
        right = area.unstretchedTimeValue.ticks.max - itemInfo.offsetPPQ - 1
      })
    end

    for _, pos in ipairs(positions) do
      if pitchInRange(pitch, pos.bottom, pos.top) then
        if pos.right >= ppqpos and pos.left <= endppqpos then
          table.insert(intersecting_areas, {
            left = max(pos.left, ppqpos), --overlapMod() and ppqpos or max(pos.left, ppqpos),
            right = min(pos.right, endppqpos) --overlapMod() and endppqpos or min(pos.right, endppqpos)
          })
        end
      end
    end
  end

  if onlyArea then
    checkAreaIntersection(onlyArea)
  else
    for _, area in ipairs(areas) do
      checkAreaIntersection(area)
    end
  end

  if #intersecting_areas == 0 then
    return nil
  end

  -- Sort areas by left edge
  table.sort(intersecting_areas, function(a, b)
    return a.left < b.left
  end)

  -- Merge overlapping areas (unchanged from original)
  local merged_areas = {intersecting_areas[1]}
  for i = 2, #intersecting_areas do
    local current = intersecting_areas[i]
    local last = merged_areas[#merged_areas]

    if current.left <= last.right then
      last.right = max(last.right, current.right)
    else
      table.insert(merged_areas, current)
    end
  end

  local valid_segments = {}

  if merged_areas[1].left > ppqpos then
    local seg_end = merged_areas[1].left - 1
    local length = seg_end - ppqpos + 1
    if length >= GLOBAL_PREF_SLOP then
      table.insert(valid_segments, {ppqpos, seg_end})
    end
  end

  for i = 1, #merged_areas - 1 do
    local seg_start = merged_areas[i].right + 1
    local seg_end = merged_areas[i + 1].left - 1
    local length = seg_end - seg_start + 1
    if length >= GLOBAL_PREF_SLOP then
      table.insert(valid_segments, {seg_start, seg_end})
    end
  end

  if merged_areas[#merged_areas].right < endppqpos then
    local seg_start = merged_areas[#merged_areas].right + 1
    local length = endppqpos - seg_start + 1
    if length >= GLOBAL_PREF_SLOP then
      table.insert(valid_segments, {seg_start, endppqpos})
    end
  end

  return #valid_segments > 0 and valid_segments or nil
end

------------------------------------------------
------------------------------------------------

-- Returns true if two time-value extents intersect
local function doExtentsIntersect(e1, e2)
  return not (e1.ticks.max < e2.ticks.min or
              e1.ticks.min > e2.ticks.max or
              e1.vals.max < e2.vals.min or
              e1.vals.min > e2.vals.max)
end

-- Returns the intersection of two time-value extents, or nil if they don't intersect
local function getIntersection(e1, e2)
  if not doExtentsIntersect(e1, e2) then
    return nil
  end

  return TimeValueExtents.new(
    math.max(e1.ticks.min, e2.ticks.min),
    math.min(e1.ticks.max, e2.ticks.max),
    math.max(e1.vals.min, e2.vals.min),
    math.min(e1.vals.max, e2.vals.max)
  )
end

-- Returns a table of TimeValueExtents objects representing the non-intersecting parts of extents1
local function getNonIntersectingAreas(e1, e2)
  local intersection = getIntersection(e1, e2)
  if not intersection then
    -- If there's no intersection, return the first extents
    return {e1}
  end

  local nonIntersecting = {}

  -- Check earlier time side of intersection
  if intersection.ticks.min > e1.ticks.min then
    table.insert(nonIntersecting, TimeValueExtents.new(
      e1.ticks.min,
      intersection.ticks.min,
      e1.vals.min,
      e1.vals.max
    ))
  end

  -- Check later time side of intersection
  if intersection.ticks.max < e1.ticks.max then
    table.insert(nonIntersecting, TimeValueExtents.new(
      intersection.ticks.max,
      e1.ticks.max,
      e1.vals.min,
      e1.vals.max
    ))
  end

  -- Check lower value side of intersection
  if intersection.vals.min > e1.vals.min then
    table.insert(nonIntersecting, TimeValueExtents.new(
      intersection.ticks.min,
      intersection.ticks.max,
      e1.vals.min,
      intersection.vals.min
    ))
  end

  -- Check upper value side of intersection
  if intersection.vals.max < e1.vals.max then
    table.insert(nonIntersecting, TimeValueExtents.new(
      intersection.ticks.min,
      intersection.ticks.max,
      intersection.vals.max,
      e1.vals.max
    ))
  end

  return nonIntersecting
end

------------------------------------------------

local function getExtentUnion(e1, e2)
  if e1.ticks.max < e2.ticks.min - 0.0001 or e2.ticks.max < e1.ticks.min - 0.0001 then
    return {e1, e2}
  end

  local e1Min = math.floor(e1.vals.min + 0.5)
  local e1Max = math.floor(e1.vals.max + 0.5)
  local e2Min = math.floor(e2.vals.min + 0.5)
  local e2Max = math.floor(e2.vals.max + 0.5)

  local function makeExtent(vMin, vMax, useE1Time, useE2Time)
    return TimeValueExtents.new(
      math.min(useE1Time and e1.ticks.min or math.huge, useE2Time and e2.ticks.min or math.huge),
      math.max(useE1Time and e1.ticks.max or -math.huge, useE2Time and e2.ticks.max or -math.huge),
      vMin,
      vMax
    )
  end

  if e1Min == e2Min and e1Max == e2Max then
    return {makeExtent(e1Min, e1Max, true, true)}
  end

  local result = {}

  if e1Min < e2Min then
    table.insert(result, makeExtent(e1Min, e2Min - 1, true, false))
    if e1Max >= e2Min then
      table.insert(result, makeExtent(e2Min, math.min(e1Max, e2Max), true, true))
    end
  elseif e2Min < e1Min then
    table.insert(result, makeExtent(e2Min, e1Min - 1, false, true))
    if e2Max >= e1Min then
      table.insert(result, makeExtent(e1Min, math.min(e1Max, e2Max), true, true))
    end
  end

  if e1Max > e2Max then
    table.insert(result, makeExtent(e2Max + 1, e1Max, true, false))
  elseif e2Max > e1Max then
    table.insert(result, makeExtent(e1Max + 1, e2Max, false, true))
  end

  return result
end

----------------------------------------------------

local function equalIsh(a, b, epsilon)
  epsilon = epsilon or 1e-9 -- Default tolerance (1e-9, or very small difference)
  return math.abs(a - b) <= epsilon
end
_G.equalIsh = equalIsh

----------------------------------------------------

-- Function to interpolate between two values
local function lerp(a, b, t)
  return a + (t * (b - a))
end

local function scaleValue(input, outputMin, outputMax, scalingFactorStart, scalingFactorEnd, t)
  -- Ensure t is clamped between 0 and 1
  t = math.max(0, math.min(1, t))

  local scalingFactor = lerp(scalingFactorStart, scalingFactorEnd, t)
  scalingFactor = math.max(0, math.min(1, scalingFactor))

  scalingFactor = 1 - scalingFactor -- scalingFactor is inverted

  -- Adjust the output based on the scaling factor
  if equalIsh(scalingFactor, 0.5) then
    return input
  elseif scalingFactor < 0.5 then
    local factor = (0.5 - scalingFactor) / 0.5
    return lerp(input, outputMin, factor)
  elseif scalingFactor > 0.5 then
    local factor = (scalingFactor - 0.5) / 0.5
    return lerp(input, outputMax, factor)
  end
end

local function offsetValue(input, outputMin, outputMax, offsetFactorStart, offsetFactorEnd, t)
  -- Ensure t is clamped between 0 and 1
  t = math.max(0, math.min(1, t))

  local offsetFactor = lerp(offsetFactorStart, offsetFactorEnd, t)
  offsetFactor = math.max(0, math.min(1, offsetFactor))

  offsetFactor = 1 - offsetFactor -- offsetFactor is inverted

  -- Adjust the output based on the scaling factor
  if equalIsh(offsetFactor, 0.5) then
    return input
  elseif offsetFactor < 0.5 then
    local factor = (0.5 - offsetFactor) / 0.5
    return input - ((outputMax - outputMin) * factor)
  elseif offsetFactor > 0.5 then
    local factor = (offsetFactor - 0.5) / 0.5
    return input + ((outputMax - outputMin) * factor)
  end
end
local function compExpValueMiddle(input, outputMin, outputMax, offsetFactorStart, offsetFactorEnd, t, inputMin, inputMax)
  t = math.max(0, math.min(1, t))

  local offsetFactor = lerp(offsetFactorStart, offsetFactorEnd, t)
  offsetFactor = math.max(0, math.min(1, offsetFactor))

  offsetFactor = 1 - offsetFactor

  local middlePoint = (outputMax + outputMin) / 2
  local canClip = 0 --0.15 -- top N percent of values which can clip, not sure if that's so nice

  if equalIsh(offsetFactor, 0.5) then
    return input
  elseif offsetFactor < 0.5 then
    local compressionFactor = (0.5 - offsetFactor) / 0.5
    local distanceFromMiddle = input - middlePoint
    local compressedDistance = distanceFromMiddle * (1 - compressionFactor)
    return middlePoint + compressedDistance
  else
    local inputRange = inputMax - inputMin
    local inputMiddle = inputMin + inputRange * 0.5

    -- Calculate normalized distance from middle (0 at middle, 1 at quartile boundaries)
    local distanceFromMiddle = math.abs(input - inputMiddle) / (inputRange * (0.5 - canClip))
    distanceFromMiddle = math.min(1, distanceFromMiddle)  -- Clamp to 1 for values beyond quartiles

    -- For values below input midpoint, expand toward outputMin
    -- For values above input midpoint, expand toward outputMax
    local fullyExpandedValue = input < inputMiddle and outputMin or outputMax

    -- Calculate expansion amount (0% at 0.5 offset, 100% at 1.0 offset)
    local expansionAmount = (offsetFactor - 0.5) / 0.5
    -- Scale expansion by distance from middle
    expansionAmount = expansionAmount * distanceFromMiddle

    -- Lerp from unity (input) to fully expanded value
    return lerp(input, fullyExpandedValue, expansionAmount)
  end
end

local function compExpValueTopBottom(input, outputMin, outputMax, offsetFactorStart, offsetFactorEnd, t, inputMin, inputMax)
  t = math.max(0, math.min(1, t))

  local offsetFactor = lerp(offsetFactorStart, offsetFactorEnd, t)
  offsetFactor = math.max(0, math.min(1, offsetFactor))
  offsetFactor = 1 - offsetFactor

  if equalIsh(offsetFactor, 0.5) then
    return input
  elseif offsetFactor < 0.5 then
    local compressionFactor = (0.5 - offsetFactor) / 0.5
    local roomToCompress = input - outputMin
    local normalizedInput = (inputMax - input) / (inputMax - inputMin)  -- Note: still inverted for compression
    local curvedInput = normalizedInput ^ 1.5
    if equalIsh(input, inputMin) then
      curvedInput = 1
    end
    local scaledCompression = curvedInput * compressionFactor
    return input - (roomToCompress * scaledCompression)
  else
    local expansionFactor = (offsetFactor - 0.5) / 0.5
    local roomToExpand = outputMax - input
    local normalizedInput = (input - inputMin) / (inputMax - inputMin)
    local curvedInput = normalizedInput ^ 1.5
    if equalIsh(input, inputMax) then
      curvedInput = 1
    end
    local scaledExpansion = curvedInput * expansionFactor
    return input + (roomToExpand * scaledExpansion)
  end
end

----------------------------------------------------

-- VKeys wrappers: prefer rcw_VKeys_* (childwindow), fallback to JS_VKeys_*
-- JS_VKeys_* always present if JS_ReaScriptAPI installed (checked at Lib load)
local has_rcw_Intercept = r.APIExists('rcw_VKeys_Intercept')
local has_rcw_GetState = r.APIExists('rcw_VKeys_GetState')
local has_rcw_ClearState = r.APIExists('rcw_VKeys_ClearState')

local function VKeys_Intercept(key, intercept)
  if has_rcw_Intercept then
    return r.rcw_VKeys_Intercept(key, intercept)
  else
    return r.JS_VKeys_Intercept(key, intercept)
  end
end

local function VKeys_GetState(cutoff)
  if has_rcw_GetState then
    return r.rcw_VKeys_GetState(cutoff)
  else
    return r.JS_VKeys_GetState(cutoff)
  end
end

local function VKeys_ClearState()
  if has_rcw_ClearState then
    r.rcw_VKeys_ClearState()
  end
end

----------------------------------------------------

Helper.deserialize = deserialize
Helper.serialize = serialize

Helper.dragDirectionToString = dragDirectionToString
Helper.sortAreas = sortAreas

Helper.is_windows = is_windows
Helper.is_macos = is_macos
Helper.is_linux = is_linux

Helper.getDPIScale = getDPIScale

Helper.ccTypeToChanmsg = ccTypeToChanmsg
Helper.ccTypeToRange = ccTypeToRange
Helper.convertCCTypeChunkToAPI = convertCCTypeChunkToAPI

Helper.addUnique = addUnique
Helper.inUniqueTab = inUniqueTab
Helper.equalIsh = equalIsh

Helper.getNoteSegments = getNoteSegments
Helper.getNonIntersectingAreas = getNonIntersectingAreas
Helper.getExtentUnion = getExtentUnion

Helper.scaleValue = scaleValue
Helper.offsetValue = offsetValue
Helper.compExpValueMiddle = compExpValueMiddle
Helper.compExpValueTopBottom = compExpValueTopBottom

Helper.GLOBAL_PREF_SLOP = GLOBAL_PREF_SLOP

Helper.VKeys_Intercept = VKeys_Intercept
Helper.VKeys_GetState = VKeys_GetState
Helper.VKeys_ClearState = VKeys_ClearState

-- convert screen Y from GetMousePosition() to native coords matching screenRect
-- macOS screen Y is flipped (origin at bottom), this converts to match lane.topPixel etc
local function screenYToNative(y, windowRect)
  if is_macos and windowRect then
    local _, wy1, _, wy2 = r.JS_Window_GetViewportFromRect(windowRect.x1, windowRect.y1, windowRect.x2, windowRect.y2, false)
    local screenHeight = math.abs(wy2 - wy1)
    return screenHeight - y
  end
  return y
end
Helper.screenYToNative = screenYToNative

-- show popup menu, preferring rcw_ShowMenu if available (better behavior with child windows)
-- menuStr: same format as gfx.showmenu
-- x, y: screen coordinates (optional, defaults to mouse position)
local hasRcwShowMenu = r.APIExists('rcw_ShowMenu')
local function showMenu(menuStr, x, y)
  if not x or not y then
    x, y = r.GetMousePosition()
  end
  if hasRcwShowMenu then
    -- convert Y to Cocoa coords on macOS (origin at bottom)
    if is_macos then
      local _, wy1, _, wy2 = r.JS_Window_GetViewportFromRect(x, y, x, y, false)
      local screenHeight = math.abs(wy2 - wy1)
      y = screenHeight - y
    end
    return r.rcw_ShowMenu(menuStr, x, y)
  else
    gfx.x, gfx.y = x, y
    return gfx.showmenu(menuStr)
  end
end
Helper.showMenu = showMenu

return Helper
