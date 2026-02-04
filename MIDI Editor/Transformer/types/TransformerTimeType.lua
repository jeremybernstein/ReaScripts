--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local TimeType = {}

local TypeRegistry = require 'TransformerTypeRegistry'
local TimeUtils = require 'TransformerTimeUtils'
local gdefs = require 'TransformerGeneralDefs'

----------------------------------------------------------------------------------------
-- Time type (absolute position: 1.1.00 format)

local timeTypeDef = {
  name = 'time',

  detectType = function(src)
    return src and src.time == true
  end,

  parseNotation = function(str, row, paramTab, index)
    local formatted = TimeUtils.timeFormatRebuf(str or gdefs.DEFAULT_TIMEFORMAT_STRING)
    row.params[index].timeFormatStr = formatted
  end,

  generateNotation = function(row, index)
    return row.params[index].timeFormatStr or gdefs.DEFAULT_TIMEFORMAT_STRING
  end,

  renderUI = function(ctx, ImGui, row, index, options)
    return {{
      widget = 'text',
      value = row.params[index].timeFormatStr or gdefs.DEFAULT_TIMEFORMAT_STRING,
      onChange = function(buf)
        row.params[index].timeFormatStr = TimeUtils.timeFormatRebuf(buf)
        if options and options.onChange then
          options.onChange()
        end
      end,
      flags = options and options.textFlags,
      callback = options and options.timeFormatCallback,
    }}
  end,
}

----------------------------------------------------------------------------------------
-- TimeDur type (duration: 0.0.00 format)

local timedurTypeDef = {
  name = 'timedur',

  detectType = function(src)
    return src and src.timedur == true
  end,

  parseNotation = function(str, row, paramTab, index)
    local formatted = TimeUtils.lengthFormatRebuf(str or gdefs.DEFAULT_LENGTHFORMAT_STRING)
    row.params[index].timeFormatStr = formatted
  end,

  generateNotation = function(row, index)
    return row.params[index].timeFormatStr or gdefs.DEFAULT_LENGTHFORMAT_STRING
  end,

  renderUI = function(ctx, ImGui, row, index, options)
    return {{
      widget = 'text',
      value = row.params[index].timeFormatStr or gdefs.DEFAULT_LENGTHFORMAT_STRING,
      onChange = function(buf)
        row.params[index].timeFormatStr = TimeUtils.lengthFormatRebuf(buf)
        if options and options.onChange then
          options.onChange()
        end
      end,
      flags = options and options.textFlags,
      callback = options and options.timeFormatCallback,
    }}
  end,
}

----------------------------------------------------------------------------------------
-- Register types

TypeRegistry.register(timeTypeDef)
TypeRegistry.register(timedurTypeDef)

return TimeType
