-- @description MIDI Transformer
-- @version 1.0-alpha.0
-- @author sockmonkey72
-- @about
--   # MIDI Transformer
-- @changelog
--   - initial
-- @provides
--   Transformer/MIDIUtils.lua https://raw.githubusercontent.com/jeremybernstein/ReaScripts/main/MIDI/MIDIUtils.lua
--   [main=main,midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Transformer.lua

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

-- metric grid: dotted/triplet, slop, length of range, reset at next bar after pattern concludes (added to end of menu?)
-- TODO: time input
-- TODO: functions

local r = reaper

package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
local mu = require 'MIDIUtils'
mu.ENFORCE_ARGS = false -- turn off type checking
mu.CORRECT_OVERLAPS = true
mu.CLAMP_MIDI_BYTES = true

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'Transformer/?.lua'
-- local mu = require 'MIDIUtils'
local tx = require 'TransformerLib'

local function fileExists(name)
  local f = io.open(name,'r')
  if f ~= nil then io.close(f) return true else return false end
end

local canStart = true

local imGuiPath = r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua'
if not fileExists(imGuiPath) then
  mu.post('MIDI Transformer requires \'ReaImGui\' 0.8+ (install from ReaPack)\n')
  canStart = false
end

if not r.APIExists('JS_Mouse_GetState') then
  mu.post('MIDI Transformer requires the \'js_ReaScriptAPI\' extension (install from ReaPack)\n')
  canStart = false
end

if not mu.CheckDependencies('MIDI Transformer') then
  canStart = false
end

if not canStart then return end

dofile(r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8')

local scriptID = 'sockmonkey72_Transformer'

local ctx = r.ImGui_CreateContext(scriptID)
r.ImGui_SetConfigVar(ctx, r.ImGui_ConfigVar_DockingWithShift(), 1) -- TODO docking

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local viewPort

local FONTSIZE_LARGE = 13
local FONTSIZE_SMALL = 11
local DEFAULT_WIDTH = 68 * FONTSIZE_LARGE
local DEFAULT_HEIGHT = 40 * FONTSIZE_LARGE
local DEFAULT_ITEM_WIDTH = 70

local PAREN_COLUMN_WIDTH = 20

local windowInfo
local fontInfo

local canvasScale = 1.0

local function scaled(num)
  return num * canvasScale
end

local DEFAULT_TITLEBAR_TEXT = 'Transformer'
local titleBarText = DEFAULT_TITLEBAR_TEXT
local focusKeyboardHere

local disabledAutoOverlap = false
local dockID = 0

local findConsoleText = ''
local actionConsoleText = ''

local presetTable = {}
local presetLabel = ''
local presetInputVisible = false
local presetInputDoesScript = false

local lastInputTextBuffer = ''
local inOKDialog = false
local statusMsg = ''
local statusTime = nil
local statusContext = 0

local findParserError = ''

local refocusInput = false

local metricLastUnit = 3 -- 1/16 in findMetricGridParam1Entries
local metricLastBarRestart = false

local DEFAULT_TIMEFORMAT_STRING = '1.1.00'
local DEFAULT_LENGTHFORMAT_STRING = '0.0.00'

local isClosing = false

local selectedFindRow = 0
local selectedActionRow = 0

local showTimeFormatColumn = false

local defaultFindRow
local defaultActionRow

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

local function addFindRow(idx, row)
  local findRowTable = tx.findRowTable()
  idx = (idx and idx ~= 0) and idx or #findRowTable+1

  if not row then
    if defaultFindRow then
      tx.processFindMacro(defaultFindRow)
      selectedFindRow = idx
      return
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
end

local function removeFindRow()
  local findRowTable = tx.findRowTable()
  if selectedFindRow ~= 0 then
    table.remove(findRowTable, selectedFindRow) -- shifts
    selectedFindRow = selectedFindRow <= #findRowTable and selectedFindRow or #findRowTable
  end
end

local function setupActionRowFormat(row, opTab)
  if tx.actionTargetEntries[row.targetEntry].notation == '$length' or opTab[row.operationEntry].timedur then
    row.param1TimeFormatStr = DEFAULT_LENGTHFORMAT_STRING
    row.param2TimeFormatStr = DEFAULT_LENGTHFORMAT_STRING
  else
    row.param1TimeFormatStr = DEFAULT_TIMEFORMAT_STRING
    row.param2TimeFormatStr = DEFAULT_TIMEFORMAT_STRING
  end
end

local function addActionRow(idx, row)
  local actionRowTable = tx.actionRowTable()
  idx = (idx and idx ~= 0) and idx or #actionRowTable+1

  if not row then
    if defaultActionRow then
      tx.processActionMacro(defaultActionRow)
      selectedActionRow = idx
      return
    end

    row = tx.ActionRow()
    local opTab = tx.actionTargetToTabs(row.targetEntry)
    setupActionRowFormat(row, opTab)
  end

  table.insert(actionRowTable, idx, row)
  selectedActionRow = idx
end

local function removeActionRow()
  local actionRowTable = tx.actionRowTable()
  if selectedActionRow ~= 0 then
    table.remove(actionRowTable, selectedActionRow) -- shifts
    selectedActionRow = selectedActionRow <= #actionRowTable and selectedActionRow or #actionRowTable
  end
end

local function handleExtState()
  local state

  state = r.GetExtState(scriptID, 'defaultFindRow')
  if state and state ~= '' then
    defaultFindRow = state
  end

  state = r.GetExtState(scriptID, 'defaultActionRow')
  if state and state ~= '' then
    defaultActionRow = state
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
  fontInfo.largeDefaultSize = FONTSIZE_LARGE
  fontInfo.smallDefaultSize = FONTSIZE_SMALL

  windowInfo.defaultWidth = 68 * fontInfo.largeDefaultSize
  windowInfo.defaultHeight = 40 * fontInfo.smallDefaultSize
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

-----------------------------------------------------------------------------
-------------------------------- THE GUTS -----------------------------------

local ppqToTime -- forward declaration to avoid vs.code warning

local function windowFn()

  ---------------------------------------------------------------------------
  --------------------------- BUNCH OF VARIABLES ----------------------------

  local vx, vy = r.ImGui_GetWindowPos(ctx)
  local handledEscape = false

  local hoverCol = r.ImGui_GetStyleColor(ctx, r.ImGui_Col_HeaderHovered())
  local hoverAlphaCol = (hoverCol &~ 0xFF) | 0x3F
  local activeCol = r.ImGui_GetStyleColor(ctx, r.ImGui_Col_HeaderActive())
  local activeAlphaCol = (activeCol &~ 0xFF) | 0x7F
  local _, framePaddingY = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE FUNS -----------------------------

  local currentRect = {}

  local function updateCurrentRect()
    -- cache the positions to generate next box position
    currentRect.left, currentRect.top = r.ImGui_GetItemRectMin(ctx)
    currentRect.right, currentRect.bottom = r.ImGui_GetItemRectMax(ctx)
    currentRect.right = currentRect.right + scaled(20) -- add some spacing after the button
  end

  local function generateLabel(label)
    -- local oldX, oldY = r.ImGui_GetCursorPos(ctx)
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
    r.ImGui_SetCursorPos(ctx, minx + 1, miny)
    r.ImGui_Text(ctx, label)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopFont(ctx)
    --r.ImGui_SetCursorPos(ctx, oldX, oldY)
  end

  local function kbdEntryIsCompleted(retval)
    return (retval and (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
              or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Tab())
              or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())))
            or r.ImGui_IsItemDeactivated(ctx)
  end

  ---------------------------------------------------------------------------
  ------------------------------ TITLEBAR TEXT ------------------------------

  titleBarText = DEFAULT_TITLEBAR_TEXT

  ---------------------------------------------------------------------------
  --------------------------------- UTILITIES -------------------------------

  -- https://stackoverflow.com/questions/1340230/check-if-directory-exists-in-lua
  --- Check if a file or directory exists in this path
  local function filePathExists(file)
    local ok, err, code = os.rename(file, file)
    if not ok then
      if code == 13 then
      -- Permission denied, but it exists
        return true
      end
    end
    return ok, err
  end

    --- Check if a directory exists in this path
  local function dirExists(path)
    -- "/" works on both Unix and Windows
    return filePathExists(path:match('/$') and path or path..'/')
  end

  local function ensureNumString(str, range)
    local num = tonumber(str)
    if not num then num = 0 end
    if range then
      if range[1] and num < range[1] then num = range[1] end
      if range[2] and num > range[2] then num = range[2] end
    end
    return tostring(num)
  end

  local presetPath = r.GetResourcePath() .. '/Scripts/Transformer Presets/'
  local presetExt = '.tfmrPreset'

  local function spairs(t, order) -- sorted iterator (https://stackoverflow.com/questions/15706270/sort-a-table-in-lua)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end
    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys
    if order then
      table.sort(keys, function(a,b) return order(t, a, b) end)
    else
      table.sort(keys)
    end
    -- return the iterator function
    local i = 0
    return function()
      i = i + 1
      if keys[i] then
        return keys[i], t[keys[i]]
      end
    end
  end

  local function enumerateTransformerPresets()
    if not dirExists(presetPath) then return {} end

    local idx = 0
    local fnames = {}

    r.EnumerateFiles(presetPath, -1)
    local fname = r.EnumerateFiles(presetPath, idx)
    while fname do
      if fname:match('%' .. presetExt .. '$') then
        fname = { label = fname:gsub('%' .. presetExt .. '$', '') }
        table.insert(fnames, fname)
      end
      idx = idx + 1
      fname = r.EnumerateFiles(presetPath, idx)
    end
    local sorted = {}
    for _, v in spairs(fnames, function (t, a, b) return string.lower(t[a].label) < string.lower(t[b].label) end) do
      table.insert(sorted, v)
    end
    return sorted
  end

  ---------------------------------------------------------------------------
  ------------------------------- PRESET RECALL -----------------------------

  r.ImGui_Spacing(ctx)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Button(ctx, 'Recall Preset...', scaled(DEFAULT_ITEM_WIDTH) * 1.5)
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    presetTable = enumerateTransformerPresets()
    if #presetTable ~= 0 then
      r.ImGui_OpenPopup(ctx, 'openPresetMenu') -- defined far below
    end
  end

  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, 0x00AAFFFF, presetLabel)

  ---------------------------------------------------------------------------
  --------------------------------- FIND ROWS -------------------------------

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x006655FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x008877FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x007766FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x006655FF)

  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_SetNextItemWidth(ctx, scaled(DEFAULT_ITEM_WIDTH))

  local optDown = false
  if r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_Alt() then
    optDown = true
  end

  r.ImGui_Button(ctx, 'Insert Criteria', scaled(DEFAULT_ITEM_WIDTH) * 1.5)
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    addFindRow()
  end

  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, scaled(DEFAULT_ITEM_WIDTH))
  if selectedFindRow == 0 then
    r.ImGui_BeginDisabled(ctx)
  end
  r.ImGui_Button(ctx, optDown and 'Clear All Criteria' or 'Remove Criteria', scaled(DEFAULT_ITEM_WIDTH) * 1.5)
  if selectedFindRow == 0 then
    r.ImGui_EndDisabled(ctx)
  end

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    if optDown then
      tx.clearFindRows()
      selectedFindRow = 0
    else
      removeFindRow()
    end
  end

  local numbersOnlyCallback = r.ImGui_CreateFunctionFromEEL([[
    (EventChar < '0' || EventChar > '9') && EventChar != '-' ? EventChar = 0;
  ]])

  local timeFormatOnlyCallback = r.ImGui_CreateFunctionFromEEL([[
    (EventChar < '0' || EventChar > '9') && EventChar != '-' && EventChar != ':' && EventChar != '.' ? EventChar = 0;
  ]])

  local function handleTableParam(row, condOp, paramName, paramTab, paramType, needsTerms, idx, procFn)
    local rv = 0
    if paramType == tx.PARAM_TYPE_METRICGRID and needsTerms == 1 then paramType = tx.PARAM_TYPE_MENU end -- special case, sorry
    local decimalFlags = r.ImGui_InputTextFlags_CharsDecimal() + r.ImGui_InputTextFlags_CharsNoBlank()
    if condOp.terms >= needsTerms then
        local targetTab = row:is_a(tx.FindRow) and tx.findTargetEntries or tx.actionTargetEntries
        local target = targetTab[row.targetEntry]
        if paramType == tx.PARAM_TYPE_MENU then
        r.ImGui_Button(ctx, #paramTab ~= 0 and paramTab[row[paramName .. 'Entry']].label or '---')
        if (#paramTab ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
          rv = idx
          r.ImGui_OpenPopup(ctx, paramName .. 'Menu')
        end
      elseif paramType == tx.PARAM_TYPE_TEXTEDITOR or paramType == tx.PARAM_TYPE_METRICGRID then -- for now
        r.ImGui_BeginGroup(ctx)
        local retval, buf = r.ImGui_InputText(ctx, '##' .. paramName .. 'edit', row[paramName .. 'TextEditorStr'], condOp.decimal and decimalFlags or r.ImGui_InputTextFlags_CallbackCharFilter(), condOp.decimal and nil or numbersOnlyCallback)
        if kbdEntryIsCompleted(retval) then
          row[paramName .. 'TextEditorStr'] = paramType == tx.PARAM_TYPE_METRICGRID and buf or ensureNumString(buf, condOp.range and condOp.range or target.range)
          procFn()
        end
        r.ImGui_EndGroup(ctx)
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
          rv = idx
        end
      elseif paramType == tx.PARAM_TYPE_TIME or paramType == tx.PARAM_TYPE_TIMEDUR then
        -- time format depends on PPQ column value
        r.ImGui_BeginGroup(ctx)
        local retval, buf = r.ImGui_InputText(ctx, '##' .. paramName .. 'edit', row[paramName .. 'TimeFormatStr'], r.ImGui_InputTextFlags_CallbackCharFilter(), timeFormatOnlyCallback)
        if kbdEntryIsCompleted(retval) then
          row[paramName .. 'TimeFormatStr'] = paramType == tx.PARAM_TYPE_TIMEDUR and tx.lengthFormatRebuf(buf) or tx.timeFormatRebuf(buf)
          procFn()
        end
        r.ImGui_EndGroup(ctx)
        if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
          rv = idx
        end
      end
    end
    return rv
  end

  r.ImGui_SameLine(ctx)
  local fcrv, fcbuf = r.ImGui_InputText(ctx, '##findConsole', findConsoleText)
  if kbdEntryIsCompleted(fcrv) then
    findConsoleText = fcbuf
    tx.processFindMacro(findConsoleText)
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE GEN ------------------------------

  -- requires userValues, above

  local function lengthFormatToSeconds(buf)
    -- b.b.f vs h:m.s vs ...?
    local tbars, tbeats, tfraction = string.match(buf, '(%d+)%.(%d+)%.(%d+)')
    local bars = tonumber(tbars)
    local beats = tonumber(tbeats)
    local fraction = tonumber(tfraction)
    fraction = not fraction and 0 or fraction > 99 and 99 or fraction < 0 and 0 or fraction
    return r.TimeMap2_beatsToTime(0, beats + (fraction / 100.), bars)
  end

  local function timeFormatToSeconds(buf)
    -- b.b.f vs h:m.s vs ...?
    local tbars, tbeats, tfraction = string.match(buf, '(%d+)%.(%d+)%.(%d+)')
    local bars = tonumber(tbars)
    local beats = tonumber(tbeats)
    local fraction = tonumber(tfraction)
    fraction = not fraction and 0 or fraction > 99 and 99 or fraction < 0 and 0 or fraction
    return r.TimeMap2_beatsToTime(0, beats + (fraction / 100.), bars)
  end

  local mainValueLabel
  local subtypeValueLabel

  local function decorateTargetLabel(label)
    if label == 'Value 1' then
      label = label .. ((subtypeValueLabel and subtypeValueLabel ~= '') and ' (' .. subtypeValueLabel .. ')' or '')
    elseif label == 'Value 2' then
      label = label .. ((mainValueLabel and mainValueLabel ~= '') and ' (' .. mainValueLabel .. ')' or '')
    end
    return label
  end

  local function createPopup(name, source, selEntry, fun, special)
    if r.ImGui_BeginPopup(ctx, name) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        if r.ImGui_IsPopupOpen(ctx, name, r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
          r.ImGui_CloseCurrentPopup(ctx)
          handledEscape = true
        end
      end

      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x00000000)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), 0x00000000)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), 0x00000000)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

      local mousePos = {}
      mousePos.x, mousePos.y = r.ImGui_GetMousePos(ctx)
      local windowRect = {}
      windowRect.left, windowRect.top = r.ImGui_GetWindowPos(ctx)
      windowRect.right, windowRect.bottom = r.ImGui_GetWindowSize(ctx)
      windowRect.right = windowRect.right + windowRect.left
      windowRect.bottom = windowRect.bottom + windowRect.top

      for i = 1, #source do
        local selectText = source[i].label
        if source.targetTable then
          selectText = decorateTargetLabel(selectText)
        end
        local factoryFn = selEntry == -1 and r.ImGui_Selectable or r.ImGui_Checkbox
        local oldX = r.ImGui_GetCursorPosX(ctx)
        r.ImGui_BeginGroup(ctx)
        local rv, selected = factoryFn(ctx, selectText, selEntry == i and true or false)
        r.ImGui_SameLine(ctx)
        r.ImGui_SetCursorPosX(ctx, oldX) -- ugly, but the selectable needs info from the checkbox
        local rect = {}
        local _, itemTop = r.ImGui_GetItemRectMin(ctx)
        local _, itemBottom = r.ImGui_GetItemRectMax(ctx)
        local inVert = mousePos.y >= itemTop + framePaddingY and mousePos.y <= itemBottom - framePaddingY and mousePos.x >= windowRect.left and mousePos.x <= windowRect.right
        local srv = r.ImGui_Selectable(ctx, '##popup' .. i .. 'Selectable', inVert, r.ImGui_SelectableFlags_AllowItemOverlap())
        r.ImGui_EndGroup(ctx)

        if rv or srv then
          if selected or srv then fun(i) end
          r.ImGui_CloseCurrentPopup(ctx)
        end
      end

      r.ImGui_PopStyleColor(ctx, 5)

      if special then special(fun) end
      r.ImGui_EndPopup(ctx)
    end
  end

  ----------------------------------------------
  ---------- SELECTION CRITERIA TABLE ----------
  ----------------------------------------------

  local timeFormatColumnName = 'Bar Range/Time Base'

  local findColumns = {
    '(',
    'Target',
    'Condition',
    'Parameter 1',
    'Parameter 2',
    timeFormatColumnName,
    ')',
    'Boolean'
  }

  r.ImGui_BeginTable(ctx, 'Selection Criteria', #findColumns - (showTimeFormatColumn == false and 1 or 0), r.ImGui_TableFlags_ScrollY() + r.ImGui_TableFlags_BordersInnerH(), 0, r.ImGui_GetFrameHeightWithSpacing(ctx) * 6.2)

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
  for _, label in ipairs(findColumns) do
    if showTimeFormatColumn or label ~= timeFormatColumnName then
      local narrow = (label == '(' or label == ')' or label == 'Boolean')
      local flags = narrow and r.ImGui_TableColumnFlags_WidthFixed() or r.ImGui_TableColumnFlags_WidthStretch()
      local colwid = narrow and (label == 'Boolean' and scaled(70) or scaled(PAREN_COLUMN_WIDTH)) or nil
      r.ImGui_TableSetupColumn(ctx, label, flags, colwid)
    end
  end
  r.ImGui_TableHeadersRow(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)

  for k, v in ipairs(tx.findRowTable()) do
    if tx.findTargetEntries[v.targetEntry].notation == '$type' then
      local label = tx.GetSubtypeValueLabel(v.param1Entry)
      if not subtypeValueLabel or subtypeValueLabel == label then subtypeValueLabel = label
      else subtypeValueLabel = 'Multiple'
      end
      label = tx.GetMainValueLabel(v.param1Entry)
      if not mainValueLabel or mainValueLabel == label then mainValueLabel = label
      else mainValueLabel = 'Multiple'
      end
    end
  end

  if not subtypeValueLabel then subtypeValueLabel = tx.GetSubtypeValueLabel(1) end
  if not mainValueLabel then mainValueLabel = tx.GetMainValueLabel(1) end

  for k, v in ipairs(tx.findRowTable()) do
    r.ImGui_PushID(ctx, tostring(k))
    local currentRow = v
    local currentFindTarget = {}
    local currentFindCondition = {}
    local conditionEntries = {}
    local param1Entries = {}
    local param2Entries = {}

    conditionEntries, param1Entries, param2Entries, currentFindTarget, currentFindCondition = tx.prepFindEntries(currentRow)

    r.ImGui_TableNextRow(ctx)

    if k == selectedFindRow then
      r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg0(), 0x77FFFF1F)
    end

    r.ImGui_TableSetColumnIndex(ctx, 0) -- '('
    if currentRow.startParenEntry < 2 then
      r.ImGui_InvisibleButton(ctx, '##startParen', scaled(PAREN_COLUMN_WIDTH), r.ImGui_GetFrameHeight(ctx)) -- or we can't test hover/click properly
    else
      r.ImGui_Button(ctx, tx.startParenEntries[currentRow.startParenEntry].label)
    end
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      r.ImGui_OpenPopup(ctx, 'startParenMenu')
      selectedFindRow = k
    end

    r.ImGui_TableSetColumnIndex(ctx, 1) -- 'Target'
    local targetText = currentRow.targetEntry > 0 and currentFindTarget.label or '---'
    r.ImGui_Button(ctx, decorateTargetLabel(targetText))
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedFindRow = k
      r.ImGui_OpenPopup(ctx, 'targetMenu')
    end

    r.ImGui_TableSetColumnIndex(ctx, 2) -- 'Condition'
    r.ImGui_Button(ctx, #conditionEntries ~= 0 and currentFindCondition.label or '---')
    if (#conditionEntries ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedFindRow = k
      r.ImGui_OpenPopup(ctx, 'conditionMenu')
    end

    local paramType = tx.getEditorTypeForRow(currentFindTarget, currentFindCondition)
    local selected

    r.ImGui_TableSetColumnIndex(ctx, 3) -- 'Parameter 1'
    selected = handleTableParam(currentRow, currentFindCondition, 'param1', param1Entries, paramType, 1, k, tx.processFind)
    if selected and selected > 0 then selectedFindRow = selected end

    r.ImGui_TableSetColumnIndex(ctx, 4) -- 'Parameter 2'
    selected = handleTableParam(currentRow, currentFindCondition, 'param2', param2Entries, paramType, 2, k, tx.processFind)
    if selected and selected > 0 then selectedFindRow = selected end

    if showTimeFormatColumn then
      r.ImGui_TableSetColumnIndex(ctx, 5) -- Time format
      if (paramType == tx.PARAM_TYPE_TIME or paramType == tx.PARAM_TYPE_TIMEDUR) and currentFindCondition.terms ~= 0 then
        r.ImGui_Button(ctx, tx.findTimeFormatEntries[currentRow.timeFormatEntry].label or '---')
        if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
          selectedFindRow = k
          r.ImGui_OpenPopup(ctx, 'timeFormatMenu')
        end
      end
    end

    r.ImGui_TableSetColumnIndex(ctx, 6 - (showTimeFormatColumn == false and 1 or 0)) -- End Paren
    if currentRow.endParenEntry < 2 then
      r.ImGui_InvisibleButton(ctx, '##endParen', scaled(PAREN_COLUMN_WIDTH), r.ImGui_GetFrameHeight(ctx)) -- or we can't test hover/click properly
    else
      r.ImGui_Button(ctx, tx.endParenEntries[currentRow.endParenEntry].label)
    end
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      r.ImGui_OpenPopup(ctx, 'endParenMenu')
      selectedFindRow = k
    end

    r.ImGui_TableSetColumnIndex(ctx, 7 - (showTimeFormatColumn == false and 1 or 0)) -- Boolean
    if k ~= #tx.findRowTable() then
      r.ImGui_Button(ctx, tx.findBooleanEntries[currentRow.booleanEntry].label or '---', 50)
      if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
        currentRow.booleanEntry = currentRow.booleanEntry == 1 and 2 or 1
        selectedFindRow = k
        tx.processFind()
      end
    end

    r.ImGui_SameLine(ctx)

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
    r.ImGui_BeginGroup(ctx)
    if r.ImGui_Selectable(ctx, '##rowGroup', false, r.ImGui_SelectableFlags_SpanAllColumns() | r.ImGui_SelectableFlags_AllowItemOverlap()) then
      selectedFindRow = k
    end
    r.ImGui_EndGroup(ctx)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopStyleColor(ctx)

    if r.ImGui_IsMouseClicked(ctx, r.ImGui_MouseButton_Right()) then
      r.ImGui_OpenPopup(ctx, 'defaultFindRow')
    end

    if r.ImGui_BeginPopup(ctx, 'defaultFindRow') then
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

    createPopup('startParenMenu', tx.startParenEntries, currentRow.startParenEntry, function(i)
        currentRow.startParenEntry = i
        tx.processFind()
      end)

    createPopup('endParenMenu', tx.endParenEntries, currentRow.endParenEntry, function(i)
        currentRow.endParenEntry = i
        tx.processFind()
      end)

    createPopup('targetMenu', tx.findTargetEntries, currentRow.targetEntry, function(i)
        currentRow:init()
        currentRow.targetEntry = i
        if tx.findTargetEntries[currentRow.targetEntry].notation == '$length' then
          currentRow.param1TimeFormatStr = DEFAULT_LENGTHFORMAT_STRING
          currentRow.param2TimeFormatStr = DEFAULT_LENGTHFORMAT_STRING
        end
        tx.processFind()
      end)

    createPopup('conditionMenu', conditionEntries, currentRow.conditionEntry, function(i)
        currentRow.conditionEntry = i
        if string.match(conditionEntries[i].notation, 'metricgrid') then
          currentRow.param1Entry = metricLastUnit
          currentRow.mg = {
            wantsBarRestart = metricLastBarRestart,
            preSlopPercent = 0,
            postSlopPercent = 0,
            modifiers = 0
          }
        end
        tx.processFind()
      end)

    local function metricParam1Special(fun)
      r.ImGui_Separator(ctx)

      local mg = currentRow.mg

      local rv, sel = r.ImGui_Checkbox(ctx, 'Dotted', mg.modifiers & 1 ~= 0)
      if rv then
        mg.modifiers = sel and 1 or 0
        fun(1, true)
      end

      rv, sel = r.ImGui_Checkbox(ctx, 'Triplet', mg.modifiers & 2 ~= 0)
      if rv then
        mg.modifiers = sel and 2 or 0
        fun(2, true)
      end

      r.ImGui_Separator(ctx)

      rv, sel = r.ImGui_Checkbox(ctx, 'Restart pattern at next bar', mg.wantsBarRestart)
      if rv then
        mg.wantsBarRestart = sel
        fun(3, true)
      end
      r.ImGui_Text(ctx, 'Slop (% of unit)')
      r.ImGui_SameLine(ctx)
      local tbuf
      rv, tbuf = r.ImGui_InputDouble(ctx, '##slopPreInput', mg.preSlopPercent, nil, nil, '%0.2f') -- TODO: regular text input (allow float)
      if kbdEntryIsCompleted(rv) then
        mg.preSlopPercent = tbuf
        fun(4, true)
      end
      r.ImGui_SameLine(ctx)
      rv, tbuf = r.ImGui_InputDouble(ctx, '##slopPostInput', mg.postSlopPercent, nil, nil, '%0.2f') -- TODO: regular text input (allow float)
      if kbdEntryIsCompleted(rv) then
        mg.postSlopPercent = tbuf
        fun(5, true)
      end
    end

    createPopup('param1Menu', param1Entries, currentRow.param1Entry, function(i, isSpecial)
        if not isSpecial then
          currentRow.param1Entry = i
          currentRow.param1Val = param1Entries[i]
          if string.match(conditionEntries[currentRow.conditionEntry].notation, 'metricgrid') then
            metricLastUnit = i
          end
        end
        tx.processFind()
      end,
      paramType == tx.PARAM_TYPE_METRICGRID and metricParam1Special or nil)

    createPopup('param2Menu', param2Entries, currentRow.param2Entry, function(i)
        currentRow.param2Entry = i
        currentRow.param2Val = param2Entries[i]
        tx.processFind()
      end)

    if showTimeFormatColumn then
      createPopup('timeFormatMenu', tx.findTimeFormatEntries, currentRow.timeFormatEntry, function(i)
          currentRow.timeFormatEntry = i
          tx.processFind()
        end)
    end

    r.ImGui_PopID(ctx)
  end

  r.ImGui_EndTable(ctx)

  updateCurrentRect()

  local oldY = r.ImGui_GetCursorPosY(ctx)

  generateLabel('Selection Criteria')

  r.ImGui_SetCursorPosY(ctx, oldY + scaled(20))

  ---------------------------------------------------------------------------
  ------------------------------- FIND BUTTONS ------------------------------

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  r.ImGui_AlignTextToFramePadding(ctx)

  r.ImGui_Button(ctx, tx.findScopeTable[tx.currentFindScope()].label, scaled(150))
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'findScopeMenu')
  end

  r.ImGui_SameLine(ctx)
  local oldX, oldY = r.ImGui_GetCursorPos(ctx)

  updateCurrentRect()
  generateLabel('Selection Scope')

  r.ImGui_SetCursorPos(ctx, oldX + 20, oldY)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, findParserError)

  r.ImGui_SameLine(ctx)

  createPopup('findScopeMenu', tx.findScopeTable, tx.currentFindScope(), function(i)
      tx.setCurrentFindScope(i)
    end)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)

  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)

  ---------------------------------------------------------------------------
  -------------------------------- ACTION ROWS ------------------------------

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x550077FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x770099FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x660088FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x440066FF)

  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_SetNextItemWidth(ctx, scaled(DEFAULT_ITEM_WIDTH))

  r.ImGui_Button(ctx, 'Insert Action', scaled(DEFAULT_ITEM_WIDTH) * 1.5)
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    local numRows = #tx.actionRowTable()
    addActionRow()

    if numRows == 0 then
      local scope = tx.actionScopeTable[tx.currentActionScope()].notation
      if scope:match('select') then -- change to Transform scope if we're in a Select scope
        for k, v in ipairs(tx.actionScopeTable) do
          if v.notation == '$transform' then
            tx.setCurrentActionScope(k)
          end
        end
      end
    end
  end

  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, scaled(DEFAULT_ITEM_WIDTH))
  if selectedActionRow == 0 then
    r.ImGui_BeginDisabled(ctx)
  end
  r.ImGui_Button(ctx, optDown and 'Clear All Actions' or 'Remove Action', scaled(DEFAULT_ITEM_WIDTH) * 1.5)
  if selectedActionRow == 0 then
    r.ImGui_EndDisabled(ctx)
  end

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    if optDown then
      tx.clearActionRows()
      selectedActionRow = 0
    else
      removeActionRow()
    end
  end

  r.ImGui_SameLine(ctx)
  local acrv, acbuf = r.ImGui_InputText(ctx, '##actionConsole', actionConsoleText)
  if kbdEntryIsCompleted(acrv) then
    actionConsoleText = acbuf
    tx.processActionMacro(actionConsoleText)
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  ----------------------------------------------
  ---------------- ACTIONS TABLE ---------------
  ----------------------------------------------

  local actionColumns = {
    'Target',
    'Operation',
    'Parameter 1',
    'Parameter 2'
  }

  r.ImGui_BeginTable(ctx, 'Actions', #actionColumns, r.ImGui_TableFlags_ScrollY() + r.ImGui_TableFlags_BordersInnerH(), 0, r.ImGui_GetFrameHeightWithSpacing(ctx) * 6.2)

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

    operationEntries, param1Entries, param2Entries, currentActionTarget, currentActionOperation = tx.prepActionEntries(currentRow)

    r.ImGui_TableNextRow(ctx)

    if k == selectedActionRow then
      r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg0(), 0xFF77FF1F)
    end

    r.ImGui_TableSetColumnIndex(ctx, 0) -- 'Target'
    local targetText = currentRow.targetEntry > 0 and currentActionTarget.label or '---'
    r.ImGui_Button(ctx, decorateTargetLabel(targetText))
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedActionRow = k
      r.ImGui_OpenPopup(ctx, 'targetMenu')
    end

    r.ImGui_TableSetColumnIndex(ctx, 1) -- 'Operation'
    r.ImGui_Button(ctx, #operationEntries ~= 0 and currentActionOperation.label or '---')
    if (#operationEntries ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedActionRow = k
      r.ImGui_OpenPopup(ctx, 'operationMenu')
    end

    local paramType = tx.getEditorTypeForRow(currentActionTarget, currentActionOperation)
    local selected

    r.ImGui_TableSetColumnIndex(ctx, 2) -- 'Parameter 1'
    selected = handleTableParam(currentRow, currentActionOperation, 'param1', param1Entries, paramType, 1, k, tx.processAction)
    if selected and selected > 0 then selectedActionRow = selected end

    r.ImGui_TableSetColumnIndex(ctx, 3) -- 'Parameter 2'
    selected = handleTableParam(currentRow, currentActionOperation, 'param2', param2Entries, paramType, 2, k, tx.processAction)
    if selected and selected > 0 then selectedActionRow = selected end

    r.ImGui_SameLine(ctx)

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), 0x00000000)
    r.ImGui_BeginGroup(ctx)
    if r.ImGui_Selectable(ctx, '##rowGroup', false, r.ImGui_SelectableFlags_SpanAllColumns() | r.ImGui_SelectableFlags_AllowItemOverlap()) then
      selectedActionRow = k
    end
    r.ImGui_EndGroup(ctx)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopStyleColor(ctx)

    if r.ImGui_IsMouseClicked(ctx, r.ImGui_MouseButton_Right()) then
      r.ImGui_OpenPopup(ctx, 'defaultActionRow')
    end

    if r.ImGui_BeginPopup(ctx, 'defaultActionRow') then
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

    createPopup('targetMenu', tx.actionTargetEntries, currentRow.targetEntry, function(i)
        currentRow:init()
        currentRow.targetEntry = i
        setupActionRowFormat(currentRow, operationEntries)
        tx.processAction()
      end)

    createPopup('operationMenu', operationEntries, currentRow.operationEntry, function(i)
        currentRow.operationEntry = i
        setupActionRowFormat(currentRow, operationEntries)
        tx.processAction()
      end)

    createPopup('param1Menu', param1Entries, currentRow.param1Entry, function(i)
        currentRow.param1Entry = i
        currentRow.param1Val = param1Entries[i]
        tx.processAction()
      end)

    createPopup('param2Menu', param2Entries, currentRow.param2Entry, function(i)
        currentRow.param2Entry = i
        currentRow.param2Val = param2Entries[i]
        tx.processAction()
      end)

    r.ImGui_PopID(ctx)
  end

  r.ImGui_EndTable(ctx)

  updateCurrentRect();

  local oldY = r.ImGui_GetCursorPosY(ctx)

  generateLabel('Actions')

  r.ImGui_SetCursorPosY(ctx, oldY + scaled(20))

  ---------------------------------------------------------------------------
  ------------------------------ ACTION BUTTONS -----------------------------

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + scaled(20))

  r.ImGui_AlignTextToFramePadding(ctx)

  r.ImGui_Button(ctx, 'Apply')
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    tx.processAction(true)
  end

  r.ImGui_SameLine(ctx)

  r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + scaled(50))
  r.ImGui_Button(ctx, tx.actionScopeTable[tx.currentActionScope()].label, scaled(120))
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'actionScopeMenu')
  end
  updateCurrentRect()
  generateLabel('Action Scope')

  createPopup('actionScopeMenu', tx.actionScopeTable, tx.currentActionScope(), function(i)
      tx.setCurrentActionScope(i)
    end)

  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)

  r.ImGui_NewLine(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)
  r.ImGui_Spacing(ctx)

  r.ImGui_Button(ctx, (optDown or presetInputDoesScript) and 'Export Script...' or 'Save Preset...', scaled(DEFAULT_ITEM_WIDTH + 30))
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) or refocusInput then
    presetInputVisible = true
    presetInputDoesScript = optDown
    refocusInput = false
    r.ImGui_SetKeyboardFocusHere(ctx)
  end

  local function positionModalWindow(yOff)
    local winWid = 4 * DEFAULT_ITEM_WIDTH * canvasScale
    local winHgt = FONTSIZE_LARGE * 7
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

  local function handleOKDialog(title, text)
    local rv = false
    local retval = 0
    local doOK = false

    r.ImGui_PushFont(ctx, fontInfo.large)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

    if inOKDialog then
      positionModalWindow(r.ImGui_GetFrameHeight(ctx) / 2)
      r.ImGui_OpenPopup(ctx, title)
    elseif (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
      or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())) then
        doOK = true
    end

    if r.ImGui_BeginPopupModal(ctx, title, true, r.ImGui_WindowFlags_TopMost()) then
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
    local buf = lastInputTextBuffer
    if not buf:match('%' .. presetExt .. '$') then buf = buf .. presetExt end

    if not dirExists(presetPath) then r.RecursiveCreateDirectory(presetPath, 0) end

    path = presetPath .. buf
    return path, buf
  end

  local function doSavePreset(path, fname)
    local saved = tx.savePreset(path, presetInputDoesScript)
    statusMsg = (saved and 'Saved' or 'Failed to save') .. (presetInputDoesScript and ' + export' or '') .. ' ' .. fname
    statusTime = r.time_precise()
    statusContext = 2
    if saved then
      fname = fname:gsub('%' .. presetExt .. '$', '')
      presetLabel = fname
      if saved and presetInputDoesScript then
        local scriptPath = path:gsub('%' .. presetExt .. '$', '.lua')
        r.AddRemoveReaScript(true, 32060, scriptPath, false) -- add to MIDI Editors automagically -- is that desirable?
        r.AddRemoveReaScript(true, 32061, scriptPath, false)
        r.AddRemoveReaScript(true, 32062, scriptPath, false)
        r.AddRemoveReaScript(true, 0, scriptPath, true)
      end
    else
      presetLabel = ''
    end
  end

  local function manageSaveAndOverwrite(pathFn, saveFn, statusCtx, suppressOverwrite)
    if inOKDialog then
      if not lastInputTextBuffer or lastInputTextBuffer == '' then
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

    if lastInputTextBuffer and lastInputTextBuffer ~= '' then
      local okrv, okval = handleOKDialog('Overwrite File?', 'Overwrite file '..lastInputTextBuffer..'?')
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

  if presetInputVisible then
    r.ImGui_SameLine(ctx)
    r.ImGui_SetNextItemWidth(ctx, 3.75 * DEFAULT_ITEM_WIDTH * canvasScale)
    local retval, buf = r.ImGui_InputTextWithHint(ctx, '##presetname', 'Untitled', lastInputTextBuffer, r.ImGui_InputTextFlags_AutoSelectAll())
    if kbdEntryIsCompleted(retval) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        presetInputVisible = false
        presetInputDoesScript = false
        handledEscape = true
      else
        lastInputTextBuffer = buf
        inOKDialog = true
      end
    else
      lastInputTextBuffer = buf
    end
    manageSaveAndOverwrite(presetPathAndFilenameFromLastInput, doSavePreset, 2)
  end

  local function handleStatus(ctext)
    if statusMsg ~= '' and statusTime and statusContext == ctext then
      if r.time_precise() - statusTime > 3 then statusTime = nil statusMsg = '' statusContext = 0
      else
        r.ImGui_SameLine(ctx)
        r.ImGui_AlignTextToFramePadding(ctx)
        r.ImGui_Text(ctx, statusMsg)
      end
    end
  end

  handleStatus(2)

  createPopup('openPresetMenu', presetTable, -1, function(i)
      local filename = presetTable[i].label .. presetExt
      if tx.loadPreset(presetPath .. filename) then
        presetLabel = presetTable[i].label
        lastInputTextBuffer = presetLabel
      end
    end)


  ---------------------------------------------------------------------------
  ------------------------------- MOD KEYS ------------------------------

  -- note that the mod is only captured if the window is explicitly focused
  -- with a click. not sure how to fix this yet. TODO
  -- local mods = r.ImGui_GetKeyMods(ctx)
  -- local shiftdown = mods & r.ImGui_Mod_Shift() ~= 0

  -- current 'fix' is using the JS extension
  local mods = r.JS_Mouse_GetState(24) -- shift key
  -- local shiftdown = mods & 8 ~= 0
  -- local optdown = mods & 16 ~= 0
  -- local PPQCent = math.floor(PPQ * 0.01) -- for BBU conversion

  ---------------------------------------------------------------------------
  ------------------------------- ARROW KEYS ------------------------------

  -- escape key kills our arrow key focus
  if not handledEscape and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
    if focusKeyboardHere then focusKeyboardHere = nil
    else
      isClosing = true
      return
    end
  end

  -- local arrowAdjust = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_UpArrow()) and 1
  --                  or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_DownArrow()) and -1
  --                  or 0
  -- if arrowAdjust ~= 0 and (activeFieldName or focusKeyboardHere) then
  --   for _, hitTest in ipairs(itemBounds) do
  --     if (hitTest.name == focusKeyboardHere
  --         or hitTest.name == activeFieldName)
  --       and hitTest.name ~= 'textmsg'
  --     then
  --       if hitTest.recalcSelection and optdown then
  --         arrowAdjust = arrowAdjust * PPQ -- beats instead of ticks
  --       elseif needsBBUConversion(hitTest.name) then
  --         arrowAdjust = arrowAdjust * PPQCent
  --       end

  --       userValues[hitTest.name].operation = OP_ADD
  --       userValues[hitTest.name].opval = arrowAdjust
  --       changedParameter = hitTest.name
  --       if hitTest.recalcEvent then recalcEventTimes = true
  --       elseif hitTest.recalcSelection then recalcSelectionTimes = true
  --       else canProcess = true end
  --       if hitTest.name == activeFieldName then
  --         rewriteIDForAFrame = hitTest.name
  --         focusKeyboardHere = hitTest.name
  --       end
  --       break
  --     end
  --   end
  -- end

  ---------------------------------------------------------------------------
  ------------------------------- MOUSE SCROLL ------------------------------

  -- local vertMouseWheel = r.ImGui_GetMouseWheel(ctx)
  -- local mScrollAdjust = vertMouseWheel > 0 and -1 or vertMouseWheel < 0 and 1 or 0
  -- if reverseScroll then mScrollAdjust = mScrollAdjust * -1 end

  -- local posx, posy = r.ImGui_GetMousePos(ctx)
  -- posx = posx - vx
  -- posy = posy - vy
  -- if mScrollAdjust ~= 0 then
  --   if shiftdown then
  --     mScrollAdjust = mScrollAdjust * 3
  --   end

  --   for _, hitTest in ipairs(itemBounds) do
  --     if userValues[hitTest.name].operation == OP_ABS -- and userValues[hitTest.name].opval ~= INVALID
  --       and posy > hitTest.hity[1] and posy < hitTest.hity[2]
  --       and posx > hitTest.hitx[1] and posx < hitTest.hitx[2]
  --       and hitTest.name ~= 'textmsg'
  --     then
  --       if hitTest.name == activeFieldName then
  --         rewriteIDForAFrame = activeFieldName
  --       end

  --       if hitTest.name == 'ticks' and shiftdown then
  --         mScrollAdjust = mScrollAdjust > 1 and 5 or -5
  --       elseif hitTest.name == 'notedur' and shiftdown then
  --         mScrollAdjust = mScrollAdjust > 1 and 10 or -10
  --       end

  --       if hitTest.recalcSelection and optdown then
  --         mScrollAdjust = mScrollAdjust * PPQ -- beats instead of ticks
  --       elseif needsBBUConversion(hitTest.name) then
  --         mScrollAdjust = mScrollAdjust * PPQCent
  --       end

  --       userValues[hitTest.name].operation = OP_ADD
  --       userValues[hitTest.name].opval = mScrollAdjust
  --       changedParameter = hitTest.name
  --       if hitTest.recalcEvent then recalcEventTimes = true
  --       elseif hitTest.recalcSelection then recalcSelectionTimes = true
  --       else canProcess = true end
  --       break
  --     end
  --   end
  -- end

  -- if recalcEventTimes or recalcSelectionTimes then canProcess = true end

