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

  --mu.MIDI_OpenWriteTransaction(take)
  --mu.MIDI_SetCCShape(take, 14, 5, -0.66)
  --mu.MIDI_CommitWriteTransaction(take)
  --if 1 then return end

  -------------------------------------------
  -- TEST DELETERS

  -- mu.post('pre:', mu.MIDI_DebugInfo(take))

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

  -- local delidx = 0
  --  rv = true
  -- while rv do
  --   rv = mu.MIDI_DeleteEvt(take, delidx)
  --   delidx = delidx + 1
  -- end


  mu.MIDI_CommitWriteTransaction(take, true)

  -- mu.post('post:', mu.MIDI_DebugInfo(take))

   noteons, noteoffs, ccs, sysexes, metas, beziers, unknowns = mu.MIDI_DebugInfo(take)
  if noteons ~= 0 or noteoffs ~= 0 or ccs ~= 0 or sysexes ~= 0 or metas ~= 0 or beziers ~= 0 or unknowns ~= 0 then
    error('not all events deleted')
  end

  if mu.MIDI_CountAllEvts(take) ~= 0 then
    error('not all events deleted')
  end

  -------------------------------------------
  -- TEST SETTERS

  mu.MIDI_OpenWriteTransaction(take)
  mu.MIDI_InsertNote(take, true, false, 480, 960, 0, 60, 92)
  mu.MIDI_InsertNote(take, false, true, 960, 1440, 0, 64, 32, 96)
  mu.MIDI_InsertNote(take, true, false, 1460, 1960, 1, 68, 257, 0)

  _, idx = mu.MIDI_InsertCC(take, true, false, 480, 0xB0, 0, 1, 32)
  mu.MIDI_SetCCShape(take, idx, 5, -0.66)
  mu.MIDI_InsertCC(take, false, false, 1440, 0xB0, 0, 1, 96)

  _, idx = mu.MIDI_InsertCC(take, false, false, 480, 0xC0, 1, 32, 0)
  mu.MIDI_InsertCC(take, true, false, 1440, 0xC0, 1, 96, 0)

  _, idx = mu.MIDI_InsertCC(take, false, false, 480, 0xD0, 2, 1, 32)
  mu.MIDI_InsertCC(take, true, false, 1440, 0xD0, 2, 1, 96)

  _, idx = mu.MIDI_InsertCC(take, false, false, 480, 0xE0, 3, 1, 32)
  mu.MIDI_InsertCC(take, true, false, 1440, 0xE0, 3, 1, 96)

  mu.MIDI_InsertTextSysexEvt(take, false, false, 1550, -1,
    table.concat({
      string.char(1),
      string.char(2),
      string.char(3),
      string.char(4),
      string.char(5)
    }))

  mu.MIDI_InsertTextSysexEvt(take, true, false, 1750, 2,
    table.concat({
      'foobar'
    }))

  mu.MIDI_CommitWriteTransaction(take, true)
  r.MarkTrackItemsDirty(r.GetMediaItemTake_Track(take), r.GetMediaItemTake_Item(take))

  -------------------------------------------
  -- TEST GETTERS

  _, notecnt, cccnt, syxcnt = reaper.MIDI_CountEvts(take)
  _, notecnt2, cccnt2, syxcnt2 = mu.MIDI_CountEvts(take)

  if notecnt ~= notecnt2 then error('note count mismatch') end
  if cccnt ~= cccnt2 then error('CC count mismatch') end
  if syxcnt ~= syxcnt2 then error('text/sysex count mismatch') end
  allcnt = mu.MIDI_CountAllEvts(take) -- includes note-off events, does not includes bezier events
  if allcnt ~= notecnt * 2 + cccnt + syxcnt then error('all count mismatch') end

  if notecnt ~= 3 then error('wrong note count') end
  if cccnt ~= 8 then error('wrong cc count') end
  if syxcnt ~= 2 then error('wrong syx count') end

  rv, selected, muted, ppqpos, endppqpos, chan, pitch, vel = r.MIDI_GetNote(take, 11)
  rv2, selected2, muted2, ppqpos2, endppqpos2, chan2, pitch2, vel2 = mu.MIDI_GetNote(take, 11)
  if rv ~= rv2
    or selected ~= selected2
    or muted ~= muted2
    or ppqpos ~= ppqpos2
    or endppqpos ~= endppqpos2
    or chan ~= chan2
    or pitch ~= pitch2
    or vel ~= vel2
  then error('note data mismatch') end -- REAPER returns false/0, '' for failed get


  rv, selected, muted, ppqpos, chanmsg, chan, msg2, msg3 = r.MIDI_GetCC(take, 14)
  rv2, selected2, muted2, ppqpos2, chanmsg2, chan2, msg2_2, msg3_2 = mu.MIDI_GetCC(take, 14)
  if rv ~= rv2
    or selected ~= selected2
    or muted ~= muted2
    or ppqpos ~= ppqpos2
    or chanmsg ~= chanmsg2
    or chan ~= chan2
    or msg2 ~= msg2_2
    or msg3 ~= msg3_2
  then error('CC data mismatch') end
  _, shape, beztension = r.MIDI_GetCCShape(take, 2)
  _, shape2, beztension2 = mu.MIDI_GetCCShape(take, 2)
  if shape ~= shape2
    or beztension ~= beztension2
  then error('bezier data mismatch') end

  rv, selected, muted, ppqpos, ttype, msg = r.MIDI_GetTextSysexEvt(take, 0)
  rv2, selected2, muted2, ppqpos2, ttype2, msg_2 = mu.MIDI_GetTextSysexEvt(take, 0)
  if rv ~= rv2
    or selected ~= selected2
    or muted ~= muted2
    or ppqpos ~= ppqpos2
    or ttype ~= ttype2
    or msg ~= msg_2
  then
    msglen = msg:len()
    msg_2_len = msg_2:len()
    b1 = msg:byte(1)
    b1_2 = msg_2:byte(1)
    b2 = msg:byte(2)
    b2_2 = msg_2:byte(2)
    b3 = msg:byte(3)
    b3_2 = msg_2:byte(3)
    error('sysex data mismatch')
  end

  for i = 0, allcnt - 1 do
    rv, selected, muted, ppqpos, msg = r.MIDI_GetEvt(take, i)
    rv2, selected2, muted2, ppqpos2, msg_2 = mu.MIDI_GetEvt(take, i)
    if rv ~= rv2
      or selected ~= selected2
      or muted ~= muted2
      or ppqpos ~= ppqpos2
      or msg ~= msg_2
    then
      msglen = msg:len()
      msg_2_len = msg_2:len()
      b1 = msg:byte(1)
      b1_2 = msg_2:byte(1)
      b2 = msg:byte(2)
      b2_2 = msg_2:byte(2)
      b3 = msg:byte(3)
      b3_2 = msg_2:byte(3)
      error('all event data mismatch @ '..i)
      break
    end
  end

  -------------------------------------------
  -- TEST ENUMERATORS

  local enumtbl = {}
  local enumtbl2 = {}

  local idx = r.MIDI_EnumSelNotes(take, -1)
  while idx ~= -1 do
    table.insert(enumtbl, idx)
    idx = r.MIDI_EnumSelNotes(take, idx)
  end

  idx = mu.MIDI_EnumSelNotes(take, -1)
  while idx ~= -1 do
    table.insert(enumtbl2, idx)
    idx = mu.MIDI_EnumSelNotes(take, idx)
  end

  if #enumtbl ~= #enumtbl2 then error('note enum idx count mismatch') end
  for k, v in ipairs(enumtbl) do
    if v ~= enumtbl2[k] then error('note enum idx mismatch') end
  end

  if #enumtbl ~= 2 then error('wrong selected note count') end

  enumtbl = {}
  enumtbl2 = {}

  idx = r.MIDI_EnumSelCC(take, -1)
  while idx ~= -1 do
    table.insert(enumtbl, idx)
    idx = r.MIDI_EnumSelCC(take, idx)
  end

  idx = mu.MIDI_EnumSelCC(take, -1)
  while idx ~= -1 do
    table.insert(enumtbl2, idx)
    idx = mu.MIDI_EnumSelCC(take, idx)
  end

  if #enumtbl ~= #enumtbl2 then error('CC enum idx count mismatch') end
  for k, v in ipairs(enumtbl) do
    if v ~= enumtbl2[k] then error('CC enum idx mismatch') end
  end

  if #enumtbl ~= 4 then error('wrong selected cc count') end

  enumtbl = {}
  enumtbl2 = {}

  idx = r.MIDI_EnumSelTextSysexEvts(take, -1)
  while idx ~= -1 do
    table.insert(enumtbl, idx)
    idx = r.MIDI_EnumSelTextSysexEvts(take, idx)
  end

  idx = mu.MIDI_EnumSelTextSysexEvts(take, -1)
  while idx ~= -1 do
    table.insert(enumtbl2, idx)
    idx = mu.MIDI_EnumSelTextSysexEvts(take, idx)
  end

  if #enumtbl ~= #enumtbl2 then error('text/syx enum idx count mismatch') end
  for k, v in ipairs(enumtbl) do
    if v ~= enumtbl2[k] then error('text/syx enum idx mismatch') end
  end

  if #enumtbl ~= 1 then error('wrong selected syx count') end

  enumtbl = {}
  enumtbl2 = {}

  idx = r.MIDI_EnumSelEvts(take, -1)
  while idx ~= -1 do
    table.insert(enumtbl, idx)
    idx = r.MIDI_EnumSelEvts(take, idx)
  end

  idx = mu.MIDI_EnumSelEvts(take, -1)
  while idx ~= -1 do
    table.insert(enumtbl2, idx)
    idx = mu.MIDI_EnumSelEvts(take, idx)
  end

  if #enumtbl ~= #enumtbl2 then error('all enum idx count mismatch') end
  for k, v in ipairs(enumtbl) do
    if v ~= enumtbl2[k] then error('all enum idx mismatch') end
  end

  if #enumtbl ~= 9 then error('wrong selected all count') end -- note offs are included here

  -- enumerator and getter/setter for all events including bezier?

  rv, selected, muted, ppqpos, endppqpos, chan, pitch, vel = mu.MIDI_GetNote(take, 0)
  mu.MIDI_OpenWriteTransaction(take)
  mu.MIDI_SetNote(take, 0, not selected, not muted, ppqpos + 960, endppqpos + 1440, chan + 1, pitch + 1, vel + 10)
  mu.MIDI_CommitWriteTransaction(take, true)
  rv2, selected2, muted2, ppqpos2, endppqpos2, chan2, pitch2, vel2 = r.MIDI_GetNote(take, 1) -- it moved, of course
  if selected2 ~= not selected
    or muted2 ~= not muted
    or ppqpos2 ~= ppqpos + 960
    or endppqpos2 ~= endppqpos + 1440
    or chan2 ~= chan + 1
    or pitch2 ~= pitch + 1
    or vel2 ~= vel + 10
  then error('bad note data in SetNote') end

  rv, selected, muted, ppqpos, chanmsg, chan, msg2, msg3 = mu.MIDI_GetCC(take, 1)
  mu.MIDI_OpenWriteTransaction(take)
  mu.MIDI_SetCC(take, 1, not selected, not muted, ppqpos + 960, chanmsg - 0x30, chan + 1, msg2 + 1, msg3 + 10)
  mu.MIDI_CommitWriteTransaction(take, true)
  rv2, selected2, muted2, ppqpos2, chanmsg2, chan2, msg2_2, msg3_2 = r.MIDI_GetCC(take, 7) -- it moved, of course
  if selected2 ~= not selected
    or muted2 ~= not muted
    or ppqpos2 ~= ppqpos + 960
    or chanmsg2 ~= chanmsg - 0x30
    or chan2 ~= chan + 1
    or msg2_2 ~= msg2 + 1
    or msg3_2 ~= msg3 + 10
  then error('bad CC data in SetCC') end

  rv, selected, muted, ppqpos, ttype, msg = mu.MIDI_GetTextSysexEvt(take, 1)
  mu.MIDI_OpenWriteTransaction(take)
  syxMsg = table.concat({ string.char(9), string.char(8), string.char(7) })
  mu.MIDI_SetTextSysexEvt(take, 1, not selected, not muted, ppqpos + 960, -1, syxMsg)
  mu.MIDI_CommitWriteTransaction(take, true)
  rv2, selected2, muted2, ppqpos2, ttype2, msg2 = r.MIDI_GetTextSysexEvt(take, 1) -- it moved, of course
  if selected2 ~= not selected
    or muted2 ~= not muted
    or ppqpos2 ~= ppqpos + 960
    or ttype2 ~= -1
    or msg2 ~= syxMsg
  then error('bad sysex data in SetTextSysexEvt') end

  rv, selected, muted, ppqpos, ttype, msg = mu.MIDI_GetTextSysexEvt(take, 0)
  mu.MIDI_OpenWriteTransaction(take)
  metaMsg = table.concat({ 'asshat' })
  mu.MIDI_SetTextSysexEvt(take, 0, not selected, not muted, ppqpos + 960, 2, metaMsg)
  mu.MIDI_CommitWriteTransaction(take, true)
  rv2, selected2, muted2, ppqpos2, ttype2, msg2 = r.MIDI_GetTextSysexEvt(take, 0) -- it moved, of course
  if selected2 ~= not selected
    or muted2 ~= not muted
    or ppqpos2 ~= ppqpos + 960
    or ttype2 ~= 2
    or msg2 ~= metaMsg
  then error('bad meta data in SetTextSysexEvt') end

  -- more of these to check complete replacements
  rv, selected, muted, ppqpos, msg = mu.MIDI_GetEvt(take, 0)
  mu.MIDI_OpenWriteTransaction(take)
  metaMsg = table.concat({ string.char(0xFF), string.char(1), 'popodoof' })
  mu.MIDI_SetEvt(take, 0, not selected, not muted, ppqpos + 960, metaMsg)
  mu.MIDI_CommitWriteTransaction(take, true)
  rv2, selected2, muted2, ppqpos2, ttype2, msg2 = r.MIDI_GetTextSysexEvt(take, 0) -- it moved, of course
  if selected2 ~= not selected
    or muted2 ~= not muted
    or ppqpos2 ~= ppqpos + 960
    or ttype2 ~= 1
    or msg2 ~= metaMsg:sub(3)
  then error('bad data in SetEvt') end


  r.MarkTrackItemsDirty(r.GetMediaItemTake_Track(take), r.GetMediaItemTake_Item(take))

end

r.Undo_EndBlock2(0, 'MIDIUtils Test', -1)
