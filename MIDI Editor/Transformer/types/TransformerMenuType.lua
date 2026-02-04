--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local MenuType = {}

local TypeRegistry = require 'TransformerTypeRegistry'

----------------------------------------------------------------------------------------
-- Menu type (button-based parameter selection)
-- renders as button with popup menu
-- no codeTemplate: menu selections substitute textEditorStr from paramTab entry

local menuTypeDef = {
  name = 'menu',

  detectType = function(src)
    return src and src.menu == true
  end,

  parseNotation = function(str, row, paramTab, index)
    -- store str in textEditorStr (menu entry lookup happens elsewhere)
    if str and row.params[index] then
      row.params[index].textEditorStr = str
    end
  end,

  generateNotation = function(row, index)
    -- return textEditorStr for preset saving
    return row.params[index] and row.params[index].textEditorStr or ''
  end,

  -- NO renderUI: handleTableParam handles button+popup rendering
  -- NO codeTemplate: menu selections use textEditorStr from paramTab entry
}

----------------------------------------------------------------------------------------
-- Param3 type (callback-based parameter extensions)
-- delegates to operation-specific callbacks (formatter, parser, menuLabel)
-- used by operations with custom third parameter UI (curve types, etc.)

local param3TypeDef = {
  name = 'param3',

  detectType = function(src)
    return src and src.param3 == true
  end,

  -- NO parseNotation: param3 uses row.params[3].parser callback
  -- NO generateNotation: param3 uses row.params[3].formatter callback
  -- NO renderUI: handleTableParam delegates to operation callbacks
  -- NO codeTemplate: operations substitute {param3} from callback result
}

----------------------------------------------------------------------------------------
-- Hidden type (no UI display)
-- signals "don't render this parameter"
-- renderUI=nil triggers early-return in handleTableParam

local hiddenTypeDef = {
  name = 'hidden',

  detectType = function(src)
    return src and src.hidden == true
  end,

  -- NO parseNotation: no value to parse
  -- NO generateNotation: no value to generate
  -- NO renderUI: handleTableParam early-returns for hidden params
  -- NO codeTemplate: hidden params not in generated code
}

----------------------------------------------------------------------------------------
-- Register types

TypeRegistry.register(menuTypeDef)
TypeRegistry.register(param3TypeDef)
TypeRegistry.register(hiddenTypeDef)

return MenuType
