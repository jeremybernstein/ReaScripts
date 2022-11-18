--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local reaper = reaper

_, _, sectionID = reaper.get_action_context()
-- ---------------- MIDI Editor ---------- Event List ------- Inline Editor
local isME = sectionID == 32060 or sectionID == 32061 or sectionID == 32062
if not isME then return end

package.path = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]] .. "?.lua;" -- GET DIRECTORY FOR REQUIRE
require "ThinCCs/ThinCCUtils"

local starttime, endtime = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
if starttime == endtime then return end -- no time selection

local take = reaper.MIDIEditor_GetTake(reaper.MIDIEditor_GetActive())
if take then
  local tt = {}
  local dt = { maxidx = 0 }
  local _, _, ccevtcnt = reaper.MIDI_CountEvts(take)

  local ppqstart = reaper.MIDI_GetPPQPosFromProjTime(take, starttime)
  local ppqend = reaper.MIDI_GetPPQPosFromProjTime(take, endtime)

  for idx = 0, ccevtcnt - 1 do
    local event = { idx = idx }
    _, event.selected, event.muted, event.ppqpos, event.chanmsg, event.chan, event.msg2, event.msg3 = reaper.MIDI_GetCC(take, idx)
    _, event.shape = reaper.MIDI_GetCCShape(take, idx)
    if event.ppqpos >= ppqstart and event.ppqpos <= ppqend then
      AddPointToList({ events = tt, todelete = dt }, event)
    end
  end

  local hasEvents = PrepareList({ events = tt, todelete = dt })
  if not hasEvents then return end

  reaper.Undo_BeginBlock2(0)
  PerformReduction({ events = tt, todelete = dt }, take)
  reaper.Undo_EndBlock2(0, "Thin CCs In Time Selection", -1)
end
