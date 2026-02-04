--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local QuantizeUI = {}

local tg = require 'TransformerGlobal'

-- groove helpers must be passed via options.grooveHelpers:
--   enumerateGrooveFiles(path, pattern, displayPattern)
--   parseGrooveFile(filepath)
--   parseMIDIGroove(filepath, opts)

-- grid division labels (shared constant) - last item uses MIDI editor grid
QuantizeUI.gridDivLabels = {'1/128', '1/64', '1/32', '1/16', '1/8', '1/4', '1/2', '1/1', '2/1', '4/1', 'grid'}
-- subdivision values for grid divisions (fraction of whole note, -1 = use REAPER grid)
QuantizeUI.gridDivSubdivs = {0.0078125, 0.015625, 0.03125, 0.0625, 0.125, 0.25, 0.5, 1.0, 2.0, 4.0, -1}
QuantizeUI.gridStyleLabels = {'straight', 'triplet', 'dotted', 'swing'}
QuantizeUI.targetLabels = {'Position only', 'Position + note end', 'Position + note length', 'Note end only', 'Note length only'}
QuantizeUI.distanceModeLabels = {'Off', 'Multiply', 'Inverse'}

-- default params factory
function QuantizeUI.defaultParams()
  return {
    scopeIndex = 1,        -- 0=notes all, 1=notes selected, 2=all events all, 3=all events selected
    targetIndex = 0,       -- position, pos+end, pos+length, end, length
    strength = 100,
    gridMode = 0,          -- 0=REAPER grid, 1=manual, 2=groove
    gridDivIndex = 10,     -- 'grid' (use MIDI editor grid) default
    gridStyleIndex = 0,    -- straight
    lengthGridDivIndex = 10,  -- 'grid' (use MIDI editor grid) default
    swingStrength = 66,
    fixOverlaps = false,
    canMoveLeft = true,
    canMoveRight = true,
    canShrink = true,
    canGrow = true,
    rangeFilterEnabled = false,
    rangeMin = 0.0,
    rangeMax = 100.0,
    distanceScaling = false,
    distanceMode = 0,      -- 0=off, 1=multiply, 2=inverse
    grooveFilePath = nil,
    grooveDirection = 0,
    grooveVelStrength = 0,
    grooveToleranceMin = 0.0,
    grooveToleranceMax = 100.0,
    midiThreshold = 10,
    midiThresholdMode = 1,  -- 0=ticks, 1=ms, 2=percent
    midiCoalesceMode = 0,   -- 0=first, 1=loudest
  }
end

