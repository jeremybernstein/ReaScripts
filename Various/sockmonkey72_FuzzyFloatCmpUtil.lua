-- @description Fuzzy Float Comparison Utility
-- @version 1.2
-- @author sockmonkey72
-- @about
--   # Fuzzy Float Comparison Utility
--   A fuzzy float comparison function based on https://floating-point-gui.de/errors/comparison/
--   and https://embeddeduse.com/2019/08/26/qt-compare-two-floats/ as well as some tests
--   to prove that it works.
-- @changelog
--   initial


-- 32-bit numerical limits
--[[
  local float_min_value = 1.175494e-38 -- min finite
  local float_min = 1.4013e-45 -- denorm_min
  local float_max = 1.175494e38
  local float_small = 1e-40
--]]

-- 64-bit numerical limits
local float_min_value = 2.22507e-308 -- min finite
local float_min = 4.94066e-324 -- denorm_min
local float_max = 1.79769e308
local float_small = 4.940656e-312

local float_epsilon = 0.00001 -- not FLT_EPSILON, but a relative amount to compare by. Here, 0.001%
local NaN = 0/0

---------------------------------------------------------------------
-- the main fuzzy comparison function -- use this
---------------------------------------------------------------------

local function nearlyEqual(a, b, epsilon)
  local absA = math.abs(a)
  local absB = math.abs(b)
  local diff = math.abs(a - b)

  epsilon = epsilon or float_epsilon -- default value

  if (a == b) then -- shortcut, handles infinities
    return true
  elseif (a == 0 or b == 0 or (absA + absB < float_min_value)) then
    -- a or b is zero or both are extremely close to it
    -- relative error is less meaningful here
    return diff < (epsilon * float_min_value)
  else -- use relative error
    return diff < epsilon * math.max(absA, absB)
    -- I prefer the comparison above, but this one works, too
    -- return (diff / math.min((absA + absB), float_max)) < epsilon
  end
end

-- test function with default epsilon for the tests
local function nearlyEqualTest(a, b, epsilon)
  return nearlyEqual(a, b, epsilon)
end

-- the tests
local reaper = reaper

local pass = 0
local fail = 0

local function testNearlyEqual_WantsTrue(a, b, epsilon)
  if not nearlyEqualTest(a, b, epsilon) then
    reaper.ShowConsoleMsg("FAILED: " .. a .. " != " .. b .. "\n")
    fail = fail + 1
  else
    reaper.ShowConsoleMsg("PASSED: " .. a .. " == " .. b .. "\n")
    pass = pass + 1
  end
end

local function testNearlyEqual_WantsFalse(a, b, epsilon)
  if nearlyEqualTest(a, b, epsilon) then
    reaper.ShowConsoleMsg("FAILED: " .. a .. " == " .. b .. "\n")
    fail = fail + 1
  else
    reaper.ShowConsoleMsg("PASSED: " .. a .. " != " .. b .. "\n")
    pass = pass + 1
  end
end

reaper.ShowConsoleMsg("float_min (denormal min): " .. float_min .. "\nfloat_min_value: " .. float_min_value .. "\nfloat_max: " .. float_max .. "\n")

reaper.ShowConsoleMsg('\nBIG\n')
testNearlyEqual_WantsTrue(1000000, 1000001)
testNearlyEqual_WantsTrue(1000001, 1000000)
testNearlyEqual_WantsFalse(10000, 10001)
testNearlyEqual_WantsFalse(10001, 10000)

reaper.ShowConsoleMsg('\nBIG NEG\n')
testNearlyEqual_WantsTrue(-1000000, -1000001)
testNearlyEqual_WantsTrue(-1000001, -1000000)
testNearlyEqual_WantsFalse(-10000, -10001)
testNearlyEqual_WantsFalse(-10001, -10000)

reaper.ShowConsoleMsg('\nMID\n')
testNearlyEqual_WantsTrue(1.0000001, 1.0000002)
testNearlyEqual_WantsTrue(1.0000002, 1.0000001)
testNearlyEqual_WantsFalse(1.0002, 1.0001)
testNearlyEqual_WantsFalse(1.0001, 1.0002)

reaper.ShowConsoleMsg('\nMID NEG\n')
testNearlyEqual_WantsTrue(-1.000001, -1.000002)
testNearlyEqual_WantsTrue(-1.000002, -1.000001)
testNearlyEqual_WantsFalse(-1.0001, -1.0002)
testNearlyEqual_WantsFalse(-1.0002, -1.0001)

reaper.ShowConsoleMsg('\nSMALL\n')
testNearlyEqual_WantsTrue(0.000000001000001, 0.000000001000002)
testNearlyEqual_WantsTrue(0.000000001000002, 0.000000001000001)
testNearlyEqual_WantsFalse(0.000000000001002, 0.000000000001001)
testNearlyEqual_WantsFalse(0.000000000001001, 0.000000000001002)

