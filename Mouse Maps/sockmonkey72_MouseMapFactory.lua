-- @description MoM Toggle: Mouse Mod Toggle Action Generator
-- @version 2.0.0-beta.1
-- @author sockmonkey72
-- @about
--   # MoM Toggle: Mouse Mod Toggle Action Generator
--   Load/Save Mouse Maps, Generate Toggle and One-shot Actions to change them up
-- @changelog
--   - support for Main, MIDI and Main+MIDI (legacy) contexts
--   - lots of other work, support for v7 MM contexts and more
-- @provides
--   {MouseMaps}/*
--   [main] sockmonkey72_MouseMapFactory.lua
--   [main] sockmonkey72_MoM_Toggle_Mouse_Mod_Toggle_Generator.lua

local r = reaper
package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'MouseMaps/?.lua'
local mm = require 'MouseMaps'
local scriptName = 'MoM Toggle'
local versionStr = '2.0.0-beta.1' -- don't forget to change this above

local canStart = true

local imGuiPath = r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua'
if not mm.FileExists(imGuiPath) then
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

local YAGNI = false

local IMAGEBUTTON_SIZE = 13
local GearImage = r.ImGui_CreateImage(debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'MouseMaps/' .. 'gear_40031.png')
-- if GearImage then r.ImGui_Attach(ctx, GearImage) end

local FONTSIZE_LARGE = 13
local FONTSIZE_SMALL = 11
local DEFAULT_WIDTH = 36 * FONTSIZE_LARGE
local DEFAULT_HEIGHT = (10 * FONTSIZE_LARGE) + (100)
local DEFAULT_ITEM_WIDTH = 60
local DEFAULT_MENUBUTTON_WIDTH = 100

local windowInfo
local fontInfo

local canvasScale = 1.0
local DEFAULT_TITLEBAR_TEXT = scriptName .. ': Mouse Mod Toggle Action Generator'
local titleBarText = DEFAULT_TITLEBAR_TEXT

local wantsUngrouped = false
local statusMsg = ''
local statusTime = nil
local statusContext = 0

local contexts = mm.UniqueContexts()
local useFilter = false
local filtered = {}

local runTogglesAtStartup = true
local activeFname
local actionNames = {}
local inOKDialog = false
local selectedPresetPath
local rebuildActionsMenu = false
local defaultPresetName = ''
local presetPopupName

local viewPort

local SectionMain = true
local SectionMIDI = false
local SectionLegacy = false
local PresetLoadSelected

local TYPE_SIMPLE = 0
local TYPE_TOGGLE = 1
local TYPE_PRESET = 2

local canReveal = true
if not r.APIExists('CF_LocateInExplorer') then
  canReveal = false
end

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

local function getFilterNames()
  local filterNames = {}
  for k, v in mm.spairs(filtered, function (t, a, b) return a < b end) do
    table.insert(filterNames, k)
  end
  return filterNames
end

local function handleExtState()
  if not r.HasExtState(scriptID, 'backupSet') then
    r.SetExtState(scriptID, 'backupSet', mm.GetCurrentState_Serialized(true), true)
  end
  local filterStr = r.GetExtState(scriptID, 'filteredCats')

  if filterStr and filterStr ~= '' then
    local filterNames = mm.Deserialize(filterStr)
    if filterNames then
      for _, v in ipairs(filterNames) do
        filtered[v] = true
      end
    end
  end

  local useFilterStr = r.GetExtState(scriptID, 'useFilter')
  if useFilterStr and useFilter ~= '' then
    useFilter = tonumber(useFilterStr) == 1 and true or false
  end

  local runToggles = r.GetExtState(scriptID, 'runTogglesAtStartup')
  if runToggles and runToggles ~= '' then
    runTogglesAtStartup = tonumber(runToggles) == 1 and true or false
  end

  defaultPresetName = r.GetExtState(scriptID, 'defaultPresetName')
end

local function prepRandomShit()
  handleExtState()
end

local function processBaseFontUpdate(baseFontSize)

  if not baseFontSize then return FONTSIZE_LARGE end

  baseFontSize = math.floor(baseFontSize + 0.5)
  if baseFontSize < 10 then baseFontSize = 10
  elseif baseFontSize > 48 then baseFontSize = 48
  end

  if baseFontSize == FONTSIZE_LARGE then return FONTSIZE_LARGE end

  FONTSIZE_LARGE = baseFontSize
  FONTSIZE_SMALL = math.floor(baseFontSize * (11/13) + 0.5)
  fontInfo.largeDefaultSize = FONTSIZE_LARGE
  fontInfo.smallDefaultSize = FONTSIZE_SMALL
  windowInfo.defaultWidth = 36 * FONTSIZE_LARGE
  local scale = ((fontInfo.largeDefaultSize / 15) - 1)
  if scale < 1 then scale = 1 end
  windowInfo.defaultHeight = (10 * FONTSIZE_LARGE) + (100 * scale)
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
local lastInputTextBuffer

local function PositionModalWindow(wScale, yOff)
  local winWid = 4 * DEFAULT_ITEM_WIDTH * canvasScale
  local winHgt = winWid * (windowInfo.height / windowInfo.width) * wScale
  r.ImGui_SetNextWindowSize(ctx, winWid, winHgt)
  local winPosX, winPosY = r.ImGui_Viewport_GetPos(viewPort)
  local winSizeX, winSizeY = r.ImGui_Viewport_GetSize(viewPort)
  local okPosX = winPosX + (winSizeX / 2.) - (winWid / 2.)
  local okPosY = winPosY + (winSizeY / 2.) - (winHgt / 2.) + (yOff and yOff or 0)
  if okPosY + winHgt > windowInfo.top + windowInfo.height then
    okPosY = okPosY - ((windowInfo.top + windowInfo.height) - (okPosY + winHgt))
  end
  r.ImGui_SetNextWindowPos(ctx, okPosX, okPosY)
  --r.ImGui_SetNextWindowPos(ctx, r.ImGui_GetMousePos(ctx))
end

local function Spacing()
  local posy = r.ImGui_GetCursorPosY(ctx)
  r.ImGui_SetCursorPosY(ctx, posy + ((r.ImGui_GetFrameHeight(ctx) / 4) * canvasScale))
end

local function HandleOKDialog(title, text)
  local rv = false
  local retval = 0
  local doOK = false

  r.ImGui_PushFont(ctx, fontInfo.large)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if inOKDialog then
    PositionModalWindow(0.7, r.ImGui_GetFrameHeight(ctx) / 2)
    r.ImGui_OpenPopup(ctx, title)
  elseif (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
    or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())) then
      doOK = true
  end

  if r.ImGui_BeginPopupModal(ctx, title, true) then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      r.ImGui_CloseCurrentPopup(ctx)
    end
    Spacing()
    r.ImGui_Text(ctx, text)
    Spacing()
    if r.ImGui_Button(ctx, 'Cancel') then
      rv = true
      retval = 0
      r.ImGui_CloseCurrentPopup(ctx)
    end

    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'OK') or doOK then
      rv = true
      retval = 1
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_SetItemDefaultFocus(ctx)

    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopFont(ctx)
  r.ImGui_PopStyleColor(ctx)

  inOKDialog = false

  return rv, retval
end

local function EnumerateMouseMapFiles()
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
  return fnames
end

local function BuildTooltip(height, text)
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_SetNextWindowContentSize(ctx, FONTSIZE_SMALL * 24, FONTSIZE_SMALL * height)
    r.ImGui_SetTooltip(ctx, text)
    r.ImGui_PopFont(ctx)
  end
end

local function MakeLoadPopup()
  r.ImGui_PushFont(ctx, fontInfo.small)
  r.ImGui_SetCursorPosX(ctx, 15 * canvasScale)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, 'LOAD:')
  r.ImGui_PopFont(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_SetCursorPosX(ctx, (DEFAULT_ITEM_WIDTH - 5) * canvasScale)

  if defaultPresetName ~= '' then
    r.ImGui_SameLine(ctx)
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_AlignTextToFramePadding(ctx)
    local x = r.ImGui_GetWindowSize(ctx)
    local textWidth = r.ImGui_CalcTextSize(ctx, 'Restore Default')
    r.ImGui_SetCursorPosX(ctx, x - textWidth - (15 * canvasScale))
    if r.ImGui_Button(ctx, 'Restore Default') then
      local restored = mm.RestoreStateFromFile(r.GetResourcePath()..'/MouseMaps/'..defaultPresetName..'.ReaperMouseMap', useFilter and getFilterNames() or nil)
      statusMsg = (restored and 'Loaded' or 'Failed to load')..' '..defaultPresetName..'.ReaperMouseMap'
      statusTime = r.time_precise()
      statusContext = 1
      popupLabel = defaultPresetName
    end
    r.ImGui_PopFont(ctx)
  end

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  local textWidth = r.ImGui_CalcTextSize(ctx, 'Load a Preset...')
  if r.ImGui_Button(ctx, popupLabel, textWidth + 15 * canvasScale) then
    r.ImGui_OpenPopup(ctx, 'preset menu')
  end

  BuildTooltip(5, 'Load a Mouse Modifier preset\nfile (as exported in the Mouse\nModifiers Preferences dialog).')

  handleStatus(1)

  if r.ImGui_BeginPopup(ctx, 'preset menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      r.ImGui_CloseCurrentPopup(ctx)
    end

    local fnames = EnumerateMouseMapFiles()
    if #fnames > 0 then
      local cherry = true
      for _, fn in mm.spairs(fnames, function (t, a, b) return t[a] < t[b] end ) do
        if not cherry then Spacing() end
        if r.ImGui_Selectable(ctx, fn) then
          local restored = mm.RestoreStateFromFile(r.GetResourcePath()..'/MouseMaps/'..fn..'.ReaperMouseMap', useFilter and getFilterNames() or nil)
          statusMsg = (restored and 'Loaded' or 'Failed to load')..' '..fn..'.ReaperMouseMap'
          statusTime = r.time_precise()
          statusContext = 1
          r.ImGui_CloseCurrentPopup(ctx)
          popupLabel = fn
        end
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsItemClicked(ctx, r.ImGui_MouseButton_Right()) then
          selectedPresetPath = r.GetResourcePath()..'/MouseMaps/'..fn..'.ReaperMouseMap'
          presetPopupName = fn
          r.ImGui_OpenPopup(ctx, 'preset ctx menu')
        end
        cherry = false
      end
      if r.ImGui_BeginPopup(ctx, 'preset ctx menu') then
        local retval, v = r.ImGui_Checkbox(ctx, 'Set Default Preset', presetPopupName == defaultPresetName)
        if retval then
          defaultPresetName = v and presetPopupName or ''
          r.SetExtState(scriptID, 'defaultPresetName', defaultPresetName, true)
        end
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)

        if canReveal then
          r.ImGui_Spacing(ctx)
          if r.ImGui_Selectable(ctx, 'Reveal in Finder/Explorer') then
            r.CF_LocateInExplorer(selectedPresetPath)
            r.ImGui_CloseCurrentPopup(ctx)
          end
        end

        r.ImGui_Spacing(ctx)
        if r.ImGui_Selectable(ctx, 'Delete Preset') then
          inOKDialog = true
        end
        r.ImGui_EndPopup(ctx)
      end
      if selectedPresetPath then
        local spName = selectedPresetPath:match('.*/(.*)%.ReaperMouseMap$')
        local okrv, okval = HandleOKDialog('Delete Preset?', 'Delete '..spName..' permanently?')
        if okrv then
          if okval == 1 then
            os.remove(selectedPresetPath)
            selectedPresetPath = nil
            --r.ImGui_CloseCurrentPopup(ctx)
          end
        end
      end
    else
      r.ImGui_BeginDisabled(ctx)
      r.ImGui_Selectable(ctx, 'No presets')
      r.ImGui_EndDisabled(ctx)
    end
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopStyleColor(ctx)
end

