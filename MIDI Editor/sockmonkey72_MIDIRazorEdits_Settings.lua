--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'RazorEdits/?.lua;' -- GET DIRECTORY FOR REQUIRE
local keys = require 'MIDIRazorEdits_Keys'
local helper = require 'MIDIRazorEdits_Helper'
if not keys then
  r.ShowConsoleMsg("MIDI Razor Edits (Settings) cannot find necessary files, please reinstall\n")
end

if not r.APIExists('ImGui_GetBuiltinPath') then
  r.ShowConsoleMsg('MIDI Razor Edits (Settings) requires \'ReaImGui\' 0.9.3+ (install from ReaPack)\n')
  return
end

package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9.3'
if not ImGui then
  r.ShowConsoleMsg('MIDI Razor Edits (Settings) requires \'ReaImGui\' 0.9.3+ (install from ReaPack)\n')
  return
end

local scriptID = 'sockmonkey72_MRE_Settings'
local scriptID_Save = 'sockmonkey72_MIDIRazorEdits'

local osName = r.GetOS()
local is_windows = osName:match('Win')
local is_macos = osName:match('OS')
local is_linux = osName:match('Other')

local ctrlName = is_macos and 'cmd' or 'ctrl'
local shiftName = 'shift'
local altName = is_macos and 'opt' or 'alt'
local superName = is_macos and 'ctrl' or is_linux and 'super' or 'windows'

------------------------------------------------
------------------------------------------------

local _, _, sectionID, commandID = reaper.get_action_context()

r.set_action_options(1)

local ctx = ImGui.CreateContext(scriptID)

local function tableCopySimpleKeys(obj, seen)
  if type(obj) ~= 'table' then return obj end
  if seen and seen[obj] then return seen[obj] end
  local s = seen or {}
  local res = setmetatable({}, getmetatable(obj))
  s[obj] = res
  for k, v in pairs(obj) do res[k] = tableCopySimpleKeys(v, s) end
  return res
end

local function spairs(t, order)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  if order then
    table.sort(keys, function(a, b) return order(t, a, b) end)
  else
    table.sort(keys)
  end
  local i = 0
  return function()
    i = i + 1
    if keys[i] then return keys[i], t[keys[i]] end
  end
end

-- (Win/Lin: add 1 for shift, 2 for control, 4 for alt, 8 for win.)
-- (macOS: add 1 for shift, 2 for command, 4 for opt, 8 for control.)

local intercepting = false
local currentRow
local prevKeys
local overlapTestFailed = false

local keyMappings = tableCopySimpleKeys(keys.defaultKeyMappings)
local pbKeyMappings = tableCopySimpleKeys(keys.defaultPbKeyMappings)
local modMappings = tableCopySimpleKeys(keys.defaultModMappings)
local widgetMappings = tableCopySimpleKeys(keys.defaultWidgetMappings)

local lastKeyState
local lastPbKeyState
local lastModState
local lastWidgetState
local prefsStretchMode
local stretchMode
local prefsWidgetStretchMode
local widgetStretchMode
local prefsWantsControlPoints
local wantsControlPoints
local prefsSlicerDefaultTrim
local slicerDefaultTrim
local prefsWantsFullLaneDefault
local wantsFullLaneDefault
local prefsWantsRightButton
local wantsRightButton
local prefsPbMaxBendUp
local pbMaxBendUp
local prefsPbMaxBendDown
local pbMaxBendDown
local prefsPbSnapToSemitone
local pbSnapToSemitone
local prefsPbShowAllNotes
local pbShowAllNotes
local prefsPbSclDirectory
local pbSclDirectory
local prefsPbDefaultTuning
local pbDefaultTuning
local pbSclFiles = {}  -- cached list of .scl files
-- color overrides (nil = use theme)
local prefsPbLineColor
local pbLineColor
local prefsPbPointColor
local pbPointColor
local prefsPbSelectedColor
local pbSelectedColor
local prefsPbHoveredColor
local pbHoveredColor

local function releaseKeys()
  if intercepting then
    helper.VKeys_Intercept(-1, -1)
    intercepting = false
  end
end

local function interceptKeys()
  if not intercepting then
    helper.VKeys_Intercept(-1, 1)
    intercepting = true
  end
end

local currentPbRow  -- forward declaration for PB key mappings

local function setup()
  overlapTestFailed = false

  if not ImGui.IsWindowFocused(ctx) then
    releaseKeys()
    currentRow = nil
    currentPbRow = nil
    return
  end

  if intercepting then
    local vKeys = helper.VKeys_GetState(10)
    local found

    if vKeys == prevKeys then return end

    prevKeys = vKeys

    if vKeys:byte(keys.vKeys.VK_ESCAPE) ~= 0 then
      found = keys.vKeys.VK_ESCAPE
    elseif vKeys:byte(keys.vKeys.VK_SPACE) ~= 0 then
      found = keys.vKeys.VK_SPACE
    -- elseif vKeys:byte(keys.vKeys.VK_DELETE) ~= 0 then
    --   found = keys.vKeys.VK_DELETE
    elseif vKeys:byte(keys.vKeys.VK_BACK) ~= 0 then
      found = keys.vKeys.VK_DELETE -- deliberate, don't distinguish between del and bk  sp
    else
      for i = keys.vKeys.VK_LEFT, keys.vKeys.VK_DOWN do
        if vKeys:byte(i) ~= 0 then
          found = i
          break
        end
      end
      for i = keys.vKeys.VK_0, keys.vKeys.VK_Z do
        if vKeys:byte(i) ~= 0 then
          found = i
          break
        end
      end
      for i = keys.vKeys.VK_NUMPAD0, keys.vKeys.VK_F24 do
        if vKeys:byte(i) ~= 0 and i ~= keys.vKeys.VK_SEPARATOR then
          found = i
          break
        end
      end

      -- these are inconsistent on macos, not supporting
      -- if is_macos then
      --   local special = { keys.vKeys.VK_OEM_1, keys.vKeys.VK_OEM_PLUS, keys.vKeys.VK_OEM_MINUS,
      --                     keys.vKeys.VK_OEM_COMMA, keys.vKeys.VK_OEM_PERIOD, keys.vKeys.VK_OEM_2,
      --                     keys.vKeys.VK_OEM_3, keys.vKeys.VK_OEM_4, keys.vKeys.VK_OEM_5,
      --                     keys.vKeys.VK_OEM_6, keys.vKeys.VK_OEM_7 }
      --   for i = 1, #special do
      --     if vKeys:byte(special[i]) ~= 0 then
      --       found = i
      --       break
      --     end
      --   end
      -- else
      --   for i = keys.vKeys.VK_OEM_1, keys.vKeys.VK_OEM_7 do
      --     if vKeys:byte(i) ~= 0 then
      --       found = i
      --       break
      --     end
      --   end
      -- end
    end

    if found then
      for k, v in pairs(keys.vKeyLookup) do
        if found == v then
          if currentRow then
            keyMappings[currentRow].baseKey = k
            local jsMouse = r.JS_Mouse_GetState(0x3C)
            local mouseState = 0 | (jsMouse & 0x08 ~= 0 and 1 or 0) | (jsMouse & 0x04 ~= 0 and 2 or 0) | (jsMouse & 0x10 ~= 0 and 4 or 0) | (jsMouse & 0x20 ~= 0 and 8 or 0)
            keyMappings[currentRow].modifiers = mouseState
            currentRow = nil
          elseif currentPbRow then
            pbKeyMappings[currentPbRow].baseKey = k
            currentPbRow = nil
          end
          releaseKeys()
          break
        end
      end
    -- else
    --   for i = 1, #vKeys do
    --     if vKeys:byte(i) ~= 0 then r.ShowConsoleMsg(i .. '\n') end
    --   end
    end
  end
