--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  Coordinate conversion utilities for MIDI Razor Edits.

  Pure functions that convert between coordinate systems:
  - Screen (pixels, window-relative)
  - MIDI (PPQ ticks, pitch values 0-127)
  - PitchBend (14-bit values 0-16383, semitone offsets)
  - Time (project seconds)

  All functions take explicit parameters to avoid hidden dependencies.
]]

local Coords = {}

local r = reaper

-- constants
local PB_CENTER = 8192
local PB_MAX = 16383

Coords.PB_CENTER = PB_CENTER
Coords.PB_MAX = PB_MAX

-----------------------------------------------------------------------------
-- Platform helpers
-----------------------------------------------------------------------------

local is_macos = r.GetOS():find('OSX') ~= nil or r.GetOS():find('macOS') ~= nil

-- convert screen Y from GetMousePosition() to native coords
-- macOS screen Y is flipped (origin at bottom)
function Coords.screenYToNative(y, windowRect)
  if is_macos and windowRect then
    local _, wy1, _, wy2 = r.JS_Window_GetViewportFromRect(
      windowRect.x1, windowRect.y1, windowRect.x2, windowRect.y2, false)
    local screenHeight = math.abs(wy2 - wy1)
    return screenHeight - y
  end
  return y
end

-- convert native Y to screen Y (inverse of above)
function Coords.nativeYToScreen(y, windowRect)
  -- same operation, it's symmetric
  return Coords.screenYToNative(y, windowRect)
end

-----------------------------------------------------------------------------
-- Pitch Bend value conversions
-----------------------------------------------------------------------------

-- convert 14-bit PB value (0-16383) to semitones
-- params: pbValue, maxBendUp, maxBendDown (semitones)
function Coords.pbToSemitones(pbValue, maxBendUp, maxBendDown)
  maxBendDown = maxBendDown or maxBendUp
  local offset = pbValue - PB_CENTER
  if offset >= 0 then
    return (offset / PB_CENTER) * maxBendUp
  else
    return (offset / PB_CENTER) * maxBendDown
  end
end

-- convert semitones to 14-bit PB value
function Coords.semitonesToPb(semitones, maxBendUp, maxBendDown)
  maxBendDown = maxBendDown or maxBendUp
  local pbValue
  if semitones >= 0 then
    pbValue = PB_CENTER + (semitones / maxBendUp) * PB_CENTER
  else
    pbValue = PB_CENTER + (semitones / maxBendDown) * PB_CENTER
  end
  return math.floor(math.max(0, math.min(PB_MAX, pbValue)) + 0.5)
end

-- encode 14-bit PB value to MIDI bytes (msg2=LSB, msg3=MSB)
function Coords.pbToBytes(pbValue)
  local msg2 = pbValue & 0x7F           -- LSB (lower 7 bits)
  local msg3 = (pbValue >> 7) & 0x7F    -- MSB (upper 7 bits)
  return msg2, msg3
end

-- decode MIDI bytes to 14-bit PB value
function Coords.bytesToPb(msg2, msg3)
  return (msg3 << 7) | msg2
end

-----------------------------------------------------------------------------
-- Semitone snapping
-----------------------------------------------------------------------------

-- snap to nearest integer semitone (equal temperament)
function Coords.snapToSemitone(semitones)
  return math.floor(semitones + 0.5)
end

