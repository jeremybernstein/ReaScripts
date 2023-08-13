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

local CalcFasterAPI = function ()
  local appVer = r.GetAppVersion()
  local major, minor, devrev = appVer:match('(%d+)%.(%d+)([^%d][^+/]*)')
  if not major then major, minor = appVer:match('(%d+)%.(%d+)') end
  if devrev then devrev = devrev:match('+dev(%d+)') end
  major = major and tonumber(major) or 0
  minor = minor and tonumber(minor) or 0
  devrev = devrev and tonumber(devrev) or 0
  return major > 6 or (major == 6 and (minor > 73 or (minor == 73 and devrev and devrev >= 111))), major, minor, devrev
end
local UseFasterAPI, major, minor, devrev = CalcFasterAPI()

-----------------------------------------------------------------------------
---------------------------------- CONTEXTS ---------------------------------

-- known contexts as of 7. Jan 2023
local contexts = {
  MM_CTX_AREASEL = 'Razor edit area (left drag)',
  MM_CTX_AREASEL_CLK = 'Razor edit area (left click)',
  MM_CTX_AREASEL_EDGE = 'Razor edit edge (left drag)',
  MM_CTX_AREASEL_ENV = 'Razor edit envelope area (left drag)',
  MM_CTX_ARRANGE_MMOUSE = 'Arrange view (middle drag)',
  MM_CTX_ARRANGE_MMOUSE_CLK = 'Arrange view (middle click)',
  MM_CTX_ARRANGE_RMOUSE = 'Arrange view (right drag)',
  MM_CTX_CROSSFADE = 'Media item fade intersection (left drag)',
  MM_CTX_CROSSFADE_CLK = 'Media item fade intersection (left click)',
  MM_CTX_CROSSFADE_DBLCLK = 'Media item fade intersection (double click)',
  MM_CTX_CURSORHANDLE = 'Edit cursor handle (left drag)',
  MM_CTX_ENVCP_DBLCLK = 'Envelope control panel (double click)',
  MM_CTX_ENVLANE = 'Envelope lane (left drag)',
  MM_CTX_ENVLANE_DBLCLK = 'Envelope lane (double click)',
  MM_CTX_ENVPT = 'Envelope point (left drag)',
  MM_CTX_ENVPT_DBLCLK = 'Envelope point (double click)',
  MM_CTX_ENVSEG = 'Envelope segment (left drag)',
  MM_CTX_ENVSEG_DBLCLK = 'Envelope segment (double click)',
  MM_CTX_FIXEDLANETAB_CLK = 'Fixed lane header button (left click)',
  MM_CTX_ITEM = 'Media item (left drag)',
  MM_CTX_ITEMEDGE = 'Media item edge (left drag)',
  MM_CTX_ITEMEDGE_DBLCLK = 'Media item edge (double click)',
  MM_CTX_ITEMFADE = 'Media item fade/autocrossfade (left drag)',
  MM_CTX_ITEMFADE_CLK = 'Media item fade/autocrossfade (left click)',
  MM_CTX_ITEMFADE_DBLCLK = 'Media item fade/autocrossfade (double click)',
  MM_CTX_ITEMLOWER = 'Media item bottom half (left drag)',
  MM_CTX_ITEMLOWER_CLK = 'Media item bottom half (left click)',
  MM_CTX_ITEMLOWER_DBLCLK = 'Media item bottom half (double click)',
  MM_CTX_ITEMSTRETCHMARKER = 'Media item stretch marker (left drag)',
  MM_CTX_ITEMSTRETCHMARKERRATE = 'Media item stretch marker rate (left drag)',
  MM_CTX_ITEMSTRETCHMARKER_DBLCLK = 'Media item stretch marker (double click)',
  MM_CTX_ITEM_CLK = 'Media item (left click)',
  MM_CTX_ITEM_DBLCLK = 'Media item (double click)',
  MM_CTX_LINKEDLANE = 'Fixed lane when comping is enabled (left drag)',
  MM_CTX_LINKEDLANE_CLK = 'Fixed lane comp area (left click)',
  MM_CTX_MARKERLANES = 'Project marker/region lane (left drag)',
  MM_CTX_MARKER_REGIONEDGE = 'Project marker/region edge (left drag)',
  MM_CTX_MCP_DBLCLK = 'Mixer control panel (double click)',
  MM_CTX_MIDI_CCEVT = 'MIDI CC event (left click/drag)',
  MM_CTX_MIDI_CCEVT_DBLCLK = 'MIDI CC event (double click)',
  MM_CTX_MIDI_CCLANE = 'MIDI CC lane (left click/drag)',
  MM_CTX_MIDI_CCLANE_DBLCLK = 'MIDI CC lane (double click)',
  MM_CTX_MIDI_CCSEG = 'MIDI CC segment (left click/drag)',
  MM_CTX_MIDI_CCSEG_DBLCLK = 'MIDI CC segment (double click)',
  MM_CTX_MIDI_ENDPTR = 'MIDI source loop end marker (left drag)',
  MM_CTX_MIDI_MARKERLANES = 'MIDI marker/region lanes (left drag)',
  MM_CTX_MIDI_NOTE = 'MIDI note (left drag)',
  MM_CTX_MIDI_NOTEEDGE = 'MIDI note edge (left drag)',
  MM_CTX_MIDI_NOTE_CLK = 'MIDI note (left click)',
  MM_CTX_MIDI_NOTE_DBLCLK = 'MIDI note (double click)',
  MM_CTX_MIDI_PIANOROLL = 'MIDI piano roll (left drag)',
  MM_CTX_MIDI_PIANOROLL_CLK = 'MIDI piano roll (left click)',
  MM_CTX_MIDI_PIANOROLL_DBLCLK = 'MIDI piano roll (double click)',
  MM_CTX_MIDI_RMOUSE = 'MIDI editor (right drag)',
  MM_CTX_MIDI_RULER = 'MIDI ruler (left drag)',
  MM_CTX_MIDI_RULER_CLK = 'MIDI ruler (left click)',
  MM_CTX_MIDI_RULER_DBLCLK = 'MIDI ruler (double click)',
  MM_CTX_POOLEDENV = 'Automation item (left drag)',
  MM_CTX_POOLEDENVEDGE = 'Automation item edge (left drag)',
  MM_CTX_POOLEDENV_DBLCLK = 'Automation item (double click)',
  MM_CTX_REGION = 'Project region (left drag)',
  MM_CTX_RULER = 'Ruler (left drag)',
  MM_CTX_RULER_CLK = 'Ruler (left click)',
  MM_CTX_RULER_DBLCLK = 'Ruler (double click)',
  MM_CTX_TCP_DBLCLK = 'Track control panel (double click)',
  MM_CTX_TEMPOMARKER = 'Project tempo/time signature marker (left drag)',
  MM_CTX_TRACK = 'Track (left drag)',
  MM_CTX_TRACK_CLK = 'Track (left click)',
}

