--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  Mode Interface Contract

  All mode modules (Slicer, PitchBend, etc.) should implement these methods:

  Required:
    isActive()                        -> bool: whether mode is currently active
    enter()                           -> void: called when mode activates
    exit()                            -> void: called when mode deactivates
    processInput(mx, my, mouseState)  -> handled, undoText: mouse input handling
    render(ctx)                       -> void: draw mode overlay (ctx has hwnd, mode, antialias)

  Optional:
    handleKey(vState, mods)           -> handled: keyboard input (return true if consumed)
    handleState(scriptID)             -> void: load preferences from ExtState
    shutdown(destroyBitmap)           -> void: cleanup resources

  Mode modules export these via their return table.
  The mode registry in Lib.lua iterates active modes for dispatch.
]]

local Mode = {}

-- validate that a module implements required mode interface
function Mode.validate(module, name)
  local required = { 'isActive', 'enter', 'exit', 'processInput', 'render' }
  local missing = {}
  for _, method in ipairs(required) do
    if type(module[method]) ~= 'function' then
      table.insert(missing, method)
    end
  end
  if #missing > 0 then
    error(string.format('Mode "%s" missing required methods: %s', name, table.concat(missing, ', ')))
  end
  return true
end

-- create a mode registry
function Mode.createRegistry()
  return {
    modes = {},

    register = function(self, name, module)
      Mode.validate(module, name)
      self.modes[name] = module
    end,

    getActive = function(self)
      for name, mode in pairs(self.modes) do
        if mode.isActive() then
          return mode, name
        end
      end
      return nil
    end,

    -- call method on active mode if it exists
    dispatch = function(self, method, ...)
      local mode = self:getActive()
      if mode and type(mode[method]) == 'function' then
        return mode[method](...)
      end
      return nil
    end,

    -- call method on all modes
    broadcast = function(self, method, ...)
      for _, mode in pairs(self.modes) do
        if type(mode[method]) == 'function' then
          mode[method](...)
        end
      end
    end,
  }
end

return Mode
