-- @description Mouse Map Factory
-- @version 0.0.1-beta.2
-- @author sockmonkey72
-- @about
--   # Mouse Map Factory
--   Load/Save Mouse Maps, Create Toggle and One-shot Actions to change them up
-- @changelog
--   - initial
-- @provides
--   {MouseMaps}/*
--   [main] sockmonkey72_MouseMapFactory.lua

local r = reaper
package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'MouseMaps/?.lua'
local mm = require 'MouseMaps'
local scriptName = 'Mouse Map Factory'

local function fileExists(name)
  local f = io.open(name,'r')
  if f ~= nil then io.close(f) return true else return false end
end

local canStart = true

local imGuiPath = r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua'
if not fileExists(imGuiPath) then
  mm.post(scriptName..' requires \'ReaImGui\' 0.8+ (install from ReaPack)\n')
  canStart = false
end

if not canStart then return end

dofile(r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8')

local scriptID = 'sockmonkey72_MouseMapFactory'

local ctx = r.ImGui_CreateContext(scriptID) --, r.ImGui_ConfigFlags_DockingEnable()) -- TODO docking
--r.ImGui_SetConfigVar(ctx, r.ImGui_ConfigVar_DockingWithShift(), 1) -- TODO docking

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local FONTSIZE_LARGE = 13
local FONTSIZE_SMALL = 11
local DEFAULT_WIDTH = 36 * FONTSIZE_LARGE
local DEFAULT_HEIGHT = 19.5 * FONTSIZE_LARGE
local DEFAULT_ITEM_WIDTH = 60

local windowInfo
local fontInfo

local canvasScale = 1.0
local DEFAULT_TITLEBAR_TEXT = 'Mouse Map Factory'
local titleBarText = DEFAULT_TITLEBAR_TEXT

local wantsUngrouped = false
local statusMsg = ''
local statusTime = nil
local statusContext = 0

local contexts = mm.UniqueContexts()
local showFilter = false
local filtered = {}

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

local function handleExtState()
  if not r.HasExtState(scriptID, 'backupSet') then
    r.SetExtState(scriptID, 'backupSet', mm.GetCurrentState_Serialized(true), true)
  end
  local filterStr = r.GetExtState(scriptID, 'filteredCats')
  if filterStr and filterStr ~= '' then
    filtered = mm.Deserialize(filterStr)
  end
end

local function prepRandomShit()
  handleExtState()
end

local function processBaseFontUpdate(baseFontSize)

  if not baseFontSize then return FONTSIZE_LARGE end

  baseFontSize = math.floor(baseFontSize)
  if baseFontSize < 10 then baseFontSize = 10
  elseif baseFontSize > 48 then baseFontSize = 48
  end

  if baseFontSize == FONTSIZE_LARGE then return FONTSIZE_LARGE end

  FONTSIZE_LARGE = baseFontSize
  FONTSIZE_SMALL = math.floor(baseFontSize * (11/13))
  fontInfo.largeDefaultSize = FONTSIZE_LARGE
  fontInfo.smallDefaultSize = FONTSIZE_SMALL

  windowInfo.defaultWidth = 36 * fontInfo.largeDefaultSize
  windowInfo.defaultHeight = 19.5 * fontInfo.largeDefaultSize
  DEFAULT_ITEM_WIDTH = 4.6 * FONTSIZE_LARGE
  windowInfo.width = windowInfo.defaultWidth -- * canvasScale
  windowInfo.height = windowInfo.defaultHeight -- * canvasScale
  windowInfo.wantsResize = true
  return FONTSIZE_LARGE
end

local function prepWindowAndFont()
  windowInfo = {
    defaultWidth = DEFAULT_WIDTH,
    defaultHeight = DEFAULT_HEIGHT,
    width = DEFAULT_WIDTH,
    height = DEFAULT_HEIGHT,
    left = 100,
    top = 100,
    wantsResize = false,
    wantsResizeUpdate = false
  }

  fontInfo = {
    large = r.ImGui_CreateFont('sans-serif', FONTSIZE_LARGE), largeSize = FONTSIZE_LARGE, largeDefaultSize = FONTSIZE_LARGE,
    small = r.ImGui_CreateFont('sans-serif', FONTSIZE_SMALL), smallSize = FONTSIZE_SMALL, smallDefaultSize = FONTSIZE_SMALL
  }
  r.ImGui_Attach(ctx, fontInfo.large)
  r.ImGui_Attach(ctx, fontInfo.small)

  processBaseFontUpdate(tonumber(r.GetExtState(scriptID, 'baseFont')))
end

local function handleStatus(context)
  if statusMsg ~= '' and statusTime and statusContext == context then
    if r.time_precise() - statusTime > 3 then statusTime = nil statusMsg = '' statusContext = 0
    else
      r.ImGui_SameLine(ctx)
      r.ImGui_AlignTextToFramePadding(ctx)
      r.ImGui_Text(ctx, statusMsg)
    end
  end
end

-----------------------------------------------------------------------------
---------------------------------- MAINFN -----------------------------------

local popupLabel = 'Load a Preset...'

local function Spacing()
  local posy = r.ImGui_GetCursorPosY(ctx)
  r.ImGui_SetCursorPosY(ctx, posy + ((r.ImGui_GetFrameHeight(ctx) / 4) * canvasScale))
end

local function MakeGearPopup()
  local x = r.ImGui_GetWindowSize(ctx)
  local textWidth = r.ImGui_CalcTextSize(ctx, 'Gear')
  r.ImGui_SetCursorPosX(ctx, x - textWidth - (15 * canvasScale))
  r.ImGui_Button(ctx, 'Gear')

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'gear menu')
  end

  if r.ImGui_BeginPopup(ctx, 'gear menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      if r.ImGui_IsPopupOpen(ctx, 'gear menu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end
    local rv, selected, v

    rv, selected = r.ImGui_Selectable(ctx, 'Open Mouse Modifiers Preference')
    if rv and selected then
      r.ViewPrefs(466, '')
      r.ImGui_CloseCurrentPopup(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Spacing(ctx)

    rv, selected = r.ImGui_Selectable(ctx, 'Update Backup Set')
    if rv and selected then
      local backupStr = mm.GetCurrentState_Serialized(true) -- always get a full set
      r.SetExtState(scriptID, 'backupSet', backupStr, true)
      r.ImGui_CloseCurrentPopup(ctx)
    end
    rv, selected = r.ImGui_Selectable(ctx, 'Restore Backup Set')
    if rv and selected then
      local backupStr = r.GetExtState(scriptID, 'backupSet')
      mm.RestoreState_Serialized(backupStr)
      r.ImGui_CloseCurrentPopup(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Spacing(ctx)

    -- r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_SetNextItemWidth(ctx, (DEFAULT_ITEM_WIDTH / 2) * canvasScale)
    rv, v = r.ImGui_InputText(ctx, 'Base Font Size', FONTSIZE_LARGE, r.ImGui_InputTextFlags_EnterReturnsTrue()
                                                                   + r.ImGui_InputTextFlags_CharsDecimal())
    if rv then
      v = processBaseFontUpdate(tonumber(v))
      r.SetExtState(scriptID, 'baseFont', tostring(v), true)
      r.ImGui_CloseCurrentPopup(ctx)
    end

    if showFilter then
      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)

      if r.ImGui_BeginMenu(ctx, 'Filter') then
        r.ImGui_PushFont(ctx, fontInfo.small)
        for cxkey, context in mm.spairs(contexts, function (t, a, b) return t[a].label < t[b].label end) do
          if context.label and context.label ~= '' then
            local f_retval, f_v = r.ImGui_Checkbox(ctx, context.label, filtered[cxkey] and true or false)
            if f_retval then
              filtered[cxkey] = f_v and true or nil
              for _, subval in ipairs(context) do
                filtered[subval.key] = f_v and true or nil
              end
              r.SetExtState(scriptID, 'filteredCats', mm.Serialize(filtered, nil, true), true)
            end
          end
        end
        r.ImGui_PopFont(ctx)
        r.ImGui_EndMenu(ctx)
      end
    end
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopStyleColor(ctx)
end

local function MakeLoadPopup()
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, 'LOAD:')
  r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
  r.ImGui_Button(ctx, popupLabel)
  handleStatus(1)

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'preset menu')
  end

  if r.ImGui_BeginPopup(ctx, 'preset menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      if r.ImGui_IsPopupOpen(ctx, 'preset menu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end
    -- r.ImGui_PushFont(ctx, fontInfo.small)
    local idx = 0
    local fnames = {}
    r.EnumerateFiles(r.GetResourcePath()..'/MouseMaps/', -1)
    local fname = r.EnumerateFiles(r.GetResourcePath()..'/MouseMaps/', idx)
    while fname do
      if fname:match('%.ReaperMouseMap$') then
        fname = fname:gsub('%.ReaperMouseMap$', '')
        table.insert(fnames, fname)
      end
      idx = idx + 1
      fname = r.EnumerateFiles(r.GetResourcePath()..'/MouseMaps/', idx)
    end
    local cherry = true
    for _, fn in mm.spairs(fnames, function (t, a, b) return t[a] < t[b] end ) do
      if not cherry then Spacing() end
      local rv, selected = r.ImGui_Selectable(ctx, fn)
      if rv and selected then
        local restored = mm.RestoreStateFromFile(r.GetResourcePath()..'/MouseMaps/'..fn..'.ReaperMouseMap')
        statusMsg = (restored and 'Loaded' or 'Failed to load')..' '..fn..'.ReaperMouseMap'
        statusTime = r.time_precise()
        statusContext = 1
        r.ImGui_CloseCurrentPopup(ctx)
        popupLabel = fn
      end
      cherry = false
    end
    -- r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopStyleColor(ctx)
end

local function MakeSavePopup()
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, 'SAVE: ')
  r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
  r.ImGui_Button(ctx, 'Write a Preset...')
  handleStatus(2)

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'writepreset menu')
  end

  if r.ImGui_BeginPopup(ctx, 'writepreset menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      if r.ImGui_IsPopupOpen(ctx, 'writepreset menu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end
    -- r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Text(ctx, 'Preset Name')
    Spacing()
    if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
    local retval, buf = r.ImGui_InputTextWithHint(ctx, '##presetname', 'Untitled', '', r.ImGui_InputTextFlags_EnterReturnsTrue())
    if retval and buf then
      if not buf:match('%.ReaperMouseMap$') then buf = buf..'.ReaperMouseMap' end
      local saved = mm.SaveCurrentStateToFile(r.GetResourcePath()..'/MouseMaps/'..buf)
      statusMsg = (saved and 'Saved' or 'Failed to save')..' '..buf
      statusTime = r.time_precise()
      statusContext = 2
      buf = buf:gsub('%.ReaperMouseMap$', '')
      popupLabel = buf
      r.ImGui_CloseCurrentPopup(ctx)
    end
    -- r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopStyleColor(ctx)
end

function MakeToggleActionPopup()
  r.ImGui_Button(ctx, 'Build a Toggle Action...')
  handleStatus(3)

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'writetoggle menu')
  end

  if r.ImGui_BeginPopup(ctx, 'writetoggle menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      if r.ImGui_IsPopupOpen(ctx, 'writetoggle menu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end
    -- r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Text(ctx, 'Toggle Action Name')
    Spacing()
    if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
    local retval, buf = r.ImGui_InputTextWithHint(ctx, '##toggleaction', 'Untitled Toggle Action', '', r.ImGui_InputTextFlags_EnterReturnsTrue())
    if retval and buf then
      local path = r.GetResourcePath()..'/Scripts/MouseMapActions/'
      if not r.file_exists(path) then r.RecursiveCreateDirectory(path, 0) end
      if r.file_exists(path) then
        local actionName = buf..'_MouseMap.lua'
        local rv = mm.SaveToggleActionToFile(path..actionName, wantsUngrouped)
        wantsUngrouped = false
        r.ImGui_CloseCurrentPopup(ctx)
        if rv then
          r.AddRemoveReaScript(true, 0, path..actionName, true)
          statusMsg = 'Wrote and registered '..actionName
        else
          statusMsg = 'Error writing '..actionName
        end
      else
        statusMsg = 'Could not find or create directory'
      end
      statusTime = r.time_precise()
      statusContext = 3
    end

    r.ImGui_SameLine(ctx)
    local retval2, v = r.ImGui_Checkbox(ctx, 'Ungrouped', wantsUngrouped)
    if retval2 then
      wantsUngrouped = v
    end
    -- r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopStyleColor(ctx)
end

local function MakeOneShotActionPopup()
  r.ImGui_Button(ctx, 'Build a One-shot Action...')
  handleStatus(4)

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'writeoneshot menu')
  end

  if r.ImGui_BeginPopup(ctx, 'writeoneshot menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      if r.ImGui_IsPopupOpen(ctx, 'writeoneshot menu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end
    -- r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Text(ctx, 'One-Shot Action Name')
    Spacing()
    if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
    local retval, buf = r.ImGui_InputTextWithHint(ctx, '##oneshotaction', 'Untitled One-Shot Action', '', r.ImGui_InputTextFlags_EnterReturnsTrue())
    if retval and buf then
      local path = r.GetResourcePath()..'/Scripts/MouseMapActions/'
      if not r.file_exists(path) then r.RecursiveCreateDirectory(path, 0) end
      if r.file_exists(path) then
        local actionName = buf..'_MouseMap.lua'
        local rv = mm.SaveOneShotActionToFile(path..actionName)
        r.ImGui_CloseCurrentPopup(ctx)
        if rv then
          r.AddRemoveReaScript(true, 0, path..actionName, true)
          statusMsg = 'Wrote and registered '..actionName
        else
          statusMsg = 'Error writing '..actionName
        end
      else
        statusMsg = 'Could not find or create directory'
      end
      statusTime = r.time_precise()
      statusContext = 4
    end
    -- r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopStyleColor(ctx)
end

local function mainFn()
  ---------------------------------------------------------------------------
  -------------------------------- POPUP MENU -------------------------------

  r.ImGui_PushFont(ctx, fontInfo.large)

  Spacing()
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, 'PRESETS')

  r.ImGui_SameLine(ctx)
  MakeGearPopup()

  r.ImGui_Separator(ctx)

  Spacing()
  MakeLoadPopup()

  Spacing()
  MakeSavePopup()
  Spacing()

  Spacing()
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, 'FACTORIES')

  r.ImGui_Separator(ctx)

  Spacing()
  MakeToggleActionPopup()

  Spacing()
  MakeOneShotActionPopup()

  r.ImGui_PopFont(ctx)
end

-----------------------------------------------------------------------------
--------------------------------- CLEANUP -----------------------------------

local function doClose()
  r.ImGui_Detach(ctx, fontInfo.large)
  r.ImGui_Detach(ctx, fontInfo.small)
  r.ImGui_DestroyContext(ctx)
  ctx = nil
end

local function onCrash(err)
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
end

-----------------------------------------------------------------------------
----------------------------- WSIZE/FONTS JUNK ------------------------------

local function updateWindowPosition()
  local curWindowWidth, curWindowHeight = r.ImGui_GetWindowSize(ctx)
  local curWindowLeft, curWindowTop = r.ImGui_GetWindowPos(ctx)

  if not windowInfo.wantsResize
    and (windowInfo.wantsResizeUpdate
      or curWindowWidth ~= windowInfo.width
      or curWindowHeight ~= windowInfo.height
      or curWindowLeft ~= windowInfo.left
      or curWindowTop ~= windowInfo.top)
  then
    r.SetExtState(scriptID, 'windowRect', math.floor(curWindowLeft)..','..math.floor(curWindowTop)..','..math.floor(curWindowWidth)..','..math.floor(curWindowHeight), true)
    windowInfo.left, windowInfo.top, windowInfo.width, windowInfo.height = curWindowLeft, curWindowTop, curWindowWidth, curWindowHeight
    windowInfo.wantsResizeUpdate = false
  end
end

local function initializeWindowPosition()
  local wLeft = 100
  local wTop = 100
  local wWidth = windowInfo.defaultWidth
  local wHeight = windowInfo.defaultHeight
  if r.HasExtState(scriptID, 'windowRect') then
    local rectStr = r.GetExtState(scriptID, 'windowRect')
    local rectTab = {}
    for word in string.gmatch(rectStr, '([^,]+)') do
      table.insert(rectTab, word)
    end
    if rectTab[1] then wLeft = rectTab[1] end
    if rectTab[2] then wTop = rectTab[2] end
    if rectTab[3] then wWidth = rectTab[3] end
    if rectTab[4] then wHeight = rectTab[4] end
  end
  return wLeft, wTop, wWidth, wHeight
end

local function updateOneFont(name)
  if not fontInfo[name] then return end

  local newFontSize = math.floor(fontInfo[name..'DefaultSize'] * canvasScale)
  local fontSize = fontInfo[name..'Size']

  if newFontSize ~= fontSize then
    r.ImGui_Detach(ctx, fontInfo[name])
    fontInfo[name] = r.ImGui_CreateFont('sans-serif', newFontSize)
    r.ImGui_Attach(ctx, fontInfo[name])
    fontInfo[name..'Size'] = newFontSize
  end
end

local function updateFonts()
  updateOneFont('large')
  updateOneFont('small')
end

local function openWindow()
  local windowSizeFlag = r.ImGui_Cond_Appearing()
  if windowInfo.wantsResize then
    windowSizeFlag = nil
  end
  r.ImGui_SetNextWindowSize(ctx, windowInfo.width, windowInfo.height, windowSizeFlag)
  r.ImGui_SetNextWindowPos(ctx, windowInfo.left, windowInfo.top, windowSizeFlag)
  if windowInfo.wantsResize then
    windowInfo.wantsResize = false
    windowInfo.wantsResizeUpdate = true
  end

  r.ImGui_SetNextWindowBgAlpha(ctx, 1.0)
  -- r.ImGui_SetNextWindowDockID(ctx, -1)--, r.ImGui_Cond_FirstUseEver()) -- TODO docking
  r.ImGui_SetNextWindowSizeConstraints(ctx, windowInfo.defaultWidth * canvasScale, windowInfo.defaultHeight, windowInfo.defaultWidth * canvasScale, windowInfo.defaultHeight * 2)

  r.ImGui_PushFont(ctx, fontInfo.small)
  local visible, open = r.ImGui_Begin(ctx, titleBarText, true,
                                        r.ImGui_WindowFlags_TopMost()
                                      + r.ImGui_WindowFlags_NoScrollWithMouse()
                                      + r.ImGui_WindowFlags_NoScrollbar()
                                      + r.ImGui_WindowFlags_NoSavedSettings())
  r.ImGui_PopFont(ctx)

  return visible, open
end

-----------------------------------------------------------------------------
-------------------------------- SHORTCUTS ----------------------------------

local function checkShortcuts()
  -- if r.ImGui_IsAnyItemActive(ctx) then return end

  -- local keyMods = r.ImGui_GetKeyMods(ctx)
  -- local modKey = keyMods == r.ImGui_Mod_Shortcut()
  -- local modShiftKey = keyMods == r.ImGui_Mod_Shortcut() + r.ImGui_Mod_Shift()
  -- local noMod = keyMods == 0

  -- if modKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then -- undo
  --   r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40013)
  -- elseif modShiftKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then -- redo
  --   r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40014)
  -- elseif noMod and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Space()) then -- play/pause
  --   r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40016)
  -- end
end

-----------------------------------------------------------------------------
-------------------------------- MAIN LOOP ----------------------------------

local isClosing = false

local function loop()
  if isClosing then
    doClose()
    return
  end

  canvasScale = windowInfo.height / windowInfo.defaultHeight
  if canvasScale > 2 then canvasScale = 2 end

  updateFonts()

  local visible, open = openWindow()
  if visible then
    checkShortcuts()

    r.ImGui_PushFont(ctx, fontInfo.large)
    mainFn()
    r.ImGui_PopFont(ctx)

    -- ww, wh = r.ImGui_Viewport_GetSize(r.ImGui_GetWindowViewport(ctx)) -- TODO docking
    updateWindowPosition()

    r.ImGui_End(ctx)
  end

  if not open then
    isClosing = true -- will close out on the next frame
  end

  r.defer(function() xpcall(loop, onCrash) end)
end

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

prepRandomShit()
prepWindowAndFont()
windowInfo.left, windowInfo.top, windowInfo.width, windowInfo.height = initializeWindowPosition()
r.defer(function() xpcall(loop, onCrash) end)