-----------------------------------------------------------------------------
----------------------------------- UTILS -----------------------------------

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

local function OrderByKey(t, a, b)
  return a < b
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
    for k, v in spairs(val, OrderByKey) do
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

-----------------------------------------------------------------------------
------------------------------- CONTEXT UTILS -------------------------------

local function getContextNames()
  local contextNames = {}
  for k in pairs(contexts) do
    table.insert(contextNames, k)
  end
  return contextNames
end

local function UniqueContexts()
  local unique = {}
  for k, v in spairs(contexts, OrderByKey) do
    local base = k:match('^(.*)_[RM]MOUSE_CLK$')
    if not base then base = k:match('^(.*)_(.*)CLK$') end
    if not base then base = k:match('^(.*)_[RM]MOUSE') end
    if not base then base = k end
    if base then
      if not unique[base] then
        unique[base] = {}
        unique[base].label = v:match('^(.*)%s+%(')
        if not unique[base].label then unique[base].label = v end
      end
      table.insert(unique[base], { key = k, value = v })
    end
  end
  return unique
end

-----------------------------------------------------------------------------
------------------------------ ACTIVE ACTIONS -------------------------------

local function GetActiveToggleAction()
  local activeAction = r.GetExtState(SectionName, 'activeToggleAction')
  local activeActionTable = Deserialize(activeAction)
  if activeActionTable then return activeActionTable.cmdID, activeActionTable.path end
  return nil, nil
