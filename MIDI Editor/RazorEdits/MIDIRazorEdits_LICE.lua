--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local Lice = {}

local r = reaper

-- package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'RazorEdits/?.lua;' -- GET DIRECTORY FOR REQUIRE
local classes = require 'MIDIRazorEdits_Classes'
local glob = require 'MIDIRazorEdits_Global'
local keys = require 'MIDIRazorEdits_Keys'
local helper = require 'MIDIRazorEdits_Helper'

local Point = classes.Point
local Rect = classes.Rect

local winscale = helper.is_windows and 2 or 1
local pixelScale

local MOAR_BITMAPS = true

-- magic numbers
Lice.EDGE_SLOP = 0
Lice.MIDI_RULER_H = 0
Lice.MIDI_SCROLLBAR_B = 0
Lice.MIDI_SCROLLBAR_R = 0
Lice.MIDI_HANDLE_L = 0
Lice.MIDI_HANDLE_R = 0
Lice.MIDI_SEPARATOR = 0

winscale = helper.getDPIScale()
pixelScale = math.floor((1 / winscale) + 0.5)

-- the Klangfarben Numbers are good for the large bitmap
-- for MOAR_BITMAPS, smaller defaults are more appropriate
Lice.compositeDelayMinDefault = MOAR_BITMAPS and 0.032 or 0.1 --0.020 -- 0.016 -- 0.05
Lice.compositeDelayMaxDefault = MOAR_BITMAPS and 0.048 or 0.2 --0.033 -- 0.024 -- 0.15
Lice.compositeDelayBitmapsDefault = 10 -- 15 -- 10 -- 100

Lice.compositeDelayMin = Lice.compositeDelayMinDefault
Lice.compositeDelayMax = Lice.compositeDelayMaxDefault
Lice.compositeDelayBitmaps = Lice.compositeDelayBitmapsDefault

local prevDPIScale

local function recalcConstants(force)
  local DPIScale = helper.getDPIScale()

  if not force and DPIScale ~= prevDPIScale then
    winscale = DPIScale
    pixelScale = math.floor((1 / winscale) + 0.5)
    prevDPIScale = DPIScale
    force = true
  end

  if force then
    local val
    Lice.EDGE_SLOP = math.floor((5 * winscale) + 0.5)
    val = helper.is_windows and 64 or 64 -- slight geom variations on Windows
    Lice.MIDI_RULER_H = math.floor((val * winscale) + 0.5)
    val = helper.is_windows and 17 or 15
    Lice.MIDI_SCROLLBAR_B = math.floor((val * winscale) + 0.5)
    val = helper.is_windows and 19 or 17
    Lice.MIDI_SCROLLBAR_R = math.floor((val * winscale) + 0.5)
    Lice.MIDI_HANDLE_L = math.floor((26 * winscale) + 0.5)
    Lice.MIDI_HANDLE_R = math.floor((26 * winscale) + 0.5)
    Lice.MIDI_SEPARATOR = math.floor((7 * winscale) + 0.5)
  end
end

local function pointConvertNative(x, y, windRect)
  if helper.is_macos then
    local x1, y1, x2, y2 = r.JS_Window_GetViewportFromRect(windRect.x1, windRect.y1, windRect.x2, windRect.y2, false)
    local height = math.abs(y2 - y1)
    return x, height - y
  end
  return x, y
end

local function prepMidiview(midiview)
  local _, x1, y1, x2, y2 = r.JS_Window_GetRect(midiview)
  local rect = Rect.new(x1, y1, x2, y2)
  local windChanged = false
  local oldy1 = rect.y1

  rect.y1 = rect.y1 + Lice.MIDI_RULER_H * (helper.is_macos and -1 or 1)

  if not glob.liceData
    or not rect:equals(glob.liceData.windRect)
  then
    recalcConstants()
    windChanged = true
    rect.y1 = oldy1 + Lice.MIDI_RULER_H * (helper.is_macos and -1 or 1)
  end
  return windChanged, rect
end

local numBitmaps = 0 -- print this out for diagnostics if it wets your whistle
local childHWND

local function destroyBitmap(bitmap)
  if bitmap then
    if childHWND then
      r.rcw_DestroyBitmap(bitmap)
    else
      r.JS_LICE_DestroyBitmap(bitmap)
    end
    numBitmaps = numBitmaps - 1
    return true
  end
  return false
end

local function createBitmap(w, h, upsizing)
  if childHWND then
    return r.rcw_CreateBitmap(w, h)
  else
    return r.JS_LICE_CreateBitmap(true, w + (upsizing and w or 0), h + (upsizing and h or 0)) -- when upsizing, make it double-the size so that we don't have to resize so often
  end
end

local function createMidiViewBitmap(midiview, windRect)
  local hwnd = childHWND and childHWND or midiview
  local integrated = not helper.is_windows or hwnd == childHWND

  local w, h = math.floor(windRect:width() + 0.5), math.floor(windRect:height() + 0.5)
  local bitmap = r.JS_LICE_CreateBitmap(true, w, h)
  numBitmaps = numBitmaps + 1
  r.JS_Composite(hwnd, 0, Lice.MIDI_RULER_H, w, h, bitmap, 0, 0, w, h, true)
  if not integrated then
    -- should only need to do this once for the view
    r.JS_Composite_Delay(midiview, Lice.compositeDelayMin, Lice.compositeDelayMax, Lice.compositeDelayBitmaps)
  end
  local x1, y1 = pointConvertNative(windRect.x1, windRect.y1, windRect)
  local x2, y2 = pointConvertNative(windRect.x2, windRect.y2, windRect)
  return bitmap, Rect.new(x1, y1, x2, y2)
end

local mouseIntercepts = {
  { timestamp = 0, passthrough = false, message = 'WM_SETCURSOR' },
  { timestamp = 0, passthrough = false, message = 'WM_LBUTTONDOWN' },
  { timestamp = 0, passthrough = false, message = 'WM_LBUTTONUP' },
  { timestamp = 0, passthrough = false, message = 'WM_LBUTTONDBLCLK' },
  { timestamp = 0, passthrough = false, message = 'WM_RBUTTONDOWN' }, -- ---------|
  { timestamp = 0, passthrough = false, message = 'WM_RBUTTONUP' }, -- need both -|
  { timestamp = 0, passthrough = false, message = 'WM_RBUTTONDBLCLK' },
  -- { timestamp = 0, passthrough = false, message = 'WM_MOUSEWHEEL' }, -- TODO
}

local appInterceptActiveMessageName = helper.is_linux and 'WM_ACTIVATEAPP' or 'WM_ACTIVATE'

local appIntercepts = {
  { timestamp = 0, passthrough = true, message = appInterceptActiveMessageName },
}

local keyMappings
local modMappings
local widgetMappings

local keyCt = 0

local userKeyMappings
local userModMappings
local userWidgetMappings

