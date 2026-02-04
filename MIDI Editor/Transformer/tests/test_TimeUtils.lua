--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  TimeUtils unit tests
  Tests pure formatting functions: timeFormatRebuf, lengthFormatRebuf
  Uses reaper_stub for REAPER API calls
--]]

-- setup package path (pwd-based for subprocess execution)
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
package.path = projectRoot .. "?.lua;" .. package.path
package.path = projectRoot .. "tests/helpers/?.lua;" .. package.path

-- load REAPER stub before TransformerTimeUtils
reaper = require("reaper_stub")

-- now require TimeUtils (it uses global 'reaper')
local TimeUtils = require("TransformerTimeUtils")
local gdefs = require("TransformerGeneralDefs")

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name)
    print("  " .. tostring(err))
  end
end

local function assertEqual(expected, actual, msg)
  if expected ~= actual then
    error((msg or "assertion failed") .. ": expected '" .. tostring(expected) .. "', got '" .. tostring(actual) .. "'")
  end
end

-- timeFormatRebuf tests (position format)
test("timeFormatRebuf: already valid measures format", function()
  assertEqual("1.2.34", TimeUtils.timeFormatRebuf("1.2.34"))
end)

test("timeFormatRebuf: single number fills in beats/ticks", function()
  assertEqual("5.1.00", TimeUtils.timeFormatRebuf("5"))
end)

test("timeFormatRebuf: 0.0 -> 0.1.00 (beats min is 1 for position)", function()
  assertEqual("0.1.00", TimeUtils.timeFormatRebuf("0.0"))
end)

test("timeFormatRebuf: negative preserves minus", function()
  assertEqual("-1.2.34", TimeUtils.timeFormatRebuf("-1.2.34"))
end)

test("timeFormatRebuf: ticks suffix preserved", function()
  assertEqual("1.2.100t", TimeUtils.timeFormatRebuf("1.2.100t"))
end)

test("timeFormatRebuf: minutes format preserved", function()
  assertEqual("1:30.500", TimeUtils.timeFormatRebuf("1:30.500"))
end)

test("timeFormatRebuf: minutes without fraction gets .000", function()
  assertEqual("1:30.000", TimeUtils.timeFormatRebuf("1:30"))
end)

test("timeFormatRebuf: empty string returns default", function()
  assertEqual(gdefs.DEFAULT_TIMEFORMAT_STRING, TimeUtils.timeFormatRebuf(""))
end)

test("timeFormatRebuf: invalid chars returns default", function()
  assertEqual(gdefs.DEFAULT_TIMEFORMAT_STRING, TimeUtils.timeFormatRebuf("abc"))
end)

test("timeFormatRebuf: subfraction preserved", function()
  assertEqual("1.2.34.5", TimeUtils.timeFormatRebuf("1.2.34.5"))
end)

-- lengthFormatRebuf tests (duration format)
test("lengthFormatRebuf: zero length valid", function()
  assertEqual("0.0.00", TimeUtils.lengthFormatRebuf("0.0.00"))
end)

test("lengthFormatRebuf: already valid format", function()
  assertEqual("1.2.34", TimeUtils.lengthFormatRebuf("1.2.34"))
end)

test("lengthFormatRebuf: minutes format preserved", function()
  assertEqual("0:30.000", TimeUtils.lengthFormatRebuf("0:30.000"))
end)

test("lengthFormatRebuf: max fraction 99", function()
  assertEqual("0.0.99", TimeUtils.lengthFormatRebuf("0.0.99"))
end)

test("lengthFormatRebuf: fraction clamped to 99", function()
  assertEqual("0.0.99", TimeUtils.lengthFormatRebuf("0.0.150"))
end)

test("lengthFormatRebuf: single number", function()
  assertEqual("5.0.00", TimeUtils.lengthFormatRebuf("5"))
end)

test("lengthFormatRebuf: empty returns default", function()
  assertEqual(gdefs.DEFAULT_LENGTHFORMAT_STRING, TimeUtils.lengthFormatRebuf(""))
end)

test("lengthFormatRebuf: ticks suffix", function()
  assertEqual("1.2.100t", TimeUtils.lengthFormatRebuf("1.2.100t"))
end)

test("lengthFormatRebuf: negative preserves minus", function()
  assertEqual("-1.2.34", TimeUtils.lengthFormatRebuf("-1.2.34"))
end)

-- summary
if failed > 0 then
  print(string.format("\n%d/%d passed", passed, passed + failed))
  os.exit(1)
else
  os.exit(0)
end
