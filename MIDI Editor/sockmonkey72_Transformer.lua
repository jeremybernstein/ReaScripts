-- @description MIDI Transformer
-- @version 1.0.10
-- @author sockmonkey72
-- @about
--   # MIDI Transformer
-- @changelog
--   - fix crash when reading in old linear ramp presets
--   - add (and accommodate) 'text' type
--   - fix state restoration of scope & mods
-- @provides
--   {Transformer}/*
--   Transformer/icons/*
--   Transformer/MIDIUtils.lua https://raw.githubusercontent.com/jeremybernstein/ReaScripts/main/MIDI/MIDIUtils.lua
--   Transformer Presets/Factory Presets/**/*.tfmrPreset > ../$path
--   [main=main,midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Transformer.lua

-----------------------------------------------------------------------------

-- note that the @provides path with $path only works due to a reapack-index hack (at the moment)

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

local versionStr = '1.0.10'

local r = reaper

-- local fontStyle = 'monospace'
local fontStyle = 'sans-serif'

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'Transformer/?.lua'
local tx = require 'TransformerLib'
local mu = tx.mu

local canStart = true

local function fileExists(name)
  local f = io.open(name,'r')
  if f ~= nil then io.close(f) return true else return false end
end

if not tx then
  r.ShowConsoleMsg('MIDI Transformer requires TransformerLib, which appears to not be present (should have been installed by ReaPack when installing this script. Please reinstall.\n')
  canStart = false
end

if canStart and not tx.startup() then
  r.ShowConsoleMsg('MIDI Transformer requires MIDIUtils, which appears to not be present (should have been installed by ReaPack when installing this script. Please reinstall.\n')
  canStart = false
end

local imGuiPath = r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua'
if canStart and not fileExists(imGuiPath) then
  r.ShowConsoleMsg('MIDI Transformer requires \'ReaImGui\' 0.8+ (install from ReaPack)\n')
  canStart = false
end

-- if not r.APIExists('JS_Mouse_GetState') then
--   r.ShowConsoleMsg('MIDI Transformer appreciates the presence of the \'js_ReaScriptAPI\' extension (install from ReaPack)\n')
-- end

local canReveal = true

if canStart and not r.APIExists('CF_LocateInExplorer') then
  r.ShowConsoleMsg('MIDI Transformer appreciates the presence of the SWS extension (install from ReaPack)\n')
  canReveal = false
end

if not canStart then return end

dofile(r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8.5')

local scriptID = 'sockmonkey72_Transformer'

local ctx = r.ImGui_CreateContext(scriptID)
r.ImGui_SetConfigVar(ctx, r.ImGui_ConfigVar_DockingWithShift(), 1)

local IMAGEBUTTON_SIZE = 13
local GearImage = r.ImGui_CreateImage(debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'Transformer/icons/' .. 'gear_40031.png')
if GearImage then r.ImGui_Attach(ctx, GearImage) end
local UndoImage = r.ImGui_CreateImage(debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'Transformer/icons/' .. 'left-arrow_9144323.png')
if UndoImage then r.ImGui_Attach(ctx, UndoImage) end
local RedoImage = r.ImGui_CreateImage(debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'Transformer/icons/' .. 'right-arrow_9144322.png')
if RedoImage then r.ImGui_Attach(ctx, RedoImage) end

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local showConsoles = false

local viewPort

local presetPath = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]
presetPath = presetPath:gsub('(.*[/\\]).*[/\\]', '%1Transformer Presets')

-- local presetPath = r.GetResourcePath() .. '/Scripts/Transformer Presets'
local scriptPrefix = 'Xform_'
local scriptPrefix_Empty = '<no prefix>'
local presetExt = '.tfmrPreset'
local presetSubPath
local restoreLastState = false

local CANONICAL_FONTSIZE_LARGE = 13
local FONTSIZE_LARGE = 13
local FONTSIZE_SMALL = 11
local FONTSIZE_SMALLER = 9
local DEFAULT_WIDTH = 68 * FONTSIZE_LARGE
local DEFAULT_HEIGHT = 40 * FONTSIZE_LARGE
local DEFAULT_ITEM_WIDTH = 70

local winHeight

local canonicalFont = r.ImGui_CreateFont(fontStyle, CANONICAL_FONTSIZE_LARGE)
r.ImGui_Attach(ctx, canonicalFont)

local inputFlag = r.ImGui_InputTextFlags_AutoSelectAll()

local PAREN_COLUMN_WIDTH = 20

local windowInfo
local fontInfo

local canonicalFontWidth

local currentFontWidth
local currentFrameHeight
local currentFrameHeightEx
local framePaddingX, framePaddingY

local updateItemBoundsOnEdit = true

local canvasScale = 1.0
local fontWidScale = 1.0

local function scaled(num)
  return num * canvasScale * fontWidScale
end

local DEFAULT_TITLEBAR_TEXT = 'Transformer'
local titleBarText = DEFAULT_TITLEBAR_TEXT
local focusKeyboardHere

local disabledAutoOverlap = false
local dockID = 0

local findConsoleText = ''
local actionConsoleText = ''

local presetTable = {}
local presetFolders = {}
local presetLabel = ''
local presetInputVisible = false
local presetInputDoesScript = false
local presetNotesBuffer = ''
local presetNotesViewEditor = false
local justChanged = false
local filterPresetsBuffer = ''
local folderNameTextBuffer = ''
local inNewFolderDialog = false
local newFolderParentPath = ''

local scriptWritesMainContext = true
local scriptWritesMIDIContexts = true
local scriptIgnoreSelectionInArrangeView = true
local refocusField = false
local refocusOnNextIteration = false

local presetNameTextBuffer = ''
local inOKDialog = false
local statusMsg = ''
local statusTime = nil
local statusContext = 0

local findParserError = ''

local refocusInput = false

local metricLastUnit = 3 -- 1/16 in findMetricGridParam1Entries
local musicalLastUnit = 3 -- 1/16 in findMetricGridParam1Entries
local metricLastBarRestart = false

local isClosing = false

local lastSelectedRowType
local selectedFindRow = 0
local selectedActionRow = 0

local showTimeFormatColumn = false

local defaultFindRow
local defaultActionRow

local inTextInput = false

-- should be global
NewHasTable = false

-- local focuswait
-- local wantsRecede -- = tonumber(r.GetExtState('sm72_CreateCrossfade', 'ConfigWantsRecede'))
-- wantsRecede = (not wantsRecede or wantsRecede ~= 0) and 1 or 0

-- local function reFocus()
--   focuswait = 5
-- end

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

local function doUpdate(action)
  local updateState = tx.update(action, restoreLastState)
  if updateState then
    local lastState = {
      state = updateState,
      presetSubPath = presetSubPath,
      presetName = presetNameTextBuffer
    }
    r.SetExtState(scriptID, 'lastState', base64encode(serialize(lastState)), true)
  end
end

local function doFindUpdate()
  doUpdate()
end

local function doActionUpdate()
  doUpdate(true)
end

local bitFieldCallback = r.ImGui_CreateFunctionFromEEL([[
  (EventChar < '0' || EventChar > '9') ? EventChar = 0
    : EventChar != '0' ? EventChar = '1'
    : EventChar = '0';
]])

local numbersOnlyCallback = r.ImGui_CreateFunctionFromEEL([[
  (EventChar < '0' || EventChar > '9') && EventChar != '-' ? EventChar = 0;
]])

local numbersOrNoteNameCallback = r.ImGui_CreateFunctionFromEEL([[
  (EventChar < '0' || EventChar > '9')
  && EventChar != '-'
  && !(EventChar >= 'A' && EventChar <= 'G')
  && !(EventChar >= 'a' && EventChar <= 'g')
  && EventChar != '#'
  ? EventChar = 0;
]])

local timeFormatOnlyCallback = r.ImGui_CreateFunctionFromEEL([[
  (EventChar < '0' || EventChar > '9')
    && EventChar != '-'
    && EventChar != ':'
    && EventChar != '.'
    && EventChar != 't'
  ? EventChar = 0;
]])

r.ImGui_Attach(ctx, bitFieldCallback)
r.ImGui_Attach(ctx, numbersOnlyCallback)
r.ImGui_Attach(ctx, numbersOrNoteNameCallback)
r.ImGui_Attach(ctx, timeFormatOnlyCallback)

local function positionModalWindow(yOff, yScale)
  local winWid = 4 * DEFAULT_ITEM_WIDTH * canvasScale
  local winHgt = currentFrameHeight * (5 * (yScale and yScale or 1))
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

local function addFindRow(idx, row)
  local findRowTable = tx.findRowTable()
  idx = (idx and idx ~= 0) and idx or #findRowTable+1

  if not row then
    if defaultFindRow then
      if tx.processFindMacro(defaultFindRow) then
        selectedFindRow = idx
        lastSelectedRowType = 0 -- Find
        return
      else
        defaultFindRow = ''
      end
    end

    row = tx.FindRow()
    for k, v in ipairs(tx.findTargetEntries) do
      if v.notation == '$type' then
        row.targetEntry = k
        break
      end
    end
  end

  table.insert(findRowTable, idx, row)
  selectedFindRow = idx
  lastSelectedRowType = 0 -- Find
  doFindUpdate()
end

local function removeFindRow()
  local findRowTable = tx.findRowTable()
  if selectedFindRow ~= 0 then
    table.remove(findRowTable, selectedFindRow) -- shifts
    selectedFindRow = selectedFindRow <= #findRowTable and selectedFindRow or #findRowTable
    doFindUpdate()
  end
end

-- TODO: move these to Lib or Extra
local function setupRowFormat(row, condOpTab)
  local isFind = row:is_a(tx.FindRow)

  local target = isFind and tx.findTargetEntries[row.targetEntry] or tx.actionTargetEntries[row.targetEntry]
  local condOp = condOpTab[isFind and row.conditionEntry or row.operationEntry]
  local paramTypes = tx.getParamTypesForRow(row, target, condOp)
  local isEveryN = condOp.everyn
  local isNewMIDIEvent = condOp.newevent
  local isMetric = condOp.metricgrid or (condOp.split and condOp.split[1].metricgrid) -- metric/musical only allowed as param1
  local isMusical = condOp.musical or (condOp.split and condOp.split[1].musical)
  local isParam3 = condOp.param3
  local isEventSelector = condOp.eventselector or (condOp.split and condOp.split[1].eventselector)

  -- ensure that there are no lingering tables
  row.mg = nil
  row.evn = nil
  row.nme = nil
  row.evsel = nil
  row.params[3] = nil

  for i = 1, 2 do
    if condOp.split and condOp.split[i].default then
      local menuEntry
      row.params[i].textEditorStr = tostring(condOp.split[i].default) -- hack
      if paramTypes[i] == tx.PARAM_TYPE_MENU then
        menuEntry = tonumber(row.params[i].textEditorStr)
      end
      row.params[i].menuEntry = menuEntry and menuEntry or 1
    else
      row.params[i].textEditorStr = '0'
      row.params[i].menuEntry = 1
    end
    row.params[i].percentVal = nil
    row.params[i].editorType = nil
  end

  if isMetric or isMusical then
    local data = {}
    data.isMetric = isFind and isMetric or false
    data.metricLastUnit = metricLastUnit
    data.musicalLastUnit = musicalLastUnit
    data.metricLastBarRestart = metricLastBarRestart
    tx.makeDefaultMetricGrid(row, data)
    if row.mg then row.mg.showswing = condOp.showswing or (condOp.split and condOp.split[1].showswing) end
  elseif isEveryN then
    tx.makeDefaultEveryN(row)
  elseif isNewMIDIEvent then
    tx.makeDefaultNewMIDIEvent(row)
  elseif isParam3 then
    tx.makeParam3(row)
  elseif isEventSelector then
    tx.makeDefaultEventSelector(row)
  end

  local p1 = tx.DEFAULT_TIMEFORMAT_STRING
  local p2 = tx.DEFAULT_TIMEFORMAT_STRING

  if target.notation == '$length' then
    p1 = tx.DEFAULT_LENGTHFORMAT_STRING
    p2 = tx.DEFAULT_LENGTHFORMAT_STRING
  end

  if paramTypes[1] == tx.PARAM_TYPE_TIMEDUR then p1 = tx.DEFAULT_LENGTHFORMAT_STRING end
  if paramTypes[2] == tx.PARAM_TYPE_TIMEDUR then p2 = tx.DEFAULT_LENGTHFORMAT_STRING end

  row.params[1].timeFormatStr = p1
  row.params[2].timeFormatStr = p2
end

local function addActionRow(idx, row)
  local actionRowTable = tx.actionRowTable()
  idx = (idx and idx ~= 0) and idx or #actionRowTable+1

  if not row then
    if defaultActionRow then
      if tx.processActionMacro(defaultActionRow) then
        selectedActionRow = idx
        lastSelectedRowType = 1
        return
      else
        defaultActionRow = ''
      end
    end

    row = tx.ActionRow()
    setupRowFormat(row, tx.actionTabsFromTarget(row))
  end

  table.insert(actionRowTable, idx, row)
  selectedActionRow = idx
  lastSelectedRowType = 1
  doActionUpdate()
end

local function removeActionRow()
  local actionRowTable = tx.actionRowTable()
  if selectedActionRow ~= 0 then
    table.remove(actionRowTable, selectedActionRow) -- shifts
    selectedActionRow = selectedActionRow <= #actionRowTable and selectedActionRow or #actionRowTable
    lastSelectedRowType = 1
    doActionUpdate()
  end
end

local function check14Bit(paramType)
  local has14bit = false
  local hasOther = false
  if paramType == tx.PARAM_TYPE_INTEDITOR then
    local hasTable, fresh = tx.getHasTable()
    has14bit = hasTable[0xE0] and true or false
    hasOther = (hasTable[0x90] or hasTable[0xA0] or hasTable[0xB0] or hasTable[0xD0] or hasTable[0xF0]) and true or false
    if fresh then NewHasTable = true end
  end
  return has14bit, hasOther
end

local function overrideEditorType(row, target, condOp, paramTypes, idx)
  local has14bit, hasOther = check14Bit(paramTypes[idx])
  if condOp.bitfield or (condOp.split and condOp.split[idx].bitfield) then
    tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_BITFIELD)
  elseif not (paramTypes[idx] == tx.PARAM_TYPE_INTEDITOR or paramTypes[idx] == tx.PARAM_TYPE_FLOATEDITOR)
    or (condOp.norange or (condOp.split and condOp.split[idx].norange))
    or (condOp.nooverride or (condOp.split and condOp.split[idx].nooverride))
  then
    tx.setEditorTypeForRow(row, idx, nil)
  elseif target.notation == '$velocity' or target.notation == '$relvel' then
    if condOp.bipolar or (condOp.split and condOp.split[idx].bipolar) then
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT_BIPOLAR)
    elseif target.notation == '$velocity' and not condOp.fullrange then
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT_NOZERO)
    else
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT)
    end
  elseif has14bit then
    if condOp.bipolar or (condOp.split and condOp.split[idx].bipolar) then
      tx.setEditorTypeForRow(row, idx, hasOther and tx.EDITOR_TYPE_PERCENT_BIPOLAR or tx.EDITOR_TYPE_PITCHBEND_BIPOLAR)
    else
      tx.setEditorTypeForRow(row, idx, hasOther and tx.EDITOR_TYPE_PERCENT or tx.EDITOR_TYPE_PITCHBEND)
    end
  elseif target.notation ~= '$position'
    and target.notation ~= '$length'
    and target.notation ~= '$channel'
  then
    if condOp.bipolar or (condOp.split and condOp.split[idx].bipolar) then
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT_BIPOLAR)
    else
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT)
    end
  else
    tx.setEditorTypeForRow(row, idx, nil)
  end
end

local function overrideEditorTypeForAllRows()
  local rows = tx.findRowTable()
  for _, row in ipairs(rows) do
    local _, _, _, currentFindTarget, currentFindCondition = tx.findTabsFromTarget(row)
    local paramTypes = tx.getParamTypesForRow(row, currentFindTarget, currentFindCondition)
    overrideEditorType(row, currentFindTarget, currentFindCondition, paramTypes, 1)
    overrideEditorType(row, currentFindTarget, currentFindCondition, paramTypes, 2)
    if currentFindCondition.param3 then
      overrideEditorType(row, currentFindTarget, currentFindCondition, paramTypes, 3)
    end
  end
  rows = tx.actionRowTable()
  for _, row in ipairs(rows) do
    local _, _, _, currentActionTarget, currentActionOperation = tx.actionTabsFromTarget(row)
    local paramTypes = tx.getParamTypesForRow(row, currentActionTarget, currentActionOperation)
    overrideEditorType(row, currentActionTarget, currentActionOperation, paramTypes, 1)
    overrideEditorType(row, currentActionTarget, currentActionOperation, paramTypes, 2)
    if currentActionOperation.param3 then
      overrideEditorType(row, currentActionTarget, currentActionOperation, paramTypes, 3)
    end
  end
