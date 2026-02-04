--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Classes = {}

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

function MouseMods:flags()
  local modFlags = 0
  if self.shiftFlag then modFlags = modFlags | 1 end
  if self.ctrlFlag then modFlags = modFlags | 2 end
  if self.altFlag then modFlags = modFlags | 4 end
  if self.superFlag then modFlags = modFlags | 8 end
  return modFlags
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

function Point:equals(point)
  return point and self.x == point.x and self.y == point.y
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

function Rect:containsPoint(pt)
  return pt.x >= self.x1 and pt.x <= self.x2
     and pt.y >= self.y1 and pt.y <= self.y2
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

function TimeValueExtents:compare(other)
  return equalIsh(self.ticks.min, other.ticks.min)
     and equalIsh(self.ticks.max, other.ticks.max)
     and equalIsh(self.vals.min, other.vals.min)
     and equalIsh(self.vals.max, other.vals.max)
end

-- check if self fully contains other
function TimeValueExtents:contains(other)
  return self.ticks.min <= other.ticks.min and
         self.ticks.max >= other.ticks.max and
         self.vals.min <= other.vals.min and
         self.vals.max >= other.vals.max
end

-- check if self intersects with other
function TimeValueExtents:intersects(other)
  local ticks_overlap = not (self.ticks.max < other.ticks.min or
                             other.ticks.max < self.ticks.min)
  local vals_overlap = not (self.vals.max < other.vals.min or
                            other.vals.max < self.vals.min or
                            self.vals.min > other.vals.max or
                            other.vals.min > self.vals.max)
  return ticks_overlap and vals_overlap
end

-- calculate 2D area (ticks × vals)
function TimeValueExtents:calcArea()
  return (self.ticks.max - self.ticks.min) *
         (self.vals.max - self.vals.min)
end

----------------------------------------------------

local Area = {}
Area.__index = Area

function Area.newFromRect(tab, completionFn, cfArg)
  local self = setmetatable({}, Area)

  self.viewRect = tab.viewRect
  self.logicalRect = tab.logicalRect
  self.origin = tab.origin
  self.ccLane = tab.ccLane
  self.ccType = tab.ccType
  self.active = tab.active or false
  self.fullLane = tab.fullLane or false
  self.onClipboard = tab.onClipbooard or false

  if completionFn then
    completionFn(self, cfArg)
  end

  return self
end

function Area.new(tab, completionFn, cfArg)
  local self = setmetatable({}, Area)

  self.ccLane = tab.ccLane
  self.ccType = tab.ccType
  self.timeValue = TimeValueExtents.deserialize(tab.timeValue)
  self.active = false
  self.fullLane = tab.fullLane or false
  self.onClipboard = tab.onClipbooard or false

  if completionFn then
    completionFn(self, cfArg)
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
    timeValue = self.timeValue:serialize(),
  }
end

function Area:clone()
  return self:serialize()
end

----------------------------------------------------

Classes.Area = Area
Classes.MouseMods = MouseMods
Classes.Point = Point
Classes.Rect = Rect
Classes.Extent = Extent
Classes.TimeValueExtents = TimeValueExtents

return Classes
