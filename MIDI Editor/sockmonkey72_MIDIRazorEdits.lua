-- @description MIDI Razor Edits
-- @version 1.5.1-beta.1
-- @author sockmonkey72
-- @about
--   # MIDI Razor Edits
-- @changelog
--   - pitch bend display and editing now respect the MIDI editor's channel filter,
--     including multi-channel filters set in the event filter dialog
--   - marquee selection no longer selects PB points on hidden channels
--   - hiding a channel deselects any selected PB points, so they won't be deleted or
--     dragged while invisible
--   - new PB points take the channel of the note you're pointing at, for both
--     double-click insert and freehand draw
--   - when showing all channels, clicking empty space no longer inserts a point
--     measured against a note that isn't there (MIDI 60, C4)
--   - channel is always visible: hovering a point shows its channel, otherwise the
--     ruler shows the channel on which the next edit will land
--   - the pitch bend channel menu no longer sets the MIDI editor's "channel for new
--     events" — it could never set it reliably, and MRE now tracks its own channel internally
--   - note selection changes from outside of MRE (via script f.e.) will not change MRE's
--     channel target out from under the user
-- @provides
--   {RazorEdits}/*
--   {RazorEdits}/{lib}/{lua-scala}/*
--   {RazorEdits}/{lib}/{semver}/*
--   RazorEdits/MIDIUtils.lua https://raw.githubusercontent.com/jeremybernstein/ReaScripts/refs/heads/jb/extents_fixup/MIDI/MIDIUtils.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits_PitchBend.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits_SelectedNotes.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits_Slicer.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits_Settings.lua

-- copyright (c) 2026 Jeremy Bernstein
-- with a big thanks to FeedTheCat for his assistance

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'RazorEdits/?.lua;' -- GET DIRECTORY FOR REQUIRE
local lib = require 'MIDIRazorEdits_Lib'

------------------------------------------------
------------------------------------------------

if not lib then return end

local _, _, sectionID, commandID = reaper.get_action_context()
lib.startup(sectionID, commandID)

-- set some kind of pref here (new area with selected notes, f.e.)

reaper.defer(function() xpcall(lib.loop, lib.onCrash) end)
reaper.atexit(lib.shutdown)
