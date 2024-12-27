-- @description MoM Toggle: Mouse Mod Toggle Action Generator
-- @version 2.0.0-beta.6
-- @author sockmonkey72
-- @about
--   # MoM Toggle: Mouse Mod Toggle Action Generator
--   Load/Save Mouse Maps, Generate Toggle and One-shot Actions to change them up
-- @changelog
--   - update ImGui dependency to 0.9.3+
--   - add new MM contexts (take marker)
-- @provides
--   {MouseMaps}/*
--   [main] sockmonkey72_MouseMapFactory.lua
--   [main] sockmonkey72_MoM_Toggle_Mouse_Mod_Toggle_Generator.lua

local r = reaper
package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'MouseMaps/?.lua'
local mm = require 'MouseMaps'
local scriptName = 'MoM Toggle'
local versionStr = '2.0.0-beta.6' -- don't forget to change this above

local canStart = true

package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9.3'
if canStart and not ImGui then
  r.ShowConsoleMsg('MIDI Transformer requires \'ReaImGui\' 0.9.3+ (install from ReaPack)\n')
  canStart = false
end

if not canStart then return end

local scriptID = 'sockmonkey72_MouseMapFactory'

local ctx = ImGui.CreateContext(scriptID) --, ImGui.ConfigFlags_DockingEnable) -- TODO docking
--ImGui.SetConfigVar(ctx, ImGui.ConfigVar_DockingWithShift, 1) -- TODO docking

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local YAGNI = false

local IMAGEBUTTON_SIZE = 13
local GearImage = ImGui.CreateImage(debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'MouseMaps/' .. 'gear_40031.png')
if GearImage then ImGui.Attach(ctx, GearImage) end

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
  if FONTSIZE_SMALL < 1 then FONTSIZE_SMALL = 1 end
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
    large = ImGui.CreateFont('sans-serif', FONTSIZE_LARGE), largeSize = FONTSIZE_LARGE, largeDefaultSize = FONTSIZE_LARGE,
    small = ImGui.CreateFont('sans-serif', FONTSIZE_SMALL), smallSize = FONTSIZE_SMALL, smallDefaultSize = FONTSIZE_SMALL
  }
  ImGui.Attach(ctx, fontInfo.large)
  ImGui.Attach(ctx, fontInfo.small)

  processBaseFontUpdate(tonumber(r.GetExtState(scriptID, 'baseFont')))
end

local function handleStatus(context)
  if statusMsg ~= '' and statusTime and statusContext == context then
    if r.time_precise() - statusTime > 3 then statusTime = nil statusMsg = '' statusContext = 0
    else
      ImGui.SameLine(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, statusMsg)
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
  ImGui.SetNextWindowSize(ctx, winWid, winHgt)
  local winPosX, winPosY = ImGui.Viewport_GetPos(viewPort)
  local winSizeX, winSizeY = ImGui.Viewport_GetSize(viewPort)
  local okPosX = winPosX + (winSizeX / 2.) - (winWid / 2.)
  local okPosY = winPosY + (winSizeY / 2.) - (winHgt / 2.) + (yOff and yOff or 0)
  if okPosY + winHgt > windowInfo.top + windowInfo.height then
    okPosY = okPosY - ((windowInfo.top + windowInfo.height) - (okPosY + winHgt))
  end
  ImGui.SetNextWindowPos(ctx, okPosX, okPosY)
  --ImGui.SetNextWindowPos(ctx, ImGui.GetMousePos(ctx))
end

local function Spacing()
  local posy = ImGui.GetCursorPosY(ctx)
  ImGui.SetCursorPosY(ctx, posy + ((ImGui.GetFrameHeight(ctx) / 4) * canvasScale))
end

local function HandleOKDialog(title, text)
  local rv = false
  local retval = 0
  local doOK = false

  ImGui.PushFont(ctx, fontInfo.large)
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333355FF)

  if inOKDialog then
    PositionModalWindow(0.7, ImGui.GetFrameHeight(ctx) / 2)
    ImGui.OpenPopup(ctx, title)
  elseif (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
    or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)) then
      doOK = true
  end

  if ImGui.BeginPopupModal(ctx, title, true) then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      ImGui.CloseCurrentPopup(ctx)
    end
    Spacing()
    ImGui.Text(ctx, text)
    Spacing()
    if ImGui.Button(ctx, 'Cancel') then
      rv = true
      retval = 0
      ImGui.CloseCurrentPopup(ctx)
    end

    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'OK') or doOK then
      rv = true
      retval = 1
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SetItemDefaultFocus(ctx)

    ImGui.EndPopup(ctx)
  end
  ImGui.PopFont(ctx)
  ImGui.PopStyleColor(ctx)

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
  if ImGui.IsItemHovered(ctx) then
    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.SetNextWindowContentSize(ctx, FONTSIZE_SMALL * 24, FONTSIZE_SMALL * height)
    ImGui.SetTooltip(ctx, text)
    ImGui.PopFont(ctx)
  end
end

local function MakeLoadPopup()
  ImGui.PushFont(ctx, fontInfo.small)
  ImGui.SetCursorPosX(ctx, 15 * canvasScale)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'LOAD:')
  ImGui.PopFont(ctx)
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, (DEFAULT_ITEM_WIDTH - 5) * canvasScale)

  if defaultPresetName ~= '' then
    ImGui.SameLine(ctx)
    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.AlignTextToFramePadding(ctx)
    local x = ImGui.GetWindowSize(ctx)
    local textWidth = ImGui.CalcTextSize(ctx, 'Restore Default')
    ImGui.SetCursorPosX(ctx, x - textWidth - (15 * canvasScale))
    if ImGui.Button(ctx, 'Restore Default') then
      local restored = mm.RestoreStateFromFile(r.GetResourcePath()..'/MouseMaps/'..defaultPresetName..'.ReaperMouseMap', useFilter and getFilterNames() or nil)
      statusMsg = (restored and 'Loaded' or 'Failed to load')..' '..defaultPresetName..'.ReaperMouseMap'
      statusTime = r.time_precise()
      statusContext = 1
      popupLabel = defaultPresetName
    end
    ImGui.PopFont(ctx)
  end

  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333355FF)

  local textWidth = ImGui.CalcTextSize(ctx, 'Load a Preset...')
  if ImGui.Button(ctx, popupLabel, textWidth + 15 * canvasScale) then
    ImGui.OpenPopup(ctx, 'preset menu')
  end

  BuildTooltip(5, 'Load a Mouse Modifier preset\n'..
    'file (as exported in the Mouse\n'..
    'Modifiers Preferences dialog).')

  handleStatus(1)

  if ImGui.BeginPopup(ctx, 'preset menu') then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      ImGui.CloseCurrentPopup(ctx)
    end

    local fnames = EnumerateMouseMapFiles()
    if #fnames > 0 then
      local cherry = true
      for _, fn in mm.spairs(fnames, function (t, a, b) return t[a] < t[b] end ) do
        if not cherry then Spacing() end
        if ImGui.Selectable(ctx, fn) then
          local restored = mm.RestoreStateFromFile(r.GetResourcePath()..'/MouseMaps/'..fn..'.ReaperMouseMap', useFilter and getFilterNames() or nil)
          statusMsg = (restored and 'Loaded' or 'Failed to load')..' '..fn..'.ReaperMouseMap'
          statusTime = r.time_precise()
          statusContext = 1
          ImGui.CloseCurrentPopup(ctx)
          popupLabel = fn
        end
        if ImGui.IsItemHovered(ctx) and ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then
          selectedPresetPath = r.GetResourcePath()..'/MouseMaps/'..fn..'.ReaperMouseMap'
          presetPopupName = fn
          ImGui.OpenPopup(ctx, 'preset ctx menu')
        end
        cherry = false
      end
      if ImGui.BeginPopup(ctx, 'preset ctx menu') then
        local retval, v = ImGui.Checkbox(ctx, 'Set Default Preset', presetPopupName == defaultPresetName)
        if retval then
          defaultPresetName = v and presetPopupName or ''
          r.SetExtState(scriptID, 'defaultPresetName', defaultPresetName, true)
        end
        ImGui.Spacing(ctx)
        ImGui.Separator(ctx)

        if canReveal then
          ImGui.Spacing(ctx)
          if ImGui.Selectable(ctx, 'Reveal in Finder/Explorer') then
            r.CF_LocateInExplorer(selectedPresetPath)
            ImGui.CloseCurrentPopup(ctx)
          end
        end

        ImGui.Spacing(ctx)
        if ImGui.Selectable(ctx, 'Delete Preset') then
          inOKDialog = true
        end
        ImGui.EndPopup(ctx)
      end
      if selectedPresetPath then
        local spName = selectedPresetPath:match('.*/(.*)%.ReaperMouseMap$')
        local okrv, okval = HandleOKDialog('Delete Preset?', 'Delete '..spName..' permanently?')
        if okrv then
          if okval == 1 then
            os.remove(selectedPresetPath)
            selectedPresetPath = nil
            --ImGui.CloseCurrentPopup(ctx)
          end
        end
      end
    else
      ImGui.BeginDisabled(ctx)
      ImGui.Selectable(ctx, 'No presets')
      ImGui.EndDisabled(ctx)
    end
    ImGui.EndPopup(ctx)
  end
  ImGui.PopStyleColor(ctx)
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
      ImGui.CloseCurrentPopup(ctx)
    end
  end

  if lastInputTextBuffer and lastInputTextBuffer ~= '' then
    local okrv, okval = HandleOKDialog('Overwrite File?', 'Overwrite file '..lastInputTextBuffer..'?')
    if okrv then
      if okval == 1 then
        local path, fname = pathFn()
        saveFn(path, fname)
        ImGui.CloseCurrentPopup(ctx)
      end
    end
  end
