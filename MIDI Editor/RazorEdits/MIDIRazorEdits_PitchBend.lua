--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local PitchBend = {}

local r = reaper

local glob = require 'MIDIRazorEdits_Global'
local mod = require 'MIDIRazorEdits_Keys'.mod
local helper = require 'MIDIRazorEdits_Helper'
local coords = require 'MIDIRazorEdits_Coords'

-- scala tuning file parser
local scl = require 'lib.lua-scala.scl'

-- midiutils will be set via setMIDIUtils() from Lib
local mu = nil

-- constants
local PB_CENTER = coords.PB_CENTER
local PB_MAX = coords.PB_MAX
local CHANMSG_PITCHBEND = 0xE0
local NOTE_NAMES = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }

local function pitchToNoteName(pitch)
  local basePitch = math.floor(pitch + 0.5)  -- Round to nearest semitone
  local fraction = pitch - basePitch
  local octave = math.floor(basePitch / 12) - 1
  local noteIndex = (basePitch % 12) + 1
  local name = NOTE_NAMES[noteIndex] .. octave
  if fraction > 0.005 then
    name = name .. '+'
  elseif fraction < -0.005 then
    name = name .. '-'
  end
  return name
end

-- curve types
local CURVE_STEP = 0
local CURVE_LINEAR = 1
local CURVE_SLOW_START = 2
local CURVE_SLOW_END = 3
local CURVE_BEZIER = 4

-- configuration (will be loaded from ExtState)
local DRAG_CROSS_CLAMP = 0   -- clamp at neighbor ±1 ppq (REAPER default)
local DRAG_CROSS_ABSORB = 1  -- absorb crossed points, delete on commit

local config = {
  maxBendUp = 48,       -- semitones (MPE default)
  maxBendDown = 48,
  snapToSemitone = true,  -- default on, modifier disables
  curveType = CURVE_STEP,
  showAllNotes = true,
  activeChannel = 0,    -- 0-15
  dragCrossMode = DRAG_CROSS_CLAMP, -- default matches REAPER CC editor
  sclDirectory = nil,
  tuningFile = nil,     -- nil = 12-TET
  tuningScale = nil,
  showMicrotonalLines = false,
  -- colors (nil = use theme, value = user override)
  lineColor = nil,
  pointColor = nil,
  selectedColor = nil,
  hoveredColor = nil,
}

-- system defaults (from ExtState, set via Settings.lua)
local systemDefaults = {
  maxBendUp = 48,
  maxBendDown = 48,
  tuningFile = nil,
  -- color overrides (nil = use theme color)
  lineColor = nil,            -- curve line color (0xAARRGGBB)
  pointColor = nil,           -- unselected point color
  selectedColor = nil,        -- selected point color
  hoveredColor = nil,         -- hovered point color
}

-- project overrides (from ProjExtState, set via in-script dialog)
-- nil = use system default, value = project-specific override
local projectOverrides = {
  maxBendUp = nil,
  maxBendDown = nil,
  tuningFile = nil,  -- "" means explicitly 12-TET, nil means use system
}

-- state
local pbPoints = {}           -- Per-channel PB point data: { [chan] = { { ppqpos, value, selected, hovered } ... } }
local hoveredPoint = nil      -- Point under mouse
local hoveredCurve = nil      -- Curve segment under mouse (for bezier tension editing)
local dragState = nil         -- Current drag operation
local lastTooltipText = nil
local notesByChannel = {}     -- Notes per channel for reference pitch lookup
local clipboardSpan = nil     -- stashed at copy time: { minPpq, maxPpq, channels = { [chan]=true } }

-- center line state for compress/expand
local centerLineState = {
  active = false,             -- True when Cmd held, showing center line
  screenY = nil,              -- Screen Y position of center line
  semitones = 0,              -- Semitone offset value at center line
  locked = false,             -- True once clicked, during drag
}

-- draw mode state
local drawState = nil         -- { chan, path = {{ppq, pbValue, screenX, screenY}, ...}, lastPbValue, smooth }

-- dirty flag for draw optimization (skip redraw when nothing visual changed)
local pbNeedsRedraw = true

local function setTooltip(text, x, y, topmost)
  -- only skip redundant clears; non-empty tooltips need regular refresh to stay visible
  if text == '' and lastTooltipText == '' then return end
  lastTooltipText = text
  r.TrackCtl_SetToolTip(text, x, y, topmost)
end

-- cache for change detection
local cache = {
  take = nil,           -- Track active take changes
  midiHash = nil,       -- Track MIDI data changes
  viewState = {         -- Track view changes for screen coord updates
    timeBase = nil,
    pixelsPerSecond = nil,
    leftmostTime = nil,
    pixelsPerTick = nil,
    leftmostTick = nil,
    pixelsPerPitch = nil,
    laneTopPixel = nil,
    laneTopValue = nil,
  },
}

-- cache for getScaleSnapLines (invalidated on config/view change)
local snapLineCache = {}  -- { [refPitch] = lines }
local snapLineCacheKey = nil  -- serialized config+view state for invalidation

-- sorted unique pitches from PB-associated notes (rebuilt on MIDI change)
local uniquePitchList = {}  -- sorted array of unique pitches

-- check if view state has changed (requires screen coord update)
local function viewStateChanged()
  local meState = glob.meState
  local meLanes = glob.meLanes
  local vs = cache.viewState

  local lane = meLanes and meLanes[-1]
  if not lane then return true end  -- No lane data yet, force update

  return vs.timeBase ~= meState.timeBase
      or vs.pixelsPerSecond ~= meState.pixelsPerSecond
      or vs.leftmostTime ~= meState.leftmostTime
      or vs.pixelsPerTick ~= meState.pixelsPerTick
      or vs.leftmostTick ~= meState.leftmostTick
      or vs.pixelsPerPitch ~= meState.pixelsPerPitch
      or vs.laneTopPixel ~= lane.topPixel
      or vs.laneTopValue ~= lane.topValue
end

-- update view state cache after screen coords updated
local function updateViewStateCache()
  local meState = glob.meState
  local meLanes = glob.meLanes
  local vs = cache.viewState
  local lane = meLanes and meLanes[-1]

  vs.timeBase = meState.timeBase
  vs.pixelsPerSecond = meState.pixelsPerSecond
  vs.leftmostTime = meState.leftmostTime
  vs.pixelsPerTick = meState.pixelsPerTick
  vs.leftmostTick = meState.leftmostTick
  vs.pixelsPerPitch = meState.pixelsPerPitch
  if lane then
    vs.laneTopPixel = lane.topPixel
    vs.laneTopValue = lane.topValue
  end
end

-- clear cache (call when mode exits or take changes)
local function clearCache()
  cache.take = nil
  cache.midiHash = nil
  for k in pairs(cache.viewState) do
    cache.viewState[k] = nil
  end
  pbNeedsRedraw = true
end

local function pbToSemitones(pbValue)
  return coords.pbToSemitones(pbValue, config.maxBendUp, config.maxBendDown)
end

local function semitonesToPb(semitones)
  return coords.semitonesToPb(semitones, config.maxBendUp, config.maxBendDown)
end

local function snapToSemitone(semitones)
  return coords.snapToSemitone(semitones)
end

local function snapToMicrotonal(semitones, scale)
  return coords.snapToMicrotonal(semitones, scale)
end

-- clamp semitones to configured bend range
local function clampSemitones(semitones)
  return math.max(-config.maxBendDown, math.min(config.maxBendUp, semitones))
end

-- XOR toggle: returns true when default is on and toggle is off, or vice versa
local function shouldSnapToggle(default, toggle)
  return (default and not toggle) or (not default and toggle)
end

-- snap PPQ to grid, returns snapped value (no-op if no grid)
local function snapPpqToGrid(ppqpos, take)
  if not take or not glob.currentGrid then return ppqpos end
  local gridUnit = mu.MIDI_GetPPQ(take) * glob.currentGrid
  local som = r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)
  local tickInMeasure = ppqpos - som
  return som + (gridUnit * math.floor((tickInMeasure / gridUnit) + 0.5))
end

-- deselect all PB points across all channels
local function deselectAll()
  for _, points in pairs(pbPoints) do
    for _, pt in ipairs(points) do
      pt.selected = false
    end
  end
end

-- check if any PB point is selected
local function hasSelection()
  for _, points in pairs(pbPoints) do
    for _, pt in ipairs(points) do
      if pt.selected then return true end
    end
  end
  return false
end

local function pbToBytes(pbValue)
  return coords.pbToBytes(pbValue)
end

local function bytesToPb(msg2, msg3)
  return coords.bytesToPb(msg2, msg3)
end

-- write selected points back to MIDI (values already updated in-memory)
-- returns true if any points were written
local function commitSelectedToMIDI(take, selectedStarts)
  if not take or not mu or not selectedStarts then return false end
  mu.MIDI_OpenWriteTransaction(take)
  for _, sel in ipairs(selectedStarts) do
    local msg2, msg3 = pbToBytes(sel.point.pbValue)
    mu.MIDI_SetCC(take, sel.point.idx,
      sel.point.selected,
      sel.point.muted,
      sel.point.ppqpos,
      CHANMSG_PITCHBEND,
      sel.chan,
      msg2, msg3)
  end
  mu.MIDI_CommitWriteTransaction(take, true, true)
  return true
end

-- recalculate semitones for all points (call when bend range changes)
local function recalcSemitones()
  for chan, points in pairs(pbPoints) do
    for _, pt in ipairs(points) do
      pt.semitones = pbToSemitones(pt.pbValue)
    end
  end
  -- clear view cache to trigger screen coord update
  for k in pairs(cache.viewState) do
    cache.viewState[k] = nil
  end
end

local function pbToScreenY(semitoneOffset, notePitch)
  local meLanes = glob.meLanes
  local meState = glob.meState
  if not meLanes[-1] or not meState.pixelsPerPitch then return nil end
  return coords.semitonesToScreenY(semitoneOffset, notePitch,
    meLanes[-1].topPixel, meLanes[-1].topValue, meState.pixelsPerPitch)
end

local function screenYToPitch(screenY)
  local meLanes = glob.meLanes
  local meState = glob.meState
  if not meLanes or not meLanes[-1] or not meState or not meState.pixelsPerPitch then return 60 end
  return coords.screenYToPitch(screenY, meLanes[-1].topPixel, meLanes[-1].topValue, meState.pixelsPerPitch)
end

local function screenYToSemitones(screenY, refPitch)
  local meLanes = glob.meLanes
  local meState = glob.meState
  if not meLanes or not meLanes[-1] or not meState or not meState.pixelsPerPitch then return 0 end
  return coords.screenYToSemitones(screenY, refPitch,
    meLanes[-1].topPixel, meLanes[-1].topValue, meState.pixelsPerPitch)
end

local function ppqToScreenX(ppqpos, take)
  local meState = glob.meState
  if not take then return nil end

  if meState.timeBase == 'time' then
    return coords.ppqToScreenX_Time(ppqpos, take, 0, meState.leftmostTime, meState.pixelsPerSecond)
  else
    return coords.ppqToScreenX_Tick(ppqpos, 0, meState.leftmostTick, meState.pixelsPerTick)
  end
end

local function screenXToPpq(screenX, take)
  local meState = glob.meState
  if not take then return nil end

  if meState.timeBase == 'time' then
    return coords.screenXToPPQ_Time(screenX, take, 0, meState.leftmostTime, meState.pixelsPerSecond)
  else
    return coords.screenXToPPQ_Tick(screenX, 0, meState.leftmostTick, meState.pixelsPerTick)
  end
end

-- get pixels per PPQ unit for delta calculations (approximate in time mode)
local function getPixelsPerPpq(take)
  local meState = glob.meState
  if meState.timeBase == 'time' then
    -- time mode: approximate using PPQ (tempo-dependent)
    if not meState.pixelsPerSecond or not take then return nil end
    local ppq = mu.MIDI_GetPPQ(take) or 960
    -- at 120 BPM: 1 beat = 0.5 sec, so pixelsPerPpq = pixelsPerSecond * 0.5 / ppq
    -- get actual tempo at current position for better accuracy
    local cursorTime = r.GetCursorPosition()
    local tempo = r.TimeMap_GetDividedBpmAtTime(cursorTime) or 120
    local secsPerBeat = 60 / tempo
    return meState.pixelsPerSecond * secsPerBeat / ppq
  else
    return meState.pixelsPerTick
  end
end

local function getActiveChannelFilter()
  if config.showAllNotes then return nil end
  return config.activeChannel
end

-- hit test: check if mouse position is near a PB point
local function hitTestPoint(mx, my, tolerance)
  tolerance = tolerance or 8
  local activeChannel = getActiveChannelFilter()
  for chan, points in pairs(pbPoints) do
    if not activeChannel or chan == activeChannel then
      for i, pt in ipairs(points) do
        if pt.screenX and pt.screenY then
          local dx = math.abs(mx - pt.screenX)
          local dy = math.abs(my - pt.screenY)
          if dx <= tolerance and dy <= tolerance then
            return { chan = chan, index = i, point = pt }
          end
        end
      end
    end
  end
  return nil
end

-- hit test for curve segments (between points)
-- returns the starting point of the segment (which owns the beztension)
-- hit region: middle 85% horizontally, 16px vertically from the Y range
local function hitTestCurve(mx, my)
  local tolerance = 16
  local activeChannel = getActiveChannelFilter()
  for chan, points in pairs(pbPoints) do
    if not activeChannel or chan == activeChannel then
      for i = 1, #points - 1 do
        local pt1 = points[i]
        local pt2 = points[i + 1]
        if pt1.screenX and pt1.screenY and pt2.screenX and pt2.screenY then
          local minX = math.min(pt1.screenX, pt2.screenX)
          local maxX = math.max(pt1.screenX, pt2.screenX)
          local spanX = maxX - minX
          -- middle 85% of horizontal span
          local hitMinX = minX + spanX * 0.075
          local hitMaxX = maxX - spanX * 0.075
          -- y range with tolerance
          local minY = math.min(pt1.screenY, pt2.screenY) - tolerance
          local maxY = math.max(pt1.screenY, pt2.screenY) + tolerance

          if mx >= hitMinX and mx <= hitMaxX and my >= minY and my <= maxY then
            return { chan = chan, index = i, point = pt1, nextPoint = pt2 }
          end
        end
      end
    end
  end
  return nil