local function PresetPathAndFilenameFromLastInput()
  local path
  local buf = lastInputTextBuffer
  if not buf:match('%.ReaperMouseMap$') then buf = buf..'.ReaperMouseMap' end
  path = r.GetResourcePath()..'/MouseMaps/'..buf
  return path, buf
end

local function ActionPathAndFilenameFromLastInput()
  local buf = lastInputTextBuffer
  local path = r.GetResourcePath()..'/Scripts/MouseMapActions/'
  if not mm.DirExists(path) then r.RecursiveCreateDirectory(path, 0) end
  if mm.DirExists(path) then
    if not buf:match('_MouseMap%.lua$') then buf = buf..'_MouseMap.lua' end
    path = path..buf
    return path, buf
  end
  return nil
end

local function ManageSaveAndOverwrite(pathFn, saveFn, statusCtx, suppressOverwrite)
  if inOKDialog then
    if not lastInputTextBuffer or lastInputTextBuffer == '' then
      statusMsg = 'Name must contain at least 1 character'
      statusTime = r.time_precise()
      statusContext = statusCtx
      return
    end
    local path, fname = pathFn()
    if not path then
      statusMsg = 'Could not find or create directory'
      statusTime = r.time_precise()
      statusContext = statusCtx
    elseif suppressOverwrite or not mm.FileExists(path) then
      saveFn(path, fname)
      inOKDialog = false
      r.ImGui_CloseCurrentPopup(ctx)
    end
  end

  if lastInputTextBuffer and lastInputTextBuffer ~= '' then
    local okrv, okval = HandleOKDialog('Overwrite File?', 'Overwrite file '..lastInputTextBuffer..'?')
    if okrv then
      if okval == 1 then
        local path, fname = pathFn()
        saveFn(path, fname)
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end
  end
