--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Slicer = {}

local r = reaper

local classes = require 'MIDIRazorEdits_Classes'
local glob = require 'MIDIRazorEdits_Global'
local helper = require 'MIDIRazorEdits_Helper'
local mod = require 'MIDIRazorEdits_Keys'.mod

local equalIsh = helper.equalIsh
local Rect = classes.Rect
local Point = classes.Point

local OP_SLICE = 50

local slicerDefaultTrim = false

local slicerPoints = nil
local slicerPointsQuantized = nil
local slicerPointsUnquantized = nil
local slicerBitmap = nil

local function getSlicerPoints()
	return slicerPoints
end

local function getSlicerBitmap()
	return slicerBitmap
end

local function setSlicerBitmap(bitmap)
	slicerBitmap = bitmap
end

local function handleState(scriptID)
  slicerDefaultTrim = false -- default

	local stateVal
	stateVal = r.GetExtState(scriptID, 'slicerDefaultTrim')
  if stateVal then
    stateVal = tonumber(stateVal)
    if stateVal then slicerDefaultTrim = stateVal == 1 and true or false end
  end
end

local function calculateSlicerIntersections(area)
  local intersections = {}
  local logRect = area.logicalRect

  local revX = not equalIsh(area.origin.x, logRect.x1)
  local revY = equalIsh(area.origin.y, logRect.y1)
  local x1 = revX and area.timeValue.ticks.max or area.timeValue.ticks.min
  local y1 = revY and area.timeValue.vals.max or area.timeValue.vals.min
  local x2 = revX and area.timeValue.ticks.min or area.timeValue.ticks.max
  local y2 = revY and area.timeValue.vals.min or area.timeValue.vals.max

  -- line slope (dy/dx)
  local dx = x2 - x1
  local dy = y2 - y1

  local rows = (area.timeValue.vals.max - area.timeValue.vals.min) + 1
  -- vertical line case
  if dx == 0 then
    for row = 0, rows - 1 do
      intersections[row] = x1
    end
    return intersections
  end

  -- For each row, find where the line crosses it
  for row = 0, rows - 1 do
    -- Calculate the y-coordinate for this row
    local row_y = area.timeValue.vals.min + (row / (rows - 1)) * (area.timeValue.vals.max - area.timeValue.vals.min)

    -- Solve for x: x = x1 + (row_y - y1) * (dx / dy)
    local t = (row_y - y1) / dy
    local intersection_x = x1 + t * dx

    -- Clamp to bounding box if needed
    intersection_x = math.max(area.timeValue.ticks.min, math.min(area.timeValue.ticks.max, intersection_x))

    intersections[row] = intersection_x
    -- _P('intersections['..row..'] = ' .. intersection_x)
  end

  return #intersections ~= 0 and intersections or nil
end

local function handleSlicer(areaProcessor, quantized)
  if slicerPoints
    and slicerPoints.start and slicerPoints.stop
    and not slicerPoints.start:equals(slicerPoints.stop)
  then
    local x1, y1, x2, y2 = slicerPoints.start.x, slicerPoints.start.y, slicerPoints.stop.x, slicerPoints.stop.y
    if quantized then mod.setForceSnap(true) end
    areaProcessor({ viewRect = Rect.new(x1, y1, x2, y2):conform(),
                    logicalRect = Rect.new(x1, y1, x2, y2):conform(),
                    origin = Point.new(x1, y1),
                    ccLane = nil,
                    ccType = nil }, OP_SLICE, not quantized and true or false)
    if quantized then mod.setForceSnap(false) end
  end
end

