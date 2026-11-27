# Universal Helper Platform — Agent Harness

Самодостаточный инспекционный и верификационный **Agent Harness** для разработки и безопасной модификации `helper_core.lua` (GTA SA / SA-MP / MoonLoader / LuaJIT 2.1 / `mimgui` / `SAMP.Lua`).

---

## Быстрые команды

| Команда | Назначение |
|---|---|
| `python harness/run.py` | Полный набор проверок (CP1251+CRLF, LuaJIT лексер/AST/лимиты, render-thread `OnFrame`, контракты фаз, AutoEdit 1971 правил, `/find`, `/calc`, v1.9–v2.7) |
| `python harness/run.py --fast` | Быстрый gate (~1–2 сек): кодировка, структура Lua, лимиты LuaJIT, `OnFrame` безопасность, AST `LuaParser`/`ScopeAnalyzer` и регрессии |
| `python harness/run.py --fast --json` | То же в машиночитаемом JSON для оркестрации и CI |
| `python harness/run.py --snapshot` | Живая телеметрия `helper_core.lua`: версия, строки/байты, SHA256, текущий бюджет LuaJIT (`top_locals`, `max_active`, `max_upvals`), все модули и `sampev`-хуки |
| `python harness/run.py --deploy-check` | Проверка совпадения SHA256 и размера между репозиторием и `E:\ukraine_rp_runtime\moonloader\helper_core.lua` |
| `python harness/patch_helper.py --read 11525 11545` | Безопасное чтение строк CP1251 файла `helper_core.lua` с конвертацией в UTF-8 |
| `python harness/patch_helper.py --search "P1_getImguiInputState"` | Поиск по регулярному выражению в CP1251 `helper_core.lua` без искажения кириллицы |

---

## Библиотека безопасного патчинга (`harness/patch_helper.py`)

```python
from harness.patch_helper import load_helper, replace_once, save_helper

src = load_helper()
src = replace_once(src, OLD_BLOCK, NEW_BLOCK, label="v3.0 patch")
save_helper(src, verify_fast=True)  # Автооткат при падении `harness/run.py --fast`
```

---

## Активные хуки Antigravity (`.agents/hooks.json`)

1. **`cp1251-edit-guard` (`PreToolUse` на `edit_file|write_file`):** блокирует прямое редактирование `helper_core.lua` UTF-8 инструментами до повреждения кодировки CP1251 / CRLF.
2. **`harness-stop-gate` (`Stop`):** если в ходе работы менялся `helper_core.lua` (`git status`), автоматически прогоняет `python harness/run.py --fast` и не даёт агенту завершить ход с поломанным скриптом.
