# SAMP ↔ Lua ↔ MoonLoader: Архитектура взаимодействия и анализ багов helper_core.lua

## 1. Архитектура: как SAMP взаимодействует с Lua-скриптами

### 1.1. MoonLoader (ядро)

MoonLoader — это DLL-инъекция в процесс GTA SA, которая добавляет Lua-движок (LuaJIT) и хуки в игру и SAMP.

**Поток загрузки скрипта:**
```
GTA SA запускается
  → MoonLoader инжектится (moonloader.dll)
    → хуки pre-game (установка перехватов)
      → загрузка GTA
        → хуки post-load
          → SAMP загружается (samp.dll)
            → MoonLoader обнаруживает SAMP
              → загружает все .lua скрипты из moonloader/
                → каждый скрипт: top-level код выполняется → main() вызывается MoonLoader'ом
```

**Lifecycle скрипта:**
1. **Загрузка**: MoonLoader читает .lua файл, выполняет top-level код (объявления, `local` переменные, `function main()` определение).
2. **main()**: MoonLoader вызывает `main()`. Это точка входа. Здесь скрипт ждёт `isSampAvailable()`, регистрирует команды, запускает воркеры, входит в главный цикл.
3. **Главный цикл**: `while true do wait(0) ... end` — кооперативная многозадачность. `wait(ms)` отдаёт управление.
4. **Termination**: `onScriptTerminate` event — очистка ресурсов.

### 1.2. lua_thread (кооперативная многозадачность)

`lua_thread.create(fn, ...)` — создаёт корутину. Все потоки выполняются в одном OS-потоке. `wait(ms)` — единственная точка переключения. Если поток не вызывает `wait()`, он блокирует весь скрипт (и игру).

**Правило:** каждый воркер должен вызывать `wait()` в цикле, иначе игра зависнет.

### 1.3. Событийная модель (addEventHandler)

MoonLoader предоставляет события через `addEventHandler(eventName, callback)`:
- `onD3DPresent` — каждый кадр рендера (используется mimgui для отрисовки)
- `onWindowMessage` — сообщения Windows (клавиатура, мышь)
- `onD3DDeviceLost` / `onD3DDeviceReset` — потеря/восстановление D3D устройства
- `onScriptTerminate` — завершение скрипта
- `onSendRpc` / `onReceiveRpc` / `onSendPacket` / `onReceivePacket` — сетевые пакеты SAMP

### 1.4. SAMP.Lua (samp.events)

Библиотека `lib/samp/events.lua` перехватывает RakNet пакеты SAMP и преобразует их в Lua-события.

**Механика:**
- `OUTCOMING_RPCS[RPC_ID] = {'onEventName', {field = 'type'}, ...}` — маппинг RPC → событие
- При отправке/получении RPC: `process_packet()` → чтение bitstream → вызов callback
- **Возврат `false`** из callback → пакет поглощается (не отправляется/не обрабатывается)
- **Возврат таблицы** → модификация пакета перед отправкой/обработкой

**Ключевые события, используемые в helper_core.lua:**
- `sampev.onServerMessage(color, text)` — входящее сообщение сервера (RPC_SCRCLIENTMESSAGE = 93)
  - `text` — строка в **CP1251** (кодировка SAMP)
  - `color` — число (ARGB)
- `sampev.onSendChat(message)` — исходящий чат (RPC_CHAT = 101)

### 1.5. SAMPFUNCS (sampfuncs.lua)

SAMPFUNCS — отдельная DLL, расширяющая SAMP API. Предоставляет функции:
- `sampSendChat(text)` — отправить сообщение в чат (text в **CP1251**)
- `sampAddChatMessage(text, color)` — добавить сообщение в локальный чат (text в **CP1251**)
- `sampRegisterChatCommand(cmd, callback)` — регистрация команды
- `sampGetPlayerIdByCharHandle(ped)` → `result, id`
- `sampGetPlayerNickname(id)` → nickname (CP1251)
- `sampGetPlayerIdByNickname(name)` → `result, id` (name в CP1251)
- `sampIsDialogActive()` → bool
- `sampGetCurrentDialogId()` → id
- `sampGetDialogCaption()` → title (CP1251)
- `sampGetDialogText()` → text (CP1251)
- `sampIsChatInputActive()` → bool