local function buildNewKeyMap()
  keyMappings = tableCopy(keys.defaultKeyMappings)
  if userKeyMappings then
    for k, map in pairs(userKeyMappings) do
      if keyMappings[k] then
        keyMappings[k] = map -- pre-vetted
      end
    end
  end
  keyMappings.enterKey = { name = 'Enter Key', baseKey = 'enter', vKey = keys.vKeys.VK_ENTER } -- always listen to enter

  for k, map in pairs(keyMappings) do
    map.vKey = map.vKey or keys.vKeyLookup[map.baseKey]
  end

  modMappings = tableCopy(keys.defaultModMappings)
  if userModMappings then
    for k, map in pairs(userModMappings) do
      if modMappings[k] and map.modKey then
        modMappings[k].modKey = map.modKey
      end
    end
  end

  widgetMappings = tableCopy(keys.defaultWidgetMappings)
  if userWidgetMappings then
    for k, map in pairs(userWidgetMappings) do
      if widgetMappings[k] and map.modKey then
        widgetMappings[k].modKey = map.modKey
      end
    end
  end

  -- _T(keyMappings)
  -- _T(modMappings)
end

local function keyIsMapped(k)
  for _, map in pairs(keyMappings) do
    if map.vKey == k then return true end
  end
  return false
end

local function initLiceKeys(onlyGlobal)
  if not keyMappings then buildNewKeyMap() end
  if glob.liceData and keyCt == 0 then
    for _, map in pairs(keyMappings) do
      if map.vKey and (not onlyGlobal or map.global) then
        r.JS_VKeys_Intercept(map.vKey, 1)
      end
    end
    keyCt = keyCt + 1
  end
end

local function shutdownLiceKeys(onlyGlobal)
  if glob.liceData and keyCt > 0 then
    for _, map in pairs(keyMappings) do
      if map.vKey and (not onlyGlobal or map.global) then
        r.JS_VKeys_Intercept(map.vKey, -1)
      end
    end
    keyCt = keyCt - 1
  end
end

local function loadKeyMappingState(stateTab)
  if userKeyMappings then userKeyMappings = nil end
  if stateTab then
    for k, map in pairs(stateTab) do
      if map.baseKey then
        local vKey = keys.vKeyLookup[map.baseKey]
        if vKey then
          if not userKeyMappings then userKeyMappings = {} end
          userKeyMappings[k] = { baseKey = map.baseKey, modifiers = map.modifiers, vKey = vKey } -- need to ensure that there are no duplicate key/modifiers pairs
        end
      end
    end
  end
end

local function loadModMappingState(stateTab)
  if userModMappings then userModMappings = nil end
  if stateTab then
    for k, map in pairs(stateTab) do
      if map.modKey then
        if not userModMappings then userModMappings = {} end
        userModMappings[k] = { modKey = map.modKey }
      end
    end
  end
end

local function loadWidgetMappingState(stateTab)
  if userWidgetMappings then userWidgetMappings = nil end
  if stateTab then
    for k, map in pairs(stateTab) do
      if map.modKey then
        if not userWidgetMappings then userWidgetMappings = {} end
        userWidgetMappings[k] = { modKey = map.modKey }
      end
    end
  end
end

local lastClickTime = 0

local attendKeyIntercepts
local ignoreKeyIntercepts
local interceptKeyInput = false
local interceptOnlyGlobal = false

local function reloadSettings()
  local oldState, oldGlobal = ignoreKeyIntercepts()

  local stateVal
  local stateTab

  stateVal = r.GetExtState(glob.scriptID, 'keyMappings')
  if stateVal then
    stateTab = fromExtStateString(stateVal)
  end
  loadKeyMappingState(stateTab)

  stateVal = r.GetExtState(glob.scriptID, 'modMappings')
  if stateVal then
    stateTab = fromExtStateString(stateVal)
  end
  loadModMappingState(stateTab)

  stateVal = r.GetExtState(glob.scriptID, 'widgetMappings')
  if stateVal then
    stateTab = fromExtStateString(stateVal)
  end
  loadWidgetMappingState(stateTab)

  keyMappings = nil
  modMappings = nil
  widgetMappings = nil

  buildNewKeyMap()

  if oldState then attendKeyIntercepts(oldGlobal) end
end

attendKeyIntercepts = function(onlyGlobal)
  if not interceptKeyInput or interceptOnlyGlobal ~= onlyGlobal then
    if interceptKeyInput then
      -- _P('shutdown', 'global? ' .. (interceptOnlyGlobal and 'true' or 'false'))
      shutdownLiceKeys(interceptOnlyGlobal)
    end

    glob.refreshNoteTab = true
    interceptKeyInput = true
    interceptOnlyGlobal = onlyGlobal or false
    -- _P('init', 'global? ' .. (interceptOnlyGlobal and 'true' or 'false'))
    initLiceKeys(onlyGlobal)
  end
end

ignoreKeyIntercepts = function()
  if interceptKeyInput then
    local wasGlobal = interceptOnlyGlobal
    -- _P('shutdown', 'global? ' .. (interceptOnlyGlobal and 'true' or 'false'))
    shutdownLiceKeys(interceptOnlyGlobal)
    interceptKeyInput = false
    interceptOnlyGlobal = false
    return true, wasGlobal
  end
  return false, false
end

local appInterceptsHWND
local lastPeekAppInterceptsTime

local function startAppIntercepts()
  if appInterceptsHWND or not glob.liceData then return end
  if r.JS_Window_IsChild(r.GetMainHwnd(), glob.liceData.editor) then
    appInterceptsHWND = r.GetMainHwnd()
  else
    appInterceptsHWND = glob.liceData.editor
  end
  for _, intercept in ipairs(appIntercepts) do
    r.JS_WindowMessage_Intercept(appInterceptsHWND, intercept.message, intercept.passthrough)
  end
  lastPeekAppInterceptsTime = nil
end

local function endAppIntercepts()
  if not appInterceptsHWND then return end
  for _, intercept in ipairs(appIntercepts) do
    r.JS_WindowMessage_Release(appInterceptsHWND, intercept.message)
    intercept.timestamp = 0
  end
  appInterceptsHWND = nil
  lastPeekAppInterceptsTime = nil
end

local function startIntercepts()
  if glob.isIntercept then return end
  glob.isIntercept = true
  if glob.liceData then
    for _, intercept in ipairs(mouseIntercepts) do
      r.JS_WindowMessage_Intercept(glob.liceData.midiview, intercept.message, intercept.passthrough)
    end
  end
  if helper.is_windows and r.APIExists('rcw_CreateCompositingOverlayForHWND') then
    childHWND = r.rcw_CreateCompositingOverlayForHWND(glob.liceData.midiview, "*MRE")
  end
  startAppIntercepts()
end

