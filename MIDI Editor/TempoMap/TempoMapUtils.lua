--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local r = reaper

local function post(...)
    local args = {...}
    local str = ''
    for i = 1, #args do
      local v = args[i]
      local val = tostring(v)
      str = str .. (i ~= 1 and ', ' or '') .. (val ~= nil and val or '<nil>')
    end
    str = str .. '\n'
    r.ShowConsoleMsg(str)
  end

local smallEnough = 0.000001

local TempoMap = {}

local function AnalyzeMarkers(projPos)
    local ttsPrev = { index = -1, pos = -0xFFFFFFFF, bpm = 0 }
    local ttsCurr = { index = -1, pos = -0xFFFFFFFF, bpm = 0 }
    local ttsNext = { index = -1, pos = 0xFFFFFFFF, bpm = 0 }

    local ttsCount = r.CountTempoTimeSigMarkers(0)
    for i = 0, ttsCount - 1 do
        local _, ttsPos, _, _, ttsBpm = r.GetTempoTimeSigMarker(0, i)
        local ttsDiff = projPos - ttsPos
        if math.abs(ttsDiff) < smallEnough then
            ttsCurr.index = i
            ttsCurr.pos = projPos
            ttsCurr.bpm = ttsBpm
        elseif ttsDiff > 0 and ttsDiff < projPos - ttsPrev.pos then
            ttsPrev.index = i
            ttsPrev.pos = ttsPos
            ttsPrev.bpm = ttsBpm
        elseif ttsDiff < 0 and ttsDiff > projPos - ttsNext.pos then
            ttsNext.index = i
            ttsNext.pos = ttsPos
            ttsNext.bpm = ttsBpm
        end
    end
    return { prev = ttsPrev, curr = ttsCurr, next = ttsNext }
end

local function GetReference()
-- first selected note in first selected item is the guide
    local selectedIndex = 0
    while 1 do
        local item = r.GetSelectedMediaItem(0, selectedIndex)
        if not item then break end
        local take = r.GetActiveTake(item)
        if take and r.TakeIsMIDI(take) then
            local noteidx = r.MIDI_EnumSelNotes(take, -1)
            if noteidx >= 0 then
                local rv, _, _, ppqpos = r.MIDI_GetNote(take, noteidx)
                if rv then
                    local projPos = r.MIDI_GetProjTimeFromPPQPos(take, ppqpos)
                    local itemStart = r.GetMediaItemInfo_Value(item, 'D_POSITION')
                    local itemEnd = itemStart + r.GetMediaItemInfo_Value(item, 'D_LENGTH')

                    if projPos < itemStart or projPos > itemEnd then
                        goto continue
                    end

                    local ttsTab = AnalyzeMarkers(projPos)
                    local bpm
                    local createPrevMarker = false
                    local ttsPrev = ttsTab.prev

                    if ttsPrev.index >= 0 then
                        if ttsPrev.bpm and ttsPrev.bpm ~= 0 then bpm = ttsPrev.bpm end
                    end
                    if not bpm then
                        bpm = r.GetProjectTimeSignature2(0)
                    end

                    if ttsPrev.index < 0 then
                        ttsTab.prev.index = 0
                        ttsTab.prev.pos = 0.
                        ttsTab.prev.bpm = bpm
                        createPrevMarker = true
                    end


                    return { item = item, take = take, projPos = projPos, ttsTab = ttsTab, bpm = bpm, createPrevMarker = createPrevMarker }
                end
            end
        end
        ::continue::
        selectedIndex = selectedIndex + 1
    end
    return nil
end

local function CalcPrevBeat(projPos)
    local _, measoff = r.get_config_var_string('projmeasoffs')
    local beats, measures = r.TimeMap2_timeToBeats(0, projPos)
    measures = measures + (tonumber(measoff) + 1)
    local timePosStr = measures .. '.' .. math.floor(beats + 1) .. '.00'

    return timePosStr
end

local function CalcNextBeat(projPos)
    local _, measoff = r.get_config_var_string('projmeasoffs')
    local beats, measures, cml = r.TimeMap2_timeToBeats(0, projPos)
    measures = measures + (tonumber(measoff) + 1)
    beats = math.floor(beats) + 2
    if (beats > cml) then
        measures = measures + 1
        beats = 1
    end
    local timePosStr = measures .. '.' .. beats .. '.00'

    return timePosStr
end

