-- @description MIDI Razor Edits
-- @version 1.5.0-beta.23
-- @author sockmonkey72
-- @about
--   # MIDI Razor Edits
-- @changelog
--   - fix: ruler clicks/interaction restored in all modes (cursor resets, clicks pass through)
--   - fix: drag-to-create area completing properly when released outside piano roll
--   - fix: lost button-up detection when overlapping windows capture mouse events
--   - fix: defensive re-establishment of message intercepts if released by another script
--   - fix: focus-loss during drag now properly finalizes or cancels the operation
--   - fix: PB settings (and all module settings) now reload live from Settings dialog
--   - fix: PB config defaults properly restored when ExtState is deleted
--   - fix: color overrides no longer R/B-swapped on Windows (convertColorFromNative removed for user colors)
--   - fix: Settings color pickers now show actual theme-derived colors as defaults
--   - add: PB horizontal drag clamps to visible view bounds
--   - add: PB vertical drag clamps to visible note area
--   - add: PB drag cross-point behavior: Clamp mode (REAPER default, ±1 ppq) and Absorb mode (setting)
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