end

-- load tuning file helper
local function loadTuningFromFile(filename)
  if not filename or filename == '' then
    return nil
  end
  if config.sclDirectory then
    local path = config.sclDirectory .. '/' .. filename
    local ok, result = pcall(function() return scl.Scale.load(path) end)
    if ok and result then
      return result
    end
  end
  return nil
end

-- forward declarations for mutual recursion
local loadProjectState
local applyEffectiveConfig

-- apply effective config from system defaults + project overrides
applyEffectiveConfig = function()
  -- bend range: project override or system default
  if projectOverrides.maxBendUp ~= nil then
    config.maxBendUp = projectOverrides.maxBendUp
  else
    config.maxBendUp = systemDefaults.maxBendUp
  end

  if projectOverrides.maxBendDown ~= nil then
    config.maxBendDown = projectOverrides.maxBendDown
  else
    config.maxBendDown = systemDefaults.maxBendDown
  end

  -- tuning: project override or system default
  -- projectOverrides.tuningFile == "" means explicitly 12-TET
  -- projectOverrides.tuningFile == nil means use system default
  local tuningFile
  if projectOverrides.tuningFile ~= nil then
    tuningFile = projectOverrides.tuningFile ~= '' and projectOverrides.tuningFile or nil
  else
    tuningFile = systemDefaults.tuningFile
  end

  config.tuningFile = tuningFile
  config.tuningScale = loadTuningFromFile(tuningFile)

  -- colors (system defaults only, no project overrides)
  config.lineColor = systemDefaults.lineColor
  config.pointColor = systemDefaults.pointColor
  config.selectedColor = systemDefaults.selectedColor
  config.hoveredColor = systemDefaults.hoveredColor
end

-- handle ExtState preferences (system defaults)
local function handleState(scriptID)
  local stateVal

  stateVal = r.GetExtState(scriptID, 'pbMaxBendUp')
  if stateVal and stateVal ~= '' then
    local val = tonumber(stateVal)
    if val then systemDefaults.maxBendUp = val end
  else
    systemDefaults.maxBendUp = 48
  end

  stateVal = r.GetExtState(scriptID, 'pbMaxBendDown')
  if stateVal and stateVal ~= '' then
    local val = tonumber(stateVal)
    if val then systemDefaults.maxBendDown = val end
  else
    systemDefaults.maxBendDown = 48
  end

  stateVal = r.GetExtState(scriptID, 'pbSnapToSemitone')
  if stateVal and stateVal ~= '' then
    config.snapToSemitone = stateVal == '1'
  else
    config.snapToSemitone = true
  end

  stateVal = r.GetExtState(scriptID, 'pbCurveType')
  if stateVal and stateVal ~= '' then
    local val = tonumber(stateVal)
    if val then config.curveType = val end
  else
    config.curveType = CURVE_STEP
  end

  stateVal = r.GetExtState(scriptID, 'pbShowAllNotes')
  if stateVal and stateVal ~= '' then
    config.showAllNotes = stateVal == '1'
  else
    config.showAllNotes = true
  end

  stateVal = r.GetExtState(scriptID, 'pbDragCrossMode')
  if stateVal and stateVal ~= '' then
    local val = tonumber(stateVal)
    if val then config.dragCrossMode = val end
  else
    config.dragCrossMode = DRAG_CROSS_CLAMP
  end

  stateVal = r.GetExtState(scriptID, 'pbSclDirectory')
  if not stateVal or stateVal == '' then
    stateVal = '~/Documents/scl'  -- Default
  end
  -- expand ~ to home directory
  if stateVal:sub(1, 1) == '~' then
    local home = os.getenv('HOME') or os.getenv('USERPROFILE') or ''
    stateVal = home .. stateVal:sub(2)
  end
  config.sclDirectory = stateVal

  stateVal = r.GetExtState(scriptID, 'pbTuningFile')
  if stateVal and stateVal ~= '' then
    systemDefaults.tuningFile = stateVal
  else
    systemDefaults.tuningFile = nil
  end

  -- color overrides (nil = use theme)
  stateVal = r.GetExtState(scriptID, 'pbLineColor')
  systemDefaults.lineColor = (stateVal and stateVal ~= '') and tonumber(stateVal) or nil

  stateVal = r.GetExtState(scriptID, 'pbPointColor')
  systemDefaults.pointColor = (stateVal and stateVal ~= '') and tonumber(stateVal) or nil

  stateVal = r.GetExtState(scriptID, 'pbSelectedColor')
  systemDefaults.selectedColor = (stateVal and stateVal ~= '') and tonumber(stateVal) or nil

  stateVal = r.GetExtState(scriptID, 'pbHoveredColor')
  systemDefaults.hoveredColor = (stateVal and stateVal ~= '') and tonumber(stateVal) or nil

  -- load project overrides and apply effective config
  loadProjectState(scriptID)
  applyEffectiveConfig()
end

-- load project-specific overrides
loadProjectState = function(scriptID)
  local rv, stateVal

  -- reset overrides
  projectOverrides.maxBendUp = nil
  projectOverrides.maxBendDown = nil
  projectOverrides.tuningFile = nil

  -- note: GetProjExtState returns string length (0 if not found), not 1/0
  rv, stateVal = r.GetProjExtState(0, scriptID, 'pbMaxBendUp')
  if rv > 0 and stateVal ~= '' then
    local val = tonumber(stateVal)
    if val then projectOverrides.maxBendUp = val end
  end

  rv, stateVal = r.GetProjExtState(0, scriptID, 'pbMaxBendDown')
  if rv > 0 and stateVal ~= '' then
    local val = tonumber(stateVal)
    if val then projectOverrides.maxBendDown = val end
  end

  rv, stateVal = r.GetProjExtState(0, scriptID, 'pbTuningFile')
  if rv > 0 then
    -- "NONE" sentinel means explicitly 12-TET, key not found means use system
    if stateVal == 'NONE' then
      projectOverrides.tuningFile = ''
    else
      projectOverrides.tuningFile = stateVal
    end
  end

  -- restore last-used active channel (saved as 0-indexed) and showAllNotes
  rv, stateVal = r.GetProjExtState(0, scriptID, 'pbActiveChannel')
  if rv > 0 and stateVal ~= '' then
    local val = tonumber(stateVal)
    if val then
      config.activeChannel = val
    end
    -- restore showAllNotes (defaults to false if channel was saved)
    local rv2, showAllVal = r.GetProjExtState(0, scriptID, 'pbShowAllNotes')
    if rv2 > 0 and showAllVal ~= '' then
      config.showAllNotes = showAllVal == '1'
    else
      config.showAllNotes = false
    end
  else
    -- no saved channel: use editor's active channel (1-based in chunk, convert to 0-based)
    local meState = glob.meState
    if meState and meState.activeChannel then
      config.activeChannel = math.max(0, meState.activeChannel - 1)
      config.showAllNotes = false
    end
  end
end

-- save project-specific overrides
local function saveProjectState(scriptID)
  if projectOverrides.maxBendUp ~= nil then
    r.SetProjExtState(0, scriptID, 'pbMaxBendUp', tostring(projectOverrides.maxBendUp))
  else
    r.SetProjExtState(0, scriptID, 'pbMaxBendUp', '')
  end

  if projectOverrides.maxBendDown ~= nil then
    r.SetProjExtState(0, scriptID, 'pbMaxBendDown', tostring(projectOverrides.maxBendDown))
  else
    r.SetProjExtState(0, scriptID, 'pbMaxBendDown', '')
  end

  if projectOverrides.tuningFile ~= nil then
    -- use "NONE" sentinel for 12-TET since empty string can't be distinguished from missing key
    local tuningVal = projectOverrides.tuningFile == '' and 'NONE' or projectOverrides.tuningFile
    r.SetProjExtState(0, scriptID, 'pbTuningFile', tuningVal or 'NONE')
  else
    r.SetProjExtState(0, scriptID, 'pbTuningFile', '')
  end

  r.MarkProjectDirty(0)  -- Ensure project knows it needs saving
end