end

local function IsOKDialogOpen()
  return r.ImGui_IsPopupOpen(ctx, 'Overwrite File?')
end

local function KbdEntryIsCompleted()
  return not IsOKDialogOpen()
    and (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
      or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Tab())
      or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter()))
end

local function DoSavePreset(path, fname)
  local saved = mm.SaveCurrentStateToFile(path, useFilter and getFilterNames() or nil)
  statusMsg = (saved and 'Saved' or 'Failed to save')..' '..fname
  statusTime = r.time_precise()
  statusContext = 2
  fname = fname:gsub('%.ReaperMouseMap$', '')
  popupLabel = fname
  r.ImGui_CloseCurrentPopup(ctx)
end

local function ConfirmButton()
  if not lastInputTextBuffer or lastInputTextBuffer == '' then
    r.ImGui_BeginDisabled(ctx)
  end
  if r.ImGui_Button(ctx, 'Confirm') then
    inOKDialog = true
  end
  if not lastInputTextBuffer or lastInputTextBuffer == '' then
    r.ImGui_EndDisabled(ctx)
  end
end

local function MakeSavePopup()
  r.ImGui_PushFont(ctx, fontInfo.small)
  r.ImGui_SetCursorPosX(ctx, 15 * canvasScale)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, 'SAVE: ')
  r.ImGui_PopFont(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_SetCursorPosX(ctx, (DEFAULT_ITEM_WIDTH - 5) * canvasScale)

  local DEBUG = false
  if DEBUG then
    r.ImGui_SameLine(ctx)
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_AlignTextToFramePadding(ctx)
    local x = r.ImGui_GetWindowSize(ctx)
    local textWidth = r.ImGui_CalcTextSize(ctx, 'Read reaper-mouse.ini')
    r.ImGui_SetCursorPosX(ctx, x - textWidth - (15 * canvasScale))
    if r.ImGui_Button(ctx, 'Read reaper-mouse.ini') then
      mm.GetCurrentState()
    end
    r.ImGui_PopFont(ctx)
  end

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  local textWidth = r.ImGui_CalcTextSize(ctx, 'Write a Preset...')
  if r.ImGui_Button(ctx, 'Write a Preset...', textWidth + 15 * canvasScale) then
    PositionModalWindow(0.75)
    r.ImGui_OpenPopup(ctx, 'Write Preset')
    lastInputTextBuffer = ''
  end

  BuildTooltip(7, 'Write a Mouse Modifier preset\nfile (for import in the Mouse\nModifiers Preferences dialog\nor via the Load Preset menu in\nthis script).')

  handleStatus(2)

  if r.ImGui_BeginPopupModal(ctx, 'Write Preset', true) then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) and not IsOKDialogOpen() then
      r.ImGui_CloseCurrentPopup(ctx)
    end
      r.ImGui_Text(ctx, 'Preset Name')
    r.ImGui_Spacing(ctx)
    if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
    r.ImGui_SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    local _, buf = r.ImGui_InputTextWithHint(ctx, '##presetname', 'Untitled', lastInputTextBuffer, r.ImGui_InputTextFlags_AutoSelectAll())
    lastInputTextBuffer = buf
    if buf and KbdEntryIsCompleted() then
      inOKDialog = true
    end

    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Spacing(ctx)

    ConfirmButton()

    ManageSaveAndOverwrite(PresetPathAndFilenameFromLastInput, DoSavePreset, 2)

    r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopStyleColor(ctx)
end

local function DoRegisterScript(path, section, isToggle)
  local newCmdIdx = r.AddRemoveReaScript(true, section, path, true) -- Main
  if isToggle then
    if section == 0 then
      r.Main_OnCommand(newCmdIdx, section) -- jigger
    else
      r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), newCmdIdx) -- jigger
    end
    if runTogglesAtStartup then
      mm.AddRemoveStartupAction(newCmdIdx, path, true, section ~= 0 and 1 or 0)
    end
  end
end

