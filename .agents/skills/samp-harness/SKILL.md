---
name: samp-harness
description: "SAMP Agent Harness — GTA SA / SA-MP / MoonLoader / LuaJIT / mimgui / SAMP.Lua / SAMPFUNCS / CLEO architecture, runtime guards, and repo-contained verification workflow for helper_core.lua. Activate whenever inspecting or modifying helper_core.lua, running harness/run.py or harness/patch_helper.py, auditing LuaJIT limits or DX9/mimgui crashes, designing v3.0 Faction-Adaptive modules (МО Армия, МВД, МЗ, СМИ, Мэрия, Крайм, Гражданский), adding ENV_CAPS dependency badges, or enforcing Advance RP server isolation."
---

# SAMP Agent Harness (`helper_core.lua` Engineering Workflow)

Self-contained verification, safe-editing, and architectural enforcement skill for **Universal Helper Platform** (`helper_core.lua`, GTA San Andreas — SA-MP | Advance RP).

## Active Harness Commands & Guardrails
Always run repo-local commands instead of one-off root scripts or UTF-8 file editors:
- **Inspect CP1251 `helper_core.lua` safely:**
  - `python harness/patch_helper.py --read <START> <END>` (outputs UTF-8 lines; `read_file` rejects CP1251 `helper_core.lua`)
  - `python harness/patch_helper.py --search "<regex>"`
- **Patch `helper_core.lua` atomically with auto-rollback:**
  ```python
  from harness.patch_helper import load_helper, replace_once, save_helper
  src = load_helper()
  src = replace_once(src, old_block, new_block, label="change description")
  save_helper(src, verify_fast=True)
  ```
- **Verify:**
  - `python harness/run.py --fast` (~1–2s encoding, LuaJIT budget, `OnFrame` render safety, `LuaParser`/`ScopeAnalyzer` AST gate)
  - `python harness/run.py` (full suite + AutoEdit 1,971 rules + Phases 2–6 + v1.9–v2.7)
  - `python harness/run.py --snapshot` (live ground-truth telemetry: version, SHA256, LuaJIT budget, module/hook lines)
  - `python harness/run.py --deploy-check` (SHA256 verification against `E:\ukraine_rp_runtime\moonloader\helper_core.lua`)
- **Active Lifecycle Hooks (`.agents/hooks.json`):**
  - `PreToolUse` (`cp1251_guard.py`) blocks `edit_file` / `write_file` on `helper_core.lua`.
  - `Stop` (`stop_verify.py`) automatically runs `python harness/run.py --fast` whenever `helper_core.lua` is modified.

## Core Stack Mental Model
- **Execution Stack:** `GTA SA 1.0 (Win32 / DX9)` -> `ASI Loader` -> `CLEO 4.3+` + `SAMPFUNCS 5.4+` + `MoonLoader 0.26+ (LuaJIT 2.1, jit.off())` -> `mimgui (cimguidx9.dll)` + `SAMP.Lua (lib.samp.events)` + `encoding (iconv CP1251/UTF-8)` + `ffi` / `memory` / `bit`.
- **Two-Thread Rule:** `main()` -> `while true do wait(0) pcall(mainFrameTick) end` runs on the Game Main Loop; `imgui.OnFrame` runs inside DX9 `Present`. **NEVER** invoke `samp*`, `getCharCoordinates`, `lua_thread.create`, `setClipboardText`, audio/CLEO, `memory.write`, disk I/O, or `imgui.ReleaseTexture` directly inside `OnFrame` or `drawSettings()`. Allocate `queueTask(fn)` (L59) / `scheduleTask(delay_ms, fn)` (L66) closures only inside triggered branches (`if imgui.Button(...) then`), or set dirty flags handled by `mainFrameTick()` (L14030) / `P8_tick()`, and flush DX9 textures via `P6_flushTexReleaseQueue()` (L12926).

