-- TransformerQuantizeOps.lua
-- MIDI blob parsing, reconciliation, and cache management for TransformerQuantize


local Ops = {}

-- dependencies (set via init)
local r = nil  -- reaper
local mu = nil  -- MIDIUtils

-- debug flag (set via init() from main file's CACHE_DEBUG, not here)
local CACHE_DEBUG = false

-- state
local state = {
  originalMIDICache = {},       -- table[take] = binary MIDI string (for restore, may be updated with preserved props)
  reconciliationBaseline = {},  -- table[take] = binary MIDI string (for diff, updated after each apply)
  pristinePostQuantize = {},    -- table[take] = binary MIDI string (set once after quantize, never updated)
  preRestoreSnapshot = {},      -- table[take] = MIDI string captured before restore
  lastMIDIContentHash = nil,    -- MIDI_GetHash result for change detection
  catastrophicTakes = {},       -- takes with catastrophic changes this frame
  pauseLiveMode = false,        -- true when conflict dialog showing
  showConflictDialog = false,   -- trigger for OpenPopup
  previewPending = false,
  lastControlChangeTime = nil,
  lastTakeHash = nil,           -- for selection change detection
  isApplying = false,           -- true during Apply to filter self-changes
  lastOriginalHash = nil,
  lastPreviewApplied = false,
}

-- initialize with dependencies
function Ops.init(reaper, midiUtils, debug)
  r = reaper
  mu = midiUtils
  CACHE_DEBUG = debug or false
end

-- get state (for main file to read)
function Ops.getState()
  return state
end

-- reset all state (for cleanup)
function Ops.resetState()
  state.originalMIDICache = {}
  state.reconciliationBaseline = {}
  state.pristinePostQuantize = {}
  state.preRestoreSnapshot = {}
  state.lastMIDIContentHash = nil
  state.catastrophicTakes = {}
  state.pauseLiveMode = false
  state.showConflictDialog = false
  state.previewPending = false
  state.lastControlChangeTime = nil
  state.lastTakeHash = nil
  state.isApplying = false
  state.lastOriginalHash = nil
  state.lastPreviewApplied = false
end

--------------------------------------------------------------------------------
-- Pure utility functions
--------------------------------------------------------------------------------

-- deep copy table with cycle detection
local function deepcopy(t, seen)
  if type(t) ~= 'table' then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local copy = {}
  seen[t] = copy
  for k, v in pairs(t) do
    copy[deepcopy(k, seen)] = deepcopy(v, seen)
  end
  return setmetatable(copy, getmetatable(t))
end
Ops.deepcopy = deepcopy

--------------------------------------------------------------------------------
-- MIDI parsing/encoding
--------------------------------------------------------------------------------

-- parse MIDI binary string to event array
function Ops.parseMIDIEvents(midiStr)
  if not midiStr or #midiStr == 0 then return {} end
  local events = {}
  local stringPos = 1
  local ppqTime = 0
  local noteOns = {}  -- track pending note-ons for linking: [chan][pitch] = eventIdx

  while stringPos < #midiStr - 12 do  -- -12 excludes final all-notes-off
    local offset, flags, msg, newStringPos = string.unpack('i4Bs4', midiStr, stringPos)
    if not (msg and newStringPos) then break end

    ppqTime = ppqTime + offset
    local msgLen = #msg
    local event = {
      stringPos = stringPos,
      offset = offset,
      flags = flags,
      msg = msg,
      msgLen = msgLen,
      ppqTime = ppqTime,
    }

    -- categorize event type
    if msgLen >= 3 then
      local status = msg:byte(1)
      if status >= 0x80 and status < 0xF0 then
        local eventType = status >> 4
        local channel = (status & 0x0F) + 1
        local data1 = msg:byte(2)
        local data2 = msg:byte(3)

        if eventType == 0x9 and data2 > 0 then  -- note on
          event.type = 'note'
          event.channel = channel
          event.pitch = data1
          event.velocity = data2
          -- track for linking to note-off
          noteOns[channel] = noteOns[channel] or {}
          noteOns[channel][data1] = noteOns[channel][data1] or {}
          table.insert(noteOns[channel][data1], #events + 1)
        elseif eventType == 0x8 or (eventType == 0x9 and data2 == 0) then  -- note off
          event.type = 'noteoff'
          event.channel = channel
          event.pitch = data1
          -- link to matching note-on (FIFO)
          if noteOns[channel] and noteOns[channel][data1] and #noteOns[channel][data1] > 0 then
            local noteOnIdx = table.remove(noteOns[channel][data1], 1)
            events[noteOnIdx].noteOffIdx = #events + 1
            event.noteOnIdx = noteOnIdx
          end
        elseif eventType == 0xA then  -- poly pressure (aftertouch)
          event.type = 'polyat'
          event.channel = channel
          event.pitch = data1
          event.pressure = data2
        elseif eventType == 0xB then  -- cc
          event.type = 'cc'
          event.channel = channel
          event.cc_num = data1
          event.value = data2
        else
          event.type = 'other'
        end
      else
        event.type = 'other'
      end
    else
      event.type = 'other'
    end

    table.insert(events, event)
    stringPos = newStringPos
  end

  -- capture tail event (all-notes-off)
  if #midiStr >= 12 then
    local tailMsg = midiStr:sub(-12)
    local offset, flags, msg = string.unpack('i4Bs4', tailMsg)
    table.insert(events, {
      stringPos = #midiStr - 11,
      offset = offset,
      flags = flags,
      msg = msg,
      msgLen = #msg,
      ppqTime = ppqTime + offset,
      type = 'tail',
    })
  end

  return events
end

-- encode event array back to MIDI binary string
function Ops.encodeMIDIEvents(events)
  if not events or #events == 0 then return '' end
  local parts = {}

  for _, event in ipairs(events) do
    local packed = string.pack('i4Bs4', event.offset, event.flags, event.msg)
    table.insert(parts, packed)
  end

  return table.concat(parts)
end

--------------------------------------------------------------------------------
-- Note matching
--------------------------------------------------------------------------------

-- match notes between two event arrays using diff-based approach
-- returns mapping[actualIdx] = cachedIdx, or nil if unmatched
-- ppq: pulses per quarter note (for distance thresholds)
function Ops.matchNotesByIdentity(cached, actual, ppq)
  ppq = ppq or 960  -- fallback default
  local cachedNotes, actualNotes = {}, {}
  for i, e in ipairs(cached) do
    if e.type == 'note' then table.insert(cachedNotes, {idx=i, e=e, matched=false}) end
  end
  for i, e in ipairs(actual) do
    if e.type == 'note' then table.insert(actualNotes, {idx=i, e=e, matched=false}) end
  end
  if #cachedNotes ~= #actualNotes then return nil end

  local mapping = {}  -- mapping[actualIdx] = cachedIdx

  -- Phase 1: match notes that are identical (same position AND content)
  for _, an in ipairs(actualNotes) do
    for _, cn in ipairs(cachedNotes) do
      if not cn.matched and not an.matched then
        if cn.e.channel == an.e.channel and cn.e.pitch == an.e.pitch and
           cn.e.velocity == an.e.velocity and cn.e.ppqTime == an.e.ppqTime then
          mapping[an.idx] = cn.idx
          cn.matched = true
          an.matched = true
          break
        end
      end
    end
  end

  -- Phase 2: collect unmatched notes (the "diff")
  local unmatchedCached, unmatchedActual = {}, {}
  for _, cn in ipairs(cachedNotes) do
    if not cn.matched then table.insert(unmatchedCached, cn) end
  end
  for _, an in ipairs(actualNotes) do
    if not an.matched then table.insert(unmatchedActual, an) end
  end

  if CACHE_DEBUG and #unmatchedActual > 0 then
    r.ShowConsoleMsg('MATCH: ' .. #unmatchedActual .. ' unmatched notes to resolve\n')
  end

  -- Phase 3: match by chan+pitch+position (ignore velocity - humanization makes it unreliable)
  local MAX_NEARBY_DIST = ppq  -- 1 beat
  for _, an in ipairs(unmatchedActual) do
    local bestDist, bestCached = math.huge, nil
    for _, cn in ipairs(unmatchedCached) do
      if not cn.matched and cn.e.channel == an.e.channel and cn.e.pitch == an.e.pitch then
        local dist = math.abs(cn.e.ppqTime - an.e.ppqTime)
        if dist < bestDist then
          bestDist, bestCached = dist, cn
        end
      end
    end
    if bestCached and bestDist <= MAX_NEARBY_DIST then
      if CACHE_DEBUG then
        r.ShowConsoleMsg(string.format('P3: a[%d]@%d -> c[%d]@%d dist=%d p=%d\n',
          an.idx, an.e.ppqTime, bestCached.idx, bestCached.e.ppqTime, bestDist, an.e.pitch))
      end
      mapping[an.idx] = bestCached.idx
      bestCached.matched = true
      an.matched = true
    end
  end

  -- Phase 4: wider search - chan+pitch, larger distance
  local MAX_WIDE_DIST = ppq * 4  -- 1 bar (assuming 4/4)
  for _, an in ipairs(unmatchedActual) do
    if not an.matched then
      local bestDist, bestCached = math.huge, nil
      for _, cn in ipairs(unmatchedCached) do
        if not cn.matched and cn.e.channel == an.e.channel and cn.e.pitch == an.e.pitch then
          local dist = math.abs(cn.e.ppqTime - an.e.ppqTime)
          if dist < bestDist then
            bestDist, bestCached = dist, cn
          end
        end
      end
      if bestCached and bestDist <= MAX_WIDE_DIST then
        if CACHE_DEBUG then
          r.ShowConsoleMsg(string.format('P4: a[%d]@%d -> c[%d]@%d dist=%d p=%d\n',
            an.idx, an.e.ppqTime, bestCached.idx, bestCached.e.ppqTime, bestDist, an.e.pitch))
        end
        mapping[an.idx] = bestCached.idx
        bestCached.matched = true
        an.matched = true
      end
    end
  end

  -- Phase 5: last resort - chan+position only (pitch might have changed)
  for _, an in ipairs(unmatchedActual) do
    if not an.matched then
      local bestDist, bestCached = math.huge, nil
      for _, cn in ipairs(unmatchedCached) do
        if not cn.matched and cn.e.channel == an.e.channel then
          local dist = math.abs(cn.e.ppqTime - an.e.ppqTime)
          if dist < bestDist then
            bestDist, bestCached = dist, cn
          end
        end
      end
      if bestCached then
        if CACHE_DEBUG then
          r.ShowConsoleMsg(string.format('P5: a[%d]@%d p=%d -> c[%d]@%d p=%d dist=%d\n',
            an.idx, an.e.ppqTime, an.e.pitch, bestCached.idx, bestCached.e.ppqTime, bestCached.e.pitch, bestDist))
        end
        mapping[an.idx] = bestCached.idx
        bestCached.matched = true
        an.matched = true
      end
    end
  end

  -- Check if all matched
  for _, an in ipairs(actualNotes) do
    if not an.matched then
      if CACHE_DEBUG then r.ShowConsoleMsg('MATCH: failed to match note at ppq=' .. an.e.ppqTime .. '\n') end
      return nil
    end
  end

  return mapping
end

-- match CCs between two event arrays
-- CCs are identified by channel + cc_num, matched by nearest position
-- returns mapping[actualIdx] = cachedIdx, or nil if counts don't match
function Ops.matchCCsByIdentity(cached, actual, ppq)
  ppq = ppq or 960
  local cachedCCs, actualCCs = {}, {}
  for i, e in ipairs(cached) do
    if e.type == 'cc' then table.insert(cachedCCs, {idx=i, e=e, matched=false}) end
  end
  for i, e in ipairs(actual) do
    if e.type == 'cc' then table.insert(actualCCs, {idx=i, e=e, matched=false}) end
  end
  if #cachedCCs ~= #actualCCs then return nil end
  if #cachedCCs == 0 then return {} end  -- no CCs to match

  local mapping = {}

  -- Phase 1: exact match (same chan, cc_num, value, position)
  for _, acc in ipairs(actualCCs) do
    for _, ccc in ipairs(cachedCCs) do
      if not ccc.matched and not acc.matched then
        if ccc.e.channel == acc.e.channel and ccc.e.cc_num == acc.e.cc_num and
           ccc.e.value == acc.e.value and ccc.e.ppqTime == acc.e.ppqTime then
          mapping[acc.idx] = ccc.idx
          ccc.matched = true
          acc.matched = true
          break
        end
      end
    end
  end

  -- Phase 2: match by chan + cc_num + nearest position
  for _, acc in ipairs(actualCCs) do
    if not acc.matched then
      local bestDist, bestCached = math.huge, nil
      for _, ccc in ipairs(cachedCCs) do
        if not ccc.matched and ccc.e.channel == acc.e.channel and ccc.e.cc_num == acc.e.cc_num then
          local dist = math.abs(ccc.e.ppqTime - acc.e.ppqTime)
          if dist < bestDist then
            bestDist, bestCached = dist, ccc
          end
        end
      end
      if bestCached then
        mapping[acc.idx] = bestCached.idx
        bestCached.matched = true
        acc.matched = true
      end
    end
  end

  -- Check if all matched
  for _, acc in ipairs(actualCCs) do
    if not acc.matched then
      if CACHE_DEBUG then r.ShowConsoleMsg('MATCH: failed to match CC at ppq=' .. acc.e.ppqTime .. '\n') end
      return nil
    end
  end

  return mapping
end

-- match poly pressure events between two event arrays
-- identified by channel + pitch, matched by nearest position
-- returns mapping[actualIdx] = cachedIdx, or nil if counts don't match
function Ops.matchPolyATByIdentity(cached, actual, ppq)
  ppq = ppq or 960
  local cachedPAs, actualPAs = {}, {}
  for i, e in ipairs(cached) do
    if e.type == 'polyat' then table.insert(cachedPAs, {idx=i, e=e, matched=false}) end
  end
  for i, e in ipairs(actual) do
    if e.type == 'polyat' then table.insert(actualPAs, {idx=i, e=e, matched=false}) end
  end
  if #cachedPAs ~= #actualPAs then return nil end
  if #cachedPAs == 0 then return {} end

  local mapping = {}

  -- Phase 1: exact match (same chan, pitch, pressure, position)
  for _, apa in ipairs(actualPAs) do
    for _, cpa in ipairs(cachedPAs) do
      if not cpa.matched and not apa.matched then
        if cpa.e.channel == apa.e.channel and cpa.e.pitch == apa.e.pitch and
           cpa.e.pressure == apa.e.pressure and cpa.e.ppqTime == apa.e.ppqTime then
          mapping[apa.idx] = cpa.idx
          cpa.matched = true
          apa.matched = true
          break
        end
      end
    end
  end

  -- Phase 2: match by chan + pitch + pressure + nearest position
  for _, apa in ipairs(actualPAs) do
    if not apa.matched then
      local bestDist, bestCached = math.huge, nil
      for _, cpa in ipairs(cachedPAs) do
        if not cpa.matched and cpa.e.channel == apa.e.channel and cpa.e.pitch == apa.e.pitch and
           cpa.e.pressure == apa.e.pressure then
          local dist = math.abs(cpa.e.ppqTime - apa.e.ppqTime)
          if dist < bestDist or (dist == bestDist and bestCached and cpa.idx < bestCached.idx) then
            bestDist, bestCached = dist, cpa
          end
        end
      end
      if bestCached then
        mapping[apa.idx] = bestCached.idx
        bestCached.matched = true
        apa.matched = true
      end
    end
  end

  -- Phase 3: match by chan + pitch + nearest position (pressure may have changed)
  for _, apa in ipairs(actualPAs) do
    if not apa.matched then
      local bestDist, bestCached = math.huge, nil
      for _, cpa in ipairs(cachedPAs) do
        if not cpa.matched and cpa.e.channel == apa.e.channel and cpa.e.pitch == apa.e.pitch then
          local dist = math.abs(cpa.e.ppqTime - apa.e.ppqTime)
          if dist < bestDist or (dist == bestDist and bestCached and cpa.idx < bestCached.idx) then
            bestDist, bestCached = dist, cpa
          end
        end
      end
      if bestCached then
        mapping[apa.idx] = bestCached.idx
        bestCached.matched = true
        apa.matched = true
      end
    end
  end

  -- Check if all matched
  for _, apa in ipairs(actualPAs) do
    if not apa.matched then
      if CACHE_DEBUG then r.ShowConsoleMsg('MATCH: failed to match polyat at ppq=' .. apa.e.ppqTime .. '\n') end
      return nil
    end
  end

  return mapping
end

--------------------------------------------------------------------------------
-- Hash functions
--------------------------------------------------------------------------------

-- compute hash of current MIDI state across all cached takes
function Ops.computeMIDIContentHash()
  local hash = ''
  for take, _ in pairs(state.originalMIDICache) do
    if r.ValidatePtr(take, 'MediaItem_Take*') then
      local rv, hashVal = r.MIDI_GetHash(take, false, '')
      if rv then
        hash = hash .. hashVal .. '_'
      end
    end
  end
  return hash
end

-- compute hash of original (cached) MIDI state
function Ops.computeOriginalHash()
  local hash = ''
  for take, midiStr in pairs(state.originalMIDICache) do
    if r.ValidatePtr(take, 'MediaItem_Take*') then
      hash = hash .. tostring(#midiStr) .. '_'
    end
  end
  return hash
end

-- compute hash of current take selection
function Ops.computeTakeHash()
  local me = r.MIDIEditor_GetActive()
  if not me then return '' end
  local hash = ''
  local idx = 0
  while true do
    local take = r.MIDIEditor_EnumTakes(me, idx, true)
    if not take then break end
    hash = hash .. tostring(take)
    idx = idx + 1
  end
  return hash
end

-- detect if selection changed
function Ops.detectSelectionChange()
  local currentHash = Ops.computeTakeHash()
  if currentHash ~= state.lastTakeHash then
    state.lastTakeHash = currentHash
    return true
  end
  return false
end

--------------------------------------------------------------------------------
-- Cache management
--------------------------------------------------------------------------------

-- cache MIDI state for all affected takes
-- getAffectedTakes: callback function that returns list of takes
function Ops.cacheMIDIState(getAffectedTakes)
  if CACHE_DEBUG then r.ShowConsoleMsg('=== CACHE START ===\n') end
  state.originalMIDICache = {}
  state.reconciliationBaseline = {}
  state.pristinePostQuantize = {}
  state.lastPreviewApplied = false
  state.lastOriginalHash = nil
  local takes = getAffectedTakes()
  local takeCount = 0
  for _, take in ipairs(takes) do
    mu.MIDI_InitializeTake(take)  -- ensure MIDIUtils reads fresh state
    local rv, midiStr = r.MIDI_GetAllEvts(take, '')
    if rv then
      state.originalMIDICache[take] = midiStr
      takeCount = takeCount + 1
      if CACHE_DEBUG then
        local events = Ops.parseMIDIEvents(midiStr)
        local noteCount = 0
        for i, e in ipairs(events) do
          if e.type == 'note' and noteCount < 3 then
            r.ShowConsoleMsg('  original[' .. i .. '] ppq=' .. e.ppqTime .. ' p=' .. e.pitch .. ' v=' .. (e.velocity or '?') .. '\n')
            noteCount = noteCount + 1
          end
        end
      end
    end
  end
  state.lastMIDIContentHash = Ops.computeMIDIContentHash()
  if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: cached ' .. takeCount .. ' takes\n') end
end

-- capture current MIDI state for property preservation (call before restoreMIDIState)
function Ops.capturePreRestoreSnapshot()
  state.preRestoreSnapshot = {}
  for take, _ in pairs(state.originalMIDICache) do
    if r.ValidatePtr(take, 'MediaItem_Take*') then
      local rv, midiStr = r.MIDI_GetAllEvts(take, '')
      if rv then state.preRestoreSnapshot[take] = midiStr end
    end
  end
end

-- restore MIDI state from cache with property preservation
-- forceRaw: if true, skip property preservation (used by Undo Edit in conflict dialog)
function Ops.restoreMIDIState(forceRaw)
  if CACHE_DEBUG then
    r.ShowConsoleMsg('=== RESTORE START forceRaw=' .. tostring(forceRaw) .. ' ===\n')
    r.ShowConsoleMsg('  originalMIDICache has ' .. (function() local n=0; for _ in pairs(state.originalMIDICache) do n=n+1 end; return n end)() .. ' takes\n')
    r.ShowConsoleMsg('  pristinePostQuantize has ' .. (function() local n=0; for _ in pairs(state.pristinePostQuantize) do n=n+1 end; return n end)() .. ' takes\n')
  end
  local count = 0
  for take, cachedMIDI in pairs(state.originalMIDICache) do
    if not r.ValidatePtr(take, 'MediaItem_Take*') then goto continue end

    -- forceRaw: skip all property preservation, restore cached MIDI directly
    if forceRaw then
      r.MIDI_SetAllEvts(take, cachedMIDI)
      r.MIDI_Sort(take)
      local item = r.GetMediaItemTake_Item(take)
      if item then r.UpdateItemInProject(item) end
      count = count + 1
      goto continue
    end

    -- use snapshot if available, else read fresh
    local currentMIDI = state.preRestoreSnapshot[take]
    if not currentMIDI then
      local rv
      rv, currentMIDI = r.MIDI_GetAllEvts(take, '')
      if not rv then currentMIDI = nil end
    end

    if currentMIDI then
      local cachedEvents = Ops.parseMIDIEvents(cachedMIDI)
      local currentEvents = Ops.parseMIDIEvents(currentMIDI)
      local ppq = mu.MIDI_GetPPQ(take)
      local mapping = Ops.matchNotesByIdentity(cachedEvents, currentEvents, ppq)

      if CACHE_DEBUG then
        r.ShowConsoleMsg('  cached events=' .. #cachedEvents .. ' current events=' .. #currentEvents .. '\n')
        local noteCount = 0
        for i, e in ipairs(cachedEvents) do
          if e.type == 'note' and noteCount < 3 then
            r.ShowConsoleMsg('    cached[' .. i .. '] ppq=' .. e.ppqTime .. ' p=' .. e.pitch .. ' v=' .. (e.velocity or '?') .. '\n')
            noteCount = noteCount + 1
          end
        end
        noteCount = 0
        for i, e in ipairs(currentEvents) do
          if e.type == 'note' and noteCount < 3 then
            r.ShowConsoleMsg('    current[' .. i .. '] ppq=' .. e.ppqTime .. ' p=' .. e.pitch .. ' v=' .. (e.velocity or '?') .. '\n')
            noteCount = noteCount + 1
          end
        end
        r.ShowConsoleMsg('  mapping=' .. (mapping and 'YES' or 'NO') .. '\n')
      end
      if mapping then
        -- three-way comparison: original, baseline (post-quantize), current
        local baselineMIDI = state.pristinePostQuantize[take]
        local baselineEvents = baselineMIDI and Ops.parseMIDIEvents(baselineMIDI) or nil
        local baselineMapping = baselineEvents and Ops.matchNotesByIdentity(cachedEvents, baselineEvents, ppq) or nil

        if CACHE_DEBUG then
          r.ShowConsoleMsg('  baseline=' .. (baselineMIDI and 'YES' or 'NO') .. '\n')
          if baselineEvents then
            local noteCount = 0
            for i, e in ipairs(baselineEvents) do
              if e.type == 'note' and noteCount < 3 then
                r.ShowConsoleMsg('    baseline[' .. i .. '] ppq=' .. e.ppqTime .. ' p=' .. e.pitch .. ' v=' .. (e.velocity or '?') .. '\n')
                noteCount = noteCount + 1
              end
            end
          end
        end

        -- preserve note edits
        for currIdx, cacheIdx in pairs(mapping) do
          local curr = currentEvents[currIdx]
          local cached = cachedEvents[cacheIdx]

          -- find corresponding baseline note
          local baseline = nil
          if baselineMapping then
            for baseIdx, baseCacheIdx in pairs(baselineMapping) do
              if baseCacheIdx == cacheIdx then
                baseline = baselineEvents[baseIdx]
                break
              end
            end
          end

          -- always preserve flags (selection/mute)
          cached.flags = curr.flags
          if cached.noteOffIdx and cachedEvents[cached.noteOffIdx] then
            cachedEvents[cached.noteOffIdx].flags = curr.flags
          end

          -- for velocity/pitch/position: only preserve if different from baseline
          if baseline then
            if curr.velocity ~= baseline.velocity then
              cached.velocity = curr.velocity
              cached.msg = string.char(cached.msg:byte(1), cached.pitch, curr.velocity)
            end
            if curr.pitch ~= baseline.pitch then
              cached.pitch = curr.pitch
              cached.msg = string.char(cached.msg:byte(1), curr.pitch, cached.velocity)
              if cached.noteOffIdx and cachedEvents[cached.noteOffIdx] then
                local noteOff = cachedEvents[cached.noteOffIdx]
                noteOff.msg = string.char(noteOff.msg:byte(1), curr.pitch, noteOff.msg:byte(3) or 0)
              end
            end
            if curr.ppqTime ~= baseline.ppqTime then
              local delta = curr.ppqTime - baseline.ppqTime
              if CACHE_DEBUG then
                r.ShowConsoleMsg('RESTORE: POSITION DELTA! curr=' .. curr.ppqTime .. ' baseline=' .. baseline.ppqTime .. ' delta=' .. delta .. '\n')
              end
              cached.ppqTime = cached.ppqTime + delta
              if cached.noteOffIdx and cachedEvents[cached.noteOffIdx] then
                cachedEvents[cached.noteOffIdx].ppqTime = cachedEvents[cached.noteOffIdx].ppqTime + delta
              end
            end
          else
            if CACHE_DEBUG then
              r.ShowConsoleMsg('RESTORE: NO BASELINE for cached[' .. cacheIdx .. '] - skipping position check\n')
            end
          end
        end

        -- preserve CC edits
        local ccMapping = Ops.matchCCsByIdentity(cachedEvents, currentEvents, ppq)
        local baselineCCMapping = baselineEvents and Ops.matchCCsByIdentity(cachedEvents, baselineEvents, ppq) or nil
        if ccMapping then
          for currIdx, cacheIdx in pairs(ccMapping) do
            local curr = currentEvents[currIdx]
            local cached = cachedEvents[cacheIdx]

            -- find corresponding baseline CC
            local baseline = nil
            if baselineCCMapping then
              for baseIdx, baseCacheIdx in pairs(baselineCCMapping) do
                if baseCacheIdx == cacheIdx then
                  baseline = baselineEvents[baseIdx]
                  break
                end
              end
            end

            -- always preserve flags
            cached.flags = curr.flags

            -- for value/position: only preserve if different from baseline
            if baseline then
              if curr.value ~= baseline.value then
                cached.value = curr.value
                local status = 0xB0 | (cached.channel - 1)
                cached.msg = string.char(status, cached.cc_num, curr.value)
              end
              if curr.ppqTime ~= baseline.ppqTime then
                local delta = curr.ppqTime - baseline.ppqTime
                cached.ppqTime = cached.ppqTime + delta
              end
            end
          end
        end

        -- preserve poly pressure edits
        local paMapping = Ops.matchPolyATByIdentity(cachedEvents, currentEvents, ppq)
        local baselinePAMapping = baselineEvents and Ops.matchPolyATByIdentity(cachedEvents, baselineEvents, ppq) or nil
        if paMapping then
          for currIdx, cacheIdx in pairs(paMapping) do
            local curr = currentEvents[currIdx]
            local cached = cachedEvents[cacheIdx]

            -- find corresponding baseline poly pressure
            local baseline = nil
            if baselinePAMapping then
              for baseIdx, baseCacheIdx in pairs(baselinePAMapping) do
                if baseCacheIdx == cacheIdx then
                  baseline = baselineEvents[baseIdx]
                  break
                end
              end
            end

            -- always preserve flags
            cached.flags = curr.flags

            -- for pressure/position: only preserve if different from baseline
            if baseline then
              if curr.pressure ~= baseline.pressure then
                cached.pressure = curr.pressure
                local status = 0xA0 | (cached.channel - 1)
                cached.msg = string.char(status, cached.pitch, curr.pressure)
              end
              if curr.ppqTime ~= baseline.ppqTime then
                local delta = curr.ppqTime - baseline.ppqTime
                cached.ppqTime = cached.ppqTime + delta
              end
            end
          end
        end

        for i = 1, #cachedEvents do
          local prevPPQ = (i == 1) and 0 or cachedEvents[i-1].ppqTime
          cachedEvents[i].offset = math.floor(cachedEvents[i].ppqTime - prevPPQ + 0.5)
        end
        if CACHE_DEBUG then
          local noteCount = 0
          for i, e in ipairs(cachedEvents) do
            if e.type == 'note' and noteCount < 3 then
              r.ShowConsoleMsg('    WRITING[' .. i .. '] ppq=' .. e.ppqTime .. ' p=' .. e.pitch .. ' v=' .. (e.velocity or '?') .. '\n')
              noteCount = noteCount + 1
            end
          end
        end
        r.MIDI_SetAllEvts(take, Ops.encodeMIDIEvents(cachedEvents))
      else
        -- matching failed - fall back to raw restore
        if CACHE_DEBUG then r.ShowConsoleMsg('  matching failed, raw restore\n') end
        r.MIDI_SetAllEvts(take, cachedMIDI)
      end
    else
      r.MIDI_SetAllEvts(take, cachedMIDI)
    end

    r.MIDI_Sort(take)
    local item = r.GetMediaItemTake_Item(take)
    if item then r.UpdateItemInProject(item) end
    count = count + 1

    if CACHE_DEBUG then
      local rv, verifyMIDI = r.MIDI_GetAllEvts(take, '')
      if rv then
        local verifyEvents = Ops.parseMIDIEvents(verifyMIDI)
        local noteCount = 0
        for i, e in ipairs(verifyEvents) do
          if e.type == 'note' and noteCount < 3 then
            r.ShowConsoleMsg('    VERIFY[' .. i .. '] ppq=' .. e.ppqTime .. ' p=' .. e.pitch .. ' v=' .. (e.velocity or '?') .. '\n')
            noteCount = noteCount + 1
          end
        end
      end
    end

    ::continue::
  end
  r.UpdateArrange()
  state.preRestoreSnapshot = {}
  if CACHE_DEBUG then r.ShowConsoleMsg('=== RESTORE END ' .. count .. ' takes ===\n') end
end

--------------------------------------------------------------------------------
-- Reconciliation
--------------------------------------------------------------------------------

-- reconcile user edits with cached state
-- applyQuantizeToEvents: callback to apply quantize to events array
-- returns updated cache string and edit count, or (nil, reason) for failures
function Ops.reconcileUserEdits(take, cachedMIDI, applyQuantizeToEvents)
  local cachedEvents = Ops.parseMIDIEvents(cachedMIDI)
  local rv, currentMIDI = r.MIDI_GetAllEvts(take, '')
  if not rv then return nil end
  local actualEvents = Ops.parseMIDIEvents(currentMIDI)

  -- count mismatch: check if drastic length change (transient) vs real catastrophic
  if #cachedEvents ~= #actualEvents then
    local lengthRatio = #currentMIDI / #cachedMIDI
    if lengthRatio < 0.5 or lengthRatio > 2.0 then
      -- drastic length change - likely transient REAPER state, skip this frame
      if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: drastic length change, skipping frame\n') end
      return nil, 'skip'
    end
    if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: count mismatch cached=' .. #cachedEvents .. ' actual=' .. #actualEvents .. '\n') end
    return nil, 'catastrophic'
  end
  if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: event counts match (' .. #cachedEvents .. ')\n') end

  -- generate expected state
  local expectedEvents = deepcopy(cachedEvents, {})
  applyQuantizeToEvents(expectedEvents, take)

  local ppq = mu.MIDI_GetPPQ(take)

  -- helper: reconcile using identity-based matching
  local function doIdentityReconcile(reason)
    if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: ' .. reason .. ', trying identity match\n') end
    local editCount = 0
    local mapping = Ops.matchNotesByIdentity(cachedEvents, actualEvents, ppq)
    if not mapping then
      if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: note identity match failed\n') end
      return nil, 'position_mismatch'
    end

    -- reconcile notes
    for actualIdx, cachedIdx in pairs(mapping) do
      local actualNote = actualEvents[actualIdx]
      local expectedNote = expectedEvents[cachedIdx]
      if actualNote.ppqTime ~= expectedNote.ppqTime then
        editCount = editCount + 1
        cachedEvents[cachedIdx].ppqTime = actualNote.ppqTime
      end
      if actualNote.velocity ~= expectedNote.velocity then
        editCount = editCount + 1
        cachedEvents[cachedIdx].velocity = actualNote.velocity
      end
      if actualNote.pitch ~= expectedNote.pitch then
        editCount = editCount + 1
        cachedEvents[cachedIdx].pitch = actualNote.pitch
        local noteOffIdx = cachedEvents[cachedIdx].noteOffIdx
        if noteOffIdx and cachedEvents[noteOffIdx] then
          local offStatus = cachedEvents[noteOffIdx].msg:byte(1)
          local offVel = cachedEvents[noteOffIdx].msg:byte(3) or 0
          cachedEvents[noteOffIdx].msg = string.char(offStatus, actualNote.pitch, offVel)
          cachedEvents[noteOffIdx].pitch = actualNote.pitch
        end
      end
      if actualNote.flags ~= expectedNote.flags then
        cachedEvents[cachedIdx].flags = actualNote.flags
      end
      local status = 0x90 | (cachedEvents[cachedIdx].channel - 1)
      cachedEvents[cachedIdx].msg = string.char(status, cachedEvents[cachedIdx].pitch, cachedEvents[cachedIdx].velocity)
    end

    -- reconcile CCs
    local ccMapping = Ops.matchCCsByIdentity(cachedEvents, actualEvents, ppq)
    if ccMapping then
      for actualIdx, cachedIdx in pairs(ccMapping) do
        local actualCC = actualEvents[actualIdx]
        local expectedCC = expectedEvents[cachedIdx]
        if actualCC.ppqTime ~= expectedCC.ppqTime then
          editCount = editCount + 1
          cachedEvents[cachedIdx].ppqTime = actualCC.ppqTime
        end
        if actualCC.value ~= expectedCC.value then
          editCount = editCount + 1
          cachedEvents[cachedIdx].value = actualCC.value
          local status = 0xB0 | (cachedEvents[cachedIdx].channel - 1)
          cachedEvents[cachedIdx].msg = string.char(status, cachedEvents[cachedIdx].cc_num, actualCC.value)
        end
        if actualCC.flags ~= expectedCC.flags then
          cachedEvents[cachedIdx].flags = actualCC.flags
        end
      end
    end

    -- reconcile poly pressure
    local paMapping = Ops.matchPolyATByIdentity(cachedEvents, actualEvents, ppq)
    if paMapping then
      for actualIdx, cachedIdx in pairs(paMapping) do
        local actualPA = actualEvents[actualIdx]
        local expectedPA = expectedEvents[cachedIdx]
        if actualPA.ppqTime ~= expectedPA.ppqTime then
          editCount = editCount + 1
          cachedEvents[cachedIdx].ppqTime = actualPA.ppqTime
        end
        if actualPA.pressure ~= expectedPA.pressure then
          editCount = editCount + 1
          cachedEvents[cachedIdx].pressure = actualPA.pressure
          local status = 0xA0 | (cachedEvents[cachedIdx].channel - 1)
          cachedEvents[cachedIdx].msg = string.char(status, cachedEvents[cachedIdx].pitch, actualPA.pressure)
        end
        if actualPA.flags ~= expectedPA.flags then
          cachedEvents[cachedIdx].flags = actualPA.flags
        end
      end
    end

    for j = 1, #cachedEvents do
      local prevPPQ = (j == 1) and 0 or cachedEvents[j-1].ppqTime
      cachedEvents[j].offset = math.floor(cachedEvents[j].ppqTime - prevPPQ + 0.5)
    end
    if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: identity match reconciled ' .. editCount .. ' edits\n') end
    return Ops.encodeMIDIEvents(cachedEvents), editCount
  end

  local editCount = 0

  for i = 1, #actualEvents do
    local cached = cachedEvents[i]
    local expected = expectedEvents[i]
    local actual = actualEvents[i]

    if cached.type ~= actual.type then
      return doIdentityReconcile('type mismatch at ' .. i)
    end

    if cached.type == 'tail' then
      goto continue
    end

    if cached.type == 'note' then
      if cached.channel ~= actual.channel then
        return doIdentityReconcile('note channel mismatch at ' .. i)
      end

      if actual.ppqTime ~= expected.ppqTime then
        editCount = editCount + 1
        cachedEvents[i].ppqTime = actual.ppqTime
      end

      if actual.velocity ~= expected.velocity then
        editCount = editCount + 1
        cachedEvents[i].velocity = actual.velocity
        local status = 0x90 | (actual.channel - 1)
        cachedEvents[i].msg = string.char(status, actual.pitch, actual.velocity)
      end

      if actual.pitch ~= expected.pitch then
        editCount = editCount + 1
        cachedEvents[i].pitch = actual.pitch
        local status = 0x90 | (actual.channel - 1)
        cachedEvents[i].msg = string.char(status, actual.pitch, actual.velocity)
        local noteOffIdx = cachedEvents[i].noteOffIdx
        if noteOffIdx and cachedEvents[noteOffIdx] then
          local offStatus = cachedEvents[noteOffIdx].msg:byte(1)
          local offVel = cachedEvents[noteOffIdx].msg:byte(3) or 0
          cachedEvents[noteOffIdx].msg = string.char(offStatus, actual.pitch, offVel)
          cachedEvents[noteOffIdx].pitch = actual.pitch
        end
      end

      if actual.flags ~= expected.flags then
        cachedEvents[i].flags = actual.flags
      end

    elseif cached.type == 'cc' then
      if cached.channel ~= actual.channel or cached.cc_num ~= actual.cc_num then
        return doIdentityReconcile('CC identity mismatch at ' .. i)
      end

      -- position diff: user moved CC from expected quantized position
      if actual.ppqTime ~= expected.ppqTime then
        editCount = editCount + 1
        cachedEvents[i].ppqTime = actual.ppqTime
      end

      if actual.value ~= expected.value then
        editCount = editCount + 1
        cachedEvents[i].value = actual.value
        local status = 0xB0 | (actual.channel - 1)
        cachedEvents[i].msg = string.char(status, actual.cc_num, actual.value)
      end

      if actual.flags ~= expected.flags then
        cachedEvents[i].flags = actual.flags
      end

    elseif cached.type == 'polyat' then
      if cached.channel ~= actual.channel or cached.pitch ~= actual.pitch then
        return doIdentityReconcile('polyat identity mismatch at ' .. i)
      end

      if actual.ppqTime ~= expected.ppqTime then
        editCount = editCount + 1
        cachedEvents[i].ppqTime = actual.ppqTime
      end

      if actual.pressure ~= expected.pressure then
        editCount = editCount + 1
        cachedEvents[i].pressure = actual.pressure
        local status = 0xA0 | (actual.channel - 1)
        cachedEvents[i].msg = string.char(status, actual.pitch, actual.pressure)
      end

      if actual.flags ~= expected.flags then
        cachedEvents[i].flags = actual.flags
      end

    elseif cached.type == 'noteoff' then
      if actual.flags ~= expected.flags then
        cachedEvents[i].flags = actual.flags
      end

    else
      if actual.msg ~= expected.msg then
        editCount = editCount + 1
        cachedEvents[i].msg = actual.msg
      end
      if actual.flags ~= expected.flags then
        cachedEvents[i].flags = actual.flags
      end
    end

    ::continue::
  end

  for i = 1, #cachedEvents do
    local prevPPQ = (i == 1) and 0 or cachedEvents[i-1].ppqTime
    cachedEvents[i].offset = math.floor(cachedEvents[i].ppqTime - prevPPQ + 0.5)
  end

  if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: reconciled ' .. editCount .. ' edits\n') end
  return Ops.encodeMIDIEvents(cachedEvents), editCount
end

-- called when external MIDI edit detected during live mode
-- applyQuantizeToEvents: callback to apply quantize to events
function Ops.onExternalMIDIChange(applyQuantizeToEvents)
  if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: external MIDI change detected, starting reconciliation\n') end
  local catastrophicChanges = false
  local reconciledCache = {}
  local totalEdits = 0

  for take, baselineMIDI in pairs(state.reconciliationBaseline) do
    if r.ValidatePtr(take, 'MediaItem_Take*') then
      local result, editCountOrReason = Ops.reconcileUserEdits(take, baselineMIDI, applyQuantizeToEvents)
      if result then
        reconciledCache[take] = result
        totalEdits = totalEdits + (editCountOrReason or 0)
      else
        local reason = editCountOrReason or 'catastrophic'
        if reason == 'skip' then
          -- transient REAPER state, skip this frame entirely
          return 'skip'
        end
        local rv, midiStr = r.MIDI_GetAllEvts(take, '')
        if rv then
          reconciledCache[take] = midiStr
          if reason == 'catastrophic' then
            catastrophicChanges = true
            state.catastrophicTakes[take] = true
          else
            if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: position mismatch, keeping current state for take\n') end
          end
        end
      end
    end
  end

  if catastrophicChanges then
    if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: catastrophic change - showing conflict dialog\n') end
    state.showConflictDialog = true
    state.pauseLiveMode = true
  else
    if CACHE_DEBUG then r.ShowConsoleMsg('CACHE: reconciled ' .. totalEdits .. ' edits, updating baseline\n') end
    state.reconciliationBaseline = reconciledCache
    -- NOTE: don't update originalMIDICache here - restoreMIDIState handles
    -- property preservation via three-way comparison (current vs baseline)
    state.lastMIDIContentHash = Ops.computeMIDIContentHash()
  end
end

-- mark control as changed (triggers debounce)
function Ops.markControlChanged()
  state.lastControlChangeTime = r.time_precise()
  state.previewPending = true
  state.lastPreviewApplied = false
  state.pristinePostQuantize = {}
end

-- update reconciliation baseline after preview apply
function Ops.updateBaselineAfterApply()
  for take, _ in pairs(state.originalMIDICache) do
    if r.ValidatePtr(take, 'MediaItem_Take*') then
      local rv, midiStr = r.MIDI_GetAllEvts(take, '')
      if rv then
        state.reconciliationBaseline[take] = midiStr
        local setPristine = not state.pristinePostQuantize[take]
        if setPristine then
          state.pristinePostQuantize[take] = midiStr
        end
        if CACHE_DEBUG then
          local events = Ops.parseMIDIEvents(midiStr)
          local noteCount = 0
          for i, e in ipairs(events) do
            if e.type == 'note' and noteCount < 3 then
              r.ShowConsoleMsg('BASELINE: post-quantize[' .. i .. '] ppq=' .. e.ppqTime .. ' pitch=' .. e.pitch .. (setPristine and ' (SET PRISTINE)' or '') .. '\n')
              noteCount = noteCount + 1
            end
          end
        end
      end
    end
  end
  -- update hash so next frame doesn't see a false "external change"
  state.lastMIDIContentHash = Ops.computeMIDIContentHash()
end

return Ops
