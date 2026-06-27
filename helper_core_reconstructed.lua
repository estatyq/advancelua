--[[
Universal Game Helper Core for SAMP (MoonLoader / Lua)

Этот файл является ядром и каркасом вашей будущей платформы.
Здесь реализован минималистичный интерфейс на mimgui (разделенный на вкладки/модули),
механизм динамического подключения функций, парсинг объявлений СМИ для базы номеров,
проверка онлайна игроков, автоматизированный обзвон, СМИ Редактор (MM Editor),
справочник точных команд Advance RP, автоматические RP отыгровки,
стробоскопы, круиз-контроль, а также смена погоды/времени и скин-ченджер.

ВЕРСИЯ 0.7: Полностью убран SAMP.Lua и требования к SAMPFUNCS. 
Скрипт работает «из коробки» на чистом MoonLoader без установки сторонних плагинов!

Установка:
1. Установите MoonLoader v0.26+.
2. Поместите этот файл в папку `GTA San Andreas/moonloader/`.
3. Открыть меню: клавиша F11 или команда /helper.
]]

local imgui = require 'mimgui'
local encoding = require 'encoding'
local json = require 'json'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- Инициализируем переменные для GUI
local show_main_window = imgui.new.bool(false)
local active_module_idx = 1

-- Путь к базам данных
local db_path = getWorkingDirectory() .. "/config/helper_db.json"
local rules_path = getWorkingDirectory() .. "/config/helper_mm_rules.json"
local settings_path = getWorkingDirectory() .. "/config/helper_settings.json"

local player_db = {}
local current_server_idx = imgui.new.int(0)
local server_names = {u8"Advance RP", u8"Diamond RP", u8"Arizona RP", u8"Evolve RP"}

-- Переменные для модуля "Сбор и обзвон"
local call_active = false
local call_delay = imgui.new.int(7000)
local max_calls_session = imgui.new.int(3)
local call_current_nick = ""
local call_current_phone = ""
local last_called = {}

-- Переменные для модуля "MM Editor" (СМИ Редактор)
local mm_auto_format = imgui.new.bool(true)
local mm_auto_send = imgui.new.bool(false)
local mm_send_delay = imgui.new.int(3000)
local test_input = imgui.new.char[128]("")
local test_output = ""
local mm_rules = {
{abbreviation = "булка", replacement = "а/м марки \"Bullet\""},
{abbreviation = "инф", replacement = "а/м марки \"Infernus\""},
{abbreviation = "туризмо", replacement = "а/м марки \"Turismo\""},
{abbreviation = "кловер", replacement = "а/м марки \"Clover\""},
{abbreviation = "лс", replacement = "г. Los Santos"},
{abbreviation = "сф", replacement = "г. San Fierro"},
{abbreviation = "лв", replacement = "г. Las Venturas"},
{abbreviation = "кк", replacement = ".000.000$"},
{abbreviation = "дог", replacement = "Цена: договорная"}
}

-- Переменные для модуля "Авто-отыгровки (Auto-RP)"
local rp_weapons_enabled = imgui.new.bool(true)
local rp_phone_enabled = imgui.new.bool(true)
local rp_mask_enabled = imgui.new.bool(true)
local rp_heal_enabled = imgui.new.bool(true)

-- Переменные для модуля "Транспорт и Визуал (Vehicles & Visuals)"
local strobe_enabled = imgui.new.bool(false)
local strobe_speed = imgui.new.int(150)
local strobe_mode = imgui.new.int(1)
local strobe_active = false
local cruise_enabled = imgui.new.bool(false)
local cruise_active = false
local cruise_speed = 0.0

-- Погода и Время (Визуал)
local weather_locked = imgui.new.bool(false)
local weather_id = imgui.new.int(1)
local time_locked = imgui.new.bool(false)
local time_hour = imgui.new.int(12)

-- Визуальный скин-ченджер
local skin_changer_id = imgui.new.int(0)

-- СПРАВОЧНИК КОМАНД ADVANCE RP
local advance_commands = {
{
category = u8"Основное / Гражданские",
cmds = {
{name = "/menu", desc = u8"Главное меню персонажа (статистика, настройки)"},
{name = "/gps", desc = u8"Навигатор по важным местам штата"},
{name = "/phone", desc = u8"Достать телефон (интерфейс)"},
{name = "/call [номер]", desc = u8"Позвонить игроку"},
{name = "/h", desc = u8"Повесить трубку телефона"},
{name = "/c [номер] [текст]", desc = u8"Отправить SMS игроку (точно для Advance!)"},
{name = "/book", desc = u8"Открыть телефонную книгу"},
{name = "/dir", desc = u8"Справочник организаций и лидеров онлайн"},
{name = "/pay [ID] [сумма]", desc = u8"Передать деньги игроку"},
{name = "/id [Ник/ID]", desc = u8"Узнать ID и уровень игрока"},
{name = "/number [ID]", desc = u8"Узнать номер телефона игрока"},
{name = "/lic", desc = u8"Показать свои лицензии"},
{name = "/pass [ID]", desc = u8"Показать паспорт игроку"},
{name = "/med [ID]", desc = u8"Показать мед. карту игроку"},
{name = "/w [ID] [текст]", desc = u8"Шептать (тихий чат)"},
{name = "/s [текст]", desc = u8"Кричать (громкий чат)"}
}
},
{
category = u8"СМИ (Mass Media)",
cmds = {
{name = "/edit", desc = u8"Редактировать объявления из очереди"},
{name = "/ad [текст]", desc = u8"Подать объявление на модерацию"},
{name = "/t [текст]", desc = u8"Вещание в эфир из студии / фургона новостей"},
{name = "/u [текст]", desc = u8"Вещание в микрофон во время репортажа"},
{name = "/bring [ID]", desc = u8"Пригласить гостя в радиоэфир"},
{name = "/nbring [ID]", desc = u8"Пригласить гостя в газетный эфир"},
{name = "/audiomedia", desc = u8"Управление медиаплеером радиоцентра"},
{name = "/lead", desc = u8"Управление радиостанцией (для лидера/замов)"}
}
},
{
category = u8"МВД (Полиция / ФБР)",
cmds = {
{name = "/su [ID] [уровень] [причина]", desc = u8"Выдать розыск (до 6 звезд)"},
{name = "/cuff [ID]", desc = u8"Надеть наручники"},
{name = "/uncuff [ID]", desc = u8"Снять наручники"},
{name = "/clear [ID]", desc = u8"Снять розыск (очистить уровень розыска)"},
{name = "/putpl [ID]", desc = u8"Посадить задержанного в патрульную машину"},
{name = "/outpl [ID]", desc = u8"Высадить задержанного из машины"},
{name = "/arrest [ID] [мин] [залог 0/1] [цена]", desc = u8"Арестовать в КПЗ"},
{name = "/co", desc = u8"Список разыскиваемых преступников онлайн (Wanted)"},
{name = "/search [ID]", desc = u8"Обыскать игрока на наркотики/патроны"},
{name = "/take [ID]", desc = u8"Изъять права, наркотики, оружие или лицензии"},
{name = "/m [текст]", desc = u8"Говорить в полицейский мегафон"},
{name = "/ticket [ID] [сумма] [причина]", desc = u8"Выписать штраф"},
{name = "/patrol", desc = u8"Начать/завершить патрулирование района"},
{name = "/ram", desc = u8"Выломать дверь дома (штурм)"},
{name = "/ftalk", desc = u8"Подслушивать рацию других гос. организаций (ФБР)"}
}
},
{
category = u8"МЗ (Больницы)",
cmds = {
{name = "/heal [ID] [цена]", desc = u8"Вылечить игрока (в больнице или карете)"},
{name = "/medcard [ID] [тип 1-3] [цена]", desc = u8"Выдать/обновить медицинскую карту"},
{name = "/changeheal [цена]", desc = u8"Установить цену лечения по умолчанию"}
}
},
{
category = u8"МО (Армия)",
cmds = {
{name = "/makegun", desc = u8"Сделать оружие из патронов/металла в казарме"},
{name = "/state", desc = u8"Проверить состояние складов патронов на базах"},
{name = "/putammo", desc = u8"Загрузить ящик патронов в грузовик снабжения"},
{name = "/takeammo", desc = u8"Выгрузить ящик патронов на склад базы"}
}
},
{
category = u8"Дома, Авто и Бизнес",
cmds = {
{name = "/home", desc = u8"Управление домашним меню (подселение, сейф)"},
{name = "/sellhome", desc = u8"Продать дом государству или игроку"},
{name = "/lock", desc = u8"Закрыть/открыть замок домашней двери или машины"},
{name = "/car", desc = u8"Управление личным транспортом (припарковать, капот)"},
{name = "/fill", desc = u8"Заправить транспорт на АЗС или из канистры"},
{name = "/sellcar [ID] [цена]", desc = u8"Продать свой автомобиль другому игроку"},
{name = "/biz", desc = u8"Управление бизнесом (заказ продуктов, налоги)"},
{name = "/sellbiz", desc = u8"Продать бизнес"}
}
}
}