### 1.6. mimgui (ImGui для MoonLoader)

mimgui — Lua-обёртка над Dear ImGui через FFI.

**Архитектура:**
- `imgui.OnFrame(condition, drawCallback)` — подписка на рендер. Каждый кадр:
  1. Проверяется `condition()` → если true, `_render = true`
  2. `renderer:NewFrame()` — начало кадра ImGui
  3. `sub:_draw()` — вызов callback отрисовки
  4. `renderer:EndFrame()` — конец кадра
- `imgui.OnInitialize(callback)` — вызывается один раз при инициализации рендерера

**Кодировка строк в ImGui:**
- ImGui ожидает **UTF-8** строки для всех текстовых функций
- `u8"текст"` — конвертирует CP1251 литерал в UTF-8 (через `encoding.UTF8`)
- `imgui.Text(u8"Привет")` — правильно (UTF-8 в ImGui)
- `imgui.Text("Привет")` — НЕправильно (CP1251 литерал, ImGui покажет мусор для кириллицы)

**Доступные функции PushID (mimgui 1.7.0):**
- `imgui.PushIDStr(str)` — по строке
- `imgui.PushIDInt(int)` — по числу
- `imgui.PushIDPtr(ptr)` — по указателю
- `imgui.PushIDRange(begin, end)` — по диапазону
- **`imgui.PushID` — НЕ существует** (nil)

**Combo функции:**
- `imgui.Combo(label, current_item, items, items_count)` — items = `const char*const*` (ffi C-массив)
- `imgui.ComboStr(label, current_item, items_separated_by_zeros)` — items = Lua string с `\0` разделителями
- `imgui.BeginCombo(label, preview, flags)` / `imgui.Selectable(...)` / `imgui.EndCombo()` — ручной combo

**Style stack (Push/Pop пары):**
- `imgui.PushItemWidth(w)` ↔ `imgui.PopItemWidth()` — ширина элементов
- `imgui.PushStyleColor(col, ImVec4)` ↔ `imgui.PopStyleColor(count)` — цвета
- **Несбалансированные Push/Pop** → assertion или визуальные баги

### 1.7. encoding (iconv)

```lua
encoding.default = 'CP1251'  -- кодировка файла скрипта
local u8 = encoding.UTF8     -- конвертер UTF-8
```

- `u8:encode(str)` — CP1251 → UTF-8 (для передачи CP1251 текста в ImGui)
- `u8:decode(str)` — UTF-8 → CP1251 (для передачи UTF-8 текста в SAMP)
- `u8"текст"` — то же что `u8:encode("текст")` — CP1251 литерал → UTF-8
- Флаг `//IGNORE` — неконвертируемые байты молча удаляются

### 1.8. ffi (LuaJIT FFI)

- `ffi.new("type[?]", count, ...)` — создание C-массива
- `ffi.cast("type", value)` — приведение типа
- `ffi.string(ptr)` — чтение C-строки (до \0) в Lua-строку
- `ffi.copy(dst, src)` / `ffi.copy(dst, src, len)` — копирование
- `#` оператор **не работает** на ffi-массивах (только на Lua-строках и таблицах)

### 1.9. Кодировки данных в pipeline

```
SAMP сервер ──CP1251──→ samp.events (text параметр)
                              │
                    u8:encode(text) ──UTF-8──→ ImGui
                    u8:encode(text) ──UTF-8──→ player_db (JSON)
                              │
                    sampSendChat(u8:decode(utf8)) ──CP1251──→ SAMP сервер
```

---

## 2. Структура helper_core.lua

### 2.1. Модули (таблица `modules`)

| Индекс | id | Имя | Описание |
|--------|-----|------|----------|
| 1 | autocall_db | Звон в базу | Авто-звонки игрокам из БД |
| 2 | auto_ad | Авто-объявления | Периодическая отправка /ad |
| 3 | mm_editor | MM Editor (СМИ) | Форматирование объявлений |
| 4 | auto_rp | Авто-отыгровка | RP-сообщения для оружия, телефона и т.д. |
| 5 | vehicle_visuals | Транспорт и визуал | Стробоскоп, круиз, погода, скины |
| 6 | commands_guide | Справочник команд | Справочник команд Advance RP |

### 2.2. Воркеры (фоновые потоки)