end

local function IsOKDialogOpen()
  return ImGui.IsPopupOpen(ctx, 'Overwrite File?')
end

local function KbdEntryIsCompleted()
  return not IsOKDialogOpen()
    and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
      or ImGui.IsKeyPressed(ctx, ImGui.Key_Tab)
      or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter))
end

local function DoSavePreset(path, fname)
  local saved = mm.SaveCurrentStateToFile(path, useFilter and getFilterNames() or nil)
  statusMsg = (saved and 'Saved' or 'Failed to save')..' '..fname
  statusTime = r.time_precise()
  statusContext = 2
  fname = fname:gsub('%.ReaperMouseMap$', '')
  popupLabel = fname
  ImGui.CloseCurrentPopup(ctx)
end

local function ConfirmButton()
  if not lastInputTextBuffer or lastInputTextBuffer == '' then
    ImGui.BeginDisabled(ctx)
  end
  if ImGui.Button(ctx, 'Confirm') then
    inOKDialog = true
  end
  if not lastInputTextBuffer or lastInputTextBuffer == '' then
    ImGui.EndDisabled(ctx)
  end
end

local function MakeSavePopup()
  ImGui.PushFont(ctx, fontInfo.small)
  ImGui.SetCursorPosX(ctx, 15 * canvasScale)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'SAVE: ')
  ImGui.PopFont(ctx)
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, (DEFAULT_ITEM_WIDTH - 5) * canvasScale)

  local DEBUG = false
  if DEBUG then
    ImGui.SameLine(ctx)
    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.AlignTextToFramePadding(ctx)
    local x = ImGui.GetWindowSize(ctx)
    local textWidth = ImGui.CalcTextSize(ctx, 'Read reaper-mouse.ini')
    ImGui.SetCursorPosX(ctx, x - textWidth - (15 * canvasScale))
    if ImGui.Button(ctx, 'Read reaper-mouse.ini') then
      mm.GetCurrentState()
    end
    ImGui.PopFont(ctx)
  end

  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333355FF)

  local textWidth = ImGui.CalcTextSize(ctx, 'Write a Preset...')
  if ImGui.Button(ctx, 'Write a Preset...', textWidth + 15 * canvasScale) then
    PositionModalWindow(0.75)
    ImGui.OpenPopup(ctx, 'Write Preset')
    lastInputTextBuffer = ''
  end

  BuildTooltip(7, 'Write a Mouse Modifier preset\n'..
    'file (for import in the Mouse\n'..
    'Modifiers Preferences dialog\n'..
    'or via the Load Preset menu in\n'..
    'this script).')

  handleStatus(2)

  if ImGui.BeginPopupModal(ctx, 'Write Preset', true) then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not IsOKDialogOpen() then
      ImGui.CloseCurrentPopup(ctx)
    end
      ImGui.Text(ctx, 'Preset Name')
    ImGui.Spacing(ctx)
    if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    local _, buf = ImGui.InputTextWithHint(ctx, '##presetname', 'Untitled', lastInputTextBuffer, ImGui.InputTextFlags_AutoSelectAll)
    lastInputTextBuffer = buf
    if buf and KbdEntryIsCompleted() then
      inOKDialog = true
    end

    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.Spacing(ctx)

    ConfirmButton()

    ManageSaveAndOverwrite(PresetPathAndFilenameFromLastInput, DoSavePreset, 2)

    ImGui.PopFont(ctx)
    ImGui.EndPopup(ctx)
  end
  ImGui.PopStyleColor(ctx)
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
  ImGui.CloseCurrentPopup(ctx)
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
  ImGui.CloseCurrentPopup(ctx)
  if rv then
    RegisterScript(path)
    statusMsg = 'Wrote and registered '..fname
  else
    statusMsg = 'Error writing '..fname
  end
  statusTime = r.time_precise()
  statusContext = 5
