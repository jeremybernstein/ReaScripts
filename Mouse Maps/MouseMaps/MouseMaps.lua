--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

local MouseMaps = {}
local SectionName = 'sockmonkey72_MouseMaps'
local CommonName = 'commonInitState'

-- known context as of 7. Jan 2023
local contexts = {
  MM_CTX_AREASEL = 'Razor edit area (left click)',
  MM_CTX_AREASEL_CLK = 'Razor edit area (left click)',
  MM_CTX_AREASEL_EDGE = 'Razor edit edge (left click)',
  MM_CTX_AREASEL_ENV = 'Razor edit envelope area (left click)',
  MM_CTX_ARRANGE_MMOUSE = 'Arrange view (middle drag)',
  MM_CTX_ARRANGE_MMOUSE_CLK = 'Arrange view (middle click)',
  MM_CTX_ARRANGE_RMOUSE = 'Arrange view (right drag)',
  MM_CTX_CROSSFADE = 'Media item fade intersection (left click)',
  MM_CTX_CROSSFADE_CLK = 'Media item fade intersection (left click)',
  MM_CTX_CROSSFADE_DBLCLK = 'Media item fade intersection (double click)',
  MM_CTX_CURSORHANDLE = 'Edit cursor handle (left click)',
  MM_CTX_ENVCP_DBLCLK = 'Envelope control panel (double click)',
  MM_CTX_ENVLANE = 'Envelope lane (left click)',
  MM_CTX_ENVLANE_DBLCLK = 'Envelope lane (double click)',
  MM_CTX_ENVPT = 'Envelope point (left click)',
  MM_CTX_ENVPT_DBLCLK = 'Envelope point (double click)',
  MM_CTX_ENVSEG = 'Envelope segment (left click)',
  MM_CTX_ENVSEG_DBLCLK = 'Envelope segment (double click)',
  MM_CTX_FIXEDLANETAB_CLK = 'Fixed lane header button (left click)',
  MM_CTX_ITEM = 'Media item (left click)',
  MM_CTX_ITEMEDGE = 'Media item edge (left click)',
  MM_CTX_ITEMEDGE_DBLCLK = 'Media item edge (double click)',
  MM_CTX_ITEMFADE = 'Media item fade/autocrossfade (left click)',
  MM_CTX_ITEMFADE_CLK = 'Media item fade/autocrossfade (left click)',
  MM_CTX_ITEMFADE_DBLCLK = 'Media item fade/autocrossfade (double click)',
  MM_CTX_ITEMLOWER = 'Media item bottom half (left click)',
  MM_CTX_ITEMLOWER_CLK = 'Media item bottom half (left click)',
  MM_CTX_ITEMLOWER_DBLCLK = 'Media item bottom half (double click)',
  MM_CTX_ITEMSTRETCHMARKER = 'Media item stretch marker (left click)',
  MM_CTX_ITEMSTRETCHMARKERRATE = 'Media item stretch marker rate (left click)',
  MM_CTX_ITEMSTRETCHMARKER_DBLCLK = 'Media item stretch marker (double click)',
  MM_CTX_ITEM_CLK = 'Media item (left click)',
  MM_CTX_ITEM_DBLCLK = 'Media item (double click)',
  MM_CTX_MARKERLANES = 'Project marker/region lane (left click)',
  MM_CTX_MARKER_REGIONEDGE = 'Project marker/region edge (left click)',
  MM_CTX_MCP_DBLCLK = 'Mixer control panel (double click)',
  MM_CTX_MIDI_CCEVT = 'MIDI CC event (left click/drag)',
  MM_CTX_MIDI_CCEVT_DBLCLK = 'MIDI CC event (double click)',
  MM_CTX_MIDI_CCLANE = 'MIDI CC lane (left click/drag)',
  MM_CTX_MIDI_CCLANE_DBLCLK = 'MIDI CC lane (double click)',
  MM_CTX_MIDI_CCSEG = 'MIDI CC segment (left click/drag)',
  MM_CTX_MIDI_CCSEG_DBLCLK = 'MIDI CC segment (double click)',
  MM_CTX_MIDI_ENDPTR = 'MIDI source loop end marker (left click)',
  MM_CTX_MIDI_MARKERLANES = 'MIDI marker/region lanes (left click)',
  MM_CTX_MIDI_NOTE = 'MIDI note (left click)',
  MM_CTX_MIDI_NOTEEDGE = 'MIDI note edge (left click)',
  MM_CTX_MIDI_NOTE_CLK = 'MIDI note (left click)',
  MM_CTX_MIDI_NOTE_DBLCLK = 'MIDI note (double click)',
  MM_CTX_MIDI_PIANOROLL = 'MIDI piano roll (left click)',
  MM_CTX_MIDI_PIANOROLL_CLK = 'MIDI piano roll (left click)',
  MM_CTX_MIDI_PIANOROLL_DBLCLK = 'MIDI piano roll (double click)',
  MM_CTX_MIDI_RMOUSE = 'MIDI editor (right drag)',
  MM_CTX_MIDI_RULER = 'MIDI ruler (left click)',
  MM_CTX_MIDI_RULER_CLK = 'MIDI ruler (left click)',
  MM_CTX_MIDI_RULER_DBLCLK = 'MIDI ruler (double click)',
  MM_CTX_POOLEDENV = 'Automation item (left click)',
  MM_CTX_POOLEDENVEDGE = 'Automation item edge (left click)',
  MM_CTX_POOLEDENV_DBLCLK = 'Automation item (double click)',
  MM_CTX_REGION = 'Project region (left click)',
  MM_CTX_RULER = 'Ruler (left click)',
  MM_CTX_RULER_CLK = 'Ruler (left click)',
  MM_CTX_RULER_DBLCLK = 'Ruler (double click)',
  MM_CTX_TCP_DBLCLK = 'Track control panel (double click)',
  MM_CTX_TEMPOMARKER = 'Project tempo/time signature marker (left click)',
  MM_CTX_TRACK = 'Track (left click)',
  MM_CTX_TRACK_CLK = 'Track (left click)',
}