local function CalcPrevMeasure(projPos)
    local _, measoff = r.get_config_var_string('projmeasoffs')
    local _, measures = r.TimeMap2_timeToBeats(0, projPos)
    measures = measures + (tonumber(measoff) + 1)
    local timePosStr = measures .. '.1.00'

    return timePosStr
end

local function CalcNextMeasure(projPos)
    local _, measoff = r.get_config_var_string('projmeasoffs')
    local _, measures = r.TimeMap2_timeToBeats(0, projPos)
    measures = measures + (tonumber(measoff) + 2)
    local timePosStr = measures .. '.1.00'

    return timePosStr
end

local function ValidateTargetTime(timePos, infoTab)
    local ttsTab = infoTab.ttsTab
    local ttsPrev = ttsTab.prev
    local ttsCurr = ttsTab.curr
    local ttsNext = ttsTab.next

    local prevDiff = math.abs(timePos - ttsPrev.pos)
    -- I guess that we could allow the user to overwrite the previous marker
    -- but it would require re-iterating all of the tempo markers and rejiggering
    -- everything, not sure if it's worth it. overwriting the next marker is not a big deal.
    if prevDiff < smallEnough or timePos < ttsPrev.pos then
        r.ShowMessageBox('Earlier than previous tempo marker', 'Bad Target Position', 0)
        return false
    elseif ttsNext.index > 0 then
        local nextDiff = math.abs(timePos - ttsNext.pos)
        if nextDiff < smallEnough then
            ttsTab.curr = ttsNext
            ttsTab.next = { index = -1, pos = 0xFFFFFFFF, bpm = 0 }
        elseif timePos > ttsNext.pos then
            r.ShowMessageBox('Later than next tempo marker', 'Bad Target Position', 0)
            return r.ImGui_TabBarFlags_NoCloseWithMiddleMouseButton()
        end
    end
    return true
end

