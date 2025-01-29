-- @description MIDI Razor Edits
-- @version 0.1.0-beta.18
-- @author sockmonkey72
-- @about
--   # MIDI Razor Edits
-- @changelog
--   - eliminate unnecessary per-frame bounds calculation introduced in previous update
--   - more (non-)deletion/addition fixes when moving areas in the piano roll
--   - prevent areas in the Media Item "CC" lane
--   - fix drag-left to create a new area
--   - fix missing overlap prevention from above/below
--   - fix crash when opening Windows config dialog
--   - fix alt-drag (full-lane drag) in piano roll
--   - change Windows compositing defaults to 0.032/0.048 due to (apparent) performance changes in last versions
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
