# SAMP Harness Deep Reference — GTA SA / SA-MP / MoonLoader / LuaJIT / mimgui Stack

## 1. Layer-by-Layer Runtime Breakdown

| Layer | Binary / Module | Responsibility | Failure Mode if Missing / Misused |
|---|---|---|---|
| **Host Engine** | `gta_sa.exe` (1.0 US, Win32, DirectX 9) | 32-bit x86 game loop, RenderWare DX9 pipeline, SCM virtual machine | Wrong exe version breaks memory offsets & ASI hooks |
| **Loader** | ASI Loader (`vorbisFile.dll` / `dinput8.dll`) | Loads `.asi` plugins at process startup | Neither CLEO, SAMPFUNCS, nor MoonLoader initializes |
| **CLEO** | `cleo.asi` (4.3+) | Extended SCM opcodes, `.cs` scripts, custom anims/helpers | Features using CLEO opcodes/scripts silently fail or crash without `ENV_CAPS.cleo` check |
| **SAMPFUNCS** | `SAMPFUNCS.asi` (5.4+, active testbed `v5.7.1 rel.25`) | RakNet packet/RPC bridge, SAMP chat/dialog/player structures, SF console | `SAMP.Lua` cannot hook RPCs; `samp*` functions unavailable |
| **MoonLoader** | `MoonLoader.asi` (0.26+, active testbed `v.026.5-beta`) | Embeds **LuaJIT 2.1**, schedules Lua coroutines (`lua_thread`), exposes GTA/SAMP opcodes | Missing opcodes on `<0.26`; buggy C++ `lua_thread` GC destructor (`0x6AE877D6`) |
| **SAMP.Lua** | `moonloader/lib/samp/events.lua` | Decodes/encodes RakNet RPCs (`onServerMessage`, `onShowDialog`, `onSendCommand`, damage, object edit) | AutoEdit `/edit`, chat filters, server/faction auto-detect, confirmed RP, and Damage Informer stop working |
| **mimgui** | `mimgui` + `cimguidx9.dll` | Dear ImGui bindings hooking DX9 `Present`/`EndScene` with lazy renderer creation | Calling `GetIO()` before first `OnFrame` dereferences NULL `GImGui` (`0xC0000005 at 0x6E0A6BFE`) |
| **encoding** | `encoding` (`iconv`) | Converts between game CP1251 strings and mimgui UTF-8 (`u8`) | Truncates at embedded `\0`; UTF-8 source files break Cyrillic in SA-MP chat |
| **ffi / memory / bit** | LuaJIT FFI + MoonLoader `memory` + LuaJIT `bit` | C buffers (`imgui.new.char[N]`), raw GTA SA RAM reads/writes, bitmasks | Missing `memory` breaks strobes, weather/time lock, engine check (`P1_isCarEngineOn`) |

---

## 2. Proven Crash Signatures & Permanent Mitigations in `helper_core.lua`

1. **`Exception 0xC0000005 at 0x6E0A6BFE` + `cannot resume non-suspended coroutine`**
   - **Root cause:** `mimgui` creates `renderer` (`GImGui`) lazily on the first active `OnFrame`. Calling `imgui.GetIO()` from the main loop on Frame 1 dereferences `NULL` inside `cimguidx9.dll` and unwinds across `pcall`.
   - **Fix:** `P1_getImguiInputState()` (L11530) verifies `imgui.IsInitialized()`, `local r = imgui.GetRenderer(); if not r or r.lost then ... end`, calls `imgui.SwitchContext()`, and only then reads `imgui.GetIO()`. Main loop calls hoisted `mainFrameTick()` (L14030) instead of inline closures.
2. **`Crash 0x6AE877F1` (`luaL_unref` from DX9 Present)**
   - **Root cause:** Spawning `lua_thread.create`, invoking `samp*` natives, playing CLEO/audio, calling `memory.write`, or mutating SAMP state from inside `imgui.OnFrame`.
   - **Fix:** Push `queueTask(fn)` (L59) / `scheduleTask(delay_ms, fn)` (L66) closures **only inside triggered branches** (`if imgui.Button(...) then`, never per-frame allocations and never capturing `lua_thread` userdata), or toggle dirty flags drained inside `mainFrameTick()` / `P8_tick()`.
