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
    extractEvents(data, header, flags) - extract all event types from all tracks
    extractNotes(data, header) - extract notes only (wrapper for extractEvents)
    parse(data, flags) - convenience wrapper for parseHeader + extractEvents
    extractGroove(notes, header, opts) - convert notes to .rgt groove format

  Flags:
    flags.notes - include note on/off events (default true, explicit false skips)
    flags.events - include channel events: CC, pitch bend, etc (default false)
    flags.meta - include meta events: tempo, time sig, text, etc (default false)
    flags.sysex - include SysEx events with data array (default false)
    flags.absoluteTime - build tempo map for tick-to-time conversion (default false)
    flags.preserveTracks - return tracks table instead of flat array (default false)

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

-- Format SysEx data as hex string for debugging
-- @param bytes table - byte array starting with F0
-- @return string - hex representation "F0 43 10 ..."
local function sysexPrettyPrint(bytes)
  local parts = {}
  for _, b in ipairs(bytes) do
    table.insert(parts, string.format("%02X", b))
  end
  return table.concat(parts, " ")
end

-- Build tempo map from tempo events
-- @param events table[] - parsed events (must include meta events)
-- @param ppq number - ticks per quarter note
-- @return table {changes=[], tempoAt=fn, tickToTime=fn}
local function buildTempoMap(events, ppq)
  local changes = {}
  local defaultTempo = 500000  -- 120 BPM

  -- Collect tempo changes from events
  for _, e in ipairs(events) do
    if e.type == "tempo" then
      table.insert(changes, {
        tick = e.tick,
        uspb = e.microseconds_per_quarter,
        bpm = e.bpm
      })
    end
  end

  -- Sort by tick (should already be sorted, but ensure)
  table.sort(changes, function(a, b) return a.tick < b.tick end)

  -- Remove duplicates at same tick (keep last)
  local deduped = {}
  for _, c in ipairs(changes) do
    if #deduped == 0 or deduped[#deduped].tick ~= c.tick then
      table.insert(deduped, c)
    else
      deduped[#deduped] = c  -- replace with later one
    end
  end
  changes = deduped

  -- Mark if no tempo specified (use default)
  local hasExplicitTempo = #changes > 0

  -- tempoAt lookup
  local function tempoAt(tick)
    local currentUspb = defaultTempo
    for _, c in ipairs(changes) do
      if c.tick <= tick then
        currentUspb = c.uspb
      else
        break
      end
    end
    return currentUspb, 60000000 / currentUspb  -- uspb, bpm
  end

  -- tickToTime conversion
  local function tickToTime(tick)
    local totalMicroseconds = 0
    local prevTick = 0
    local prevTempo = defaultTempo

    for _, c in ipairs(changes) do
      if c.tick <= tick then
        -- Add time from prevTick to this change
        local deltaTicks = c.tick - prevTick
        local deltaMicroseconds = (deltaTicks / ppq) * prevTempo
        totalMicroseconds = totalMicroseconds + deltaMicroseconds
        prevTick = c.tick
        prevTempo = c.uspb
      else
        break
      end
    end

    -- Add remaining time from last change to target tick
    local deltaTicks = tick - prevTick
    local deltaMicroseconds = (deltaTicks / ppq) * prevTempo
    totalMicroseconds = totalMicroseconds + deltaMicroseconds

    local ms = totalMicroseconds / 1000
    local sec = string.format("%.6f", ms / 1000) + 0  -- 6 decimal places
    return {ms = ms, sec = sec}
  end

  return {
    changes = changes,
    tempoAt = tempoAt,
    tickToTime = tickToTime,
    hasExplicitTempo = hasExplicitTempo
  }
end

-- Parse MTrk (track) chunk and extract note events
-- @param data string - raw file bytes
-- @param pos number - start of MTrk chunk
-- @param flags table - optional {notes=bool, events=bool, meta=bool} to control output
-- @return table events[], number nextPos on success
-- @return nil, string error on failure
local function parseTrack(data, pos, flags)
  flags = flags or {}
  local includeNotes = flags.notes ~= false
  local includeEvents = flags.events == true
  local includeMeta = flags.meta == true
  local includeSysex = flags.sysex == true

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
      if includeNotes then
        table.insert(events, {
          tick = absoluteTick,
          pitch = pitch,
          velocity = velocity,
          channel = channel,
          isNoteOn = isNoteOn
        })
      end
    elseif msgType == 0x80 then
      -- Note Off - needs 2 data bytes
      if pos + 1 > #data then break end
      local pitch, velocity
      pitch, velocity, pos = string.unpack("BB", data, pos)
      if includeNotes then
        table.insert(events, {
          tick = absoluteTick,
          pitch = pitch,
          velocity = velocity,
          channel = channel,
          isNoteOn = false
        })
      end
    elseif actualStatus == 0xFF then
      -- Meta event
      if pos > #data then break end
      local metaType, length
      metaType, pos = string.unpack("B", data, pos)
      length, pos = parseVLQ(data, pos)
      if not length then break end

      if metaType == 0x51 and length == 3 then
        -- Tempo (META-01)
        if pos + 2 > #data then break end
        local microseconds_per_quarter
        microseconds_per_quarter, pos = string.unpack(">I3", data, pos)
        if includeMeta then
          table.insert(events, {
            type = "tempo",
            tick = absoluteTick,
            microseconds_per_quarter = microseconds_per_quarter,
            bpm = 60000000 / microseconds_per_quarter
          })
        end
      elseif metaType == 0x58 and length == 4 then
        -- Time Signature (META-02)
        if pos + 3 > #data then break end
        local nn, dd, cc, bb
        nn, dd, cc, bb, pos = string.unpack("BBBB", data, pos)
        if includeMeta then
          table.insert(events, {
            type = "time_sig",
            tick = absoluteTick,
            numerator = nn,
            denominator = 1 << dd,  -- 2^dd
            clocks_per_click = cc,
            thirtysecondsPerQuarter = bb
          })
        end
      elseif metaType == 0x59 and length == 2 then
        -- Key Signature (META-03)
        if pos + 1 > #data then break end
        local sf, mi
        sf, mi, pos = string.unpack("bb", data, pos)  -- signed bytes
        local keyNames = {
          [-7] = {"Cb major", "Ab minor"},
          [-6] = {"Gb major", "Eb minor"},
          [-5] = {"Db major", "Bb minor"},
          [-4] = {"Ab major", "F minor"},
          [-3] = {"Eb major", "C minor"},
          [-2] = {"Bb major", "G minor"},
          [-1] = {"F major", "D minor"},
          [0] = {"C major", "A minor"},
          [1] = {"G major", "E minor"},
          [2] = {"D major", "B minor"},
          [3] = {"A major", "F# minor"},
          [4] = {"E major", "C# minor"},
          [5] = {"B major", "G# minor"},
          [6] = {"F# major", "D# minor"},
          [7] = {"C# major", "A# minor"}
        }
        local keyName = keyNames[sf] and keyNames[sf][mi + 1] or "Unknown"
        if includeMeta then
          table.insert(events, {
            type = "key_sig",
            tick = absoluteTick,
            sf = sf,
            mi = mi,
            key_name = keyName
          })
        end
      elseif metaType >= 0x01 and metaType <= 0x07 then
        -- Text events (META-04, META-05, META-06, META-07)
        local textTypeNames = {
          [0x01] = "text",
          [0x02] = "copyright",
          [0x03] = "track_name",
          [0x04] = "instrument_name",
          [0x05] = "lyric",
          [0x06] = "marker",
          [0x07] = "cue_point"
        }
        local textLength = math.min(length, #data - pos + 1)
        local text = data:sub(pos, pos + textLength - 1)
        pos = pos + textLength
        if includeMeta then
          table.insert(events, {
            type = "meta",
            text_type = textTypeNames[metaType],
            tick = absoluteTick,
            text = text
          })
        end
      elseif metaType == 0x00 and length == 2 then
        -- Sequence Number
        if pos + 1 > #data then break end
        local seqNum
        seqNum, pos = string.unpack(">I2", data, pos)
        if includeMeta then
          table.insert(events, {
            type = "sequence_number",
            tick = absoluteTick,
            value = seqNum
          })
        end
      elseif metaType == 0x2F then
        -- End of Track
        if includeMeta then
          table.insert(events, {
            type = "end_of_track",
            tick = absoluteTick
          })
        end
        -- Skip any length bytes (should be 0)
        local skipBytes = math.min(length, #data - pos + 1)
        pos = pos + skipBytes
        break  -- exit loop
      else
        -- Unknown meta - skip data, optionally capture
        local skipBytes = math.min(length, #data - pos + 1)
        if includeMeta then
          table.insert(events, {
            type = "unknown_meta",
            tick = absoluteTick,
            raw_type = metaType,
            raw_data = data:sub(pos, pos + skipBytes - 1)
          })
        end
        pos = pos + skipBytes
      end
    elseif actualStatus == 0xF0 or actualStatus == 0xF7 then
      -- SysEx
      local length
      length, pos = parseVLQ(data, pos)
      if not length then
        break -- truncated sysex length
      end

      -- Read sysex data (clamp to available data)
      local readBytes = math.min(length, #data - pos + 1)
      local sysexData = {}

      if actualStatus == 0xF0 then
        -- Start of SysEx - include F0 at start
        table.insert(sysexData, 0xF0)
      end

      -- Read data bytes
      for i = 1, readBytes do
        local byte
        byte, pos = string.unpack("B", data, pos)
        table.insert(sysexData, byte)
      end

      -- Check if message is complete (ends with F7)
      local isComplete = false
      if #sysexData > 0 and sysexData[#sysexData] == 0xF7 then
        isComplete = true
      end

      -- If F7 continuation, try to append to previous incomplete sysex
      if actualStatus == 0xF7 and #events > 0 then
        local prevEvent = events[#events]
        if prevEvent.type == "sysex" and not prevEvent.complete then
          -- Append to previous incomplete sysex
          for i = 1, #sysexData do
            table.insert(prevEvent.data, sysexData[i])
          end
          prevEvent.complete = isComplete
        elseif includeSysex then
          -- F7 escape sequence - treat as standalone
          table.insert(events, {
            type = "sysex",
            tick = absoluteTick,
            data = sysexData,
            complete = isComplete
          })
        end
      elseif includeSysex then
        -- F0 start - insert new event
        table.insert(events, {
          type = "sysex",
          tick = absoluteTick,
          data = sysexData,
          complete = isComplete
        })
      end
    elseif msgType == 0xA0 then
      -- Poly Pressure (Aftertouch) - 2 data bytes
      if pos + 1 > #data then break end
      local note, pressure
      note, pressure, pos = string.unpack("BB", data, pos)
      if includeEvents then
        table.insert(events, {
          type = "poly_pressure",
          tick = absoluteTick,
          channel = channel,
          note = note,
          pressure = pressure
        })
      end
    elseif msgType == 0xB0 then
      -- Control Change - 2 data bytes
      if pos + 1 > #data then break end
      local cc_number, value
      cc_number, value, pos = string.unpack("BB", data, pos)
      if includeEvents then
        table.insert(events, {
          type = "cc",
          tick = absoluteTick,
          channel = channel,
          cc_number = cc_number,
          value = value
        })
      end
    elseif msgType == 0xC0 then
      -- Program Change - 1 data byte
      if pos > #data then break end
      local program
      program, pos = string.unpack("B", data, pos)
      if includeEvents then
        table.insert(events, {
          type = "program_change",
          tick = absoluteTick,
          channel = channel,
          program = program
        })
      end
    elseif msgType == 0xD0 then
      -- Channel Pressure (Aftertouch) - 1 data byte
      if pos > #data then break end
      local pressure
      pressure, pos = string.unpack("B", data, pos)
      if includeEvents then
        table.insert(events, {
          type = "channel_pressure",
          tick = absoluteTick,
          channel = channel,
          pressure = pressure
        })
      end
    elseif msgType == 0xE0 then
      -- Pitch Bend - 2 data bytes (LSB, MSB -> 14-bit value)
      if pos + 1 > #data then break end
      local lsb, msb
      lsb, msb, pos = string.unpack("BB", data, pos)
      local value = (msb << 7) | lsb  -- 14-bit: 0-16383, center at 8192
      if includeEvents then
        table.insert(events, {
          type = "pitch_bend",
          tick = absoluteTick,
          channel = channel,
          value = value
        })
      end
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
-- @return table header, number nextPos on success
--   PPQ files: {format, ntracks, division}
--   SMPTE files: {format, ntracks, smpte_format, ticks_per_frame}
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

  -- Check if SMPTE timing (bit 15 set) or PPQ
  local header = {
    format = format,    -- 0=single track, 1=multi track, 2=patterns
    ntracks = ntracks   -- number of tracks
  }

  if division & 0x8000 ~= 0 then
    -- SMPTE timing: bits 15-8 = signed frame rate (negative), bits 7-0 = ticks/frame
    local byte_high = (division >> 8) & 0xFF
    -- Interpret upper byte as signed (-24, -25, -29, -30)
    local smpte_format = byte_high
    if smpte_format >= 128 then
      smpte_format = smpte_format - 256
    end
    local ticks_per_frame = division & 0xFF
    header.smpte_format = smpte_format
    header.ticks_per_frame = ticks_per_frame
    -- division not applicable for SMPTE
  else
    -- PPQ timing
    header.division = division -- ticks per quarter (PPQ)
  end

  return header, pos
end

-- Extract note events from all tracks in SMF file
-- Extract all event types from all tracks
-- @param data string - raw file bytes
-- @param header table - from parseHeader() with format, ntracks, division
-- @param flags table - optional {notes, events, meta, sysex, preserveTracks}
--   preserveTracks - if true, return tracks table instead of flat array
-- @return table events[] on success (sorted by tick) OR tracks table if preserveTracks=true
-- @return nil, string error on failure
function SMFParser.extractEvents(data, header, flags)
  flags = flags or {}
  local includeNotes = flags.notes ~= false
  local preserveTracks = flags.preserveTracks == true

  local tracks = preserveTracks and {} or nil
  local allNotes = not preserveTracks and {} or nil
  local pos = 15 -- after 14-byte MThd chunk (4 magic + 4 size + 6 data)

  -- Parse all tracks
  for trackIdx = 1, header.ntracks do
    -- Boundary check: need at least 8 bytes for track header (4 MTrk + 4 size)
    if pos + 8 > #data then
      return nil, "Unexpected end of file (track " .. trackIdx .. " header)"
    end

    local events, err = parseTrack(data, pos, flags)
    if not events then
      return nil, "Track " .. trackIdx .. " parse error: " .. err
    end

    if preserveTracks then
      -- Extract track name from events
      local trackName = nil
      for _, e in ipairs(events) do
        if e.type == "meta" and e.text_type == "track_name" then
          trackName = e.text
          break
        end
      end

      tracks[trackIdx] = {
        index = trackIdx,
        name = trackName,
        events = events
      }
    else
      -- Merge track events into allNotes (existing behavior)
      for _, event in ipairs(events) do
        table.insert(allNotes, event)
      end
    end

    pos = err -- parseTrack returns nextPos as second value
  end

  if preserveTracks then
    -- Return tracks table (no sorting - each track already tick-ordered)
    return tracks
  else
    -- Sort by tick (stable sort for same-tick events)
    table.sort(allNotes, function(a, b)
      return a.tick < b.tick
    end)
    return allNotes
  end
end

-- Extract notes only (convenience wrapper for extractEvents)
-- @param data string - raw file bytes
-- @param header table - from parseHeader()
-- @return table notes[] on success
function SMFParser.extractNotes(data, header)
  return SMFParser.extractEvents(data, header, {notes = true})
end

-- Parse complete SMF file (convenience wrapper)
-- @param data string - raw file bytes from io.read('*all')
-- @param flags table - optional {notes=bool, events=bool, meta=bool, sysex=bool, absoluteTime=bool, preserveTracks=bool}
--   flags.absoluteTime - if true, build tempo map for tick-to-time conversion (forces meta=true)
--   flags.preserveTracks - if true, return tracks table instead of flat notes array
-- @return table {header=header, notes=notes[, tempoMap=tempoMap]} on success
--   OR {header=header, tracks=tracks[, tempoMap=tempoMap]} if preserveTracks=true
--   tempoMap (if flags.absoluteTime): {changes=[], tempoAt=fn, tickToTime=fn, hasExplicitTempo=bool}
-- @return nil, string error on failure
function SMFParser.parse(data, flags)
  flags = flags or {}

  local header, err = SMFParser.parseHeader(data)
  if not header then
    return nil, err
  end

  -- Validate format (Type 2 not supported)
  if header.format == 2 then
    return nil, "Type 2 SMF not supported"
  end

  -- Force meta=true if absoluteTime requested (need tempo events)
  if flags.absoluteTime then
    flags.meta = true
  end

  local notes, err = SMFParser.extractEvents(data, header, flags)
  if not notes then
    return nil, err
  end

  local result
  if flags.preserveTracks then
    result = {header = header, tracks = notes}  -- notes is actually tracks table here
  else
    result = {header = header, notes = notes}
  end

  if flags.absoluteTime and header.division then
    -- Build tempo map (requires tempo events)
    local tempoEvents
    if flags.preserveTracks then
      -- Collect tempo events from all tracks
      tempoEvents = {}
      for _, track in pairs(notes) do
        for _, e in ipairs(track.events) do
          if e.type == "tempo" then
            table.insert(tempoEvents, e)
          end
        end
      end
    else
      -- Flat array case (from 17-02)
      tempoEvents = notes
    end
    -- Skip SMPTE files (header.division==nil) - absolute time not applicable via tempo
    result.tempoMap = buildTempoMap(tempoEvents, header.division)
  end

  return result
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
-- Inline Tests
----------------------------------------------------------------------------------------

-- Run with: lua SMFParser.lua
if arg and arg[0] and arg[0]:find("SMFParser") then
  print("Running SMFParser inline tests...")

  -- Minimal valid SMF: Type 0, 1 track, 96 PPQ, empty track with EOT
  local testSMF = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
                .. "MTrk" .. string.pack(">I4", 4) .. "\x00\xFF\x2F\x00"

  -- Test 1: parse() with no flags (backward compat)
  local result, err = SMFParser.parse(testSMF)
  assert(result, "parse() failed: " .. (err or ""))
  assert(result.header.division == 96, "PPQ mismatch")
  print("  [PASS] parse() backward compat")

  -- Test 2: parse() with flags.notes=true (explicit)
  result = SMFParser.parse(testSMF, {notes = true})
  assert(result, "parse(flags.notes=true) failed")
  print("  [PASS] parse(flags.notes=true)")

  -- Test 3: parse() with flags.notes=false
  result = SMFParser.parse(testSMF, {notes = false})
  assert(result, "parse(flags.notes=false) failed")
  assert(type(result.notes) == "table", "notes should be table")
  print("  [PASS] parse(flags.notes=false)")

  -- Test 4: extractNotes() with no flags
  local header = {format = 0, ntracks = 1, division = 96}
  local notes = SMFParser.extractNotes(testSMF, header)
  assert(notes, "extractNotes() failed")
  print("  [PASS] extractNotes() backward compat")

  -- Test 5: flags.events=true captures CC
  local ccTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
               .. "MTrk" .. string.pack(">I4", 8)
               .. "\x00\xB0\x07\x64"  -- delta 0, CC ch0, cc#7, value 100
               .. "\x00\xFF\x2F\x00"  -- EOT
  result = SMFParser.parse(ccTrack, {events = true})
  assert(result, "parse with CC failed")
  local foundCC = false
  for _, e in ipairs(result.notes) do
    if e.type == "cc" and e.cc_number == 7 and e.value == 100 then
      foundCC = true
    end
  end
  assert(foundCC, "CC event not found")
  print("  [PASS] flags.events=true captures CC")

  -- Test 6: flags.events absent skips CC
  result = SMFParser.parse(ccTrack)
  foundCC = false
  for _, e in ipairs(result.notes) do
    if e.type == "cc" then foundCC = true end
  end
  assert(not foundCC, "CC should be skipped without flags.events")
  print("  [PASS] flags.events absent skips CC")

  -- Test 7: Pitch Bend 14-bit value
  local pbTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
               .. "MTrk" .. string.pack(">I4", 8)
               .. "\x00\xE0\x00\x40"  -- delta 0, PB ch0, LSB=0, MSB=64 -> 8192 (center)
               .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(pbTrack, {events = true})
  local foundPB = false
  for _, e in ipairs(result.notes) do
    if e.type == "pitch_bend" and e.value == 8192 then
      foundPB = true
    end
  end
  assert(foundPB, "Pitch Bend center value (8192) not found")
  print("  [PASS] Pitch Bend 14-bit reconstruction")

  -- Test 8: Tempo meta event
  local tempoTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
               .. "MTrk" .. string.pack(">I4", 10)
               .. "\x00\xFF\x51\x03\x07\xA1\x20"  -- tempo: 500000 microsec (120 BPM)
               .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(tempoTrack, {meta = true})
  assert(result, "parse with tempo failed")
  local foundTempo = false
  for _, e in ipairs(result.notes) do
    if e.type == "tempo" and e.microseconds_per_quarter == 500000 then
      assert(e.bpm == 120, "BPM should be 120")
      foundTempo = true
    end
  end
  assert(foundTempo, "Tempo event not found")
  print("  [PASS] Tempo meta event (META-01)")

  -- Test 9: Time Signature meta event
  local tsTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
             .. "MTrk" .. string.pack(">I4", 11)
             .. "\x00\xFF\x58\x04\x04\x02\x18\x08"  -- 4/4 time (nn=4, dd=2 -> 2^2=4)
             .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(tsTrack, {meta = true})
  local foundTS = false
  for _, e in ipairs(result.notes) do
    if e.type == "time_sig" and e.numerator == 4 and e.denominator == 4 then
      foundTS = true
    end
  end
  assert(foundTS, "Time Signature 4/4 not found")
  print("  [PASS] Time Signature meta event (META-02)")

  -- Test 10: Key Signature meta event
  local ksTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
             .. "MTrk" .. string.pack(">I4", 9)
             .. "\x00\xFF\x59\x02\x00\x00"  -- C major (sf=0, mi=0)
             .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(ksTrack, {meta = true})
  local foundKS = false
  for _, e in ipairs(result.notes) do
    if e.type == "key_sig" and e.key_name == "C major" then
      foundKS = true
    end
  end
  assert(foundKS, "Key Signature C major not found")
  print("  [PASS] Key Signature meta event (META-03)")

  -- Test 11: Track Name text event (META-04)
  local nameTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
               .. "MTrk" .. string.pack(">I4", 12)
               .. "\x00\xFF\x03\x04Test"  -- track name "Test"
               .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(nameTrack, {meta = true})
  local foundName = false
  for _, e in ipairs(result.notes) do
    if e.type == "meta" and e.text_type == "track_name" and e.text == "Test" then
      foundName = true
    end
  end
  assert(foundName, "Track Name not found")
  print("  [PASS] Track Name meta event (META-04)")

  -- Test 12: flags.meta absent skips meta events
  result = SMFParser.parse(tempoTrack)
  foundTempo = false
  for _, e in ipairs(result.notes) do
    if e.type == "tempo" then foundTempo = true end
  end
  assert(not foundTempo, "Tempo should be skipped without flags.meta")
  print("  [PASS] flags.meta absent skips meta events")

  -- Test 13: End of Track event captured
  result = SMFParser.parse(tempoTrack, {meta = true})
  local foundEOT = false
  for _, e in ipairs(result.notes) do
    if e.type == "end_of_track" then foundEOT = true end
  end
  assert(foundEOT, "End of Track event not found")
  print("  [PASS] End of Track event captured")

  -- Test 14: SysEx capture basic
  local sysexTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
                  .. "MTrk" .. string.pack(">I4", 11)
                  .. "\x00\xF0\x05\x7E\x00\x09\x01\xF7"  -- delta 0, F0 len=5, identity request
                  .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(sysexTrack, {sysex = true})
  local foundSysex = false
  for _, e in ipairs(result.notes) do
    if e.type == "sysex" and e.data[1] == 0xF0 and e.complete == true then
      foundSysex = true
      -- Verify full data: F0 7E 00 09 01 F7
      assert(#e.data == 6, "SysEx should have 6 bytes")
      assert(e.data[2] == 0x7E, "SysEx byte 2 should be 0x7E")
      assert(e.data[6] == 0xF7, "SysEx should end with F7")
    end
  end
  assert(foundSysex, "Complete SysEx not found")
  print("  [PASS] SysEx capture basic")

  -- Test 15: SysEx skipped without flag
  result = SMFParser.parse(sysexTrack)
  foundSysex = false
  for _, e in ipairs(result.notes) do
    if e.type == "sysex" then foundSysex = true end
  end
  assert(not foundSysex, "SysEx should be skipped without flags.sysex")
  print("  [PASS] SysEx skipped without flag")

  -- Test 16: Incomplete SysEx (no F7)
  local incompleteSysex = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
                       .. "MTrk" .. string.pack(">I4", 10)
                       .. "\x00\xF0\x03\x43\x10\x4C"  -- delta 0, F0 len=3, no terminator
                       .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(incompleteSysex, {sysex = true})
  foundSysex = false
  for _, e in ipairs(result.notes) do
    if e.type == "sysex" and e.complete == false then
      foundSysex = true
      assert(e.data[1] == 0xF0, "Incomplete SysEx should start with F0")
      assert(e.data[#e.data] ~= 0xF7, "Incomplete SysEx should not end with F7")
    end
  end
  assert(foundSysex, "Incomplete SysEx not found")
  print("  [PASS] Incomplete SysEx (no F7)")

  -- Test 17: SMPTE division detection
  local smpteHeader = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 0xE728)
                   .. "MTrk" .. string.pack(">I4", 4) .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(smpteHeader)
  assert(result.header.smpte_format == -25, "SMPTE format should be -25")
  assert(result.header.ticks_per_frame == 40, "Ticks per frame should be 40")
  assert(result.header.division == nil, "division should be nil for SMPTE")
  print("  [PASS] SMPTE division detection")

  -- Test 18: sysexPrettyPrint helper
  local hexStr = sysexPrettyPrint({0xF0, 0x43, 0x10})
  assert(hexStr == "F0 43 10", "sysexPrettyPrint should return 'F0 43 10'")
  print("  [PASS] sysexPrettyPrint helper")

  -- Test 19: Tempo map builds from tempo events
  local tempoMapTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
                     .. "MTrk" .. string.pack(">I4", 21)
                     .. "\x00\xFF\x51\x03\x07\xA1\x20"  -- tick 0: 500000 uspb (120 BPM)
                     .. "\x83\x60\xFF\x51\x03\x03\xD0\x90"  -- tick 480: 250000 uspb (240 BPM)
                     .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(tempoMapTrack, {absoluteTime = true})
  assert(result.tempoMap, "tempoMap should exist")
  assert(#result.tempoMap.changes == 2, "Should have 2 tempo changes")
  assert(result.tempoMap.hasExplicitTempo == true, "Should have explicit tempo")
  assert(result.tempoMap.changes[1].tick == 0, "First tempo at tick 0")
  assert(result.tempoMap.changes[1].uspb == 500000, "First tempo 500000 uspb")
  assert(result.tempoMap.changes[2].tick == 480, "Second tempo at tick 480")
  assert(result.tempoMap.changes[2].uspb == 250000, "Second tempo 250000 uspb")
  print("  [PASS] Tempo map builds from tempo events")

  -- Test 20: tempoAt() returns correct tempo
  local uspb1, bpm1 = result.tempoMap.tempoAt(0)
  assert(uspb1 == 500000, "tempoAt(0) should return 500000")
  assert(bpm1 == 120, "tempoAt(0) BPM should be 120")
  local uspb2, bpm2 = result.tempoMap.tempoAt(480)
  assert(uspb2 == 250000, "tempoAt(480) should return 250000")
  assert(bpm2 == 240, "tempoAt(480) BPM should be 240")
  local uspb3, bpm3 = result.tempoMap.tempoAt(240)
  assert(uspb3 == 500000, "tempoAt(240) should return 500000 (between changes)")
  print("  [PASS] tempoAt() returns correct tempo")

  -- Test 21: tickToTime() conversion
  local time0 = result.tempoMap.tickToTime(0)
  assert(time0.ms == 0, "tick 0 should be 0ms")
  local time96 = result.tempoMap.tickToTime(96)  -- 1 beat at 120 BPM = 500ms
  assert(math.abs(time96.ms - 500) < 0.01, "tick 96 should be ~500ms")
  -- After tick 480 (tempo change to 240 BPM), 1 beat = 250ms
  -- tick 576 = tick 480 + 96 ticks
  -- Time to tick 480: (480/96) * 500000 / 1000 = 2500ms
  -- Time from 480 to 576: (96/96) * 250000 / 1000 = 250ms
  -- Total: 2750ms
  local time576 = result.tempoMap.tickToTime(576)
  assert(math.abs(time576.ms - 2750) < 0.01, "tick 576 should be ~2750ms")
  print("  [PASS] tickToTime() conversion")

  -- Test 22: Default tempo when no tempo events
  local noTempoTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
                    .. "MTrk" .. string.pack(">I4", 4) .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(noTempoTrack, {absoluteTime = true})
  assert(result.tempoMap.hasExplicitTempo == false, "Should not have explicit tempo")
  local defaultUspb, defaultBpm = result.tempoMap.tempoAt(0)
  assert(defaultUspb == 500000, "Default tempo should be 500000 uspb (120 BPM)")
  assert(defaultBpm == 120, "Default BPM should be 120")
  print("  [PASS] Default tempo when no tempo events")

  -- Test 23: Duplicate tempo at same tick keeps last
  local dupTempoTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
                     .. "MTrk" .. string.pack(">I4", 17)
                     .. "\x00\xFF\x51\x03\x07\xA1\x20"  -- tick 0: 500000 uspb
                     .. "\x00\xFF\x51\x03\x03\xD0\x90"  -- tick 0: 250000 uspb (duplicate)
                     .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(dupTempoTrack, {absoluteTime = true})
  assert(#result.tempoMap.changes == 1, "Should dedupe to 1 tempo change")
  assert(result.tempoMap.changes[1].uspb == 250000, "Should keep last tempo (250000)")
  print("  [PASS] Duplicate tempo at same tick keeps last")

  -- Test 24: preserveTracks=true returns tracks table
  local type1SMF = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 1, 2, 96)
                .. "MTrk" .. string.pack(">I4", 4) .. "\x00\xFF\x2F\x00"  -- track 1
                .. "MTrk" .. string.pack(">I4", 4) .. "\x00\xFF\x2F\x00"  -- track 2
  result = SMFParser.parse(type1SMF, {preserveTracks = true})
  assert(result.tracks, "result.tracks should exist")
  assert(result.tracks[1], "result.tracks[1] should exist")
  assert(result.tracks[2], "result.tracks[2] should exist")
  assert(result.notes == nil, "result.notes should be nil")
  print("  [PASS] preserveTracks=true returns tracks table")

  -- Test 25: Track name extraction
  local namedTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 0, 1, 96)
                  .. "MTrk" .. string.pack(">I4", 13)
                  .. "\x00\xFF\x03\x05Piano"  -- track name "Piano"
                  .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(namedTrack, {preserveTracks = true, meta = true})
  assert(result.tracks[1].name == "Piano", "Track name should be 'Piano'")
  print("  [PASS] Track name extraction")

  -- Test 26: Default behavior flattens (backward compat)
  local twoTrackSMF = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 1, 2, 96)
                   .. "MTrk" .. string.pack(">I4", 8)
                   .. "\x00\x90\x3C\x40"  -- note on C4
                   .. "\x00\xFF\x2F\x00"
                   .. "MTrk" .. string.pack(">I4", 8)
                   .. "\x00\x90\x40\x50"  -- note on E4
                   .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(twoTrackSMF)
  assert(result.notes, "result.notes should exist")
  assert(#result.notes == 2, "Should have 2 notes")
  assert(result.tracks == nil, "result.tracks should be nil")
  print("  [PASS] Default behavior flattens (backward compat)")

  -- Test 27: Empty tracks preserved
  local emptyMiddleTrack = "MThd" .. string.pack(">I4", 6) .. string.pack(">I2I2I2", 1, 3, 96)
                        .. "MTrk" .. string.pack(">I4", 8)
                        .. "\x00\x90\x3C\x40"  -- track 1 with note
                        .. "\x00\xFF\x2F\x00"
                        .. "MTrk" .. string.pack(">I4", 4)
                        .. "\x00\xFF\x2F\x00"  -- track 2 empty
                        .. "MTrk" .. string.pack(">I4", 8)
                        .. "\x00\x90\x40\x50"  -- track 3 with note
                        .. "\x00\xFF\x2F\x00"
  result = SMFParser.parse(emptyMiddleTrack, {preserveTracks = true})
  assert(result.tracks[2], "Empty track 2 should exist")
  assert(#result.tracks[2].events == 0, "Track 2 should have empty events array")
  print("  [PASS] Empty tracks preserved")

  -- Test 28: Track index in track structure
  result = SMFParser.parse(type1SMF, {preserveTracks = true})
  assert(result.tracks[1].index == 1, "Track 1 index should be 1")
  assert(result.tracks[2].index == 2, "Track 2 index should be 2")
  print("  [PASS] Track index in track structure")

  print("All tests passed! (28 total)")
end

----------------------------------------------------------------------------------------

return SMFParser