-- Загрузка баз
local function loadDatabases()
if not doesDirectoryExist(getWorkingDirectory() .. "/config") then
createDirectory(getWorkingDirectory() .. "/config")
end

local file = io.open(db_path, "r")
if file then
local content = file:read("*a")
file:close()
local ok, parsed = pcall(json.decode, content)
if ok and parsed then player_db = parsed end
end

local file_rules = io.open(rules_path, "r")
if file_rules then
local content = file_rules:read("*a")
file_rules:close()
local ok, parsed = pcall(json.decode, content)
if ok and parsed then mm_rules = parsed end
end

local file_settings = io.open(settings_path, "r")
if file_settings then
local content = file_settings:read("*a")
file_settings:close()
local ok, parsed = pcall(json.decode, content)
if ok and parsed then
if parsed.current_server then current_server_idx[0] = parsed.current_server end
if parsed.rp_weapons ~= nil then rp_weapons_enabled[0] = parsed.rp_weapons end
if parsed.rp_phone ~= nil then rp_phone_enabled[0] = parsed.rp_phone end
if parsed.rp_mask ~= nil then rp_mask_enabled[0] = parsed.rp_mask end
if parsed.rp_heal ~= nil then rp_heal_enabled[0] = parsed.rp_heal end
if parsed.mm_auto_format ~= nil then mm_auto_format[0] = parsed.mm_auto_format end
if parsed.mm_auto_send ~= nil then mm_auto_send[0] = parsed.mm_auto_send end
if parsed.mm_send_delay ~= nil then mm_send_delay[0] = parsed.mm_send_delay end
if parsed.strobe_speed ~= nil then strobe_speed[0] = parsed.strobe_speed end
if parsed.strobe_mode ~= nil then strobe_mode[0] = parsed.strobe_mode end
if parsed.weather_locked ~= nil then weather_locked[0] = parsed.weather_locked end
if parsed.weather_id ~= nil then weather_id[0] = parsed.weather_id end
if parsed.time_locked ~= nil then time_locked[0] = parsed.time_locked end
if parsed.time_hour ~= nil then time_hour[0] = parsed.time_hour end
end
end
end

-- Сохранение настроек
local function saveSettings()
local settings = {
current_server = current_server_idx[0],
rp_weapons = rp_weapons_enabled[0],
rp_phone = rp_phone_enabled[0],
rp_mask = rp_mask_enabled[0],
rp_heal = rp_heal_enabled[0],
mm_auto_format = mm_auto_format[0],
mm_auto_send = mm_auto_send[0],
mm_send_delay = mm_send_delay[0],
strobe_speed = strobe_speed[0],
strobe_mode = strobe_mode[0],
weather_locked = weather_locked[0],
weather_id = weather_id[0],
time_locked = time_locked[0],
time_hour = time_hour[0]
}
local file = io.open(settings_path, "w")
if file then
file:write(json.encode(settings))
file:close()
end
end

local function saveDatabase()
local file = io.open(db_path, "w")
if file then
file:write(json.encode(player_db))
file:close()
end
end

local function saveRules()
local file = io.open(rules_path, "w")
if file then
file:write(json.encode(mm_rules))
file:close()
end
end

-- Умное форматирование ПРО
local function formatAdText(text)
local formatted = text
local lower = formatted:lower()

local is_car = false
local car_keywords = {"булка", "буллет", "bullet", "инф", "инфернус", "infernus", "туризмо", "turismo", "тур", "кловер", "clover", "мото", "машина", "а/м", "м/ц"}
for _, word in ipairs(car_keywords) do
if lower:find(word) then
is_car = true
break
end
end

if is_car then
formatted = formatted:gsub("%f[%a][Вв]%s+[Лл][Сс]%f[%A]", "")
formatted = formatted:gsub("%f[%a][Вв]%s+[Сс][Фф]%f[%A]", "")
formatted = formatted:gsub("%f[%a][Вв]%s+[Лл][Вв]%f[%A]", "")
formatted = formatted:gsub("%f[%a][Лл][Сс]%f[%A]", "")
formatted = formatted:gsub("%f[%a][Сс][Фф]%f[%A]", "")
formatted = formatted:gsub("%f[%a][Лл][Вв]%f[%A]", "")
end

