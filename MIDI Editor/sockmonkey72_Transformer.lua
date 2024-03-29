-- @description MIDI Transformer
-- @version 1.0-alpha.1
-- @author sockmonkey72
-- @about
--   # MIDI Transformer
-- @changelog
--   - initial
-- @provides
--   Transformer/MIDIUtils.lua https://raw.githubusercontent.com/jeremybernstein/ReaScripts/main/MIDI/MIDIUtils.lua
--   Transformer/TransformerLib.lua
--   [main=main,midi_editor,midi_eventlisteditor,midi_inlineeditor] sockmonkey72_Transformer.lua

-----------------------------------------------------------------------------
--------------------------------- STARTUP -----------------------------------

-- TODO: bipolar multiplication / pitchbend

local versionStr = '1.0-alpha.1'

local r = reaper

-- local fontStyle = 'monospace'
local fontStyle = 'sans-serif'

local DEBUG = true

local mu

if DEBUG then
  package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI/?.lua'
  mu = require 'MIDIUtils' -- for post/tprint/whatever
end

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]..'Transformer/?.lua'
local tx = require 'TransformerLib'

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
--   r.ShowConsoleMsg('MIDI Transformer requires the \'js_ReaScriptAPI\' extension (install from ReaPack)\n')
--   canStart = false
-- end

local canReveal = true

if canStart and not r.APIExists('CF_LocateInExplorer') then
  r.ShowConsoleMsg('MIDI Transformer appreciates the presence of the SWS extension (install from ReaPack)\n')
  canReveal = false
end

if not canStart then return end

dofile(r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8')

local scriptID = 'sockmonkey72_Transformer'

local ctx = r.ImGui_CreateContext(scriptID)
r.ImGui_SetConfigVar(ctx, r.ImGui_ConfigVar_DockingWithShift(), 1)

local IMAGEBUTTON_SIZE = 13
local GearImage = r.ImGui_CreateImage(debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'Transformer/' .. 'gear_40031.png')
if GearImage then r.ImGui_Attach(ctx, GearImage) end

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local viewPort

local presetPath = r.GetResourcePath() .. '/Scripts/Transformer Presets'
local presetExt = '.tfmrPreset'

local CANONICAL_FONTSIZE_LARGE = 13
local FONTSIZE_LARGE = 13
local FONTSIZE_SMALL = 11
local DEFAULT_WIDTH = 68 * FONTSIZE_LARGE
local DEFAULT_HEIGHT = 40 * FONTSIZE_LARGE
local DEFAULT_ITEM_WIDTH = 70

local canonicalFont = r.ImGui_CreateFont(fontStyle, CANONICAL_FONTSIZE_LARGE)
r.ImGui_Attach(ctx, canonicalFont)

local PAREN_COLUMN_WIDTH = 20

local windowInfo
local fontInfo

local canonicalFontWidth

local currentFontWidth
local currentFrameHeight

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
local presetLabel = ''
local presetInputVisible = false
local presetInputDoesScript = false
local presetNotesBuffer = ''
local presetNotesViewEditor = false
local justChanged = false

local scriptWritesMainContext = true
local scriptWritesMIDIContexts = true
local refocusField = false

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

local lastSelectedRowType
local selectedFindRow = 0
local selectedActionRow = 0

local showTimeFormatColumn = false

local defaultFindRow
local defaultActionRow

local newHasTable = false
local inTextInput = false

-- local focuswait
-- local wantsRecede -- = tonumber(r.GetExtState('sm72_CreateCrossfade', 'ConfigWantsRecede'))
-- wantsRecede = (not wantsRecede or wantsRecede ~= 0) and 1 or 0

-- local function reFocus()
--   focuswait = 5
-- end

-----------------------------------------------------------------------------
----------------------------- GLOBAL FUNS -----------------------------------

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
  tx.processFind()
end

local function removeFindRow()
  local findRowTable = tx.findRowTable()
  if selectedFindRow ~= 0 then
    table.remove(findRowTable, selectedFindRow) -- shifts
    selectedFindRow = selectedFindRow <= #findRowTable and selectedFindRow or #findRowTable
    tx.processFind()
  end
end

local function setupRowFormat(row, condOpTab)
  local isFind = row:is_a(tx.FindRow)

  local target = tx.actionTargetEntries[row.targetEntry]
  local condOp = condOpTab[isFind and row.conditionEntry or row.operationEntry]
  local paramTypes = tx.getEditorTypesForRow(row, target, condOp)
  local p1 = DEFAULT_TIMEFORMAT_STRING
  local p2 = DEFAULT_TIMEFORMAT_STRING

  if target.notation == '$length' then
    p1 = DEFAULT_LENGTHFORMAT_STRING
    p2 = DEFAULT_LENGTHFORMAT_STRING
  end

  if paramTypes[1] == tx.PARAM_TYPE_TIMEDUR then p1 = DEFAULT_LENGTHFORMAT_STRING end
  if paramTypes[2] == tx.PARAM_TYPE_TIMEDUR then p2 = DEFAULT_LENGTHFORMAT_STRING end

  row.param1TimeFormatStr = p1
  row.param2TimeFormatStr = p2
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
    setupRowFormat(row, tx.actionOpTabFromTarget(row.targetEntry))
  end

  table.insert(actionRowTable, idx, row)
  selectedActionRow = idx
  lastSelectedRowType = 1
  tx.processAction()
end

local function removeActionRow()
  local actionRowTable = tx.actionRowTable()
  if selectedActionRow ~= 0 then
    table.remove(actionRowTable, selectedActionRow) -- shifts
    selectedActionRow = selectedActionRow <= #actionRowTable and selectedActionRow or #actionRowTable
    lastSelectedRowType = 1
    tx.processAction()
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

  state = r.GetExtState(scriptID, 'scriptWritesMainContext')
  if state and state ~= '' then
    scriptWritesMainContext = tonumber(state) == 1 and true or false
  end

  state = r.GetExtState(scriptID, 'scriptWritesMIDIContexts')
  if state and state ~= '' then
    scriptWritesMIDIContexts = tonumber(state) == 1 and true or false
  end

  state = r.GetExtState(scriptID, 'updateItemBoundsOnEdit')
  if state and state ~= '' then
    updateItemBoundsOnEdit = state == '1' and true or false
    tx.setUpdateItemBoundsOnEdit(updateItemBoundsOnEdit)
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
    small = r.ImGui_CreateFont(fontStyle, FONTSIZE_SMALL), smallSize = FONTSIZE_SMALL, smallDefaultSize = FONTSIZE_SMALL
  }
  r.ImGui_Attach(ctx, fontInfo.large)
  r.ImGui_Attach(ctx, fontInfo.small)

  processBaseFontUpdate(tonumber(r.GetExtState(scriptID, 'baseFont')))