end

local function handleExtState()
  local state

  state = r.GetExtState(scriptID, 'defaultFindRow')
  if isValidString(state) then
    defaultFindRow = state
  end

  state = r.GetExtState(scriptID, 'defaultActionRow')
  if isValidString(state) then
    defaultActionRow = state
  end

  state = r.GetExtState(scriptID, 'scriptWritesMainContext')
  if isValidString(state) then
    scriptWritesMainContext = tonumber(state) == 1 and true or false
  end

  state = r.GetExtState(scriptID, 'scriptWritesMIDIContexts')
  if isValidString(state) then
    scriptWritesMIDIContexts = tonumber(state) == 1 and true or false
  end

  state = r.GetExtState(scriptID, 'updateItemBoundsOnEdit')
  if isValidString(state) then
    updateItemBoundsOnEdit = state == '1' and true or false
    tx.setUpdateItemBoundsOnEdit(updateItemBoundsOnEdit)
  end

  if r.HasExtState(scriptID, 'scriptPrefix') then
    state = r.GetExtState(scriptID, 'scriptPrefix')
    scriptPrefix = (state and state ~= scriptPrefix_Empty) and state or ''
  end

  state = r.GetExtState(scriptID, 'restoreLastState')
  if isValidString(state) then
    restoreLastState = tonumber(state) == 1 and true or false
    if restoreLastState then
      state = r.GetExtState(scriptID, 'lastState')
      if isValidString(state) then
        local presetStateStr = base64decode(state)
        if isValidString(presetStateStr) then
          local lastState = deserialize(presetStateStr)
          if lastState then
            if lastState.state then
              presetNameTextBuffer = lastState.presetName
              if dirExists(lastState.presetSubPath) then presetSubPath = lastState.presetSubPath end
              presetNotesBuffer = tx.loadPresetFromTable(lastState.state)
              overrideEditorTypeForAllRows()
              doActionUpdate()
            end
          end
        end
      end
    end
  end
end

local function prepRandomShit()
  handleExtState()
end

local function gooseAutoOverlap()
  -- r.SetToggleCommandState(sectionID, 40681, 0) -- this doesn't work
  r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40681) -- but this does
  disabledAutoOverlap = not disabledAutoOverlap
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
  FONTSIZE_SMALLER = math.floor(baseFontSize * (9/13))
  fontInfo.largeDefaultSize = FONTSIZE_LARGE
  fontInfo.smallDefaultSize = FONTSIZE_SMALL
  fontInfo.smallerDefaultSize = FONTSIZE_SMALLER

  windowInfo.defaultWidth = 68 * fontInfo.largeDefaultSize
  windowInfo.defaultHeight = 40 * fontInfo.smallDefaultSize

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
    large = r.ImGui_CreateFont(fontStyle, FONTSIZE_LARGE), largeSize = FONTSIZE_LARGE, largeDefaultSize = FONTSIZE_LARGE,
    small = r.ImGui_CreateFont(fontStyle, FONTSIZE_SMALL), smallSize = FONTSIZE_SMALL, smallDefaultSize = FONTSIZE_SMALL,
    smaller = r.ImGui_CreateFont(fontStyle, FONTSIZE_SMALLER), smallerSize = FONTSIZE_SMALLER, smallerDefaultSize = FONTSIZE_SMALLER
  }
  r.ImGui_Attach(ctx, fontInfo.large)
  r.ImGui_Attach(ctx, fontInfo.small)
  r.ImGui_Attach(ctx, fontInfo.smaller)

  processBaseFontUpdate(tonumber(r.GetExtState(scriptID, 'baseFont')))
end

local function moveFindRowUp()
  local index = selectedFindRow
  if index > 1 then
    local rows = tx.findRowTable()
    local tmp = rows[index - 1]
    rows[index - 1] = rows[index]
    rows[index] = tmp
    selectedFindRow = index - 1
    doFindUpdate()
  end
end

local function moveFindRowDown()
  local index = selectedFindRow
  local rows = tx.findRowTable()
  if index < #rows then
    local tmp = rows[index + 1]
    rows[index + 1] = rows[index]
    rows[index] = tmp
    selectedFindRow = index + 1
    doFindUpdate()
  end
end

local function moveActionRowUp()
  local index = selectedActionRow
  if index > 1 then
    local rows = tx.actionRowTable()
    local tmp = rows[index - 1]
    rows[index - 1] = rows[index]
    rows[index] = tmp
    selectedActionRow = index - 1
    doActionUpdate()
  end
end

local function moveActionRowDown()
  local index = selectedActionRow
  local rows = tx.actionRowTable()
  if index < #rows then
    local tmp = rows[index + 1]
    rows[index + 1] = rows[index]
    rows[index] = tmp
    selectedActionRow = index + 1
    doActionUpdate()
  end
end

local function enableDisableFindRow()
  local index = selectedFindRow
  local rows = tx.findRowTable()
  if index > 0 and index <= #rows then
    rows[index].disabled = not rows[index].disabled and true or false
    doFindUpdate()
  end
end

local function enableDisableActionRow()
  local index = selectedActionRow
  local rows = tx.actionRowTable()
  if index > 0 and index <= #rows then
    rows[index].disabled = not rows[index].disabled and true or false
    doActionUpdate()
  end
end

local function setPresetNotesBuffer(buf)
  presetNotesBuffer = buf
  tx.setPresetNotesBuffer(presetNotesBuffer)
end

local function endPresetLoad(pLabel, notes, ignoreSelectInArrange)
  overrideEditorTypeForAllRows()
  presetNameTextBuffer = pLabel
  setPresetNotesBuffer(notes and notes or '')
  scriptIgnoreSelectionInArrangeView = ignoreSelectInArrange
  doActionUpdate()
end

-----------------------------------------------------------------------------
-------------------------------- SHORTCUTS ----------------------------------

local function checkShortcuts()
  if not r.ImGui_IsWindowFocused(ctx, r.ImGui_FocusedFlags_RootAndChildWindows()) or r.ImGui_IsAnyItemActive(ctx) then return end

  -- attempts to suss out the keyboard section focus fail for various reasons
  -- the amount of code required to check what the user clicks on when the script
  -- is running in the background is not commensurate to the task at hand, and it
  -- breaks if REAPER was in the background and then re-activated. anyway, to hell with it.
  -- I've asked for a new API to get the current section focus, if that shows up, can revisit this.

  -- fallback to old style, selective passthrough and that's it
  local keyMods = r.ImGui_GetKeyMods(ctx)
  local modKey = keyMods == r.ImGui_Mod_Shortcut()
  local modShiftKey = keyMods == r.ImGui_Mod_Shortcut() + r.ImGui_Mod_Shift()
  local noMod = keyMods == 0

  local active = r.MIDIEditor_GetActive()
  active = active and active or 0

  if modKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then -- undo
    if active ~= 0 then
      r.MIDIEditor_OnCommand(active, 40013)
    else
      r.Main_OnCommandEx(40029, -1, 0)
    end
  elseif modShiftKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then -- redo
    if active ~= 0 then
      r.MIDIEditor_OnCommand(active, 40014)
    else
      r.Main_OnCommandEx(40030, -1, 0)
    end
  elseif noMod and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Space()) then -- play/pause
    if active ~= 0 then
      r.MIDIEditor_OnCommand(active, 40016)
    else
      r.Main_OnCommandEx(40073, -1, 0)
    end
  end
end

local function handleKeys(handledEscape)
  -- note that the mod is only captured if the window is explicitly focused
  -- with a click. not sure how to fix this yet. TODO
  -- local mods = r.ImGui_GetKeyMods(ctx)
  -- local shiftdown = mods & r.ImGui_Mod_Shift() ~= 0

  -- current 'fix' is using the JS extension
  -- local mods = r.JS_Mouse_GetState(24) -- shift key
  -- local shiftdown = mods & 8 ~= 0
  -- local optdown = mods & 16 ~= 0
  -- local PPQCent = math.floor(PPQ * 0.01) -- for BBU conversion

  -- escape key kills our arrow key focus
  if not handledEscape and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
    if focusKeyboardHere then focusKeyboardHere = nil
    else
      isClosing = true
      return
    end
  end

  local handledKey = false

  if not inTextInput
    and not r.ImGui_IsPopupOpen(ctx, '', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel())
    and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Backspace())
  then
    handledKey = true
    if lastSelectedRowType == 0 then removeFindRow()
    elseif lastSelectedRowType == 1 then removeActionRow()
    end
  end

  if not inTextInput and r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_Shortcut() then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_UpArrow()) then
      handledKey = true
      if lastSelectedRowType == 0 then
        moveFindRowUp()
      elseif lastSelectedRowType == 1 then
        moveActionRowUp()
      end
    elseif r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_DownArrow()) then
      handledKey = true
      if lastSelectedRowType == 0 then
        moveFindRowDown()
      elseif lastSelectedRowType == 1 then
        moveActionRowDown()
      end
    elseif r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_K()) then
      handledKey = true
      if lastSelectedRowType == 0 then
        enableDisableFindRow()
      else
        enableDisableActionRow()
      end
    elseif r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter()) then
      handledKey = true
      tx.processAction(true)
    end
  end

  if not handledKey then
    checkShortcuts()
  end
end


-----------------------------------------------------------------------------
-------------------------------- THE GUTS -----------------------------------

local ppqToTime -- forward declaration to avoid vs.code warning

