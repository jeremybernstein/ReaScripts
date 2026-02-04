--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper
local Lib = {}

local RCW_MIN_VERSION = '2.0.0'

local DEBUG_UNDO = false
local sectionID, commandID
local hasSWS = true

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

local DEBUG_MU = false
if DEBUG_MU then
  package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
else
  package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. '/?.lua;' -- GET DIRECTORY FOR REQUIRE
end
local mu = require 'MIDIUtils'

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
local mod = keys.mod
local helper = require 'MIDIRazorEdits_Helper'
local slicer = require 'MIDIRazorEdits_Slicer'
local pitchbend = require 'MIDIRazorEdits_PitchBend'
local Mode = require 'MIDIRazorEdits_Mode'
local analyze = require 'MIDIRazorEdits_Analyze'
local semver = require 'lib.semver.semver'

pitchbend.setMIDIUtils(mu)

-- mode registry for standardized dispatch
local modeRegistry = Mode.createRegistry()
modeRegistry:register('slicer', slicer)
modeRegistry:register('pitchbend', pitchbend)

local needsupdate = false
if not r.APIExists('rcw_GetVersion') then
  if r.APIExists('CreateChildWindowForHWND') then
    needsupdate = true
  else
    r.ShowConsoleMsg('For best results, please install the \'childwindow\' extension\nvia ReaPack (also from sockmonkey72).\n')
  end
else
  local rcwVersion = semver(r.rcw_GetVersion())
  if rcwVersion < semver(RCW_MIN_VERSION) then
    needsupdate = true
  end
end
if needsupdate then
  r.ShowConsoleMsg('Please update to the latest version of the \'childwindow\' extension.\nThe older version has been disabled for this run.\n')
end

local Area = classes.Area
local Point = classes.Point
local Rect = classes.Rect
local Extent = classes.Extent
local TimeValueExtents = classes.TimeValueExtents
local MouseMods = classes.MouseMods

local GLOBAL_PREF_SLOP = glob.GLOBAL_PREF_SLOP

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
local OP_SELECT           = 7
local OP_UNSELECT         = 8
local OP_CUT              = 9
local OP_COPY             = 10
local OP_PASTE            = 11
local OP_DELETE_USER      = 12

local OP_STRETCH          = 20 -- behaves a little differently
local OP_STRETCH_DELETE   = 21 -- behaves a little differently

local OP_SHIFTLEFT        = 30
local OP_SHIFTRIGHT       = 31
local OP_SHIFTLEFTGRID    = 32
local OP_SHIFTRIGHTGRID   = 33
local OP_SHIFTLEFTGRIDQ   = 34
local OP_SHIFTRIGHTGRIDQ  = 35
local OP_SHIFTEND         = 40

local OP_SLICE            = slicer.OP_SLICE -- 50

local function isShiftOperation(op)
  return op and op >= OP_SHIFTLEFT and op < OP_SHIFTEND
end

-- misc
local muState
local justLoaded = true

local hottestMods = MouseMods.new()
local currentMods = MouseMods.new()
keys.mod.setMods(currentMods, hottestMods)

local widgetMods

local lastPoint, lastPointQuantized, hasMoved
local wasDragged = false
local wantsQuit = false
local didStartup = false  -- Track if we actually started (for shutdown cleanup)
local wantsPaste = false
local touchedMIDI = false
local noRestore = {} -- if we didn't touch the MIDI or change it significantly, we can avoid a restore

local dragDirection
local areaTickExtent

local analyzeCheckTime = nil
local editorCheckTime = nil
local editorFilterChannels = nil

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

local equalIsh = helper.equalIsh

local clipInt = helper.clipInt

------------------------------------------------
------------------------------------------------

local function getWidgetProcessor(mode)
  local fun = (mode == keys.WIDGET_MODE_PUSHPULL) and helper.scaleValue
           or (mode == keys.WIDGET_MODE_OFFSET) and helper.offsetValue
           or (mode == keys.WIDGET_MODE_COMPEXPMID) and helper.compExpValueMiddle
           or (mode == keys.WIDGET_MODE_COMPEXPTB) and helper.compExpValueTopBottom
  return fun
end

local function callWidgetProcessingMode(val, outputMin, outputMax, offsetFactorStart, offsetFactorEnd, t, inputMin, inputMax)
  local found = false
  local newval
  for k, _ in ipairs(lice.widgetMappings()) do
    if k ~= glob.widgetStretchMode and mod.matchesWidgetMod(k) then
      local fun = getWidgetProcessor(k)
      if fun then
        newval = fun(val, outputMin, outputMax, offsetFactorStart, offsetFactorEnd, t, inputMin, inputMax)
        found = true
      end
      break
    end
  end
  if not found then
    local fun = getWidgetProcessor(glob.widgetStretchMode)
    if fun then
      newval = fun(val, outputMin, outputMax, offsetFactorStart, offsetFactorEnd, t, inputMin, inputMax)
    end
  end
  return newval and math.floor(newval + 0.5)
end

-- delegate to analyze module
local function calculateVisibleRangeWithMargin(scroll, zoom, marginSize, viewHeight, minValue, maxValue)
  return analyze.calculateVisibleRangeWithMargin(scroll, zoom, marginSize, viewHeight, minValue, maxValue)
end

local function getEditorAndSnapWish()
  if mod.getForceSnap() then return true end

  local wantsSnap = r.MIDIEditor_GetSetting_int(glob.liceData.editor, 'snap_enabled') == 1
  if mod.snapMod() then wantsSnap = not wantsSnap end
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
  -- area coords are now relative (0-based)
  if meState.timeBase == 'time' then
    local leftmostTime = meState.leftmostTime + (area.logicalRect.x1 / meState.pixelsPerSecond)
    return r.MIDI_GetPPQPosFromProjTime(glob.liceData.editorTake, leftmostTime - getTimeOffset()), leftmostTime
  else
    return meState.leftmostTick + math.floor((area.logicalRect.x1 / meState.pixelsPerTick) + 0.5)
  end
end

local function updateTimeValueRight(area, leftmost)
  -- area coords are now relative (0-based)
  if meState.timeBase == 'time' then
    leftmost = leftmost or area.timeValue.time.min
    local rightmostTime = meState.leftmostTime + (area.logicalRect.x2 / meState.pixelsPerSecond)
    return r.MIDI_GetPPQPosFromProjTime(glob.liceData.editorTake, rightmostTime - getTimeOffset()), rightmostTime
  else
    leftmost = leftmost or area.timeValue.ticks.min
    return equalIsh(area.logicalRect.x2, area.logicalRect.x1) and leftmost
        or (meState.leftmostTick + math.floor((area.logicalRect.x2 / meState.pixelsPerTick) + 0.5))
  end
end

