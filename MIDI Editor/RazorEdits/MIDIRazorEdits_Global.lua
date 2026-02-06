--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Global = {}

local helper = require 'MIDIRazorEdits_Helper'

local r = reaper

Global.scriptID = 'sockmonkey72_MIDIRazorEdits'
Global.DEBUG_LANES = false

--[[
{ UNDEFINED=0,
  POINTER=_load_cursor(32512),
  BEAM=_load_cursor(32513),
  LOADING=_load_cursor(32514),
  CROSSHAIR=_load_cursor(32515),
  UP_ARROW=_load_cursor(32516),
  SIZE_NW_SE=_load_cursor(rtk.os.linux and 32643 or 32642),
  SIZE_SW_NE=_load_cursor(rtk.os.linux and 32642 or 32643),
  SIZE_EW=_load_cursor(32644),
  SIZE_NS=_load_cursor(32645),
  MOVE=_load_cursor(32646),
  INVALID=_load_cursor(32648),
  HAND=_load_cursor(32649),
  POINTER_LOADING=_load_cursor(32650),
  POINTER_HELP=_load_cursor(32651),
  REAPER_FADEIN_CURVE=_load_cursor(105),
  REAPER_FADEOUT_CURVE=_load_cursor(184),
  REAPER_CROSSFADE=_load_cursor(463),
  REAPER_DRAGDROP_COPY=_load_cursor(182),
  REAPER_DRAGDROP_RIGHT=_load_cursor(1011),
  REAPER_POINTER_ROUTING=_load_cursor(186),
  REAPER_POINTER_MOVE=_load_cursor(187),
  REAPER_POINTER_MARQUEE_SELECT=_load_cursor(488),
  REAPER_POINTER_DELETE=_load_cursor(464),
  REAPER_POINTER_LEFTRIGHT=_load_cursor(465),
  REAPER_POINTER_ARMED_ACTION=_load_cursor(434),
  REAPER_MARKER_HORIZ=_load_cursor(188),
  REAPER_MARKER_VERT=_load_cursor(189),
  REAPER_ADD_TAKE_MARKER=_load_cursor(190),
  REAPER_TREBLE_CLEF=_load_cursor(191),
  REAPER_BORDER_LEFT=_load_cursor(417),
  REAPER_BORDER_RIGHT=_load_cursor(418),
  REAPER_BORDER_TOP=_load_cursor(419),
  REAPER_BORDER_BOTTOM=_load_cursor(421),
  REAPER_BORDER_LEFTRIGHT=_load_cursor(450),
  REAPER_VERTICAL_LEFTRIGHT=_load_cursor(462),
  REAPER_GRID_RIGHT=_load_cursor(460),
  REAPER_GRID_LEFT=_load_cursor(461),
  REAPER_HAND_SCROLL=_load_cursor(429),
  REAPER_FIST_LEFT=_load_cursor(430),
  REAPER_FIST_RIGHT=_load_cursor(431),
  REAPER_FIST_BOTH=_load_cursor(453),
  REAPER_PENCIL=_load_cursor(185),
  REAPER_PENCIL_DRAW=_load_cursor(433),
  REAPER_ERASER=_load_cursor(472),
  REAPER_BRUSH=_load_cursor(473),
  REAPER_ARP=_load_cursor(502),
  REAPER_CHORD=_load_cursor(503),
  REAPER_TOUCHSEL=_load_cursor(515),
  REAPER_SWEEP=_load_cursor(517),
  REAPER_FADEIN_CURVE_ALT=_load_cursor(525),
  REAPER_FADEOUT_CURVE_ALT=_load_cursor(526),
  REAPER_XFADE_WIDTH=_load_cursor(528),
  REAPER_XFADE_CURVE=_load_cursor(529),
  REAPER_EXTMIX_SECTION_RESIZE=_load_cursor(530),
  REAPER_EXTMIX_MULTI_RESIZE=_load_cursor(531),
  REAPER_EXTMIX_MULTISECTION_RESIZE=_load_cursor(532),
  REAPER_EXTMIX_RESIZE=_load_cursor(533),
  REAPER_EXTMIX_ALLSECTION_RESIZE=_load_cursor(534),
  REAPER_EXTMIX_ALL_RESIZE=_load_cursor(535),
  REAPER_ZOOM=_load_cursor(1009),
  REAPER_INSERT_ROW=_load_cursor(1010),
  REAPER_RAZOR=_load_cursor(599),
  REAPER_RAZOR_MOVE=_load_cursor(600),
  REAPER_RAZOR_ADD=_load_cursor(601),
  REAPER_RAZOR_ENVELOPE_VERTICAL=_load_cursor(202),
  REAPER_RAZOR_ENVELOPE_RIGHT_TILT=_load_cursor(203),
  REAPER_RAZOR_ENVELOPE_LEFT_TILT=_load_cursor(204)}
--]]

-- is this a problem, multiple initialization?
local scriptPath = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]

Global.normal_cursor = r.JS_Mouse_LoadCursor(helper.is_windows and 32512 or 0)
Global.razor_cursor1 = r.JS_Mouse_LoadCursor(599)
Global.razor_cursor_rmb = r.JS_Mouse_LoadCursorFromFile(scriptPath .. 'rmb.cur')
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
Global.slicer_cursor = r.JS_Mouse_LoadCursorFromFile(scriptPath .. 'slicer.cur')
Global.slicer_cursor_rmb = r.JS_Mouse_LoadCursorFromFile(scriptPath .. 'slicer_rmb.cur')
Global.bend_cursor = r.JS_Mouse_LoadCursorFromFile(scriptPath .. 'bend.cur')
Global.bend_cursor_rmb = r.JS_Mouse_LoadCursorFromFile(scriptPath .. 'bend_rmb.cur')
Global.draw_cursor = r.JS_Mouse_LoadCursor(185)
Global.hand_cursor = r.JS_Mouse_LoadCursor(32649)       -- IDC_HAND
Global.move_cursor = r.JS_Mouse_LoadCursor(32646)       -- IDC_SIZEALL
Global.bezier_cursor = r.JS_Mouse_LoadCursor(462)       -- bezier tension edit
-- Global.curve_select_cursor = r.JS_Mouse_LoadCursor(105) -- fade-in curve (curve type selection)
Global.curve_select_cursor = r.JS_Mouse_LoadCursorFromFile(scriptPath .. 'curve.cur')

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
Global.windowChanged = false
Global.currentGrid = nil
-- TODO: swing grid
Global.currentSwing = nil
Global.stretchMode = 0 -- default = compress/expand
Global.widgetStretchMode = 1
Global.wantsControlPoints = false
Global.wantsRightButton = false

Global.areas = {}
Global.liceData = nil
Global.deadZones = {}

Global.widgetInfo = nil
Global.changeWidget = nil
Global.inWidgetMode = false

Global.inSlicerMode = false
Global.slicerQuitAfterProcess = false

Global.inPitchBendMode = false
Global.pitchBendQuitOnToggle = false

Global.insertMode = false
Global.horizontalLock = false
Global.verticalLock = false

Global.editorIsForeground = true
Global.currentTime = 0.

Global.setCursor = setCursor
Global.refreshNoteTab = true

Global.GLOBAL_PREF_SLOP = helper.GLOBAL_PREF_SLOP

Global.STARTUP_SELECTED_NOTES = 1
Global.STARTUP_SLICER_MODE = 2
Global.STARTUP_PITCHBEND_MODE = 4



return Global