| Функция | Запуск | Что делает |
|---------|--------|------------|
| `factionScannerWorker` | `loadDatabases()` → `lua_thread.create` | Сканирует диалоги SAMP для определения фракции |
| `weaponTrackWorker` | `main()` → `lua_thread.create` | Отслеживает смену оружия → RP-сообщения |
| `cruiseControlWorker` | `main()` → `lua_thread.create` | Круиз-контроль (клавиша C) |
| `environmentWorker` | `main()` → `lua_thread.create` | Блокировка погоды/времени |
| `dialogScannerWorker` | `main()` → `lua_thread.create` | Сканирует диалоги для MM Editor |
| `strobeWorker` | `drawSettings()` / клавиша J → `lua_thread.create` | Стробоскоп (мигание фар) |
| `onlineCallWorker` | `drawSettings()` → `lua_thread.create` | Обзвон игроков из БД |

### 2.3. События SAMP

- `sampev.onServerMessage(color, text)` — обработка сообщений сервера:
  - Парсинг объявлений (отправитель + телефон)
  - Авто-отправка следующего объявления (auto_ad)
  - Сохранение в БД (autocall_db)

### 2.4. Команды чата

| Команда | Действие |
|---------|----------|
| `/helper` | Открыть/закрыть GUI |
| `/aad [текст]` | Включить/выключить авто-объявления |
| `/rpdebug` | Отладка auto_rp |
| `/fskin [ID]` | Смена скина |
| `/call [номер]` | Звонок с RP-отыгровкой |
| `/h`, `/hangup` | Завершить звонок с RP |
| `/mask` | Маска с RP |
| `/healme` | Лечение с RP |
| `/drugs [кол-во]` | Наркотики с RP |

### 2.5. GUI (mimgui)

- `imgui.OnInitialize` → `applyCustomStyle()` — кастомный стиль
- `imgui.OnFrame(show_main_window, drawCallback)` — главное окно
  - Селектор сервера (BeginCombo)
  - Левая панель: список модулей (Selectable)
  - Правая панель: настройки активного модуля (drawSettings)

---

## 3. НАЙДЕННЫЕ БАГИ

### 🔴 КРИТИЧЕСКИЕ (краш скрипта)

#### БАГ-1: `strobe_sequences` — необъявленная переменная
**Строки:** 1828, 1830
**Симптом:** `attempt to index global 'strobe_sequences' (a nil value)` при включении стробоскопа
**Причина:** `strobeWorker()` обращается к `strobe_sequences[mode]` и `strobe_sequences[0]`, но таблица `strobe_sequences` нигде не определена в файле.
**Последствие:** Стробоскоп полностью неработоспособен. Скрипт не крашится (pcall не используется), но воркер завершается с ошибкой.
**Фикс:** Добавить определение таблицы последовательностей мигания:
```lua
local strobe_sequences = {
    [0] = {{0,0},{2,2},{0,0},{2,2}},          -- Простой
    [1] = {{0,2},{2,0},{0,2},{2,0}},          -- Быстро-медленно
}
```

#### БАГ-2: `selected_faction` — необъявленная переменная
**Строки:** 1362, 1364, 1521, 2005
**Симптом:** `attempt to index global 'selected_faction' (a nil value)`
**Причина:** `factionScannerWorker` записывает `selected_faction[0] = detected_faction`, `getWeaponRp` читает `selected_faction[0]`, `/rpdebug` читает `selected_faction[0]` — но `selected_faction` нигде не объявлен.
**Последствие:**
- Определение фракции крашится сразу после обнаружения (factionScannerWorker)
- RP-отыгровка оружия крашится (weaponTrackWorker → getWeaponRp)
- Команда `/rpdebug` крашится
**Фикс:** Добавить `local selected_faction = imgui.new.int(0)` в блок объявлений.

#### БАГ-3: `rp_engine_enabled` — необъявленная переменная
**Строка:** 1519
**Симптом:** `attempt to index global 'rp_engine_enabled' (a nil value)` при выполнении `/rpdebug`
**Причина:** В команде `/rpdebug` есть строка `tostring(rp_engine_enabled[0])`, но переменная нигде не объявлена. Вероятно, остаток от удалённой функции авто-отыгровки двигателя.
**Фикс:** Удалить строку 1519 или добавить `local rp_engine_enabled = imgui.new.bool(false)`.

---