end

-- we could consider decoupling install location and toggle group, but not sure if it's really necessary
local function MakeSectionPopup(actionType)
  ImGui.SameLine(ctx)

  local ibSize = IMAGEBUTTON_SIZE * 0.75 * canvasScale
  local x = ImGui.GetWindowSize(ctx)
  ImGui.SetCursorPosX(ctx, x - ibSize - (15 * canvasScale))

  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333355FF)

  local wantsPop = false
  if ImGui.ImageButton(ctx, 'sectgear', GearImage, ibSize, ibSize) then
    wantsPop = true
  end

  local toolTipStr = 'Choose a Section for the script.\n\n'..
                     'Section determines:\n\n'
  local toolTipHeight

  if not actionType or actionType == TYPE_SIMPLE or actionType == TYPE_TOGGLE then
    toolTipHeight = 12
    toolTipStr = toolTipStr..
      '\t* Where the new Action will be\n'..
      '\t  installed in the Actions Window\n'..
      '\t  and which contexts are affected.\n'..
      '\t  (Main vs MIDI Editors context)'
  end

  if actionType == TYPE_TOGGLE then
    toolTipHeight = 21
    toolTipStr = toolTipStr..'\n\n'..
      '\t* For Toggle Actions, which group\n'..
      '\t  the Action belongs to (Main/MIDI).\n\n'..
      'Toggle actions installed to\n'..
      '"Main + MIDI" or "Legacy" belong\n'..
      'to the"Main" toggle group.'
  end

  if actionType == TYPE_PRESET then
    toolTipHeight = 10
    toolTipStr = toolTipStr..
      '\t* Where the new Action will be\n'..
      '\t  installed in the Actions Window.\n'..
      '\t  Presets are not filtered by context.'
  end

  BuildTooltip(toolTipHeight, toolTipStr)

  if wantsPop then
    ImGui.OpenPopup(ctx, 'sectgear menu')
  end

  if ImGui.BeginPopup(ctx, 'sectgear menu') then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not IsOKDialogOpen() then
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Section(s):')
    ImGui.SameLine(ctx)

    if useFilter then
      ImGui.BeginDisabled(ctx)
      ImGui.Button(ctx, 'Filtered', DEFAULT_MENUBUTTON_WIDTH * canvasScale)
      ImGui.EndDisabled(ctx)
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

      if ImGui.Button(ctx, sectText, DEFAULT_MENUBUTTON_WIDTH * canvasScale) then
        ImGui.OpenPopup(ctx, 'section menu')
      end

      if ImGui.BeginPopup(ctx, 'section menu') then
        if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
          ImGui.CloseCurrentPopup(ctx)
        end

        ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
        local retval, v = ImGui.Checkbox(ctx, 'Main', SectionMain and true or false)
        if retval then
          SectionMain = v
          if v then SectionLegacy = false end
        end

        ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
        retval, v = ImGui.Checkbox(ctx, 'MIDI Editors', SectionMIDI and true or false)
        if retval then
          SectionMIDI = v
          if v then SectionLegacy = false end
        end

        ImGui.SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * canvasScale)
        retval, v = ImGui.Checkbox(ctx, 'Legacy (Global)', SectionLegacy and true or false)
        if retval then
          SectionLegacy = v
          if v then
            SectionMain = false
            SectionMIDI = false
          end
        end
        ImGui.EndPopup(ctx)
      end
    end
    ImGui.PopFont(ctx)
    ImGui.EndPopup(ctx)
  end
  ImGui.PopStyleColor(ctx)