local function RegisterScript(path, isToggle)
  if SectionMain or SectionLegacy then
    DoRegisterScript(path, 0, isToggle)
  end
  if SectionMIDI then
    DoRegisterScript(path, 32060, isToggle) -- MIDI Editor
    DoRegisterScript(path, 32061, false) -- Event List
    DoRegisterScript(path, 32062, false) -- Inline Editor
  end
end

local function GetSectionIDForActiveSections()
  if SectionLegacy then return 3
  elseif SectionMain and SectionMIDI then return 2
  elseif SectionMIDI then return 1
  else return 0
  end
end

local function DoSaveToggleAction(path, fname)
  local rv = mm.SaveToggleActionToFile(path, wantsUngrouped, useFilter and getFilterNames() or nil, GetSectionIDForActiveSections())
  wantsUngrouped = false
  r.ImGui_CloseCurrentPopup(ctx)
  if rv then
    RegisterScript(path, true)
    statusMsg = 'Wrote and registered '..fname
  else
    statusMsg = 'Error writing '..fname
  end
  statusTime = r.time_precise()
  statusContext = 3
end

local function DoSavePresetLoadAction(path, fname)
  local rv = mm.SavePresetLoadActionToFile(path, PresetLoadSelected)
  r.ImGui_CloseCurrentPopup(ctx)
  if rv then
    RegisterScript(path)
    statusMsg = 'Wrote and registered '..fname
  else
    statusMsg = 'Error writing '..fname
  end
  statusTime = r.time_precise()
  statusContext = 5
end

local function MakeSectionPopup()
  r.ImGui_SameLine(ctx)

  local ibSize = IMAGEBUTTON_SIZE * 0.75 * canvasScale
  local x = r.ImGui_GetWindowSize(ctx)
  r.ImGui_SetCursorPosX(ctx, x - ibSize - (15 * canvasScale))

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  local wantsPop = false
  if r.ImGui_ImageButton(ctx, 'sectgear', GearImage, ibSize, ibSize) then
    wantsPop = true
  end

  if wantsPop then
    r.ImGui_OpenPopup(ctx, 'sectgear menu')
  end

  if r.ImGui_BeginPopup(ctx, 'sectgear menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) and not IsOKDialogOpen() then
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_AlignTextToFramePadding(ctx)
    r.ImGui_Text(ctx, 'Section(s):')
    r.ImGui_SameLine(ctx)

    if useFilter then
      r.ImGui_BeginDisabled(ctx)
      r.ImGui_Button(ctx, 'Filtered', DEFAULT_MENUBUTTON_WIDTH * canvasScale)
      r.ImGui_EndDisabled(ctx)
      SectionMain = false
      SectionMIDI = false
      WantsLegacy = true
    else
      if not SectionMain and not SectionMIDI and not SectionLegacy then SectionMain = true end

      local sectText
      if SectionMain and SectionMIDI then
        sectText = 'Main + MIDI'
      elseif SectionMain then
        sectText = 'Main'
      elseif SectionMIDI then
        sectText = 'MIDI'
      elseif SectionLegacy then
        sectText = 'Legacy (unfiltered)'
      end

      if r.ImGui_Button(ctx, sectText, DEFAULT_MENUBUTTON_WIDTH * canvasScale) then
        r.ImGui_OpenPopup(ctx, 'section menu')
      end

      if r.ImGui_BeginPopup(ctx, 'section menu') then
        if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
          r.ImGui_CloseCurrentPopup(ctx)
        end

        r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
        local retval, v = r.ImGui_Checkbox(ctx, 'Main', SectionMain and true or false)
        if retval then
          SectionMain = v
          if v then SectionLegacy = false end
        end

        r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
        retval, v = r.ImGui_Checkbox(ctx, 'MIDI Editors', SectionMIDI and true or false)
        if retval then
          SectionMIDI = v
          if v then SectionLegacy = false end
        end

        r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
        retval, v = r.ImGui_Checkbox(ctx, 'Legacy (Global)', SectionLegacy and true or false)
        if retval then
          SectionLegacy = v
          if v then
            SectionMain = false
            SectionMIDI = false
          end
        end
        r.ImGui_EndPopup(ctx)
      end
    end
    r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopStyleColor(ctx)
end

local function MakeToggleActionModal(modalName, editableName, suppressOverwrite)
  if r.ImGui_BeginPopupModal(ctx, modalName, true) then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) and not IsOKDialogOpen() then
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Text(ctx, 'Toggle Action Name')
    r.ImGui_PopFont(ctx)
    r.ImGui_Spacing(ctx)
    if r.ImGui_IsWindowAppearing(ctx) and editableName then r.ImGui_SetKeyboardFocusHere(ctx) end
    r.ImGui_SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    local retval, buf, v
    if not editableName then r.ImGui_BeginDisabled(ctx) end
    retval, buf = r.ImGui_InputTextWithHint(ctx, '##toggleaction', 'Untitled Toggle Action', lastInputTextBuffer, r.ImGui_InputTextFlags_AutoSelectAll())
    if not editableName then r.ImGui_EndDisabled(ctx) end
    lastInputTextBuffer = buf
    if buf and KbdEntryIsCompleted() then
      inOKDialog = true
    end

    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Spacing(ctx)

    ConfirmButton()

    MakeSectionPopup()

    ManageSaveAndOverwrite(ActionPathAndFilenameFromLastInput, DoSaveToggleAction, 3)

    if YAGNI then
      r.ImGui_Spacing(ctx)
      retval, v = r.ImGui_Checkbox(ctx, 'Refresh Toggle State At Startup', runTogglesAtStartup)
      if retval then
        runTogglesAtStartup = v
        r.SetExtState(scriptID, 'runTogglesAtStartup', runTogglesAtStartup and '1' or '0', true)
      end

      r.ImGui_Spacing(ctx)
      retval, v = r.ImGui_Checkbox(ctx, 'Unlinked from other Toggle States', wantsUngrouped)
      if retval then
        wantsUngrouped = v
      end
    end
    r.ImGui_PopFont(ctx)

    r.ImGui_EndPopup(ctx)
  end
