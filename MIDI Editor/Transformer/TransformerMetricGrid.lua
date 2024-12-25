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

local function parseMetricGridNotation(str)
  local mg = {}

  local fs, fe, mod, rst, pre, post, swing = string.find(str, '|([tdrm%-])([b-])|(.-)|(.-)|sw%((.-)%)$')
  if not (fs and fe) then
    fs, fe, mod, rst, pre, post = string.find(str, '|([tdrm%-])([b-])|(.-)|(.-)$')
  end
  if fs and fe then
    mg.modifiers =
      mod == 'r' and (gdefs.MG_GRID_SWING | gdefs.MG_GRID_SWING_REAPER) -- reaper
      or mod == 'm' and gdefs.MG_GRID_SWING -- mpc
      or mod == 't' and gdefs.MG_GRID_TRIPLET
      or mod == 'd' and gdefs.MG_GRID_DOTTED
      or gdefs.MG_GRID_STRAIGHT
    mg.wantsBarRestart = rst == 'b' and true or false
    mg.preSlopPercent = tonumber(pre)
    mg.postSlopPercent = tonumber(post)

    local reaperSwing = mg.modifiers & gdefs.MG_GRID_SWING_REAPER ~= 0
    mg.swing = swing and tonumber(swing)
    if not mg.swing then mg.swing = reaperSwing and 0 or 50 end
    if reaperSwing then
      mg.swing = mg.swing < -100 and -100 or mg.swing > 100 and 100 or mg.swing
    else
      mg.swing = mg.swing < 0 and 0 or mg.swing > 100 and 100 or mg.swing
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

return MetricGrid
