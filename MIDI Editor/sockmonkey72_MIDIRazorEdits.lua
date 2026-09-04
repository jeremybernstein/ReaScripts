-- @description MIDI Razor Edits
-- @version 1.5.1-beta.4
-- @author sockmonkey72
-- @about
--   # MIDI Razor Edits
-- @changelog
--   - fix delete key falling through to the MIDI editor and deleting selected notes
--   - fix notes losing segments when split by an area (delete, move, stretch)
--   - fix a note crossing several areas only being cut at the first one when moving
--   - prevent copy with 'preserve overlaps' from deleting the source notes
--   - fix potential for CC events at the same position in different lanes being dropped
--   - fix potential for note and CC deletions colliding when one operation spans both
--   - CC control points: correct position and value tracking when moving, per-take
--     handling, and placement when editing several items at once
--   - fix 'add control points' preference never being saved
--   - new pref: guard destination context (CC control points)
--   - new pref: add control points for the widget
--   - hide MRE in event list and notation views, and give the keys back to the editor
--   - fix pitch bend mode keys being swallowed instead of passed to the editor
--   - perf: fewer full event scans and allocations while dragging
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
