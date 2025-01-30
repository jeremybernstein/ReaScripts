--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

-- TODOs
--   x insert control points when moving CC areas [in progress]
--   x multiple widget support {post-public}
--   x move/copy area to next lane {post-public}
--   x all editable items {post-public}
--   x anything to be done about the repeated erasure cost of the unstretched rect? preErasedMUState f.e.? {post-public}
--   x rewrite to use LICE coords (although it's not a big deal, isn't causing performance issues)
--   x note selection edge cases (preceding note collides with a moved region note)

local r = reaper
local Lib = {}

local GLOBAL_PREF_SLOP = 10 -- ticks

local DEBUG_UNDO = false
local sectionID, commandID
local hasSWS = true

local STARTUP_SELECTED_NOTES = 1

local startupOptions

local PROFILING = false
local profiler
if PROFILING then
  profiler = dofile(r.GetResourcePath() ..
    '/Scripts/ReaTeam Scripts/Development/cfillion_Lua profiler.lua')
  r.defer = profiler.defer
end

if not r.APIExists('JS_Window_FindChildByID') then
  r.ShowConsoleMsg('MIDI Razor Edits requires the JS_ReaScriptAPI extension (install from ReaPack)\n')
  return
end

if not r.APIExists('CF_SendActionShortcut') then
  r.ShowConsoleMsg('MIDI Razor Edits appreciates the presence of SWS 2.14+ (please install or update via ReaPack))\n')
  hasSWS = false
end

local mu
local DEBUG_MU = false
if DEBUG_MU then
  package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
  mu = require 'MIDIUtils'
else
  package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. '/?.lua;' -- GET DIRECTORY FOR REQUIRE
  mu = require 'MIDIUtils'
end

mu.ENFORCE_ARGS = false -- turn off for release
mu.USE_XPCALL = false
mu.CLAMP_MIDI_BYTES = true
mu.CORRECT_EXTENTS = true
mu.COMMIT_CANSKIP = true
mu.CORRECT_OVERLAPS = false -- maybe need to turn this on only at the very, very end

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. '/?.lua;' -- GET DIRECTORY FOR REQUIRE
local classes = require 'MIDIRazorEdits_Classes'
local lice = require 'MIDIRazorEdits_LICE'
local glob = require 'MIDIRazorEdits_Global'
local keys = require 'MIDIRazorEdits_Keys'

local Area = classes.Area
local Point = classes.Point
local Rect = classes.Rect
local Extent = classes.Extent
local TimeValueExtents = classes.TimeValueExtents
local MouseMods = classes.MouseMods

local scriptID = glob.scriptID

local _P = mu.post
local _T = mu.tprint

_G._P = _P -- for debugging
_G._T = _T
_G.tableCopy = mu.tableCopy

local areas = glob.areas
local meState = glob.meState
local meLanes = glob.meLanes

-- global resizing type
local RS_UNCLICKED = -1
local RS_NEWAREA = 0
local RS_LEFT = 1
local RS_TOP = 2
local RS_RIGHT = 3
local RS_BOTTOM = 4
local RS_MOVEAREA = 5

local resizing = RS_UNCLICKED

-- local OP_NONE = 0 -- use nil for area.operation
local OP_DELETE           = 1
local OP_DELETE_TRIM      = 2
local OP_DUPLICATE        = 3
local OP_INVERT           = 4
local OP_RETROGRADE       = 5
local OP_RETROGRADE_VALS  = 6
local OP_COPY             = 7
local OP_SELECT           = 8
local OP_UNSELECT         = 9

local OP_STRETCH          = 20 -- behaves a little differently
local OP_STRETCH_DELETE   = 21 -- behaves a little differently

-- misc
local muState
local justLoaded = true

local hottestMods = MouseMods.new()
local currentMods = MouseMods.new()

local lastPoint, lastPointQuantized, hasMoved
local wasDragged = false
local wantsQuit = false
local touchedMIDI = false
local noRestore = false -- if we didn't touch the MIDI or change it significantly, we can avoid a restore

local dragDirection
local areaTickExtent

local analyzeCheckTime = nil
local editorCheckTime = nil

------------------------------------------------
------------------------------------------------

local function pointIsInRect(p, rect, slop)
  if not p or not rect then return false end
  if not slop then slop = lice.EDGE_SLOP end
  return  p.x >= rect.x1 - slop and p.x <= rect.x2 + slop
      and p.y >= rect.y1 - slop and p.y <= rect.y2 + slop
end

local function nearValue(val, val2, slop)
  if not slop then slop = lice.EDGE_SLOP * 2 end
  return val >= val2 - slop and val <= val2 + slop
end

local function equalIsh(a, b, epsilon)
  epsilon = epsilon or 1e-9 -- Default tolerance (1e-9, or very small difference)
  return math.abs(a - b) <= epsilon
end

local function clipInt(val, min, max)
  if not val then return nil end

  min = min or 0
  max = max or 127

  val = val < min and min or val > max and max or val
  return math.floor(val)
end

------------------------------------------------
------------------------------------------------

local function getMod(someMods, mod)
  someMods = someMods or currentMods
  if mod & 1 ~= 0 then return someMods:shift(), 'shift', 'shiftFlag'
  elseif mod & 2 ~= 0 then return someMods:ctrl(), 'ctrl', 'ctrlFlag'
  elseif mod & 4 ~= 0 then return someMods:alt(), 'alt', 'altFlag'
  elseif mod & 8 ~= 0 then return someMods:super(), 'super', 'superFlag'
  end
  return false, nil, nil
end

local function snapMod(someMods)
  return getMod(someMods, lice.modMappings()[keys.MODTYPE_SNAP].modKey)
end

local function copyMod(someMods)
  return getMod(someMods, lice.modMappings()[keys.MODTYPE_MOVE_COPY].modKey)
end

local function overlapMod(someMods)
  return getMod(someMods, lice.modMappings()[keys.MODTYPE_MOVE_OVERLAP].modKey)
end

local function singleMod(someMods)
  return getMod(someMods, lice.modMappings()[keys.MODTYPE_MOVE_SINGLE].modKey)
end

local function fullLaneMod(someMods)
  return getMod(someMods, lice.modMappings()[keys.MODTYPE_NEW_FULLLANE].modKey)
end

local function preserveMod(someMods)
  return getMod(someMods, lice.modMappings()[keys.MODTYPE_NEW_PRESERVE].modKey)
end

local function stretchMod(someMods)
  return getMod(someMods, lice.modMappings()[keys.MODTYPE_STRETCH].modKey)
end

------------------------------------------------
------------------------------------------------

-- the fruits of 2 hours of hard labor with chatGPT 4 -- in the end, I had to fix it for the AI
local function calculateVisibleRangeWithMargin(scroll, zoom, marginSize, viewHeight, minValue, maxValue)
  -- Default values for minValue and maxValue
  minValue = minValue or 0
  maxValue = maxValue or 127

  -- Logical value range
  local valueRange = maxValue - minValue

  -- Logical height for the value range
  local logicalValueHeight = (viewHeight - 2 * marginSize) * zoom

  -- Total logical height (values + fixed margins)
  local totalLogicalHeight = logicalValueHeight + 2 * marginSize

  -- Center of the visible area in the total logical height
  local center = scroll * (totalLogicalHeight - viewHeight) + viewHeight / 2

  -- Visible range in the total logical height
  local visibleStart = center - viewHeight / 2
  local visibleEnd = center + viewHeight / 2

  -- Margins (renamed for inverted coordinates)
  local bottomMarginStart = totalLogicalHeight - marginSize
  local bottomMarginEnd = totalLogicalHeight
  local topMarginStart = 0
  local topMarginEnd = marginSize

  -- Calculate visible portions of the margins
  local marginBottomVisible = math.max(0, math.min(visibleEnd, bottomMarginEnd) - math.max(visibleStart, bottomMarginStart))
  local marginTopVisible = math.max(0, math.min(visibleEnd, topMarginEnd) - math.max(visibleStart, topMarginStart))

  -- Clamp the visible value range within the logical value height
  local visibleValueStart = math.max(visibleStart - marginSize, 0)
  local visibleValueEnd = math.min(visibleEnd - marginSize, logicalValueHeight)

  -- Convert logical value range to actual values (inverted range)
  local visibleMin = maxValue - (visibleValueEnd / logicalValueHeight) * valueRange
  local visibleMax = maxValue - (visibleValueStart / logicalValueHeight) * valueRange

  return visibleMin, visibleMax, marginTopVisible, marginBottomVisible
end

local function getEditorAndSnapWish()
  local wantsSnap = r.MIDIEditor_GetSetting_int(glob.liceData.editor, 'snap_enabled') == 1
  if snapMod() then wantsSnap = not wantsSnap end

  return wantsSnap
end

local function quantizeTimeValueTimeExtent(x1, x2)
  local wantsSnap = getEditorAndSnapWish()
  if not wantsSnap then return x1, x2 end

  local activeTake = glob.liceData.editorTake
  local gridUnit = mu.MIDI_GetPPQ(activeTake) * glob.currentGrid
  local newx1, newx2 = x1, x2
  local som, tickInMeasure

  if x1 then
    som = r.MIDI_GetPPQPos_StartOfMeasure(activeTake, x1)
    tickInMeasure = x1 - som -- get the position from the start of the measure
    newx1 = som + (gridUnit * math.floor((tickInMeasure / gridUnit) + 0.5))
    if newx1 < meState.leftmostTick then return x1, x2 end
  end

  if x2 then
    som = r.MIDI_GetPPQPos_StartOfMeasure(activeTake, x2)
    tickInMeasure = x2 - som -- get the position from the start of the measure
    newx2 = som + (gridUnit * math.floor((tickInMeasure / gridUnit) + 0.5))
    if newx2 < meState.leftmostTick then return x1, x2 end
  end

  return newx1, newx2
end

local function getTimeOffset()
  return 0 -- mu.MIDI_GetTimeOffset()
end

local function updateTimeValueLeft(area)
  if meState.timeBase == 'time' then
    local leftmostTime = meState.leftmostTime + ((area.logicalRect.x1 - glob.windowRect.x1) / meState.pixelsPerSecond)
    return r.MIDI_GetPPQPosFromProjTime(glob.liceData.editorTake, leftmostTime - getTimeOffset()), leftmostTime
  else
    return meState.leftmostTick + math.floor(((area.logicalRect.x1 - glob.windowRect.x1) / meState.pixelsPerTick) + 0.5)
  end
end

local function updateTimeValueRight(area, leftmost)
  if meState.timeBase == 'time' then
    leftmost = leftmost or area.timeValue.time.min
    local rightmostTime = equalIsh(area.logicalRect.x2, area.logicalRect.x1) and leftmost or (leftmost + (area.logicalRect:width() / meState.pixelsPerSecond))
    return r.MIDI_GetPPQPosFromProjTime(glob.liceData.editorTake, rightmostTime - getTimeOffset()), rightmostTime
  else
    leftmost = leftmost or area.timeValue.ticks.min
    return equalIsh(area.logicalRect.x2, area.logicalRect.x1) and leftmost or (leftmost + math.floor((area.logicalRect:width() / meState.pixelsPerTick) + 0.5))
  end
end

local function updateTimeValueTop(area)
  local topValue = area.ccLane and meLanes[area.ccLane].topValue or meState.topPitch
  local topPixel = area.ccLane and meLanes[area.ccLane].topPixel or glob.windowRect.y1
  local divisor = area.ccLane and meLanes[area.ccLane].pixelsPerValue or meState.pixelsPerPitch

  return topValue - math.floor(((area.logicalRect.y1 - topPixel) / divisor) + 0.5)
end

local function updateTimeValueBottom(area)
  local divisor = area.ccLane and meLanes[area.ccLane].pixelsPerValue or meState.pixelsPerPitch
  return equalIsh(area.logicalRect.y2, area.logicalRect.y1) and area.timeValue.vals.max or (area.timeValue.vals.max - math.floor((area.logicalRect:height() / divisor) + 0.5) + 1)
end

local function makeTimeValueExtentsForArea(area, noQuantize)
  local leftmostTick
  local rightmostTick
  local leftmostTime
  local rightmostTime

  -- TODO review math.floor usage here
  if meState.timeBase == 'time' then
    leftmostTick, leftmostTime = updateTimeValueLeft(area)
    rightmostTick, rightmostTime = updateTimeValueRight(area, leftmostTime)
  else
    leftmostTick = updateTimeValueLeft(area)
    rightmostTick = updateTimeValueRight(area, leftmostTick)
  end

  if not noQuantize then
    leftmostTick, rightmostTick = quantizeTimeValueTimeExtent(leftmostTick, rightmostTick)
  end

  local topValue = area.ccLane and meLanes[area.ccLane].topValue or meState.topPitch
  local bottomValue = area.ccLane and meLanes[area.ccLane].bottomValue or meState.bottomPitch
  local topPixel = area.ccLane and meLanes[area.ccLane].topPixel or glob.windowRect.y1
  local divisor = area.ccLane and meLanes[area.ccLane].pixelsPerValue or meState.pixelsPerPitch

  local valMax = area.fullLane and topValue or (topValue - math.floor(((area.logicalRect.y1 - topPixel) / divisor) + 0.5))
  local valMin = area.fullLane and bottomValue or (equalIsh(area.logicalRect.y2, area.logicalRect.y1) and valMax or (valMax - math.floor((area.logicalRect:height() / divisor) + 0.5) + 1))
  area.timeValue = TimeValueExtents.new(leftmostTick, rightmostTick, valMin, valMax, leftmostTime, rightmostTime)
end

local function adjustFullLane(area, testPix)
  local ccLane = area.ccLane or -1
  if testPix then
    if area.logicalRect.y1 <= meLanes[ccLane].topPixel and area.logicalRect.y2 >= meLanes[ccLane].bottomPixel then
      area.fullLane = true
    else
      area.fullLane = false
    end
  else
    if area.timeValue.vals.min <= meLanes[ccLane].bottomValue and area.timeValue.vals.max >= meLanes[ccLane].topValue then
      area.fullLane = true
    else
      area.fullLane = false
    end
  end
end

local updateAreaFromTimeValue

local function updateTimeValueExtentsForArea(area, noCheck, force)
  local updated = true
  local oldTicksMin, oldTicksMax = area.timeValue.ticks.min, area.timeValue.ticks.max

  if not noCheck then adjustFullLane(area, true) end

  if resizing == RS_NEWAREA then
    makeTimeValueExtentsForArea(area) -- do quantize
  elseif resizing == RS_LEFT then
    area.timeValue.ticks.min = updateTimeValueLeft(area)
    area.timeValue.ticks.min = quantizeTimeValueTimeExtent(area.timeValue.ticks.min)
    if area.fullLane then
      area.timeValue.vals.min = 0
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range
    end
  elseif resizing == RS_RIGHT then
    area.timeValue.ticks.max = updateTimeValueRight(area)
    _, area.timeValue.ticks.max = quantizeTimeValueTimeExtent(nil, area.timeValue.ticks.max)
    if area.fullLane then
      area.timeValue.vals.min = 0
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range
    end
  elseif resizing == RS_TOP then
    if area.fullLane then
      area.timeValue.vals.min = 0
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range
    else
      area.timeValue.vals.max = updateTimeValueTop(area)
    end
  elseif resizing == RS_BOTTOM then
    if area.fullLane then
      area.timeValue.vals.min = 0
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range
    else
      area.timeValue.vals.min = updateTimeValueBottom(area)
    end
  elseif resizing == RS_MOVEAREA and not force then
    local oldmin = area.timeValue.ticks.min
    local oldtop = area.timeValue.vals.max
    area.timeValue.ticks.min = updateTimeValueLeft(area)
    if area.fullLane then
      area.timeValue.vals.min = 0
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range
    else
      area.timeValue.vals.max = updateTimeValueTop(area)
    end
    local deltaX = area.timeValue.ticks.min - oldmin
    local deltaY = area.timeValue.vals.max - oldtop
    area.timeValue.ticks.max = area.timeValue.ticks.max + deltaX
    area.timeValue.vals.min = area.timeValue.vals.min + deltaY
  elseif force then
    makeTimeValueExtentsForArea(area, true)
  else
    updated = false
  end
  if updated then
    if area.active then
      local isMovingTime = resizing == RS_LEFT or resizing == RS_RIGHT or resizing == RS_MOVEAREA
      if isMovingTime then
        local min, max = quantizeTimeValueTimeExtent(area.timeValue.ticks.min, area.timeValue.ticks.max)
        if resizing == RS_LEFT then
          area.timeValue.ticks.min = min
        elseif resizing == RS_RIGHT then
          area.timeValue.ticks.max = max
        elseif resizing == RS_MOVEAREA then
          local delta = min - area.timeValue.ticks.min
          area.timeValue.ticks.min = min
          area.timeValue.ticks.max = area.timeValue.ticks.max + delta -- ensure that the area width doesn't change
        end
      end

      if isMovingTime then
        if meState.timeBase == 'time' then
          if oldTicksMin ~= area.timeValue.ticks.min then
            local oldTime = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.editorTake, oldTicksMin)
            local newTime = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.editorTake, area.timeValue.ticks.min)
            local timeDelta = newTime - oldTime
            area.timeValue.time.min = area.timeValue.time.min + timeDelta
          end
          if oldTicksMax ~= area.timeValue.ticks.max then
            local oldTime = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.editorTake, oldTicksMax)
            local newTime = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.editorTake, area.timeValue.ticks.max)
            local timeDelta = newTime - oldTime
            area.timeValue.time.max = area.timeValue.time.max + timeDelta
          end
        end
        updateAreaFromTimeValue(area)
      end
    end
    area.modified = true
  end