end

local function MakeToggleActionPopup()
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if r.ImGui_Button(ctx, 'Build a Toggle Action...') then
    PositionModalWindow(YAGNI and 1.1 or 0.75)
    lastInputTextBuffer = lastInputTextBuffer or activeFname and activeFname or ''
    r.ImGui_OpenPopup(ctx, 'Build a Toggle Action')
  end

  BuildTooltip(8, 'Toggle Actions have on/off state\nand are linked with another.\n\nOnly one Toggle Action\ncan be active at a time.')

  handleStatus(3)

  MakeToggleActionModal('Build a Toggle Action', true)
  r.ImGui_PopStyleColor(ctx)
end

local function DoSaveOneShotAction(path, fname)
  local rv = mm.SaveOneShotActionToFile(path, useFilter and getFilterNames() or nil, GetSectionIDForActiveSections())
  r.ImGui_CloseCurrentPopup(ctx)
  if rv then
    RegisterScript(path)
    statusMsg = 'Wrote and registered '..fname
  else
    statusMsg = 'Error writing '..fname
  end
  statusTime = r.time_precise()
  statusContext = 4
end

local function MakeOneShotActionModal(modalName, editableName, suppressOverwrite)
  if r.ImGui_BeginPopupModal(ctx, modalName, true) then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) and not IsOKDialogOpen() then
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Text(ctx, 'One-Shot Action Name')
    r.ImGui_PopFont(ctx)
    r.ImGui_Spacing(ctx)
    if r.ImGui_IsWindowAppearing(ctx) and editableName then r.ImGui_SetKeyboardFocusHere(ctx) end
    r.ImGui_SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    if not editableName then r.ImGui_BeginDisabled(ctx) end
    local retval, buf = r.ImGui_InputTextWithHint(ctx, '##oneshotaction', 'Untitled One-Shot Action', lastInputTextBuffer, r.ImGui_InputTextFlags_AutoSelectAll())
    if not editableName then r.ImGui_EndDisabled(ctx) end
    lastInputTextBuffer = buf
    if buf and KbdEntryIsCompleted() then
      inOKDialog = true
    end

    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Spacing(ctx)

    ConfirmButton()

    MakeSectionPopup()

    ManageSaveAndOverwrite(ActionPathAndFilenameFromLastInput, DoSaveOneShotAction, 4)

    r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end
end

local function MakeOneShotActionPopup()
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if r.ImGui_Button(ctx, 'Build a One-shot Action...') then
    PositionModalWindow(0.75)
    lastInputTextBuffer = lastInputTextBuffer or activeFname and activeFname or ''
    r.ImGui_OpenPopup(ctx, 'Build a One-shot Action')
  end

  BuildTooltip(3, 'One-shot actions have no state and\nare independent of one another.')

  handleStatus(4)

  MakeOneShotActionModal('Build a One-shot Action', true)
  r.ImGui_PopStyleColor(ctx)
end

local function MakePresetSelectionPopup()
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)
  r.ImGui_PushFont(ctx, fontInfo.small)

  if r.ImGui_Button(ctx, PresetLoadSelected ~= nil and PresetLoadSelected or 'Choose Preset...', DEFAULT_MENUBUTTON_WIDTH * canvasScale) then

    r.ImGui_OpenPopup(ctx, 'presetload menu')
  end

  handleStatus(5)

  if r.ImGui_BeginPopup(ctx, 'presetload menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      r.ImGui_CloseCurrentPopup(ctx)
    end

    local fnames = EnumerateMouseMapFiles()
    if #fnames > 0 then
      local cherry = true
      -- TODO: select multiple presets for restore?
      for _, fn in mm.spairs(fnames, function (t, a, b) return t[a] < t[b] end ) do
        if not cherry then Spacing() end
        if r.ImGui_Selectable(ctx, fn) then
          PresetLoadSelected = fn
          r.ImGui_CloseCurrentPopup(ctx)
        end
        cherry = false
      end
    else
      r.ImGui_BeginDisabled(ctx)
      r.ImGui_Selectable(ctx, 'No presets')
      r.ImGui_EndDisabled(ctx)
    end
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopFont(ctx)
  r.ImGui_PopStyleColor(ctx)
end

local function MakePresetLoadActionModal(modalName, editableName, suppressOverwrite)
  if r.ImGui_BeginPopupModal(ctx, modalName, true) then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) and not IsOKDialogOpen() then
      r.ImGui_CloseCurrentPopup(ctx)
    end

    MakePresetSelectionPopup()

    -- preset to load menu
    -- set context/all contexts to default before recall
    -- script context (main, midi, etc.) see reapack
    r.ImGui_Spacing(ctx)
    r.ImGui_Spacing(ctx)
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Text(ctx, 'Preset Load Action Name')
    r.ImGui_PopFont(ctx)
    r.ImGui_Spacing(ctx)
    if r.ImGui_IsWindowAppearing(ctx) and editableName then r.ImGui_SetKeyboardFocusHere(ctx) end
    r.ImGui_SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    if not editableName then r.ImGui_BeginDisabled(ctx) end
    local retval, buf = r.ImGui_InputTextWithHint(ctx, '##presetloadaction', 'Untitled Preset Load Action', lastInputTextBuffer, r.ImGui_InputTextFlags_AutoSelectAll())
    if not editableName then r.ImGui_EndDisabled(ctx) end
    lastInputTextBuffer = buf
    if buf and KbdEntryIsCompleted() then
      inOKDialog = true
    end

    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_Spacing(ctx)

    if PresetLoadSelected == nil then
      r.ImGui_BeginDisabled(ctx)
    end

    ConfirmButton()

    if PresetLoadSelected == nil then
      r.ImGui_EndDisabled(ctx)
    end

    MakeSectionPopup()

    ManageSaveAndOverwrite(ActionPathAndFilenameFromLastInput, DoSavePresetLoadAction, 5)

    r.ImGui_PopFont(ctx)
    r.ImGui_EndPopup(ctx)
  end
