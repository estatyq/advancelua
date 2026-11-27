# AGENTS.md — Universal Helper Platform (GTA SA / SA-MP | Advance RP)

> Always-on workspace rules and **Agent Harness** contract. Supersedes legacy v0.9 `optional/AGENTS.md`.
> Deep architecture spec: `SAMP_LUA_ARCHITECTURE.md`. Harness skill & references: `.agents/skills/samp-harness/SKILL.md`.

---

## 1. Project Identity & Repo Agent Harness
- **Main script:** `d:\Проекты\advance sapm\helper_core.lua` (v2.7, `17,921` lines, `814,687` bytes, targeting **v3.0 Faction-Adaptive**).
- **Active game deploy path:** `E:\ukraine_rp_runtime\moonloader\helper_core.lua` (`MoonLoader v.026.5-beta`, `SAMPFUNCS v5.7.1 rel.25 (SA-MP 0.3.7-R1)`, `mimgui / cimguidx9.dll`, `SAMP.Lua`).
- **Verification Harness (`harness/`):**
  - Full suite: `python harness/run.py`
  - Fast gate (~1–2s): `python harness/run.py --fast` (or `--fast --json`)
  - Live telemetry snapshot: `python harness/run.py --snapshot`
  - Deploy SHA256 check: `python harness/run.py --deploy-check`
- **Active Antigravity Hooks (`.agents/hooks.json`):**
  - `PreToolUse` (`cp1251_guard.py`) blocks `edit_file`/`write_file` on `helper_core.lua`.
  - `Stop` (`stop_verify.py`) auto-runs `python harness/run.py --fast` whenever `helper_core.lua` is modified.
- **Git & scratch hygiene:** leave existing untracked local root scratch/backup files untouched; never bypass Git Credential Manager auth or force-push; never claim live in-game GTA SA execution without observed logs.

---

## 2. Mandatory Editing Workflow (CP1251 + CRLF)
- **`helper_core.lua` is strictly Windows-1251 (`cp1251`) with CRLF (`\r\n`).**
- **NEVER use `edit_file` or UTF-8 editors on `helper_core.lua`** (it corrupts Cyrillic chat/UI strings and triggers `cp1251_guard.py`).
- **Inspect CP1251 `helper_core.lua` safely:** `python harness/patch_helper.py --read <START> <END>` and `--search "<regex>"`.
- **Patch via Python (`harness/patch_helper.py`):** use `load_helper()`, `replace_once()`, and `save_helper(..., verify_fast=True)` (atomic rollback if `--fast` fails). Run `python harness/run.py` after changes.
- Documentation, skills, harness scripts, and Markdown files (`*.md`, `harness/*.py`) stay **UTF-8**.

---

## 3. Non-Negotiable Runtime Stack Invariants
Violating any item below causes native Win32/DX9 crashes (`0xC0000005`, `0x6AE877F1`, `0x6AE877D6`) or LuaJIT compile errors:

