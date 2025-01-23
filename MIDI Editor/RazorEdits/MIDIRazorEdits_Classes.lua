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

local function deserialize(str)
  local f, err = load('return ' .. str)
  if not f then r.ShowConsoleMsg(err .. '\n') end
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

function Area.new(tab, completionFn)
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

function Area.deserialize(tab, completionFn)
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

-- safekeeping
local vKeys = {
  VK_LBUTTON 	    = 0x01,   --  The left mouse button
  VK_RBUTTON 	    = 0x02,   --  The right mouse button
  VK_CANCEL 	    = 0x03,   --  The Cancel virtual key, used for control-break processing
  VK_MBUTTON 	    = 0x04,   --  The middle mouse button
  VK_BACK 	      = 0x08,   --  Backspace
  VK_TAB 	        = 0x09,   --  Tab
  VK_CLEAR 	      = 0x0C,   --  5 (keypad without Num Lock)
  VK_ENTER   	    = 0x0D,   --  Enter
  VK_SHIFT 	      = 0x10,   --  Shift (either one)
  VK_CONTROL 	    = 0x11,   --  Ctrl (either one)
  VK_MENU         = 0x12,   --  Alt (either one)
  VK_PAUSE        = 0x13,   --  Pause
  VK_CAPITAL 	    = 0x14,   --  Caps Lock
  VK_ESCAPE 	    = 0x1B,   --  Esc
  VK_SPACE 	      = 0x20,   --  Spacebar
  VK_PAGEUP 	    = 0x21,   --  Page Up
  VK_PAGEDOWN 	  = 0x22,   --  Page Down
  VK_END 	        = 0x23,   --  End
  VK_HOME 	      = 0x24,   --  Home
  VK_LEFT 	      = 0x25,   --  Left Arrow
  VK_UP 	        = 0x26,   --  Up Arrow
  VK_RIGHT 	      = 0x27,   --  Right Arrow
  VK_DOWN 	      = 0x28,   --  Down Arrow
  VK_SELECT 	    = 0x29,   --  Select
  VK_PRINT 	      = 0x2A,   --  Print (only used by Nokia keyboards)
  VK_EXECUTE 	    = 0x2B,   --  Execute (not used)
  VK_SNAPSHOT 	  = 0x2C,   --  Print Screen
  VK_INSERT 	    = 0x2D,   --  Insert
  VK_DELETE 	    = 0x2E,   --  Delete
  VK_HELP 	      = 0x2F,   --  Help
  VK_0 	          = 0x30,   --  0
  VK_1 	          = 0x31,   --  1
  VK_2 	          = 0x32,   --  2
  VK_3 	          = 0x33,   --  3
  VK_4 	          = 0x34,   --  4
  VK_5 	          = 0x35,   --  5
  VK_6 	          = 0x36,   --  6
  VK_7 	          = 0x37,   --  7
  VK_8 	          = 0x38,   --  8
  VK_9 	          = 0x39,   --  9
  VK_A 	          = 0x41,   --  A
  VK_B 	          = 0x42,   --  B
  VK_C 	          = 0x43,   --  C
  VK_D 	          = 0x44,   --  D
  VK_E 	          = 0x45,   --  E
  VK_F 	          = 0x46,   --  F
  VK_G 	          = 0x47,   --  G
  VK_H 	          = 0x48,   --  H
  VK_I 	          = 0x49,   --  I
  VK_J 	          = 0x4A,   --  J
  VK_K 	          = 0x4B,   --  K
  VK_L 	          = 0x4C,   --  L
  VK_M 	          = 0x4D,   --  M
  VK_N 	          = 0x4E,   --  N
  VK_O 	          = 0x4F,   --  O
  VK_P 	          = 0x50,   --  P
  VK_Q 	          = 0x51,   --  Q
  VK_R 	          = 0x52,   --  R
  VK_S 	          = 0x53,   --  S
  VK_T 	          = 0x54,   --  T
  VK_U 	          = 0x55,   --  U
  VK_V 	          = 0x56,   --  V
  VK_W 	          = 0x57,   --  W
  VK_X 	          = 0x58,   --  X
  VK_Y 	          = 0x59,   --  Y
  VK_Z 	          = 0x5A,   --  Z
  VK_STARTKEY 	  = 0x5B,   --  Start Menu key
  VK_CONTEXTKEY 	= 0x5D,   --  Context Menu key
  VK_NUMPAD0 	    = 0x60,   --  0 (keypad with Num Lock)
  VK_NUMPAD1 	    = 0x61,   --  1 (keypad with Num Lock)
  VK_NUMPAD2 	    = 0x62,   --  2 (keypad with Num Lock)
  VK_NUMPAD3 	    = 0x63,   --  3 (keypad with Num Lock)
  VK_NUMPAD4 	    = 0x64,   --  4 (keypad with Num Lock)
  VK_NUMPAD5 	    = 0x65,   --  5 (keypad with Num Lock)
  VK_NUMPAD6 	    = 0x66,   --  6 (keypad with Num Lock)
  VK_NUMPAD7 	    = 0x67,   --  7 (keypad with Num Lock)
  VK_NUMPAD8 	    = 0x68,   --  8 (keypad with Num Lock)
  VK_NUMPAD9 	    = 0x69,   --  9 (keypad with Num Lock)
  VK_MULTIPLY 	  = 0x6A,   --  * (keypad)
  VK_ADD 	        = 0x6B,   --  = 0x(keypad)
  VK_SEPARATOR 	  = 0x6C,   --  Separator (never generated by the keyboard)
  VK_SUBTRACT 	  = 0x6D,   --  - (keypad)
  VK_DECIMAL 	    = 0x6E,   --  . (keypad with Num Lock)
  VK_DIVIDE 	    = 0x6F,   --  / (keypad)
  VK_F1 	        = 0x70,   --  F1
  VK_F2 	        = 0x71,   --  F2
  VK_F3 	        = 0x72,   --  F3
  VK_F4 	        = 0x73,   --  F4
  VK_F5 	        = 0x74,   --  F5
  VK_F6 	        = 0x75,   --  F6
  VK_F7 	        = 0x76,   --  F7
  VK_F8 	        = 0x77,   --  F8
  VK_F9 	        = 0x78,   --  F9
  VK_F10 	        = 0x79,   --  F10
  VK_F11 	        = 0x7A,   --  F11
  VK_F12 	        = 0x7B,   --  F12
  VK_F13 	        = 0x7C,   --  F13
  VK_F14 	        = 0x7D,   --  F14
  VK_F15 	        = 0x7E,   --  F15
  VK_F16 	        = 0x7F,   --  F16
  VK_F17 	        = 0x80,   --  F17
  VK_F18 	        = 0x81,   --  F18
  VK_F19 	        = 0x82,   --  F19
  VK_F20 	        = 0x83,   --  F20
  VK_F21 	        = 0x84,   --  F21
  VK_F22 	        = 0x85,   --  F22
  VK_F23 	        = 0x86,   --  F23
  VK_F24 	        = 0x87,   --  F24
  VK_NUMLOCK 	    = 0x90,   --  Num Lock
  VK_OEM_SCROLL 	= 0x91,   --  Scroll Lock
  VK_OEM_1 	      = 0xBA,   --  ;
  VK_OEM_PLUS 	  = 0xBB,   --  =
  VK_OEM_COMMA 	  = 0xBC,   --  ,
  VK_OEM_MINUS 	  = 0xBD,   --  -
  VK_OEM_PERIOD 	= 0xBE,   --  .
  VK_OEM_2 	      = 0xBF,   --  /
  VK_OEM_3 	      = 0xC0,   --  `
  VK_OEM_4 	      = 0xDB,   --  [
  VK_OEM_5 	      = 0xDC,   --  \
  VK_OEM_6 	      = 0xDD,   --  ]
  VK_OEM_7 	      = 0xDE,   --  '
  VK_OEM_8 	      = 0xDF,   --  (unknown)
  VK_ICO_F17 	    = 0xE0,   --  F17 on Olivetti extended keyboard (internal use only)
  VK_ICO_F18 	    = 0xE1,   --  F18 on Olivetti extended keyboard (internal use only)
  VK_OEM_102 	    = 0xE2,   --  < or | on IBM-compatible 102 enhanced non-U.S. keyboard
  VK_ICO_HELP 	  = 0xE3,   --  Help on Olivetti extended keyboard (internal use only)
  VK_ICO_00 	    = 0xE4,   --  00 on Olivetti extended keyboard (internal use only)
  VK_ICO_CLEAR 	  = 0xE6,   --  Clear on Olivette extended keyboard (internal use only)
  VK_OEM_RESET 	  = 0xE9,   --  Reset (Nokia keyboards only)
  VK_OEM_JUMP 	  = 0xEA,   --  Jump (Nokia keyboards only)
  VK_OEM_PA1 	    = 0xEB,   --  PA1 (Nokia keyboards only)
  VK_OEM_PA2 	    = 0xEC,   --  PA2 (Nokia keyboards only)
  VK_OEM_PA3 	    = 0xED,   --  PA3 (Nokia keyboards only)
  VK_OEM_WSCTRL 	= 0xEE,   --  WSCTRL (Nokia keyboards only)
  VK_OEM_CUSEL 	  = 0xEF,   --  CUSEL (Nokia keyboards only)
  VK_OEM_ATTN 	  = 0xF0,   --  ATTN (Nokia keyboards only)
  VK_OEM_FINNISH 	= 0xF1,   --  FINNISH (Nokia keyboards only)
  VK_OEM_COPY 	  = 0xF2,   --  COPY (Nokia keyboards only)
  VK_OEM_AUTO 	  = 0xF3,   --  AUTO (Nokia keyboards only)
  VK_OEM_ENLW 	  = 0xF4,   --  ENLW (Nokia keyboards only)
  VK_OEM_BACKTAB 	= 0xF5,   --  BACKTAB (Nokia keyboards only)
  VK_ATTN 	      = 0xF6,   --  ATTN
  VK_CRSEL 	      = 0xF7,   --  CRSEL
  VK_EXSEL 	      = 0xF8,   --  EXSEL
  VK_EREOF 	      = 0xF9,   --  EREOF
  VK_PLAY 	      = 0xFA,   --  PLAY
  VK_ZOOM 	      = 0xFB,   --  ZOOM
  VK_NONAME 	    = 0xFC,   --  NONAME
  VK_PA1 	        = 0xFD,   --  PA1
  VK_OEM_CLEAR 	  = 0xFE,   --  CLEAR
}

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
