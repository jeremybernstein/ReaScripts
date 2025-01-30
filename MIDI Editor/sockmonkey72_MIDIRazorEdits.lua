-- @description MIDI Razor Edits
-- @version 0.1.0-beta.22
-- @author sockmonkey72
-- @about
--   # MIDI Razor Edits
-- @changelog
--   - fix enter key for 'finishing' the widget
--   - add compress/expand to middle mode for widget (not available for normal stretching, doesn't make visual sense)
--     widget default and stretch default will be separated in a future beta
--   - moving multiple areas shouldn't cause minor relative timing variations
--   - make sure that unconsumed key events are sent to the correct Action section
--   - fix potential crash when removing CC lanes
--   - minor data structure optimizations
--   - profiler works again (infra)
-- @provides
--   {RazorEdits}/*
--   RazorEdits/MIDIUtils.lua https://raw.githubusercontent.com/jeremybernstein/ReaScripts/main/MIDI/MIDIUtils.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits_SelectedNotes.lua
--   [main=main,midi_editor] sockmonkey72_MIDIRazorEdits_Settings.lua

-- copyright (c) 2025 Jeremy Bernstein
-- with a big thanks to FeedTheCat for his assistance

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'RazorEdits/?.lua;' -- GET DIRECTORY FOR REQUIRE
local lib = require 'MIDIRazorEdits_Lib'

------------------------------------------------
------------------------------------------------

local _, _, sectionID, commandID = reaper.get_action_context()
lib.startup(sectionID, commandID)

-- set some kind of pref here (new area with selected notes, f.e.)

reaper.defer(function() xpcall(lib.loop, lib.onCrash) end)
reaper.atexit(lib.shutdown)
