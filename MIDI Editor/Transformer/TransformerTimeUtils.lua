--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local TimeUtils = {}

local r = reaper
local gdefs = require 'TransformerGeneralDefs'

----------------------------------------------------------------------------------------
--------------------------------- TIME UTILITIES ---------------------------------------

-- forward declaration (required for mutual recursion)
local ppqToTime

local function getTimeOffset(correctMeasures)
  local offset = r.GetProjectTimeOffset(0, false)
  if correctMeasures then
    local rv, measoff = r.get_config_var_string('projmeasoffs')
    if rv then
      local mo = tonumber(measoff)
      if mo then
        local qn1, qn2
        _, qn1 = r.TimeMap_GetMeasureInfo(0, mo)
        _, qn2 = r.TimeMap_GetMeasureInfo(0, -1) -- 0 in the prefs interface is -1, go figure
        if qn1 and qn2 then
          local time1 = r.TimeMap2_QNToTime(0, qn1)
          local time2 = r.TimeMap2_QNToTime(0, qn2)
          offset = offset + (time2 - time1)
        end
      end
    end
  end
  return offset
end

local function bbtToPPQ(take, measures, beats, ticks, relativeppq, nosubtract)
  local nilmeas = measures == nil
  if not measures then measures = 0 end
  if not beats then beats = 0 end
  if not ticks then ticks = 0 end
  if relativeppq then
    local relMeasures, relBeats, _, relTicks = ppqToTime(relativeppq)
    measures = measures + relMeasures
    beats = beats + relBeats
    ticks = ticks + relTicks
  end
  local bbttime
  if nilmeas then
    bbttime = r.TimeMap2_beatsToTime(0, beats) -- have to do it this way, passing nil as 3rd arg is equivalent to 0 and breaks things
  else
    bbttime = r.TimeMap2_beatsToTime(0, beats, measures)
  end
  local ppqpos = r.MIDI_GetPPQPosFromProjTime(take, bbttime) + ticks
  if relativeppq and not nosubtract then ppqpos = ppqpos - relativeppq end
  return math.floor(ppqpos)
end

-- local
ppqToTime = function(take, ppqpos, projtime)
  local _, posMeasures, cml, posBeats = r.TimeMap2_timeToBeats(0, projtime)
  local _, posMeasuresSOM, _, posBeatsSOM = r.TimeMap2_timeToBeats(0, r.MIDI_GetProjTimeFromPPQPos(take, r.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)))

  local measures = posMeasures
  local beats = math.floor(posBeats - posBeatsSOM)
  cml = tonumber(cml) or 0
  posBeats = tonumber(posBeats) or 0
  local beatsmax = math.floor(cml)
  local posBeats_PPQ = bbtToPPQ(take, nil, math.floor(posBeats))
  local ticks = math.floor(ppqpos - posBeats_PPQ)
  return measures, beats, beatsmax, ticks
end

local function calcMIDITime(take, e)
  local timeAdjust = getTimeOffset()
  e.projtime = r.MIDI_GetProjTimeFromPPQPos(take, e.ppqpos) + timeAdjust
  if e.endppqpos then
    e.projlen = (r.MIDI_GetProjTimeFromPPQPos(take, e.endppqpos) + timeAdjust) - e.projtime
  else
    e.projlen = 0
  end
  e.measures, e.beats, e.beatsmax, e.ticks = ppqToTime(take, e.ppqpos, e.projtime)
end

local function timeFormatClampPad(str, min, max, fmt, startVal)
  local num = tonumber(str)
  if not num then num = 0 end
  num = num + (startVal and startVal or 0)
  num = (min and num < min) and min or (max and num > max) and max or num
  return string.format(fmt, num), num
end

local TIME_FORMAT_UNKNOWN = 0
local TIME_FORMAT_MEASURES = 1
local TIME_FORMAT_MINUTES = 2
local TIME_FORMAT_HMSF = 3

local function determineTimeFormatStringType(buf)
  if string.match(buf, '%d+') then
    local isMSF = false
    local isHMSF = false

    isHMSF = string.match(buf, '^%s-%d+:%d+:%d+:%d+')
    if isHMSF then return TIME_FORMAT_HMSF end

    isMSF = string.match(buf, '^%s-%d-:')
    if isMSF then return TIME_FORMAT_MINUTES end

    return TIME_FORMAT_MEASURES
  end
  return TIME_FORMAT_UNKNOWN
end