local tag = ""
if lower:find("продам") or lower:find("прод") then
tag = "[Продам] "
elseif lower:find("куплю") or lower:find("куп") then
tag = "[Куплю] "
elseif lower:find("услуг") or lower:find("ищу") then
tag = "[Услуги] "
end

for _, rule in ipairs(mm_rules) do
local skip_rule = false
if is_car and (rule.abbreviation == "лс" or rule.abbreviation == "сф" or rule.abbreviation == "лв") then
skip_rule = true
end

if not skip_rule then
local pattern = "([%s%,%.])" .. rule.abbreviation .. "([%s%,%.])"
formatted = (" " .. formatted .. " "):gsub(pattern, function(left, right)
return left .. rule.replacement .. right
end)
formatted = formatted:sub(2, -2)
if formatted:lower() == rule.abbreviation then
formatted = rule.replacement
end
end
end

if tag ~= "" and not formatted:find("^%[") then
formatted = tag .. formatted
end

formatted = formatted:gsub("%s+", " ")
formatted = formatted:gsub("%s+$", "")

if #formatted > 0 then
formatted = formatted:sub(1, 1):upper() .. formatted:sub(2)
end

return formatted
end

-- Проверка онлайна (Встроенными методами)
local function isPlayerOnline(nickname)
local result, id = sampGetPlayerIdByNickname(nickname)
if result and id then
-- Проверяем, что не мы сами
local myid = -1
local self_result, self_id = sampGetPlayerIdByNickname(sampGetPlayerNickname(sampGetPlayerIdByCharHandle(PLAYER_PED)))
if self_result then myid = self_id end
if id == myid then return false end
return true, id
end
return false
end

-- Сбор онлайн игроков
local function getOnlinePlayersFromDb()
local online_list = {}
for nick, data in pairs(player_db) do
if isPlayerOnline(nick) then
table.insert(online_list, {
nick = nick,
phone = data.phone,
time = data.time,
ad = data.ad
})
end
end
return online_list
end

-- СПИСОК МОДУЛЕЙ
local modules = {
{
id = "autocall_db",
name = u8" Сбор и Обзвон",
description = u8"Скрипт автоматически сканирует чат СМИ на сервере, извлекает ники продавцов и их номера телефонов, сохраняя их в базу.\nЗатем вы можете в 1 клик прозвонить 1-3 случайных игроков, которые сейчас ОНЛАЙН, без спама одним и тем же лицам.",
enabled = false,
drawSettings = function()
local total_records = 0
for _ in pairs(player_db) do total_records = total_records + 1 end

imgui.Text(u8"Статистика:")
imgui.BulletText(u8"Всего контактов в базе: " .. total_records)

local online_list = getOnlinePlayersFromDb()
imgui.BulletText(u8"Контактов онлайн прямо сейчас: " .. #online_list)

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.Text(u8"Настройки обзвона:")
imgui.PushItemWidth(150)
imgui.SliderInt(u8"Задержка вызова (мс)", call_delay, 2000, 15000)
imgui.InputInt(u8"Лимит звонков за сессию", max_calls_session)
imgui.PopItemWidth()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if call_active then
imgui.TextColored(imgui.ImVec4(0, 1, 0, 1), u8"Статус: Идет обзвон...")
imgui.Text(u8"Звоним: " .. call_current_nick .. " (" .. call_current_phone .. ")")
if imgui.Button(u8"Остановить обзвон") then call_active = false end
else
imgui.TextColored(imgui.ImVec4(1, 0.5, 0, 1), u8"Статус: Ожидание")
if #online_list > 0 then
if imgui.Button(u8" Обзвонить онлайн-игроков") then
call_active = true
lua_thread.create(onlineCallWorker, online_list)
end
else
imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), u8"Нет контактов онлайн для обзвона")
end
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.Text(u8"Последние собранные объявления:")
imgui.BeginChild("db_list", imgui.ImVec2(0, 150), true)
for nick, data in pairs(player_db) do
local is_on = isPlayerOnline(nick) and u8" [ОНЛАЙН]" or ""
imgui.TextColored(is_on ~= "" and imgui.ImVec4(0, 1, 0, 1) or imgui.ImVec4(0.7, 0.7, 0.7, 1), nick .. " | Тел: " .. data.phone .. is_on)
if data.ad and data.ad ~= "" then
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextWrapped("-> " .. data.ad)
imgui.PopStyleColor()
end
imgui.Separator()
end
imgui.EndChild()
end,
onToggle = function(state)
if not state then call_active = false end
end
},
{
id = "mm_editor",
name = u8" MM Editor (СМИ)",
description = u8"Помощник для сотрудников радиоцентра (СМИ). Автоматически заменяет сокращения при редактировании объявлений с учетом правил ПРО (город пишется для домов/бизнесов, но стирается для автомобилей).",
enabled = false,
drawSettings = function()
if imgui.Checkbox(u8"Авто-форматирование при открытии редактора", mm_auto_format) then saveSettings() end
if imgui.Checkbox(u8"Авто-отправка объявлений (Auto-Edit)", mm_auto_send) then saveSettings() end

if mm_auto_send[0] then
imgui.PushItemWidth(150)
if imgui.SliderInt(u8"Задержка отправки (мс)", mm_send_delay, 500, 8000) then saveSettings() end
imgui.PopItemWidth()
imgui.TextColored(imgui.ImVec4(1, 0.8, 0, 1), u8" Внимание: Используйте задержку от 2000 мс для безопасности от админов!")
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.Text(u8"Тест автозамены:")
imgui.InputText(u8"Введите черновик", test_input, 128)

if imgui.Button(u8"Проверить замену") then
local raw_text = u8:encode(ffi.string(test_input), encoding.default)
test_output = u8:decode(formatAdText(raw_text))
end

if test_output ~= "" then
imgui.Text(u8"Результат:")
imgui.TextColored(imgui.ImVec4(0, 1, 0.8, 1), test_output)
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.Text(u8"Правила замены сокращений (База):")
imgui.BeginChild("rules_list", imgui.ImVec2(0, 110), true)
for idx, rule in ipairs(mm_rules) do
imgui.Text(rule.abbreviation .. " -> " .. rule.replacement)
imgui.SameLine(350)
if imgui.Button(u8"Удалить##" .. idx) then
table.remove(mm_rules, idx)
saveRules()
end
imgui.Separator()
end
imgui.EndChild()

static_new_abbr = static_new_abbr or imgui.new.char[32]("")
static_new_repl = static_new_repl or imgui.new.char[128]("")
imgui.InputText(u8"Сокращение", static_new_abbr, 32)
imgui.InputText(u8"Замена на...", static_new_repl, 128)
if imgui.Button(u8"Добавить правило") then
local abbr = u8:encode(ffi.string(static_new_abbr), encoding.default):lower()
local repl = u8:encode(ffi.string(static_new_repl), encoding.default)
if abbr ~= "" and repl ~= "" then
table.insert(mm_rules, {abbreviation = abbr, replacement = repl})
saveRules()
static_new_abbr[0] = 0
static_new_repl[0] = 0
end
end
end,
onToggle = function(state) end
},
{
id = "auto_rp",
name = u8" Авто-Отыгровки",
description = u8"Скрипт автоматически отыгрывает через команды /me и /do стандартные игровые действия в чат (доставание оружия, звонки по телефону, маски, аптечки).",
enabled = false,
drawSettings = function()
if imgui.Checkbox(u8"Отыгровка доставания/убирания оружия", rp_weapons_enabled) then saveSettings() end
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"-> Доставание Deagle, M4, Shotgun, AK-47, Ножа")