end

local function GetActiveAction()
  local activeAction = r.GetExtState(SectionName, 'activeToggleAction')
  -- from beta versions, can be removed eventually
  local cmdIdx = tonumber(activeAction)
  if cmdIdx then
    local cmdID = r.ReverseNamedCommandLookup(cmdIdx)
    if cmdID and cmdID ~= '' then return '_'..cmdID end
  end
  -- end beta version support
  local activeActionTable = Deserialize(activeAction)
  if activeActionTable then return activeActionTable.cmdID end
  return ''
end

local function IsActiveAction(cmdID)
  local activeAction = GetActiveAction()
  return cmdID == activeAction
end

local function PutActiveAction(cmdID, path)
  if cmdID then
    r.SetExtState(SectionName, 'activeToggleAction', Serialize({ cmdID = cmdID, path = path }, nil, 1), 1)
  else
    r.DeleteExtState(SectionName, 'activeToggleAction', 1)
  end
end

local function SwapActiveAction(sectionID, cmdID, path)
  local activeAction = GetActiveAction()
  if activeAction ~= cmdID then
    -- NOTE: this sets the command state, but doesn't call into the command itself
    -- which simplifies the logic significantly
    if activeAction then r.SetToggleCommandState(sectionID, r.NamedCommandLookup(activeAction), 0) end
    PutActiveAction(cmdID, path)
  end
end

local function SetActiveAction(sectionID, cmdID, path)
  local activeAction = GetActiveAction()
  if activeAction ~= cmdID then
    PutActiveAction(cmdID, path)
  end
end

local function RemoveActiveAction(sectionID, cmdID)
  PutActiveAction()
end

-----------------------------------------------------------------------------
---------------------------------- READING ----------------------------------

local function ReadStateFromFile(path, filtered)
  local state = {}
  local ctx
  if filtered then
    ctx = {}
    for _, v in ipairs(filtered) do
      ctx[v] = true
    end
  end
  local current, currentctx
  if not FileExists(path) then return false end
  for line in io.lines(path) do
    local newcontext = line:match('%[(.*)%]')
    if newcontext and newcontext ~= '' then
      if newcontext == 'hasimported' then
        current = nil
        currentctx = nil
      else
        local append = true
        if filtered then
          append = ctx[newcontext] and true or false
        end
        if append then
          if not state[newcontext] then state[newcontext] = {} end
          currentctx = newcontext
          current = state[newcontext]
          -- post('['..newcontext..']')
        else
          current = nil
          currentctx = nil
        end
      end
    end

    if current == nil and currentctx == nil then
      -- local ctxname = line:match('(MM_CTX_%g*)%s*=')
      -- if ctxname then
      --   if not state[ctxname] then state[ctxname] = {} end
      -- end
    else
      local modidx, action, flag = line:match('mm_(%d+)%s*=%s*(%g*)%s*(%g*)$')
      if modidx and action then
        modidx = tonumber(modidx)
        if flag == '' then flag = nil end

        local actionId = tonumber(action)
        if actionId and not flag and actionId < 1000 then flag = 'm' end

        if flag then action = action .. ' ' .. flag end
        if modidx then current[modidx] = action end

        -- post('mm'..modidx, '"'..action..'"')
      end
    end
  end
  return state