end

-----------------------------------------------------------------------------
--------------------------------- CLEANUP -----------------------------------

local function doClose()
  r.ImGui_Detach(ctx, fontInfo.large)
  r.ImGui_Detach(ctx, fontInfo.small)
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

  local newFontSize = math.floor(scaled(fontInfo[name..'DefaultSize']))
  if newFontSize < 1 then newFontSize = 1 end
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
  if dockID == 0 then
    r.ImGui_SetNextWindowSize(ctx, windowInfo.width, windowInfo.height, windowSizeFlag)
    r.ImGui_SetNextWindowPos(ctx, windowInfo.left, windowInfo.top, windowSizeFlag)
  end
  if windowInfo.wantsResize then
    windowInfo.wantsResize = false
    windowInfo.wantsResizeUpdate = true
  end

  r.ImGui_SetNextWindowBgAlpha(ctx, 1.0)

  r.ImGui_PushFont(ctx, fontInfo.large)
  local winheight = r.ImGui_GetFrameHeightWithSpacing(ctx) * 30
  r.ImGui_SetNextWindowSizeConstraints(ctx, windowInfo.defaultWidth, winheight, windowInfo.defaultWidth * 3, winheight)
  r.ImGui_PopFont(ctx)

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
-------------------------------- SHORTCUTS ----------------------------------

local function checkShortcuts()
  if r.ImGui_IsAnyItemActive(ctx) then return end

  local keyMods = r.ImGui_GetKeyMods(ctx)
  local modKey = keyMods == r.ImGui_Mod_Shortcut()
  local modShiftKey = keyMods == r.ImGui_Mod_Shortcut() + r.ImGui_Mod_Shift()
  local noMod = keyMods == 0

  if modKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then -- undo
    r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40013)
  elseif modShiftKey and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Z()) then -- redo
    r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40014)
  elseif noMod and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Space()) then -- play/pause
    r.MIDIEditor_OnCommand(r.MIDIEditor_GetActive(), 40016)
  end
end

-----------------------------------------------------------------------------
-------------------------------- MAIN LOOP ----------------------------------

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
    checkShortcuts()

    r.ImGui_PushFont(ctx, fontInfo.large)
    windowFn()
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