local function processSlicer(mx, my, mouseState, areaProcessor, quantizer)
  if glob.inSlicerMode then
    local undoText = nil
    -- only straight line or freeform?
    -- beat-quantized or linear?
    -- my instinct is that pure linear straight-line is 99% of the usage
    -- but that other modes will be requested (because they always are...)

    -- maybe we want to draw/adjust this line, and then enter to process
    -- this is fine for proof of concept
    glob.setCursor(glob.slicer_cursor)

    local meLanes = glob.meLanes
    local meState = glob.meState

    -- adjust my to snap to notes
    my = my < meLanes[-1].topPixel and meLanes[-1].topPixel or my > meLanes[-1].bottomPixel and meLanes[-1].bottomPixel or my
    my = math.floor((math.floor(((my - meLanes[-1].topPixel) / meState.pixelsPerPitch) + 0.5) * meState.pixelsPerPitch) + meLanes[-1].topPixel + 0.5)

    local vertLock = mod.slicerVertLockMod(mouseState.hottestMods)

    if mouseState.ccLane == nil then
      if mouseState.clicked then
        slicerPointsUnquantized = { start = Point.new(mx, my), stop = nil }
        local q = quantizer(mx, false, true)
        slicerPointsQuantized = { start = Point.new(q, my), stop = nil } -- always get this
      elseif mouseState.dragging then
				if slicerPoints and slicerPointsUnquantized and slicerPointsQuantized then -- eliminate warnings
					if vertLock then mx = slicerPoints.start.x end
					slicerPointsUnquantized.stop = Point.new(mx, my)
					-- local q = quantizer(mx, false, true)
					slicerPointsQuantized.stop = Point.new(mx, my)
				end
      end
    end

    local quantized = mod.snapMod(mouseState.hottestMods) -- false -- mod.slicerVertLockMod(mouseState.hottestMods)
    slicerPoints = quantized and slicerPointsQuantized or slicerPointsUnquantized

    -- or should release only work if we're over the note lane, otherwise cancel?
    if mouseState.released then
      -- finish line and perform slice
      handleSlicer(areaProcessor, quantized)
      slicerPoints = nil
      slicerPointsUnquantized = nil
      slicerPointsQuantized = nil
      undoText = 'Slice Notes'
    end

    return true, undoText
  end
  return false
end

local function processNotes(activeTake, area, processInfo)
	local sourceEvents = processInfo.sourceEvents
	local tInsertions = processInfo.tInsertions
	local tDeletions = processInfo.tDeletions
	local mu = processInfo.mu
	local rv = false

	local intersectionsPerRow = calculateSlicerIntersections(area)
	if intersectionsPerRow then
		local wantsTrim = mod.slicerTrimMod()
		if slicerDefaultTrim then wantsTrim = not wantsTrim end -- reverse meaning

		local endMod = mod.slicerEndMod()

		if not wantsTrim then
			mu.MIDI_SelectAll(activeTake, false) -- first unselect everything in the take (should do for non-matching takes, too?)
		end
		for _, event in ipairs(sourceEvents) do
			local ppqIntersection = intersectionsPerRow[event.pitch - area.timeValue.vals.min]
			if ppqIntersection and event.ppqpos <= ppqIntersection and event.endppqpos >= ppqIntersection then
				helper.addUnique(tDeletions, { type = mu.NOTE_TYPE, idx = event.idx })
				if (wantsTrim and endMod) or not wantsTrim then
					helper.addUnique(tInsertions, { type = mu.NOTE_TYPE,
																					selected = wantsTrim and event.selected or (not endMod and true or false),
																					muted = event.muted,
																					ppqpos = event.ppqpos,
																					endppqpos = ppqIntersection,
																					chan = event.chan,
																					pitch = event.pitch,
																					vel = event.vel,
																					relvel = event.relvel })
				end
				if (wantsTrim and not endMod) or not wantsTrim then
					helper.addUnique(tInsertions, { type = mu.NOTE_TYPE,
																					selected = wantsTrim and event.selected or (endMod and true or false),
																					muted = event.muted,
																					ppqpos = ppqIntersection,
																					endppqpos = event.endppqpos,
																					chan = event.chan,
																					pitch = event.pitch,
																					vel = event.vel,
																					relvel = event.relvel })
				end
				rv = true
			end
		end
	end
	return rv
end

Slicer.handleState = handleState
Slicer.processSlicer = processSlicer
Slicer.processNotes = processNotes
Slicer.OP_SLICE = OP_SLICE

Slicer.getSlicerPoints = getSlicerPoints
Slicer.getSlicerBitmap = getSlicerBitmap
Slicer.setSlicerBitmap = setSlicerBitmap

return Slicer
