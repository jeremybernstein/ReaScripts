-- @description Clear Clip Indicators After 3 Seconds
-- @author sockmonkey72
-- @version 1.1
-- @changelog 1.1 add master track processing
-- @about Clear clip indicators after 3s of non-clipping (background script)


tracksAndTimes = {}

function processTrack(tr, now)
  if tr ~= nil then
    numChans = reaper.GetMediaTrackInfo_Value(tr, "I_NCHAN")
    wantsReset = false
    hasClip = false
    for j = 0,numChans-1 do
      holdDB = reaper.Track_GetPeakHoldDB(tr, j, false)
      if holdDB > 0. then
        hasClip = true
        clock = tracksAndTimes[tr]
        if clock == nil then
          tracksAndTimes[tr] = now -- add a timestamp for the first over detection
          break -- no need to iterate further
        elseif now - clock > 3. then
          tracksAndTimes[tr] = nil
          wantsReset = true -- we'll iterate at the end
          break
        end
      end
    end
    -- reset all channels in this case
    if wantsReset then
      for j = 0,numChans-1 do
        reaper.Track_GetPeakHoldDB(tr, j, true)
      end
    end
    if hasClip == false then
      if tracksAndTimes[tr] ~= nil then
        tracksAndTimes[tr] = nil -- zero it out, it was probably manually reset
      end
    end
  end
end

function loop()
  trackCount = reaper.CountTracks(0)
  now = os.time()
  for i=0,trackCount-1 do
    processTrack(reaper.GetTrack(0, i), now)
  end
  processTrack(reaper.GetMasterTrack(0), now)
  reaper.defer(loop)
end

reaper.defer(loop)