end

local function makeKeyRowTable(id, source, isDupe)
  if not source.modifiers then source.modifiers = 0 end

  local rv, v

  ImGui.TableNextRow(ctx)

  if isDupe then
    local col
    col = ImGui.GetColor(ctx, ImGui.Col_TableRowBg)
    ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, col + 0xBB0000BB)
  end
  if id == currentRow then
    local col
    col = ImGui.GetColor(ctx, ImGui.Col_TableRowBg)
    ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, col + 0x00BBBBBB)
  end

  ImGui.TableNextColumn(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, source.name)

  ImGui.TableNextColumn(ctx)
  rv, v = ImGui.Checkbox(ctx, '##' .. ctrlName .. '_key_' .. id, (source.modifiers & 0x02 ~= 0))
  if rv then
    if v then source.modifiers = source.modifiers | 0x02
    else source.modifiers = source.modifiers & ~0x02
    end
  end

  ImGui.TableNextColumn(ctx)
  rv, v = ImGui.Checkbox(ctx, '##' .. shiftName .. '_key_' .. id, (source.modifiers & 0x01 ~= 0))
  if rv then
    if v then source.modifiers = source.modifiers | 0x01
    else source.modifiers = source.modifiers & ~0x01
    end
  end

  ImGui.TableNextColumn(ctx)
  rv, v = ImGui.Checkbox(ctx, '##' .. altName .. '_key_' .. id, (source.modifiers & 0x04 ~= 0))
  if rv then
    if v then source.modifiers = source.modifiers | 0x04
    else source.modifiers = source.modifiers & ~0x04
    end
  end

  ImGui.TableNextColumn(ctx)
  rv, v = ImGui.Checkbox(ctx, '##' .. superName .. '_key_' .. id, (source.modifiers & 0x08 ~= 0))
  if rv then
    if v then source.modifiers = source.modifiers | 0x08
    else source.modifiers = source.modifiers & ~0x08
    end
  end

  ImGui.TableNextColumn(ctx)
  rv = ImGui.Button(ctx, (intercepting and currentRow == id) and ('Waiting...##' .. id) or (source.baseKey .. '##' .. id), 100)
  if rv then
    intercepting = (not intercepting or id ~= currentRow) and true or false
    if intercepting then
      interceptKeys()
      currentRow = id
      currentPbRow = nil  -- clear PB row selection
    else
      releaseKeys()
      currentRow = nil
    end
  end
end

local function makeModRowTable(id, source, isDupe)

  ImGui.TableNextRow(ctx)

  if isDupe then
    local col
    col = ImGui.GetColor(ctx, ImGui.Col_TableRowBg)
    ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, col + 0xBB0000BB)
  end

  ImGui.TableNextColumn(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, (source.cat and '[' .. source.cat .. '] ' or '') .. source.name)
  ImGui.TableNextColumn(ctx)

  local rv
  local modKey = source.modKey
  if source.check then
    local val, v = 0, false
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + 52)
    rv, v = ImGui.Checkbox(ctx, ctrlName .. '##mod_' .. id, modKey & 2 ~= 0)
    if v then val = val | 2 end
    ImGui.SameLine(ctx)
    rv, v = ImGui.Checkbox(ctx, shiftName .. '##mod_' .. id, modKey & 1 ~= 0)
    if v then val = val | 1 end
    ImGui.SameLine(ctx)
    rv, v = ImGui.Checkbox(ctx, altName .. '##mod_' .. id, modKey & 4 ~= 0)
    if v then val = val | 4 end
    ImGui.SameLine(ctx)
    rv, v = ImGui.Checkbox(ctx, superName .. '##mod_' .. id, modKey & 8 ~= 0)
    if v then val = val | 8 end
    modKey = val
  else
    rv, modKey = ImGui.RadioButtonEx(ctx, 'off##mod_' .. id, modKey, 0)
    ImGui.SameLine(ctx)
    rv, modKey = ImGui.RadioButtonEx(ctx, ctrlName .. '##mod_' .. id, modKey, 2)
    ImGui.SameLine(ctx)
    rv, modKey = ImGui.RadioButtonEx(ctx, shiftName .. '##mod_' .. id, modKey, 1)
    ImGui.SameLine(ctx)
    rv, modKey = ImGui.RadioButtonEx(ctx, altName .. '##mod_' .. id, modKey, 4)
    ImGui.SameLine(ctx)
    rv, modKey = ImGui.RadioButtonEx(ctx, superName .. '##mod_' .. id, modKey, 8)
  end

  source.modKey = modKey
end

