# Transformer Unit Tests

Unit tests for Transformer modules, runnable outside REAPER using Lua 5.4.

## Running Tests

```bash
cd tests
lua test_runner.lua
```

Expected output: 8 test files, all passing.

## Test Coverage

| Module | File | Tests | Notes |
|--------|------|-------|-------|
| Context | test_Context.lua | 9 | Full TransformerLib loaded with expanded stubs |
| FactoryPresets | test_FactoryPresets.lua | 249 | 4-stage validation: deserialize → parse → codegen → execute |
| Integration | test_Integration.lua | 5 | Runtime behavior: param → code → execution pipeline |
| Notation | test_Notation.lua | 13 | getParamPercentTerm (code executes), handleMacroParam |
| SMFParser | test_SMFParser.lua | 28 | inline tests via arg[0] trick |
| TimeUtils | test_TimeUtils.lua | 19 | timeFormatRebuf, lengthFormatRebuf (pure functions) |
| TypeModules | test_TypeModules.lua | 17 | All 8 type modules detectType verification |
| TypeRegistry | test_TypeRegistry.lua | 9 | register, getType, detectType, hasType, getAll |

## Limitations

- **REAPER-dependent functions** (bbtToPPQ, ppqToTime, calcMIDITime) need live REAPER
- **renderUI functions** not tested (requires ImGui)

## Adding New Tests

1. Create `test_ModuleName.lua` in tests/
2. Set package.path at top using `getProjectRoot()` pattern:
   ```lua
   local function getProjectRoot()
     local handle = io.popen("pwd")
     if handle then
       local pwd = handle:read("*l")
       handle:close()
       if pwd then return pwd:gsub("/tests$", "") .. "/" end
     end
     return "../"
   end
   package.path = getProjectRoot() .. "?.lua;" .. package.path
   ```
3. Load `reaper_stub` before requiring modules:
   ```lua
   reaper = require("reaper_stub")
   ```
4. Use `test(name, fn)` pattern with `assert()` or helper functions
5. Exit with code 0 on success, 1 on failure
6. Runner auto-discovers `test_*.lua` files

## Factory Preset Tests

`test_FactoryPresets.lua` validates all 249 factory presets through a 4-stage pipeline:

1. **Deserialize** - preset file parses as valid Lua
2. **Parse macros** - findMacro/actionMacro process without error
3. **Code generation** - generated Lua code is syntactically valid
4. **Runtime execution** - code executes with mock event data

Preset discovery uses `find` command from `../../../Transformer Presets/Factory Presets`.
Override with `FACTORY_PRESET_PATH` env var for CI.

## REAPER Stub

`tests/helpers/reaper_stub.lua` provides minimal REAPER API functions for module loading:

- `GetAppVersion()` - returns "7.0" for REAPER 7 checks
- `GetProjectTimeOffset()` - returns 0
- `GetResourcePath()` - returns current directory
- `TimeMap_*` functions - default 120 BPM, 4/4
- `MIDI_GetProjTimeFromPPQPos()` - default 96 PPQ
- `EnumerateFiles()`, `EnumerateSubdirectories()` - stubs for groove file iteration

Also provides runtime function stubs for generated code execution:
- `CreateNewMIDIEvent`, `OperateEvent1`, `RandomValue`
- `QuantizeMusicalPosition`, `SetMusicalLength`, `AddDuration`, `SubtractDuration`
- `LinearChangeOverSelection`, `QuantizeTo`, `MultiplyPosition`
- Groove variants of the above

Extend as needed for new module tests.