local function post(...)
  local args = {...}
  local str = ''
  for i, v in ipairs(args) do
    str = str .. (i ~= 1 and ', ' or '') .. tostring(v)
  end
  str = str .. '\n'
  r.ShowConsoleMsg(str)
end

-- Print contents of `tbl`, with indentation.
-- `indent` sets the initial level of indentation.
local function tprint (tbl, indent)
  if not indent then indent = 0 end
  for k, v in pairs(tbl) do
    local formatting = string.rep('  ', indent) .. k .. ': '
    if type(v) == 'table' then
      post(formatting)
      tprint(v, indent+1)
    elseif type(v) == 'boolean' then
      post(formatting .. tostring(v))
    else
      post(formatting .. v)
    end
  end
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

local function ReadStateFromFile(path)
  local state = {}
  local current, currentctx
  if not r.file_exists(path) then return false end
  for line in io.lines(path) do
    local newcontext = line:match('%[(.*)%]')
    if newcontext and newcontext ~= '' then
      if newcontext == 'hasimported' then
        current = nil
        currentctx = nil
      else
        if not state[newcontext] then state[newcontext] = {} end
        currentctx = newcontext
        current = state[newcontext]
      end
    end

    if current == nil and currentctx == nil then
      -- local ctxname = line:match('(MM_CTX_%g*)%s*=')
      -- if ctxname then
      --   if not state[ctxname] then state[ctxname] = {} end
      -- end
    else
      local modflag, action = line:match('mm_(%d+)%s*=%s*(%g*)$')
      if modflag and action then
        modflag = tonumber(modflag)
        if modflag then current[modflag] = action end
      end
    end
  end
  return state
end

local function GetCurrentState()
  return ReadStateFromFile(r.GetResourcePath()..'/reaper-mouse.ini')
end

local function RestoreState(state)
  if not state then return false end
  -- set everything to -1
  for k, v in pairs(contexts) do
    for i = 0, 15 do
      r.SetMouseModifier(k, i, '-1')
    end
  end

  for k, v in pairs(state) do
    for i = 0, 15 do
      if v[i] then
        r.SetMouseModifier(k, i, v[i])
      end
    end
  end
  return true
end

