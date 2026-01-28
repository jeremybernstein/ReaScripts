--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.0.0
   * NoIndex: true
--]]

--[[
  SMFParser.lua - Standard MIDI File parser

  Parses Type 0 and Type 1 SMF files, extracts note events.
  Designed for groove template extraction (notes only).

  Usage:
    local SMFParser = require 'SMFParser'
    local data = io.open('file.mid', 'rb'):read('*all')
    local result, err = SMFParser.parse(data)
    if result then
      print("PPQ:", result.header.division)
      for _, note in ipairs(result.notes) do
        print(note.tick, note.pitch, note.isNoteOn)
      end
    end

  API:
    parseHeader(data, pos) - parse MThd chunk
    extractNotes(data, header) - extract note events from all tracks
    parse(data) - convenience wrapper for parseHeader + extractNotes
    extractGroove(notes, header, opts) - convert notes to .rgt groove format

  Version: 1.0.0
  No REAPER dependencies - vanilla Lua 5.4
--]]

local SMFParser = {}

SMFParser.VERSION = "1.0.0"

----------------------------------------------------------------------------------------
-- Internal Helpers
----------------------------------------------------------------------------------------

-- Parse Variable-Length Quantity (VLQ)
-- Used for delta times and meta event lengths in SMF format
-- @param data string - raw bytes
-- @param pos number - 1-based position (default 1)
-- @return number value, number nextPos on success
-- @return nil, string error on overflow or malformed data
local function parseVLQ(data, pos)
  pos = pos or 1
  local value = 0
  local byteCount = 0
  local byte

  repeat
    -- Enforce 4-byte max to prevent infinite loops on malformed data
    if byteCount >= 4 then
      return nil, "VLQ exceeds 4 bytes (malformed)"
    end

    -- Boundary check before reading byte
    if pos > #data then
      return nil, "Unexpected end of data in VLQ"
    end

    byte, pos = string.unpack("B", data, pos)
    value = (value << 7) | (byte & 0x7F)
    byteCount = byteCount + 1
  until (byte & 0x80) == 0

  -- Check for overflow (max valid VLQ value)
  if value > 0x0FFFFFFF then
    return nil, "VLQ value exceeds maximum (0x0FFFFFFF)"
  end

  return value, pos
end

-- Convert threshold to ticks based on mode
-- @param threshold number - user-provided threshold value
-- @param mode string - "ticks", "percent", or "ms"
-- @param ppq number - from header.division
-- @param tempo number - microseconds per quarter (default 500000 = 120 BPM)
-- @return number thresholdTicks
local function convertThresholdToTicks(threshold, mode, ppq, tempo)
  if mode == "ticks" then
    return threshold
  elseif mode == "percent" then
    -- threshold is % of quarter note (beat)
    return threshold * ppq
  elseif mode == "ms" then
    -- Convert ms to ticks using tempo
    -- tempo in microseconds per quarter note
    -- ticks = (ms * 1000 * ppq) / tempo
    return (threshold * 1000 * ppq) / tempo
  else
    error("Invalid threshold mode: " .. mode)
  end
end

