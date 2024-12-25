--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local TransformerGlobal = {}

----------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------

local gdefs = require 'TransformerGeneralDefs'

-----------------------------------------------------------------------------
----------------------------------- OOP -------------------------------------

local DEBUG_CLASS = false -- enable to check whether we're using known object properties

local function class(base, setup, init) -- http://lua-users.org/wiki/SimpleLuaClasses
  local c = {}    -- a new class instance
  if not init and type(base) == 'function' then
    init = base
    base = nil
  elseif type(base) == 'table' then
   -- our new class is a shallow copy of the base class!
    for i, v in pairs(base) do
      c[i] = v
    end
    c._base = base
  end
  if DEBUG_CLASS then
    c._names = {}
    if setup then
      for i, v in pairs(setup) do
        c._names[i] = true
      end
    end

    c.__newindex = function(table, key, value)
      local found = false
      if table._names and table._names[key] then found = true
      else
        local m = getmetatable(table)
        while (m) do
          if m._names[key] then found = true break end
          m = m._base
        end
      end
      if not found then
        error('unknown property: '..key, 3)
      else rawset(table, key, value)
      end
    end
  end

  -- the class will be the metatable for all its objects,
  -- and they will look up their methods in it.
  c.__index = c

  -- expose a constructor which can be called by <classname>(<args>)
  local mt = {}
  mt.__call = function(class_tbl, ...)
    local obj = {}
    setmetatable(obj, c)
    if class_tbl.init then
      class_tbl.init(obj,...)
    else
      -- make sure that any stuff from the base class is initialized!
      if base and base.init then
        base.init(obj, ...)
      end
    end
    return obj
  end
  c.init = init
  c.is_a = function(self, klass)
    local m = getmetatable(self)
    while m do
      if m == klass then return true end
      m = m._base
    end
    return false
  end
  setmetatable(c, mt)
  return c
end

-----------------------------------------------------------------------------
-------------------------------- PARAMINFO ----------------------------------

local ParamInfo = class(nil, {})

function ParamInfo:init()
  self.menuEntry = 1
  self.textEditorStr = '0'
  self.timeFormatStr = gdefs.DEFAULT_TIMEFORMAT_STRING
  self.editorType = nil
  self.percentVal = nil
end

----------------------------------------------------------
--------- BASE64 LIB from http://lua-users.org/wiki/BaseSixtyFour

-- character table string
local bt = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- encoding
local function b64enc(data)
  return ((data:gsub('.', function(x)
    local r,b='',x:byte()
    for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
    return r;
  end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if (#x < 6) then return '' end
    local c=0
    for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
    return bt:sub(c+1,c+1)
  end)..({ '', '==', '=' })[#data%3+1])
end

-- decoding
local function b64dec(data)
  data = string.gsub(data, '[^'..bt..'=]', '')
  return (data:gsub('.', function(x)
    if (x == '=') then return '' end
    local r,f='',(bt:find(x)-1)
    for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
    return r;
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if (#x ~= 8) then return '' end
    local c=0
    for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
    return string.char(c)
  end))
end

-----------------------------------------------------------------------------
---------------------------------- UTILS ------------------------------------

local function isREAPER7()
  local v = reaper.GetAppVersion()
  if v and v:sub(1, 1) == '7' then return true end
  return false
end

local function tableCopy(obj, seen)
  if type(obj) ~= 'table' then return obj end
  if seen and seen[obj] then return seen[obj] end
  local s = seen or {}
  local res = setmetatable({}, getmetatable(obj))
  s[obj] = res
  for k, v in pairs(obj) do res[tableCopy(k, s)] = tableCopy(v, s) end
  return res
end

local function isValidString(str)
  return str ~= nil and str ~= ''
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

local function deserialize(str)
  local f, err = load('return ' .. str)
  if not f then P(err) end
  return f ~= nil and f() or nil
end

local function orderByKey(t, a, b)
  return a < b
end

local function serialize(val, name, skipnewlines, depth)
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
    for k, v in spairs(val, orderByKey) do
      tmp =  tmp .. serialize(v, k, skipnewlines, depth + 1) .. ',' .. (not skipnewlines and '\n' or '')
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

-- https://stackoverflow.com/questions/1340230/check-if-directory-exists-in-lua
--- Check if a file or directory exists in this path
local function filePathExists(file)
  if not file then return false end
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
  if not path then return false end
  -- '/' works on both Unix and Windows
  return filePathExists(path:match('/$') and path or path..'/')
end

-----------------------------------------------------------------------------
----------------------------------- MISC ------------------------------------

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

TransformerGlobal.class = class
TransformerGlobal.ParamInfo = ParamInfo
TransformerGlobal.isREAPER7 = isREAPER7
TransformerGlobal.tableCopy = tableCopy
TransformerGlobal.isValidString = isValidString
TransformerGlobal.spairs = spairs
TransformerGlobal.serialize = serialize
TransformerGlobal.deserialize = deserialize
TransformerGlobal.base64encode = b64enc
TransformerGlobal.base64decode = b64dec
TransformerGlobal.filePathExists = filePathExists
TransformerGlobal.dirExists = dirExists
TransformerGlobal.ensureNumString = ensureNumString

return TransformerGlobal