-- save active channel and showAllNotes to project state (called when channel changes)
local function saveActiveChannel()
  if glob.scriptID then
    r.SetProjExtState(0, glob.scriptID, 'pbActiveChannel', tostring(config.activeChannel))
    r.SetProjExtState(0, glob.scriptID, 'pbShowAllNotes', config.showAllNotes and '1' or '0')
    r.MarkProjectDirty(0)
  end
  if glob.liceData.editor and not config.showAllNotes then
    r.MIDIEditor_OnCommand(glob.liceData.editor, 40775) -- goose whatever this annoying bug is in REAPER (https://forum.cockos.com/showthread.php?p=2917377#post2917377)
    r.MIDIEditor_OnCommand(glob.liceData.editor, config.activeChannel + 40482)
  end
end

-- clear project overrides (revert to system defaults)
local function clearProjectOverrides(scriptID)
  projectOverrides.maxBendUp = nil
  projectOverrides.maxBendDown = nil
  projectOverrides.tuningFile = nil
  -- clear from project file
  r.SetProjExtState(0, scriptID, 'pbMaxBendUp', '')
  r.SetProjExtState(0, scriptID, 'pbMaxBendDown', '')
  r.SetProjExtState(0, scriptID, 'pbTuningFile', '')
  applyEffectiveConfig()
end

-- check if any project overrides are set
local function hasProjectOverrides()
  return projectOverrides.maxBendUp ~= nil
      or projectOverrides.maxBendDown ~= nil
      or projectOverrides.tuningFile ~= nil
end

-- save preferences to ExtState (system defaults - called from Settings.lua context)
local function saveState(scriptID)
  r.SetExtState(scriptID, 'pbMaxBendUp', tostring(systemDefaults.maxBendUp), true)
  r.SetExtState(scriptID, 'pbMaxBendDown', tostring(systemDefaults.maxBendDown), true)
  r.SetExtState(scriptID, 'pbSnapToSemitone', config.snapToSemitone and '1' or '0', true)
  r.SetExtState(scriptID, 'pbCurveType', tostring(config.curveType), true)
  r.SetExtState(scriptID, 'pbShowAllNotes', config.showAllNotes and '1' or '0', true)
  if systemDefaults.tuningFile then
    r.SetExtState(scriptID, 'pbTuningFile', systemDefaults.tuningFile, true)
  else
    r.DeleteExtState(scriptID, 'pbTuningFile', true)
  end
end

-- extract PB events from a take, organized by channel
local function extractPBEvents(take, mu)
  local events = {}
  if not take or not mu then return events end

  local _, _, ccCount = mu.MIDI_CountEvts(take)  -- returns: rv, noteCount, ccCount, syxCount
  for i = 0, ccCount - 1 do
    local rv, selected, muted, ppqpos, chanmsg, chan, msg2, msg3 = mu.MIDI_GetCC(take, i)
    if rv and chanmsg == CHANMSG_PITCHBEND then
      if not events[chan] then events[chan] = {} end
      local pbValue = bytesToPb(msg2, msg3)
      -- get curve shape for this event
      local shapeRv, shape, beztension = mu.MIDI_GetCCShape(take, i)
      table.insert(events[chan], {
        idx = i,
        ppqpos = ppqpos,
        pbValue = pbValue,
        semitones = pbToSemitones(pbValue),
        selected = selected,
        muted = muted,
        msg2 = msg2,
        msg3 = msg3,
        shape = shapeRv and shape or 0,  -- 0=square, 1=linear, 2=slow, 3=fast start, 4=fast end, 5=bezier
        beztension = shapeRv and beztension or 0,
        screenX = nil,
        screenY = nil,
        hovered = false,
      })
    end
  end

  -- sort each channel's events by PPQ position
  for chan, pts in pairs(events) do
    table.sort(pts, function(a, b) return a.ppqpos < b.ppqpos end)
  end

  return events
end

-- find notes associated with each PB event (same channel only)
-- for MPE, PB often arrives before or at note-on, so we need lookahead
-- NOTE: keep in sync with draw-start note selection (~line 1092)
local function associatePBWithNotes(take, pbEvents, mu)
  if not take or not mu then return end

  local _, noteCount = mu.MIDI_CountEvts(take)  -- returns: rv, noteCount, ccCount, syxCount

  -- build note list per channel (store in module-level variable for insertion lookup)
  notesByChannel = {}
  for i = 0, noteCount - 1 do
    local rv, selected, muted, startppq, endppq, noteChan, pitch, vel = mu.MIDI_GetNote(take, i)
    if rv then
      local note = { pitch = pitch, startppq = startppq, endppq = endppq, chan = noteChan }
      if not notesByChannel[noteChan] then notesByChannel[noteChan] = {} end
      table.insert(notesByChannel[noteChan], note)
    end
  end

  -- sort notes by start time
  for chan, notes in pairs(notesByChannel) do
    table.sort(notes, function(a, b) return a.startppq < b.startppq end)
  end

  -- lookahead for upcoming note association (2x grid, min 1/8 beat)
  -- NOTE: keep in sync with draw-start note selection (~line 1120)
  local ppq = take and mu.MIDI_GetPPQ(take) or 960
  local gridLookahead = glob.currentGrid and (ppq * glob.currentGrid * 2) or 0
  local maxLookahead = math.max(gridLookahead, ppq / 8)  -- min 1/8 beat

  for chan, points in pairs(pbEvents) do
    local channelNotes = notesByChannel[chan] or {}
    local noteIdx = 1  -- sliding window cursor into sorted notes
    local nNotes = #channelNotes
    local prevNote = nil  -- continuity: prefer previous point's note if still sounding

    for i, pt in ipairs(points) do
      pt.associatedNotes = {}
      pt.fallbackAssociation = nil

      -- get the next PB event time (for lookahead limit), capped by maxLookahead
      local nextPbTime = points[i + 1] and points[i + 1].ppqpos or (pt.ppqpos + maxLookahead)
      local lookaheadLimit = math.min(nextPbTime, pt.ppqpos + maxLookahead)

      -- continuity: if previous point's note is still sounding, keep that association
      -- (prevents flipping between overlapping notes for consecutive points)
      if prevNote and prevNote.startppq <= pt.ppqpos and prevNote.endppq >= pt.ppqpos then
        table.insert(pt.associatedNotes, prevNote)
      else
        -- advance sliding window: skip notes that ended before this point
        while noteIdx <= nNotes and channelNotes[noteIdx].endppq < pt.ppqpos do
          noteIdx = noteIdx + 1
        end

        -- search from sliding window position: sounding or upcoming within lookahead
        local bestNote = nil
        local bestDist = math.huge
        for j = noteIdx, nNotes do
          local note = channelNotes[j]
          if note.startppq > lookaheadLimit then break end  -- past lookahead window
          local isSounding = note.startppq <= pt.ppqpos and note.endppq >= pt.ppqpos
          local isUpcoming = note.startppq > pt.ppqpos and note.startppq <= lookaheadLimit
          if isSounding or isUpcoming then
            local timeDist = math.abs(note.startppq - pt.ppqpos)
            if timeDist < bestDist then
              bestDist = timeDist
              bestNote = note
            end
          end
        end

        if bestNote then
          table.insert(pt.associatedNotes, bestNote)
        end
      end

      -- update prevNote for next iteration
      prevNote = pt.associatedNotes[1]

      -- fallback: most recently ended note, else closest upcoming
      if #pt.associatedNotes == 0 and nNotes > 0 then
        -- scan backward from window for most recently ended note
        local recentNote = nil
        for j = noteIdx - 1, 1, -1 do
          local note = channelNotes[j]
          if note.endppq <= pt.ppqpos then
            recentNote = note
            break  -- sorted by start, most recent ended note is at highest index
          end
        end
        if recentNote then
          table.insert(pt.associatedNotes, recentNote)
          pt.fallbackAssociation = true
          prevNote = recentNote
        else
          -- closest upcoming note (for events before any notes)
          for j = noteIdx, nNotes do
            local note = channelNotes[j]
            if note.startppq > pt.ppqpos then
              table.insert(pt.associatedNotes, note)
              pt.fallbackAssociation = true
              prevNote = note
              break
            end
          end
        end
      end
    end
  end
end

-- find notes sounding at a given time on a channel
-- returns the note closest to targetPitch if multiple, or first sounding note
-- notesByChannel is sorted by startppq; binary search to find the neighborhood
local function findNoteAtTime(chan, ppqpos, targetPitch)
  local channelNotes = notesByChannel[chan]
  if not channelNotes then return nil end
  local n = #channelNotes
  if n == 0 then return nil end

  -- binary search: find rightmost note with startppq <= ppqpos
  local lo, hi = 1, n
  while lo < hi do
    local mid = lo + math.floor((hi - lo + 1) / 2)
    if channelNotes[mid].startppq <= ppqpos then
      lo = mid
    else
      hi = mid - 1
    end
  end

  -- collect sounding notes: scan backward from lo (notes starting at or before ppqpos)
  -- can't break early on short notes — longer notes at earlier indices may still sound
  local soundingNotes = {}
  for i = lo, 1, -1 do
    local note = channelNotes[i]
    if note.startppq <= ppqpos and note.endppq > ppqpos then
      table.insert(soundingNotes, note)
    end
  end

  if #soundingNotes == 0 then
    -- no sounding note: check lo-1, lo, lo+1 for closest by start/end distance
    local closestNote = channelNotes[lo]
    local closestDist = math.min(math.abs(closestNote.startppq - ppqpos), math.abs(closestNote.endppq - ppqpos))
    for _, idx in ipairs({ lo - 1, lo + 1 }) do
      if idx >= 1 and idx <= n then
        local note = channelNotes[idx]
        local dist = math.min(math.abs(note.startppq - ppqpos), math.abs(note.endppq - ppqpos))
        if dist < closestDist then
          closestDist = dist
          closestNote = note
        end
      end
    end
    return closestNote
  elseif #soundingNotes == 1 then
    return soundingNotes[1]
  else
    -- multiple sounding notes, pick closest to target pitch
    local closestNote = soundingNotes[1]
    if not targetPitch then return closestNote end
    local closestDist = math.abs(soundingNotes[1].pitch - targetPitch)
    for i = 2, #soundingNotes do
      local dist = math.abs(soundingNotes[i].pitch - targetPitch)
      if dist < closestDist then
        closestDist = dist
        closestNote = soundingNotes[i]
      end
    end
    return closestNote
  end
end

-- calculate visible PPQ range with margin for curves that span into view
local function getVisiblePPQRange(take)
  local meState = glob.meState
  local margin = 960  -- ~1 beat margin for curve endpoints
  local leftPPQ = meState.leftmostTick - margin
  local viewWidth = glob.liceData.screenRect:width()  -- screen width
  local rightPPQ
  if meState.timeBase == 'time' then
    local rightTime = meState.leftmostTime + (viewWidth / meState.pixelsPerSecond)
    rightPPQ = r.MIDI_GetPPQPosFromProjTime(take, rightTime) + margin
  else
    rightPPQ = meState.leftmostTick + (viewWidth / meState.pixelsPerTick) + margin
  end
  return leftPPQ, rightPPQ
end

-- update screen coordinates for all PB points (with optional PPQ culling)
local function updateScreenCoords(take, leftPPQ, rightPPQ)
  local meState = glob.meState
  local meLanes = glob.meLanes

  for chan, points in pairs(pbPoints) do
    for _, pt in ipairs(points) do
      -- skip off-screen points if PPQ range provided (clear coords so rendering skips them)
      if leftPPQ and rightPPQ and (pt.ppqpos < leftPPQ or pt.ppqpos > rightPPQ) then
        pt.screenX = nil
        pt.screenY = nil
      else
        pt.screenX = ppqToScreenX(pt.ppqpos, take)
        -- for screen Y, use the first associated note's pitch, or a default
        if pt.associatedNotes and #pt.associatedNotes > 0 then
          pt.screenY = pbToScreenY(pt.semitones, pt.associatedNotes[1].pitch)
        else
          -- no associated note, show relative to middle C (60)
          pt.screenY = pbToScreenY(pt.semitones, 60)
        end
      end
    end
  end
end

-- sync selection state to MIDI data (updates selected flag for all points)
local function syncSelectionToMIDI(take, mu)
  if not take or not mu then return end
  mu.MIDI_OpenWriteTransaction(take)
  for chan, points in pairs(pbPoints) do
    for _, pt in ipairs(points) do
      local msg2, msg3 = pbToBytes(pt.pbValue)
      mu.MIDI_SetCC(take, pt.idx, pt.selected, pt.muted, pt.ppqpos, CHANMSG_PITCHBEND, chan, msg2, msg3)
    end
  end
  mu.MIDI_CommitWriteTransaction(take, false, false)  -- no undo for selection changes
end

-- select all PB points within a screen rect, returns true if any selected
local function marqueeSelectPoints(x1, y1, x2, y2)
  local anySelected = false
  for _, points in pairs(pbPoints) do
    for _, pt in ipairs(points) do
      if pt.screenX and pt.screenY
         and pt.screenX >= x1 and pt.screenX <= x2
         and pt.screenY >= y1 and pt.screenY <= y2 then
        pt.selected = true
        anySelected = true
      end
    end
  end
  return anySelected
end

-- absorb/restore non-selected points crossed by dragged selection
-- returns true if pbPoints changed (needs redraw)
local function sweepAbsorb(dragState, pbPoints)
  if not dragState or not dragState.nonSelected then return false end
  local changed = false

  for chan, nsList in pairs(dragState.nonSelected) do
    -- build sweep range from selected points on this channel
    local sweepMin, sweepMax
    for _, sel in ipairs(dragState.selectedStarts) do
      if sel.chan == chan then
        local lo = math.min(sel.startPpq, sel.point.ppqpos)
        local hi = math.max(sel.startPpq, sel.point.ppqpos)
        if not sweepMin or lo < sweepMin then sweepMin = lo end
        if not sweepMax or hi > sweepMax then sweepMax = hi end
      end
    end
    if not sweepMin then goto nextChan end

    -- absorb: non-selected points inside sweep range
    for i = #nsList, 1, -1 do
      local ns = nsList[i]
      if not ns.absorbed and ns.point.ppqpos > sweepMin and ns.point.ppqpos < sweepMax then
        ns.absorbed = true
        -- remove from pbPoints[chan]
        local pts = pbPoints[chan]
        if pts then
          for j = #pts, 1, -1 do
            if pts[j] == ns.point then
              table.remove(pts, j)
              break
            end
          end
        end
        changed = true
      end
    end

    -- restore: absorbed points no longer inside sweep range
    for i = #nsList, 1, -1 do
      local ns = nsList[i]
      if ns.absorbed and (ns.point.ppqpos <= sweepMin or ns.point.ppqpos >= sweepMax) then
        ns.absorbed = false
        -- insert back into pbPoints[chan] sorted by ppqpos
        local pts = pbPoints[chan]
        if pts then
          local inserted = false
          for j = 1, #pts do
            if pts[j].ppqpos > ns.point.ppqpos then
              table.insert(pts, j, ns.point)
              inserted = true
              break
            end
          end
          if not inserted then pts[#pts + 1] = ns.point end
        end
        changed = true
      end
    end

    ::nextChan::
  end
  return changed
end

-- restore all absorbed points back to pbPoints (for drag cancel)
local function restoreAbsorbed(dragState, pbPoints)
  if not dragState or not dragState.nonSelected then return end
  for chan, nsList in pairs(dragState.nonSelected) do
    for _, ns in ipairs(nsList) do
      if ns.absorbed then
        ns.absorbed = false
        local pts = pbPoints[chan]
        if pts then
          local inserted = false
          for j = 1, #pts do
            if pts[j].ppqpos > ns.point.ppqpos then
              table.insert(pts, j, ns.point)
              inserted = true
              break
            end
          end
          if not inserted then pts[#pts + 1] = ns.point end
        end
      end
    end
  end
end

-- finalize a drag operation on mouse release, returns undo text or nil
local function finalizeDragRelease(activeTake)
  if not dragState then return nil end

  if dragState.isBezierDrag then
    if activeTake and dragState.bezierPoints then
      local anyChanged = false
      for _, bp in ipairs(dragState.bezierPoints) do
        if (bp.point.beztension or 0) ~= bp.startTension then
          anyChanged = true
          break
        end
      end
      if anyChanged then
        mu.MIDI_OpenWriteTransaction(activeTake)
        for _, bp in ipairs(dragState.bezierPoints) do
          mu.MIDI_SetCCShape(activeTake, bp.point.idx, bp.point.shape or 5, bp.point.beztension or 0)
        end
        mu.MIDI_CommitWriteTransaction(activeTake, true, true)
        return 'Adjust Bezier Tension'
      end
    end

  elseif dragState.isCompressExpand and activeTake then
    -- reset center line state after compress/expand completes
    centerLineState.active = false
    centerLineState.locked = false
    local anyChanged = false
    for _, sel in ipairs(dragState.selectedStarts) do
      if sel.point.semitones ~= sel.startSemitones then
        anyChanged = true
        break
      end
    end
    if anyChanged then
      commitSelectedToMIDI(activeTake, dragState.selectedStarts)
      return 'Compress/Expand Pitch Bend'
    end

  elseif dragState.isMarquee and dragState.currentMx then
    local x1 = math.min(dragState.startMx, dragState.currentMx)
    local y1 = math.min(dragState.startMy, dragState.currentMy)
    local x2 = math.max(dragState.startMx, dragState.currentMx)
    local y2 = math.max(dragState.startMy, dragState.currentMy)
    if marqueeSelectPoints(x1, y1, x2, y2) and activeTake then
      syncSelectionToMIDI(activeTake, mu)
      return 'Select Pitch Bend'
    end

  elseif dragState.selectedStarts and #dragState.selectedStarts > 0 and activeTake then
    local anyMoved = false
    for _, sel in ipairs(dragState.selectedStarts) do
      if sel.point.ppqpos ~= sel.startPpq or sel.point.semitones ~= sel.startSemitones then
        anyMoved = true
        break
      end
    end

    -- collect absorbed points for deletion
    local absorbedForDelete = {}
    if dragState.nonSelected then
      for _, nsList in pairs(dragState.nonSelected) do
        for _, ns in ipairs(nsList) do
          if ns.absorbed then
            absorbedForDelete[#absorbedForDelete + 1] = ns.point
          end
        end
      end
      -- sort by idx descending so deletions don't invalidate earlier indices
      table.sort(absorbedForDelete, function(a, b) return a.idx > b.idx end)
    end

    if anyMoved or #absorbedForDelete > 0 then
      mu.MIDI_OpenWriteTransaction(activeTake)
      -- commit moved points
      for _, sel in ipairs(dragState.selectedStarts) do
        local msg2, msg3 = pbToBytes(sel.point.pbValue)
        mu.MIDI_SetCC(activeTake, sel.point.idx,
          sel.point.selected, sel.point.muted,
          sel.point.ppqpos, CHANMSG_PITCHBEND, sel.chan,
          msg2, msg3)
      end
      -- delete absorbed points
      for _, pt in ipairs(absorbedForDelete) do
        mu.MIDI_DeleteCC(activeTake, pt.idx)
      end
      mu.MIDI_CommitWriteTransaction(activeTake, true, true)
      return 'Modify Pitch Bend'
    elseif dragState.pendingDeselect then
      dragState.pendingDeselect.selected = false
      syncSelectionToMIDI(activeTake, mu)
      return 'Select Pitch Bend'
    end
  end

  return nil
end

-- commit drawn path to MIDI, returns undo text or nil
local function commitDrawPath(activeTake)
  if not drawState or not activeTake or #drawState.path == 0 then return nil end

  local chan = drawState.chan
  local path = drawState.path

  table.sort(path, function(a, b) return a.ppq < b.ppq end)

  local minPpq = path[1].ppq
  local maxPpq = path[#path].ppq

  mu.MIDI_OpenWriteTransaction(activeTake)

  -- delete existing PB events in the drawn range on this channel
  local _, _, ccCount = mu.MIDI_CountEvts(activeTake)
  local toDelete = {}
  for i = 0, ccCount - 1 do
    local rv, _, _, ppqpos, chanmsg, evtChan = mu.MIDI_GetCC(activeTake, i)
    if rv and chanmsg == CHANMSG_PITCHBEND and evtChan == chan and ppqpos >= minPpq and ppqpos <= maxPpq then
      table.insert(toDelete, i)
    end
  end
  for i = #toDelete, 1, -1 do
    mu.MIDI_DeleteCC(activeTake, toDelete[i])
  end

  -- insert new events
  for _, pt in ipairs(path) do
    local msg2, msg3 = pbToBytes(pt.pbValue)
    mu.MIDI_InsertCC(activeTake, false, false, pt.ppq, CHANMSG_PITCHBEND, chan, msg2, msg3)
  end

  -- set curve type for new events if needed
  if config.curveType ~= 0 then
    local _, _, newCcCount = mu.MIDI_CountEvts(activeTake)
    for i = 0, newCcCount - 1 do
      local rv, _, _, ppqpos, chanmsg, evtChan = mu.MIDI_GetCC(activeTake, i)
      if rv and chanmsg == CHANMSG_PITCHBEND and evtChan == chan and ppqpos >= minPpq and ppqpos <= maxPpq then
        mu.MIDI_SetCCShape(activeTake, i, config.curveType, 0)
      end
    end
  end

  mu.MIDI_CommitWriteTransaction(activeTake, true, true)
  clearCache()
  return 'Draw Pitch Bend'
end

-- process PB mode (called from main loop)
local function processPitchBend(mx, my, mouseState, mu, activeTake)
  if not glob.inPitchBendMode then return false end

  local undoText = nil
  local selectionChanged = false

  -- data acquisition with caching
  if activeTake and not dragState then
    -- check if take changed
    local takeChanged = cache.take ~= activeTake
    if takeChanged then
      clearCache()
      cache.take = activeTake
    end

    -- check if MIDI data changed (use reaper API directly, not MIDIUtils)
    local _, currentHash = r.MIDI_GetHash(activeTake, false, '')
    local midiChanged = takeChanged or (currentHash ~= cache.midiHash)

    local leftPPQ, rightPPQ = getVisiblePPQRange(activeTake)

    if midiChanged then
      -- force MIDIUtils to re-read the MIDI data (it caches by take pointer)
      mu.MIDI_InitializeTake(activeTake)
      -- full refresh: extract PB data and update screen coords
      pbPoints = extractPBEvents(activeTake, mu)
      associatePBWithNotes(activeTake, pbPoints, mu)
      -- rebuild sorted unique pitch list for center-line binary search
      local pitchSet = {}
      for _, points in pairs(pbPoints) do
        for _, pt in ipairs(points) do
          if pt.associatedNotes then
            for _, note in ipairs(pt.associatedNotes) do
              pitchSet[note.pitch] = true
            end
          end
        end
      end
      uniquePitchList = {}
      for pitch in pairs(pitchSet) do
        uniquePitchList[#uniquePitchList + 1] = pitch
      end
      table.sort(uniquePitchList)
      updateScreenCoords(activeTake, leftPPQ, rightPPQ)
      cache.midiHash = currentHash
      updateViewStateCache()
      pbNeedsRedraw = true
    elseif viewStateChanged() then
      -- view changed but MIDI didn't: just update screen coords
      updateScreenCoords(activeTake, leftPPQ, rightPPQ)
      updateViewStateCache()
      pbNeedsRedraw = true
    end
    -- else: nothing changed, use cached data
  elseif activeTake and dragState then
    -- during drag, always update screen coords for visual feedback
    -- (we're modifying point positions in memory)
    local leftPPQ, rightPPQ = getVisiblePPQRange(activeTake)
    updateScreenCoords(activeTake, leftPPQ, rightPPQ)
    pbNeedsRedraw = true
    if viewStateChanged() then
      updateViewStateCache()
    end
  end

  -- handle mouse outside content area (mx/my nil: ruler, outside editor, etc.)
  if not mx or not my then
    if mouseState.released then
      if dragState or drawState or centerLineState.active then
        pbNeedsRedraw = true
      end
      local outOfBoundsUndo = finalizeDragRelease(activeTake)
      dragState = nil
      drawState = nil  -- cancel draw without committing
      centerLineState.active = false
      centerLineState.locked = false
      return true, outOfBoundsUndo
    end
    return true  -- still in PB mode, just nothing to process
  end

  if mx and my then
    -- hit testing (skip during active drag/draw)
    local optHeld = mod.pbSnapToPitchMod and mod.pbSnapToPitchMod(mouseState.hottestMods)
    if not dragState and not drawState then
      local prevHovered = hoveredPoint
      local prevHoveredCurve = hoveredCurve
      local hit = hitTestPoint(mx, my)
      -- clear previous hovered flag
      if prevHovered then
        prevHovered.point.hovered = false
      end
      if hit then
        hoveredPoint = hit
        hit.point.hovered = true
        hoveredCurve = nil
      else
        hoveredPoint = nil
        -- check for curve hover when not over a point (only for bezier curves)
        if optHeld then
          local curve = hitTestCurve(mx, my)
          if curve and curve.point.shape == 5 then
            hoveredCurve = curve
          else
            hoveredCurve = nil
          end
        else
          hoveredCurve = nil
        end
      end
      -- compare underlying point identity, not wrapper table refs
      local hPt = hoveredPoint and hoveredPoint.point
      local pPt = prevHovered and prevHovered.point
      local hCv = hoveredCurve and hoveredCurve.point
      local pCv = prevHoveredCurve and prevHoveredCurve.point
      if hPt ~= pPt or hCv ~= pCv then
        pbNeedsRedraw = true
      end
    end

    -- tooltip: show note name and semitone offset on hover, or channel filter info
    if not glob.editorIsForeground then
      setTooltip("", 0, 0, false)
    elseif hoveredPoint then
      local st = hoveredPoint.point.semitones or 0
      local basePitch = hoveredPoint.point.associatedNotes and hoveredPoint.point.associatedNotes[1] and hoveredPoint.point.associatedNotes[1].pitch or 60
      local soundingPitch = basePitch + st
      local noteName = pitchToNoteName(soundingPitch)
      local tipX, tipY = r.GetMousePosition()
      setTooltip(string.format("%.2f st (%s)", st, noteName), tipX + 12, tipY + 12, true)
    elseif not config.showAllNotes then
      local screenRect = glob.liceData and glob.liceData.screenRect
      local windRect = glob.liceData and glob.liceData.windRect
      if screenRect and windRect then
        local activeChan = getActiveChannelFilter()
        if activeChan then
          local centerX = math.floor((screenRect.x1 + screenRect.x2) / 2)
          -- screenRect Y is native-converted on macOS, convert back for TrackCtl_SetToolTip
          -- offset direction differs: Y-down on Windows, Y-up on macOS (Cocoa)
          local rulerY = math.floor(coords.nativeYToScreen(screenRect.y1, windRect)) + (helper.is_macos and 85 or -60)
          setTooltip(string.format("Ch %d (h=menu)", activeChan + 1), centerX, rulerY, true)
        end
      end
    else
      setTooltip("", 0, 0, false)
    end

    -- center line positioning mode (comp/exp modifier held without dragging)
    local compExpHeld = mod.pbCompExpMod and mod.pbCompExpMod(mouseState.hottestMods)
    local prevCenterActive = centerLineState.active
    local prevCenterY = centerLineState.screenY
    -- reset state if window loses focus
    if not glob.editorIsForeground then
      centerLineState.active = false
      centerLineState.locked = false
      drawState = nil
      restoreAbsorbed(dragState, pbPoints)
      dragState = nil
    elseif compExpHeld and not dragState then
      if not hasSelection() then
        -- no selection: show tooltip, don't draw center line
        centerLineState.active = false
        local tipX, tipY = r.GetMousePosition()
        setTooltip("No points selected", tipX + 12, tipY + 12, true)
      else
        -- find reference pitch: nearest note (with PB points) to mouse Y position
        -- uses pre-sorted uniquePitchList for O(log n) lookup
        local mousePitch = screenYToPitch(my)
        local refPitch = 60
        local nPitches = #uniquePitchList
        if nPitches > 0 then
          -- binary search for nearest pitch
          local lo, hi = 1, nPitches
          while lo < hi do
            local mid = lo + math.floor((hi - lo) / 2)
            if uniquePitchList[mid] < mousePitch then
              lo = mid + 1
            else
              hi = mid
            end
          end
          -- lo is the first pitch >= mousePitch; check lo and lo-1
          refPitch = uniquePitchList[lo]
          if lo > 1 then
            local prev = uniquePitchList[lo - 1]
            if math.abs(prev - mousePitch) < math.abs(refPitch - mousePitch) then
              refPitch = prev
            end
          end
        end

        -- convert mouse Y to semitones (relative to nearest note)
        local semitones = screenYToSemitones(my, refPitch)
        local shouldSnap = shouldSnapToggle(config.snapToSemitone, optHeld)
        if shouldSnap then
          semitones = snapToMicrotonal(semitones, config.tuningScale)
        end
        -- clamp to bend range
        semitones = clampSemitones(semitones)

        -- convert snapped semitones back to screen Y for display
        local snappedScreenY = pbToScreenY(semitones, refPitch)

        centerLineState.active = true
        centerLineState.screenY = snappedScreenY or my
        centerLineState.semitones = semitones
        centerLineState.refPitch = refPitch
      end
    elseif not compExpHeld and not (dragState and dragState.isCompressExpand) then
      -- ctrl released and not in compress/expand drag, reset center line
      centerLineState.active = false
      centerLineState.locked = false
    end
    if centerLineState.active ~= prevCenterActive or centerLineState.screenY ~= prevCenterY then
      pbNeedsRedraw = true
    end

    -- pass through clicks outside note area (ruler, CC lanes, etc.)
    -- uses clickedLane from lane detection (before my is clamped to note bounds)
    if mouseState.clicked or mouseState.doubleClicked then
      if not dragState and not drawState and mouseState.clickedLane ~= -1 then
        return false
      end
    end

    -- handle mouse clicks for selection (and prepare for drag)
    -- note: Right-click is handled via glob.handleRightClick -> pitchbend.handleRightClick
    if mouseState.clicked then
      pbNeedsRedraw = true
      local shiftHeld = mod.shiftMod and mod.shiftMod(mouseState.hottestMods)  -- For selection toggle

      -- check for ctrl+click for compress/expand mode (vibrato scaling)
      -- note: opt key affects snap during positioning, but doesn't prevent click
      local drawHeld = mod.pbDrawMod and mod.pbDrawMod(mouseState.hottestMods)
      if compExpHeld then
        -- collect selected points for compress/expand
        local selectedStarts = {}
        for chan, points in pairs(pbPoints) do
          for _, pt in ipairs(points) do
            if pt.selected then
              table.insert(selectedStarts, {
                point = pt,
                chan = chan,
                startSemitones = pt.semitones,
              })
            end
          end
        end

        -- only lock center and start drag if we have selected points
        if #selectedStarts > 0 then
          centerLineState.locked = true
          -- store unclamped client Y so drag delta is zero at click point
          local rawX, rawY = r.GetMousePosition()
          local _, unclampedStartY = r.JS_Window_ScreenToClient(glob.liceData.midiview, rawX, rawY)
          dragState = {
            startMx = mx,
            startMy = my,
            isCompressExpand = true,
            selectedStarts = selectedStarts,
            centerSemitones = centerLineState.semitones,
            unclampedStartY = unclampedStartY,
          }
        end
      elseif drawHeld then
        -- draw modifier: always start draw, even over existing points
        local meState = glob.meState
        local activeChan = meState.activeChannel and meState.activeChannel > 0 and (meState.activeChannel - 1) or 0

        -- calculate initial point (snap based on current shift state)
        local ppqpos = screenXToPpq(mx, activeTake)
        if not ppqpos then return end

        -- grid snap for X (unless shift held for smooth mode)
        if not shiftHeld then
          ppqpos = snapPpqToGrid(ppqpos, activeTake)
        end

        -- find initial reference note from mouse Y position (nearest note by pitch)
        -- search ALL channels, then adopt that channel for drawing
        -- NOTE: keep in sync with associatePBWithNotes (~line 644)
        local mousePitch = screenYToPitch(my)
        local drawPpq = activeTake and mu.MIDI_GetPPQ(activeTake) or 960
        local gridLookahead = glob.currentGrid and (drawPpq * glob.currentGrid * 2) or 0
        local lookahead = math.max(gridLookahead, drawPpq / 8)  -- 2x grid, min 1/8 beat
        local refNote = nil
        local minPitchDist = math.huge
        -- search all channels for nearest note by pitch
        for chan, channelNotes in pairs(notesByChannel) do
          for _, note in ipairs(channelNotes) do
            -- include sounding notes OR notes starting within lookahead
            local isSounding = note.startppq <= ppqpos and note.endppq > ppqpos
            local isUpcoming = note.startppq > ppqpos and note.startppq <= ppqpos + lookahead
            if isSounding or isUpcoming then
              local pitchDist = math.abs(note.pitch - mousePitch)
              if pitchDist < minPitchDist then
                minPitchDist = pitchDist
                refNote = note
                activeChan = chan  -- adopt this channel
              end
            end
          end
        end
        -- adopt channel: update config so display filters to this channel
        -- (skip if showAllNotes - use cmd+rightclick to switch channel explicitly)
        if refNote and not config.showAllNotes then
          config.activeChannel = activeChan
          saveActiveChannel()
        end
        local refPitch = refNote and refNote.pitch or 60

        -- calculate semitones from mouse Y using the reference pitch
        local semitones = screenYToSemitones(my, refPitch)
        -- y snap to semitones (unless opt held)
        local shouldSnapY = shouldSnapToggle(config.snapToSemitone, optHeld)
        if shouldSnapY then
          semitones = snapToMicrotonal(semitones, config.tuningScale)
        end
        semitones = clampSemitones(semitones)
        local pbValue = semitonesToPb(semitones)

        -- calculate snapped screen positions for visual feedback
        local snappedScreenX = ppqToScreenX(ppqpos, activeTake) or mx
        local snappedScreenY = pbToScreenY(pbToSemitones(pbValue), refPitch) or my

        drawState = {
          chan = activeChan,
          refPitch = refPitch,
          refNoteEnd = refNote and refNote.endppq or nil,  -- track when current note ends
          path = {{ ppq = ppqpos, pbValue = pbValue, screenX = snappedScreenX, screenY = snappedScreenY }},
          lastPbValue = pbValue,
          lastPpq = ppqpos,
          lastDirection = 0,  -- 1=ascending, -1=descending, 0=initial
          drawDir = nil,  -- 1=LTR, -1=RTL, nil=undetermined
        }
      elseif optHeld and not hoveredPoint then
      -- check for opt+click on curve for bezier tension editing (only bezier curves)
        local curveHit = hitTestCurve(mx, my)
        if curveHit and curveHit.point.shape == 5 then
          local bezierPoints = {}
          if curveHit.point.selected then
            -- batch: edit all selected bezier points together
            for chan, points in pairs(pbPoints) do
              for _, pt in ipairs(points) do
                if pt.selected and pt.shape == 5 then
                  table.insert(bezierPoints, {
                    point = pt,
                    chan = chan,
                    startTension = pt.beztension or 0,
                  })
                end
              end
            end
          else
            -- clicked unselected curve: deselect all, select this curve's start point, edit solo
            deselectAll()
            curveHit.point.selected = true
            selectionChanged = true
            table.insert(bezierPoints, {
              point = curveHit.point,
              chan = curveHit.chan,
              startTension = curveHit.point.beztension or 0,
            })
          end
          dragState = {
            startMx = mx,
            startMy = my,
            isBezierDrag = true,
            bezierPoints = bezierPoints,
          }
        end
      elseif hoveredPoint then
        -- clicked on a point
        local wasSelected = hoveredPoint.point.selected
        if shiftHeld then
          if wasSelected then
            -- defer deselect to mouse-up (so drag can still include this point)
          else
            hoveredPoint.point.selected = true
            selectionChanged = true
          end
        else
          -- if clicking unselected point, clear others and select this one
          if not wasSelected then
            deselectAll()
            selectionChanged = true
          end
          hoveredPoint.point.selected = true
        end

        -- initialize dragState for point dragging (store all selected points' start positions)
        local selectedStarts = {}
        local nonSelected = {}
        for chan, points in pairs(pbPoints) do
          for _, pt in ipairs(points) do
            if pt.selected then
              table.insert(selectedStarts, {
                point = pt,
                chan = chan,
                startPpq = pt.ppqpos,
                startSemitones = pt.semitones,
              })
            else
              if not nonSelected[chan] then nonSelected[chan] = {} end
              table.insert(nonSelected[chan], { point = pt, chan = chan, absorbed = false })
            end
          end
        end
        -- find the dragged anchor in selectedStarts
        local anchorIdx = 1
        for i, sel in ipairs(selectedStarts) do
          if sel.point == hoveredPoint.point then
            anchorIdx = i
            break
          end
        end
        dragState = {
          startMx = mx,
          startMy = my,
          isMarquee = false,
          selectedStarts = selectedStarts,
          nonSelected = nonSelected,
          anchorIdx = anchorIdx,
          pendingDeselect = shiftHeld and wasSelected and hoveredPoint.point or nil,
        }
      else
        -- clicked on empty space without draw modifier
        -- start marquee selection
        if not shiftHeld then
          selectionChanged = hasSelection()
          deselectAll()
        end
        dragState = {
          startMx = mx,
          startMy = my,
          isMarquee = true,
          selectedStarts = {},
        }
      end

      -- sync selection to MIDI on click
      if selectionChanged and activeTake then
        syncSelectionToMIDI(activeTake, mu)
        undoText = 'Select Pitch Bend'
      end
    end

    -- handle dragging
    if mouseState.dragging and dragState then
      pbNeedsRedraw = true
      local meState = glob.meState
      local dx = mx - dragState.startMx
      local dy = my - dragState.startMy

      if dragState.isBezierDrag then
        -- bezier tension drag - horizontal movement adjusts tension (-1 to 1)
        -- 100 pixels = full range
        local tensionDelta = dx / 100
        for _, bp in ipairs(dragState.bezierPoints) do
          local newTension = math.max(-1, math.min(1, bp.startTension + tensionDelta))
          bp.point.beztension = newTension
        end
      elseif dragState.isCompressExpand then
        -- compress/expand vibrato - vertical drag scales raw PB semitone values around center
        -- drag up = expand (factor > 1), drag down = compress (factor < 1)
        -- use unclamped mouse position so expansion isn't limited by window bounds
        local rawX, rawY = r.GetMousePosition()
        local _, unclampedY = r.JS_Window_ScreenToClient(glob.liceData.midiview, rawX, rawY)
        local rawDy = unclampedY - dragState.unclampedStartY
        local factor = 1 - (rawDy / 100)
        factor = math.max(0, factor)

        local center = dragState.centerSemitones or 0
        for _, sel in ipairs(dragState.selectedStarts) do
          -- scale raw semitone values around center (ignores note association)
          local newSemitones = center + (sel.startSemitones - center) * factor
          -- clamp to max bend range
          newSemitones = clampSemitones(newSemitones)

          local pbValue = semitonesToPb(newSemitones)
          sel.point.pbValue = pbValue
          sel.point.semitones = pbToSemitones(pbValue)  -- Round-trip for accurate display
        end
      elseif dragState.isMarquee then
        -- marquee selection - just update drag rect, actual selection happens on release
        dragState.currentMx = mx
        dragState.currentMy = my
      elseif dragState.selectedStarts and #dragState.selectedStarts > 0 then
        -- point dragging: axis-locked, snap only anchor point, move others relative
        local anchor = dragState.selectedStarts[dragState.anchorIdx or 1]

        -- detect drag axis on first significant movement
        local AXIS_THRESHOLD = 4
        if not dragState.dragAxis then
          if math.abs(dx) > AXIS_THRESHOLD or math.abs(dy) > AXIS_THRESHOLD then
            dragState.dragAxis = math.abs(dx) > math.abs(dy) and 'x' or 'y'
          end
        end

        if dragState.dragAxis == 'y' then
          -- vertical: value change only
          -- clamp my to visible note area
          local noteArea = glob.meLanes and glob.meLanes[-1]
          local clampedMy = my
          if noteArea then
            clampedMy = math.max(noteArea.topPixel, math.min(noteArea.bottomPixel, my))
          end
          local clampedDy = clampedMy - dragState.startMy

          local deltaSemitones = 0
          if meState.pixelsPerPitch and meState.pixelsPerPitch > 0 then
            deltaSemitones = -clampedDy / meState.pixelsPerPitch
          end

          -- pitch snap: snap anchor, derive delta from snapped position
          local pitchSnapToggle = mod.pbSnapToPitchMod and mod.pbSnapToPitchMod(mouseState.hottestMods)
          local shouldSnapPitch = shouldSnapToggle(config.snapToSemitone, pitchSnapToggle)
          local anchorNewSemitones = anchor.startSemitones + deltaSemitones
          if shouldSnapPitch then
            anchorNewSemitones = snapToMicrotonal(anchorNewSemitones, config.tuningScale)
          end
          anchorNewSemitones = clampSemitones(anchorNewSemitones)
          local snappedDeltaSemitones = anchorNewSemitones - anchor.startSemitones

          for _, sel in ipairs(dragState.selectedStarts) do
            local newSemitones = sel.startSemitones + snappedDeltaSemitones
            newSemitones = clampSemitones(newSemitones)
            local pbValue = semitonesToPb(newSemitones)
            sel.point.pbValue = pbValue
            sel.point.semitones = pbToSemitones(pbValue)
          end
        elseif dragState.dragAxis == 'x' then
          -- horizontal: time change only
          local deltaPpq = 0
          if activeTake then
            local pixPerPpq = getPixelsPerPpq(activeTake)
            if pixPerPpq and pixPerPpq > 0 then
              deltaPpq = dx / pixPerPpq
            end
          end

          -- grid snap: snap anchor's new ppq, derive delta from snapped position
          local gridSnapToggle = mod.pbSnapToGridMod and mod.pbSnapToGridMod(mouseState.hottestMods)
          local editorSnapEnabled = glob.liceData and glob.liceData.editor
            and r.MIDIEditor_GetSetting_int(glob.liceData.editor, 'snap_enabled') == 1
          local shouldSnapGrid = shouldSnapToggle(editorSnapEnabled, gridSnapToggle)
          local anchorNewPpq = anchor.startPpq + deltaPpq
          if shouldSnapGrid then
            anchorNewPpq = snapPpqToGrid(anchorNewPpq, activeTake)
          end

          -- clamp to visible view
          local viewWidth = glob.liceData.screenRect:width()
          local leftPpq = screenXToPpq(0, activeTake)
          local rightPpq = screenXToPpq(viewWidth, activeTake)
          if leftPpq and rightPpq then
            anchorNewPpq = math.max(leftPpq, math.min(rightPpq, anchorNewPpq))
          end

          -- clamp to neighbor boundaries (per-channel, ±1 ppq from nearest non-selected)
          if config.dragCrossMode == DRAG_CROSS_CLAMP and dragState.nonSelected then
            local clampMin, clampMax
            for _, sel in ipairs(dragState.selectedStarts) do
              local nsList = dragState.nonSelected[sel.chan]
              if nsList then
                for _, ns in ipairs(nsList) do
                  if ns.point.ppqpos < sel.startPpq then
                    -- neighbor to the left: can't move left of it + 1
                    local limit = ns.point.ppqpos + 1 - sel.startPpq + anchor.startPpq
                    if not clampMin or limit > clampMin then clampMin = limit end
                  elseif ns.point.ppqpos > sel.startPpq then
                    -- neighbor to the right: can't move right of it - 1
                    local limit = ns.point.ppqpos - 1 - sel.startPpq + anchor.startPpq
                    if not clampMax or limit < clampMax then clampMax = limit end
                  end
                end
              end
            end
            if clampMin then anchorNewPpq = math.max(clampMin, anchorNewPpq) end
            if clampMax then anchorNewPpq = math.min(clampMax, anchorNewPpq) end
          end

          local snappedDeltaPpq = math.floor(anchorNewPpq - anchor.startPpq + 0.5)

          for _, sel in ipairs(dragState.selectedStarts) do
            sel.point.ppqpos = sel.startPpq + snappedDeltaPpq
          end

          -- absorb mode: absorb/restore non-selected points crossed during drag
          if config.dragCrossMode == DRAG_CROSS_ABSORB then
            if sweepAbsorb(dragState, pbPoints) then
              pbNeedsRedraw = true
            end
          end
        end
      end
    end

    -- handle draw mode dragging (separate from dragState)
    if mouseState.dragging and drawState then
      pbNeedsRedraw = true
      local meState = glob.meState
      local pitchSnapToggle = mod.pbSnapToPitchMod and mod.pbSnapToPitchMod(mouseState.hottestMods)
      local smoothToggle = mod.pbSmoothDrawMod and mod.pbSmoothDrawMod(mouseState.hottestMods)

      -- smooth mode is dynamic based on modifier
      local smooth = smoothToggle

      -- calculate current position
      local ppqpos = screenXToPpq(mx, activeTake)
      if not ppqpos then return end

      -- grid snap for X (unless smooth mode)
      if not smooth then
        ppqpos = snapPpqToGrid(ppqpos, activeTake)
      end

      -- dynamic reference pitch: only switch to new note when current note has ended
      -- this keeps the curve relative to the original note during legato passages
      local currentNoteEnded = drawState.refNoteEnd and ppqpos > drawState.refNoteEnd
      if currentNoteEnded then
        local targetPitch = math.floor(screenYToPitch(my) + 0.5)
        local noteAtCursor = findNoteAtTime(drawState.chan, ppqpos, targetPitch)
        if noteAtCursor then
          drawState.refNoteEnd = noteAtCursor.endppq
          if noteAtCursor.pitch ~= drawState.refPitch then
            drawState.refPitch = noteAtCursor.pitch
          end
        end
      end

      -- calculate semitones from mouse Y using (possibly updated) reference pitch
      local semitones = screenYToSemitones(my, drawState.refPitch or 60)
      local shouldSnapY = shouldSnapToggle(config.snapToSemitone, pitchSnapToggle)
      if shouldSnapY then
        semitones = snapToMicrotonal(semitones, config.tuningScale)
      end
      semitones = clampSemitones(semitones)
      local pbValue = semitonesToPb(semitones)

      -- calculate snapped screen positions for visual feedback
      local snappedScreenX = ppqToScreenX(ppqpos, activeTake) or mx
      local snappedScreenY = pbToScreenY(pbToSemitones(pbValue), drawState.refPitch or 60) or my

      -- determine draw direction on first significant movement
      local lastPathPt = drawState.path[#drawState.path]
      if not drawState.drawDir and ppqpos ~= drawState.path[1].ppq then
        drawState.drawDir = ppqpos > drawState.path[1].ppq and 1 or -1
      end

      -- backward = opposite of draw direction
      local dd = drawState.drawDir or 1
      local isBackward = #drawState.path > 1
        and ((dd == 1 and ppqpos < lastPathPt.ppq) or (dd == -1 and ppqpos > lastPathPt.ppq))

      if isBackward then
        -- retract the live (last) point to cursor position
        lastPathPt.ppq = ppqpos
        lastPathPt.screenX = snappedScreenX
        lastPathPt.pbValue = pbValue
        lastPathPt.screenY = snappedScreenY

        -- absorb at crossings: if live point reached a locked-in point, remove it
        -- and promote the locked-in point to live (retract it to cursor too)
        while #drawState.path > 1 do
          local livePt = drawState.path[#drawState.path]
          local prevPt = drawState.path[#drawState.path - 1]
          local shouldAbsorb = (dd == 1 and livePt.ppq <= prevPt.ppq)
            or (dd == -1 and livePt.ppq >= prevPt.ppq)
          if shouldAbsorb then
            table.remove(drawState.path)
            if #drawState.path > 1 then
              local newLive = drawState.path[#drawState.path]
              newLive.ppq = ppqpos
              newLive.screenX = snappedScreenX
              newLive.pbValue = pbValue
              newLive.screenY = snappedScreenY
            end
          else
            break
          end
        end

        -- first point: anchored, only adjust value if cursor is near
        if #drawState.path == 1 then
          local firstPt = drawState.path[1]
          local halfGrid = (glob.currentGrid and activeTake)
            and math.floor(mu.MIDI_GetPPQ(activeTake) * glob.currentGrid / 2) or 0
          if ppqpos >= firstPt.ppq - halfGrid and ppqpos <= firstPt.ppq + halfGrid then
            firstPt.pbValue = pbValue
            firstPt.screenY = snappedScreenY
          end
        end

        drawState.lastPpq = ppqpos
        drawState.lastPbValue = drawState.path[#drawState.path].pbValue
        drawState.lastDirection = 0
      elseif smooth then
        -- smooth mode: add point on any value change, no consolidation
        if pbValue ~= drawState.lastPbValue then
          table.insert(drawState.path, {
            ppq = ppqpos,
            pbValue = pbValue,
            screenX = snappedScreenX,
            screenY = snappedScreenY,
          })
          drawState.lastPbValue = pbValue
          drawState.lastPpq = ppqpos
        end
      else
        -- grid mode forward drawing
        local shouldAdd = ppqpos ~= drawState.lastPpq

        if shouldAdd and pbValue ~= drawState.lastPbValue then
          local lastPt = drawState.path[#drawState.path]
          local direction = pbValue > drawState.lastPbValue and 1 or -1
          local coastSpan = math.abs(drawState.lastPpq - lastPt.ppq)
          local gridUnit = glob.currentGrid and (mu.MIDI_GetPPQ(activeTake) * glob.currentGrid) or 0
          local coasted = coastSpan > gridUnit  -- only for coasts longer than 1 grid

          if coasted then
            -- after sustained coast: hold-point + new point
            if glob.defaultCCCurve ~= 0 and glob.currentGrid then
              local holdPpq = dd == 1 and (ppqpos - 1) or (ppqpos + 1)
              local holdOk = (dd == 1 and holdPpq > lastPt.ppq) or (dd == -1 and holdPpq < lastPt.ppq)
              if holdOk then
                local holdScreenX = ppqToScreenX(holdPpq, activeTake) or lastPt.screenX
                table.insert(drawState.path, {
                  ppq = holdPpq,
                  pbValue = drawState.lastPbValue,
                  screenX = holdScreenX,
                  screenY = lastPt.screenY,
                })
              end
            end
            table.insert(drawState.path, {
              ppq = ppqpos,
              pbValue = pbValue,
              screenX = snappedScreenX,
              screenY = snappedScreenY,
            })
          elseif direction == drawState.lastDirection and #drawState.path > 1 then
            -- same direction, no coast: extend ramp by updating last point in-place
            -- (never update the start point — #path > 1 protects it)
            lastPt.ppq = ppqpos
            lastPt.pbValue = pbValue
            lastPt.screenX = snappedScreenX
            lastPt.screenY = snappedScreenY
          else
            -- direction change: lock in current point, start new ramp
            table.insert(drawState.path, {
              ppq = ppqpos,
              pbValue = pbValue,
              screenX = snappedScreenX,
              screenY = snappedScreenY,
            })
          end
          drawState.lastDirection = direction
          drawState.lastPbValue = pbValue
          drawState.lastPpq = ppqpos
        elseif not shouldAdd and pbValue ~= drawState.lastPbValue then
          -- same grid position, value changed: only update if continuing same direction
          -- reversal at same position = vertex (lock extreme value)
          local lastPt = drawState.path[#drawState.path]
          if lastPt and lastPt.ppq == ppqpos then
            local moveDir = pbValue > drawState.lastPbValue and 1 or -1
            if drawState.lastDirection == 0 or moveDir == drawState.lastDirection then
              lastPt.pbValue = pbValue
              lastPt.screenY = snappedScreenY
              drawState.lastPbValue = pbValue
            end
          end
        elseif shouldAdd and pbValue == drawState.lastPbValue then
          -- same value but new position - update lastPpq to track position without adding point
          drawState.lastPpq = ppqpos
          -- update last point's screen position for visual continuity (but not the first point)
          if #drawState.path > 1 then
            local lastPt = drawState.path[#drawState.path]
            lastPt.screenX = snappedScreenX
            lastPt.screenY = snappedScreenY
          end
        end
      end
    end

    -- handle mouse release
    if mouseState.released and dragState then
      pbNeedsRedraw = true
      undoText = finalizeDragRelease(activeTake)
      dragState = nil
    end

    -- handle draw mode release
    if mouseState.released and drawState then
      pbNeedsRedraw = true
      undoText = undoText or commitDrawPath(activeTake)
      drawState = nil
    end

    -- note: Delete and curve type cycling are handled in processKeys (Lib.lua)

    -- handle double-click to add new point
    if mouseState.doubleClicked and activeTake and not hoveredPoint then
      local meState = glob.meState
      local meLanes = glob.meLanes

      local ppqpos = screenXToPpq(mx, activeTake)
      if ppqpos and meLanes[-1] then

        -- grid snap handling (modifier toggles, respects editor snap setting)
        local gridSnapToggle = mod.pbSnapToGridMod and mod.pbSnapToGridMod(mouseState.hottestMods)
        local editorSnapEnabled = r.MIDIEditor_GetSetting_int(glob.liceData.editor, 'snap_enabled') == 1
        local shouldSnapGrid = shouldSnapToggle(editorSnapEnabled, gridSnapToggle)
        if shouldSnapGrid then
          ppqpos = snapPpqToGrid(ppqpos, activeTake)
        end

        -- use active channel from editor (1-based in chunk, convert to 0-based for MIDI)
        local chan = math.max(0, (meState.activeChannel or 1) - 1)

        -- get target pitch from mouse Y position
        local targetPitch = screenYToPitch(my)

        -- find the associated note to calculate semitone offset from
        local refNote = findNoteAtTime(chan, ppqpos, targetPitch)
        local refPitch = refNote and refNote.pitch or 60  -- Default to middle C if no note

        -- calculate semitone offset: how far from reference note pitch
        local semitones = targetPitch - refPitch

        -- pitch snap handling (modifier toggles, default ON)
        local pitchSnapToggle = mod.pbSnapToPitchMod and mod.pbSnapToPitchMod(mouseState.hottestMods)
        local shouldSnapPitch = shouldSnapToggle(config.snapToSemitone, pitchSnapToggle)
        if shouldSnapPitch then
          semitones = snapToMicrotonal(semitones, config.tuningScale)
        end
        semitones = clampSemitones(semitones)

        local pbValue = semitonesToPb(semitones)
        local msg2, msg3 = pbToBytes(pbValue)

        mu.MIDI_OpenWriteTransaction(activeTake)
        mu.MIDI_InsertCC(activeTake, true, false, ppqpos, CHANMSG_PITCHBEND, chan, msg2, msg3)
        mu.MIDI_CommitWriteTransaction(activeTake, true, true)
        clearCache()  -- Force refresh to show the new point
        undoText = 'Insert Pitch Bend Point'
      end
    end

    -- set cursor based on state (only when mouse is in valid area)
    local drawHeld = mod.pbDrawMod and mod.pbDrawMod(mouseState.hottestMods)
    local compExpHeld = mod.pbCompExpMod and mod.pbCompExpMod(mouseState.hottestMods)
    if dragState and dragState.isBezierDrag then
      glob.setCursor(glob.bezier_cursor)
    elseif dragState and dragState.isCompressExpand then
      glob.setCursor(glob.segment_up_down_cursor)
    elseif dragState and dragState.isDraw then
      glob.setCursor(glob.draw_cursor)
    elseif dragState and not dragState.isMarquee then
      glob.setCursor(glob.move_cursor)
    elseif compExpHeld then
      glob.setCursor(glob.segment_up_down_cursor)
    elseif drawHeld then
      glob.setCursor(glob.draw_cursor)
    elseif hoveredPoint then
      glob.setCursor(glob.hand_cursor)
    elseif hoveredCurve then
      glob.setCursor(glob.bezier_cursor)
    else
      glob.setCursor(glob.wantsRightButton and glob.bend_cursor_rmb or glob.bend_cursor)
    end
  end

  return true, undoText
end

local function getPBPoints()
  return pbPoints
end

local function getDragState()
  return dragState
end

local function getConfig()
  return config
end

-- get snap line data for microtonal scale visualization
-- returns { { semitoneOffset, screenY }, ... } for each snap point within bend range
-- referencePitch is the note pitch to center the lines around
local function getScaleSnapLines(referencePitch)
  if not config.tuningScale then return nil end

  -- invalidate cache when config or view state changes
  local meLanes = glob.meLanes
  local meState = glob.meState
  local lane = meLanes and meLanes[-1]
  local key = string.format('%s_%d_%d_%s_%s_%s',
    tostring(config.tuningScale), config.maxBendUp, config.maxBendDown,
    tostring(lane and lane.topPixel), tostring(lane and lane.topValue),
    tostring(meState and meState.pixelsPerPitch))
  if key ~= snapLineCacheKey then
    snapLineCache = {}
    snapLineCacheKey = key
  end

  if snapLineCache[referencePitch] then
    return snapLineCache[referencePitch]
  end

  local scale = config.tuningScale
  local lines = {}

  -- build snap points from scale (same logic as snapToMicrotonal)
  local snapPoints = { 0 }
  for _, pitch in ipairs(scale.pitches) do
    local n, d = pitch[1], pitch[2]
    local semitoneOffset
    if d == 1200 then
      semitoneOffset = n / 100
    else
      local ratio = n / d
      semitoneOffset = 12 * math.log(ratio) / math.log(2)
    end
    table.insert(snapPoints, semitoneOffset)
  end

  local octaveSize = snapPoints[#snapPoints] or 12

  -- generate lines for all scale degrees within bend range (multiple octaves)
  local maxUp = config.maxBendUp
  local maxDown = config.maxBendDown

  -- cover from -maxDown to +maxUp
  local minOctave = math.floor(-maxDown / octaveSize) - 1
  local maxOctave = math.floor(maxUp / octaveSize) + 1

  for oct = minOctave, maxOctave do
    for _, pt in ipairs(snapPoints) do
      local semitones = (oct * octaveSize) + pt
      if semitones >= -maxDown and semitones <= maxUp then
        local screenY = pbToScreenY(semitones, referencePitch)
        if screenY then
          table.insert(lines, { semitones = semitones, screenY = screenY })
        end
      end
    end
  end

  snapLineCache[referencePitch] = lines
  return lines
end

local function setConfig(key, value)
  if config[key] ~= nil then
    config[key] = value
    pbNeedsRedraw = true
  end
end

local function cycleCurveType()
  config.curveType = (config.curveType + 1) % 5 -- 0-4 for STEP, LINEAR, SLOW_START, SLOW_END, BEZIER
  return config.curveType
end

local function showCurveMenu(take, midiUtils)
  if not take or not midiUtils then return nil end

  local activeChannel = getActiveChannelFilter()
  local hasPoints = false
  local hasSelection = false
  for chan, points in pairs(pbPoints) do
    if not activeChannel or chan == activeChannel then
      for _, pt in ipairs(points) do
        hasPoints = true
        if pt.selected then hasSelection = true end
      end
    end
  end
  if not hasPoints then return nil end

  helper.VKeys_ClearState()

  local curveNames = { 'Square', 'Linear', 'Slow start/end', 'Fast start', 'Fast end', 'Bezier' }
  local menuStr = table.concat(curveNames, '|')

  local choice = helper.showMenu(menuStr)

  helper.VKeys_ClearState()

  if choice > 0 then
    local shapeNum = choice - 1
    local changed = false
    midiUtils.MIDI_OpenWriteTransaction(take)
    for chan, points in pairs(pbPoints) do
      if not activeChannel or chan == activeChannel then
        for _, pt in ipairs(points) do
          if not hasSelection or pt.selected then
            midiUtils.MIDI_SetCCShape(take, pt.idx, shapeNum, pt.beztension or 0)
            pt.shape = shapeNum
            changed = true
          end
        end
      end
    end
    if changed then
      midiUtils.MIDI_CommitWriteTransaction(take, true, true)
      clearCache()
      return 'Set Pitch Bend Curve Type'
    else
      midiUtils.MIDI_CommitWriteTransaction(take, false, false)
    end
  end
  return nil
end

-- snap selected points to nearest scale interval (returns undo text if changed)
local function snapSelectedToSemitone(take, midiUtils)
  if not take or not midiUtils then return nil end

  local changed = false
  midiUtils.MIDI_OpenWriteTransaction(take)
  for chan, points in pairs(pbPoints) do
    for _, pt in ipairs(points) do
      if pt.selected then
        local snappedSemitones = snapToMicrotonal(pt.semitones, config.tuningScale)
        if snappedSemitones ~= pt.semitones then
          local pbValue = semitonesToPb(snappedSemitones)
          local msg2, msg3 = pbToBytes(pbValue)
          midiUtils.MIDI_SetCC(take, pt.idx, pt.selected, pt.muted, pt.ppqpos, CHANMSG_PITCHBEND, chan, msg2, msg3)
          pt.pbValue = pbValue
          pt.semitones = snappedSemitones
          changed = true
        end
      end
    end
  end
  if changed then
    midiUtils.MIDI_CommitWriteTransaction(take, true, true)
    return config.tuningScale and 'Snap Pitch Bend to Scale' or 'Snap Pitch Bend to Semitone'
  else
    midiUtils.MIDI_CommitWriteTransaction(take, false, false)
    return nil
  end
end

local function selectAll()
  local activeChannel = getActiveChannelFilter()
  deselectAll()
  -- then select only visible/active channel points
  for chan, points in pairs(pbPoints) do
    if not activeChannel or chan == activeChannel then
      for _, pt in ipairs(points) do
        pt.selected = true
      end
    end
  end
  pbNeedsRedraw = true
end

-- delete selected points (returns undo text if deleted)
local function deleteSelectedPoints(take, midiUtils)
  if not take or not midiUtils then return nil end

  local deleted = false
  midiUtils.MIDI_OpenWriteTransaction(take)
  for chan, points in pairs(pbPoints) do
    for i = #points, 1, -1 do
      if points[i].selected then
        midiUtils.MIDI_DeleteCC(take, points[i].idx)
        table.remove(points, i)
        deleted = true
      end
    end
  end
  if deleted then
    midiUtils.MIDI_CommitWriteTransaction(take, true, true)
    clearCache()  -- Force refresh to update the display
    return 'Delete Pitch Bend Points'
  else
    midiUtils.MIDI_CommitWriteTransaction(take, false, false)
    return nil
  end
end

-- stash selected point span for paste-replace (call at copy time)
local function stashClipboardSpan()
  local minPpq, maxPpq = math.huge, -math.huge
  local channels = {}
  local found = false
  for chan, points in pairs(pbPoints) do
    for _, pt in ipairs(points) do
      if pt.selected then
        if pt.ppqpos < minPpq then minPpq = pt.ppqpos end
        if pt.ppqpos > maxPpq then maxPpq = pt.ppqpos end
        channels[chan] = true
        found = true
      end
    end
  end
  if found then
    clipboardSpan = { minPpq = minPpq, maxPpq = maxPpq, channels = channels }
  else
    clipboardSpan = nil
  end
end

-- delete existing PB events in paste target range (call before native paste)
local function deleteBeforePaste(take, midiUtils)
  if not clipboardSpan or not take or not midiUtils then return end

  local cursorTime = r.GetCursorPositionEx(0)
  local cursorPpq = r.MIDI_GetPPQPosFromProjTime(take, cursorTime)
  local offset = cursorPpq - clipboardSpan.minPpq
  local targetMin = clipboardSpan.minPpq + offset
  local targetMax = clipboardSpan.maxPpq + offset

  local _, _, ccCount = midiUtils.MIDI_CountEvts(take)
  midiUtils.MIDI_OpenWriteTransaction(take)
  local deleted = false
  for i = 0, ccCount - 1 do
    local rv, _, _, ppqpos, chanmsg, chan = midiUtils.MIDI_GetCC(take, i)
    if rv and chanmsg == CHANMSG_PITCHBEND and clipboardSpan.channels[chan]
       and ppqpos >= targetMin and ppqpos <= targetMax then
      midiUtils.MIDI_DeleteCC(take, i)
      deleted = true
    end
  end
  midiUtils.MIDI_CommitWriteTransaction(take, deleted, deleted)
end

-- get curve type name for display
local function getCurveTypeName(curveType)
  curveType = curveType or config.curveType
  if curveType == CURVE_STEP then return 'Step'
  elseif curveType == CURVE_LINEAR then return 'Linear'
  elseif curveType == CURVE_SLOW_START then return 'Slow Start'
  elseif curveType == CURVE_SLOW_END then return 'Slow End'
  elseif curveType == CURVE_BEZIER then return 'Bezier/S-Curve'
  end
  return 'Unknown'
end


-- gFX-based config dialog for bend range
local configDialogState = nil  -- { active, fields, focusedField, scriptID }

-- shutdown cleanup
local function shutdown(destroyBitmap)
  -- close config dialog if open
  if configDialogState and configDialogState.active then
    gfx.quit()
    configDialogState = nil
  end
  pbPoints = {}
  hoveredPoint = nil
  hoveredCurve = nil
  dragState = nil
  drawState = nil
  centerLineState.active = false
  centerLineState.locked = false
  centerLineState.screenY = nil
  centerLineState.semitones = 0
  clearCache()
end

local function setMIDIUtils(midiUtils)
  mu = midiUtils
end

local function getCenterLineState()
  return centerLineState
end

local function getDrawState()
  return drawState
end

local function getSclFiles()
  local files = {}
  if not config.sclDirectory then return files end

  local idx = 0
  while true do
    local file = r.EnumerateFiles(config.sclDirectory, idx)
    if not file then break end
    if file:lower():match('%.scl$') then
      table.insert(files, file)
    end
    idx = idx + 1
  end
  table.sort(files)
  return files
end

local function loadTuningFile(filename)
  if not filename or not config.sclDirectory then
    config.tuningFile = nil
    config.tuningScale = nil
    return
  end

  local path = config.sclDirectory .. '/' .. filename
  local ok, result = pcall(function() return scl.Scale.load(path) end)
  if ok and result then
    config.tuningFile = filename
    config.tuningScale = result
  else
    config.tuningFile = nil
    config.tuningScale = nil
  end
end

local function configDialogLoop()
  if not configDialogState or not configDialogState.active then return end

  local state = configDialogState
  local char = gfx.getchar()

  -- window closed
  if char == -1 then
    -- restore original values on close
    applyEffectiveConfig()
    recalcSemitones()
    local take = glob.liceData and glob.liceData.editorTake
    if take then updateScreenCoords(take) end
    configDialogState = nil
    if glob.liceData and glob.liceData.editor then
      r.JS_Window_SetFocus(glob.liceData.editor)
    end
    return
  end

  -- escape: cancel and restore original values
  if char == 27 then
    applyEffectiveConfig()
    recalcSemitones()
    local take = glob.liceData and glob.liceData.editorTake
    if take then updateScreenCoords(take) end
    gfx.quit()
    helper.VKeys_ClearState()
    configDialogState = nil
    if glob.liceData and glob.liceData.editor then
      r.JS_Window_SetFocus(glob.liceData.editor)
    end
    return
  end

  -- track frames since open to avoid 'b' key race (opening keypress picked up by gfx)
  state.frameCount = (state.frameCount or 0) + 1

  -- cmd+W or 'b': same as Enter (save and close)
  -- 'b' only accepted after first frame to avoid race with the opening keypress
  if char == 23 or (char == 98 and state.frameCount > 1) then
    char = 13  -- Treat as Enter
  end

  -- enter: confirm and save to project overrides
  if char == 13 then
    local upVal = tonumber(state.fields[1].value)
    local downVal = tonumber(state.fields[2].value)
    if upVal and upVal > 0 and upVal <= 48 then
      projectOverrides.maxBendUp = upVal
    end
    if downVal and downVal > 0 and downVal <= 48 then
      projectOverrides.maxBendDown = downVal
    end
    saveProjectState(state.scriptID)
    applyEffectiveConfig()
    recalcSemitones()  -- Force curves to redraw with new range
    gfx.quit()
    helper.VKeys_ClearState()
    configDialogState = nil
    if glob.liceData and glob.liceData.editor then
      r.JS_Window_SetFocus(glob.liceData.editor)
    end
    return
  end

  -- helper to apply current values and refresh curves
  local function applyPreview()
    local upVal = tonumber(state.fields[1].value)
    local downVal = tonumber(state.fields[2].value)
    if upVal and upVal > 0 and upVal <= 48 then
      config.maxBendUp = upVal
    end
    if downVal and downVal > 0 and downVal <= 48 then
      config.maxBendDown = downVal
    end
    recalcSemitones()
    -- force screen coord update (cache invalidation may not trigger in time)
    local take = glob.liceData and glob.liceData.editorTake
    if take then updateScreenCoords(take) end
  end

  -- tab: switch fields and select contents
  if char == 9 then
    applyPreview()
    state.focusedField = state.focusedField == 1 and 2 or 1
    state.fields[state.focusedField].selected = true
  end

  -- backspace: delete last char (or clear if selected)
  if char == 8 then
    local field = state.fields[state.focusedField]
    if field.selected then
      field.value = ''
      field.selected = false
    elseif #field.value > 0 then
      field.value = field.value:sub(1, -2)
    end
    applyPreview()
  end

  -- number input (0-9)
  if char >= 48 and char <= 57 then
    local field = state.fields[state.focusedField]
    if field.selected then
      field.value = string.char(char)  -- Replace selection
      field.selected = false
    elseif #field.value < 2 then  -- Max 2 digits (range 1-48)
      field.value = field.value .. string.char(char)
    end
    applyPreview()
  end

  -- draw dialog
  gfx.set(0.2, 0.2, 0.2, 1)  -- Dark background
  gfx.rect(0, 0, state.width, state.height, 1)

  local scale = state.scale or 1
  for i, field in ipairs(state.fields) do
    -- label
    gfx.set(0.8, 0.8, 0.8, 1)
    gfx.x, gfx.y = field.x, field.y
    gfx.drawstr(field.label)

    -- input box
    local boxX = field.x + math.floor(155 * scale)
    local boxW, boxH = math.floor(50 * scale), math.floor(20 * scale)
    local isFocused = i == state.focusedField

    -- box background
    gfx.set(0.15, 0.15, 0.15, 1)
    gfx.rect(boxX, field.y - math.floor(2 * scale), boxW, boxH, 1)

    -- box border (highlight if focused)
    if isFocused then
      gfx.set(0.4, 0.6, 1, 1)
    else
      gfx.set(0.4, 0.4, 0.4, 1)
    end
    gfx.rect(boxX, field.y - math.floor(2 * scale), boxW, boxH, 0)

    -- selection highlight if selected
    if field.selected and isFocused then
      local textW = gfx.measurestr(field.value)
      gfx.set(0.3, 0.5, 0.8, 1)
      gfx.rect(boxX + math.floor(3 * scale), field.y, textW + math.floor(2 * scale), math.floor(14 * scale), 1)
    end

    -- value text
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = boxX + math.floor(4 * scale), field.y + math.floor(2 * scale)
    gfx.drawstr(field.value)

    -- cursor if focused (and not selected)
    if isFocused and not field.selected then
      local textW = gfx.measurestr(field.value)
      gfx.line(boxX + math.floor(4 * scale) + textW, field.y + scale, boxX + math.floor(4 * scale) + textW, field.y + math.floor(14 * scale))
    end
  end

  -- tuning button
  local tuningY = math.floor(80 * scale)
  local tuningBtnX = math.floor(10 * scale)
  local tuningBtnW = state.width - math.floor(20 * scale)
  local tuningBtnH = math.floor(22 * scale)

  -- label
  gfx.set(0.8, 0.8, 0.8, 1)
  gfx.x, gfx.y = tuningBtnX, tuningY
  gfx.drawstr("Tuning:")

  -- button
  local btnX = tuningBtnX + math.floor(60 * scale)
  local btnW = tuningBtnW - math.floor(60 * scale)
  local tuningLabel = config.tuningFile or "None (12-TET)"
  -- truncate long names
  if #tuningLabel > 20 then
    tuningLabel = tuningLabel:sub(1, 17) .. "..."
  end

  gfx.set(0.15, 0.15, 0.15, 1)
  gfx.rect(btnX, tuningY - math.floor(2 * scale), btnW, tuningBtnH, 1)
  gfx.set(0.4, 0.4, 0.4, 1)
  gfx.rect(btnX, tuningY - math.floor(2 * scale), btnW, tuningBtnH, 0)
  gfx.set(1, 1, 1, 1)
  gfx.x, gfx.y = btnX + math.floor(4 * scale), tuningY + math.floor(2 * scale)
  gfx.drawstr(tuningLabel)

  -- check for mouse click on tuning button
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local mouseClicked = gfx.mouse_cap & 1 == 1 and not state.wasMouseDown
  state.wasMouseDown = gfx.mouse_cap & 1 == 1

  if mouseClicked and mx >= btnX and mx <= btnX + btnW and my >= tuningY - math.floor(2 * scale) and my <= tuningY + tuningBtnH then
    -- build menu with position-to-file mapping
    local menuItems = { "None (12-TET)" }
    local sclFiles = getSclFiles()
    local posToFile = {}  -- maps menu position → filename
    local pos = 1  -- "None" is position 1

    if #sclFiles > 0 then
      table.insert(menuItems, "|")  -- separator (not counted in positions)

      -- group by first character for large collections
      if #sclFiles > 50 then
        local groups = {}
        for _, f in ipairs(sclFiles) do
          local firstChar = f:sub(1, 1):upper()
          if firstChar:match('%d') then firstChar = '0-9' end
          if not groups[firstChar] then groups[firstChar] = {} end
          table.insert(groups[firstChar], f)
        end

        local sortedKeys = {}
        for k in pairs(groups) do table.insert(sortedKeys, k) end
        table.sort(sortedKeys)

        for _, key in ipairs(sortedKeys) do
          local groupFiles = groups[key]
          table.insert(menuItems, ">" .. key .. " (" .. #groupFiles .. ")")
          pos = pos + 1  -- submenu header counts as a position
          for j, f in ipairs(groupFiles) do
            local prefix = (f == config.tuningFile) and "!" or ""
            -- close submenu on last item in group
            if j == #groupFiles then prefix = "<" .. prefix end
            table.insert(menuItems, prefix .. f)
            pos = pos + 1
            posToFile[pos] = f
          end
        end
      else
        for _, f in ipairs(sclFiles) do
          local prefix = (f == config.tuningFile) and "!" or ""
          table.insert(menuItems, prefix .. f)
          pos = pos + 1
          posToFile[pos] = f
        end
      end
    elseif not config.sclDirectory then
      table.insert(menuItems, "|")
      table.insert(menuItems, "#Set SCL directory in Settings")
    else
      table.insert(menuItems, "|")
      table.insert(menuItems, "#No .scl files found")
    end

    local menuStr = table.concat(menuItems, "|")
    local choice = helper.showMenu(menuStr)

    if choice == 1 then
      projectOverrides.tuningFile = ""
      saveProjectState(state.scriptID)
      applyEffectiveConfig()
      pbNeedsRedraw = true
    elseif posToFile[choice] then
      projectOverrides.tuningFile = posToFile[choice]
      saveProjectState(state.scriptID)
      applyEffectiveConfig()
      pbNeedsRedraw = true
    end
  end

  -- reset to System button (only shown if project has overrides)
  local resetY = math.floor(110 * scale)
  local resetBtnX = math.floor(10 * scale)
  local resetBtnW = state.width - math.floor(20 * scale)
  local resetBtnH = math.floor(20 * scale)

  if hasProjectOverrides() then
    gfx.set(0.3, 0.15, 0.15, 1)  -- Dark red background
    gfx.rect(resetBtnX, resetY, resetBtnW, resetBtnH, 1)
    gfx.set(0.5, 0.3, 0.3, 1)  -- Red border
    gfx.rect(resetBtnX, resetY, resetBtnW, resetBtnH, 0)
    gfx.set(1, 0.7, 0.7, 1)  -- Light red text
    local resetLabel = "Reset to System Defaults"
    local labelW = gfx.measurestr(resetLabel)
    gfx.x, gfx.y = resetBtnX + (resetBtnW - labelW) / 2, resetY + math.floor(3 * scale)
    gfx.drawstr(resetLabel)

    -- check for click on reset button
    if mouseClicked and mx >= resetBtnX and mx <= resetBtnX + resetBtnW and my >= resetY and my <= resetY + resetBtnH then
      clearProjectOverrides(state.scriptID)
      -- update field values to show system defaults
      state.fields[1].value = tostring(config.maxBendUp)
      state.fields[2].value = tostring(config.maxBendDown)
      recalcSemitones()
      local take = glob.liceData and glob.liceData.editorTake
      if take then updateScreenCoords(take) end
    end
  else
    -- show "Using System Defaults" indicator
    gfx.set(0.4, 0.4, 0.4, 1)
    local sysLabel = "(Using System Defaults)"
    local labelW = gfx.measurestr(sysLabel)
    gfx.x, gfx.y = resetBtnX + (resetBtnW - labelW) / 2, resetY + math.floor(3 * scale)
    gfx.drawstr(sysLabel)
  end

  -- instructions
  gfx.set(0.5, 0.5, 0.5, 1)
  gfx.x, gfx.y = math.floor(10 * scale), state.height - math.floor(22 * scale)
  gfx.drawstr("Tab: switch | Enter/b: save | Esc: cancel")

  gfx.update()
  r.defer(configDialogLoop)
end

local function openConfigDialog(scriptID)
  if configDialogState and configDialogState.active then return end  -- Already open

  local scale = helper.getDPIScale()
  local width, height = math.floor(300 * scale), math.floor(170 * scale)

  -- position near cursor, but ensure it doesn't go off screen
  local mx, my = r.GetMousePosition()
  local _, _, screenW, screenH = r.my_getViewport(0, 0, 0, 0, mx, my, mx, my, 0)
  local x = math.max(0, math.min(mx - width / 2, screenW - width))
  local y = math.max(0, math.min(my - height / 2, screenH - height))

  gfx.init("Pitch Bend Config", width, height, 0, x, y)
  gfx.setfont(1, "Arial", math.floor(12 * scale))

  configDialogState = {
    active = true,
    scriptID = scriptID,
    scale = scale,
    fields = {
      { label = "Bend Up (semitones):", value = tostring(config.maxBendUp), x = math.floor(10 * scale), y = math.floor(20 * scale), selected = true },
      { label = "Bend Down (semitones):", value = tostring(config.maxBendDown), x = math.floor(10 * scale), y = math.floor(50 * scale) },
    },
    focusedField = 1,
    width = width,
    height = height,
    wasMouseDown = false,
  }

  r.defer(configDialogLoop)
end

local function updateConfigDialog()
  -- no longer needed, dialog has its own defer loop
  return configDialogState and configDialogState.active
end

local function isConfigDialogOpen()
  return configDialogState and configDialogState.active
end

-- handle right-click (called from glob.handleRightClick)
-- cmd+right-click: adopt channel from nearest note
-- plain right-click: delete hovered point
local function handleRightClick(mods)
  local take = glob.liceData and glob.liceData.editorTake
  if not take or not mu then return false end

  -- cmd+right-click: adopt channel from nearest note at mouse position
  if mods and mods:ctrl() then
    local meState = glob.meState
    if not meState then return false end
    local sr = glob.liceData and glob.liceData.screenRect
    if not sr then return false end

    -- convert screen-absolute mouse coords to relative (0-based)
    local mx, my = r.GetMousePosition()
    my = coords.screenYToNative(my, sr)
    mx = mx - sr.x1
    my = my - sr.y1
    local ppqpos = screenXToPpq(mx, take)
    if not ppqpos then return false end
    local mousePitch = screenYToPitch(my)
    local ppq = mu.MIDI_GetPPQ(take) or 960
    local gridLookahead = glob.currentGrid and (ppq * glob.currentGrid * 2) or 0
    local lookahead = math.max(gridLookahead, ppq / 8)

    -- search all channels for nearest note by pitch
    -- two-pass: prefer sounding notes over upcoming notes
    local refNote = nil
    local minPitchDist = math.huge
    local adoptChan = nil

    -- pass 1: sounding notes only
    for chan, channelNotes in pairs(notesByChannel) do
      for _, note in ipairs(channelNotes) do
        if note.startppq <= ppqpos and note.endppq > ppqpos then
          local pitchDist = math.abs(note.pitch - mousePitch)
          if pitchDist < minPitchDist then
            minPitchDist = pitchDist
            refNote = note
            adoptChan = chan
          end
        end
      end
    end

    -- pass 2: upcoming notes (only if no sounding note found)
    if not refNote then
      for chan, channelNotes in pairs(notesByChannel) do
        for _, note in ipairs(channelNotes) do
          if note.startppq > ppqpos and note.startppq <= ppqpos + lookahead then
            local pitchDist = math.abs(note.pitch - mousePitch)
            if pitchDist < minPitchDist then
              minPitchDist = pitchDist
              refNote = note
              adoptChan = chan
            end
          end
        end
      end
    end

    if refNote and adoptChan then
      config.activeChannel = adoptChan
      config.showAllNotes = false
      saveActiveChannel()
      return true  -- handled, no undo needed
    end
    return false
  end

  -- plain right-click: delete hovered point
  if not hoveredPoint then return false end

  -- select the hovered point if not already selected
  if not hoveredPoint.point.selected then
    deselectAll()
    hoveredPoint.point.selected = true
  end

  -- delete selected points
  local undoText = deleteSelectedPoints(take, mu)
  if undoText then
    clearCache()
    return true, undoText
  end
  return false
end

local function toggleMicrotonalLines()
  config.showMicrotonalLines = not config.showMicrotonalLines
  pbNeedsRedraw = true
  return config.showMicrotonalLines
end

local function getActiveChannel()
  if config.showAllNotes then return nil end
  return config.activeChannel
end

local function showChannelMenu()
  -- extra guard: don't show menu if not in foreground (gfx.showmenu brings app to front)
  if not glob.editorIsForeground then return end

  helper.VKeys_ClearState()

  local currentChan = config.activeChannel or 0
  local menuItems = {}
  menuItems[1] = (config.showAllNotes and '!' or '') .. 'All'
  for i = 1, 16 do
    local prefix = (not config.showAllNotes and (i - 1 == currentChan)) and '!' or ''
    menuItems[i + 1] = prefix .. i
  end
  local menuStr = table.concat(menuItems, '|')

  local choice = helper.showMenu(menuStr)

  helper.VKeys_ClearState()

  if choice == 1 then
    config.showAllNotes = true
    saveActiveChannel()
  elseif choice > 1 then
    config.activeChannel = choice - 2  -- offset: 1 for menu index, 1 for "All"
    config.showAllNotes = false
    saveActiveChannel()
  end
  pbNeedsRedraw = true
end

-----------------------------------------------------------------------
-- module interface
-----------------------------------------------------------------------
PitchBend.handleState = handleState
PitchBend.saveState = saveState
PitchBend.processPitchBend = processPitchBend
PitchBend.getPBPoints = getPBPoints
PitchBend.getDragState = getDragState
PitchBend.getConfig = getConfig
PitchBend.getScaleSnapLines = getScaleSnapLines
PitchBend.setConfig = setConfig
PitchBend.cycleCurveType = cycleCurveType
PitchBend.showCurveMenu = showCurveMenu
PitchBend.selectAll = selectAll
PitchBend.syncSelectionToMIDI = syncSelectionToMIDI
PitchBend.deleteSelectedPoints = deleteSelectedPoints
PitchBend.stashClipboardSpan = stashClipboardSpan
PitchBend.deleteBeforePaste = deleteBeforePaste
PitchBend.snapSelectedToSemitone = snapSelectedToSemitone
PitchBend.getCurveTypeName = getCurveTypeName
PitchBend.consumeRedraw = function() if pbNeedsRedraw then pbNeedsRedraw = false return true end return false end
PitchBend.markDirty = function() pbNeedsRedraw = true end
PitchBend.shutdown = shutdown
PitchBend.setMIDIUtils = setMIDIUtils
PitchBend.clearCache = clearCache
PitchBend.getCenterLineState = getCenterLineState
PitchBend.getDrawState = getDrawState
PitchBend.openConfigDialog = openConfigDialog
PitchBend.updateConfigDialog = updateConfigDialog
PitchBend.isConfigDialogOpen = isConfigDialogOpen
PitchBend.hasProjectOverrides = hasProjectOverrides
PitchBend.handleRightClick = handleRightClick
PitchBend.toggleMicrotonalLines = toggleMicrotonalLines
PitchBend.getActiveChannel = getActiveChannel
PitchBend.showChannelMenu = showChannelMenu
PitchBend.restoreCursor = function()
  glob.setCursor(glob.wantsRightButton and glob.bend_cursor_rmb or glob.bend_cursor)
end

PitchBend.pbToSemitones = pbToSemitones
PitchBend.semitonesToPb = semitonesToPb
PitchBend.pbToBytes = pbToBytes
PitchBend.bytesToPb = bytesToPb
PitchBend.snapToSemitone = snapToSemitone
PitchBend.snapToMicrotonal = snapToMicrotonal

PitchBend.PB_CENTER = PB_CENTER
PitchBend.PB_MAX = PB_MAX
PitchBend.CHANMSG_PITCHBEND = CHANMSG_PITCHBEND
PitchBend.CURVE_STEP = CURVE_STEP
PitchBend.CURVE_LINEAR = CURVE_LINEAR
PitchBend.CURVE_SLOW_START = CURVE_SLOW_START
PitchBend.CURVE_SLOW_END = CURVE_SLOW_END
PitchBend.CURVE_BEZIER = CURVE_BEZIER

-- Mode interface implementation
function PitchBend.isActive()
  return glob.inPitchBendMode
end

function PitchBend.enter()
  glob.inPitchBendMode = true
  glob.inSlicerMode = false -- exclusive modes
  -- seed activeChannel from ME if filtering is active
  if not config.showAllNotes then
    local meActiveChan = math.max(0, (glob.meState.activeChannel or 1) - 1)
    config.activeChannel = meActiveChan
  end
end

function PitchBend.exit()
  glob.inPitchBendMode = false
  hoveredPoint = nil
  hoveredCurve = nil
  dragState = nil
  drawState = nil
  centerLineState.active = false
  centerLineState.locked = false
end

-- processInput wraps processPitchBend for mode interface
function PitchBend.processInput(mx, my, mouseState, mu, activeTake)
  if not glob.inPitchBendMode then return false, nil end
  return processPitchBend(mx, my, mouseState, mu, activeTake)
end

-- render is delegated to LICE (keeps bitmap management centralized)
function PitchBend.render(ctx)
  -- rendering handled by LICE.drawPitchBend for now
end

-- handleKey returns true if key was consumed
-- note: most PB key handling is in Lib.lua; this is for mode-specific keys
function PitchBend.handleKey(vState, mods)
  -- key handling currently in Lib.lua processKeys
  return false
end

-- test-only: expose internals for integration testing
PitchBend._test = {
  extractAndAssociate = function(take, midiUtils)
    local events = extractPBEvents(take, midiUtils)
    associatePBWithNotes(take, events, midiUtils)
    return events, notesByChannel
  end,
  findNoteAtTime = findNoteAtTime,
}

return PitchBend
