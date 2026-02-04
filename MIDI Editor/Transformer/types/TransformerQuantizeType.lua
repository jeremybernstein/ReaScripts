--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local QuantizeType = {}

local TypeRegistry = require 'TransformerTypeRegistry'
local QuantizeUI = require 'TransformerQuantizeUI'
local tg = require 'TransformerGlobal'

local typeDef = {
  name = 'quantize',

  detectType = function(src)
    return src and src.quantize == true
  end,

  parseNotation = function(str, row, paramTab, index)
    -- Quantize uses child window, not inline notation
    -- But must handle preset loading (quantizeParams serialized)
    if not str or str == '' then
      row.quantizeParams = QuantizeUI.defaultParams()
      return
    end
    local params = tg.deserialize(str)
    row.quantizeParams = params or QuantizeUI.defaultParams()
  end,

  generateNotation = function(row)
    -- Return serialized quantizeParams for preset saving
    if not row.quantizeParams then return '' end
    return tg.serialize(row.quantizeParams)
  end,

  codeTemplate = function(row, ctx)
    -- ctx param is SIGNATURE ONLY for Phase 35 foundation
    -- The returned code string (QuantizeGrid.quantizeGridPosition(...)) does NOT reference ctx
    -- Phase 36 will wire ctx into generated code if needed

    -- Generate complete quantize function call
    local params = row.quantizeParams or QuantizeUI.defaultParams()

    -- Build qParams with all settings needed at runtime
    local qParams = row.mg and tg.tableCopy(row.mg) or {}
    qParams.targetIndex = params.targetIndex or 0
    qParams.strength = params.strength or 100
    qParams.gridMode = params.gridMode or 0
    qParams.gridDivIndex = params.gridDivIndex or 3
    qParams.gridStyleIndex = params.gridStyleIndex or 0

    -- Convert gridDivIndex to subdivision value for quantize functions
    -- gridMode 0 = REAPER grid (-1), gridMode 1 = manual (use gridDivSubdivs)
    local gridDivIndex = params.gridDivIndex or 3
    local gridMode = params.gridMode or 0  -- default to REAPER grid
    if gridMode == 0 then
      qParams.param1 = -1  -- use REAPER grid
    elseif gridMode == 2 then
      qParams.param1 = -2  -- groove mode (handled separately)
    else
      qParams.param1 = QuantizeUI.gridDivSubdivs[gridDivIndex + 1] or 0.0625  -- default 1/16
    end
    qParams.param2 = tostring(params.strength or 100)  -- strength as string for compatibility

    -- Set modifiers based on gridStyleIndex (straight=0, triplet=1, dotted=2, swing=3)
    -- Maps to MG_GRID_* constants: STRAIGHT=0, DOTTED=1, TRIPLET=2, SWING=3
    local styleToModifier = {[0] = 0, [1] = 2, [2] = 1, [3] = 3}  -- indices don't match constants
    qParams.modifiers = styleToModifier[params.gridStyleIndex or 0] or 0

    -- ActionFuns uses 'swing' field (0-100), QuantizeUI stores 'swingStrength'
    qParams.swing = params.swingStrength or 66
    qParams.roundmode = 'round'  -- default, Quantize UI doesn't expose this
    qParams.swingStrength = params.swingStrength or 66
    qParams.lengthGridDivIndex = params.lengthGridDivIndex or 10
    qParams.fixOverlaps = params.fixOverlaps or false
    qParams.canMoveLeft = params.canMoveLeft
    if qParams.canMoveLeft == nil then qParams.canMoveLeft = true end
    qParams.canMoveRight = params.canMoveRight
    if qParams.canMoveRight == nil then qParams.canMoveRight = true end
    qParams.canShrink = params.canShrink
    if qParams.canShrink == nil then qParams.canShrink = true end
    qParams.canGrow = params.canGrow
    if qParams.canGrow == nil then qParams.canGrow = true end
    qParams.rangeFilterEnabled = params.rangeFilterEnabled or false
    qParams.rangeMin = params.rangeMin or 0.0
    qParams.rangeMax = params.rangeMax or 100.0
    qParams.distanceScaling = params.distanceScaling or false
    qParams.distanceMode = params.distanceMode or 0

    -- inject groove data if present (gridMode == 2)
    local gridMode = params.gridMode or 0
    if gridMode == 2 then
      qParams.isGroove = true
      if params.grooveData then
        qParams.groove = {
          data = params.grooveData,
          direction = params.grooveDirection or 0,
          velStrength = params.grooveVelStrength or 0,
          toleranceMin = params.grooveToleranceMin or 0,
          toleranceMax = params.grooveToleranceMax or 100,
        }
      end
    end

    -- Select function based on gridMode and targetIndex
    local funcName
    if gridMode == 2 then  -- groove
      if params.targetIndex == 3 then funcName = 'quantizeGrooveEndPos'
      elseif params.targetIndex == 4 then funcName = 'quantizeGrooveLength'
      else funcName = 'quantizeGroovePosition'
      end
    else  -- musical (REAPER or manual)
      -- context exports these with capital Q
      if params.targetIndex == 3 then funcName = 'QuantizeMusicalEndPos'
      elseif params.targetIndex == 4 then funcName = 'QuantizeMusicalLength'
      else funcName = 'QuantizeMusicalPosition'
      end
    end

    -- Serialize params inline for generated code
    local paramsStr = tg.serialize(qParams)
    return funcName .. '(event, take, PPQ, ' .. paramsStr .. ')'
  end,

  renderUI = function(ctx, ImGui, row, index, options)
    -- Ensure params exist
    row.quantizeParams = row.quantizeParams or QuantizeUI.defaultParams()
    local params = row.quantizeParams

    -- Generate summary text for inline display
    local summary = {}

    -- Grid info
    if (params.gridMode or 0) == 0 then
      table.insert(summary, 'Grid')
    elseif (params.gridMode or 0) == 2 then
      local name = params.grooveFilePath and params.grooveFilePath:match('([^/\\]+)$') or 'Groove'
      table.insert(summary, name)
    else
      local divs = QuantizeUI.gridDivLabels
      local styles = QuantizeUI.gridStyleLabels
      table.insert(summary, (divs[(params.gridDivIndex or 3) + 1] or '1/16'))
      local style = styles[(params.gridStyleIndex or 0) + 1]
      if style and style ~= 'straight' then table.insert(summary, style) end
    end

    -- Strength if not 100%
    if (params.strength or 100) ~= 100 then
      table.insert(summary, '@' .. (params.strength or 100) .. '%')
    end

    local summaryStr = table.concat(summary, ' ')

    -- Return widget definitions
    return {
      {
        widget = 'text',
        value = summaryStr,
      },
      {
        label = 'Configure...',
        widget = 'button',
        onClick = function()
          if options and options.onOpenChildWindow then
            options.onOpenChildWindow(row, index)
          end
        end,
      }
    }
  end,

  getDefaultParams = function()
    return QuantizeUI.defaultParams()
  end,
}

TypeRegistry.register(typeDef)

return QuantizeType
