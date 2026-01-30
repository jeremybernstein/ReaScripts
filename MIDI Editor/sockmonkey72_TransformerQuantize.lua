--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper
local scriptID = 'sockmonkey72_TransformerQuantize'
local DEBUG = false  -- set true to output generated scripts to console
local CACHE_DEBUG = false  -- set true to output cache reconciliation debug (passed to ops.init)

-- require MIDI editor
local function requireMIDIEditor()
  local editor = r.MIDIEditor_GetActive()
  if not editor then
    r.ShowMessageBox('Quantize (Transformer) requires an active MIDI editor.',
      'Quantize (Transformer)', 0)
    return false
  end
  return true
end

if not requireMIDIEditor() then return end

-- require ReaImGui
if not r.APIExists('ImGui_GetBuiltinPath') then
  r.ShowConsoleMsg('Quantize (Transformer) requires \'ReaImGui\' 0.9.3+\n')
  return
end

package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9.3'
if not ImGui then
  r.ShowConsoleMsg('Quantize (Transformer) requires \'ReaImGui\' 0.9.3+\n')
  return
end

-- add Transformer directory to path for TransformerLib
package.path = r.GetResourcePath() .. '/Scripts/sockmonkey72 Scripts/MIDI Editor/Transformer/?.lua;' .. package.path
local tx = require 'TransformerLib'
local tg = require 'TransformerGlobal'
local mu = require 'MIDIUtils'
local mgdefs = require 'TransformerMetricGrid'
local SMFParser = require 'lib.SMFParser.SMFParser' -- only partially impmeneted for this case
local ops = require 'TransformerQuantizeOps'

-- initialize ops module with dependencies
ops.init(r, mu, CACHE_DEBUG)

-- early wrapper for markControlChanged (called throughout UI code)
local function markControlChanged() return ops.markControlChanged() end

-- action context for toggle state / single instance
local _, _, sectionID, commandID = r.get_action_context()
r.set_action_options(1)

-- create context
local ctx = ImGui.CreateContext(scriptID)

-- window state
local wantsQuit = false
local windowPos = { left = 100, top = 100 }
local scopeIndex = 1  -- 0=All notes, 1=Selected notes, 2=All events, 3=Selected events
local scopeItems = 'All notes\0Selected notes\0All events\0Selected events\0'

-- quantize parameters
local targetIndex = 0  -- 0=Position only, 1=Position + note end, 2=Position + note length, 3=Note end only, 4=Note length only
local targetItems = 'Position only\0Position + note end\0Position + note length\0Note end only\0Note length only\0'
local strength = 100  -- 0-100
local fixOverlaps = false
local previewActive = false  -- true when preview is showing (replaces inverted 'bypass')
local previewLatched = false  -- true when opt-clicked to stay on
local previewButtonDown = false  -- true while mouse is held on preview button
local previewShiftDown = false  -- true while shift is held for momentary preview
local statusMessage = ''  -- feedback shown in status line
local isExecuting = false  -- prevent double-click during execution

-- live preview state (managed by ops module)
-- access via ops.getState() for: originalMIDICache, reconciliationBaseline, pristinePostQuantize,
-- preRestoreSnapshot, lastMIDIContentHash, catastrophicTakes, pauseLiveMode, showConflictDialog,
-- previewPending, lastControlChangeTime, lastTakeHash, isApplying, lastOriginalHash, lastPreviewApplied

-- grid parameters
local gridMode = 0  -- 0=Use Grid, 1=Manual, 2=Groove
local gridModeItems = 'Use Grid\0Manual\0Groove\0'
local gridDivIndex = 3  -- default 1/16
local gridDivLabels = {'1/128', '1/64', '1/32', '1/16', '1/8', '1/4', '1/2', '1/1', '2/1', '4/1', 'grid'}
local gridStyleIndex = 0  -- 0=straight, 1=triplet, 2=dotted, 3=swing
local gridStyleItems = 'straight\0triplet\0dotted\0swing\0'
local lengthGridDivIndex = 10  -- default Grid
local swingStrength = 66  -- 0-100
local canMoveLeft = true
local canMoveRight = true
local canShrink = true
local canGrow = true

-- range filter
local rangeFilterEnabled = false
local rangeMin = 0.0
local rangeMax = 100.0

-- distance scaling (linear interpolation within range)
local distanceScaling = false

-- groove quantization state
local grooveFilePath = nil      -- full path to selected groove (.rgt or .mid)
local grooveDirection = 0       -- 0=both, 1=early only, 2=late only
local grooveVelStrength = 0     -- 0-100%
local grooveToleranceMin = 0.0
local grooveToleranceMax = 100.0
local grooveData = nil          -- cached parsed groove {version, nBeats, positions[]}
local grooveErrorMessage = nil  -- inline error display

-- RGT groove browser state
local rgtRootPath = nil         -- root folder for RGT files (default set in init)
local rgtSubPath = nil          -- current navigation within RGT root

-- MIDI groove browser state
local midiRootPath = nil        -- root folder for MIDI files (no default)
local midiSubPath = nil         -- current navigation within MIDI root

-- MIDI groove extraction settings
local midiThreshold = 10        -- coalescing threshold value
local midiThresholdMode = 1     -- 0=ticks, 1=ms, 2=percent
local midiCoalesceMode = 0      -- 0=first, 1=loudest

-- layout constants
local labelWidthHeader = 65   -- Settings, Quantize labels
local labelWidthMain = 65     -- Strength, Grid labels
local labelWidthSwing = 100   -- Swing strength label

-- preset state (go up 2 dirs: Transformer/ and MIDI Editor/ -> sockmonkey72 Scripts/)
local presetPath = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]]
presetPath = presetPath:gsub('(.*[/\\]).*[/\\].*[/\\]', '%1Transformer Presets')