end

local function MakeToggleActionModal(modalName, editableName, suppressOverwrite)
  if ImGui.BeginPopupModal(ctx, modalName, true) then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not IsOKDialogOpen() then
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.Text(ctx, 'Toggle Action Name')
    ImGui.PopFont(ctx)
    ImGui.Spacing(ctx)
    if ImGui.IsWindowAppearing(ctx) and editableName then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    local retval, buf, v
    if not editableName then ImGui.BeginDisabled(ctx) end
    retval, buf = ImGui.InputTextWithHint(ctx, '##toggleaction', 'Untitled Toggle Action', lastInputTextBuffer, ImGui.InputTextFlags_AutoSelectAll)
    if not editableName then ImGui.EndDisabled(ctx) end
    lastInputTextBuffer = buf
    if buf and KbdEntryIsCompleted() then
      inOKDialog = true
    end

    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.Spacing(ctx)

    ConfirmButton()

    MakeSectionPopup(TYPE_TOGGLE)

    ManageSaveAndOverwrite(ActionPathAndFilenameFromLastInput, DoSaveToggleAction, 3)

    if YAGNI then
      ImGui.Spacing(ctx)
      retval, v = ImGui.Checkbox(ctx, 'Refresh Toggle State At Startup', runTogglesAtStartup)
      if retval then
        runTogglesAtStartup = v
        r.SetExtState(scriptID, 'runTogglesAtStartup', runTogglesAtStartup and '1' or '0', true)
      end

      ImGui.Spacing(ctx)
      retval, v = ImGui.Checkbox(ctx, 'Unlinked from other Toggle States', wantsUngrouped)
      if retval then
        wantsUngrouped = v
      end
    end
    ImGui.PopFont(ctx)

    ImGui.EndPopup(ctx)
  end
end

local function MakeToggleActionPopup()
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333355FF)

  if ImGui.Button(ctx, 'Build a Toggle Action...') then
    PositionModalWindow(YAGNI and 1.1 or 0.75)
    lastInputTextBuffer = lastInputTextBuffer or activeFname and activeFname or ''
    ImGui.OpenPopup(ctx, 'Build a Toggle Action')
  end

  BuildTooltip(8, 'Toggle Actions have on/off state\n'..
    'and are linked with another.\n\n'..
    'Only one Toggle Action\n'..
    'can be active at a time.')

  handleStatus(3)

  MakeToggleActionModal('Build a Toggle Action', true)
  ImGui.PopStyleColor(ctx)
end