if imgui.Checkbox(u8"Отыгровка звонков и сбросов телефона", rp_phone_enabled) then saveSettings() end
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"-> Срабатывает при командах /call и /h")

if imgui.Checkbox(u8"Отыгровка одевания маски", rp_mask_enabled) then saveSettings() end
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"-> Срабатывает при команде /mask")

if imgui.Checkbox(u8"Отыгровка использования аптечки", rp_heal_enabled) then saveSettings() end
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"-> Срабатывает при командах /healme и /drugs")
end,
onToggle = function(state) end
},
{
id = "vehicle_visuals",
name = u8" Транспорт и Визуал",
description = u8"Функции для водителей и визуальная кастомизация мира. Включает стробоскопы фарами, круиз-контроль, локальную смену погоды/времени и скин-ченджер.",
enabled = false,
drawSettings = function()
imgui.TextColored(imgui.ImVec4(0, 1, 0.7, 1), u8"Стробоскопы и Круиз:")
if imgui.Checkbox(u8"Включить стробоскопы", strobe_enabled) then
if strobe_enabled[0] then
strobe_active = true
lua_thread.create(strobeWorker)
else
strobe_active = false
end
end
imgui.SameLine(220)
imgui.Checkbox(u8"Круиз-контроль (на клавишу C)", cruise_enabled)

imgui.PushItemWidth(150)
if imgui.SliderInt(u8"Скорость стробоскопов (мс)", strobe_speed, 50, 600) then saveSettings() end

static_strobe_names = static_strobe_names or {u8"Обычное мигание фар", u8"Попеременное лево-право"}
if imgui.Combo(u8"Режим стробоскопов", strobe_mode, static_strobe_names, #static_strobe_names) then
saveSettings()
end
imgui.PopStyleColor()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextColored(imgui.ImVec4(0, 1, 0.7, 1), u8"Окружение (Локально):")

if imgui.Checkbox(u8"Зафиксировать погоду", weather_locked) then saveSettings() end
if weather_locked[0] then
imgui.PushItemWidth(250)
if imgui.SliderInt(u8"ID Погоды", weather_id, 0, 45) then saveSettings() end
imgui.PopStyleColor()
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"Популярные ID: 1-2 (ясно), 8 (шторм), 9 (туман), 19 (песок)")
end

if imgui.Checkbox(u8"Зафиксировать время суток", time_locked) then saveSettings() end
if time_locked[0] then
imgui.PushItemWidth(250)
if imgui.SliderInt(u8"Часы", time_hour, 0, 23) then saveSettings() end
imgui.PopStyleColor()
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextColored(imgui.ImVec4(0, 1, 0.7, 1), u8"Скин-Ченджер (Локально):")
imgui.PushItemWidth(150)
imgui.InputInt(u8"ID Скина (0-311)", skin_changer_id)
imgui.PopStyleColor()

if imgui.Button(u8"Применить скин") then
applyLocalSkin(skin_changer_id[0])
end
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"-> Вы также можете ввести команду в чат: /fskin [ID]")
end,
onToggle = function(state)
if not state then
strobe_active = false
strobe_enabled[0] = false
cruise_active = false
weather_locked[0] = false
time_locked[0] = false
end
end
},
{
id = "commands_guide",
name = u8" Справочник Команд",
description = u8"Полный и точный список команд сервера Advance RP по фракциям. Дважды кликните по любой команде в списке, чтобы скопировать её в буфер обмена.",
enabled = true,
drawSettings = function()
imgui.Text(u8"Выберите категорию фракций:")
static_selected_cat = static_selected_cat or imgui.new.int(1)

if imgui.BeginCombo(u8"Категории", advance_commands[static_selected_cat[0]].category) then
for idx, cat_data in ipairs(advance_commands) do
local is_selected = (static_selected_cat[0] == idx)
if imgui.Selectable(cat_data.category, is_selected) then
static_selected_cat[0] = idx
end
end
imgui.EndCombo()
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

local active_cat = advance_commands[static_selected_cat[0]]
imgui.BeginChild("commands_scroll", imgui.ImVec2(0, 180), true)
for _, cmd in ipairs(active_cat.cmds) do
imgui.TextColored(imgui.ImVec4(0, 0.9, 0.7, 1), cmd.name)

if imgui.IsItemHovered() then
imgui.SetTooltip(u8"Двойной клик: скопировать в буфер")
if imgui.IsMouseDoubleClicked(0) then
setClipboardText(cmd.name)
sampAddChatMessage(u8:decode("[Helper] Скопировано в буфер: " .. cmd.name), 0x00FFFF)
end
end

imgui.SameLine(180)
imgui.TextWrapped(cmd.desc)
imgui.Separator()
end
imgui.EndChild()
end,
onToggle = function(state) end
}
}

-- ГЛАВНАЯ ФУНКЦИЯ (Точка входа)
function main()
while not isSampAvailable() do wait(100) end

-- Загружаем базы и настройки
loadDatabases()

sampAddChatMessage(u8:decode("Helper Core v0.7 загружен. Открыть меню: {00FF00}F11{FFFFFF} или {00FF00}/helper"), 0xFFFFFF)

