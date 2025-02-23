-- @description Calculate Project Media Footprint
-- @version 1.0.0
-- @author sockmonkey72
-- @about
--   # Calculate Project Media Footprint
--   Calculate the total size of media (audio files, etc.),
--   peak files and the RPP file on disk, in KB, MB and GB.
--   Thanks to McSound for the idea, and for the code contribution!
-- @changelog
--   - initial release (media, peaks and RPP)
-- @provides
--   [main] sockmonkey72_CalcProjectMediaFootprint.lua

-- (c) 2025 Jeremy Bernstein / sockmonkey72
-- All uses permitted by all REAPER users except for F1308, who may not use it for any purpose

-- Thanks to McSound for inspiring this script, and for discovering the
-- special sauce about REAPER's handling of identically-named files (at
-- different paths) with same vs different sizes.

local r = reaper

local units = 1024
-- local units = 1000 -- macos seems to use 1000-based file size calculations

local function getFileName(path)
  -- Match the last occurrence of either / or \ followed by any non-slash chars until end
  local filename = path:match("[^/\\]*$")
  return filename
end

local function getFileSize(path)
  local eof
  local file = io.open(path, "rb")
  if file then
    eof = file:seek('end')
    file:close()
  -- else
  --   r.ShowConsoleMsg('cannot open ' .. path .. ' for reading\n')
  end
  return eof
end


local function getTotalSize()
  local totalbytesize = 0
  local processedFiles = {}  -- track files we've already counted
  local processedFileSizes = {}

  local itemCount = r.CountMediaItems(0)
  for i = 0, itemCount - 1 do
    local item = r.GetMediaItem(0, i)
    if item then
      local takeCount = r.CountTakes(item)

      for t = 0, takeCount - 1 do
        local take = r.GetTake(item, t)
        if take then
          local source = r.GetMediaItemTake_Source(take)
          if source then
            local parent = r.GetMediaSourceParent(source)
            while parent do
              source = parent
              parent = r.GetMediaSourceParent(source)
            end
            local filePath = r.GetMediaSourceFileName(source)
            if filePath and not processedFiles[filePath] then
              processedFiles[filePath] = true

              local fileName = getFileName(filePath)
              if not processedFileSizes[fileName] then processedFileSizes[fileName] = {} end

              local eof = getFileSize(filePath)
              if eof then
                -- REAPER will consolidate files with the same name and the same size
                -- so we need this additional logic. Thanks McSound for figuring that out.
                local skip = false
                for _, sz in ipairs(processedFileSizes[fileName]) do
                  if sz == eof then
                    skip = true
                    break
                  end
                end
                if not skip then
                  table.insert(processedFileSizes[fileName], eof)
                  totalbytesize = totalbytesize + eof
                end
              end

              local peakFilePath = r.GetPeakFileName(filePath)
              if peakFilePath and not processedFiles[peakFilePath] then
                processedFiles[peakFilePath] = true
                eof = getFileSize(peakFilePath)
                if eof then
                  totalbytesize = totalbytesize + eof
                end
              end

              local _, projectFilePath = reaper.EnumProjects(-1)
              if projectFilePath then
                eof = getFileSize(projectFilePath)
                if eof then
                  totalbytesize = totalbytesize + eof
                end
              end
            end
          end
        end
      end
    end
  end

  return totalbytesize
end

local size = getTotalSize()

r.ShowConsoleMsg('Total Size of Project Media in KB: ' .. string.format("%.2f", size / units) .. ' KB\n')
r.ShowConsoleMsg('Total Size of Project Media in MB: ' .. string.format("%.2f", size / (units * units)) .. ' MB\n')
r.ShowConsoleMsg('Total Size of Project Media in GB: ' .. string.format("%.2f", size / (units * units * units)) .. ' GB\n')

