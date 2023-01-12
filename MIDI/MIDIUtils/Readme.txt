--[[
   * Author: sockmonkey72 / Jeremy Bernstein
   * Licence: MIT
   * Version: 0.1.2
   * NoIndex: true
--]]

--[[

MIDI Utils API:

This project began as an attempt to rewrite some parts of Cockos' high-level ReaScript MIDI API, correcting some bugs
and improving some (at least from my perspective) less than ideal behaviors and restrictions. Once I finished the
subset of features I needed for one of my recent projects, I decided to keep going and just do the rest.

With some minor exceptions, this API is drop-in compatible with Cockos' API -- they can be used in parallel if necessary.
I've gone to some trouble to ensure that the behaviors, return values, etc. remain consistent (with some documented exceptions).

* MIDI_GetNote() start and end ppq positions should be consistent with how REAPER itself handles note-on/note-off
  matching and duration determination.
* MIDI_SetNote() will no longer arbitrarily truncate or elongate overlapping notes under certain circumstances
* MIDI_GetEvt() doesn't confuse note-on and note-off messages under certain circumstances
* MIDI_Get/Set/InsertNote() support release velocity
* Write operations (set/insert/delete) are by definition unsorted, as they occur in memory. The optional 'unsorted'
  argument to several API functions has been dropped (will be ignored), and in the case of the note operations,
  has been replaced with a release velocity argument. Sorting occurs automatically post-commit.
* API 'Write' operations don't write back to REAPER until MIDI_CommitWriteTransaction() is called.
* API 'Read' operations are based on the data in memory, not the data in the take. If updates are
  potentially occuring in REAPER 'behind the back' of the API (such as in a defer script), call
  MIDI_InitializeTake() every frame, or whenever you need to resync the in-memory data with the
  actual state of the take in REAPER.
* 'Read' operations don't require a transaction, and will generally trigger a MIDI_InitializeTake(take)
   event slurp if the requested take isn't already in memory.

In general, for many projects, dropping down to the low-level Get/SetAllEvts() API is overkill and, for many developers,
a terra incognita of status and data bytes in a 40-year-old serial specification. The high-level API is fairly
well-designed and easily applicable to many, if not most MIDI scripting problems. But it's buggy and there doesn't
appear to be much dev interest in solving these problems (some of which have been in the docket since 2016ish)
at the present time. So to make a long story short, I took some time to reimplement the very useful API in what I
hope is a more usable form (because fixed).

If the native API worked 100% correctly, there would be no point to this project, of course. My hope is that this
replacement becomes obsolete at some point, when Cockos circles around to working on MIDI stuff again in some uncertain
future. Until then, I hope this provides a useful interim solution to scripters struggling with the behavior and
reliability of the native API.

-----------------------------------------------------------------------------

USAGE:

    -- get the package path to MIDIUtils in my repository
  package.path = reaper.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
  local mu = require 'MIDIUtils'

    -- true by default, enabling argument type-checking, turn off for 'production' code
  -- mu.ENFORCE_ARGS = false -- or use mu.MIDI_InitializeTake(), see below

    -- enable overlap correction
  mu.CORRECT_OVERLAPS = true
    -- by default, note-ons take precedence when calculating overlap correction
    -- turn this on to favor selected notes' note-off instead
  -- mu.CORRECT_OVERLAPS_FAVOR_SELECTION = true

    -- return early if something is missing (currently no dependencies)
  if not mu.CheckDependencies('My Script') then return end

  local take = reaper.MIDIEditor_GetTake(MIDIEditor_GetActive())
  if not take then return end

    -- acquire events from take (can pass true/false as 2nd arg to enable/disable ENFORCE_ARGS)
    -- you will want to do this once per defer cycle in persistent scripts to ensure that the
    -- internal state matches the current take state
  mu.MIDI_InitializeTake(take)

    -- inform the library that we'll be writing to this take
  mu.MIDI_OpenWriteTransaction(take)

    -- insert a note
  mu.MIDI_InsertNote(take, true, false, 960, 1920, 0, 64, 64)

    -- insert a CC (using default CC curve)
  mu.MIDI_InsertCC(take, true, false, 960, 0xB0, 0, 1, 64)

    -- insert a CC, get new index (using default CC curve)
  local _, newidx = mu.MIDI_InsertCC(take, true, false, 1200, 0xB0, 0, 1, 96)

    -- insert another CC (using default CC curve)
  mu.MIDI_InsertCC(take, true, false, 1440, 0xB0, 0, 1, 127)

    -- change the CC shape of the 2nd CC to bezier with a 0.66 tension
  mu.MIDI_SetCCShape(take, newidx, 5, 0.66)

    -- commit the transaction to the take
    --   by default, this won't reacquire the MIDI events and update the
    --   take data in memory, pass 'true' as a 2nd argument if you want that
  mu.MIDI_CommitWriteTransaction(take)

    -- pass 'true' as a 3rd argument to MIDI_CommitWriteTransaction()
    --   to do this automatically
  reaper.MarkTrackItemsDirty(
    reaper.GetMediaItemTake_Track(take),
    reaper.GetMediaItemTake_Item(take))
--]]