3. **`Crash 0x6AE877D6` / `0x643877D6` (MoonLoader `lua_thread` GC Destructor)**
   - **Root cause:** LuaJIT garbage-collecting finished `lua_thread` objects triggers a buggy C++ `luaL_unref` inside `MoonLoader.asi`.
   - **Fix:** `__thread_anchor_pool` (L39–L45) wraps `lua_thread.create` and retains thread references permanently.
4. **JIT Trace Instability in DX9/FFI Hooks**
   - **Fix:** `jit.off()` at L28 right after script metadata.
5. **DX9 Texture Release During Draw / Game Exit Crash**
   - **Fix:** Enqueue textures into deferred queue flushed outside draw pass by `P6_flushTexReleaseQueue()` (L12926); guard `onScriptTerminate()` (L17885) with `if not quitGame and imgui.IsInitialized() then ... end`.
6. **LuaJIT 2.1 Bytecode Limits (`200` locals per prototype, `60` upvalues per closure)**
   - **Current verified metrics (v2.7 via `python harness/run.py --snapshot`):** `top_locals = 48/150`, `max_active = 49/180`, `max_fn_locals = 62/180` (`mainFrameTick`), `max_upvals = 10/45`.
   - **Rule:** Never add top-level `local` variables; house all v3.0 data in global `P8` and `ENV_CAPS`, and put v3.0 per-frame work in hoisted `P8_tick()` called by `mainFrameTick()` so `mainFrameTick` stays far below `180` locals.

---

## 3. Known GTA SA Memory Offsets & Math Used in `helper_core.lua`

- **Weather lock (L15648):** `0xC81320` (1 byte).
- **Clock lock (L15657–L15659):** `0xB70153` (1 byte, hours), `0xB70152` (1 byte, minutes), `0xB70158` (4 bytes, game clock tick).
- **Vehicle engine flag `P1_isCarEngineOn` (L15886–L15888):** `carPtr + 0x428` (1 byte), test `bit.band(val_428, 0x10) ~= 0`.
- **Strobe lights (L15782–L15797):** light bitmask toggled via `bit.band(lightVal, 0xFFFFFFF0)` / `bit.bor` (`0x02` left, `0x08` right).
- **Architectural gap to close in v3.0:** Lines L15782–L15797 and L15886 call `memory.read`/`memory.write` assuming `memory` is present globally. In v3.0, load safely via `local ok_mem, mem_lib = pcall(require, 'memory')`, expose via `ENV_CAPS.memory`, and guard every memory call + show a capability badge if missing.
- **Object Quaternion Math (`P6_quatToEuler`, L12303):** GTA:SA `CMatrix::SetRotate(rx, ry, rz)` composes rotations as `Rz * Rx * Ry` (not standard ZYX!). Never replace `P6_quatToEuler` with generic XYZ/ZYX quaternion formulas.

---

## 4. `mimgui` & `SAMP.Lua` Defensive Coding Rules

- **Text & Buffers:** Always `imgui.TextUnformatted(...)` (prevents `%` format-string crashes on player chat/names). Allocate odd sizes for `imgui.new.char[N]` and pass `ffi.sizeof(buf)`.
- **Null-delimited Combo/ListBox strings:** Never pass `\0` inside `u8(...)` because `iconv` stops at the first NUL byte. Write `u8"Пункт 1" .. "\0" .. u8"Пункт 2" .. "\0"`. Convert CP1251 -> UTF-8 via `u8(...)` strictly once at the UI boundary (never double-encode).
- **ID Stack & Windows:** Use `imgui.PushIDStr` / `PushIDInt` / `PushIDPtr` (there is no generic `imgui.PushID`). Always call `imgui.End()` unconditionally after `imgui.Begin(...)`. Passive HUD overlays MUST set `HideCursor = true` and `imgui.WindowFlags.NoInputs`.
- **`pcall` Multi-Return Rule:** `pcall(fn, ...)` prepends boolean `ok`:
  - `local ok, res, pid = pcall(sampGetPlayerIdByCharHandle, ped)`
  - `local ok, res, x, y, z = pcall(getObjectCoordinates, obj)`