local function DoSaveOneShotAction(path, fname)
  local rv = mm.SaveOneShotActionToFile(path, useFilter and getFilterNames() or nil, GetSectionIDForActiveSections())
  ImGui.CloseCurrentPopup(ctx)
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
  if ImGui.BeginPopupModal(ctx, modalName, true) then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not IsOKDialogOpen() then
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.Text(ctx, 'One-Shot Action Name')
    ImGui.PopFont(ctx)
    ImGui.Spacing(ctx)
    if ImGui.IsWindowAppearing(ctx) and editableName then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    if not editableName then ImGui.BeginDisabled(ctx) end
    local retval, buf = ImGui.InputTextWithHint(ctx, '##oneshotaction', 'Untitled One-Shot Action', lastInputTextBuffer, ImGui.InputTextFlags_AutoSelectAll)
    if not editableName then ImGui.EndDisabled(ctx) end
    lastInputTextBuffer = buf
    if buf and KbdEntryIsCompleted() then
      inOKDialog = true
    end

    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.Spacing(ctx)

    ConfirmButton()

    MakeSectionPopup(TYPE_SIMPLE)

    ManageSaveAndOverwrite(ActionPathAndFilenameFromLastInput, DoSaveOneShotAction, 4)

    ImGui.PopFont(ctx)
    ImGui.EndPopup(ctx)
  end
end

local function MakeOneShotActionPopup()
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333355FF)

  if ImGui.Button(ctx, 'Build a One-shot Action...') then
    PositionModalWindow(0.75)
    lastInputTextBuffer = lastInputTextBuffer or activeFname and activeFname or ''
    ImGui.OpenPopup(ctx, 'Build a One-shot Action')
  end

  BuildTooltip(3, 'One-shot actions have no state and\n'..
    'are independent of one another.')

  handleStatus(4)

  MakeOneShotActionModal('Build a One-shot Action', true)
  ImGui.PopStyleColor(ctx)
end

local function MakePresetSelectionPopup()
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333355FF)
  ImGui.PushFont(ctx, fontInfo.small)

  if ImGui.Button(ctx, PresetLoadSelected ~= nil and PresetLoadSelected or 'Choose Preset...', DEFAULT_MENUBUTTON_WIDTH * canvasScale) then

    ImGui.OpenPopup(ctx, 'presetload menu')
  end

  handleStatus(5)

  if ImGui.BeginPopup(ctx, 'presetload menu') then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      ImGui.CloseCurrentPopup(ctx)
    end

    local fnames = EnumerateMouseMapFiles()
    if #fnames > 0 then
      local cherry = true
      -- TODO: select multiple presets for restore?
      for _, fn in mm.spairs(fnames, function (t, a, b) return t[a] < t[b] end ) do
        if not cherry then Spacing() end
        if ImGui.Selectable(ctx, fn) then
          PresetLoadSelected = fn
          ImGui.CloseCurrentPopup(ctx)
        end
        cherry = false
      end
    else
      ImGui.BeginDisabled(ctx)
      ImGui.Selectable(ctx, 'No presets')
      ImGui.EndDisabled(ctx)
    end
    ImGui.EndPopup(ctx)
  end
  ImGui.PopFont(ctx)
  ImGui.PopStyleColor(ctx)
end

local function MakePresetLoadActionModal(modalName, editableName, suppressOverwrite)
  if ImGui.BeginPopupModal(ctx, modalName, true) then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not IsOKDialogOpen() then
      ImGui.CloseCurrentPopup(ctx)
    end

    MakePresetSelectionPopup()

    -- preset to load menu
    -- set context/all contexts to default before recall
    -- script context (main, midi, etc.) see reapack
    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)
    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.Text(ctx, 'Preset Load Action Name')
    ImGui.PopFont(ctx)
    ImGui.Spacing(ctx)
    if ImGui.IsWindowAppearing(ctx) and editableName then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    if not editableName then ImGui.BeginDisabled(ctx) end
    local retval, buf = ImGui.InputTextWithHint(ctx, '##presetloadaction', 'Untitled Preset Load Action', lastInputTextBuffer, ImGui.InputTextFlags_AutoSelectAll)
    if not editableName then ImGui.EndDisabled(ctx) end
    lastInputTextBuffer = buf
    if buf and KbdEntryIsCompleted() then
      inOKDialog = true
    end

    ImGui.PushFont(ctx, fontInfo.small)
    ImGui.Spacing(ctx)

    if PresetLoadSelected == nil then
      ImGui.BeginDisabled(ctx)
    end

    ConfirmButton()

    if PresetLoadSelected == nil then
      ImGui.EndDisabled(ctx)
    end

    MakeSectionPopup(TYPE_PRESET)

    ManageSaveAndOverwrite(ActionPathAndFilenameFromLastInput, DoSavePresetLoadAction, 5)

    ImGui.PopFont(ctx)
    ImGui.EndPopup(ctx)
  end
end