end

local function GetCurrentState(filtered)
  return ReadStateFromFile(r.GetResourcePath()..'/reaper-mouse.ini', filtered)
end

local function RestoreStateInternal(state, filtered, disableToggles)
  if not state then return false end

  if disableToggles then
    r.DeleteExtState(SectionName, CommonName, true)
    SwapActiveAction(0)
  end

  local rawCtx = filtered
  if not rawCtx then rawCtx = getContextNames() end

  local ctx = {}
  for _, v in ipairs(rawCtx) do
    ctx[v] = true
  end

  -- set everything to -1
  if not filtered and UseFasterAPI then
    r.SetMouseModifier(-1, -1, -1)
  else
    if ctx then
      for k in pairs(ctx) do
        if UseFasterAPI then
          r.SetMouseModifier(k, -1, -1)
        else
          for i = 0, 15 do
            r.SetMouseModifier(k, i, '-1')
          end
        end
      end
    end
  end

  for k, v in pairs(state) do
    -- filtered will not restored unknown cats
    local known = filtered and true or (ctx and ctx[k]) and true or false
    for i = 0, 15 do
      if v[i] then
        local action = v[i]
        -- -- was necessary in +dev 0114(?)-0120, fixed in 0124
        -- local action, flag = v[i]:match('^(%g*)%s*(%g*)$')
        -- if flag == '' then flag = nil end
        -- if not tonumber(action) then action = tostring(r.NamedCommandLookup(action)) end
        -- if flag then action = action .. ' ' .. flag end
        r.SetMouseModifier(k, i, action)
        -- post('setting in ['..k..']', i, '"'..action..'"')
      elseif not known then
        r.SetMouseModifier(k, i, '-1')
      end
    end
  end
  return true
end

local function RestoreState(state, filtered)
  return RestoreStateInternal(state, filtered, true)
end

local function RestoreStateFromFile(path, filtered)
  local state = ReadStateFromFile(path)
  return RestoreState(state, filtered)
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

-----------------------------------------------------------------------------
---------------------------------- WRITING ----------------------------------

local function PrintState(state)
  local str = ''
  for k, v in spairs(state, OrderByKey) do
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

local function SaveCurrentStateToFile(path, filtered)
  return SaveStateToFile(GetCurrentState(filtered), path)
end

-----------------------------------------------------------------------------
---------------------------------- STARTUP ----------------------------------

local function PrintStartupActionScript(actionTable)
  local str = 'local r = reaper\n\n'
    ..'local '..Serialize(actionTable, 'cmdIDs')..'\n\n'
    ..'for _, v in ipairs(cmdIDs) do\n'
    ..'  r.Main_OnCommand(r.NamedCommandLookup(v.cmdID), 0)\n'
    ..'end\n'
    -- ..'r.TrackList_AdjustWindows(0)\n'
  return str
end