local function windowFn()

  -- if wantsRecede ~= 0 and focuswait then
  --   focuswait = focuswait - 1
  --   if focuswait == 0 then
  --     r.SetCursorContext(0, nil)
  --     focuswait = nil
  --   end
  -- end

  -- if r.ImGui_IsMouseHoveringRect(ctx, windowInfo.left, windowInfo.top, windowInfo.left + windowInfo.width, windowInfo.top + windowInfo.height) then
  --   reFocus()
  -- else
  --   if not focuswait then focuswait = 5 end
  -- end

  ---------------------------------------------------------------------------
  --------------------------- BUNCH OF VARIABLES ----------------------------

  local vx, vy = r.ImGui_GetWindowPos(ctx)
  local handledEscape = false

  local hoverCol = r.ImGui_GetStyleColor(ctx, r.ImGui_Col_HeaderHovered())
  local hoverAlphaCol = (hoverCol &~ 0xFF) | 0x3F
  local activeCol = r.ImGui_GetStyleColor(ctx, r.ImGui_Col_HeaderActive())
  local activeAlphaCol = (activeCol &~ 0xFF) | 0x7F

  framePaddingX, framePaddingY = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE FUNS -----------------------------

  local currentRect = {}

  local gearPopupLeft

  local function MakeClearAll()
    r.ImGui_SameLine(ctx)
    r.ImGui_SetCursorPosX(ctx, gearPopupLeft - (DEFAULT_ITEM_WIDTH * 2) - (10 * canvasScale))
    r.ImGui_Button(ctx, 'Clear All', DEFAULT_ITEM_WIDTH * 1.5)
    if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
        tx.suspendUndo()
        tx.clearFindRows()
        selectedFindRow = 0
        tx.setCurrentFindScope(3)
        tx.setFindScopeFlags(0)
        tx.clearFindPostProcessingInfo()
        tx.clearActionRows()
        selectedActionRow = 0
        tx.setCurrentActionScope(1)
        tx.setCurrentActionScopeFlags(1)
        presetLabel = ''
        presetNotesBuffer = ''
        tx.resumeUndo()
        doActionUpdate()
    end
  end

  local function MakeUndoRedo()
    r.ImGui_SameLine(ctx)
    r.ImGui_SetCursorPosX(ctx, gearPopupLeft - (DEFAULT_ITEM_WIDTH * 1) - (10 * canvasScale))

    local ibSize = FONTSIZE_LARGE * canvasScale

    gearPopupLeft = r.ImGui_GetCursorPosX(ctx)

    local hasUndo = tx.hasUndoSteps()
    local hasRedo = tx.hasRedoSteps()

    if not hasUndo then
      r.ImGui_BeginDisabled(ctx)
    end
    if r.ImGui_ImageButton(ctx, 'undo', UndoImage, ibSize, ibSize) then
      local undoState = tx.popUndo()
      if undoState then
        presetNotesBuffer = tx.loadPresetFromTable(undoState)
        overrideEditorTypeForAllRows()
        doActionUpdate()
      end
    end
    if not hasUndo then
      r.ImGui_EndDisabled(ctx)
    end

    r.ImGui_SameLine(ctx)

    if not hasRedo then
      r.ImGui_BeginDisabled(ctx)
    end
    if r.ImGui_ImageButton(ctx, 'redo', RedoImage, ibSize, ibSize) then
      local redoState = tx.popRedo()
      if redoState then
        presetNotesBuffer = tx.loadPresetFromTable(redoState)
        overrideEditorTypeForAllRows()
        doActionUpdate()
      end
    end
    if not hasRedo then
      r.ImGui_EndDisabled(ctx)
    end
  end

  local function MakeGearPopup()
    r.ImGui_SameLine(ctx)

    local ibSize = FONTSIZE_LARGE * canvasScale

    local x = r.ImGui_GetContentRegionMax(ctx)
    local frame_padding_x = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
    r.ImGui_SetCursorPosX(ctx, x - ibSize - (frame_padding_x * 2))

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

    local wantsPop = false
    gearPopupLeft = r.ImGui_GetCursorPosX(ctx)
    if r.ImGui_ImageButton(ctx, 'gear', GearImage, ibSize, ibSize) then
      wantsPop = true
    end

    if wantsPop then
      r.ImGui_OpenPopup(ctx, 'gear menu')
    end

    if r.ImGui_BeginPopup(ctx, 'gear menu', r.ImGui_WindowFlags_NoMove()) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then -- and not IsOKDialogOpen() then
        r.ImGui_CloseCurrentPopup(ctx)
        handledEscape = true
      end
      local rv, selected, v

      r.ImGui_BeginDisabled(ctx)
      r.ImGui_Text(ctx, 'Version ' .. versionStr)
      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_EndDisabled(ctx)

      -----------------------------------------------------------------------------
      ---------------------------------- BASE FONT --------------------------------

      r.ImGui_Spacing(ctx)

      r.ImGui_SetNextItemWidth(ctx, (DEFAULT_ITEM_WIDTH / 2) * canvasScale)
      rv, v = r.ImGui_InputText(ctx, 'Base Font Size', FONTSIZE_LARGE, inputFlag
                                                                     | r.ImGui_InputTextFlags_EnterReturnsTrue()
                                                                     | r.ImGui_InputTextFlags_CharsDecimal())
      if rv then
        v = processBaseFontUpdate(tonumber(v))
        r.SetExtState(scriptID, 'baseFont', tostring(v), true)
        r.ImGui_CloseCurrentPopup(ctx)
      end

      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)

      r.ImGui_Spacing(ctx)
      rv, v = r.ImGui_Checkbox(ctx, 'Update item bounds on edit', updateItemBoundsOnEdit)
      if rv then
        updateItemBoundsOnEdit = v
        r.SetExtState(scriptID, 'updateItemBoundsOnEdit', v and '1' or '0', true)
        tx.setUpdateItemBoundsOnEdit(updateItemBoundsOnEdit)
        -- r.ImGui_CloseCurrentPopup(ctx) -- feels weird if it closes, feels weird if it doesn't
      end

      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)

      r.ImGui_Spacing(ctx)
      r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 1.5)
      local defaultText = isValidString(scriptPrefix) and scriptPrefix or scriptPrefix_Empty
      rv, v = r.ImGui_InputText(ctx, 'Script Prefix', defaultText, inputFlag | r.ImGui_InputTextFlags_EnterReturnsTrue())
      if rv then
        scriptPrefix = v == scriptPrefix_Empty and '' or v
        r.SetExtState(scriptID, 'scriptPrefix', v, true)
        r.ImGui_CloseCurrentPopup(ctx)
      end

      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)

      r.ImGui_Spacing(ctx)
      rv, v = r.ImGui_Checkbox(ctx, 'Restore Previous State on Startup', restoreLastState)
      if rv then
        restoreLastState = v
        r.SetExtState(scriptID, 'restoreLastState', v and '1' or '0', true)
        if restoreLastState then
          doFindUpdate()
        else
          r.DeleteExtState(scriptID, 'lastState', true)
        end
        -- r.ImGui_CloseCurrentPopup(ctx) -- feels weird if it closes, feels weird if it doesn't
      end
      r.ImGui_EndPopup(ctx)
    end
    r.ImGui_PopStyleColor(ctx)
  end

  local function updateCurrentRect()
    -- cache the positions to generate next box position
    currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
    currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
    currentRect.right = currentRect.right + scaled(20) -- add some spacing after the button
  end

  local function generateLabel(label)
    local ix, iy = currentRect.left, currentRect.top
    r.ImGui_PushFont(ctx, fontInfo.small)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFFEF)
    local tw, th = r.ImGui_CalcTextSize(ctx, label)
    local fp = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()) / 2
    local minx = ix + 2
    local miny = iy - r.ImGui_GetTextLineHeight(ctx) - 3
    r.ImGui_DrawList_AddRectFilled(r.ImGui_GetWindowDrawList(ctx), minx - fp, miny - fp, minx + tw + fp + 2, miny + th + fp + 1, 0xFFFFFF2F)
    minx = minx - vx
    miny = miny - vy
    r.ImGui_AlignTextToFramePadding(ctx)
    r.ImGui_SetCursorPos(ctx, minx + 1, miny - scaled(1.5))
    r.ImGui_Text(ctx, label)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopFont(ctx)
  end

  local function generateLabelOnLine(label, advance)
    local restoreY = r.ImGui_GetCursorPosY(ctx)
    if not advance then
      r.ImGui_SameLine(ctx)
    end
    updateCurrentRect()
    local oldX, oldY = r.ImGui_GetCursorPos(ctx)
    generateLabel(label)
    r.ImGui_SetCursorPosY(ctx, restoreY)
  end

  local function completionKeyPress()
    return r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_None()
      and (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
        or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Tab())
        or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter()))
  end

  local function kbdEntryIsCompleted(retval)
    local complete = false
    local withKey = false
    if retval then
      if completionKeyPress() then
        complete = true
        withKey = true
      end
    end
    if not complete and not refocusField and r.ImGui_IsItemDeactivated(ctx) then
      complete = true
      if completionKeyPress() then
        withKey = true
      end
    end
    return complete, withKey
  end

  ---------------------------------------------------------------------------
  ------------------------------ TITLEBAR TEXT ------------------------------

  titleBarText = DEFAULT_TITLEBAR_TEXT

  ---------------------------------------------------------------------------
  --------------------------------- UTILITIES -------------------------------

  local function ensureNumString(str, range, floor)
    local num = tonumber(str)
    if not num then num = 0 end
    if range then
      if range[1] and num < range[1] then num = range[1] end
      if range[2] and num > range[2] then num = range[2] end
    end
    if floor then num = math.floor(num + 0.5) end
    return tostring(num)
  end

  local function handleNewFolderCreationDialog(title, text)
    local rv = false
    local doOK = false

    r.ImGui_PushFont(ctx, fontInfo.large)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

    if inNewFolderDialog then
      positionModalWindow(r.ImGui_GetFrameHeight(ctx) / 2, 1.2)
      r.ImGui_OpenPopup(ctx, title)
    elseif folderNameTextBuffer:len() ~= 0
      and (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
        or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter()))
    then
      rv = true
      doOK = true
    end

    if r.ImGui_BeginPopupModal(ctx, title, true, r.ImGui_WindowFlags_TopMost() | r.ImGui_WindowFlags_NoMove()) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        r.ImGui_CloseCurrentPopup(ctx)
        handledEscape = true
        refocusInput = true
      end
      if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
      r.ImGui_Spacing(ctx)
      r.ImGui_Text(ctx, text)
      r.ImGui_Spacing(ctx)

      local retval, buf = r.ImGui_InputText(ctx, '##newfoldername', folderNameTextBuffer)
      folderNameTextBuffer = buf
      local complete, withKeys = kbdEntryIsCompleted(retval)
      if complete and withKeys then
        if folderNameTextBuffer:len() ~= 0 then
          doOK = true
        end
      end

      r.ImGui_Spacing(ctx)
      if r.ImGui_Button(ctx, 'Cancel') then
        r.ImGui_CloseCurrentPopup(ctx)
      end

      r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx, 'OK') or doOK then
        rv = true
        r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_SetItemDefaultFocus(ctx)

      r.ImGui_EndPopup(ctx)
    end
    r.ImGui_PopFont(ctx)
    r.ImGui_PopStyleColor(ctx)

    inNewFolderDialog = false

    return rv, folderNameTextBuffer
  end

  local function generateFindPostProcessingPopup()
    if r.ImGui_BeginPopup(ctx, 'findPostPocessingMenu', r.ImGui_WindowFlags_NoMove()) then
      local deactivated
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        r.ImGui_CloseCurrentPopup(ctx)
        handledEscape = true
      end
      local ppInfo = tx.getFindPostProcessingInfo()
      local ppFlags = ppInfo.flags
      local rv, sel, buf
      local changed

      rv, sel = r.ImGui_Checkbox(ctx, 'Retain first', ppFlags & tx.FIND_POSTPROCESSING_FLAG_FIRSTEVENT ~= 0)
      if rv then
        ppFlags = sel and (ppFlags | tx.FIND_POSTPROCESSING_FLAG_FIRSTEVENT) or (ppFlags & ~tx.FIND_POSTPROCESSING_FLAG_FIRSTEVENT)
        changed = true
      end
      r.ImGui_SameLine(ctx)
      r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
      rv, buf = r.ImGui_InputText(ctx, 'events beginning at offset##frontcount', ppInfo.front.count,
        r.ImGui_InputTextFlags_CallbackCharFilter(), numbersOnlyCallback)
      if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
      if kbdEntryIsCompleted(rv) then
        ppInfo.front.count = tonumber(buf)
        if not ppInfo.front.count or ppInfo.front.count < 1 then ppInfo.front.count = 0 end
        changed = true
      end
      r.ImGui_SameLine(ctx)
      r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
      rv, buf = r.ImGui_InputText(ctx, 'from front##frontoffset', ppInfo.front.offset,
        r.ImGui_InputTextFlags_CallbackCharFilter(), numbersOnlyCallback)
      if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
      if kbdEntryIsCompleted(rv) then
        ppInfo.front.offset = tonumber(buf)
        if not ppInfo.front.offset then ppInfo.front.offset = 0 end
        changed = true
      end

      rv, sel = r.ImGui_Checkbox(ctx, 'Retain last', ppFlags & tx.FIND_POSTPROCESSING_FLAG_LASTEVENT ~= 0)
      if rv then
        ppFlags = sel and (ppFlags | tx.FIND_POSTPROCESSING_FLAG_LASTEVENT) or (ppFlags & ~tx.FIND_POSTPROCESSING_FLAG_LASTEVENT)
        changed = true
      end
      r.ImGui_SameLine(ctx)
      r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
      rv, buf = r.ImGui_InputText(ctx, 'events beginning at offset##backcount', ppInfo.back.count,
        r.ImGui_InputTextFlags_CallbackCharFilter(), numbersOnlyCallback)
      if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
      if kbdEntryIsCompleted(rv) then
        ppInfo.back.count = tonumber(buf)
        if not ppInfo.back.count or ppInfo.back.count < 1 then ppInfo.back.count = 1 end
        changed = true
      end
      r.ImGui_SameLine(ctx)
      r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
      rv, buf = r.ImGui_InputText(ctx, 'from end##backoffset', ppInfo.back.offset,
        r.ImGui_InputTextFlags_CallbackCharFilter(), numbersOnlyCallback)
      if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
      if kbdEntryIsCompleted(rv) then
        ppInfo.back.offset = tonumber(buf)
        if not ppInfo.back.offset then ppInfo.back.offset = 0 end
        changed = true
      end

      if changed then
        ppInfo.flags = ppFlags
        tx.setFindPostProcessingInfo(ppInfo)
        doUpdate()
      end

      if not r.ImGui_IsAnyItemActive(ctx) and not deactivated then
        if completionKeyPress() then
          r.ImGui_CloseCurrentPopup(ctx)
        end
      end

      r.ImGui_EndPopup(ctx)
    end

    generateLabelOnLine('Post-Processing', true)
  end

  local function generatePresetMenu(source, path, lab, filter, onlyFolders)
    local mousePos = {}
    mousePos.x, mousePos.y = r.ImGui_GetMousePos(ctx)
    local windowRect = {}
    windowRect.left, windowRect.top = r.ImGui_GetWindowPos(ctx)
    windowRect.right, windowRect.bottom = r.ImGui_GetWindowSize(ctx)
    windowRect.right = windowRect.right + windowRect.left
    windowRect.bottom = windowRect.bottom + windowRect.top

    for i = 1, #source do
      local selectText = source[i].label
      if PresetMatches(source[i], filter, onlyFolders) then
        local saveX = r.ImGui_GetCursorPosX(ctx)
        r.ImGui_BeginGroup(ctx)

        local rv, selected

        if source[i].sub then
          if r.ImGui_BeginMenu(ctx, selectText) then
            generatePresetMenu(source[i].sub, path .. '/' .. selectText, selectText, filter, onlyFolders)
            r.ImGui_EndMenu(ctx)
          end
        else
          rv, selected = r.ImGui_Selectable(ctx, selectText, false)
        end

        r.ImGui_SameLine(ctx)
        r.ImGui_SetCursorPosX(ctx, saveX) -- ugly, but the selectable needs info from the checkbox

        local _, itemTop = r.ImGui_GetItemRectMin(ctx)
        local _, itemBottom = r.ImGui_GetItemRectMax(ctx)
        local inVert = mousePos.y >= itemTop + framePaddingY and mousePos.y <= itemBottom - framePaddingY and mousePos.x >= windowRect.left and mousePos.x <= windowRect.right
        local srv = r.ImGui_Selectable(ctx, '##popup' .. (lab and lab or '') .. i .. 'Selectable', inVert, r.ImGui_SelectableFlags_AllowItemOverlap())

        r.ImGui_EndGroup(ctx)

        if rv or srv then
          if selected or srv then
            local filename = source[i].label .. presetExt
            local success, notes, ignoreSelectInArrange = tx.loadPreset(path .. '/' .. filename)
            if success then
              presetLabel = source[i].label
              endPresetLoad(presetLabel, notes, ignoreSelectInArrange)
            end
          end
          r.ImGui_CloseCurrentPopup(ctx)
        end
      end
    end
    if onlyFolders then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xCCCCFFCC)
      local rv, selected = r.ImGui_Selectable(ctx, 'Save presets here...', false)
      if rv and selected then
        presetSubPath = path ~= presetPath and path or nil
        doFindUpdate()
      end

      rv, selected = r.ImGui_Selectable(ctx, 'New folder here...', false)
      if rv and selected then
        inNewFolderDialog = true
        newFolderParentPath = path
      end

      r.ImGui_PopStyleColor(ctx)
    end
  end

  local function enumerateTransformerPresets(pPath, onlyFolders)
    local idx = 0
    local fnames = {}
    local fname

    r.EnumerateSubdirectories(pPath, -1)
    fname = r.EnumerateSubdirectories(pPath, idx)
    while fname do
      local entry = { label = fname }
      table.insert(fnames, entry)
      idx = idx + 1
      fname = r.EnumerateSubdirectories(pPath, idx)
    end

    for _, v in ipairs(fnames) do
      local newPath = pPath .. '/' .. v.label
      v.sub = enumerateTransformerPresets(newPath, onlyFolders)
    end

    if not onlyFolders then
      idx = 0
      r.EnumerateFiles(pPath, -1)
      fname = r.EnumerateFiles(pPath, idx)
      while fname do
        if fname:match('%' .. presetExt .. '$') then
          local entry = { label = fname:gsub('%' .. presetExt .. '$', '') }
          table.insert(fnames, entry)
        end
        idx = idx + 1
        fname = r.EnumerateFiles(pPath, idx)
      end
    end

    local sorted = {}
    for _, v in spairs(fnames, function (t, a, b) return string.lower(t[a].label) < string.lower(t[b].label) end) do
      table.insert(sorted, v)
    end
    return sorted
  end

  local mainValueLabel
  local subtypeValueLabel

  local function decorateTargetLabel(label)
    if label == 'Value 1' then
      label = label .. (isValidString(subtypeValueLabel) and ' (' .. subtypeValueLabel .. ')' or '')
    elseif label == 'Value 2' then
      label = label .. (isValidString(mainValueLabel) and ' (' .. mainValueLabel .. ')' or '')
    end
    return label
  end

  local dontCloseXPos

  local function createPopup(row, name, source, selEntry, fun, special, dontClose)
    if r.ImGui_BeginPopup(ctx, name, r.ImGui_WindowFlags_NoMove()) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        if r.ImGui_IsPopupOpen(ctx, name, r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
          r.ImGui_CloseCurrentPopup(ctx)
          handledEscape = true
        end
      end

      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)
      local numStyleCol = 2

      local windowRect = {}
      windowRect.left, windowRect.top = r.ImGui_GetWindowPos(ctx)
      windowRect.right, windowRect.bottom = r.ImGui_GetWindowSize(ctx)
      windowRect.right = windowRect.right + windowRect.left
      windowRect.bottom = windowRect.bottom + windowRect.top

      local listed = false
      if dontClose then
        if type(dontClose) == 'string' then
          r.ImGui_Text(ctx, dontClose)
          r.ImGui_SameLine(ctx)
          dontCloseXPos = r.ImGui_GetCursorPosX(ctx)
        end
        listed = r.ImGui_BeginListBox(ctx, '##wrapperBox', nil, currentFrameHeightEx * #source)
      end

      for i = 1, #source do
        local selectText = source[i].label
        local disabled = source[i].disable

        if disabled then r.ImGui_BeginDisabled(ctx) end

        if source.targetTable then
          selectText = decorateTargetLabel(selectText)
        end
        if not selEntry then selEntry = 1 end
        local selectable = selEntry == -1
        local rv
        if selectable then
          rv = r.ImGui_Selectable(ctx, selectText, selEntry == i and true or false)
        else
          rv = r.ImGui_MenuItem(ctx, selectText, nil, selEntry == i)
        end

        if disabled then r.ImGui_EndDisabled(ctx) end

        r.ImGui_Spacing(ctx)

        if rv then
          fun(i)
          if not dontClose or selEntry == i then
            r.ImGui_CloseCurrentPopup(ctx)
          end
        end
      end

      if listed then
        r.ImGui_EndListBox(ctx)
      end

      r.ImGui_PopStyleColor(ctx, numStyleCol)

      if special then special(fun, row, source, selEntry) end
      r.ImGui_EndPopup(ctx)
    end
  end

  ---------------------------------------------------------------------------
  ------------------------------- PRESET RECALL -----------------------------

  local function Spacing(half)
    local posy = r.ImGui_GetCursorPosY(ctx)
    r.ImGui_SetCursorPosY(ctx, posy + (currentFrameHeight / (half and 4 or 2)))
  end

  Spacing(true)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Button(ctx, 'Recall Preset...', DEFAULT_ITEM_WIDTH * 2)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    if not dirExists(presetPath) then r.RecursiveCreateDirectory(presetPath, 0) end
    presetTable = enumerateTransformerPresets(presetPath)
    r.ImGui_OpenPopup(ctx, 'openPresetMenu') -- defined far below
  end

  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, 0x00AAFFFF, presetLabel)

  ---------------------------------------------------------------------------
  ----------------------------------- GEAR ----------------------------------

  MakeGearPopup()
  MakeUndoRedo()
  MakeClearAll()
  ---------------------------------------------------------------------------
  --------------------------------- FIND ROWS -------------------------------

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x006655FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x008877FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x007766FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x006655FF)

  Spacing()
  r.ImGui_AlignTextToFramePadding(ctx)

  local optDown = false
  if r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_Alt() then
    optDown = true
  end

  r.ImGui_Button(ctx, 'Insert Criteria', DEFAULT_ITEM_WIDTH * 2)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    addFindRow()
  end

  r.ImGui_SameLine(ctx)
  local findButDisabled = (optDown and #tx.findRowTable() == 0) or (not optDown and selectedFindRow == 0)
  if findButDisabled then
    r.ImGui_BeginDisabled(ctx)
  end
  r.ImGui_Button(ctx, optDown and 'Clear All Criteria' or 'Remove Criteria', DEFAULT_ITEM_WIDTH * 2)
  if findButDisabled then
    r.ImGui_EndDisabled(ctx)
  end

  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    if optDown then
      tx.clearFindRows()
      selectedFindRow = 0
      doFindUpdate()
    else
      removeFindRow()
    end
  end

  local function rewriteNoteName(buf)
    if buf:match('[A-Ga-g][%-#b]*%d') then
      return tostring(mu.MIDI_NoteNameToNoteNumber(buf))
    end
    return buf
  end

  local function chanMsgToName(chanmsg)
    return chanmsg == 0x00 and 'Any'
      or chanmsg == 0x90 and 'Note'
      or chanmsg == 0xA0 and 'Poly Pressure'
      or chanmsg == 0xB0 and 'Controller'
      or chanmsg == 0xC0 and 'Program Change'
      or chanmsg == 0xD0 and 'Aftertouch'
      or chanmsg == 0xE0 and 'Pitch Bend'
      or chanmsg == 0xF0 and 'System Exclusive'
      or chanmsg == 0x100 and 'Text'
      or 'Unknown'
  end

  local function doHandleTableParam(row, target, condOp, paramType, editorType, index, flags, procFn)
    local isNote = tx.isANote(target, condOp)
    local floatFlags = r.ImGui_InputTextFlags_CharsDecimal() + r.ImGui_InputTextFlags_CharsNoBlank()

    -- TODO: cleanup these attributes & combinations
    local range, bipolar = tx.getRowParamRange(row, target, condOp, paramType, editorType, index)
    if NewHasTable then
      local strVal = row.params[index].textEditorStr
      if not (flags.isMetricOrMusical or flags.isBitField) then
        strVal = ensureNumString(row.params[index].textEditorStr, range, paramType == tx.PARAM_TYPE_INTEDITOR)
      end
      strVal = tx.handlePercentString(strVal, row, target, condOp, paramType, editorType, index, range, bipolar)
      row.params[index].textEditorStr = strVal
    end

    if isNote then r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75) end
    local retval, buf = r.ImGui_InputText(ctx, '##' .. 'param' .. index .. 'Edit',
      row.params[index].textEditorStr,
      flags.isFloat and floatFlags or r.ImGui_InputTextFlags_CallbackCharFilter(),
      flags.isFloat and nil or isNote and numbersOrNoteNameCallback or flags.isBitField and bitFieldCallback or numbersOnlyCallback)

    if kbdEntryIsCompleted(retval) then
      if isNote then
        buf = rewriteNoteName(buf)
      end
      tx.setRowParam(row, index, paramType, editorType, buf, range, condOp.literal and true or false)
      procFn()
      inTextInput = false
      row.dirty = true
    elseif retval then inTextInput = true
    end

    local deactivated = r.ImGui_IsItemDeactivated(ctx)

    -- note name support
    if isNote then
      if row.dirty or not row.params[index].noteName then
        local noteNum = tonumber(row.params[index].textEditorStr)
        if noteNum then
          row.params[index].noteName = mu.MIDI_NoteNumberToNoteName(noteNum)
        end
      else
        r.ImGui_SameLine(ctx)
        r.ImGui_AlignTextToFramePadding(ctx)
        r.ImGui_TextColored(ctx, 0x7FFFFFCF, '[' .. row.params[index].noteName .. ']')
      end
    else
      row.params[index].noteName = nil
    end

    local rangelabel = condOp.split and condOp.split[index].rangelabel or condOp.rangelabel and condOp.rangelabel[index]
    if rangelabel then
      r.ImGui_SameLine(ctx)
      r.ImGui_AlignTextToFramePadding(ctx)
      r.ImGui_TextColored(ctx, 0xFFFFFF7F, '(' .. rangelabel .. ')')
    elseif range then
      r.ImGui_SameLine(ctx)
      r.ImGui_AlignTextToFramePadding(ctx)
      r.ImGui_PushFont(ctx, fontInfo.small)
      if editorType == tx.EDITOR_TYPE_PERCENT
        or condOp.percent or (condOp.split and condOp.split[index].percent) -- hack
      then
        r.ImGui_TextColored(ctx, 0xFFFFFF7F, '%')
      elseif range and range[1] and range[2] then
        r.ImGui_TextColored(ctx, 0xFFFFFF7F, '(' .. range[1] .. ' - ' .. range[2] .. ')')
      end
      r.ImGui_PopFont(ctx)
    end

    return deactivated
  end

  local function handleTableParam(row, condOp, paramTab, paramType, index, procFn)
    local rv = false

    if paramType == tx.PARAM_TYPE_HIDDEN then return end

    local editorType = row.params[index].editorType
    local flags = {}
    flags.isMetricOrMusical = paramType == tx.PARAM_TYPE_METRICGRID or paramType == tx.PARAM_TYPE_MUSICAL
    flags.isEveryN = paramType == tx.PARAM_TYPE_EVERYN and row.evn
    flags.isBitField = editorType == tx.EDITOR_TYPE_BITFIELD
    flags.isFloat = (paramType == tx.PARAM_TYPE_FLOATEDITOR or editorType == tx.EDITOR_TYPE_PERCENT) and true or false
    flags.isNewMIDIEvent = paramType == tx.PARAM_TYPE_NEWMIDIEVENT
    flags.isParam3 = condOp.param3 and paramType ~= tx.PARAM_TYPE_MENU -- param3 exception -- make this nicer
    flags.isEventSelector = paramType == tx.PARAM_TYPE_EVENTSELECTOR

    if (flags.isMetricOrMusical and index == 1) -- special case, sorry
      or (flags.isEveryN and index == 1)
      or flags.isNewMIDIEvent
      or flags.isParam3
      or flags.isEventSelector
    then
      paramType = tx.PARAM_TYPE_MENU
    end

    if condOp.terms >= index then
      local targetTab = row:is_a(tx.FindRow) and tx.findTargetEntries or tx.actionTargetEntries
      local target = targetTab[row.targetEntry]

      if paramType == tx.PARAM_TYPE_MENU then
        local canOpen = (flags.isEveryN or flags.isParam3 or flags.isEventSelector) and true or #paramTab ~= 0
        local paramEntry = paramTab[row.params[index].menuEntry]
        local label =  #paramTab ~= 0 and paramEntry.label or '---'
        if flags.isEveryN then
          label = (row.evn.isBitField and '(b) ' or '') .. row.evn.textEditorStr .. (row.evn.offset ~= 0 and (' [' .. row.evn.offset .. ']') or '')
        elseif flags.isNewMIDIEvent then
          local isRel = row.nme.relmode and row.params[2].menuEntry ~= tx.NEWEVENT_POSITION_ATPOSITION
          local isRelNeg = isRel and row.nme.posText:sub(1,1) == '-'
          local posText = isRelNeg and row.nme.posText:sub(2) or row.nme.posText
          if index == 2 and (row.params[2].menuEntry == tx.NEWEVENT_POSITION_ATPOSITION or row.nme.relmode) then
             label = label .. (isRelNeg and ' - ' or isRel and ' + ' or ': ') .. posText
          elseif index == 1 then
            label = label .. ': ' .. row.nme.msg2 ..
              ((row.nme.chanmsg >= 0xC0 and row.nme.chanmsg < 0xE0)
                and ''
                or ('/' .. row.nme.msg3)) ..
              (row.nme.chanmsg ~= 0x90
                and ''
                or (' [' .. row.nme.durText .. ']'))
          end
        elseif flags.isParam3 and row.params[3] and row.params[3].menuLabel then
          label = row.params[3].menuLabel(row, target, condOp)
        elseif flags.isEventSelector then
          label = chanMsgToName(row.evsel.chanmsg) .. ' [' .. (row.evsel.channel == -1 and 'Any' or tostring(row.evsel.channel + 1)) .. ']'
          local useVal1 = row.evsel.chanmsg ~= 0x00 and row.evsel.chanmsg < 0xD0 and row.evsel.useval1
          if useVal1 then
            label = label .. ' ('
            .. (row.evsel.chanmsg == 0x90 and mu.MIDI_NoteNumberToNoteName(row.evsel.msg2) or tostring(row.evsel.msg2))
            .. ')'
          end
        end
        if flags.isMetricOrMusical and paramEntry.notation ~= '$grid' then
          local mgMods, mgReaSwing = tx.GetMetricGridModifiers(row.mg)
          if mgMods == tx.MG_GRID_TRIPLET then label = label .. 'T'
          elseif mgMods == tx.MG_GRID_DOTTED then label = label .. '.'
          elseif mgMods == tx.MG_GRID_SWING then label = label .. 'sw' .. (mgReaSwing and 'R' or '')
          end
        end
        r.ImGui_Button(ctx, label)
        if canOpen and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
          rv = true
          r.ImGui_OpenPopup(ctx, 'param' .. index .. 'Menu')
        end
      elseif paramType == tx.PARAM_TYPE_INTEDITOR
        or flags.isFloat
        or flags.isMetricOrMusical or flags.isBitField
        or editorType == tx.EDITOR_TYPE_PITCHBEND
        or editorType == tx.EDITOR_TYPE_PERCENT
      then
        r.ImGui_BeginGroup(ctx)

        doHandleTableParam(row, target, condOp, paramType, editorType, index, flags, procFn)

        r.ImGui_EndGroup(ctx)
        if r.ImGui_IsItemHovered(ctx) then
          if r.ImGui_IsMouseClicked(ctx, 0) then
            rv = true
          end
        end
      elseif paramType == tx.PARAM_TYPE_TIME or paramType == tx.PARAM_TYPE_TIMEDUR then
        r.ImGui_BeginGroup(ctx)
        local retval, buf = r.ImGui_InputText(ctx, '##' .. 'param' .. index .. 'Edit', row.params[index].timeFormatStr, r.ImGui_InputTextFlags_CallbackCharFilter(), timeFormatOnlyCallback)
        if kbdEntryIsCompleted(retval) then
          row.params[index].timeFormatStr = paramType == tx.PARAM_TYPE_TIMEDUR and tx.lengthFormatRebuf(buf) or tx.timeFormatRebuf(buf)
          procFn()
          inTextInput = false
        elseif retval then inTextInput = true
        end
        local rangelabel = condOp.split and condOp.split[index].rangelabel or condOp.rangelabel and condOp.rangelabel[index]
        if rangelabel then
          r.ImGui_SameLine(ctx)
          r.ImGui_AlignTextToFramePadding(ctx)
          r.ImGui_PushFont(ctx, fontInfo.small)
          r.ImGui_TextColored(ctx, 0xFFFFFF7F, '(' .. condOp.rangelabel[index] .. ')')
          r.ImGui_PopFont(ctx)
        end
        r.ImGui_EndGroup(ctx)
        if r.ImGui_IsItemHovered(ctx) then
          if r.ImGui_IsMouseClicked(ctx, 0) then
            rv = true
          end
        end
      end
    end
    return rv
  end

  if showConsoles then
    r.ImGui_SameLine(ctx)
    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 6)
    local fcrv, fcbuf = r.ImGui_InputText(ctx, '##findConsole', findConsoleText)
    if kbdEntryIsCompleted(fcrv) then
      findConsoleText = fcbuf
      tx.processFindMacro(findConsoleText)
      inTextInput = false
    elseif fcrv then inTextInput = true
    end

    generateLabelOnLine('Selection Criteria Console')
  end

  Spacing(true)
  r.ImGui_Separator(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + currentFrameHeight)

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE GEN ------------------------------

  local function handleValueLabels()
    local hasTable, fresh = tx.getHasTable()
    local numTypes = 0
    local foundType
    for k, v in pairs(hasTable) do
      if v == true then
        numTypes = numTypes + 1
        foundType = numTypes > 1 and nil or tonumber(k)
      end
    end

    if numTypes == 0 then
      subtypeValueLabel = 'Databyte 1'
      mainValueLabel = 'Databyte 2'
    elseif numTypes == 1 then
      subtypeValueLabel = tx.getSubtypeValueLabel((foundType >> 4) - 8)
      mainValueLabel = tx.getMainValueLabel((foundType >> 4) - 8)
    else
      subtypeValueLabel = 'Multiple (Databyte 1)'
      mainValueLabel = 'Multiple (Databyte 2)'
    end
    if fresh then NewHasTable = true end
  end

  local function musicalActionParam1Special(fun, row, addMetric, addSlop, paramEntry)
    r.ImGui_Separator(ctx)

    local mg = row.mg
    local useGrid = paramEntry.notation == '$grid'
    local mgMods, mgReaSwing = tx.GetMetricGridModifiers(mg)
    local newMgMods = mgMods
    local dotVal = not useGrid and mgMods == tx.MG_GRID_DOTTED or false
    local tripVal = not useGrid and mgMods == tx.MG_GRID_TRIPLET or false
    local swingVal = not useGrid and mgMods == tx.MG_GRID_SWING or false
    local showSwing = mg.showswing

    if useGrid then r.ImGui_BeginDisabled(ctx) end
    local rv, sel = r.ImGui_Checkbox(ctx, 'Dotted', dotVal)
    if rv then
      newMgMods = tx.SetMetricGridModifiers(mg, sel and tx.MG_GRID_DOTTED or tx.MG_GRID_STRAIGHT)
      fun(1, true)
    end

    rv, sel = r.ImGui_Checkbox(ctx, 'Triplet', tripVal)
    if rv then
      newMgMods = tx.SetMetricGridModifiers(mg, sel and tx.MG_GRID_TRIPLET or tx.MG_GRID_STRAIGHT)
      fun(2, true)
    end

    if showSwing then
      rv, sel = r.ImGui_Checkbox(ctx, 'Swing', swingVal)
      if rv then
        newMgMods = tx.SetMetricGridModifiers(mg, sel and tx.MG_GRID_SWING or tx.MG_GRID_STRAIGHT)
        fun(4, true)
      end

      r.ImGui_SameLine(ctx)
      local isSwing = newMgMods == tx.MG_GRID_SWING

      if not isSwing then r.ImGui_BeginDisabled(ctx) end
      r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH)
      local swbuf
      rv, swbuf = r.ImGui_InputText(ctx, '##swing', tostring(mg.swing), r.ImGui_InputTextFlags_CharsDecimal())
      mg.swing = tonumber(swbuf)

      r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, '[')
      r.ImGui_SameLine(ctx)
      rv, sel = r.ImGui_Checkbox(ctx, 'MPC', not mgReaSwing)
      if rv then
        local _, newMgReaSwing = tx.SetMetricGridModifiers(mg, nil, not sel)
        if mgReaSwing ~= newMgReaSwing then
          if mgReaSwing then -- from REAPER to MPC
            mg.swing = ((mg.swing + 100) / 4) + 25
          else -- MPC to REAPER
            mg.swing = ((mg.swing) * 4) - 200
          end
          mgReaSwing = newMgReaSwing
        end
      end
      r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, ']')
      if not isSwing then r.ImGui_EndDisabled(ctx) end

      if mgReaSwing then
        mg.swing = not mg.swing and 0 or mg.swing < -100 and -100 or mg.swing > 100 and 100 or mg.swing
      else
        mg.swing = not mg.swing and 50 or mg.swing < 0 and 0 or mg.swing > 100 and 100 or mg.swing
      end
    end

    if useGrid then r.ImGui_EndDisabled(ctx) end

    if addMetric then
      r.ImGui_Separator(ctx)
      rv, sel = r.ImGui_Checkbox(ctx, 'Restart pattern at next bar', mg.wantsBarRestart)
      if rv then
        mg.wantsBarRestart = sel
        fun(3, true)
      end
    end

    if addSlop then
      r.ImGui_Separator(ctx)
      r.ImGui_AlignTextToFramePadding(ctx)
      r.ImGui_Text(ctx, 'Slop (% of unit)')
      r.ImGui_SameLine(ctx)
      local tbuf
      r.ImGui_SetNextItemWidth(ctx, scaled(50))
      rv, tbuf = r.ImGui_InputDouble(ctx, 'Pre', mg.preSlopPercent, nil, nil, '%0.2f')
      if kbdEntryIsCompleted(rv) then
        mg.preSlopPercent = tbuf
        fun(4, true)
      end
      r.ImGui_SameLine(ctx)
      r.ImGui_SetNextItemWidth(ctx, scaled(50))
      rv, tbuf = r.ImGui_InputDouble(ctx, 'Post', mg.postSlopPercent, nil, nil, '%0.2f')
      if kbdEntryIsCompleted(rv) then
        mg.postSlopPercent = tbuf
        fun(5, true)
      end
    end
  end

  local function musicalParam1Special(fun, row, source, entry)
    musicalActionParam1Special(fun, row, false, true, source[entry])
  end

  local function musicalParam1SpecialNoSlop(fun, row, source, entry)
    musicalActionParam1Special(fun, row, false, false, source[entry])
  end

  local function metricParam1Special(fun, row, source, entry)
    musicalActionParam1Special(fun, row, true, true, source[entry])
  end

  local function everyNActionParam1Special(fun, row)
    local evn = row.evn
    local deactivated = false

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    r.ImGui_AlignTextToFramePadding(ctx)

    r.ImGui_Text(ctx, evn.isBitField and 'Pattern' or 'Interval')
    r.ImGui_SameLine(ctx)

    local saveX = r.ImGui_GetCursorPosX(ctx)
    if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
    if evn.isBitField then evn.textEditorStr = evn.textEditorStr:gsub('[2-9]', '1')
    else evn.textEditorStr = tostring(tonumber(evn.textEditorStr))
    end
    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 1.5)
    local rv, buf = r.ImGui_InputText(ctx, '##everyNentry', evn.textEditorStr,
      inputFlag | r.ImGui_InputTextFlags_CallbackCharFilter(),
      evn.isBitField and bitFieldCallback or numbersOnlyCallback)
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
    if kbdEntryIsCompleted(rv) then
      if isValidString(buf) then
        evn.textEditorStr = buf
        if evn.isBitField then
          evn.pattern = evn.textEditorStr
        else
          evn.interval = tonumber(evn.textEditorStr)
        end
        fun(2, true)
      end
    end

    r.ImGui_SameLine(ctx)

    r.ImGui_PushFont(ctx, fontInfo.smaller)
    local yCache = r.ImGui_GetCursorPosY(ctx)
    local _, smallerHeight = r.ImGui_CalcTextSize(ctx, '0') -- could make this global if it is expensive
    r.ImGui_SetCursorPosY(ctx, yCache + ((r.ImGui_GetFrameHeight(ctx) - smallerHeight) / 2))
    local selected
    rv, selected = r.ImGui_Checkbox(ctx, 'Bitfield', evn.isBitField)
    if rv then
      evn.isBitField = selected
      fun(1, true)
    end
    r.ImGui_PopFont(ctx)

    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, 'Offset')
    r.ImGui_SameLine(ctx)

    r.ImGui_SetCursorPosX(ctx, saveX)
    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 1.5)
    rv, buf = r.ImGui_InputText(ctx, '##everyNoffset', evn.offsetEditorStr, r.ImGui_InputTextFlags_CallbackCharFilter(), numbersOnlyCallback)
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
    if kbdEntryIsCompleted(rv) then
      if isValidString(buf) then
        evn.offsetEditorStr = buf
        evn.offset = tonumber(evn.offsetEditorStr)
        fun(3, true)
      end
    end

    if not r.ImGui_IsAnyItemActive(ctx) and not deactivated then
      if completionKeyPress() then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 2)
  end

  local function everyNParam1Special(fun, row)
    everyNActionParam1Special(fun, row)
  end

  local function newMIDIEventActionParam1Special(fun, row) -- type list is main menu
    local nme = row.nme
    local deactivated = false

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    r.ImGui_Separator(ctx)

    r.ImGui_AlignTextToFramePadding(ctx)

    r.ImGui_Text(ctx, 'Channel')
    r.ImGui_SameLine(ctx)

    if r.ImGui_BeginListBox(ctx, '##chanList', currentFontWidth * 10, currentFrameHeight * 3) then
      for i = 1, 16 do
        local rv = r.ImGui_MenuItem(ctx, tostring(i), nil, nme.channel == i - 1)
        if rv then
          if nme.channel == i - 1 then r.ImGui_CloseCurrentPopup(ctx) end
          nme.channel = i - 1
        end
      end
      r.ImGui_EndListBox(ctx)
    end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end

    r.ImGui_SameLine(ctx)

    local saveX, saveY = r.ImGui_GetCursorPos(ctx)
    saveX = saveX + scaled(20)
    saveY = saveY + currentFrameHeight * 0.5

    r.ImGui_SetCursorPos(ctx, saveX, saveY)

    local rv, sel = r.ImGui_Checkbox(ctx, 'Sel?', nme.selected)
    if rv then
      nme.selected = sel
    end

    r.ImGui_SetCursorPos(ctx, saveX, saveY + (currentFrameHeight * 1.1))

    rv, sel = r.ImGui_Checkbox(ctx, 'Mute?', nme.muted)
    if rv then
      nme.muted = sel
    end

    r.ImGui_SetCursorPosY(ctx, saveY + (currentFrameHeight * 2.7))

    r.ImGui_Separator(ctx)

    local isNote = nme.chanmsg == 0x90

    local twobyte = nme.chanmsg >= 0xC0
    local is14 = nme.chanmsg == 0xE0
    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
    local byte1Txt = is14 and tostring((nme.msg3 << 7 | nme.msg2) - (1 << 13)) or tostring(nme.msg2)
    rv, byte1Txt = r.ImGui_InputText(ctx, 'Val1', byte1Txt, inputFlag | r.ImGui_InputTextFlags_CallbackCharFilter(), numbersOnlyCallback)
    if rv then
      local nummy = tonumber(byte1Txt) or 0
      if is14 then
        if nummy < -8192 then nummy = -8192 elseif nummy > 8191 then nummy = 8191 end
        nummy = nummy + (1 << 13)
        nme.msg2 = nummy & 0x7F
        nme.msg3 = nummy >> 7 & 0x7F
      else
        nme.msg2 = nummy < 0 and 0 or nummy > 127 and 127 or nummy
      end
    end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end

    r.ImGui_SameLine(ctx)

    r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + DEFAULT_ITEM_WIDTH * 0.25)

    if is14 or twobyte then r.ImGui_BeginDisabled(ctx) end
    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
    local byte2Txt = (is14 or twobyte) and '0' or tostring(nme.msg3)
    rv, byte2Txt = r.ImGui_InputText(ctx, 'Val2', byte2Txt, inputFlag | r.ImGui_InputTextFlags_CallbackCharFilter(), numbersOnlyCallback)
    if rv then
      local nummy = tonumber(byte2Txt) or 0
      if is14 or twobyte then
      else
        local min = isNote and 1 or 0
        nme.msg3 = nummy < min and min or nummy > 127 and 127 or nummy
      end
    end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
    if is14 or twobyte then r.ImGui_EndDisabled(ctx) end

    if nme.chanmsg == 0x90 then
      r.ImGui_Separator(ctx)

      r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH)
      rv, nme.durText = r.ImGui_InputText(ctx, 'Dur.', nme.durText, inputFlag | r.ImGui_InputTextFlags_CallbackCharFilter(), timeFormatOnlyCallback)
      if rv then
        nme.durText = tx.lengthFormatRebuf(nme.durText)
      end
      if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end

      r.ImGui_SameLine(ctx)

      r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
      local relVelTxt = tostring(nme.relvel)
      rv, relVelTxt = r.ImGui_InputText(ctx, 'RelVel', relVelTxt, inputFlag | r.ImGui_InputTextFlags_CallbackCharFilter(), numbersOnlyCallback)
      if rv then
        nme.relvel = tonumber(relVelTxt) or 0
        nme.relvel = nme.relvel < 0 and 0 or nme.relvel > 127 and 127 or nme.relvel
      end
      if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
    end

    if not r.ImGui_IsAnyItemActive(ctx) and not deactivated then
      if completionKeyPress() then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 2)
  end

  local function newMIDIEventParam1Special(fun, row)
    newMIDIEventActionParam1Special(fun, row)
  end

  local function eventSelectorActionParam1Special(fun, row) -- type list is main menu
    local evsel = row.evsel
    local deactivated = false
    local rv

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    r.ImGui_Separator(ctx)

    r.ImGui_AlignTextToFramePadding(ctx)

    r.ImGui_Text(ctx, 'Chan.')
    r.ImGui_SameLine(ctx)

    if dontCloseXPos then r.ImGui_SetCursorPosX(ctx, dontCloseXPos) end

    if r.ImGui_BeginListBox(ctx, '##chanList', currentFontWidth * 10, currentFrameHeight * 3) then
      rv = r.ImGui_MenuItem(ctx, tostring('Any'), nil, evsel.channel == -1)
      if rv then
        if evsel.channel == -1 then r.ImGui_CloseCurrentPopup(ctx) end
        evsel.channel = -1
      end

      for i = 1, 16 do
        rv = r.ImGui_MenuItem(ctx, tostring(i), nil, evsel.channel == i - 1)
        if rv then
          if evsel.channel == i - 1 then r.ImGui_CloseCurrentPopup(ctx) end
          evsel.channel = i - 1
        end
      end
      r.ImGui_EndListBox(ctx)
    end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end

    local saveNextLineY = r.ImGui_GetCursorPosY(ctx)

    r.ImGui_SameLine(ctx)

    local disableUseVal1 = evsel.chanmsg == 0x00 or evsel.chanmsg >= 0xD0
    local saveX, saveY = r.ImGui_GetCursorPos(ctx)
    if disableUseVal1 then
      r.ImGui_BeginDisabled(ctx)
    end
    local sel
    rv, sel = r.ImGui_Checkbox(ctx, 'Use Val1?', evsel.useval1)
    if rv then
      evsel.useval1 = sel
    end
    if disableUseVal1 then
      r.ImGui_EndDisabled(ctx)
    end

    local isNote = evsel.chanmsg == 0x90
    local disableVal1 = disableUseVal1 or not evsel.useval1
    if disableVal1 then
      r.ImGui_BeginDisabled(ctx)
    end
    r.ImGui_SetCursorPos(ctx, saveX, saveY + currentFrameHeight * 1.5)
    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
    local byte1Txt = tostring(evsel.msg2)
    rv, byte1Txt = r.ImGui_InputText(ctx, '##Val1', byte1Txt,
      inputFlag | r.ImGui_InputTextFlags_CallbackCharFilter(),
      isNote and numbersOrNoteNameCallback or numbersOnlyCallback)
    if rv then
      if isNote then
        byte1Txt = rewriteNoteName(byte1Txt)
      end
      local nummy = tonumber(byte1Txt) or 0
      evsel.msg2 = nummy < 0 and 0 or nummy > 127 and 127 or nummy
    end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
    if isNote then
      local noteName = mu.MIDI_NoteNumberToNoteName(evsel.msg2)
      if noteName then
        r.ImGui_SameLine(ctx)
        r.ImGui_AlignTextToFramePadding(ctx)
        r.ImGui_TextColored(ctx, 0x7FFFFFCF, '[' .. noteName .. ']')
      end
    end
    if disableVal1 then
      r.ImGui_EndDisabled(ctx)
    end

    r.ImGui_SetCursorPosY(ctx, saveNextLineY)

    r.ImGui_Separator(ctx)

    r.ImGui_Text(ctx, 'Sel.')
    r.ImGui_SameLine(ctx)

    if dontCloseXPos then r.ImGui_SetCursorPosX(ctx, dontCloseXPos) end

    if r.ImGui_BeginListBox(ctx, '##selList', currentFontWidth * 14, currentFrameHeight * 3) then
      rv = r.ImGui_MenuItem(ctx, tostring('Any'), nil, evsel.selected == -1)
      if rv then
        if evsel.selected == -1 then r.ImGui_CloseCurrentPopup(ctx) end
        evsel.selected = -1
      end

      rv = r.ImGui_MenuItem(ctx, tostring('Unselected'), nil, evsel.selected == 0)
      if rv then
        if evsel.selected == 0 then r.ImGui_CloseCurrentPopup(ctx) end
        evsel.selected = 0
      end

      rv = r.ImGui_MenuItem(ctx, tostring('Selected'), nil, evsel.selected == 1)
      if rv then
        if evsel.selected == 1 then r.ImGui_CloseCurrentPopup(ctx) end
        evsel.selected = 1
      end
      r.ImGui_EndListBox(ctx)
    end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end

    r.ImGui_SameLine(ctx)

    r.ImGui_Text(ctx, 'Muted')
    r.ImGui_SameLine(ctx)

    if r.ImGui_BeginListBox(ctx, '##muteList', currentFontWidth * 12, currentFrameHeight * 3) then
      rv = r.ImGui_MenuItem(ctx, tostring('Any'), nil, evsel.muted == -1)
      if rv then
        if evsel.muted == -1 then r.ImGui_CloseCurrentPopup(ctx) end
        evsel.muted = -1
      end

      rv = r.ImGui_MenuItem(ctx, tostring('Unmuted'), nil, evsel.muted == 0)
      if rv then
        if evsel.muted == 0 then r.ImGui_CloseCurrentPopup(ctx) end
        evsel.muted = 0
      end

      rv = r.ImGui_MenuItem(ctx, tostring('Muted'), nil, evsel.muted == 1)
      if rv then
        if evsel.muted == 1 then r.ImGui_CloseCurrentPopup(ctx) end
        evsel.muted = 1
      end
      r.ImGui_EndListBox(ctx)
    end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end

    if not r.ImGui_IsAnyItemActive(ctx) and not deactivated then
      if completionKeyPress() then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 2)
  end

  local function eventSelectorParam1Special(fun, row)
    eventSelectorActionParam1Special(fun, row)
  end

  local function musicalSlopParamSpecial(fun, row, underEditCursor)
    local deactivated = false
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    r.ImGui_Separator(ctx)

    r.ImGui_AlignTextToFramePadding(ctx)

    r.ImGui_Text(ctx, '+- % of unit')
    r.ImGui_SameLine(ctx)

    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
    local retval, buf = r.ImGui_InputText(ctx, '##eventSelectorParam2',
      underEditCursor and row.params[2].textEditorStr or row.evsel.scaleStr,
      r.ImGui_InputTextFlags_CharsDecimal() + r.ImGui_InputTextFlags_CharsNoBlank())
    local scale = tonumber(buf)
    scale = scale == nil and 100 or scale < 0 and 0 or scale > 100 and 100 or scale
    if underEditCursor then
      row.params[2].textEditorStr = tostring(scale)
    else
      row.evsel.scaleStr = tostring(scale)
    end
    if kbdEntryIsCompleted(retval) then
      inTextInput = false
    elseif retval then inTextInput = true
    end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end

    if not r.ImGui_IsAnyItemActive(ctx) and not deactivated then
      if completionKeyPress() then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 2)
  end

  local function eventSelectorParam2Special(fun, row)
    musicalSlopParamSpecial(fun, row, false)
  end

  local function underEditCursorParam1Special(fun, row)
    musicalSlopParamSpecial(fun, row, true)
  end

  local function newMIDIEventActionParam2Special(fun, row) -- type list is main menu
    local nme = row.nme
    local deactivated = false

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    r.ImGui_Separator(ctx)

    r.ImGui_AlignTextToFramePadding(ctx)

    local xPos = r.ImGui_GetCursorPosX(ctx)
    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH)
    local absPos = nme.posmode == tx.NEWEVENT_POSITION_ATPOSITION
    local isRel = nme.relmode and not absPos
    local disableNumbox = not isRel and not absPos
    if disableNumbox then r.ImGui_BeginDisabled(ctx) end
    local label = not absPos and 'Pos+-' or 'Pos.'
    local rv
    rv, nme.posText = r.ImGui_InputText(ctx, label, nme.posText, inputFlag | r.ImGui_InputTextFlags_CallbackCharFilter(), timeFormatOnlyCallback)
    if rv then
      nme.posText = isRel and tx.lengthFormatRebuf(nme.posText) or tx.timeFormatRebuf(nme.posText)
    end
    if disableNumbox then r.ImGui_EndDisabled(ctx) end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end

    r.ImGui_SameLine(ctx)
    r.ImGui_SetCursorPosX(ctx, xPos + DEFAULT_ITEM_WIDTH + (currentFontWidth * 7))

    local disableCheckbox = absPos
    if disableCheckbox then r.ImGui_BeginDisabled(ctx) end
    local relval
    rv, relval = r.ImGui_Checkbox(ctx, 'Relative', nme.relmode)
    if rv then nme.relmode = relval end
    if disableCheckbox then r.ImGui_EndDisabled(ctx) end

    if not r.ImGui_IsAnyItemActive(ctx) and not deactivated then
      if completionKeyPress() then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 2)
  end

  local function newMIDIEventParam2Special(fun, row)
    newMIDIEventActionParam2Special(fun, row)
  end

  local function positionScaleOffsetParam1Special(fun, row)
    local deactivated = false

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    r.ImGui_AlignTextToFramePadding(ctx)

    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
    local rv, buf = r.ImGui_InputText(ctx, 'Scale', row.params[1].textEditorStr, inputFlag | r.ImGui_InputTextFlags_CharsDecimal() | r.ImGui_InputTextFlags_CharsNoBlank())
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
    tx.setRowParam(row, 1, tx.PARAM_TYPE_FLOATEDITOR, nil, buf, nil, false)

    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
    rv, buf = r.ImGui_InputText(ctx, 'Offset', (row.params[3] and row.params[3].textEditorStr) and row.params[3].textEditorStr or tx.DEFAULT_LENGTHFORMAT_STRING, inputFlag | r.ImGui_InputTextFlags_CallbackCharFilter(), timeFormatOnlyCallback)
    if rv then
      row.params[3].textEditorStr = tx.lengthFormatRebuf(buf)
    end
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end

    if not r.ImGui_IsAnyItemActive(ctx) and not deactivated then
      if completionKeyPress() then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 2)
  end

  local function LineParam1Special(fun, row)
    local deactivated = false

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    r.ImGui_AlignTextToFramePadding(ctx)

    local _, _, _, target, operation = tx.actionTabsFromTarget(row)
    local paramTypes = tx.getParamTypesForRow(row, target, operation)
    local flags = {}

    if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
    for i = 1, 3, 2 do
      overrideEditorType(row, target, operation, paramTypes, i)
      local paramType = paramTypes[i]
      local editorType = row.params[i].editorType
      flags.isFloat = (paramType == tx.PARAM_TYPE_FLOATEDITOR or editorType == tx.EDITOR_TYPE_PERCENT) and true or false
      r.ImGui_AlignTextToFramePadding(ctx)
      r.ImGui_Text(ctx, i == 1 and 'Lo:' or 'Hi:')
      r.ImGui_SameLine(ctx)
      r.ImGui_SetCursorPosX(ctx, currentFontWidth * 4)
      r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
      if doHandleTableParam(row, target, operation, paramType, editorType, i, flags, doActionUpdate) then deactivated = true end
    end

    if not r.ImGui_IsAnyItemActive(ctx) and not deactivated then
      if completionKeyPress() then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 2)
  end

  local function LineParam2Special(fun, row)
    local deactivated = false

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    r.ImGui_Separator(ctx)

    r.ImGui_AlignTextToFramePadding(ctx)

    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 0.75)
    -- TODO disabled
    if row.params[2].menuEntry == 1 then r.ImGui_BeginDisabled(ctx) end
    -- if not row.params[3].mod then row.params[3].mod = 2 end -- necessary?
    local mod = row.params[3].mod
    local modrange = row.params[3].modrange
    if modrange then
      mod = (modrange[1] and mod < modrange[1]) and modrange[1] or (modrange[2] and mod > modrange[2]) and modrange[2] or mod
    end

    local DBL_MIN, DBL_MAX = 2.22507e-308, 1.79769e+308
    local dmin = row.params[2].menuEntry == 4 and -1 or 0
    local dmax = row.params[2].menuEntry == 4 and 1 or DBL_MAX
    local rv, dmod = r.ImGui_DragDouble(ctx, 'Curve Var.', mod, 0.005, dmin, dmax, '%0.3f')
    -- local rv, buf = r.ImGui_InputText(ctx, 'Exp/Log Factor', tostring(mod), inputFlag | r.ImGui_InputTextFlags_CharsDecimal() | r.ImGui_InputTextFlags_CharsNoBlank())
    if r.ImGui_IsItemDeactivated(ctx) then deactivated = true end
    if row.params[2].menuEntry == 1 then r.ImGui_EndDisabled(ctx) end

    mod = dmod
    -- mod = tonumber(buf)
    if mod then
      if modrange then
        mod = (modrange[1] and mod < modrange[1]) and modrange[1] or (modrange[2] and mod > modrange[2]) and modrange[2] or mod
      elseif mod < 0 then
        mod = 0
      end
      row.params[3].mod = mod
    end

    if not r.ImGui_IsAnyItemActive(ctx) and not deactivated then
      if completionKeyPress() then
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 2)
  end

  ----------------------------------------------
  ---------- SELECTION CRITERIA TABLE ----------
  ----------------------------------------------

  local timeFormatColumnName = 'Bar Range/Time Base'

  local findColumns = {
    '(',
    'Target',
    'Not',
    'Condition',
    'Parameter 1',
    'Parameter 2',
    timeFormatColumnName,
    ')',
    'Boolean'
  }

  local tableHeight = currentFrameHeight * 6.2
  local restoreY = r.ImGui_GetCursorPosY(ctx) + tableHeight
  if r.ImGui_BeginTable(ctx, 'Selection Criteria', #findColumns - (showTimeFormatColumn == false and 1 or 0), r.ImGui_TableFlags_ScrollY() + r.ImGui_TableFlags_BordersInnerH(), 0, tableHeight) then

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
    for _, label in ipairs(findColumns) do
      if showTimeFormatColumn or label ~= timeFormatColumnName then
        local narrow = (label == '(' or label == ')' or label == 'Not' or label == 'Boolean')
        local flags = narrow and r.ImGui_TableColumnFlags_WidthFixed() or r.ImGui_TableColumnFlags_WidthStretch()
        local colwid = narrow and (label == 'Boolean' and scaled(70) or scaled(PAREN_COLUMN_WIDTH)) or nil
        r.ImGui_TableSetupColumn(ctx, label, flags, colwid)
      end
    end
    r.ImGui_TableHeadersRow(ctx)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopStyleColor(ctx)

    handleValueLabels()

    for k, v in ipairs(tx.findRowTable()) do
      r.ImGui_PushID(ctx, tostring(k))
      local currentRow = v
      local currentFindTarget = {}
      local currentFindCondition = {}
      local conditionEntries = {}
      local param1Entries = {}
      local param2Entries = {}

      currentRow.dirty = false
      if v.disabled then r.ImGui_BeginDisabled(ctx) end

      conditionEntries, param1Entries, param2Entries, currentFindTarget, currentFindCondition = tx.findTabsFromTarget(currentRow)

      r.ImGui_TableNextRow(ctx)

      if k == selectedFindRow then
        r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg0(), 0x77FFFF1F)
      end

      local colIdx = 0

      r.ImGui_TableSetColumnIndex(ctx, colIdx) -- '('
      if currentRow.startParenEntry < 2 then
        r.ImGui_InvisibleButton(ctx, '##startParen', scaled(PAREN_COLUMN_WIDTH), currentFrameHeight) -- or we can't test hover/click properly
      else
        r.ImGui_Button(ctx, tx.startParenEntries[currentRow.startParenEntry].label)
      end
      if currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
        r.ImGui_OpenPopup(ctx, 'startParenMenu')
        selectedFindRow = k
        lastSelectedRowType = 0 -- Find
      end

      colIdx = colIdx + 1
      r.ImGui_TableSetColumnIndex(ctx, colIdx) -- 'Target'
      local targetText = currentRow.targetEntry > 0 and currentFindTarget.label or '---'
      r.ImGui_Button(ctx, decorateTargetLabel(targetText))
      if currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
        selectedFindRow = k
        lastSelectedRowType = 0 -- Find
        currentRow.except = true
        doFindUpdate()
        r.ImGui_OpenPopup(ctx, 'targetMenu')
      end
      if not r.ImGui_IsPopupOpen(ctx, 'targetMenu') and currentRow.except then
        currentRow.except = nil
        doFindUpdate()
      end

      colIdx = colIdx + 1
      r.ImGui_TableSetColumnIndex(ctx, colIdx) -- 'Not'
      if not currentFindCondition.notnot then
        r.ImGui_PushFont(ctx, fontInfo.smaller)
        local yCache = r.ImGui_GetCursorPosY(ctx)
        local _, smallerHeight = r.ImGui_CalcTextSize(ctx, '0') -- could make this global if it is expensive
        r.ImGui_SetCursorPosY(ctx, yCache + ((r.ImGui_GetFrameHeight(ctx) - smallerHeight) / 2))
        local rv, selected = r.ImGui_Checkbox(ctx, '##notBox', currentRow.isNot)
        if rv then
          currentRow.isNot = selected
        end
        r.ImGui_SetCursorPosY(ctx, yCache)
        r.ImGui_PopFont(ctx)
      end

      colIdx = colIdx + 1
      r.ImGui_TableSetColumnIndex(ctx, colIdx) -- 'Condition'
      r.ImGui_Button(ctx, #conditionEntries ~= 0 and currentFindCondition.label or '---')
      if #conditionEntries ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
        selectedFindRow = k
        lastSelectedRowType = 0 -- Find
        r.ImGui_OpenPopup(ctx, 'conditionMenu')
      end

      local paramTypes = tx.getParamTypesForRow(currentRow, currentFindTarget, currentFindCondition)

      colIdx = colIdx + 1
      r.ImGui_TableSetColumnIndex(ctx, colIdx) -- 'Parameter 1'
      overrideEditorType(currentRow, currentFindTarget, currentFindCondition, paramTypes, 1)
      if handleTableParam(currentRow, currentFindCondition, param1Entries, paramTypes[1], 1, doFindUpdate) then
        selectedFindRow = k
        lastSelectedRowType = 0
      end

      colIdx = colIdx + 1
      r.ImGui_TableSetColumnIndex(ctx, colIdx) -- 'Parameter 2'
      overrideEditorType(currentRow, currentFindTarget, currentFindCondition, paramTypes, 2)
      if handleTableParam(currentRow, currentFindCondition, param2Entries, paramTypes[2], 2, doFindUpdate) then
        selectedFindRow = k
        lastSelectedRowType = 0
      end

      -- unused currently
      if showTimeFormatColumn then
        colIdx = colIdx + 1
        r.ImGui_TableSetColumnIndex(ctx, colIdx) -- Time format
        if (paramTypes[1] == tx.PARAM_TYPE_TIME or paramTypes[1] == tx.PARAM_TYPE_TIMEDUR) and currentFindCondition.terms ~= 0 then
          r.ImGui_Button(ctx, tx.findTimeFormatEntries[currentRow.timeFormatEntry].label or '---')
          if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
            selectedFindRow = k
            lastSelectedRowType = 0
            r.ImGui_OpenPopup(ctx, 'timeFormatMenu')
          end
        end
      end

      colIdx = colIdx + 1
      r.ImGui_TableSetColumnIndex(ctx, colIdx) -- End Paren
      if currentRow.endParenEntry < 2 then
        r.ImGui_InvisibleButton(ctx, '##endParen', scaled(PAREN_COLUMN_WIDTH), currentFrameHeight) -- or we can't test hover/click properly
      else
        r.ImGui_Button(ctx, tx.endParenEntries[currentRow.endParenEntry].label)
      end
      if currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
        r.ImGui_OpenPopup(ctx, 'endParenMenu')
        selectedFindRow = k
        lastSelectedRowType = 0
      end

      colIdx = colIdx + 1
      r.ImGui_TableSetColumnIndex(ctx, colIdx) -- Boolean
      if k ~= #tx.findRowTable() then
        r.ImGui_Button(ctx, tx.findBooleanEntries[currentRow.booleanEntry].label or '---', 50)
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
          currentRow.booleanEntry = currentRow.booleanEntry == 1 and 2 or 1
          selectedFindRow = k
          lastSelectedRowType = 0
          doFindUpdate()
        end
      end

      if v.disabled then r.ImGui_EndDisabled(ctx) end

      r.ImGui_SameLine(ctx)

      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
      if r.ImGui_Selectable(ctx, '##rowGroup', false, r.ImGui_SelectableFlags_SpanAllColumns() | r.ImGui_SelectableFlags_AllowItemOverlap()) then
        selectedFindRow = k
        lastSelectedRowType = 0
      end
      r.ImGui_PopStyleColor(ctx)
      r.ImGui_PopStyleColor(ctx)

      if r.ImGui_IsItemHovered(ctx) and r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_None() and r.ImGui_IsMouseClicked(ctx, r.ImGui_MouseButton_Right()) then
        selectedFindRow = k
        lastSelectedRowType = 0
        r.ImGui_OpenPopup(ctx, 'defaultFindRow')
      end

      if r.ImGui_BeginPopup(ctx, 'defaultFindRow', r.ImGui_WindowFlags_NoMove()) then
        if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
          if r.ImGui_IsPopupOpen(ctx, 'defaultFindRow', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
            r.ImGui_CloseCurrentPopup(ctx)
            handledEscape = true
          end
        end
        r.ImGui_Separator(ctx)
        if r.ImGui_Selectable(ctx, 'Make This Row Default For New Criteria', false) then
          defaultFindRow = tx.findRowToNotation(tx.findRowTable()[selectedFindRow])
          r.SetExtState(scriptID, 'defaultFindRow', defaultFindRow, true)
          r.ImGui_CloseCurrentPopup(ctx)
        end
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        if r.ImGui_Selectable(ctx, 'Clear Row Default', false) then
          r.DeleteExtState(scriptID, 'defaultFindRow', true)
          defaultFindRow = nil
          r.ImGui_CloseCurrentPopup(ctx)
        end
        r.ImGui_EndPopup(ctx)
      end

      createPopup(currentRow, 'startParenMenu', tx.startParenEntries, currentRow.startParenEntry, function(i)
          currentRow.startParenEntry = i
          doFindUpdate()
        end)

      createPopup(currentRow, 'endParenMenu', tx.endParenEntries, currentRow.endParenEntry, function(i)
          currentRow.endParenEntry = i
          doFindUpdate()
        end)

      createPopup(currentRow, 'targetMenu', tx.findTargetEntries, currentRow.targetEntry, function(i)
          local oldNotation = currentFindCondition.notation
          currentRow:init()
          currentRow.targetEntry = i
          conditionEntries = tx.findTabsFromTarget(currentRow)
          for kk, vv in ipairs(conditionEntries) do
            if vv.notation == oldNotation then currentRow.conditionEntry = kk break end
          end
          setupRowFormat(currentRow, conditionEntries)
          doFindUpdate()
        end)

      createPopup(currentRow, 'conditionMenu', conditionEntries, currentRow.conditionEntry, function(i)
          currentRow.conditionEntry = i
          local condNotation = conditionEntries[i].notation
          setupRowFormat(currentRow, conditionEntries)
          doFindUpdate()
        end)

      createPopup(currentRow, 'param1Menu', param1Entries, currentRow.params[1].menuEntry, function(i, isSpecial)
          if not isSpecial then
            if paramTypes[1] == tx.PARAM_TYPE_EVENTSELECTOR then
              currentRow.evsel.chanmsg = tonumber(param1Entries[i].text)
            end
            currentRow.params[1].menuEntry = i
          end
          doFindUpdate()
        end,
        paramTypes[1] == tx.PARAM_TYPE_METRICGRID
            and metricParam1Special
          or paramTypes[1] == tx.PARAM_TYPE_MUSICAL
            and musicalParam1Special
          or paramTypes[1] == tx.PARAM_TYPE_EVERYN
            and everyNParam1Special
          or paramTypes[1] == tx.PARAM_TYPE_EVENTSELECTOR
            and eventSelectorParam1Special
          or conditionEntries[currentRow.conditionEntry].notation == ':undereditcursor'
            and underEditCursorParam1Special
          or nil,
        paramTypes[1] == tx.PARAM_TYPE_EVENTSELECTOR and 'Type' or false)

      createPopup(currentRow, 'param2Menu', param2Entries, currentRow.params[2].menuEntry, function(i)
          currentRow.params[2].menuEntry = i
          doFindUpdate()
        end,
        paramTypes[1] == tx.PARAM_TYPE_EVENTSELECTOR
          and eventSelectorParam2Special
        or nil)

      if showTimeFormatColumn then
        createPopup(currentRow, 'timeFormatMenu', tx.findTimeFormatEntries, currentRow.timeFormatEntry, function(i)
            currentRow.timeFormatEntry = i
            doFindUpdate()
          end)
      end

      r.ImGui_PopID(ctx)
    end

    r.ImGui_EndTable(ctx)
  end

  generateLabelOnLine('Selection Criteria', true)

  ---------------------------------------------------------------------------
  ------------------------------- FIND BUTTONS ------------------------------

  r.ImGui_SetCursorPosY(ctx, restoreY)

  Spacing(true)
  local saveSeparatorX = r.ImGui_GetCursorPosX(ctx)

  r.ImGui_Separator(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + currentFrameHeight)

  r.ImGui_AlignTextToFramePadding(ctx)

  r.ImGui_Button(ctx, tx.findScopeTable[tx.currentFindScope()].label, DEFAULT_ITEM_WIDTH * 2)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    r.ImGui_OpenPopup(ctx, 'findScopeMenu')
  end

  r.ImGui_SameLine(ctx)

  local saveX, saveY = r.ImGui_GetCursorPos(ctx)

  generateLabelOnLine('Selection Scope', true)

  createPopup(nil, 'findScopeMenu', tx.findScopeTable, tx.currentFindScope(), function(i)
    tx.setCurrentFindScope(i)
    doUpdate()
  end)

  r.ImGui_SetCursorPos(ctx, saveX, saveY)

  local findScopeNotation = tx.findScopeTable[tx.currentFindScope()].notation
  local isActiveEditorScope = findScopeNotation == '$midieditor'

  if not isActiveEditorScope then r.ImGui_BeginDisabled(ctx) end

  r.ImGui_Button(ctx, tx.getFindScopeFlagLabel(), DEFAULT_ITEM_WIDTH * 1.7)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    r.ImGui_OpenPopup(ctx, 'findScopeFlagMenu')
  end

  if r.ImGui_BeginPopup(ctx, 'findScopeFlagMenu', r.ImGui_WindowFlags_NoMove()) then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      r.ImGui_CloseCurrentPopup(ctx)
      handledEscape = true
    end
    local rv, sel = r.ImGui_Checkbox(ctx, 'Selected Events', tx.getFindScopeFlags() & tx.FIND_SCOPE_FLAG_SELECTED_ONLY ~= 0)
    if rv then
      local oldflags = tx.getFindScopeFlags()
      local newflags = sel and (oldflags | tx.FIND_SCOPE_FLAG_SELECTED_ONLY) or (oldflags & ~tx.FIND_SCOPE_FLAG_SELECTED_ONLY)
      tx.setFindScopeFlags(newflags)
      doUpdate()
    end

    rv, sel = r.ImGui_Checkbox(ctx, 'Active Note Row (+ notes only)', tx.getFindScopeFlags() & tx.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW ~= 0)
    if rv then
      local oldflags = tx.getFindScopeFlags()
      local newflags = sel and (oldflags | tx.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW) or (oldflags & ~tx.FIND_SCOPE_FLAG_ACTIVE_NOTE_ROW)
      tx.setFindScopeFlags(newflags)
      doUpdate()
    end
    r.ImGui_EndPopup(ctx)
  end

  r.ImGui_SameLine(ctx)

  saveX, saveY = r.ImGui_GetCursorPos(ctx)

  generateLabelOnLine('Scope Mods', true)

  if not isActiveEditorScope then r.ImGui_EndDisabled(ctx) end

  r.ImGui_SetCursorPos(ctx, saveX, saveY)

  r.ImGui_Button(ctx, tx.getFindPostProcessingLabel(), DEFAULT_ITEM_WIDTH * 1.7)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    r.ImGui_OpenPopup(ctx, 'findPostPocessingMenu')
  end

  generateFindPostProcessingPopup()

  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, findParserError)
  r.ImGui_SameLine(ctx)

  r.ImGui_PopStyleColor(ctx, 4)

  r.ImGui_SetCursorPosX(ctx, saveSeparatorX)

  Spacing(true)
  r.ImGui_Separator(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_SetCursorPos(ctx, saveSeparatorX, r.ImGui_GetCursorPosY(ctx) + 15)
  r.ImGui_Separator(ctx)

  ---------------------------------------------------------------------------
  -------------------------------- ACTION ROWS ------------------------------

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x550077FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x770099FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x660088FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x440066FF)

  r.ImGui_AlignTextToFramePadding(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + currentFrameHeight * 0.75)

  r.ImGui_Button(ctx, 'Insert Action', DEFAULT_ITEM_WIDTH * 2)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    local numRows = #tx.actionRowTable()
    addActionRow()

    if numRows == 0 then
      local scope = tx.actionScopeTable[tx.currentActionScope()].notation
      if scope:match('select') then -- change to Transform scope if we're in a Select scope
        for k, v in ipairs(tx.actionScopeTable) do
          if v.notation == '$transform' then
            tx.setCurrentActionScope(k)
            doUpdate()
          end
        end
      end
    end
  end

  r.ImGui_SameLine(ctx)
  local actButDisabled = (optDown and #tx.actionRowTable() == 0) or (not optDown and selectedActionRow == 0)
  if actButDisabled then
    r.ImGui_BeginDisabled(ctx)
  end
  r.ImGui_Button(ctx, optDown and 'Clear All Actions' or 'Remove Action', DEFAULT_ITEM_WIDTH * 2)
  if actButDisabled then
    r.ImGui_EndDisabled(ctx)
  end

  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    if optDown then
      tx.clearActionRows()
      selectedActionRow = 0
      doActionUpdate()
    else
      removeActionRow()
    end
  end

  if showConsoles then
    r.ImGui_SameLine(ctx)
    r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 6)
    local acrv, acbuf = r.ImGui_InputText(ctx, '##actionConsole', actionConsoleText)
    if kbdEntryIsCompleted(acrv) then
      actionConsoleText = acbuf
      tx.processActionMacro(actionConsoleText)
      inTextInput = false
    elseif acrv then inTextInput = true
    end

    generateLabelOnLine('Action Console')
  end

  Spacing(true)
  r.ImGui_Separator(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + currentFrameHeight)

  ----------------------------------------------
  ---------------- ACTIONS TABLE ---------------
  ----------------------------------------------

  local actionColumns = {
    'Target',
    'Operation',
    'Parameter 1',
    'Parameter 2'
  }

  restoreY = r.ImGui_GetCursorPosY(ctx) + tableHeight

  if r.ImGui_BeginTable(ctx, 'Actions', #actionColumns, r.ImGui_TableFlags_ScrollY() + r.ImGui_TableFlags_BordersInnerH(), 0, tableHeight) then

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
    for _, label in ipairs(actionColumns) do
      local flags = r.ImGui_TableColumnFlags_None()
      r.ImGui_TableSetupColumn(ctx, label, flags)
    end
    r.ImGui_TableHeadersRow(ctx)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopStyleColor(ctx)

    for k, v in ipairs(tx.actionRowTable()) do
      r.ImGui_PushID(ctx, tostring(k))
      local currentRow = v
      local currentActionTarget = {}
      local currentActionOperation = {}
      local operationEntries = {}
      local param1Entries = {}
      local param2Entries = {}

      currentRow.dirty = false
      if v.disabled then r.ImGui_BeginDisabled(ctx) end

      operationEntries, param1Entries, param2Entries, currentActionTarget, currentActionOperation = tx.actionTabsFromTarget(currentRow)

      r.ImGui_TableNextRow(ctx)

      if k == selectedActionRow then
        r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg0(), 0xFF77FF1F)
      end

      r.ImGui_TableSetColumnIndex(ctx, 0) -- 'Target'
      local targetText = currentRow.targetEntry > 0 and currentActionTarget.label or '---'
      r.ImGui_Button(ctx, decorateTargetLabel(targetText))
      if currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
        selectedActionRow = k
        lastSelectedRowType = 1
        r.ImGui_OpenPopup(ctx, 'targetMenu')
      end

      r.ImGui_TableSetColumnIndex(ctx, 1) -- 'Operation'
      r.ImGui_Button(ctx, #operationEntries ~= 0 and currentActionOperation.label or '---')
      if #operationEntries ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
        selectedActionRow = k
        lastSelectedRowType = 1
        r.ImGui_OpenPopup(ctx, 'operationMenu')
      end

      local paramTypes = tx.getParamTypesForRow(currentRow, currentActionTarget, currentActionOperation)

      r.ImGui_TableSetColumnIndex(ctx, 2) -- 'Parameter 1'
      overrideEditorType(currentRow, currentActionTarget, currentActionOperation, paramTypes, 1)
      if handleTableParam(currentRow, currentActionOperation, param1Entries, paramTypes[1], 1, doActionUpdate) then
        selectedActionRow = k
        lastSelectedRowType = 1
      end

      r.ImGui_TableSetColumnIndex(ctx, 3) -- 'Parameter 2'
      overrideEditorType(currentRow, currentActionTarget, currentActionOperation, paramTypes, 2)
      if handleTableParam(currentRow, currentActionOperation, param2Entries, paramTypes[2], 2, doActionUpdate) then
        selectedActionRow = k
        lastSelectedRowType = 1
      end

      if currentActionOperation.param3 then
        overrideEditorType(currentRow, currentActionTarget, currentActionOperation, paramTypes, 3)
      end

      if v.disabled then r.ImGui_EndDisabled(ctx) end

      r.ImGui_SameLine(ctx)

      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
      if r.ImGui_Selectable(ctx, '##rowGroup', false, r.ImGui_SelectableFlags_SpanAllColumns() | r.ImGui_SelectableFlags_AllowItemOverlap()) then
        selectedActionRow = k
        lastSelectedRowType = 1
      end
      r.ImGui_PopStyleColor(ctx)
      r.ImGui_PopStyleColor(ctx)

      if r.ImGui_IsItemHovered(ctx) and r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_None() and r.ImGui_IsMouseClicked(ctx, r.ImGui_MouseButton_Right()) then
        selectedActionRow = k
        lastSelectedRowType = 1
        r.ImGui_OpenPopup(ctx, 'defaultActionRow')
      end

      -- TODO: row drag/drop
      -- if r.ImGui_BeginDragDropSource(ctx) then
      --   r.ImGui_SetDragDropPayload(ctx, 'row', 'somedata')
      --   r.ImGui_EndDragDropSource(ctx)
      -- end

      if r.ImGui_BeginPopup(ctx, 'defaultActionRow', r.ImGui_WindowFlags_NoMove()) then
        if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
          if r.ImGui_IsPopupOpen(ctx, 'defaultActionRow', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
            r.ImGui_CloseCurrentPopup(ctx)
            handledEscape = true
          end
        end
        if r.ImGui_Selectable(ctx, 'Make This Row Default For New Actions', false) then
          defaultActionRow = tx.actionRowToNotation(tx.actionRowTable()[selectedActionRow])
          r.SetExtState(scriptID, 'defaultActionRow', defaultActionRow, true)
          r.ImGui_CloseCurrentPopup(ctx)
        end
        r.ImGui_Spacing(ctx)
        r.ImGui_Separator(ctx)
        r.ImGui_Spacing(ctx)
        if r.ImGui_Selectable(ctx, 'Clear Row Default', false) then
          r.DeleteExtState(scriptID, 'defaultActionRow', true)
          defaultActionRow = nil
          r.ImGui_CloseCurrentPopup(ctx)
        end
        r.ImGui_EndPopup(ctx)
      end

      createPopup(currentRow, 'targetMenu', tx.actionTargetEntries, currentRow.targetEntry, function(i)
          local oldNotation = currentActionOperation.notation
          currentRow:init()
          currentRow.targetEntry = i
          operationEntries = tx.actionTabsFromTarget(currentRow)
          for kk, vv in ipairs(operationEntries) do
            if vv.notation == oldNotation then currentRow.operationEntry = kk break end
          end
          setupRowFormat(currentRow, operationEntries)
          doActionUpdate()
        end)

      createPopup(currentRow, 'operationMenu', operationEntries, currentRow.operationEntry, function(i)
          currentRow.operationEntry = i
          setupRowFormat(currentRow, operationEntries)
          doActionUpdate()
        end)

      local isLineOp = currentActionOperation.param3
        and (currentActionOperation.notation == ':line' or currentActionOperation.notation == ':relline')

      createPopup(currentRow, 'param1Menu', param1Entries, currentRow.params[1].menuEntry, function(i, isSpecial)
          if not isSpecial then
            currentRow.params[1].menuEntry = i
            if operationEntries[currentRow.operationEntry].musical then
              musicalLastUnit = i
            elseif operationEntries[currentRow.operationEntry].newevent then
              currentRow.nme.chanmsg = tonumber(param1Entries[i].text)
            end
            doActionUpdate()
          end
        end,
        paramTypes[1] == tx.PARAM_TYPE_MUSICAL
            and musicalParam1SpecialNoSlop
          or paramTypes[1] == tx.PARAM_TYPE_NEWMIDIEVENT
            and newMIDIEventParam1Special
          or currentActionOperation.param3
            and (currentActionOperation.notation == ':scaleoffset' and positionScaleOffsetParam1Special
            or isLineOp and LineParam1Special)
          or nil,
          paramTypes[1] == tx.PARAM_TYPE_NEWMIDIEVENT)

      createPopup(currentRow, 'param2Menu', param2Entries, currentRow.params[2].menuEntry, function(i, isSpecial)
          if not isSpecial then
            if currentActionOperation.newevent then
              currentRow.nme.posmode = i
            elseif currentActionOperation.param3 and currentActionOperation.param3.paramProc then
              currentActionOperation.param3.paramProc(currentRow, 2, i)
            end
            currentRow.params[2].menuEntry = i
            doActionUpdate()
          end
        end,
        paramTypes[2] == tx.PARAM_TYPE_NEWMIDIEVENT
            and newMIDIEventParam2Special
          or isLineOp
            and LineParam2Special
          or nil,
          isLineOp or paramTypes[1] == tx.PARAM_TYPE_NEWMIDIEVENT)

      r.ImGui_PopID(ctx)
    end

    r.ImGui_EndTable(ctx)
  end

  r.ImGui_SetCursorPosY(ctx, restoreY)

  generateLabelOnLine('Actions', true)

  ---------------------------------------------------------------------------
  ------------------------------ ACTION BUTTONS -----------------------------

  Spacing(true)
  r.ImGui_Separator(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + currentFrameHeight)

  r.ImGui_AlignTextToFramePadding(ctx)

  local restoreX
  restoreX, restoreY = r.ImGui_GetCursorPos(ctx)

  r.ImGui_Button(ctx, 'Apply', DEFAULT_ITEM_WIDTH / 1.25)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    tx.processAction(true)
  end

  r.ImGui_SameLine(ctx)

  r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + scaled(5))

  r.ImGui_Button(ctx, tx.actionScopeTable[tx.currentActionScope()].label, DEFAULT_ITEM_WIDTH * 2)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    r.ImGui_OpenPopup(ctx, 'actionScopeMenu')
  end

  r.ImGui_SameLine(ctx)

  saveX = r.ImGui_GetCursorPosX(ctx)

  updateCurrentRect()
  generateLabel('Action Scope')

  createPopup(nil, 'actionScopeMenu', tx.actionScopeTable, tx.currentActionScope(), function(i)
      tx.setCurrentActionScope(i)
      doUpdate()
    end)

  r.ImGui_SameLine(ctx)

  r.ImGui_SetCursorPosX(ctx, saveX + scaled(5))

  local scopeNotation = tx.actionScopeTable[tx.currentActionScope()].notation
  local isSelectScope = scopeNotation:match('select') or scopeNotation:match('delete')

  if isSelectScope then r.ImGui_BeginDisabled(ctx) end

  r.ImGui_Button(ctx, tx.actionScopeFlagsTable[tx.currentActionScopeFlags()].label, DEFAULT_ITEM_WIDTH * 2.5)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    r.ImGui_OpenPopup(ctx, 'actionScopeFlagsMenu')
  end

  r.ImGui_SameLine(ctx)

  updateCurrentRect()

  generateLabel('Post-Action')

  if isSelectScope then r.ImGui_EndDisabled(ctx) end

  createPopup(nil, 'actionScopeFlagsMenu', tx.actionScopeFlagsTable, tx.currentActionScopeFlags(), function(i)
      tx.setCurrentActionScopeFlags(i)
      doUpdate()
    end)

  r.ImGui_PopStyleColor(ctx, 4)

  r.ImGui_NewLine(ctx)
  Spacing()
  Spacing(true)

  local presetButtonBottom = r.ImGui_GetCursorPosY(ctx)
  r.ImGui_Button(ctx, '...', currentFontWidth + scaled(10))
  local _, presetButtonHeight = r.ImGui_GetItemRectSize(ctx)
  presetButtonBottom = presetButtonBottom + presetButtonHeight
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    if not dirExists(presetPath) then r.RecursiveCreateDirectory(presetPath, 0) end
    presetFolders = enumerateTransformerPresets(presetPath, true)
    r.ImGui_OpenPopup(ctx, '##presetfolderselect')
  end

  r.ImGui_SameLine(ctx)
  saveX, saveY = r.ImGui_GetCursorPos(ctx)

  if presetSubPath then
    r.ImGui_NewLine(ctx)
    r.ImGui_Indent(ctx)
    local str = string.gsub(presetSubPath, presetPath, '')
    r.ImGui_TextColored(ctx, 0x00AAFFFF, '-> ' .. str)
  end

  if r.ImGui_BeginPopup(ctx, '##presetfolderselect', r.ImGui_WindowFlags_NoMove()) then
    r.ImGui_TextDisabled(ctx, 'Select destination folder...')

    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Spacing(ctx)

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    generatePresetMenu(presetFolders, presetPath, nil, nil, true)

    if canReveal then
      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
      local rv = r.ImGui_Selectable(ctx, 'Manage Presets...', false)
      if rv then
        r.CF_ShellExecute(presetPath) -- try this until it breaks
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 5)

    r.ImGui_EndPopup(ctx)
  end

  local createNewFolder, folderName = handleNewFolderCreationDialog('Create New Folder', 'New Folder Name')
  if createNewFolder then
    local newPath = newFolderParentPath .. '/' .. folderName
    if r.RecursiveCreateDirectory(newPath, 0) ~= 0 then
      presetSubPath = newPath ~= presetPath and newPath or nil
      doFindUpdate()
    else
      -- some kind of status message
    end
  end

  local buttonClickSave = false

  r.ImGui_SetCursorPos(ctx, saveX, saveY)
  r.ImGui_Button(ctx, (optDown or presetInputDoesScript) and 'Export Script...' or 'Save Preset...', DEFAULT_ITEM_WIDTH * 1.5)
  if (not presetInputVisible and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) or refocusInput then
    presetInputVisible = true
    presetInputDoesScript = optDown
    refocusInput = false
    r.ImGui_SetKeyboardFocusHere(ctx)
  elseif presetInputVisible and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
    buttonClickSave = true
  end

  local function handleOKDialog(title, text)
    local rv = false
    local retval = 0
    local doOK = false

    r.ImGui_PushFont(ctx, fontInfo.large)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

    if inOKDialog then
      positionModalWindow(r.ImGui_GetFrameHeight(ctx) / 2)
      r.ImGui_OpenPopup(ctx, title)
    elseif r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter()
      or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())) then
        doOK = true
    end

    if r.ImGui_BeginPopupModal(ctx, title, true, r.ImGui_WindowFlags_TopMost() | r.ImGui_WindowFlags_NoMove()) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        r.ImGui_CloseCurrentPopup(ctx)
        handledEscape = true
        refocusInput = true
      end
      if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
      r.ImGui_Spacing(ctx)
      r.ImGui_Text(ctx, text)
      r.ImGui_Spacing(ctx)
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

  local function presetPathAndFilenameFromLastInput()
    local path
    local buf = presetNameTextBuffer
    if not buf:match('%' .. presetExt .. '$') then buf = buf .. presetExt end

    if not dirExists(presetPath) then r.RecursiveCreateDirectory(presetPath, 0) end

    path = (presetSubPath and presetSubPath or presetPath) .. '/' .. buf
    return path, buf
  end

  local function doSavePreset(path, fname)
    local saved, scriptPath = tx.savePreset(path, { script = presetInputDoesScript, ignoreSelectionInArrangeView = scriptIgnoreSelectionInArrangeView, scriptPrefix = scriptPrefix })
    statusMsg = (saved and 'Saved' or 'Failed to save') .. (presetInputDoesScript and ' + export' or '') .. ' ' .. fname
    statusTime = r.time_precise()
    statusContext = 2
    if saved then
      fname = fname:gsub('%' .. presetExt .. '$', '')
      presetLabel = fname
      if saved and presetInputDoesScript and scriptPath then
        if scriptWritesMainContext then
          r.AddRemoveReaScript(true, 0, scriptPath, true)
        end
        if scriptWritesMIDIContexts then
          r.AddRemoveReaScript(true, 32060, scriptPath, false)
          r.AddRemoveReaScript(true, 32061, scriptPath, false)
          r.AddRemoveReaScript(true, 32062, scriptPath, false)
        end
      end
      doFindUpdate()
    else
      presetLabel = ''
    end
  end

  local function manageSaveAndOverwrite(pathFn, saveFn, statusCtx, suppressOverwrite)
    if inOKDialog then
      if not presetNameTextBuffer or presetNameTextBuffer == '' then
        statusMsg = 'Name must contain at least 1 character'
        statusTime = r.time_precise()
        statusContext = statusCtx
        inOKDialog = false
        return
      end
      local path, fname = pathFn()
      if not path then
        statusMsg = 'Could not find or create directory'
        statusTime = r.time_precise()
        statusContext = statusCtx
      elseif suppressOverwrite or not filePathExists(path) then
        saveFn(path, fname)
        inOKDialog = false
      end
    end

    if isValidString(presetNameTextBuffer) then
      local okrv, okval = handleOKDialog('Overwrite File?', 'Overwrite file '..presetNameTextBuffer..'?')
      if okrv then
        if okval == 1 then
          local path, fname = pathFn()
          saveFn(path, fname)
          r.ImGui_CloseCurrentPopup(ctx)
        end
      end
    end
  end

  if statusContext == 2 then
    presetInputVisible = false
    presetInputDoesScript = false
  end

  r.ImGui_SameLine(ctx)
  saveX, saveY = r.ImGui_GetCursorPos(ctx)

  if presetInputVisible then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      presetInputVisible = false
      presetInputDoesScript = false
      handledEscape = true
    end

    r.ImGui_SetNextItemWidth(ctx, 2.5 * DEFAULT_ITEM_WIDTH)
    if refocusOnNextIteration then
      r.ImGui_SetKeyboardFocusHere(ctx)
      refocusOnNextIteration = false
    end
    local retval, buf = r.ImGui_InputTextWithHint(ctx, '##presetname', 'Untitled', presetNameTextBuffer, inputFlag)
    local deactivated = r.ImGui_IsItemDeactivated(ctx)
    if deactivated and (not refocusField or buttonClickSave) then
      local complete = buttonClickSave or completionKeyPress()
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape())
        or not complete
      then
        presetInputVisible = false
        presetInputDoesScript = false
        handledEscape = true
      else
        presetNameTextBuffer = buf
        inOKDialog = true
      end
      inTextInput = false
    else
      presetNameTextBuffer = buf
      inOKDialog = false
      if retval then inTextInput = true end
    end

    if refocusField then
      refocusField = false
    end

    if presetInputDoesScript then
      r.ImGui_SameLine(ctx)
      local saveXPos = r.ImGui_GetCursorPosX(ctx)
      local rv, sel = r.ImGui_Checkbox(ctx, 'Main', scriptWritesMainContext)
      if rv then
        scriptWritesMainContext = sel
        r.SetExtState(scriptID, 'scriptWritesMainContext', scriptWritesMainContext and '1' or '0', true)
        refocusOnNextIteration = true
      end
      if r.ImGui_IsItemHovered(ctx) then
        refocusField = true
        inOKDialog = false
      end

      r.ImGui_SameLine(ctx)
      rv, sel = r.ImGui_Checkbox(ctx, 'MIDI', scriptWritesMIDIContexts)
      if rv then
        scriptWritesMIDIContexts = sel
        r.SetExtState(scriptID, 'scriptWritesMIDIContexts', scriptWritesMIDIContexts and '1' or '0', true)
        refocusOnNextIteration = true
      end
      if r.ImGui_IsItemHovered(ctx) then
        refocusField = true
        inOKDialog = false
      end

      r.ImGui_SetCursorPosX(ctx, saveXPos)
      rv, sel = r.ImGui_Checkbox(ctx, 'Ignore Selection in Arrange View', scriptIgnoreSelectionInArrangeView)
      if rv then
        scriptIgnoreSelectionInArrangeView = sel -- not persistent
        refocusOnNextIteration = true
      end
      if r.ImGui_IsItemHovered(ctx) then
        refocusField = true
        inOKDialog = false
      end
    end
    manageSaveAndOverwrite(presetPathAndFilenameFromLastInput, doSavePreset, 2)
  end

  restoreX = restoreX + 60 * currentFontWidth
  r.ImGui_SetCursorPos(ctx, restoreX, restoreY)

  local windowSizeX = r.ImGui_GetWindowSize(ctx)

  if not presetNotesViewEditor then
    r.ImGui_BeginGroup(ctx)
    local noBuf = false
    if presetNotesBuffer == '' then noBuf = true end
    if noBuf then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFF7F) end
    r.ImGui_SetCursorPos(ctx, restoreX + (framePaddingX / 2), restoreY + (framePaddingY / 2))
    r.ImGui_AlignTextToFramePadding(ctx)
    r.ImGui_TextWrapped(ctx, presetNotesBuffer == '' and 'Double-Click To Edit Preset Notes' or presetNotesBuffer)
    if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
      presetNotesViewEditor = true
      justChanged = true
    end
    if noBuf then r.ImGui_PopStyleColor(ctx) end
    r.ImGui_SetCursorPos(ctx, restoreX, restoreY)
    r.ImGui_EndGroup(ctx)
    updateCurrentRect()
  else
    if justChanged then r.ImGui_SetKeyboardFocusHere(ctx) end
    local retval, buf = r.ImGui_InputTextMultiline(ctx, '##presetnotes', presetNotesBuffer, windowSizeX - restoreX - 20, presetButtonBottom - restoreY, inputFlag)
    if justChanged and r.ImGui_IsItemActivated(ctx) then
      justChanged = false
    end
    local deactivated = r.ImGui_IsItemDeactivated(ctx)
    if deactivated and not completionKeyPress() then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        handledEscape = true -- don't revert the buffer if escape was pressed, use whatever's in there. causes a momentary flicker
      else
        if buf:gsub('%s+', '') == '' then buf = '' end
        setPresetNotesBuffer(buf)
      end
      presetNotesViewEditor = false
      inTextInput = false
    else
      if retval then inTextInput = true end
      if buf:gsub('%s+', '') == '' then buf = '' end
      setPresetNotesBuffer(buf)
    end
    updateCurrentRect()
  end

  restoreY = r.ImGui_GetCursorPosY(ctx) - 10 * canvasScale

  generateLabel('Preset Notes')

  local function handleStatus()
    if statusMsg ~= '' and statusTime then
      if r.time_precise() - statusTime > 3 then statusTime = nil statusMsg = '' statusContext = 0
      else
        r.ImGui_AlignTextToFramePadding(ctx)
        r.ImGui_Text(ctx, statusMsg)
      end
    end
  end

  r.ImGui_SetCursorPos(ctx, saveX, saveY)
  handleStatus()

  function PresetMatches(sourceEntry, filter, onlyFolders)
    if (sourceEntry.sub and (onlyFolders or PresetSubMenuMatches(sourceEntry.sub, filter)))
      or not sourceEntry.sub and
        (not filter
        or filter == ''
        or string.match(string.lower(sourceEntry.label), filter))
    then
      return true
    end
    return false
  end

  function PresetSubMenuMatches(source, filter)
    for i = 1, #source do
      if PresetMatches(source[i], filter) then
        return true
      end
    end
    return false
  end

  if r.ImGui_BeginPopup(ctx, 'openPresetMenu', r.ImGui_WindowFlags_NoMove()) then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      if r.ImGui_IsPopupOpen(ctx, 'openPresetMenu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
        r.ImGui_CloseCurrentPopup(ctx)
        handledEscape = true
      end
    end

    if r.ImGui_IsWindowAppearing(ctx) then
      r.ImGui_SetKeyboardFocusHere(ctx)
    end
    local rv, buf = r.ImGui_InputTextWithHint(ctx, '##presetFilter', 'Filter...', filterPresetsBuffer)
    if rv then
      filterPresetsBuffer = buf
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Spacing(ctx)

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    generatePresetMenu(presetTable, presetPath, nil, string.lower(filterPresetsBuffer))

    if canReveal then
      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
      local rv = r.ImGui_Selectable(ctx, 'Manage Presets...', false)
      if rv then
        r.CF_ShellExecute(presetPath) -- try this until it breaks
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end

    r.ImGui_PopStyleColor(ctx, 5)

    r.ImGui_EndPopup(ctx)
  end

  handleKeys(handledEscape)

  -- if recalcEventTimes or recalcSelectionTimes then canProcess = true end
  if NewHasTable then NewHasTable = false end
end

-----------------------------------------------------------------------------
--------------------------------- CLEANUP -----------------------------------

local function doClose()
  r.ImGui_Detach(ctx, fontInfo.large)
  r.ImGui_Detach(ctx, fontInfo.small)
  r.ImGui_Detach(ctx, fontInfo.smaller)
  r.ImGui_Detach(ctx, canonicalFont)
  r.ImGui_DestroyContext(ctx)
  ctx = nil
  if disabledAutoOverlap then
    gooseAutoOverlap()
  end
end

local function onCrash(err)
  if disabledAutoOverlap then
    gooseAutoOverlap()
  end
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
end

-----------------------------------------------------------------------------
----------------------------- WSIZE/FONTS JUNK ------------------------------

local function updateWindowPosition()
  local curWindowWidth, curWindowHeight = r.ImGui_GetWindowSize(ctx)
  local curWindowLeft, curWindowTop = r.ImGui_GetWindowPos(ctx)

  if dockID ~= 0 then
    local styleWidth, styleHeight = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_WindowMinSize())
    if curWindowWidth == styleWidth and curWindowHeight == styleHeight then
      curWindowWidth = windowInfo.width
      curWindowHeight = windowInfo.height
    end
  end

  if not windowInfo.wantsResize
    and (windowInfo.wantsResizeUpdate
      or curWindowWidth ~= windowInfo.width
      or curWindowHeight ~= windowInfo.height
      or curWindowLeft ~= windowInfo.left
      or curWindowTop ~= windowInfo.top)
  then
    if dockID == 0 then
      r.SetExtState(scriptID, 'windowRect', math.floor(curWindowLeft)..','..math.floor(curWindowTop)..','..math.floor(curWindowWidth)..','..math.floor(curWindowHeight), true)
    end
    windowInfo.left, windowInfo.top, windowInfo.width, windowInfo.height = curWindowLeft, curWindowTop, curWindowWidth, curWindowHeight
    windowInfo.wantsResizeUpdate = false
  end

  local isDocked = r.ImGui_IsWindowDocked(ctx)
  if isDocked then
    local curDockID = r.ImGui_GetWindowDockID(ctx)
    if dockID ~= curDockID then
      dockID = curDockID
      r.SetExtState(scriptID, 'dockID', tostring(math.floor(dockID)), true)
    end
  elseif dockID ~= 0 then
    dockID = 0
    r.DeleteExtState(scriptID, 'dockID', true)
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
  if newFontSize < 1 then newFontSize = 1 end
  local fontSize = fontInfo[name..'Size']

  if newFontSize ~= fontSize then
    r.ImGui_Detach(ctx, fontInfo[name])
    fontInfo[name] = r.ImGui_CreateFont(fontStyle, newFontSize)
    r.ImGui_Attach(ctx, fontInfo[name])
    fontInfo[name..'Size'] = newFontSize
    winHeight = nil
  end