local function endIntercepts()
  if not glob.isIntercept then return end
  glob.isIntercept = false
  endAppIntercepts()
  if glob.liceData then
    shutdownLiceKeys()
    for _, intercept in ipairs(mouseIntercepts) do
      r.JS_WindowMessage_Release(glob.liceData.midiview, intercept.message)
      intercept.timestamp = 0
    end
    glob.setCursor(glob.normal_cursor)
    if helper.is_windows and r.APIExists('rcw_DestroyCompositingOverlay') and childHWND then
      r.rcw_DestroyCompositingOverlay(childHWND)
      childHWND = nil
    end  
  end
  glob.prevCursor = -1
end

local function passthroughIntercepts()
  if not glob.liceData then return end
  for _, intercept in ipairs(mouseIntercepts) do -- no app passthroughs
    local msg = intercept.message
    local ret, _, time, wpl, wph, lpl, lph = r.JS_WindowMessage_Peek(glob.liceData.midiview, msg)
    if ret and time ~= intercept.timestamp then
      intercept.timestamp = time
      r.JS_WindowMessage_Post(glob.liceData.midiview, intercept.message, wpl, wph, lpl, lph)
    end
  end
end

Lice.button = { pressX = nil, pressY = nil, click = nil, drag = nil, release = nil, dblclick = nil, dblclickSeen = nil }

local function resetButtons()
  Lice.button = {
                   pressX = nil,
                   pressY = nil,
                   click = nil,
                   drag = nil,
                   release = nil,
                   dblclick = nil,
                   dblclickSeen = nil,
                   which = nil,
                   canDrag = nil,
                   canNew = false
                 }
end

local function peekAppIntercepts(force)
  if force or not appInterceptsHWND then
    endAppIntercepts()
    startAppIntercepts()
  end

  if not appInterceptsHWND then return end

  if lastPeekAppInterceptsTime and glob.currentTime < lastPeekAppInterceptsTime + 0.5 then return end

  lastPeekAppInterceptsTime = glob.currentTime

  for _, intercept in ipairs(appIntercepts) do
    local msg = intercept.message
    local ret, _, time, wpl, wph, lpl, lph = r.JS_WindowMessage_Peek(appInterceptsHWND, msg)

    if ret and time ~= intercept.timestamp then
      intercept.timestamp = time

      if msg == appInterceptActiveMessageName then
        glob.editorIsForeground = (wpl ~= 0)
        if not glob.editorIsForeground then
          glob.setCursor(glob.normal_cursor)
        end
      end
    end
  end
end

local function handleButtonDown(m_x, m_y, which, hovering)
  Lice.button.which = which -- TODO refactor with below
  -- Only register the click if we're outside the double-click window
  if not Lice.button.pressX then
    Lice.button.pressX, Lice.button.pressY = m_x, m_y
    Lice.button.click = true
  else
    Lice.button.click = false
  end
  Lice.button.release = false
  if hovering then
    Lice.button.canDrag = hovering
  else
    Lice.button.canNew = true
  end
end

local function handleButtonResetState(which, state)
  resetButtons()
  Lice.button[state] = true
  Lice.button.which = which
end

local function peekIntercepts(m_x, m_y)
  if not glob.liceData then return end
  local DOUBLE_CLICK_DELAY = 0.2 -- 200ms, adjust based on system double-click time
  local hovering

  local pt = Point.new(m_x + glob.liceData.screenRect.x1, m_y + glob.liceData.screenRect.y1 - Lice.MIDI_RULER_H )
  for _, area in ipairs(glob.areas) do
    if area.viewRect:containsPoint(pt) then
      hovering = area
      break
    end
  end

  local prevClickTime = lastClickTime
  local currentTime = glob.currentTime

  for _, intercept in ipairs(mouseIntercepts) do
    local msg = intercept.message
    local ret, _, time, wpl, wph, lpl, lph = r.JS_WindowMessage_Peek(glob.liceData.midiview, msg)

    if ret and time ~= intercept.timestamp then
      intercept.timestamp = time

      -- if msg == 'WM_MOUSEWHEEL' then -- TODO: can use this to improve sync on scroll
      --   glob._P('mousewheel', wpl, wph, lpl, lph)
      -- end

      if msg == 'WM_RBUTTONDBLCLK' then
        -- Got a double click - clear any pending single click state
        if not Lice.button.dblclick then
          handleButtonResetState(1, 'dblclick')
        end
        lastClickTime = currentTime
      elseif msg == 'WM_RBUTTONDOWN' then
        if currentTime - prevClickTime > DOUBLE_CLICK_DELAY then
          if not glob.wantsRightButton or hovering then
            glob.handleRightClick()
            if glob.wantsRightButton then
              handleButtonResetState(1, 'clicked')
              Lice.button.pressX, Lice.button.pressY = m_x, m_y
            end
          else
            handleButtonDown(m_x, m_y, 1, hovering)
          end
        end
        lastClickTime = currentTime
      elseif msg == 'WM_RBUTTONUP' then
        if glob.wantsRightButton then
          if currentTime - prevClickTime > DOUBLE_CLICK_DELAY then
            if Lice.button.which == 1 then
              -- Only process the release if we're outside the double-click window
              if Lice.button.pressX then
                handleButtonResetState(1, 'release')
                return
              end
            end
            -- must have been pressed in a dead zone, post it
            r.JS_WindowMessage_Post(glob.liceData.midiview, intercept.message, wpl, wph, lpl, lph)
          end
        end
        lastClickTime = currentTime
        -- don't post if we're looking for the left button
      elseif msg == 'WM_LBUTTONDBLCLK' then
        -- Got a double click - clear any pending single click state
        if not Lice.button.dblclick then
          handleButtonResetState(0, 'dblclick')
        end
        lastClickTime = currentTime
      elseif msg == 'WM_LBUTTONDOWN' then
        if currentTime - prevClickTime > DOUBLE_CLICK_DELAY then
          if glob.wantsRightButton and not hovering then
            r.JS_WindowMessage_Post(glob.liceData.midiview, intercept.message, wpl, wph, lpl, lph)
          else
            handleButtonDown(m_x, m_y, 0, hovering)
          end
        end
        if helper.is_windows then
          -- on windows, we don't get focus back when clicking
          -- into the midiview for some reason I cannot explain.
          r.JS_Window_SetFocus(glob.liceData.midiview)
        end
        lastClickTime = currentTime
      elseif msg == 'WM_LBUTTONUP' then
        if currentTime - prevClickTime > DOUBLE_CLICK_DELAY then
          if Lice.button.which == 0 then
            -- Only process the release if we're outside the double-click window
            if Lice.button.pressX then
              handleButtonResetState(0, 'release')
              return
            end
          end
          -- must have been pressed in a dead zone, post it
          r.JS_WindowMessage_Post(glob.liceData.midiview, intercept.message, wpl, wph, lpl, lph)
        elseif glob.wantsRightButton then
          r.JS_WindowMessage_Post(glob.liceData.midiview, intercept.message, wpl, wph, lpl, lph)
        end
        lastClickTime = currentTime
      end
    end
  end