local function makeWidgetRowTable(id, source, isDupe)

  ImGui.TableNextRow(ctx)

  if isDupe then
    local col
    col = ImGui.GetColor(ctx, ImGui.Col_TableRowBg)
    ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, col + 0xBB0000BB)
  end

  ImGui.TableNextColumn(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, (source.cat and '[' .. source.cat .. '] ' or '') .. source.name)
  ImGui.TableNextColumn(ctx)

  local rv
  local modKey = source.modKey
  local val, v = 0, false
  rv, widgetStretchMode = ImGui.RadioButtonEx(ctx, 'default##wid_' .. id, widgetStretchMode, id)
  if widgetStretchMode == id then
    ImGui.BeginDisabled(ctx)
  end
  ImGui.SameLine(ctx)
  rv, v = ImGui.Checkbox(ctx, ctrlName .. '##wid_' .. id, modKey & 2 ~= 0)
  if v then val = val | 2 end
  ImGui.SameLine(ctx)
  rv, v = ImGui.Checkbox(ctx, shiftName .. '##wid_' .. id, modKey & 1 ~= 0)
  if v then val = val | 1 end
  ImGui.SameLine(ctx)
  rv, v = ImGui.Checkbox(ctx, altName .. '##wid_' .. id, modKey & 4 ~= 0)
  if v then val = val | 4 end
  ImGui.SameLine(ctx)
  rv, v = ImGui.Checkbox(ctx, superName .. '##wid_' .. id, modKey & 8 ~= 0)
  if v then val = val | 8 end
  if widgetStretchMode == id then
    ImGui.EndDisabled(ctx)
  end
  modKey = val
  source.modKey = modKey
end

local function prepKeysForSaving()
  local output = {}
  local defaults = keys.defaultKeyMappings
  for k, v in pairs(keyMappings) do
    if not defaults[k]
      or defaults[k].baseKey == v.baseKey
        and ((v.modifiers == 0 and not defaults[k].modifiers)
          or (v.modifiers == defaults[k].modifiers))
    then
      -- nada
    else
      output[k] = { baseKey = v.baseKey, modifiers = v.modifiers } -- drop vKey and description
    end
  end
  return output
end

local function prepPbKeysForSaving()
  local output = {}
  local defaults = keys.defaultPbKeyMappings
  for k, v in pairs(pbKeyMappings) do
    if not defaults[k]
      or defaults[k].baseKey == v.baseKey
        and ((v.modifiers == 0 and not defaults[k].modifiers)
          or (v.modifiers == defaults[k].modifiers))
    then
      -- nada
    else
      output[k] = { baseKey = v.baseKey, modifiers = v.modifiers }
    end
  end
  return output
end

local function prepModsForSaving()
  local output = {}
  local defaults = keys.defaultModMappings
  for k, v in ipairs(modMappings) do
    if defaults[k] and defaults[k].modKey == v.modKey then
    else
      output[k] = { modKey = v.modKey }
    end
  end
  return output
end

local function prepWidgetsForSaving()
  local output = {}
  local defaults = keys.defaultWidgetMappings
  for k, v in ipairs(widgetMappings) do
    if defaults[k] and defaults[k].modKey == v.modKey then
    else
      output[k] = { modKey = v.modKey }
    end
  end
  return output
end

local function handleSavedMappings()
  local state
  state = r.GetExtState(scriptID_Save, 'keyMappings')
  lastKeyState = state ~= '' and state or nil
  if state then
    state = fromExtStateString(state)
    if state then
      for k, v in pairs(state) do
        if keyMappings[k] and v.baseKey and keys.vKeyLookup[v.baseKey] then
          keyMappings[k].baseKey = v.baseKey
          keyMappings[k].modifiers = v.modifiers
        end
      end
    end
  end

  state = r.GetExtState(scriptID_Save, 'pbKeyMappings')
  lastPbKeyState = state ~= '' and state or nil
  if state then
    state = fromExtStateString(state)
    if state then
      for k, v in pairs(state) do
        if pbKeyMappings[k] and v.baseKey and keys.vKeyLookup[v.baseKey] then
          pbKeyMappings[k].baseKey = v.baseKey
          pbKeyMappings[k].modifiers = v.modifiers
        end
      end
    end
  end

  state = r.GetExtState(scriptID_Save, 'modMappings')
  lastModState = state ~= '' and state or nil
  if state then
    state = fromExtStateString(state)
    if state then
      for k, v in pairs(state) do
        if modMappings[k] and v.modKey then
          modMappings[k].modKey = v.modKey
        end
      end
    end
  end

  state = r.GetExtState(scriptID_Save, 'widgetMappings')
  lastWidgetState = state ~= '' and state or nil
  if state then
    state = fromExtStateString(state)
    if state then
      for k, v in pairs(state) do
        if widgetMappings[k] and v.modKey then
          widgetMappings[k].modKey = v.modKey
        end
      end
    end
  end

  state = r.GetExtState(scriptID_Save, 'wantsControlPoints')
  prefsWantsControlPoints = state ~= '' and tonumber(state) or 0
  if not prefsWantsControlPoints then prefsWantsControlPoints = 0 end
  wantsControlPoints = prefsWantsControlPoints

  state = r.GetExtState(scriptID_Save, 'stretchMode')
  prefsStretchMode = state ~= '' and tonumber(state) or 0
  if not prefsStretchMode then prefsStretchMode = 0 end
  stretchMode = prefsStretchMode

  state = r.GetExtState(scriptID_Save, 'widgetStretchMode')
  prefsWidgetStretchMode = state ~= '' and tonumber(state)
  prefsWidgetStretchMode = math.max(prefsWidgetStretchMode or 1, 1)
  widgetStretchMode = prefsWidgetStretchMode

  state = r.GetExtState(scriptID_Save, 'slicerDefaultTrim')
  prefsSlicerDefaultTrim = state ~= '' and tonumber(state) or 0
  if not prefsSlicerDefaultTrim then prefsSlicerDefaultTrim = 0 end
  slicerDefaultTrim = prefsSlicerDefaultTrim

  state = r.GetExtState(scriptID_Save, 'wantsFullLaneDefault')
  prefsWantsFullLaneDefault = state ~= '' and tonumber(state) or 0
  if not prefsWantsFullLaneDefault then prefsWantsFullLaneDefault = 0 end
  wantsFullLaneDefault = prefsWantsFullLaneDefault

  state = r.GetExtState(scriptID_Save, 'wantsRightButton')
  prefsWantsRightButton = state ~= '' and tonumber(state) or 0
  if not prefsWantsRightButton then prefsWantsRightButton = 0 end
  wantsRightButton = prefsWantsRightButton

  -- Pitch Bend settings
  state = r.GetExtState(scriptID_Save, 'pbMaxBendUp')
  prefsPbMaxBendUp = state ~= '' and tonumber(state) or 48
  if not prefsPbMaxBendUp then prefsPbMaxBendUp = 48 end
  pbMaxBendUp = prefsPbMaxBendUp

  state = r.GetExtState(scriptID_Save, 'pbMaxBendDown')
  prefsPbMaxBendDown = state ~= '' and tonumber(state) or 48
  if not prefsPbMaxBendDown then prefsPbMaxBendDown = 48 end
  pbMaxBendDown = prefsPbMaxBendDown

  state = r.GetExtState(scriptID_Save, 'pbSnapToSemitone')
  prefsPbSnapToSemitone = state ~= '' and tonumber(state) or 0
  if not prefsPbSnapToSemitone then prefsPbSnapToSemitone = 0 end
  pbSnapToSemitone = prefsPbSnapToSemitone

  state = r.GetExtState(scriptID_Save, 'pbShowAllNotes')
  prefsPbShowAllNotes = state ~= '' and tonumber(state) or 1
  if not prefsPbShowAllNotes then prefsPbShowAllNotes = 1 end
  pbShowAllNotes = prefsPbShowAllNotes

  state = r.GetExtState(scriptID_Save, 'pbSclDirectory')
  prefsPbSclDirectory = state ~= '' and state or '~/Documents/scl'
  pbSclDirectory = prefsPbSclDirectory

  state = r.GetExtState(scriptID_Save, 'pbDefaultTuning')
  prefsPbDefaultTuning = state ~= '' and state or ''
  pbDefaultTuning = prefsPbDefaultTuning

  -- color overrides (nil = use theme)
  state = r.GetExtState(scriptID_Save, 'pbLineColor')
  prefsPbLineColor = state ~= '' and tonumber(state) or nil
  pbLineColor = prefsPbLineColor

  state = r.GetExtState(scriptID_Save, 'pbPointColor')
  prefsPbPointColor = state ~= '' and tonumber(state) or nil
  pbPointColor = prefsPbPointColor

  state = r.GetExtState(scriptID_Save, 'pbSelectedColor')
  prefsPbSelectedColor = state ~= '' and tonumber(state) or nil
  pbSelectedColor = prefsPbSelectedColor

  state = r.GetExtState(scriptID_Save, 'pbHoveredColor')
  prefsPbHoveredColor = state ~= '' and tonumber(state) or nil
  pbHoveredColor = prefsPbHoveredColor