-- Coalesce notes within threshold window
-- @param notes table[] - sorted by tick, with {tick, velocity, isNoteOn}
-- @param thresholdTicks number - window size in ticks
-- @param mode string - "first" or "loudest"
-- @return table[] - coalesced notes with {tick, velocity}
local function coalesceNotes(notes, thresholdTicks, mode)
  if #notes == 0 then return {} end

  local coalesced = {}

  if mode == "first" then
    -- First-note-wins coalescing
    local windowStart = nil

    for _, note in ipairs(notes) do
      -- Only process note-ons (skip note-offs)
      if note.isNoteOn then
        if not windowStart then
          -- Start new window
          windowStart = {
            tick = note.tick,
            velocity = note.velocity
          }
        elseif note.tick - windowStart.tick > thresholdTicks then
          -- Beyond threshold - emit window start, begin new window
          table.insert(coalesced, windowStart)
          windowStart = {
            tick = note.tick,
            velocity = note.velocity
          }
        end
        -- else: within threshold, ignore (first note already captured)
      end
    end

    -- Emit final window
    if windowStart then
      table.insert(coalesced, windowStart)
    end

  elseif mode == "loudest" then
    -- Loudest-wins coalescing
    local windowNotes = {}
    local windowStartTick = nil

    for _, note in ipairs(notes) do
      if note.isNoteOn then
        if not windowStartTick then
          windowStartTick = note.tick
          windowNotes = {note}
        elseif note.tick - windowStartTick <= thresholdTicks then
          -- Within window - collect
          table.insert(windowNotes, note)
        else
          -- Beyond threshold - emit loudest, start new window
          local loudest = windowNotes[1]
          for _, n in ipairs(windowNotes) do
            if n.velocity > loudest.velocity then
              loudest = n
            end
          end
          table.insert(coalesced, {tick = loudest.tick, velocity = loudest.velocity})

          windowStartTick = note.tick
          windowNotes = {note}
        end
      end
    end

    -- Emit final window
    if #windowNotes > 0 then
      local loudest = windowNotes[1]
      for _, n in ipairs(windowNotes) do
        if n.velocity > loudest.velocity then
          loudest = n
        end
      end
      table.insert(coalesced, {tick = loudest.tick, velocity = loudest.velocity})
    end

  else
    error("Invalid coalescing mode: " .. mode)
  end

  return coalesced
end

-- Get number of data bytes for channel message type
-- @param msgType number - upper nibble of status byte (0x80-0xE0)
-- @return number - data bytes count
local function getDataByteCount(msgType)
  if msgType == 0x80 or msgType == 0x90 or msgType == 0xA0 or msgType == 0xB0 or msgType == 0xE0 then
    return 2 -- note off, note on, poly pressure, control change, pitch bend
  elseif msgType == 0xC0 or msgType == 0xD0 then
    return 1 -- program change, channel pressure
  else
    return 0 -- unknown
  end
end