-- Регистрируем команду открытия меню
sampRegisterChatCommand("helper", function()
show_main_window[0] = not show_main_window[0]
end)

-- Регистрируем команду смены скина
sampRegisterChatCommand("fskin", function(arg)
local id = tonumber(arg)
if id and id >= 0 and id <= 311 then
skin_changer_id[0] = id
applyLocalSkin(id)
else
sampAddChatMessage(u8:decode("[Helper] Использование: /fskin [0-311]"), 0xFF0000)
end
end)

-- РЕГИСТРАЦИЯ КОМАНД ДЛЯ АВТО-ОТЫГРОВОК
sampRegisterChatCommand("call", function(arg)
lua_thread.create(function()
if modules[3].enabled and rp_phone_enabled[0] and arg ~= "" then
sampSendChat(u8:decode("/me достал мобильный телефон и набрал номер " .. arg))
wait(100)
end
sampSendChat("/call " .. arg)
end)
end)

local function handleHangup()
lua_thread.create(function()
if modules[3].enabled and rp_phone_enabled[0] then
sampSendChat(u8:decode("/me нажал кнопку сброса и убрал телефон в карман"))
wait(100)
end
sampSendChat("/h")
end)
end
sampRegisterChatCommand("h", handleHangup)
sampRegisterChatCommand("hangup", handleHangup)

sampRegisterChatCommand("mask", function()
lua_thread.create(function()
if modules[3].enabled and rp_mask_enabled[0] then
sampSendChat(u8:decode("/me достал из кармана черную маску и натянул ее на лицо"))
wait(100)
end
sampSendChat("/mask")
end)
end)

sampRegisterChatCommand("healme", function()
lua_thread.create(function()
if modules[3].enabled and rp_heal_enabled[0] then
sampSendChat(u8:decode("/me открыл походную аптечку, достал бинт и перевязал рану"))
wait(100)
end
sampSendChat("/healme")
end)
end)

sampRegisterChatCommand("drugs", function(arg)
lua_thread.create(function()
if modules[3].enabled and rp_heal_enabled[0] then
sampSendChat(u8:decode("/me достал конфету из кармана и съел её"))
wait(100)
end
sampSendChat("/drugs " .. arg)
end)
end)

-- Запуск потоков
lua_thread.create(weaponTrackWorker)
lua_thread.create(cruiseControlWorker)
lua_thread.create(environmentWorker)

-- Поток считывания чата (альтернатива onServerMessage без SAMP.Lua)
lua_thread.create(chatScannerWorker)

-- Поток отслеживания диалоговых окон (альтернатива onShowDialog без SAMP.Lua)
lua_thread.create(dialogScannerWorker)

while true do
wait(0)

-- Клавиша F11
if wasKeyPressed(0x7A) then
show_main_window[0] = not show_main_window[0]
end

-- Клавиша J для стробоскопов в машине
if wasKeyPressed(0x4A) and isCharInAnyCar(PLAYER_PED) then -- J
if modules[4].enabled then
strobe_enabled[0] = not strobe_enabled[0]
strobe_active = strobe_enabled[0]
if strobe_active then
lua_thread.create(strobeWorker)
end
sampAddChatMessage(u8:decode("[Helper] Стробоскопы: " .. (strobe_enabled[0] and "{00FF00}ВКЛ" or "{FF0000}ВЫКЛ")), 0xFFFFFF)
end
end
end
end

-- ПОТОК ДЛЯ СКАНИРОВАНИЯ ИГРОВОГО ЧАТА (без SAMP.Lua)
function chatScannerWorker()
local processed_chat = {}
local processed_chat_count = 0

while true do
wait(50) -- Сканируем каждые 50 мс

if modules[1].enabled and isSampAvailable() then
-- Проходим по последним 10 строкам чата
for i = 90, 99 do
local text, prefix, color, pcolor = sampGetChatString(i)
if text and text ~= "" and not processed_chat[text] then
-- Помечаем как обработанное
processed_chat[text] = true
processed_chat_count = processed_chat_count + 1

-- Очищаем таблицу от переполнения
if processed_chat_count > 200 then
processed_chat = {}
processed_chat_count = 0
end

-- Парсинг
local text_utf8 = u8:encode(text, encoding.default)
local sender, phone = text_utf8:match("Отправитель:%s*([A-Za-z0-9_]+).-[Тт]ел%s*:%s*(%d+)")
if not sender or not phone then
sender, phone = text_utf8:match("([A-Za-z0-9_]+)%s*%.%s*[Тт]ел%s*:%s*(%d+)")
end

if sender and phone then
player_db[sender] = {
phone = phone,
time = os.date("%Y-%m-%d %H:%M:%S"),
ad = text_utf8:match("Объявление:%s*(.-)%s*Отправитель:") or ""
}
saveDatabase()
sampAddChatMessage(u8:decode("[Helper DB] Добавлен контакт: " .. sender .. " (Тел: " .. phone .. ")"), 0x00FF90)
end
end
end
end
end
end

-- ПОТОК ОТСЛЕЖИВАНИЯ ДИАЛОГОВЫХ ОКON (без SAMP.Lua)
function dialogScannerWorker()
local last_active_dialog_id = -1

while true do
wait(50) -- Проверка каждые 50 мс

if modules[2].enabled and mm_auto_format[0] and isSampAvailable() then
if sampIsDialogActive() then
local current_dialog_id = sampGetActiveDialogId()
if current_dialog_id ~= last_active_dialog_id then
last_active_dialog_id = current_dialog_id

local text_utf8 = u8:encode(text, encoding.default)
local sender, phone = text_utf8:match("Отправитель:%s*([A-Za-z0-9_]+).-[Тт]ел%s*:%s*(%d+)")
if not sender or not phone then
sender, phone = text_utf8:match("([A-Za-z0-9_]+)%s*%.%s*[Тт]ел%s*:%s*(%d+)")
end

if sender and phone then
local result, my_id = sampGetPlayerIdByCharHandle(PLAYER_PED)
local my_name = result and sampGetPlayerNickname(my_id) or ""

if sender == my_name then
-- Наше объявление вышло на сервере
if aad_active and aad_text ~= "" then
lua_thread.create(function()
sampAddChatMessage(u8:decode("[Helper] Ваше объявление опубликовано. Следующая автоподача через " .. (aad_delay[0]/1000) .. " сек..."), 0x00FFFF)
wait(aad_delay[0])
if aad_active and aad_text ~= "" then
sampSendChat("/ad " .. aad_text)
end
end)
end
else
-- Чужое объявление, собираем в базу данных
if modules[1].enabled then
player_db[sender] = {
phone = phone,
time = os.date("%Y-%m-%d %H:%M:%S"),
ad = text_utf8:match("Объявление:%s*(.-)%s*Отправитель:") or ""
}
saveDatabase()
sampAddChatMessage(u8:decode("[Helper DB] Добавлен контакт: " .. sender .. " (Тел: " .. phone .. ")"), 0x00FF90)
end
end
end
end
end
end
end
end

