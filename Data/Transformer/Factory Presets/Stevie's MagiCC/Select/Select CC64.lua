package.path = reaper.GetResourcePath() .. "/Scripts/sockmonkey72 Scripts/MIDI Editor/Transformer/?.lua"
local tx = require("TransformerLib")
local thisPath = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]]
tx.loadPreset(thisPath .. "Select CC64.tfmrPreset")
tx.processAction(true)
