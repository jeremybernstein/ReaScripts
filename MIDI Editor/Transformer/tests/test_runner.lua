--[[
   * Author: sockmonkey72
   * Licence: MIT
   * Version: 1.00
   * NoIndex: true
--]]

--[[
  Test Runner - discovers and executes test_*.lua files
  Exit code: 0 on success, 1 on any failure
  Output: quiet (module name + "." or "F"), summary at end
--]]

local function getScriptDir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("^@(.*/)")
  return path or "./"
end

local scriptDir = getScriptDir()

-- discover test files via ls
local function discoverTests()
  local tests = {}
  local handle = io.popen('ls "' .. scriptDir .. '"test_*.lua 2>/dev/null')
  if not handle then return tests end

  for line in handle:lines() do
    -- extract just filename
    local filename = line:match("([^/]+)$")
    if filename and filename ~= "test_runner.lua" then
      table.insert(tests, filename)
    end
  end
  handle:close()
  return tests
end

-- run single test file
local function runTest(filename)
  local fullPath = scriptDir .. filename
  local cmd = string.format('lua "%s" 2>&1', fullPath)
  local handle = io.popen(cmd)
  if not handle then return false, "failed to execute" end

  local output = handle:read("*all")
  local success, exitType, code = handle:close()

  -- Lua 5.4: success is true on exit 0, or "exit" with code
  -- handle both Lua 5.3 and 5.4 return conventions
  local passed = false
  if success == true then
    passed = true
  elseif type(success) == "number" then
    -- Lua 5.3 style
    passed = (success == 0)
  elseif exitType == "exit" then
    passed = (code == 0)
  end

  return passed, output
end

-- extract module name from filename
local function moduleName(filename)
  return filename:match("test_(.+)%.lua") or filename
end

-- main
local tests = discoverTests()

if #tests == 0 then
  print("No tests found")
  os.exit(0)
end

local passed = 0
local failed = 0
local failures = {}

for _, test in ipairs(tests) do
  local name = moduleName(test)
  io.write(name .. ": ")
  io.flush()

  local ok, output = runTest(test)
  if ok then
    print(".")
    passed = passed + 1
  else
    print("F")
    failed = failed + 1
    table.insert(failures, {name = name, output = output})
  end
end

-- summary
print("")
print(string.format("%d/%d passed", passed, passed + failed))

-- show failure details
if #failures > 0 then
  print("")
  print("Failures:")
  for _, f in ipairs(failures) do
    print("  " .. f.name .. ":")
    for line in f.output:gmatch("[^\n]+") do
      print("    " .. line)
    end
  end
  os.exit(1)
end

os.exit(0)
