-- @description Smart item group/ungroup
-- @author sockmonkey72
-- @version 1.0
-- @changelog 1.0 initial upload
-- @about
--   # Smart item group/ungroup
--   Thanks to daxliniere for the following specification:
--   * I select 3 ungrouped items and run the action - those items form a unique group.
--   * If I run the action again those 3 are no longer part of any group.
--   * If I select 3 items, some of which are part of a group and some ungrouped, the ungrouped items should be placed into the existing group.
--   * If I select 3 items, some of which are part of one group and some another group, the grouping should be removed.

function allSelectedItemsAreInTheSameGroup()
  local count = reaper.CountSelectedMediaItems(0)
  local grpid
  local sawzero = false
  local samegroup = true

  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    if item then
      local itemid = reaper.GetMediaItemInfo_Value(item, "I_GROUPID")
      if grpid == nil then
        grpid = itemid
      elseif itemid ~= grpid then
        samegroup = false
      end
      if itemid == 0 then sawzero = true end
    end
  end

  if sawzero == false then
    return 1 -- everything is in a group: 1 (ungroup)
  elseif samegroup == false then
    return 0 -- something is unselected: 0 (update group)
  else
    return -1 -- nothing is grouped: -1 (create new group)
  end
end

function removeItemsFromAllGroups()
  reaper.Main_OnCommandEx(40033, 0) -- Ungroup native command
end

function createGroupFromSelection()
  reaper.Main_OnCommandEx(40033, 0) -- Ungroup native command
  reaper.Main_OnCommandEx(40032, 0) -- Group native command
end

-----------------------------------------------------------
-----------------------------------------------------------

if reaper.CountSelectedMediaItems(0) > 0 then

  reaper.PreventUIRefresh(1)

  local undoDescription
  reaper.Undo_BeginBlock2(0)

  status = allSelectedItemsAreInTheSameGroup()
  if status == 1 then
    removeItemsFromAllGroups()
    undoDescription = "Remove Items From Group"
  else
    createGroupFromSelection()
    undoDescription = status == 0 and "Update Item Group" or "Create Item Group"
  end

  reaper.Undo_EndBlock2(0, undoDescription, -1)
  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)

end