1. **LuaJIT 2.1 limits (`200` locals/prototype, `60` upvalues/closure):** v2.7 budget is `top_locals=48/150`, `max_active=49/180`, `max_fn_locals=62/180 [mainFrameTick]`, `max_upvals=10/45` (`python harness/run.py --snapshot` prints live counts). **Add ZERO new top-level `local` declarations** — store all new state in global phase tables (`P2`..`P7`, `P8`, `ENV_CAPS`).
2. **Keep `jit.off()` (L28):** prevents FFI/DX9 trace corruption in MoonLoader.
3. **Keep `__thread_anchor_pool` (L39–L45):** all coroutines must go through wrapped `lua_thread.create` to avoid `0x6AE877D6` / `0x643877D6` GC crashes in `MoonLoader.asi`.
4. **No side effects inside `imgui.OnFrame` / `drawSettings()`:** NEVER call `samp*`, `getCharCoordinates`, `lua_thread.create`, `setClipboardText`, audio/CLEO, `memory.write`, or disk I/O inside DX9 Present callbacks (`0x6AE877F1`). Allocate `queueTask(fn)` (L59) / `scheduleTask(delay_ms, fn)` (L66) closures strictly inside triggered UI branches (`if imgui.Button(...) then`), or set dirty flags handled by hoisted `mainFrameTick()` (L14030) / `P8_tick()`.
5. **Lazy `mimgui` context (`0xC0000005 at 0x6E0A6BFE`):** `GImGui` is `NULL` until the first active `OnFrame`. Always read input outside `OnFrame` via `P1_getImguiInputState()` (L11530) (`IsInitialized()`, `GetRenderer()`, `SwitchContext()`). Guard top-level `require('mimgui')` safely or degrade via chat/log warning if absent.
6. **`encoding` (`iconv`) null-byte truncation & double-encoding:** `u8"A\0B\0"` truncates at the first `\0`. Always split `\0` outside `u8(...)`: `u8"A" .. "\0" .. u8"B" .. "\0"`. Convert CP1251 -> UTF-8 via `u8(...)` once at the UI boundary.
7. **Safe `mimgui` widget rules:** `imgui.TextUnformatted(...)` only; odd `imgui.new.char[N]` + `ffi.sizeof(buf)`; `imgui.PushIDStr`/`Int`/`Ptr`; unconditional `imgui.End()`; balanced `BeginChild`/`EndChild` and `Push*`/`Pop*`; `HideCursor = true` + `NoInputs` on passive HUD overlays; release DX9 textures outside draw passes via `P6_flushTexReleaseQueue()` (L12926); guard `onScriptTerminate()` (L17885) with `not quitGame and imgui.IsInitialized()`.
8. **`pcall` multi-return shift & coroutines:** `pcall` prepends `ok` (`local ok, res, pid = pcall(sampGetPlayerIdByCharHandle, ped)`; `local ok, res, x, y, z = pcall(getObjectCoordinates, obj)`). Never call `wait()` inside `pcall` or allocate per-frame closures inside `while true do`.
9. **Banned non-existent APIs & hook order:** never use `isSampPauseMenuActive` (`isPauseMenuActive`), `sampGetCurrentDialogStyle` (`sampGetCurrentDialogType`), `isThisModelABike`/`Train` (`NON_AUTO_MODELS` + `isThisModelACar`), `getObjectRotation` (`getObjectQuaternion` + `P6_quatToEuler` L12303 `Rz*Rx*Ry`), or `setCarLightDamageStatus`. Never shadow MoonLoader globals (`isCarEngineOn` -> `P1_isCarEngineOn`). In `sampev.onServerMessage` (L14959), run `evaluateChatFilter()` BEFORE `/clog`, sounds, and parsers. For suppressed dialogs (e.g., `/find`), call `sampSendDialogResponse(dialogId, 0, -1, "")` (4th arg `""`, not `-1`) before `return false`.
10. **Safe library probing:** never assume `memory` (or `cleo`/`sampfuncs`) exists globally without `pcall(require, 'memory')` and `ENV_CAPS` guards; parse `getSampfuncsVersion()` via `tostring` + pattern matching rather than raw numeric comparison.

---

## 4. v3.0 Architectural Mandates
1. **Faction-Adaptive First (`P8.faction_ctx`):** Every module and contextual widget (F11 sidebar `modules[i]`, top quick bar, MMB wheel, Target Menu, Auto-RP, `/hud`) MUST declare `factions = {...}` (`"mo"`, `"mvd"`, `"mz"`, `"smi"`, `"gov"`, `"crime"`, `"civ"`, or `"all"`). Support auto-detect (`/pass`, `/stats`, `/mn`, own-nickname `/r`/`/f` — never `/d`/`/gnews`), manual header selector, and 1-click **"Показать все модули"**. Keep `P8_tick()` separate from `mainFrameTick()`. **МО (Армия: СВ/ВВС/ВМФ)** is first-class (`army_tools`: posts, convoy/БП, base alarm/ЧС, oath/charter in Lecturer, combat Auto-RP + `/sp` bypass, reuse of `/dmglog`).
2. **Runtime Capability Badges («плашки», `ENV_CAPS`):** Features depending on MoonLoader version, SAMPFUNCS, CLEO, `SAMP.Lua`, `mimgui` textures, `memory`, or `bit` MUST declare `requires = {...}` and call `P8_drawCapabilityBanner(reqs)` backed by `P8_checkCapabilities(reqs)` (`[!] Для работы этой функции требуется <Dep> <Ver> (сейчас не установлено — установите)`).
3. **Strict Server Isolation:** Auto-detect Advance RP servers (`Blue`, `Red`, `Green`, `Lime`, `Chocolate`) via server name + welcome message. Never substitute `Blue` legislation/charters onto another server (including unscoped legacy JSON migrations).
4. **Confirmed RP & Non-Fragile Automation:** Use `P8.rp_pending` (`{ patterns, on_confirm, expires_at }`) + `/sp <cmd>` one-shot bypass (`onSendCommand` rewrite). Dialog automation (armory, refuel, food, mask) MUST be opt-in (OFF by default), strip `{RRGGBB}`, match items by localized text, and handle `TABLIST_HEADERS` (`style == 5`).

---

## 5. Harness Skill Reference
Load `.agents/skills/samp-harness/SKILL.md` for full stack deep-dives, Faction-Adaptive matrices, `army_tools` specs, and harness extension details.
