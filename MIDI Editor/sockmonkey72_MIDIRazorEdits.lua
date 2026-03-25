-- @description MIDI Razor Edits
-- @version 1.5.0-beta.19
-- @author sockmonkey72
-- @about
--   # MIDI Razor Edits
-- @changelog
--   - fix tuning menu: selection was off-by-N with grouped submenus
--   - fix config dialog: 'b' key no longer immediately closes dialog on open
--   - fix note boundary curves: curve direction now matches pitch bend direction per note
--   - fix pb note-search algo: no longer misses longer sounding notes behind short ones
--   - tuning change now updates microtonal line display immediately
--   - perf: binary search for note lookups and center-line positioning-- @provides
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
