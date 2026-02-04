--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local TypeRegistry = {}
local types = {}

-- Register a type definition
-- def must have: name (string), detectType (function)
-- Optional: parseNotation, generateNotation, makeDefault, renderUI, codeTemplate
function TypeRegistry.register(def)
  if not def.name then
    error('TypeRegistry.register: missing name')
  end
  if types[def.name] then
    error('TypeRegistry.register: type already registered: ' .. def.name)
  end
  types[def.name] = def
  return def.name
end

-- Get type definition by name
function TypeRegistry.getType(name)
  return types[name]
end

-- Detect type from operation/condition entry
-- Returns (typeName, typeDef) or (nil, nil)
function TypeRegistry.detectType(src)
  if not src then return nil, nil end
  for name, def in pairs(types) do
    if def.detectType and def.detectType(src) then
      return name, def
    end
  end
  return nil, nil
end

-- Get all registered types (for iteration)
function TypeRegistry.getAll()
  return types
end

-- Check if type is registered
function TypeRegistry.hasType(name)
  return types[name] ~= nil
end

return TypeRegistry