local function AddRemoveStartupAction(cmdIdx, fpath, add)
  local path = r.GetResourcePath()..'/Scripts/MouseMapActions/__startup_MouseMap.lua'
  local existing = ''
  local capturing = false

  if FileExists(path) then
    for line in io.lines(path) do
      if capturing then
        existing = existing..' '..line
        if line:match('^}') then capturing = false break end
      elseif line:match('^local cmdIDs = {') then
        existing = '{ '
        capturing = true
      end
    end
  end

  local actionTable
  if existing ~= '' then actionTable = Deserialize(existing) end
  if not actionTable then actionTable = {} end

  if cmdIdx then
    local cmdID = '_'..r.ReverseNamedCommandLookup(cmdIdx)
    local found = 0
    for k, v in ipairs(actionTable) do
      if v.cmdID == cmdID then found = k break end
    end
    if found == 0 and add then
      table.insert(actionTable, { cmdID = cmdID, path = fpath })
    elseif found > 0 and not add then
      table.remove(actionTable, found)
    end
  end

  -- prune action table for missing files
  for i = #actionTable, 1, -1 do
    local v = actionTable[i]
    if not FileExists(v.path) then
      r.AddRemoveReaScript(false, 0, v.path, true)
      table.remove(actionTable, i)
    end
  end

  local actionStr = PrintStartupActionScript(actionTable)
  local f = io.open(path, 'w+b')
  if f then
    f:write(actionStr)
    f:close()
    local actionScriptID = r.AddRemoveReaScript(true, 0, path, true)
    if actionScriptID ~= 0 then
      local startupFilePath = r.GetResourcePath()..'/Scripts/__startup.lua'
      local actionScriptName = '_'..r.ReverseNamedCommandLookup(actionScriptID)
      local startupStr = ''
      f = io.open(startupFilePath, 'r')
      if f then
        startupStr = f:read('*all')
        f:close()
      end
      if not startupStr:match(actionScriptName) then
        -- make a backup
        if startupStr ~= '' then
          f = io.open(r.GetResourcePath()..'/Scripts/__startup_backup.lua', 'wb')
          if f then
            f:write(startupStr)
            f:close()
          end
        end
        -- end backup
        f = io.open(startupFilePath, 'a+b')
        if f then
          f:write('\nreaper.Main_OnCommand(reaper.NamedCommandLookup("'..actionScriptName..'"), 0) -- __startup_MouseMaps.lua\n')
          f:close()
        end
      end
    end
    return true, actionScriptID
  end
  return false, 0
end

-----------------------------------------------------------------------------
---------------------------------- ACTIONS ----------------------------------

local function PrintToggleActionForState(state, wantsUngrouped, filtered)
  local actionName = 'nil'
  if wantsUngrouped then
    local _, filename, sectionID, cmdID = r.get_action_context()
    actionName = filename
  end

  local str = 'local r = reaper\n\n'
    ..'package.path = r.GetResourcePath().."/Scripts/sockmonkey72 Scripts/Mouse Maps/MouseMaps/?.lua"\n'
    ..'local mm = require "MouseMaps"\n\n'
    ..'local '..Serialize(state, 'data')..'\n\n'
    ..(filtered and ('local '..Serialize(filtered, 'filter')..'\n\n') or '')
    ..'mm.HandleToggleAction('..actionName..', '..'data'..(filtered and ', filter' or '')..')\n'
    ..'r.TrackList_AdjustWindows(0)\n'
  return str
end

local function SaveToggleActionToFile(path, wantsUngrouped, filtered)
  local actionStr = PrintToggleActionForState(GetCurrentState(filtered), wantsUngrouped, filtered)
  local f = io.open(path, 'wb')
  if f then
    f:write(actionStr)
    f:close()
    return true
  end
  return false
end

local function PrintOneShotActionForState(state, filtered)
  local str = 'local r = reaper\n\n'
    ..'package.path = r.GetResourcePath().."/Scripts/sockmonkey72 Scripts/Mouse Maps/MouseMaps/?.lua"\n'
    ..'local mm = require "MouseMaps"\n\n'
    ..'local '..Serialize(state, 'data')..'\n\n'
    ..(filtered and ('local '..Serialize(filtered, 'filter')..'\n\n') or '')
    ..'mm.RestoreState(data'..(filtered and ', filter' or '')..')\n'
  return str
end

local function SaveOneShotActionToFile(path, filtered)
  local actionStr = PrintOneShotActionForState(GetCurrentState(filtered), filtered)
  local f = io.open(path, 'wb')
  if f then
    f:write(actionStr)
    f:close()
    return true
  end
  return false
end

local function PrintPresetLoadActionForState(presetName)
  local str = 'local r = reaper\n\n'
    ..'package.path = r.GetResourcePath().."/Scripts/sockmonkey72 Scripts/Mouse Maps/MouseMaps/?.lua"\n'
    ..'local mm = require "MouseMaps"\n\n'
    ..'mm.RestoreStateFromFile(r.GetResourcePath().."/MouseMaps/'..presetName..'.ReaperMouseMap")\n'
  return str
