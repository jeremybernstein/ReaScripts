-- @description Smarter Zoom
-- @author sockmonkey72
-- @version 1.05
-- @changelog
--  * ensure that the option "SWS/NF: Toggle obey track height lock in vertical zoom and track height actions" is enabled when running this script.
-- @about Zoom and scroll to razor edit region, item selection or time selection. Requires JS and SWS extensions

local r = reaper

local doRE = false
local doItems = false
local doTimeSel = false

local trackview = r.JS_Window_FindChildByID(r.GetMainHwnd(), 1000)
local _, arrange_width, arrange_height = r.JS_Window_GetClientSize(trackview)

local trackCount = r.CountTracks(0)
local firstTrack = -1
local lastTrack = -1

local REtracks = {}

local minTime = tonumber(0xFFFFFFFFF) -- whatever, something big
local maxTime = tonumber(0)

local bufferscale = 0.15 -- might need to increase this on other platforms

for i = 0, trackCount-1 do
  local track = r.GetTrack(0, i)
  if track and r.IsTrackVisible(track, false) then
    local rv, razorEdits = r.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
    if rv == true and razorEdits ~= "" then
      if firstTrack == -1 then firstTrack = i
      else lastTrack = i end

      REtracks[#REtracks + 1] = track

      local count = 0
      for str in string.gmatch(razorEdits, "([^%s]+)") do
        if count % 3 == 0 then
          local value = tonumber(str)
          if value < minTime then
            minTime = value
          end
        elseif count % 3 == 1 then
          local value = tonumber(str)
          if value > maxTime then
            maxTime = value
          end
        end
        count = count + 1
      end
    end
  end
end

if #REtracks ~= 0 then doRE = true end

if doRE == false then
  local numSelectedItems = r.CountSelectedMediaItems(0)
  if numSelectedItems > 0 then doItems = true
  else
    minTime, maxTime = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    doTimeSel = minTime ~= maxTime and true or false
  end
end

if doRE == true or doItems == true  or doTimeSel == true then
  local swsTrackHeightLockEnabled = r.GetToggleCommandStateEx(0, r.NamedCommandLookup("_NF_TOGGLE_OBEY_TRACK_HEIGHT_LOCK"))

  r.Undo_BeginBlock2(0)

  if swsTrackHeightLockEnabled == 0 then
    r.Main_OnCommandEx(r.NamedCommandLookup("_NF_TOGGLE_OBEY_TRACK_HEIGHT_LOCK"), 0, 0) -- turn it on temporarily
  end

  if doRE == true then
    r.PreventUIRefresh(1)
    local selectedTracks = {}
    local selCount = r.CountSelectedTracks(0)
    for i = 0, selCount - 1 do
      selectedTracks[#selectedTracks + 1] = r.GetSelectedTrack(0, i)
    end

    r.Main_OnCommandEx(40297, 0, 0) -- Track: Unselect (clear selection of) all tracks

    for _, track in pairs(REtracks) do
      if track then r.SetTrackSelected(track, true) end
    end

    r.PreventUIRefresh(-1)

    r.Main_OnCommandEx(40913, 0, 0) -- Track: Vertical scroll selected tracks into view
    r.Main_OnCommandEx(r.NamedCommandLookup("_SWS_VZOOMFITMIN"), 0, 0) -- SWS: Vertical zoom to selected tracks, minimize others

    local buffer = (maxTime - minTime) * bufferscale -- might need to increase this on other platforms
    r.GetSet_ArrangeView2(0, true, 0, 0, minTime - buffer, maxTime + buffer)

    r.PreventUIRefresh(1)

    r.Main_OnCommandEx(40297, 0, 0) -- Track: Unselect (clear selection of) all tracks

    for _, track in pairs(selectedTracks) do
      r.SetTrackSelected(track, true)
    end
    r.PreventUIRefresh(-1)
  elseif doItems == true then
    r.Main_OnCommandEx(r.NamedCommandLookup("_SWS_ITEMZOOMMIN"), 0, 0) -- SWS: Vertical zoom to selected items, minimize others
  elseif doTimeSel == true then
    local buffer = (maxTime - minTime) * bufferscale
    r.GetSet_ArrangeView2(0, true, 0, 0, minTime - buffer, maxTime + buffer)
  end

  if swsTrackHeightLockEnabled == 0 then
    r.Main_OnCommandEx(r.NamedCommandLookup("_NF_TOGGLE_OBEY_TRACK_HEIGHT_LOCK"), 0, 0) -- turn it back off
  end

  r.Undo_EndBlock2(0, "Smarter Zoom: " .. (doRE and "Razor Edit" or doItems and "Items" or doTimeSel and "Time Selection" or "(no-op)"), -1)

  r.UpdateTimeline()
end
