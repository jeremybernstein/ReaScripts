--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

package.path = debug.getinfo(1, 'S').source:match [[^@?(.*[\/])[^\/]-$]] .. 'RazorEdits/?.lua;' -- GET DIRECTORY FOR REQUIRE
local keys = require 'MIDIRazorEdits_Keys'
if not keys then
  r.ShowConsoleMsg("MIDI Razor Edits (Settings) cannot find necessary files, please reinstall\n")
end

package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9.3'
if not ImGui then
  r.ShowConsoleMsg('MIDI Razor Edits (Settings) requires \'ReaImGui\' 0.9.3+ (install from ReaPack)\n')
end

local scriptID = 'sockmonkey72_MRE_Settings'
local scriptID_Save = 'sockmonkey72_MIDIRazorEdits'

local os = r.GetOS()
local is_windows = os:match('Win')
local is_macos = os:match('OS')
local is_linux = os:match('Other')

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

-- (Win/Lin: add 1 for shift, 2 for control, 4 for alt, 8 for win.)
-- (macOS: add 1 for shift, 2 for command, 4 for opt, 8 for control.)

local intercepting = false
local currentRow
local prevKeys

local keyMappings = tableCopySimpleKeys(keys.defaultKeyMappings)
local modMappings = tableCopySimpleKeys(keys.defaultModMappings)

local function releaseKeys()
  if intercepting then
    r.JS_VKeys_Intercept(-1, -1)
    intercepting = false
  end
end

local function interceptKeys()
  if not intercepting then
    r.JS_VKeys_Intercept(-1, 1)
    intercepting = true
  end
end

local function setup()
  if not ImGui.IsWindowFocused(ctx) then
    releaseKeys()
    currentRow = nil
    return
  end

  if intercepting then
    local vKeys = r.JS_VKeys_GetState(10)
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
          keyMappings[currentRow].baseKey = k
          releaseKeys()
          local jsMouse = r.JS_Mouse_GetState(0x3C)
          local mouseState = 0 | (jsMouse & 0x08 ~= 0 and 1 or 0) | (jsMouse & 0x04 ~= 0 and 2 or 0) | (jsMouse & 0x10 ~= 0 and 4 or 0) | (jsMouse & 0x20 ~= 0 and 8 or 0)
          keyMappings[currentRow].modifiers = mouseState
          currentRow = nil
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
  rv, v = ImGui.Checkbox(ctx, '##' .. ctrlName .. '_' .. id, (source.modifiers & 0x02 ~= 0))
  if rv then
    if v then source.modifiers = source.modifiers | 0x02
    else source.modifiers = source.modifiers & ~0x02
    end
  end

  ImGui.TableNextColumn(ctx)
  rv, v = ImGui.Checkbox(ctx, '##' .. shiftName .. '_' .. id, (source.modifiers & 0x01 ~= 0))
  if rv then
    if v then source.modifiers = source.modifiers | 0x01
    else source.modifiers = source.modifiers & ~0x01
    end
  end

  ImGui.TableNextColumn(ctx)
  rv, v = ImGui.Checkbox(ctx, '##' .. altName .. '_' .. id, (source.modifiers & 0x04 ~= 0))
  if rv then
    if v then source.modifiers = source.modifiers | 0x04
    else source.modifiers = source.modifiers & ~0x04
    end
  end

  ImGui.TableNextColumn(ctx)
  rv, v = ImGui.Checkbox(ctx, '##' .. superName .. '_' .. id, (source.modifiers & 0x08 ~= 0))
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
  rv, modKey = ImGui.RadioButtonEx(ctx, 'off##' .. id, modKey, 0)
  ImGui.SameLine(ctx)
  rv, modKey = ImGui.RadioButtonEx(ctx, ctrlName .. '##' .. id, modKey, 2)
  ImGui.SameLine(ctx)
  rv, modKey = ImGui.RadioButtonEx(ctx, shiftName .. '##' .. id, modKey, 1)
  ImGui.SameLine(ctx)
  rv, modKey = ImGui.RadioButtonEx(ctx, altName .. '##' .. id, modKey, 4)
  ImGui.SameLine(ctx)
  rv, modKey = ImGui.RadioButtonEx(ctx, superName .. '##' .. id, modKey, 8)

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

local lastKeyState
local lastModState
local prefsStretchMode
local stretchMode

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

  state = r.GetExtState(scriptID_Save, 'stretchMode')
  prefsStretchMode = state ~= '' and tonumber(state) or 0
  if not prefsStretchMode then prefsStretchMode = 0 end
  stretchMode = prefsStretchMode
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
        if not t[a].cat then return true
        elseif not t[b].cat then return false
        else
          if t[a].cat ~= t[b].cat then return t[a].cat < t[b].cat
          else return t[a].name < t[b].name
          end
        end
      end)
    do
      local function isDuped()
        for kk, mod in ipairs(modMappings) do
          if kk ~= k then
            if mod.modKey == v.modKey and (not mod.cat or not v.cat or mod.cat == v.cat) then return true end
          end
        end
        return false
      end
      makeModRowTable(k, v, isDuped())
    end
    ImGui.EndTable(ctx)
  end
end

local wantsQuit = false

local function hasChanges() -- could throttle this if it's a performance concern
  if stretchMode ~= prefsStretchMode then return true end
  if lastKeyState ~= toExtStateString(prepKeysForSaving()) then return true end
  if lastModState ~= toExtStateString(prepModsForSaving()) then return true end
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

    -- MOD mappings
    extStateStr = toExtStateString(prepModsForSaving())
    if extStateStr then
      r.SetExtState(scriptID_Save, 'modMappings', extStateStr, true)
      lastModState = extStateStr
    else
      r.DeleteExtState(scriptID_Save, 'modMappings', true)
      lastModState = nil
    end

    -- stretch mode
    if stretchMode ~= 0 then
      r.SetExtState(scriptID_Save, 'stretchMode', tostring(stretchMode), true)
    else
      r.DeleteExtState(scriptID_Save, 'stretchMode', true)
    end
    prefsStretchMode = stretchMode

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
    keyMappings = tableCopySimpleKeys(keys.defaultKeyMappings)
    modMappings = tableCopySimpleKeys(keys.defaultModMappings)
  end
end

local function drawMiscOptions()
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Value Stretch Mode:')
  local rv
  local sm = stretchMode
  ImGui.SameLine(ctx)
  rv, sm = ImGui.RadioButtonEx(ctx, 'Compress/Expand', sm, 0)
  ImGui.SameLine(ctx)
  rv, sm = ImGui.RadioButtonEx(ctx, 'Offset', sm, 1)
  stretchMode = sm
end

local inWindow = false

local function shutdown()
  releaseKeys()
  if inWindow then
    ImGui.End(ctx)
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

    drawKeyMappings()

    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    drawModMappings()

    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)


    drawMiscOptions()

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    drawButtons()

    if ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Left) then
      releaseKeys()
      currentRow = nil
    end

    ImGui.End(ctx)

    inWindow = false
  end
  if open and not wantsQuit then
    r.defer(function() xpcall(loop, onCrash) end)
  end
end

handleSavedMappings()
reaper.defer(function() xpcall(loop, onCrash) end)
r.atexit(shutdown)
