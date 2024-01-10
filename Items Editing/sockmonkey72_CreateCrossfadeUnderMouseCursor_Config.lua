--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

-- use imgui if available
dofile(r.GetResourcePath() .. '/Scripts/ReaTeam Extensions/API/imgui.lua')('0.8')

local some_tiny_amount = 0.0001 -- needed to prev_ent edge overlap

local _, cfgval = r.get_config_var_string('defsplitxfadelen')
local globaldef = tonumber(cfgval) or 0.01

if r.ImGui_CreateContext then
  local ctx = r.ImGui_CreateContext('Create Crossfade Under Mouse (Config)') -- prevent docking
  local sans_serif = r.ImGui_CreateFont('sans-serif', 15)
  local sans_serif_13 = r.ImGui_CreateFont('sans-serif', 13)
  r.ImGui_Attach(ctx, sans_serif)
  r.ImGui_Attach(ctx, sans_serif_13)

  local grid = tonumber(r.GetExtState('sm72_CreateCrossfade', 'GridWidth'))
  if grid and grid == 0 then grid = nil end
  local time = tonumber(r.GetExtState('sm72_CreateCrossfade', 'TimeWidth'))
  if time and time == 0 then time = nil end
  local just = tonumber(r.GetExtState('sm72_CreateCrossfade', 'Justification'))
  local exts = tonumber(r.GetExtState('sm72_CreateCrossfade', 'IgnoreExtents'))

  local function fixGridAndTime()
    if grid and grid < some_tiny_amount then grid = some_tiny_amount end
    if time and time < some_tiny_amount then time = some_tiny_amount end

    if not just then just = -1 end
    just = just < 0 and -1 or just > 0 and 1 or 0

    if not exts then exts = 0 end
    exts = exts ~= 0 and 1 or 0
  end

  fixGridAndTime()

  local cursel = ((grid and grid ~= 0) and 1) or (((time and time ~= 0) and 2) or 0)

  local justclosed = false
  local escwait

  local focuswait
  local wantsRecede = tonumber(r.GetExtState('sm72_CreateCrossfade', 'ConfigWantsRecede'))
  wantsRecede = (not wantsRecede or wantsRecede ~= 0) and 1 or 0

  local function reFocus()
    focuswait = 5
  end

  local function loop()

    -- tortured wait code to prevent closing a menu from closing the entire script
    if not r.ImGui_IsPopupOpen(ctx, '', r.ImGui_PopupFlags_AnyPopup()) then
      if r.ImGui_IsKeyDown(ctx, r.ImGui_Key_Escape()) then
        if justclosed then escwait = 5
        elseif not escwait then escwait = 1
        end
        if escwait then
          escwait = escwait - 1
          if escwait == 0 then
            r.ImGui_DestroyContext(ctx)
            return
          end
        end
      else
        escwait = nil
      end
      justclosed = false
    end

    if wantsRecede ~= 0 and focuswait then
      focuswait = focuswait - 1
      if focuswait == 0 then
        r.SetCursorContext(0, nil)
        focuswait = nil
      end
    end

    r.ImGui_PushFont(ctx, sans_serif_13)

    r.ImGui_SetNextWindowSize(ctx, 350, 120, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, 'Create Crossfade Under Mouse (Config)', true, r.ImGui_WindowFlags_TopMost() | r.ImGui_WindowFlags_AlwaysAutoResize())
    if visible then
      local rv, val
      local button1Label = cursel == 2 and 'Absolute Time' or cursel == 1 and 'Grid Percentage' or 'Global Default'

      r.ImGui_PushFont(ctx, sans_serif)

      if r.ImGui_BeginPopup(ctx, 'gridtimemenu') then
        if r.ImGui_IsKeyDown(ctx, r.ImGui_Key_Escape()) then
          r.ImGui_CloseCurrentPopup(ctx)
          justclosed = true
        end

        rv, val = r.ImGui_Selectable(ctx, 'Global Default', cursel == 0)
        if rv and val then
          cursel = 0
          r.DeleteExtState('sm72_CreateCrossfade', 'GridWidth', true)
          r.DeleteExtState('sm72_CreateCrossfade', 'TimeWidth', true)
          reFocus()
        end

        rv, val = r.ImGui_Selectable(ctx, 'Grid Percentage', cursel == 1)
        if rv and val then
          cursel = 1
          if not grid or grid == 0 then grid = 0.5 end
          r.SetExtState('sm72_CreateCrossfade', 'GridWidth', tostring(grid), true)
          r.SetExtState('sm72_CreateCrossfade', 'TimeWidth', '0', true)
          reFocus()
        end

        rv, val = r.ImGui_Selectable(ctx, 'Absolute Time', cursel == 2)
        if rv and val then
          if not time or time == 0 then time = some_tiny_amount end
          cursel = 2
          r.SetExtState('sm72_CreateCrossfade', 'TimeWidth', tostring(time), true)
          r.SetExtState('sm72_CreateCrossfade', 'GridWidth', '0', true)
          reFocus()
        end

        r.ImGui_EndPopup(ctx)
      end

      r.ImGui_Spacing(ctx)

      r.ImGui_BeginGroup(ctx)
      r.ImGui_AlignTextToFramePadding(ctx)
      r.ImGui_Text(ctx, 'Time: ')
      r.ImGui_SameLine(ctx)

      rv, val = r.ImGui_Button(ctx, button1Label)
      if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
        r.ImGui_OpenPopup(ctx, 'gridtimemenu')
      end

      r.ImGui_SameLine(ctx)

      if cursel > 0 then
        if not grid then grid = 0.5 end
        if not time then time = 0 end
        fixGridAndTime()

        r.ImGui_SetNextItemWidth(ctx, 100)
        rv, val = r.ImGui_InputDouble(ctx, '##val', cursel == 1 and (grid * 100) or time, nil, nil, '%0.6g')
        if rv and val then
          if cursel == 1 then
            grid = val / 100.
            r.SetExtState('sm72_CreateCrossfade', 'GridWidth', tostring(grid), true)
            r.SetExtState('sm72_CreateCrossfade', 'TimeWidth', '0', true)
          else
            time = val
            r.SetExtState('sm72_CreateCrossfade', 'TimeWidth', tostring(time), true)
            r.SetExtState('sm72_CreateCrossfade', 'GridWidth', '0', true)
          end
          reFocus()
        end
      else
        r.ImGui_Text(ctx, tostring(globaldef))
      end

      r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, cursel == 1 and '%' or 'sec.')
      r.ImGui_EndGroup(ctx)

      if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, 'Set the length of the crossfade.')
      end

      if r.ImGui_BeginPopup(ctx, 'justmenu') then
        if r.ImGui_IsKeyDown(ctx, r.ImGui_Key_Escape()) then
          r.ImGui_CloseCurrentPopup(ctx)
          justclosed = true
        end

        rv, val = r.ImGui_Selectable(ctx, 'Left', just < 0)
        if rv and val then
          just = -1
          r.SetExtState('sm72_CreateCrossfade', 'Justification', tostring(just), true)
          reFocus()
        end

        rv, val = r.ImGui_Selectable(ctx, 'Centered', just == 0)
        if rv and val then
          just = 0
          r.SetExtState('sm72_CreateCrossfade', 'Justification', tostring(just), true)
          reFocus()
        end

        rv, val = r.ImGui_Selectable(ctx, 'Right', just > 0)
        if rv and val then
          just = 1
          r.SetExtState('sm72_CreateCrossfade', 'Justification', tostring(just), true)
          reFocus()
        end

        r.ImGui_EndPopup(ctx)
      end

      r.ImGui_Spacing(ctx)

      r.ImGui_BeginGroup(ctx)
      r.ImGui_AlignTextToFramePadding(ctx)
      r.ImGui_Text(ctx, 'Alignment: ')
      r.ImGui_SameLine(ctx)

      local button2Label = (just < 0 and 'Left') or (just > 0 and 'Right') or 'Centered'
      rv, val = r.ImGui_Button(ctx, button2Label)
      if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
        r.ImGui_OpenPopup(ctx, 'justmenu')
      end
      r.ImGui_EndGroup(ctx)

      if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, 'Set the alignment of the crossfade relative to the split point.')
      end

      r.ImGui_Spacing(ctx)

      r.ImGui_BeginGroup(ctx)
      r.ImGui_AlignTextToFramePadding(ctx)
      r.ImGui_Text(ctx, 'Ignore Extents: ')
      r.ImGui_SameLine(ctx)

      rv, val = r.ImGui_Checkbox(ctx, '##extents', exts ~= 0 and true or false)
      if rv then
        exts = val and 1 or 0
        r.SetExtState('sm72_CreateCrossfade', 'IgnoreExtents', tostring(exts), true)
        reFocus()
      end
      r.ImGui_EndGroup(ctx)

      if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_BeginTooltip(ctx)
        r.ImGui_Text(ctx, 'Ignore time selection or razor edit when determining')
        r.ImGui_Text(ctx, 'crossfade length (using settings above). Otherwise,')
        r.ImGui_Text(ctx, 'use the length of the extent for the crossfade.')
        r.ImGui_EndTooltip(ctx)
      end

      r.ImGui_SameLine(ctx)

      r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + 20)

      r.ImGui_BeginGroup(ctx)
      r.ImGui_AlignTextToFramePadding(ctx)
      r.ImGui_Text(ctx, 'Auto-Unfocus: ')
      r.ImGui_SameLine(ctx)

      rv, val = r.ImGui_Checkbox(ctx, '##recede', wantsRecede ~= 0 and true or false)
      if rv then
        wantsRecede = val and 1 or 0
        r.SetExtState('sm72_CreateCrossfade', 'ConfigWantsRecede', tostring(wantsRecede), true)
        reFocus()
      end
      r.ImGui_EndGroup(ctx)

      if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_SetTooltip(ctx, 'Automatically refocus the arrange view after making changes.')
      end

      r.ImGui_PopFont(ctx)

      r.ImGui_End(ctx)
    end

    r.ImGui_PopFont(ctx)

    if open then
      r.defer(loop)
    end
  end

  r.defer(loop)