reaper.ShowConsoleMsg('\nSMALL NEG\n')
testNearlyEqual_WantsTrue(-0.000000001000001, -0.000000001000002)
testNearlyEqual_WantsTrue(-0.000000001000002, -0.000000001000001)
testNearlyEqual_WantsFalse(-0.000000000001002, -0.000000000001001)
testNearlyEqual_WantsFalse(-0.000000000001001, -0.000000000001002)

reaper.ShowConsoleMsg('\nSMALL DIFFS\n')
testNearlyEqual_WantsTrue(0.3, 0.30000003)
testNearlyEqual_WantsTrue(-0.3, -0.30000003)

reaper.ShowConsoleMsg('\nZERO\n')
testNearlyEqual_WantsTrue(0.0, 0.0)
testNearlyEqual_WantsTrue(0.0, -0.0)
testNearlyEqual_WantsTrue(-0.0, -0.0)
testNearlyEqual_WantsFalse(0.00000001, 0.0)
testNearlyEqual_WantsFalse(0.0, 0.00000001)
testNearlyEqual_WantsFalse(-0.00000001, 0.0)
testNearlyEqual_WantsFalse(0.0, -0.00000001)

testNearlyEqual_WantsTrue(0.0, float_small, 0.01)
testNearlyEqual_WantsTrue(float_small, 0.0, 0.01)
testNearlyEqual_WantsFalse(float_small, 0.0, 0.000001)
testNearlyEqual_WantsFalse(0.0, float_small, 0.000001)

testNearlyEqual_WantsTrue(0.0, -float_small, 0.1)
testNearlyEqual_WantsTrue(-float_small, 0.0, 0.1)
testNearlyEqual_WantsFalse(-float_small, 0.0, 0.00000001)
testNearlyEqual_WantsFalse(0.0, -float_small, 0.00000001)

reaper.ShowConsoleMsg('\nEXTREME MAX\n')
testNearlyEqual_WantsTrue(float_max, float_max)
testNearlyEqual_WantsFalse(float_max, -float_max)
testNearlyEqual_WantsFalse(-float_max, float_max)
testNearlyEqual_WantsFalse(float_max, float_max / 2)
testNearlyEqual_WantsFalse(float_max, -float_max / 2)
testNearlyEqual_WantsFalse(-float_max, float_max / 2)

reaper.ShowConsoleMsg('\nINFINITIES\n')
testNearlyEqual_WantsTrue(math.huge, math.huge)
testNearlyEqual_WantsTrue(-math.huge, -math.huge)
testNearlyEqual_WantsFalse(-math.huge, math.huge)
testNearlyEqual_WantsFalse(math.huge, float_max)
testNearlyEqual_WantsFalse(-math.huge, -float_max)

reaper.ShowConsoleMsg('\nNAN\n')
testNearlyEqual_WantsFalse(NaN, NaN)
testNearlyEqual_WantsFalse(NaN, 0.0)
testNearlyEqual_WantsFalse(-0.0, NaN)
testNearlyEqual_WantsFalse(NaN, -0.0)
testNearlyEqual_WantsFalse(0.0, NaN)
testNearlyEqual_WantsFalse(NaN, math.huge)
testNearlyEqual_WantsFalse(math.huge, NaN)
testNearlyEqual_WantsFalse(NaN, -math.huge)
testNearlyEqual_WantsFalse(-math.huge, NaN)
testNearlyEqual_WantsFalse(NaN, float_max)
testNearlyEqual_WantsFalse(float_max, NaN)
testNearlyEqual_WantsFalse(NaN, -float_max)
testNearlyEqual_WantsFalse(-float_max, NaN)
testNearlyEqual_WantsFalse(NaN, float_min)
testNearlyEqual_WantsFalse(float_min, NaN)
testNearlyEqual_WantsFalse(NaN, -float_min)
testNearlyEqual_WantsFalse(-float_min, NaN)

reaper.ShowConsoleMsg('\nOPPOSITE\n')
testNearlyEqual_WantsFalse(1.000000001, -1.0)
testNearlyEqual_WantsFalse(-1.0, 1.000000001)
testNearlyEqual_WantsFalse(-1.000000001, 1.0)
testNearlyEqual_WantsFalse(1.0, -1.000000001)

reaper.ShowConsoleMsg('\nULP\n')

testNearlyEqual_WantsTrue(float_min, float_min)
testNearlyEqual_WantsTrue(float_min, -float_min)
testNearlyEqual_WantsTrue(-float_min, float_min)
testNearlyEqual_WantsTrue(float_min, 0)
testNearlyEqual_WantsTrue(0, float_min)
testNearlyEqual_WantsTrue(-float_min, 0)
testNearlyEqual_WantsTrue(0, -float_min)

testNearlyEqual_WantsFalse(0.000000001, -float_min)
testNearlyEqual_WantsFalse(0.000000001, float_min)
testNearlyEqual_WantsFalse(float_min, 0.000000001)
testNearlyEqual_WantsFalse(-float_min, 0.000000001)

reaper.ShowConsoleMsg("\nPASSED: " .. pass .. ", FAILED: " .. fail .. "\n")