local function updateTimeValueTop(area)
  local topValue = area.ccLane and meLanes[area.ccLane].topValue or meState.topPitch
  local topPixel = area.ccLane and meLanes[area.ccLane].topPixel or 0  -- relative (0-based)
  local divisor = area.ccLane and meLanes[area.ccLane].pixelsPerValue or meState.pixelsPerPitch

  if area.ccLane or not meState.noteTab then
    return topValue - math.floor(((area.logicalRect.y1 - topPixel) / divisor) + 0.5)
  else
    -- in noteTab mode, topValue is 127 (or less if scrolled)
    local numRows = #meState.noteTab - (127 - meState.topPitch)
    local idx = numRows - math.floor((area.logicalRect.y1 / divisor) + 0.5)  -- y1 is relative
    return math.min(math.max(idx, 1), #meState.noteTab)
  end
end

local function updateTimeValueBottom(area)
  local divisor = area.ccLane and meLanes[area.ccLane].pixelsPerValue or meState.pixelsPerPitch
  if equalIsh(area.logicalRect.y2, area.logicalRect.y1) then return area.timeValue.vals.max end
  if area.ccLane or not meState.noteTab then
    return area.timeValue.vals.max - math.floor((area.logicalRect:height() / divisor) + 0.5) + 1
  else
    -- in noteTab mode, topValue is 127 (or less if scrolled)
    local numRows = #meState.noteTab - (127 - meState.topPitch)
    local idx = numRows - math.floor((area.logicalRect.y2 / divisor) + 0.5) + 1  -- y2 is relative
    return math.min(math.max(idx, 1), #meState.noteTab)
  end
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

  local topValue = area.fullLane and meLanes[area.ccLane and area.ccLane or -1].range or meLanes[area.ccLane and area.ccLane or -1].topValue
  local bottomValue = area.fullLane and 0 or meLanes[area.ccLane and area.ccLane or -1].bottomValue
  local topPixel = area.ccLane and meLanes[area.ccLane].topPixel or 0  -- relative (0-based)
  local divisor = area.ccLane and meLanes[area.ccLane].pixelsPerValue or meState.pixelsPerPitch

  local valMin, valMax
  if area.ccLane or not meState.noteTab then
    valMax = area.fullLane and topValue or (topValue - math.floor(((area.logicalRect.y1 - topPixel) / divisor) + 0.5))
    valMin = area.fullLane and bottomValue or (equalIsh(area.logicalRect.y2, area.logicalRect.y1) and valMax or (valMax - math.floor((area.logicalRect:height() / divisor) + 0.5) + 1))
  else
    -- in noteTab mode, topValue is 127 (or less if scrolled)
    local numRows = #meState.noteTab - (127 - meState.topPitch)
    if area.fullLane then
      valMax = numRows
      valMin = 1-- not sure if this is really what we want
    else
      local idx = numRows - math.floor(((area.logicalRect.y1 - topPixel) / divisor) + 0.5)
      valMax = math.min(math.max(idx, 1), #meState.noteTab)
      idx = numRows - math.floor((area.logicalRect.y2 / divisor) + 0.5) + 1  -- y2 is relative
      valMin = math.min(math.max(idx, 1), #meState.noteTab)
    end
  end
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
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range -- TODO noterow
    end
  elseif resizing == RS_RIGHT then
    area.timeValue.ticks.max = updateTimeValueRight(area)
    _, area.timeValue.ticks.max = quantizeTimeValueTimeExtent(nil, area.timeValue.ticks.max)
    if area.fullLane then
      area.timeValue.vals.min = 0
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range -- TODO noterow
    end
  elseif resizing == RS_TOP then
    if area.fullLane then
      area.timeValue.vals.min = 0
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range -- TODO noterow
    else
      area.timeValue.vals.max = updateTimeValueTop(area)
    end
  elseif resizing == RS_BOTTOM then
    if area.fullLane then
      area.timeValue.vals.min = 0
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range -- TODO noterow
    else
      area.timeValue.vals.min = updateTimeValueBottom(area)
    end
  elseif resizing == RS_MOVEAREA and not force then
    local oldmin = area.timeValue.ticks.min
    local oldtop = area.timeValue.vals.max
    area.timeValue.ticks.min = updateTimeValueLeft(area)
    if area.fullLane then
      area.timeValue.vals.min = 0
      area.timeValue.vals.max = meLanes[area.ccLane and area.ccLane or -1].range -- TODO noterow
    else
      area.timeValue.vals.max = updateTimeValueTop(area)
    end
    local deltaX = area.timeValue.ticks.min - oldmin
    local deltaY = area.fullLane and 0 or area.timeValue.vals.max - oldtop
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

        -- correct for the timebase
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
  end
end

local function updateTimeValueTime(area)
  if meState.timeBase == 'time' then
    if not area.timeValue.time then area.timeValue.time = Extent.new() end
    area.timeValue.time.min = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.editorTake, area.timeValue.ticks.min)
    area.timeValue.time.max = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.editorTake, area.timeValue.ticks.max)
  end
end

updateAreaFromTimeValue = function(area, noCheck)
  if glob.meNeedsRecalc
    and area.ccLane
    and (not meLanes[area.ccLane] or meLanes[area.ccLane].type ~= area.ccType)
  then
    local found = false
    for ccLane = #meLanes, 0, -1 do
      if meLanes[ccLane].type == area.ccType then
        area.ccLane = ccLane -- should check for a collision and delete if it doesn't fit
        found = true
        break
      end
    end
    if not found then
      return false -- should be deleted
    end
  end

  if not noCheck then adjustFullLane(area) end

  if area.timeValue then
    -- area coords are relative (0-based)
    local x1, y1, x2, y2
    if meState.timeBase == 'time' then
      if not area.timeValue.time then
        updateTimeValueTime(area)
      end
      x1 = math.floor(((area.timeValue.time.min - meState.leftmostTime) * meState.pixelsPerSecond) + 0.5)
      x2 = math.floor(((area.timeValue.time.max - meState.leftmostTime) * meState.pixelsPerSecond) + 0.5)
    else
      x1 = math.floor(((area.timeValue.ticks.min - meState.leftmostTick) * meState.pixelsPerTick) + 0.5)
      x2 = math.floor(((area.timeValue.ticks.max - meState.leftmostTick) * meState.pixelsPerTick) + 0.5)
    end
    if area.fullLane then
      -- TODO noterow
      if area.ccLane then
        y1 = math.floor((meLanes[area.ccLane].topPixel - ((meLanes[area.ccLane].range - meLanes[area.ccLane].topValue) * meLanes[area.ccLane].pixelsPerValue)) + 0.5) -- hack RANGE
        y2 = math.floor((meLanes[area.ccLane].bottomPixel + ((meLanes[area.ccLane].bottomValue) * meLanes[area.ccLane].pixelsPerValue)) + 0.5)
      else
        y1 = math.floor(0 - ((meLanes[-1].range - meState.topPitch) * meState.pixelsPerPitch) + 0.5)  -- relative (0-based)
        y2 = math.floor((meLanes[-1].bottomPixel + (meState.bottomPitch * meState.pixelsPerPitch)) + 0.5)
      end
    else
      if meState.noteTab then
        local topPixel = 0  -- relative (0-based)
        local multi = meState.pixelsPerPitch
        -- in noteTab mode, topValue is 127 (or less if scrolled)
        local numRows = #meState.noteTab - (127 - meState.topPitch)
        y1 = math.floor(topPixel + ((numRows - area.timeValue.vals.max) * multi) + 0.5)
        y2 = math.min(math.floor((topPixel + ((numRows - (area.timeValue.vals.min - 1)) * multi)) + 0.5), meLanes[-1].bottomPixel)
      else
        local topPixel = area.ccLane and meLanes[area.ccLane].topPixel or 0  -- relative (0-based)
        local topValue = area.ccLane and meLanes[area.ccLane].topValue or meState.topPitch
        local multi = area.ccLane and meLanes[area.ccLane].pixelsPerValue or meState.pixelsPerPitch
        y1 = math.floor((topPixel + ((topValue - area.timeValue.vals.max) * multi)) + 0.5)
        y2 = math.min(math.floor((topPixel + ((topValue - area.timeValue.vals.min + 1) * multi)) + 0.5), meLanes[area.ccLane or -1].bottomPixel)
      end
    end

    local oldViewRect = area.viewRect and area.viewRect:clone() or nil

    area.logicalRect = Rect.new(x1, y1, x2, y2)
    area.viewRect = lice.viewIntersectionRect(area)

    if not area.viewRect:equals(oldViewRect) then
      area.modified = true
    end
  end
  return true
end

local function makeFullLane(area)
  area.fullLane = true
  updateTimeValueExtentsForArea(area, true, true)
  updateAreaFromTimeValue(area, true)
end

local function updateAreasFromTimeValue(force)
  if glob.meNeedsRecalc or force
  then
    for i = #areas, 1, -1 do
      local area = areas[i]
      if not updateAreaFromTimeValue(area) then
        table.remove(areas, i)
      end
    end
    glob.meNeedsRecalc = false
  end
end

local function resetWidgetMode()
  -- TODO really? 3 variables seems like overkill here. consolidate.
  glob.inWidgetMode = false
  glob.widgetInfo = nil
  glob.changeWidget = nil
end

local processNotesWithGeneration
local clipboardEvents
local tInsertions
local tDeletions
local tDelQueries
local clickedLane
local lastHoveredOrClickedLane

------------------------------------------------
------------------------------------------------

local function pitchInRange(pitch, bottomPitch, topPitch)
  if meState.noteTab then
    if meState.noteTabReverse[pitch] then
      for i = bottomPitch, topPitch do
        if pitch == meState.noteTab[i] then return true end
      end
    end
  else
    return pitch >= bottomPitch and pitch <= topPitch
  end
  return false
end

local DEBUG_COPY = false  -- DEBUG flag for copy mode
local DEBUG_DUPLICATE = false  -- DEBUG flag for duplicate mode
local DEBUG_INVERT = false  -- DEBUG flag for invert mode

local function processNotes(activeTake, area, operation)
  if DEBUG_INVERT and operation == OP_INVERT then
    _P('=== processNotes: OP_INVERT ===')
    _P('  area ticks:', area.timeValue.ticks.min, '-', area.timeValue.ticks.max)
    _P('  area pitch:', area.timeValue.vals.min, '-', area.timeValue.vals.max)
  end

  local ratio = 1.
  local idx = -1
  local movingArea = operation == OP_STRETCH
        and resizing == RS_MOVEAREA
        and (not mod.onlyAreaMod() or area.active)
  local duplicatingArea = movingArea and mod.copyMod()

  -- DEBUG copy mode
  if DEBUG_COPY and duplicatingArea then
    _P('=== COPY MODE ===')
    _P('src area (unstretched): ticks', area.unstretchedTimeValue.ticks.min, '-', area.unstretchedTimeValue.ticks.max,
       'pitch', area.unstretchedTimeValue.vals.min, '-', area.unstretchedTimeValue.vals.max)
    _P('dst area (timeValue): ticks', area.timeValue.ticks.min, '-', area.timeValue.ticks.max,
       'pitch', area.timeValue.vals.min, '-', area.timeValue.vals.max)
    _P('insertMode:', glob.insertMode)
  end

  local stretchingArea = operation == OP_STRETCH
        and mod.stretchMod()
        and area.active
        and resizing > RS_UNCLICKED and resizing < RS_MOVEAREA
  local deltaTicks, deltaPitch

  local sourceInfo = area.sourceInfo[activeTake]

  if sourceInfo.skip then return end

  local itemInfo = glob.liceData.itemInfo[activeTake]
  local timeValue = area.timeValue:clone()
  timeValue.ticks:shift(-itemInfo.offsetPPQ)

  local unstretchedTimeValue = area.unstretchedTimeValue and area.unstretchedTimeValue:clone() or nil
  if unstretchedTimeValue then unstretchedTimeValue.ticks:shift(-itemInfo.offsetPPQ) end

  local sourceEvents = sourceInfo.sourceEvents
  local usingUnstretched = sourceInfo.usingUnstretched

  -- DEBUG sourceEvents
  if DEBUG_COPY and duplicatingArea then
    _P('sourceEvents count:', #sourceEvents)
    for i, ev in ipairs(sourceEvents) do
      _P('  src note', i, ': idx', ev.idx, 'ppq', ev.ppqpos, '-', ev.endppqpos, 'pitch', ev.pitch)
    end
  end

  if movingArea then
    deltaTicks = area.timeValue.ticks.min - area.unstretchedTimeValue.ticks.min
    deltaPitch = -(area.timeValue.vals.min - area.unstretchedTimeValue.vals.min)

    deltaTicks = math.floor(deltaTicks + 0.5)
    deltaPitch = math.floor(deltaPitch + 0.5)
  end

  if operation == OP_STRETCH and area.unstretched and (not mod.singleMod() or area.active) then
    local denom = area.unstretchedTimeValue.ticks:size()
    if denom == 0 then return end
    ratio = area.timeValue.ticks:size() / denom
    usingUnstretched = true
    if ratio == 1 and resizing < RS_MOVEAREA then return end
  end

  local leftmostTick, rightmostTick, topPitch, bottomPitch
  local areaLeftmostTick = math.floor(timeValue.ticks.min + 0.5)
  local areaRightmostTick = math.floor(timeValue.ticks.max + 0.5)

  if usingUnstretched then
    leftmostTick = sourceInfo.leftmostTick
    rightmostTick = sourceInfo.rightmostTick
    topPitch = sourceInfo.topValue
    bottomPitch = sourceInfo.bottomValue
  else
    leftmostTick = areaLeftmostTick
    rightmostTick = areaRightmostTick
    topPitch = timeValue.vals.max
    bottomPitch = timeValue.vals.min
  end

  local skipiter = false
  local widgeting = false
  local slicing = false

  if glob.widgetInfo and area == glob.widgetInfo.area then
    if glob.widgetInfo.sourceEvents[activeTake] then
      skipiter = true
    end
    widgeting = true
  elseif slicer.getSlicerPoints() then
    skipiter = true
    slicing = true
  end

  local insert = false

  -- potential second iteration, deal with deletions in the target area
  if operation == OP_COPY or operation == OP_CUT then
    area.onClipboard = true --area.ccLane and lastHoveredOrClickedLane == area.ccLane or lastHoveredOrClickedLane == -1
    if area.onClipboard then
      local events
      for _, ev in ipairs(clipboardEvents) do
        if ev.ref == area then
          events = ev
          break
        end
      end
      if not events then
        events = { ref = area, area = area:clone(), events = {} }
        table.insert(clipboardEvents, events)
      end
      events.events[activeTake] = sourceEvents

      if operation == OP_CUT then
        local tmpArea = Area.new(area:serialize()) -- only used for event selection
        processNotesWithGeneration(activeTake, tmpArea, OP_DELETE_USER)
      end
    end
    skipiter = true
  elseif wantsPaste or operation == OP_PASTE then
    skipiter = true
  elseif operation == OP_DUPLICATE then
    local tmpArea = Area.new(area:serialize()) -- OP_DELETE_TRIM will use this area for the deletion itself (in addition to event selection)
    tmpArea.timeValue.ticks:shift(areaTickExtent:size())
    if DEBUG_DUPLICATE then
      _P('--- OP_DUPLICATE: calling OP_DELETE_TRIM ---')
      _P('  original area ticks:', area.timeValue.ticks.min, '-', area.timeValue.ticks.max)
      _P('  shifted tmpArea ticks:', tmpArea.timeValue.ticks.min, '-', tmpArea.timeValue.ticks.max)
      _P('  areaTickExtent:', areaTickExtent.min, '-', areaTickExtent.max, 'size:', areaTickExtent:size())
    end
    processNotesWithGeneration(activeTake, tmpArea, OP_DELETE_TRIM)
  elseif movingArea then
     if deltaTicks ~= 0 or deltaPitch ~= 0 then
      -- for move: delete union of source+dest (notes move from source to dest)
      -- for copy: skip area-based deletion, segment dest notes around copy positions below
      local deletionExtents = not duplicatingArea
        and helper.getExtentUnion(area.timeValue, area.unstretchedTimeValue)
        or {}  -- for copy: handled after sourceEvents loop

      -- DEBUG deletion extents
      if DEBUG_COPY then
        _P('--- DELETION EXTENT LOGIC ---')
        _P('movingArea:', movingArea, 'duplicatingArea:', duplicatingArea)
        _P('glob.insertMode:', glob.insertMode)
        _P('deletionExtents count:', #deletionExtents)
        for i, ext in ipairs(deletionExtents) do
          _P('  extent', i, ': ticks', ext.ticks.min, '-', ext.ticks.max, 'vals', ext.vals.min, '-', ext.vals.max)
        end
      end

      local tmpArea = Area.new(area:serialize()) -- only used for event selection
      tmpArea.unstretched, tmpArea.unstretchedTimeValue = nil, nil
      if not glob.insertMode then
        if DEBUG_COPY then
          _P('NOT insertMode - processing deletions')
        end
        -- create temporary areas from deletion extents for segment calculation
        -- this ensures getNoteSegments uses the correct extents (merged or separate)
        -- instead of glob.areas which always has both source+dest merged
        glob.deletionAreas = {}
        for _, extent in ipairs(deletionExtents) do
          local delArea = Area.new(area:serialize())
          delArea.timeValue = extent
          delArea.unstretched, delArea.unstretchedTimeValue = nil, nil
          table.insert(glob.deletionAreas, delArea)
        end
        for _, extent in ipairs(deletionExtents) do
          tmpArea.timeValue = extent
          if DEBUG_COPY then
            _P('  calling processNotesWithGeneration OP_DELETE for extent ticks', extent.ticks.min, '-', extent.ticks.max)
          end
          processNotesWithGeneration(activeTake, tmpArea, OP_DELETE, mod.overlapMod() and sourceEvents)
        end
        glob.deletionAreas = nil
      else
        if DEBUG_COPY then
          _P('insertMode ON - SKIPPING deletions')
        end
      end
      insert = true -- won't do anything anymore because we pre-process
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
  if wantsPaste or operation == OP_COPY or operation == OP_CUT or operation == OP_PASTE or operation == OP_SELECT or operation == OP_UNSELECT then
    process = false
  end

  if not skipiter then

  if DEBUG_INVERT and operation == OP_INVERT then
    _P('sourceEvents count:', #sourceEvents)
    for i, ev in ipairs(sourceEvents) do
      _P('  source', i, ': idx', ev.idx, 'ppq', ev.ppqpos, '-', ev.endppqpos, 'pitch', ev.pitch)
    end
  end

  for sidx, event in ipairs(sourceEvents) do
    local selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel = event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.pitch, event.vel, event.relvel
    local newppqpos, newendppqpos, newpitch

    idx = event.idx

    local function trimOverlappingNotes()
      local canOperate = true

      if ppqpos + GLOBAL_PREF_SLOP < rightmostTick and endppqpos - GLOBAL_PREF_SLOP >= leftmostTick then
        if ppqpos < leftmostTick  then
          if not mod.overlapMod() then
            if DEBUG_DUPLICATE and operation == OP_DELETE_TRIM then
              _P('    trimOverlappingNotes: creating LEFT segment', ppqpos, '-', leftmostTick, 'pitch', pitch)
            end
            if DEBUG_INVERT and operation == OP_INVERT then
              _P('    trimOverlappingNotes: creating LEFT segment', ppqpos, '-', leftmostTick, 'pitch', pitch)
            end
            helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = ppqpos, endppqpos = leftmostTick, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
          else
            canOperate = false
          end
        end
        if endppqpos > rightmostTick then
          if not mod.overlapMod() then
            if DEBUG_DUPLICATE and operation == OP_DELETE_TRIM then
              _P('    trimOverlappingNotes: creating RIGHT segment', rightmostTick, '-', endppqpos, 'pitch', pitch)
            end
            if DEBUG_INVERT and operation == OP_INVERT then
              _P('    trimOverlappingNotes: creating RIGHT segment', rightmostTick, '-', endppqpos, 'pitch', pitch)
            end
            helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = rightmostTick, endppqpos = endppqpos, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
          else
            canOperate = false
          end
        end
      end
      return canOperate
    end

    local overlapped = mod.overlapMod()

    if DEBUG_DUPLICATE and operation == OP_DELETE_TRIM then
      local inRange = endppqpos > leftmostTick and ppqpos < rightmostTick and pitchInRange(pitch, bottomPitch, topPitch)
      _P('  note idx', idx, ': ppq', ppqpos, '-', endppqpos, 'pitch', pitch)
      _P('    leftmostTick:', leftmostTick, 'rightmostTick:', rightmostTick)
      _P('    endppqpos > leftmostTick:', endppqpos > leftmostTick, 'ppqpos < rightmostTick:', ppqpos < rightmostTick)
      _P('    inRange:', inRange)
    end
    if endppqpos > leftmostTick and ppqpos < rightmostTick
      and pitchInRange(pitch, bottomPitch, topPitch)
    then
      if operation == OP_SELECT or operation == OP_UNSELECT then
        mu.MIDI_SetNote(activeTake, idx, not (operation == OP_UNSELECT) and true or false, nil, nil, nil, nil, nil)
        touchedMIDI = true
      elseif operation == OP_INVERT then
        if DEBUG_INVERT then
          _P('--- OP_INVERT: note idx', idx, '---')
          _P('  original: ppq', ppqpos, '-', endppqpos, 'pitch', pitch)
          _P('  area bounds: leftTick', leftmostTick, 'rightTick', rightmostTick)
          _P('  area pitch: min', area.timeValue.vals.min, 'max', area.timeValue.vals.max)
          _P('  overlapped:', overlapped)
        end
        trimOverlappingNotes()
        newppqpos = (overlapped or ppqpos >= leftmostTick) and ppqpos or leftmostTick
        newendppqpos = (overlapped or endppqpos <= rightmostTick) and endppqpos or rightmostTick
        if meState.noteTab then
          local newidx = area.timeValue.vals.max - (meState.noteTabReverse[pitch] - area.timeValue.vals.min)
          newpitch = meState.noteTab[newidx]
        else
          newpitch = area.timeValue.vals.max - (pitch - area.timeValue.vals.min)
        end
        if DEBUG_INVERT then
          _P('  -> new: ppq', newppqpos, '-', newendppqpos, 'pitch', newpitch)
        end
      elseif operation == OP_RETROGRADE then
        trimOverlappingNotes()
        local firstppq = sourceEvents[1].ppqpos
        local lastendppq = sourceEvents[#sourceEvents].endppqpos
        if not overlapped and firstppq < leftmostTick then firstppq = leftmostTick end
        if not overlapped and lastendppq > rightmostTick then lastendppq = rightmostTick end

        local thisppqpos = (not overlapped and ppqpos < leftmostTick) and leftmostTick or ppqpos
        local thisendppqpos = (not overlapped and endppqpos > rightmostTick) and rightmostTick or endppqpos
        local delta = (firstppq - leftmostTick) - (rightmostTick - lastendppq)

        if not overlapped then
          newppqpos = (rightmostTick - ((thisppqpos >= leftmostTick and thisppqpos or leftmostTick) - leftmostTick)) - (thisendppqpos - thisppqpos) + delta
        else
          newppqpos = firstppq + (lastendppq - thisendppqpos) - delta
        end
        newendppqpos = newppqpos + (thisendppqpos - thisppqpos)
      elseif operation == OP_RETROGRADE_VALS then
        trimOverlappingNotes()
        newppqpos = (overlapped or ppqpos >= leftmostTick) and ppqpos or leftmostTick
        newendppqpos = (overlapped or endppqpos <= rightmostTick) and endppqpos or rightmostTick
        newpitch = sourceEvents[#sourceEvents - (sidx - 1)].pitch
      elseif operation == OP_DUPLICATE then
        helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = (ppqpos >= leftmostTick and ppqpos or leftmostTick) + areaTickExtent:size(),
                          endppqpos = (endppqpos <= rightmostTick and endppqpos or rightmostTick) + areaTickExtent:size(), chan = chan, pitch = pitch, vel = vel, relvel = relvel })
      elseif operation == OP_DELETE_USER or operation == OP_DELETE or operation == OP_STRETCH_DELETE or operation == OP_DELETE_TRIM then
        local deleteOrig = true
        local isOverlapped = operation == OP_DELETE_USER and overlapped

        if operation == OP_DELETE_TRIM then
          deleteOrig = trimOverlappingNotes() -- this screws up most operations, but is necessary for OP_DUPLICATE
          if DEBUG_DUPLICATE then
            _P('    after trimOverlappingNotes: deleteOrig =', deleteOrig)
          end
        end

        -- don't unnecessarily repeat this calculation if we've already done it
        -- for OP_DELETE during move/copy, use glob.deletionAreas (the actual deletion extents)
        -- instead of glob.areas which always has both source+dest that get merged incorrectly
        -- skip getNoteSegments for OP_DELETE_TRIM since trimOverlappingNotes already handles it
        if operation ~= OP_DELETE_TRIM and not isOverlapped and helper.addUnique(tDelQueries, { ppqpos = ppqpos, endppqpos = endppqpos, pitch = pitch, op = operation }) then
          local areasForSegments = (operation == OP_DELETE and glob.deletionAreas) or areas
          local onlyArea = nil -- was: operation == OP_DELETE_TRIM and area or nil
          local segments = helper.getNoteSegments(areasForSegments, itemInfo, ppqpos, endppqpos, pitch, onlyArea)
          if DEBUG_DUPLICATE and operation == OP_DELETE_TRIM then
            _P('    getNoteSegments returned:', segments and #segments or 'nil', 'segments')
            if segments then
              for si, seg in ipairs(segments) do
                _P('      segment', si, ':', seg[1], '-', seg[2])
              end
            end
          end
          if segments then
            for _, seg in ipairs(segments) do
              local newEvent = mu.tableCopy(event)
              newEvent.ppqpos = seg[1]
              newEvent.endppqpos = seg[2]
              newEvent.pitch = pitch
              newEvent.type = mu.NOTE_TYPE
              helper.addUnique(tInsertions, newEvent)
              deleteOrig = true
            end
          end
        end
        if isOverlapped or deleteOrig then
          if DEBUG_DUPLICATE and operation == OP_DELETE_TRIM then
            _P('    DELETING note idx', idx)
          end
          helper.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = idx })
        end
      elseif not mod.singleMod() or ppqpos >= leftmostTick then
        if stretchingArea then
          if resizing ~= RS_MOVEAREA
            and mod.stretchMod()
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
              helper.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = idx })
            end
          end
        end

        if movingArea or duplicatingArea then
          -- for move (not copy), preserve note segments outside the source area
          if movingArea and not duplicatingArea then
            local segments = not event.segments and helper.getNoteSegments(areas, itemInfo, newppqpos or ppqpos, newendppqpos or endppqpos, newpitch or pitch, nil)
            if segments then -- should only be done once per full iter, in fact, since these are the segments for all areas
              for _, seg in ipairs(segments) do
                helper.addUnique(tInsertions,
                                { type = mu.NOTE_TYPE,
                                  selected = selected, muted = muted,
                                  ppqpos = seg[1],
                                  endppqpos = seg[2],
                                  chan = chan, pitch = newpitch or pitch,
                                  vel = vel, relvel = relvel }
                                )
              end
              event.segments = segments
            end
          end
          -- for copy: check if copied note position overlaps original note position
          -- only segment/delete original if there's actual overlap (same pitch conflict)
          if duplicatingArea then
            -- compute actual copy position (with area clipping)
            local copyPpqpos = (ppqpos + deltaTicks < areaLeftmostTick and not overlapped) and areaLeftmostTick or ppqpos + deltaTicks
            local copyEndppqpos = (endppqpos + deltaTicks > areaRightmostTick and not overlapped) and areaRightmostTick or endppqpos + deltaTicks
            -- check if copy overlaps original (would create same-pitch overlap)
            -- use <= and >= because endppqpos is inclusive
            -- also check deltaPitch == 0, otherwise copy is at different pitch (no collision)
            local copyOverlapsOriginal = deltaPitch == 0 and copyPpqpos <= endppqpos and copyEndppqpos >= ppqpos

            if DEBUG_COPY then
              _P('--- SOURCE NOTE COPY OVERLAP CHECK ---')
              _P('  source note idx', idx, ': ppq', ppqpos, '-', endppqpos, 'pitch', pitch)
              _P('  copy position: ppq', copyPpqpos, '-', copyEndppqpos)
              _P('  copyOverlapsOriginal:', copyOverlapsOriginal)
            end

            if copyOverlapsOriginal then
              if DEBUG_COPY then
                _P('  -> OVERLAP DETECTED, insertMode:', glob.insertMode)
              end
              -- only create segments to preserve source note portions when in insertMode
              if glob.insertMode then
                if ppqpos < copyPpqpos then
                  local segEnd = copyPpqpos - 1
                  local len = segEnd - ppqpos + 1
                  if len >= GLOBAL_PREF_SLOP then
                    if DEBUG_COPY then
                      _P('    inserting left segment: ppq', ppqpos, '-', segEnd)
                    end
                    helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted,
                      ppqpos = ppqpos, endppqpos = segEnd, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
                  end
                end
                if endppqpos > copyEndppqpos then
                  local segStart = copyEndppqpos + 1
                  local len = endppqpos - segStart + 1
                  if len >= GLOBAL_PREF_SLOP then
                    if DEBUG_COPY then
                      _P('    inserting right segment: ppq', segStart, '-', endppqpos)
                    end
                    helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted,
                      ppqpos = segStart, endppqpos = endppqpos, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
                  end
                end
              else
                -- NOT insertMode - create segments around DEST AREA bounds
                -- (portions of original outside dest area should remain visible)
                if DEBUG_COPY then
                  _P('    NOT insertMode - creating segments around dest area bounds')
                end
                if ppqpos < areaLeftmostTick then
                  local segEnd = areaLeftmostTick - 1
                  local len = segEnd - ppqpos + 1
                  if len >= GLOBAL_PREF_SLOP then
                    if DEBUG_COPY then
                      _P('    inserting left segment: ppq', ppqpos, '-', segEnd)
                    end
                    helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted,
                      ppqpos = ppqpos, endppqpos = segEnd, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
                  end
                end
                if endppqpos > areaRightmostTick then
                  local segStart = areaRightmostTick + 1
                  local len = endppqpos - segStart + 1
                  if len >= GLOBAL_PREF_SLOP then
                    if DEBUG_COPY then
                      _P('    inserting right segment: ppq', segStart, '-', endppqpos)
                    end
                    helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted,
                      ppqpos = segStart, endppqpos = endppqpos, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
                  end
                end
              end
              if DEBUG_COPY then
                _P('    DELETING original source note idx', idx)
              end
              helper.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = idx })
            elseif not glob.insertMode then
              -- copy doesn't overlap original, but source note may still be in dest area
              -- in non-insertMode, segment source notes around dest area bounds
              -- use timeValue pitch range (dest area), not sourceInfo pitch range
              local destBottomPitch = math.floor(timeValue.vals.min + 0.5)
              local destTopPitch = math.floor(timeValue.vals.max + 0.5)
              local inDestArea = endppqpos > areaLeftmostTick and ppqpos < areaRightmostTick
                and pitchInRange(pitch, destBottomPitch, destTopPitch)
              if DEBUG_COPY then
                _P('  checking if source note in dest area:')
                _P('    ppqpos', ppqpos, 'endppqpos', endppqpos, 'pitch', pitch)
                _P('    areaLeftmostTick', areaLeftmostTick, 'areaRightmostTick', areaRightmostTick)
                _P('    destBottomPitch', destBottomPitch, 'destTopPitch', destTopPitch)
                _P('    inDestArea:', inDestArea)
              end
              if inDestArea then
                if DEBUG_COPY then
                  _P('  -> SOURCE NOTE IN DEST AREA, deleting and segmenting')
                end
                -- create segments for portions outside dest area
                if ppqpos < areaLeftmostTick then
                  local segEnd = areaLeftmostTick - 1
                  local len = segEnd - ppqpos + 1
                  if len >= GLOBAL_PREF_SLOP then
                    if DEBUG_COPY then
                      _P('    inserting left segment: ppq', ppqpos, '-', segEnd)
                    end
                    helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted,
                      ppqpos = ppqpos, endppqpos = segEnd, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
                  end
                end
                if endppqpos > areaRightmostTick then
                  local segStart = areaRightmostTick + 1
                  local len = endppqpos - segStart + 1
                  if len >= GLOBAL_PREF_SLOP then
                    if DEBUG_COPY then
                      _P('    inserting right segment: ppq', segStart, '-', endppqpos)
                    end
                    helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted,
                      ppqpos = segStart, endppqpos = endppqpos, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
                  end
                end
                helper.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = idx })
              end
            end
          end
          if meState.noteTab then
            local pitchidx = meState.noteTabReverse[pitch]
            if not pitchidx then
              _P('fatal error')
              newpitch = pitch
            else
              local save = pitchidx
              pitchidx = pitchidx - deltaPitch
              pitchidx = math.min(math.max(pitchidx, 1), #meState.noteTab)
              newpitch = meState.noteTab[pitchidx]
            end
          else
            newpitch = pitch - deltaPitch
          end
          local copyPpqpos = (ppqpos + deltaTicks < areaLeftmostTick and not mod.overlapMod()) and areaLeftmostTick or ppqpos + deltaTicks
          local copyEndppqpos = (endppqpos + deltaTicks > areaRightmostTick and not mod.overlapMod()) and areaRightmostTick or endppqpos + deltaTicks

          if DEBUG_COPY then
            _P('--- ADDING COPIED NOTE ---')
            _P('  from source idx', idx, 'pitch', pitch, 'ppq', ppqpos, '-', endppqpos)
            _P('  to dest pitch', newpitch, 'ppq', copyPpqpos, '-', copyEndppqpos)
          end

          helper.addUnique(tInsertions,
                          { type = mu.NOTE_TYPE,
                            selected = selected, muted = muted,
                            ppqpos = copyPpqpos,
                            endppqpos = copyEndppqpos,
                            chan = chan, pitch = newpitch,
                            vel = vel, relvel = relvel }
                          )
          if not glob.insertMode and mod.overlapMod() then
            if DEBUG_COPY then
              _P('  overlapMod + !insertMode -> DELETING source note idx', idx)
            end
            helper.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = idx })
          end
        end
      end

      if process then
        if duplicatingArea then
          if newppqpos and newendppqpos then
            helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = newppqpos, endppqpos = newendppqpos, chan = chan, pitch = newpitch or pitch, vel = vel, relvel = relvel })
          end
        else
          if newppqpos and newendppqpos and newppqpos < newendppqpos then
            if newendppqpos - newppqpos > GLOBAL_PREF_SLOP then
              if insert then -- only called for stretching
                local segments = not event.segments and helper.getNoteSegments(areas, itemInfo, newppqpos or ppqpos, newendppqpos or endppqpos, newpitch or pitch, nil, meState)
                if segments then -- should only be done once per full iter, in fact, since these are the segments for all areas
                  for _, seg in ipairs(segments) do
                    helper.addUnique(tInsertions,
                                    { type = mu.NOTE_TYPE,
                                      selected = selected, muted = muted,
                                      ppqpos = seg[1],
                                      endppqpos = seg[2],
                                      chan = chan, pitch = newpitch or pitch,
                                      vel = vel, relvel = relvel }
                                    )
                  end
                  event.segments = segments
                end
                helper.addUnique(tInsertions,
                                { type = mu.NOTE_TYPE,
                                  selected = selected, muted = muted,
                                  ppqpos = newppqpos or ppqpos,
                                  endppqpos = newendppqpos or endppqpos,
                                  chan = chan, pitch = newpitch or pitch,
                                  vel = vel, relvel = relvel }
                                )
              else
                if DEBUG_INVERT and operation == OP_INVERT then
                  _P('  -> MIDI_SetNote idx', idx, ': ppq', newppqpos, '-', newendppqpos, 'pitch', newpitch)
                end
                mu.MIDI_SetNote(activeTake, idx, selected, nil, newppqpos, newendppqpos, nil, newpitch)
                touchedMIDI = true
              end
            else
              -- TODO: I don't think this is reachable anymore
              if DEBUG_INVERT and operation == OP_INVERT then
                _P('  -> MIDI_DeleteNote idx', idx, '(note too short)')
              end
              mu.MIDI_DeleteNote(activeTake, idx)
              touchedMIDI = true
            end
          end
        end
      end
    end
  end
  end

  if DEBUG_INVERT and operation == OP_INVERT then
    _P('=== INVERT SUMMARY ===')
    _P('  tInsertions count:', #tInsertions)
    for i, ins in ipairs(tInsertions) do
      if ins.type == mu.NOTE_TYPE then
        _P('    insert', i, ': ppq', ins.ppqpos, '-', ins.endppqpos, 'pitch', ins.pitch)
      end
    end
    _P('  tDeletions count:', #tDeletions)
    for i, del in ipairs(tDeletions) do
      _P('    delete', i, ': idx', del.idx)
    end
    _P('=== END INVERT ===')
  end

  -- for copy: segment dest notes (not in sourceEvents) around the copy positions
  if duplicatingArea then
    -- DEBUG
    if DEBUG_COPY then
      _P('--- DEST AREA PROCESSING ---')
      _P('insertMode:', glob.insertMode)
      _P('areaLeftmostTick:', areaLeftmostTick, 'areaRightmostTick:', areaRightmostTick)
      _P('bottomPitch:', bottomPitch, 'topPitch:', topPitch)
    end

    -- build set of sourceEvents indices to exclude
    local sourceIdxSet = {}
    for _, ev in ipairs(sourceEvents) do
      if ev.idx then sourceIdxSet[ev.idx] = true end
    end
    -- collect copy positions from tInsertions (notes added during sourceEvents loop)
    local copyPositions = {}
    for _, ins in ipairs(tInsertions) do
      if ins.type == mu.NOTE_TYPE and ins.ppqpos and ins.endppqpos then
        table.insert(copyPositions, ins)
      end
    end

    -- DEBUG
    if DEBUG_COPY then
      _P('copyPositions count:', #copyPositions)
      for i, cp in ipairs(copyPositions) do
        _P('  copy', i, ': ppq', cp.ppqpos, '-', cp.endppqpos, 'pitch', cp.pitch)
      end
    end

    -- enumerate all notes at dest and segment those that overlap copies
    local idx = -1
    while true do
      idx = mu.MIDI_EnumNotes(activeTake, idx)
      if not idx or idx == -1 then break end
      if not sourceIdxSet[idx] then  -- skip sourceEvents notes (already handled)
        local _, sel, muted, ppqpos, endppqpos, chan, pitch, vel, relvel = mu.MIDI_GetNote(activeTake, idx)
        -- check if this note overlaps dest area (timeValue)
        local destLeft = math.floor(areaLeftmostTick + 0.5)
        local destRight = math.floor(areaRightmostTick + 0.5)
        -- use dest area pitch range, not source area pitch range
        local destBottomPitch = math.floor(timeValue.vals.min + 0.5)
        local destTopPitch = math.floor(timeValue.vals.max + 0.5)

        -- DEBUG: show all notes being considered
        if DEBUG_COPY then
          local inDest = endppqpos > destLeft and ppqpos < destRight and pitchInRange(pitch, destBottomPitch, destTopPitch)
          _P('  note idx', idx, ': ppq', ppqpos, '-', endppqpos, 'pitch', pitch, 'inDestArea:', inDest, 'isSourceNote:', sourceIdxSet[idx] or false)
        end

        if endppqpos > destLeft and ppqpos < destRight
          and pitchInRange(pitch, destBottomPitch, destTopPitch)
        then
          -- find all copies that overlap this note (same pitch)
          local overlappingCopies = {}
          for _, cp in ipairs(copyPositions) do
            if cp.pitch == pitch and cp.ppqpos <= endppqpos and cp.endppqpos >= ppqpos then
              table.insert(overlappingCopies, cp)
            end
          end
          -- DEBUG
          if DEBUG_COPY then
            _P('    -> in dest area, overlappingCopies:', #overlappingCopies)
          end

          -- insertMode: only process notes that overlap with copies (segment around copies)
          -- non-insertMode: process all notes in dest area (segment around dest bounds)
          if glob.insertMode then
            if #overlappingCopies > 0 then
              -- insertMode: segment around copy positions
              local segments = {}
              table.sort(overlappingCopies, function(a, b) return a.ppqpos < b.ppqpos end)
              local segStart = ppqpos
              for _, cp in ipairs(overlappingCopies) do
                if segStart < cp.ppqpos then
                  local segEnd = cp.ppqpos - 1
                  if segEnd - segStart + 1 >= GLOBAL_PREF_SLOP then
                    table.insert(segments, {segStart, segEnd})
                  end
                end
                segStart = math.max(segStart, cp.endppqpos + 1)
              end
              -- final segment after last copy
              if segStart <= endppqpos then
                local segEnd = endppqpos
                if segEnd - segStart + 1 >= GLOBAL_PREF_SLOP then
                  table.insert(segments, {segStart, segEnd})
                end
              end
              if DEBUG_COPY then
                _P('    -> insertMode: SEGMENTING around copy positions')
                _P('    -> creating', #segments, 'segments, DELETING original')
                for si, seg in ipairs(segments) do
                  _P('       segment', si, ':', seg[1], '-', seg[2])
                end
              end
              for _, seg in ipairs(segments) do
                helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = sel, muted = muted,
                  ppqpos = seg[1], endppqpos = seg[2], chan = chan, pitch = pitch, vel = vel, relvel = relvel })
              end
              helper.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = idx })
            else
              -- insertMode but no overlapping copies - skip this note entirely
              if DEBUG_COPY then
                _P('    -> insertMode: no overlapping copies, SKIPPING note')
              end
            end
          else
            -- non-insertMode: segment around dest area bounds only
            local segments = {}
            if ppqpos < destLeft then
              local segEnd = destLeft - 1
              if segEnd - ppqpos + 1 >= GLOBAL_PREF_SLOP then
                table.insert(segments, {ppqpos, segEnd})
              end
            end
            if endppqpos > destRight then
              local segStart = destRight + 1
              if endppqpos - segStart + 1 >= GLOBAL_PREF_SLOP then
                table.insert(segments, {segStart, endppqpos})
              end
            end
            if DEBUG_COPY then
              _P('    -> non-insertMode: SEGMENTING around dest area bounds')
              _P('    -> creating', #segments, 'segments, DELETING original')
              for si, seg in ipairs(segments) do
                _P('       segment', si, ':', seg[1], '-', seg[2])
              end
            end
            for _, seg in ipairs(segments) do
              helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = sel, muted = muted,
                ppqpos = seg[1], endppqpos = seg[2], chan = chan, pitch = pitch, vel = vel, relvel = relvel })
            end
            helper.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = idx })
          end
        end
      end
    end
  end

  -- outside of the enumeration
  if widgeting and glob.widgetInfo and glob.widgetInfo.sourceEvents[activeTake] then
    for _, event in ipairs(glob.widgetInfo.sourceEvents[activeTake]) do
      local val = event.vel
      local newval = callWidgetProcessingMode(val, 1, 127,
                                              area.widgetExtents.min, area.widgetExtents.max,
                                              (event.ppqpos - area.timeValue.ticks.min) / (area.timeValue.ticks.max - area.timeValue.ticks.min),
                                              glob.widgetInfo.sourceMin[activeTake], glob.widgetInfo.sourceMax[activeTake])
      if newval then
        mu.MIDI_SetNote(activeTake, event.idx, nil, nil, nil, nil, nil, nil, newval, nil)
        touchedMIDI = true
      end
    end
  elseif slicing then
    if slicer.processNotes(activeTake, area, { mu = mu, sourceEvents = sourceEvents, tInsertions = tInsertions, tDeletions = tDeletions }) then
      touchedMIDI = true
    end
  end

  -- DEBUG: summary of final insertions and deletions
  if DEBUG_COPY and duplicatingArea then
    _P('=== FINAL COPY SUMMARY ===')
    _P('tDeletions count:', #tDeletions)
    for i, del in ipairs(tDeletions) do
      _P('  delete', i, ': idx', del.idx)
    end
    _P('tInsertions count:', #tInsertions)
    for i, ins in ipairs(tInsertions) do
      if ins.type == mu.NOTE_TYPE then
        _P('  insert', i, ': ppq', ins.ppqpos, '-', ins.endppqpos, 'pitch', ins.pitch)
      end
    end
    _P('=== END COPY ===')
  end
end

local processCCsWithGeneration

local function laneIsVelocity(area)
  return area.ccLane and (meLanes[area.ccLane].type == 0x200 or meLanes[area.ccLane].type == 0x207)
end

local function addControlPoints(activeTake, area)
  if glob.wantsControlPoints and
    area.ccLane
    and not laneIsVelocity(area)
    and not area.controlPoints
    and area.sourceInfo[activeTake].sourceEvents
    and #area.sourceInfo[activeTake].sourceEvents ~= 0
  then
    local newEvent
    local cp1, cp2, cp3, cp4
    local sourceInfo = area.sourceInfo[activeTake]
    local sourceEvents = sourceInfo.sourceEvents

    if sourceInfo.potentialControlPoints and #sourceInfo.potentialControlPoints == 4 then
      area.controlPoints = {}
      return
    end

    newEvent = mu.tableCopy(sourceEvents[1])
    local rv, _, _, _, _, msg2out, msg3out = mu.MIDI_GetCCValueAtTime(activeTake, newEvent.chanmsg, newEvent.chan, newEvent.msg2, area.timeValue.ticks.min, true)
    if rv then
      newEvent.ppqpos = area.timeValue.ticks.min - 1
      newEvent.msg2 = msg2out
      newEvent.msg3 = msg3out
      cp1 = newEvent
    end

    newEvent = mu.tableCopy(sourceEvents[1])
    newEvent.ppqpos = area.timeValue.ticks.min
    cp2 = newEvent

    newEvent = mu.tableCopy(sourceEvents[#sourceEvents])
    newEvent.ppqpos = area.timeValue.ticks.max
    cp3 = newEvent

    newEvent = mu.tableCopy(sourceEvents[#sourceEvents])
    rv, _, _, _, _, msg2out, msg3out = mu.MIDI_GetCCValueAtTime(activeTake, newEvent.chanmsg, newEvent.chan, newEvent.msg2, area.timeValue.ticks.max, true)
    if rv then
      newEvent.ppqpos = area.timeValue.ticks.max + 1
      newEvent.msg2 = msg2out
      newEvent.msg3 = msg3out
      cp4 = newEvent
    end

    area.controlPoints = { cp1, cp2, cp3, cp4 }
  end
end

local function processCCs(activeTake, area, operation)
  local hratio, vratio = 1., 1.
  -- local insertions = {}
  -- local removals = {}
  local idx = -1
  local movingArea = operation == OP_STRETCH
        and resizing == RS_MOVEAREA
        and (not mod.onlyAreaMod() or area.active)
  local duplicatingArea = movingArea and mod.copyMod()
  local stretchingArea = operation == OP_STRETCH
        and mod.stretchMod()
        and area.active
        and resizing > RS_UNCLICKED and resizing < RS_MOVEAREA
  local deltaTicks, deltaVal

  local sourceInfo = area.sourceInfo[activeTake]

  if sourceInfo.skip then return end

  local itemInfo = glob.liceData.itemInfo[activeTake]
  local timeValue = area.timeValue:clone()
  timeValue.ticks:shift(-itemInfo.offsetPPQ)

  local unstretchedTimeValue = area.unstretchedTimeValue and area.unstretchedTimeValue:clone() or nil
  if unstretchedTimeValue then unstretchedTimeValue.ticks:shift(-itemInfo.offsetPPQ) end

  local sourceEvents = sourceInfo.sourceEvents
  local usingUnstretched = sourceInfo.usingUnstretched

  local pixelsPerValue = meLanes[area.ccLane].pixelsPerValue
  local ccType = meLanes[area.ccLane].type

  local laneIsVel = laneIsVelocity(area)
  local isRelVelocity = ccType == 0x207
  local ccChanmsg, ccFilter = helper.ccTypeToChanmsg(ccType)

  if movingArea then
    deltaTicks = area.timeValue.ticks.min - area.unstretchedTimeValue.ticks.min
    deltaVal = -(area.timeValue.vals.min - area.unstretchedTimeValue.vals.min)

    deltaTicks = math.floor(deltaTicks + 0.5)
    deltaVal = math.floor(deltaVal + 0.5)
  end

  if operation == OP_STRETCH and area.unstretched and (not mod.singleMod() or area.active) then
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
  local areaLeftmostTick = math.floor(timeValue.ticks.min + 0.5)
  local areaRightmostTick = math.floor(timeValue.ticks.max + 0.5)

  if usingUnstretched then
    leftmostTick = sourceInfo.leftmostTick
    rightmostTick = sourceInfo.rightmostTick
    topValue = sourceInfo.topValue
    bottomValue = sourceInfo.bottomValue
  else
    leftmostTick = areaLeftmostTick
    rightmostTick = areaRightmostTick
    topValue = timeValue.vals.max
    bottomValue = timeValue.vals.min
  end

  local enumFn = laneIsVel and mu.MIDI_EnumNotes or mu.MIDI_EnumCC

  local skipiter = false
  local widgeting = false
  if glob.widgetInfo and area == glob.widgetInfo.area then
    if glob.widgetInfo.sourceEvents[activeTake] then
      skipiter = true
    end
    widgeting = true
  end

  local process = true
  if wantsPaste or operation == OP_COPY or operation == OP_CUT or operation == OP_PASTE or operation == OP_SELECT or operation == OP_UNSELECT then
    process = false
  end

  local insert = false

  -- TODO: REFACTOR (can use same code, approximately, for notes)
  -- potential second iteration, deal with deletions in the target area
  if operation == OP_COPY or operation == OP_CUT then
    area.onClipboard = true --area.ccLane and lastHoveredOrClickedLane == area.ccLane or lastHoveredOrClickedLane == -1
    if area.onClipboard then
      local events
      for _, ev in ipairs(clipboardEvents) do
        if ev.ref == area then
          events = ev
          break
        end
      end
      if not events then
        events = { ref = area, area = area:clone(), events = {} }
        table.insert(clipboardEvents, events)
      end
      events.events[activeTake] = sourceEvents
      if operation == OP_CUT then
        for _, event in ipairs(sourceEvents) do
          helper.addUnique(tDeletions, { type = laneIsVel and mu.NOTE_TYPE or mu.CC_TYPE, idx = event.idx })
        end
      end
    end
    skipiter = true
  elseif wantsPaste or operation == OP_PASTE then
    -- do nothing
  elseif operation == OP_DUPLICATE then
    local tmpArea = Area.new(area:serialize())
    tmpArea.timeValue.ticks:shift(areaTickExtent:size())
    processCCsWithGeneration(activeTake, tmpArea, OP_DELETE)
  elseif movingArea then
    addControlPoints(activeTake, area)
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
    addControlPoints(activeTake, area)
    if deltaTicks ~= 0 or deltaVal ~= 0 then
      if resizing == RS_TOP or resizing == RS_BOTTOM then
        skipiter = true
      else
        local tmpArea = Area.new(area:serialize()) -- only used for event selection
        local cacheMods = currentMods
        currentMods = MouseMods.new() -- clear out for the operation
        keys.mod.setMods(currentMods)
        tmpArea.unstretched, tmpArea.unstretchedTimeValue = area.unstretched, area.unstretchedTimeValue
        if not glob.insertMode then
          processCCsWithGeneration(activeTake, tmpArea, OP_DELETE) -- target
        end
        tmpArea.timeValue = area.unstretchedTimeValue
        processCCsWithGeneration(activeTake, tmpArea, OP_DELETE) -- source
        currentMods = cacheMods
        keys.mod.setMods(currentMods)
        insert = true
      end
    else
      return
    end
  end

  ccChanmsg = ccChanmsg & 0xF0 -- to be safe

  local onebyte = laneIsVel or ccChanmsg == 0xC0 or ccChanmsg == 0xD0
  local pitchbend = ccChanmsg == 0xE0

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
        if operation == OP_SELECT or operation == OP_UNSELECT then
          if laneIsVel then
            mu.MIDI_SetNote(activeTake, idx, not (operation == OP_UNSELECT) and true or false) -- allow note deletion like this?
          else
            mu.MIDI_SetCC(activeTake, idx, not (operation == OP_UNSELECT) and true or false)
          end
          touchedMIDI = true
        elseif operation == OP_INVERT then
          newmsg2, newmsg3 = valToBytes(area.timeValue.vals.max - (val - area.timeValue.vals.min))
        elseif operation == OP_RETROGRADE then
          if not laneIsVel then
            local firstppq = sourceEvents[1].ppqpos
            local lastppq = sourceEvents[#sourceEvents].ppqpos
            local delta = (firstppq - leftmostTick) - (rightmostTick - lastppq)
            newppqpos = (rightmostTick - (ppqpos - leftmostTick)) + delta
          end
        elseif operation == OP_RETROGRADE_VALS then
          newmsg2, newmsg3 = valToBytes(sourceEvents[#sourceEvents - (sidx - 1)].val)
        elseif operation == OP_DUPLICATE then
          if laneIsVel then
            helper.addUnique(tInsertions, { type = mu.NOTE_TYPE, selected = selected, muted = muted, ppqpos = ppqpos + areaTickExtent:size(), endppqpos = endppqpos + areaTickExtent:size(), chanmsg = chanmsg, chan = chan, pitch = pitch, vel = vel, relvel = relvel })
          else
            helper.addUnique(tInsertions, { type = mu.CC_TYPE, selected = selected, muted = muted, ppqpos = ppqpos + areaTickExtent:size(), chanmsg = chanmsg, chan = chan, msg2 = msg2, msg3 = msg3 })
          end
        elseif operation == OP_DELETE then
          helper.addUnique(tDeletions, { type = laneIsVel and mu.NOTE_TYPE or mu.CC_TYPE, idx = idx })
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
            --   helper.addUnique(tInsertions, { selected = selected, muted = muted, ppqpos = newppqpos, endppqpos = endppqpos + deltaTicks, chan = chan, pitch = pitch, vel = newmsg2 or vel, relvel = newmsg3 or relvel })
            -- end
          else
            if newppqpos then
              helper.addUnique(tInsertions, { type = mu.CC_TYPE, selected = selected, muted = muted, ppqpos = newppqpos, chanmsg = chanmsg, chan = chan, msg2 = newmsg2 or msg2, msg3 = newmsg3 or msg3 })
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
                helper.addUnique(tInsertions, newEvent)
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
              helper.addUnique(tInsertions, newEvent)
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
  if area.controlPoints then
    helper.addUnique(tInsertions, area.controlPoints[1])
    helper.addUnique(tInsertions, area.controlPoints[2])
    helper.addUnique(tInsertions, area.controlPoints[3])
    helper.addUnique(tInsertions, area.controlPoints[4])
  end

  if stretchingArea and (resizing == RS_TOP or resizing == RS_BOTTOM) then
    for _, event in ipairs(sourceEvents) do
      local val = event.val
      local newval

      if resizing == RS_TOP then -- don't support stretchmode 2 for area stretching, only for widget
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
      newval = clipInt(newval, 0, meLanes[area.ccLane].range)
      newmsg2 = onebyte and newval or pitchbend and (newval & 0x7F) or event.msg2
      newmsg3 = onebyte and event.msg3 or pitchbend and ((newval >> 7) & 0x7F) or newval

      if laneIsVel then
        newmsg3 = isRelVelocity and newmsg2 or nil
        newmsg2 = not isRelVelocity and newmsg2 or nil
        mu.MIDI_SetNote(activeTake, event.idx, nil, nil, nil, nil, nil, nil, newmsg2, newmsg3)
      else
        mu.MIDI_SetCC(activeTake, event.idx, nil, nil, nil, nil, nil, newmsg2, newmsg3)
      end
      touchedMIDI = true
    end
  end

  if widgeting and glob.widgetInfo and glob.widgetInfo.sourceEvents[activeTake] then
    for _, event in ipairs(glob.widgetInfo.sourceEvents[activeTake]) do
      local val = event.val

      local newval = callWidgetProcessingMode(val, area.timeValue.vals.min, area.timeValue.vals.max,
                                              area.widgetExtents.min, area.widgetExtents.max,
                                              (event.ppqpos - area.timeValue.ticks.min) / (area.timeValue.ticks.max - area.timeValue.ticks.min),
                                              glob.widgetInfo.sourceMin[activeTake], glob.widgetInfo.sourceMax[activeTake])
      -- TODO valToBytes, untangle here
      if newval then
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
  end
end

------------------------------------------------
------------------------------------------------

local function processInsertions()
  local activeTake = glob.liceData.editorTake
  if DEBUG_DUPLICATE or DEBUG_INVERT then
    _P('--- processInsertions ---')
    _P('  tInsertions count:', #tInsertions)
    for i, event in ipairs(tInsertions) do
      if event.type == mu.NOTE_TYPE then
        _P('    insertion', i, ': NOTE ppq', event.ppqpos, '-', event.endppqpos, 'pitch', event.pitch)
      else
        _P('    insertion', i, ': CC ppq', event.ppqpos)
      end
    end
    _P('  tDeletions count:', #tDeletions)
    for i, event in ipairs(tDeletions) do
      _P('    deletion', i, ': type', event.type, 'idx', event.idx)
    end
  end
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

local function generateSourceInfo(area, op, force, overlap)
  local activeTake = glob.liceData.editorTake
  local itemInfo = glob.liceData.itemInfo[activeTake]

  local relativePPQ, relativeEndPPQ, offsetPPQ = itemInfo.relativePPQ, itemInfo.relativeEndPPQ, itemInfo.offsetPPQ

  area.sourceInfo = area.sourceInfo or {}
  if not area.sourceInfo[activeTake] or force then

    -- do an early return if it's obvious that this item is at a different time than our area
    if relativePPQ > area.timeValue.ticks.max or relativeEndPPQ < area.timeValue.ticks.min then
      area.sourceInfo[activeTake] = { sourceEvents = {}, skip = true }
      return
    end

    local isNote = not area.ccLane and true or false
    local sourceInfo = { sourceEvents = {}, localRect = area.logicalRect, usingUnstretched = false }

    local wantsWidget = false

    if op == OP_STRETCH
      and area.unstretched
      and (not mod.singleMod()
        or area.active)
    then
      sourceInfo.usingUnstretched = true
    end

    local usingUnstretched = sourceInfo.usingUnstretched

    local leftmostTick = not usingUnstretched and area.timeValue.ticks.min - offsetPPQ or area.unstretchedTimeValue.ticks.min - offsetPPQ
    local rightmostTick = not usingUnstretched and area.timeValue.ticks.max - offsetPPQ or area.unstretchedTimeValue.ticks.max - offsetPPQ

    leftmostTick = math.floor(leftmostTick + 0.5)
    rightmostTick = math.floor(rightmostTick + 0.5)

    local topValue = not usingUnstretched and area.timeValue.vals.max or area.unstretchedTimeValue.vals.max
    local bottomValue = not usingUnstretched and area.timeValue.vals.min or area.unstretchedTimeValue.vals.min

    sourceInfo.leftmostTick = leftmostTick
    sourceInfo.rightmostTick = rightmostTick
    sourceInfo.topValue = topValue
    sourceInfo.bottomValue = bottomValue

    if glob.widgetInfo and area == glob.widgetInfo.area then
      glob.widgetInfo.sourceEvents = glob.widgetInfo.sourceEvents or {}
      if not glob.widgetInfo.sourceEvents[activeTake] then
        wantsWidget = true
      end
    end

    local idx = -1
    if isNote then
      local overlapTab
      local excludeByIdx  -- for copy: exclude sourceEvents by idx (positions differ between source/dest)
      -- use exclusion list when provided (for copy: excludes sourceEvents from dest deletion)
      if not (op == OP_STRETCH or op == OP_STRETCH_DELETE or op == OP_DELETE_TRIM)
        and overlap
      then
        overlapTab = {}
        excludeByIdx = {}
        for _, event in ipairs(overlap) do
          if not editorFilterChannels or (editorFilterChannels & (1 << event.chan) ~= 0) then
            helper.addUnique(overlapTab, { type = mu.NOTE_TYPE,
                                          selected = event.selected,
                                          muted = event.muted,
                                          ppqpos = event.ppqpos,
                                          endppqpos = event.endppqpos,
                                          chan = event.chan,
                                          pitch = event.pitch,
                                          vel = event.vel,
                                          relvel = event.relvel
                                        })
            if event.idx then excludeByIdx[event.idx] = true end
          end
        end
      end

      while true do
        idx = mu.MIDI_EnumNotes(activeTake, idx)
        if not idx or idx == -1 then break end
        local event = { type = mu.NOTE_TYPE }
        _, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.pitch, event.vel, event.relvel = mu.MIDI_GetNote(activeTake, idx)

        if not editorFilterChannels or (editorFilterChannels & (1 << event.chan) ~= 0) then
          if event.endppqpos > leftmostTick and event.ppqpos < rightmostTick
            and pitchInRange(event.pitch, bottomValue, topValue)
          then
            -- exclude by idx (for copy) or by hash (for overlapMod)
            if (excludeByIdx and excludeByIdx[idx]) or (overlapTab and helper.inUniqueTab(overlapTab, event)) then
              -- ignore
            else
              event.idx = idx
              sourceInfo.sourceEvents[#sourceInfo.sourceEvents + 1] = event
            end
          end
        end
      end
    else
      local ccType = meLanes[area.ccLane].type
      local laneIsVel = laneIsVelocity(area)
      local isRelVelocity = ccType == 0x207
      local ccChanmsg, ccFilter = helper.ccTypeToChanmsg(ccType)
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
        local event = { type = (laneIsVel and mu.NOTE_TYPE or mu.CC_TYPE) }
        -- local rv, selected, muted, ppqpos, endppqpos, chanmsg, chan, msg2, msg3, pitch, vel, relvel

        if laneIsVel then
          _, event.selected, event.muted, event.ppqpos, event.endppqpos, event.chan, event.pitch, event.vel, event.relvel = mu.MIDI_GetNote(activeTake, idx)
          event.msg2, event.msg3 = event.vel, event.relvel
          if isRelVelocity then event.msg2 = event.msg3 end
          event.chanmsg, event.msg3 = 0x90, 0
        else
          _, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3 = mu.MIDI_GetCC(activeTake, idx)
        end

        if not editorFilterChannels or (editorFilterChannels & (1 << event.chan) ~= 0) then
          event.chanmsg = event.chanmsg & 0xF0 -- to be safe
          local onebyte = laneIsVel or event.chanmsg == 0xC0 or event.chanmsg == 0xD0
          -- local pitchbend = chanmsg == 0xE0
          local val = (event.chanmsg == 0xA0 or event.chanmsg == 0xB0) and event.msg3 or onebyte and event.msg2 or (event.msg3 << 7 | event.msg2)

          if event.ppqpos >= leftmostTick - 1 and event.ppqpos <= rightmostTick + 1
            and event.chanmsg == ccChanmsg and (not ccFilter or (ccFilter >= 0 and event.msg2 == ccFilter))
            and (not selNotes or selNotes[event.msg2]) -- handle PolyAT lane
          then
            local wants = true
            if event.ppqpos <= leftmostTick or event.ppqpos >= rightmostTick then
              sourceInfo.potentialControlPoints = sourceInfo.potentialControlPoints or {}
              sourceInfo.potentialControlPoints[#sourceInfo.potentialControlPoints + 1] = event
              if event.ppqpos < leftmostTick or event.ppqpos > rightmostTick then
                wants = false
              end
            end
            if wants and val <= topValue and val >= bottomValue then
              event.idx = idx
              event.val = val
              sourceInfo.sourceEvents[#sourceInfo.sourceEvents + 1] = event
            end
          end
        end
      end
    end

    if wantsWidget then
      local ccType = isNote and 0 or meLanes[area.ccLane].type
      local laneIsVel = laneIsVelocity(area)
      local isRelVelocity = laneIsVel and ccType == 0x207

      glob.widgetInfo.sourceEvents[activeTake] = sourceInfo.sourceEvents
      glob.widgetInfo.sourceMin = glob.widgetInfo.sourceMin or {}
      glob.widgetInfo.sourceMax = glob.widgetInfo.sourceMax or {}
      if isNote or laneIsVel then
        for _, event in ipairs(glob.widgetInfo.sourceEvents[activeTake]) do
          local val = isRelVelocity and event.relvel or event.vel
          if not glob.widgetInfo.sourceMin[activeTake] or val < glob.widgetInfo.sourceMin[activeTake] then glob.widgetInfo.sourceMin[activeTake] = val end
          if not glob.widgetInfo.sourceMax[activeTake] or val > glob.widgetInfo.sourceMax[activeTake] then glob.widgetInfo.sourceMax[activeTake] = val end
        end
      else
        for _, event in ipairs(glob.widgetInfo.sourceEvents[activeTake]) do
          if not glob.widgetInfo.sourceMin[activeTake] or event.val < glob.widgetInfo.sourceMin[activeTake] then glob.widgetInfo.sourceMin[activeTake] = event.val end
          if not glob.widgetInfo.sourceMax[activeTake] or event.val > glob.widgetInfo.sourceMax[activeTake] then glob.widgetInfo.sourceMax[activeTake] = event.val end
        end
      end
    end
    area.sourceInfo[activeTake] = sourceInfo
  end
end

local function singleAreaProcessing()
  return hottestMods:matches({ shift = true, alt = true, super = '' })
end

processNotesWithGeneration = function(take, area, op, overlap)
  generateSourceInfo(area, op, true, overlap)
  processNotes(take, area, op)
end

processCCsWithGeneration = function(take, area, op)
  generateSourceInfo(area, op, true)
  processCCs(take, area, op)
end

------------------------------------------------
------------------------------------------------

local function swapAreas(newAreas)
  glob.areas = newAreas
  areas = glob.areas
end

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

------------------------------------------------
------------------------------------------------

local lastChanged = {}

local function prepItemInfoForTake(take)
  glob.liceData.editorTake = take

  local activeTake = take
  local activeItem = r.GetMediaItemTake_Item(activeTake)

  local startTime = r.GetMediaItemInfo_Value(activeItem, 'D_POSITION')
  local endTime = startTime + r.GetMediaItemInfo_Value(activeItem, 'D_LENGTH')
  local relativePPQ = r.MIDI_GetPPQPosFromProjTime(glob.liceData.referenceTake, startTime)
  local relativeEndPPQ = r.MIDI_GetPPQPosFromProjTime(glob.liceData.referenceTake, endTime)
  local activeRelPPQ = r. MIDI_GetPPQPosFromProjTime(activeTake, startTime)
  local activeRelEndPPQ = r. MIDI_GetPPQPosFromProjTime(activeTake, endTime)
  local offsetPPQ = relativePPQ - activeRelPPQ

  glob.liceData.itemInfo = glob.liceData.itemInfo or {}
  glob.liceData.itemInfo[activeTake] = {
    relativePPQ = relativePPQ,
    relativeEndPPQ = relativeEndPPQ,
    offsetPPQ = offsetPPQ,
    activeRelPPQ = activeRelPPQ, -- maybe don't need here
    activeRelEndPPQ = activeRelEndPPQ -- ditto
  }
  return activeTake, glob.liceData.itemInfo[activeTake]
end

local function handleOpenTransaction(activeTake)
  muState = muState or {}
  if not muState[activeTake] then
    mu.MIDI_InitializeTake(activeTake)
    muState[activeTake] = mu.MIDI_GetState()
  else
    if not noRestore[activeTake] then
      mu.MIDI_RestoreState(muState[activeTake])
    end
    noRestore[activeTake] = false
  end
  mu.MIDI_OpenWriteTransaction(activeTake)
end

local function handleCommitTransaction(activeTake)
  local changed = touchedMIDI

  if changed ~= lastChanged[activeTake] then -- ensure that we return to the original state
    mu.MIDI_ForceNextTransaction(activeTake)
    lastChanged[activeTake] = changed
    touchedMIDI = true
  end

  if touchedMIDI then
    mu.MIDI_CommitWriteTransaction(activeTake, false, true)
  else
    noRestore[activeTake] = true
  end
  touchedMIDI = false
end

-- paste needs to clear the target area
local function handlePaste()
  if not clipboardEvents or #clipboardEvents == 0 then return end

  local multi = #clipboardEvents > 1

  clearAreas()
  local insertionPPQ = r.MIDI_GetPPQPosFromProjTime(glob.liceData.editorTake, r.GetCursorPositionEx(0))

  local fromLane = clipboardEvents[1].area.ccLane or -1
  local toLane = lastHoveredOrClickedLane or -1

  local fromLaneType = fromLane ~= -1 and clipboardEvents[1].area.ccType
  local toLaneType = toLane ~= -1 and meLanes[toLane].type

  if not multi
    and fromLane ~= toLane
    and (fromLane == -1 or toLane == -1
      or fromLaneType == 0x200 or fromLaneType == 0x207
      or toLaneType == 0x200 or toLaneType == 0x207)
  then
    return
  end

  local newchanmsg, newmsg2
  if not multi  then
    newchanmsg, newmsg2 = helper.ccTypeToChanmsg(toLaneType)
  end

  table.sort(clipboardEvents, function(t1, t2)
    return t1.area.timeValue.ticks.min < t2.area.timeValue.ticks.min
  end)
  local firstOffset = insertionPPQ - clipboardEvents[1].area.timeValue.ticks.min

  local cherry = false

  for _, v in ipairs(clipboardEvents) do
    local area = Area.deserialize(v.area)
    local offset = not cherry and firstOffset or firstOffset + (area.timeValue.ticks.min - clipboardEvents[1].area.timeValue.ticks.min)
    area.timeValue.ticks:shift(offset)
    area.ccLane = (not multi and (toLane ~= -1 and toLane or nil)) or area.ccLane
    area.ccType = (not multi and (toLane ~= -1 and toLaneType or nil)) or area.ccType

    updateAreaFromTimeValue(area)
    areas[#areas + 1] = area

    for take, events in pairs(v.events) do
      local activeTake, _ = prepItemInfoForTake(take)
      tInsertions = {}
      tDeletions = {}
      tDelQueries = {}

      handleOpenTransaction(activeTake)

      local tmpArea = Area.new(area:serialize())
      if area.ccLane then
        processCCsWithGeneration(activeTake, tmpArea, OP_DELETE)
      else
        processNotesWithGeneration(activeTake, tmpArea, OP_DELETE_TRIM)
      end
      for _, e in ipairs(events) do
        local event = mu.tableCopy(e)
        event.ppqpos = event.ppqpos + offset
        if event.type == mu.NOTE_TYPE then
          event.endppqpos = event.endppqpos + offset
        end
        if area.ccLane then
          event.chanmsg = newchanmsg or event.chanmsg
          event.msg2 = newmsg2 or event.msg2
          -- might need to scale value based on mismatch between 14- and 7-bit?
          helper.addUnique(tInsertions, event)
        else
          local overlapped = mod.overlapMod()
          helper.addUnique(tInsertions,
                          { type = mu.NOTE_TYPE,
                            selected = event.selected, muted = event.muted,
                            ppqpos = (not overlapped and event.ppqpos < area.timeValue.ticks.min) and area.timeValue.ticks.min or event.ppqpos,
                            endppqpos = (not overlapped and event.endppqpos > area.timeValue.ticks.max) and area.timeValue.ticks.max or event.endppqpos,
                            chan = event.chan, pitch = event.pitch,
                            vel = event.vel, relvel = event.relvel }
                          )

        end
      end

      processInsertions()
      noRestore[activeTake] = true -- force
      handleCommitTransaction(activeTake)
    end
  end
  noRestore = {}
  muState = nil
end

local function handleProcessAreas(singleArea, forceSourceInfo)
  local clipboardInited = false

  for _, take in ipairs(glob.liceData.allTakes) do
    local activeTake = prepItemInfoForTake(take)

    handleOpenTransaction(activeTake)

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

      -- used by OP_DUPLICATE
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

    if operation == OP_SELECT then
      mu.MIDI_SelectAll(activeTake, false) -- should 'select' unselect everything else?
      touchedMIDI = true
    end

    local function runProcess(area)
      if not area.ccLane then
        processNotes(activeTake, area, operation)
      else
        processCCs(activeTake, area, operation)
      end
    end

    if (operation == OP_COPY or operation == OP_CUT) and not clipboardInited then
      clipboardEvents = {} -- otherwise let it persist
      clipboardInited = true
    end

    tInsertions = {}
    tDeletions = {}
    tDelQueries = {}
    if hovering then
      runProcess(hovering)
    else
      if dragDirection then
        local ddString = helper.dragDirectionToString(dragDirection)
        if ddString then
          swapAreas(helper.sortAreas(areas, ddString))
        end
      end
      for i, area in ipairs(areas) do
        runProcess(area)
      end
    end
    processInsertions()
    handleCommitTransaction(activeTake)
  end
end

local function processAreaShift(area, operation)
  local shift = 0
  if operation == OP_SHIFTLEFT then shift = -area.timeValue.ticks:size()
  elseif operation == OP_SHIFTRIGHT then shift = area.timeValue.ticks:size()
  elseif operation == OP_SHIFTLEFTGRID then shift = -(mu.MIDI_GetPPQ(glob.liceData.editorTake) * glob.currentGrid)
  elseif operation == OP_SHIFTRIGHTGRID then shift = (mu.MIDI_GetPPQ(glob.liceData.editorTake) * glob.currentGrid)
  elseif operation == OP_SHIFTLEFTGRIDQ then
    local grid = mu.MIDI_GetPPQ(glob.liceData.editorTake) * glob.currentGrid
    local temp = area.timeValue.ticks.min - grid
    local som = r.MIDI_GetPPQPos_StartOfMeasure(glob.liceData.referenceTake, temp)
    temp = temp - som -- 0-based position in measure
    temp = som + (math.floor((temp / grid)) * grid)
    shift = temp - (area.timeValue.ticks.min - grid)
    if shift == 0 then shift = -grid end
  elseif operation == OP_SHIFTRIGHTGRIDQ then
    local grid = mu.MIDI_GetPPQ(glob.liceData.editorTake) * glob.currentGrid
    local temp = area.timeValue.ticks.min + grid
    local som = r.MIDI_GetPPQPos_StartOfMeasure(glob.liceData.referenceTake, temp)
    temp = temp - som -- 0-based position in measure
    temp = som + (math.floor((temp / grid) + 1) * grid)
    shift = temp - (area.timeValue.ticks.min + grid)
    if shift == 0 then shift = grid end
  end
  area.timeValue.ticks:shift(shift)
  updateTimeValueTime(area)
  updateAreaFromTimeValue(area)
end

local function processAreas(singleArea, forceSourceInfo)
  glob.liceData.referenceTake = glob.liceData.editorTake
  local doPaste = false
  local doCut = false
  local doShift = false

  local operation = singleArea and singleArea.operation or #areas ~= 0 and areas[1].operation or wantsPaste and OP_PASTE or nil
  if operation == OP_PASTE then
    doPaste = true
  elseif operation == OP_CUT then
    doCut = true
  elseif isShiftOperation(operation) then
    doShift = true
  end

  if doPaste then
    handlePaste()
    wantsPaste = false
  elseif doShift then

  else
    handleProcessAreas(singleArea, forceSourceInfo)
  end

  if doCut then
    clearAreas()
  elseif doShift then
    for i, area in ipairs(areas) do -- ideally only for a single area?
      processAreaShift(area, operation)
      area.operation = area.operation == OP_STRETCH and area.operation or nil -- TODO, why do we do that?
    end
  else
    for i, area in ipairs(areas) do
      -- TODO, this should only happen after all takes have been processed, no?
      if area.operation == OP_DUPLICATE then
        area.timeValue.ticks:shift(areaTickExtent:size())
        updateTimeValueTime(area)
        updateAreaFromTimeValue(area)
      end
      area.operation = area.operation == OP_STRETCH and area.operation or nil -- TODO, why do we do that?
    end
  end

  glob.liceData.itemInfo = nil
  glob.liceData.editorTake = glob.liceData.referenceTake
  glob.liceData.referenceTake = nil
end

------------------------------------------------
------------------------------------------------

-- thanks FeedTheCat for this absolutely disgusting hack

local function setCustomOrder(hwnd, visible_note_rows)
  local take = reaper.MIDIEditor_GetTake(hwnd)
  if not take then return end

  local track = reaper.GetMediaItemTake_Track(take)
  if not track then return end

  local custom_order = table.concat(visible_note_rows, ' ')

  local _, chunk = reaper.GetTrackStateChunk(track, '', false)

  local new_chunk, occ = chunk:gsub('(CUSTOM_NOTE_ORDER )(.-)\n',
                                    '%1' .. custom_order .. '\n',
                                    1)

  if occ == 0 then
    new_chunk = chunk:gsub('<TRACK',
                           '<TRACK\nCUSTOM_NOTE_ORDER ' .. custom_order,
                           1)
  end

  if new_chunk ~= chunk then
    reaper.SetTrackStateChunk(track, new_chunk, false)
  end
  reaper.MIDIEditor_OnCommand(hwnd, 40143)
  meState.showNoteRows = 3
end

-- delegate to analyze module
local function getVisibleNoteRows(hwnd, mode, chunk)
  return analyze.getVisibleNoteRows(hwnd, mode, chunk)
end

-- cribbed from Julian Sader

local function analyzeChunk()
  local activeTake = glob.liceData.editorTake
  local activeItem = glob.liceData.editorItem

  if not activeItem then return false end

  local activeTakeChunk
  local activeChannel
  local windY = 0 -- relative to content area (below ruler)
  local rv, midivuConfig = r.get_config_var_string('midivu')
  local midivu = tonumber(midivuConfig)
  local showMargin = midivu and (midivu & 0x80) == 0

  glob.currentGrid, glob.currentSwing = r.MIDI_GetGrid(activeTake)

  local mePrevLanes = meLanes
  meLanes = {}
  local mePrevState = meState
  -- this needs to persist!
  meState = { noteTab = mePrevState.noteTab, noteTabReverse = mePrevState.noteTabReverse}
  -- reuse table to reduce GC pressure (called every 200ms)
  if not glob.deadZones then glob.deadZones = {} end
  for k in pairs(glob.deadZones) do glob.deadZones[k] = nil end

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
  meState.leftmostTick, meState.horzZoom, meState.topPitch, meState.pixelsPerPitch = tonumber(meState.leftmostTick), tonumber(meState.horzZoom), 127 - tonumber(meState.topPitch), tonumber(meState.pixelsPerPitch)

  meState.leftmostTick = meState.leftmostTick and math.floor(meState.leftmostTick + 0.5)

  if not (meState.leftmostTick and meState.horzZoom and meState.topPitch and meState.pixelsPerPitch) then
    r.MB('Could not determine the MIDI editor\'s zoom and scroll positions.', 'ERROR', 0)
    return false
  end
  activeChannel, meState.showNoteRows, meState.timeBase = activeTakeChunk:match('\nCFGEDIT %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+) (%S+)')
  meState.activeChannel = tonumber(activeChannel) or 0

  local multiChanFilter, filterChannel, filterEnabled = activeTakeChunk:match('\nEVTFILTER (%S+) %S+ %S+ %S+ %S+ (%S+) (%S+)')

  multiChanFilter = tonumber(multiChanFilter)
  filterChannel = tonumber(filterChannel)
  filterEnabled = tonumber(filterEnabled)
  editorFilterChannels = filterEnabled ~= 0 and multiChanFilter ~= 0 and multiChanFilter or nil

  --[[
  0 = show all
  1 = hide unused
  2 = hide unused and unnamed
  3 = custom
  -- ]]

  -- when does this need to be rebuilt? could add names, etc. per API
  -- so probably every tick
  -- REAPER BUG prevents this from being good: https://forum.cockos.com/showthread.php?t=298446
  meState.showNoteRows = tonumber(meState.showNoteRows)
  local noteRowsChanged = false
  if mePrevState.showNoteRows ~= meState.showNoteRows then
    glob.refreshNoteTab = true
    noteRowsChanged = true  -- caller handles clearAreas
  end
  if meState.showNoteRows ~= 0 and (not meState.noteTab or glob.refreshNoteTab) then
    local tChunkOk, tChunk
    if meState.showNoteRows == 2 or meState.showNoteRows == 3 then
      tChunkOk, tChunk = r.GetTrackStateChunk(r.GetMediaItemTrack(activeItem), '', false)
    end
    meState.noteTab = getVisibleNoteRows(glob.liceData.editor, meState.showNoteRows, tChunk)
    glob.refreshNoteTab = false

    meState.noteTabReverse = {}
    for k, v in ipairs(meState.noteTab) do
      meState.noteTabReverse[v] = k
    end
  elseif meState.showNoteRows == 0 then
    meState.noteTab = nil
    meState.noteTabReverse = nil
  end

  meState.timeBase = (meState.timeBase == '0' or meState.timeBase == '4') and 'beats' or 'time'
  if meState.timeBase == 'beats' then
    meState.pixelsPerTick = meState.horzZoom
  else
    meState.pixelsPerSecond = meState.horzZoom
  end
  meState.leftmostTime = r.MIDI_GetProjTimeFromPPQPos(activeTake, meState.leftmostTick)

  local screenWidth = glob.liceData.screenRect:width()
  if meState.timeBase == 'time' then
    meState.rightmostTime = meState.leftmostTime + ((screenWidth - lice.MIDI_SCROLLBAR_R) / meState.pixelsPerSecond)
  else
    local rightmostTick = meState.leftmostTick + ((screenWidth - lice.MIDI_SCROLLBAR_R) / meState.pixelsPerTick)
    meState.rightmostTime = r.MIDI_GetProjTimeFromPPQPos(activeTake, rightmostTick)
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
    laneType, ME_Height, inlineHeight = helper.convertCCTypeChunkToAPI(tonumber(laneType)), tonumber(ME_Height), tonumber(inlineHeight)
    if not (laneType and ME_Height and inlineHeight) then
      r.MB('Could not parse the VELLANE fields in the item state chunk.', 'ERROR', 0)
        return false
    end
    laneID = laneID + 1
    meLanes[laneID] = { VELLANE = vellaneStr, type = laneType, range = helper.ccTypeToRange(laneType), height = ME_Height, inlineHeight = inlineHeight, scroll = scroll, zoom = zoom }
  end

  local sr = glob.liceData.screenRect
  local laneBottomPixel = sr:height() - lice.MIDI_SCROLLBAR_B -- relative to content area (0-based)
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

    -- deadZones use relative coords (0-based)
    table.insert(glob.deadZones, Rect.new(0, meLanes[i].bottomPixel + bottomMargin, lice.MIDI_HANDLE_L, meLanes[i + 1] and meLanes[i + 1].topPixel - meLanes[i + 1].topMargin or sr:height()))
    table.insert(glob.deadZones, Rect.new(sr:width() - (lice.MIDI_SCROLLBAR_R + lice.MIDI_HANDLE_R), meLanes[i].bottomPixel + bottomMargin, sr:width() - lice.MIDI_SCROLLBAR_R, meLanes[i + 1] and meLanes[i + 1].topPixel - meLanes[i + 1].topMargin or sr:height()))

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

  if meLanes[0] then
    table.insert(glob.deadZones, Rect.new(0, meLanes[-1].bottomPixel, lice.MIDI_HANDLE_L, meLanes[0].topPixel - meLanes[0].topMargin)) -- piano roll -> first lane
    table.insert(glob.deadZones, Rect.new(sr:width() - (lice.MIDI_SCROLLBAR_R + lice.MIDI_HANDLE_R), meLanes[-1].bottomPixel, sr:width() - lice.MIDI_SCROLLBAR_R, meLanes[0].topPixel - meLanes[0].topMargin)) -- piano roll -> first lane
  end
  table.insert(glob.deadZones, Rect.new(sr:width() - lice.MIDI_SCROLLBAR_R, 0, sr:width(), sr:height()))

  if meLanes[0] then
    table.insert(glob.deadZones, Rect.new(0, meLanes[#meLanes].bottomPixel + meLanes[#meLanes].bottomMargin, sr:width(), sr:height()))
  else
    table.insert(glob.deadZones, Rect.new(0, meLanes[-1].bottomPixel, sr:width(), sr:height()))
  end

  glob.meLanes = meLanes
  glob.meState = meState

  return true, noteRowsChanged
end

------------------------------------------------
------------------------------------------------

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
      if meLanes[i].type == 0x200 or meLanes[i].type == 0x207 then
        -- do nothing
      else
        local newArea = Area.new({ fullLane = true,
                                   timeValue = TimeValueExtents.new(area.timeValue.ticks.min, area.timeValue.ticks.max, 0, meLanes[i].range),
                                   ccLane = i,
                                   ccType = meLanes[i].type
                                 }, updateAreaFromTimeValue)
        areas[#areas + 1] = newArea
      end
    end
    ccLanesToggled = area
  else
    ccLanesToggled = nil
  end
  return ccLanesToggled
end

local currentMode

local function getCurrentMode(force)
  local modesToTest = { 40452, 40453, 40454, 40143 }
  for _, v in ipairs(modesToTest) do
    if force or v ~= currentMode then
      if r.GetToggleCommandStateEx(32060, v) == 1 then
        return v
      end
    end
  end
end

local function getAreaTableForSerialization()
  local widgetArea
  if glob.widgetInfo and glob.widgetInfo.area and glob.inWidgetMode then
    widgetArea = glob.widgetInfo.area
  end
  local areaTable = {}
  for i, area in ipairs(areas) do
    areaTable[#areaTable + 1] = area:serialize()
    if area == widgetArea then
      areaTable[-1] = i
    end
  end
  areaTable[-2] = currentMode
  return areaTable
end

local prjStateChangeCt

local function createUndoStep(undoText, override)
  local undoData = override or (#areas ~= 0 and helper.serialize(getAreaTableForSerialization()) or '')
  r.Undo_BeginBlock2(0)
  r.GetSetMediaItemTakeInfo_String(glob.liceData.editorTake, 'P_EXT:'..scriptID, undoData, true)
  -- r.MarkTrackItemsDirty(r.GetMediaItem_Track(glob.liceData.editorItem), glob.liceData.editorItem)
  r.Undo_EndBlock2(0, undoText, -1)
  if DEBUG_UNDO then
    _P(undoText, #areas)
  end
  prjStateChangeCt = r.GetProjectStateChangeCount(0) -- don't reload due to this
  return prjStateChangeCt
end

glob.handleRightClick = function() -- a little smelly, but whatever works
  -- PB mode: delegate to pitchbend module for point deletion
  if glob.inPitchBendMode then
    local handled, undoText = pitchbend.handleRightClick(hottestMods)
    if handled then
      if undoText then
        r.Undo_OnStateChange2(0, undoText)
      end
      return true
    end
    return false  -- No hovered point, don't process normal right-click
  end

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

local function checkProjectExtState(noWidget)
  local _, projState = r.GetSetMediaItemTakeInfo_String(glob.liceData.editorTake, 'P_EXT:'..scriptID, '', false)
  if #projState then
    local areaTable = helper.deserialize(projState)

    -- this can be called at any time (in particular, the 'del' key will cause the project state
    -- index to change for some reason, and will trigger this function). We need to ensure that
    -- hovering state doesn't lose continuity when that happens. Thus this painful bit of code.
    local hovering
    if areas and areaTable then
      for _, area in ipairs(areas) do
        if area.hovering then
          hovering = area
          break
        end
      end
    end

    clearAreas()
    local widgetArea
    if areaTable then
      if areaTable[-1] then
        widgetArea = not noWidget and areaTable[-1] or nil
        areaTable[-1] = nil
      end
      wasDragged = true

      local savedMode = 40452 -- all notes
      if areaTable[-2] then
        savedMode = areaTable[-2]
        areaTable[-2] = nil
      end

      if savedMode ~= getCurrentMode(true) then
        resetWidgetMode()
        return -- do not restore to a different mode
      end

      for idx = #areaTable, 1, -1 do
        local area = Area.deserialize(areaTable[idx], updateAreaFromTimeValue)
        if not (area.viewRect and area.logicalRect and area.timeValue) then
          widgetArea = nil
        else
          areas[#areas + 1] = area
          if widgetArea == #areas then
            glob.widgetInfo = glob.widgetInfo or {}
            glob.widgetInfo.area = area
            glob.inWidgetMode = true
            if not area.widgetExtents then area.widgetExtents = Extent.new(0.5, 0.5) end
          end
        end
        if hovering and area.timeValue and area.timeValue:compare(hovering.timeValue) then
          area.hovering = hovering.hovering
        end
      end
      if not widgetArea then resetWidgetMode() end
    end
  end
end

local function restorePreferences()
  local stateVal

  if helper.is_windows then
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

  glob.widgetStretchMode = 1 -- default
  stateVal = r.GetExtState(scriptID, 'widgetStretchMode')
  if stateVal then
    stateVal = tonumber(stateVal)
    if stateVal then glob.widgetStretchMode = math.min(math.max(1, math.floor(stateVal)), 4) end -- more options
  end

  glob.wantsControlPoints = false -- default
  stateVal = r.GetExtState(scriptID, 'wantsControlPoints')
  if stateVal then
    stateVal = tonumber(stateVal)
    if stateVal then glob.wantsControlPoints = stateVal == 1 and true or false end
  end

  glob.wantsFullLaneDefault = false -- default
  stateVal = r.GetExtState(scriptID, 'wantsFullLaneDefault')
  if stateVal then
    stateVal = tonumber(stateVal)
    if stateVal then glob.wantsFullLaneDefault = stateVal == 1 and true or false end
  end

  glob.wantsRightButton = false -- default
  stateVal = r.GetExtState(scriptID, 'wantsRightButton')
  if stateVal then
    stateVal = tonumber(stateVal)
    if stateVal then glob.wantsRightButton = stateVal == 1 and true or false end
  end

  slicer.handleState(scriptID)
  pitchbend.handleState(scriptID)

  lice.reloadSettings() -- key/mod mappings
end

local function savePreferences()
  if helper.is_windows then
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
  if glob.widgetStretchMode ~= 1 then
    r.SetExtState(scriptID, 'widgetStretchMode', tostring(glob.widgetStretchMode), true)
  else
    r.DeleteExtState(scriptID, 'widgetStretchMode', true)
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
  keys.mod.setMods(nil, hottestMods)
end

local function swapCurrentMods()
  acquireKeyMods()
  currentMods = hottestMods:clone()
  keys.mod.setMods(currentMods)
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
      local hasOverlapMod, overlapModName = mod.overlapMod(someMods)
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

local contextMods = 0
local contextCode = nil

local function passUnconsumedKeys(vState)
  -- pass anything else through, requires SWS
  if hasSWS and glob.liceData then
    -- _P(contextMods, contextCode, hottestMods:flags())
    local hotMods = hottestMods:flags() == contextMods
    for k = 1, #vState do
      -- if k ~= 0xD and keys:byte(k) ~= 0 then
      if vState:byte(k) ~= 0 then
        if hotMods and k == contextCode then -- don't pass the key used to trigger the script
          wantsQuit = true -- quit instead, it's a toggle
        else
          if lice.keyIsMapped(k) then
            -- _P('passing a key', k)
            r.CF_SendActionShortcut(glob.liceData.editor, 32060, k)
          end
        end
      end
    end
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

  local hotSnap, _, snapFlagName = mod.snapMod(hottestMods)
  if hotSnap ~= mod.snapMod() then
    if snapFlagName then
      currentMods[snapFlagName] = hottestMods[snapFlagName]
    end
  end

  local vState = helper.VKeys_GetState(10)
  if vState == prevKeys then
    return
  end

  prevKeys = vState

  if resizing ~= RS_UNCLICKED then return end -- don't handle key commands while dragging

  -- global key commands which need to be checked every loop

  local keyMappings = lice.keyMappings()
  local pbKeyMappings = lice.pbKeyMappings()

  -- global exit check - works in all modes
  if keyMatches(vState, keyMappings.exitScript) then
    wantsQuit = true
    return
  end

  -- cmd+Q: quit REAPER (global, all modes)
  if vState:byte(keys.vKeyLookup['q']) ~= 0 and hottestMods:ctrl() and not hottestMods:shift() and not hottestMods:alt() then
    r.Main_OnCommand(40004, 0)
    return
  end

  -- SLICER (skip if launched from dedicated PitchBend launcher)
  if not glob.slicerQuitAfterProcess and not glob.pitchBendQuitOnToggle and keyMatches(vState, keyMappings.slicerMode) then
    glob.inSlicerMode = not glob.inSlicerMode
    if glob.inSlicerMode then glob.inPitchBendMode = false end -- exclusive modes
    return
  end

  if glob.inSlicerMode then
    -- allow switching to PitchBend mode from Slicer mode (but not from dedicated slicer script)
    if not glob.slicerQuitAfterProcess and keyMatches(vState, keyMappings.pitchBendMode) then
      glob.inPitchBendMode = true
      glob.inSlicerMode = false
      local pbConfig = pitchbend.getConfig()
      if not pbConfig.showAllNotes then
        local meActiveChan = math.max(0, (glob.meState.activeChannel or 1) - 1)
        pitchbend.setConfig('activeChannel', meActiveChan)
      end
      return
    end
    passUnconsumedKeys(vState) -- we might not want this
    return
  end
  -- SLICER

  -- PITCH BEND (skip if launched from dedicated Slicer launcher)
  if not glob.slicerQuitAfterProcess and keyMatches(vState, keyMappings.pitchBendMode) then
    if glob.pitchBendQuitOnToggle then
      wantsQuit = true
      return
    end
    glob.inPitchBendMode = not glob.inPitchBendMode
    if glob.inPitchBendMode then
      glob.inSlicerMode = false -- exclusive modes
      -- seed activeChannel from MIDI editor's active channel (if filtering)
      local pbConfig = pitchbend.getConfig()
      if not pbConfig.showAllNotes then
        local meActiveChan = math.max(0, (glob.meState.activeChannel or 1) - 1)
        pitchbend.setConfig('activeChannel', meActiveChan)
      end
    end
    return
  end

  if glob.inPitchBendMode then
    local activeTake = glob.liceData and glob.liceData.editorTake

    if keyMatches(vState, keyMappings.deleteAreaContents) then
      local undoText = pitchbend.deleteSelectedPoints(activeTake, mu)
      if undoText then createUndoStep(undoText) end
      return
    end

    -- not ctrl: don't block cmd-C
    if keyMatches(vState, pbKeyMappings.pitchBendCurveType) and not hottestMods:ctrl() then
      local undoText = pitchbend.showCurveMenu(activeTake, mu)
      if undoText then createUndoStep(undoText) end
      return
    end

    -- not ctrl: don't block cmd-Q
    if keyMatches(vState, pbKeyMappings.pitchBendSnapSemi) and not hottestMods:ctrl() then
      local undoText = pitchbend.snapSelectedToSemitone(activeTake, mu)
      if undoText then createUndoStep(undoText) end
      return
    end

    if keyMatches(vState, pbKeyMappings.pitchBendConfig) and not hottestMods:ctrl() then
      helper.VKeys_ClearState()
      pitchbend.openConfigDialog(glob.scriptID)
      return
    end

    if keyMatches(vState, pbKeyMappings.pitchBendMicrotonal) and not hottestMods:ctrl() then
      pitchbend.toggleMicrotonalLines()
      return
    end

    if keyMatches(vState, pbKeyMappings.pitchBendChannel) and not hottestMods:ctrl() then
      pitchbend.showChannelMenu()
      return
    end

    -- raw check: key in pbKeyMappings for interception only
    if vState:byte(keys.vKeyLookup['a']) ~= 0 and hottestMods:ctrl() and not hottestMods:shift() and not hottestMods:alt() then
      pitchbend.selectAll()
      pitchbend.syncSelectionToMIDI(activeTake, mu)
      createUndoStep('Select Pitch Bend')
      return
    end

    -- cmd-C: unselect all first so only PB events are copied
    if keyMatches(vState, pbKeyMappings.pitchBendCopy) then
      mu.MIDI_OpenWriteTransaction(activeTake)
      mu.MIDI_SelectAll(activeTake, false)
      mu.MIDI_CommitWriteTransaction(activeTake, true, false)
      pitchbend.syncSelectionToMIDI(activeTake, mu)
      r.MIDIEditor_OnCommand(glob.liceData.editor, 40010)
      return
    end

    if keyMatches(vState, pbKeyMappings.pitchBendPaste) then
      r.MIDIEditor_OnCommand(glob.liceData.editor, 40011)
      pitchbend.clearCache()  -- force refresh to show pasted events
      return
    end

    passUnconsumedKeys(vState)
    return
  end
  -- PITCH BEND

  if keyMatches(vState, keyMappings.insertMode) then
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
  elseif helper.is_windows and keyMatches(vState, keyMappings.compositingSetup) then
    showCompositingDialog()
    return
  elseif keyMatches(vState, keyMappings.paste, true) then
    wantsPaste = true
    return
  end

  if not glob.isIntercept or #areas == 0 then -- early return for non-essential/area stuff
    passUnconsumedKeys(vState) -- we might not want this
    return
  end

  local function processAreaShortcuts(area)

    -- only hovered
    if keyMatches(vState, keyMappings.fullLane) then
      if #areas == 1 or area.hovering then
        makeFullLane(area)
        createUndoStep('Modify Razor Edit Area')
        return true
      end
      return false
    end

    if keyMatches(vState, keyMappings.shiftleft) then -- shift left
      if #areas == 1 or area.hovering then
        area.operation = OP_SHIFTLEFT
        return true
      else
        return false
      end
    elseif keyMatches(vState, keyMappings.shiftright) then -- shift right
      if #areas == 1 or area.hovering then
        area.operation = OP_SHIFTRIGHT
        return true
      else
        return false
      end
    elseif keyMatches(vState, keyMappings.shiftleftgrid) then -- shift left
      if #areas == 1 or area.hovering then
        area.operation = OP_SHIFTLEFTGRID
        return true
      else
        return false
      end
    elseif keyMatches(vState, keyMappings.shiftrightgrid) then -- shift right
      if #areas == 1 or area.hovering then
        area.operation = OP_SHIFTRIGHTGRID
        return true
      else
        return false
      end
    elseif keyMatches(vState, keyMappings.shiftleftgridq) then -- shift left
      if #areas == 1 or area.hovering then
        area.operation = OP_SHIFTLEFTGRIDQ
        return true
      else
        return false
      end
    elseif keyMatches(vState, keyMappings.shiftrightgridq) then -- shift right
      if #areas == 1 or area.hovering then
        area.operation = OP_SHIFTRIGHTGRIDQ
        return true
      else
        return false
      end
    end

    if keyMatches(vState, keyMappings.ccSpan) then
      if (#areas == 1 or area.hovering) and not area.ccLane then
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
      if keyMatches(vState, keyMappings.deleteContents, true) then -- delete contents
        area.operation = OP_DELETE_USER
        return true
      elseif keyMatches(vState, keyMappings.duplicate, false) then -- duplicate
        area.operation = OP_DUPLICATE
        return true
      elseif keyMatches(vState, keyMappings.invert, true) then -- invert
        area.operation = OP_INVERT
        return true
      elseif keyMatches(vState, keyMappings.copy, true) then -- copy
        area.operation = OP_COPY
        return true
      elseif keyMatches(vState, keyMappings.cut, true) then -- cut
        area.operation = OP_CUT
        return true
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
  if keyMatches(vState, keyMappings.enterKey) and glob.inWidgetMode then
    glob.changeWidget = { area = nil }
    return
  end

  local deleteArea = false
  local deleteOnlyArea = false
  if keyMatches(vState, keyMappings.deleteAreaContents, false) then
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

  passUnconsumedKeys(vState)

  -- if ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) then
  --   reaper.CF_SendActionShortcut(reaper.GetMainHwnd(), 0, 0xD)
  -- end
  -- if ImGui.IsKeyPressed(ctx, ImGui.Key_NumpadEnter) then
  --   reaper.CF_SendActionShortcut(reaper.GetMainHwnd(), 0, 0x800D)
  -- end

end

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
local doOverlap = helper.doOverlap

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
    local oldViewRect = dragArea.viewRect and dragArea.viewRect:clone() or nil
    -- do this delta thing so that the unmanipulated logical coords aren't lost
    local applyX1, applyY1, applyX2, applyY2 = newRectFull.x1 - dragArea.viewRect.x1, newRectFull.y1 - dragArea.viewRect.y1, newRectFull.x2 - dragArea.viewRect.x2, newRectFull.y2 - dragArea.viewRect.y2
    dragArea.logicalRect = Rect.new(dragArea.logicalRect.x1 + applyX1, dragArea.logicalRect.y1 + applyY1, dragArea.logicalRect.x2 + applyX2, dragArea.logicalRect.y2 + applyY2)
    dragArea.viewRect = lice.viewIntersectionRect(dragArea)
    if not dragArea.viewRect:equals(oldViewRect) then
      dragArea.modified = true
    end
    return true
  end

  return false
end

local function mouseXToTick(mx)
  -- mx is now relative (0-based)
  local activeTake = glob.liceData.editorTake

  local itemStartTime = r.GetMediaItemInfo_Value(glob.liceData.editorItem, 'D_POSITION')
  local itemStartTick = r.MIDI_GetPPQPosFromProjTime(activeTake, itemStartTime - getTimeOffset())

  local currentTick

  if meState.timeBase == 'time' then
    local currentTime = meState.leftmostTime + (mx / meState.pixelsPerSecond)
    currentTick = r.MIDI_GetPPQPosFromProjTime(activeTake, currentTime - getTimeOffset())
  else
    currentTick = meState.leftmostTick + math.floor((mx / meState.pixelsPerTick) + 0.5)
  end
  if currentTick < itemStartTick then currentTick = itemStartTick end
  return currentTick
end

local function quantizeToGrid(mx, wantsTick, force)
  local wantsSnap = getEditorAndSnapWish()
  if not force and not wantsSnap then return mx, (wantsTick and mouseXToTick(mx)) end

  local activeTake = glob.liceData.editorTake
  local currentTick = mouseXToTick(mx)
  local som = r.MIDI_GetPPQPos_StartOfMeasure(activeTake, currentTick)

  local tickInMeasure = currentTick - som -- get the position from the start of the measure
  local gridUnit = mu.MIDI_GetPPQ(activeTake) * glob.currentGrid
  local quantizedTick = som + (gridUnit * math.floor((tickInMeasure / gridUnit) + 0.5))

  -- return relative coords (0-based)
  if meState.timeBase == 'time' then
    local quantizedTime = r.MIDI_GetProjTimeFromPPQPos(activeTake, quantizedTick)
    mx = math.floor(((quantizedTime - meState.leftmostTime) * meState.pixelsPerSecond) + 0.5)
  else
    mx = math.floor(((quantizedTick - meState.leftmostTick) * meState.pixelsPerTick) + 0.5)
  end
  return mx, (wantsTick and quantizedTick)
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
  glob.liceData.referenceTake = glob.liceData.editorTake

  local timeMin, timeMax
  local valMin, valMax
  local ccType = area.ccLane and meLanes[area.ccLane].type or nil
  local ccChanmsg, ccFilter = helper.ccTypeToChanmsg(ccType)

  local laneIsVel = laneIsVelocity(area)
  local isNote = not area.ccLane or laneIsVel
  local ccValLimited = mod.fullLaneMod() and not laneIsVel

  for _, take in ipairs(glob.liceData.allTakes) do
    local activeTake, itemInfo = prepItemInfoForTake(take)
    local idx = -1
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

      if ppqpos >= itemInfo.activeRelPPQ and ppqpos < itemInfo.activeRelEndPPQ then -- don't bother with events before or after the item starts/ends
        ppqpos = ppqpos + itemInfo.offsetPPQ
        endppqpos = endppqpos and endppqpos + itemInfo.offsetPPQ

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
    end
  end
  if timeMin and timeMax then
    local leftmostTime
    local rightmostTime

    if meState.timeBase == 'time' then
      leftmostTime = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.referenceTake, timeMin)
      rightmostTime = r.MIDI_GetProjTimeFromPPQPos(glob.liceData.referenceTake, timeMax)
    end

    area.timeValue = TimeValueExtents.new(timeMin, timeMax,
                                          (isNote and not laneIsVel) and valMin or ccValLimited and valMin or 0, (isNote and not laneIsVel) and valMax or ccValLimited and valMax or meLanes[area.ccLane].range,
                                          leftmostTime, rightmostTime)
    updateAreaFromTimeValue(area)
  end

  glob.liceData.itemInfo = nil
  glob.liceData.editorTake = glob.liceData.referenceTake
  glob.liceData.referenceTake = nil
end

------------------------------------------------
------------------------------------------------

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
          and areas[j].timeValue:contains(extents1)
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
        and result[i].timeValue:intersects(result[j].timeValue)
      then
        -- Get current extents
        local extents1 = result[i].timeValue
        local extents2 = result[j].timeValue

        -- Determine which extents should stay unchanged
        local keep_first = result[i].active or
                          (not result[j].active and extents1:calcArea() > extents2:calcArea())

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
    createUndoStep('Adjust Razor Edit Area (Widget)')

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
    local widgetSide = glob.widgetInfo and glob.widgetInfo.side
    local middle = area.viewRect.x1 + (area.viewRect:width() / 2)

    local bothArea = area.viewRect:width() * 0.375

    area.hovering = { area = true }

    if not widgetSide and mouseState.down then
      if mx <= middle - bothArea then
        widgetSide = 0
      elseif mx >= middle + bothArea then
        widgetSide = 1
      else
        widgetSide = -1
      end
    end

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
      if glob.widgetInfo and (not mouseState.down or not mouseState.dragging) then
        acquireKeyMods()
        if widgetMods and hottestMods:flags() ~= widgetMods:flags() then
          local pscc = r.GetProjectStateChangeCount(0)
          processAreas(area, true)
          if pscc ~= createUndoStep('Adjust Razor Edit Area (Widget)') then
            muState = nil
          end
          widgetMods = hottestMods:clone()
          keys.mod.setWidgetMods(widgetMods)
          area.widgetExtents = Extent.new(0.5, 0.5)
          glob.widgetInfo = { area = area, side = nil }
        end
      end

      if mouseState.clicked or (mouseState.down and not lastPoint) then
        lastPoint = testPoint
        if glob.widgetInfo then
          local halfway = area.viewRect.y1 + (((area.viewRect:height() * area.widgetExtents.min) + (area.viewRect:height() * area.widgetExtents.max)) / 2)
          if pointIsInRect(testPoint, Rect.new(middle - lice.EDGE_SLOP, halfway - lice.EDGE_SLOP, middle + lice.EDGE_SLOP, halfway + lice.EDGE_SLOP)) then
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

        if widgetSide == -1 then
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
      acquireKeyMods()
      widgetMods = hottestMods:clone()
      keys.mod.setWidgetMods(widgetMods)
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
  -- mouse coords and deadZones are now relative (0-based)
  local pt = Point.new(mx, my - lice.MIDI_RULER_H)
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

local deadzone_button_state = 0
local wasValid = false

local function ValidateMouse()

  local mState = r.JS_Mouse_GetState(glob.wantsRightButton and 3 or 1)

  if deadzone_button_state == 0 then
    local x, y = r.GetMousePosition()

    local wx1, wy1, wx2, wy2 = glob.liceData.windRect:coords()
    if helper.is_macos then  wy1, wy2 = wy2, wy1 end

    local isMidiViewHovered = x >= wx1 and x <= wx2 and y >= wy1 and y <= wy2
    if not isMidiViewHovered then
      -- Limit mouse to midiview coordinates
      x = x < wx1 and wx1 or x > wx2 and wx2 or x
      y = y < wy1 and wy1 or y > wy2 and wy2 or y
    end
    local mx, my = r.JS_Window_ScreenToClient(glob.liceData.midiview, x, y)

    local function testValidMouseAction()
      return lice.button.drag
        and ((lice.button.which == 0 and mState == 1)
          or (lice.button.which == 1 and mState == 2))
    end

    local isValidMouseAction = testValidMouseAction()

    if not isValidMouseAction and lice.button.drag and wasValid then
      lice.peekIntercepts(mx, my) -- attempt to prevent annoying race condition
      isValidMouseAction = testValidMouseAction() -- isValidMouseAction will remain false here, but for completeness...
      -- if isValidMouseAction then _P('unexpected fortune!') end
    end

    local inDeadZone = isDeadZone(mx, my)
    -- Check that mouse cursor is hovered over a valid midiview area
    if not isValidMouseAction then
      isValidMouseAction = isMidiViewHovered and not inDeadZone
      --[[ I think that the point of this is to catch mouse-ups which happen
           outside of the midiview and are thus lost, but it ends up being a race
           condition with the window messages, which are first intercepted below.
           Have now introduced a fallback, above, which should catch this. --]]
      if lice.button.drag then
        lice.resetButtons()
        lice.button.release = true
      end
    end

    if isValidMouseAction then
      wasValid = true
      lice.peekIntercepts(mx, my)
      return true, mx, my
    end
  end

  wasValid = false

  deadzone_button_state = mState
  lice.passthroughIntercepts()

  lice.button.click = false
  lice.button.drag = false
  lice.button.release = true
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

local function runOperation(op)
  swapCurrentMods()
  processAreas(nil, true)
  createUndoStep(op == OP_COPY and 'Copy Razor Area' -- copy doesn't actually change anything, this is actually pointless
              or op == OP_CUT and 'Cut Razor Area'
              or op == OP_PASTE and 'Paste Razor Area'
              or 'Process Razor Area Contents')
end

local function processTempArea(serializedArea, op, arg)

  local tmpArea = Area.newFromRect(serializedArea, makeTimeValueExtentsForArea, arg)

  glob.liceData.referenceTake = glob.liceData.editorTake

  for _, take in ipairs(glob.liceData.allTakes) do
    local activeTake = prepItemInfoForTake(take)
    tInsertions = {}
    tDeletions = {}
    tDelQueries = {}
    handleOpenTransaction(activeTake)
    processNotesWithGeneration(take, tmpArea, op)
    processInsertions()
    noRestore[activeTake] = true -- force
    handleCommitTransaction(activeTake)
  end

  glob.liceData.itemInfo = nil
  glob.liceData.editorTake = glob.liceData.referenceTake
  glob.liceData.referenceTake = nil

  noRestore = {}
  muState = nil
end

local function processSlicer(mx, my, mouseState)
  local rv = false
  if glob.inSlicerMode then
    local sliced, undoText = slicer.processSlicer(mx, my, mouseState, processTempArea, quantizeToGrid)
    if sliced then
      rv = true
      if undoText then
        createUndoStep(undoText)
        if glob.slicerQuitAfterProcess then
          wantsQuit = true
        end
        resetMouse()
      end
    end
    return true, rv
  end
  return false, rv
end

local function processPitchBendMode(mx, my, mouseState)
  local rv = false
  if glob.inPitchBendMode then
    -- Config dialog has its own defer loop, don't block curve rendering
    local activeTake = glob.liceData and glob.liceData.editorTake
    local processed, undoText = pitchbend.processPitchBend(mx, my, mouseState, mu, activeTake)
    if processed then
      rv = true
      if undoText then
        createUndoStep(undoText)
        resetMouse()
      end
    end
    return true, rv
  end
  return false, rv
end

local function processMouse()

  local rv, mx, my = ValidateMouse()

  if not rv then
    if processSlicer(mx, my, { released = true, hottestMods = hottestMods }) then
      return
    elseif processPitchBendMode(mx, my, { released = true, hottestMods = hottestMods }) then
      return
    else
      for _, area in ipairs(areas) do
        if area.operation then
          runOperation(area.operation)
          break
        end
      end
    end
    return
  end

  if not glob.editorIsForeground and not pitchbend.isConfigDialogOpen() then return end

  local isCC = false
  local ccLane
  local isActive

  -- mouse coords are now relative (no screen offset added)
  -- only adjust for ruler offset
  my = my - lice.MIDI_RULER_H -- correct for the RULER

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
          break
        end
      end
    end
  end
  lastHoveredOrClickedLane = clickedLane

  local inop = false

  -- TODO: cleanup using glob.liceData.button .canDrag / .canNew
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

  local isDoubleClicked = lice.button.dblclick and not lice.button.dblclickSeen

  -- Skip double-click area creation when in slicer or pitch bend mode
  if isDoubleClicked and (glob.inSlicerMode or glob.inPitchBendMode) then
    isDoubleClicked = false
  end

  if isDoubleClicked then
    local wantsWidgetToggle = nil
    local areaCountPreClick = #areas
    lice.button.dblclickSeen = true

    if lice.isPrimaryButton() then
      for i = #areas, 1, -1 do
        local area = areas[i]
        if clickedLane == area.ccLane or (clickedLane == -1 and not area.ccLane) then
          if area.hovering then
            wantsWidgetToggle = area
            break
          end
        end
      end
    end

    if wantsWidgetToggle then
      glob.changeWidget = { area = wantsWidgetToggle or nil }
      return
    elseif lice.isPrimaryButton()
    then
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
    lice.button.which = nil
  end

  local isDown = lice.button.pressX and true or false
  local isClicked = lice.button.click and true or false
  local isDragging = lice.button.drag and true or false
  local isReleased = lice.button.release and true or false
  local isHovered = true

  local isOnlyHovered = not isDown and not isReleased and isHovered

  -- _P('down', isDown, 'clicked', isClicked, 'drag', isDragging, 'rel', isReleased, 'hov', isHovered)

  if isClicked then
    swapCurrentMods()
  end

  -- correct/update state
  if isDown and isClicked then lice.button.click = false lice.button.drag = true end
  if not isDown and isReleased then lice.button.drag = false lice.button.release = false end

  -- SLICER
  local _, sliced = processSlicer(mx, my, { down = isDown,
                                            clicked = isClicked,
                                            dragging = isDragging,
                                            released = isReleased,
                                            hovered = isHovered,
                                            hoveredOnly = isOnlyHovered,
                                            ccLane = ccLane,
                                            inop = inop,
                                            hottestMods = hottestMods })
  if sliced then return end
  -- SLICER

  -- PITCH BEND
  local pbModeActive, pbProcessed = processPitchBendMode(mx, my, { down = isDown,
                                                         clicked = isClicked,
                                                         dragging = isDragging,
                                                         released = isReleased,
                                                         hovered = isHovered,
                                                         hoveredOnly = isOnlyHovered,
                                                         ccLane = ccLane,
                                                         inop = inop,
                                                         hottestMods = hottestMods,
                                                         doubleClicked = lice.button.dblclick })
  if pbModeActive then
    -- Clear dblclick flags when in PB mode to prevent pass-through
    if lice.button.dblclick then
      lice.button.dblclick = false
      lice.button.dblclickSeen = true
    end
    return
  end
  -- PITCH BEND

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
    local operation = wantsPaste and OP_PASTE or nil
    if wantsPaste then doProcess = true end

    for _, area in ipairs(areas) do
      local hovering = { left = false, top = false, right = false, bottom = false, widget = false, area = false }
      local addHover = false
      local theseMods = isClicked and currentMods or hottestMods

      area.sourceInfo = nil
      operation = operation or area.operation
      if pointIsInRect(testPoint, area.viewRect) then
        if not addHover and area.viewRect:width() > 20 then
          if equalIsh(area.logicalRect.x1, area.viewRect.x1) and nearValue(mx, area.viewRect.x1) then
            hovering.left = true
            addHover = true
            glob.setCursor((mod.stretchMod(theseMods) and canStretchLR(area)) and glob.stretch_left_cursor
                    or (mod.stretchMod(theseMods) and not canStretchLR(area)) and glob.forbidden_cursor
                    or glob.resize_left_cursor)
            cursorSet = true
          elseif equalIsh(area.logicalRect.x2, area.viewRect.x2) and nearValue(mx, area.viewRect.x2) then
            hovering.right = true
            addHover = true
            glob.setCursor((mod.stretchMod(theseMods) and canStretchLR(area)) and glob.stretch_right_cursor
                    or (mod.stretchMod(theseMods) and not canStretchLR(area)) and glob.forbidden_cursor
                    or glob.resize_right_cursor)
            cursorSet = true
          end
        end
        if not addHover and area.viewRect:height() > 20 then
          if equalIsh(area.logicalRect.y1, area.viewRect.y1) and nearValue(my, area.viewRect.y1) then
            hovering.top = true
            addHover = true
            glob.setCursor((mod.stretchMod(theseMods) and area.ccLane) and glob.stretch_up_down
                    or (mod.stretchMod(theseMods) and not area.ccLane) and glob.forbidden_cursor
                    or glob.resize_top_cursor) -- stretch_top?
            cursorSet = true
          elseif equalIsh(area.logicalRect.y2, area.viewRect.y2) and nearValue(my, area.viewRect.y2) then
            hovering.bottom = true
            addHover = true
            glob.setCursor((mod.stretchMod(theseMods) and area.ccLane) and glob.stretch_up_down
                    or (mod.stretchMod(theseMods) and not area.ccLane) and glob.forbidden_cursor
                    or glob.resize_bottom_cursor) -- stretch_bottom?
            cursorSet = true
          end
        end
        if not addHover and pointIsInRect(testPoint, area.viewRect, 0) then
          hovering.area = true
          addHover = true
          glob.setCursor(laneIsVelocity(area) and (mod.onlyAreaMod(theseMods) and glob.razor_move_cursor or glob.forbidden_cursor)
            or mod.copyMod(theseMods) and glob.razor_copy_cursor
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
        area.unstretched = (not mod.onlyAreaMod() or area.active) and area.logicalRect:clone() or nil
        area.unstretchedTimeValue = area.unstretched and area.timeValue:clone() or nil
        area.operation = (not mod.onlyAreaMod() or area.active) and OP_STRETCH or nil
      else
        area.active = false
        area.unstretched = (isDown and not mod.onlyAreaMod()) and area.logicalRect:clone() or nil -- we need this for multi-area move/copy (only RS_MOVEAREA?)
        area.unstretchedTimeValue = area.unstretched and area.timeValue:clone() or nil
      end
      if area.operation then doProcess = true end
      area.hovering = addHover and hovering or nil
      area.widgetExtents = nil
    end

    if not cursorSet then
      glob.setCursor(glob.wantsRightButton and glob.razor_cursor_rmb or glob.razor_cursor1)
    end

    if glob.widgetInfo then glob.widgetInfo.sourceEvents = nil end

    if isOnlyHovered then
      if doProcess then
        runOperation(operation)
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

      if not mod.preserveMod() then
        doClearAll()
        deferredClearAll = true
      end

      if ccLane and meLanes[ccLane].type == 0x210 then
        resizing = RS_UNCLICKED return -- media item lane is verboten
      end

      -- CC lanes: default full lane, modifier disables
      -- Note lane: default depends on wantsFullLaneDefault setting, modifier toggles
      local fullLane = (ccLane and not mod.fullLaneMod())
                    or (not ccLane and (glob.wantsFullLaneDefault ~= mod.fullLaneMod()))

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
      if meState.showNoteRows ~= 0 then
        setCustomOrder(glob.liceData.editor, meState.noteTab) -- disgusting hack from FTC (thank you!)
      end
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
            area.logicalRect.y1 = 0 - ((meLanes[-1].range - meState.topPitch) * meState.pixelsPerPitch)  -- relative (0-based)
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
            and (not mod.singleMod() or laneIsVelocity(area))
          then
            if laneIsVelocity(area) then
              if mod.onlyAreaMod() then
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

            stretching = not (resizing == RS_MOVEAREA and mod.onlyAreaMod()) -- all = just move area
            if not stretching then noProcessOnRelease = true end -- TODO hack
            found = true

            if resizing ~= RS_MOVEAREA and mod.stretchMod() then
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

                -- itemStartX is relative (0-based)
                if meState.timeBase == 'time' then
                  itemStartX = math.floor(((itemStartTime - glob.meState.leftmostTime) * meState.pixelsPerSecond) + 0.5)
                else
                  itemStartX = math.floor(((itemStartTick - glob.meState.leftmostTick) * meState.pixelsPerTick) + 0.5)
                end

                for i, testArea in ipairs(areas) do
                  if (testArea.ccLane == area.ccLane or (not testArea.ccLane and not area.ccLane)) then
                    local bottomPixel = meLanes[area.ccLane or -1].bottomPixel
                    if meState.noteTab then
                      bottomPixel = math.min(bottomPixel, meLanes[-1].topPixel + math.floor(((#meState.noteTab - (127 - meState.topPitch)) * meState.pixelsPerPitch) + 0.5))
                    end
                    if testArea.viewRect.y2 + dy > bottomPixel then dy = 0 break end
                    if testArea.viewRect.y1 + dy < meLanes[area.ccLane or -1].topPixel then dy = 0 break end

                    -- prevent motion past item start
                    if testArea.viewRect.x1 + dx < itemStartX then dx = 0 break end
                  end
                end

                local oldMinTicks, oldMaxTicks = areas[isActive].timeValue.ticks.min, areas[isActive].timeValue.ticks.max
                local oldMinVals, oldMaxVals = areas[isActive].timeValue.vals.min, areas[isActive].timeValue.vals.max
                -- only move one area via pixels, all others will be adjusted based on the time delta to ensure consistency
                attemptDragRectPartial(isActive, dx, dy, true)
                updateTimeValueExtentsForArea(areas[isActive])
                local newMinTicks, newMaxTicks = areas[isActive].timeValue.ticks.min, areas[isActive].timeValue.ticks.max
                local newMinVals, newMaxVals = areas[isActive].timeValue.vals.min, areas[isActive].timeValue.vals.max

                for _, testArea in ipairs(areas) do
                  if testArea ~= areas[isActive] then
                    testArea.timeValue.ticks:shift(newMinTicks - oldMinTicks, newMaxTicks - oldMaxTicks)
                    if not testArea.fullLane and testArea.ccLane == areas[isActive].ccLane then
                      testArea.timeValue.vals:shift(newMinVals - oldMinVals, newMaxVals - oldMaxVals)
                    end
                    updateTimeValueTime(testArea)
                    updateAreaFromTimeValue(testArea)
                  end
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

    if resizing == RS_NEWAREA then
      local earlyReturn = false
      if areas[#areas].logicalRect then
        if (areas[#areas].logicalRect:width() < 5 or areas[#areas].logicalRect:height() < 5) then
          if deferredClearAll or mod.setCursorMod() then
            earlyReturn = true
          end
        end

        if meState.noteTab then
          -- bottomPixel is relative (0-based)
          local bottomPixel = math.floor(((#meState.noteTab - (127 - meState.topPitch)) * meState.pixelsPerPitch) + 0.5)
          if areas[#areas].logicalRect.y1 > bottomPixel then
            earlyReturn = true
          end
        end
      end

      if earlyReturn then
        clearArea(#areas)
        if mod.setCursorMod() then
          local _, currentTick = quantizeToGrid(mx, true)
          r.SetEditCurPos2(0, r.MIDI_GetProjTimeFromPPQPos(glob.liceData.editorTake, currentTick), false, false)
          createUndoStep('Move edit cursor') -- ... to b.b.u?
        end

        resetState()
        lastPoint = nil
        lastPointQuantized = nil
        return
      end
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
        area.controlPoints = nil
      end

      for idx = #removals, 1, -1 do
        clearArea(idx)
      end

      local undoText
      if stretching and resizing ~= RS_NEWAREA then
        if #removals ~= 0 then undoText = 'Delete Razor Edit Area'
        elseif resizing ~= RS_MOVEAREA then undoText = 'Scale Razor Edit Area'
        elseif not mod.onlyAreaMod() then undoText = 'Move Razor Edit Area Contents'
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
  if not didStartup then return end  -- Don't cleanup if we never actually started

  -- if we add more stuff, we can add a registry for startup & shutdown funs
  -- and maybe a selection of cleanup functions. anyway, this is fine as a stopgap
  slicer.shutdown(lice.destroyBitmap)
  pitchbend.shutdown(lice.destroyBitmap)

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

local function getEditableTakes(me)
  local take = nil
  if me then
    local takeTab = {}
    local ct = 0
    while true do
      local t = r.MIDIEditor_EnumTakes(me, ct, true)
      if not t then break end
      takeTab[#takeTab + 1] = t
      ct = ct + 1
    end
    return takeTab
  end
  return nil
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
  glob.liceData.allTakes = getEditableTakes(currEditor)

  glob.wantsAnalyze = glob.wantsAnalyze or glob.editorIsForeground or pitchbend.isConfigDialogOpen()
  if not glob.wantsAnalyze then
    analyzeCheckTime = analyzeCheckTime or glob.currentTime -- check periodically
    if glob.currentTime > analyzeCheckTime + 0.2 then glob.wantsAnalyze = true end
  end

  if not currentMode or r.GetToggleCommandStateEx(32060, currentMode) ~= 1 then
    glob.wantsAnalyze = true
    currentMode = getCurrentMode()
  end

  if glob.wantsAnalyze then
    analyzeCheckTime = (analyzeCheckTime and (glob.editorIsForeground or pitchbend.isConfigDialogOpen())) and glob.currentTime or nil
    local _, noteRowsChanged = analyzeChunk()
    if noteRowsChanged then clearAreas() end
  end

  local wantsUndo = false
  local stateChangeCt = r.GetProjectStateChangeCount(0)
  if prjStateChangeCt and prjStateChangeCt ~= stateChangeCt then
    wantsUndo = true
    mu.MIDI_ForceNextTransaction()
  end
  prjStateChangeCt = stateChangeCt

  if justLoaded or wantsUndo then
    checkProjectExtState(justLoaded)
    justLoaded = false

    if startupOptions then
      if startupOptions & glob.STARTUP_SELECTED_NOTES ~= 0 then
        clearAreas()
        createAreaForSelectedNotes()
        swapAreas(areas)
      elseif startupOptions & glob.STARTUP_SLICER_MODE ~= 0 then
        glob.inSlicerMode = true
        glob.slicerQuitAfterProcess = true
      elseif startupOptions & glob.STARTUP_PITCHBEND_MODE ~= 0 then
        glob.inPitchBendMode = true
        glob.pitchBendQuitOnToggle = true
        -- activeChannel is restored from ProjExtState in handleState (or falls back to editor's channel)
      end
    end
  end

  -- Intercept keyboard when focused and areas are present
  local focusWindow = glob.editorIsForeground and r.JS_Window_GetFocus() or nil
  if focusWindow
    and (focusWindow == currEditor
      or focusWindow == glob.liceData.midiview -- don't call into JS_Window_IsChild unless necessary
      or focusWindow == lice.childHWND()
      or r.JS_Window_IsChild(currEditor, focusWindow))
  then
    lice.attendKeyIntercepts(#areas == 0)
    processKeys()
  else
    lice.ignoreKeyIntercepts()
  end

  if wantsQuit then return end

  updateAreasFromTimeValue(glob.wantsAnalyze)
  glob.wantsAnalyze = false

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
  if wantsQuit then return end  -- Already detected multiple instance

  didStartup = true
  sectionID, commandID = secID, cmdID

  local _, _, _, _, _, _, _, contextstr = reaper.get_action_context()

  contextMods = 0
  local ctxFlags, ctxCode = string.match(contextstr, 'key:([%w%p]*):(%d+)')
  if ctxFlags and ctxFlags ~= '' then
    if string.match(ctxFlags, 'V') then
      if string.match(ctxFlags, 'A') then contextMods = contextMods | 4 end
      if string.match(ctxFlags, 'S') then contextMods = contextMods | 1 end
      if string.match(ctxFlags, 'C') then contextMods = contextMods | 2 end
      if string.match(ctxFlags, 'W') then contextMods = contextMods | 8 end
    end
  end
  contextCode = tonumber(ctxCode)
  -- _P(contextstr, ctxFlags, ctxCode, contextMods)

  r.set_action_options(1)
  r.SetToggleCommandState(sectionID, commandID, 1)
  r.RefreshToolbar2(sectionID, commandID)

  helper.VKeys_ClearState()  -- clear stuck keys from previous session

  justLoaded = true
  restorePreferences()

  lice.recalcConstants(true)

  if PROFILING then
    local lMu, lGlob, lClasses, lLice, lKeys, lHelper = mu, glob, classes, lice, keys, helper
    profiler.attachToWorld() -- after all functions have been defined
    profiler.attachTo('lMu', { recursive = false })
    profiler.attachTo('lGlob', { recursive = false })
    profiler.attachTo('lClasses', { recursive = false })
    profiler.attachTo('lLice', { recursive = false })
    profiler.attachTo('lKeys', { recursive = false })
    profiler.attachTo('lHelper', { recursive = false })
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

prevKeys = helper.VKeys_GetState(10)

return Lib