end

local function viewIntersectionRect(area)
  local idx = area.ccLane and area.ccLane or -1
  return Rect.new(math.max(area.logicalRect.x1, glob.windowRect.x1),
                  math.max(area.logicalRect.y1, meLanes[idx].topPixel),
                  math.min(area.logicalRect.x2, glob.windowRect.x2),
                  math.min(area.logicalRect.y2, meLanes[idx].bottomPixel))
end

local function updateTimeValueTime(area)
  if meState.timeBase == 'time' then
    if not area.timeValue.time then area.timeValue.time = Extent.new() end
    area.timeValue.time.min = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.editorTake, area.timeValue.ticks.min)
    area.timeValue.time.max = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.editorTake, area.timeValue.ticks.max)
  end
end

updateAreaFromTimeValue = function(area, noCheck)
  if not noCheck then adjustFullLane(area) end

  if area.ccLane and (not meLanes[area.ccLane] or meLanes[area.ccLane].type ~= area.ccType) then
    for ccLane = #meLanes, 0, -1 do
      if meLanes[ccLane].type == area.ccType then
        area.ccLane = ccLane -- should check for a collision and delete if it doesn't fit
        break
      end
    end
  end
  if area.timeValue then
    local x1, y1, x2, y2
    if meState.timeBase == 'time' then
      if not area.timeValue.time then
        updateTimeValueTime(area)
      end
      x1 = math.floor((glob.windowRect.x1 + ((area.timeValue.time.min - meState.leftmostTime) * meState.pixelsPerSecond)) + 0.5)
      x2 = math.floor((glob.windowRect.x1 + ((area.timeValue.time.max - meState.leftmostTime) * meState.pixelsPerSecond)) + 0.5)
    else
      x1 = math.floor((glob.windowRect.x1 + ((area.timeValue.ticks.min - meState.leftmostTick) * meState.pixelsPerTick)) + 0.5)
      x2 = math.floor((glob.windowRect.x1 + ((area.timeValue.ticks.max - meState.leftmostTick) * meState.pixelsPerTick)) + 0.5)
    end
    if area.fullLane then
      if area.ccLane then
        y1 = math.floor((meLanes[area.ccLane].topPixel - ((meLanes[area.ccLane].range - meLanes[area.ccLane].topValue) * meLanes[area.ccLane].pixelsPerValue)) + 0.5) -- hack RANGE
        y2 = math.floor((meLanes[area.ccLane].bottomPixel + ((meLanes[area.ccLane].bottomValue) * meLanes[area.ccLane].pixelsPerValue)) + 0.5)
      else
        y1 = math.floor(glob.windowRect.y1 - ((meLanes[-1].range - meState.topPitch) * meState.pixelsPerPitch) + 0.5)
        y2 = math.floor((meLanes[-1].bottomPixel + (meState.bottomPitch * meState.pixelsPerPitch)) + 0.5)
      end
    else
      local topPixel = area.ccLane and meLanes[area.ccLane].topPixel or glob.windowRect.y1
      local topValue = area.ccLane and meLanes[area.ccLane].topValue or meState.topPitch
      local multi = area.ccLane and meLanes[area.ccLane].pixelsPerValue or meState.pixelsPerPitch
      y1 = math.floor((topPixel + ((topValue - area.timeValue.vals.max) * multi)) + 0.5)
      y2 = math.min(math.floor((topPixel + ((topValue - area.timeValue.vals.min + 1) * multi)) + 0.5), meLanes[area.ccLane or -1].bottomPixel)
    end
    area.logicalRect = Rect.new(x1, y1, x2, y2)
    area.viewRect = viewIntersectionRect(area)
    area.modified = true
  end
end

local function makeFullLane(area)
  area.fullLane = true
  updateTimeValueExtentsForArea(area, true, true)
  updateAreaFromTimeValue(area, true)
end

local function updateAreasFromTimeValue()
  -- lagorama when following along, but nothing unusual
  if glob.meNeedsRecalc
  then
    for _, area in ipairs(areas) do
      updateAreaFromTimeValue(area)
    end
    glob.meNeedsRecalc = false
  end
end

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

local function resetWidgetMode()
  -- TODO really? 3 variables seems like overkill here. consolidate.
  glob.inWidgetMode = false
  glob.widgetInfo = nil
  glob.changeWidget = nil
end

local processNotesWithGeneration
local tInsertions
local tDeletions

