# Установка Helper Core

## Что нужно копировать (обязательно)

| Файл | Куда копировать | Назначение |
|------|----------------|------------|
| `helper_core.lua` | `moonloader/helper_core.lua` | Основной скрипт |
| `config/helper_db.json` | `moonloader/config/helper_db.json` | База контактов (обзвон) |

> Остальные JSON-файлы (`helper_rp_settings.json`, `helper_blacklist.json`,
> `helper_ad_history.json`, `helper_settings.json`, `helper_mm_rules.json`)
> создаются автоматически при первом запуске в `%LOCALAPPDATA%` или
> `moonloader/config/`.

## Зависимости (одноразово)

Запусти `install_libs.ps1` в PowerShell, или установи вручную через `MoonLoader Package Manager`:

```
luarocks install mimgui
```

Требуемые библиотеки:
- **mimgui** — GUI (окно F11)
- **memory** — чтение/запись памяти GTA (погода, время, движок)
- **encoding** — конвертация CP1251 ↔ UTF8 (входит в MoonLoader)
- **ffi** — FFI LuaJIT (входит в MoonLoader)
- **json** — JSON (есть встроенный fallback, если не установлен)
- **lib.samp.events** — события SAMP (входит в SAMP.Lua)

## После установки

1. Скопируй файлы (см. таблицу выше)
2. Запусти игру
3. Нажми **F11** или введи `/helper` — откроется меню
4. Включи нужные модули в разделе «Модули»

## Папка `optional/`

Всё внутри `optional/` — **не нужно** копировать в игру:
- `.md` файлы — документация для разработчиков
- `*_backup.lua`, `*_reconstructed.lua`, `*_recovered.lua` — старые бэкапы
- `*_donor.lua`, `auto_gov.lua` — донор-скрипты (использовались как референс)

## Кодировка

`helper_core.lua` хранится в **CP1251**. Не открывай/не сохраняй его в UTF-8
редакторах — скрипт перестанет загружаться.