end

local function drawPageTabs()
  local page = 0
  if ImGui.BeginTabBar(ctx, 'Page') then
    if ImGui.BeginTabItem(ctx, 'Key Mappings') then page = 0 ImGui.EndTabItem(ctx) end
    if ImGui.BeginTabItem(ctx, 'Other Settings') then page = 1 ImGui.EndTabItem(ctx) end
    if ImGui.BeginTabItem(ctx, 'Even More Settings') then page = 2 ImGui.EndTabItem(ctx) end
    ImGui.EndTabBar(ctx)
  end
  return page
end

local function drawKeyMappings()
  ImGui.Text(ctx, 'Key Mappings')
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)
  if ImGui.BeginTable(ctx, '##keyMappings', 6, ImGui.TableFlags_RowBg, 600) then
    ImGui.TableSetupColumn(ctx, 'Description', ImGui.TableColumnFlags_WidthStretch, 300)
    ImGui.TableSetupColumn(ctx, ctrlName, ImGui.TableColumnFlags_WidthFixed | ImGui.TableColumnFlags_AngledHeader, 0)
    ImGui.TableSetupColumn(ctx, shiftName, ImGui.TableColumnFlags_WidthFixed | ImGui.TableColumnFlags_AngledHeader, 0)
    ImGui.TableSetupColumn(ctx, altName, ImGui.TableColumnFlags_WidthFixed | ImGui.TableColumnFlags_AngledHeader, 0)
    ImGui.TableSetupColumn(ctx, superName, ImGui.TableColumnFlags_WidthFixed | ImGui.TableColumnFlags_AngledHeader, 0)
    ImGui.TableSetupColumn(ctx, 'Key', ImGui.TableColumnFlags_WidthFixed, 100)

    ImGui.TableAngledHeadersRow(ctx)
    ImGui.TableHeadersRow(ctx)

    for k, v in spairs(keyMappings, function(t, a, b) return t[a].name < t[b].name end) do
      local function isDuped()
        for kk, map in pairs(keyMappings) do
          if kk ~= k then
            if map.baseKey == v.baseKey and map.modifiers == v.modifiers then return true end
          end
        end
        if v.testOverlap then
          local modKey = modMappings[keys.MODTYPE_MOVE_OVERLAP].modKey
          if v.modifiers ~= 0 and v.modifiers == modKey then
            overlapTestFailed = true
            return true
          end
        end
        return false
      end
      makeKeyRowTable(k, v, isDuped())
    end
    ImGui.EndTable(ctx)
  end
end

local function drawModMappings()
  ImGui.Text(ctx, 'Modifier Mappings')

  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  if ImGui.BeginTable(ctx, '##modMappings', 2, ImGui.TableFlags_RowBg, 600) then
    ImGui.TableSetupColumn(ctx, 'Description', ImGui.TableColumnFlags_WidthStretch, 300)
    ImGui.TableSetupColumn(ctx, 'ModKey', ImGui.TableColumnFlags_WidthFixed, 0)

    ImGui.TableHeadersRow(ctx)
    for k, v in spairs(modMappings, function(t, a, b)
        if t[a].check then return false
        elseif t[b].check then return true
        elseif not t[a].cat and t[b].cat then return true
        elseif not t[b].cat and t[a].cat then return false
        else
          if t[a].cat ~= t[b].cat then return t[a].cat < t[b].cat
          else return t[a].name < t[b].name
          end
        end
      end)
    do
      local function isDuped()
        if k == keys.MODTYPE_MOVE_OVERLAP and overlapTestFailed then
          return true
        end
        for kk, mod in ipairs(modMappings) do
          if kk ~= k then
            if mod.modKey ~= 0 and mod.modKey == v.modKey
              and (not mod.cat or not v.cat or mod.cat == v.cat)
            then
              return true
            end
          end
        end
        return false
      end
      makeModRowTable(k, v, isDuped())
    end
    ImGui.EndTable(ctx)
  end
end