local function getNoteSegments(ppqpos, endppqpos, pitch, onlyArea)
  -- First, find all areas that intersect with the pitch line
  local intersecting_areas = {}

  local function checkAreaIntersection(area)
    -- Check both unstretched and current positions
    local positions = {
      {
        bottom = area.timeValue.vals.min,
        top = area.timeValue.vals.max,
        left = area.timeValue.ticks.min,
        right = area.timeValue.ticks.max - 1
      }
    }
    if area.unstretchedTimeValue then
      table.insert(positions, 1, {
        bottom = area.unstretchedTimeValue.vals.min,
        top = area.unstretchedTimeValue.vals.max,
        left = area.unstretchedTimeValue.ticks.min,
        right = area.unstretchedTimeValue.ticks.max - 1
      })
    end

    for _, pos in ipairs(positions) do
      if pitch <= pos.top and pitch >= pos.bottom then
        -- Only include if it overlaps with our note bounds
        if pos.right >= ppqpos and pos.left <= endppqpos then
          table.insert(intersecting_areas, {
            left = math.max(pos.left, ppqpos),
            right = math.min(pos.right, endppqpos)
          })
        end
      end
    end
  end

  -- Check all areas
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

  -- Merge overlapping areas
  local merged_areas = {intersecting_areas[1]}
  for i = 2, #intersecting_areas do
    local current = intersecting_areas[i]
    local last = merged_areas[#merged_areas]

    if current.left <= last.right then
      -- Areas overlap, extend the last area if needed
      last.right = math.max(last.right, current.right)
    else
      -- No overlap, add as new area
      table.insert(merged_areas, current)
    end
  end

  -- Find valid segments between areas and within note bounds
  local valid_segments = {}

  -- Check segment before first area
  if merged_areas[1].left > ppqpos then
    local length = merged_areas[1].left - ppqpos
    if length >= GLOBAL_PREF_SLOP then
      table.insert(valid_segments, {ppqpos, merged_areas[1].left})
    end
  end

  -- Check segments between areas
  for i = 1, #merged_areas - 1 do
    local length = merged_areas[i + 1].left - merged_areas[i].right
    if length >= GLOBAL_PREF_SLOP then
      table.insert(valid_segments, {merged_areas[i].right, merged_areas[i + 1].left})
    end
  end

  -- Check segment after last area
  if merged_areas[#merged_areas].right < endppqpos then
    local length = endppqpos - merged_areas[#merged_areas].right
    if length >= GLOBAL_PREF_SLOP then
      table.insert(valid_segments, {merged_areas[#merged_areas].right, endppqpos})
    end
  end

  -- if merged_areas[#merged_areas].right < endppqpos then
  --   local length = endppqpos - (overlapMod() and ppqpos or merged_areas[#merged_areas].right)
  --   if length >= GLOBAL_PREF_SLOP then
  --     table.insert(valid_segments, {overlapMap() and ppqpos or merged_areas[#merged_areas].right, endppqpos})
  --   end
  -- end

  if #valid_segments > 0 then
    return valid_segments
  end
  return nil
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
------------------------------------------------

local function processNotes(activeTake, area, operation)
  local ratio = 1.
  local idx = -1
  local movingArea = operation == OP_STRETCH
        and resizing == RS_MOVEAREA
        and (not currentMods:all() or area.active)
  local duplicatingArea = movingArea and copyMod()
  local stretchingArea = operation == OP_STRETCH
        and stretchMod()
        and area.active
        and resizing > RS_UNCLICKED and resizing < RS_MOVEAREA
  local deltaTicks, deltaPitch

  local sourceEvents = area.sourceInfo.sourceEvents
  local usingUnstretched = area.sourceInfo.usingUnstretched

  if movingArea then
    deltaTicks = area.timeValue.ticks.min - area.unstretchedTimeValue.ticks.min
    deltaPitch = -(area.timeValue.vals.min - area.unstretchedTimeValue.vals.min)

    deltaTicks = math.floor(deltaTicks + 0.5)
    deltaPitch = math.floor(deltaPitch + 0.5)
  end

  if operation == OP_STRETCH and area.unstretched and (not singleMod() or area.active) then
    ratio = area.timeValue.ticks:size() / area.unstretchedTimeValue.ticks:size()
    usingUnstretched = true
    if ratio == 1 and resizing < RS_MOVEAREA then return end
  end

  local leftmostTick, rightmostTick, topPitch, bottomPitch
  local areaLeftmostTick = math.floor(area.timeValue.ticks.min + 0.5)
  local areaRightmostTick = math.floor(area.timeValue.ticks.max + 0.5)

  if usingUnstretched then
    leftmostTick = area.sourceInfo.leftmostTick
    rightmostTick = area.sourceInfo.rightmostTick
    topPitch = area.sourceInfo.topValue
    bottomPitch = area.sourceInfo.bottomValue
  else
    leftmostTick = areaLeftmostTick
    rightmostTick = areaRightmostTick
    topPitch = area.timeValue.vals.max
    bottomPitch = area.timeValue.vals.min
  end

  local skipiter = false
  local widgeting = false
  if glob.widgetInfo and area == glob.widgetInfo.area then
    if glob.widgetInfo.sourceEvents then
      skipiter = true
    end
    widgeting = true
  end

  local insert = false

  -- TODO: REFACTOR (can use same code, approximately, for CCs)
  -- potential second iteration, deal with deletions in the target area
  if operation == OP_DUPLICATE then
    local tmpArea = Area.new(area:serialize()) -- OP_DELETE_TRIM will use this area for the deletion itself (in addition to event selection)
    tmpArea.timeValue.ticks:shift(areaTickExtent:size())
    processNotesWithGeneration(activeTake, tmpArea, OP_DELETE_TRIM)
  elseif movingArea then
     if deltaTicks ~= 0 or deltaPitch ~= 0 then
      -- extra work to avoid deleting the target area, if it intersects with the source area
      local deletionExtents = getNonIntersectingAreas(area.timeValue, area.unstretchedTimeValue)
      local tmpArea = Area.new(area:serialize()) -- only used for event selection
      tmpArea.unstretched, tmpArea.unstretchedTimeValue = area.unstretched, area.unstretchedTimeValue
      if not glob.insertMode then
        for _, extent in ipairs(deletionExtents) do
          tmpArea.timeValue = extent
          processNotesWithGeneration(activeTake, tmpArea, OP_DELETE) -- target
        end
      end
      if not duplicatingArea then
        tmpArea.timeValue = area.unstretchedTimeValue
        processNotesWithGeneration(activeTake, tmpArea, OP_DELETE) -- source
      end
      insert = true
    else
      return -- not doing anything? don't do anything.
    end
  elseif stretchingArea and not (resizing == RS_TOP or resizing == RS_BOTTOM) then
    if deltaTicks ~= 0 or deltaPitch ~= 0 then
      local tmpArea = Area.new(area:serialize()) -- only used for event selection
      local cacheMods = currentMods
      currentMods = MouseMods.new() -- clear out for the operation
      tmpArea.unstretched, tmpArea.unstretchedTimeValue = area.unstretched, area.unstretchedTimeValue
      if not glob.insertMode then
        processNotesWithGeneration(activeTake, tmpArea, OP_STRETCH_DELETE) -- target
      end
      tmpArea.timeValue = area.unstretchedTimeValue
      processNotesWithGeneration(activeTake, tmpArea, OP_STRETCH_DELETE) -- source
      currentMods = cacheMods
      insert = true
    else
      return -- not doing anything? don't do anything.
    end
  end

  local process = true
  if operation == OP_COPY or operation == OP_SELECT or operation == OP_UNSELECT then
    process = false
  end

  if not skipiter then
  for sidx, event in ipairs(sourceEvents) do
    local selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel = event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.pitch, event.vel, event.relvel
    local newppqpos, newendppqpos, newpitch

    idx = event.idx

    local function trimOverlappingNotes()
      local canOperate = true

      if ppqpos + GLOBAL_PREF_SLOP < rightmostTick and endppqpos - GLOBAL_PREF_SLOP >= leftmostTick then
        if ppqpos < leftmostTick  then
          if not overlapMod() then
            classes.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = ppqpos, endppqpos = leftmostTick, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
          else
            canOperate = false
          end
        end
        if endppqpos > rightmostTick then
          if not overlapMod() then
            classes.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = rightmostTick, endppqpos = endppqpos, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
          end
        end
      end
      return canOperate
    end

    if endppqpos > leftmostTick and ppqpos < rightmostTick
      and pitch <= topPitch and pitch >= bottomPitch
    then
      if operation == OP_COPY or operation == OP_SELECT or operation == OP_UNSELECT then
        mu.MIDI_SetNote(activeTake, idx, not (operation == OP_UNSELECT) and true or false, nil, nil, nil, nil, nil)
        touchedMIDI = true
      elseif operation == OP_INVERT then
        local invertOrig = trimOverlappingNotes()
        if invertOrig then
          newppqpos = ppqpos >= leftmostTick and ppqpos or leftmostTick
          newendppqpos = (endppqpos <= rightmostTick or overlapMod()) and endppqpos or rightmostTick + 1
          newpitch = area.timeValue.vals.max - (pitch - area.timeValue.vals.min)
        end
      elseif operation == OP_RETROGRADE then
        local retroOrig = trimOverlappingNotes()
        if retroOrig then
          local firstppq = sourceEvents[1].ppqpos
          local lastendppq = sourceEvents[#sourceEvents].endppqpos
          if firstppq < leftmostTick then firstppq = leftmostTick end
          if lastendppq > rightmostTick then lastendppq = rightmostTick end

          local thisppqpos = ppqpos < leftmostTick and leftmostTick or ppqpos
          local thisendppqpos = endppqpos > rightmostTick and rightmostTick or endppqpos
          local delta = (firstppq - leftmostTick) - (rightmostTick - lastendppq)

          newppqpos = (rightmostTick - ((thisppqpos >= leftmostTick and thisppqpos or leftmostTick) - leftmostTick)) - (thisendppqpos - thisppqpos) + delta
          newendppqpos = newppqpos + (thisendppqpos - thisppqpos)
        end
      elseif operation == OP_RETROGRADE_VALS then
        local retroOrig = trimOverlappingNotes()
        if retroOrig then
          newppqpos = ppqpos >= leftmostTick and ppqpos or leftmostTick
          newendppqpos = (endppqpos <= rightmostTick or overlapMod()) and endppqpos or rightmostTick + 1
          newpitch = sourceEvents[#sourceEvents - (sidx - 1)].pitch
        end
      elseif operation == OP_DUPLICATE then
        classes.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = (ppqpos >= leftmostTick and ppqpos or leftmostTick) + areaTickExtent:size(),
                          endppqpos = (endppqpos <= rightmostTick and endppqpos or rightmostTick + 1) + areaTickExtent:size(), chan = chan, pitch = pitch, vel = vel, relvel = relvel })
      elseif operation == OP_DELETE or operation == OP_STRETCH_DELETE or operation == OP_DELETE_TRIM then
        local deleteOrig = true

        if operation == OP_DELETE_TRIM then
          deleteOrig = trimOverlappingNotes() -- this screws up most operations, but is necessary for OP_DUPLICATE
        end

        local segments = getNoteSegments(ppqpos, endppqpos, pitch, operation == OP_DELETE_TRIM and area or nil)
        if segments then
          for i, seg in ipairs(segments) do
            local newEvent = mu.tableCopy(event)
            newEvent.ppqpos = seg[1]
            newEvent.endppqpos = seg[2]
            newEvent.pitch = pitch
            newEvent.type = mu.NOTE_TYPE
            classes.addUnique(tInsertions, newEvent)
            deleteOrig = true
          end
        end
        if deleteOrig then
          classes.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = idx })
        end
      elseif not singleMod() or ppqpos >= leftmostTick then
        if stretchingArea then
          if resizing ~= RS_MOVEAREA
            and stretchMod()
          then
            if ppqpos >= leftmostTick and endppqpos <= rightmostTick then
              if resizing == RS_LEFT then
                newppqpos = areaLeftmostTick + ((ppqpos - leftmostTick) * ratio)
              elseif resizing == RS_RIGHT then
                newppqpos = areaLeftmostTick + ((ppqpos - areaLeftmostTick) * ratio)
              end
              if resizing == RS_LEFT or resizing == RS_RIGHT then
                newendppqpos = (newppqpos or ppqpos) + ((endppqpos - ppqpos) * ratio)
              end
            elseif ppqpos >= leftmostTick then
              if resizing == RS_LEFT then
                newppqpos = areaLeftmostTick + ((ppqpos - leftmostTick) * ratio)
                newendppqpos = areaRightmostTick
              elseif resizing == RS_RIGHT then
                newppqpos = areaLeftmostTick + ((ppqpos - areaLeftmostTick) * ratio)
                newendppqpos = areaRightmostTick
              end
            elseif endppqpos <= rightmostTick then
              if resizing == RS_LEFT then
                newendppqpos = areaRightmostTick - ((areaRightmostTick - endppqpos) * ratio)
                newppqpos = areaLeftmostTick
              elseif resizing == RS_RIGHT then
                newendppqpos = areaLeftmostTick + ((endppqpos - areaLeftmostTick) * ratio)
                newppqpos = areaLeftmostTick
              end
            else -- burning the candle at both ends
              if resizing == RS_LEFT then
                newendppqpos = areaLeftmostTick + ((rightmostTick - leftmostTick) * ratio)
                newppqpos = areaLeftmostTick
              elseif resizing == RS_RIGHT then
                newppqpos = areaRightmostTick - ((rightmostTick - leftmostTick) * ratio)
                newendppqpos = areaRightmostTick
              end
            end

            if newendppqpos and newendppqpos < (newppqpos or ppqpos) then
              classes.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = idx })
            end
          end
        end

        if movingArea or duplicatingArea then
          local handled = false
          if ppqpos < leftmostTick then
            if not duplicatingArea then
              local leftLeft = math.min(leftmostTick, areaLeftmostTick)
              newppqpos = ppqpos
              newendppqpos = endppqpos < leftLeft and endppqpos or leftLeft
              if ((ppqpos >= areaLeftmostTick and endppqpos < areaRightmostTick)
                  or (newppqpos >= areaLeftmostTick and newendppqpos < areaRightmostTick))
                and pitch >= area.timeValue.vals.min and pitch <= area.timeValue.vals.max
              then
                newppqpos = nil
                newendppqpos = nil
                newpitch = nil
                -- _P('i love you')
              else
                -- _P('i want to love you', ppqpos, endppqpos, areaLeftmostTick, areaRightmostTick, newppqpos, newendppqpos)
              end
            end
            local insEnd = endppqpos + deltaTicks
            if insEnd >= areaRightmostTick then insEnd = areaRightmostTick - 1 end
            classes.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = areaLeftmostTick, endppqpos = insEnd, chan = chan, pitch = pitch - deltaPitch, vel = vel, relvel = relvel })
            handled = true
          end
          if endppqpos > rightmostTick then
            if not overlapMod() then
              if not handled then
                if not duplicatingArea then
                  local rightRight = math.max(rightmostTick, areaRightmostTick)
                  newppqpos = ppqpos > rightRight and ppqpos or rightRight
                  newendppqpos = endppqpos
                  if ((ppqpos >= areaLeftmostTick and endppqpos < areaRightmostTick)
                      or (newppqpos >= areaLeftmostTick and newendppqpos < areaRightmostTick))
                    and pitch >= area.timeValue.vals.min and pitch <= area.timeValue.vals.max
                  then
                    newppqpos = nil
                    newendppqpos = nil
                    newpitch = nil
                    -- _P('i hate you', ppqpos, endppqpos)
                  else
                    -- _P('i want to hate you', ppqpos, endppqpos, areaLeftmostTick, areaRightmostTick, newppqpos, newendppqpos)
                  end
                end
                classes.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = ppqpos + deltaTicks, endppqpos = rightmostTick + deltaTicks - 1, chan = chan, pitch = pitch - deltaPitch, vel = vel, relvel = relvel })
              end
              handled = true
            end
          end
          if not handled then
            newppqpos = ppqpos + deltaTicks
            newendppqpos = endppqpos + deltaTicks
            newpitch = pitch - deltaPitch
          end
        end
      end

      if process then
        if duplicatingArea then
          if newppqpos and newendppqpos then
            classes.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = newppqpos, endppqpos = newendppqpos, chan = chan, pitch = newpitch or pitch, vel = vel, relvel = relvel })
          end
        else
          if newppqpos and newendppqpos and newppqpos < newendppqpos then
            if newendppqpos - newppqpos > GLOBAL_PREF_SLOP then
              if insert then
                local segments
                if overlapMod()
                  and (ppqpos + GLOBAL_PREF_SLOP < leftmostTick
                    or endppqpos - GLOBAL_PREF_SLOP > rightmostTick)
                then
                  -- nada
                else
                  segments = getNoteSegments(newppqpos or ppqpos, newendppqpos or endppqpos, newpitch or pitch)
                end
                if segments then
                  for i, seg in ipairs(segments) do
                    local newEvent = mu.tableCopy(event)
                    newEvent.ppqpos = seg[1]
                    newEvent.endppqpos = seg[2]
                    newEvent.pitch = newpitch or pitch
                    newEvent.type = mu.NOTE_TYPE
                    classes.addUnique(tInsertions, newEvent)
                  end
                else
                  local newEvent = mu.tableCopy(event)
                  newEvent.ppqpos = newppqpos or ppqpos
                  newEvent.endppqpos = newendppqpos or endppqpos
                  newEvent.pitch = newpitch or pitch
                  newEvent.type = mu.NOTE_TYPE
                  classes.addUnique(tInsertions, newEvent)
                end
              else
                mu.MIDI_SetNote(activeTake, idx, selected, nil, newppqpos, newendppqpos, nil, newpitch)
                touchedMIDI = true
              end
            else
              -- what to do here, maybe it's already deleted??
              mu.MIDI_DeleteNote(activeTake, idx)
              touchedMIDI = true
            end
          end
        end
      end
    end
  end
  end

  -- outside of the enumeration
  if operation == OP_DUPLICATE then
    area.timeValue.ticks:shift(areaTickExtent:size())
    updateTimeValueTime(area)
    updateAreaFromTimeValue(area)
  end

  if widgeting and glob.widgetInfo and glob.widgetInfo.sourceEvents then
    for _, event in ipairs(glob.widgetInfo.sourceEvents) do
      local val = event.vel
      local newval

      if glob.stretchMode == 1 then
        newval = math.floor(offsetValue(val, 1, 127,
                            area.widgetExtents.min, area.widgetExtents.max,
                            (event.ppqpos - area.timeValue.ticks.min) / (area.timeValue.ticks.max - area.timeValue.ticks.min)) + 0.5)
      else
        newval = math.floor(scaleValue(val, 1, 127,
                            area.widgetExtents.min, area.widgetExtents.max,
                            (event.ppqpos - area.timeValue.ticks.min) / (area.timeValue.ticks.max - area.timeValue.ticks.min)) + 0.5)
      end

      mu.MIDI_SetNote(activeTake, event.idx, nil, nil, nil, nil, nil, nil, newval, nil)
      touchedMIDI = true
    end
  end
  return
end

local processCCsWithGeneration

local function laneIsVelocity(area)
  return area.ccLane and (meLanes[area.ccLane].type == 0x200 or meLanes[area.ccLane].type == 0x207)
end

local function processCCs(activeTake, area, operation)
  local hratio, vratio = 1., 1.
  -- local insertions = {}
  -- local removals = {}
  local idx = -1
  local movingArea = operation == OP_STRETCH
        and resizing == RS_MOVEAREA
        and (not currentMods:all() or area.active)
  local duplicatingArea = movingArea and copyMod()
  local stretchingArea = operation == OP_STRETCH
        and stretchMod()
        and area.active
        and resizing > RS_UNCLICKED and resizing < RS_MOVEAREA
  local deltaTicks, deltaVal

  local sourceEvents = area.sourceInfo.sourceEvents
  local usingUnstretched = area.sourceInfo.usingUnstretched

  local pixelsPerValue = meLanes[area.ccLane].pixelsPerValue
  local ccType = meLanes[area.ccLane].type

  local laneIsVel = laneIsVelocity(area)
  local isRelVelocity = ccType == 0x207
  local ccChanmsg, ccFilter = classes.ccTypeToChanmsg(ccType)

  if movingArea then
    deltaTicks = area.timeValue.ticks.min - area.unstretchedTimeValue.ticks.min
    deltaVal = -(area.timeValue.vals.min - area.unstretchedTimeValue.vals.min)

    deltaTicks = math.floor(deltaTicks + 0.5)
    deltaVal = math.floor(deltaVal + 0.5)
  end

  if operation == OP_STRETCH and area.unstretched and (not singleMod() or area.active) then
    hratio = (area.timeValue.ticks:size()) / (area.unstretchedTimeValue.ticks:size())
    vratio = (area.timeValue.vals:size()) / (area.unstretchedTimeValue.vals:size())
    usingUnstretched = true
    if (hratio == 1 and (resizing == RS_LEFT or resizing == RS_RIGHT))
      or (vratio == 1 and (resizing == RS_TOP or resizing == RS_BOTTOM))
    then
      return
    end
  end

  local leftmostTick, rightmostTick, topValue, bottomValue
  local areaLeftmostTick = math.floor(area.timeValue.ticks.min + 0.5)
  local areaRightmostTick = math.floor(area.timeValue.ticks.max + 0.5)

  if usingUnstretched then
    leftmostTick = area.sourceInfo.leftmostTick
    rightmostTick = area.sourceInfo.rightmostTick
    topValue = area.sourceInfo.topValue
    bottomValue = area.sourceInfo.bottomValue
  else
    leftmostTick = areaLeftmostTick
    rightmostTick = areaRightmostTick
    topValue = area.timeValue.vals.max
    bottomValue = area.timeValue.vals.min
  end

  local enumFn = laneIsVel and mu.MIDI_EnumNotes or mu.MIDI_EnumCC

  local skipiter = false
  local widgeting = false
  if glob.widgetInfo and area == glob.widgetInfo.area then
    if glob.widgetInfo.sourceEvents then
      skipiter = true
    end
    widgeting = true
  end

  local process = true
  if operation == OP_COPY or operation == OP_SELECT or operation == OP_UNSELECT then
    process = false
  end

  local insert = false

  -- TODO: REFACTOR (can use same code, approximately, for notes)
  -- potential second iteration, deal with deletions in the target area
  if operation == OP_DUPLICATE then
    local tmpArea = Area.new(area:serialize())
    tmpArea.timeValue.ticks:shift(areaTickExtent:size())
    processCCsWithGeneration(activeTake, tmpArea, OP_DELETE)
  elseif movingArea then
    -- addControlPoints()
    if deltaTicks ~= 0 or deltaVal ~= 0 then
      if laneIsVel then
        -- no move/copy support for vel/rel vel atm
        -- processNotes(activeTake, tmpArea, OP_DELETE)
      else
        local tmpArea = Area.new(area:serialize()) -- only used for event selection
        tmpArea.unstretched, tmpArea.unstretchedTimeValue = area.unstretched, area.unstretchedTimeValue
        if not glob.insertMode then
          processCCsWithGeneration(activeTake, tmpArea, OP_DELETE) -- target
        end
        if not duplicatingArea then
          tmpArea.timeValue = area.unstretchedTimeValue
          processCCsWithGeneration(activeTake, tmpArea, OP_DELETE) -- source
        end
      end
      insert = true
    else
      return
    end
  elseif stretchingArea then
    -- addControlPoints()
    if deltaTicks ~= 0 or deltaVal ~= 0 then
      if resizing == RS_TOP or resizing == RS_BOTTOM then
        skipiter = true
      else
        local tmpArea = Area.new(area:serialize()) -- only used for event selection
        local cacheMods = currentMods
        currentMods = MouseMods.new() -- clear out for the operation
        tmpArea.unstretched, tmpArea.unstretchedTimeValue = area.unstretched, area.unstretchedTimeValue
        if not glob.insertMode then
          processCCsWithGeneration(activeTake, tmpArea, OP_DELETE) -- target
        end
        tmpArea.timeValue = area.unstretchedTimeValue
        processCCsWithGeneration(activeTake, tmpArea, OP_DELETE) -- source
        currentMods = cacheMods
        insert = true
      end
    else
      return
    end
  end

  -- third iteration
  if not skipiter then
    for sidx, event in ipairs(sourceEvents) do
      local selected, muted, ppqpos, endppqpos, chanmsg, chan, msg2, msg3, pitch, vel, relvel

      idx = event.idx

      if laneIsVel then
        selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel, chanmsg, msg2, msg3 = event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.pitch, event.vel, event.relvel, event.chanmsg, event.msg2, event.msg3
      else
        selected, muted, ppqpos, chanmsg, chan, msg2, msg3 = event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3
      end

      local newppqpos, newmsg2, newmsg3

      chanmsg = chanmsg & 0xF0 -- to be safe
      local onebyte = laneIsVel or chanmsg == 0xC0 or chanmsg == 0xD0
      local pitchbend = chanmsg == 0xE0
      local val = event.val

      local function valToBytes(newval, numsg2, numsg3)
        numsg2 = numsg2 or msg2
        numsg3 = numsg3 or msg3
        newval = math.floor(newval)
        numsg2 = onebyte and clipInt(newval) or pitchbend and (newval & 0x7F) or numsg2
        numsg3 = onebyte and numsg3 or pitchbend and ((newval >> 7) & 0x7F) or clipInt(newval)
        return numsg2, numsg3
      end

      if ppqpos >= leftmostTick and ppqpos <= rightmostTick
        and chanmsg == ccChanmsg and (not ccFilter or (ccFilter >= 0 and msg2 == ccFilter))
        and val <= topValue and val >= bottomValue
      then
        if operation == OP_COPY or operation == OP_SELECT or operation == OP_UNSELECT then
          if laneIsVel then
            mu.MIDI_SetNote(activeTake, idx, not (operation == OP_UNSELECT) and true or false) -- allow note deletion like this?
          else
            mu.MIDI_SetCC(activeTake, idx, not (operation == OP_UNSELECT) and true or false)
          end
          touchedMIDI = true
        elseif operation == OP_INVERT then
          newmsg2, newmsg3 = valToBytes(area.timeValue.vals.max - (val - area.timeValue.vals.min))
          -- local newval = area.timeValue.vals.max - (val - area.timeValue.vals.min)
          -- newmsg2 = onebyte and clipInt(newval) or pitchbend and (newval & 0x7F) or msg2
          -- newmsg3 = onebyte and msg3 or pitchbend and ((newval >> 7) & 0x7F) or clipInt(newval)
        elseif operation == OP_RETROGRADE then
          if not laneIsVel then
            local firstppq = sourceEvents[1].ppqpos
            local lastppq = sourceEvents[#sourceEvents].ppqpos
            local delta = (firstppq - leftmostTick) - (rightmostTick - lastppq)
            newppqpos = (rightmostTick - (ppqpos - leftmostTick)) + delta
          end
        elseif operation == OP_RETROGRADE_VALS then
          newmsg2, newmsg3 = valToBytes(sourceEvents[#sourceEvents - (sidx - 1)].val)
          -- local newval = sourceEvents[#sourceEvents - (sidx - 1)].val
          -- newmsg2 = onebyte and clipInt(newval) or pitchbend and (newval & 0x7F) or msg2
          -- newmsg3 = onebyte and msg3 or pitchbend and ((newval >> 7) & 0x7F) or clipInt(newval)
        elseif operation == OP_DUPLICATE then
          if laneIsVel then
            classes.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = ppqpos + areaTickExtent:size(), endppqpos = endppqpos + areaTickExtent:size(), chanmsg = chanmsg, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
          else
            classes.addUnique(tInsertions, { type = mu.CC_TYPE, selected = selected, muted = muted, ppqpos = ppqpos + areaTickExtent:size(), chanmsg = chanmsg, chan = chan, msg2 = msg2, msg3 = msg3 })
          end
        elseif operation == OP_DELETE then
          classes.addUnique(tDeletions, { type = laneIsVel and mu.NOTE_TYPE or mu.CC_TYPE, idx = idx })
        else
          local newval

          if stretchingArea then
            if resizing == RS_LEFT then
              newppqpos = areaLeftmostTick + ((ppqpos - leftmostTick) * hratio)
            elseif resizing == RS_RIGHT then
              newppqpos = areaLeftmostTick + ((ppqpos - areaLeftmostTick) * hratio)
            elseif resizing == RS_TOP or resizing == RS_BOTTOM then
              -- shouldn't ever get here
            end
            if newval then
              newmsg2, newmsg3 = valToBytes(clipInt(newval, 0, meLanes[area.ccLane].range))
              -- newval = clipInt(newval, 0, meLanes[area.ccLane].range)
              -- newmsg2 = onebyte and newval or pitchbend and newval & 0x7F or msg2
              -- newmsg3 = onebyte and msg3 or pitchbend and ((newval >> 7) & 0x7F) or newval
            end
          elseif movingArea then
            -- TODO valToBytes, untangle the value here
            newppqpos = ppqpos + deltaTicks
            newmsg2 = onebyte and clipInt(msg2 - deltaVal) or pitchbend and ((val - deltaVal) & 0x7F) or msg2
            newmsg3 = onebyte and msg3 or pitchbend and (((val - deltaVal) >> 7) & 0x7F) or clipInt(msg3 - deltaVal)
          end
        end
      end

      if process then
        if duplicatingArea then
          if laneIsVel then
            -- newmsg3 = isRelVelocity and newmsg2 or nil
            -- newmsg2 = not isRelVelocity and newmsg2 or nil
            -- if newppqpos then
            --   _P(deltaTicks, ppqpos, newppqpos, endppqpos, endppqpos + deltaTicks)
            --   classes.addUnique(tInsertions, { selected = selected, muted = muted, ppqpos = newppqpos, endppqpos = endppqpos + deltaTicks, chan = chan, pitch = pitch, vel = newmsg2 or vel, relvel = newmsg3 or relvel })
            -- end
          else
            if newppqpos then
              classes.addUnique(tInsertions, { type = mu.CC_TYPE, selected = selected, muted = muted, ppqpos = newppqpos, chanmsg = chanmsg, chan = chan, msg2 = newmsg2 or msg2, msg3 = newmsg3 or msg3 })
            end
          end
        else
          if laneIsVel then
            if not movingArea then
              newmsg3 = isRelVelocity and newmsg2 or nil
              newmsg2 = not isRelVelocity and newmsg2 or nil
              if insert then
                local newEvent = mu.tableCopy(event)
                newEvent.vel, newEvent.relvel = newmsg2 or vel, newmsg3 or relvel
                newEvent.type = mu.NOTE_TYPE
                classes.addUnique(tInsertions, newEvent)
              else
                mu.MIDI_SetNote(activeTake, idx, selected, nil, nil, nil, nil, nil, newmsg2, newmsg3)
                touchedMIDI = true
              end
            end
          else
            if insert then
              local newEvent = mu.tableCopy(event)
              newEvent.ppqpos = newppqpos or ppqpos
              newEvent.msg2 = newmsg2 or msg2
              newEvent.msg3 = newmsg3 or msg3
              newEvent.type = mu.CC_TYPE
              classes.addUnique(tInsertions, newEvent)
            elseif newppqpos or newmsg2 or newmsg3 then
              mu.MIDI_SetCC(activeTake, idx, selected, nil, newppqpos, nil, nil, newmsg2, newmsg3)
              touchedMIDI = true
            end
          end
        end
      end
    end
  end

  -- outside of the enumeration

  if operation == OP_DUPLICATE then
    area.timeValue.ticks:shift(areaTickExtent:size())
    updateTimeValueTime(area)
    updateAreaFromTimeValue(area)
  end

  -- for _, rdx in ipairs(removals) do
  --   if laneIsVel then
  --     mu.MIDI_DeleteNote(activeTake, rdx) -- allow note deletion like this?
  --   else
  --     mu.MIDI_DeleteCC(activeTake, rdx)
  --   end
  --   touchedMIDI = true
  -- end

  if stretchingArea and (resizing == RS_TOP or resizing == RS_BOTTOM) then
    for _, event in ipairs(sourceEvents) do
      local chanmsg = event.chanmsg & 0xF0 -- to be safe
      local onebyte = laneIsVel or chanmsg == 0xC0 or chanmsg == 0xD0
      local pitchbend = chanmsg == 0xE0
      local val = event.val
      local newval

      if resizing == RS_TOP then
        if glob.stretchMode == 1 then
          newval = math.min(math.max(val + (area.timeValue.vals.max - area.unstretchedTimeValue.vals.max), 0), meLanes[area.ccLane].range)
        else
          newval = bottomValue + ((val - bottomValue) * vratio)
        end
      elseif resizing == RS_BOTTOM then
        if glob.stretchMode == 1 then
          newval = math.min(math.max(val + (area.timeValue.vals.min - area.unstretchedTimeValue.vals.min), 0), meLanes[area.ccLane].range)
        else
          newval = topValue - ((topValue - val) * vratio)
        end
      end

      local newmsg2
      local newmsg3
      newmsg2 = onebyte and clipInt(newval) or pitchbend and (newval & 0x7F) or event.msg2
      newmsg3 = onebyte and event.msg3 or pitchbend and ((newval >> 7) & 0x7F) or clipInt(newval)

      if laneIsVel then
        newmsg3 = isRelVelocity and newmsg2 or nil
        newmsg2 = not isRelVelocity and newmsg2 or nil
        mu.MIDI_SetNote(activeTake, event.idx, nil, nil, nil, nil, nil, nil, newmsg2, newmsg3)
      else
        mu.MIDI_SetCC(activeTake, event.idx, nil, nil, nil, event.chanmsg, nil, newmsg2, newmsg3)
      end
      touchedMIDI = true
    end
  end

  if widgeting and glob.widgetInfo and glob.widgetInfo.sourceEvents then
    for _, event in ipairs(glob.widgetInfo.sourceEvents) do
      local chanmsg = event.chanmsg & 0xF0 -- to be safe
      local onebyte = laneIsVel or chanmsg == 0xC0 or chanmsg == 0xD0
      local pitchbend = chanmsg == 0xE0
      local val = (chanmsg == 0xA0 or chanmsg == 0xB0) and event.msg3 or onebyte and event.msg2 or (event.msg3 << 7 | event.msg2)

      local newval
      if glob.stretchMode == 1 then
        newval = math.floor(offsetValue(val, area.timeValue.vals.min, area.timeValue.vals.max,
                            area.widgetExtents.min, area.widgetExtents.max,
                            (event.ppqpos - area.timeValue.ticks.min) / (area.timeValue.ticks.max - area.timeValue.ticks.min)) + 0.5)
      else
        newval = math.floor(scaleValue(val, area.timeValue.vals.min, area.timeValue.vals.max,
                            area.widgetExtents.min, area.widgetExtents.max,
                            (event.ppqpos - area.timeValue.ticks.min) / (area.timeValue.ticks.max - area.timeValue.ticks.min)) + 0.5)
      end
      -- TODO valToBytes, untangle here
      local newmsg2
      local newmsg3
      newmsg2 = onebyte and clipInt(newval) or pitchbend and (newval & 0x7F) or event.msg2
      newmsg3 = onebyte and event.msg3 or pitchbend and ((newval >> 7) & 0x7F) or clipInt(newval)

      if laneIsVel then
        newmsg3 = isRelVelocity and newmsg2 or nil
        newmsg2 = not isRelVelocity and newmsg2 or nil
        mu.MIDI_SetNote(activeTake, event.idx, nil, nil, nil, nil, nil, nil, newmsg2, newmsg3)
      else
        mu.MIDI_SetCC(activeTake, event.idx, nil, nil, nil, event.chanmsg, nil, newmsg2, newmsg3)
      end
      touchedMIDI = true
    end
  end
  return
end

------------------------------------------------
------------------------------------------------

local function processInsertions()
  local activeTake = glob.liceData.editorTake
  for _, event in ipairs(tInsertions) do
    if event.type == mu.NOTE_TYPE then
      if event.ppqpos and event.endppqpos and event.ppqpos < event.endppqpos and event.endppqpos - event.ppqpos > GLOBAL_PREF_SLOP then
        mu.MIDI_InsertNote(activeTake, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.pitch, event.vel, event.relvel)
        touchedMIDI = true
      end
    else
      mu.MIDI_InsertCC(activeTake, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3)
      touchedMIDI = true
    end
  end

  for _, event in ipairs(tDeletions) do
    if event.type == mu.NOTE_TYPE then
      mu.MIDI_DeleteNote(activeTake, event.idx)
    else
      mu.MIDI_DeleteCC(activeTake, event.idx)
    end
    touchedMIDI = true
  end
end

local function addControlPoints(activeTake, area)
  if area.ccLane and not laneIsVelocity(area) and not area.controlPoints and area.sourceInfo.sourceEvents and #area.sourceInfo.sourceEvents ~= 0 then
    local newEvent
    local cp1, cp2
    local sourceEvents = area.sourceInfo.sourceEvents

    newEvent = mu.tableCopy(sourceEvents[1])
    local rv, _, _, _, _, msg2out, msg3out = mu.MIDI_GetCCValueAtTime(activeTake, newEvent.chanmsg, newEvent.chan, newEvent.msg2, area.timeValue.ticks.min, true)
    if rv then
      newEvent.ppqpos = area.timeValue.ticks.min
      newEvent.msg2 = msg2out
      newEvent.msg3 = msg3out
      cp1 = newEvent
    end

    newEvent = mu.tableCopy(sourceEvents[#sourceEvents])
    rv, _, _, _, _, msg2out, msg3out = mu.MIDI_GetCCValueAtTime(activeTake, newEvent.chanmsg, newEvent.chan, newEvent.msg2, area.timeValue.ticks.max, true)
    if rv then
      newEvent.ppqpos = area.timeValue.ticks.max - 10
      newEvent.msg2 = msg2out
      newEvent.msg3 = msg3out
      cp2 = newEvent
    end
    area.controlPoints = {}

    if area.controlPoints then
      table.insert(sourceEvents, 1, cp1)
      table.insert(sourceEvents, cp2)
    end
  end
end

local function generateSourceInfo(area, op, force)
  if not area.sourceInfo or force then
    local isNote = not area.ccLane and true or false
    local activeTake = glob.liceData.editorTake

    area.sourceInfo = { sourceEvents = {}, localRect = area.logicalRect, usingUnstretched = false }

    local wantsWidget = false

    if op == OP_STRETCH
      and area.unstretched
      and (not singleMod()
        or area.active)
    then
      area.sourceInfo.usingUnstretched = true
    end

    local usingUnstretched = area.sourceInfo.usingUnstretched

    local leftmostTick = not usingUnstretched and area.timeValue.ticks.min or area.unstretchedTimeValue.ticks.min
    local rightmostTick = not usingUnstretched and area.timeValue.ticks.max or area.unstretchedTimeValue.ticks.max

    leftmostTick = math.floor(leftmostTick + 0.5)
    rightmostTick = math.floor(rightmostTick + 0.5)

    local topValue = not usingUnstretched and area.timeValue.vals.max or area.unstretchedTimeValue.vals.max
    local bottomValue = not usingUnstretched and area.timeValue.vals.min or area.unstretchedTimeValue.vals.min

    area.sourceInfo.leftmostTick = leftmostTick
    area.sourceInfo.rightmostTick = rightmostTick
    area.sourceInfo.topValue = topValue
    area.sourceInfo.bottomValue = bottomValue

    if glob.widgetInfo and area == glob.widgetInfo.area then
      if not glob.widgetInfo.sourceEvents then
        wantsWidget = true
      end
    end

    local idx = -1
    if isNote then
      while true do
        idx = mu.MIDI_EnumNotes(activeTake, idx)
        if not idx or idx == -1 then break end
        local event = {}
        _, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.pitch, event.vel, event.relvel = mu.MIDI_GetNote(activeTake, idx)

        if event.endppqpos > leftmostTick and event.ppqpos < rightmostTick
          and event.pitch <= topValue and event.pitch >= bottomValue
        then
          if not (op == OP_STRETCH or op == OP_STRETCH_DELETE or op == OP_DELETE_TRIM)
            and overlapMod()
            and event.ppqpos + GLOBAL_PREF_SLOP < leftmostTick
          then
            -- ignore
          else
            event.idx = idx
            area.sourceInfo.sourceEvents[#area.sourceInfo.sourceEvents + 1] = event
          end
        end
      end
    else
      local ccType = meLanes[area.ccLane].type
      local laneIsVel = laneIsVelocity(area)
      local isRelVelocity = ccType == 0x207
      local ccChanmsg, ccFilter = classes.ccTypeToChanmsg(ccType)
      local selNotes

      if ccChanmsg == 0xA0 then -- polyAT, we need to know which notes are selected
        idx = -1
        selNotes = {}
        while true do
          idx = mu.MIDI_EnumSelNotes(activeTake, idx)
          if idx == -1 then break end
          local rv, _, _, _, _, _, pitch = mu.MIDI_GetNote(activeTake, idx)
          if rv and pitch then selNotes[pitch] = 1 end
        end
        if not next(selNotes) then selNotes = nil end -- select all, no selected notes
        idx = -1
      end

      local enumFn = laneIsVel and mu.MIDI_EnumNotes or mu.MIDI_EnumCC

      while true do
        idx = enumFn(activeTake, idx)
        if not idx or idx == -1 then break end
        local event = {}
        -- local rv, selected, muted, ppqpos, endppqpos, chanmsg, chan, msg2, msg3, pitch, vel, relvel

        if laneIsVel then
          _, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.pitch, event.vel, event.relvel = mu.MIDI_GetNote(activeTake, idx)
          event.msg2, event.msg3 = event.vel, event.relvel
          if isRelVelocity then event.msg2 = event.msg3 end
          event.chanmsg, event.msg3 = 0x90, 0
        else
          _, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3 = mu.MIDI_GetCC(activeTake, idx)
        end

        event.chanmsg = event.chanmsg & 0xF0 -- to be safe
        local onebyte = laneIsVel or event.chanmsg == 0xC0 or event.chanmsg == 0xD0
        -- local pitchbend = chanmsg == 0xE0
        local val = (event.chanmsg == 0xA0 or event.chanmsg == 0xB0) and event.msg3 or onebyte and event.msg2 or (event.msg3 << 7 | event.msg2)

        if event.ppqpos >= leftmostTick and event.ppqpos <= rightmostTick
          and event.chanmsg == ccChanmsg and (not ccFilter or (ccFilter >= 0 and event.msg2 == ccFilter))
          and (not selNotes or selNotes[event.msg2]) -- handle PolyAT lane
          and val <= topValue and val >= bottomValue
        then
          event.idx = idx
          event.val = val
          area.sourceInfo.sourceEvents[#area.sourceInfo.sourceEvents + 1] = event
        end
      end
    end

    -- addControlPoints(activeTake, area)

    if wantsWidget then
      glob.widgetInfo.sourceEvents = area.sourceInfo.sourceEvents
    end
  end
end

local function singleAreaProcessing()
  return hottestMods:matches({ shift = true, alt = true, super = '' })
end

processNotesWithGeneration = function(take, area, op)
  generateSourceInfo(area, op, true)
  processNotes(take, area, op)
end

processCCsWithGeneration = function(take, area, op)
  generateSourceInfo(area, op, true)
  processCCs(take, area, op)
end

local function swapAreas(newAreas)
  glob.areas = newAreas
  areas = glob.areas
end

local lastChanged = false

local function processAreas(singleArea, forceSourceInfo)
  local activeTake = glob.liceData.editorTake

  if not muState then
    mu.MIDI_InitializeTake(activeTake)
    muState = mu.MIDI_GetState()
  else
    if not noRestore then
      mu.MIDI_RestoreState(muState)
    end
  end

  noRestore = false

  local operation

  local hovering
  if singleArea or singleAreaProcessing() then
    if singleArea then hovering = singleArea
    else
      for _, area in ipairs(areas) do
        if area.hovering then
          hovering = area
          break
        end
      end
    end
  end

  areaTickExtent = Extent.new(math.huge, -math.huge)

  local function preProcessArea(area) -- captures 'operation'
    if not operation then operation = area.operation end
    area.operation = area.operation == OP_STRETCH and area.operation or nil
    if area.timeValue.ticks.min < areaTickExtent.min then areaTickExtent.min = area.timeValue.ticks.min end
    if area.timeValue.ticks.max > areaTickExtent.max then areaTickExtent.max = area.timeValue.ticks.max end

    generateSourceInfo(area, operation, forceSourceInfo)
  end

  if hovering then
    preProcessArea(hovering)
  else
    for _, area in ipairs(areas) do
      preProcessArea(area)
    end
  end

  mu.MIDI_OpenWriteTransaction(activeTake)

  if operation == OP_COPY or operation == OP_SELECT then
    mu.MIDI_SelectAll(activeTake, false) -- should 'select' unselect everything else?
    touchedMIDI = true
  end

  local changed = false

  local function runProcess(area)
    if not area.ccLane then
      processNotes(activeTake, area, operation)
    else
      processCCs(activeTake, area, operation)
    end
  end

  tInsertions = {}
  tDeletions = {}
  if hovering then
    runProcess(hovering)
  else
    if dragDirection then
      local ddString = classes.dragDirectionToString(dragDirection)
      if ddString then
        swapAreas(classes.sortAreas(areas, ddString))
      end
    end
    for i, area in ipairs(areas) do
      runProcess(area)
    end
  end
  processInsertions()

  if touchedMIDI then changed = true end

  if changed ~= lastChanged then -- ensure that we return to the original state
    mu.MIDI_ForceNextTransaction()
    lastChanged = changed
    touchedMIDI = true
  end

  if touchedMIDI then
    mu.MIDI_CommitWriteTransaction(activeTake, false, true)
  else
    noRestore = true
  end
  touchedMIDI = false

  if operation == OP_COPY then
    r.MIDIEditor_OnCommand(glob.liceData.editor, 40010) -- copy

    mu.MIDI_RestoreState(muState)

    mu.MIDI_OpenWriteTransaction(activeTake)
    mu.MIDI_CommitWriteTransaction(activeTake, false, true)
  end
end

------------------------------------------------
------------------------------------------------

-- cribbed from Julian Sader

local function analyzeChunk()
  local activeTake = glob.liceData.editorTake
  local activeItem = glob.liceData.editorItem

  if not activeItem then return false end

  local activeTakeChunk
  local activeChannel
  local windY = glob.windowRect.y1
  local rv, midivuConfig = r.get_config_var_string('midivu')
  local midivu = tonumber(midivuConfig)
  local showMargin = midivu and (midivu & 0x80) == 0

  glob.currentGrid, glob.currentSwing = r.MIDI_GetGrid(activeTake)

  local mePrevLanes = meLanes
  meLanes = {}
  local mePrevState = meState
  meState = {}
  glob.deadZones = {} -- does this need to be more efficient?

  local takeNum = r.GetMediaItemTakeInfo_Value(activeTake, 'IP_TAKENUMBER')
  local chunkOK, chunk = r.GetItemStateChunk(activeItem, '', false)
    if not chunkOK then
      r.MB('Could not get the state chunk of the active item.', 'ERROR', 0)
      return false
    end
  local takeChunkStartPos
  takeChunkStartPos = 1
  for t = 1, takeNum do
    takeChunkStartPos = chunk:find('\nTAKE[^\n]-\nNAME', takeChunkStartPos+1)
    if not takeChunkStartPos then
      r.MB('Could not find the active take\'s part of the item state chunk.', 'ERROR', 0)
      return false
    end
  end
  local takeChunkEndPos = chunk:find('\nTAKE[^\n]-\nNAME', takeChunkStartPos+1)
  activeTakeChunk = chunk:sub(takeChunkStartPos, takeChunkEndPos)

  -- The MIDI editor scroll and zoom are hidden within the CFGEDITVIEW field
  -- If the MIDI editor's timebase = project synced or project time, horizontal zoom is given as pixels per second.  If timebase is beats, pixels per tick
  meState.leftmostTick, meState.horzZoom, meState.topPitch, meState.pixelsPerPitch = activeTakeChunk:match('\nCFGEDITVIEW (%S+) (%S+) (%S+) (%S+)')

  -- _P('CFGEDITVIEW', meState.leftmostTick, meState.horzZoom, meState.topPitch, meState.pixelsPerPitch)

  meState.leftmostTick, meState.horzZoom, meState.topPitch, meState.pixelsPerPitch = tonumber(meState.leftmostTick), tonumber(meState.horzZoom), 127 - tonumber(meState.topPitch), tonumber(meState.pixelsPerPitch)

  meState.leftmostTick = meState.leftmostTick and math.floor(meState.leftmostTick + 0.5)

  if not (meState.leftmostTick and meState.horzZoom and meState.topPitch and meState.pixelsPerPitch) then
    r.MB('Could not determine the MIDI editor\'s zoom and scroll positions.', 'ERROR', 0)
    return false
  end
  activeChannel, meState.timeBase = activeTakeChunk:match('\nCFGEDIT %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+)')

  -- _P('CFGEDIT', activeChannel, meState.timeBase)

  meState.timeBase = (meState.timeBase == '0' or meState.timeBase == '4') and 'beats' or 'time'
  if meState.timeBase == 'beats' then
    meState.pixelsPerTick = meState.horzZoom
  else
    meState.pixelsPerSecond = meState.horzZoom
    meState.leftmostTime = r.MIDI_GetProjTimeFromPPQPos(activeTake, meState.leftmostTick)
  end

  if mePrevState
    and (mePrevState.leftmostTick ~= meState.leftmostTick
      or mePrevState.horzZoom ~= meState.horzZoom
      or mePrevState.topPitch ~= meState.topPitch
      or mePrevState.pixelsPerPitch ~= meState.pixelsPerPitch)
  then
    glob.meNeedsRecalc = true
    glob.needsRecomposite = true
  end

  -- Now get the heights and types of all the CC lanes.
  -- !!!! WARNING: IF THE EDITOR DISPLAYS TWO LANE OF THE SAME TYPE/NUMBER, FOR EXAMPLE TWO MODWHEEL LANES, THE CHUNK WILL ONLY LIST ONE, AND THIS CODE WILL THEREFORE FAIL !!!!
  -- Chunk lists CC lane from top to bottom, so must first get each lane's height, from top to bottom,
  --    then go in reverse direction, from bottom to top, calculating screen coordinates.
  -- Lane heights include lane divider (9 pixels high in MIDI editor, 8 in inline editor)
  local laneID = -1 -- lane = -1 is the notes area
  meLanes[-1] = {Type = -1, inlineHeight = 100} -- inlineHeight is not accurate, but will simply be used to indicate that this 'lane' is large enough to be visible.
  for vellaneStr in activeTakeChunk:gmatch('\nVELLANE [^\n]+') do
    -- this might fail on R6 -- do I care?
    local laneType, ME_Height, inlineHeight, scroll, zoom = vellaneStr:match('VELLANE (%S+) (%d+) (%d+) (%S+) (%S+)') -- 2 addl args for vertical scroll (0-1) and zoom (1.0 - 8) in R7
    scroll, zoom = tonumber(scroll), tonumber(zoom)
    scroll = scroll or 0
    zoom = zoom or 1

    -- _P('VELLANE', laneType, ME_Height, inlineHeight, scroll, zoom)

    -- Lane number as used in the chunk differ from those returned by API functions such as MIDIEditor_GetSetting_int(editor, 'last_clicked')
    laneType, ME_Height, inlineHeight = classes.convertCCTypeChunkToAPI(tonumber(laneType)), tonumber(ME_Height), tonumber(inlineHeight)
    if not (laneType and ME_Height and inlineHeight) then
      r.MB('Could not parse the VELLANE fields in the item state chunk.', 'ERROR', 0)
        return false
    end
    laneID = laneID + 1
    meLanes[laneID] = { VELLANE = vellaneStr, type = laneType, range = classes.ccTypeToRange(laneType), height = ME_Height, inlineHeight = inlineHeight, scroll = scroll, zoom = zoom }
  end

  local laneBottomPixel = glob.windowRect.y1 + (glob.windowRect:height() - lice.MIDI_SCROLLBAR_B) -- magic numbers which work
  for i = #meLanes, 0, -1 do
    local margin = 0
    meLanes[i].bottomPixel = laneBottomPixel -- - (1 * winscale)
    meLanes[i].topPixel    = laneBottomPixel - meLanes[i].height + lice.MIDI_SEPARATOR

    local height = meLanes[i].bottomPixel - meLanes[i].topPixel

    if showMargin then
      margin = height < 16 and 0 or height >= 192 and 12 or math.floor(((height / 192) * 12) + 0.5)
    end

    local topMargin, bottomMargin = 0, 0
    meLanes[i].bottomValue, meLanes[i].topValue, topMargin, bottomMargin = calculateVisibleRangeWithMargin(meLanes[i].scroll, meLanes[i].zoom, margin, height, 0, meLanes[i].range)

    meLanes[i].bottomPixel = math.floor(meLanes[i].bottomPixel - bottomMargin + 0.5)
    meLanes[i].topPixel = math.floor(meLanes[i].topPixel + topMargin + 0.5)
    meLanes[i].bottomMargin = bottomMargin
    meLanes[i].topMargin = topMargin

    meLanes[i].pixelsPerValue = ((meLanes[i].bottomPixel - meLanes[i].topPixel) / (meLanes[i].topValue - meLanes[i].bottomValue))

    -- _P('meLanes', i, meLanes[i].bottomPixel, meLanes[i].topPixel, meLanes[i].bottomValue, meLanes[i].topValue, meLanes[i].bottomMargin, meLanes[i].topMargin, meLanes[i].pixelsPerValue)

    -- should also check margin on/off, what else?
    if not glob.meNeedsRecalc -- don't bother if we're doing it already
      and mePrevLanes
      and mePrevLanes[i]
      and (mePrevLanes[i].type ~= meLanes[i].type
        or mePrevLanes[i].height ~= meLanes[i].height
        or mePrevLanes[i].scroll ~= meLanes[i].scroll
        or mePrevLanes[i].zoom ~= meLanes[i].zoom)
    then
      glob.meNeedsRecalc = true
      glob.needsRecomposite = true
    end

    table.insert(glob.deadZones, Rect.new(glob.windowRect.x1, meLanes[i].bottomPixel + bottomMargin, glob.windowRect.x1 + lice.MIDI_HANDLE_L, meLanes[i + 1] and meLanes[i + 1].topPixel - meLanes[i + 1].topMargin or glob.windowRect.y2))
    table.insert(glob.deadZones, Rect.new(glob.windowRect.x2 - (lice.MIDI_SCROLLBAR_R + lice.MIDI_HANDLE_R), meLanes[i].bottomPixel + bottomMargin, glob.windowRect.x2 - lice.MIDI_SCROLLBAR_R, meLanes[i + 1] and meLanes[i + 1].topPixel - meLanes[i + 1].topMargin or glob.windowRect.y2))

    laneBottomPixel = laneBottomPixel - meLanes[i].height
  end

  if mePrevLanes and #mePrevLanes ~= #meLanes then
    glob.meNeedsRecalc = true
    glob.needsRecomposite = true
  end

  -- Notes area height is remainder after deducting 1) total CC lane height and 2) height (62 pixels) of Ruler/Marker/Region area at top of midiview
  meLanes[-1].bottomPixel = laneBottomPixel - 1 --- (1 * winscale)
  meLanes[-1].topPixel    = windY
  meLanes[-1].height      = meLanes[-1].bottomPixel - meLanes[-1].topPixel
  meLanes[-1].range       = 127
  meState.bottomPitch = meState.topPitch - math.floor(meLanes[-1].height / meState.pixelsPerPitch)
  meLanes[-1].bottomValue = meState.bottomPitch
  meLanes[-1].topValue = meState.topPitch
  meLanes[-1].pixelsPerValue = meState.pixelsPerPitch

  -- _P('meLanes', -1, meLanes[-1].bottomPixel, meLanes[-1].topPixel, meLanes[-1].bottomValue, meLanes[-1].topValue, meLanes[-1].height, meLanes[-1].pixelsPerValue)

  if meLanes[0] then
    table.insert(glob.deadZones, Rect.new(glob.windowRect.x1, meLanes[-1].bottomPixel, glob.windowRect.x1 + lice.MIDI_HANDLE_L, meLanes[0].topPixel - meLanes[0].topMargin)) -- piano roll -> first lane
    table.insert(glob.deadZones, Rect.new(glob.windowRect.x2 - (lice.MIDI_SCROLLBAR_R + lice.MIDI_HANDLE_R), meLanes[-1].bottomPixel, glob.windowRect.x2 - lice.MIDI_SCROLLBAR_R, meLanes[0].topPixel - meLanes[0].topMargin)) -- piano roll -> first lane
  end
  table.insert(glob.deadZones, Rect.new(glob.windowRect.x2 - lice.MIDI_SCROLLBAR_R, glob.windowRect.y1, glob.windowRect.x2, glob.windowRect.y2))

  if meLanes[0] then
    table.insert(glob.deadZones, Rect.new(glob.windowRect.x1, meLanes[#meLanes].bottomPixel + meLanes[#meLanes].bottomMargin, glob.windowRect.x2, glob.windowRect.y2))
  else
    table.insert(glob.deadZones, Rect.new(glob.windowRect.x1, meLanes[-1].bottomPixel, glob.windowRect.x2, glob.windowRect.y2))
  end

  glob.meLanes = meLanes
  glob.meState = meState

  return true
end

------------------------------------------------
------------------------------------------------

local function clearArea(idx, areaa)
  if not idx then
    for iidx, aarea in ipairs(areas) do
      if aarea == areaa then idx = iidx break end
    end
  end

  if idx and idx > 0 and idx <= #areas then
    local area = areas[idx]
    if lice.destroyBitmap(area.bitmap) then
      area.bitmap = nil
    end
    table.remove(areas, idx)
  end
end

local function clearAreas()
  for _, area in ipairs(areas) do
    if lice.destroyBitmap(area.bitmap) then
      area.bitmap = nil
    end
  end
  swapAreas({})
  resetWidgetMode()
end

local ccLanesToggled = nil

local function toggleThisAreaToCCLanes(area)
  for i = #areas, 1, -1 do
    local a = areas[i]
    if a.ccLane then
      clearArea(i)
    end
  end

  if not ccLanesToggled or area ~= ccLanesToggled then
    for i = #meLanes, 0, -1 do
      local newArea = Area.new({ fullLane = true,
                                         timeValue = TimeValueExtents.new(area.timeValue.ticks.min, area.timeValue.ticks.max, 0, meLanes[i].range),
                                         ccLane = i,
                                         ccType = meLanes[i].type
                                       }, updateAreaFromTimeValue)
      areas[#areas + 1] = newArea
    end
    ccLanesToggled = area
  else
    ccLanesToggled = nil
  end
  return ccLanesToggled
end

local prjStateChangeCt

local function getAreaTableForSerialization()
  local areaTable = {}
  for _, area in ipairs(areas) do
    areaTable[#areaTable + 1] = area:serialize()
  end
  return areaTable
end

local function createUndoStep(undoText, override)
  local undoData = override or (#areas ~= 0 and classes.serialize(getAreaTableForSerialization()) or '')
  r.Undo_BeginBlock2(0)
  r.GetSetMediaItemTakeInfo_String(glob.liceData.editorTake, 'P_EXT:'..scriptID, undoData, true)
  -- r.MarkTrackItemsDirty(r.GetMediaItem_Track(glob.liceData.editorItem), glob.liceData.editorItem)
  r.Undo_EndBlock2(0, undoText, -1)
  if DEBUG_UNDO then
    _P(undoText, #areas)
  end
  prjStateChangeCt = r.GetProjectStateChangeCount(0) -- don't reload due to this
end

glob.handleRightClick = function() -- a little smelly, but whatever works
  for idx, area in ipairs(areas) do
    if area.hovering then
      if glob.widgetInfo and glob.widgetInfo.area and glob.inWidgetMode and area == glob.widgetInfo.area then
        area.widgetExtents = Extent.new(0.5, 0.5)
        processAreas(area) -- TODO: inelegant
        createUndoStep('Reset Widget Trim')
      else
        clearArea(idx)
        createUndoStep('Delete Razor Edit Area')
      end
      return true
    end
  end
  return false
end

local function doClearAll()
  if #areas > 0 then
    clearAreas()
    createUndoStep('Delete All Razor Edit Areas', '')
  end
end

local function checkProjectExtState()
  local _, projState = r.GetSetMediaItemTakeInfo_String(glob.liceData.editorTake, 'P_EXT:'..scriptID, '', false)
  if #projState then
    local areaTable = classes.deserialize(projState)
    clearAreas()
    if areaTable then
      wasDragged = true
      for idx = #areaTable, 1, -1 do
        local area = Area.deserialize(areaTable[idx], updateAreaFromTimeValue)
        if not (area.viewRect and area.logicalRect and area.timeValue) then
        else
          areas[#areas + 1] = area
        end
      end
      resetWidgetMode()
    end
  end
end

local function restorePreferences()
  local stateVal

  if classes.is_windows then
    if lice.MOAR_BITMAPS then
      if r.GetExtState(scriptID, 'moarBitmaps') == '' then
        r.DeleteExtState(scriptID, 'compositeDelayMin', true) -- delete the old prefs and reset to new defaults
        r.DeleteExtState(scriptID, 'compositeDelayMax', true)
        r.DeleteExtState(scriptID, 'compositeDelayBitmaps', true)
        r.SetExtState(scriptID, 'moarBitmaps', '1', true)
      end
    end

    stateVal = r.GetExtState(scriptID, 'compositeDelayMin')
    if stateVal then
      stateVal = tonumber(stateVal)
      if stateVal then lice.compositeDelayMin = math.min(math.max(0, stateVal), 0.3) end
    end

    stateVal = r.GetExtState(scriptID, 'compositeDelayMax')
    if stateVal then
      stateVal = tonumber(stateVal)
      if stateVal then lice.compositeDelayMax = math.min(math.max(0, stateVal), 0.5) end
    end

    stateVal = r.GetExtState(scriptID, 'compositeDelayBitmaps')
    if stateVal then
      stateVal = tonumber(stateVal)
      if stateVal then lice.compositeDelayBitmaps = math.min(math.max(1, stateVal), 100) end
    end
  end

  glob.stretchMode = 0 -- default
  stateVal = r.GetExtState(scriptID, 'stretchMode')
  if stateVal then
    stateVal = tonumber(stateVal)
    if stateVal then glob.stretchMode = math.min(math.max(0, math.floor(stateVal)), 1) end
  end

  lice.reloadSettings() -- key/mod mappings
end

local function savePreferences()
  if classes.is_windows then
    if lice.compositeDelayMin ~= lice.compositeDelayMinDefault then
      r.SetExtState(scriptID, 'compositeDelayMin', string.format('%0.3f', lice.compositeDelayMin), true)
    end
    if lice.compositeDelayMax ~= lice.compositeDelayMaxDefault then
      r.SetExtState(scriptID, 'compositeDelayMax', string.format('%0.3f', lice.compositeDelayMax), true)
    end
    if lice.compositeDelayBitmaps ~= lice.compositeDelayBitmapsDefault then
      r.SetExtState(scriptID, 'compositeDelayBitmaps', string.format('%0.3f', lice.compositeDelayBitmaps), true)
    end
  end
  if glob.stretchMode ~= 0 then
    r.SetExtState(scriptID, 'stretchMode', tostring(glob.stretchMode), true)
  else
    r.DeleteExtState(scriptID, 'stretchMode', true)
  end
end

------------------------------------------------
------------------------------------------------

local prevKeys

local function acquireKeyMods()
  local keyMods = r.JS_Mouse_GetState(0x3C)

  hottestMods:set(keyMods & 0x08 ~= 0, -- shift
                  keyMods & 0x10 ~= 0, -- alt
                  keyMods & 0x04 ~= 0, -- cmd/ctrl (windows)
                  keyMods & 0x20 ~= 0) -- ctrl/'super' (windows)
end

local function swapCurrentMods()
  acquireKeyMods()
  currentMods = hottestMods:clone()
end

local function keyMatches(vkState, info, allowOverlap, someMods)
  someMods = someMods or hottestMods

  local found = false

  if info and info.vKey then
    if vkState:byte(info.vKey) ~= 0 then found = true end
    if info.baseKey == 'del' then
      if vkState:byte(keys.vKeyLookup['back']) ~= 0 then found = true end
    end
    if found then
      local hasOverlapMod, overlapModName = overlapMod(someMods)
      return someMods:matchesFlags(info.modifiers, (allowOverlap and hasOverlapMod) and { [overlapModName] = true } or nil)
    end
  end
  return false
end

local function showCompositingDialog()
  local inputString = string.format('%0.3f', lice.compositeDelayMin) .. ',' .. string.format('%0.3f', lice.compositeDelayMax) .. ',' .. string.format('%d', lice.compositeDelayBitmaps)
  local rv, outputString = r.GetUserInputs('LICE Composite Debug', 3, 'Min. Delay (0 - 0.3), Max. Delay (0 - 0.5), Bitmap Count (1 -100)', inputString)
  if rv then
    local fs, fe, minDel, maxDel, maxBit
    fs, fe, minDel, maxDel, maxBit = string.find(outputString, '^(.*),(.*),(.*)$')

    minDel = minDel and tonumber(minDel) or nil
    maxDel = maxDel and tonumber(maxDel) or nil
    maxBit = maxBit and tonumber(maxBit) or nil
    if maxBit then maxBit = math.floor(maxBit) end

    if minDel then lice.compositeDelayMin = math.min(math.max(0, minDel), 0.3) end
    if maxDel then lice.compositeDelayMax = math.min(math.max(0, maxDel), 0.5) end
    if maxBit then lice.compositeDelayBitmaps = math.min(math.max(1, maxBit), 100) end
    glob.needsRecomposite = true
    savePreferences()
  end
end

local function processKeys()

  -- attempts to suss out the keyboard section focus fail for various reasons
  -- the amount of code required to check what the user clicks on when the script
  -- is running in the background is not commensurate to the task at hand, and it
  -- breaks if REAPER was in the background and then re-activated. anyway, to hell with it.
  -- I've asked for a new API to get the current section focus, if that shows up, can revisit this.

  -- fallback to old style, selective passthrough and that's it
  acquireKeyMods()

  local hotSnap, _, snapFlagName = snapMod(hottestMods)
  if hotSnap ~= snapMod() then
    if snapFlagName then
      currentMods[snapFlagName] = hottestMods[snapFlagName]
    end
  end

  local vState = r.JS_VKeys_GetState(10)
  if vState == prevKeys then
    return
  end

  prevKeys = vState

  if resizing ~= RS_UNCLICKED then return end -- don't handle key commands while dragging

  -- global key commands which need to be checked every loop

  local keyMappings = lice.keyMappings()

  if keyMatches(vState, keyMappings.exitScript) then
    wantsQuit = true
    return
  elseif keyMatches(vState, keyMappings.insertMode) then
    glob.insertMode = not glob.insertMode
    return
  elseif keyMatches(vState, keyMappings.horzLockMode) then
    glob.horizontalLock = not glob.horizontalLock
    if glob.horizontalLock and glob.verticalLock then glob.verticalLock = false end
    return
  elseif keyMatches(vState, keyMappings.vertLockMode) then
    glob.verticalLock = not glob.verticalLock
    if glob.verticalLock and glob.horizontalLock then glob.horizontalLock = false end
    return
  elseif classes.is_windows and keyMatches(vState, keyMappings.compositingSetup) then
    showCompositingDialog()
    return
  end

  if not glob.isIntercept or #areas == 0 then return end -- early return for non-essential/area stuff

  local function processAreaShortcuts(area)

    -- only hovered
    if keyMatches(vState, keyMappings.fullLane) then
      if area.hovering then
        makeFullLane(area)
        createUndoStep('Modify Razor Edit Area')
        return true
      end
      return false
    end

    if keyMatches(vState, keyMappings.ccSpan) then
      if area.hovering and not area.ccLane then
        local toggledOn = toggleThisAreaToCCLanes(area)
        createUndoStep((toggledOn and 'Create' or 'Remove') .. ' Areas for CC Lanes')
        return true
      end
      return false
    end

    if keyMatches(vState, keyMappings.retrograde, true) then
      area.operation = OP_RETROGRADE
      return true
    end

    if keyMatches(vState, keyMappings.retrograde2, true) then -- retrograde values
      area.operation = OP_RETROGRADE_VALS
      return true
    end

    -- local singleMod = singleAreaProcessing()
    -- if (singleMod and area.hovering) or noMod or (not area.ccLane and hottestMods:alt()) then
      if keyMatches(vState, keyMappings.deleteContents, true) then -- delete contents (or D?)
        area.operation = OP_DELETE
        return true
      elseif keyMatches(vState, keyMappings.duplicate, true) then -- duplicate
        area.operation = OP_DUPLICATE
        return true
      elseif keyMatches(vState, keyMappings.invert, true) then -- invert
        area.operation = OP_INVERT
        return true
      -- elseif keyMatches(vState, keyMappings.copy, true) then -- copy
      --   area.operation = OP_COPY
      --   return true
      elseif keyMatches(vState, keyMappings.select, true) then -- select
        area.operation = OP_SELECT
        return true
      elseif keyMatches(vState, keyMappings.unselect, true) then -- unselect
        area.operation = OP_UNSELECT
        return true
      end
    -- end

    return false
  end

  local hovering, processed
  for _, area in ipairs(areas) do
    area.operation = nil
    if area.hovering then hovering = area end
    if processAreaShortcuts(area) then processed = true end
  end
  if processed then return end

  if keyMatches(vState, keyMappings.widgetMode) then -- unselect
    glob.changeWidget = { area = hovering or nil }
    return
  end

  -- this one is special
  if (vState:byte(keys.vKeyLookup['enter']) ~= 0) and glob.inWidgetMode then
    glob.changeWidget = { area = nil }
    return
  end

  local deleteArea = false
  local deleteOnlyArea = false
  if keyMatches(vState, keyMappings.deleteAreaContents) then
    deleteArea = true
  end
  if keyMatches(vState, keyMappings.deleteArea) then
    deleteArea = true
    deleteOnlyArea = true
  end

  if deleteArea then
    if hovering then
      if not deleteOnlyArea then
        hovering.operation = OP_DELETE
        processAreas(hovering, true)
      end
      clearArea(nil, hovering)
      createUndoStep('Delete Razor Edit Area')
    else
      if not deleteOnlyArea then
        for _, area in ipairs(areas) do
          area.operation = OP_DELETE
        end
        processAreas(nil, true)
      end
      doClearAll()
    end
    return
  end

  -- pass anything else through, requires SWS
  if hasSWS and glob.liceData then
    for k = 1, #vState do
      -- if k ~= 0xD and keys:byte(k) ~= 0 then
      if vState:byte(k) ~= 0 then
        if lice.keyIsMapped(k) then
          reaper.CF_SendActionShortcut(glob.liceData.editor, 0, k)
        end
      end
    end
  end

  -- if ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) then
  --   reaper.CF_SendActionShortcut(reaper.GetMainHwnd(), 0, 0xD)
  -- end
  -- if ImGui.IsKeyPressed(ctx, ImGui.Key_NumpadEnter) then
  --   reaper.CF_SendActionShortcut(reaper.GetMainHwnd(), 0, 0x800D)
  -- end

end

local clickedLane

local function resetState()
  resizing = RS_UNCLICKED
  for _, area in ipairs(areas) do
    area.operation = area.operation ~= OP_STRETCH and area.operation or nil
  end
  muState = nil
  clickedLane = nil
  dragDirection = nil
  analyzeCheckTime = nil
  hasMoved = false
end

------------------------------------------------
------------------------------------------------
--- Thanks ChatGPT

-- Standard AABB overlap check:
local function doOverlap(r1, r2)
  return (r1.x1 < r2.x2) and (r1.x2 > r2.x1)
     and (r1.y1 < r2.y2) and (r1.y2 > r2.y1)
end

local function noConflicts(testRect, ignoreIndex)
  for i, area in ipairs(areas) do
    if i ~= ignoreIndex then
      if doOverlap(testRect, area.viewRect) then
        return false
      end
    end
  end
  return true
end

local function attemptDragRectPartial(dragAreaIndex, dx, dy, justdoit)
  local dragArea = areas[dragAreaIndex]
  local visibleRect = dragArea.viewRect
  local originate = resizing == RS_NEWAREA and dragArea.origin

  local draggingMode = (resizing == RS_LEFT and { left = true })
    or (resizing == RS_RIGHT and { right = true })
    or (resizing == RS_TOP and { top = true })
    or (resizing == RS_BOTTOM and { bottom = true })
    or (resizing == RS_MOVEAREA and { move = true })
    or (resizing == RS_NEWAREA and (not dragArea.specialDrag and { right = true, bottom = true } or dragArea.specialDrag))
    or {}

  local newRectFull = visibleRect:clone()

  if draggingMode.move then
    newRectFull.x1 = newRectFull.x1 + dx
    newRectFull.x2 = newRectFull.x2 + dx
    newRectFull.y1 = newRectFull.y1 + dy
    newRectFull.y2 = newRectFull.y2 + dy
  else
    if draggingMode.left then
      newRectFull.x1 = newRectFull.x1 + dx
      if originate then newRectFull.x2 = dragArea.origin.x end
    end
    if draggingMode.right then
      newRectFull.x2 = newRectFull.x2 + dx
      if originate then newRectFull.x1 = dragArea.origin.x end
    end
    if draggingMode.top then
      newRectFull.y1 = newRectFull.y1 + dy
      if originate then newRectFull.y2 = dragArea.origin.y end
    end
    if draggingMode.bottom then
      newRectFull.y2 = newRectFull.y2 + dy
      if originate then newRectFull.y1 = dragArea.origin.y end
    end
  end

  if justdoit or noConflicts(newRectFull, dragAreaIndex) then
    -- do this delta thing so that the unmanipulated logical coords aren't lost
    local applyX1, applyY1, applyX2, applyY2 = newRectFull.x1 - dragArea.viewRect.x1, newRectFull.y1 - dragArea.viewRect.y1, newRectFull.x2 - dragArea.viewRect.x2, newRectFull.y2 - dragArea.viewRect.y2
    dragArea.logicalRect = Rect.new(dragArea.logicalRect.x1 + applyX1, dragArea.logicalRect.y1 + applyY1, dragArea.logicalRect.x2 + applyX2, dragArea.logicalRect.y2 + applyY2)
    dragArea.viewRect = viewIntersectionRect(dragArea)
    return true
  end

  return false
end

local function quantizeToGrid(mx)
  local wantsSnap = getEditorAndSnapWish()
  if not wantsSnap then return mx end

  local activeTake = glob.liceData.editorTake

  local itemStartTime = r.GetMediaItemInfo_Value(glob.liceData.editorItem, 'D_POSITION')
  local itemStartTick = r.MIDI_GetPPQPosFromProjTime(activeTake, itemStartTime - getTimeOffset())

  local currentTick

  if meState.timeBase == 'time' then
    local currentTime = meState.leftmostTime + ((mx - glob.windowRect.x1) / meState.pixelsPerSecond)
    currentTick = r.MIDI_GetPPQPosFromProjTime(activeTake, currentTime - getTimeOffset())
  else
    currentTick = meState.leftmostTick + math.floor(((mx - glob.windowRect.x1) / meState.pixelsPerTick) + 0.5)
  end
  if currentTick < itemStartTick then currentTick = itemStartTick end
  local som = r.MIDI_GetPPQPos_StartOfMeasure(activeTake, currentTick)

  local tickInMeasure = currentTick - som -- get the position from the start of the measure
  local gridUnit = mu.MIDI_GetPPQ(activeTake) * glob.currentGrid
  local quantizedTick = som + (gridUnit * math.floor((tickInMeasure / gridUnit) + 0.5))

  if meState.timeBase == 'time' then
    local quantizedTime = r.MIDI_GetProjTimeFromPPQPos(activeTake, quantizedTick)
    mx = glob.windowRect.x1 + math.floor(((quantizedTime - meState.leftmostTime) * meState.pixelsPerSecond) + 0.5)
  else
    mx = glob.windowRect.x1 + math.floor(((quantizedTick - meState.leftmostTick) * meState.pixelsPerTick) + 0.5)
  end
  return mx
end

local function quantizeMousePosition(mx, my, ccLane)
  mx = mx and quantizeToGrid(mx)
  if my then
    if not ccLane then -- quantize pitch/value
      my = my < meLanes[-1].topPixel and meLanes[-1].topPixel or my > meLanes[-1].bottomPixel and meLanes[-1].bottomPixel or my
      my = math.floor((math.floor(((my - meLanes[-1].topPixel) / meState.pixelsPerPitch) + 0.5) * meState.pixelsPerPitch) + meLanes[-1].topPixel + 0.5)
    else
      my = my < meLanes[ccLane].topPixel and meLanes[ccLane].topPixel or my > meLanes[ccLane].bottomPixel and meLanes[ccLane].bottomPixel or my
      my = math.floor((math.floor(((my - meLanes[ccLane].topPixel) / meLanes[ccLane].pixelsPerValue) + 0.5) * meLanes[ccLane].pixelsPerValue) + meLanes[ccLane].topPixel + 0.5)
    end
  end
  return mx, my
end

local function updateAreaForAllEvents(area)
  local activeTake = glob.liceData.editorTake
  local idx = -1
  local timeMin, timeMax
  local valMin, valMax
  local ccType = area.ccLane and meLanes[area.ccLane].type or nil
  local ccChanmsg, ccFilter = classes.ccTypeToChanmsg(ccType)

  local laneIsVel = laneIsVelocity(area)
  local isNote = not area.ccLane or laneIsVel
  local chanmsg
  local selNotes

  if isNote then
    ccChanmsg = 0x90
    chanmsg = 0x90
  end

  if ccChanmsg == 0xA0 then -- polyAT, we need to know which notes are selected
    idx = -1
    selNotes = {}
    while true do
      idx = mu.MIDI_EnumSelNotes(activeTake, idx)
      if idx == -1 then break end
      local rv, _, _, _, _, _, pitch = mu.MIDI_GetNote(activeTake, idx)
      if rv and pitch then selNotes[pitch] = 1 end
    end
    if not next(selNotes) then selNotes = nil end -- select all, no selected notes
    idx = -1
  end

  local ccValLimited = fullLaneMod() and not laneIsVel
  local enumFn = isNote and mu.MIDI_EnumNotes or mu.MIDI_EnumCC

  while true do
    idx = enumFn(activeTake, idx)
    if not idx or idx == -1 then break end

    local rv, ppqpos, endppqpos, chan, msg2, msg3, pitch

    if isNote then
      rv, _, _, ppqpos, endppqpos, chan, pitch = mu.MIDI_GetNote(activeTake, idx)
    else
      rv, _, _, ppqpos, chanmsg, chan, msg2, msg3 = mu.MIDI_GetCC(activeTake, idx)
    end

    chanmsg = chanmsg & 0xF0

    if chanmsg == ccChanmsg
      and (not ccFilter or (ccFilter >= 0 and msg2 == ccFilter))
      and (not selNotes or selNotes[msg2]) -- handle PolyAT lane
    then
      if not timeMin or ppqpos < timeMin then timeMin = ppqpos end
      local cmppos = isNote and endppqpos or ppqpos
      if not timeMax or cmppos > timeMax then timeMax = cmppos end
      if isNote then
        if not valMin or pitch < valMin then valMin = pitch end
        if not valMax or pitch > valMax then valMax = pitch end
      elseif ccValLimited then
        local val = (chanmsg == 0xC0 or chanmsg == 0xD0) and msg2 or (chanmsg == 0xA0 or chanmsg == 0xB0) and msg3 or msg2 or (msg3 << 7 | msg2)
        if not valMin or val < valMin then valMin = val end
        if not valMax or val > valMax then valMax = val end
      end
    end
  end

  if timeMin and timeMax then
    local leftmostTime
    local rightmostTime

    if meState.timeBase == 'time' then
      leftmostTime = r.MIDI_GetProjTimeFromPPQPos(activeTake, timeMin)
      rightmostTime = r.MIDI_GetProjTimeFromPPQPos(activeTake, timeMax)
    end

    area.timeValue = TimeValueExtents.new(timeMin, timeMax,
                                          (isNote and not laneIsVel) and valMin or ccValLimited and valMin or 0, (isNote and not laneIsVel) and valMax or ccValLimited and valMax or meLanes[area.ccLane].range,
                                          leftmostTime, rightmostTime)
    updateAreaFromTimeValue(area)
  end
end

------------------------------------------------
------------------------------------------------

-- Helper to check if extents1 fully contains extents2
local function contains(extents1, extents2)
  return extents1.ticks.min <= extents2.ticks.min and
         extents1.ticks.max >= extents2.ticks.max and
         extents1.vals.min <= extents2.vals.min and
         extents1.vals.max >= extents2.vals.max
end

-- Helper to check if two extents intersect at all
local function intersects(extents1, extents2)
  local ticks_overlap = not (extents1.ticks.max < extents2.ticks.min or
                           extents2.ticks.max < extents1.ticks.min)

  -- Changed to catch equal values between min and max
  local vals_overlap = not (extents1.vals.max < extents2.vals.min or
                           extents2.vals.max < extents1.vals.min or
                           extents1.vals.min > extents2.vals.max or
                           extents2.vals.min > extents1.vals.max)

  return ticks_overlap and vals_overlap
end

-- Helper to get extents area
local function calcArea(extents)
  return (extents.ticks.max - extents.ticks.min) *
         (extents.vals.max - extents.vals.min)
end

-- Main function to resolve intersections
local function resolveIntersections()
  local result = {}

  -- First pass: remove fully enclosed extents
  for i = 1, #areas do
    local extents1 = areas[i].timeValue
    local is_contained = false
    for j = 1, #areas do
      if i ~= j then
        if areas[i].ccLane == areas[j].ccLane
          and contains(areas[j].timeValue, extents1)
        then
          is_contained = true
          break
        end
      end
    end
    if not is_contained then
      table.insert(result, Area.new(areas[i], updateAreaFromTimeValue)) -- Area.new(areas[i], updateAreaFromTimeValue))
    end
  end

  -- Second pass: resolve partial intersections
  local i = 1
  while i <= #result do
    local j = i + 1
    while j <= #result do
      if result[i].ccLane == result[j].ccLane
        and intersects(result[i].timeValue, result[j].timeValue)
      then
        -- Get current extents
        local extents1 = result[i].timeValue
        local extents2 = result[j].timeValue

        -- Determine which extents should stay unchanged
        local keep_first = result[i].active or
                          (not result[j].active and calcArea(extents1) > calcArea(extents2))

        -- Get the extents in the right order
        local keep_extents = keep_first and extents1 or extents2
        local modify_extents = keep_first and extents2 or extents1
        local modify_idx = keep_first and j or i

        if modify_extents.ticks.max > keep_extents.ticks.min
          and modify_extents.ticks.min < keep_extents.ticks.min
        then
          local new_area = Area.new(result[modify_idx])
          new_area.timeValue = TimeValueExtents.new(
            modify_extents.ticks.min,
            keep_extents.ticks.min,
            modify_extents.vals.min,
            modify_extents.vals.max
          )
          result[modify_idx] = new_area
          updateAreaFromTimeValue(result[modify_idx])
        elseif modify_extents.ticks.min < keep_extents.ticks.max
          and modify_extents.ticks.max > keep_extents.ticks.max
        then
          local new_area = Area.new(result[modify_idx])
          new_area.timeValue = TimeValueExtents.new(
            keep_extents.ticks.max,
            modify_extents.ticks.max,
            modify_extents.vals.min,
            modify_extents.vals.max
          )
          result[modify_idx] = new_area
          updateAreaFromTimeValue(result[modify_idx])
        -- Add vertical intersection handling (inverted for bottom-up coordinates)
        elseif modify_extents.vals.max >= keep_extents.vals.min  -- if top of modify is above bottom of keep
          and modify_extents.vals.min < keep_extents.vals.min   -- and bottom of modify is below bottom of keep
        then
          local new_area = Area.new(result[modify_idx])
          new_area.timeValue = TimeValueExtents.new(
            modify_extents.ticks.min,
            modify_extents.ticks.max,
            modify_extents.vals.min,
            keep_extents.vals.min - 1
          )
          result[modify_idx] = new_area
          updateAreaFromTimeValue(result[modify_idx])
        elseif modify_extents.vals.min <= keep_extents.vals.max  -- if bottom of modify is below top of keep
          and modify_extents.vals.max > keep_extents.vals.max   -- and top of modify is above top of keep
        then
          local new_area = Area.new(result[modify_idx])
          new_area.timeValue = TimeValueExtents.new(
            modify_extents.ticks.min,
            modify_extents.ticks.max,
            keep_extents.vals.max + 1,
            modify_extents.vals.max
          )
          result[modify_idx] = new_area
          updateAreaFromTimeValue(result[modify_idx])
        end
      end
      j = j + 1
    end
    i = i + 1
  end
  updateAreasFromTimeValue()
  return result
end

------------------------------------------------
------------------------------------------------

local function resetMouse()
  resetState()
  clickedLane = nil
  lastPoint = nil
  lastPointQuantized = nil
  if glob.widgetInfo then glob.widgetInfo.side = nil end -- necessary
end

local function processWidget(mx, my, mouseState)
  local testPoint = Point.new(mx, my)

  if glob.widgetInfo and glob.widgetInfo.area
    and glob.inWidgetMode
    and glob.changeWidget and (not glob.changeWidget.area or glob.inWidgetMode)
  then
    local area = glob.widgetInfo.area
    processAreas(area, true)
    createUndoStep('Adjust Razor Edit Area Trim')

    area.widgetExtents = nil
    resetWidgetMode()

    resetState()
    lastPoint = nil
    lastPointQuantized = nil
    return true
  end

  if glob.changeWidget and glob.changeWidget.area and not glob.inWidgetMode then
    glob.changeWidget = nil
    glob.inWidgetMode = true
  end

  if (glob.widgetInfo and glob.widgetInfo.area)
    or (not mouseState.inop and mouseState.hovered and glob.inWidgetMode)
  then
    local found = glob.widgetInfo and glob.widgetInfo.area
    if found and mouseState.clicked and not pointIsInRect(testPoint, glob.widgetInfo.area.viewRect:clone(lice.EDGE_SLOP)) then
      glob.changeWidget = { area = nil }
      -- or should it cancel? TODO
      return true
    end
    if not found then
      for _, area in ipairs(areas) do
        if not found
          and ((area.ccLane and area.ccLane == mouseState.ccLane)
            or (not area.ccLane and not mouseState.ccLane))
          and pointIsInRect(testPoint, area.viewRect, 0)
        then
          found = area
        else
          area.widgetExtents = nil
        end
      end
    end
    if not found then return false end

    -- we have a widget
    local area = found
    local widgetSide = glob.widgetInfo and glob.widgetInfo.side or nil
    local middle = area.viewRect.x1 + (area.viewRect:width() / 2)

    if not widgetSide and mouseState.down then
      if mx <= middle then
        widgetSide = 0
      else
        widgetSide = 1
      end
    end

    local bothArea = area.viewRect:width() * 0.375
    if not mouseState.dragging and not pointIsInRect(testPoint, area.viewRect) then
      glob.setCursor(glob.forbidden_cursor)
    else
      if mx <= middle - bothArea then
        glob.setCursor(glob.tilt_left_cursor)
      elseif mx >= middle + bothArea then
        glob.setCursor(glob.tilt_right_cursor)
      else
        glob.setCursor(glob.segment_up_down_cursor)
      end
    end

    if area.widgetExtents then
      if mouseState.clicked or (mouseState.down and not lastPoint) then
        lastPoint = testPoint
        if glob.widgetInfo then
          local middleX = area.viewRect.x1 + (area.viewRect:width() / 2)
          local halfway = area.viewRect.y1 + (((area.viewRect:height() * area.widgetExtents.min) + (area.viewRect:height() * area.widgetExtents.max)) / 2)
          if pointIsInRect(testPoint, Rect.new(middleX - lice.EDGE_SLOP, halfway - lice.EDGE_SLOP, middleX + lice.EDGE_SLOP, halfway + lice.EDGE_SLOP)) then
            area.widgetExtents = Extent.new(0.5, 0.5)
            return true
          end
        end
        glob.widgetInfo = { area = area, side = widgetSide }
      elseif mouseState.dragging then
        local dy = my - lastPoint.y

        local function handleMin()
          local minValue = area.viewRect.y1 + (area.viewRect:height() * area.widgetExtents.min)
          minValue = minValue + dy
          if minValue < area.viewRect.y1 then minValue = area.viewRect.y1 end
          if minValue > area.viewRect.y2 then minValue = area.viewRect.y2 end
          area.widgetExtents.min = (minValue - area.viewRect.y1) / area.viewRect:height()
        end
        local function handleMax()
          local maxValue = area.viewRect.y1 + (area.viewRect:height() * area.widgetExtents.max)
          maxValue = maxValue + dy
          if maxValue < area.viewRect.y1 then maxValue = area.viewRect.y1 end
          if maxValue > area.viewRect.y2 then maxValue = area.viewRect.y2 end
          area.widgetExtents.max = (maxValue - area.viewRect.y1) / area.viewRect:height()
        end

        local middleX = area.viewRect.x1 + (area.viewRect:width() / 2)
        if pointIsInRect(testPoint, Rect.new(middleX - bothArea, area.viewRect.y1, middleX + bothArea, area.viewRect.y2)) then
          handleMin()
          handleMax()
        elseif widgetSide == 0 then
          handleMin()
        elseif widgetSide == 1 then
          handleMax()
        end
        lastPoint = testPoint
        processAreas(area, true)
      elseif mouseState.released then
        if glob.widgetInfo then
          glob.widgetInfo.side = nil
        end
      end
    else
      area.widgetExtents = Extent.new(0.5, 0.5)
      glob.widgetInfo = { area = area, side = nil }
    end
    return true
  end
  return false
end

-- the idea being that if we were dragging and then we
-- left the window and come back and we're no longer dragging
-- we should auto-release to ensure that everything is complete
-- otherwise we never receive a release event and chaos ensues

local function doBail()
  resetMouse()
  lice.resetButtons()
end

local function isDeadZone(mx, my)
  if my < lice.MIDI_RULER_H then return true end
  local pt = Point.new(mx + glob.liceData.screenRect.x1, my + glob.liceData.screenRect.y1 - lice.MIDI_RULER_H)
  for _, dz in ipairs(glob.deadZones) do
    if resizing == RS_UNCLICKED and pointIsInRect(pt, dz) then
      return true
    end
  end
  return false
end

local function validateDeltaCoords(area, dx, dy)
  if ((dx and dx ~= 0) or (dy and dy ~= 0)) then
    local activeArea = area
    local coordX = (area.specialDrag and area.specialDrag.right or resizing == RS_RIGHT) and area.viewRect.x2 or activeArea.viewRect.x1
    local coordY = (area.specialDrag and area.specialDrag.bottom or resizing == RS_BOTTOM) and activeArea.viewRect.y2 or activeArea.viewRect.y1
    local adjX, adjY = quantizeMousePosition(dx and coordX + dx, dy and coordY + dy, area.ccLane)
    dx = adjX and adjX - coordX
    dy = adjY and adjY - coordY
    return true, dx, dy
  end
  return false, dx, dy
end

local deadzone_lbutton_state = 0

local function ValidateMouse()

  local mState = r.JS_Mouse_GetState(1)

  if deadzone_lbutton_state == 0 then
    local x, y = r.GetMousePosition()

    local wx1, wy1, wx2, wy2 = glob.liceData.windRect:coords()
    if classes.is_macos then  wy1, wy2 = wy2, wy1 end

    local isMidiViewHovered = x >= wx1 and x <= wx2 and y >= wy1 and y <= wy2
    if not isMidiViewHovered then
      -- Limit mouse to midiview coordinates
      x = x < wx1 and wx1 or x > wx2 and wx2 or x
      y = y < wy1 and wy1 or y > wy2 and wy2 or y
    end
    local mx, my = r.JS_Window_ScreenToClient(glob.liceData.midiview, x, y)
    local mouseLeftDown = mState == 1

    local isValidMouseAction = lice.lbutton_drag and mouseLeftDown
    local inDeadZone = isDeadZone(mx, my)
    -- Check that mouse cursor is hovered over a valid midiview area
    if not isValidMouseAction then
      isValidMouseAction = isMidiViewHovered and not inDeadZone
      if lice.lbutton_drag and not mouseLeftDown then
        lice.resetButtons()
        lice.lbutton_release = true
      end
    end

    if isValidMouseAction then
      lice.peekIntercepts(mx, my)
      return true, mx, my
    end
  end

  deadzone_lbutton_state = mState
  lice.passthroughIntercepts()

  lice.lbutton_click = false
  lice.lbutton_drag = false
  lice.lbutton_release = true
  glob.prevCursor = -1

  doBail()
  return false
end

local function canStretchLR(area)
  return not area.ccLane
    or not laneIsVelocity(area)
end

local function canStretchTB(area)
  return area.ccLane
end

local deferredClearAll = false
local noProcessOnRelease = false

local function runOperation()
  swapCurrentMods()
  processAreas(nil, true)
  createUndoStep('Process Razor Area Contents')
end

local function processMouse()

  local rv, mx, my = ValidateMouse()

  if not rv then
    for _, area in ipairs(areas) do
      if area.operation then
        runOperation()
        break
      end
    end
    return
  end

  if not glob.appIsForeground then return end

  local isCC = false
  local ccLane
  local isActive

  mx = mx + glob.liceData.screenRect.x1
  my = my + glob.liceData.screenRect.y1 - lice.MIDI_RULER_H -- correct for the RULER

  local valid = false
  if clickedLane then
    valid = true
    ccLane = clickedLane ~= -1 and clickedLane or nil
    isCC = ccLane ~= nil
  else
    -- here we can determine what the current target is: piano roll or CC lane
    if my >= meLanes[-1].topPixel - lice.EDGE_SLOP and my <= meLanes[-1].bottomPixel + lice.EDGE_SLOP then
      -- it's a note
      valid = true
      clickedLane = -1
    else
      for i = #meLanes, 0, -1 do
        if my >= meLanes[i].topPixel - lice.EDGE_SLOP and my <= meLanes[i].bottomPixel + lice.EDGE_SLOP then
          valid = true
          isCC = true
          ccLane = i
          clickedLane = i
        end
      end
    end
  end

  local inop = false

  for idx, area in ipairs(areas) do
    if area.active and resizing ~= RS_UNCLICKED then isActive = idx end
    if area.operation then inop = true end
  end

  if (isActive and not areas[isActive].ccLane) or (not isActive and (not valid or not isCC)) then
    if my < meLanes[-1].topPixel then my = meLanes[-1].topPixel end
    if my > meLanes[-1].bottomPixel then my = meLanes[-1].bottomPixel end
  elseif meLanes[0] then
    if my < meLanes[0].topPixel then my = meLanes[0].topPixel end
    if my > meLanes[#meLanes].bottomPixel then my = meLanes[#meLanes].bottomPixel end
  end

  local isDoubleClicked = lice.lbutton_dblclick and not lice.lbutton_dblclick_seen

  if isDoubleClicked then
    local wantsWidgetToggle = nil
    local areaCountPreClick = #areas
    lice.lbutton_dblclick_seen = true

    for i = #areas, 1, -1 do
      local area = areas[i]
      if clickedLane == area.ccLane or (clickedLane == -1 and not area.ccLane) then
        if area.hovering then
          wantsWidgetToggle = area
          break
        end
      end
    end

    if wantsWidgetToggle then
      glob.changeWidget = { area = wantsWidgetToggle or nil }
      return
    else
      resetState()
      processAreas(nil, true) -- get the state

      areas[#areas + 1] = Area.newFromRect({ viewRect = Rect.new(mx, my, mx, my),
                                      logicalRect = Rect.new(mx, my, mx, my),
                                      origin = Point.new(mx, my),
                                      ccLane = ccLane or nil,
                                      ccType = ccLane and meLanes[ccLane].type or nil }, updateAreaForAllEvents)
      if not areas[#areas].timeValue then
        if areaCountPreClick > 0 then doClearAll() else clearArea(1) end
      else
        local newAreas = resolveIntersections()
        clearAreas()
        swapAreas(newAreas)
        createUndoStep('Create Razor Edit Area (Full Lane)')
      end
      return
    end
  end

  local isDown = lice.lbutton_press_x and true or false
  local isClicked = lice.lbutton_click and true or false
  local isDragging = lice.lbutton_drag and true or false
  local isReleased = lice.lbutton_release and true or false
  local isHovered = true

  local isOnlyHovered = not isDown and not isReleased and isHovered

  -- _P('down', isDown, 'clicked', isClicked, 'drag', isDragging, 'rel', isReleased, 'hov', isHovered)

  if isClicked then
    swapCurrentMods()
  end

  -- correct/update state
  if isDown and isClicked then lice.lbutton_click = false lice.lbutton_drag = true end
  if not isDown and isReleased then lice.lbutton_drag = false lice.lbutton_release = false end

  if not isDown and not isHovered then
    resetMouse()
    return
  end

  if processWidget(mx, my, { down = isDown,
                              clicked = isClicked,
                              dragging = isDragging,
                              released = isReleased,
                              hovered = isHovered,
                              hoveredOnly = isOnlyHovered,
                              ccLane = ccLane,
                              inop = inop }) then return end

  if (not isClicked and isDown and not lastPoint) then return end

  local testPoint = Point.new(mx, my)

  if isClicked or isOnlyHovered then
    local doProcess = false

    resetState()

    local cursorSet = false

    for _, area in ipairs(areas) do
      local hovering = { left = false, top = false, right = false, bottom = false, widget = false, area = false }
      local addHover = false
      local theseMods = isClicked and currentMods or hottestMods

      area.sourceInfo = nil
      if pointIsInRect(testPoint, area.viewRect) then
        if equalIsh(area.logicalRect.x1, area.viewRect.x1) and nearValue(mx, area.viewRect.x1) then
          hovering.left = true
          addHover = true
          glob.setCursor((stretchMod(theseMods) and canStretchLR(area)) and glob.stretch_left_cursor
                  or (stretchMod(theseMods) and not canStretchLR(area)) and glob.forbidden_cursor
                  or glob.resize_left_cursor)
          cursorSet = true
        elseif equalIsh(area.logicalRect.x2, area.viewRect.x2) and nearValue(mx, area.viewRect.x2) then
          hovering.right = true
          addHover = true
          glob.setCursor((stretchMod(theseMods) and canStretchLR(area)) and glob.stretch_right_cursor
                  or (stretchMod(theseMods) and not canStretchLR(area)) and glob.forbidden_cursor
                  or glob.resize_right_cursor)
          cursorSet = true
        elseif equalIsh(area.logicalRect.y1, area.viewRect.y1) and nearValue(my, area.viewRect.y1) then
          hovering.top = true
          addHover = true
          glob.setCursor((stretchMod(theseMods) and area.ccLane) and glob.stretch_up_down
                  or (stretchMod(theseMods) and not area.ccLane) and glob.forbidden_cursor
                  or glob.resize_top_cursor) -- stretch_top?
          cursorSet = true
        elseif equalIsh(area.logicalRect.y2, area.viewRect.y2) and nearValue(my, area.viewRect.y2) then
          hovering.bottom = true
          addHover = true
          glob.setCursor((stretchMod(theseMods) and area.ccLane) and glob.stretch_up_down
                  or (stretchMod(theseMods) and not area.ccLane) and glob.forbidden_cursor
                  or glob.resize_bottom_cursor) -- stretch_bottom?
          cursorSet = true
        elseif pointIsInRect(testPoint, area.viewRect, 0) then
          hovering.area = true
          addHover = true
          glob.setCursor(laneIsVelocity(area) and (currentMods:all() and glob.razor_move_cursor or glob.forbidden_cursor)
            or copyMod(theseMods) and glob.razor_copy_cursor
            or glob.razor_move_cursor)
          cursorSet = true
        end
      end

      local rsz = RS_UNCLICKED
      local canResize = resizing == RS_UNCLICKED and wasDragged and addHover
      if canResize then
        if hovering.left then
          rsz = RS_LEFT
        elseif hovering.right then
          rsz = RS_RIGHT
        elseif hovering.top then
          rsz = RS_TOP
        elseif hovering.bottom then
          rsz = RS_BOTTOM
        elseif hovering.area then
          rsz = RS_MOVEAREA
        end
      end

      if canResize and not isOnlyHovered then
        if isDown then resizing = rsz end
        area.active = rsz > RS_NEWAREA
        area.unstretched = (not currentMods:all() or area.active) and area.logicalRect:clone() or nil
        area.unstretchedTimeValue = area.unstretched and area.timeValue:clone() or nil
        area.operation = (not currentMods:all() or area.active) and OP_STRETCH or nil
      else
        area.active = false
        area.unstretched = (isDown and not currentMods:all()) and area.logicalRect:clone() or nil -- we need this for multi-area move/copy (only RS_MOVEAREA?)
        area.unstretchedTimeValue = area.unstretched and area.timeValue:clone() or nil
      end
      if area.operation then doProcess = true end
      area.hovering = addHover and hovering or nil
      area.widgetExtents = nil
    end

    if not cursorSet then
      glob.setCursor(glob.razor_cursor1)
    end

    if glob.widgetInfo then glob.widgetInfo.sourceEvents = nil end

    if isOnlyHovered then
      if doProcess then
        runOperation()
      end
      return
    end

    if resizing == RS_UNCLICKED then resizing = RS_NEWAREA end

    local canNew = false
    if resizing == RS_NEWAREA then
      canNew = true
      for _, area in ipairs(areas) do
        if pointIsInRect(testPoint, area.viewRect, 0) then canNew = false end
      end
    end

    lastPoint = testPoint
    mx, my = quantizeMousePosition(mx, my, ccLane)
    lastPointQuantized = Point.new(mx, my)
    hasMoved = false

    if canNew then
      wasDragged = false
      muState = nil

      if not preserveMod() then
        clearAreas()
        deferredClearAll = true
      end

      if ccLane and meLanes[ccLane].type == 0x210 then
        resizing = RS_UNCLICKED return -- media item lane is verboten
      end

      local fullLane = (ccLane and not fullLaneMod()) or (not ccLane and fullLaneMod())

      areas[#areas + 1] = Area.newFromRect({ viewRect = Rect.new(mx, my, mx, my),
                                      logicalRect = Rect.new(mx, my, mx, my),
                                      origin = Point.new(mx, my),
                                      ccLane = ccLane or nil,
                                      ccType = ccLane and meLanes[ccLane].type or nil,
                                      active = true,
                                      fullLane = fullLane }, makeTimeValueExtentsForArea)
    end
  elseif isDragging then
    local updatePoint = true
    local stretching = false
    local prevPoint = lastPoint
    local isMoving

    wasDragged = true
    if not analyzeCheckTime then
      analyzeCheckTime = glob.currentTime
    end

    if not hasMoved then -- first drag
      isMoving = math.abs(lastPoint.x - mx) > 3 or math.abs(lastPoint.y - my) > 3
    else
      isMoving = lastPoint.x ~= mx or lastPoint.y ~= my
    end

    if isMoving
      or (resizing == RS_NEWAREA and areas[#areas].logicalRect:height() == 0)
    then
      hasMoved = true
      dragDirection = { left = mx < lastPoint.x, right = mx > lastPoint.x, top = my < lastPoint.y, bottom = my > lastPoint.y }
      if not lastPointQuantized then lastPointQuantized = lastPoint:clone() end
      lastPoint = Point.new(mx, my)
      mx, my = quantizeMousePosition(mx, my, ccLane)

      if resizing == RS_NEWAREA then -- making a new area
        local area = areas[#areas]

        local dx = mx - lastPointQuantized.x
        local dy = my - lastPointQuantized.y

        -- try this for now, maybe it can be improved (ensure at least 1 note height in piano roll)
        if dy == 0 and area.logicalRect:height() == 0 then dy = (meLanes[area.ccLane and area.ccLane or -1].pixelsPerValue * (dragDirection.top and -1 or 1)) end

        area.specialDrag = {}
        if area.fullLane then
          if area.ccLane then
            area.logicalRect.y1 = meLanes[area.ccLane].topPixel - ((meLanes[area.ccLane].range - meLanes[area.ccLane].topValue) * meLanes[area.ccLane].pixelsPerValue)
            area.logicalRect.y2 = meLanes[area.ccLane].bottomPixel + (meLanes[area.ccLane].bottomValue * meLanes[area.ccLane].pixelsPerValue)
            area.viewRect.y1 = meLanes[area.ccLane].topPixel
            area.viewRect.y2 = meLanes[area.ccLane].bottomPixel
          else
            area.logicalRect.y1 = glob.windowRect.y1 - ((meLanes[-1].range - meState.topPitch) * meState.pixelsPerPitch)
            area.logicalRect.y2 = meLanes[-1].bottomPixel + (meState.bottomPitch * meState.pixelsPerPitch)
            area.viewRect.y1 = meLanes[-1].topPixel
            area.viewRect.y2 = meLanes[-1].bottomPixel
          end
          dy = 0
          if area.origin and mx < area.origin.x then area.specialDrag.left = true end
          if not area.specialDrag.left then area.specialDrag.right = true end
        else
          if area.origin and mx < area.origin.x then area.specialDrag.left = true end
          if area.origin and my < area.origin.y then area.specialDrag.top = true end
          if not area.specialDrag.top then area.specialDrag.bottom = true end
          if not area.specialDrag.left then area.specialDrag.right = true end
        end

        _, dx, dy = validateDeltaCoords(area, dx, dy)

        if not attemptDragRectPartial(#areas, dx, dy, true) then
          updatePoint = false
        end
        updateTimeValueExtentsForArea(area)
      else -- resizing (single), stretching (single) or moving (single with modifier, otherwise all)
        local multilane = false
        if #areas > 1 then
          local laneCCLane = areas[#areas].ccLane
          for _, area in ipairs(areas) do
            if laneCCLane ~= area.ccLane then multilane = true break end
          end
        end
        for idx, area in ipairs(areas) do
          local found = false
          local dx, dy = 0, 0
          local single = true
          if resizing == RS_MOVEAREA
            and (not singleMod() or laneIsVelocity(area))
          then
            if laneIsVelocity(area) then
              if currentMods:all() then
                dx = mx - lastPointQuantized.x
                dy = my - lastPointQuantized.y
              else
                dx = 0
                dy = 0
              end
              stretching = false
            else
              dx = mx - lastPointQuantized.x
              dy = my - lastPointQuantized.y
              single = false
              stretching = true
            end
            found = true
          elseif area.active then
            if resizing == RS_LEFT or resizing == RS_RIGHT then
              dx = mx - lastPointQuantized.x
            elseif resizing == RS_TOP or resizing == RS_BOTTOM then
              dy = my - lastPointQuantized.y
            elseif resizing == RS_MOVEAREA then
              dx = mx - lastPointQuantized.x
              dy = my - lastPointQuantized.y
            end

            stretching = not (resizing == RS_MOVEAREA and currentMods:all()) -- all = just move area
            if not stretching then noProcessOnRelease = true end -- TODO hack
            found = true

            if resizing ~= RS_MOVEAREA and stretchMod() then
              if ((resizing == RS_LEFT or resizing == RS_RIGHT) and not canStretchLR(area)) then
                dx = 0
                stretching = false
              elseif ((resizing == RS_TOP or resizing == RS_BOTTOM) and not canStretchTB(area)) then
                dy = 0
                stretching = false
              end
            else
              stretching = false
            end
          end
          if found then
            local ret
            ret, dx, dy = validateDeltaCoords(isActive and areas[isActive] or area, dx, dy)
            if ret and resizing == RS_MOVEAREA
              and (area.fullLane
                or (isActive
                  and (areas[isActive].fullLane or areas[isActive].ccLane ~= area.ccLane)
                )
              )
            then dy = 0 end

            if (resizing == RS_LEFT and area.viewRect.x1 + dx >= area.viewRect.x2)
              or (resizing == RS_RIGHT and area.viewRect.x2 + dx <= area.viewRect.x1)
              or (resizing == RS_TOP and area.viewRect.y1 + dy >= area.viewRect.y2)
              or (resizing == RS_BOTTOM and area.viewRect.y2 + dy <= area.viewRect.y1)
            then
              -- nada
              updatePoint = false
            else
              if resizing == RS_MOVEAREA then
                if glob.horizontalLock then dy = 0 end
                if glob.verticalLock then dx = 0 end
              end

              if not single then
                if multilane then dy = 0 end

                -- prevent motion past item start
                local itemStartTime = r.GetMediaItemInfo_Value(glob.liceData.editorItem, 'D_POSITION')
                local itemStartTick = r.MIDI_GetPPQPosFromProjTime(glob.liceData.editorTake, itemStartTime)
                local itemStartX

                if meState.timeBase == 'time' then
                  itemStartX = glob.windowRect.x1 + ((itemStartTime - glob.meState.leftmostTime) * meState.pixelsPerSecond)
                else
                  itemStartX = glob.windowRect.x1 + ((itemStartTick - glob.meState.leftmostTick) * meState.pixelsPerTick)
                end

                for i, testArea in ipairs(areas) do
                  if (testArea.ccLane == area.ccLane or (not testArea.ccLane and not area.ccLane)) then
                    if testArea.viewRect.y2 + dy > meLanes[area.ccLane or -1].bottomPixel then dy = 0 break end
                    if testArea.viewRect.y1 + dy < meLanes[area.ccLane or -1].topPixel then dy = 0 break end

                    -- prevent motion past item start
                    if testArea.viewRect.x1 + dx < itemStartX then dx = 0 break end
                  end
                end

                for tidx, testArea in ipairs(areas) do
                  attemptDragRectPartial(tidx, dx, dy, true)
                  updateTimeValueExtentsForArea(testArea)
                end
                break
              else
                if not attemptDragRectPartial(idx, dx, dy) then
                  updatePoint = false
                end
                updateTimeValueExtentsForArea(area)
            end
            end
            if single then break end
          end
        end
      end
      if isMoving and updatePoint then
        lastPointQuantized = Point.new(mx, my)
      else
        lastPoint = prevPoint
      end
    end
    if stretching then -- TODO: not if resizing?
      processAreas()
    end
  elseif isReleased then
    local stretching = false
    for _, area in ipairs(areas) do -- update all areas, maybe we did a multi-stretch or sth (if supported at some point)
      area.viewRect:conform()
      area.logicalRect:conform()
      area.origin = nil
      area.specialDrag = nil
      if area.active then stretching = true end
      updateTimeValueTime(area)
    end

    if resizing == RS_NEWAREA
      and (areas[#areas].logicalRect:width() < 5 or areas[#areas].logicalRect:height() < 5)
      and deferredClearAll
    then
      doClearAll()
      resetState()
      lastPoint = nil
      lastPointQuantized = nil
      return
    end

    if hasMoved then -- only if we dragged
      if not noProcessOnRelease then
        processAreas()
      end

      local newAreas = resolveIntersections()
      clearAreas()
      swapAreas(newAreas)

      local removals = {}
      for idx, area in ipairs(areas) do
        if area.logicalRect:width() < 5 or area.logicalRect:height() < 5 then
          table.insert(removals, 1, idx)
        end
        area.active = false
        area.unstretched = nil
        area.unstretchedTimeValue = nil
      end

      for idx = #removals, 1, -1 do
        clearArea(idx)
      end

      local undoText
      if stretching and resizing ~= RS_NEWAREA then
        if #removals ~= 0 then undoText = 'Delete Razor Edit Area'
        elseif resizing ~= RS_MOVEAREA then undoText = 'Scale Razor Edit Area'
        elseif not currentMods:all() then undoText = 'Move Razor Edit Area Contents'
        else undoText = 'Duplicate Razor Edit Area Contents'
        end
      else
        if #removals ~= 0 then undoText = nil -- basically we did nothing
        else undoText = 'Create Razor Edit Area'
        end
      end

      if undoText then
        createUndoStep(undoText)
      end
    end

    resetState()
    lastPoint = nil
    lastPointQuantized = nil
    noProcessOnRelease = false
  end
end

local function createAreaForSelectedNotes()
  if not glob.liceData then return end
  local activeTake = glob.liceData.editorTake
  local minVal, maxVal, minTick, maxTick
  local idx = -1

  while true do
    idx = mu.MIDI_EnumSelNotes(activeTake, idx)
    if idx == -1 then break end
    local _, _, _, ppqpos, endppqpos, _, pitch = mu.MIDI_GetNote(activeTake, idx)
    if not minTick or ppqpos < minTick then minTick = ppqpos end
    if not maxTick or endppqpos > maxTick then maxTick = endppqpos end
    if not minVal or pitch < minVal then minVal = pitch end
    if not maxVal or pitch > maxVal then maxVal = pitch end
  end

  if minVal and maxVal and minTick and maxTick then
    local newArea = Area.new({ timeValue = TimeValueExtents.new(minTick, maxTick, minVal, maxVal) }, updateAreaFromTimeValue)
    areas[#areas + 1] = newArea
    createUndoStep('Create Razor Area for Selected Notes')
  end
end

local function checkForSettingsUpdate()
  local state = r.GetExtState(scriptID, 'settingsUpdated')
  if state then
    r.DeleteExtState(scriptID, 'settingsUpdated', false)
    if state ~= '' then
      restorePreferences()
    end
  end
end

local function shutdown()
  lice.shutdownLice()
  local editor = r.MIDIEditor_GetActive()
  if editor then
    r.DockWindowActivate(editor)
    local midiview = r.JS_Window_FindChildByID(editor, 1001)
    r.JS_Window_SetFocus(midiview or editor)
  end

  r.SetToggleCommandState(sectionID, commandID, 0)
  r.RefreshToolbar2(sectionID, commandID)

  r.DeleteExtState(scriptID, 'MRERunning', false)
end

local function onCrash(err)
  shutdown()
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
end

local function loop()

  if wantsQuit then return end -- check once before doing anything, and again after processing keys

  glob.currentTime = r.time_precise()

  local currEditor = glob.liceData and glob.liceData.editor or nil
  -- Get MIDI editor window (limit to one call per 200ms)
  if not currEditor or not editorCheckTime or glob.currentTime > editorCheckTime + 0.2 then
    editorCheckTime = glob.currentTime
    currEditor = r.MIDIEditor_GetActive()
    checkForSettingsUpdate()
  elseif currEditor and not r.ValidatePtr(currEditor, 'HWND*') then
    currEditor = r.MIDIEditor_GetActive()
  end

  -- End process when no MIDI editor is open
  if not currEditor then return end

  local editorTake = r.MIDIEditor_GetTake(currEditor)
  -- Keep process idle when there is no take
  if not r.ValidatePtr(editorTake, 'MediaItem_Take*') then
    lice.shutdownLice()
    r.defer(function() xpcall(loop, onCrash) end)
    return
  end

  lice.peekAppIntercepts()

  lice.initLice(currEditor)

  glob.liceData.editorTake = editorTake
  glob.liceData.editorItem = r.GetMediaItemTake_Item(editorTake)

  if glob.appIsForeground -- no need to analyze in bg or during drag (TODO: expect when scrolling)
    and (not analyzeCheckTime or glob.currentTime > analyzeCheckTime + 0.2)
  then
    analyzeCheckTime = analyzeCheckTime and glob.currentTime or nil
    analyzeChunk()
  end

  local stateChangeCt = r.GetProjectStateChangeCount(0)
  if prjStateChangeCt and prjStateChangeCt ~= stateChangeCt then
    justLoaded = true
    mu.MIDI_ForceNextTransaction()
  end
  prjStateChangeCt = stateChangeCt

  if justLoaded then
    justLoaded = false
    checkProjectExtState()

    if startupOptions and startupOptions & STARTUP_SELECTED_NOTES ~= 0 then
      clearAreas()
      createAreaForSelectedNotes()
      swapAreas(areas)
      startupOptions = nil
    end
  end

  -- Intercept keyboard when focused and areas are present
  local focusWindow = glob.appIsForeground and r.JS_Window_GetFocus() or nil
  if focusWindow
    and (focusWindow == currEditor
      or focusWindow == glob.liceData.midiview -- don't call into JS_Window_IsChild unless necessary
      or r.JS_Window_IsChild(currEditor, focusWindow))
    and #areas > 0
  then
    lice.attendKeyIntercepts()
    processKeys()
  else
    lice.ignoreKeyIntercepts()
  end

  if wantsQuit then return end

  updateAreasFromTimeValue()
  processMouse()
  lice.drawLice()

  r.defer(function() xpcall(loop, onCrash) end)
end

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

local function setStartupOptions(opt)
  startupOptions = opt
end

local function startup(secID, cmdID)
  sectionID, commandID = secID, cmdID

  r.set_action_options(1)
  r.SetToggleCommandState(sectionID, commandID, 1)
  r.RefreshToolbar2(sectionID, commandID)

  justLoaded = true
  restorePreferences()

  lice.recalcConstants(true)

  if PROFILING then
    profiler.attachToWorld() -- after all functions have been defined
    profiler.run()
  end
end

-----------------------------------------------------------------------------
-----------------------------------------------------------------------------

Lib.startup = startup
Lib.loop = loop
Lib.shutdown = shutdown
Lib.onCrash = onCrash

Lib.setStartupOptions = setStartupOptions

local runState = r.GetExtState(scriptID, 'MRERunning')
if runState and runState ~= '' then
  _P('Cannot run multiple instances of MIDI Razor Edits')
  wantsQuit = true
else
  r.SetExtState(scriptID, 'MRERunning', 'true', false)
end

return Lib
