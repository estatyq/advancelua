# SAMP Harness Deep Reference — v3.0 Faction-Adaptive Platform & МО (Армия) Spec

## 1. Core UX Principle: Context Over Clutter
A player serving in **МО (Армия)** must NEVER wade through СМИ `/edit` tools, МВД wanted/fine menus, or МЗ medical buttons by default. Conversely, an МВД officer or СМИ editor must immediately see their own tools.

**Three rules govern adaptability:**
1. **Auto-detect first, manual override always:** detect faction + subdivision + rank automatically from `/pass`, `/stats`, `/mn`, and **strictly own-nickname** messages in `/r` or `/f` (NEVER infer faction from incoming `/d` or `/gnews`, which broadcast other factions' tags!), while offering a 1-click faction/subdivision selector right in the `F11` window header.
2. **Never lock features away:** a single checkbox **`Показать все модули`** in the `F11` header reveals all modules at any time without changing the active faction context.
3. **Adapt every surface, not just the sidebar:** F11 Sidebar (`modules[i]`), Top Quick Bar, MMB Wheel Menu, Target Menu (`ПКМ + X/R/E`), Auto-RP trigger set, Lecturer preset pack, Commands Guide priority section, and `/hud` widgets all read `P8.faction_ctx.active_faction`.

---

## 2. Faction Profiles (`P8.faction_ctx`)

| Key | Display Name | Subdivisions (`sub_division`) | Primary Exclusive / Highlighted Tools |
|---|---|---|---|
| `mo` | **МО (Армия)** | `СВ` (Сухопутные войска), `ВВС`, `ВМФ` | `army_tools` (Посты, Конвой БП, ЧС, Устав МО, быстрый доступ к `/dmglog`), Лектор (Присяга/КПП/Субординация), боевое Авто-РП + `/sp`, `/location` (Блокпост/Полигон/Плац) |
| `mvd` | **МВД / ФБР** | `ЛСПД`, `СФПД`, `ЛВПД`, `ФБР` | `faction_tools` (Патруль 38 зон + сектора, `/suw` Розыск/Штрафы по серверному профилю, Мегафон), Лектор (Академия/Миранда), Авто-РП с подтверждением сервера + `/sp` |
| `mz` | **МЗ (Больница)** | `БЛС`, `БСФ`, `БЛВ` | `faction_tools` (вкладка `/medui`: лечение, медкарта, ЕЦП), Лектор (Мед. лекции), мед. Авто-РП |
| `smi` | **СМИ** | `LSFM`, `SFFM`, `LVFM`, `TV-C` | `mm_editor` (`/edit` AutoEdit 1971 правило), `smi_tools` (Эфиры, Викторины), `auto_ad`, `autocall_db` |
| `gov` | **Мэрия / Правительство** | `Мэрия ЛС/СФ/ЛВ`, `АП` | `gnews`, `lecturer` (Гос. речи), `autocall_db`, трибуна в `/location`, профильные команды в `commands_guide` |
| `crime` | **Банды / Мафии** | `Grove/Ballas/Vagos/Aztec/Rifa`, `LCN/Yakuza/RM` | Боевое Авто-РП + `/sp`, Damage Informer, `auto_ad`, `vehicle_visuals`, `keybinds`, `qol_tools` (`/price`, `/hud`) |
| `civ` | **Гражданский / Бизнес** | `—` | `qol_tools` (`/price` трекер рынка, `/hud`), `auto_ad`, `autocall_db`, `vehicle_visuals`, `keybinds`, `location_builder` |

---

## 3. Complete Module Visibility Matrix (`mod.factions`)

| Module ID | `factions` | `mo` | `mvd` | `mz` | `smi` | `gov` | `crime` | `civ` |
|---|---|---|---|---|---|---|---|---|
| `army_tools` *(v3.0 new)* | `{"mo"}` | **Primary** | Hidden | Hidden | Hidden | Hidden | Hidden | Hidden |
| `faction_tools` (`P4_drawFactionUI`: МВД/МЗ/Damage/Патруль) | `{"mvd", "mz"}` | Hidden *(Damage in qol/army)* | **Primary** | **Primary** | Hidden | Hidden | Hidden | Hidden |
| `mm_editor` (`/edit`) | `{"smi"}` | Hidden | Hidden | Hidden | **Primary** | Hidden | Hidden | Hidden |
| `smi_tools` (эфиры/викторины) | `{"smi"}` | Hidden | Hidden | Hidden | **Primary** | Hidden | Hidden | Hidden |
| `gnews` (гос. новости) | `{"mo", "mvd", "mz", "smi", "gov"}` | Visible | Visible | Visible | Visible | Visible | Hidden | Hidden |
| `lecturer` (лекции/присяга) | `{"mo", "mvd", "mz", "smi", "gov"}` | **МО pack** | МВД pack | МЗ pack | СМИ pack | Гос. pack | Hidden | Hidden |
| `auto_rp` (боевое / служебное RP) | `{"all"}` | Combat/MO | Police | Medical | Media | Gov | Combat | Basic |
| `rp_engine` (СКМ + Таргет-меню) | `{"all"}` | MO wheel/target | MVD wheel/target | MZ wheel/target | SMI wheel/target | Gov wheel/target | Crime wheel/target | Civ wheel/target |
| `vehicle_visuals` | `{"all"}` | Visible | Visible | Visible | Visible | Visible | Visible | Visible |
| `keybinds` | `{"all"}` | Visible | Visible | Visible | Visible | Visible | Visible | Visible |
| `commands_guide` | `{"all"}` | МО first | МВД first | МЗ first | СМИ first | Мэрия first | Крайм first | General |
| `qol_tools` (`/hud`, `/price`, `/dmglog`, темы) | `{"all"}` | Visible | Visible | Visible | Visible | Visible | Visible | Visible |
| `location_builder` (`/location`) | `{"all"}` | Military presets | Police presets | Med presets | Studio presets | Gov presets | All | All |
| `autocall_db` | `{"smi", "gov", "civ"}` | Hidden | Hidden | Hidden | Visible | Visible | Hidden | Visible |
| `auto_ad` | `{"smi", "crime", "civ"}` | Hidden | Hidden | Hidden | Visible | Hidden | Visible | Visible |

*Note: Switching `active_faction` must reset `active_module_idx` to the first visible module inside `mainFrameTick()` / setter before `imgui.OnFrame` renders `modules[active_module_idx]`.*

---

## 4. Detailed Specification: МО / Армия Module (`army_tools`)

Designed specifically for Advance RP military service (**СВ / ВВС / ВМФ**):

### Tab 1 — Посты и Дежурство (`P8.army.post`)
- **Post Presets:** `КПП-1`, `КПП-2`, `Вышка`, `Склад БП`, `Авианосец (Кит)`, `Ангар`, `Казарма` + custom text buffer.
- **Status Codes:** `Код 1 (спокойно)`, `Код 2 (подозрительная активность)`, `Код 3 (ЧС / нападение)`.
- **Report Timer:** configurable interval (default `10 min`), visible countdown in `/hud` (`Пост КПП-1 | Доклад: 04:15`). Plays soft alert when due and exposes a 1-click/hotkey send button to `/r` — **never auto-sends while AFK** to comply with server rules.
- **Template Variables:** `{tag}` (e.g. `[СВ]`/`[ВВС]`/`[ВМФ]`), `{post}`, `{code}`, `{crew}`, `{zone}` (38 SA zones), `{sector}` (`A-1..H-8`).

### Tab 2 — Конвой и БП (`P8.army.convoy`)
- Reuses `P7` zone/sector resolver (`38` San Andreas zones + `A-1..H-8` grid).
- 4-stage quick report buttons:
  1. `Выехал за БП` (`/r {tag} Выехал на Авианосец/Склад за БП. Состав: {crew}.`)
  2. `Загрузился` (`/r {tag} Загрузился БП, выдвигаюсь на базу. Район: {zone} ({sector}).`)
  3. `Нападение на конвой` (`/r {tag} ВНИМАНИЕ! Нападение на конвой БП! Район: {zone} ({sector}), нужна подмога!`)
  4. `Разгрузился на складе` (increments session delivery counter for promotion reports).

### Tab 3 — Тревога / ЧС и Боевые утилиты (`P8.army.alarm` + `P8.army.combat`)
- **Base Alarm Hotkey:** 1-key or 2-key combo immediately dispatching `/r` (or `/d` if toggled) with current zone/sector and base threat location (`КПП` / `Склад` / `Авианосец`).
- **Radio Watch (Opt-In):** highlights & chimes when `/r` or `/d` contains trigger words (`ЧС`, `нападение`, `прорыв`, `код 3`) with a 15-second cooldown per trigger.
- **Reuse Existing Damage Informer (`/dmglog`):** reuses v2.7 `dmg_enabled`, `dmg_show_hud`, and `sampev.onSendGiveDamage` (L15329) / `sampev.onSendTakeDamage` (L15333) directly from `army_tools` and `qol_tools` (guarding `playerId == 65535` / environmental fall/explosion damage before `sampGetPlayerNickname`), requires `ENV_CAPS.samp_lua`.
- **Combat Target Menu & Wheel Actions (when `active_faction == "mo"`):**
  - Check documents at КПП (`/s Здравия желаю! Предъявите ваши документы.`)
  - Warning to leave restricted zone (`/s Вы находитесь на охраняемой территории! Покиньте зону в течение 10 секунд!`)
  - Report intruder to `/r` with target nickname/ID and current zone
  - Give medkit/mask / Salute animation

### Tab 4 — Устав МО и Лектор-пакет
- Built-in searchable **Устав МО / Коды рации / Правила КПП** quick reference inside `army_tools`.
- Auto-selected **МО Preset Pack** inside `lecturer`: Военная Присяга, Субординация, Правила несения службы на КПП, Правила доставки БП.
- Military presets in `/location`: **Блокпост / КПП**, **Стрельбище / Полигон**, **Строевой плац** (built strictly from verified IDs in the 522-object catalog).

---

## 5. Cross-Faction Patterns (PoliceHelper-Derived Standards)

### 5.1. Auto Server Detection & Strict Non-Mixing Legislation
- Detect Advance RP server on connect via `sampGetCurrentServerName()` + `sampev.onServerMessage` welcome text (never rely solely on IP because of proxies/VPNs):
  - `blue` | `red` | `green` | `lime` | `chocolate` | `unknown`.
- Announce detected server once in chat (`[Helper] Определён сервер: Advance RP Chocolate`).
- **Hard Rule:** `P8.server_profiles[server_id]` stores isolated legislation/charter bundles (do NOT migrate unscoped v2.7 `helper_codex.json` data automatically onto `red`/`green`/`lime`/`chocolate`):
  - `blue`: УК, АК, ПК, Устав МВД, Полицейская академия, КТО, коды.
  - `chocolate`: УК, КоАП, ПК, ПДД.
  - `red`: УК, АК, ПДД.
  - `green`: УК, АК, ПДД, Федеральное постановление.
  - `lime`: УК, КоАП, Дорожный кодекс.
- **Never substitute `blue` articles onto another server (including `unknown`).** If an article/chapter is missing for the active server, display a clear info banner pointing to custom JSON override (`helper_codex.json`).

### 5.2. Server-Confirmed RP (`P8.rp_pending`) & `/sp <cmd>` Bypass
- Sensitive commands (`/cuff`, `/gotome`, `/mask`, `/healme`, `/form`, `/gpsoff`, armory equip) split RP into:
  1. Optional pre-action `/me` (or none if instant combat command).
  2. Register pending confirmation: `P8.rp_pending[cmd] = { patterns = {...}, on_confirm = fn, expires_at = os.clock() + 3.0 }`.
  3. On matching `sampev.onServerMessage`, fire finishing `/me` and clear pending entry; on timeout, drop silently (no fake RP on failed commands!).
- **`/sp <cmd> [args]`:** intercepts in `sampev.onSendCommand`, sets `P8.rp_bypass_once = true`, and rewrites the outgoing command by returning `{ "/" .. inner }` (instead of calling `sampSendChat`, which risks hook re-entrancy / race).

### 5.3. Text-Matched Non-Fragile Dialog Automation (Opt-In OFF by Default)
- Targets: Armory/gear pickup (склад МО / МВД), vehicle refuel, food purchase, mask renewal.
- **Strictly OFF by default** in `helper_settings.json`.
- Inside `sampev.onShowDialog`, guards against duplicate `dialogId` triggers, strips SA-MP `{RRGGBB}` color codes before pattern matching, accounts for `TABLIST_HEADERS` (`style == 5`, where line 0 is header rather than item index `0`), and selects the item matching localized text patterns (e.g., `"Бронежилет"`, `"Аптечка"`, `"Deagle"`, `"Заправить"`) rather than fragile numeric row indexes. If no pattern matches, leaves dialog open for manual user interaction (never clicks blind).

### 5.4. Press-to-Capture 1-Key & 2-Key Hotkeys
- Unified capture widget allowing single keys (`J`, `C`, `F11`) or modifier+key pairs (`Alt+1`, `Ctrl+E`, `Shift+R`).
- Every hotkey dispatch checks: `not sampIsChatInputActive() and not sampIsDialogActive() and not P1_getImguiInputState().want_text and not isPauseMenuActive()`.
