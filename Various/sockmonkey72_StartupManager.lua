-- @description Startup Manager
-- @version 0.0.1-beta.3
-- @author sockmonkey72
-- @about
--   # Startup Manager
--   Manage startup actions in the __startup.lua file
-- @changelog
--   - initial
-- @provides
--   [main] sockmonkey72_StartupManager.lua

local r = reaper

local scriptName = 'Startup Manager'

-- https://stackoverflow.com/questions/1340230/check-if-directory-exists-in-lua
--- Check if a file or directory exists in this path
local function FilePathExists(file)
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
local function DirExists(path)
  -- "/" works on both Unix and Windows
  return FilePathExists(path:match('/$') and path or path..'/')
end

local function FileExists(path)
  return FilePathExists(path)
end

local function post(...)
  local args = {...}
  local str = ''
  for i = 1, #args do
    local v = args[i]
    str = str .. (i ~= 1 and ', ' or '') .. (v ~= nil and tostring(v) or '<nil>')
  end
  str = str .. '\n'
  r.ShowConsoleMsg(str)
end

local canStart = true
local canReveal = true

local imGuiPath = r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua'
if not FileExists(imGuiPath) then
  post(scriptName..' requires \'ReaImGui\' 0.8+ (install from ReaPack)\n')
  canStart = false
end

if not canStart then return end

dofile(r.GetResourcePath()..'/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8')

if not r.APIExists('CF_LocateInExplorer') then
  canReveal = false
end

local scriptID = 'sockmonkey72_StartupManager'

local ctx = r.ImGui_CreateContext(scriptID)

-----------------------------------------------------------------------------
----------------------------- GLOBAL VARS -----------------------------------

local canvasScale = 1.0
local FONTSIZE_LARGE = 13
local FONTSIZE_SMALL = 11
local WIDTH_BASE = 58
local HEIGHT_BASE = 20
local DEFAULT_WIDTH = WIDTH_BASE * FONTSIZE_LARGE
local DEFAULT_HEIGHT = HEIGHT_BASE * FONTSIZE_LARGE
local DEFAULT_ITEM_WIDTH = 60

local windowInfo
local fontInfo

local DEFAULT_TITLEBAR_TEXT = scriptName
local titleBarText = DEFAULT_TITLEBAR_TEXT

local entries = {}
local inActionList = false
local actionListRow = -1

local startupFilePath = r.GetResourcePath()..'/Scripts/__startup.lua'
local defaultHoverColor
local defaultWindowBgColor
local gooseLines = true
local gooseTimer = nil

local function MakeBackup(path)
  local startupStr = ''
  local f = io.open(path, 'r')
  if f then
    startupStr = f:read('*all')
    f:close()
  end
  -- make a backup
  if startupStr ~= '' then
    f = io.open(r.GetResourcePath()..'/Scripts/__startup_backup.lua', 'wb')
    if f then
      f:write(startupStr)
      f:close()
    end
  end
end

local function WriteFile(path, entries)
  MakeBackup(path)
  local f = io.open(path, 'wb')
  local outputString = ''
  if f then
    for _, entry in ipairs(entries) do
      if entry.cmdInfo then
        local cmdStr = entry.cmdInfo.enabled and '' or '-- '
        cmdStr = cmdStr .. 'reaper.Main_OnCommand('
        if tonumber(entry.cmdInfo.cmdID) then cmdStr = cmdStr .. entry.cmdInfo.cmdID
        else cmdStr = cmdStr .. 'reaper.NamedCommandLookup("' .. entry.cmdInfo.cmdID .. '")'
        end
        cmdStr = cmdStr .. ', 0) -- ' .. entry.cmdInfo.name
        outputString = outputString .. cmdStr .. '\n'
      else
        local lineStr
        if entry.comment then
          lineStr = '--[[ -- ___Startup_Manager___ ' .. entry.line .. ' ]]'
        else
          lineStr = entry.line
        end
        outputString = outputString .. lineStr .. '\n'
      end
    end
    outputString = string.gsub(outputString, '^%s*(.-)%s*$', '%1')
    f:write(outputString .. '\n')
    f:close()
  end
  gooseLines = true
  gooseTimer = nil
end

