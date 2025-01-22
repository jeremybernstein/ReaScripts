--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Global = {}

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'RazorEdits/?.lua;' -- GET DIRECTORY FOR REQUIRE
local classes = require 'MIDIRazorEdits_Classes'

local r = reaper

Global.DEBUG_LANES = false

-- this this a problem, multiple initialization?
Global.normal_cursor = r.JS_Mouse_LoadCursor(classes.is_windows and 32512 or 0)
Global.razor_cursor1 = r.JS_Mouse_LoadCursor(599)
Global.resize_left_cursor = r.JS_Mouse_LoadCursor(417)
Global.resize_right_cursor = r.JS_Mouse_LoadCursor(418)
Global.resize_top_cursor = r.JS_Mouse_LoadCursor(419)
Global.resize_bottom_cursor = r.JS_Mouse_LoadCursor(421)
Global.razor_move_cursor = r.JS_Mouse_LoadCursor(600)
Global.razor_copy_cursor = r.JS_Mouse_LoadCursor(601)
Global.segment_up_down_cursor = r.JS_Mouse_LoadCursor(202)
Global.tilt_left_cursor = r.JS_Mouse_LoadCursor(203)
Global.tilt_right_cursor = r.JS_Mouse_LoadCursor(204)
Global.stretch_left_cursor = r.JS_Mouse_LoadCursor(430)
Global.stretch_right_cursor = r.JS_Mouse_LoadCursor(431)
Global.stretch_up_down = r.JS_Mouse_LoadCursor(429)
Global.forbidden_cursor = r.JS_Mouse_LoadCursor(32648)
-- local empty_cursor = r.JS_Mouse_LoadCursorFromFile(debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'RazorEdits/empty.cur')

Global.prevCursor = Global.normal_cursor

local function setCursor(cursor, force)
  if cursor ~= Global.prevCursor or force then
    r.JS_Mouse_SetCursor(cursor)
    Global.prevCursor = cursor
  end
end

Global.meState = { leftmostTick = nil, topPitch = nil, pixelsPerTick = nil, pixelsPerPitch = nil, horzZoom = nil, timeBase = nil, pixelsPerSecond = nil, leftmostTime = nil }
Global.meLanes = {}

Global.isIntercept = false
Global.meNeedsRecalc = true
Global.needsRecomposite = true
Global.currentGrid = nil
-- TODO: swing grid
Global.currentSwing = nil

Global.areas = {}
Global.liceData = nil
Global.windowRect = nil
Global.deadZones = {}

Global.widgetInfo = nil
Global.changeWidget = nil
Global.inWidgetMode = false

Global.insertMode = false
Global.horizontalLock = false
Global.verticalLock = false

Global.appIsForeground = true
Global.currentTime = 0.

Global.setCursor = setCursor

return Global