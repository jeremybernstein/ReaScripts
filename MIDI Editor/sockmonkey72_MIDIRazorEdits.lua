-- @description MIDI Razor Edits
-- @version 1.1.0-alpha.8
-- @author sockmonkey72
-- @about
--   # MIDI Razor Edits
-- @changelog
--   - add key commands for shifting the area (not contents) left/right [might change]
--   - add tab bar to settings script so that it will fit on smaller screens
-- @provides
--   {RazorEdits}/*
--   RazorEdits/MIDIUtils.lua https://raw.githubusercontent.com/jeremybernstein/ReaScripts/refs/heads/jb/extents_fixup/MIDI/MIDIUtils.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits_SelectedNotes.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits_Settings.lua

-- copyright (c) 2025 Jeremy Bernstein
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
