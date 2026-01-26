-- @description MIDI Razor Edits
-- @version 1.5.0-beta.7
-- @author sockmonkey72
-- @about
--   # MIDI Razor Edits
-- @changelog
--   - add color pickers for pitchbend curve/point colors
--   - fix behavior when selection goes out of bounds in pitchbend mode
--   - some fixes for switching modes between main, slicer, pitchbend (and preventing same when dedicated scripts in use)
--   - minor cursor/focus fixups
--   - now using custom menu function where appropriate to work around gfx.showmenu multiple monitor limitations
-- @provides
--   {RazorEdits}/*
--   {RazorEdits}/{lib}/{lua-scala}/*
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