end

local function SavePresetLoadActionToFile(path, presetName)
  local actionStr = PrintPresetLoadActionForState(presetName)
  local f = io.open(path, 'wb')
  if f then
    f:write(actionStr)
    f:close()
    return true
  end
  return false
end

-----------------------------------------------------------------------------
---------------------------------- RUNTIME ----------------------------------

local function HandleToggleAction(cmdName, data, filtered)
  local _, path, sectionID, cmdIdx = r.get_action_context()
  local togState = r.GetToggleCommandStateEx(sectionID, cmdIdx)
  local commandName = cmdName or CommonName
  local extState = r.GetExtState(SectionName, commandName)
  local common = cmdName and false or true
  local cmdID = '_'..r.ReverseNamedCommandLookup(cmdIdx)

  if togState == -1 then -- first run, not set yet (fix this, Cockos!)
    togState = 0
    if extState and extState ~= '' then
      if not common or IsActiveAction(cmdID) then
        togState = 1
        if common then
          SetActiveAction(sectionID, cmdID, path)
        end
        -- post('-1 toggle on')
      end
    else
      if not common or IsActiveAction(cmdID) then
        r.DeleteExtState(SectionName, commandName, true)
        if common then
          RemoveActiveAction(sectionID, cmdID)
        end
        -- post('-1 toggle off')
      end
    end
  else -- normal operation
    if togState ~= 1 then
      togState = 1
      if common then
        if not extState or extState == '' then
          r.SetExtState(SectionName, commandName, GetCurrentState_Serialized(), true)
          -- post('set common state')
        end
        SwapActiveAction(sectionID, cmdID, path)
      else
        r.SetExtState(SectionName, commandName, GetCurrentState_Serialized(), true)
      end
      -- post('toggle on')
      RestoreStateInternal(data, filtered, false)
    else
      togState = 0
      -- post('restore common state')
      if extState and extState ~= '' then RestoreState_Serialized(extState) end
      r.DeleteExtState(SectionName, commandName, true)
      if common then
        RemoveActiveAction(sectionID, cmdID)
      end
      -- post('toggle off')
    end
  end
  r.SetToggleCommandState(sectionID, cmdIdx, togState)
end

-----------------------------------------------------------------------------
----------------------------------- EXPORT ----------------------------------

MouseMaps.GetActiveToggleAction = GetActiveToggleAction
MouseMaps.AddRemoveStartupAction = AddRemoveStartupAction

MouseMaps.RestoreState = RestoreState
MouseMaps.RestoreState_Serialized = RestoreState_Serialized
MouseMaps.RestoreStateFromFile = RestoreStateFromFile

MouseMaps.GetCurrentState = GetCurrentState
MouseMaps.GetCurrentState_Serialized = GetCurrentState_Serialized
MouseMaps.SaveCurrentStateToFile = SaveCurrentStateToFile

MouseMaps.SaveToggleActionToFile = SaveToggleActionToFile
MouseMaps.SaveOneShotActionToFile = SaveOneShotActionToFile
MouseMaps.SavePresetLoadActionToFile = SavePresetLoadActionToFile

MouseMaps.HandleToggleAction = HandleToggleAction

MouseMaps.UniqueContexts = UniqueContexts

MouseMaps.Serialize = Serialize
MouseMaps.Deserialize = Deserialize

MouseMaps.FileExists = FileExists
MouseMaps.DirExists = DirExists
MouseMaps.tprint = tprint
MouseMaps.spairs = spairs
MouseMaps.post = post
MouseMaps.p = post

-- post(UseFasterAPI and 'FAST' or 'SLOW', major, minor, devrev)

return MouseMaps
