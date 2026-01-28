--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local MetricGrid = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

local gdefs = require 'TransformerGeneralDefs'
local SMFParser = require 'lib.SMFParser.SMFParser'

local function getMetricGridModifiers(mg) -- used in ActionFuns, can we improve on that
  if mg then
    local mods = mg.modifiers & 0x7
    local reaperSwing = mg.modifiers & gdefs.MG_GRID_SWING_REAPER ~= 0
    return mods, reaperSwing
  end
  return gdefs.MG_GRID_STRAIGHT, false
end

local function generateMetricGridNotation(row)
  if not row.mg then return '' end
  local mgStr = '|'
  local mgMods, mgReaSwing = getMetricGridModifiers(row.mg)
  mgStr = mgStr .. (mgMods == gdefs.MG_GRID_SWING and (mgReaSwing and 'r' or 'm')
                      or mgMods == gdefs.MG_GRID_TRIPLET and 't'
                      or mgMods == gdefs.MG_GRID_DOTTED and 'd'
                      or '-')
  mgStr = mgStr .. (row.mg.wantsBarRestart and 'b' or '-')
  mgStr = mgStr .. string.format('|%0.2f|%0.2f', row.mg.preSlopPercent, row.mg.postSlopPercent)
  if mgMods == gdefs.MG_GRID_SWING then
    mgStr = mgStr .. '|sw(' .. string.format('%0.2f', row.mg.swing) .. ')'
  end
  if row.mg.roundmode and row.mg.roundmode ~= 'round' then
    mgStr = mgStr .. '|rd(' .. row.mg.roundmode .. ')'
  end
  return mgStr
end

local function setMetricGridModifiers(mg, mgMods, mgReaSwing)
  local mods = mg.modifiers & 0x7
  local reaperSwing = mg.modifiers & gdefs.MG_GRID_SWING_REAPER ~= 0
  if mg then
    mods = mgMods and (mgMods & 0x7) or mods
    if mgReaSwing ~= nil then reaperSwing = mgReaSwing end
    mg.modifiers = mods | (reaperSwing and gdefs.MG_GRID_SWING_REAPER or 0)
  end
  return mods, reaperSwing
end

-- parse groove file (.rgt format)
local function parseGrooveFile(filepath)
  local file = io.open(filepath, 'r')
  if not file then return nil end

  local version = 0
  local nBeats = 1
  local positions = {}

  for line in file:lines() do
    local vMatch = line:match('^Version:%s*(%d+)')
    if vMatch then
      version = tonumber(vMatch)
    end

    local beatsMatch = line:match('^Number of beats in groove:%s*(%d+)')
    if beatsMatch then
      nBeats = tonumber(beatsMatch)
    end

    -- skip header lines
    if not line:match('^Version:') and not line:match('^Number of beats') and not line:match('^Groove:') then
      -- version 0: position only, version 1: position amplitude
      if version == 0 then
        local pos = tonumber(line)
        if pos then
          table.insert(positions, { beat = pos, amplitude = 1.0 })
        end
      else
        local pos, amp = line:match('^([%d%.e%-]+)%s+([%d%.e%-]+)')
        if pos then
          table.insert(positions, { beat = tonumber(pos), amplitude = tonumber(amp) or 1.0 })
        else
          local posOnly = tonumber(line)
          if posOnly then
            table.insert(positions, { beat = posOnly, amplitude = 1.0 })
          end
        end
      end
    end
  end

  file:close()

  if #positions == 0 then return nil end

  return {
    version = version,
    nBeats = nBeats,
    positions = positions
  }
end

-- parse MIDI file as groove using SMFParser
-- @param filepath string - path to MIDI file
-- @param opts table - optional {threshold, thresholdMode, coalescingMode}
local function parseMIDIGroove(filepath, opts)
  local file = io.open(filepath, 'rb')
  if not file then return nil end

  local data = file:read('*all')
  file:close()

  local parsed, err = SMFParser.parse(data)
  if not parsed then return nil end

  -- merge defaults with provided options
  opts = opts or {}
  local extractOpts = {
    threshold = opts.threshold or 10,
    thresholdMode = opts.thresholdMode or "ms",
    coalescingMode = opts.coalescingMode or "first"
  }

  local groove, err2 = SMFParser.extractGroove(parsed.notes, parsed.header, extractOpts)
  return groove
end

-- load groove from file, auto-detecting format (.rgt or .mid/.smf)
-- @param filepath string - path to groove file
-- @param opts table - optional extraction options for MIDI files
local function loadGrooveFromFile(filepath, opts)
  if not filepath then return nil end
  local ext = filepath:lower():match('%.([^%.]+)$')
  if ext == 'mid' or ext == 'smf' or ext == 'midi' then
    return parseMIDIGroove(filepath, opts)
  else
    return parseGrooveFile(filepath)
  end
end