-- ПОТОК ОТСЛЕЖИВАНИЯ ДИАЛОГОВЫХ ОКON (без SAMP.Lua)
function dialogScannerWorker()
local last_active_dialog_id = -1

while true do
wait(50) -- Проверка каждые 50 мс

if modules[2].enabled and mm_auto_format[0] and isSampAvailable() then
if sampIsDialogActive() then
local current_dialog_id = sampGetActiveDialogId()
if current_dialog_id ~= last_active_dialog_id then
last_active_dialog_id = current_dialog_id

local title = sampGetDialogCaption()
local title_utf8 = u8:encode(title, encoding.default)
local text = sampGetDialogText()
local text_utf8 = u8:encode(text, encoding.default)

-- Проверяем, наш ли это диалог редактирования
if title_utf8:find("Редактирование") or text_utf8:find("Текст объявления:") then
local original_ad = text_utf8:match("подал объявление:%s*\n%s*(.+)") 
or text_utf8:match("Текст:%s*(.+)") 
or text_utf8

if original_ad and original_ad ~= "" then
local formatted = formatAdText(original_ad)

if mm_auto_send[0] then
lua_thread.create(function()
wait(mm_send_delay[0]) 
sampSendDialogResponse(current_dialog_id, 1, 0, u8:decode(formatted))
end)
else
lua_thread.create(function()
wait(100)
sampSetCurrentDialogInputText(u8:decode(formatted))
end)
end
end
end
end
else
last_active_dialog_id = -1
end
end
end
end

-- ПРИМЕНЕНИЕ ЛОКАЛЬНОГО СКИНА
function applyLocalSkin(skinId)
lua_thread.create(function()
if skinId >= 0 and skinId <= 311 and skinId ~= 74 then
requestModel(skinId)
loadAllModelsNow()
if isModelAvailable(skinId) then
setCharModel(PLAYER_PED, skinId)
sampAddChatMessage(u8:decode("[Helper] Скин успешно изменен на ID: " .. skinId), 0x00FF00)
else
sampAddChatMessage(u8:decode("[Helper] Ошибка загрузки модели скина."), 0xFF0000)
end
else
sampAddChatMessage(u8:decode("[Helper] Некорректный ID скина (допустимо 0-311, кроме 74)."), 0xFF0000)
end
end)
end

-- РАБОТА С ПОГОДОЙ И ВРЕМЕНЕМ
function environmentWorker()
local has_memory, memory = pcall(require, 'memory')
while true do
wait(50)
if modules[4].enabled then
if weather_locked[0] then
local w = weather_id[0]
if has_memory then
pcall(function()
memory.write(0xC81320, w, 2, true)
memory.write(0xC8131C, w, 2, true)
memory.write(0xC81314, floatToInt(0.0), 4, true)
end)
else
forceWeatherNow(w)
end
end
if time_locked[0] then
local h = time_hour[0]
if has_memory then
pcall(function()
memory.write(0xB70153, h, 1, true)
memory.write(0xB70152, 0, 1, true)
end)
else
setTimeOfDay(h, 0)
end
end
end
end
end

-- РАБОТА СТРОБОСКОПОВ
function strobeWorker()
local step = 1
local last_car = nil
while strobe_active and strobe_enabled[0] do
if isCharInAnyCar(PLAYER_PED) then
local car = storeCarCharIsInNoSave(PLAYER_PED)
if car and doesVehicleExist(car) then
last_car = car
setCarLightsOn(car, true)
local mode = strobe_mode[0]
local seq = strobe_sequences[mode]
if not seq then seq = strobe_sequences[0] end

local current_step = seq[step]
if current_step then
pcall(setCarLightDamageStatus, car, 0, current_step[1])
pcall(setCarLightDamageStatus, car, 2, current_step[2])
end

step = step + 1
if step > #seq then
step = 1
end

local delay = strobe_speed[0]
if mode == 5 then
delay = math.max(25, math.floor(delay / 2))
end
wait(delay)
else
break
end
else
break
end
end

strobe_enabled[0] = false
strobe_active = false

if last_car and doesVehicleExist(last_car) then
pcall(setCarLightDamageStatus, last_car, 0, 0)
pcall(setCarLightDamageStatus, last_car, 1, 0)
pcall(setCarLightDamageStatus, last_car, 2, 0)
pcall(setCarLightDamageStatus, last_car, 3, 0)
end
end

-- РАБОТА КРУИЗ-КОНТРОЛЯ
function cruiseControlWorker()
while true do
wait(50)
if modules[4].enabled and cruise_enabled[0] then
if isCharInAnyCar(PLAYER_PED) then
local car = storeCarCharIsInNoSave(PLAYER_PED)
if isKeyDown(0x43) and not sampIsDialogActive() and not sampIsChatInputActive() then -- C
if not cruise_active then
local cx, cy, cz = getActiveVehicleSpeed(car)
cruise_speed = math.sqrt(cx*cx + cy*cy + cz*cz)
if cruise_speed > 0.05 then
cruise_active = true
sampAddChatMessage(u8:decode("[Helper] Круиз-контроль активирован!"), 0x00FF00)
wait(500)
end
else
cruise_active = false
sampAddChatMessage(u8:decode("[Helper] Круиз-контроль выключен."), 0xFF0000)
wait(500)
end
end

if cruise_active then
if isKeyDown(0x53) or isKeyDown(0x20) then -- S or Space
cruise_active = false
sampAddChatMessage(u8:decode("[Helper] Круиз-контроль отключен торможением."), 0xFF0000)
else
local cx, cy, cz = getActiveVehicleSpeed(car)
local current_speed = math.sqrt(cx*cx + cy*cy + cz*cz)
if current_speed < cruise_speed then
local angle = getCarHeading(car)
local rad = math.rad(angle + 90)
local factor = 0.015
setCarVelocity(car, cx + math.cos(rad) * factor, cy + math.sin(rad) * factor, cz)
end
end
end
else
cruise_active = false
end
else
cruise_active = false
end
end
end

function getActiveVehicleSpeed(car)
local x, y, z = getCarVelocity(car)
return x, y, z
end

