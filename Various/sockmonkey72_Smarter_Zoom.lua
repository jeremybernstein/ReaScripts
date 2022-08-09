-- @description Smarter Zoom
-- @author sockmonkey72
-- @version 1.03
-- @changelog 1.03 initial upload
-- @about Zoom and scroll to razor edit region, item selection or time selection. Requires JS and SWS extensions

local reaper = reaper

local doRE = false
local doItems = false
local doTimeSel = false

local trackview = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
local _, arrange_width, arrange_height = reaper.JS_Window_GetClientSize(trackview)

local trackCount = reaper.CountTracks(0)
local firstTrack = -1
local lastTrack = -1

local REtracks = {}

 minTime = 0xFFFFFFFFF -- whatever, something big
 maxTime = 0

for i = 0, trackCount-1 do
  local track = reaper.GetTrack(0, i)
  if track and reaper.IsTrackVisible(track, false) then
    local rv, razorEdits = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
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
  numSelectedItems = reaper.CountSelectedMediaItems(0)
  if numSelectedItems > 0 then doItems = true
  else
    minTime, maxTime = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    doTimeSel = minTime ~= maxTime and true or false
  end
end

if doRE == true or doItems == true  or doTimeSel == true then
  reaper.PreventUIRefresh(1)

  reaper.Undo_BeginBlock2(0)

  if doRE == true then
    local selectedTracks = {}
    local selCount = reaper.CountSelectedTracks(0)
    for i = 0, selCount - 1 do
      selectedTracks[#selectedTracks + 1] = reaper.GetSelectedTrack(0, i)
    end

    reaper.Main_OnCommandEx(40297, 0, 0) -- unselect all tracks

    for _, track in pairs(REtracks) do
      if track then reaper.SetTrackSelected(track, true) end
    end

    reaper.PreventUIRefresh(-1)

    reaper.Main_OnCommandEx(40913, 0, 0)
    reaper.Main_OnCommandEx(reaper.NamedCommandLookup("_SWS_VZOOMFIT"), 0, 0) -- vert zoom to selected tracks

    local buffer = (maxTime - minTime) * 0.01
    reaper.GetSet_ArrangeView2(0, true, 0, 0, minTime - buffer, maxTime + 2 * buffer)

    reaper.PreventUIRefresh(1)

    reaper.Main_OnCommandEx(40297, 0, 0) -- unselect all tracks

    for _, track in pairs(selectedTracks) do
      reaper.SetTrackSelected(track, true)
    end
  elseif doItems == true then
    reaper.Main_OnCommandEx(41622, 0, 0)
  elseif doTimeSel == true then
    local buffer = (maxTime - minTime) * 0.01
    reaper.GetSet_ArrangeView2(0, true, 0, 0, minTime - buffer, maxTime + 2 * buffer)
  end

  reaper.PreventUIRefresh(-1)

  reaper.Undo_EndBlock2(0, "Zoom to Razor Edit", -1)

  reaper.UpdateTimeline()
end
