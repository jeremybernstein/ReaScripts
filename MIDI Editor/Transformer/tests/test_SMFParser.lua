--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  SMFParser test wrapper
  Triggers inline tests by setting arg[0] to match "SMFParser"
  SMFParser has 28 built-in tests that run on require()
--]]

-- setup package path using pwd
local function getProjectRoot()
  local handle = io.popen("pwd")
  if handle then
    local pwd = handle:read("*l")
    handle:close()
    if pwd then
      return pwd:gsub("/tests$", "") .. "/"
    end
  end
  return "../"
end

local projectRoot = getProjectRoot()
package.path = projectRoot .. "lib/SMFParser/?.lua;" .. package.path

-- set arg[0] to trigger inline tests
arg = arg or {}
arg[0] = "SMFParser.lua"

-- require triggers the inline tests
-- if tests pass, "All tests passed! (28 total)" is printed
-- if tests fail, an assertion error is thrown and we exit non-zero
local ok, err = pcall(function()
  require("SMFParser")
end)

if not ok then
  print("SMFParser test failed:")
  print(err)
  os.exit(1)
end

-- success
os.exit(0)