local function drawWidgetMappings()
  ImGui.Text(ctx, 'Widget Mode Mappings')

  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  if ImGui.BeginTable(ctx, '##widgetMappings', 2, ImGui.TableFlags_RowBg, 600) then
    ImGui.TableSetupColumn(ctx, 'Description', ImGui.TableColumnFlags_WidthStretch, 300)
    ImGui.TableSetupColumn(ctx, 'ModKey', ImGui.TableColumnFlags_WidthFixed, 0)

    ImGui.TableHeadersRow(ctx)
    for k, v in ipairs(widgetMappings) do
      local function isDuped()
        for kk, mod in ipairs(widgetMappings) do
          if kk ~= k then
            if mod.modKey == v.modKey then
              return true
            end
          end
        end
        return false
      end
      makeWidgetRowTable(k, v, isDuped())
    end
    ImGui.EndTable(ctx)
  end
end

local wantsQuit = false

local function hasChanges() -- could throttle this if it's a performance concern
  if wantsFullLaneDefault ~= prefsWantsFullLaneDefault then return true end
  if wantsRightButton ~= prefsWantsRightButton then return true end
  if slicerDefaultTrim ~= prefsSlicerDefaultTrim then return true end
  if wantsControlPoints ~= prefsWantsControlPoints then return true end
  if stretchMode ~= prefsStretchMode then return true end
  if widgetStretchMode ~= prefsWidgetStretchMode then return true end
  if pbMaxBendUp ~= prefsPbMaxBendUp then return true end
  if pbMaxBendDown ~= prefsPbMaxBendDown then return true end
  if pbSnapToSemitone ~= prefsPbSnapToSemitone then return true end
  if pbShowAllNotes ~= prefsPbShowAllNotes then return true end
  if pbSclDirectory ~= prefsPbSclDirectory then return true end
  if pbDefaultTuning ~= prefsPbDefaultTuning then return true end
  if pbLineColor ~= prefsPbLineColor then return true end
  if pbPointColor ~= prefsPbPointColor then return true end
  if pbSelectedColor ~= prefsPbSelectedColor then return true end
  if pbHoveredColor ~= prefsPbHoveredColor then return true end
  if lastKeyState ~= toExtStateString(prepKeysForSaving()) then return true end
  if lastPbKeyState ~= toExtStateString(prepPbKeysForSaving()) then return true end
  if lastModState ~= toExtStateString(prepModsForSaving()) then return true end
  if lastWidgetState ~= toExtStateString(prepWidgetsForSaving()) then return true end
  return false
end

