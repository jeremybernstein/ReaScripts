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

local defaultReduction = "5"
if reaper.HasExtState("sockmonkey72_ThinCCs", "level") then
  defaultReduction = reaper.GetExtState("sockmonkey72_ThinCCs", "level")
end
local rv, retvals_csv = reaper.GetUserInputs("Thin CCs", 1, "Reduction Level", defaultReduction)
if rv ~= true then return end

local reduction = tonumber(retvals_csv)
if not reduction then reduction = 5 end
if reduction < 0 then reduction = 0 elseif reduction > 50 then reduction = 50 end

reaper.SetExtState("sockmonkey72_ThinCCs", "level", tostring(math.floor(reduction)), true)