end

local function check14Bit(paramType)
  local has14bit = false
  local hasOther = false
  if paramType == tx.PARAM_TYPE_INTEDITOR then
    local hasTable, fresh = tx.getHasTable()
    has14bit = hasTable[0xE0] and true or false
    hasOther = (hasTable[0x90] or hasTable[0xA0] or hasTable[0xB0] or hasTable[0xD0] or hasTable[0xF0]) and true or false
    if fresh then newHasTable = true end
  end
  return has14bit, hasOther
end

local function overrideEditorType(row, target, condOp, paramTypes, idx)
  local has14bit, hasOther = check14Bit(paramTypes[idx])
  if not (paramTypes[idx] == tx.PARAM_TYPE_INTEDITOR or paramTypes[idx] == tx.PARAM_TYPE_FLOATEDITOR) or condOp.norange then
    tx.setEditorTypeForRow(row, idx, nil)
  elseif target.notation == '$velocity' or  target.notation == '$relvel' then
    if condOp.bipolar then
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT_BIPOLAR)
    elseif target.notation == '$velocity' and not condOp.fullrange then
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT_NOZERO)
    else
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT)
    end
  elseif has14bit then
    if condOp.bipolar then
      tx.setEditorTypeForRow(row, idx, hasOther and tx.EDITOR_TYPE_PERCENT_BIPOLAR or tx.EDITOR_TYPE_PITCHBEND_BIPOLAR)
    else
      tx.setEditorTypeForRow(row, idx, hasOther and tx.EDITOR_TYPE_PERCENT or tx.EDITOR_TYPE_PITCHBEND)
    end
  elseif target.notation ~= '$position' and target.notation ~= '$length' then
    if condOp.bipolar then
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT_BIPOLAR)
    else
      tx.setEditorTypeForRow(row, idx, tx.EDITOR_TYPE_7BIT)
    end
  else
    tx.setEditorTypeForRow(row, idx, nil)
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
  local _, framePaddingY = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())

  ---------------------------------------------------------------------------
  ------------------------------ INTERFACE FUNS -----------------------------

  local currentRect = {}

  local function MakeGearPopup()
    r.ImGui_SameLine(ctx)

    local ibSize = FONTSIZE_LARGE * canvasScale
    local x = r.ImGui_GetWindowSize(ctx)
    local textWidth = ibSize -- r.ImGui_CalcTextSize(ctx, 'Gear')
    r.ImGui_SetCursorPosX(ctx, x - textWidth - (15 * canvasScale))
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

    local wantsPop = false
    if r.ImGui_ImageButton(ctx, 'gear', GearImage, ibSize, ibSize) then
      wantsPop = true
    end

    if wantsPop then
      r.ImGui_OpenPopup(ctx, 'gear menu')
    end

    if r.ImGui_BeginPopup(ctx, 'gear menu') then
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
      rv, v = r.ImGui_InputText(ctx, 'Base Font Size', FONTSIZE_LARGE, r.ImGui_InputTextFlags_EnterReturnsTrue()
                                                                     + r.ImGui_InputTextFlags_CharsDecimal())
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

  local function kbdEntryIsCompleted(retval)
    return (retval and (r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter())
              or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Tab())
              or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter())))
            or (not refocusField and r.ImGui_IsItemDeactivated(ctx))
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

  local function enumerateTransformerPresets(pPath)
    if not dirExists(pPath) then return {} end

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
      v.sub = enumerateTransformerPresets(newPath)
    end

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
        if not selEntry then selEntry = 1 end
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

  ---------------------------------------------------------------------------
  ------------------------------- PRESET RECALL -----------------------------

  local function Spacing(half)
    local posy = r.ImGui_GetCursorPosY(ctx)
    r.ImGui_SetCursorPosY(ctx, posy + (currentFrameHeight / (half and 4 or 2)))
  end

  Spacing(true)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Button(ctx, 'Recall Preset...', DEFAULT_ITEM_WIDTH * 2)
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    presetTable = enumerateTransformerPresets(presetPath)
    r.ImGui_OpenPopup(ctx, 'openPresetMenu') -- defined far below
  end

  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, 0x00AAFFFF, presetLabel)

  ---------------------------------------------------------------------------
  ----------------------------------- GEAR ----------------------------------

  MakeGearPopup()

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
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    addFindRow()
  end

  r.ImGui_SameLine(ctx)
  if selectedFindRow == 0 then
    r.ImGui_BeginDisabled(ctx)
  end
  r.ImGui_Button(ctx, optDown and 'Clear All Criteria' or 'Remove Criteria', DEFAULT_ITEM_WIDTH * 2)
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
    local editorType = row[paramName .. 'EditorType']
    if paramType == tx.PARAM_TYPE_METRICGRID and needsTerms == 1 then paramType = tx.PARAM_TYPE_MENU end -- special case, sorry
    local isFloat = (paramType == tx.PARAM_TYPE_FLOATEDITOR or editorType == tx.EDITOR_TYPE_PERCENT) and true or false
    local floatFlags = r.ImGui_InputTextFlags_CharsDecimal() + r.ImGui_InputTextFlags_CharsNoBlank()
    if condOp.terms >= needsTerms then
      local targetTab = row:is_a(tx.FindRow) and tx.findTargetEntries or tx.actionTargetEntries
      local target = targetTab[row.targetEntry]
      if paramType == tx.PARAM_TYPE_MENU then
        r.ImGui_Button(ctx, #paramTab ~= 0 and paramTab[row[paramName .. 'Entry']].label or '---')
        if (#paramTab ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
          rv = idx
          r.ImGui_OpenPopup(ctx, paramName .. 'Menu')
        end
      elseif paramType == tx.PARAM_TYPE_INTEDITOR
        or isFloat
        or paramType == tx.PARAM_TYPE_METRICGRID
        or editorType == tx.EDITOR_TYPE_PITCHBEND
        or editorType == tx.EDITOR_TYPE_PERCENT
      then
        local range = tx.getRowParamRange(row, target, condOp, paramType, editorType)
        r.ImGui_BeginGroup(ctx)
        if newHasTable then
          local strVal = ensureNumString(row[paramName .. 'TextEditorStr'], range)
          if range and row[paramName .. 'PercentVal'] then
            local percentVal = row[paramName .. 'PercentVal'] / 100
            local scaledVal
            if editorType == tx.EDITOR_TYPE_PITCHBEND and condOp.literal then
              scaledVal = percentVal * ((1 << 14) - 1)
            else -- this feels hacky
              local mult = (percentVal < 0 and condOp.bipolar) and -1 or 1
              percentVal = math.abs(percentVal)
              local range1 = condOp.bipolar and 0 or range[1]
              scaledVal = ((percentVal * (range[2] - range1)) + range1) * mult
              -- mu.post(percentVal, scaledVal)
            end
            if paramType == tx.PARAM_TYPE_INTEDITOR then
              scaledVal = math.floor(scaledVal + 0.5)
            end
            strVal = tostring(scaledVal)
          end
          row[paramName .. 'TextEditorStr'] = strVal
        end
        local retval, buf = r.ImGui_InputText(ctx, '##' .. paramName .. 'edit', row[paramName .. 'TextEditorStr'], isFloat and floatFlags or r.ImGui_InputTextFlags_CallbackCharFilter(), isFloat and nil or numbersOnlyCallback)
        if kbdEntryIsCompleted(retval) then
          tx.setRowParam(row, paramName, paramType, editorType, buf, range, condOp.literal and true or false)
          -- row[paramName .. 'TextEditorStr'] = paramType == tx.PARAM_TYPE_METRICGRID and buf or ensureNumString(buf, range)
          procFn()
          inTextInput = false
        elseif retval then inTextInput = true
        end
        if range then
          r.ImGui_SameLine(ctx)
          r.ImGui_AlignTextToFramePadding(ctx)
          r.ImGui_PushFont(ctx, fontInfo.small)
          if editorType == tx.EDITOR_TYPE_PERCENT then
            r.ImGui_TextColored(ctx, 0xFFFFFF7F, '%')
          elseif range and range[1] and range[2] then
            r.ImGui_TextColored(ctx, 0xFFFFFF7F, '(' .. range[1] .. ' - ' .. range[2] .. ')')
          end
          r.ImGui_PopFont(ctx)
        end
        r.ImGui_EndGroup(ctx)
        if r.ImGui_IsItemHovered(ctx) then
          if r.ImGui_IsMouseClicked(ctx, 0) then
            rv = idx
          -- elseif r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_Alt() and r.ImGui_IsMouseClicked(ctx, 1) then
          --   r.ImGui_OpenPopup(ctx, 'forceParam' .. needsTerms .. 'Type')
          --   rv = idx
          end
        end
      elseif paramType == tx.PARAM_TYPE_TIME or paramType == tx.PARAM_TYPE_TIMEDUR then
        r.ImGui_BeginGroup(ctx)
        local retval, buf = r.ImGui_InputText(ctx, '##' .. paramName .. 'edit', row[paramName .. 'TimeFormatStr'], r.ImGui_InputTextFlags_CallbackCharFilter(), timeFormatOnlyCallback)
        if kbdEntryIsCompleted(retval) then
          row[paramName .. 'TimeFormatStr'] = paramType == tx.PARAM_TYPE_TIMEDUR and tx.lengthFormatRebuf(buf) or tx.timeFormatRebuf(buf)
          procFn()
          inTextInput = false
        elseif retval then inTextInput = true
        end
        r.ImGui_EndGroup(ctx)
        if r.ImGui_IsItemHovered(ctx) then
          if r.ImGui_IsMouseClicked(ctx, 0) then
            rv = idx
          -- elseif r.ImGui_GetKeyMods(ctx) == r.ImGui_Mod_Alt() and r.ImGui_IsMouseClicked(ctx, 1) then
          --   r.ImGui_OpenPopup(ctx, 'forceParam' .. needsTerms .. 'Type')
          --   rv = idx
          end
        end
      end

      -- not working yet
      -- local paramTypeMenu = {
      --   { label = 'Default', value = nil },
      --   { label = 'Integer', value = tx.PARAM_TYPE_INTEDITOR },
      --   { label = 'Float', value = tx.PARAM_TYPE_FLOATEDITOR },
      --   { label = 'Time',  value = tx.PARAM_TYPE_TIME },
      --   { label = 'Duration',  value = tx.PARAM_TYPE_TIMEDUR },
      --   { label = 'Percent',  value = tx.PARAM_TYPE_PERCENT },
      --   { label = 'Pitch Bend', value = tx.PARAM_TYPE_PITCHBEND }
      --   -- { label = '14-bit', value = tx.PARAM_TYPE_14BIT },
      -- }

      -- local function paramTypeToMenuIdx(paramType)
      --   for k, v in ipairs(paramTypeMenu) do
      --     if v.value == paramType then return k end
      --   end
      --   return 1
      -- end

      -- createPopup('forceParam' .. needsTerms .. 'Type', paramTypeMenu, paramTypeToMenuIdx(row['forceParam' .. needsTerms .. 'Type']), function(i)
      --   row['forceParam' .. needsTerms .. 'Type'] = paramTypeMenu[i].value
      -- end)

    end
    return rv
  end

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
      subtypeValueLabel = tx.GetSubtypeValueLabel((foundType >> 4) - 8)
      mainValueLabel = tx.GetMainValueLabel((foundType >> 4) - 8)
    else
      subtypeValueLabel = 'Multiple (Databyte 1)'
      mainValueLabel = 'Multiple (Databyte 2)'
    end
    if fresh then newHasTable = true end
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

  local tableHeight = currentFrameHeight * 6.2
  local restoreY = r.ImGui_GetCursorPosY(ctx) + tableHeight

  r.ImGui_BeginTable(ctx, 'Selection Criteria', #findColumns - (showTimeFormatColumn == false and 1 or 0), r.ImGui_TableFlags_ScrollY() + r.ImGui_TableFlags_BordersInnerH(), 0, tableHeight)

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

  handleValueLabels()

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
      r.ImGui_InvisibleButton(ctx, '##startParen', scaled(PAREN_COLUMN_WIDTH), currentFrameHeight) -- or we can't test hover/click properly
    else
      r.ImGui_Button(ctx, tx.startParenEntries[currentRow.startParenEntry].label)
    end
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      r.ImGui_OpenPopup(ctx, 'startParenMenu')
      selectedFindRow = k
      lastSelectedRowType = 0 -- Find
    end

    r.ImGui_TableSetColumnIndex(ctx, 1) -- 'Target'
    local targetText = currentRow.targetEntry > 0 and currentFindTarget.label or '---'
    r.ImGui_Button(ctx, decorateTargetLabel(targetText))
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedFindRow = k
      lastSelectedRowType = 0 -- Find
      r.ImGui_OpenPopup(ctx, 'targetMenu')
    end

    r.ImGui_TableSetColumnIndex(ctx, 2) -- 'Condition'
    r.ImGui_Button(ctx, #conditionEntries ~= 0 and currentFindCondition.label or '---')
    if (#conditionEntries ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedFindRow = k
      lastSelectedRowType = 0 -- Find
      r.ImGui_OpenPopup(ctx, 'conditionMenu')
    end

    local paramTypes = tx.getEditorTypesForRow(currentRow, currentFindTarget, currentFindCondition)
    local selected

    r.ImGui_TableSetColumnIndex(ctx, 3) -- 'Parameter 1'
    overrideEditorType(currentRow, currentFindTarget, currentFindCondition, paramTypes, 1)
    selected = handleTableParam(currentRow, currentFindCondition, 'param1', param1Entries, paramTypes[1], 1, k, tx.processFind)
    if selected and selected > 0 then selectedFindRow = selected lastSelectedRowType = 0 end

    r.ImGui_TableSetColumnIndex(ctx, 4) -- 'Parameter 2'
    overrideEditorType(currentRow, currentFindTarget, currentFindCondition, paramTypes, 2)
    selected = handleTableParam(currentRow, currentFindCondition, 'param2', param2Entries, paramTypes[2], 2, k, tx.processFind)
    if selected and selected > 0 then selectedFindRow = selected lastSelectedRowType = 0 end

    -- unused currently
    if showTimeFormatColumn then
      r.ImGui_TableSetColumnIndex(ctx, 5) -- Time format
      if (paramTypes[1] == tx.PARAM_TYPE_TIME or paramTypes[1] == tx.PARAM_TYPE_TIMEDUR) and currentFindCondition.terms ~= 0 then
        r.ImGui_Button(ctx, tx.findTimeFormatEntries[currentRow.timeFormatEntry].label or '---')
        if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
          selectedFindRow = k
          lastSelectedRowType = 0
          r.ImGui_OpenPopup(ctx, 'timeFormatMenu')
        end
      end
    end

    r.ImGui_TableSetColumnIndex(ctx, 6 - (showTimeFormatColumn == false and 1 or 0)) -- End Paren
    if currentRow.endParenEntry < 2 then
      r.ImGui_InvisibleButton(ctx, '##endParen', scaled(PAREN_COLUMN_WIDTH), currentFrameHeight) -- or we can't test hover/click properly
    else
      r.ImGui_Button(ctx, tx.endParenEntries[currentRow.endParenEntry].label)
    end
    if (currentRow.targetEntry > 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      r.ImGui_OpenPopup(ctx, 'endParenMenu')
      selectedFindRow = k
      lastSelectedRowType = 0
    end

    r.ImGui_TableSetColumnIndex(ctx, 7 - (showTimeFormatColumn == false and 1 or 0)) -- Boolean
    if k ~= #tx.findRowTable() then
      r.ImGui_Button(ctx, tx.findBooleanEntries[currentRow.booleanEntry].label or '---', 50)
      if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
        currentRow.booleanEntry = currentRow.booleanEntry == 1 and 2 or 1
        selectedFindRow = k
        lastSelectedRowType = 0
        tx.processFind()
      end
    end

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
      local oldNotation = currentFindCondition.notation
        currentRow:init()
        currentRow.targetEntry = i
        conditionEntries = tx.prepFindEntries(currentRow)
        for kk, vv in ipairs(conditionEntries) do
          if vv.notation == oldNotation then currentRow.conditionEntry = kk break end
        end
        setupRowFormat(currentRow, conditionEntries)
        tx.processFind()
      end)

    createPopup('conditionMenu', conditionEntries, currentRow.conditionEntry, function(i)
        currentRow.conditionEntry = i
        setupRowFormat(currentRow, conditionEntries)
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
      paramTypes[1] == tx.PARAM_TYPE_METRICGRID and metricParam1Special or nil)

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

  generateLabelOnLine('Selection Criteria', true)

  ---------------------------------------------------------------------------
  ------------------------------- FIND BUTTONS ------------------------------

  r.ImGui_SetCursorPosY(ctx, restoreY)

  Spacing(true)
  r.ImGui_Separator(ctx)

  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + currentFrameHeight)

  r.ImGui_AlignTextToFramePadding(ctx)

  r.ImGui_Button(ctx, tx.findScopeTable[tx.currentFindScope()].label, DEFAULT_ITEM_WIDTH * 2)
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'findScopeMenu')
  end

  generateLabelOnLine('Selection Scope', true)

  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, findParserError)

  r.ImGui_SameLine(ctx)

  createPopup('findScopeMenu', tx.findScopeTable, tx.currentFindScope(), function(i)
      tx.setCurrentFindScope(i)
    end)

  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)

  Spacing(true)
  r.ImGui_Separator(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + 15)
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
  if selectedActionRow == 0 then
    r.ImGui_BeginDisabled(ctx)
  end
  r.ImGui_Button(ctx, optDown and 'Clear All Actions' or 'Remove Action', DEFAULT_ITEM_WIDTH * 2)
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
  r.ImGui_SetNextItemWidth(ctx, DEFAULT_ITEM_WIDTH * 6)
  local acrv, acbuf = r.ImGui_InputText(ctx, '##actionConsole', actionConsoleText)
  if kbdEntryIsCompleted(acrv) then
    actionConsoleText = acbuf
    tx.processActionMacro(actionConsoleText)
    inTextInput = false
  elseif acrv then inTextInput = true
  end

  generateLabelOnLine('Action Console')

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

  r.ImGui_BeginTable(ctx, 'Actions', #actionColumns, r.ImGui_TableFlags_ScrollY() + r.ImGui_TableFlags_BordersInnerH(), 0, tableHeight)

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
      lastSelectedRowType = 1
      r.ImGui_OpenPopup(ctx, 'targetMenu')
    end

    r.ImGui_TableSetColumnIndex(ctx, 1) -- 'Operation'
    r.ImGui_Button(ctx, #operationEntries ~= 0 and currentActionOperation.label or '---')
    if (#operationEntries ~= 0 and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
      selectedActionRow = k
      lastSelectedRowType = 1
      r.ImGui_OpenPopup(ctx, 'operationMenu')
    end

    local paramTypes = tx.getEditorTypesForRow(currentRow, currentActionTarget, currentActionOperation)
    local selected

    r.ImGui_TableSetColumnIndex(ctx, 2) -- 'Parameter 1'
    overrideEditorType(currentRow, currentActionTarget, currentActionOperation, paramTypes, 1)
    selected = handleTableParam(currentRow, currentActionOperation, 'param1', param1Entries, paramTypes[1], 1, k, tx.processAction)
    if selected and selected > 0 then selectedActionRow = selected lastSelectedRowType = 1 end

    r.ImGui_TableSetColumnIndex(ctx, 3) -- 'Parameter 2'
    overrideEditorType(currentRow, currentActionTarget, currentActionOperation, paramTypes, 2)
    selected = handleTableParam(currentRow, currentActionOperation, 'param2', param2Entries, paramTypes[2], 2, k, tx.processAction)
    if selected and selected > 0 then selectedActionRow = selected lastSelectedRowType = 1 end

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
        local oldNotation = currentActionOperation.notation
        currentRow:init()
        currentRow.targetEntry = i
        operationEntries = tx.prepActionEntries(currentRow)
        for kk, vv in ipairs(operationEntries) do
          if vv.notation == oldNotation then currentRow.operationEntry = kk break end
        end
        setupRowFormat(currentRow, operationEntries)
        tx.processAction()
      end)

    createPopup('operationMenu', operationEntries, currentRow.operationEntry, function(i)
        currentRow.operationEntry = i
        setupRowFormat(currentRow, operationEntries)
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

  r.ImGui_Button(ctx, 'Apply')
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    tx.processAction(true)
  end

  r.ImGui_SameLine(ctx)

  r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + scaled(20))

  r.ImGui_Button(ctx, tx.actionScopeTable[tx.currentActionScope()].label, DEFAULT_ITEM_WIDTH * 2)
  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) then
    r.ImGui_OpenPopup(ctx, 'actionScopeMenu')
  end

  r.ImGui_SameLine(ctx)

  local saveX, saveY = r.ImGui_GetCursorPos(ctx)

  updateCurrentRect()
  generateLabel('Action Scope')

  createPopup('actionScopeMenu', tx.actionScopeTable, tx.currentActionScope(), function(i)
      tx.setCurrentActionScope(i)
    end)

  r.ImGui_PopStyleColor(ctx, 4)

  r.ImGui_NewLine(ctx)
  Spacing()
  Spacing(true)

  local presetButtonBottom = r.ImGui_GetCursorPosY(ctx)
  r.ImGui_Button(ctx, (optDown or presetInputDoesScript) and 'Export Script...' or 'Save Preset...', DEFAULT_ITEM_WIDTH * 1.5)
  local _, presetButtonHeight = r.ImGui_GetItemRectSize(ctx)
  presetButtonBottom = presetButtonBottom + presetButtonHeight

  if (r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0)) or refocusInput then
    presetInputVisible = true
    presetInputDoesScript = optDown
    refocusInput = false
    r.ImGui_SetKeyboardFocusHere(ctx)
  end

  local handleStatusPosX, handStatusPosY = r.ImGui_GetCursorPos(ctx)

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

    path = presetPath .. '/' .. buf
    return path, buf
  end

  local function doSavePreset(path, fname)
    local saved = tx.savePreset(path, presetNotesBuffer, presetInputDoesScript)
    statusMsg = (saved and 'Saved' or 'Failed to save') .. (presetInputDoesScript and ' + export' or '') .. ' ' .. fname
    statusTime = r.time_precise()
    statusContext = 2
    if saved then
      fname = fname:gsub('%' .. presetExt .. '$', '')
      presetLabel = fname
      if saved and presetInputDoesScript then
        local scriptPath = path:gsub('%' .. presetExt .. '$', '.lua')
        if scriptWritesMainContext then
          r.AddRemoveReaScript(true, 0, scriptPath, true)
        end
        if scriptWritesMIDIContexts then
          r.AddRemoveReaScript(true, 32060, scriptPath, false)
          r.AddRemoveReaScript(true, 32061, scriptPath, false)
          r.AddRemoveReaScript(true, 32062, scriptPath, false)
        end
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
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      presetInputVisible = false
      presetInputDoesScript = false
      handledEscape = true
    end

    r.ImGui_SameLine(ctx)
    r.ImGui_SetNextItemWidth(ctx, 2.5 * DEFAULT_ITEM_WIDTH)
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
      inTextInput = false
    else
      lastInputTextBuffer = buf
      inOKDialog = false
      if retval then inTextInput = true end
    end

    if refocusField then refocusField = false end

    if presetInputDoesScript then
      r.ImGui_SameLine(ctx)
      local rv, sel = r.ImGui_Checkbox(ctx, 'Main', scriptWritesMainContext)
      if rv then
        scriptWritesMainContext = sel
        r.SetExtState(scriptID, 'scriptWritesMainContext', scriptWritesMainContext and '1' or '0', true)
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
      end
      if r.ImGui_IsItemHovered(ctx) then
        refocusField = true
        inOKDialog = false
      end
    end
    manageSaveAndOverwrite(presetPathAndFilenameFromLastInput, doSavePreset, 2)
  end

  restoreX = restoreX + 57 * (currentFontWidth and currentFontWidth or canonicalFontWidth)
  r.ImGui_SetCursorPos(ctx, restoreX, restoreY)

  local windowSizeX = r.ImGui_GetWindowSize(ctx)

  if not presetNotesViewEditor then
    r.ImGui_BeginGroup(ctx)
    r.ImGui_SetCursorPos(ctx, restoreX + 2, restoreY + 3)
    local noBuf = false
    if presetNotesBuffer == '' then noBuf = true end
    if noBuf then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFF7F) end
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
    if justChanged then r.ImGui_SetKeyboardFocusHere(ctx) justChanged = false end
    local retval, buf = r.ImGui_InputTextMultiline(ctx, '##presetnotes', presetNotesBuffer, windowSizeX - restoreX - 20, presetButtonBottom - restoreY, r.ImGui_InputTextFlags_AutoSelectAll())
    if kbdEntryIsCompleted(retval) and not r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter()) then
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
        handledEscape = true -- don't revert the buffer if escape was pressed, use whatever's in there. causes a momentary flicker
      else
        presetNotesBuffer = buf
      end
      presetNotesViewEditor = false
      inTextInput = false
    else
      if retval then inTextInput = true end
      presetNotesBuffer = buf
    end
    updateCurrentRect()
  end

  restoreY = r.ImGui_GetCursorPosY(ctx) - 10 * canvasScale

  generateLabel('Preset Notes')

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

  r.ImGui_SetCursorPos(ctx, handleStatusPosX, handStatusPosY - r.ImGui_GetFrameHeightWithSpacing(ctx))
  r.ImGui_Dummy(ctx, DEFAULT_ITEM_WIDTH * 1.5, 1)
  handleStatus(2)

  local function generatePresetMenu(source, path, lab)
    local mousePos = {}
    mousePos.x, mousePos.y = r.ImGui_GetMousePos(ctx)
    local windowRect = {}
    windowRect.left, windowRect.top = r.ImGui_GetWindowPos(ctx)
    windowRect.right, windowRect.bottom = r.ImGui_GetWindowSize(ctx)
    windowRect.right = windowRect.right + windowRect.left
    windowRect.bottom = windowRect.bottom + windowRect.top

    for i = 1, #source do
      local selectText = source[i].label
      local saveX = r.ImGui_GetCursorPosX(ctx)
      r.ImGui_BeginGroup(ctx)

      local rv, selected

      if source[i].sub then
        if r.ImGui_BeginMenu(ctx, selectText) then
          generatePresetMenu(source[i].sub, path .. '/' .. selectText, selectText)
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
          local success, notes = tx.loadPreset(path .. '/' .. filename)
          if success then
            presetLabel = source[i].label
            lastInputTextBuffer = presetLabel
            presetNotesBuffer = notes and notes or ''
            tx.processAction()
          end
        end
        r.ImGui_CloseCurrentPopup(ctx)
      end
    end
  end

  if r.ImGui_BeginPopup(ctx, 'openPresetMenu') then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      if r.ImGui_IsPopupOpen(ctx, 'openPresetMenu', r.ImGui_PopupFlags_AnyPopupId() + r.ImGui_PopupFlags_AnyPopupLevel()) then
        r.ImGui_CloseCurrentPopup(ctx)
        handledEscape = true
      end
    end

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), hoverAlphaCol)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), activeAlphaCol)

    generatePresetMenu(presetTable, presetPath)

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

  ---------------------------------------------------------------------------
  ------------------------------- MOD KEYS ------------------------------

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

  if not inTextInput and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Backspace()) then
    if lastSelectedRowType == 0 then removeFindRow()
    elseif lastSelectedRowType == 1 then removeActionRow()
    end
  end

  -- if recalcEventTimes or recalcSelectionTimes then canProcess = true end
  if newHasTable then newHasTable = false end
