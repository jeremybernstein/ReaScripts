--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  REAPER API stub for testing modules outside REAPER
  Provides minimal functions needed for module loading
--]]

local reaper = {}

-- version info
function reaper.GetAppVersion()
  return "7.0/darwin-arm64"  -- simulate REAPER 7
end

-- resource path
function reaper.GetResourcePath()
  return "/mock/reaper/resources"
end

-- enumerate files/folders
function reaper.EnumerateSubdirectories(path, idx)
  if idx == -1 then return nil end  -- reset
  return nil  -- no subdirectories in stub
end

function reaper.EnumerateFiles(path, idx)
  if idx == -1 then return nil end  -- reset
  return nil  -- no files in stub
end

-- project time offset (usually 0)
function reaper.GetProjectTimeOffset(proj, rndframe)
  return 0
end

-- config variable access
function reaper.get_config_var_string(name)
  return "", false
end

-- measure info at time position
function reaper.TimeMap_GetMeasureInfo(proj, measure)
  -- returns: measure_start_qn, measure_end_qn, time_sig_num, time_sig_denom, tempo
  return 0, 4, 4, 4, 120
end

-- quarter notes to project time
function reaper.TimeMap2_QNToTime(proj, qn)
  -- default 120 BPM: 0.5 sec per quarter note
  return qn * 0.5
end

-- beats to project time
function reaper.TimeMap2_beatsToTime(proj, tpos, beats)
  -- default: same as QN
  return tpos + (beats * 0.5)
end

-- project time from PPQ position
function reaper.MIDI_GetProjTimeFromPPQPos(take, ppqpos)
  -- default 96 PPQ, 120 BPM
  local beats = ppqpos / 96
  return beats * 0.5
end

-- PPQ position from project time
function reaper.MIDI_GetPPQPosFromProjTime(take, projtime)
  -- default 96 PPQ, 120 BPM
  local beats = projtime / 0.5
  return beats * 96
end

-- PPQ at start of measure
function reaper.MIDI_GetPPQPos_StartOfMeasure(take, ppqpos)
  -- default 4/4, 96 PPQ: measure = 384 PPQ
  local measure = math.floor(ppqpos / 384)
  return measure * 384
end

-- project time to beats
function reaper.TimeMap2_timeToBeats(proj, tpos)
  -- default 120 BPM
  -- returns: beats, measures, cml, fullbeats, cdenom
  local beats = tpos / 0.5
  local measures = math.floor(beats / 4)
  local beatInMeasure = beats - (measures * 4)
  return beatInMeasure, measures, 0, beats, 4
end

-- frame rate
function reaper.TimeMap_curFrameRate(proj)
  -- returns: fps, drop_frame
  return 30, false
end

-- project time from beats
function reaper.TimeMap2_beatsToTime(proj, tpos, beats)
  -- default 120 BPM: 0.5 sec per beat
  return beats * 0.5
end

-- get track GUID
function reaper.GetTrackGUID(track)
  return "{00000000-0000-0000-0000-000000000000}"
end

-- get media item take GUID
function reaper.BR_GetMediaItemTakeGUID(take)
  return "{00000000-0000-0000-0000-000000000001}"
end

-- transformer runtime functions (used by generated code)
-- these are global functions, not in reaper namespace

function CreateNewMIDIEvent(event, value1, value2, context)
  -- stub: just return the event unchanged
  return event
end

function OperateEvent1(event, operation, param1, param2)
  -- stub: just return the event unchanged
  return event
end

function RandomValue(min, max)
  -- stub: handle both number and table args
  -- if args are tables (param expressions), return 0
  if type(min) == 'table' or type(max) == 'table' then
    return 0
  end
  -- return midpoint for numeric args
  return (min + max) / 2
end

function QuantizeMusicalPosition(event, take, PPQ, params)
  -- stub: just return the event unchanged
  return event
end

function SetMusicalLength(event, take, PPQ, params)
  -- stub: just return the event unchanged
  return event
end

function AddDuration(event, duration)
  -- stub: just return the event unchanged
  return event
end

function SubtractDuration(event, duration)
  -- stub: just return the event unchanged
  return event
end

function QuantizeMusicalEndPos(event, take, PPQ, params)
  -- stub: just return the event unchanged
  return event
end

function QuantizeMusicalLength(event, take, PPQ, params)
  -- stub: just return the event unchanged
  return event
end

function quantizeGroovePosition(event, take, PPQ, params)
  -- stub: just return the event unchanged
  return event
end

function quantizeGrooveEndPos(event, take, PPQ, params)
  -- stub: just return the event unchanged
  return event
end

function quantizeGrooveLength(event, take, PPQ, params)
  -- stub: just return the event unchanged
  return event
end

function LinearChangeOverSelection(event, context)
  -- stub: just return the event unchanged
  return event
end

function QuantizeTo(event, take, PPQ, params)
  -- stub: just return the event unchanged
  return event
end

function MultiplyPosition(event, multiplier)
  -- stub: just return the event unchanged
  return event
end

-- Set as global so all modules can access it
_G.reaper = reaper

return reaper