local function lengthFormatRebuf(buf)
  local format = determineTimeFormatStringType(buf)
  if format == TIME_FORMAT_UNKNOWN then return gdefs.DEFAULT_LENGTHFORMAT_STRING end

  local isneg = string.match(buf, '^%s*%-')

  if format == TIME_FORMAT_MEASURES then
    local absTicks = false
    local bars, beats, fraction, subfrac = string.match(buf, '(%d-)%.(%d+)%.(%d+)%.(%d+)')
    if not bars then
      bars, beats, fraction = string.match(buf, '(%d-)%.(%d+)%.(%d+)')
    end
    if not bars then
      bars, beats = string.match(buf, '(%d-)%.(%d+)')
    end
    if not bars then
      bars = string.match(buf, '(%d+)')
    end
    absTicks = string.match(buf, 't%s*$')

    if not bars or bars == '' then bars = 0 end
    bars = timeFormatClampPad(bars, 0, nil, '%d')
    if not beats or beats == '' then beats = 0 end
    beats = timeFormatClampPad(beats, 0, nil, '%d')

    if not fraction or fraction == '' then fraction = 0 end
    if absTicks and not subfrac then -- no range check on ticks
      return (isneg and '-' or '') .. bars .. '.' .. beats .. '.' .. fraction .. 't'
    else
      fraction = timeFormatClampPad(fraction, 0, 99, '%02d')

      if not subfrac or subfrac == '' then subfrac = nil end
      if subfrac then
        subfrac = timeFormatClampPad(subfrac, 0, 9, '%d')
      end
      return (isneg and '-' or '') .. bars .. '.' .. beats .. '.' .. fraction .. (subfrac and ('.' .. subfrac) or '')
    end
  elseif format == TIME_FORMAT_MINUTES then
    local minutes, seconds, fraction = string.match(buf, '(%d-):(%d+)%.(%d+)')
    local minutesVal, secondsVal
    if not minutes then
      minutes, seconds = string.match(buf, '(%d-):(%d+)')
      if not minutes then
        minutes = string.match(buf, '(%d-):')
      end
    end

    if not fraction or fraction == '' then fraction = 0 end
    fraction = timeFormatClampPad(fraction, 0, 999, '%03d')
    seconds, secondsVal = timeFormatClampPad(seconds, 0, nil, '%d')
    if secondsVal > 59 then
      minutesVal = math.floor(secondsVal / 60)
      seconds = string.format('%02d', secondsVal % 60)
    end
    if not minutes or minutes == '' then minutes = 0 end
    minutes = timeFormatClampPad(minutes, 0, nil, '%d', minutesVal)
    return (isneg and '-' or '') .. minutes .. ':' .. seconds .. '.' .. fraction
  elseif format == TIME_FORMAT_HMSF then
    local hours, minutes, seconds, frames = string.match(buf, '(%d-):(%d-):(%d-):(%d+)')
    local hoursVal, minutesVal, secondsVal, framesVal
    local frate = r.TimeMap_curFrameRate(0)

    if not frames or frames == '' then frames = 0 end
    frames, framesVal = timeFormatClampPad(frames, 0, nil, '%02d')
    if framesVal > frate then
      secondsVal = math.floor(framesVal / frate)
      frames = string.format('%03d', framesVal % frate)
    end
    if not seconds or seconds == '' then seconds = 0 end
    seconds, secondsVal = timeFormatClampPad(seconds, 0, nil, '%02d', secondsVal)
    if secondsVal > 59 then
      minutesVal = math.floor(secondsVal / 60)
      seconds = string.format('%02d', secondsVal % 60)
    end
    if not minutes or minutes == '' then minutes = 0 end
    minutes, minutesVal = timeFormatClampPad(minutes, 0, nil, '%02d', minutesVal)
    if minutesVal > 59 then
      hoursVal = math.floor(minutesVal / 60)
      minutes = string.format('%02d', minutesVal % 60)
    end
    if not hours or hours == '' then hours = 0 end
    hours = timeFormatClampPad(hours, 0, nil, '%d', hoursVal)
    return (isneg and '-' or '') .. hours .. ':' .. minutes .. ':' .. seconds .. ':' .. frames
  end
  return gdefs.DEFAULT_LENGTHFORMAT_STRING
end