-----------------------------------------------------------------------------

from ReaPack projects, you can include a copy of MIDIUtils.lua like this

-- @provides
--   MyScriptFolder/MIDIUtils.lua https://raw.githubusercontent.com/jeremybernstein/ReaScripts/main/MIDI/MIDIUtils.lua

which will grab the latest version of MIDIUtils.lua and place it in a project-specific folder
(the folder will be created if it doesn't already exist). If you include MIDIUtils like this,
I would be happy for an acknowledgement of usage in your README.

-----------------------------------------------------------------------------

MIDIUtils.SetOnError(fn)
--[[
    SetOnError: set an optional error callback for xpcall(), otherwise a
                traceback will be posted to the REAPER console window by default.

    Return value: none
--]]

boolean rv =
MIDIUtils.CheckDependencies(callerScriptName)
--[[
    CheckDependencies: check whether all MIDIUtils dependencies are met,
                       pass the name of your script as an argument, will be used as an
                       identifier in any error message generated.

    Return value:
      boolean rv: true if dependencies are met, false otherwise
--]]

-----------------------------------------------------------------------------

MIDIUtils.MIDI_InitializeTake(take, enforceargs = true)
--[[
    MIDI_InitializeTake: gather the events in a MediaItem_Take for use with
                         MIDIUtils. In simple usage, this call is optional -- API calls
                         will automatically call MIDI_InitializeTake() internally if the
                         provided take is not already prepared.

                         NOTE: if using MIDIUtils in a defer() script, you will want to
                         call this once per defer cycle to ensure that the MIDIUtils
                         internal state is synced with the take state.

                         The optional 'enforceargs' argument can be used to disable API argument
                         type enforcement for efficiency in production code.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER

    Return value: none
--]]

boolean rv, number notecnt, number ccevtcnt, number textsyxevtcnt =
MIDIUtils.MIDI_CountEvts(take)
--[[
    MIDI_CountEvts: provide a count of take events by type.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER

    Return values:
      boolean rv: true if successful, false otherwise
      number notecnt: count of note-on events
      number ccevtcnt: count of CC, pitch bend, program change, aftertouch events
      number textsyxevtcnt: count of meta and system exclusive events (not including bezier curves)
--]]

-----------------------------------------------------------------------------

MIDIUtils.MIDI_OpenWriteTransaction(take)
--[[
    MIDI_OpenWriteTransaction: start a 'write' transaction. MIDIUtils performs all
                               of its MIDI data manipulation in memory. Unlike Cockos'
                               high-level MIDI API, there are no 'immediately sorted'
                               API calls. To make changes to the data, you are required to
                               open a transaction, make all changes, and then commit the
                               transaction, which will write all changes in a single bulk set action.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER

    Return value: none
--]]

boolean rv =
MIDIUtils.MIDI_CommitWriteTransaction(take, refresh, dirty)
--[[
    MIDI_CommitWriteTransaction: end a 'write' transaction and commit the data to the take.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      boolean refresh: when true, MIDIUtils will re-initialize the take after commit
                       this is useful if you intend to perform further manipulation on the data post-commit
      boolean dirty: when true, MIDIUtils will dirty the take post-commit

    Return value: true on success, false otherwise
--]]

-----------------------------------------------------------------------------

boolean rv =
MIDIUtils.MIDI_CorrectOverlaps(take, favorSelection)
--[[
    MIDI_CorrectOverlaps: manually apply overlap correction to the current take. See also
                          MIDIUtils.CORRECT_OVERLAPS and MIDIUtils.CORRECT_OVERLAPS_FAVOR_SELECTION
                          for automatic overlap correction options.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      boolean favorSelection: when true, overlap correction will attempt to leave any selected
                              notes untouched (the note-on of position unselected note events will
                              be changed). When false (or missing), overlap correction will preserve
                              note-on positions and move note-offs to prevent MIDI overlaps. [optional]

    Return value: true on success, false otherwise
--]]

-----------------------------------------------------------------------------

boolean rv, boolean selected, boolean muted, number ppqpos, number endppqpos, number chan, number pitch, number vel, number relvel =
MIDIUtils.MIDI_GetNote(take, idx)
--[[
    MIDI_GetNote: Get MIDI note properties.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: note index (see MIDI_CountEvts for the number of MIDI notes)

    Return values:
      boolean rv: true on success, false otherwise
      boolean selected: true if note is selected
      boolean muted: true if note is muted
      number ppqpos: note-on PPQ position
      number endppqpos: note-off PPQ position
      number chan: MIDI channel (0 - 15)
      number pitch: MIDI note number (0 - 127)
      number vel: note-on velocity (0 - 127)
      number relvel: note-off velocity (0 - 127)
--]]

boolean rv =
MIDIUtils.MIDI_SetNote(take, idx, selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel)
--[[
    MIDI_SetNote: Set MIDI note properties for an existing event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: note index to modify (see MIDI_CountEvts for the number of MIDI notes)
      boolean selected: true if note is selected [optional]
      boolean muted: true if note is muted [optional]
      number ppqpos: note-on PPQ position [optional]
      number endppqpos: note-off PPQ position [optional]
      number chan: MIDI channel (0 - 15) [optional]
      number pitch: MIDI note number (0 - 127) [optional]
      number vel: note-on velocity (0 - 127) [optional]
      number relvel: note-off velocity (0 - 127) [optional]

    Return value: true on success, false otherwise
--]]

boolean rv, idx =
MIDIUtils.MIDI_InsertNote(take, selected, muted, ppqpos, endppqpos, chan, pitch, vel, relvel)
--[[
    MIDI_InsertNote: Create a new MIDI note event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      boolean selected: true if note is selected
      boolean muted: true if note is muted
      number ppqpos: note-on PPQ position
      number endppqpos: note-off PPQ position
      number chan: MIDI channel (0 - 15)
      number pitch: MIDI note number (0 - 127)
      number vel: note-on velocity (0 - 127)
      number relvel: note-off velocity (0 - 127) [optional, 0 if not provided]

    Return value:
      boolean rv: true on success, false otherwise
      number idx: new note index
--]]

boolean rv =
MIDIUtils.MIDI_DeleteNote(take, idx)
--[[
    MIDI_DeleteNote: Delete a note event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: note index to delete (see MIDI_CountEvts for the number of MIDI notes)

    Return value: true on success, false otherwise
--]]

-----------------------------------------------------------------------------

boolean rv, boolean selected, boolean muted, number ppqpos, number chanmsg, number chan, number msg2, number msg3 =
MIDIUtils.MIDI_GetCC(take, idx)
--[[
    MIDI_GetCC: Get CC/channel message properties.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: note index (see MIDI_CountEvts for the number of MIDI notes)

    Return values:
      boolean rv: true on success, false otherwise
      boolean selected: true if event is selected
      boolean muted: true if event is muted
      number ppqpos: event PPQ position
      number chanmsg: message type:
        0xA0 - poly pressure / aftertouch
        0xB0 - continuous controller
        0xC0 - program change [* only requres 2 bytes]
        0xD0 - channel pressure / aftertouch [* only requres 2 bytes]
        0xE0 - pitch bend
      number chan: MIDI channel (0 - 15)
      number msg2: 2nd message byte (0 - 127)
      number msg3: 3rd message byte (0 - 127)
--]]

boolean rv =
MIDIUtils.MIDI_SetCC(take, idx, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
--[[
    MIDI_SetCC: Set CC/channel message properties for an existing event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: CC event index to modify (see MIDI_CountEvts for the number of CC-like events)
      boolean selected: true if event is selected [optional]
      boolean muted: true if event is muted [optional]
      number ppqpos: event PPQ position [optional]
      number chanmsg: message type [optional]:
        0xA0 - poly pressure / aftertouch
        0xB0 - continuous controller
        0xC0 - program change [* only requres 2 bytes]
        0xD0 - channel pressure / aftertouch [* only requres 2 bytes]
        0xE0 - pitch bend
      number chan: MIDI channel (0 - 15) [optional]
      number msg2: 2nd message byte (0 - 127) [optional]
      number msg3: 3rd message byte (0 - 127) [optional]

    Return value: true on success, false otherwise
--]]

boolean rv, number idx =
MIDIUtils.MIDI_InsertCC(take, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
--[[
    MIDI_InsertCC: Create a new CC/channel message event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      boolean selected: true if event is selected
      boolean muted: true if event is muted
      number ppqpos: PPQ position
      number chanmsg: message type:
        0xA0 - poly pressure / aftertouch
        0xB0 - continuous controller
        0xC0 - program change [* only requres 2 bytes]
        0xD0 - channel pressure / aftertouch [* only requres 2 bytes]
        0xE0 - pitch bend
      number chan: MIDI channel (0 - 15)
      number msg2: 2nd message byte (0 - 127)
      number msg3: 3rd message byte (0 - 127)

    Return value:
      boolean rv: true on success, false otherwise
      number idx: new CC event index
--]]

boolean rv =
MIDIUtils.MIDI_DeleteCC(take, idx)
--[[
    MIDI_DeleteCC: Delete a CC/channel message event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: CC event index to delete (see MIDI_CountEvts for the number of CC-like events)

    Return value: true on success, false otherwise
--]]

-----------------------------------------------------------------------------

boolean rv, number shape, number beztension =
MIDIUtils.MIDI_GetCCShape(take, idx)
--[[
    MIDI_GetCCShape: Get CC shape and bezier tension.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: CC event index to query

    Return values:
      boolean rv: true on success, false otherwise
      number shape: curve shape
        0 - square
        1 - linear
        2 - slow start/end
        3 - fast start
        4 - fast end
        5 - bezier
      number beztension: bezier tension
--]]

boolean rv =
MIDIUtils.MIDI_SetCCShape(take, idx, shape, beztension)
--[[
    MIDI_SetCCShape: Set CC shape and bezier tension.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: CC event index to query
      number shape: curve shape
        0 - square
        1 - linear
        2 - slow start/end
        3 - fast start
        4 - fast end
        5 - bezier
      number beztension: bezier tension [required for shape 5 (bezier)]

    Return value: true on success, false otherwise
--]]

-----------------------------------------------------------------------------

boolean rv, boolean selected, boolean muted, number ppqpos, number type, string msg =
MIDIUtils.MIDI_GetTextSysexEvt(take, idx)
--[[
    MIDI_GetTextSysexEvt: Get meta / system exclusive message properties.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (see MIDI_CountEvts for the number of meta / sysex events)

    Return values:
      boolean rv: true on success, false otherwise
      boolean selected: true if event is selected
      boolean muted: true if event is muted
      number ppqpos: event PPQ position
      number type: message type
        -1 - system exclusive
        1 - 14: meta text event:
          1 - text
          2 - copyright notice
          3 - track name
          4 - instrument name
          5 - lyrics
          6 - marker
          7 - cue point
          8 - program name
          9 - device name
          10 - 14: REAPER-specific, undocumented
        15: REAPER notation event
      string msg: message payload (no header or footer bytes)
--]]

boolean rv =
MIDIUtils.MIDI_SetTextSysexEvt(take, idx, selected, muted, ppqpos, type, msg)
--[[
    MIDI_SetTextSysexEvt: Set meta / system exclusive message properties for an existing event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (see MIDI_CountEvts for the number of meta / sysex events)
      boolean selected: true if event is selected [optional]
      boolean muted: true if event is muted [optional]
      number ppqpos: event PPQ position [optional]
      number type: message type [optional, required if msg is provided]
        -1 - system exclusive
        1 - 14: meta text event:
          1 - text
          2 - copyright notice
          3 - track name
          4 - instrument name
          5 - lyrics
          6 - marker
          7 - cue point
          8 - program name
          9 - device name
          10 - 14: REAPER-specific, undocumented
        15: REAPER notation event
      string msg: message payload (no header or footer bytes) [optional, required if type is provided]

    Return values:
      boolean rv: true on success, false otherwise
--]]

boolean rv, number idx =
MIDIUtils.MIDI_InsertTextSysexEvt(take, selected, muted, ppqpos, type, bytestr)
--[[
    MIDI_InsertTextSysexEvt: Create a new meta / system exclusive message event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      boolean selected: true if event is selected
      boolean muted: true if event is muted
      number ppqpos: PPQ position
      number type: message type
        -1 - system exclusive
        1 - 14: meta text event:
          1 - text
          2 - copyright notice
          3 - track name
          4 - instrument name
          5 - lyrics
          6 - marker
          7 - cue point
          8 - program name
          9 - device name
          10 - 14: REAPER-specific, undocumented
        15: REAPER notation event
      string msg: message payload (no header or footer bytes)

    Return value:
      boolean rv: true on success, false otherwise
      number idx: new CC event index
--]]

boolean rv =
MIDIUtils.MIDI_DeleteTextSysexEvt(take, idx)
--[[
    MIDI_DeleteTextSysexEvt: Delete a meta / system exclusive message event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index to delete (see MIDI_CountEvts for the number of meta / sysex events)

    Return value: true on success, false otherwise
--]]

-----------------------------------------------------------------------------

boolean rv, boolean selected, boolean muted, number ppqpos, string msg =
MIDIUtils.MIDI_GetEvt(take, idx)
--[[
    MIDI_GetEvt: Get event properties.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (see MIDI_CountEvts for event count)

    Return values:
      boolean rv: true on success, false otherwise
      boolean selected: true if event is selected
      boolean muted: true if event is muted
      number ppqpos: event PPQ position
      string msg: complete message payload (incl. status, header and/or footer bytes)
--]]

boolean rv =
MIDIUtils.MIDI_SetEvt(take, idx, selected, muted, ppqpos, msg)
--[[
    MIDI_SetEvt: Set event properties for an existing event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (see MIDI_CountEvts for event count)
      boolean selected: true if event is selected [optional]
      boolean muted: true if event is muted [optional]
      number ppqpos: event PPQ position [optional]
      string msg: complete message payload (incl. status, header and/or footer bytes) [optional]

    Return value: true on success, false otherwise
--]]

boolean rv, number idx =
MIDIUtils.MIDI_InsertEvt(take, selected, muted, ppqpos, bytestr)
--[[
    MIDI_SetEvt: Insert new event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      boolean selected: true if event is selected
      boolean muted: true if event is muted
      number ppqpos: event PPQ position
      string msg: complete message payload (incl. status, header and/or footer bytes)

    Return value: true on success, false otherwise
--]]

boolean rv =
MIDIUtils.MIDI_DeleteEvt(take, idx)
--[[
    MIDI_DeleteEvt: Delete an event.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (see MIDI_CountEvts for event count)

    Return value: true on success, false otherwise
--]]

-----------------------------------------------------------------------------

number idx =
MIDIUtils.MIDI_EnumSelNotes(take, idx)
--[[
    MIDI_EnumSelNotes: Returns the index of the next selected MIDI note event after idx (-1 if there are no more selected events).

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (pass -1 to get the first selected note event)

    Return value: index of next selected MIDI Note event
--]]

number idx =
MIDIUtils.MIDI_EnumSelCC(take, idx)
--[[
    MIDI_EnumSelCC: Returns the index of the next selected MIDI CC event after idx (-1 if there are no more selected events).

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (pass -1 to get the first selected CC event)

    Return value: index of next selected MIDI CC event
--]]

number idx =
MIDIUtils.MIDI_EnumSelTextSysexEvts(take, idx)
--[[
    MIDI_EnumSelCC: Returns the index of the next selected MIDI meta / system exclusive event after idx (-1 if there are no more selected events).

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (pass -1 to get the first selected meta / sysex event)

    Return value: index of next selected MIDI meta / sysex event
--]]

number idx =
MIDIUtils.MIDI_EnumSelEvts(take, idx)
--[[
    MIDI_EnumSelCC: Returns the index of the next selected event after idx (-1 if there are no more selected events).

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (pass -1 to get the first selected event)

    Return value: index of next selected event of any type (note-on, note-off, CC, meta/sysex)
--]]

-----------------------------------------------------------------------------

number allcnt =
MIDIUtils.MIDI_CountAllEvts(take)
--[[
    MIDI_CountEvts: provide a count of all take events.

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER

    Return values:
      number allcnt: count of all events (note-on, note-off, CC, meta/sysex)
--]]

-----------------------------------------------------------------------------

number idx =
MIDIUtils.MIDI_EnumNotes(take, idx)
--[[
    MIDI_EnumNotes: Returns the index of the next MIDI note event after idx (-1 if there are no more events).

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (pass -1 to get the first note event)

    Return value: index of next MIDI Note event
--]]

number idx =
MIDIUtils.MIDI_EnumCC(take, idx)
--[[
    MIDI_EnumCC: Returns the index of the next MIDI CC event after idx (-1 if there are no more events).

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (pass -1 to get the first CC event)

    Return value: index of next MIDI CC event
--]]

number idx =
MIDIUtils.MIDI_EnumTextSysexEvts(take, idx)
--[[
    MIDI_EnumTextSysexEvts: Returns the index of the next MIDI meta / system exclusive event after idx (-1 if there are no more events).

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (pass -1 to get the first meta/sysex event)

    Return value: index of next MIDI meta/sysex event
--]]

number idx =
MIDIUtils.MIDI_EnumEvts(take, idx)
--[[
    MIDI_EnumEvts: Returns the index of the next event after idx (-1 if there are no more events).

    Arguments:
      MediaItem_Take take: the MediaItem_Take provided by REAPER
      number idx: event index (pass -1 to get the first event)

    Return value: index of next event of any type (note-on, note-off, CC, meta/sysex)
--]]

-----------------------------------------------------------------------------

string notename =
MIDIUtils.MIDI_NoteNumberToNoteName(notenum, names = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' })
--[[
    MIDI_NoteNumberToNoteName: Returns the note name + octave (i.e. A3, D#-1) of the provided MIDI note number.
                               Takes REAPER's MIDI octave name display offset preference into account.

    Arguments:
      number notenum: MIDI note number (0 - 127)
      number names: table of 12 pitch class names, from C - B, as they should be used for display [optional]

    Return value: note name + octave string for the input value
--]]

MIDIUtils.post(...)
MIDIUtils.p(...)
--[[
    Convenience method to post a message (or comma-delimited messages) to the REAPER console.
--]]

-----------------------------------------------------------------------------

MIDIUtils.ENFORCE_ARGS = true
--[
  Flag to enable/disable argument type-checking. When enabled, submitting the wrong argument type(s) to MIDIUtils
  functions will cause an error, useful for debugging code. Disable in production code, since the type checking
  adds some minimal overhead. On by default, see also MIDIUtils.InitializeTake(), where this can be set.
--]

MIDIUtils.CORRECT_OVERLAPS = false
--[
  Flag to enable/disable overlap correction on commit. Off by default, but may be desirable if the option "Correct
  overlapping notes while editing" is enabled, or for the Inline MIDI Editor (where that option is always active).
--]

MIDIUtils.CORRECT_OVERLAPS_FAVOR_SELECTION = false
--[
  If CORRECT_OVERLAPS is enabled, CORRECT_OVERLAPS_FAVOR_SELECTION determines whether the selection's note-off takes
  precedence over an unselected note-on when performing the overlap correction. Off by default.
--]

MIDIUtils.ALLSOUNDSOFF_SNAPS_TO_ITEM_END = true
--[
  If ALLSOUNDSOFF_SNAPS_TO_ITEM_END is enabled, the "All Sounds Off" event (at the end of every item) will be snapped
  to the end of the item, rather than floating around near the end of the item, or being stuck at the end of the
  last note, or whatever REAPER decides to do with it. On by default.
--]
