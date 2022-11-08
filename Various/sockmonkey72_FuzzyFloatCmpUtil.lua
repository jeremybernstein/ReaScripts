-- @description Fuzzy Float Comparison Utility
-- @version 1.0
-- @author sockmonkey72
-- @about
--   # Fuzzy Float Comparison Utility
--   A fuzzy float comparison function based on https://floating-point-gui.de/errors/comparison/ as well as some tests to prove that it works.
-- @changelog
--   initial


local float_min = 1.175494 * (10^-38) -- using 32-bit numerical limits
local float_max = 1.175494 * (10^38)
local float_epsilon = 2^-23

-- the main fuzzy comparison function
function nearlyEqual(a, b, epsilon)
  local absA = math.abs(a);
  local absB = math.abs(b);
  local diff = math.abs(a - b);

  epsilon = epsilon or float_epsilon -- default value

  if (a == b) then -- shortcut, handles infinities
    return true
  elseif (a == 0 or b == 0 or (absA + absB < float_min)) then
    -- a or b is zero or both are extremely close to it
    -- relative error is less meaningful here
    return diff < (epsilon * float_min)
  else -- use relative error
    return (diff / math.min((absA + absB), float_max)) < epsilon
  end
end

-- test function with default epsilon for the tests
function nearlyEqualTest(a, b, epsilon)
  epsilon = epsilon or 0.00001
  return nearlyEqual(a, b, epsilon)
end

-- the tests
local reaper = reaper

local pass = 0
local fail = 0

function assertTrue(a, b, epsilon)
  if not nearlyEqualTest(a, b, epsilon) then
    reaper.ShowConsoleMsg("FAILED: " .. a .. " != " .. b .. "\n")
    fail = fail + 1
  else
    reaper.ShowConsoleMsg("PASSED: " .. a .. " == " .. b .. "\n")
    pass = pass + 1
  end
end

function assertFalse(a, b, epsilon)
  if nearlyEqualTest(a, b, epsilon) then
    reaper.ShowConsoleMsg("FAILED: " .. a .. " == " .. b .. "\n")
    fail = fail + 1
  else
    reaper.ShowConsoleMsg("PASSED: " .. a .. " != " .. b .. "\n")
    pass = pass + 1
  end
end


reaper.ShowConsoleMsg("float_min: " .. float_min .. ", float_max: " .. float_max .. ", float_epsilon: " .. float_epsilon .. "\n")

assertTrue(1.0000001, 1.0000002)
assertTrue(1.0000002, 1.0000001)
assertFalse(1.0002, 1.0001)
assertFalse(1.0001, 1.0002)

assertTrue(-1.000001, -1.000002)
assertTrue(-1.000002, -1.000001)
assertFalse(-1.0001, -1.0002)
assertFalse(-1.0002, -1.0001)

assertTrue(0.000000001000001, 0.000000001000002)
assertTrue(0.000000001000002, 0.000000001000001)
assertFalse(0.000000000001002, 0.000000000001001)
assertFalse(0.000000000001001, 0.000000000001002)

assertTrue(-0.000000001000001, -0.000000001000002)
assertTrue(-0.000000001000002, -0.000000001000001)
assertFalse(-0.000000000001002, -0.000000000001001)
assertFalse(-0.000000000001001, -0.000000000001002)

assertTrue(0.3, 0.30000003)
assertTrue(-0.3, -0.30000003)

assertTrue(0.0, 0.0)
assertTrue(0.0, -0.0)
assertTrue(-0.0, -0.0)
assertFalse(0.00000001, 0.0)
assertFalse(0.0, 0.00000001)
assertFalse(-0.00000001, 0.0)
assertFalse(0.0, -0.00000001)

assertTrue(0.0, 1e-40, 0.01)
assertTrue(1e-40, 0.0, 0.01)
assertFalse(1e-40, 0.0, 0.000001)
assertFalse(0.0, 1e-40, 0.000001)

assertTrue(0.0, -1e-40, 0.1)
assertTrue(-1e-40, 0.0, 0.1)
assertFalse(-1e-40, 0.0, 0.00000001)
assertFalse(0.0, -1e-40, 0.00000001)

assertFalse(1.000000001, -1.0)
assertFalse(-1.0, 1.000000001)
assertFalse(-1.000000001, 1.0)
assertFalse(1.0, -1.000000001)

reaper.ShowConsoleMsg("PASSED: " .. pass .. ", FAILED: " .. fail .. "\n")