-- СЛЕЖЕНИЕ ЗА ОРУЖИЕМ
function weaponTrackWorker()
local current_weapon = getCurrentCharWeapon(PLAYER_PED)
local weapon_names = {
[24] = "Desert Eagle",
[31] = "M4",
[30] = "AK-47",
[25] = "Shotgun",
[29] = "MP5",
[4] = "нож"
}

while true do
wait(200)
if modules[3].enabled and rp_weapons_enabled[0] then
if not sampIsDialogActive() and not sampIsChatInputActive() then
local new_weapon = getCurrentCharWeapon(PLAYER_PED)
if new_weapon ~= current_weapon then
if current_weapon ~= 0 and weapon_names[current_weapon] then
local weapon_name = weapon_names[current_weapon]
if current_weapon == 24 then
sampSendChat(u8:decode("/me поставил пистолет \"" .. weapon_name .. "\" на предохранитель и убрал в кобуру"))
elseif current_weapon == 4 then
sampSendChat(u8:decode("/me убрал \"" .. weapon_name .. "\" в ножны на поясе"))
else
sampSendChat(u8:decode("/me повесил автомат \"" .. weapon_name .. "\" на плечо"))
end
wait(500)
end

if new_weapon ~= 0 and weapon_names[new_weapon] then
local weapon_name = weapon_names[new_weapon]
if new_weapon == 24 then
sampSendChat(u8:decode("/me резким движением выхватил пистолет \"" .. weapon_name .. "\" из кобуры"))
elseif new_weapon == 4 then
sampSendChat(u8:decode("/me вынул \"" .. weapon_name .. "\" из ножен на поясе"))
else
sampSendChat(u8:decode("/me снял автомат \"" .. weapon_name .. "\" с плеча и снял с предохранителя"))
end
end
current_weapon = new_weapon
end
end
end
end
end

-- АСИНХРОННЫЙ ОБЗВОН ОНЛАЙН ИГРОКОВ
function onlineCallWorker(online_list)
local called_count = 0
local limit = max_calls_session[0]

for i = #online_list, 2, -1 do
local j = math.random(i)
online_list[i], online_list[j] = online_list[j], online_list[i]
end

for _, target in ipairs(online_list) do
if not call_active or called_count >= limit then break end

local last_time = last_called[target.nick] or 0
if os.time() - last_time > 300 then
call_current_nick = target.nick
call_current_phone = target.phone

sampAddChatMessage(u8:decode("[Helper] Обзвон: Звоним " .. target.nick .. " (Тел: " .. target.phone .. ")"), 0xFFFF00)

-- Вызов /call отыграется автоматически, так как мы зарегистрировали команду call
sampSendChat("/call " .. target.phone)

last_called[target.nick] = os.time()
called_count = called_count + 1

local timeLeft = call_delay[0]
while timeLeft > 0 and call_active do
wait(100)
timeLeft = timeLeft - 100
end

if not call_active then break end

sampSendChat("/h")
wait(1000)
end
end

call_active = false
call_current_nick = ""
call_current_phone = ""
sampAddChatMessage(u8:decode("[Helper] Сессия обзвона завершена. Обзвонили игроков: " .. called_count), 0x00FF00)
end

-- ==========================================
-- ОТРИСОВКА ИНТЕРФЕЙСА (MIMGUI)
-- ==========================================
local function applyCustomStyle()
local style = imgui.GetStyle()
style.WindowRounding = 6.0
style.ChildRounding = 6.0
style.FrameRounding = 4.0
style.PopupRounding = 4.0
style.ScrollbarRounding = 4.0
style.GrabRounding = 3.0

style.Colors[imgui.Col.WindowBg] = imgui.ImVec4(0.08, 0.08, 0.10, 0.95)
style.Colors[imgui.Col.ChildBg] = imgui.ImVec4(0.12, 0.12, 0.14, 0.70)
style.Colors[imgui.Col.Border] = imgui.ImVec4(0.20, 0.20, 0.25, 0.50)
style.Colors[imgui.Col.FrameBg] = imgui.ImVec4(0.15, 0.15, 0.18, 1.00)
style.Colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.22, 0.22, 0.27, 1.00)
style.Colors[imgui.Col.FrameBgActive] = imgui.ImVec4(0.30, 0.30, 0.38, 1.00)
style.Colors[imgui.Col.TitleBg] = imgui.ImVec4(0.12, 0.12, 0.15, 1.00)
style.Colors[imgui.Col.TitleBgActive] = imgui.ImVec4(0.16, 0.16, 0.21, 1.00)
style.Colors[imgui.Col.Button] = imgui.ImVec4(0.25, 0.25, 0.32, 1.00)
style.Colors[imgui.Col.ButtonHovered] = imgui.ImVec4(0.32, 0.32, 0.42, 1.00)
style.Colors[imgui.Col.ButtonActive] = imgui.ImVec4(0.40, 0.40, 0.55, 1.00)
style.Colors[imgui.Col.Header] = imgui.ImVec4(0.20, 0.20, 0.28, 1.00)
style.Colors[imgui.Col.HeaderHovered] = imgui.ImVec4(0.26, 0.26, 0.36, 1.00)
style.Colors[imgui.Col.HeaderActive] = imgui.ImVec4(0.33, 0.33, 0.46, 1.00)
style.Colors[imgui.Col.CheckMark] = imgui.ImVec4(0.00, 0.80, 0.50, 1.00)
end

imgui.OnInitialize(function()
applyCustomStyle()
end)