--- render the Quantize UI into ctx, mutating params table
--- returns (changed, deactivated) - changed if any value changed, deactivated if input field lost focus
function QuantizeUI.render(ctx, ImGui, params, options)
  options = options or {}
  local changed = false
  local deactivated = false
  local itemWidth = options.itemWidth or 150
  local labelWidth = options.labelWidth  -- optional label alignment width

  -- cache full content width once at start (for inline mode calculations)
  local fullAvailWidth = ImGui.GetContentRegionAvail(ctx)

  -- scope section (skip in Transformer - already handled by find rows)
  if not options.hideScope then
    if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
    ImGui.Text(ctx, 'Scope')
    if labelWidth then
      ImGui.SameLine(ctx, labelWidth)
    end
    ImGui.SetNextItemWidth(ctx, itemWidth)
    local scopeLabels = {'Notes (All)', 'Notes (Selected)', 'All Events (All)', 'All Events (Selected)'}
    local rv, val = ImGui.Combo(ctx, '##scope', params.scopeIndex, table.concat(scopeLabels, '\0') .. '\0')
    if rv then
      params.scopeIndex = val
      changed = true
      if options.onScopeChanged then options.onScopeChanged(val) end
    end
    ImGui.Dummy(ctx, 0, 2)
  end

  -- settings/target section - can be inline (same row) or separate
  local gridLabel = options.gridLabel or 'Grid'
  local gridModeLabels = {'REAPER Grid', 'Manual', 'Groove'}
  local useAvailWidth = options.inlineSettingsTarget  -- use available width in inline mode

  if options.inlineSettingsTarget then
    -- inline mode: Settings combo + Target combo on same row, no labels
    local comboWidth = math.floor((fullAvailWidth - 8) / 2)  -- split with gap
    ImGui.SetNextItemWidth(ctx, comboWidth)
    rv, val = ImGui.Combo(ctx, '##gridMode', params.gridMode, table.concat(gridModeLabels, '\0') .. '\0')
    if rv then
      params.gridMode = val
      changed = true
      if options.onGridModeChanged then options.onGridModeChanged(val) end
    end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, comboWidth)
    rv, val = ImGui.Combo(ctx, '##target', params.targetIndex, table.concat(QuantizeUI.targetLabels, '\0') .. '\0')
    if rv then
      params.targetIndex = val
      changed = true
      if options.onTargetChanged then options.onTargetChanged(val) end
    end
    ImGui.Dummy(ctx, 0, 2)
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 2)
  else
    -- standard mode: separate rows with labels
    -- target section
    if not options.hideTarget then
      if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
      ImGui.Text(ctx, 'Target')
      if labelWidth then
        ImGui.SameLine(ctx, labelWidth)
      end
      ImGui.SetNextItemWidth(ctx, itemWidth)
      rv, val = ImGui.Combo(ctx, '##target', params.targetIndex, table.concat(QuantizeUI.targetLabels, '\0') .. '\0')
      if rv then
        params.targetIndex = val
        changed = true
        if options.onTargetChanged then options.onTargetChanged(val) end
      end
      ImGui.Dummy(ctx, 0, 2)
    end

    -- grid section (skip if host renders its own)
    if not options.hideGridMode then
      if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
      ImGui.Text(ctx, gridLabel)
      if labelWidth then
        ImGui.SameLine(ctx, labelWidth)
      end

      -- grid mode (REAPER/Manual/Groove)
      ImGui.SetNextItemWidth(ctx, itemWidth)
      rv, val = ImGui.Combo(ctx, '##gridMode', params.gridMode, table.concat(gridModeLabels, '\0') .. '\0')
      if rv then
        params.gridMode = val
        changed = true
        if options.onGridModeChanged then options.onGridModeChanged(val) end
      end
    end
  end

  -- manual grid settings (only when gridMode == 1)
  if params.gridMode == 1 then
    -- Grid row: label + [div][style] + Length: + [length div]
    if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
    ImGui.Text(ctx, 'Grid:')
    if labelWidth then
      ImGui.SameLine(ctx, labelWidth)
    else
      ImGui.SameLine(ctx)
    end
    -- calculate combo widths: in inline mode use available width, else fixed
    local gridComboW, styleComboW, lengthComboW
    if useAvailWidth then
      local availW = ImGui.GetContentRegionAvail(ctx)
      -- reserve space for "Length:" label (~50px) and gaps (~20px)
      local comboSpace = availW - 70
      gridComboW = math.floor(comboSpace * 0.33)
      styleComboW = math.floor(comboSpace * 0.33)
      lengthComboW = math.floor(comboSpace * 0.33)
    else
      gridComboW, styleComboW, lengthComboW = 69, 68, 69
    end
    ImGui.SetNextItemWidth(ctx, gridComboW)
    rv, val = ImGui.Combo(ctx, '##gridDiv', params.gridDivIndex, table.concat(QuantizeUI.gridDivLabels, '\0') .. '\0')
    if rv then
      params.gridDivIndex = val
      changed = true
      if options.onGridDivChanged then options.onGridDivChanged(val) end
    end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, styleComboW)
    rv, val = ImGui.Combo(ctx, '##gridStyle', params.gridStyleIndex, table.concat(QuantizeUI.gridStyleLabels, '\0') .. '\0')
    if rv then
      params.gridStyleIndex = val
      changed = true
      if options.onGridStyleChanged then options.onGridStyleChanged(val) end
    end
    -- Length combo on same row (disabled when not applicable)
    local lengthGridEnabled = params.targetIndex == 2 or params.targetIndex == 4
    ImGui.SameLine(ctx, 0, 15)
    ImGui.BeginDisabled(ctx, not lengthGridEnabled)
    ImGui.Text(ctx, 'Length:')
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, lengthComboW)
    rv, val = ImGui.Combo(ctx, '##lengthDiv', params.lengthGridDivIndex, table.concat(QuantizeUI.gridDivLabels, '\0') .. '\0')
    if rv then
      params.lengthGridDivIndex = val
      changed = true
      if options.onLengthGridChanged then options.onLengthGridChanged(val) end
    end
    ImGui.EndDisabled(ctx)
    ImGui.Dummy(ctx, 0, 2)

    -- Swing strength row (only in Manual mode)
    local showSwing = params.gridStyleIndex == 3
    if showSwing then
      if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
      ImGui.Text(ctx, 'Swing strength:')
      local swingLabelWidth = labelWidth and (labelWidth + 35) or 100
      ImGui.SameLine(ctx, swingLabelWidth)
      ImGui.SetNextItemWidth(ctx, 240)
      rv, val = ImGui.SliderInt(ctx, '##swing', params.swingStrength, 0, 100, '%d%%')
      if rv then
        params.swingStrength = val
        changed = true
        if options.onSwingStrengthChanged then options.onSwingStrengthChanged(val) end
      end
    else
      -- dummy for stable height when non-swing style
      ImGui.Dummy(ctx, 0, ImGui.GetFrameHeight(ctx))
    end
    ImGui.Dummy(ctx, 0, 2)
  end

  -- groove settings section (visible when gridMode == 2)
  if params.gridMode == 2 then
    local r = options.r or require('reaper')
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 2)
    ImGui.Text(ctx, 'Groove Settings')
    ImGui.Dummy(ctx, 0, 2)

    -- groove file picker
    if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
    ImGui.Text(ctx, 'Groove:')
    if labelWidth then
      ImGui.SameLine(ctx, labelWidth)
    else
      ImGui.SameLine(ctx)
    end

    local grooveDisplay = '(none)'
    if params.grooveFilePath then
      grooveDisplay = params.grooveFilePath:match('([^/\\]+)$') or params.grooveFilePath
    end

    local grooveComboW = useAvailWidth and ImGui.GetContentRegionAvail(ctx) or 275
    ImGui.SetNextItemWidth(ctx, grooveComboW)
    if ImGui.BeginCombo(ctx, '##grooveCombo', grooveDisplay) then
      local browserState = options.grooveBrowserState or {}

      -- === RGT SUBMENU ===
      ImGui.SetNextWindowSizeConstraints(ctx, 150, 0, 300, 400)
      if ImGui.BeginMenu(ctx, 'RGT') then
        if ImGui.MenuItem(ctx, 'Set folder...') then
          tg.initCache() -- ensure cache populated (perf)
          local initPath = browserState.rgtRootPath or tg.cache.resourcePath .. '/Data/Grooves'
          local folder
          if r.APIExists('JS_Dialog_BrowseForFolder') then
            local retval, path = r.JS_Dialog_BrowseForFolder('Select RGT Groove Folder', initPath)
            if retval == 1 and path and path ~= '' then folder = path end
          else
            local retval, filepath = r.GetUserFileNameForRead(initPath, 'Select any .rgt file to set folder', '.rgt')
            if retval and filepath and filepath ~= '' then folder = filepath:match('(.+)[/\\][^/\\]+$') end
          end
          if folder then
            browserState.rgtRootPath = folder
            browserState.rgtSubPath = nil
            r.SetExtState('sockmonkey72_TransformerQuantize', 'rgtRootPath', folder, true)
            r.SetExtState('sockmonkey72_TransformerQuantize', 'rgtSubPath', '', true)
          end
        end

        if browserState.rgtRootPath then
          ImGui.Separator(ctx)
          if browserState.rgtSubPath then
            if ImGui.Selectable(ctx, '..', false, ImGui.SelectableFlags_DontClosePopups) then
              local parent = browserState.rgtSubPath:match('(.+)/[^/]+$')
              if parent and #parent >= #browserState.rgtRootPath then
                browserState.rgtSubPath = parent == browserState.rgtRootPath and nil or parent
              else
                browserState.rgtSubPath = nil
              end
              r.SetExtState('sockmonkey72_TransformerQuantize', 'rgtSubPath', browserState.rgtSubPath or '', true)
            end
          end

          local path = browserState.rgtSubPath or browserState.rgtRootPath
          local rgtContents = options.grooveHelpers.enumerateGrooveFiles(path, '%.rgt$', '%.rgt$')
          for _, entry in ipairs(rgtContents) do
            if entry.sub then
              local folderLabel = entry.label .. '/' .. (entry.count > 0 and ' (' .. entry.count .. ')' or '')
              if ImGui.Selectable(ctx, folderLabel, false, ImGui.SelectableFlags_DontClosePopups) then
                browserState.rgtSubPath = path .. '/' .. entry.label
                r.SetExtState('sockmonkey72_TransformerQuantize', 'rgtSubPath', browserState.rgtSubPath, true)
              end
            else
              local selected = params.grooveFilePath and params.grooveFilePath:match('([^/\\]+)$') == entry.filename
              if ImGui.MenuItem(ctx, entry.label, nil, selected) then
                local filepath = path .. '/' .. entry.filename
                local data = options.grooveHelpers.parseGrooveFile(filepath)
                if data then
                  params.grooveFilePath = filepath
                  params.grooveData = data
                  options.grooveErrorMessage = nil
                  changed = true
                  if options.onGrooveFileChanged then options.onGrooveFileChanged(filepath, data) end
                else
                  options.grooveErrorMessage = 'Could not load groove file'
                end
              end
            end
          end
          if #rgtContents == 0 then ImGui.TextDisabled(ctx, '(no .rgt files)') end
        else
          ImGui.Separator(ctx)
          ImGui.TextDisabled(ctx, '(folder not set)')
        end
        ImGui.EndMenu(ctx)
      end

      -- === MIDI SUBMENU ===
      ImGui.SetNextWindowSizeConstraints(ctx, 150, 0, 300, 400)
      if ImGui.BeginMenu(ctx, 'MIDI') then
        if ImGui.MenuItem(ctx, 'Set folder...') then
          tg.initCache() -- ensure cache populated (perf)
          local initPath = browserState.midiRootPath or tg.cache.resourcePath
          local folder
          if r.APIExists('JS_Dialog_BrowseForFolder') then
            local retval, path = r.JS_Dialog_BrowseForFolder('Select MIDI Groove Folder', initPath)
            if retval == 1 and path and path ~= '' then folder = path end
          else
            local retval, filepath = r.GetUserFileNameForRead(initPath, 'Select any MIDI file to set folder', '.mid')
            if retval and filepath and filepath ~= '' then folder = filepath:match('(.+)[/\\][^/\\]+$') end
          end
          if folder then
            browserState.midiRootPath = folder
            browserState.midiSubPath = nil
            r.SetExtState('sockmonkey72_TransformerQuantize', 'midiRootPath', folder, true)
            r.SetExtState('sockmonkey72_TransformerQuantize', 'midiSubPath', '', true)
          end
        end

        if browserState.midiRootPath then
          ImGui.Separator(ctx)
          if browserState.midiSubPath then
            if ImGui.Selectable(ctx, '..', false, ImGui.SelectableFlags_DontClosePopups) then
              local parent = browserState.midiSubPath:match('(.+)/[^/]+$')
              if parent and #parent >= #browserState.midiRootPath then
                browserState.midiSubPath = parent == browserState.midiRootPath and nil or parent
              else
                browserState.midiSubPath = nil
              end
              r.SetExtState('sockmonkey72_TransformerQuantize', 'midiSubPath', browserState.midiSubPath or '', true)
            end
          end

          local path = browserState.midiSubPath or browserState.midiRootPath
          local midiContents = options.grooveHelpers.enumerateGrooveFiles(path, '%.[mMsS][iImM][dDfF]$', '%.[mMsS][iImM][dDfF]$')
          for _, entry in ipairs(midiContents) do
            if entry.sub then
              local folderLabel = entry.label .. '/' .. (entry.count > 0 and ' (' .. entry.count .. ')' or '')
              if ImGui.Selectable(ctx, folderLabel, false, ImGui.SelectableFlags_DontClosePopups) then
                browserState.midiSubPath = path .. '/' .. entry.label
                r.SetExtState('sockmonkey72_TransformerQuantize', 'midiSubPath', browserState.midiSubPath, true)
              end
            else
              local selected = params.grooveFilePath and params.grooveFilePath:match('([^/\\]+)$') == entry.filename
              if ImGui.MenuItem(ctx, entry.label, nil, selected) then
                local filepath = path .. '/' .. entry.filename
                local data, err = options.grooveHelpers.parseMIDIGroove(filepath, {
                  threshold = params.midiThreshold,
                  thresholdMode = params.midiThresholdMode,
                  coalesceMode = params.midiCoalesceMode
                })
                if data then
                  params.grooveFilePath = filepath
                  params.grooveData = data
                  options.grooveErrorMessage = nil
                  changed = true
                  if options.onGrooveFileChanged then options.onGrooveFileChanged(filepath, data) end
                else
                  options.grooveErrorMessage = err or 'Could not load MIDI file'
                end
              end
            end
          end
          if #midiContents == 0 then ImGui.TextDisabled(ctx, '(no MIDI files)') end
        else
          ImGui.Separator(ctx)
          ImGui.TextDisabled(ctx, '(folder not set)')
        end
        ImGui.EndMenu(ctx)
      end

      ImGui.EndCombo(ctx)
    end

    -- inline error display
    if options.grooveErrorMessage then
      ImGui.TextColored(ctx, 0xFF4444FF, options.grooveErrorMessage)
    end

    -- direction + velocity strength
    ImGui.Dummy(ctx, 0, 2)
    if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
    ImGui.Text(ctx, 'Direction:')
    if labelWidth then
      ImGui.SameLine(ctx, labelWidth)
    else
      ImGui.SameLine(ctx)
    end
    -- calculate widths: direction combo fixed, vel slider fills remaining
    local dirComboW = useAvailWidth and math.floor(fullAvailWidth * 0.28) or 90
    ImGui.SetNextItemWidth(ctx, dirComboW)
    local dirItems = 'Both\0Early only\0Late only\0'
    rv, val = ImGui.Combo(ctx, '##grooveDir', params.grooveDirection, dirItems)
    if rv then
      params.grooveDirection = val
      changed = true
      if options.onGrooveDirectionChanged then options.onGrooveDirectionChanged(val) end
    end

    ImGui.SameLine(ctx)
    ImGui.Text(ctx, 'Vel Str:')
    ImGui.SameLine(ctx)
    -- vel slider fills remaining space
    local velSliderW = useAvailWidth and ImGui.GetContentRegionAvail(ctx) or 120
    ImGui.SetNextItemWidth(ctx, velSliderW)
    rv, val = ImGui.SliderInt(ctx, '##grooveVel', params.grooveVelStrength, 0, 100, '%d%%')
    if rv then
      params.grooveVelStrength = math.max(0, math.min(100, val))
      changed = true
      if options.onGrooveVelStrengthChanged then options.onGrooveVelStrengthChanged(params.grooveVelStrength) end
    end

    -- tolerance sliders
    ImGui.Dummy(ctx, 0, 2)
    if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
    ImGui.Text(ctx, 'Tolerance:')
    if labelWidth then
      ImGui.SameLine(ctx, labelWidth)
    else
      ImGui.SameLine(ctx)
    end
    -- calculate tolerance slider widths
    local tolSliderW
    if useAvailWidth then
      local availW = ImGui.GetContentRegionAvail(ctx)
      -- reserve space for "to" label (~20px) and gaps
      tolSliderW = math.floor((availW - 28) / 2)
    else
      tolSliderW = 125
    end
    ImGui.SetNextItemWidth(ctx, tolSliderW)
    local tolMin = params.grooveToleranceMin or 0.0
    local tolMax = params.grooveToleranceMax or 100.0
    rv, val = ImGui.SliderDouble(ctx, '##grooveTolMin', tolMin, 0.0, 100.0, '%.0f%%')
    if rv then
      params.grooveToleranceMin = val
      if params.grooveToleranceMin > (params.grooveToleranceMax or 100.0) then
        params.grooveToleranceMax = params.grooveToleranceMin
      end
      changed = true
      if options.onGrooveToleranceMinChanged then options.onGrooveToleranceMinChanged(val) end
    end

    ImGui.SameLine(ctx)
    ImGui.Text(ctx, 'to')
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, tolSliderW)
    rv, val = ImGui.SliderDouble(ctx, '##grooveTolMax', tolMax, 0.0, 100.0, '%.0f%%')
    if rv then
      params.grooveToleranceMax = val
      if params.grooveToleranceMax < (params.grooveToleranceMin or 0.0) then
        params.grooveToleranceMin = params.grooveToleranceMax
      end
      changed = true
      if options.onGrooveToleranceMaxChanged then options.onGrooveToleranceMaxChanged(val) end
    end

    -- MIDI extraction settings (only when MIDI file loaded)
    local ext = params.grooveFilePath and params.grooveFilePath:lower():match('%.([^%.]+)$')
    local isMidiGroove = ext == 'mid' or ext == 'smf' or ext == 'midi'
    if isMidiGroove then
      ImGui.Separator(ctx)
      ImGui.Dummy(ctx, 0, 2)
      ImGui.TextDisabled(ctx, 'MIDI Extraction')

      if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
      ImGui.Text(ctx, 'Coalesce:')
      if labelWidth then
        ImGui.SameLine(ctx, labelWidth)
      else
        ImGui.SameLine(ctx)
      end
      ImGui.SetNextItemWidth(ctx, 66)
      rv, val = ImGui.InputDouble(ctx, '##midiThreshold', params.midiThreshold, 0, 0, '%.1f')
      deactivated = deactivated or ImGui.IsItemDeactivated(ctx)
      if rv then
        params.midiThreshold = math.max(0, val)
        -- re-extract groove
        local data, err = options.grooveHelpers.parseMIDIGroove(params.grooveFilePath, {
          threshold = params.midiThreshold,
          thresholdMode = params.midiThresholdMode,
          coalesceMode = params.midiCoalesceMode
        })
        if data then params.grooveData = data end
        changed = true
        if options.onMidiThresholdChanged then options.onMidiThresholdChanged(params.midiThreshold) end
      end

      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 65)
      local threshModeItems = 'ticks\0ms\0%beat\0'
      rv, val = ImGui.Combo(ctx, '##midiThreshMode', params.midiThresholdMode, threshModeItems)
      if rv then
        params.midiThresholdMode = val
        local data, err = options.grooveHelpers.parseMIDIGroove(params.grooveFilePath, {
          threshold = params.midiThreshold,
          thresholdMode = params.midiThresholdMode,
          coalesceMode = params.midiCoalesceMode
        })
        if data then params.grooveData = data end
        changed = true
        if options.onMidiThresholdModeChanged then options.onMidiThresholdModeChanged(val) end
      end

      ImGui.SameLine(ctx, 0, 10)
      ImGui.Text(ctx, 'preferring')
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 66)
      local coalesceItems = 'first\0loudest\0'
      rv, val = ImGui.Combo(ctx, '##midiCoalesce', params.midiCoalesceMode, coalesceItems)
      if rv then
        params.midiCoalesceMode = val
        local data, err = options.grooveHelpers.parseMIDIGroove(params.grooveFilePath, {
          threshold = params.midiThreshold,
          thresholdMode = params.midiThresholdMode,
          coalesceMode = params.midiCoalesceMode
        })
        if data then params.grooveData = data end
        changed = true
        if options.onMidiCoalesceModeChanged then options.onMidiCoalesceModeChanged(val) end
      end
    end
  end

  ImGui.Dummy(ctx, 0, 2)

  -- strength slider
  if labelWidth then ImGui.AlignTextToFramePadding(ctx) end
  ImGui.Text(ctx, 'Strength')
  if labelWidth then
    ImGui.SameLine(ctx, labelWidth)
  end
  local strengthWidth = useAvailWidth and fullAvailWidth or itemWidth
  ImGui.SetNextItemWidth(ctx, strengthWidth)
  rv, val = ImGui.SliderInt(ctx, '##strength', params.strength, 0, 100, '%d%%')
  if rv then
    params.strength = val
    changed = true
    if options.onStrengthChanged then options.onStrengthChanged(val) end
  end

  ImGui.Dummy(ctx, 0, 2)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 2)

  -- direction constraints (disabled in groove mode - direction menu handles this)
  local isGrooveMode = params.gridMode == 2
  ImGui.BeginDisabled(ctx, isGrooveMode)
  ImGui.Text(ctx, 'Allow events to:')
  ImGui.Dummy(ctx, 0, 2)
  local cbSpacer = 16
  rv, val = ImGui.Checkbox(ctx, 'Move left', params.canMoveLeft)
  if rv then
    -- at least one of left/right must be selected
    if not val and not params.canMoveRight then
      params.canMoveRight = true
      if options.onCanMoveRightChanged then options.onCanMoveRightChanged(true) end
    end
    params.canMoveLeft = val
    changed = true
    if options.onCanMoveLeftChanged then options.onCanMoveLeftChanged(val) end
  end
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + cbSpacer)
  rv, val = ImGui.Checkbox(ctx, 'Move right', params.canMoveRight)
  if rv then
    -- at least one of left/right must be selected
    if not val and not params.canMoveLeft then
      params.canMoveLeft = true
      if options.onCanMoveLeftChanged then options.onCanMoveLeftChanged(true) end
    end
    params.canMoveRight = val
    changed = true
    if options.onCanMoveRightChanged then options.onCanMoveRightChanged(val) end
  end
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + cbSpacer)
  rv, val = ImGui.Checkbox(ctx, 'Shrink', params.canShrink)
  if rv then
    -- at least one of shrink/grow must be selected
    if not val and not params.canGrow then
      params.canGrow = true
      if options.onCanGrowChanged then options.onCanGrowChanged(true) end
    end
    params.canShrink = val
    changed = true
    if options.onCanShrinkChanged then options.onCanShrinkChanged(val) end
  end
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + cbSpacer)
  rv, val = ImGui.Checkbox(ctx, 'Grow', params.canGrow)
  if rv then
    -- at least one of shrink/grow must be selected
    if not val and not params.canShrink then
      params.canShrink = true
      if options.onCanShrinkChanged then options.onCanShrinkChanged(true) end
    end
    params.canGrow = val
    changed = true
    if options.onCanGrowChanged then options.onCanGrowChanged(val) end
  end
  ImGui.EndDisabled(ctx)

  ImGui.Dummy(ctx, 0, 2)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 2)

  -- range filter section
  rv, val = ImGui.Checkbox(ctx, 'Only quantize range:', params.rangeFilterEnabled)
  if rv then
    params.rangeFilterEnabled = val
    changed = true
    if options.onRangeFilterEnabledChanged then options.onRangeFilterEnabledChanged(val) end
  end
  ImGui.BeginDisabled(ctx, not params.rangeFilterEnabled)
  local availW = ImGui.GetContentRegionAvail(ctx) - 10
  local sliderW = (availW - 20) / 2
  ImGui.PushItemWidth(ctx, sliderW)
  rv, val = ImGui.SliderDouble(ctx, '##rangeMin', params.rangeMin, 0.0, 100.0, '%.1f%%')
  if rv then
    params.rangeMin = val
    changed = true
    if options.onRangeMinChanged then options.onRangeMinChanged(val) end
  end
  ImGui.PopItemWidth(ctx)
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, 'to')
  ImGui.SameLine(ctx)
  ImGui.PushItemWidth(ctx, sliderW)
  rv, val = ImGui.SliderDouble(ctx, '##rangeMax', params.rangeMax, 0.0, 100.0, '%.1f%%')
  if rv then
    params.rangeMax = val
    changed = true
    if options.onRangeMaxChanged then options.onRangeMaxChanged(val) end
  end
  ImGui.PopItemWidth(ctx)
  -- distance scaling (inside range filter section)
  rv, val = ImGui.Checkbox(ctx, 'Scale strength by distance', params.distanceScaling)
  if rv then
    params.distanceScaling = val
    changed = true
    if options.onDistanceScalingChanged then options.onDistanceScalingChanged(val) end
  end
  ImGui.EndDisabled(ctx)

  ImGui.Dummy(ctx, 0, 2)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 2)

  -- fix overlaps option
  rv, val = ImGui.Checkbox(ctx, 'Fix overlaps', params.fixOverlaps)
  if rv then
    params.fixOverlaps = val
    changed = true
    if options.onFixOverlapsChanged then options.onFixOverlapsChanged(val) end
  end

  -- invoke generic callback if any change occurred
  if changed and options.onChanged then
    options.onChanged()
  end

  return changed, deactivated
end

return QuantizeUI