else

  local grid = r.GetExtState('sm72_CreateCrossfade', 'GridWidth')
  local time = r.GetExtState('sm72_CreateCrossfade', 'TimeWidth')
  local just = r.GetExtState('sm72_CreateCrossfade', 'Justification')
  local exts = r.GetExtState('sm72_CreateCrossfade', 'IgnoreExtents')
  local in_csv = '0.5,0'

  grid = tonumber(grid)
  if grid and grid ~= 0 then
    in_csv = grid..',0'
  else
    time = tonumber(time)
    if time then
      in_csv = '0,'..time
    end
  end
  just = tonumber(just)
  if not just then just = -1 end
  just = just < 0 and -1 or just > 0 and 1 or 0
  in_csv = in_csv..','..just

  exts = tonumber(exts)
  if not exts then exts = 0 end
  exts = exts ~= 0 and 1 or 0
  in_csv = in_csv..','..exts

  local retval, out_csv = r.GetUserInputs('Configure "Create crossfade"', 4, 'Grid Scale: 0=ignore,Time (sec): 0=ignore,Justification: -1/0/1,Ignore Extents (timesel, RE): 0/1', in_csv)
  if retval then
    grid, time, just, exts = out_csv:match('([^,]+),([^,]+),([^,]+),([^,]+)')

    grid = tonumber(grid)
    if grid and grid ~= 0 then
      r.SetExtState('sm72_CreateCrossfade', 'GridWidth', tostring(grid), true)
      r.SetExtState('sm72_CreateCrossfade', 'TimeWidth', '0', true)
    else
      time = tonumber(time)
      if time then
        r.SetExtState('sm72_CreateCrossfade', 'TimeWidth', tostring(time), true)
        r.SetExtState('sm72_CreateCrossfade', 'GridWidth', '0', true)
      else
        r.DeleteExtState('sm72_CreateCrossfade', 'GridWidth', true)
        r.DeleteExtState('sm72_CreateCrossfade', 'TimeWidth', true)
      end
    end
    just = tonumber(just)
    if not just then just = -1 end
    just = just < 0 and -1 or just > 0 and 1 or 0
    r.SetExtState('sm72_CreateCrossfade', 'Justification', tostring(just), true)
    exts = tonumber(exts)
    if not exts then exts = 0 end
    exts = exts ~= 0 and 1 or 0
    r.SetExtState('sm72_CreateCrossfade', 'IgnoreExtents', tostring(exts), true)

  end
end