-- helper: remove prefix from string (plain, not pattern)
local function removePrefix(str, prefix)
  if str:sub(1, #prefix) == prefix then
    return str:sub(#prefix + 1)
  end
  return str
end
local currentPresetName = ''
local loadedPresetState = nil  -- snapshot for modified detection
local presetListDirty = true  -- refresh flag
local presetSubPath = nil  -- current folder (nil = root)
local presetTree = {}  -- recursive folder/preset structure
local newFolderParentPath = nil
local confirmDeleteFolder = false
local deleteFolderPath = nil
local deleteFolderName = nil
local saveTargetPath = nil  -- folder to save to (nil = use presetSubPath)
local pendingSaveTargetPath = nil  -- pending folder selection from menu
local presetFolders = {}  -- folders only tree for save dialog
local savePopupJustOpened = false  -- track first frame of popup
local savePopupPos = {0, 0}  -- position to open popup
local saveNameBuffer = ''
local showNewFolderInput = false  -- inline folder creation mode
local newFolderInputBuffer = ''  -- folder name being typed
local focusNewFolderInput = false  -- request focus on folder name field
local confirmOverwrite = false
local overwriteName = ''
local exportAfterSave = false
local exportRegisterAction = false
local lastEnterState = false  -- track Enter key state for fresh press detection
local lastEscapeState = false  -- track Escape key state for fresh press detection

-- fresh key press detection (returns true only on transition from released to pressed)
local function isFreshEnterPress()
  local enterDown = ImGui.IsKeyDown(ctx, ImGui.Key_Enter) or ImGui.IsKeyDown(ctx, ImGui.Key_KeypadEnter)
  local fresh = enterDown and not lastEnterState
  return fresh
end

local function isFreshEscapePress()
  local escapeDown = ImGui.IsKeyDown(ctx, ImGui.Key_Escape)
  local fresh = escapeDown and not lastEscapeState
  return fresh
end

local function updateKeyStates()
  lastEnterState = ImGui.IsKeyDown(ctx, ImGui.Key_Enter) or ImGui.IsKeyDown(ctx, ImGui.Key_KeypadEnter)
  lastEscapeState = ImGui.IsKeyDown(ctx, ImGui.Key_Escape)
end

-- division to QN lookup
local divisionToQN = {
  [0] = 0.0078125,  -- 1/128
  [1] = 0.015625,   -- 1/64
  [2] = 0.03125,    -- 1/32
  [3] = 0.0625,     -- 1/16
  [4] = 0.125,      -- 1/8
  [5] = 0.25,       -- 1/4
  [6] = 0.5,        -- 1/2
  [7] = 1.0,        -- 1/1
  [8] = 2.0,        -- 2/1
  [9] = 4.0,        -- 4/1
  [10] = -1,        -- Grid (use prevailing)
  [11] = -2,        -- Groove (use groove file)
}

-- position persistence
local function initializeWindowPosition()
  if r.HasExtState(scriptID, 'windowRect') then
    local rectStr = r.GetExtState(scriptID, 'windowRect')
    local vals = {}
    for v in string.gmatch(rectStr, '([^,]+)') do table.insert(vals, tonumber(v)) end
    if vals[1] then windowPos.left = vals[1] end
    if vals[2] then windowPos.top = vals[2] end
  end
end

local function updateWindowPosition()
  local curLeft, curTop = ImGui.GetWindowPos(ctx)
  if curLeft ~= windowPos.left or curTop ~= windowPos.top then
    r.SetExtState(scriptID, 'windowRect',
      math.floor(curLeft)..','..math.floor(curTop), true)
    windowPos.left, windowPos.top = curLeft, curTop
  end
end

local function initializeScopeState()
  if r.HasExtState(scriptID, 'scopeIndex') then
    local val = tonumber(r.GetExtState(scriptID, 'scopeIndex'))
    if val then scopeIndex = val end
  end
end

local function initializeQuantizeState()
  if r.HasExtState(scriptID, 'targetIndex') then
    local val = tonumber(r.GetExtState(scriptID, 'targetIndex'))
    if val then targetIndex = val end
  end
  if r.HasExtState(scriptID, 'strength') then
    local val = tonumber(r.GetExtState(scriptID, 'strength'))
    if val then strength = val end
  end
  if r.HasExtState(scriptID, 'fixOverlaps') then
    fixOverlaps = r.GetExtState(scriptID, 'fixOverlaps') == 'true'
  end
  -- preview state not persisted (always starts off)
  if r.HasExtState(scriptID, 'gridMode') then
    local val = tonumber(r.GetExtState(scriptID, 'gridMode'))
    if val then gridMode = val end
  end
  if r.HasExtState(scriptID, 'gridDivIndex') then
    local val = tonumber(r.GetExtState(scriptID, 'gridDivIndex'))
    if val then gridDivIndex = val end
  end
  -- migrate old state: gridMode=1 + gridDivIndex=11 -> gridMode=2
  if gridMode == 1 and gridDivIndex == 11 then
    gridMode = 2
    gridDivIndex = 3  -- reset to 1/16
    r.SetExtState(scriptID, 'gridMode', tostring(gridMode), true)
    r.SetExtState(scriptID, 'gridDivIndex', tostring(gridDivIndex), true)
  end
  -- clamp gridDivIndex to valid range (max 10 now that Groove is removed)
  if gridDivIndex > 10 then
    gridDivIndex = 10
    r.SetExtState(scriptID, 'gridDivIndex', tostring(gridDivIndex), true)
  end
  if r.HasExtState(scriptID, 'gridStyleIndex') then
    local val = tonumber(r.GetExtState(scriptID, 'gridStyleIndex'))
    if val then gridStyleIndex = val end
  end
  if r.HasExtState(scriptID, 'lengthGridDivIndex') then
    local val = tonumber(r.GetExtState(scriptID, 'lengthGridDivIndex'))
    if val then lengthGridDivIndex = val end
  end
  -- clamp lengthGridDivIndex to valid range (max 10 now that Groove is removed)
  if lengthGridDivIndex > 10 then
    lengthGridDivIndex = 10
    r.SetExtState(scriptID, 'lengthGridDivIndex', tostring(lengthGridDivIndex), true)
  end
  if r.HasExtState(scriptID, 'swingStrength') then
    local val = tonumber(r.GetExtState(scriptID, 'swingStrength'))
    if val then swingStrength = val end
  end
  if r.HasExtState(scriptID, 'canMoveLeft') then
    canMoveLeft = r.GetExtState(scriptID, 'canMoveLeft') == 'true'
  end
  if r.HasExtState(scriptID, 'canMoveRight') then
    canMoveRight = r.GetExtState(scriptID, 'canMoveRight') == 'true'
  end
  if r.HasExtState(scriptID, 'canShrink') then
    canShrink = r.GetExtState(scriptID, 'canShrink') == 'true'
  end
  if r.HasExtState(scriptID, 'canGrow') then
    canGrow = r.GetExtState(scriptID, 'canGrow') == 'true'
  end
  if r.HasExtState(scriptID, 'rangeFilterEnabled') then
    rangeFilterEnabled = r.GetExtState(scriptID, 'rangeFilterEnabled') == 'true'
  end
  if r.HasExtState(scriptID, 'rangeMin') then
    local val = tonumber(r.GetExtState(scriptID, 'rangeMin'))
    if val then rangeMin = val end
  end
  if r.HasExtState(scriptID, 'rangeMax') then
    local val = tonumber(r.GetExtState(scriptID, 'rangeMax'))
    if val then rangeMax = val end
  end
  if r.HasExtState(scriptID, 'distanceScaling') then
    distanceScaling = r.GetExtState(scriptID, 'distanceScaling') == 'true'
  end
  if r.HasExtState(scriptID, 'presetSubPath') then
    local val = r.GetExtState(scriptID, 'presetSubPath')
    if val ~= '' and tg.dirExists(val) then
      presetSubPath = val
    end
  end
  -- RGT groove browser: set default root path
  local defaultRgtPath = r.GetResourcePath() .. '/Data/Grooves'
  if not tg.dirExists(defaultRgtPath) then
    defaultRgtPath = r.GetResourcePath() .. '/Grooves'
  end
  if tg.dirExists(defaultRgtPath) then
    rgtRootPath = defaultRgtPath
  end
  -- restore saved RGT paths
  if r.HasExtState(scriptID, 'rgtRootPath') then
    local val = r.GetExtState(scriptID, 'rgtRootPath')
    if val ~= '' and tg.dirExists(val) then
      rgtRootPath = val
    end
  end
  if r.HasExtState(scriptID, 'rgtSubPath') then
    local val = r.GetExtState(scriptID, 'rgtSubPath')
    if val ~= '' and tg.dirExists(val) then
      rgtSubPath = val
    end
  end
  -- restore saved MIDI paths (no default)
  if r.HasExtState(scriptID, 'midiRootPath') then
    local val = r.GetExtState(scriptID, 'midiRootPath')
    if val ~= '' and tg.dirExists(val) then
      midiRootPath = val
    end
  end
  if r.HasExtState(scriptID, 'midiSubPath') then
    local val = r.GetExtState(scriptID, 'midiSubPath')
    if val ~= '' and tg.dirExists(val) then
      midiSubPath = val
    end
  end
  -- MIDI extraction settings
  if r.HasExtState(scriptID, 'midiThreshold') then
    local val = tonumber(r.GetExtState(scriptID, 'midiThreshold'))
    if val then midiThreshold = val end
  end
  if r.HasExtState(scriptID, 'midiThresholdMode') then
    local val = tonumber(r.GetExtState(scriptID, 'midiThresholdMode'))
    if val then midiThresholdMode = val end
  end
  if r.HasExtState(scriptID, 'midiCoalesceMode') then
    local val = tonumber(r.GetExtState(scriptID, 'midiCoalesceMode'))
    if val then midiCoalesceMode = val end
  end
  -- restore selected groove file
  if r.HasExtState(scriptID, 'grooveFilePath') then
    local val = r.GetExtState(scriptID, 'grooveFilePath')
    if val ~= '' and tg.filePathExists(val) then
      grooveFilePath = val
      -- pass extraction options for MIDI files
      local ext = val:lower():match('%.([^%.]+)$')
      if ext == 'mid' or ext == 'smf' or ext == 'midi' then
        local thresholdModes = { [0] = 'ticks', [1] = 'ms', [2] = 'percent' }
        local coalesceModes = { [0] = 'first', [1] = 'loudest' }
        grooveData = mgdefs.loadGrooveFromFile(val, {
          threshold = midiThreshold,
          thresholdMode = thresholdModes[midiThresholdMode] or 'ms',
          coalescingMode = coalesceModes[midiCoalesceMode] or 'first'
        })
      else
        grooveData = mgdefs.loadGrooveFromFile(val)
      end
    end
  end
  -- groove parameters
  if r.HasExtState(scriptID, 'grooveDirection') then
    local val = tonumber(r.GetExtState(scriptID, 'grooveDirection'))
    if val then grooveDirection = val end
  end
  if r.HasExtState(scriptID, 'grooveVelStrength') then
    local val = tonumber(r.GetExtState(scriptID, 'grooveVelStrength'))
    if val then grooveVelStrength = val end
  end
  if r.HasExtState(scriptID, 'grooveToleranceMin') then
    local val = tonumber(r.GetExtState(scriptID, 'grooveToleranceMin'))
    if val then grooveToleranceMin = val end
  end
  if r.HasExtState(scriptID, 'grooveToleranceMax') then
    local val = tonumber(r.GetExtState(scriptID, 'grooveToleranceMax'))
    if val then grooveToleranceMax = val end
  end
end

local function uiToDirectionFlags()
  local gdefs = require 'TransformerGeneralDefs'
  local flags = 0
  if canMoveLeft then flags = flags | gdefs.DIR_LEFT end
  if canMoveRight then flags = flags | gdefs.DIR_RIGHT end
  if canShrink then flags = flags | gdefs.DIR_SHRINK end
  if canGrow then flags = flags | gdefs.DIR_GROW end
  return flags
end

-- build musical notation string from UI state
local function buildMusicalParams(gridType)
  local divIndex = (gridType == 'length') and lengthGridDivIndex or gridDivIndex
  local qnString, swing = '', 0

  -- groove mode: special notation (only for position, gridType is ignored)
  if gridMode == 2 then
    -- groove notation: $groove|<filepath>|dir(<dir>)|vel(<vel>)|tol(<min>:<max>)
    local notation = '$groove'
    if grooveFilePath then
      notation = notation .. '|gf(' .. grooveFilePath .. ')'
    end
    notation = notation .. '|dir(' .. grooveDirection .. ')'
    notation = notation .. '|vel(' .. grooveVelStrength .. ')'
    notation = notation .. '|tol(' .. string.format('%.1f', grooveToleranceMin) .. ':' .. string.format('%.1f', grooveToleranceMax) .. ')'
    -- add MIDI extraction options for MIDI files
    local ext = grooveFilePath and grooveFilePath:lower():match('%.([^%.]+)$')
    if ext == 'mid' or ext == 'smf' or ext == 'midi' then
      local thresholdModes = { [0] = 'ticks', [1] = 'ms', [2] = 'percent' }
      notation = notation .. '|thr(' .. midiThreshold .. ':' .. (thresholdModes[midiThresholdMode] or 'ms') .. ')'
      notation = notation .. '|coal(' .. midiCoalesceMode .. ')'
    end
    return notation
  end

  if gridMode == 0 then  -- Use Grid
    qnString = '$grid'
    -- get swing from REAPER grid
    local editor = r.MIDIEditor_GetActive()
    local take = editor and r.MIDIEditor_GetTake(editor)
    if take then
      _, _, swing = r.MIDI_GetGrid(take)
    end
  else  -- Manual
    qnString = '$' .. gridDivLabels[divIndex + 1]
  end

  -- modifier: - straight, t triplet, d dotted, r swing
  local modifiers = {'-', 't', 'd', 'r'}
  local mod = modifiers[gridStyleIndex + 1]

  -- notation: $qn|{mod}{bar}|{preSlop}|{postSlop}
  local notation = qnString .. '|' .. mod .. '-' .. '|0.00|0.00'

  -- append swing if applicable
  if gridMode == 1 and gridStyleIndex == 3 then
    notation = notation .. '|sw(' .. swingStrength .. '.00)'
  elseif gridMode == 0 and swing > 0 then
    notation = notation .. '|sw(' .. string.format('%.2f', swing * 100) .. ')'
  end

  -- append direction flags if non-default
  local dirFlags = uiToDirectionFlags()
  if dirFlags ~= 0xF then
    notation = notation .. '|df(' .. dirFlags .. ')'
  end

  -- append distance scaling params when enabled (linear interpolation within range)
  -- use colon separator to avoid conflict with macro parameter comma parsing
  if distanceScaling and rangeFilterEnabled then
    notation = notation .. '|dm(' .. string.format('%.1f', rangeMin) .. ':' .. string.format('%.1f', rangeMax) .. ')'
  end

  return notation
end

-- subdivision values for grid divisions (fraction of whole note)
local gridDivSubdivs = {0.0078125, 0.015625, 0.03125, 0.0625, 0.125, 0.25, 0.5, 1.0, 2.0, 4.0, -1}

-- compute grid subdivision from UI state (for range filter)
local function getGridSubdiv()
  if gridMode == 0 then
    return -1  -- use MIDI editor grid
  else
    local subdiv = gridDivSubdivs[gridDivIndex + 1]
    -- apply triplet/dotted modifier to subdivision
    if gridStyleIndex == 1 then  -- triplet
      subdiv = subdiv * 2 / 3
    elseif gridStyleIndex == 2 then  -- dotted
      subdiv = subdiv * 1.5
    end
    return subdiv
  end
end

-- get swing value from UI state
local function getSwingValue()
  if gridMode == 0 then
    -- get swing from MIDI editor grid
    local editor = r.MIDIEditor_GetActive()
    local take = editor and r.MIDIEditor_GetTake(editor)
    if take then
      local _, _, swing = r.MIDI_GetGrid(take)
      return swing
    end
    return 0
  elseif gridStyleIndex == 3 then  -- manual swing
    return swingStrength / 100  -- convert 0-100 to 0-1
  end
  return 0
end

-- build preset table for TransformerLib
local function buildPresetTable()
  -- findMacro: what events to process
  local findMacro
  if scopeIndex == 0 or scopeIndex == 1 then
    findMacro = '$type == $note'
  else
    findMacro = '$type :all '
  end

  -- add range filter if enabled (skip filter when distance scaling handles interpolation)
  local rangeFilterGrid = nil
  if rangeFilterEnabled and not distanceScaling then
    findMacro = findMacro .. ' && $position :ingridrange(' .. string.format('%.1f', rangeMin) .. ', ' .. string.format('%.1f', rangeMax) .. ')'
    -- store grid context for the find function
    rangeFilterGrid = {
      subdiv = getGridSubdiv(),
      swing = getSwingValue(),
    }
  end

  -- findScopeFlags: selected only?
  local findScopeFlags = nil
  if scopeIndex == 1 or scopeIndex == 3 then
    findScopeFlags = { '$selectedonly' }
  end

  -- actionMacro: what transformation to apply
  local actions = {}
  local posParams = buildMusicalParams('position')
  local lenParams = buildMusicalParams('length')

  -- position quantize (targets 0, 1, 2)
  if targetIndex == 0 or targetIndex == 1 or targetIndex == 2 then
    table.insert(actions, '$position :roundmusical(' .. posParams .. ', ' .. strength .. ')')
  end

  -- note end quantize (targets 1, 3)
  if targetIndex == 1 or targetIndex == 3 then
    table.insert(actions, '$length :roundendmusical(' .. posParams .. ', ' .. strength .. ')')
  end

  -- note length quantize (targets 2, 4)
  if targetIndex == 2 or targetIndex == 4 then
    table.insert(actions, '$length :roundlenmusical(' .. lenParams .. ', ' .. strength .. ')')
  end

  return {
    findScope = '$midieditor',
    findScopeFlags = findScopeFlags,
    findMacro = findMacro,
    actionScope = '$transform',
    actionScopeFlags = '$none',
    actionMacro = table.concat(actions, ' && '),
    notes = '',
    rangeFilterGrid = rangeFilterGrid,
  }
end

-- count preset files in folder
local function countPresetsInFolder(pPath)
  local count = 0
  local idx = 0
  r.EnumerateFiles(pPath, -1)  -- reset cache
  local fname = r.EnumerateFiles(pPath, idx)
  while fname do
    if fname:match('%.quantPreset$') then count = count + 1 end
    idx = idx + 1
    fname = r.EnumerateFiles(pPath, idx)
  end
  return count
end

-- recursive folder/preset enumeration with counts
local function enumerateQuantizePresets(pPath)
  local entries = {}
  local idx = 0

  -- enumerate subdirectories first
  r.EnumerateSubdirectories(pPath, -1)  -- reset cache
  local fname = r.EnumerateSubdirectories(pPath, idx)
  while fname do
    local entry = { label = fname, sub = nil, count = 0 }
    table.insert(entries, entry)
    idx = idx + 1
    fname = r.EnumerateSubdirectories(pPath, idx)
  end

  -- recursively populate .sub for each folder
  for _, v in ipairs(entries) do
    local newPath = pPath .. '/' .. v.label
    v.sub = enumerateQuantizePresets(newPath)
    v.count = countPresetsInFolder(newPath)
  end

  -- enumerate preset files
  idx = 0
  r.EnumerateFiles(pPath, -1)  -- reset cache
  fname = r.EnumerateFiles(pPath, idx)
  while fname do
    if fname:match('%.quantPreset$') then
      local entry = { label = fname:gsub('%.quantPreset$', '') }
      table.insert(entries, entry)
    end
    idx = idx + 1
    fname = r.EnumerateFiles(pPath, idx)
  end

  -- sort alphabetically case-insensitive (folders first since they have .sub)
  local sorted = {}
  for _, v in tg.spairs(entries, function(t, a, b)
    local aIsFolder = t[a].sub ~= nil
    local bIsFolder = t[b].sub ~= nil
    if aIsFolder ~= bIsFolder then return aIsFolder end  -- folders first
    return string.lower(t[a].label) < string.lower(t[b].label)
  end) do
    table.insert(sorted, v)
  end
  return sorted
end

-- generic file enumeration for groove browsers
-- extPattern: lua pattern for file extension (e.g., '%.rgt$' or '%.[mM][iI][dD]$')
-- extStrip: pattern to strip extension for display
local function enumerateGrooveFiles(gPath, extPattern, extStrip)
  if not gPath or not tg.dirExists(gPath) then return {} end

  local entries = {}
  local idx = 0

  -- enumerate subdirectories first
  r.EnumerateSubdirectories(gPath, -1)  -- reset cache
  local fname = r.EnumerateSubdirectories(gPath, idx)
  while fname do
    local entry = { label = fname, sub = true, count = 0 }  -- sub=true marks as folder
    table.insert(entries, entry)
    idx = idx + 1
    fname = r.EnumerateSubdirectories(gPath, idx)
  end

  -- count matching files in each subfolder
  for _, v in ipairs(entries) do
    local subPath = gPath .. '/' .. v.label
    local count = 0
    local fidx = 0
    r.EnumerateFiles(subPath, -1)
    local f = r.EnumerateFiles(subPath, fidx)
    while f do
      if f:match(extPattern) then count = count + 1 end
      fidx = fidx + 1
      f = r.EnumerateFiles(subPath, fidx)
    end
    v.count = count
  end

  -- enumerate matching files
  idx = 0
  r.EnumerateFiles(gPath, -1)  -- reset cache
  fname = r.EnumerateFiles(gPath, idx)
  while fname do
    if fname:match(extPattern) then
      local entry = { label = fname:gsub(extStrip, ''), filename = fname }
      table.insert(entries, entry)
    end
    idx = idx + 1
    fname = r.EnumerateFiles(gPath, idx)
  end

  -- sort alphabetically case-insensitive (folders first)
  local sorted = {}
  for _, v in tg.spairs(entries, function(t, a, b)
    local aIsFolder = t[a].sub
    local bIsFolder = t[b].sub
    if aIsFolder ~= bIsFolder then return aIsFolder end
    return string.lower(t[a].label) < string.lower(t[b].label)
  end) do
    table.insert(sorted, v)
  end
  return sorted
end

-- RGT groove browser functions
local function getRgtContents()
  if not rgtRootPath then return {} end
  local path = rgtSubPath or rgtRootPath
  return enumerateGrooveFiles(path, '%.rgt$', '%.rgt$')
end

local function navigateRgtParent()
  if not rgtSubPath then return end
  local parent = rgtSubPath:match('(.+)/[^/]+$')
  if parent and #parent >= #rgtRootPath then
    rgtSubPath = parent == rgtRootPath and nil or parent
  else
    rgtSubPath = nil
  end
  r.SetExtState(scriptID, 'rgtSubPath', rgtSubPath or '', true)
end

local function navigateRgtFolder(folderName)
  local basePath = rgtSubPath or rgtRootPath
  rgtSubPath = basePath .. '/' .. folderName
  r.SetExtState(scriptID, 'rgtSubPath', rgtSubPath, true)
end

local function loadRgtFile(filename)
  grooveErrorMessage = nil
  local basePath = rgtSubPath or rgtRootPath
  local filepath = basePath .. '/' .. filename .. '.rgt'
  local data = mgdefs.parseGrooveFile(filepath)
  if data then
    grooveFilePath = filepath
    grooveData = data
    r.SetExtState(scriptID, 'grooveFilePath', filepath, true)
    markControlChanged()
    return true
  end
  grooveErrorMessage = 'Could not load groove file'
  return false
end

local function pickRgtFolder()
  local initPath = rgtRootPath or r.GetResourcePath() .. '/Data/Grooves'
  local folder
  if r.APIExists('JS_Dialog_BrowseForFolder') then
    local retval, path = r.JS_Dialog_BrowseForFolder('Select RGT Groove Folder', initPath)
    if retval == 1 and path and path ~= '' then
      folder = path
    end
  else
    local retval, filepath = r.GetUserFileNameForRead(initPath, 'Select any .rgt file to set folder', '.rgt')
    if retval and filepath and filepath ~= '' then
      folder = filepath:match('(.+)[/\\][^/\\]+$')
    end
  end
  if folder then
    rgtRootPath = folder
    rgtSubPath = nil
    r.SetExtState(scriptID, 'rgtRootPath', folder, true)
    r.SetExtState(scriptID, 'rgtSubPath', '', true)
  end
end

-- load MIDI file as groove with error handling (ERR-04)
local function loadGrooveMIDIFile(filepath)
  grooveErrorMessage = nil

  local file = io.open(filepath, 'rb')
  if not file then
    grooveErrorMessage = 'Could not open file'
    return false
  end

  local size = file:seek('end')
  file:close()

  -- large file warning (>1MB)
  if size > 1048576 then
    local confirm = r.ShowMessageBox(
      string.format('File is %.1f MB. Large MIDI files may be slow to process.\n\nContinue?', size / 1048576),
      'Large MIDI File', 4)
    if confirm ~= 6 then
      return false
    end
  end

  file = io.open(filepath, 'rb')
  local data = file:read('*all')
  file:close()

  local success, result = pcall(function()
    local parsed, err = SMFParser.parse(data)
    if not parsed then error(err) end
    -- build extraction options from UI settings
    local thresholdModes = { [0] = 'ticks', [1] = 'ms', [2] = 'percent' }
    local coalesceModes = { [0] = 'first', [1] = 'loudest' }
    local opts = {
      threshold = midiThreshold,
      thresholdMode = thresholdModes[midiThresholdMode] or 'ms',
      coalescingMode = coalesceModes[midiCoalesceMode] or 'first'
    }
    local groove, err2 = SMFParser.extractGroove(parsed.notes, parsed.header, opts)
    if not groove then error(err2) end
    return groove
  end)

  if not success then
    local errMsg = tostring(result)
    if errMsg:match('MThd') or errMsg:match('too small') then
      grooveErrorMessage = 'Not a valid MIDI file'
    elseif errMsg:match('No notes') then
      grooveErrorMessage = 'No notes found in file'
    elseif errMsg:match('Type 2') then
      grooveErrorMessage = 'Type 2 MIDI not supported'
    else
      grooveErrorMessage = 'Could not read MIDI file'
    end
    return false
  end

  grooveFilePath = filepath
  grooveData = result
  r.SetExtState(scriptID, 'grooveFilePath', filepath, true)
  markControlChanged()
  return true
end

-- MIDI groove browser functions
local function getMidiContents()
  if not midiRootPath then return {} end
  local path = midiSubPath or midiRootPath
  -- match .mid, .MID, .smf, .SMF
  return enumerateGrooveFiles(path, '%.[mMsS][iImM][dDfF]$', '%.[mMsS][iImM][dDfF]$')
end

local function navigateMidiParent()
  if not midiSubPath then return end
  local parent = midiSubPath:match('(.+)/[^/]+$')
  if parent and #parent >= #midiRootPath then
    midiSubPath = parent == midiRootPath and nil or parent
  else
    midiSubPath = nil
  end
  r.SetExtState(scriptID, 'midiSubPath', midiSubPath or '', true)
end

local function navigateMidiFolder(folderName)
  local basePath = midiSubPath or midiRootPath
  midiSubPath = basePath .. '/' .. folderName
  r.SetExtState(scriptID, 'midiSubPath', midiSubPath, true)
end

-- fullFilename includes extension (e.g., "pattern.mid")
local function loadMidiFile(fullFilename)
  local basePath = midiSubPath or midiRootPath
  local filepath = basePath .. '/' .. fullFilename
  return loadGrooveMIDIFile(filepath)
end

local function pickMidiFolder()
  local initPath = midiRootPath or r.GetResourcePath()
  local folder
  if r.APIExists('JS_Dialog_BrowseForFolder') then
    local retval, path = r.JS_Dialog_BrowseForFolder('Select MIDI Groove Folder', initPath)
    if retval == 1 and path and path ~= '' then
      folder = path
    end
  else
    local retval, filepath = r.GetUserFileNameForRead(initPath, 'Select any MIDI file to set folder', '.mid')
    if retval and filepath and filepath ~= '' then
      folder = filepath:match('(.+)[/\\][^/\\]+$')
    end
  end
  if folder then
    midiRootPath = folder
    midiSubPath = nil
    r.SetExtState(scriptID, 'midiRootPath', folder, true)
    r.SetExtState(scriptID, 'midiSubPath', '', true)
  end
end

-- enumerate folders only (for save dialog)
local function enumerateFoldersOnly(pPath)
  local entries = {}
  local idx = 0

  r.EnumerateSubdirectories(pPath, -1)
  local fname = r.EnumerateSubdirectories(pPath, idx)
  while fname do
    local entry = { label = fname, sub = nil }
    table.insert(entries, entry)
    idx = idx + 1
    fname = r.EnumerateSubdirectories(pPath, idx)
  end

  -- recursively populate .sub for each folder
  for _, v in ipairs(entries) do
    local newPath = pPath .. '/' .. v.label
    v.sub = enumerateFoldersOnly(newPath)
  end

  -- sort alphabetically case-insensitive
  local sorted = {}
  for _, v in tg.spairs(entries, function(t, a, b)
    return string.lower(t[a].label) < string.lower(t[b].label)
  end) do
    table.insert(sorted, v)
  end
  return sorted
end

-- get current folder contents from tree
local function getCurrentFolderContents()
  if not presetSubPath then
    return presetTree
  end
  -- traverse tree following path segments
  local relPath = removePrefix(presetSubPath, presetPath .. '/')
  local current = presetTree
  for segment in relPath:gmatch('[^/]+') do
    local found = false
    for _, entry in ipairs(current) do
      if entry.label == segment and entry.sub then
        current = entry.sub
        found = true
        break
      end
    end
    if not found then return {} end
  end
  return current
end

-- navigate to parent folder
local function navigateToParent()
  if not presetSubPath then return end
  local parent = presetSubPath:match('(.+)/[^/]+$')
  -- only stay in subfolder if parent is deeper than presetPath
  if parent and #parent > #presetPath then
    presetSubPath = parent
  else
    presetSubPath = nil  -- back to root
  end
  r.SetExtState(scriptID, 'presetSubPath', presetSubPath or '', true)
end

-- navigate into folder
local function navigateToFolder(folderName)
  local basePath = presetSubPath or presetPath
  presetSubPath = basePath .. '/' .. folderName
  r.SetExtState(scriptID, 'presetSubPath', presetSubPath or '', true)
end

-- check if current state differs from loaded preset
local function isModified()
  if not loadedPresetState then return false end
  return scopeIndex ~= loadedPresetState.scopeIndex
    or targetIndex ~= loadedPresetState.targetIndex
    or strength ~= loadedPresetState.strength
    or gridMode ~= loadedPresetState.gridMode
    or gridDivIndex ~= loadedPresetState.gridDivIndex
    or gridStyleIndex ~= loadedPresetState.gridStyleIndex
    or lengthGridDivIndex ~= loadedPresetState.lengthGridDivIndex
    or swingStrength ~= loadedPresetState.swingStrength
    or fixOverlaps ~= loadedPresetState.fixOverlaps
    or canMoveLeft ~= loadedPresetState.canMoveLeft
    or canMoveRight ~= loadedPresetState.canMoveRight
    or canShrink ~= loadedPresetState.canShrink
    or canGrow ~= loadedPresetState.canGrow
    or rangeFilterEnabled ~= loadedPresetState.rangeFilterEnabled
    or rangeMin ~= loadedPresetState.rangeMin
    or rangeMax ~= loadedPresetState.rangeMax
    or distanceScaling ~= loadedPresetState.distanceScaling
    or grooveFilePath ~= loadedPresetState.grooveFilePath
    or grooveDirection ~= loadedPresetState.grooveDirection
    or grooveVelStrength ~= loadedPresetState.grooveVelStrength
    or grooveToleranceMin ~= loadedPresetState.grooveToleranceMin
    or grooveToleranceMax ~= loadedPresetState.grooveToleranceMax
end

-- capture current UI state for modified tracking
local function capturePresetState()
  return {
    scopeIndex = scopeIndex,
    targetIndex = targetIndex,
    strength = strength,
    gridMode = gridMode,
    gridDivIndex = gridDivIndex,
    gridStyleIndex = gridStyleIndex,
    lengthGridDivIndex = lengthGridDivIndex,
    swingStrength = swingStrength,
    fixOverlaps = fixOverlaps,
    canMoveLeft = canMoveLeft,
    canMoveRight = canMoveRight,
    canShrink = canShrink,
    canGrow = canGrow,
    rangeFilterEnabled = rangeFilterEnabled,
    rangeMin = rangeMin,
    rangeMax = rangeMax,
    distanceScaling = distanceScaling,
    grooveFilePath = grooveFilePath,
    grooveDirection = grooveDirection,
    grooveVelStrength = grooveVelStrength,
    grooveToleranceMin = grooveToleranceMin,
    grooveToleranceMax = grooveToleranceMax,
  }
end

-- sanitize preset name (handle Windows-forbidden chars)
local function sanitizePresetName(name)
  if not name then return '' end
  -- replace / with - (for grid divisions like 1/16 -> 1-16)
  name = name:gsub('/', '-')
  -- remove remaining forbidden chars: < > : " \ | ? *
  return name:gsub('[<>:"\\|%?%*]', '')
end

-- auto-generate preset name from settings
local function generatePresetName()
  local name
  if gridMode == 0 then
    name = 'Grid'
  elseif gridMode == 2 then
    -- groove mode: use groove file name (.rgt or .mid/.smf)
    if grooveFilePath then
      name = grooveFilePath:match('([^/]+)%.rgt$') or grooveFilePath:match('([^/\\]+)%.[mM][iI][dD]$') or grooveFilePath:match('([^/\\]+)%.[sS][mM][fF]$') or 'Groove'
    else
      name = 'Groove'
    end
  else
    name = gridDivLabels[gridDivIndex + 1]
  end

  -- add style modifier (only for Manual mode)
  if gridMode == 1 then
    if gridStyleIndex == 1 then
      name = name .. ' Triplet'
    elseif gridStyleIndex == 2 then
      name = name .. ' Dotted'
    elseif gridStyleIndex == 3 then
      name = name .. ' Swing ' .. swingStrength .. '%'
    end
  end

  -- add strength if not 100%
  if strength ~= 100 then
    name = name .. ' @' .. strength .. '%'
  end

  return sanitizePresetName(name)
end

-- save preset to file
local function saveQuantizePreset(name, toPath)
  name = sanitizePresetName(name)
  if name == '' then return false end

  -- determine save path (use specified, current folder, or root)
  local savePath = toPath or presetSubPath or presetPath

  -- ensure preset directory exists
  r.RecursiveCreateDirectory(savePath, 0)

  -- build preset table
  local preset = buildPresetTable()

  -- add quantizeUI metadata
  preset.quantizeUI = capturePresetState()

  -- serialize and write
  local filepath = savePath .. '/' .. name .. '.quantPreset'
  local file = io.open(filepath, 'w')
  if not file then return false end

  file:write(tg.serialize(preset))
  file:close()

  -- update state
  currentPresetName = name
  loadedPresetState = capturePresetState()
  presetListDirty = true

  return true
end

-- load preset from file
local function loadQuantizePreset(name, fromPath)
  if not name or name == '' then return false end

  local basePath = fromPath or presetSubPath or presetPath
  local filepath = basePath .. '/' .. name .. '.quantPreset'
  local file = io.open(filepath, 'r')
  if not file then
    statusMessage = 'Error: preset file not found'
    return false
  end

  local content = file:read('*all')
  file:close()

  local preset = tg.deserialize(content)
  if not preset then
    statusMessage = 'Error: failed to deserialize preset'
    return false
  end

  -- extract quantizeUI metadata
  if preset.quantizeUI then
    local ui = preset.quantizeUI
    scopeIndex = ui.scopeIndex or scopeIndex
    targetIndex = ui.targetIndex or targetIndex
    strength = ui.strength or strength
    gridMode = ui.gridMode or gridMode
    gridDivIndex = ui.gridDivIndex or gridDivIndex
    -- migrate old presets: gridMode=1 + gridDivIndex=11 -> gridMode=2
    if gridMode == 1 and gridDivIndex == 11 then
      gridMode = 2
      gridDivIndex = 3  -- reset to 1/16
    end
    -- clamp gridDivIndex to valid range (max 10 now that Groove is removed)
    if gridDivIndex > 10 then gridDivIndex = 10 end
    gridStyleIndex = ui.gridStyleIndex or gridStyleIndex
    lengthGridDivIndex = ui.lengthGridDivIndex or lengthGridDivIndex
    -- clamp lengthGridDivIndex to valid range (max 10 now that Groove is removed)
    if lengthGridDivIndex > 10 then lengthGridDivIndex = 10 end
    swingStrength = ui.swingStrength or swingStrength
    fixOverlaps = ui.fixOverlaps or fixOverlaps
    -- preview state intentionally not restored from presets

    canMoveLeft = ui.canMoveLeft ~= false  -- default true if missing (old presets)
    canMoveRight = ui.canMoveRight ~= false
    canShrink = ui.canShrink ~= false
    canGrow = ui.canGrow ~= false

    rangeFilterEnabled = ui.rangeFilterEnabled or false
    rangeMin = ui.rangeMin or 0.0
    rangeMax = ui.rangeMax or 100.0

    distanceScaling = ui.distanceScaling or false  -- default Off for old presets

    -- groove settings
    grooveFilePath = ui.grooveFilePath  -- nil if not in preset
    grooveDirection = ui.grooveDirection or 0
    grooveVelStrength = ui.grooveVelStrength or 0
    grooveToleranceMin = ui.grooveToleranceMin or 0.0
    grooveToleranceMax = ui.grooveToleranceMax or 100.0
    -- reload groove data if file path exists (.rgt or .mid/.smf)
    if grooveFilePath and tg.filePathExists(grooveFilePath) then
      grooveData = mgdefs.loadGrooveFromFile(grooveFilePath)
    else
      grooveData = nil
    end

    -- persist to ExtState
    r.SetExtState(scriptID, 'scopeIndex', tostring(scopeIndex), true)
    r.SetExtState(scriptID, 'targetIndex', tostring(targetIndex), true)
    r.SetExtState(scriptID, 'strength', tostring(strength), true)
    r.SetExtState(scriptID, 'gridMode', tostring(gridMode), true)
    r.SetExtState(scriptID, 'gridDivIndex', tostring(gridDivIndex), true)
    r.SetExtState(scriptID, 'gridStyleIndex', tostring(gridStyleIndex), true)
    r.SetExtState(scriptID, 'lengthGridDivIndex', tostring(lengthGridDivIndex), true)
    r.SetExtState(scriptID, 'swingStrength', tostring(swingStrength), true)
    r.SetExtState(scriptID, 'fixOverlaps', tostring(fixOverlaps), true)
    r.SetExtState(scriptID, 'canMoveLeft', tostring(canMoveLeft), true)
    r.SetExtState(scriptID, 'canMoveRight', tostring(canMoveRight), true)
    r.SetExtState(scriptID, 'canShrink', tostring(canShrink), true)
    r.SetExtState(scriptID, 'canGrow', tostring(canGrow), true)
    r.SetExtState(scriptID, 'rangeFilterEnabled', tostring(rangeFilterEnabled), true)
    r.SetExtState(scriptID, 'rangeMin', tostring(rangeMin), true)
    r.SetExtState(scriptID, 'rangeMax', tostring(rangeMax), true)
    r.SetExtState(scriptID, 'distanceScaling', tostring(distanceScaling), true)
    r.SetExtState(scriptID, 'grooveFilePath', grooveFilePath or '', true)
    r.SetExtState(scriptID, 'grooveDirection', tostring(grooveDirection), true)
    r.SetExtState(scriptID, 'grooveVelStrength', tostring(grooveVelStrength), true)
    r.SetExtState(scriptID, 'grooveToleranceMin', tostring(grooveToleranceMin), true)
    r.SetExtState(scriptID, 'grooveToleranceMax', tostring(grooveToleranceMax), true)
  else
    statusMessage = 'Error: no quantizeUI metadata in preset'
    return false
  end

  -- update state
  currentPresetName = name
  loadedPresetState = capturePresetState()

  -- trigger live preview with new settings
  markControlChanged()

  return true
end

-- recursively delete folder and contents
local function recursiveDeleteFolder(pPath)
  -- delete files first
  local idx = 0
  r.EnumerateFiles(pPath, -1)
  local fname = r.EnumerateFiles(pPath, idx)
  while fname do
    os.remove(pPath .. '/' .. fname)
    idx = idx + 1
    fname = r.EnumerateFiles(pPath, idx)
  end

  -- recursively delete subfolders
  idx = 0
  r.EnumerateSubdirectories(pPath, -1)
  fname = r.EnumerateSubdirectories(pPath, idx)
  while fname do
    recursiveDeleteFolder(pPath .. '/' .. fname)
    idx = idx + 1
    fname = r.EnumerateSubdirectories(pPath, idx)
  end

  -- delete empty folder
  os.remove(pPath)
end

-- delete preset file
local function deletePreset(name, fromPath)
  if not name or name == '' then return false end

  local basePath = fromPath or presetSubPath or presetPath
  local filepath = basePath .. '/' .. name .. '.quantPreset'
  os.remove(filepath)

  -- clear current preset if deleted
  if currentPresetName == name then
    currentPresetName = ''
    loadedPresetState = nil
  end

  presetListDirty = true
  return true
end

-- export preset as standalone script
local function exportQuantizeScript(presetName, registerAction)
  -- ensure preset exists first
  local presetFile = presetName .. '.quantPreset'
  local presetFullPath = presetPath .. '/' .. presetFile
  if not tg.filePathExists(presetFullPath) then
    return false, 'Preset file not found'
  end

  local scriptPath = presetPath .. '/Quantize_' .. presetName .. '.lua'
  local f = io.open(scriptPath, 'wb')
  if not f then return false, 'Could not create script file' end

  f:write('-- Auto-generated Quantize script\n')
  f:write('package.path = reaper.GetResourcePath() .. "/Scripts/sockmonkey72 Scripts/MIDI Editor/Transformer/?.lua"\n')
  f:write('local tx = require("TransformerLib")\n')
  f:write('local thisPath = debug.getinfo(1, "S").source:match [[^@?(.*[\\\\/])[^\\\\/]-$]]\n')
  f:write('tx.loadPreset(thisPath .. "' .. presetFile .. '")\n')
  f:write('tx.processAction(true, true)\n')
  f:close()

  if registerAction then
    -- Register in MIDI Editor section (32060)
    r.AddRemoveReaScript(true, 32060, scriptPath, true)
  end

  return true, scriptPath
end

-- ensure factory presets exist
local function ensureFactoryPresets()
  if not tg.dirExists(presetPath) then
    r.RecursiveCreateDirectory(presetPath, 0)
  end

  -- factory presets (only create if not exist)
  local factory = {
    {
      name = 'Quantize 1-16 Straight',
      preset = {
        findScope = '$midieditor',
        findScopeFlags = { '$selectedonly' },
        findMacro = '$type == $note',
        actionScope = '$transform',
        actionScopeFlags = '$none',
        actionMacro = '$position :roundmusical($1/16|--|0.00|0.00, 100)',
        notes = '',
        quantizeUI = {
          scopeIndex = 1, targetIndex = 0, strength = 100,
          gridMode = 1, gridDivIndex = 3, gridStyleIndex = 0,
          lengthGridDivIndex = 10, swingStrength = 66, fixOverlaps = false
        }
      }
    },
    {
      name = 'Quantize 1-8 Swing 66%',
      preset = {
        findScope = '$midieditor',
        findScopeFlags = { '$selectedonly' },
        findMacro = '$type == $note',
        actionScope = '$transform',
        actionScopeFlags = '$none',
        actionMacro = '$position :roundmusical($1/8|r-|0.00|0.00|sw(66.00), 100)',
        notes = '',
        quantizeUI = {
          scopeIndex = 1, targetIndex = 0, strength = 100,
          gridMode = 1, gridDivIndex = 4, gridStyleIndex = 3,
          lengthGridDivIndex = 10, swingStrength = 66, fixOverlaps = false
        }
      }
    },
    {
      name = 'Quantize 1-16 Triplet',
      preset = {
        findScope = '$midieditor',
        findScopeFlags = { '$selectedonly' },
        findMacro = '$type == $note',
        actionScope = '$transform',
        actionScopeFlags = '$none',
        actionMacro = '$position :roundmusical($1/16|t-|0.00|0.00, 100)',
        notes = '',
        quantizeUI = {
          scopeIndex = 1, targetIndex = 0, strength = 100,
          gridMode = 1, gridDivIndex = 3, gridStyleIndex = 1,
          lengthGridDivIndex = 10, swingStrength = 66, fixOverlaps = false
        }
      }
    },
    {
      name = 'Quantize Grid',
      preset = {
        findScope = '$midieditor',
        findScopeFlags = { '$selectedonly' },
        findMacro = '$type == $note',
        actionScope = '$transform',
        actionScopeFlags = '$none',
        actionMacro = '$position :roundmusical($grid|--|0.00|0.00, 100)',
        notes = '',
        quantizeUI = {
          scopeIndex = 1, targetIndex = 0, strength = 100,
          gridMode = 0, gridDivIndex = 3, gridStyleIndex = 0,
          lengthGridDivIndex = 10, swingStrength = 66, fixOverlaps = false
        }
      }
    }
  }

  for _, fp in ipairs(factory) do
    local path = presetPath .. '/' .. fp.name .. '.quantPreset'
    if not tg.filePathExists(path) then
      local f = io.open(path, 'wb')
      if f then
        f:write(tg.serialize(fp.preset) .. '\n')
        f:close()
      end
    end
  end
end

local function countSelectedNotes(take)
  if not take or not r.ValidatePtr(take, 'MediaItem_Take*') then return 0 end
  local count = 0
  local idx = -1
  while true do
    idx = r.MIDI_EnumSelNotes(take, idx)
    if idx == -1 then break end
    count = count + 1
  end
  return count
end

local function countSelectedEvents(take)
  if not take or not r.ValidatePtr(take, 'MediaItem_Take*') then return 0 end
  local count = 0
  local idx = -1
  while true do
    idx = r.MIDI_EnumSelCC(take, idx)
    if idx == -1 then break end
    count = count + 1
  end
  return count
end

local function countAllNotes(take)
  if not take or not r.ValidatePtr(take, 'MediaItem_Take*') then return 0 end
  local _, numNotes = r.MIDI_CountEvts(take)
  return numNotes
end

local function countAllEvents(take)
  if not take or not r.ValidatePtr(take, 'MediaItem_Take*') then return 0 end
  local numCC = r.MIDI_CountEvts(take)
  return numCC
end

-- forward declaration for shutdown
local restoreMIDIState

-- lifecycle
local function shutdown()
  -- restore cached MIDI state if preview was on
  if previewActive then
    restoreMIDIState()
  end
  -- focus MIDI editor on exit
  local me = r.MIDIEditor_GetActive()
  if me and r.JS_Window_SetFocus then
    r.JS_Window_SetFocus(me)
  end
end

local function onCrash(err)
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
  shutdown()
end

-- live preview helpers

-- get all takes from MIDI editor
local function getAffectedTakes()
  local takes = {}
  local me = r.MIDIEditor_GetActive()
  if not me then return takes end
  local idx = 0
  while true do
    local take = r.MIDIEditor_EnumTakes(me, idx, true)
    if not take then break end
    if r.ValidatePtr(take, 'MediaItem_Take*') then
      table.insert(takes, take)
    end
    idx = idx + 1
  end
  return takes
end

-- convenience accessors for ops state
local function getOpsState() return ops.getState() end

-- wrapper functions that delegate to ops module
local function computeMIDIContentHash() return ops.computeMIDIContentHash() end
local function computeOriginalHash() return ops.computeOriginalHash() end
local function detectSelectionChange() return ops.detectSelectionChange() end
local function capturePreRestoreSnapshot() return ops.capturePreRestoreSnapshot() end
restoreMIDIState = function() return ops.restoreMIDIState() end
local parseMIDIEvents = ops.parseMIDIEvents
local encodeMIDIEvents = ops.encodeMIDIEvents
local matchNotesByIdentity = ops.matchNotesByIdentity
local deepcopy = ops.deepcopy

-- cache MIDI state for all affected takes
local function cacheMIDIState()
  ops.cacheMIDIState(getAffectedTakes)
end

-- apply quantize to events array (in-memory, does not write to take)
local function applyQuantizeToEvents(events, take)
  if not events or #events == 0 then return events end

  -- get PPQ for conversion
  local ppq = 960  -- default
  if take and r.ValidatePtr(take, 'MediaItem_Take*') then
    local ppqAtZero = r.MIDI_GetPPQPosFromProjTime(take, 0)
    local ppqAtOne = r.MIDI_GetPPQPosFromProjTime(take, 1)
    ppq = math.abs(ppqAtOne - ppqAtZero)
  end

  -- get quantize params from UI
  local notation = buildMusicalParams('position')

  -- skip if groove mode (not implemented yet)
  if notation:match('^%$groove') then
    return events
  end

  -- parse notation: $grid or $qn|mod|preslop|postslop
  local gridUnit, swing, dirFlags

  if notation:match('^%$grid') then
    -- use MIDI editor grid
    local editor = r.MIDIEditor_GetActive()
    local editorTake = editor and r.MIDIEditor_GetTake(editor)
    if editorTake then
      local _, div, swingVal = r.MIDI_GetGrid(editorTake)
      gridUnit = ppq * 4 * div  -- div is fraction of whole note
      swing = swingVal or 0
    else
      return events  -- no grid available
    end
  else
    -- manual grid: parse notation
    local qnStr = notation:match('^%$([^|]+)')
    local modStr = notation:match('|([^|]+)|')

    -- subdivision from qn string
    local qnToPPQ = {
      ['1/128'] = ppq / 32,
      ['1/64'] = ppq / 16,
      ['1/32'] = ppq / 8,
      ['1/16'] = ppq / 4,
      ['1/8'] = ppq / 2,
      ['1/4'] = ppq,
      ['1/2'] = ppq * 2,
      ['1'] = ppq * 4,
      ['2'] = ppq * 8,
      ['4'] = ppq * 16,
    }
    gridUnit = qnToPPQ[qnStr] or ppq

    -- apply modifier (t=triplet, d=dotted, r=swing, -=straight)
    local mod = modStr and modStr:sub(1, 1) or '-'
    if mod == 't' then
      gridUnit = gridUnit * 2 / 3
    elseif mod == 'd' then
      gridUnit = gridUnit * 1.5
    end

    -- extract swing if present
    swing = 0
    local swingMatch = notation:match('|sw%(([%d%.]+)%)')
    if swingMatch then
      swing = tonumber(swingMatch) / 100
    end

    -- extract direction flags if present
    local dirMatch = notation:match('|df%((%d+)%)')
    dirFlags = dirMatch and tonumber(dirMatch) or 0xF
  end

  -- get strength
  local strengthVal = strength / 100

  -- helper to quantize a single ppq position
  local function quantizePPQ(oldPPQ)
    -- find measure start
    local projTime = r.MIDI_GetProjTimeFromPPQPos(take, oldPPQ)
    local measure = r.TimeMap_timeToQN(projTime) / 4  -- measures
    local measureStart = math.floor(measure) * 4  -- QN at measure start
    local measureStartTime = r.TimeMap_QNToTime(measureStart)
    local measureStartPPQ = r.MIDI_GetPPQPosFromProjTime(take, measureStartTime)

    -- quantize relative to measure
    local ppqInMeasure = oldPPQ - measureStartPPQ
    local newPPQInMeasure = gridUnit * math.floor((ppqInMeasure / gridUnit) + 0.5)

    -- apply swing (offset every other grid position)
    if swing > 0 then
      local gridIndex = math.floor(ppqInMeasure / gridUnit)
      if gridIndex % 2 == 1 then
        newPPQInMeasure = newPPQInMeasure + (gridUnit * swing)
      end
    end

    local newPPQ = measureStartPPQ + newPPQInMeasure

    -- apply strength
    return oldPPQ + ((newPPQ - oldPPQ) * strengthVal)
  end

  -- quantize note and CC events
  for i, event in ipairs(events) do
    if (event.type == 'note' or event.type == 'cc') and event.ppqTime then
      events[i].ppqTime = quantizePPQ(event.ppqTime)
    end
  end

  -- recalculate offsets from ppqTime
  for i = 1, #events do
    local prevPPQ = (i == 1) and 0 or events[i-1].ppqTime
    events[i].offset = math.floor(events[i].ppqTime - prevPPQ + 0.5)
  end

  return events
end

-- apply preview (restore then re-apply without undo)
local function applyLivePreview()
  if not previewActive then
    if CACHE_DEBUG then r.ShowConsoleMsg('APPLY: skipped (previewActive=false)\n') end
    return
  end

  local state = getOpsState()

  -- compute hash of original state to detect if cache changed
  local origHash = computeOriginalHash()

  -- skip if we already applied preview with same original data and no param change
  if state.lastPreviewApplied and origHash == state.lastOriginalHash and not state.previewPending then
    if CACHE_DEBUG then r.ShowConsoleMsg('APPLY: skipped (already applied, same hash)\n') end
    return
  end

  if CACHE_DEBUG then r.ShowConsoleMsg('=== APPLY LIVE PREVIEW ===\n') end
  capturePreRestoreSnapshot()  -- capture current state before restore to preserve user edits
  restoreMIDIState()

  if CACHE_DEBUG then r.ShowConsoleMsg('  running quantize...\n') end
  r.PreventUIRefresh(1)
  local preset = buildPresetTable()
  local loadOk = pcall(tx.loadPresetFromTable, preset)
  if loadOk then
    -- apply fixOverlaps setting (favor note-on to protect short notes)
    local savedOverlaps = mu.CORRECT_OVERLAPS
    local savedFavorNoteOn = mu.CORRECT_OVERLAPS_FAVOR_NOTEON
    mu.CORRECT_OVERLAPS = fixOverlaps
    mu.CORRECT_OVERLAPS_FAVOR_NOTEON = fixOverlaps
    pcall(tx.processAction, true, false, true)  -- execute, not from script, skip undo
    mu.CORRECT_OVERLAPS = savedOverlaps
    mu.CORRECT_OVERLAPS_FAVOR_NOTEON = savedFavorNoteOn
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()

  state.lastOriginalHash = origHash
  state.lastPreviewApplied = true
  -- update baseline after apply (captures post-quantize state)
  if CACHE_DEBUG then r.ShowConsoleMsg('  updating baseline...\n') end
  ops.updateBaselineAfterApply()
  if CACHE_DEBUG then r.ShowConsoleMsg('=== APPLY DONE ===\n') end
end

-- wrapper for onExternalMIDIChange that passes applyQuantizeToEvents callback
local function onExternalMIDIChange()
  return ops.onExternalMIDIChange(applyQuantizeToEvents)
end

local firstFrame = true
local DEBOUNCE_INTERVAL = 0.033  -- 33ms in seconds

local function loop()
  local state = getOpsState()

  -- check MIDI editor still open
  if not r.MIDIEditor_GetActive() then
    wantsQuit = true
  end

  -- live preview: check for selection change (skip first frame - handled below)
  if not firstFrame and previewActive and detectSelectionChange() then
    restoreMIDIState()  -- restore old takes before caching new ones
    cacheMIDIState()
    applyLivePreview()
  end

  -- change detection: poll MIDI hash for external edits
  if not firstFrame and previewActive and not state.isApplying and not state.pauseLiveMode then
    local currentHash = computeMIDIContentHash()
    if state.lastMIDIContentHash and currentHash ~= state.lastMIDIContentHash then
      -- external change detected
      if DEBUG then r.ShowConsoleMsg('MIDI change detected\n') end
      local result = onExternalMIDIChange()
      -- 'skip' means transient REAPER state, will retry next frame
    end
    state.lastMIDIContentHash = currentHash
  end

  -- live preview: check debounce expiry (skip first frame)
  if not firstFrame and state.previewPending and state.lastControlChangeTime then
    local elapsed = r.time_precise() - state.lastControlChangeTime
    if elapsed >= DEBOUNCE_INTERVAL then
      applyLivePreview()
      state.previewPending = false
    end
  end

  -- count notes and events for UI feedback
  local noteCount = 0
  local eventCount = 0
  local hasCount = false
  local editor = r.MIDIEditor_GetActive()
  local take = editor and r.MIDIEditor_GetTake(editor)

  if take then
    if scopeIndex == 0 then  -- All notes
      noteCount = countAllNotes(take)
      hasCount = true
    elseif scopeIndex == 1 then  -- Selected notes
      noteCount = countSelectedNotes(take)
      hasCount = true
    elseif scopeIndex == 2 then  -- All events
      noteCount = countAllNotes(take)
      eventCount = countAllEvents(take)
      hasCount = true
    elseif scopeIndex == 3 then  -- Selected events
      noteCount = countSelectedNotes(take)
      eventCount = countSelectedEvents(take)
      hasCount = true
    end
  end

  -- build count display string (only non-zero)
  local countDisplay = ''
  if hasCount then
    if scopeIndex == 0 or scopeIndex == 1 then  -- notes only
      if noteCount > 0 then
        countDisplay = noteCount .. ' note' .. (noteCount == 1 and '' or 's')
      end
    else  -- all events
      local parts = {}
      if noteCount > 0 then
        table.insert(parts, noteCount .. ' note' .. (noteCount == 1 and '' or 's'))
      end
      if eventCount > 0 then
        table.insert(parts, eventCount .. ' event' .. (eventCount == 1 and '' or 's'))
      end
      countDisplay = table.concat(parts, ', ')
    end
  end

  if firstFrame then
    ImGui.SetNextWindowPos(ctx, windowPos.left, windowPos.top, ImGui.Cond_FirstUseEver)
    firstFrame = false
    -- preview starts off by default, no initialization needed
    state.lastTakeHash = ops.computeTakeHash()
  end

  -- fixed window size to prevent layout jumps
  ImGui.SetNextWindowSizeConstraints(ctx, 350, 0, 350, 9999)
  ImGui.SetNextWindowBgAlpha(ctx, 1)

  -- visual indicator for live preview mode
  local liveMode = previewActive
  local displayTitle = liveMode and 'Quantize (Transformer) \u{25CF} LIVE' or 'Quantize (Transformer)'
  local windowTitle = displayTitle .. '###QuantizeWindow'
  if liveMode then
    -- tint when live (dark red background, orange title bar)
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, 0x200808FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive, 0x804020FF)
  end

  local visible, open = ImGui.Begin(ctx, windowTitle, true,
    ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoDocking | ImGui.WindowFlags_TopMost)

  if visible then
    local rv, newIdx

    -- frame-local key handling flags (like Transformer.lua pattern)
    local handledEscape = false
    local handledEnter = false

    -- refresh preset list if dirty
    if presetListDirty then
      presetTree = enumerateQuantizePresets(presetPath)
      presetListDirty = false
    end

    -- preset row: combo + Save button
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Preset:')
    ImGui.SameLine(ctx, labelWidthHeader)

    -- build display label with folder path indicator
    local folderIndicator = ''
    if presetSubPath then
      local relPath = removePrefix(presetSubPath, presetPath .. '/')
      folderIndicator = relPath .. '/'
    end
    local comboLabel = currentPresetName ~= '' and (folderIndicator .. currentPresetName) or '(none)'
    if currentPresetName ~= '' and isModified() then
      comboLabel = comboLabel .. ' *'
    end

    ImGui.PushItemWidth(ctx, 225)
    if ImGui.BeginCombo(ctx, '##presetCombo', comboLabel) then
      local currentContents = getCurrentFolderContents()

      -- show parent navigation if in subfolder
      if presetSubPath then
        if ImGui.Selectable(ctx, '[..]', false, ImGui.SelectableFlags_DontClosePopups) then
          navigateToParent()
        end
      end

      -- show folders and presets
      for _, entry in ipairs(currentContents) do
        if entry.sub then
          -- folder entry
          local folderLabel = '[DIR] ' .. entry.label
          if entry.count and entry.count > 0 then
            folderLabel = folderLabel .. ' (' .. entry.count .. ')'
          end
          if ImGui.Selectable(ctx, folderLabel, false, ImGui.SelectableFlags_DontClosePopups) then
            navigateToFolder(entry.label)
          end
          -- right-click context menu for folder delete
          if ImGui.BeginPopupContextItem(ctx, '##deleteFolder_' .. entry.label) then
            if ImGui.MenuItem(ctx, 'Delete folder') then
              confirmDeleteFolder = true
              deleteFolderPath = (presetSubPath or presetPath) .. '/' .. entry.label
              deleteFolderName = entry.label
            end
            ImGui.EndPopup(ctx)
          end
        else
          -- preset file entry
          local selected = (entry.label == currentPresetName)
          if ImGui.Selectable(ctx, entry.label, selected) then
            loadQuantizePreset(entry.label)
          end
          -- right-click context menu for delete
          if ImGui.BeginPopupContextItem(ctx, '##deletePreset_' .. entry.label) then
            if ImGui.MenuItem(ctx, 'Delete') then
              deletePreset(entry.label)
            end
            ImGui.EndPopup(ctx)
          end
        end
      end

      -- show empty folder message
      if #currentContents == 0 then
        ImGui.TextDisabled(ctx, 'Empty folder')
      end

      ImGui.EndCombo(ctx)
    end
    ImGui.PopItemWidth(ctx)

    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Save...') then
      -- open save popup near button
      savePopupJustOpened = true
      savePopupPos[1], savePopupPos[2] = ImGui.GetMousePos(ctx)
      saveNameBuffer = generatePresetName()
      exportAfterSave = false
      exportRegisterAction = false
    end
    ImGui.Dummy(ctx, 0, 2)
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 2)

    -- settings row: grid mode + preview button right-aligned
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Settings:')
    ImGui.SameLine(ctx, labelWidthHeader)
    ImGui.PushItemWidth(ctx, 80)
    rv, newIdx = ImGui.Combo(ctx, '##gridMode', gridMode, gridModeItems)
    ImGui.PopItemWidth(ctx)
    if rv then
      gridMode = newIdx
      grooveErrorMessage = nil  -- clear error when changing mode
      r.SetExtState(scriptID, 'gridMode', tostring(gridMode), true)
      markControlChanged()
    end
    -- preview button: right-aligned to match target combo right edge
    -- click+hold = momentary, opt-click = toggle on, click when latched = toggle off
    local previewLabel = 'Preview'
    local previewTextW = ImGui.CalcTextSize(ctx, previewLabel)
    local buttonPadding = 10  -- approximate button padding
    local targetRightEdge = ImGui.GetContentRegionMax(ctx)
    local buttonWidth = previewTextW + buttonPadding
    local previewX = targetRightEdge - buttonWidth
    ImGui.SameLine(ctx, previewX)

    -- check for opt/alt modifier
    local optHeld = ImGui.IsKeyDown(ctx, ImGui.Mod_Alt)

    -- draw button with frame border and active state styling
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
    if previewActive then
      -- orange to match LIVE title bar
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x804020FF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x905030FF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x703010FF)
      ImGui.PushStyleColor(ctx, ImGui.Col_Border, 0xC06030FF)
    else
      ImGui.PushStyleColor(ctx, ImGui.Col_Border, 0x606060FF)
    end

    local clicked = ImGui.Button(ctx, previewLabel)
    local buttonHovered = ImGui.IsItemHovered(ctx)
    local mouseDown = ImGui.IsMouseDown(ctx, 0)  -- left mouse button

    if previewActive then
      ImGui.PopStyleColor(ctx, 4)
    else
      ImGui.PopStyleColor(ctx, 1)
    end
    ImGui.PopStyleVar(ctx, 1)

    -- handle button interaction
    if clicked then
      if previewLatched then
        -- click when latched: turn off
        if CACHE_DEBUG then r.ShowConsoleMsg('=== PREVIEW OFF (unlatch) ===\n') end
        previewLatched = false
        capturePreRestoreSnapshot()
        previewActive = false
        restoreMIDIState()
      elseif optHeld then
        -- opt-click: toggle latch on
        previewLatched = true
        if not previewActive then
          previewActive = true
          cacheMIDIState()
          applyLivePreview()
          if CACHE_DEBUG then r.ShowConsoleMsg('PREVIEW: opt-click, latching on\n') end
        end
      end
      -- regular click without latch: handled by buttonActive below
    end

    -- momentary behavior: track mouse hold (only when not latched, not opt-clicking, not shift-previewing)
    local windowFocused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
    local shiftHeld = windowFocused and ImGui.IsKeyDown(ctx, ImGui.Mod_Shift)
    if not previewLatched and not optHeld and not shiftHeld then
      if buttonHovered and mouseDown and not previewButtonDown then
        -- mouse just pressed on button (start hold)
        previewButtonDown = true
        previewActive = true
        cacheMIDIState()
        applyLivePreview()
        if CACHE_DEBUG then r.ShowConsoleMsg('PREVIEW: button down, activating\n') end
      elseif previewButtonDown and not mouseDown then
        -- mouse released globally (end hold - don't require hover)
        if CACHE_DEBUG then r.ShowConsoleMsg('=== PREVIEW OFF (button up) ===\n') end
        previewButtonDown = false
        capturePreRestoreSnapshot()
        previewActive = false
        restoreMIDIState()
        if CACHE_DEBUG then r.ShowConsoleMsg('=== PREVIEW OFF COMPLETE ===\n') end
      end
    end

    -- shift key: momentary preview (only when not latched)
    if not previewLatched then
      if shiftHeld and not previewShiftDown and not previewButtonDown then
        -- shift just pressed
        previewShiftDown = true
        previewActive = true
        cacheMIDIState()
        applyLivePreview()
        if CACHE_DEBUG then r.ShowConsoleMsg('PREVIEW: shift down, activating\n') end
      elseif not shiftHeld and previewShiftDown then
        -- shift just released
        if CACHE_DEBUG then r.ShowConsoleMsg('=== PREVIEW OFF (shift up) ===\n') end
        previewShiftDown = false
        capturePreRestoreSnapshot()
        previewActive = false
        restoreMIDIState()
      end
    end
    ImGui.Dummy(ctx, 0, 2)

    -- quantize row: scope + target
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Quantize:')
    ImGui.SameLine(ctx, labelWidthHeader)
    ImGui.PushItemWidth(ctx, 125)
    rv, newIdx = ImGui.Combo(ctx, '##scope', scopeIndex, scopeItems)
    if rv then
      scopeIndex = newIdx
      r.SetExtState(scriptID, 'scopeIndex', tostring(scopeIndex), true)
      markControlChanged()
    end
    ImGui.SameLine(ctx)
    ImGui.PushItemWidth(ctx, 142)
    -- in groove mode, only Position only is available
    if gridMode == 2 then
      ImGui.BeginDisabled(ctx, true)
      ImGui.Combo(ctx, '##target', 0, 'Position only\0')
      ImGui.EndDisabled(ctx)
      if targetIndex ~= 0 then
        targetIndex = 0
        r.SetExtState(scriptID, 'targetIndex', tostring(targetIndex), true)
        markControlChanged()
      end
    else
      rv, newIdx = ImGui.Combo(ctx, '##target', targetIndex, targetItems)
      if rv then
        targetIndex = newIdx
        r.SetExtState(scriptID, 'targetIndex', tostring(targetIndex), true)
        markControlChanged()
      end
    end
    ImGui.PopItemWidth(ctx)
    ImGui.PopItemWidth(ctx)
    ImGui.Dummy(ctx, 0, 2)

    -- status line: show statusMessage if set, else countDisplay
    local displayText = statusMessage ~= '' and statusMessage or countDisplay
    if displayText == '' then displayText = ' ' end
    ImGui.Text(ctx, displayText)
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 2)

    -- strength slider
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Strength:')
    ImGui.SameLine(ctx, labelWidthMain)
    ImGui.PushItemWidth(ctx, 275)
    rv, strength = ImGui.SliderInt(ctx, '##strength', strength, 0, 100, '%d%%')
    strength = math.max(0, math.min(100, strength))
    ImGui.PopItemWidth(ctx)
    if rv then
      r.SetExtState(scriptID, 'strength', tostring(strength), true)
      markControlChanged()
    end
    ImGui.Dummy(ctx, 0, 2)

    -- grid row: Grid [div] [style] Length [div] (only shown in Manual mode)
    local lengthGridEnabled = (targetIndex == 2 or targetIndex == 4)
    if gridMode == 1 then
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, 'Grid:')
      ImGui.SameLine(ctx, labelWidthMain)
      ImGui.PushItemWidth(ctx, 69)
      if ImGui.BeginCombo(ctx, '##gridDiv', gridDivLabels[gridDivIndex + 1]) then
        for i, label in ipairs(gridDivLabels) do
          if ImGui.Selectable(ctx, label, gridDivIndex == i - 1) then
            gridDivIndex = i - 1
            r.SetExtState(scriptID, 'gridDivIndex', tostring(gridDivIndex), true)
            markControlChanged()
          end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.PopItemWidth(ctx)
      ImGui.SameLine(ctx)
      ImGui.PushItemWidth(ctx, 68)
      rv, newIdx = ImGui.Combo(ctx, '##gridStyle', gridStyleIndex, gridStyleItems)
      if rv then
        gridStyleIndex = newIdx
        r.SetExtState(scriptID, 'gridStyleIndex', tostring(gridStyleIndex), true)
        markControlChanged()
      end
      ImGui.PopItemWidth(ctx)
      ImGui.SameLine(ctx, 0, 15)
      ImGui.BeginDisabled(ctx, not lengthGridEnabled)
      ImGui.Text(ctx, 'Length:')
      ImGui.SameLine(ctx)
      ImGui.PushItemWidth(ctx, 69)
      if ImGui.BeginCombo(ctx, '##lengthDiv', gridDivLabels[lengthGridDivIndex + 1]) then
        for i, label in ipairs(gridDivLabels) do
          if ImGui.Selectable(ctx, label, lengthGridDivIndex == i - 1) then
            lengthGridDivIndex = i - 1
            r.SetExtState(scriptID, 'lengthGridDivIndex', tostring(lengthGridDivIndex), true)
            markControlChanged()
          end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.PopItemWidth(ctx)
      ImGui.EndDisabled(ctx)
      ImGui.Dummy(ctx, 0, 2)
    end

    -- swing strength row (visible when swing selected in Manual mode)
    if gridMode == 1 then
      local showSwing = (gridStyleIndex == 3)
      if showSwing then
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'Swing strength:')
        ImGui.SameLine(ctx, labelWidthSwing)
        ImGui.PushItemWidth(ctx, 240)
        rv, swingStrength = ImGui.SliderInt(ctx, '##swing', swingStrength, 0, 100, '%d%%')
        ImGui.PopItemWidth(ctx)
        if rv then
          r.SetExtState(scriptID, 'swingStrength', tostring(swingStrength), true)
          markControlChanged()
        end
      else
        -- dummy for stable height when Manual mode but non-swing style
        ImGui.Dummy(ctx, 0, ImGui.GetFrameHeight(ctx))
      end
      ImGui.Dummy(ctx, 0, 2)
    end

    -- groove settings section (visible in Groove mode)
    local grooveModeActive = gridMode == 2
    if grooveModeActive then
      ImGui.Separator(ctx)
      ImGui.Dummy(ctx, 0, 2)
      ImGui.Text(ctx, 'Groove Settings')
      ImGui.Dummy(ctx, 0, 2)

      -- groove file picker (single menu with RGT/MIDI submenus)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, 'Groove:')
      ImGui.SameLine(ctx, labelWidthMain)

      -- display: extract filename from full path
      local grooveDisplay = '(none)'
      if grooveFilePath then
        grooveDisplay = grooveFilePath:match('([^/\\]+)$') or grooveFilePath
      end

      ImGui.PushItemWidth(ctx, 275)
      if ImGui.BeginCombo(ctx, '##grooveCombo', grooveDisplay) then

        -- === RGT SUBMENU ===
        ImGui.SetNextWindowSizeConstraints(ctx, 150, 0, 300, 400)
        if ImGui.BeginMenu(ctx, 'RGT') then
          if ImGui.MenuItem(ctx, 'Set folder...') then
            pickRgtFolder()
          end

          if rgtRootPath then
            ImGui.Separator(ctx)

            if rgtSubPath then
              if ImGui.Selectable(ctx, '..', false, ImGui.SelectableFlags_DontClosePopups) then
                navigateRgtParent()
              end
            end

            local rgtContents = getRgtContents()
            for _, entry in ipairs(rgtContents) do
              if entry.sub then
                local folderLabel = entry.label .. '/'
                if entry.count > 0 then
                  folderLabel = folderLabel .. ' (' .. entry.count .. ')'
                end
                if ImGui.Selectable(ctx, folderLabel, false, ImGui.SelectableFlags_DontClosePopups) then
                  navigateRgtFolder(entry.label)
                end
              else
                local selected = grooveFilePath and grooveFilePath:match('([^/\\]+)$') == entry.filename
                if ImGui.MenuItem(ctx, entry.label, nil, selected) then
                  loadRgtFile(entry.label)
                end
              end
            end

            if #rgtContents == 0 then
              ImGui.TextDisabled(ctx, '(no .rgt files)')
            end
          else
            ImGui.Separator(ctx)
            ImGui.TextDisabled(ctx, '(folder not set)')
          end

          ImGui.EndMenu(ctx)
        end

        -- === MIDI SUBMENU ===
        ImGui.SetNextWindowSizeConstraints(ctx, 150, 0, 300, 400)
        if ImGui.BeginMenu(ctx, 'MIDI') then
          if ImGui.MenuItem(ctx, 'Set folder...') then
            pickMidiFolder()
          end

          if midiRootPath then
            ImGui.Separator(ctx)

            if midiSubPath then
              if ImGui.Selectable(ctx, '..', false, ImGui.SelectableFlags_DontClosePopups) then
                navigateMidiParent()
              end
            end

            local midiContents = getMidiContents()
            for _, entry in ipairs(midiContents) do
              if entry.sub then
                local folderLabel = entry.label .. '/'
                if entry.count > 0 then
                  folderLabel = folderLabel .. ' (' .. entry.count .. ')'
                end
                if ImGui.Selectable(ctx, folderLabel, false, ImGui.SelectableFlags_DontClosePopups) then
                  navigateMidiFolder(entry.label)
                end
              else
                local selected = grooveFilePath and grooveFilePath:match('([^/\\]+)$') == entry.filename
                if ImGui.MenuItem(ctx, entry.label, nil, selected) then
                  loadMidiFile(entry.filename)
                end
              end
            end

            if #midiContents == 0 then
              ImGui.TextDisabled(ctx, '(no MIDI files)')
            end
          else
            ImGui.Separator(ctx)
            ImGui.TextDisabled(ctx, '(folder not set)')
          end

          ImGui.EndMenu(ctx)
        end

        ImGui.EndCombo(ctx)
      end
      ImGui.PopItemWidth(ctx)

      -- inline error display (red text)
      if grooveErrorMessage then
        ImGui.TextColored(ctx, 0xFF4444FF, grooveErrorMessage)
      end
      ImGui.Dummy(ctx, 0, 2)

      -- direction combo + velocity strength slider
      local grooveDirectionItems = 'Both\0Early only\0Late only\0'
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, 'Direction:')
      ImGui.SameLine(ctx, labelWidthMain)
      ImGui.PushItemWidth(ctx, 90)
      rv, newIdx = ImGui.Combo(ctx, '##grooveDir', grooveDirection, grooveDirectionItems)
      if rv then
        grooveDirection = newIdx
        r.SetExtState(scriptID, 'grooveDirection', tostring(grooveDirection), true)
        markControlChanged()
      end
      ImGui.PopItemWidth(ctx)

      ImGui.SameLine(ctx, 0, 19)
      ImGui.Text(ctx, 'Vel Str:')
      ImGui.SameLine(ctx)
      ImGui.PushItemWidth(ctx, 120)
      rv, grooveVelStrength = ImGui.SliderInt(ctx, '##grooveVel', grooveVelStrength, 0, 100, '%d%%')
      grooveVelStrength = math.max(0, math.min(100, grooveVelStrength))
      if rv then
        r.SetExtState(scriptID, 'grooveVelStrength', tostring(grooveVelStrength), true)
        markControlChanged()
      end
      ImGui.PopItemWidth(ctx)
      ImGui.Dummy(ctx, 0, 2)

      -- tolerance sliders
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, 'Tolerance:')
      ImGui.SameLine(ctx, labelWidthMain)
      local tolSliderW = 125
      ImGui.PushItemWidth(ctx, tolSliderW)
      rv, grooveToleranceMin = ImGui.SliderDouble(ctx, '##grooveTolMin', grooveToleranceMin, 0.0, 100.0, '%.0f%%')
      if rv then
        r.SetExtState(scriptID, 'grooveToleranceMin', tostring(grooveToleranceMin), true)
        if grooveToleranceMin > grooveToleranceMax then
          grooveToleranceMax = grooveToleranceMin
          r.SetExtState(scriptID, 'grooveToleranceMax', tostring(grooveToleranceMax), true)
        end
        markControlChanged()
      end
      ImGui.PopItemWidth(ctx)
      ImGui.SameLine(ctx)
      ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) - 1)
      ImGui.Text(ctx, 'to')
      ImGui.SameLine(ctx)
      ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) - 1)
      ImGui.PushItemWidth(ctx, tolSliderW)
      rv, grooveToleranceMax = ImGui.SliderDouble(ctx, '##grooveTolMax', grooveToleranceMax, 0.0, 100.0, '%.0f%%')
      if rv then
        r.SetExtState(scriptID, 'grooveToleranceMax', tostring(grooveToleranceMax), true)
        if grooveToleranceMax < grooveToleranceMin then
          grooveToleranceMin = grooveToleranceMax
          r.SetExtState(scriptID, 'grooveToleranceMin', tostring(grooveToleranceMin), true)
        end
        markControlChanged()
      end
      ImGui.PopItemWidth(ctx)
      ImGui.Dummy(ctx, 0, 2)

      -- MIDI extraction settings (only shown when MIDI file loaded)
      local ext = grooveFilePath and grooveFilePath:lower():match('%.([^%.]+)$')
      local isMidiGroove = ext == 'mid' or ext == 'smf' or ext == 'midi'
      if isMidiGroove then
        ImGui.Separator(ctx)
        ImGui.Dummy(ctx, 0, 2)
        ImGui.TextDisabled(ctx, 'MIDI Extraction')

        -- threshold row: value + mode
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'Coalesce:')
        ImGui.SameLine(ctx, labelWidthMain)
        ImGui.PushItemWidth(ctx, 66)
        local newThreshold
        rv, newThreshold = ImGui.InputDouble(ctx, '##midiThreshold', midiThreshold, 0, 0, '%.1f')
        if rv then
          midiThreshold = math.max(0, newThreshold)
          r.SetExtState(scriptID, 'midiThreshold', tostring(midiThreshold), true)
          loadGrooveMIDIFile(grooveFilePath)
          markControlChanged()
        end
        ImGui.PopItemWidth(ctx)

        ImGui.SameLine(ctx)
        ImGui.PushItemWidth(ctx, 65)
        local thresholdModeItems = 'ticks\0ms\0%beat\0'
        rv, newIdx = ImGui.Combo(ctx, '##midiThreshMode', midiThresholdMode, thresholdModeItems)
        if rv then
          midiThresholdMode = newIdx
          r.SetExtState(scriptID, 'midiThresholdMode', tostring(midiThresholdMode), true)
          loadGrooveMIDIFile(grooveFilePath)
          markControlChanged()
        end
        ImGui.PopItemWidth(ctx)

        ImGui.SameLine(ctx, 0, 10)
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'preferring')
        -- coalesce mode
        ImGui.SameLine(ctx)
        ImGui.PushItemWidth(ctx, 66)
        local coalesceModeItems = 'first\0loudest\0'
        rv, newIdx = ImGui.Combo(ctx, '##midiCoalesce', midiCoalesceMode, coalesceModeItems)
        if rv then
          midiCoalesceMode = newIdx
          r.SetExtState(scriptID, 'midiCoalesceMode', tostring(midiCoalesceMode), true)
          loadGrooveMIDIFile(grooveFilePath)
          markControlChanged()
        end
        ImGui.PopItemWidth(ctx)
        ImGui.Dummy(ctx, 0, 2)
      end
    end

    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 2)

    -- direction constraints
    ImGui.Text(ctx, 'Allow events to:')
    ImGui.Dummy(ctx, 0, 2)

    local positionApplicable = (targetIndex <= 2)  -- Position only (0), Position+end (1), Position+length (2)
    local lengthApplicable = (targetIndex >= 1)  -- all except Position only (0)
    -- gray out move left/right when groove mode active (direction controlled by groove Direction combo)
    local groovePositionActive = gridMode == 2

    ImGui.BeginDisabled(ctx, not positionApplicable or groovePositionActive)
    rv, canMoveLeft = ImGui.Checkbox(ctx, 'Move left', canMoveLeft)
    if rv then
      r.SetExtState(scriptID, 'canMoveLeft', tostring(canMoveLeft), true)
      if not canMoveLeft and not canMoveRight then
        canMoveRight = true
        r.SetExtState(scriptID, 'canMoveRight', 'true', true)
      end
      markControlChanged()
    end

    local cbSpacer = 16

    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + cbSpacer)
    rv, canMoveRight = ImGui.Checkbox(ctx, 'Move right', canMoveRight)
    if rv then
      r.SetExtState(scriptID, 'canMoveRight', tostring(canMoveRight), true)
      if not canMoveLeft and not canMoveRight then
        canMoveLeft = true
        r.SetExtState(scriptID, 'canMoveLeft', 'true', true)
      end
      markControlChanged()
    end
    ImGui.EndDisabled(ctx)

    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + cbSpacer)
    ImGui.BeginDisabled(ctx, not lengthApplicable)
    rv, canShrink = ImGui.Checkbox(ctx, 'Shrink', canShrink)
    if rv then
      r.SetExtState(scriptID, 'canShrink', tostring(canShrink), true)
      if not canShrink and not canGrow then
        canGrow = true
        r.SetExtState(scriptID, 'canGrow', 'true', true)
      end
      markControlChanged()
    end

    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + cbSpacer)
    rv, canGrow = ImGui.Checkbox(ctx, 'Grow', canGrow)
    if rv then
      r.SetExtState(scriptID, 'canGrow', tostring(canGrow), true)
      if not canShrink and not canGrow then
        canShrink = true
        r.SetExtState(scriptID, 'canShrink', 'true', true)
      end
      markControlChanged()
    end
    ImGui.EndDisabled(ctx)
    ImGui.Dummy(ctx, 0, 2)
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 2)

    -- range filter section
    rv, rangeFilterEnabled = ImGui.Checkbox(ctx, 'Only quantize range (0% = on grid, 50% = between grid):', rangeFilterEnabled)
    if rv then
      r.SetExtState(scriptID, 'rangeFilterEnabled', tostring(rangeFilterEnabled), true)
      markControlChanged()
    end
    ImGui.BeginDisabled(ctx, not rangeFilterEnabled)
    local availWidth = ImGui.GetContentRegionAvail(ctx) - 10
    local sliderWidth = (availWidth - 20) / 2  -- subtract space for "to" text
    ImGui.PushItemWidth(ctx, sliderWidth)
    rv, rangeMin = ImGui.SliderDouble(ctx, '##rangeMin', rangeMin, 0.0, 100.0, '%.1f%%')
    if rv then
      r.SetExtState(scriptID, 'rangeMin', tostring(rangeMin), true)
      if rangeMin > rangeMax then
        rangeMax = rangeMin
        r.SetExtState(scriptID, 'rangeMax', tostring(rangeMax), true)
      end
      markControlChanged()
    end
    ImGui.PopItemWidth(ctx)
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, 'to')
    ImGui.SameLine(ctx)
    ImGui.PushItemWidth(ctx, sliderWidth)
    rv, rangeMax = ImGui.SliderDouble(ctx, '##rangeMax', rangeMax, 0.0, 100.0, '%.1f%%')
    if rv then
      r.SetExtState(scriptID, 'rangeMax', tostring(rangeMax), true)
      if rangeMax < rangeMin then
        rangeMin = rangeMax
        r.SetExtState(scriptID, 'rangeMin', tostring(rangeMin), true)
      end
      markControlChanged()
    end
    ImGui.PopItemWidth(ctx)
    -- distance scaling checkbox (linear interpolation within range)
    rv, distanceScaling = ImGui.Checkbox(ctx, 'Scale strength by distance', distanceScaling)
    if rv then
      r.SetExtState(scriptID, 'distanceScaling', tostring(distanceScaling), true)
      markControlChanged()
    end
    ImGui.EndDisabled(ctx)
    ImGui.Dummy(ctx, 0, 2)
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 2)

    -- fix overlaps checkbox
    rv, fixOverlaps = ImGui.Checkbox(ctx, 'Fix overlaps', fixOverlaps)
    if rv then
      r.SetExtState(scriptID, 'fixOverlaps', tostring(fixOverlaps), true)
      markControlChanged()
    end
    ImGui.Dummy(ctx, 0, 2)

    ImGui.Separator(ctx)

    -- buttons
    local isSelectedScope = (scopeIndex == 1 or scopeIndex == 3)
    local shouldDisable = isSelectedScope and (noteCount == 0 and eventCount == 0)
    ImGui.BeginDisabled(ctx, shouldDisable or isExecuting)
    if ImGui.Button(ctx, 'Apply') then
      isExecuting = true
      statusMessage = ''
      local applyState = getOpsState()

      local success, err = pcall(function()
        applyState.isApplying = true  -- mark start of Apply to filter self-changes

        -- restore to cached state first (clean slate)
        restoreMIDIState()

        -- build and execute with undo
        local preset = buildPresetTable()
        tx.loadPresetFromTable(preset)
        -- apply fixOverlaps setting (favor note-on to protect short notes)
        local savedOverlaps = mu.CORRECT_OVERLAPS
        local savedFavorNoteOn = mu.CORRECT_OVERLAPS_FAVOR_NOTEON
        mu.CORRECT_OVERLAPS = fixOverlaps
        mu.CORRECT_OVERLAPS_FAVOR_NOTEON = fixOverlaps
        tx.processAction(true, false)  -- WITH undo (skipUndo = false/nil)
        mu.CORRECT_OVERLAPS = savedOverlaps
        mu.CORRECT_OVERLAPS_FAVOR_NOTEON = savedFavorNoteOn

        -- re-cache current state as new baseline
        cacheMIDIState()

        -- update content hash after Apply completes (new baseline)
        applyState.lastMIDIContentHash = computeMIDIContentHash()

        -- end preview mode (quantize is now permanent)
        previewActive = false
        previewLatched = false
        previewButtonDown = false
        previewShiftDown = false
        ops.resetState()  -- clear all cache state

        -- build success message
        local gridLabel = gridMode == 0 and 'grid' or gridMode == 2 and 'groove' or gridDivLabels[gridDivIndex + 1]
        local count = scopeIndex <= 1 and noteCount or (noteCount + eventCount)
        local unit = scopeIndex <= 1 and 'note' or 'event'
        statusMessage = 'Applied: ' .. count .. ' ' .. unit .. (count == 1 and '' or 's') .. ' to ' .. gridLabel
      end)

      if not success then
        statusMessage = 'Error: ' .. tostring(err)
        r.ShowConsoleMsg('Quantize error: ' .. tostring(err) .. '\n')
        -- restore on error
        restoreMIDIState()
      end

      applyState.isApplying = false  -- clear flag after Apply completes
      isExecuting = false
    end
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Cancel') then
      -- restore to last cached state (post-Apply or initial)
      restoreMIDIState()
      wantsQuit = true
    end

    -- save preset popup modal
    if savePopupJustOpened then
      ImGui.SetNextWindowPos(ctx, savePopupPos[1], savePopupPos[2], ImGui.Cond_Appearing)
      ImGui.OpenPopup(ctx, 'Save Preset')
      -- initialize folder tree and target (only once)
      presetFolders = enumerateFoldersOnly(presetPath)
      saveTargetPath = presetSubPath  -- start with current folder
      showNewFolderInput = false  -- reset inline folder input
      savePopupJustOpened = false
    end

    -- helper: recursively render folder menu for save dialog
    local function renderFolderMenu(folders, path)
      for _, entry in ipairs(folders) do
        if ImGui.BeginMenu(ctx, entry.label) then
          renderFolderMenu(entry.sub or {}, path .. '/' .. entry.label)
          ImGui.EndMenu(ctx)
        end
      end
      -- save here option at each level
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xCCCCFFCC)
      if ImGui.Selectable(ctx, 'Save here', false, ImGui.SelectableFlags_DontClosePopups) then
        pendingSaveTargetPath = path
      end
      if ImGui.Selectable(ctx, '+ New Folder...', false, ImGui.SelectableFlags_DontClosePopups) then
        showNewFolderInput = true
        focusNewFolderInput = true
        newFolderParentPath = path
        newFolderInputBuffer = ''
      end
      ImGui.PopStyleColor(ctx)
    end

    if ImGui.BeginPopupModal(ctx, 'Save Preset', true, ImGui.WindowFlags_AlwaysAutoResize) then
      -- folder selection row
      ImGui.Text(ctx, 'Folder:')
      ImGui.SameLine(ctx)
      local folderDisplay = '(root)'
      if saveTargetPath then
        folderDisplay = removePrefix(saveTargetPath, presetPath .. '/')
      end
      ImGui.BeginDisabled(ctx, showNewFolderInput)
      if ImGui.BeginMenu(ctx, folderDisplay .. ' ...') then
        renderFolderMenu(presetFolders, presetPath)
        ImGui.EndMenu(ctx)
      end
      ImGui.EndDisabled(ctx)
      -- process pending folder selection from menu
      if pendingSaveTargetPath then
        if pendingSaveTargetPath == presetPath then
          saveTargetPath = nil
        else
          saveTargetPath = pendingSaveTargetPath
        end
        pendingSaveTargetPath = nil
      end

      -- inline new folder creation (no nested popup)
      if showNewFolderInput then
        ImGui.Spacing(ctx)
        ImGui.Separator(ctx)
        ImGui.Spacing(ctx)
        local parentDisplay = newFolderParentPath == presetPath and '(root)' or removePrefix(newFolderParentPath, presetPath .. '/')
        ImGui.Text(ctx, 'New folder in: ' .. parentDisplay)
        ImGui.SetNextItemWidth(ctx, 200)
        if focusNewFolderInput then
          ImGui.SetKeyboardFocusHere(ctx)
          focusNewFolderInput = false
        end
        local rv4, buf4 = ImGui.InputText(ctx, '##newfoldername', newFolderInputBuffer)
        newFolderInputBuffer = buf4
        -- check for Enter key while input is active
        local enterInInput = ImGui.IsItemDeactivatedAfterEdit(ctx)
          and (ImGui.IsKeyDown(ctx, ImGui.Key_Enter) or ImGui.IsKeyDown(ctx, ImGui.Key_KeypadEnter))

        ImGui.SameLine(ctx)
        local doCreate = ImGui.Button(ctx, 'Create') or (enterInInput and newFolderInputBuffer ~= '')
        if doCreate and newFolderInputBuffer ~= '' then
          local newPath = newFolderParentPath .. '/' .. newFolderInputBuffer
          if r.RecursiveCreateDirectory(newPath, 0) ~= 0 then
            saveTargetPath = newPath ~= presetPath and newPath or nil
            presetFolders = enumerateFoldersOnly(presetPath)
          end
          showNewFolderInput = false
          handledEnter = true
        end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, 'Cancel##newfolder') then
          showNewFolderInput = false
        end
        ImGui.Spacing(ctx)
        ImGui.Separator(ctx)
      end

      ImGui.Spacing(ctx)

      ImGui.BeginDisabled(ctx, showNewFolderInput)
      ImGui.Text(ctx, 'Preset name:')
      ImGui.SetNextItemWidth(ctx, 250)
      local rv2, buf = ImGui.InputText(ctx, '##saveName', saveNameBuffer)
      saveNameBuffer = buf

      ImGui.Spacing(ctx)

      -- export checkboxes
      _, exportAfterSave = ImGui.Checkbox(ctx, 'Also export as script', exportAfterSave)
      if exportAfterSave then
        ImGui.Indent(ctx)
        _, exportRegisterAction = ImGui.Checkbox(ctx, 'Add to REAPER action list', exportRegisterAction)
        ImGui.Unindent(ctx)
      end
      ImGui.EndDisabled(ctx)

      ImGui.Spacing(ctx)

      -- Enter triggers save, Escape triggers cancel
      local overwriteOpen = ImGui.IsPopupOpen(ctx, 'Overwrite?')
      local keyEnter = not handledEnter and not showNewFolderInput and isFreshEnterPress()
      local enterPressed = not overwriteOpen and keyEnter
      local doSave = ImGui.Button(ctx, 'Save') or enterPressed
      if doSave then
        if enterPressed then handledEnter = true end
        local name = saveNameBuffer
        if name and name ~= '' then
          -- use saveTargetPath or presetPath
          local targetPath = saveTargetPath or presetPath
          -- check overwrite
          local exists = tg.filePathExists(targetPath .. '/' .. name .. '.quantPreset')
          if exists then
            confirmOverwrite = true
            overwriteName = name
          else
            if saveQuantizePreset(name, targetPath) then
              statusMessage = 'Saved: ' .. name
              -- update main preset view to show saved folder
              presetSubPath = saveTargetPath
              r.SetExtState(scriptID, 'presetSubPath', presetSubPath or '', true)
              presetListDirty = true
              -- export if requested
              if exportAfterSave then
                local expOk, expResult = exportQuantizeScript(name, exportRegisterAction)
                if expOk then
                  statusMessage = statusMessage .. ' + exported'
                  if exportRegisterAction then statusMessage = statusMessage .. ' (registered)' end
                else
                  statusMessage = statusMessage .. ' (export failed: ' .. expResult .. ')'
                end
              end
            else
              statusMessage = 'Failed to save preset'
            end
            ImGui.CloseCurrentPopup(ctx)
          end
        end
      end
      ImGui.SameLine(ctx)
      local keyEscape = not handledEscape and isFreshEscapePress()
      local doCancel = ImGui.Button(ctx, 'Cancel') or keyEscape
      if doCancel then
        if keyEscape then handledEscape = true end
        ImGui.CloseCurrentPopup(ctx)
      end

      ImGui.EndPopup(ctx)
    end

    -- overwrite confirmation popup
    if confirmOverwrite then
      ImGui.OpenPopup(ctx, 'Overwrite?')
      confirmOverwrite = false  -- only call OpenPopup once
    end

    if ImGui.BeginPopupModal(ctx, 'Overwrite?', true, ImGui.WindowFlags_AlwaysAutoResize) then
      ImGui.Text(ctx, 'Preset "' .. overwriteName .. '" exists. Overwrite?')
      ImGui.Spacing(ctx)
      local keyEnter = not handledEnter and isFreshEnterPress()
      local doOverwrite = ImGui.Button(ctx, 'Overwrite') or keyEnter
      if doOverwrite then
        if keyEnter then handledEnter = true end
        local targetPath = saveTargetPath or presetPath
        if saveQuantizePreset(overwriteName, targetPath) then
          statusMessage = 'Saved: ' .. overwriteName
          -- update main preset view to show saved folder
          presetSubPath = saveTargetPath
          r.SetExtState(scriptID, 'presetSubPath', presetSubPath or '', true)
          presetListDirty = true
          -- export if requested
          if exportAfterSave then
            local expOk, expResult = exportQuantizeScript(overwriteName, exportRegisterAction)
            if expOk then
              statusMessage = statusMessage .. ' + exported'
              if exportRegisterAction then statusMessage = statusMessage .. ' (registered)' end
            else
              statusMessage = statusMessage .. ' (export failed: ' .. expResult .. ')'
            end
          end
        else
          statusMessage = 'Failed to save preset'
        end
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      local keyEscape = not handledEscape and isFreshEscapePress()
      local doCancel = ImGui.Button(ctx, 'Cancel') or keyEscape
      if doCancel then
        if keyEscape then handledEscape = true end
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.EndPopup(ctx)
    end

    -- folder delete confirmation popup
    if confirmDeleteFolder then
      ImGui.OpenPopup(ctx, 'Delete Folder?')
      confirmDeleteFolder = false  -- only call OpenPopup once
    end

    if ImGui.BeginPopupModal(ctx, 'Delete Folder?', true, ImGui.WindowFlags_AlwaysAutoResize) then
      local presetCount = countPresetsInFolder(deleteFolderPath)
      ImGui.Text(ctx, 'Delete "' .. (deleteFolderName or '') .. '"?')
      if presetCount > 0 then
        ImGui.Text(ctx, 'Contains ' .. presetCount .. ' preset' .. (presetCount == 1 and '' or 's') .. '.')
      end
      ImGui.Text(ctx, 'This cannot be undone.')
      ImGui.Spacing(ctx)
      local doDelete = ImGui.Button(ctx, 'Delete')
      if doDelete then
        recursiveDeleteFolder(deleteFolderPath)
        -- reset presetSubPath if deleted folder was current or parent
        if presetSubPath and presetSubPath:find(deleteFolderPath, 1, true) == 1 then
          presetSubPath = nil
          r.SetExtState(scriptID, 'presetSubPath', '', true)
        end
        presetListDirty = true
        confirmDeleteFolder = false
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      local keyEscape = not handledEscape and isFreshEscapePress()
      if ImGui.Button(ctx, 'Cancel') or keyEscape then
        if keyEscape then handledEscape = true end
        confirmDeleteFolder = false
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.EndPopup(ctx)
    end

    -- conflict dialog for catastrophic MIDI changes
    local conflictState = getOpsState()
    if conflictState.showConflictDialog then
      -- only show if still in preview mode; clear state if not
      if previewActive then
        -- center dialog on main window
        local winX, winY = ImGui.GetWindowPos(ctx)
        local winW, winH = ImGui.GetWindowSize(ctx)
        ImGui.SetNextWindowPos(ctx, winX + winW * 0.5, winY + winH * 0.5, ImGui.Cond_Appearing, 0.5, 0.5)
        ImGui.OpenPopup(ctx, 'MIDI Changed')
      else
        -- not in preview mode - clear catastrophic state without showing dialog
        conflictState.catastrophicTakes = {}
        conflictState.pauseLiveMode = false
      end
      conflictState.showConflictDialog = false
    end

    if ImGui.BeginPopupModal(ctx, 'MIDI Changed', true, ImGui.WindowFlags_AlwaysAutoResize) then
      ImGui.Text(ctx, 'MIDI changed during preview.')
      ImGui.Spacing(ctx)

      -- Accept Changes: bake current state (quantized + user edit), turn preview off
      if ImGui.Button(ctx, 'Accept Changes') then
        -- current MIDI (with quantization baked in) becomes the new state
        for take, _ in pairs(conflictState.catastrophicTakes) do
          if r.ValidatePtr(take, 'MediaItem_Take*') then
            local rv, midiStr = r.MIDI_GetAllEvts(take, '')
            if rv then
              conflictState.originalMIDICache[take] = midiStr
              conflictState.reconciliationBaseline[take] = midiStr
            end
          end
        end
        conflictState.catastrophicTakes = {}
        conflictState.pauseLiveMode = false
        -- turn preview off (don't restore - user accepted the current state)
        previewActive = false
        previewLatched = false
        previewButtonDown = false
        previewShiftDown = false
        ops.resetState()  -- clear all cache state
        ImGui.CloseCurrentPopup(ctx)
      end

      ImGui.SameLine(ctx)

      -- Undo Edit: restore original, re-apply preview (stay in preview mode)
      if ImGui.Button(ctx, 'Undo Edit') then
        -- restore to pre-preview state, then re-apply quantize
        conflictState.catastrophicTakes = {}
        conflictState.pauseLiveMode = false
        -- restore original MIDI (forceRaw=true to discard all edits)
        ops.restoreMIDIState(true)
        -- clear pristinePostQuantize so it gets refreshed by applyLivePreview
        conflictState.pristinePostQuantize = {}
        -- force fresh apply (skip early-exit check)
        conflictState.lastPreviewApplied = false
        applyLivePreview()
        ImGui.CloseCurrentPopup(ctx)
      end

      -- escape key closes (treat as Accept Changes)
      local keyEscape = not handledEscape and isFreshEscapePress()
      if keyEscape then
        handledEscape = true
        -- same as Accept Changes
        for take, _ in pairs(conflictState.catastrophicTakes) do
          if r.ValidatePtr(take, 'MediaItem_Take*') then
            local rv, midiStr = r.MIDI_GetAllEvts(take, '')
            if rv then
              conflictState.originalMIDICache[take] = midiStr
              conflictState.reconciliationBaseline[take] = midiStr
            end
          end
        end
        conflictState.catastrophicTakes = {}
        conflictState.pauseLiveMode = false
        previewActive = false
        previewLatched = false
        previewButtonDown = false
        previewShiftDown = false
        ops.resetState()  -- clear all cache state
        ImGui.CloseCurrentPopup(ctx)
      end

      ImGui.EndPopup(ctx)
    end

    -- keyboard shortcuts passthrough to MIDI editor
    if ImGui.IsWindowFocused(ctx) and not ImGui.IsAnyItemActive(ctx) then
      local keyMods = ImGui.GetKeyMods(ctx)
      local modKey = keyMods == ImGui.Mod_Ctrl
      local modShiftKey = keyMods == ImGui.Mod_Ctrl + ImGui.Mod_Shift
      local noMod = keyMods == 0

      local anyPopupOpen = ImGui.IsPopupOpen(ctx, '', ImGui.PopupFlags_AnyPopupId + ImGui.PopupFlags_AnyPopupLevel)
      if modKey and ImGui.IsKeyPressed(ctx, ImGui.Key_Z) then -- undo
        r.MIDIEditor_OnCommand(editor, 40013)
      elseif modShiftKey and ImGui.IsKeyPressed(ctx, ImGui.Key_Z) then -- redo
        r.MIDIEditor_OnCommand(editor, 40014)
      elseif noMod and ImGui.IsKeyPressed(ctx, ImGui.Key_Space) then -- play/pause
        r.MIDIEditor_OnCommand(editor, 40016)
      elseif noMod and not handledEscape and isFreshEscapePress() and not ImGui.IsAnyItemActive(ctx) and not anyPopupOpen then
        wantsQuit = true
      end
    elseif not handledEscape and isFreshEscapePress() and not ImGui.IsPopupOpen(ctx, '', ImGui.PopupFlags_AnyPopupId + ImGui.PopupFlags_AnyPopupLevel) then
      wantsQuit = true
    end

    -- update key states at end of frame for fresh press detection
    updateKeyStates()

    updateWindowPosition()
    ImGui.End(ctx)
  end

  -- pop live preview style colors (must match push count)
  if liveMode then
    ImGui.PopStyleColor(ctx, 2)
  end

  if open and not wantsQuit then
    r.defer(function() xpcall(loop, onCrash) end)
  end
end

initializeWindowPosition()
initializeScopeState()
initializeQuantizeState()
ensureFactoryPresets()
presetListDirty = true
r.defer(function() xpcall(loop, onCrash) end)
r.atexit(shutdown)
