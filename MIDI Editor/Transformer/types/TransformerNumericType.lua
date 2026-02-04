--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local NumericType = {}

local TypeRegistry = require 'TransformerTypeRegistry'

----------------------------------------------------------------------------------------
-- IntEditor type (integer numeric input)
-- minimal: no renderUI (doHandleTableParam handles all UI complexity)
-- no codeTemplate (operations substitute textEditorStr directly)

local intTypeDef = {
  name = 'inteditor',

  detectType = function(src)
    return src and src.inteditor == true
  end,

  parseNotation = function(str, row, paramTab, index)
    -- store raw string, validation happens later in setRowParam
    -- (setRowParam has access to range from target/condOp context)
    row.params[index].textEditorStr = str
  end,

  generateNotation = function(row, index)
    -- return textEditorStr for preset saving
    return row.params[index].textEditorStr
  end,
}

----------------------------------------------------------------------------------------
-- FloatEditor type (float numeric input)
-- same structure as inteditor, differs only in validation (handled by ensureNumString)

local floatTypeDef = {
  name = 'floateditor',

  detectType = function(src)
    return src and src.floateditor == true
  end,

  parseNotation = function(str, row, paramTab, index)
    row.params[index].textEditorStr = str
  end,

  generateNotation = function(row, index)
    return row.params[index].textEditorStr
  end,
}

----------------------------------------------------------------------------------------
-- Register types

TypeRegistry.register(intTypeDef)
TypeRegistry.register(floatTypeDef)

return NumericType