end

local function updateFonts()
  updateOneFont('large')
  updateOneFont('small')
  updateOneFont('smaller')
end

local function openWindow()
  local windowSizeFlag = r.ImGui_Cond_Appearing()
  if windowInfo.wantsResize then
    windowSizeFlag = nil
  end
  if dockID == 0 then
    r.ImGui_SetNextWindowSize(ctx, windowInfo.width, windowInfo.height, windowSizeFlag)
    r.ImGui_SetNextWindowPos(ctx, windowInfo.left, windowInfo.top, windowSizeFlag)
  end
  if windowInfo.wantsResize then
    windowInfo.wantsResize = false
    windowInfo.wantsResizeUpdate = true
  end

  r.ImGui_SetNextWindowBgAlpha(ctx, 1.0)

  if not winHeight then
    r.ImGui_PushFont(ctx, fontInfo.large)
    winHeight = r.ImGui_GetFrameHeightWithSpacing(ctx) * 19
    r.ImGui_PushFont(ctx, fontInfo.small)
    winHeight = winHeight + (r.ImGui_GetFrameHeightWithSpacing(ctx) * 9)
    r.ImGui_PopFont(ctx)
    winHeight = winHeight + ((fontInfo.largeSize - CANONICAL_FONTSIZE_LARGE) * 5)
    r.ImGui_PopFont(ctx)
  end

  r.ImGui_SetNextWindowSizeConstraints(ctx, windowInfo.defaultWidth, winHeight, windowInfo.defaultWidth * 3, winHeight)

  r.ImGui_PushFont(ctx, fontInfo.small)
  r.ImGui_SetNextWindowDockID(ctx, ~0, r.ImGui_Cond_Appearing()) --, r.ImGui_Cond_Appearing()) -- TODO docking
  local visible, open = r.ImGui_Begin(ctx, titleBarText .. '###' .. scriptID, true,
                                        r.ImGui_WindowFlags_TopMost()
                                      + r.ImGui_WindowFlags_NoScrollWithMouse()
                                      + r.ImGui_WindowFlags_NoScrollbar()
                                      + r.ImGui_WindowFlags_NoSavedSettings())

  if r.ImGui_IsWindowDocked(ctx) then
    r.ImGui_Text(ctx, titleBarText)
    r.ImGui_Separator(ctx)
  end
  r.ImGui_PopFont(ctx)

  if r.ImGui_IsWindowAppearing(ctx) then
    viewPort = r.ImGui_GetWindowViewport(ctx)
  end

  return visible, open