-- do we notify the main script that settings changed, or wait for a restart?
local function drawButtons()
  local changed = hasChanges()
  if not changed then
    ImGui.BeginDisabled(ctx)
  end
  if ImGui.Button(ctx, 'Save Changes') then
    -- KEY mappings
    local extStateStr = toExtStateString(prepKeysForSaving())
    if extStateStr then
      r.SetExtState(scriptID_Save, 'keyMappings', extStateStr, true)
      lastKeyState = extStateStr
    else
      r.DeleteExtState(scriptID_Save, 'keyMappings', true)
      lastKeyState = nil
    end

    -- PB KEY mappings
    extStateStr = toExtStateString(prepPbKeysForSaving())
    if extStateStr then
      r.SetExtState(scriptID_Save, 'pbKeyMappings', extStateStr, true)
      lastPbKeyState = extStateStr
    else
      r.DeleteExtState(scriptID_Save, 'pbKeyMappings', true)
      lastPbKeyState = nil
    end

    -- MOD mappings
    extStateStr = toExtStateString(prepModsForSaving())
    if extStateStr then
      r.SetExtState(scriptID_Save, 'modMappings', extStateStr, true)
      lastModState = extStateStr
    else
      r.DeleteExtState(scriptID_Save, 'modMappings', true)
      lastModState = nil
    end

    -- WIDGET mappings
    extStateStr = toExtStateString(prepWidgetsForSaving())
    if extStateStr then
      r.SetExtState(scriptID_Save, 'widgetMappings', extStateStr, true)
      lastWidgetState = extStateStr
    else
      r.DeleteExtState(scriptID_Save, 'widgetMappings', true)
      lastWidgetState = nil
    end

    if wantsControlPoints ~= 0 then
      r.SetExtState(scriptID_Save, 'wantsControlPoints', tostring(stretchMode), true)
    else
      r.DeleteExtState(scriptID_Save, 'wantsControlPoints', true)
    end
    prefsWantsControlPoints = wantsControlPoints

    -- stretch mode
    if stretchMode ~= 0 then
      r.SetExtState(scriptID_Save, 'stretchMode', tostring(stretchMode), true)
    else
      r.DeleteExtState(scriptID_Save, 'stretchMode', true)
    end
    prefsStretchMode = stretchMode

    -- widget stretch mode
    if widgetStretchMode ~= 1 then
      r.SetExtState(scriptID_Save, 'widgetStretchMode', tostring(widgetStretchMode), true)
    else
      r.DeleteExtState(scriptID_Save, 'widgetStretchMode', true)
    end
    prefsWidgetStretchMode = widgetStretchMode

    if slicerDefaultTrim ~= 0 then
      r.SetExtState(scriptID_Save, 'slicerDefaultTrim', tostring(slicerDefaultTrim), true)
    else
      r.DeleteExtState(scriptID_Save, 'slicerDefaultTrim', true)
    end
    prefsSlicerDefaultTrim = slicerDefaultTrim

    if wantsFullLaneDefault ~= 0 then
      r.SetExtState(scriptID_Save, 'wantsFullLaneDefault', tostring(wantsFullLaneDefault), true)
    else
      r.DeleteExtState(scriptID_Save, 'wantsFullLaneDefault', true)
    end
    prefsWantsFullLaneDefault = wantsFullLaneDefault

    if wantsRightButton ~= 0 then
      r.SetExtState(scriptID_Save, 'wantsRightButton', tostring(wantsRightButton), true)
    else
      r.DeleteExtState(scriptID_Save, 'wantsRightButton', true)
    end
    prefsWantsRightButton = wantsRightButton

    -- Pitch Bend settings
    if pbMaxBendUp ~= 48 then
      r.SetExtState(scriptID_Save, 'pbMaxBendUp', tostring(pbMaxBendUp), true)
    else
      r.DeleteExtState(scriptID_Save, 'pbMaxBendUp', true)
    end
    prefsPbMaxBendUp = pbMaxBendUp

    if pbMaxBendDown ~= 48 then
      r.SetExtState(scriptID_Save, 'pbMaxBendDown', tostring(pbMaxBendDown), true)
    else
      r.DeleteExtState(scriptID_Save, 'pbMaxBendDown', true)
    end
    prefsPbMaxBendDown = pbMaxBendDown

    if pbSnapToSemitone ~= 0 then
      r.SetExtState(scriptID_Save, 'pbSnapToSemitone', tostring(pbSnapToSemitone), true)
    else
      r.DeleteExtState(scriptID_Save, 'pbSnapToSemitone', true)
    end
    prefsPbSnapToSemitone = pbSnapToSemitone

    if pbShowAllNotes ~= 1 then
      r.SetExtState(scriptID_Save, 'pbShowAllNotes', tostring(pbShowAllNotes), true)
    else
      r.DeleteExtState(scriptID_Save, 'pbShowAllNotes', true)
    end
    prefsPbShowAllNotes = pbShowAllNotes

    if pbSclDirectory ~= '~/Documents/scl' then
      r.SetExtState(scriptID_Save, 'pbSclDirectory', pbSclDirectory, true)
    else
      r.DeleteExtState(scriptID_Save, 'pbSclDirectory', true)
    end
    prefsPbSclDirectory = pbSclDirectory

    if pbDefaultTuning ~= '' then
      r.SetExtState(scriptID_Save, 'pbDefaultTuning', pbDefaultTuning, true)
    else
      r.DeleteExtState(scriptID_Save, 'pbDefaultTuning', true)
    end
    prefsPbDefaultTuning = pbDefaultTuning

    -- color overrides
    if pbLineColor then
      r.SetExtState(scriptID_Save, 'pbLineColor', tostring(pbLineColor), true)
    else
      r.DeleteExtState(scriptID_Save, 'pbLineColor', true)
    end
    prefsPbLineColor = pbLineColor

    if pbPointColor then
      r.SetExtState(scriptID_Save, 'pbPointColor', tostring(pbPointColor), true)
    else
      r.DeleteExtState(scriptID_Save, 'pbPointColor', true)
    end
    prefsPbPointColor = pbPointColor

    if pbSelectedColor then
      r.SetExtState(scriptID_Save, 'pbSelectedColor', tostring(pbSelectedColor), true)
    else
      r.DeleteExtState(scriptID_Save, 'pbSelectedColor', true)
    end
    prefsPbSelectedColor = pbSelectedColor

    if pbHoveredColor then
      r.SetExtState(scriptID_Save, 'pbHoveredColor', tostring(pbHoveredColor), true)
    else
      r.DeleteExtState(scriptID_Save, 'pbHoveredColor', true)
    end
    prefsPbHoveredColor = pbHoveredColor

    -- NOTIFY
    r.SetExtState(scriptID_Save, 'settingsUpdated', 'ping', false)
  end
  if not changed then
    ImGui.EndDisabled(ctx)
  end

  ImGui.SameLine(ctx)

  if ImGui.Button(ctx, changed and 'Cancel & Quit' or 'Quit') then
    wantsQuit = true
  end

  ImGui.SameLine(ctx)
  local contentMaxX = ImGui.GetWindowContentRegionMax(ctx)
  ImGui.SetCursorPosX(ctx, contentMaxX - 200)
  if ImGui.Button(ctx, 'Revert to Defaults', 200) then
    wantsControlPoints = false
    slicerDefaultTrim = false
    wantsFullLaneDefault = false
    wantsRightButton = false
    stretchMode = 0
    widgetStretchMode = 1
    pbMaxBendUp = 48
    pbMaxBendDown = 48
    pbSnapToSemitone = 0
    pbShowAllNotes = 1
    pbSclDirectory = '~/Documents/scl'
    pbDefaultTuning = ''
    pbLineColor = nil
    pbPointColor = nil
    pbSelectedColor = nil
    pbHoveredColor = nil
    keyMappings = tableCopySimpleKeys(keys.defaultKeyMappings)
    pbKeyMappings = tableCopySimpleKeys(keys.defaultPbKeyMappings)
    modMappings = tableCopySimpleKeys(keys.defaultModMappings)
    widgetMappings = tableCopySimpleKeys(keys.defaultWidgetMappings)
  end
end

-- scan pbSclDirectory for .scl files
local function scanSclFiles()
  pbSclFiles = {}
  if not pbSclDirectory or pbSclDirectory == '' then return end

  local dir = pbSclDirectory
  -- expand ~ to home directory
  if dir:sub(1, 1) == '~' then
    local home = os.getenv('HOME') or os.getenv('USERPROFILE') or ''
    dir = home .. dir:sub(2)
  end

  local idx = 0
  while true do
    local file = r.EnumerateFiles(dir, idx)
    if not file then break end
    if file:lower():match('%.scl$') then
      table.insert(pbSclFiles, file)
    end
    idx = idx + 1
  end
  table.sort(pbSclFiles)
end

local function makePbKeyRowTable(id, source, isDupe)
  if not source.modifiers then source.modifiers = 0 end

  local rv

  ImGui.TableNextRow(ctx)

  if isDupe then
    local col = ImGui.GetColor(ctx, ImGui.Col_TableRowBg)
    ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, col + 0xBB0000BB)
  end
  if id == currentPbRow then
    local col = ImGui.GetColor(ctx, ImGui.Col_TableRowBg)
    ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, col + 0x00BBBBBB)
  end

  ImGui.TableNextColumn(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, source.name)

  ImGui.TableNextColumn(ctx)
  rv = ImGui.Button(ctx, (intercepting and currentPbRow == id) and ('Waiting...##pb_' .. id) or (source.baseKey .. '##pb_' .. id), 100)
  if rv then
    intercepting = (not intercepting or id ~= currentPbRow) and true or false
    if intercepting then
      interceptKeys()
      currentPbRow = id
      currentRow = nil  -- clear main row selection
    else
      releaseKeys()
      currentPbRow = nil
    end
  end
end

local function drawPbKeyMappings()
  ImGui.Text(ctx, 'Pitch Bend Mode Key Mappings')
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)
  if ImGui.BeginTable(ctx, '##pbKeyMappings', 2, ImGui.TableFlags_RowBg, 400) then
    ImGui.TableSetupColumn(ctx, 'Description', ImGui.TableColumnFlags_WidthStretch, 250)
    ImGui.TableSetupColumn(ctx, 'Key', ImGui.TableColumnFlags_WidthFixed, 100)

    ImGui.TableHeadersRow(ctx)

    for k, v in spairs(pbKeyMappings, function(t, a, b) return t[a].name < t[b].name end) do
      if not v.hidden then
        local function isDuped()
          for kk, map in pairs(pbKeyMappings) do
            if kk ~= k and not map.hidden then
              if map.baseKey == v.baseKey then return true end
            end
          end
          return false
        end
        makePbKeyRowTable(k, v, isDuped())
      end
    end
    ImGui.EndTable(ctx)
  end
