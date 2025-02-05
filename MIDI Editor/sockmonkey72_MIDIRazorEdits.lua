-- @description MIDI Razor Edits
-- @version 0.1.0-beta.25
-- @author sockmonkey72
-- @about
--   # MIDI Razor Edits
-- @changelog
--   - multi-item processing, initial version
--   - second pass at right-mouse button option
--   - fix overly strict left-drag limit to start of item
--   - only allow stretching, etc. if the area > 20px tall/wide, otherwise move/copy takes precedence
--   - using unofficial MIDIUtils for extents problem with items with a media offset (testing)
--   - moving editor window doesn't de-sync area locations
--   - add move area hotkey to settings
--   - add a bit more error reporting to settings
--   - change retrograde (preserve) default shortcut to shift+r
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

local _, _, sectionID, commandID = reaper.get_action_context()
lib.startup(sectionID, commandID)

-- set some kind of pref here (new area with selected notes, f.e.)

reaper.defer(function() xpcall(lib.loop, lib.onCrash) end)
reaper.atexit(lib.shutdown)