local function RestoreStateFromFile(path)
  local state = ReadStateFromFile(path)
  return RestoreState(state)
end

local function PrintState(state)
  local str = ''
  for k, v in spairs(state, function(t, a, b) return a < b end ) do
    local cherry = true
    for i = 0, 15 do
      if v[i] then
      -- local action = r.GetMouseModifier(k, i)
      -- if action and action ~= '-1' then
        if cherry then
          str = str..'['..k..']\n'
          cherry = false
        end
        str = str..'mm_'..i..'='..v[i]..'\n'
      end
    end
    str = str..'\n'
  end
  return str
end

local function Deserialize(str)
  local f, err = load('return '..str)
  return f ~= nil and f() or nil
end

local function Serialize(val, name, skipnewlines, depth)
  skipnewlines = skipnewlines or false
  depth = depth or 0
  local tmp = string.rep(' ', depth)
  if name then
      if type(name) == 'number' and math.floor(name) == name then
          name = '[' .. name .. ']'
      elseif not string.match(name, '^[a-zA-z_][a-zA-Z0-9_]*$') then
          name = string.gsub(name, "'", "\\'")
          name = "['".. name .. "']"
      end
      tmp = tmp .. name .. ' = '
  end
  if type(val) == 'table' then
      tmp = tmp .. '{' .. (not skipnewlines and '\n' or '')
      for k, v in spairs(val, function(t, a, b) return a < b end) do
          tmp =  tmp .. Serialize(v, k, skipnewlines, depth + 1) .. ',' .. (not skipnewlines and '\n' or '')
      end
      tmp = tmp .. string.rep(' ', depth) .. '}'
  elseif type(val) == 'number' then
      tmp = tmp .. tostring(val)
  elseif type(val) == 'string' then
      tmp = tmp .. string.format('%q', val)
  elseif type(val) == 'boolean' then
      tmp = tmp .. (val and 'true' or 'false')
  else
      tmp = tmp .. '"[unknown datatype:' .. type(val) .. ']"'
  end
  return tmp
end

local function RestoreState_Serialized(stateStr)
  local state = Deserialize(stateStr)
  if state then
    RestoreState(state)
  end
end

local function GetCurrentState_Serialized(skipnewlines)
  if skipnewlines == nil then skipnewlines = true end
  local state = GetCurrentState()
  return Serialize(state, nil, skipnewlines)
end

local function SaveStateToFile(state, path)
  local stateStr = PrintState(state)
  local f = io.open(path, 'wb')
  if f then
    f:write(stateStr)
    f:close()
    return true
  end
  return false
end

local function SaveCurrentStateToFile(path)
  return SaveStateToFile(GetCurrentState(), path)
end

local function PrintToggleActionForState(state, wantsUngrouped)
  local str = 'local r = reaper\n\n'
    ..'package.path = r.GetResourcePath().."/Scripts/sockmonkey72 Scripts/Mouse Maps/MouseMaps/?.lua"\n'
    ..'local mm = require "MouseMaps"\n\n'
    ..'local '..Serialize(state, 'data')..'\n\n'
    ..'mm.HandleToggleAction("toggleCommandTest", '..(wantsUngrouped and 'true' or 'nil')..', '..'data)\n'
    ..'r.TrackList_AdjustWindows(0)\n'
  return str
end

local function SaveToggleActionToFile(path, wantsUngrouped)
  local actionStr = PrintToggleActionForState(GetCurrentState(), wantsUngrouped)
  local f = io.open(path, 'wb')
  if f then
    f:write(actionStr)
    f:close()
    return true
  end
  return false
end

local function PrintOneShotActionForState(state)
  local str = 'local r = reaper\n\n'
    ..'package.path = r.GetResourcePath().."/Scripts/sockmonkey72 Scripts/Mouse Maps/MouseMaps/?.lua"\n'
    ..'local mm = require "MouseMaps"\n\n'
    ..'local '..Serialize(state, 'data')..'\n\n'
    ..'mm.RestoreState(data)\n'
  return str
end

local function SaveOneShotActionToFile(path)
  local actionStr = PrintOneShotActionForState(GetCurrentState())
  local f = io.open(path, 'wb')
  if f then
    f:write(actionStr)
    f:close()
    return true
  end
  return false