-- parse groove notation from the portion after $groove: |gf(<filepath>)|dir(<dir>)|vel(<vel>)|tol(<min>:<max>)|thr(<val>:<mode>)|coal(<mode>)
local function parseGrooveNotation(str)
  -- check for groove format - should contain gf() directive
  if not str:match('gf%(') then return nil end

  local groove = {}

  -- extract groove file path
  local gfPath = str:match('gf%((.-)%)')
  if gfPath then
    groove.filepath = gfPath
    -- extract MIDI extraction options (thr and coal) before loading
    local thrVal, thrMode = str:match('thr%(([%d%.]+):(%w+)%)')
    local coalMode = str:match('coal%((%d+)%)')
    local extractOpts = nil
    if thrVal or coalMode then
      extractOpts = {
        threshold = thrVal and tonumber(thrVal) or 10,
        thresholdMode = thrMode or 'ms',
        coalescingMode = coalMode == '1' and 'loudest' or 'first'
      }
    end
    groove.data = loadGrooveFromFile(gfPath, extractOpts)
  end

  -- extract direction: 0=both, 1=early only, 2=late only
  local dir = str:match('dir%((%d+)%)')
  groove.direction = dir and tonumber(dir) or 0

  -- extract velocity strength
  local vel = str:match('vel%((%d+)%)')
  groove.velStrength = vel and tonumber(vel) or 0

  -- extract tolerance min:max
  local tolMin, tolMax = str:match('tol%(([%d%.]+):([%d%.]+)%)')
  groove.toleranceMin = tolMin and tonumber(tolMin) or 0
  groove.toleranceMax = tolMax and tonumber(tolMax) or 100

  return groove
end

local function parseMetricGridNotation(str)
  local mg = {}

  -- check for groove notation first
  local groove = parseGrooveNotation(str)
  if groove then
    mg.isGroove = true
    mg.groove = groove
    return mg
  end

  local fs, fe, mod, rst, pre, post, swing = string.find(str, '|([tdrm%-])([b%-])|([^|]+)|([^|]+)|sw%((.-)%)')
  if not (fs and fe) then
    fs, fe, mod, rst, pre, post = string.find(str, '|([tdrm%-])([b%-])|([^|]+)|([^|]+).-$')
  end
  if fs and fe then
    local _, _, opt = string.find(str, '|rd%((.-)%)')
    local roundmode = opt == 'floor' and 'floor' or opt == 'ceil' and 'ceil' or 'round'
    mg.modifiers =
      mod == 'r' and (gdefs.MG_GRID_SWING | gdefs.MG_GRID_SWING_REAPER) -- reaper
      or mod == 'm' and gdefs.MG_GRID_SWING -- mpc
      or mod == 't' and gdefs.MG_GRID_TRIPLET
      or mod == 'd' and gdefs.MG_GRID_DOTTED
      or gdefs.MG_GRID_STRAIGHT

    mg.wantsBarRestart = rst == 'b' and true or false
    mg.preSlopPercent = tonumber(pre)
    mg.postSlopPercent = tonumber(post)
    mg.roundmode = roundmode

    local reaperSwing = mg.modifiers & gdefs.MG_GRID_SWING_REAPER ~= 0
    mg.swing = swing and tonumber(swing)
    if not mg.swing then mg.swing = reaperSwing and 0 or 50 end
    if reaperSwing then
      mg.swing = mg.swing < -100 and -100 or mg.swing > 100 and 100 or mg.swing
    else
      mg.swing = mg.swing < 0 and 0 or mg.swing > 100 and 100 or mg.swing
    end

    -- extract direction flags: df(N)
    local _, _, dfVal = string.find(str, 'df%((%d+)%)')
    if dfVal then
      mg.directionFlags = tonumber(dfVal)
    end

    -- extract distance scaling params: dm(rangeMin:rangeMax) for linear interpolation
    -- uses colon separator to avoid conflict with macro parameter comma parsing
    local _, _, dmMin, dmMax = string.find(str, 'dm%(([%d%.]+):([%d%.]+)%)')
    if dmMin and dmMax then
      mg.distanceRangeMin = tonumber(dmMin)
      mg.distanceRangeMax = tonumber(dmMax)
    end
  end
  return mg
end

local function makeDefaultMetricGrid(row, data)
  local isMetric = data.isMetric
  local metricLastUnit = data.metricLastUnit
  local musicalLastUnit = data.musicalLastUnit
  local metricLastBarRestart = data.metricLastBarRestart

  row.params[1].menuEntry = isMetric and metricLastUnit or musicalLastUnit
  -- row.params[2].textEditorStr = '0' -- don't overwrite defaults
  row.mg = {
    wantsBarRestart = metricLastBarRestart,
    preSlopPercent = 0,
    postSlopPercent = 0,
    modifiers = 0
  }
  return row.mg
end

MetricGrid.generateMetricGridNotation = generateMetricGridNotation
MetricGrid.setMetricGridModifiers = setMetricGridModifiers
MetricGrid.parseMetricGridNotation = parseMetricGridNotation
MetricGrid.makeDefaultMetricGrid = makeDefaultMetricGrid
MetricGrid.getMetricGridModifiers = getMetricGridModifiers
MetricGrid.parseGrooveNotation = parseGrooveNotation
MetricGrid.parseGrooveFile = parseGrooveFile
MetricGrid.loadGrooveFromFile = loadGrooveFromFile

return MetricGrid