end

local function drawPitchBendOptions()
  ImGui.Text(ctx, 'Pitch Bend Mode Settings')
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  local rv

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Max Pitch Bend Up (semitones):')
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, 280)
  ImGui.SetNextItemWidth(ctx, 100)
  rv, pbMaxBendUp = ImGui.InputInt(ctx, '##pbMaxBendUp', pbMaxBendUp, 1, 12)
  if pbMaxBendUp < 1 then pbMaxBendUp = 1 end
  if pbMaxBendUp > 96 then pbMaxBendUp = 96 end

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Max Pitch Bend Down (semitones):')
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, 280)
  ImGui.SetNextItemWidth(ctx, 100)
  rv, pbMaxBendDown = ImGui.InputInt(ctx, '##pbMaxBendDown', pbMaxBendDown, 1, 12)
  if pbMaxBendDown < 1 then pbMaxBendDown = 1 end
  if pbMaxBendDown > 96 then pbMaxBendDown = 96 end

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Snap to Semitone by Default:')
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, 280)
  local snap = pbSnapToSemitone == 1
  rv, snap = ImGui.Checkbox(ctx, '##pbSnapToSemitone', snap)
  pbSnapToSemitone = snap and 1 or 0

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Display Filter:')
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, 280)
  rv, pbShowAllNotes = ImGui.RadioButtonEx(ctx, 'All Notes##pbFilter', pbShowAllNotes, 1)
  ImGui.SameLine(ctx)
  rv, pbShowAllNotes = ImGui.RadioButtonEx(ctx, 'Active Channel##pbFilter', pbShowAllNotes, 0)

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Scale (.scl) Directory:')
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, 280)
  ImGui.SetNextItemWidth(ctx, 250)
  local dirChanged
  dirChanged, pbSclDirectory = ImGui.InputText(ctx, '##pbSclDirectory', pbSclDirectory)
  if dirChanged then scanSclFiles() end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Browse...##pbSclBrowse') then
    local ok, path = r.JS_Dialog_BrowseForFolder('Select .scl directory', pbSclDirectory)
    if ok == 1 and path then
      pbSclDirectory = path
      scanSclFiles()
    end
  end

  -- default tuning combo
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Default Tuning:')
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, 280)
  ImGui.SetNextItemWidth(ctx, 250)
  if ImGui.BeginCombo(ctx, '##pbDefaultTuning', pbDefaultTuning == '' and 'Equal Temperament (12-TET)' or pbDefaultTuning) then
    if ImGui.Selectable(ctx, 'Equal Temperament (12-TET)', pbDefaultTuning == '') then
      pbDefaultTuning = ''
    end
    local fileCount = #pbSclFiles
    if fileCount <= 50 then
      for _, file in ipairs(pbSclFiles) do
        if ImGui.Selectable(ctx, file, pbDefaultTuning == file) then
          pbDefaultTuning = file
        end
      end
    else
      -- group by first character (0-9, A, B, C...)
      local groups = {}
      for _, f in ipairs(pbSclFiles) do
        local firstChar = f:sub(1, 1):upper()
        if firstChar:match('%d') then firstChar = '0-9' end
        if not groups[firstChar] then groups[firstChar] = {} end
        table.insert(groups[firstChar], f)
      end
      -- sort group keys
      local sortedKeys = {}
      for k in pairs(groups) do table.insert(sortedKeys, k) end
      table.sort(sortedKeys)
      -- build submenus
      for _, key in ipairs(sortedKeys) do
        local groupFiles = groups[key]
        if ImGui.BeginMenu(ctx, key .. ' (' .. #groupFiles .. ')') then
          for _, file in ipairs(groupFiles) do
            if ImGui.Selectable(ctx, file, pbDefaultTuning == file) then
              pbDefaultTuning = file
            end
          end
          ImGui.EndMenu(ctx)
        end
      end
    end
    ImGui.EndCombo(ctx)
  end

  -- Color overrides
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)
  ImGui.Text(ctx, 'Color Overrides (uncheck to use theme):')
  ImGui.Spacing(ctx)

  -- convert ARGB (storage/LICE) to RGBA (ReaImGui)
  local function argbToRgba(argb)
    if not argb then return nil end
    local a = (argb >> 24) & 0xFF
    local r = (argb >> 16) & 0xFF
    local g = (argb >> 8) & 0xFF
    local b = argb & 0xFF
    return (r << 24) | (g << 16) | (b << 8) | a
  end

  -- convert RGBA (ReaImGui) to ARGB (storage/LICE)
  local function rgbaToArgb(rgba)
    if not rgba then return nil end
    local r = (rgba >> 24) & 0xFF
    local g = (rgba >> 16) & 0xFF
    local b = (rgba >> 8) & 0xFF
    local a = rgba & 0xFF
    return (a << 24) | (r << 16) | (g << 8) | b
  end

  local rv, col, enabled
  local colorX = 32  -- fixed X position for color squares

  -- Line color (default orange)
  ImGui.AlignTextToFramePadding(ctx)
  enabled = pbLineColor ~= nil
  rv, enabled = ImGui.Checkbox(ctx, '##lineColorEnabled', enabled)
  if rv then
    if enabled then pbLineColor = 0xFFFF8800 else pbLineColor = nil end
  end
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, colorX)
  if not enabled then ImGui.BeginDisabled(ctx) end
  col = argbToRgba(pbLineColor) or 0xFF8800FF  -- orange in RGBA (default)
  rv, col = ImGui.ColorEdit4(ctx, 'Curve Line##lineColor', col, ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_AlphaBar)
  if rv and enabled then pbLineColor = rgbaToArgb(col) end
  if not enabled then ImGui.EndDisabled(ctx) end

  -- Point color (unselected, default blue)
  ImGui.AlignTextToFramePadding(ctx)
  enabled = pbPointColor ~= nil
  rv, enabled = ImGui.Checkbox(ctx, '##pointColorEnabled', enabled)
  if rv then
    if enabled then pbPointColor = 0xFF0088FF else pbPointColor = nil end
  end
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, colorX)
  if not enabled then ImGui.BeginDisabled(ctx) end
  col = argbToRgba(pbPointColor) or 0x0088FFFF  -- blue in RGBA (default)
  rv, col = ImGui.ColorEdit4(ctx, 'Point (unselected)##pointColor', col, ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_AlphaBar)
  if rv and enabled then pbPointColor = rgbaToArgb(col) end
  if not enabled then ImGui.EndDisabled(ctx) end

  -- Selected color (default red)
  ImGui.AlignTextToFramePadding(ctx)
  enabled = pbSelectedColor ~= nil
  rv, enabled = ImGui.Checkbox(ctx, '##selectedColorEnabled', enabled)
  if rv then
    if enabled then pbSelectedColor = 0xFFFF0000 else pbSelectedColor = nil end
  end
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, colorX)
  if not enabled then ImGui.BeginDisabled(ctx) end
  col = argbToRgba(pbSelectedColor) or 0xFF0000FF  -- red in RGBA (default)
  rv, col = ImGui.ColorEdit4(ctx, 'Point (selected)##selectedColor', col, ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_AlphaBar)
  if rv and enabled then pbSelectedColor = rgbaToArgb(col) end
  if not enabled then ImGui.EndDisabled(ctx) end

  -- Hovered color (default yellow)
  ImGui.AlignTextToFramePadding(ctx)
  enabled = pbHoveredColor ~= nil
  rv, enabled = ImGui.Checkbox(ctx, '##hoveredColorEnabled', enabled)
  if rv then
    if enabled then pbHoveredColor = 0xFFFFFF00 else pbHoveredColor = nil end
  end
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, colorX)
  if not enabled then ImGui.BeginDisabled(ctx) end
  col = argbToRgba(pbHoveredColor) or 0xFFFF00FF  -- yellow in RGBA (default)
  rv, col = ImGui.ColorEdit4(ctx, 'Point (hovered)##hoveredColor', col, ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_AlphaBar)
  if rv and enabled then pbHoveredColor = rgbaToArgb(col) end
  if not enabled then ImGui.EndDisabled(ctx) end

  ImGui.Spacing(ctx)
