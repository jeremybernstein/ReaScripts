-- @description Toggle Send Volume Envelopes
-- @author sockmonkey72
-- @version 1.0
-- @changelog 1.0 initial upload
-- @about Toggle arm status of track send volume envelopes

count = reaper.CountSelectedTracks(0)
for i = 0,count-1 do
  tr = reaper.GetSelectedTrack(0, i)
  if tr then
    envCount = reaper.CountTrackEnvelopes(tr)
    for j = 0,envCount-1 do
      env = reaper.GetTrackEnvelope(tr, j)
      if env then
        val = reaper.GetEnvelopeInfo_Value(env, "P_DESTTRACK")
        if val ~= 0 then
          _, name = reaper.GetEnvelopeName(env)
          if name:match("Volume") then
            _, state = reaper.GetEnvelopeStateChunk(env, "", 0)
            if state:match("ARM 1") then
              state = state:gsub("ARM 1", "ARM 0")
            elseif state:match("ARM 0") then
              state = state:gsub("ARM 0", "ARM 1")
            end
            reaper.SetEnvelopeStateChunk(env, state, 1);
          end
        end
      end
    end
  end
end