end

-----------------------------------------------------------------------------
-------------------------------- MAIN LOOP ----------------------------------

local prepped = false

local function loop()

  if isClosing then
    doClose()
    return
  end

  canvasScale = windowInfo.width / windowInfo.defaultWidth
  if canvasScale > 2 then canvasScale = 2 end

  updateFonts()

  local visible, open = openWindow()
  if visible then
    r.ImGui_PushFont(ctx, fontInfo.large)

    if not prepped then
      r.ImGui_PushFont(ctx, canonicalFont)
      canonicalFontWidth = r.ImGui_CalcTextSize(ctx, '0', nil, nil)
      currentFontWidth = canonicalFontWidth
      currentFrameHeight = r.ImGui_GetFrameHeight(ctx)
      currentFrameHeightEx = r.ImGui_GetFrameHeightWithSpacing(ctx)
      currentFrameHeightEx = currentFrameHeight + math.ceil(((currentFrameHeightEx - currentFrameHeight) / 2) + 0.5)
      r.ImGui_PopFont(ctx)
      prepped = true
    else
      currentFontWidth = r.ImGui_CalcTextSize(ctx, '0', nil, nil)
      DEFAULT_ITEM_WIDTH = 10 * currentFontWidth -- (currentFontWidth / canonicalFontWidth)
      currentFrameHeight = r.ImGui_GetFrameHeight(ctx)
      currentFrameHeightEx = r.ImGui_GetFrameHeightWithSpacing(ctx)
      currentFrameHeightEx = currentFrameHeight + math.ceil(((currentFrameHeightEx - currentFrameHeight) / 2) + 0.5)
      fontWidScale = currentFontWidth / canonicalFontWidth
    end

    r.ImGui_BeginGroup(ctx)
    windowFn()
    r.ImGui_SetCursorPos(ctx, 0, 0)
    local ww, wh = r.ImGui_GetContentRegionMax(ctx)
    r.ImGui_Dummy(ctx, ww, wh)
    r.ImGui_EndGroup(ctx)

    -- handle drag and drop of preset files using the entire frame
    if r.ImGui_BeginDragDropTarget(ctx) then
      if r.ImGui_AcceptDragDropPayloadFiles(ctx) then
        local retdrag, filedrag = r.ImGui_GetDragDropPayloadFile(ctx, 0)
        if retdrag and string.match(filedrag, presetExt .. '$') then
          local success, notes, ignoreSelectInArrange = tx.loadPreset(filedrag)
          if success then
            presetLabel = string.match(filedrag, '.*[/\\](.*)' .. presetExt)
            endPresetLoad(presetLabel, notes, ignoreSelectInArrange)
          end
        end
      end
      r.ImGui_EndDragDropTarget(ctx)
    end

    r.ImGui_PopFont(ctx)

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

-----------------------------------------------------------------------------
----------------------------------- FIN -------------------------------------