### 🟠 ВЫСОКИЕ (визуальные баги / неправильное поведение)

#### БАГ-4: `imgui.PopStyleColor()` без парного `PushStyleColor()`
**Строки:** 1128, 1146, 1160, 1176
**Симптом:** ImGui assertion / stack imbalance / визуальные артефакты
**Причина:** В `vehicle_visuals.drawSettings` вызывается `imgui.PushItemWidth(150)` → `imgui.SliderInt(...)` → `imgui.PopStyleColor()`. Но `PushItemWidth` требует `PopItemWidth`, а не `PopStyleColor`. PopStyleColor без PushStyleColor нарушает стек цветов ImGui.
**Последствие:** При открытии вкладки "Транспорт и визуал" возможен assertion crash или искажение цветов всех последующих элементов.
**Фикс:** Заменить все 4 `imgui.PopStyleColor()` на `imgui.PopItemWidth()` на строках 1128, 1146, 1160, 1176.

#### БАГ-5: Кодировка `static_aad_buf` — двойная конвертация
**Строки:** 812, 817, 824, 841
**Симптом:** Кириллица в поле ввода авто-объявления отображается мусором / не отправляется
**Причина:**
- Строка 812: `imgui.new.char[128](u8:decode(aad_text))` — `aad_text` хранится в CP1251 (из `/aad` команды), но `u8:decode` ожидает UTF-8 на входе. CP1251 байты интерпретируются как UTF-8 → кириллица удаляется (`//IGNORE`). Буфер ImGui должен содержать **UTF-8**.
- Строка 817: `aad_text = u8:encode(ffi.string(static_aad_buf), encoding.default)` — буфер содержит UTF-8 (введённый пользователем), но `u8:encode` конвертирует CP1251→UTF-8, интерпретируя UTF-8 как CP1251 → двойное кодирование. `aad_text` должен храниться в **CP1251** для `sampSendChat`.
**Фикс:**
- Строка 812: `imgui.new.char[128](u8:encode(aad_text))` — CP1251 → UTF-8 для ImGui
- Строки 817, 824, 841: `u8:decode(ffi.string(static_aad_buf))` — UTF-8 → CP1251 для SAMP

#### БАГ-6: Кодировка отображения шаблонов и истории
**Строки:** 857, 860-861, 876, 897, 900-901, 916
**Симптом:** Шаблоны и история объявлений отображаются мусором в GUI
**Причина:**
- `aad_templates` и `aad_history` хранятся в UTF-8 (сохраняются через `u8:encode` на строке 841)
- Строка 857: `local tpl_utf8 = u8:decode(tpl)` — конвертирует UTF-8 → CP1251 (переменная названа "utf8", но содержит CP1251!)
- Строка 876: `imgui.Text(tpl_utf8)` — ImGui ожидает UTF-8, получает CP1251 → мусор
- Строки 860-861: `ffi.copy(static_aad_buf, u8:decode(tpl))` — копирует CP1251 в буфер ImGui, который ожидает UTF-8
**Фикс:**
- Убрать `u8:decode` — `tpl` и `hist` уже в UTF-8:
  - `imgui.Text(tpl)` вместо `imgui.Text(u8:decode(tpl))`
  - `ffi.copy(static_aad_buf, tpl)` вместо `ffi.copy(static_aad_buf, u8:decode(tpl))`

#### БАГ-7: Кодировка в MM Editor (тест форматирования)
**Строки:** 970, 972
**Симптом:** Тестовое форматирование объявлений работает неправильно для кириллицы
**Причина:**
- Строка 970: `u8:encode(ffi.string(test_input), encoding.default)` — `test_input` содержит UTF-8 от ImGui, но `u8:encode` конвертирует CP1251→UTF-8 (двойное кодирование). `formatAdText` работает с CP1251.
- Строка 972: `u8:decode(formatAdText(raw_text))` — `formatAdText` возвращает CP1251, но `u8:decode` ожидает UTF-8 → кириллица удаляется.
**Фикс:**
- Строка 970: `u8:decode(ffi.string(test_input))` — UTF-8 → CP1251 для formatAdText
- Строка 972: `u8:encode(formatAdText(raw_text))` — CP1251 → UTF-8 для ImGui