local function MakePresetLoadActionPopup()
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333355FF)

  if ImGui.Button(ctx, 'Build a Preset Load Action...') then
    PositionModalWindow(1)
    lastInputTextBuffer = lastInputTextBuffer or activeFname and activeFname or ''
    ImGui.OpenPopup(ctx, 'Build a Preset Load Action')
    PresetLoadSelected = nil
  end

  BuildTooltip(5, 'Preset actions load Mouse Modifier\n'..
    'preset files (as exported in the Mouse\n'..
    'Modifiers Preferences dialog).')

  handleStatus(5)

  MakePresetLoadActionModal('Build a Preset Load Action', true)
  ImGui.PopStyleColor(ctx)
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
  local x = ImGui.GetWindowSize(ctx)
  local textWidth = ibSize -- ImGui.CalcTextSize(ctx, 'Gear')
  ImGui.SetCursorPosX(ctx, x - textWidth - (15 * canvasScale))
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x333355FF)

  local wantsPop = false
  if ImGui.ImageButton(ctx, 'gear', GearImage, ibSize, ibSize) then
    rebuildActionsMenu = true
    wantsPop = true
  end

  if rebuildActionsMenu then
    RebuildActionsMenu()
  end
  if wantsPop then
    ImGui.OpenPopup(ctx, 'gear menu')
  end

  if ImGui.BeginPopup(ctx, 'gear menu') then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not IsOKDialogOpen() then
      ImGui.CloseCurrentPopup(ctx)
    end
    local rv, selected, v

    ImGui.BeginDisabled(ctx)
    ImGui.Text(ctx, 'Version ' .. versionStr)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.EndDisabled(ctx)

    -----------------------------------------------------------------------------
    ---------------------------------- OPEN PREFS -------------------------------

    if ImGui.Selectable(ctx, 'Open Mouse Modifiers Preference Pane...') then
      r.ViewPrefs(466, '')
      ImGui.CloseCurrentPopup(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)

    -----------------------------------------------------------------------------
    --------------------------------- TOOLBAR CUST ------------------------------

    if ImGui.Selectable(ctx, 'Open Customize Toolbars Window...') then
      r.Main_OnCommand(40905, 0) -- Toolbars: Customize...
      ImGui.CloseCurrentPopup(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)

    -----------------------------------------------------------------------------
    ---------------------------------- BASE FONT --------------------------------

    ImGui.Spacing(ctx)

    ImGui.SetNextItemWidth(ctx, (DEFAULT_ITEM_WIDTH / 2) * canvasScale)
    rv, v = ImGui.InputText(ctx, 'Base Font Size', tostring(FONTSIZE_LARGE), ImGui.InputTextFlags_EnterReturnsTrue
                                                                           + ImGui.InputTextFlags_CharsDecimal)
    if rv then
      v = processBaseFontUpdate(tonumber(v))
      r.SetExtState(scriptID, 'baseFont', tostring(v), true)
      ImGui.CloseCurrentPopup(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)

    -----------------------------------------------------------------------------
    ------------------------------------ FILTERS --------------------------------

    ImGui.Spacing(ctx)

    if ImGui.BeginMenu(ctx, 'Filter') then
      ImGui.PushFont(ctx, fontInfo.small)
      local f_retval, f_v = ImGui.Checkbox(ctx, 'Enable Filter', useFilter and true or false)
      if f_retval then
        useFilter = f_v
        r.SetExtState(scriptID, 'useFilter', useFilter and '1' or '0', true)
      end
      if not useFilter then
        ImGui.BeginDisabled(ctx)
      end
      ImGui.Indent(ctx)
      for cxkey, context in mm.spairs(contexts, function (t, a, b) return t[a].label < t[b].label end) do
        if context.label and context.label ~= '' then
          f_retval, f_v = ImGui.Checkbox(ctx, context.label, filtered[cxkey] and true or false)
          if f_retval then
            filtered[cxkey] = f_v and true or nil
            for _, subval in ipairs(context) do
              filtered[subval.key] = f_v and true or nil
            end
            r.SetExtState(scriptID, 'filteredCats', mm.Serialize(getFilterNames(), nil, true), true)
          end
        end
      end
      ImGui.Unindent(ctx)
      if not useFilter then
        ImGui.EndDisabled(ctx)
      end
      ImGui.PopFont(ctx)
      ImGui.EndMenu(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)

    -----------------------------------------------------------------------------
    ----------------------------------- ACTIONS ---------------------------------

    local function GenerateSubmenu(tab, label, spacing)
      if #tab ~= 0 then
        if spacing then ImGui.Spacing(ctx) end
        if ImGui.BeginMenu(ctx, label) then
          local cherry = true
          for _, action in mm.spairs(tab, function (t, a, b) return t[a].name < t[b].name end ) do
            local MIDIEnable = action.section ~= 1 or r.MIDIEditor_GetActive()
            local actionName = action.name
            if action.active and MIDIEnable then actionName = actionName .. ' [Active]' end
            if not cherry then Spacing() end
            cherry = false
            if ImGui.BeginMenu(ctx, actionName) then
              local didSth = false
              if action.type ~= TYPE_PRESET then
                if ImGui.Selectable(ctx, 'Update Action From Current State', false, ImGui.SelectableFlags_DontClosePopups) then
                  lastInputTextBuffer = action.name
                  inOKDialog = true
                end
                ManageSaveAndOverwrite(ActionPathAndFilenameFromLastInput, action.type == TYPE_SIMPLE and DoSaveOneShotAction or DoSaveToggleAction, true)
                didSth = true
              end

              if action.type == TYPE_TOGGLE then
                ImGui.Spacing(ctx)
                if ImGui.Selectable(ctx, action.startup and 'Remove From Startup' or 'Add To Startup') then
                  local cmdIdx = r.AddRemoveReaScript(true, action.section == 1 and 32060 or 0, action.path, true)
                  mm.AddRemoveStartupAction(cmdIdx, action.path, not action.startup, action.section == 1 and 1 or 0)
                end

                if not MIDIEnable then
                  ImGui.BeginDisabled(ctx)
                end
                ImGui.Spacing(ctx)
                if ImGui.Selectable(ctx, action.active and 'Deactivate Action' or 'Activate Action') then
                  local cmdIdx = r.AddRemoveReaScript(true, action.section == 1 and 32060 or 0, action.path, true)
                  if action.section ~= 1 then
                    r.Main_OnCommand(cmdIdx, 0)
                  else
                    r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), cmdIdx)
                  end
                end
                if not MIDIEnable then
                  ImGui.EndDisabled(ctx)
                end
                didSth = true
              end

              if didSth then
                ImGui.Spacing(ctx)
                ImGui.Separator(ctx)
              end

              if canReveal then
                ImGui.Spacing(ctx)
                if ImGui.Selectable(ctx, 'Reveal in Finder/Explorer') then
                  r.CF_LocateInExplorer(action.path)
                  ImGui.CloseCurrentPopup(ctx)
                end
              end

              ImGui.Spacing(ctx)
              if ImGui.Selectable(ctx, 'Delete Action', false, ImGui.SelectableFlags_DontClosePopups) then
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
                  -- ImGui.CloseCurrentPopup(ctx)
                end
              end
              ImGui.EndMenu(ctx)
            end
          end
          ImGui.EndMenu(ctx)
        end
        return true
      end
      return false
    end

    ImGui.Spacing(ctx)

    if ImGui.BeginMenu(ctx, 'Actions') then
      ImGui.PushFont(ctx, fontInfo.small)
      if #actionNames > 0 then
        local actionsMain = {}
        local actionsMIDI = {}
        local actionsGlobal = {}
        for _, action in mm.spairs(actionNames, function (t, a, b) return t[a].name < t[b].name end ) do
          if action.section ~= nil then
            if action.section == 1 then
              table.insert(actionsMIDI, action)
            elseif action.section == 2 then
              table.insert(actionsGlobal, action) -- remove main + midi section, this menu only shows execution context
            else
              table.insert(actionsMain, action)
            end
          else
            table.insert(actionsGlobal, action)
          end
        end

        local spacing = GenerateSubmenu(actionsMain, 'Main', false)
        if GenerateSubmenu(actionsMIDI, 'MIDI', spacing) and not spacing then spacing = true end
        GenerateSubmenu(actionsGlobal, 'Global', spacing)
      else
        ImGui.BeginDisabled(ctx)
        ImGui.Selectable(ctx, 'No Actions')
        ImGui.EndDisabled(ctx)
      end
      ImGui.PopFont(ctx)
      ImGui.EndMenu(ctx)
    end

    -----------------------------------------------------------------------------
    --------------------------------- BACKUP SET --------------------------------

    ImGui.Spacing(ctx)

    if ImGui.BeginMenu(ctx, 'Backup') then
      ImGui.PushFont(ctx, fontInfo.small)
      if ImGui.Selectable(ctx, 'Update Backup Set') then
        local backupStr = mm.GetCurrentState_Serialized(true) -- always get a full set
        r.SetExtState(scriptID, 'backupSet', backupStr, true)
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.Spacing(ctx)
      if ImGui.Selectable(ctx, 'Restore Backup Set') then
        local backupStr = r.GetExtState(scriptID, 'backupSet')
        mm.RestoreState_Serialized(backupStr)
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.PopFont(ctx)
      ImGui.EndMenu(ctx)
    end

    ImGui.Spacing(ctx)

    -----------------------------------------------------------------------------
    --------------------------------- BACKUP SET --------------------------------

    if ImGui.BeginMenu(ctx, 'Misc') then
      ImGui.PushFont(ctx, fontInfo.small)
      if ImGui.Selectable(ctx, 'Prune Startup Items') then
        mm.AddRemoveStartupAction() -- no args just means prune
        ImGui.CloseCurrentPopup(ctx)
      end

      -- could enumerate scripts in the folder here and add/remove from startup
      -- based on presence of HandleToggleAction() in the script? or add context
      -- menu for each entry to Delete/Add or Remove from startup?
      -- ImGui.Spacing(ctx)

      ImGui.PopFont(ctx)
      ImGui.EndMenu(ctx)
    end
    ImGui.EndPopup(ctx)
  end
  ImGui.PopStyleColor(ctx)
