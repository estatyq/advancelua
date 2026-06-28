# Инструкция по эксплуатации

Полное руководство по установке, настройке и использованию Universal Helper Platform v0.9.

---

## Шаг 1. Установка GTA San Andreas

1. Скачайте чистую **GTA San Andreas** версии **1.0** (Steam-версия не подойдёт — нужны пропатченные EXE)
2. Установите игру в любую папку, например `G:\GTA San Andreas\`
3. Убедитесь что `gta_sa.exe` версии 1.0 (размер ~14 МБ)

> Скачать чистую GTA SA v1.0 можно на любом трекере или сайте модов.

---

## Шаг 2. Установка SA-MP

1. Скачайте клиент **SA-MP 0.3.7-R1** с официального сайта: https://sa-mp.com/download.php
2. Установите в папку с игрой (туда же, где `gta_sa.exe`)
3. После установки появится `samp.exe` — это клиент для подключения к серверам

> Для Advance RP используется версия 0.3.7-R1 или R3 — уточните на сайте сервера.

---

## Шаг 3. Установка MoonLoader

MoonLoader — это загрузчик Lua-скриптов для GTA SA.

1. Скачайте **MoonLoader v0.26** (или новее):
   - Страница загрузки: https://libertycity.net/files/gta-san-andreas/131091-moonloader-0.27.html
   - Или с официальной темы на GTAForums: https://gtaforums.com/topic/890987-moonloader/
2. Распакуйте архив в папку с игрой
3. После установки появится папка `moonloader/` со структурой:
   ```
   GTA San Andreas/
   ├── gta_sa.exe
   ├── samp.exe
   └── moonloader/
       ├── moonloader.dll     (сам загрузчик)
       ├── lib/               (библиотеки Lua)
       ├── config/            (настройки скриптов)
       └── ...                (ваши .lua скрипты кладутся сюда)
   ```

---

## Шаг 4. Установка CLEO 4

CLEO нужен для работы SAMPFUNCS (плагин, который даёт скриптам доступ к функциям SAMP).

1. Скачайте **CLEO 4.3** (или новее):
   - https://cleo.li/ (официальный сайт)
   - Или: https://libertycity.net/files/gta-san-andreas/390-cleo-4.html
2. Установите в папку с игрой (рядом с `gta_sa.exe`)
3. После установки появятся файлы:
   ```
   GTA San Andreas/
   ├── gta_sa.exe
   ├── cleo.asi          ← сам CLEO
   ├── cleo/
   │   └── cleo_config.ini
   └── ...
   ```

> CLEO 4 обязателен — без него SAMPFUNCS не загрузится.

---

## Шаг 5. Установка библиотек

Скрипту нужны дополнительные библиотеки. Можно установить автоматически или вручную.

### Автоматически (PowerShell)

Запустите скрипт `install_libs.ps1` из этого репозитория:

```powershell
# Откройте PowerShell в папке проекта и выполните:
.\install_libs.ps1
```

> Перед запуском отредактируйте путь `$libPath` в файле `install_libs.ps1` — укажите вашу папку `moonloader/lib`.

### Вручную

Нужно скачать и положить в `moonloader/lib/` следующие библиотеки:

| Библиотека | Где скачать | Назначение |
|------------|-------------|------------|
| **mimgui** | https://github.com/THE-FYP/mimgui/releases | GUI-интерфейс (ImGui) |
| **SAMP.Lua** | https://github.com/THE-FYP/SAMP.Lua | События SAMP (чат, диалоги) |
| **SAMPFUNCS** | https://libertycity.net/files/gta-san-andreas/151974-sampfuncs-v-541-final.html | Доп. функции (CLEO+SA-MP) |
| **memory** | Входит в MoonLoader | Чтение/запись памяти игры |
| **bit** | Входит в MoonLoader | Побитовые операции |
| **encoding** | Входит в MoonLoader | Конвертация кодировок (CP1251 ↔ UTF-8) |
| **json** | Входит в MoonLoader | Чтение/запись JSON |
| **ffi** | Входит в LuaJIT (MoonLoader) | Foreign Function Interface |

**Порядок установки вручную:**

1. **mimgui**: скачайте `mimgui-v1.7.0.zip`, распакуйте, скопируйте папку `mimgui/` и файл `mimgui.dll` в `moonloader/lib/`
2. **SAMP.Lua**: скачайте ZIP с GitHub, распакуйте, скопируйте папку `samp/` в `moonloader/lib/`
3. **SAMPFUNCS**: установите как CLEO-плагин — скопируйте `sampfuncs.asi` и `sampfuncs.ini` в папку с игрой (рядом с `gta_sa.exe`)

> **Важно:** `memory`, `bit`, `encoding`, `json`, `ffi` устанавливать **не нужно** — они входят в MoonLoader и LuaJIT. Просто установите MoonLoader (Шаг 2) и эти библиотеки будут доступны автоматически.

**Структура папок после установки всех библиотек:**
```
GTA San Andreas/
├── gta_sa.exe
├── sampfuncs.asi          ← SAMPFUNCS (рядом с игрой)
├── sampfuncs.ini
└── moonloader/
    ├── moonloader.dll
    └── lib/
        ├── mimgui.dll     ← mimgui
        ├── mimgui/        ← папка из mimgui
        │   └── ...
        └── samp/          ← SAMP.Lua
            └── events.lua
