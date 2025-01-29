--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Classes = {}

local r = reaper

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

----------------------------------------------------
-- MouseMods pseudo-object

local MouseMods = {}
MouseMods.__index = MouseMods

function MouseMods.new(shift, alt, ctrl, super)
  local self = setmetatable({}, MouseMods)
  self.shiftFlag = shift or false
  self.altFlag = alt or false
  self.ctrlFlag = ctrl or false
  self.superFlag = super or false
  return self
end

function MouseMods:clone()
  return MouseMods.new(self.shiftFlag, self.altFlag, self.ctrlFlag, self.superFlag)
end

function MouseMods:set(shift, alt, ctrl, super)
  self.shiftFlag = shift
  self.altFlag = alt
  self.ctrlFlag = ctrl
  self.superFlag = super
end

function MouseMods:none()
  return not (self.shiftFlag or self.altFlag or self.ctrlFlag or self.superFlag)
end

function MouseMods:all()
  return (self.shiftFlag and self.altFlag and self.ctrlFlag and self.superFlag)
end

function MouseMods:matchesFlags(modFlags, optional)
  if not optional and (not modFlags or modFlags == 0) then return self:none()
  else
    modFlags = modFlags or 0
    return self:matches({
      shift = (optional and optional.shift) and '' or (modFlags & 1 ~= 0),
      ctrl = (optional and optional.ctrl) and '' or (modFlags & 2 ~= 0),
      alt = (optional and optional.alt) and '' or (modFlags & 4 ~= 0),
      super = (optional and optional.super) and '' or (modFlags & 8 ~= 0)
    })
  end
end

function MouseMods:matches(mods)
  return (self.shiftFlag == (mods.shift and true or false) or mods.shift == '')
     and (self.altFlag == (mods.alt and true or false) or mods.alt == '')
     and (self.ctrlFlag == (mods.ctrl and true or false) or mods.ctrl == '')
     and (self.superFlag == (mods.super and true or false) or mods.super == '')
end

function MouseMods:shift()
  return self.shiftFlag
end

function MouseMods:shiftOnly()
  return self:matches({ shift = true })
end

function MouseMods:alt()
  return self.altFlag
end

function MouseMods:altOnly()
  return self:matches({ alt = true })
end

function MouseMods:ctrl()
  return self.ctrlFlag
end

function MouseMods:ctrlOnly()
  return self:matches({ ctrl = true })
end

function MouseMods:super()
  return self.superFlag
end

function MouseMods:superOnly()
  return self:matches({ super = true })
end

function MouseMods:__tostring()
  return string.format('MouseMods(shift=%d, alt=%d, ctrl=%d, super=%d)',
                        self.shiftFlag and 1 or 0, self.altFlag and 1 or 0, self.ctrlFlag and 1 or 0, self.superFlag and 1 or 0)
end

----------------------------------------------------
-- Point pseudo-object definition with x, y (for easier printing)

local Point = {}
Point.__index = Point

function Point.new(x, y)
  local self = setmetatable({}, Point)
  self.x = x or 0
  self.y = y or 0
  return self
end

function Point:clone()
  return Point.new(self.x, self.y)
end

function Point:__tostring()
  return string.format('Point(x=%.2f, y=%.2f)',
                        self.x, self.y)
end

----------------------------------------------------

local Extent = {}
Extent.__index = Extent

function Extent.new(min, max)
  local self = setmetatable({}, Extent)
  self.min = min or 0
  self.max = max or 0
  return self
end

function Extent:size()
  return math.abs(self.max - self.min)
end

function Extent:shift(delta)
  self.min = self.min + delta
  self.max = self.max + delta
end

function Extent:__tostring()
  return string.format('Extent(min=%.2f, max=%.2f)',
                        self.min, self.max)
end

function Extent:serialize()
  return {
    min = self.min,
    max = self.max
  }
end

----------------------------------------------------
-- Rect pseudo-object definition with x1, y1, x2, y2

local Rect = {}
Rect.__index = Rect

-- Constructor for Rect
function Rect.new(x1, y1, x2, y2)
  local self = setmetatable({}, Rect)
  self.x1 = x1 or 0
  self.y1 = y1 or 0
  self.x2 = x2 or 0
  self.y2 = y2 or 0
  return self
end

-- Method to get the x size (width)
function Rect:width()
  return math.abs(self.x2 - self.x1)
end

-- Method to get the y size (height)
function Rect:height()
  return math.abs(self.y2 - self.y1)
end

function Rect:coords()
  return self.x1, self.y1, self.x2, self.y2
end

function Rect:offset(dx, dy)
  self.x1 = self.x1 + dx
  self.y1 = self.y1 + dy
  self.x2 = self.x2 + dx
  self.y2 = self.y2 + dy
end

function Rect:equals(rect)
  return rect
     and self.x1 == rect.x1
     and self.y1 == rect.y1
     and self.x2 == rect.x2
     and self.y2 == rect.y2
end

function Rect:clone(grow)
  grow = grow or 0
  return Rect.new(self.x1 - grow, self.y1 - grow, self.x2 + grow, self.y2 + grow)
end

function Rect:compare(rect)
  return self.x1 == rect.x1
    and self.y1 == rect.y1
    and self.x2 == rect.x2
    and self.y2 == rect.y2
end

-- Method to display the Rect as a string
function Rect:__tostring()
  return string.format('Rect(x1=%.2f, y1=%.2f, x2=%.2f, y2=%.2f)',
                        self.x1, self.y1, self.x2, self.y2)