local function timeFormatRebuf(buf)
  local format = determineTimeFormatStringType(buf)
  if format == TIME_FORMAT_UNKNOWN then return gdefs.DEFAULT_TIMEFORMAT_STRING end

  local isneg = string.match(buf, '^%s*%-')

  if format == TIME_FORMAT_MEASURES then
    local absTicks = false
    local bars, beats, fraction, subfrac = string.match(buf, '(%d-)%.(%d+)%.(%d+)%.(%d+)')
    if not bars then
      bars, beats, fraction = string.match(buf, '(%d-)%.(%d+)%.(%d+)')
    end
    if not bars then
      bars, beats = string.match(buf, '(%d-)%.(%d+)')
    end
    if not bars then
      bars = string.match(buf, '(%d+)')
    end
    absTicks = string.match(buf, 't%s*$')

    if not bars or bars == '' then bars = 0 end
    bars = timeFormatClampPad(bars, nil, nil, '%d')
    if not beats or beats == '' then beats = 1 end
    beats = timeFormatClampPad(beats, 1, nil, '%d')

    if not fraction or fraction == '' then fraction = 0 end
    if absTicks and not subfrac then -- no range check on ticks
      return (isneg and '-' or '') .. bars .. '.' .. beats .. '.' .. fraction .. 't'
    else
      fraction = timeFormatClampPad(fraction, 0, 99, '%02d')

      if not subfrac or subfrac == '' then subfrac = nil end
      if subfrac then
        subfrac = timeFormatClampPad(subfrac, 0, 9, '%d')
      end
      return (isneg and '-' or '') .. bars .. '.' .. beats .. '.' .. fraction .. (subfrac and ('.' .. subfrac) or '')
    end
  elseif format == TIME_FORMAT_MINUTES then
    local minutes, seconds, fraction = string.match(buf, '(%d-):(%d+)%.(%d+)')
    local minutesVal, secondsVal, fractionVal
    if not minutes then
      minutes, seconds = string.match(buf, '(%d-):(%d+)')
      if not minutes then
        minutes = string.match(buf, '(%d-):')
      end
    end

    if not fraction or fraction == '' then fraction = 0 end
    fraction = timeFormatClampPad(fraction, 0, 999, '%03d')
    seconds, secondsVal = timeFormatClampPad(seconds, 0, nil, '%d')
    if secondsVal > 59 then
      minutesVal = math.floor(secondsVal / 60)
      seconds = string.format('%02d', secondsVal % 60)
    end
    if not minutes or minutes == '' then minutes = 0 end
    minutes = timeFormatClampPad(minutes, 0, nil, '%d', minutesVal)
    return (isneg and '-' or '') .. minutes .. ':' .. seconds .. '.' .. fraction
  elseif format == TIME_FORMAT_HMSF then
    local hours, minutes, seconds, frames = string.match(buf, '(%d-):(%d-):(%d-):(%d+)')
    local hoursVal, minutesVal, secondsVal, framesVal
    local frate = r.TimeMap_curFrameRate(0)

    if not frames or frames == '' then frames = 0 end
    frames, framesVal = timeFormatClampPad(frames, 0, nil, '%02d')
    if framesVal > frate then
      secondsVal = math.floor(framesVal / frate)
      frames = string.format('%02d', framesVal % frate)
    end
    if not seconds or seconds == '' then seconds = 0 end
    seconds, secondsVal = timeFormatClampPad(seconds, 0, nil, '%02d', secondsVal)
    if secondsVal > 59 then
      minutesVal = math.floor(secondsVal / 60)
      seconds = string.format('%02d', secondsVal % 60)
    end
    if not minutes or minutes == '' then minutes = 0 end
    minutes, minutesVal = timeFormatClampPad(minutes, 0, nil, '%02d', minutesVal)
    if minutesVal > 59 then
      hoursVal = math.floor(minutesVal / 60)
      minutes = string.format('%02d', minutesVal % 60)
    end
    if not hours or hours == '' then hours = 0 end
    hours = timeFormatClampPad(hours, 0, nil, '%d', hoursVal)
    return (isneg and '-' or '') .. hours .. ':' .. minutes .. ':' .. seconds .. ':' .. frames
  end
  return gdefs.DEFAULT_TIMEFORMAT_STRING
end

----------------------------------------------------------------------------------------
--------------------------------- EXPORTS ----------------------------------------------

TimeUtils.getTimeOffset = getTimeOffset
TimeUtils.bbtToPPQ = bbtToPPQ
TimeUtils.ppqToTime = ppqToTime
TimeUtils.calcMIDITime = calcMIDITime
TimeUtils.lengthFormatRebuf = lengthFormatRebuf
TimeUtils.timeFormatRebuf = timeFormatRebuf
TimeUtils.determineTimeFormatStringType = determineTimeFormatStringType

-- constants for time format detection
TimeUtils.TIME_FORMAT_UNKNOWN = TIME_FORMAT_UNKNOWN
TimeUtils.TIME_FORMAT_MEASURES = TIME_FORMAT_MEASURES
TimeUtils.TIME_FORMAT_MINUTES = TIME_FORMAT_MINUTES
TimeUtils.TIME_FORMAT_HMSF = TIME_FORMAT_HMSF

return TimeUtils