## Mandatory Pre-Patch & Design Checklist
1. **LuaJIT 2.1 Budget:** Zero new top-level `local` declarations (v2.7: `top_locals=48/150`, `max_active=49/180`, `max_fn_locals=62/180 [mainFrameTick]`, `max_upvals=10/45`). Place v3.0 state exclusively inside global `P8` and `ENV_CAPS`, and put v3.0 per-frame work in hoisted `P8_tick()`.
2. **Native Crash Prevention:**
   - `jit.off()` intact (L28); `__thread_anchor_pool` intact (L39–L45, stops `0x6AE877D6`).
   - All non-`OnFrame` ImGui input checks go through `P1_getImguiInputState()` (L11530, stops `0xC0000005 at 0x6E0A6BFE` lazy `GImGui`); guard top-level `require('mimgui')` safely or fall back to chat/log warning if missing.
   - `u8` strings split around `\0` (`u8"A" .. "\0" .. u8"B" .. "\0"`), with single-pass CP1251 -> UTF-8 conversion at the UI boundary.
   - `imgui.TextUnformatted`, odd `imgui.new.char[N]` + `ffi.sizeof`, `PushIDStr`/`Int`/`Ptr`, unconditional `End()`.
3. **SAMP / MoonLoader Opcode Correctness:**
   - Account for `pcall` extra leading `ok` return on multi-return functions (`sampGetPlayerIdByCharHandle`, `getObjectCoordinates`).
   - Zero banned opcodes (`isSampPauseMenuActive`, `sampGetCurrentDialogStyle`, `isThisModelABike`/`Train`, `getObjectRotation`, `setCarLightDamageStatus`); use `P6_quatToEuler` (`Rz*Rx*Ry`) for object rotations.
   - `evaluateChatFilter()` runs first in `sampev.onServerMessage`; suppressed dialogs send `sampSendDialogResponse(dialogId, 0, -1, "")` before `return false`.
4. **Faction-Adaptive Scoping (`P8.faction_ctx`):**
   - Every module/widget declares `factions = {...}` (`mo`, `mvd`, `mz`, `smi`, `gov`, `crime`, `civ`, `all`).
   - Adapt Sidebar, Top Quick Bar, MMB Wheel, Target Menu, Auto-RP, Lecturer, Commands Guide, and `/hud` to the active faction (**МО / Армия** shows posts/convoy/alarm/oath/combat RP, never СМИ `/edit` or МВД wanted tools), with a 1-click **"Показать все модули"** override.
5. **Runtime Capability Badges (`ENV_CAPS`):**
   - Features depending on MoonLoader version, SAMPFUNCS, CLEO, `SAMP.Lua`, `mimgui` textures, `memory`, or `bit` declare `requires = {...}` and call `P8_drawCapabilityBanner(reqs)` (`[!] Для работы этой функции требуется <Dep> <Ver> (сейчас не установлено — установите)`) backed by `P8_checkCapabilities(reqs)`.
6. **Advance RP Server Isolation & Confirmed RP:**
   - Auto-detect `Blue`, `Red`, `Green`, `Lime`, `Chocolate` cleanly and keep legislation/charters isolated.
   - Use `P8.rp_pending` confirmation + `/sp <cmd>` one-shot rewrite in `onSendCommand`, and opt-in (OFF by default) text-matched dialog automation accounting for `{RRGGBB}` codes and `TABLIST_HEADERS` (`style == 5`).

## Deep References (Read On Demand)
- `references/stack_deep_dive.md` — GTA SA / CLEO / SAMPFUNCS / MoonLoader / LuaJIT / mimgui / `memory` / `ENV_CAPS` contract & crash signatures.
- `references/faction_matrix.md` — v3.0 Faction-Adaptive matrix, **МО / Армия (`army_tools`)** spec, server isolation, and PoliceHelper-derived UX contracts.
- Root `SAMP_LUA_ARCHITECTURE.md` — full diagrams and v3.0 implementation roadmap (`python harness/run.py --snapshot` gives live line numbers anytime).
