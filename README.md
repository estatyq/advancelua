# Universal Helper Platform v0.8

Universal game helper for **GTA San Andreas — SA-MP** (Advance RP servers).  
Built on **MoonLoader** (Lua) with **mimgui** GUI, **SAMP.Lua** events, and **SAMPFUNCS**.

---

## Features

### Cruise Control
- **Normal mode** — simulates gas pedal with hysteresis (smooth, reliable)
- **Turbo mode** — speedhack via `setCarForwardSpeed` with safety:
  - Crash detection (speed drop > 40% → 3s pause)
  - Smooth ramp-up (+3 → +20 per frame)
  - Engine state check (won't accelerate with engine off)
  - In-air detection (won't apply mid-jump)
- **Controls:** `C` = toggle, `W` = +5, `S` = -5

### Strobe Lights (19 modes)
- Memory-based headlight control via `CDamageManager`
- Modes: flashing, alternating, running, sirens, SOS, garland, mayak, patrol, etc.
- **Controls:** `J` = toggle on/off, `N` = next mode

### Keybinds System
- Bind any key to any chat command
- Defaults: `L` = `/lock`, `K` = `/e`
- Add/edit/remove via UI
- Saved to `helper_settings.json`
- Won't trigger while typing in chat or dialog open

### Auto-Call & Database
- Tracks players from chat, stores nick + phone number
- Auto-call online players from DB
- Configurable delay and max calls per session

### Auto-Advertisement
- Automatically posts ads with configurable delay

### MM Editor (Skins)
- Change player skin by model ID (0–311)

### Auto-RP
- Automated RP actions (weapons, healing) based on faction

### Faction Scanner
- Detects faction from dialog, sets skin automatically

### Commands Guide
- Built-in reference for Advance RP commands by category

---

## Installation

1. Install **MoonLoader v0.26+**
2. Install required libraries: `mimgui`, `ffi`, `encoding`, `json`, `lib.samp.events`, `memory`, `bit`
3. Copy `helper_core.lua` to `GTA San Andreas/moonloader/`
4. Launch game, press **F11** or type `/helper` to open menu

---

## Hotkeys

| Key | Action |
|-----|--------|
| `F11` | Open/close main menu |
| `C` | Toggle cruise control (in vehicle) |
| `W` / `S` | Increase / decrease cruise target speed |
| `J` | Toggle strobe lights (in vehicle) |
| `N` | Next strobe mode (in vehicle) |
| `L` | `/lock` (lock/unlock vehicle) |
| `K` | `/e` (engine on/off) |

All hotkeys are disabled while typing in chat or when a dialog is open.

---

## Configuration

Settings are saved to `moonloader/config/helper_settings.json`:
- Module enable/disable states
- Strobe mode and speed
- Cruise turbo mode toggle
- Custom keybinds

---

## Requirements

- GTA San Andreas v1.0
- SA-MP client
- MoonLoader v0.26+
- Libraries: mimgui, sampfuncs, memory, bit, encoding, json

---

## Version History

- **v0.8** (27.06.2026) — Turbo cruise redesign, keybinds system, strobe mode key, engine check, debug cleanup
- **v0.7** — Initial SAMP.Lua integration, faction scanner, auto-call DB

---

## License

Personal use. See repository for details.

## Links

- [Repository](https://github.com/estatyq/advancelua)