end

local function MakePresetLoadActionPopup()
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  if r.ImGui_Button(ctx, 'Build a Preset Load Action...') then
    PositionModalWindow(1)
    lastInputTextBuffer = lastInputTextBuffer or activeFname and activeFname or ''
    r.ImGui_OpenPopup(ctx, 'Build a Preset Load Action')
    PresetLoadSelected = nil
  end

  BuildTooltip(5, 'Preset actions load Mouse Modifier\npreset files (as exported in the Mouse\nModifiers Preferences dialog).')

  handleStatus(5)

  MakePresetLoadActionModal('Build a Preset Load Action', true)
  r.ImGui_PopStyleColor(ctx)
end

-----------------------------------------------------------------------------
----------------------------------- GEAR MENU -------------------------------

local function RebuildActionsMenu()
  actionNames = {}
  local startupFileName = mm.GetStartupFilenameForSection()
  local startupStr
  local f = io.open(r.GetResourcePath()..'/Scripts/MouseMapActions/' .. startupFileName, 'r')
  if f then
    startupStr = f:read('*all')
    f:close()
  end

  local startupFileName_MIDI = mm.GetStartupFilenameForSection(1)
  local startupStr_MIDI
  f = io.open(r.GetResourcePath()..'/Scripts/MouseMapActions/' .. startupFileName_MIDI, 'r')
  if f then
    startupStr_MIDI = f:read('*all')
    f:close()
  end

  local _, activePath = mm.GetActiveToggleAction()
  local _, activeMIDIPath = mm.GetActiveToggleAction(1)

  local idx = 0
  local actionPath = r.GetResourcePath()..'/Scripts/MouseMapActions/'
  r.EnumerateFiles(actionPath, -1)
  local fname = r.EnumerateFiles(actionPath, idx)
  while fname do
    if fname ~= startupFileName
      and fname ~= startupFileName_MIDI
      and fname:match('_MouseMap%.lua$')
    then
      local actionStr
      local actionType = nil
      local actionStartup = false
      local actionActive = false
      local actionScriptPath = actionPath..fname
      local actionSection = nil
      f = io.open(actionScriptPath, 'r')
      if f then
        actionStr = f:read('*all')
        f:close()
      end
      if actionStr then
        local matched = false
        local match

        if not matched then
          match = actionStr:match('RestoreState%s*%(.*,(.-)%s*%)')
          if match then
            actionType = TYPE_SIMPLE
            actionSection = tonumber(match)
            matched = true
          end
        end

        if not matched then
          match = actionStr:match('HandleToggleAction%s*%(.*,(.-)%s*%)')
          if match then
            actionType = TYPE_TOGGLE
            actionActive = activePath == actionScriptPath or activeMIDIPath == actionScriptPath
            actionSection = tonumber(match)
            if actionSection == 1 then actionStartup = startupStr_MIDI:match(actionScriptPath) and true or false
            else actionStartup = startupStr:match(actionScriptPath) and true or false
            end
            matched = true
          end
        end

        if not matched then
          match = actionStr:match('RestoreStateFromFile%s*%(.*,(.-)%s*%)')
          if match then
            actionType = TYPE_PRESET
            matched = true
            -- actionStartup = startupStr:match(actionScriptPath) and true or false -- this should always be false, right?
          end
        end

      end
      if actionType then
        local actionName = fname:gsub('_MouseMap%.lua$', '')
        table.insert(actionNames, { name = actionName, path = actionScriptPath, type = actionType, startup = actionStartup, active = actionActive, section = actionSection })
      end
    end
    idx = idx + 1
    fname = r.EnumerateFiles(actionPath, idx)
  end
end

