--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local EventSelector = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

Shared = Shared or {} -- Use an existing table or create a new one

local function generateEventSelectorNotation(row)
  if not row.evsel then return '' end
  local evsel = row.evsel
  local evSelStr = string.format('%02X', evsel.chanmsg)
  evSelStr = evSelStr .. '|' .. evsel.channel
  evSelStr = evSelStr .. '|' .. evsel.selected
  evSelStr = evSelStr .. '|' .. evsel.muted
  if evsel.useval1 then
    evSelStr = evSelStr .. string.format('|%02X', evsel.msg2)
  end
  local scale = tonumber(evsel.scaleStr)
  if not scale then scale = 100 end
  if scale ~= 100 then
    evSelStr = evSelStr .. string.format('|%0.4f', scale):gsub("%.?0+$", "")
  end
  return evSelStr
end

local function parseEventSelectorNotation(str, row, paramTab)
  local evsel = {}
  local fs, fe, chanmsg, channel, selected, muted = string.find(str, '([0-9A-Fa-f]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)')
  local msg2, scale, savefe
  if fs and fe then
    savefe = fe
    evsel.chanmsg = tonumber(chanmsg:sub(1, 2), 16)
    evsel.channel = tonumber(channel)
    evsel.selected = tonumber(selected)
    evsel.muted = tonumber(muted)
    evsel.useval1 = false
    evsel.msg2 = 60
    evsel.scaleStr = '100'

    fs, fe, msg2 = string.find(str, '|([0-9A-Fa-f]+)', fe)
    if fs and fe then
      evsel.useval1 = true
      evsel.msg2 = tonumber(msg2:sub(1, 2), 16)
    end

    if not fe then fe = savefe end
    fs, fe, scale = string.find(str, '|([0-9.]+)', fe)
    if fs and fe then
      evsel.scaleStr = scale
    end

    for k, v in ipairs(paramTab) do
      if tonumber(v.text) == evsel.chanmsg then
        row.params[1].menuEntry = k
        break
      end
    end
    return evsel
  end
  return nil
end

local function makeDefaultEventSelector(row)
  row.params[1].menuEntry = 1
  row.params[2].menuEntry = 4 -- $1/16
  row.evsel = {
    chanmsg = 0x00,
    channel = -1,
    selected = -1,
    muted = -1,
    useval1 = false,
    msg2 = 60,
    scale = 100,
    scaleStr = '100'
  }
end

EventSelector.generateEventSelectorNotation = generateEventSelectorNotation
EventSelector.parseEventSelectorNotation = parseEventSelectorNotation
EventSelector.makeDefaultEventSelector = makeDefaultEventSelector

return EventSelector