-- snap to nearest scale degree (microtonal)
-- scale: table with .pitches array of {numerator, denominator} pairs
function Coords.snapToMicrotonal(semitones, scale)
  if not scale then return Coords.snapToSemitone(semitones) end

  -- build snap points from scale pitches
  local snapPoints = { 0 }  -- start with unison
  for _, pitch in ipairs(scale.pitches) do
    local n, d = pitch[1], pitch[2]
    local semitoneOffset
    if d == 1200 then
      -- cents: n is cents, convert to semitones
      semitoneOffset = n / 100
    else
      -- ratio: convert to semitones
      local ratio = n / d
      semitoneOffset = 12 * math.log(ratio) / math.log(2)
    end
    table.insert(snapPoints, semitoneOffset)
  end

  -- find octave and position within octave
  local octaveSize = snapPoints[#snapPoints] or 12
  local octave = math.floor(semitones / octaveSize)
  local withinOctave = semitones - (octave * octaveSize)
  if withinOctave < 0 then
    withinOctave = withinOctave + octaveSize
    octave = octave - 1
  end

  -- find closest snap point
  local closest, minDist = 0, math.huge
  for _, pt in ipairs(snapPoints) do
    local dist = math.abs(withinOctave - pt)
    if dist < minDist then
      minDist = dist
      closest = pt
    end
  end

  return (octave * octaveSize) + closest
end

-----------------------------------------------------------------------------
-- Screen <-> MIDI coordinate conversions
-----------------------------------------------------------------------------

-- convert screen Y to pitch (fractional)
-- params: screenY, laneTopPixel, laneTopValue, pixelsPerPitch
function Coords.screenYToPitch(screenY, laneTopPixel, laneTopValue, pixelsPerPitch)
  if not (laneTopPixel and laneTopValue and pixelsPerPitch) then return 60 end
  return laneTopValue - ((screenY - laneTopPixel) / pixelsPerPitch) + 0.5
end

-- convert pitch to screen Y (center of note row)
function Coords.pitchToScreenY(pitch, laneTopPixel, laneTopValue, pixelsPerPitch)
  if not (laneTopPixel and laneTopValue and pixelsPerPitch) then return nil end
  local noteY = laneTopPixel + ((laneTopValue - pitch) * pixelsPerPitch)
  return noteY + (pixelsPerPitch / 2)  -- center of note row
end

-- convert screen Y to semitone offset from reference pitch
function Coords.screenYToSemitones(screenY, refPitch, laneTopPixel, laneTopValue, pixelsPerPitch)
  if not (laneTopPixel and laneTopValue and pixelsPerPitch) then return 0 end
  local noteY = laneTopPixel + ((laneTopValue - refPitch) * pixelsPerPitch)
  local noteCenterY = noteY + (pixelsPerPitch / 2)
  return (noteCenterY - screenY) / pixelsPerPitch
end

-- convert semitone offset to screen Y
function Coords.semitonesToScreenY(semitones, refPitch, laneTopPixel, laneTopValue, pixelsPerPitch)
  local noteCenterY = Coords.pitchToScreenY(refPitch, laneTopPixel, laneTopValue, pixelsPerPitch)
  if not noteCenterY then return nil end
  return noteCenterY - (semitones * pixelsPerPitch)
end

-----------------------------------------------------------------------------
-- Time <-> Screen conversions
-----------------------------------------------------------------------------

-- convert PPQ position to screen X (time-based mode)
function Coords.ppqToScreenX_Time(ppqpos, take, windowX1, leftmostTime, pixelsPerSecond)
  if not (take and windowX1 and leftmostTime and pixelsPerSecond) then return nil end
  local projTime = r.MIDI_GetProjTimeFromPPQPos(take, ppqpos)
  return windowX1 + ((projTime - leftmostTime) * pixelsPerSecond)
end

-- convert PPQ position to screen X (tick-based mode)
function Coords.ppqToScreenX_Tick(ppqpos, windowX1, leftmostTick, pixelsPerTick)
  if not (windowX1 and leftmostTick and pixelsPerTick) then return nil end
  return windowX1 + ((ppqpos - leftmostTick) * pixelsPerTick)
end

-- convert screen X to PPQ (time-based mode)
function Coords.screenXToPPQ_Time(screenX, take, windowX1, leftmostTime, pixelsPerSecond)
  if not (take and windowX1 and leftmostTime and pixelsPerSecond) then return nil end
  local projTime = leftmostTime + ((screenX - windowX1) / pixelsPerSecond)
  return r.MIDI_GetPPQPosFromProjTime(take, projTime)
end

-- convert screen X to PPQ (tick-based mode)
function Coords.screenXToPPQ_Tick(screenX, windowX1, leftmostTick, pixelsPerTick)
  if not (windowX1 and leftmostTick and pixelsPerTick) then return nil end
  return leftmostTick + ((screenX - windowX1) / pixelsPerTick)
end

-----------------------------------------------------------------------------
-- LICE bitmap coordinate helpers
-----------------------------------------------------------------------------

-- convert screen rect to LICE bitmap coords
function Coords.rectToLice(rect, screenRectX1, screenRectY1)
  return math.floor((rect.x1 - screenRectX1) + 0.5),
         math.floor((rect.y1 - screenRectY1) + 0.5),
         math.floor((rect.x2 - screenRectX1) + 0.5),
         math.floor((rect.y2 - screenRectY1) + 0.5)
end

-- convert screen point to LICE bitmap coords
function Coords.pointToLice(x, y, screenRectX1, screenRectY1)
  return math.floor((x - screenRectX1) + 0.5),
         math.floor((y - screenRectY1) + 0.5)
end

return Coords