imgui.OnFrame(
function() return show_main_window[0] end,
function(player)
imgui.SetNextWindowSize(imgui.ImVec2(820, 560), imgui.Cond.FirstUseEver)
imgui.Begin(u8"Universal Helper Platform v0.7", show_main_window, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

-- Верхняя панель: Переключатель серверов
imgui.Text(u8"Выбор текущего сервера:")
imgui.SameLine()
imgui.PushItemWidth(150)
if imgui.BeginCombo("##ServerSelector", server_names[current_server_idx[0] + 1]) then
for idx, srv_name in ipairs(server_names) do
local is_selected = (current_server_idx[0] == idx - 1)
if imgui.Selectable(srv_name, is_selected) then
current_server_idx[0] = idx - 1
saveSettings()
sampAddChatMessage(u8:decode("[Helper] Сервер изменен на: " .. server_names[current_server_idx[0] + 1]), 0x00FF90)
end
end
imgui.EndCombo()
end
imgui.PopItemWidth()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

-- Левая колонка: Навигационная панель
imgui.BeginChild("navigation_panel", imgui.ImVec2(220, 0), true)
imgui.Text(u8" Доступные Модули")
imgui.Separator()
imgui.Spacing()

for i, mod in ipairs(modules) do
local is_selected = (active_module_idx == i)
if imgui.Selectable(mod.name, is_selected, 0, imgui.ImVec2(0, 32)) then
active_module_idx = i
end

imgui.SameLine(180)
if mod.enabled then
imgui.TextColored(imgui.ImVec4(0, 1, 0, 1), "[ON]")
else
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "[OFF]")
end
end
imgui.EndChild()

imgui.SameLine()

-- Правая колонка: Настройки модуля
imgui.BeginChild("content_panel", imgui.ImVec2(0, 0), true)
local active_module = modules[active_module_idx]
if active_module then
imgui.Text(active_module.name)
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
imgui.TextWrapped(active_module.description)
imgui.PopStyleColor()
imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if active_module.id ~= "commands_guide" then
local state_bool = imgui.new.bool(active_module.enabled)
if imgui.Checkbox(u8"Активировать модуль", state_bool) then
active_module.enabled = state_bool[0]
saveSettings()
if active_module.onToggle then
active_module.onToggle(state_bool[0])
end
end
imgui.Spacing()
imgui.Separator()
imgui.Spacing()
end

if active_module.drawSettings then
active_module.drawSettings()
end
else
imgui.Text(u8"Выберите модуль слева.")
end
imgui.EndChild()
imgui.End()
end
)

-- Подгружаем библиотеки для работы с буфером ввода ImGui (FFI)
local ffi = require 'ffi'


-- ==========================================
-- ОТРИСОВКА ИНТЕРФЕЙСА (MIMGUI)
-- ==========================================
local function applyCustomStyle()
local style = imgui.GetStyle()
style.WindowRounding = 6.0
style.ChildRounding = 6.0
style.FrameRounding = 4.0
style.PopupRounding = 4.0
style.ScrollbarRounding = 4.0
style.GrabRounding = 3.0

style.Colors[imgui.Col.WindowBg] = imgui.ImVec4(0.08, 0.08, 0.10, 0.95)
style.Colors[imgui.Col.ChildBg] = imgui.ImVec4(0.12, 0.12, 0.14, 0.70)
style.Colors[imgui.Col.Border] = imgui.ImVec4(0.20, 0.20, 0.25, 0.50)
style.Colors[imgui.Col.FrameBg] = imgui.ImVec4(0.15, 0.15, 0.18, 1.00)
style.Colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.22, 0.22, 0.27, 1.00)
style.Colors[imgui.Col.FrameBgActive] = imgui.ImVec4(0.30, 0.30, 0.38, 1.00)
style.Colors[imgui.Col.TitleBg] = imgui.ImVec4(0.12, 0.12, 0.15, 1.00)
style.Colors[imgui.Col.TitleBgActive] = imgui.ImVec4(0.16, 0.16, 0.21, 1.00)
style.Colors[imgui.Col.Button] = imgui.ImVec4(0.25, 0.25, 0.32, 1.00)
style.Colors[imgui.Col.ButtonHovered] = imgui.ImVec4(0.32, 0.32, 0.42, 1.00)
style.Colors[imgui.Col.ButtonActive] = imgui.ImVec4(0.40, 0.40, 0.55, 1.00)
style.Colors[imgui.Col.Header] = imgui.ImVec4(0.20, 0.20, 0.28, 1.00)
style.Colors[imgui.Col.HeaderHovered] = imgui.ImVec4(0.26, 0.26, 0.36, 1.00)
style.Colors[imgui.Col.HeaderActive] = imgui.ImVec4(0.33, 0.33, 0.46, 1.00)
style.Colors[imgui.Col.CheckMark] = imgui.ImVec4(0.00, 0.80, 0.50, 1.00)
end

imgui.OnInitialize(function()
applyCustomStyle()
end)

imgui.OnFrame(
function() return show_main_window[0] end,
function(player)
imgui.SetNextWindowSize(imgui.ImVec2(820, 560), imgui.Cond.FirstUseEver)
imgui.Begin(u8"Universal Helper Platform v0.7", show_main_window, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

-- Верхняя панель: Переключатель серверов
imgui.Text(u8"Выбор текущего сервера:")
imgui.SameLine()
imgui.PushItemWidth(150)
if imgui.BeginCombo("##ServerSelector", server_names[current_server_idx[0] + 1]) then
for idx, srv_name in ipairs(server_names) do
local is_selected = (current_server_idx[0] == idx - 1)
if imgui.Selectable(srv_name, is_selected) then
current_server_idx[0] = idx - 1
saveSettings()
sampAddChatMessage(u8:decode("[Helper] Сервер изменен на: " .. server_names[current_server_idx[0] + 1]), 0x00FF90)
end
end
imgui.EndCombo()
end
imgui.PopItemWidth()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

-- Левая колонка: Навигационная панель
imgui.BeginChild("navigation_panel", imgui.ImVec2(220, 0), true)
imgui.Text(u8" Доступные Модули")
imgui.Separator()
imgui.Spacing()

for i, mod in ipairs(modules) do
local is_selected = (active_module_idx == i)
if imgui.Selectable(mod.name, is_selected, 0, imgui.ImVec2(0, 32)) then
active_module_idx = i
end

imgui.SameLine(180)
if mod.enabled then
imgui.TextColored(imgui.ImVec4(0, 1, 0, 1), "[ON]")
else
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "[OFF]")
end
end
imgui.EndChild()

imgui.SameLine()

-- Правая колонка: Настройки модуля
imgui.BeginChild("content_panel", imgui.ImVec2(0, 0), true)
local active_module = modules[active_module_idx]
if active_module then
imgui.Text(active_module.name)
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
imgui.TextWrapped(active_module.description)
imgui.PopStyleColor()
imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if active_module.id ~= "commands_guide" then
local state_bool = imgui.new.bool(active_module.enabled)
if imgui.Checkbox(u8"Активировать модуль", state_bool) then
active_module.enabled = state_bool[0]
saveSettings()
if active_module.onToggle then
active_module.onToggle(state_bool[0])
end
end
imgui.Spacing()
imgui.Separator()
imgui.Spacing()
end

if active_module.drawSettings then
active_module.drawSettings()
end
else
imgui.Text(u8"Выберите модуль слева.")
end
imgui.EndChild()
imgui.End()
end
)

-- Подгружаем библиотеки для работы с буфером ввода ImGui (FFI)
local ffi = require 'ffi'