```

---

## Шаг 6. Установка скрипта

1. Скачайте файл `helper_core.lua` из этого репозитория:
   - **Прямая ссылка:** https://github.com/estatyq/advancelua/raw/main/helper_core.lua
   - Или кнопка **Code → Download ZIP** на https://github.com/estatyq/advancelua
   - Или клонируйте: `git clone https://github.com/estatyq/advancelua.git`
   - **Нужен только один файл — `helper_core.lua`** (остальные файлы в репо — документация)
2. Скопируйте `helper_core.lua` в папку `moonloader/`:
   ```
   GTA San Andreas/
   └── moonloader/
       └── helper_core.lua    ← сюда
   ```

---

## Шаг 7. Первый запуск

1. Запустите `samp.exe`
2. Подключитесь к серверу (например, Advance RP)
3. После загрузки в чате появится:
   ```
   Helper Core v0.8 (27.06.2026) загружен. Открыть меню: F11 или /helper
   ```
4. Нажмите **F11** — откроется главное меню

Если скрипт не загрузился — проверьте лог:
```
GTA San Andreas/moonloader/moonloader.log
```

---

## Шаг 8. Настройка

### Включение модулей
1. Откройте меню (**F11**)
2. Слева — список модулей, справа — настройки выбранного
3. Поставьте галочку «Активировать модуль»
4. Настройки сохраняются автоматически в `moonloader/config/helper_settings.json`

### Горячие клавиши
| Клавиша | Действие |
|---------|----------|
| `F11` | Открыть/закрыть меню |
| `C` | Круиз-контроль вкл/выкл (в машине) |
| `W` / `S` | Скорость круиза +5 / -5 |
| `J` | Стробоскопы вкл/выкл (в машине) |
| `N` | Следующий режим стробоскопов |
| `L` | `/lock` — закрыть/открыть машину |
| `K` | `/e` — завести/заглушить двигатель |

> Все клавиши отключены, когда открыт чат или диалог.

### Свои бинды клавиш
1. Меню → «Горячие клавиши»
2. Выберите клавишу из списка
3. Введите команду (например `/me открыл дверь`)
4. Введите название (например «Открыть дверь»)
5. Нажмите «+ Добавить»

### Турбо-режим круиз-контроля
1. Меню → «Транспорт и фары»
2. Поставьте галочку «Турбо-режим (риск!)»
3. В машине нажмите `C` — включится турбо-круиз
4. `W` / `S` — менять целевую скорость

> Турбо работает как спидхак. Безопасные проверки:
> - Не разгоняет при заглушенном двигателе
> - Пауза 3 сек после удара
> - Не применяет в полёте
> - Плавный разгон (не рывком)

---

## Устранение проблем

| Проблема | Решение |
|----------|---------|
| Скрипт не загружается | Проверьте `moonloader.log` на ошибки |
| `mimgui not found` | Установите mimgui в `moonloader/lib/` |
| `samp.events not found` | Установите SAMP.Lua в `moonloader/lib/` |
| Меню не открывается | Нажмите F11 или введите `/helper` в чат |
| Клавиши не работают | Закройте чат/диалог — клавиши отключены при вводе |
| Стробоскопы мерцают с погодой | Обновите скрипт — фикс в v0.8 |
| Турбо не разгоняет | Проверьте: двигатель заведён? Машина не в воздухе? |

---

## Структура файлов

```
GTA San Andreas/
├── gta_sa.exe
├── samp.exe
├── sampfuncs.asi              (SAMPFUNCS плагин)
├── moonloader/
│   ├── moonloader.dll
│   ├── helper_core.lua        (наш скрипт)
│   ├── moonloader.log         (лог ошибок)
│   ├── lib/
│   │   ├── mimgui/            (GUI библиотека)
│   │   ├── mimgui.dll
│   │   ├── samp/              (SAMP.Lua события)
│   │   ├── memory.lua
│   │   ├── bit.lua
│   │   ├── encoding.lua
│   │   └── json.lua
│   └── config/
│       └── helper_settings.json  (настройки скрипта)
```

---

## Ссылки для скачивания

| Компонент | Ссылка |
|-----------|--------|
| GTA SA v1.0 | Любой проверенный источник |
| SA-MP 0.3.7 | https://sa-mp.com/download.php |
| MoonLoader | https://libertycity.net/files/gta-san-andreas/131091-moonloader-0.27.html |
| mimgui | https://github.com/THE-FYP/mimgui/releases |
| SAMP.Lua | https://github.com/THE-FYP/SAMP.Lua |
| SAMPFUNCS | https://libertycity.net/files/gta-san-andreas/151974-sampfuncs-v-541-final.html |
| Скрипт (этот репозиторий) | https://github.com/estatyq/advancelua |

---

## Контакты и поддержка

- Репозиторий: https://github.com/estatyq/advancelua
- Issues (баги и предложения): https://github.com/estatyq/advancelua/issues