local function handleExtState()
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

  windowInfo.defaultWidth = WIDTH_BASE * fontInfo.largeDefaultSize
  windowInfo.defaultHeight = HEIGHT_BASE * fontInfo.largeDefaultSize
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

local function MoveDraggedLine(payload, target, entries)
  local oldIdx = tonumber(payload:match('^(%d+),'))
  if oldIdx then
    local oldEntry = entries[oldIdx]
    table.remove(entries, oldIdx)
    target = oldIdx < target and target or target + 1
    if target > #entries then target = nil end

    if target then
      table.insert(entries, target, oldEntry)
    else
      table.insert(entries, oldEntry)
    end
    WriteFile(startupFilePath, entries)
  end
end

local function Spacing()
  local posy = r.ImGui_GetCursorPosY(ctx)
  r.ImGui_SetCursorPosY(ctx, posy + ((r.ImGui_GetFrameHeight(ctx) / 4) * canvasScale))
end

local function mainFn()

  r.ImGui_Spacing(ctx)

  local x = r.ImGui_GetWindowSize(ctx)
  local textWidth = r.ImGui_CalcTextSize(ctx, 'Gear')
  r.ImGui_SetCursorPosX(ctx, x - textWidth - (15 * canvasScale))
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(), 0x333355FF)

  local wantsPop = false
  if r.ImGui_Button(ctx, 'Gear') then
    wantsPop = true
  end
  if wantsPop then
    r.ImGui_OpenPopup(ctx, 'gear menu')
  end

  if r.ImGui_BeginPopup(ctx, 'gear menu') then
    -----------------------------------------------------------------------------
    ---------------------------------- OPEN PREFS -------------------------------

    if canReveal then
      if r.ImGui_Selectable(ctx, 'Reveal __startup.lua in Finder/Explorer') then
        r.CF_LocateInExplorer(startupFilePath)
        r.ImGui_CloseCurrentPopup(ctx)
      end

      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
  end

  -----------------------------------------------------------------------------
    ---------------------------------- BASE FONT --------------------------------

    r.ImGui_SetNextItemWidth(ctx, (DEFAULT_ITEM_WIDTH / 2) * canvasScale)
    local rv, v = r.ImGui_InputText(ctx, 'Base Font Size', FONTSIZE_LARGE, r.ImGui_InputTextFlags_EnterReturnsTrue()
                                                                         + r.ImGui_InputTextFlags_CharsDecimal())
    if rv then
      v = processBaseFontUpdate(tonumber(v))
      r.SetExtState(scriptID, 'baseFont', tostring(v), true)
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_EndPopup(ctx)
  end

  r.ImGui_Spacing(ctx)

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), defaultWindowBgColor) -- no selectable hover color

  if r.ImGui_BeginTable(ctx, 'Startup Items', 5) then -- order, action name (r/o), action id
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), r.ImGui_GetStyleColor(ctx, r.ImGui_Col_TableHeaderBg()))
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderActive(), r.ImGui_GetStyleColor(ctx, r.ImGui_Col_TableHeaderBg()))
    r.ImGui_TableSetupColumn(ctx, 'On', r.ImGui_TableColumnFlags_WidthFixed(), (fontInfo.largeDefaultSize * 1.5) * canvasScale)
    r.ImGui_TableSetupColumn(ctx, '#', r.ImGui_TableColumnFlags_WidthFixed(), (fontInfo.largeDefaultSize * 1.5) * canvasScale)
    r.ImGui_TableSetupColumn(ctx, 'Action Name')
    r.ImGui_TableSetupColumn(ctx, 'Action ID')
    r.ImGui_TableSetupColumn(ctx, '##choose', r.ImGui_TableColumnFlags_WidthFixed(), (fontInfo.largeDefaultSize * 5) * canvasScale)

    r.ImGui_TableHeadersRow(ctx)
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_PopStyleColor(ctx)

    -- only refresh file list every 1s, unless there's been a change
    if gooseTimer and r.time_precise() - gooseTimer > 1 then
      gooseTimer = nil
      gooseLines = true
    end

    if gooseLines then
      local enabled, name

      entries = {}
      local fileLines = {}
      if FileExists(startupFilePath) then
        for line in io.lines(startupFilePath) do
          table.insert(fileLines, line)
        end
      end
      gooseLines = false
      gooseTimer = r.time_precise()

      local cmdIdx = 1
      for idx, line in ipairs(fileLines) do
        local term
        if not line:match('%-%-%[%[%s*%-%-%s*___Startup_Manager___%s*') then
          term = line:match('Main_OnCommand%s*%(([^%s,]*),[%s%d]+%)')
        end
        if not term then
          table.insert(entries, { line = line, comment = false, cmdInfo = nil })
        else
          name = ''
          enabled = true
          local rewrite = false
          if line:match('^[%s-]+-') then enabled = false end
          local cmdID = term:match('NamedCommandLookup%([\"\']([^\"\']*)[\"\']')
          if not cmdID then
            cmdID = line:match('OnCommand%s*%(%s*(%d+)')
          end
          if not cmdID then
            local varname = line:match('NamedCommandLookup%(%s*(%g*)%s*%)')
            if varname then
              for i = #entries, 1, -1 do
                cmdID = entries[i].line:match(varname .. '%s*=%s*[\"\']([^\"\']*)[\"\']')
                if cmdID and cmdID ~= '' then
                  entries[i].comment = true
                  rewrite = true
                  break
                end
              end
              if cmdID == '' then cmdID = nil end
            end
          end
          if cmdID then
            name = r.kbd_getTextFromCmd(r.NamedCommandLookup(cmdID), nil)
            if name == '' then name = '(unknown script)' end
            local entry = { line = line, comment = false, cmdInfo = { idx = cmdIdx, cmdID = cmdID, name = name, enabled = enabled } }
            cmdIdx = cmdIdx + 1
            table.insert(entries, rewrite and { line = line, comment = true } or entry)
            if rewrite then table.insert(entries, entry) end -- add a new line afterward
          else
            table.insert(entries, { line = line, comment = false, cmdInfo = nil })
          end
        end
      end
    end

    r.ImGui_TableNextRow(ctx, nil, (fontInfo.largeDefaultSize * 1.75) * canvasScale)
    r.ImGui_TableNextColumn(ctx)
    r.ImGui_TableNextColumn(ctx)
    r.ImGui_Text(ctx, '-')
    if r.ImGui_BeginDragDropTarget(ctx) then
      local rv, payload = r.ImGui_AcceptDragDropPayload(ctx, 'row')
      if rv then
        MoveDraggedLine(payload, 1, entries)
      end
      r.ImGui_EndDragDropTarget(ctx)
    end

    for idx, entry in ipairs(entries) do
      if entry.cmdInfo then
      r.ImGui_TableNextRow(ctx, nil, (fontInfo.largeDefaultSize * 1.75) * canvasScale)
      r.ImGui_TableNextColumn(ctx)
      if r.ImGui_Checkbox(ctx, '##' .. entry.cmdInfo.idx .. '_enabled', entry.cmdInfo.enabled) then
        entry.cmdInfo.enabled = not entry.cmdInfo.enabled
        WriteFile(startupFilePath, entries)
      end
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Selectable(ctx, tostring(entry.cmdInfo.idx), false)
      if r.ImGui_BeginDragDropTarget(ctx) then
        local rv, payload = r.ImGui_AcceptDragDropPayload(ctx, 'row')
        if rv then
          MoveDraggedLine(payload, idx, entries)
        end
        r.ImGui_EndDragDropTarget(ctx)
      end

      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, entry.cmdInfo.name)
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, entry.cmdInfo.cmdID)
      r.ImGui_TableNextColumn(ctx)
      if r.ImGui_Button(ctx, 'Choose...##' .. entry.cmdInfo.idx) then
        r.PromptForAction(1, 0, 0)
        inActionList = true
        actionListRow = idx
      end
      r.ImGui_SameLine(ctx)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), 0x0077FF33)
      r.ImGui_Selectable(ctx, '##group' .. entry.cmdInfo.idx, false, r.ImGui_SelectableFlags_SpanAllColumns() | r.ImGui_SelectableFlags_AllowItemOverlap())
      if r.ImGui_BeginPopupContextItem(ctx, '##rowctx' .. entry.cmdInfo.idx) then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(), defaultHoverColor)
        r.ImGui_Spacing(ctx)
        if r.ImGui_Selectable(ctx, 'Copy Script Description To Clipboard') then
          r.ImGui_SetClipboardText(ctx, entry.cmdInfo.name)
        end
        r.ImGui_Spacing(ctx)
        if r.ImGui_Selectable(ctx, 'Copy Script ID To Clipboard') then
          r.ImGui_SetClipboardText(ctx, entry.cmdInfo.cmdID)
        end
        r.ImGui_Spacing(ctx)
        if r.ImGui_Selectable(ctx, 'Delete Entry') then
          table.remove(entries, idx)
          WriteFile(startupFilePath, entries)
        end
        r.ImGui_Spacing(ctx)
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_EndPopup(ctx)
      end
      r.ImGui_PopStyleColor(ctx)
      if r.ImGui_BeginDragDropSource(ctx, r.ImGui_DragDropFlags_SourceAllowNullID()) then
        r.ImGui_SetDragDropPayload(ctx, 'row', idx .. ',' .. (entry.cmdInfo.enabled and 1 or 0) .. ',' .. entry.cmdInfo.name .. ',' .. entry.cmdInfo.cmdID)
        r.ImGui_Text(ctx, 'Row ' .. entry.cmdInfo.idx .. ': ' .. entry.cmdInfo.name)
        r.ImGui_EndDragDropSource(ctx)
      end
      end
    end

    r.ImGui_TableNextRow(ctx, nil, (fontInfo.largeDefaultSize * 1.75) * canvasScale)
    r.ImGui_TableNextColumn(ctx)
    r.ImGui_TableNextColumn(ctx)
    r.ImGui_TableNextColumn(ctx)
    r.ImGui_TableNextColumn(ctx)
    r.ImGui_TableNextColumn(ctx)
    if r.ImGui_Button(ctx, 'Add...') then
      r.PromptForAction(1, 0, 0)
      inActionList = true
      actionListRow = 0
    end
    r.ImGui_EndTable(ctx)

    if inActionList then
      local action = r.PromptForAction(0, 0, 0)
      if action > 0 then
        local cmdID = r.ReverseNamedCommandLookup(action)
        -- r.ShowConsoleMsg('chose new action: '..action..' ('..cmdID..')'..' -- row '..actionListRow..'\n')
        r.PromptForAction(-1, 0, 0)
        local entry = { line = '', comment = false, cmdInfo = { cmdID = cmdID and '_' .. cmdID or tostring(action), name = r.kbd_getTextFromCmd(action, nil), enabled = true } }
        if actionListRow > 0 then
          table.insert(entries, actionListRow, entry)
        else
          table.insert(entries, entry)
        end
        WriteFile(startupFilePath, entries)
        inActionList = false
      elseif action < 0 then
        -- r.ShowConsoleMsg('canceled or sth went wrong\n')
        r.PromptForAction(-1, 0, 0)
        inActionList = false
      else
        -- do nothing
      end
    end
  end
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_PopStyleColor(ctx)
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
  r.ImGui_SetNextWindowSizeConstraints(ctx, windowInfo.defaultWidth, windowInfo.defaultHeight * canvasScale, windowInfo.defaultWidth * canvasScale * 2, windowInfo.defaultHeight * canvasScale * 3)

  r.ImGui_PushFont(ctx, fontInfo.small)
  local visible, open = r.ImGui_Begin(ctx, titleBarText, true,
                                        0 --r.ImGui_WindowFlags_TopMost()
                                      + r.ImGui_WindowFlags_NoScrollWithMouse()
                                      + r.ImGui_WindowFlags_NoScrollbar()
                                      + r.ImGui_WindowFlags_NoSavedSettings())
  r.ImGui_PopFont(ctx)
  return visible, open
end

local isClosing = false

local function loop()
  if isClosing then
    doClose()
    return
  end

  canvasScale = windowInfo.width / windowInfo.defaultWidth
  if canvasScale > 2 then canvasScale = 2 end
  if canvasScale < 1 then canvasScale = 1 end

  updateFonts()

  if r.ImGui_IsWindowAppearing(ctx) then
    defaultHoverColor = r.ImGui_GetColor(ctx, r.ImGui_Col_HeaderHovered())
    defaultWindowBgColor = r.ImGui_GetColor(ctx, r.ImGui_Col_WindowBg())
  end

  local visible, open = openWindow()
  if visible then
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