end

---------------------------------------------------------------------------
----------------------------------- MAINFN --------------------------------

local function mainFn()
  inOKDialog = false
  ImGui.PushFont(ctx, fontInfo.large)

  -- ImGui.Spacing(ctx)

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'PRESETS')

  ImGui.SameLine(ctx)
  MakeGearPopup()

  ImGui.Separator(ctx)

  Spacing()
  MakeLoadPopup()

  Spacing()
  MakeSavePopup()
  Spacing()

  Spacing()
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'GENERATORS')

  ImGui.Separator(ctx)

  Spacing()
  MakeToggleActionPopup()

  Spacing()
  MakeOneShotActionPopup()

  Spacing()
  MakePresetLoadActionPopup()

  ImGui.PopFont(ctx)
end

-----------------------------------------------------------------------------
--------------------------------- CLEANUP -----------------------------------

local function doClose()
  ImGui.Detach(ctx, fontInfo.large)
  ImGui.Detach(ctx, fontInfo.small)
  ImGui.Detach(ctx, GearImage)
end

local function onCrash(err)
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
end

-----------------------------------------------------------------------------
----------------------------- WSIZE/FONTS JUNK ------------------------------

local function updateWindowPosition()
  local curWindowWidth, curWindowHeight = ImGui.GetWindowSize(ctx)
  local curWindowLeft, curWindowTop = ImGui.GetWindowPos(ctx)

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
  if newFontSize < 1 then newFontSize = 1 end
  local fontSize = fontInfo[name..'Size']

  if newFontSize ~= fontSize then
    ImGui.Detach(ctx, fontInfo[name])
    fontInfo[name] = ImGui.CreateFont('sans-serif', newFontSize)
    ImGui.Attach(ctx, fontInfo[name])
    fontInfo[name..'Size'] = newFontSize
  end
