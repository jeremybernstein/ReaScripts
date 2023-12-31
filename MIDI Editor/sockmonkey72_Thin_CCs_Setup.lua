--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

local reaper = reaper

local _, _, sectionID = reaper.get_action_context()
-- ---------------- MIDI Editor ---------- Event List ------- Inline Editor
local isME = sectionID == 32060 or sectionID == 32061 or sectionID == 32062
if not isME then return end

local defaultReduction = '5'
local defaultPbscale = '10'

if reaper.HasExtState('sockmonkey72_ThinCCs', 'level') then
  defaultReduction = reaper.GetExtState('sockmonkey72_ThinCCs', 'level')
end
if reaper.HasExtState('sockmonkey72_ThinCCs', 'pbscale') then
  defaultPbscale = reaper.GetExtState('sockmonkey72_ThinCCs', 'pbscale')
end

local rv, retvals_csv = reaper.GetUserInputs('Thin CCs', 2, 'Reduction Level,Pitch Bend Scale', defaultReduction..','..defaultPbscale)
if rv ~= true then return end

local reduction, pbscale = retvals_csv:match('([^,]+),([^,]+)')

reduction = tonumber(reduction)
if not reduction then reduction = 5 end
if reduction < 0 then reduction = 0 elseif reduction > 50 then reduction = 50 end

pbscale = tonumber(pbscale)
if not pbscale then pbscale = 10 end
if pbscale < 1 then pbscale = 1 elseif pbscale > 100 then reduction = 100 end

reaper.SetExtState('sockmonkey72_ThinCCs', 'level', tostring(math.floor(reduction)), true)
reaper.SetExtState('sockmonkey72_ThinCCs', 'pbscale', tostring(math.floor(pbscale)), true)