end

-- TODO: group handling -- register command IDs and disable all but this one when enabling

local function GetGroup()
  local groupState
  local extState = r.GetExtState(SectionName, 'commonTogIDs')
  if extState then groupState = Deserialize(extState) end
  return groupState
end

local function PutGroup(groupState)
  if groupState then
    r.SetExtState(SectionName, 'commonTogIDs', Serialize(groupState, nil, true), 1)
  end
end

local function DisableAllInGroup(sectionID, cmdID)
  local groupState = GetGroup()
  if groupState then
    for _, v in pairs(groupState) do
      if v ~= cmdID then
        -- NOTE: this sets the command state, but doesn't call into the command itself
        -- which simplifies the logic significantly
        r.SetToggleCommandState(sectionID, v, 0)
      end
    end
  end
end

local function AddToGroup(sectionID, cmdID)
  local found = false
  local groupState = GetGroup()
  if groupState then
    for _, v in pairs(groupState) do
      if v == cmdID then
        found = true
        break
      end
    end
  end
  if not found then
    if not groupState then groupState = {} end
    table.insert(groupState, cmdID)
    PutGroup(groupState)
  end
end

local function RemoveFromGroup(sectionID, cmdID)
  local groupState = GetGroup()
  if groupState then
    for k, v in pairs(groupState) do
      if v == cmdID then
        groupState[k] = nil
        PutGroup(groupState)
        return
      end
    end
  end
end

local function HandleToggleAction(cmdName, ungrouped, data)
  local _, _, sectionID, cmdID = r.get_action_context()
  local togState = r.GetToggleCommandStateEx(sectionID, cmdID)
  local commandName = ungrouped and cmdName or CommonName
  local extState = r.GetExtState(SectionName, commandName)
  local common = not ungrouped

  -- post(cmdName, '"'..(extState and 'hasExt' or 'nil')..'"')

  if togState == -1 then -- first run, not set yet (fix this, Cockos!)
    if extState and extState ~= '' then
      togState = 1
      if common then
        AddToGroup(sectionID, cmdID)
      end
      post('-1 toggle on')
    else
      togState = 0
      if common then
        RemoveFromGroup(sectionID, cmdID)
      else
        r.DeleteExtState(SectionName, commandName, true)
      end
      post('-1 toggle off')
    end
  else -- normal operation
    if togState ~= 1 then
      togState = 1
      if common then
        if not extState or extState == '' then
          r.SetExtState(SectionName, commandName, GetCurrentState_Serialized(), true)
          post('set common state')
        end
        DisableAllInGroup(sectionID, cmdID)
        AddToGroup(sectionID, cmdID)
      else
        r.SetExtState(SectionName, commandName, GetCurrentState_Serialized(), true)
      end
      post('toggle on')
      RestoreState(data)
    else
      togState = 0
      post('restore common state')
      if extState and extState ~= '' then RestoreState_Serialized(extState) end
      r.DeleteExtState(SectionName, commandName, true)
      if common then
        RemoveFromGroup(sectionID, cmdID)
      end
      post('toggle off')
    end
  end
  r.SetToggleCommandState(sectionID, cmdID, togState)
end

-----------------------------------------------------------------------------
----------------------------------- EXPORT ----------------------------------

MouseMaps.RestoreState = RestoreState
MouseMaps.RestoreState_Serialized = RestoreState_Serialized
MouseMaps.RestoreStateFromFile = RestoreStateFromFile

MouseMaps.GetCurrentState = GetCurrentState
MouseMaps.GetCurrentState_Serialized = GetCurrentState_Serialized
MouseMaps.SaveCurrentStateToFile = SaveCurrentStateToFile

MouseMaps.PrintToggleActionForState = PrintToggleActionForState
MouseMaps.SaveToggleActionToFile = SaveToggleActionToFile

MouseMaps.PrintOneShotActionForState = PrintOneShotActionForState
MouseMaps.SaveOneShotActionToFile = SaveOneShotActionToFile

MouseMaps.HandleToggleAction = HandleToggleAction

MouseMaps.spairs = spairs
MouseMaps.post = post
MouseMaps.p = post

return MouseMaps
