# Universal Helper Platform v2.6

Universal game helper for **GTA San Andreas — SA-MP** (Advance RP servers).  
Built on **MoonLoader** (Lua) with **mimgui** GUI, **SAMP.Lua** events, and **SAMPFUNCS**.

[Русская версия](README.md) | [Roadmap](ROADMAP.md) | [Инструкция по эксплуатации](INSTRUCTION_RU.md)

---

## Features

### `/location` Scene Builder — Free *TitanLocation* Alternative (`location_builder`)
- **522-Object Catalog (`/loc 1` / `/tloc 1`)**: all 522 official IDs from `adv-rp.com/decor` across 7 categories, ID/name search, sorting, favorites, recents, compact/card toggle, and optional JPG preview cache (`config/decor_cache/`)
- **Precision Overlay Editor (`/tedit`, `/tcopy`, `/tpaste`, `/tdup`)**: live local preview via `sampGetObjectHandleBySampId`, `setObjectCoordinates`, `setObjectRotation`; axis nudge `X/Y/Z` (`0.01–2.0`), rotation `RX/RY/RZ` (`1°–90°`), Undo/Redo, full/Z-only/rot-only/offset copy-paste, and object duplication
- **Saved Location Registry (`/loc 2` / `/tloc 2`)**: persists saved objects per server & character in `helper_locations.json` upon server save (`response == 1`), mid-list edit/delete recovery guide, and JSON blueprint export/import (auto-falls back to `/tloc` if `/loc` conflicts)

### MVD, Medic & Senior Staff (`faction_tools`, `lecturer`, `gnews`)
- **MVD (`/suw [ID]`)**: customizable UK/AK codex (`helper_codex.json`) with Blue/Red/Green/Chocolate presets, 1-click RP + `/su` or `/ticket` (leaves manual `/su` untouched), optional Auto-RP for `/cuff`/`/uncuff`/`/search`/`/putpl`/`/arrest`, 4 megaphone `/m` presets
- **Medic (`/medui [ID]`)**: configurable ECP price table, 1-click RP + `/medhelp`, `/heal`, `/medcard`, `/analysis`, optional Auto-RP on `/medhelp`/`/heal`
- **Opt-in Local Damage Informer (`/dmglog`)**: disabled by default; HUD readout + 25-entry hit log via `onSendGiveDamage`/`onSendTakeDamage`
- **Scheduled GNEWS (`HH:MM:SS`) & `/l` Booking**: HUD countdown, 15s alert, 1-click wave booking in `/l`
- **Lecturer & Interviews (`/lect`, `/lectstop`)**: 7 editable multi-line templates with `<0>` pause & timers (`helper_lecturer.json`)

### Menus, Vehicles, Chat, AutoEdit, Quiz, GPS & Utilities
- **MMB Quick Menu (`/wheelmenu`) & Target Menu (`RMB + X/R/E`)**: cursor-anchored RP Engine favorites + MVD/MZ/history target actions with optional Auto-RP
- **Vehicles**: siren-linked auto-strobes (`isCarSirenOn`), Sport-mode (`Alt+W` / `Shift+W`) & cruise (`C`/`W`/`S`) with turn/brake assist *(ban-risk warning kept)*, plus opt-in **Drone Free Camera (`/cam`)** off by default using GTA camera opcodes
- **Chat & QoL**: post-parser anti-spam chat filter, word-boundary auto line-wrap, `/rec`, `/hist`, opt-in `/buyfast`, opt-in AFK/session HUD tracker, layout fixer (`F2`), radio auto-tag, friendlist, `/ss`, `/clog`, finance tracker, `/wp` GPS, 6 faction presets, **Export/Import v2 (`helper_export.json`)**
- **AutoEdit v2 & SMI**: single-pass engine (`1971` rules), `270+` non-repeating anagrams (`/anag [0-5]`), Quiz Director (`/quiz`), fixed `/find` vs `/gps`, online phonebook (`/calln`, `/smsn`, `/lsms`), `/hud`, `/calc`
- **LuaJIT headroom**: top-level locals kept well under compile limits (`< 60 / 200`).

---

## Installation

1. Install **CLEO 4** and **SAMPFUNCS**
2. Install **MoonLoader v0.26+** (full bundle with `mimgui`, `SAMP.Lua`, `memory`, `bit`, `encoding`, `json`, `ffi`)
3. Copy `helper_core.lua` to `GTA San Andreas/moonloader/`
4. Launch the game and press **F11** or type `/helper`

---

## Links

- [Repository](https://github.com/estatyq/advancelua)
- [Roadmap](ROADMAP.md)
- [Русская версия](README.md)