end

-- Serialize the Rect object to a table
function Rect:serialize()
  return {
      x1 = self.x1,
      y1 = self.y1,
      x2 = self.x2,
      y2 = self.y2,
  }
end

function Rect.deserialize(data)
  local self = setmetatable({}, Rect)
  self.x1 = data.x1
  self.y1 = data.y1
  self.x2 = data.x2
  self.y2 = data.y2
  return self
end

function Rect:conform()
  if self.x1 > self.x2 then
    local tmp = self.x2
    self.x2 = self.x1
    self.x1 = tmp
  end
  if self.y1 > self.y2 then
    local tmp = self.y2
    self.y2 = self.y1
    self.y1 = tmp
  end
  return self
end

----------------------------------------------------

local TimeValueExtents = {}
TimeValueExtents.__index = TimeValueExtents

function TimeValueExtents.new(minTicks, maxTicks, minVal, maxVal, minTime, maxTime)
  local self = setmetatable({}, TimeValueExtents)
  self.ticks = Extent.new(minTicks, maxTicks)
  self.vals = Extent.new(minVal, maxVal)
  self.time = (minTime and maxTime) and Extent.new(minTime, maxTime) or nil
  return self
end

function TimeValueExtents:clone()
  return TimeValueExtents.new(self.ticks.min, self.ticks.max, self.vals.min, self.vals.max, self.time and self.time.min or nil, self.time and self.time.max or nil)
end

function TimeValueExtents:__tostring()
  return string.format('TimeValueExtents(ticks => min=%.2f, max=%.2f; vals => min=%.2f, max=%.2f' .. (self.time and '; time => min=%.2f, max=%.2f' or '') .. ')',
                        self.ticks.min, self.ticks.max, self.vals.min, self.vals.max, self.time and self.time.min, self.time and self.time.max)
end

function TimeValueExtents.deserialize(data)
  local self = setmetatable({}, TimeValueExtents)
  self.ticks = Extent.new(data.ticks.min, data.ticks.max)
  self.vals = Extent.new(data.vals.min, data.vals.max)
  self.time = data.time and Extent.new(data.time.min, data.time.max) or nil
  return self
end

function TimeValueExtents:serialize()
  local rv = {
    ticks = self.ticks:serialize(),
    vals = self.vals:serialize()
  }
  if self.time then rv.time = self.time:serialize() end
  return rv
end

----------------------------------------------------

local Area = {}
Area.__index = Area

function Area.newFromRect(tab, completionFn)
  local self = setmetatable({}, Area)

  self.viewRect = tab.viewRect
  self.logicalRect = tab.logicalRect
  self.origin = tab.origin
  self.ccLane = tab.ccLane
  self.ccType = tab.ccType
  self.active = tab.active or false
  self.fullLane = tab.fullLane or false

  if completionFn then
    completionFn(self)
  end

  return self
end

function Area.new(tab, completionFn)
  local self = setmetatable({}, Area)

  self.ccLane = tab.ccLane
  self.ccType = tab.ccType
  self.timeValue = TimeValueExtents.deserialize(tab.timeValue)
  self.active = false
  self.fullLane = tab.fullLane or false

  if completionFn then
    completionFn(self)
  end

  return self
end

function Area.deserialize(tab, completionFn)
  return Area.new(tab, completionFn)
end

function Area:serialize()
  return {
    ccLane = self.ccLane,
    ccType = self.ccType,
    fullLane = self.fullLane,
    timeValue = self.timeValue:serialize()
  }
end

----------------------------------------------------

Classes.deserialize = deserialize
Classes.serialize = serialize

Classes.Area = Area
Classes.MouseMods = MouseMods
Classes.Point = Point
Classes.Rect = Rect
Classes.Extent = Extent
Classes.TimeValueExtents = TimeValueExtents

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

Classes.dragDirectionToString = dragDirectionToString
Classes.sortAreas = sortAreas

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

Classes.is_windows = is_windows
Classes.is_macos = is_macos
Classes.is_linux = is_linux

Classes.getDPIScale = getDPIScale

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

Classes.ccTypeToChanmsg = ccTypeToChanmsg
Classes.ccTypeToRange = ccTypeToRange
Classes.convertCCTypeChunkToAPI = convertCCTypeChunkToAPI

-- Helper function to generate a hash key from a complex value
local function hashValue(value)
  if type(value) == "table" then
    local parts = {}
    -- Sort keys for consistent ordering
    local keys = {}
    for k in pairs(value) do
      table.insert(keys, k)
    end
    table.sort(keys)

    -- Build hash string from sorted key-value pairs
    for _, k in ipairs(keys) do
      table.insert(parts, k .. ":" .. hashValue(value[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  else
    -- For non-table values, convert to string
    return tostring(value)
  end
end

-- Main function to add unique values to a table
local function addUnique(t, value)
  -- Store hash lookup table in the table's metatable
  if not getmetatable(t) then
    setmetatable(t, {_hashes = {}})
  end
  local mt = getmetatable(t)

  -- Generate hash for the new value
  local hash = hashValue(value)

  -- Check if hash exists
  if not mt._hashes[hash] then
    table.insert(t, value)
    mt._hashes[hash] = true
    return true
  else
    -- r.ShowConsoleMsg('found hash\n')
  end
  return false
end

Classes.addUnique = addUnique

return Classes
