-- @description Selected Envelope Points to Razor Edit
-- @version 1.0
-- @author sockmonkey72
-- @about
--   # Selected Envelope Points to Razor Edit
--   Convert selected envelope points to a razor edit region.
-- @changelog
--   initial upload

local anEnvelope = reaper.GetSelectedEnvelope(0)
if anEnvelope then
  local tab = {}
  local numPoints = reaper.CountEnvelopePoints(anEnvelope)
  for i=0,numPoints-1 do
    local _, time, _, _, _, selected = reaper.GetEnvelopePoint(anEnvelope, i)
    if selected then
      if #tab == 0 then
        tab[1] = time
      else
        tab[2] = time
      end
    end
  end
  if #tab == 2 then
    local aTrack = reaper.GetEnvelopeInfo_Value(anEnvelope, "P_TRACK")
    if aTrack ~= 0 then
      local _, guid = reaper.GetSetEnvelopeInfo_String(anEnvelope, "GUID", "", false)
      local str = "" .. tab[1].." "..tab[2].." \""..guid.."\""
      reaper.Undo_BeginBlock2(0)
      reaper.GetSetMediaTrackInfo_String(aTrack, "P_RAZOREDITS", str, true)
      reaper.Undo_EndBlock2(0, "Selected Envelope Points to Razor Edit", -1)
    end
  end
end