local function MakeGearPopup()
  local ibSize = FONTSIZE_LARGE * canvasScale
  local x = r.ImGui_GetWindowSize(ctx)
  local textWidth = ibSize -- r.ImGui_CalcTextSize(ctx, 'Gear')
  r.ImGui_SetCursorPosX(ctx, x - textWidth - (15 * canvasScale))
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  local wantsPop = false
  if r.ImGui_ImageButton(ctx, 'gear', GearImage, ibSize, ibSize) then
    rebuildActionsMenu = true
    wantsPop = true
  end

  if rebuildActionsMenu then
    RebuildActionsMenu()
  end
  if wantsPop then
    r.ImGui_OpenPopup(ctx, 'gear menu')
  end

  if r.ImGui_BeginPopup(ctx, 'gear menu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) and not IsOKDialogOpen() then
      r.ImGui_CloseCurrentPopup(ctx)
    end
    local rv, selected, v

    r.ImGui_BeginDisabled(ctx)
    r.ImGui_Text(ctx, 'Version ' .. versionStr)
    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_EndDisabled(ctx)

    -----------------------------------------------------------------------------
    ---------------------------------- OPEN PREFS -------------------------------

    if r.ImGui_Selectable(ctx, 'Open Mouse Modifiers Preference Pane...') then
      r.ViewPrefs(466, '')
      r.ImGui_CloseCurrentPopup(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)

    -----------------------------------------------------------------------------
    --------------------------------- TOOLBAR CUST ------------------------------

    if r.ImGui_Selectable(ctx, 'Open Customize Toolbars Window...') then
      r.Main_OnCommand(40905, 0) -- Toolbars: Customize...
      r.ImGui_CloseCurrentPopup(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)

    -----------------------------------------------------------------------------
    ---------------------------------- BASE FONT --------------------------------

    r.ImGui_Spacing(ctx)

    r.ImGui_SetNextItemWidth(ctx, (DEFAULT_ITEM_WIDTH / 2) * canvasScale)
    rv, v = r.ImGui_InputText(ctx, 'Base Font Size', FONTSIZE_LARGE, r.ImGui_InputTextFlags_EnterReturnsTrue()
                                                                   + r.ImGui_InputTextFlags_CharsDecimal())
    if rv then
      v = processBaseFontUpdate(tonumber(v))
      r.SetExtState(scriptID, 'baseFont', tostring(v), true)
      r.ImGui_CloseCurrentPopup(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)

    -----------------------------------------------------------------------------
    ------------------------------------ FILTERS --------------------------------

    r.ImGui_Spacing(ctx)

    if r.ImGui_BeginMenu(ctx, 'Filter') then
      r.ImGui_PushFont(ctx, fontInfo.small)
      local f_retval, f_v = r.ImGui_Checkbox(ctx, 'Enable Filter', useFilter and true or false)
      if f_retval then
        useFilter = f_v
        r.SetExtState(scriptID, 'useFilter', useFilter and '1' or '0', true)
      end
      if not useFilter then
        r.ImGui_BeginDisabled(ctx)
      end
      r.ImGui_Indent(ctx)
      for cxkey, context in mm.spairs(contexts, function (t, a, b) return t[a].label < t[b].label end) do
        if context.label and context.label ~= '' then
          f_retval, f_v = r.ImGui_Checkbox(ctx, context.label, filtered[cxkey] and true or false)
          if f_retval then
            filtered[cxkey] = f_v and true or nil
            for _, subval in ipairs(context) do
              filtered[subval.key] = f_v and true or nil
            end
            r.SetExtState(scriptID, 'filteredCats', mm.Serialize(getFilterNames(), nil, true), true)
          end
        end
      end
      r.ImGui_Unindent(ctx)
      if not useFilter then
        r.ImGui_EndDisabled(ctx)
      end
      r.ImGui_PopFont(ctx)
      r.ImGui_EndMenu(ctx)
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)

    -----------------------------------------------------------------------------
    ----------------------------------- ACTIONS ---------------------------------

    local function GenerateSubmenu(tab, label, spacing)
      if #tab ~= 0 then
        if spacing then r.ImGui_Spacing(ctx) end
        if r.ImGui_BeginMenu(ctx, label) then
          local cherry = true
          for _, action in mm.spairs(tab, function (t, a, b) return t[a].name < t[b].name end ) do
            local MIDIEnable = action.section ~= 1 or r.MIDIEditor_GetActive()
            local actionName = action.name
            if action.active and MIDIEnable then actionName = actionName .. ' [Active]' end
            if not cherry then Spacing() end
            cherry = false
            if r.ImGui_BeginMenu(ctx, actionName) then
              local didSth = false
              if action.type ~= TYPE_PRESET then
                if r.ImGui_Selectable(ctx, 'Update Action From Current State', false, r.ImGui_SelectableFlags_DontClosePopups()) then
                  lastInputTextBuffer = action.name
                  inOKDialog = true
                end
                ManageSaveAndOverwrite(ActionPathAndFilenameFromLastInput, action.type == TYPE_SIMPLE and DoSaveOneShotAction or DoSaveToggleAction, true)
                didSth = true
              end

              if action.type == TYPE_TOGGLE then
                r.ImGui_Spacing(ctx)
                if r.ImGui_Selectable(ctx, action.startup and 'Remove From Startup' or 'Add To Startup') then
                  local cmdIdx = r.AddRemoveReaScript(true, action.section == 1 and 32060 or 0, action.path, true)
                  mm.AddRemoveStartupAction(cmdIdx, action.path, not action.startup, action.section == 1 and 1 or 0)
                end

                if not MIDIEnable then
                  r.ImGui_BeginDisabled(ctx)
                end
                r.ImGui_Spacing(ctx)
                if r.ImGui_Selectable(ctx, action.active and 'Deactivate Action' or 'Activate Action') then
                  local cmdIdx = r.AddRemoveReaScript(true, action.section == 1 and 32060 or 0, action.path, true)
                  if action.section ~= 1 then
                    r.Main_OnCommand(cmdIdx, 0)
                  else
                    r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), cmdIdx)
                  end
                end
                if not MIDIEnable then
                  r.ImGui_EndDisabled(ctx)
                end
                didSth = true
              end

              if didSth then
                r.ImGui_Spacing(ctx)
                r.ImGui_Separator(ctx)
              end

              if canReveal then
                r.ImGui_Spacing(ctx)
                if r.ImGui_Selectable(ctx, 'Reveal in Finder/Explorer') then
                  r.CF_LocateInExplorer(action.path)
                  r.ImGui_CloseCurrentPopup(ctx)
                end
              end

              r.ImGui_Spacing(ctx)
              if r.ImGui_Selectable(ctx, 'Delete Action', false, r.ImGui_SelectableFlags_DontClosePopups()) then
                inOKDialog = true
              end
              local okrv, okval = HandleOKDialog('Delete Action?', 'Delete '..action.name..' permanently?')
              if okrv then
                if okval == 1 then
                  if action.active then
                    local cmdIdx = r.AddRemoveReaScript(true, action.section == 1 and 32060 or 0, action.path, false)
                    if action.section ~= 1 then
                      r.Main_OnCommand(cmdIdx, 0) -- turn it off
                    else
                      -- this might need to be done for all contexts, could be a little error-prone
                      r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), cmdIdx)
                    end
                  end
                  r.AddRemoveReaScript(false, 0, action.path, false)
                  r.AddRemoveReaScript(false, 32060, action.path, false)
                  r.AddRemoveReaScript(false, 32061, action.path, false)
                  r.AddRemoveReaScript(false, 32062, action.path, true)
                  os.remove(action.path)
                  mm.AddRemoveStartupAction() -- prune
                  rebuildActionsMenu = true
                  -- r.ImGui_CloseCurrentPopup(ctx)
                end
              end
              r.ImGui_EndMenu(ctx)
            end
          end
          r.ImGui_EndMenu(ctx)
        end
        return true
      end
      return false
    end

    r.ImGui_Spacing(ctx)

    if r.ImGui_BeginMenu(ctx, 'Actions') then
      r.ImGui_PushFont(ctx, fontInfo.small)
      if #actionNames > 0 then
        local actionsMain = {}
        local actionsMIDI = {}
        local actionsMM = {}
        local actionsLegacy = {}
        for _, action in mm.spairs(actionNames, function (t, a, b) return t[a].name < t[b].name end ) do
          if action.section ~= nil then
            if action.section == 1 then
              table.insert(actionsMIDI, action)
            elseif action.section == 2 then
              table.insert(actionsMM, action)
            else
              table.insert(actionsMain, action)
            end
          else
            table.insert(actionsLegacy, action)
          end
        end

        local spacing = GenerateSubmenu(actionsMain, 'Main', false)
        if GenerateSubmenu(actionsMIDI, 'MIDI', spacing) and not spacing then spacing = true end
        if GenerateSubmenu(actionsMM, 'Main + MIDI', spacing) and not spacing then spacing = true end
        GenerateSubmenu(actionsLegacy, 'Global', spacing)
      else
        r.ImGui_BeginDisabled(ctx)
        r.ImGui_Selectable(ctx, 'No Actions')
        r.ImGui_EndDisabled(ctx)
      end
      r.ImGui_PopFont(ctx)
      r.ImGui_EndMenu(ctx)
    end

    -----------------------------------------------------------------------------
    --------------------------------- BACKUP SET --------------------------------

    r.ImGui_Spacing(ctx)

    if r.ImGui_BeginMenu(ctx, 'Backup') then
      r.ImGui_PushFont(ctx, fontInfo.small)
      if r.ImGui_Selectable(ctx, 'Update Backup Set') then
        local backupStr = mm.GetCurrentState_Serialized(true) -- always get a full set
        r.SetExtState(scriptID, 'backupSet', backupStr, true)
        r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_Spacing(ctx)
      if r.ImGui_Selectable(ctx, 'Restore Backup Set') then
        local backupStr = r.GetExtState(scriptID, 'backupSet')
        mm.RestoreState_Serialized(backupStr)
        r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_PopFont(ctx)
      r.ImGui_EndMenu(ctx)
    end

    r.ImGui_Spacing(ctx)

    -----------------------------------------------------------------------------
    --------------------------------- BACKUP SET --------------------------------

    if r.ImGui_BeginMenu(ctx, 'Misc') then
      r.ImGui_PushFont(ctx, fontInfo.small)
      if r.ImGui_Selectable(ctx, 'Prune Startup Items') then
        mm.AddRemoveStartupAction() -- no args just means prune
        r.ImGui_CloseCurrentPopup(ctx)
      end

      -- could enumerate scripts in the folder here and add/remove from startup
      -- based on presence of HandleToggleAction() in the script? or add context
      -- menu for each entry to Delete/Add or Remove from startup?
      -- r.ImGui_Spacing(ctx)

      r.ImGui_PopFont(ctx)
      r.ImGui_EndMenu(ctx)
    end
    r.ImGui_EndPopup(ctx)
  end
  r.ImGui_PopStyleColor(ctx)