-- Parse MTrk (track) chunk and extract note events
-- @param data string - raw file bytes
-- @param pos number - start of MTrk chunk
-- @return table events[], number nextPos on success
-- @return nil, string error on failure
local function parseTrack(data, pos)
  -- Validate MTrk magic
  local chunkType
  chunkType, pos = string.unpack("c4", data, pos)
  if chunkType ~= "MTrk" then
    return nil, "Invalid MTrk magic: " .. chunkType
  end

  -- Read chunk size
  local chunkSize
  chunkSize, pos = string.unpack(">I4", data, pos)
  local chunkEnd = pos + chunkSize

  local events = {}
  local absoluteTick = 0
  local runningStatus = nil

  -- Parse events until chunk boundary
  -- ERR-02: Loop terminates at chunkEnd even if End-Of-Track missing
  while pos < chunkEnd do
    -- Boundary check before VLQ read
    if pos > #data then
      break -- truncated data, stop gracefully
    end

    -- Parse delta time
    local deltaTime, err
    deltaTime, pos = parseVLQ(data, pos)
    if not deltaTime then
      -- Truncated VLQ at end of track, stop gracefully
      break
    end
    absoluteTick = absoluteTick + deltaTime

    -- Boundary check before status byte
    if pos > #data then
      break
    end

    -- Read potential status byte
    local statusByte
    statusByte, pos = string.unpack("B", data, pos)

    -- Handle running status
    local actualStatus = statusByte
    if statusByte < 0x80 then
      -- Running status - use previous status, rewind pos
      if not runningStatus then
        -- No previous status but data byte received - skip
        break
      end
      actualStatus = runningStatus
      pos = pos - 1 -- rewind since this was data byte not status
    elseif statusByte >= 0x80 and statusByte < 0xF0 then
      -- Channel message - update running status
      runningStatus = statusByte
    elseif statusByte >= 0xF0 and statusByte <= 0xF7 then
      -- System Common - cancel running status
      runningStatus = nil
    end
    -- Real-time messages (0xF8-0xFF) don't affect running status

    -- Parse message by type
    local msgType = actualStatus & 0xF0
    local channel = actualStatus & 0x0F

    if msgType == 0x90 then
      -- Note On - needs 2 data bytes
      if pos + 1 > #data then break end
      local pitch, velocity
      pitch, velocity, pos = string.unpack("BB", data, pos)
      -- Note-on with velocity 0 is note-off
      local isNoteOn = velocity > 0
      table.insert(events, {
        tick = absoluteTick,
        pitch = pitch,
        velocity = velocity,
        channel = channel,
        isNoteOn = isNoteOn
      })
    elseif msgType == 0x80 then
      -- Note Off - needs 2 data bytes
      if pos + 1 > #data then break end
      local pitch, velocity
      pitch, velocity, pos = string.unpack("BB", data, pos)
      table.insert(events, {
        tick = absoluteTick,
        pitch = pitch,
        velocity = velocity,
        channel = channel,
        isNoteOn = false
      })
    elseif actualStatus == 0xFF then
      -- Meta event - needs type byte + length VLQ
      if pos > #data then break end
      local metaType, length
      metaType, pos = string.unpack("B", data, pos)
      length, pos = parseVLQ(data, pos)
      if not length then
        break -- truncated meta event length
      end
      -- Skip meta data (clamp to available data)
      local skipBytes = math.min(length, #data - pos + 1)
      pos = pos + skipBytes
      -- End-Of-Track (0x2F) - break loop
      if metaType == 0x2F then
        break
      end
    elseif actualStatus == 0xF0 or actualStatus == 0xF7 then
      -- SysEx
      local length
      length, pos = parseVLQ(data, pos)
      if not length then
        break -- truncated sysex length
      end
      -- Skip sysex data (clamp to available data)
      local skipBytes = math.min(length, #data - pos + 1)
      pos = pos + skipBytes
    elseif actualStatus >= 0xF1 and actualStatus <= 0xF6 then
      -- ERR-03: System Common messages (skip safely)
      -- F1 = MTC Quarter Frame (1 data byte)
      -- F2 = Song Position (2 data bytes)
      -- F3 = Song Select (1 data byte)
      -- F4, F5 = undefined (0 data bytes)
      -- F6 = Tune Request (0 data bytes)
      if actualStatus == 0xF2 then
        if pos + 1 > #data then break end
        pos = pos + 2
      elseif actualStatus == 0xF1 or actualStatus == 0xF3 then
        if pos > #data then break end
        pos = pos + 1
      end
      -- F4, F5, F6 have no data bytes, nothing to skip
    elseif msgType >= 0x80 and msgType < 0xF0 then
      -- Other channel message - skip data bytes
      local dataBytes = getDataByteCount(msgType)
      if pos + dataBytes - 1 > #data then break end
      pos = pos + dataBytes
    end
    -- else: unknown message type, continue to next iteration
  end

  return events, pos
end

----------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------

-- Parse MThd (header) chunk
-- @param data string - raw file bytes
-- @param pos number - start position (default 1)
-- @return table {format, ntracks, division}, number nextPos on success
-- @return nil, string error on failure
function SMFParser.parseHeader(data, pos)
  pos = pos or 1

  -- ERR-01: File size validation (14 = 4 MThd + 4 size + 6 data)
  if #data < 14 then
    return nil, "File too small (expected 14+ bytes for header)"
  end

  -- Validate MThd magic (4 bytes)
  local chunkType
  chunkType, pos = string.unpack("c4", data, pos)
  if chunkType ~= "MThd" then
    return nil, "Invalid MThd magic: " .. chunkType
  end

  -- Read chunk size (big-endian 4 bytes) - must be 6 for standard SMF
  local chunkSize
  chunkSize, pos = string.unpack(">I4", data, pos)
  if chunkSize ~= 6 then
    return nil, "Invalid MThd size: " .. chunkSize .. " (expected 6)"
  end

  -- Read header fields (all big-endian 2 bytes each)
  local format, ntracks, division
  format, ntracks, division, pos = string.unpack(">I2I2I2", data, pos)

  return {
    format = format,    -- 0=single track, 1=multi track, 2=patterns
    ntracks = ntracks,  -- number of tracks
    division = division -- ticks per quarter (PPQ) if bit 15 clear
  }, pos
end

-- Extract note events from all tracks in SMF file
-- @param data string - raw file bytes
-- @param header table - from parseHeader() with format, ntracks, division
-- @return table notes[] on success (sorted by tick)
-- @return nil, string error on failure
function SMFParser.extractNotes(data, header)
  local allNotes = {}
  local pos = 15 -- after 14-byte MThd chunk (4 magic + 4 size + 6 data)

  -- Parse all tracks
  for trackIdx = 1, header.ntracks do
    -- Boundary check: need at least 8 bytes for track header (4 MTrk + 4 size)
    if pos + 8 > #data then
      return nil, "Unexpected end of file (track " .. trackIdx .. " header)"
    end

    local events, err = parseTrack(data, pos)
    if not events then
      return nil, "Track " .. trackIdx .. " parse error: " .. err
    end

    -- Merge track events into allNotes
    for _, event in ipairs(events) do
      table.insert(allNotes, event)
    end

    pos = err -- parseTrack returns nextPos as second value
  end

  -- Sort by tick (stable sort for same-tick events)
  table.sort(allNotes, function(a, b)
    return a.tick < b.tick
  end)

  return allNotes
end

-- Parse complete SMF file (convenience wrapper)
-- @param data string - raw file bytes from io.read('*all')
-- @return table {header=header, notes=notes} on success
-- @return nil, string error on failure
function SMFParser.parse(data)
  local header, err = SMFParser.parseHeader(data)
  if not header then
    return nil, err
  end

  -- Validate format (Type 2 not supported)
  if header.format == 2 then
    return nil, "Type 2 SMF not supported"
  end

  local notes, err = SMFParser.extractNotes(data, header)
  if not notes then
    return nil, err
  end

  return {header = header, notes = notes}
end

-- Extract groove template from note events
-- @param notes table[] - from extractNotes() with {tick, velocity, isNoteOn, ...}
-- @param header table - from parseHeader() with {division, ...}
-- @param options table - optional {threshold=N, thresholdMode="ticks"|"percent"|"ms",
--                         coalescingMode="first"|"loudest", tempo=500000}
-- @return table {version=1, nBeats=N, positions[]{beat, amplitude}} on success
-- @return nil, string error on failure
function SMFParser.extractGroove(notes, header, options)
  options = options or {}

  -- Default options
  local threshold = options.threshold or (header.division / 64) -- 1/64 note default
  local thresholdMode = options.thresholdMode or "ticks"
  local coalescingMode = options.coalescingMode or "first"
  local tempo = options.tempo or 500000 -- 120 BPM

  -- Convert threshold to ticks
  local thresholdTicks = convertThresholdToTicks(threshold, thresholdMode, header.division, tempo)

  -- Enforce max threshold (1/4 note cap)
  local maxThreshold = header.division
  if thresholdTicks > maxThreshold then
    thresholdTicks = maxThreshold
  end

  -- Coalesce notes within threshold
  local coalesced = coalesceNotes(notes, thresholdTicks, coalescingMode)

  if #coalesced == 0 then
    return nil, "No notes found in MIDI file"
  end

  -- Convert ticks to beats
  local firstTick = coalesced[1].tick
  local lastTick = coalesced[#coalesced].tick

  local positions = {}
  for _, note in ipairs(coalesced) do
    local beat = (note.tick - firstTick) / header.division
    local amplitude = note.velocity / 127.0
    table.insert(positions, {beat = beat, amplitude = amplitude})
  end

  -- Calculate nBeats from span
  local nBeats = math.ceil((lastTick - firstTick) / header.division)
  if nBeats < 1 then nBeats = 1 end

  return {
    version = 1,
    nBeats = nBeats,
    positions = positions
  }
end

----------------------------------------------------------------------------------------

return SMFParser