#### БАГ-8: Кодировка в MM Editor (добавление правил)
**Строки:** 1024, 1026
**Симптом:** Новые правила сокращений сохраняются с двойным кодированием
**Причина:** `u8:encode(ffi.string(static_new_abbr), encoding.default)` — берёт UTF-8 из ImGui, конвертирует как CP1251→UTF-8 (двойное кодирование). Но `mm_rules` должны хранить CP1251 (для `formatAdText` pattern matching).
**Фикс:** `u8:decode(ffi.string(static_new_abbr))` — UTF-8 → CP1251.
**Но:** при этом `imgui.Text(rule.abbreviation ...)` на строке 996 будет показывать CP1251 в ImGui (мусор). Нужно: `imgui.Text(u8:encode(rule.abbreviation) .. " -> " .. u8:encode(rule.replacement))`.
**Альтернатива:** хранить `mm_rules` в UTF-8 и конвертировать при matching в `formatAdText`.

---

### 🟡 СРЕДНИЕ (неправильные сообщения)

#### БАГ-9: `u8:decode()` на CP1251 литералах в sampAddChatMessage
**Строки:** 1264, 1467, 1513, 1515, 1517, 1519, 1521, 1539, 1644, 1724, 1728, 1734, 1918, 1928, 1942, 2094, 2130, 2224
**Симптом:** Сообщения в чат SAMP выводятся без кириллицы (только ASCII часть)
**Причина:** `sampAddChatMessage(u8:decode("CP1251 литерал"), color)` — `u8:decode` ожидает UTF-8 на входе, но получает CP1251. С флагом `//IGNORE` кириллические байты молча удаляются.
**Правильно:** `sampAddChatMessage("CP1251 литерал", color)` — напрямую, без конвертации (sampAddChatMessage ожидает CP1251).
**Фикс:** Убрать `u8:decode(...)` обёртку во всех этих вызовах. ИЛИ заменить на `u8:decode(u8"литерал")` (roundtrip: CP1251→UTF-8→CP1251, работает но избыточно).

#### БАГ-10: `text_utf8:match(u8"LV%s*|%s*(.-)%s*%|")` — неправильный паттерн
**Строка:** 1450
**Симптом:** Поле `ad` в БД всегда пустое
**Причина:** Паттерн ищет "LV | ... |" в тексте объявления, но:
1. Формат объявлений Advance RP может не содержать префикс "LV"
2. `%|` — избыточное экранирование (`|` не спецсимвол в Lua паттернах, но работает)
3. Если паттерн не находит совпадение, `match` возвращает `nil`, и `or ""` даёт пустую строку
**Фикс:** Проверить реальный формат объявлений на сервере и скорректировать паттерн.

---

### 🟢 НИЗКИЕ (косметика / потенциальные проблемы)

#### БАГ-11: `strobeWorker` сбрасывает `strobe_enabled[0]` при выходе
**Строка:** 1874
**Симптом:** После выхода из машины стробоскоп нельзя включить заново через GUI (чекбокс сброшен)
**Причина:** `strobeWorker` завершается с `strobe_enabled[0] = false` (строка 1874), что сбрасывает чекбокс в GUI без вызова `saveSettings()`.
**Фикс:** Не сбрасывать `strobe_enabled[0]` в воркере, только `strobe_active = false`.

#### БАГ-12: Несоответствие индексов модулей
**Строки:** 1632, 1752, 1900
**Симптом:** Проверка `modules[5].enabled` хардкодит индекс модуля vehicle_visuals
**Причина:** Если порядок модулей в таблице изменится, хардкод `modules[5]` сломается.
**Фикс:** Использовать `isModuleEnabled("vehicle_visuals")` вместо `modules[5].enabled`.

#### БАГ-13: `factionScannerWorker` — `sampGetDialogCaption()` может вернуть nil
**Строка:** 1324
**Симптом:** `attempt to index local 'title' (a nil value)` если диалог без заголовка
**Причина:** `title:find("...")` вызывается без проверки на nil.
**Фикс:** `local title = sampGetDialogCaption() or ""`

#### БАГ-14: `getOnlinePlayersFromDb` — `sampGetPlayerIdByCharHandle` может не вернуть результат
**Строка:** 637
**Симптом:** `attempt to call a nil value` если игрок не в игре
**Причина:** `sampGetPlayerIdByNickname(sampGetPlayerNickname(sampGetPlayerIdByCharHandle(PLAYER_PED)))` — вложенные вызовы без проверки результатов.
**Фикс:** Разложить на шаги с проверками.