end

---------------------------------------------------------------------------
----------------------------------- MAINFN --------------------------------

local function mainFn()
  inOKDialog = false
  r.ImGui_PushFont(ctx, fontInfo.large)

  -- r.ImGui_Spacing(ctx)

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
  r.ImGui_Text(ctx, 'GENERATORS')

  r.ImGui_Separator(ctx)

  Spacing()
  MakeToggleActionPopup()

  Spacing()
  MakeOneShotActionPopup()

  Spacing()
  MakePresetLoadActionPopup()

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

  local newFontSize = math.floor((fontInfo[name..'DefaultSize'] * canvasScale) + 0.5)
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

  -- TODO: active MIDI toggle action in titlebar?
  local activeCmdID, activePath = mm.GetActiveToggleAction()
  if activeCmdID and activePath then
    activePath = tostring(activePath)
    local name = activePath:match('.*/(.*)_MouseMap.lua')
    if name ~= nil and name ~= activeFname then
      titleBarText = DEFAULT_TITLEBAR_TEXT .. ' :: [Active: ' .. name .. ']'
      activeFname = name
      lastInputTextBuffer = activeFname
    end
  else
    titleBarText = DEFAULT_TITLEBAR_TEXT
    activeFname = nil
  end

  if useFilter then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), 0x330000FF)
  end
  r.ImGui_SetNextWindowBgAlpha(ctx, 1.0)
  -- r.ImGui_SetNextWindowDockID(ctx, -1)--, r.ImGui_Cond_FirstUseEver()) -- TODO docking
  r.ImGui_SetNextWindowSizeConstraints(ctx, windowInfo.defaultWidth * canvasScale, windowInfo.defaultHeight, windowInfo.defaultWidth * canvasScale, windowInfo.defaultHeight * 2) -- ((windowInfo.defaultHeight - 120) * 2) + 120)

  r.ImGui_PushFont(ctx, fontInfo.small)
  local visible, open = r.ImGui_Begin(ctx, titleBarText, true,
                                        0 -- r.ImGui_WindowFlags_TopMost()
                                      + r.ImGui_WindowFlags_NoScrollWithMouse()
                                      + r.ImGui_WindowFlags_NoScrollbar()
                                      + r.ImGui_WindowFlags_NoSavedSettings())
  r.ImGui_PopFont(ctx)
  if useFilter then
    r.ImGui_PopStyleColor(ctx)
  end

  if r.ImGui_IsWindowAppearing(ctx) then
    viewPort = r.ImGui_GetWindowViewport(ctx)
  end

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

  canvasScale = fontInfo.largeSize / fontInfo.largeDefaultSize --  windowInfo.height / windowInfo.defaultHeight
  if canvasScale > 2 then canvasScale = 2 end

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