end

local composite

local function createFrameBitmaps(midiview, windRect)
  local bitmaps = {}

  local hwnd = childHWND and childHWND or midiview
  local integrated = not helper.is_windows or hwnd == childHWND

  local x1, y1 = pointConvertNative(windRect.x1, windRect.y1, windRect)
  local x2, y2 = pointConvertNative(windRect.x2, windRect.y2, windRect)

  if MOAR_BITMAPS then
  local meLanes = glob.meLanes
  if meLanes and next(meLanes) then
    local bottomPixel = meLanes[0] and meLanes[#meLanes].bottomPixel or meLanes[-1].bottomPixel
    local w, h = math.floor(windRect:width() + 0.5), math.floor( (bottomPixel - y1) + 0.5)
    bitmaps.top = createBitmap(1, 1)
    composite(hwnd, 0, Lice.MIDI_RULER_H, w, pixelScale, bitmaps.top, 0, 0, 1, 1)
    numBitmaps = numBitmaps + 1
    bitmaps.bottom = createBitmap(1, 1)
    composite(hwnd, 0, Lice.MIDI_RULER_H + (bottomPixel - y1) - pixelScale + 1, w, pixelScale, bitmaps.bottom, 0, 0, 1, 1, true)
    numBitmaps = numBitmaps + 1
    if meLanes[0] then
      local middleHeight = meLanes[0].topPixel - meLanes[-1].bottomPixel
      bitmaps.middletop = createBitmap(1, 1)
      composite(hwnd, 0, Lice.MIDI_RULER_H + (meLanes[-1].bottomPixel - y1) - (pixelScale - 1) + (pixelScale - 1), w, 1, bitmaps.middletop, 0, 0, 1, 1, true)
      numBitmaps = numBitmaps + 1
      bitmaps.middlebottom = createBitmap(1, 1)
      composite(hwnd, 0, Lice.MIDI_RULER_H + (meLanes[0].topPixel - y1) - (pixelScale - 1), w, 1, bitmaps.middlebottom, 0, 0, 1, 1, true)
      numBitmaps = numBitmaps + 1
    end
    bitmaps.left = createBitmap(1, 1)
    composite(hwnd, 0, Lice.MIDI_RULER_H, pixelScale, h, bitmaps.left, 0, 0, 1, 1, true)
    numBitmaps = numBitmaps + 1
    bitmaps.right = createBitmap(1, 1)
    composite(hwnd, w - Lice.MIDI_SCROLLBAR_R - (pixelScale - 1), Lice.MIDI_RULER_H, pixelScale, h, bitmaps.right, 0, 0, 1, 1, true)
    numBitmaps = numBitmaps + 1

    if not integrated then
      -- should only need to do this once for the view
      r.JS_Composite_Delay(midiview, Lice.compositeDelayMin, Lice.compositeDelayMax, Lice.compositeDelayBitmaps)
    end
  end
  end

  return bitmaps, Rect.new(x1, y1, x2, y2)
end

local recompositeInit
local recompositeDraw

local function viewIntersectionRect(area)
  local idx = area.ccLane and area.ccLane or -1
  return Rect.new(math.max(area.logicalRect.x1, glob.windowRect.x1),
                  math.max(area.logicalRect.y1, glob.meLanes[idx].topPixel),
                  math.min(area.logicalRect.x2, glob.windowRect.x2),
                  math.min(area.logicalRect.y2, glob.meLanes[idx].bottomPixel))
end

local function initLice(editor)
  if not glob.meLanes then return end
  if glob.liceData and glob.liceData.editor == editor then
    local windChanged, windRect = prepMidiview(glob.liceData.midiview)
    if windChanged 
      or not next(glob.liceData.bitmaps)
      or recompositeInit 
    then
      glob.liceData.windRect = windRect
      -- Create new bitmaps
      for _, bitmap in pairs(glob.liceData.bitmaps) do
        if bitmap then destroyBitmap(bitmap) end
      end
      glob.liceData.bitmaps, glob.liceData.screenRect = createFrameBitmaps(glob.liceData.midiview, windRect)
      if glob.DEBUG_LANES or not MOAR_BITMAPS then
        if glob.liceData.bitmap then destroyBitmap(glob.liceData.bitmap) end
        glob.liceData.bitmap = createMidiViewBitmap(glob.liceData.midiview, windRect)
      end
      glob.windowRect = glob.liceData.screenRect:clone()
      recompositeDraw = true
      glob.wantsAnalyze = true
      peekAppIntercepts(true)
    end
  elseif editor then
    local midiview = r.JS_Window_FindChildByID(editor, 1001)
    if midiview then
      local _, windRect = prepMidiview(midiview)
      local bitmaps, screenRect = createFrameBitmaps(midiview, windRect)
      glob.liceData = { editor = editor, midiview = midiview, bitmaps = bitmaps, windRect = windRect, screenRect = screenRect }
      if glob.DEBUG_LANES or not MOAR_BITMAPS then
        glob.liceData.bitmap = createMidiViewBitmap(midiview, windRect)
      end
      glob.windowRect = glob.liceData.screenRect:clone()
      recompositeDraw = true
      glob.wantsAnalyze = true
      peekAppIntercepts(true)
      startIntercepts()
    end
  end
  recompositeInit = false
end

local function shutdownLice()
  for _, area in ipairs(glob.areas) do
    if destroyBitmap(area.bitmap) then
      area.bitmap = nil
    end
  end

  if glob.liceData then
    if MOAR_BITMAPS then
    if glob.liceData.bitmaps then
      for _, bitmap in pairs(glob.liceData.bitmaps) do
        if bitmap then destroyBitmap(bitmap) end
      end
      glob.liceData.bitmaps = nil
    end
    end
    if glob.DEBUG_LANES or not MOAR_BITMAPS then
      if destroyBitmap(glob.liceData.bitmap) then
        glob.liceData.bitmap = nil
      end
    end
  end
  endIntercepts()
  glob.liceData = nil
  glob.setCursor(glob.normal_cursor)
end

local function convertColorFromNative(col)  
  if helper.is_windows then
    col = (col & 0xFF000000)
        | (col & 0xFF) << 16
        | (col & 0xFF00)
        | (col & 0xFF0000) >> 16
    return col
  end
  return col
end

local reFillColor = convertColorFromNative(r.GetThemeColor('areasel_fill', 0) + (0x5F << 24))
local reBorderColor = convertColorFromNative(r.GetThemeColor('areasel_outline', 0) + (0xFF << 24))

-- Convert 32-bit ARGB to components
local function argbToComponents(argb)
  local a = math.floor(argb / 0x1000000) % 256
  local cr = math.floor(argb / 0x10000) % 256
  local cg = math.floor(argb / 0x100) % 256
  local cb = argb % 256
  return a, cr, cg, cb
end

-- Convert components to 32-bit ARGB
local function componentsToARGB(a, cr, cg, cb)
  return a * 0x1000000 + cr * 0x10000 + cg * 0x100 + cb
end

-- Convert RGB to HSL
local function rgbToHSL(cr, cg, cb)
  cr, cg, cb = cr/255, cg/255, cb/255
  local max = math.max(cr, cg, cb)
  local min = math.min(cr, cg, cb)
  local h, s, l = 0, 0, (max + min) / 2

  if max ~= min then
    local d = max - min
    s = l > 0.5 and d / (2 - max - min) or d / (max + min)

    if max == cr then
      h = (cg - cb) / d + (cg < cb and 6 or 0)
    elseif max == cg then
      h = (cb - cr) / d + 2
    else
      h = (cr - cg) / d + 4
    end
    h = h / 6
  end

  return h * 360, s * 100, l * 100
end

-- Convert HSL to RGB
local function hslToRGB(h, s, l)
  h, s, l = h/360, s/100, l/100

  local function hue2rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
  end

  local cr, cg, cb
  if s == 0 then
    cr, cg, cb = l, l, l
  else
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    cr = hue2rgb(p, q, h + 1/3)
    cg = hue2rgb(p, q, h)
    cb = hue2rgb(p, q, h - 1/3)
  end

  return math.floor(cr * 255 + 0.5), math.floor(cg * 255 + 0.5), math.floor(cb * 255 + 0.5)
end

-- Generate vibrant contrast color for 32-bit ARGB
local function generateVibrantContrast32(argb)
  local a, cr, cg, cb = argbToComponents(argb)
  local h, s, l = rgbToHSL(cr, cg, cb)

  -- Shift hue by 180 degrees for complement, then adjust
  local contrastH = (h + 180) % 360

  -- Adjust based on original color's properties
  if l < 50 then
    -- For darker colors, brighten the contrast
    l = math.min(l + 20, 60)
  else
    -- For lighter colors, maintain vibrancy but ensure contrast
    l = math.max(l - 10, 40)
  end

  -- Maintain high saturation for vibrancy
  s = math.max(s, 70)

  -- Convert back to RGB and then to 32-bit ARGB
  cr, cg, cb = hslToRGB(contrastH, s, l)
  return componentsToARGB(a, cr, cg, cb)
end

-- Function to generate a full palette with 32-bit colors
local function generatePalette32(argb)
  local a, cr, cg, cb = argbToComponents(argb)
  local h, s, l = rgbToHSL(cr, cg, cb)

  -- Generate analogous colors
  local analog1_cr, analog1_cg, analog1_cb = hslToRGB((h + 30) % 360, s, l)
  local analog2_cr, analog2_cg, analog2_cb = hslToRGB((h - 30) % 360, s, l)

  return {
    base = argb,
    contrast = generateVibrantContrast32(argb),
    analogous1 = componentsToARGB(a, analog1_cr, analog1_cg, analog1_cb),
    analogous2 = componentsToARGB(a, analog2_cr, analog2_cg, analog2_cb)
  }
end

local reFillContrastColor
local reBorderContrastColor

local function rebuildColors()
  reFillColor = convertColorFromNative(r.GetThemeColor('areasel_fill', 0) + (0x5F << 24))
  reBorderColor = convertColorFromNative(r.GetThemeColor('areasel_outline', 0) + (0xFF << 24))
  reFillContrastColor = generateVibrantContrast32(reFillColor)
  reBorderContrastColor = generateVibrantContrast32(reBorderColor)
end

rebuildColors()

local function rectToLiceCoords(rect)
  -- macos
  return math.floor((rect.x1 - glob.liceData.screenRect.x1) + 0.5),
         math.floor((rect.y1 - glob.liceData.screenRect.y1) + 0.5), -- - MIDI_RULER_H,
         math.floor((rect.x2 - glob.liceData.screenRect.x1) + 0.5),
         math.floor((rect.y2 - glob.liceData.screenRect.y1) + 0.5)  -- - MIDI_RULER_H
end

local function getAlpha(color)
  return helper.is_windows and (((color & 0xFF000000) >> 24) / 0xFF) or 1
end

local colors = {}
for i = 1, 10 do
  colors[#colors + 1] = (math.random(0, 0xFFFFFF)) + 0xBF000000
end

composite = function(hwnd, dstX, dstY, dstW, dstH, bitmap, srcX, srcY, srcW, srcH)
  if childHWND then
    r.rcw_Composite(hwnd, dstX, dstY, dstW, dstH, bitmap, srcX, srcY, srcW, srcH)
  else
    r.JS_Composite(hwnd, dstX, dstY, dstW, dstH, bitmap, srcX, srcY, srcW, srcH, true)
  end
end

local function clearBitmap(bitmap, x1, y1, width, height)
  if childHWND then
    r.rcw_ClearBitmap(bitmap, x1, y1, width, height)
  else
    r.JS_LICE_FillRect(bitmap, x1, y1, width, height, 0, 1, 'MUL')
  end
end

local function fillRect(bitmap, x1, y1, width, height, color, alpha, mode)
  if childHWND then
    r.rcw_DrawRectWithAlpha(bitmap, x1, y1, width, height, color, alpha, true)
  else
    r.JS_LICE_FillRect(bitmap, x1, y1, width, height, color, alpha, mode)
  end
end

local function frameRect(bitmap, x1, y1, width, height, color, alpha, mode, antialias)
  local scale = pixelScale

  while scale > 0 do
    if childHWND then
      r.rcw_DrawRectWithAlpha(bitmap, x1, y1, width, height, color, alpha, false)
    else
      r.JS_LICE_RoundRect(bitmap, x1, y1, width, height, 0, color, alpha, mode, antialias)
    end
    x1 = x1 + 1
    y1 = y1 + 1
    width = width - 2
    height = height - 2
    scale = scale - 1
  end
end

local function putPixel(bitmap, xx1, yy1, which, color, alpha, mode)
  local scale = pixelScale

  while scale > 0 do
    if childHWND then
      r.rcw_SetPixelWithAlpha(bitmap, xx1, yy1, color, alpha);
    else
      r.JS_LICE_PutPixel(bitmap, xx1, yy1, color, alpha, mode)
    end

    xx1 = xx1 + ((which == 0) and 1 or (which == 2) and -1 or 0)
    yy1 = yy1 + ((which == 1) and 1 or (which == 3) and -1 or 0)

    scale = scale - 1
  end
end

local function simpleLine(bitmap, xx1, yy1, xx2, yy2, color, alpha, mode, antialias)
  if childHWND then
    r.rcw_DrawLineWithAlpha(bitmap, xx1, yy1, xx2, yy2, color, alpha, 1)
  else
    r.JS_LICE_Line(bitmap, xx1, yy1, xx2, yy2, color, alpha, mode, antialias)
  end
end

local function thickLine(bitmap, xx1, yy1, xx2, yy2, which, color, alpha, mode, antialias)
  local scale = pixelScale

  while scale > 0 do
    simpleLine(bitmap, xx1, yy1, xx2, yy2, color, alpha, mode, antialias)
    xx1 = xx1 + ((which == 0) and 1 or (which == 2) and -1 or (which == 5) and 0  or (which == 6) and -1 or 0)
    yy1 = yy1 + ((which == 1) and 1 or (which == 3) and -1 or (which == 5) and -1 or (which == 6) and 0  or 0)
    xx2 = xx2 + ((which == 0) and 1 or (which == 2) and -1 or (which == 5) and 0  or (which == 6) and -1 or 0)
    yy2 = yy2 + ((which == 1) and 1 or (which == 3) and -1 or (which == 5) and -1 or (which == 6) and 0  or 0)
    simpleLine(bitmap, xx1, yy1, xx2, yy2, color, alpha, mode, antialias)
    xx1 = xx1 + ((which == 0) and 1 or (which == 2) and -1 or (which == 5) and 0 or (which == 6) and 2 or 0)
    yy1 = yy1 + ((which == 1) and 1 or (which == 3) and -1 or (which == 5) and 2 or (which == 6) and 0 or 0)
    xx2 = xx2 + ((which == 0) and 1 or (which == 2) and -1 or (which == 5) and 0 or (which == 6) and 2 or 0)
    yy2 = yy2 + ((which == 1) and 1 or (which == 3) and -1 or (which == 5) and 2 or (which == 6) and 0 or 0)
    simpleLine(bitmap, xx1, yy1, xx2, yy2, color, alpha, mode, antialias)
    scale = scale - 1
  end
end

local function fillCircle(bitmap, x, y, radius, color, alpha, mode, antialias)
  if childHWND then
    r.rcw_FillCircleWithAlpha(bitmap, x, y, radius, color, alpha)
  else
    r.JS_LICE_FillCircle(bitmap, x, y, radius, color, alpha, mode, antialias)
  end
end

local function frameCircle(bitmap, x, y, radius, color, alpha, mode, antialias)
  if childHWND then
    r.rcw_DrawCircleWithAlpha(bitmap, x, y, radius, color, alpha)
  else
    r.JS_LICE_Circle(bitmap, x, y, radius, color, alpha, mode, antialias)
  end
end

local function fillTriangle(bitmap, x1, y1, x2, y2, x3, y3, color, alpha, mode)
  if childHWND then
    r.rcw_FillTriangleWithAlpha(bitmap, x1, y1, x2, y2, x3, y3, color, alpha)
  else
    r.JS_LICE_FillTriangle(bitmap, x1, y1, x2, y2, x3, y3, color, alpha, mode)
  end
end

local lastCheckTime
local lastThemeFile

local function checkThemeFile()
  local time = glob.currentTime
  if not lastCheckTime or time > lastCheckTime + 0.5 then
    lastCheckTime = time
    local themeFile = r.GetLastColorThemeFile()
    if themeFile ~= lastThemeFile then
      rebuildColors() -- better than nothing for now
      lastThemeFile = themeFile
      glob.needsRecomposite = true
    end
  end
end

local function drawLice()
  local hwnd = childHWND and childHWND or glob.liceData.midiview
  local integrated = not helper.is_windows or hwnd == childHWND

  checkThemeFile()
  local recomposite = glob.needsRecomposite or recompositeDraw
  recompositeInit = glob.needsRecomposite
  glob.needsRecomposite = false
  recompositeDraw = false

  local antialias = true
  local mode = 'COPY,ALPHA' --helper.is_windows and 0 or 'COPY,ALPHA'
  local alpha = getAlpha(reBorderColor)
  local meLanes = glob.meLanes
  if glob.liceData then
    for _, area in ipairs(glob.areas) do
      if area.logicalRect then
        local viewRect = (area.viewRect:clone()):conform()
        local x1V, y1V, x2V, y2V = rectToLiceCoords(viewRect)
        local w, h = math.floor(viewRect:width() + (Lice.EDGE_SLOP * 2) + 1 + 0.5), math.floor(viewRect:height() + (Lice.EDGE_SLOP * 2) + 1 + 0.5) -- need some y slop for the widget
        local skip = false
        local upsizing = false
        local downsizing = false

        if viewRect.y2 <= viewRect.y1
          or viewRect.x2 <= viewRect.x1
        then
          if destroyBitmap(area.bitmap) then
            area.bitmap = nil
          end
          area.modified = true
          skip = true
        end

        if not skip and area.bitmap and (area.modified or recomposite) then
          local bmWidth, bmHeight 
          if childHWND then
            bmWidth, bmHeight = r.rcw_GetBitmapWidth(area.bitmap), r.rcw_GetBitmapHeight(area.bitmap)
          else
            bmWidth, bmHeight = r.JS_LICE_GetWidth(area.bitmap), r.JS_LICE_GetHeight(area.bitmap)
          end
          if w > bmWidth or h > bmHeight then
            upsizing = true
          elseif w < bmWidth / 2 or h < bmHeight / 2 then
            downsizing = true
          end
          if recomposite then
            composite(hwnd, x1V - Lice.EDGE_SLOP, y1V + Lice.MIDI_RULER_H - Lice.EDGE_SLOP, w, h, area.bitmap, 0, 0, w, h);
          elseif upsizing or downsizing then
            --_P('will destroy', upsizing, downsizing)
            if destroyBitmap(area.bitmap) then
              area.bitmap = nil
            end
          else
            clearBitmap(area.bitmap, 0, 0, bmWidth, bmHeight)
            composite(hwnd, x1V - Lice.EDGE_SLOP, y1V + Lice.MIDI_RULER_H - Lice.EDGE_SLOP, w, h, area.bitmap, 0, 0, w, h)
          end
        end
        if not skip and not area.bitmap then
          area.bitmap = createBitmap(w, h, upsizing)
          composite(hwnd, x1V - Lice.EDGE_SLOP, y1V + Lice.MIDI_RULER_H - Lice.EDGE_SLOP, w, h, area.bitmap, 0, 0, w, h)
          numBitmaps = numBitmaps + 1
          area.modified = true
        end

        if not skip and area.modified or area.hovering or area.washovering then
          area.modified = false
          area.washovering = false -- ensure that it gets cleared

          local logicalRect = (area.logicalRect:clone()):conform()
          local x1L, y1L, x2L, y2L = rectToLiceCoords(logicalRect)
          local logWidth, logHeight = math.floor(logicalRect:width() + 0.5), math.floor(logicalRect:height() + 0.5)

          local x1, y1, x2, y2 = (x1L - x1V) + Lice.EDGE_SLOP, (y1L - y1V) + Lice.EDGE_SLOP, (x2L - x1V) + Lice.EDGE_SLOP, (y2L - y1V) + Lice.EDGE_SLOP - 1

          local function maskTopBottom()
            if helper.is_windows then
              clearBitmap(area.bitmap, x1, y1, logWidth + 1, math.abs(y1L - y1V)) -- top
              clearBitmap(area.bitmap, x1, y2 - math.abs(y2L - y2V) + 1, logWidth + 1, y2) -- bottom
              --r.JS_LICE_FillRect(area.bitmap, x1, y1, logWidth + 1, math.abs(y1L - y1V), 0, 1, 'MUL') -- top
              --r.JS_LICE_FillRect(area.bitmap, x1, y2 - math.abs(y2L - y2V) + 1, logWidth + 1, y2, 0, 1, 'MUL') -- bottom
            else
              r.JS_LICE_FillRect(area.bitmap, x1, y1, logWidth + 1, math.abs(y1L - y1V), 0x00FFFFFF, 1, 'COPY') -- top
              r.JS_LICE_FillRect(area.bitmap, x1, y2 - math.abs(y2L - y2V) + 1, logWidth + 1, y2, 0x00FFFFFF, 1, 'COPY') -- bottom
            end
          end

          -- LICE has neither line widths nor clipping rects. Meh.
          clearBitmap(area.bitmap, x1 - Lice.EDGE_SLOP, y1 - Lice.EDGE_SLOP, logWidth + (Lice.EDGE_SLOP * 2) + 1, logHeight + (Lice.EDGE_SLOP * 2) + 1)
          fillRect(area.bitmap, x1, y1,
                   logWidth, logHeight - 1, reFillColor, helper.is_windows and 0.3 or 1, mode)
          frameRect(area.bitmap, x1, y1, logWidth, logHeight - 1, reBorderColor, alpha, mode, antialias)
          -- if area.onClipboard then
          --   frameRect(area.bitmap, x1 + 3, y1 + 3, logWidth - 6, logHeight - 7, reBorderContrastColor, alpha, mode, antialias)
          -- end
          if area.hovering then
            local visTop = (y1 + math.abs(y1L - y1V))
            local visBottom = (y2 - math.abs(y2L - y2V) + 1)
            local visHeight = math.abs(visBottom - visTop)
            if glob.inWidgetMode and ((glob.widgetInfo and area == glob.widgetInfo.area)) then -- or (not widgetInfo and area.ccLane)) then -- tilt only in cc lanes
              maskTopBottom()
              -- if not area.widgetExtents then area.widgetExtents = Extent.new(0.5, 0.5) end
              local widgetMin, widgetMax = visTop + (visHeight * area.widgetExtents.min),
                                           visTop + (visHeight * area.widgetExtents.max)
              simpleLine(area.bitmap, x1, widgetMin, x2, widgetMax,
                         reBorderColor, alpha, mode, antialias)
              simpleLine(area.bitmap, x1, widgetMin - 1, x2, widgetMax - 1,
                         reBorderColor, alpha, mode, antialias)
              simpleLine(area.bitmap, x1, widgetMin + 1, x2, widgetMax + 1,
                         reBorderColor, alpha, mode, antialias)
              fillCircle(area.bitmap, x1, widgetMin, Lice.EDGE_SLOP, reBorderColor, alpha, mode, antialias)
              fillCircle(area.bitmap, x2, widgetMax, Lice.EDGE_SLOP, reBorderColor, alpha, mode, antialias)
              frameCircle(area.bitmap, x1 + math.floor((viewRect:width() / 2) + 0.5), math.floor((widgetMin + ((widgetMax - widgetMin) / 2)) + 0.5), Lice.EDGE_SLOP, reBorderColor, alpha, mode, antialias)
              area.washovering = true
            else
              if area.hovering.area then
                frameRect(area.bitmap, x1 + 2, y1 + 2,
                          logWidth - 4, logHeight - 5, reBorderColor, alpha, mode, antialias)
                frameRect(area.bitmap, x1 + 1, y1 + 1,
                          logWidth - 2, logHeight - 3, reBorderColor, alpha, mode, antialias)
                -- if ... is held, draw the widget for tilt-scaling
              elseif area.hovering.left then
                thickLine(area.bitmap, x1, y1, x1, y2, 0, reBorderColor, alpha, mode, antialias)
              elseif area.hovering.right then
                thickLine(area.bitmap, x2, y1, x2, y2, 2, reBorderColor, alpha, mode, antialias)
              elseif area.hovering.top then
                thickLine(area.bitmap, x1, y1, x2, y1, 1, reBorderColor, alpha, mode, antialias)
              elseif area.hovering.bottom then
                thickLine(area.bitmap, x1, y2, x2, y2, 3, reBorderColor, alpha, mode, antialias)
              end

              if glob.insertMode then
                local middleX = x2 - math.floor(Lice.EDGE_SLOP * 3.5 + 0.5)
                local middleY = math.floor(y1 + Lice.EDGE_SLOP * 3 + 0.5)
                local tqslop = math.floor(Lice.EDGE_SLOP * 0.75 + 0.5)
                if true then -- add to target mode -> this might be in combination with one of the above, so different corner?
                  frameCircle(area.bitmap, middleX, middleY, math.floor(Lice.EDGE_SLOP * 1.5), reBorderContrastColor, 1., mode, false) --antialias)
                  frameCircle(area.bitmap, middleX, middleY, math.floor(Lice.EDGE_SLOP * 1.5) + 1, reBorderContrastColor, 1., mode, false) --antialias)
                  thickLine(area.bitmap, middleX - tqslop, middleY, middleX + tqslop, middleY, 5, reBorderContrastColor, 1., mode, antialias)
                  thickLine(area.bitmap, middleX, middleY - tqslop, middleX, middleY + tqslop, 6, reBorderContrastColor, 1., mode, antialias)
                end
              end

              if glob.horizontalLock or glob.verticalLock then
                local middleX = x1 + Lice.EDGE_SLOP * 4
                local mx2 = math.floor(middleX - Lice.EDGE_SLOP / 1 + 0.5)
                local middleY = math.floor(y1 + Lice.EDGE_SLOP * 3.5 + 0.5)
                local my2 = math.floor(middleY - Lice.EDGE_SLOP / 1 + 0.5)
                if glob.horizontalLock then -- horizontal lock scroll mode
                  fillTriangle(area.bitmap, middleX - (Lice.EDGE_SLOP * 2), my2,
                                            middleX - Lice.EDGE_SLOP, my2 - Lice.EDGE_SLOP,
                                            middleX - Lice.EDGE_SLOP, my2 + Lice.EDGE_SLOP,
                                            reBorderContrastColor, 1., mode)
                  fillTriangle(area.bitmap, mx2 + (Lice.EDGE_SLOP * 2), my2,
                                            mx2 + Lice.EDGE_SLOP, my2 - Lice.EDGE_SLOP,
                                            mx2 + Lice.EDGE_SLOP, my2 + Lice.EDGE_SLOP,
                                            reBorderContrastColor, 1., mode)
                elseif glob.verticalLock then -- vertical lock scroll mode
                  -- r.JS_LICE_FillRect(area.bitmap, middleX - Lice.EDGE_SLOP * 3, middleY - (Lice.EDGE_SLOP * 3),
                  --                                     Lice.EDGE_SLOP * 6, (Lice.EDGE_SLOP * 6),
                  --                                     ((reBorderColor & 0x00FFFFFF) | 0x88000000), helper.is_windows and 0x88/255 or 1, mode)
                  fillTriangle(area.bitmap, mx2, middleY - (Lice.EDGE_SLOP * 2),
                               mx2 - Lice.EDGE_SLOP, middleY - Lice.EDGE_SLOP,
                               mx2 + Lice.EDGE_SLOP, middleY - Lice.EDGE_SLOP,
                               reBorderContrastColor, 1., mode)
                  fillTriangle(area.bitmap, mx2, my2 + (Lice.EDGE_SLOP * 2),
                               mx2 - Lice.EDGE_SLOP, my2 + Lice.EDGE_SLOP,
                               mx2 + Lice.EDGE_SLOP, my2 + Lice.EDGE_SLOP,
                               reBorderContrastColor, 1., mode)
                end
              end

              maskTopBottom()
              area.washovering = true
            end
          else
            maskTopBottom()
          end
        end
      end
    end
    if glob.DEBUG_LANES then
      clearBitmap(glob.liceData.bitmap, glob.liceData.windRect.x1, glob.liceData.windRect.y1,
                                   math.abs(glob.liceData.windRect.x2 - glob.liceData.windRect.x1), math.abs(glob.liceData.windRect.y2 - glob.liceData.windRect.y2))
      for i = #meLanes, -1, -1 do
        local x1, y1, x2, y2 = rectToLiceCoords(Rect.new(glob.windowRect.x1, meLanes[i].topPixel, glob.windowRect.x2 - Lice.MIDI_SCROLLBAR_R + 1, meLanes[i].bottomPixel))
        local width, height = math.abs(x2 - x1), math.abs(y2 - y1)
        r.JS_LICE_FillRect(glob.liceData.bitmap, x1, y1,
                           width, height, colors[i + 2], alpha, mode)
      end
      for _, dz in ipairs(glob.deadZones) do
        local x1, y1, x2, y2 = rectToLiceCoords(dz)
        local width, height = math.abs(x2 - x1), math.abs(y2 - y1)
        r.JS_LICE_FillRect(glob.liceData.bitmap, x1, y1,
                           width, height, 0xEFFFFFFF, alpha, mode)
      end
    else
      if recomposite then
        if MOAR_BITMAPS then
        local bitmaps = glob.liceData.bitmaps
        if bitmaps then
          local x1, y1, x2, y2 = rectToLiceCoords(Rect.new(glob.windowRect.x1, glob.windowRect.y1, glob.windowRect.x2 - Lice.MIDI_SCROLLBAR_R, glob.windowRect.y2 - 1))
          local width, height = math.abs(x2 - x1), math.abs(y2 - y1)
            if bitmaps.top then
              clearBitmap(bitmaps.top, 0, 0, 1, 1)
              putPixel(bitmaps.top, 0, 0, 1, reBorderColor, alpha, mode)
            end
            if bitmaps.bottom then
              clearBitmap(bitmaps.bottom, 0, 0, 1, 1)
              putPixel(bitmaps.bottom, 0, 0, 3, reBorderColor, alpha, mode)
            end
            if bitmaps.middletop then
              clearBitmap(bitmaps.middletop, 0, 0, 1, 1)
              putPixel(bitmaps.middletop, 0, 0, 1, reBorderColor, alpha, mode)
            end
            if bitmaps.middlebottom then
              clearBitmap(bitmaps.middlebottom, 0, 0, 1, 1)
              putPixel(bitmaps.middlebottom, 0, 0, 3, reBorderColor, alpha, mode)
            end
            if bitmaps.left then
              clearBitmap(bitmaps.left, 0, 0, 1, 1)
              putPixel(bitmaps.left, 0, 0, 0, reBorderColor, alpha, mode)
            end
            if bitmaps.right then
              clearBitmap(bitmaps.right, 0, 0, 1, 1)
              putPixel(bitmaps.right, 0, 0, 2, reBorderColor, alpha, mode)
            end
        end
        else
        local x1, y1, x2, y2 = rectToLiceCoords(Rect.new(glob.windowRect.x1, glob.windowRect.y1, glob.windowRect.x2 - Lice.MIDI_SCROLLBAR_R, meLanes[0] and (meLanes[-1].bottomPixel - 1) or (glob.windowRect.y2 - 1)))
        local width, height = math.abs(x2 - x1), math.abs(y2 - y1)
        clearBitmap(glob.liceData.bitmap, x1, y1 - Lice.MIDI_SEPARATOR, width, height + (2 * Lice.MIDI_SEPARATOR))
        frameRect(glob.liceData.bitmap, x1, y1, width, height, reBorderColor, alpha, mode, antialias)
        if meLanes[0] then
          y1 = meLanes[0].topPixel - glob.liceData.screenRect.y1
          height = math.abs(meLanes[#meLanes].bottomPixel - meLanes[0].topPixel)
          clearBitmap(glob.liceData.bitmap, x1, y1 - Lice.MIDI_SEPARATOR, width, height + (2 * Lice.MIDI_SEPARATOR))
          frameRect(glob.liceData.bitmap, x1, y1, width, height, reBorderColor, alpha, mode, antialias)
        end
        end
      end
    end
  end
end

Lice.recalcConstants = recalcConstants
Lice.initLice = initLice
Lice.shutdownLice = shutdownLice
Lice.createBitmap = createMidiViewBitmap
Lice.destroyBitmap = destroyBitmap
Lice.attendKeyIntercepts = attendKeyIntercepts
Lice.ignoreKeyIntercepts = ignoreKeyIntercepts
Lice.startIntercepts = startIntercepts
Lice.endIntercepts = endIntercepts

Lice.passthroughIntercepts = passthroughIntercepts
Lice.peekIntercepts = peekIntercepts

Lice.peekAppIntercepts = peekAppIntercepts

Lice.keyMappings = function() return keyMappings end
Lice.modMappings = function() return modMappings end
Lice.widgetMappings = function() return widgetMappings end
Lice.keyIsMapped = keyIsMapped

Lice.resetButtons = resetButtons
Lice.rebuildColors = rebuildColors
Lice.reloadSettings = reloadSettings

Lice.viewIntersectionRect = viewIntersectionRect

Lice.drawLice = drawLice

Lice.childHWND = function() return childHWND end
Lice.MOAR_BITMAPS = MOAR_BITMAPS

return Lice
