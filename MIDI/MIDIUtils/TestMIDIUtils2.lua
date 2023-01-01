--[[
   * Author: sockmonkey72 / Jeremy Bernstein
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
local mu = require('MIDIUtils')

r.Undo_BeginBlock2(0)

local take = r.MIDIEditor_GetTake(r.MIDIEditor_GetActive())
if take then
  local rv

  mu.MIDI_OpenWriteTransaction(take)

  local _, ctnote, ctcc, ctsyx = mu.MIDI_CountEvts(take)
  for i = 0, ctnote - 1 do
    mu.MIDI_DeleteNote(take, i)
  end
  for i = 0, ctcc - 1 do
    mu.MIDI_DeleteCC(take, i)
  end
  for i = 0, ctsyx - 1 do
    mu.MIDI_DeleteTextSysexEvt(take, i)
  end

  mu.MIDI_CommitWriteTransaction(take, true)

  mu.p('post-delete:', mu.MIDI_DebugInfo(take))

  local noteons, noteoffs, ccs, sysexes, metas, beziers, unknowns = mu.MIDI_DebugInfo(take)
  if noteons ~= 0 or noteoffs ~= 0 or ccs ~= 0 or sysexes ~= 0 or metas ~= 0 or beziers ~= 0 or unknowns ~= 0 then
    error('not all events deleted')
  end

  if mu.MIDI_CountAllEvts(take) ~= 0 then
    error('not all events deleted')
  end

  mu.MIDI_OpenWriteTransaction(take)
  mu.MIDI_InsertCC(take, false, false, 480, 0xB0, 0, 1, 32)
  mu.MIDI_InsertCC(take, false, false, 960, 0xB0, 0, 1, 96)
  mu.MIDI_InsertCC(take, false, false, 1440, 0xB0, 0, 1, 64)
  mu.MIDI_InsertCC(take, false, false, 1920, 0xB0, 0, 1, 127)
  mu.MIDI_InsertCC(take, false, false, 2400, 0xB0, 0, 1, 0)
  mu.MIDI_CommitWriteTransaction(take, true)

  mu.p('post-insert:', mu.MIDI_DebugInfo(take))

  mu.MIDI_OpenWriteTransaction(take)
  mu.MIDI_SetCCShape(take, 0, 5, -0.75)
  mu.MIDI_SetCCShape(take, 1, 1)
  mu.MIDI_SetCCShape(take, 2, 0)
  mu.MIDI_SetCCShape(take, 3, 5, 0.75)
  mu.MIDI_SetCCShape(take, 4, 2)
  mu.MIDI_CommitWriteTransaction(take, true)
  mu.p('post-shape:', mu.MIDI_DebugInfo(take))

  mu.MIDI_OpenWriteTransaction(take)
  mu.MIDI_SetCC(take, 0, false, false, 480, 0xB0, 0, 1, 0)
  mu.MIDI_SetCC(take, 1, false, false, 960, 0xB0, 0, 1, 127)
  mu.MIDI_SetCC(take, 2, false, false, 1440, 0xB0, 0, 1, 64)
  mu.MIDI_SetCC(take, 3, false, false, 1920, 0xB0, 0, 1, 96)
  mu.MIDI_SetCC(take, 4, false, false, 2400, 0xB0, 0, 1, 32)
  mu.MIDI_CommitWriteTransaction(take, true, true)

  local shape, btens
  _, shape, btens = mu.MIDI_GetCCShape(take, 0)
  if shape ~= 5 and btens ~= -0.75 then error('bad shape evt 0') end
  _, shape, btens = mu.MIDI_GetCCShape(take, 1)
  if shape ~= 1 then error('bad shape evt 1') end
  _, shape, btens = mu.MIDI_GetCCShape(take, 2)
  if shape ~= 0 then error('bad shape evt 2') end
  _, shape, btens = mu.MIDI_GetCCShape(take, 3)
  if shape ~= 5 and btens ~= 0.75 then error('bad shape evt 3') end
  _, shape, btens = mu.MIDI_GetCCShape(take, 4)
  if shape ~= 2 then error('bad shape evt 4') end

  mu.p('post-setcc:', mu.MIDI_DebugInfo(take))

end

r.Undo_EndBlock2(0, 'MIDIUtils Test2', -1)