local function ProcessToTargetTime(timePos, infoTab)
    local item = infoTab.item
    local take = infoTab.take
    local projPos = infoTab.projPos
    local bpm = infoTab.bpm
    local createPrevMarker = infoTab.createPrevMarker

    local ttsTab = infoTab.ttsTab
    local ttsPrev = ttsTab.prev
    local ttsCurr = ttsTab.curr
    local ttsNext = ttsTab.next

    r.Undo_BeginBlock2(0)
    r.PreventUIRefresh(1)

    if createPrevMarker then
        r.SetTempoTimeSigMarker(0, -1, ttsPrev.pos, -1, -1, ttsPrev.bpm, 0, 0, false)
    end

    local oldBeatAttach = r.GetMediaItemInfo_Value(item, 'C_BEATATTACHMODE')
    local midiTakeTempoInfo = {}
    _, midiTakeTempoInfo.ignoreProjTempo, midiTakeTempoInfo.bpm, midiTakeTempoInfo.num, midiTakeTempoInfo.den = r.BR_GetMidiTakeTempoInfo(take)
    local needsIgnoreProjTempo = false
    local needsBeatAttach = false

    -- ensure that the item is timebase time and that the take is ignoring project tempo
    if oldBeatAttach ~= 0 then
        needsBeatAttach = true
    end
    if not midiTakeTempoInfo.ignoreProjTempo then
        needsIgnoreProjTempo = true
    end

    -- TODO (or not): attempt to split at next tempo marker and keep everything lined up
    -- this is very tricky, disabling for now
    -- local rhItem = nil
    -- if ttsNext.index >= 0 then
    --     rhItem = r.SplitMediaItem(item, ttsNext.pos)
    --     if rhItem then
    --         r.SetMediaItemInfo_Value(rhItem, 'B_UISEL', 0) -- deselect the unaffected rh side
    --     end
    -- end

    if needsBeatAttach or needsIgnoreProjTempo then
        local rhItemPre = r.SplitMediaItem(item, ttsPrev.pos)
        if rhItemPre then -- split worked
            -- closing the inline editor pre-split causes weird undo behavior, leaving for now
            r.SetMediaItemInfo_Value(item, 'B_UISEL', 0) -- deselect the unaffected lh side
            item = rhItemPre
            take = r.GetActiveTake(item)
        end

        if needsBeatAttach then
            r.SetMediaItemInfo_Value(item, 'C_BEATATTACHMODE', 0) -- time
        end
        if needsIgnoreProjTempo then
            local num, den, tempo = r.TimeMap_GetTimeSigAtTime(0, projPos)
            r.BR_SetMidiTakeTempoInfo(take, true, bpm, num, den)
        end
    end

    local qnprev = r.TimeMap2_timeToQN(0, ttsPrev.pos)
    local qncur = r.TimeMap2_timeToQN(0, projPos) - qnprev

    local qntarg = r.TimeMap2_timeToQN(0, timePos)
    local qndes = qntarg - qnprev
    local ratio = qncur / qndes

    local adjustBpm = bpm / ratio
    local markerBpm = (ttsCurr.index >= 0 and ttsCurr.bpm ~= 0) and ttsCurr.bpm or bpm

    r.SetTempoTimeSigMarker(0, ttsPrev.index, ttsPrev.pos, -1, -1, adjustBpm, 0, 0, false)
    r.SetTempoTimeSigMarker(0, ttsCurr.index, projPos, -1, -1, markerBpm, 0, 0, false)

    -- TODO: see above re: attempts to split at the next tempo marker and leave anything after
    -- as untouched as possible. These attempts are now disabled, it's not working as intended
    -- and I am not convinced that it's worth solving. For now, the next tempo event will just
    -- stay put (locked to time), and later items and events will stay put (based on their
    -- timebase). The affected item, though might be different due to its timebase changes

    -- if false and ttsNext.index >= 0 then
    --     local rhItem = r.SplitMediaItem(item, ttsNext.pos)

    --     r.SetTempoTimeSigMarker(0, ttsNext.index + 1, ttsNext.pos, -1, -1, ttsNext.bpm, 0, 0, false)
    --     if rhItem then
    --         r.SetMediaItemInfo_Value(rhItem, 'D_POSITION', r.GetMediaItemInfo_Value(item, 'D_POSITION') + r.GetMediaItemInfo_Value(item, 'D_LENGTH'))

    --         r.SetMediaItemInfo_Value(rhItem, 'B_UISEL', 0) -- deselect the unaffected rh side
    --         r.SetMediaItemInfo_Value(rhItem, 'C_BEATATTACHMODE', oldBeatAttach)
    --         r.BR_SetMidiTakeTempoInfo(r.GetActiveTake(rhItem), midiTakeTempoInfo.ignoreProjTempo, midiTakeTempoInfo.bpm, midiTakeTempoInfo.num, midiTakeTempoInfo.den)
    --     end
    -- end

    -- if false and ttsNext.index >= 0 then
    --     -- local rhItem = r.SplitMediaItem(item, ttsNext.pos)
    --     if rhItem then
    --         -- r.SetMediaItemInfo_Value(rhItem, 'C_BEATATTACHMODE', oldBeatAttach)
    --         -- r.BR_SetMidiTakeTempoInfo(r.GetActiveTake(rhItem), midiTakeTempoInfo.ignoreProjTempo, midiTakeTempoInfo.bpm, midiTakeTempoInfo.num, midiTakeTempoInfo.den)

    --         local oldstart, oldend = r.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    --         local _, newtime = r.GetTempoTimeSigMarker(0, ttsNext.index + 1)
    --         r.GetSet_LoopTimeRange2(0, true, false, r.GetMediaItemInfo_Value(item, 'D_POSITION') + r.GetMediaItemInfo_Value(item, 'D_LENGTH'), newtime, false)
    --         r.Main_OnCommandEx(40201, 0, 0) -- remove time
    --         r.GetSet_LoopTimeRange2(0, true, false, oldstart, oldend, false)
    --     end
    -- end

    -- if ttsNext.index >- 0 then
    --     local idx = ttsCurr.index >= 0 and ttsNext.index or ttsNext.index + 1
    --     r.SetTempoTimeSigMarker(0, idx, ttsNext.pos, -1, -1, ttsNext.bpm, 0, 0, false)
    -- end

    r.UpdateTimeline()
    r.MarkTrackItemsDirty(r.GetMediaItemTake_Track(take), item)

    r.PreventUIRefresh(-1)
    r.Undo_EndBlock2(0, 'Add Tempo Markers To Hit Note Position', -1)
end

TempoMap.post = post
TempoMap.smallEnough = smallEnough
TempoMap.GetReference = GetReference
TempoMap.ValidateTargetTime = ValidateTargetTime
TempoMap.ProcessToTargetTime = ProcessToTargetTime

TempoMap.CalcPrevBeat = CalcPrevBeat
TempoMap.CalcNextBeat = CalcNextBeat
TempoMap.CalcPrevMeasure = CalcPrevMeasure
TempoMap.CalcNextMeasure = CalcNextMeasure

return TempoMap