end

local function drawMiscOptions()
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Add Control Points (CC):')
  local rv
  local cp = wantsControlPoints
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + 20)
  local saveX = ImGui.GetCursorPosX(ctx)
  rv, cp = ImGui.Checkbox(ctx, '##wantsControlPoints', cp == 1 and true or false)
  wantsControlPoints = cp and 1 or 0

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Value Stretch Mode (Area):')
  local sm = stretchMode
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, saveX)
  rv, sm = ImGui.RadioButtonEx(ctx, 'Compress/Expand##sm', sm, 0)
  ImGui.SameLine(ctx)
  rv, sm = ImGui.RadioButtonEx(ctx, 'Offset##sm', sm, 1)
  stretchMode = sm

  -- ImGui.AlignTextToFramePadding(ctx)
  -- ImGui.Text(ctx, 'Value Stretch Mode (Widget):')
  -- local wsm = widgetStretchMode
  -- ImGui.SameLine(ctx)
  -- ImGui.SetCursorPosX(ctx, saveX)
  -- rv, wsm = ImGui.RadioButtonEx(ctx, 'Push Up/Down##wsm', wsm, 0)
  -- ImGui.SameLine(ctx)
  -- rv, wsm = ImGui.RadioButtonEx(ctx, 'Offset##wsm', wsm, 1)
  -- ImGui.SameLine(ctx)
  -- rv, wsm = ImGui.RadioButtonEx(ctx, 'Comp/Exp Mid##wsm', wsm, 2)
  -- ImGui.SameLine(ctx)
  -- rv, wsm = ImGui.RadioButtonEx(ctx, 'Comp/Exp##wsm', wsm, 3)
  -- widgetStretchMode = wsm

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Full-Lane Note Selection By Default:')
  local fl = wantsFullLaneDefault
  ImGui.SameLine(ctx)
  rv, fl = ImGui.Checkbox(ctx, '##wantsFullLaneDefault', fl == 1 and true or false)
  wantsFullLaneDefault = fl and 1 or 0

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Use Right Mouse Button (experimental):')
  local rb = wantsRightButton
  ImGui.SameLine(ctx)
  -- ImGui.SetCursorPosX(ctx, saveX)
  rv, rb = ImGui.Checkbox(ctx, '##wantsRightButton', rb == 1 and true or false)
  wantsRightButton = rb and 1 or 0
end

local function drawSlicerOptions()
  ImGui.Text(ctx, 'Slicer Mode Settings')
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Slicer Trims By Default (opt/alt to split only):')
  local trim = slicerDefaultTrim
  ImGui.SameLine(ctx)
  local rv
  rv, trim = ImGui.Checkbox(ctx, '##slicerDefaultTrim', trim == 1 and true or false)
  slicerDefaultTrim = trim and 1 or 0
end

local inWindow = false

local function shutdown()
  releaseKeys()
  if inWindow then
    -- ImGui.End(ctx)
  end
end

local function onCrash(err)
  r.ShowConsoleMsg(err .. '\n' .. debug.traceback() .. '\n')
  shutdown()
end


local function loop()
  ImGui.SetNextWindowBgAlpha(ctx, 1)
  local visible, open = ImGui.Begin(ctx, 'MIDI Razor Edits (Settings)', true, ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoDocking)
  if visible then
    inWindow = true

    setup()

    local page = drawPageTabs()

    if page == 0 then

    drawKeyMappings()

    elseif page == 1 then

    drawModMappings()

    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    drawMiscOptions()

    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    drawWidgetMappings()

    else  -- page == 2

    drawSlicerOptions()

    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    drawPitchBendOptions()

    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    drawPbKeyMappings()

    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    drawButtons()

    if ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Left) then
      releaseKeys()
      currentRow = nil
      currentPbRow = nil
    end

    -- esc to quit (only if not intercepting keys)
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not intercepting then
      wantsQuit = true
    end

    ImGui.End(ctx)

    inWindow = false
  end
  if open and not wantsQuit then
    r.defer(function() xpcall(loop, onCrash) end)
  end
end

handleSavedMappings()
scanSclFiles()
reaper.defer(function() xpcall(loop, onCrash) end)
r.atexit(shutdown)