end

-----------------------------------------------------------------------------
--------------------------------- CLEANUP -----------------------------------

local function doClose()
  r.ImGui_Detach(ctx, fontInfo.large)
  r.ImGui_Detach(ctx, fontInfo.small)
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
  local winheight = r.ImGui_GetFrameHeightWithSpacing(ctx) * 27
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
    checkShortcuts()

    r.ImGui_PushFont(ctx, fontInfo.large)

    if not prepped then
      r.ImGui_PushFont(ctx, canonicalFont)
      canonicalFontWidth = r.ImGui_CalcTextSize(ctx, '0', nil, nil)
      currentFrameHeight = r.ImGui_GetFrameHeight(ctx)
      r.ImGui_PopFont(ctx)
      prepped = true
    else
      currentFontWidth = r.ImGui_CalcTextSize(ctx, '0', nil, nil)
      DEFAULT_ITEM_WIDTH = 10 * currentFontWidth -- (currentFontWidth / canonicalFontWidth)
      currentFrameHeight = r.ImGui_GetFrameHeight(ctx)
      fontWidScale = currentFontWidth / canonicalFontWidth
    end

    r.ImGui_BeginGroup(ctx)
    windowFn()
    r.ImGui_EndGroup(ctx)

    -- handle drag and drop of preset files using the entire frame
    if r.ImGui_BeginDragDropTarget(ctx) then
      if r.ImGui_AcceptDragDropPayloadFiles(ctx) then
        local retdrag, filedrag = r.ImGui_GetDragDropPayloadFile(ctx, 0)
        if retdrag and string.match(filedrag, presetExt .. '$') then
          local success, notes = tx.loadPreset(filedrag)
          if success then
            presetLabel = string.match(filedrag, '.*[/\\](.*)' .. presetExt)
            lastInputTextBuffer = presetLabel
            presetNotesBuffer = notes and notes or ''
            tx.processAction()
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