- **Banned Opcodes:**
  - `isSampPauseMenuActive` -> use `isPauseMenuActive`
  - `sampGetCurrentDialogStyle` -> use `sampGetCurrentDialogType`
  - `isThisModelABike` / `isThisModelATrain` -> use `NON_AUTO_MODELS` table + `isThisModelACar`
  - `getObjectRotation` -> use `getObjectQuaternion` + `P6_quatToEuler`
  - `setCarLightDamageStatus` -> direct `memory` bitmask (guarded by `ENV_CAPS.memory`)
- **Dialog & Chat Hooks:**
  - `sampev.onServerMessage` (L14959): `evaluateChatFilter()` MUST run before `/clog`, alert sounds, and parsers.
  - Suppressed dialogs (e.g., `/find` in `onShowDialog` L15206): send `sampSendDialogResponse(dialogId, 0, -1, "")` (4th arg `""`, never `-1`) before `return false`.

---

## 5. `ENV_CAPS` Runtime Capability Probe & Badge Contract (v3.0)

### Startup Probe (`P8_probeEnvironment()`)
Executed at script load / `main()` before entering `while true do` (wrap top-level `require('mimgui')` safely in `pcall`; if `mimgui` is completely missing, log/print to SA-MP chat because UI banners cannot draw without ImGui):
- `ENV_CAPS.moonloader = { ok = (ver >= 26), ver = ver, label = "MoonLoader 0.26+" }` via `getMoonloaderVersion()`.
- `ENV_CAPS.sampfuncs = { ok = loaded and sf_ok, loaded = loaded, ver = sf_ver_str, label = "SAMPFUNCS 5.4+" }` via `pcall(isSampfuncsLoaded)` and `pcall(getSampfuncsVersion)` parsing `major, minor` from `tostring(sf_ver)` (never raw `string >= number`).
- `ENV_CAPS.cleo = { ok = has_cleo, file_present = has_cleo, label = "CLEO 4.3+" }` via `doesFileExist(getGameDirectory() .. "\\cleo.asi")` (caveat: confirms `cleo.asi` exists on disk, NOT exact binary version `4.3+` or active ASI load).
- `ENV_CAPS.samp_lua = { ok = (sampev ~= nil), label = "SAMP.Lua" }`.
- `ENV_CAPS.mimgui = { ok = (imgui ~= nil), label = "mimgui 1.7+" }`.
- `ENV_CAPS.mimgui_tex = { ok = (imgui ~= nil and type(imgui.CreateTextureFromFile) == "function"), label = "mimgui DX9 Textures" }`.
- `ENV_CAPS.memory = { ok = (mem_lib ~= nil), lib = mem_lib, label = "MoonLoader memory" }` via `pcall(require, 'memory')`.
- `ENV_CAPS.bit = { ok = (type(bit) == "table" and type(bit.band) == "function"), label = "LuaJIT bit" }`.
- `ENV_CAPS.json = { ok = true, mode = ok_json and "native" or "fallback", label = "JSON" }`.

### Banner Widget (`P8_drawCapabilityBanner(reqs)`)
- **Two-part contract:** `P8_checkCapabilities(reqs)` returns `(is_hard_blocked, issues)` cleanly separated from `P8_drawCapabilityBanner(reqs)` which calls `P8_checkCapabilities(reqs)`, renders banners, and returns `is_hard_blocked`.
- Input: array of `{ id, min, label, severity = "hard" | "soft", hint }`.
- Visual text (dynamically built from `req.label`):
  - Missing: `"[!] Для работы этой функции требуется " .. req.label .. " (сейчас не установлено — установите)"`
  - Outdated: `"[!] Для работы этой функции требуется " .. req.label .. " (установлена v" .. cur .. " — обновите)"`
- Styling: red-tinted bordered banner for `hard` (followed by disabled/guarded controls), amber-tinted banner for `soft` (feature degrades gracefully).
- Global Diagnostics Panel: placed in `qol_tools` showing live status of all 9 runtime components.