#### БАГ-15: `dialogScannerWorker` — пустой блок логики
**Строки:** 1688-1694
**Симптом:** MM Editor авто-форматирование не работает
**Причина:** Блок `if sender and phone then -- ... end` пустой (только комментарий). Логика авто-форматирования не реализована.
**Фикс:** Реализовать логику или удалить мёртвый код.

#### БАГ-16: `chatScannerWorker` — закомментирован
**Строка:** 1610
**Симптом:** Сканер чата не работает
**Причина:** `-- lua_thread.create(chatScannerWorker)` — запуск закомментирован, и `chatScannerWorker` нигде не определён.
**Фикс:** Удалить закомментированную строку или реализовать воркер.

#### БАГ-17: `formatAdText` — паттерны с однобайтовыми классами
**Строки:** 543-553
**Симптом:** Удаление слов "куплю/продам" может не работать для кириллицы
**Причина:** Паттерны вроде `%f[%a][к]%s+[п][к]%f[%A]` используют классы `%a`/`%A`, которые в LuaJIT работают по байтам. Для CP1251 кириллицы `%a` может не сработать (не ASCII буква).
**Фикс:** Использовать явные диапазоны CP1251: `[%wа-яА-Я]` вместо `%a`.

---

## 4. Сводка багов по приоритету

| # | Приоритет | Баг | Строки | Статус |
|---|-----------|-----|--------|--------|
| 1 | 🔴 Крит | `strobe_sequences` не объявлена | 1828,1830 | НЕ ИСПРАВЛЕНО |
| 2 | 🔴 Крит | `selected_faction` не объявлена | 1362,1364,1521,2005 | НЕ ИСПРАВЛЕНО |
| 3 | 🔴 Крит | `rp_engine_enabled` не объявлена | 1519 | НЕ ИСПРАВЛЕНО |
| 4 | 🟠 Выс | `PopStyleColor` без `PushStyleColor` | 1128,1146,1160,1176 | НЕ ИСПРАВЛЕНО |
| 5 | 🟠 Выс | Кодировка `static_aad_buf` | 812,817,824,841 | НЕ ИСПРАВЛЕНО |
| 6 | 🟠 Выс | Кодировка шаблонов/истории | 857,860,876,897,900,916 | НЕ ИСПРАВЛЕНО |
| 7 | 🟠 Выс | Кодировка MM Editor тест | 970,972 | НЕ ИСПРАВЛЕНО |
| 8 | 🟠 Выс | Кодировка MM Editor правил | 1024,1026 | НЕ ИСПРАВЛЕНО |
| 9 | 🟡 Ср | `u8:decode` на CP1251 литералах | 18 строк | НЕ ИСПРАВЛЕНО |
| 10 | 🟡 Ср | Паттерн `ad` в БД | 1450 | НЕ ИСПРАВЛЕНО |
| 11 | 🟢 Низ | `strobe_enabled` сброс в воркере | 1874 | НЕ ИСПРАВЛЕНО |
| 12 | 🟢 Низ | Хардкод `modules[5]` | 1632,1752,1900 | НЕ ИСПРАВЛЕНО |
| 13 | 🟢 Низ | `sampGetDialogCaption()` nil | 1324 | НЕ ИСПРАВЛЕНО |
| 14 | 🟢 Низ | Вложенные вызовы без проверки | 637 | НЕ ИСПРАВЛЕНО |
| 15 | 🟢 Низ | Пустой блок dialogScanner | 1688-1694 | НЕ ИСПРАВЛЕНО |
| 16 | 🟢 Низ | chatScannerWorker закомментирован | 1610 | НЕ ИСПРАВЛЕНО |
| 17 | 🟢 Низ | `%a` паттерны для кириллицы | 543-553 | НЕ ИСПРАВЛЕНО |

### Ранее исправленные баги (в этой сессии):
| # | Баг | Фикс |
|---|-----|------|
| ✅ | `sendAdCommand` used before declaration | Forward declaration + assignment |
| ✅ | `imgui.PushID` is nil | → `imgui.PushIDStr` |
| ✅ | `#static_strobe_names` on ffi array | → `imgui.ComboStr` |
