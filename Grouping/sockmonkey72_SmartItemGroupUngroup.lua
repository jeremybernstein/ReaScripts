-- @description Smart item group/ungroup
-- @author sockmonkey72
-- @version 1.2
-- @changelog
--   * When updating a group, don't change the group index (thanks X-Raym for noticing)
-- @about
--   # Smart item group/ungroup
--   Thanks to daxliniere for the following specification:
--   * I select 3 ungrouped items and run the action - those items form a unique group.
--   * If I run the action again those 3 are no longer part of any group.
--   * If I select 3 items, some of which are part of a group and some ungrouped, the ungrouped items should be placed into the existing group.
--   * If I select 3 items, some of which are part of one group and some another group, the grouping should be removed.

local r = reaper

local function allSelectedItemsAreInTheSameGroup()
  local count = r.CountSelectedMediaItems(0)
  local grpid
  local sawzero = false
  local samegroup = true

  for i = 0, count - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    if item then
      local itemid = r.GetMediaItemInfo_Value(item, "I_GROUPID")
      if itemid ~= 0 then
        if grpid == nil then
          grpid = itemid
        elseif itemid ~= grpid then
          samegroup = false
        end
      else
        sawzero = true
      end
    end
  end

  if sawzero == false then
    return 1, nil -- everything is in a group: 1 (ungroup)
  elseif samegroup == true then
    return 0, grpid -- something is unselected, but everything else is in the same group
  else
    return -1, nil -- some mix of unselected and different groups: -1 (create new group)
  end
end

local function removeItemsFromAllGroups()
  r.Main_OnCommandEx(40033, 0) -- Ungroup native command
end

local function updateGroupFromSelection(grpid)
  local count = r.CountSelectedMediaItems(0)
  for i = 0, count - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    if item then
      r.SetMediaItemInfo_Value(item, "I_GROUPID", grpid)
    end
  end
end

local function createGroupFromSelection()
  r.Main_OnCommandEx(40033, 0) -- Ungroup native command
  r.Main_OnCommandEx(40032, 0) -- Group native command
end

-----------------------------------------------------------
-----------------------------------------------------------

if r.CountSelectedMediaItems(0) > 0 then

  r.PreventUIRefresh(1)

  local undoDescription
  r.Undo_BeginBlock2(0)

  local status, grpid = allSelectedItemsAreInTheSameGroup()
  if status == 1 then
    removeItemsFromAllGroups()
    undoDescription = "Remove Items From Group"
  elseif status == 0 and grpid then
    updateGroupFromSelection(grpid)
    undoDescription = "Update Item Group"
  else
    createGroupFromSelection()
    undoDescription = "Create Item Group"
  end

  r.Undo_EndBlock2(0, undoDescription, -1)
  r.UpdateArrange()
  r.PreventUIRefresh(-1)

end