end

local function updateFonts()
  updateOneFont('large')
  updateOneFont('small')
end

local function openWindow()
  local windowSizeFlag = ImGui.Cond_Appearing
  if windowInfo.wantsResize then
    windowSizeFlag = 0
  end

  ImGui.SetNextWindowSize(ctx, windowInfo.width, windowInfo.height, windowSizeFlag)
  ImGui.SetNextWindowPos(ctx, windowInfo.left, windowInfo.top, windowSizeFlag)
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
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, 0x330000FF)
  end
  ImGui.SetNextWindowBgAlpha(ctx, 1.0)
  -- ImGui.SetNextWindowDockID(ctx, -1)--, ImGui.Cond_FirstUseEver) -- TODO docking
  ImGui.SetNextWindowSizeConstraints(ctx, windowInfo.defaultWidth * canvasScale, windowInfo.defaultHeight, windowInfo.defaultWidth * canvasScale, windowInfo.defaultHeight * 2) -- ((windowInfo.defaultHeight - 120) * 2) + 120)

  ImGui.PushFont(ctx, fontInfo.small)
  local visible, open = ImGui.Begin(ctx, titleBarText, true,
                                        0 -- ImGui.WindowFlags_TopMost
                                      + ImGui.WindowFlags_NoScrollWithMouse
                                      + ImGui.WindowFlags_NoScrollbar
                                      + ImGui.WindowFlags_NoSavedSettings)
  ImGui.PopFont(ctx)
  if useFilter then
    ImGui.PopStyleColor(ctx)
  end

  if ImGui.IsWindowAppearing(ctx) then
    viewPort = ImGui.GetWindowViewport(ctx)
  end

  return visible, open
end

-----------------------------------------------------------------------------
-------------------------------- SHORTCUTS ----------------------------------

local function checkShortcuts()
  -- if ImGui.IsAnyItemActive(ctx) then return end

  -- local keyMods = ImGui.GetKeyMods(ctx)
  -- local modKey = keyMods == ImGui.Mod_Shortcut
  -- local modShiftKey = keyMods == ImGui.Mod_Shortcut + ImGui.Mod_Shift
  -- local noMod = keyMods == 0

  -- if modKey and ImGui.IsKeyPressed(ctx, ImGui.Key_Z) then -- undo
  --   r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40013)
  -- elseif modShiftKey and ImGui.IsKeyPressed(ctx, ImGui.Key_Z) then -- redo
  --   r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40014)
  -- elseif noMod and ImGui.IsKeyPressed(ctx, ImGui.Key_Space) then -- play/pause
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

    ImGui.PushFont(ctx, fontInfo.large)
    mainFn()
    ImGui.PopFont(ctx)

    -- ww, wh = ImGui.Viewport_GetSize(ImGui.GetWindowViewport(ctx)) -- TODO docking
    updateWindowPosition()

    ImGui.End(ctx)
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
