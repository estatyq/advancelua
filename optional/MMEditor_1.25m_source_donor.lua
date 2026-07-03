script_name("MM Editor v1.25m")
script_authors("Skelmer")
script_version("Final")
script_version_number(25)
script_description("ARP-C for Mass Media")
script_moonloader(026)
script_url("https://vk.com/mmeditor")

-- Спасибо всем, кто участвовал и поддерживал!

-------------------------------- REQUIRE
local res1, sampev = pcall(require, 'lib.samp.events') 
local res2, imgui = pcall(require, 'imgui')
local res3, http = pcall(require, 'socket.http')
local res4, md5 = pcall(require, 'md5')

dlstatus = require('moonloader').download_status
local inicfg = require 'inicfg'
local key = require 'vkeys'
local encoding = require 'encoding'
encoding.default = 'CP1251'
u8 = encoding.UTF8

function split(str, delim, plain)
    local tokens, pos, plain = {}, 1, not (plain == false) --[[ delimiter is plain text by default ]]
    repeat
        local npos, epos = string.find(str, delim, pos, plain)
        table.insert(tokens, string.sub(str, pos, npos and npos - 1))
        pos = epos and epos + 1
    until not pos
    return tokens
end
function downloadMaster(url, dir, readon, delete)

	print(dir)
	local OK = false
	local dtime = os.time() + 10
	
	downloadUrlToFile(url, dir, function(id, status, p1, p2)
		if status == dlstatus.STATUS_DOWNLOADINGDATA then
			print(string.format('Загружено %d из %d.', p1, p2))
			dtime = os.time() + 10
		elseif status == dlstatus.STATUS_ENDDOWNLOADDATA then
			print('Загрузка завершена.')
			OK = true
		end
	end)
	
	while true do
		if OK then break end
		if os.time() > dtime then
			return false, 'Время ожидания скачивания файла истекло.'
		end
		wait(1000)
	end
	
	local dtime = os.time() + 5
	local file = io.open(dir)

	while file == nil do
		if os.time() > dtime then
			return false, 'Файл был загружен, но так и не открылся.'
		end
		wait(100)
	end
	
	if readon then 
		local info = file:read('*a')
		file:close()
		if delete then os.remove(dir) end
		return true, info
	end
	
	if delete and not readon then 
		file:close()
		os.remove(dir)
	end
	
	if not delete and not readon then file:close() end
	
	return true
end
function urlencode(url)
	if url == nil then
		return
	end
	url = url:gsub("\n", "\r\n")
	url = string.gsub(url, "([^%w _%%%-%.~])", function(c) return string.format("%%%02X", string.byte(c)) end)
	url = url:gsub(" ", "+")
	return url
end

-------------------------------- GLOBAL VARS
local ScriptUse = 3 -- 0 запрещено, 1 разрешено, 3 на проверке, 2 чек аккаунта
local selectedm = 1
local lastselected = 1
local selectedlec = 1
local selectedRP = 1
local selected = 1
local regDialogOpen = false
local dialogHistoryOpen = false
local dialogLift = false
local dialogTime = false
local dialogFind = false
local dialogAudience = false
local editflood = false -- вкл/выкл ловля
local btn_size = imgui.ImVec2(-0.1, 0) -- размер кнопок в target
local styleWindowOpen = false
local blacklistactive = false
local RPactive = false
local RPpalata = false
local RPefir = false
local blockButton = {pravila = false, color = false, blacklist = false}

local buttonLocked = false -- Блокировка кнопки смены цвета ника

local editappear = false
local editFrom = ''
local editOriginal = ''
local editcursorpos = nil

local comboPravila = imgui.ImInt(0)
local comboLecRadio = imgui.ImInt(0)
local comboQuestion = imgui.ImInt(0)
local comboQuestionType = imgui.ImInt(0)
local comboEfir = imgui.ImInt(0)

-- GNEWS
local newsDialogOpen = false
local regedit = false

-- LEC
local reglec = false

-- Клавиши
local keymapTable = {'Главное меню скрипта', 'Ловля объявлений', 'Подача гос. новостей', 'Отправка лекций', 'Открыть шпаргалки', 'Взаимодействие с игроком (ПКМ + ...)'}
local choiceNum = 0

-- Заголовки и содержание правил
local charterNameTable = {}
local charterTable = {}
local proNameTable = {}
local proTable = {}
local ppeNameTable = {}
local ppeTable = {}

local edit_buffer = imgui.ImBuffer('', 128)

-- ЭФИРЫ
local callTable = {}
local smsTable = {}
local scoreTable = inicfg.load({}, './MME/scores.ini')
local numberToID = {}
for i, thing in ipairs(scoreTable) do
	numberToID[tostring(thing['number'])] = i
	--sampAddChatMessage(numberToID[thing['number']], -1)
end
local callerID = -1
local efirTime = nil
local callTime = nil

--rangTable = {'Помощник редакции[1]','Верстальщик новостей[2]','Радиотехник[3]','Журналист[4]','Ст.Журналист[5]','Корректор[6]','Помощник редактора[7]','Редактор[8]','Гл.Редактор[9]','Директор[10]', 'Начинающий работник[1]','Помощник телемастера[2]','Телемастер[3]','Светотехник[4]','Оператор[5]','Звукорежиссер[6]','Режиссер[7]','Ведущий[8]','Управляющий студией[9]','Директор[10]'}

-------------------------------- LOADING INI
local lectureIni = ({
	{
		name = 'УСМИ, ПРО, ППЭ',
		lec1 = 'Уважаемые сотрудники, минуточку внимания!',
		lec2 = 'Соблюдайте устав СМИ, ПРО и ПЭВ.',
		lec3 = 'Спасибо за внимание!',
		time = 1000
	}
})

local inilec = inicfg.load(lectureIni, './MME/lec_set.ini')
local lec1_buffer = imgui.ImBuffer(u8(inilec[1]['lec1']), 150)
local lec2_buffer = imgui.ImBuffer(u8(inilec[1]['lec2']), 150)
local lec3_buffer = imgui.ImBuffer(u8(inilec[1]['lec3']), 150)
local lec_name = imgui.ImBuffer(u8(inilec[1]['name']), 32)
local lec_time = imgui.ImInt(inilec[1]['time'])

local RPIni = ({
	{
		name = 'Трудовой договор',
		RP = '/me достал из кейса трудовой договор\n700\n/me передал договор человку напротив\n700\n/anim 21\n2500\n/do В договоре написаны следующие пункты:\n700\n/do 1. Рекомендуем ознакомиться с требованиями к повышению.\n700\n/do 2. Рекомендуем ознакомиться с Уставом СМИ, ПРО и ППЭ.\n1000\nВсю информацию Вы можете найти на форуме ТВ-Радио.\n1000\nЕсли Вы принимаете условия нашего договора, то поставьте свою подпись.\n1000\n/me передал ручку человеку напротив',
		tags = 'Теги: {name} - имя человека'
	},
	{
		name = 'Инструктаж',
		RP = 'Поздравляю. Вы прошли собеседование.\n1000\nСейчас я выдам Вам вашу форму и рацию.\n1000\n/n Для повышения на 3 ранг Вам необходимо сдать УСМИ, ПРО и ППЭ.\n700\n/n Вся необходимая информация находится на форуме...\n700\n/n ... Chocolate Server -> Организации -> ТВ и Радио.\n700\n/n Начиная с 3 ранга повышение идет по отчётам на форуме.',
		tags = 'Теги: {name} - имя человека'
	},
	{
		name = 'Часы /c 60',
		RP = '/me посмотрел на часы\n100\n/do Время: {time}. Дата: {data}',
		tags = 'Теги: {time} - время, {data} - дата'
	},
	{
		name = 'Сотрудники /find',
		RP = '/me достал планшет\n100\n/me перешел во вкладку «Список сотрудников»\n100\n/do Количество сотрудников в штате: {work}.',
		tags = 'Теги: {work} - кол-во сотрудников'
	},
	{
		name = 'Продажа газеты /sale',
		RP = '/me взял газету с прилавка\n100\n/me передал газету {name}\n100\n/anim 21\n1500',
		tags = '{name} - имя, кому продаете'
	},
	{
		name = 'Поставить палатку',
		RP = '/me снял рюкзак со спины\n1000\n/me открыл рюкзак и достал необходимые детали\n1000\n/me установил киоск для продажи газет\n/stand\n2500\n/me достал из рюкзака упаковку свежих газет\n1000\n/me разложил газеты по прилавку',
		tags = ''
	},
	{
		name = 'Разобрать палатку',
		RP = '/do На спине висит рюкзак\n1000\n/me снял рюкзак со спины\n1000\n/me собрал с прилавка газеты\n1000\n/me убрал газеты в рюкзак\n1000\n/me разобрал киоск для продажи газет\n/stand\n1500\n/me убрал в рюкзак детали от киоска\n1000\n/me застегнул рюкзак и надел его на спину',
		tags = ''
	},
	{
		name = 'Увольнение /uninv',
		RP = '/me достал планшет\n500\n/me зашел в базу данных сотрудников СМИ\n500\n/me выбрав имя и фамилию, уволил сотрудника {work}.',
		tags = 'Теги: {work} - имя сотрудника'
	},
	{
		name = 'Выдача одежды',
		RP = '/do Стоит вешалка с костюмами.\n500\n/me нашел нужный костюм\n500\n/do Костюм в руках.\n500\n/me передал костюм {name}\n500',
		tags = 'Теги: {name} - имя человека'
	},
	{
		name = 'Выход в эфир',
		RP = '/me взял наушники\n700\n/me надел наушники\n700\n/me включил аппаратуру\n700\n/do Аппаратура включена\n700\n/me вышел в прямой эфир\n700\n/efir',
		tags = '/efir нужно указывать в этой отыгровке'
	},
	{
		name = 'Выход из эфира',
		RP = '/efir\n700\n/me вышел из эфира\n700\n/me снял наушники\n700\n/me отключил аппаратуру',
		tags = '/efir нужно указывать в этой отыгровке'
	},
	{
		name = 'Начало эфира',
		RP = '..:: Музыкальная заставка на радио города Los Santos::..',
		tags = 'В строки без команд скрипт автоматически подставляет /t'
	},
	{
		name = 'Конец эфира',
		RP = '..:: Музыкальная заставка на радио города Los Santos::..',
		tags = 'В строки без команд скрипт автоматически подставляет /t'
	},
	{
		name = '/audience',
		RP = '/me достал планшет\n500\n/me перешел во вкладку «Количество слушателей»\n500\n/do Количество слушателей: {num}',
		tags = 'Теги: {num} - количество слушателей/телезрителей'
	}
})

local iniRP = inicfg.load(RPIni, './MME/RP_set.ini')
local editRP_buffer = imgui.ImBuffer(string.gsub(u8(iniRP[1]['RP']), '\\n', '\n'), 4096)

local gnewsIni = ({
	{
		name = '',
		Gos1 = "СМИ | Вы всегда мечтали о престижной и уважаемой профессии?",
		Gos2 = "СМИ | Тогда не упустите шанс пройти собеседование в радиоцентр LS!",
		Gos3 = "СМИ | Требования: 4 года в штате, законопослушность. GPS: 3-14",
		Gosn = "СМИ | Собеседование в радиоцентр г. Los Santos продолжается! GPS: 3-14",
		Gose = "СМИ | Собеседование в радиоцентр LS окончено! Оставляйте эл. заявления",
		Gosd = 'СМИ | Собеседование в радиоцентр г. Los Santos началось! Ждём опоздавших.',
		time = 1000
	}
})

local inig = inicfg.load(gnewsIni, './MME/gnews_set.ini')
local gnews1_buffer = imgui.ImBuffer(u8(inig[1]['Gos1']), 150)
local gnews2_buffer = imgui.ImBuffer(u8(inig[1]['Gos2']), 150)
local gnews3_buffer = imgui.ImBuffer(u8(inig[1]['Gos3']), 150)
local gnews_reminder_buffer = imgui.ImBuffer(u8(inig[1]['Gosn']), 150)
local gnews_end_buffer = imgui.ImBuffer(u8(inig[1]['Gose']), 150)
local gnews_dop = imgui.ImBuffer(u8(inig[1]['Gosd']), 150)
local gnews_name = imgui.ImBuffer(u8(inig[1]['name']), 32)
local gnews_time = imgui.ImInt(inig[1]['time'])

local mainIni = ({
  Tags =
  {
  	f = 'default',
  	r = ''
  },
  Look =
  {
  	scale = 1
  },
  Key1 = {78},
  Key2 = {114},
  Key3 = {18, 50},
  Key4 = {18, 51},
  Key5 = {18, 52},
  Key6 = {83},
  Prefs =
  {
  	pref1 = true,
  	pref2 = true,
  	pref3 = true,
  	pref4 = true,
  	pref5 = true,
  	pref6 = true,
  	pref7 = true,
  	pref8 = true,
	pref9 = true,
  	pref10 = false,
	pref11 = true,
	pref12 = false,
	pref13 = false,
	pref14 = true
  },
  Ystav =
  {
   Yst1 = "С какой должности можно брать транспорт без разрешения?",
   Yst2 = "С какой должности человек считается в старшем составе?",
   Yst3 = "Рабочее время в СМИ",
   Yst4 = "С какой должности можно пользоваться общей волной",
   Yst5 = "Пункт устава 3.2",
   Yst6 = "В какое время обед?",
   Yst7 = "С какой должности можно брать транспорт СМИ?",
   Yst8 = "Пункт устава 4.1",
   Yst9 = "Какое максимальное время отпуска?"
  },
  PRO =
  {
   Pro1 = "Работает такси турбо",
   Pro2 = "Куплю султан",
   Pro3 = "Продам дом",
   Pro4 = "Куплю чай",
   Pro5 = "Куплю дом за 30к",
   Pro6 = "Куплю авто",
   Pro7 = "Продам парикмахерскую",
   Pro8 = "Продам симку",
   Pro9 = "Куплю булку"
  },
  PPE =
  {
   Ppe1 = "С какой должности разрешено выходить в эфир?",
   Ppe2 = "Места проведения эфиров?",
   Ppe3 = "Назовите три различных разновидности эфира",
   Ppe4 = "Минимальная продолжительность эфира?",
   Ppe5 = "Минимальный интервал между двумя эфирами разных ведущих?",
   Ppe6 = "Минимальный интервал между двумя эфирами одного и того же ведущего?",
   Ppe7 = "Максимальная продолжительность эфира?",
   Ppe8 = "Минимальный приз на развлекательном эфире?",
   Ppe9 = "Минимальный приз на эфире-мероприятии?"
  },
  Efir = 
  {
  	pref1 = false,
  	pref2 = true,
  	pref3 = true,
	pref4 = true
  },
  LIBmsg = 
  {
	lib1 = true
  }
})

local ini = inicfg.load(mainIni, './MME/setting.ini')
local questionTypes = {'Yst', 'Pro', 'Ppe'}
local questionTypesFull = {'Ystav', 'PRO', 'PPE'}
local quest_buffer = imgui.ImBuffer(u8(ini[questionTypesFull[comboQuestionType.v + 1]][questionTypes[comboQuestionType.v + 1] .. comboQuestion.v + 1]), 128)
local global_scale = imgui.ImFloat(ini.Look.scale)
local global_scale_slider = imgui.ImFloat(ini.Look.scale)
local r_buffer = imgui.ImBuffer(u8(ini.Tags.r), 128)
local f_buffer = imgui.ImBuffer(u8(ini.Tags.f), 128)
local prefTable = {'РП отыгровка часов (/c 60)', 'Время до ЗП + чистый онлайн (/c 60)', 'Уведомление в /r об увольнении (/uninv)', 'Отыгровка /find', 'Отыгровка /audience', 'Уведомление о зарплате (/do)', 'Отыгровка эфира (/efir)', 'Отыгровка палатки (/stand)','Отыгровка продажи газет (/sale)','Проверка терминов в СМС', 'Резерв','Писать во время эфира без /t', 'Заставки эфиров', 'Цветные ники в чате'}
local prefTable_info = {'Отыгровка настраивается', 'При просмотре часов, скрипт напишет Ваш чистый онлайн и время до ЗП', 'Для управляющего в /f чат', 'Отыгровка настраивается', 'Отыгровка настраивается', 'Отключает уведомление на телефоне при напоминании', 'Отыгровка настраивается.\nТВ также может использовать эту команду для отыгровки', 'Отыгровка настраивается','Отыгровка настраивается\nРаботает через ПКМ + ...','Включено: /n PG | TK /sms 4000 (( ))', 'Раньше здесь можно было выключить окно редактирования\nТеперь же вместо этого в будущем будет другая настройка ^-^', 'Не нужно писать /t, можно просто писать в чат\nРаботает только во время эфира\nКоманды не отправляются в эфир\nНе включайте, если Вы об этом забудете', 'После начала эфира и перед концом эфира, скрипт отправит заставку\nНастроить их можно в отыгровках (Начало эфира/Конец эфира)', 'Только для людей, которые поддержали скрипт','При добавлении балла напишет /t Стоп! и отправит', '*При принятии вызова', '*При принятии ответа', 'В таблице баллов баллы будут идти от большего к меньшему'}
local prefBools = {}
for i = 1, #prefTable do
	prefBools['pref' .. i] = imgui.ImBool(ini.Prefs['pref' .. i])
end
local efirsetTable = {'Писать \"Стоп\" при принятии ответа', 'Очищать список звонков', 'Очищать список SMS', 'Сортировать баллы по убыванию'}
local efirBools = {}
for i = 1, #efirsetTable do
	efirBools['pref' .. i] = imgui.ImBool(ini.Efir['pref' .. i])
end
-------------------------------- IMGUI
local resx, resy = getScreenResolution()
local font_path = getFolderPath(0x14) .. '\\trebucbd.ttf'
assert(doesFileExist(font_path), 'WTF: Font "' .. font_path .. '" doesn\'t exist')
local glyph_ranges_cyrillic = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()	
local largerFont = imgui.GetIO().Fonts:AddFontFromFileTTF(font_path, 20.0*global_scale.v, nil, glyph_ranges_cyrillic)
local medFont = imgui.GetIO().Fonts:AddFontFromFileTTF(font_path, 16.0*global_scale.v, nil, glyph_ranges_cyrillic)

function apply_custom_style()
	imgui.SwitchContext()
	local style = imgui.GetStyle()
	local colors = style.Colors
	local clr = imgui.Col
	local ImVec4 = imgui.ImVec4

	style.WindowRounding = 4.0
	style.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)
	style.ChildWindowRounding = 2.0
	style.FrameRounding = 2.0
	style.ItemSpacing = imgui.ImVec2(8.0*global_scale.v, 4.0*global_scale.v)
	--style.ItemInnerSpacing = imgui.ImVec2(163.0*global_scale.v, 8.0*global_scale.v)
	style.ScrollbarSize = 15.0*global_scale.v
	style.ScrollbarRounding = 0
	style.GrabMinSize = 8.0*global_scale.v
	style.GrabRounding = 1.0
	-- style.Alpha =
	style.WindowPadding = imgui.ImVec2(8.0*global_scale.v, 8.0*global_scale.v)
	-- style.WindowMinSize =
	style.FramePadding = imgui.ImVec2(4.0*global_scale.v, 3.0*global_scale.v)
	-- style.ItemInnerSpacing =
	-- style.TouchExtraPadding =
	-- style.IndentSpacing =
	-- style.ColumnsMinSpacing = ?
	-- style.ButtonTextAlign =
	style.DisplayWindowPadding = imgui.ImVec2(22.0*global_scale.v, 22.0*global_scale.v)
	style.DisplaySafeAreaPadding = imgui.ImVec2(4.0*global_scale.v, 4.0*global_scale.v)
	-- style.AntiAliasedLines =
	-- style.AntiAliasedShapes =
	-- style.CurveTessellationTol =

	colors[clr.Text]                   = ImVec4(1.00, 1.00, 1.00, 1.00)
	colors[clr.TextDisabled]           = ImVec4(0.50, 0.50, 0.50, 1.00)
	colors[clr.WindowBg]               = ImVec4(0.00, 0.00, 0.03, 0.85)
	colors[clr.ChildWindowBg]          = ImVec4(1.00, 1.00, 1.00, 0.00)
	colors[clr.PopupBg]                = ImVec4(0.00, 0.00, 0.03, 0.85)
	colors[clr.ComboBg]                = colors[clr.PopupBg]
	colors[clr.Border]                 = ImVec4(0.43, 0.43, 0.50, 0.50)
	colors[clr.BorderShadow]           = ImVec4(0.00, 0.00, 0.00, 0.00)
	colors[clr.FrameBg]                = ImVec4(0.16, 0.29, 0.48, 0.5)
	colors[clr.FrameBgHovered]         = ImVec4(0.26, 0.59, 0.98, 0.40)
	colors[clr.FrameBgActive]          = ImVec4(0.26, 0.59, 0.98, 0.67)
	colors[clr.TitleBg]                = ImVec4(0.1, 0.25, 0.45, 1.00)
	colors[clr.TitleBgActive]          = ImVec4(0.2, 0.5, 0.9, 1.00)
	colors[clr.TitleBgCollapsed]       = ImVec4(0.00, 0.00, 0.00, 0.51)
	colors[clr.MenuBarBg]              = ImVec4(0.1, 0.15, 0.3, 1.00)
	colors[clr.ScrollbarBg]            = ImVec4(0.02, 0.02, 0.06, 0.8)
	colors[clr.ScrollbarGrab]          = ImVec4(0.31, 0.37, 0.51, 1.00)
	colors[clr.ScrollbarGrabHovered]   = ImVec4(0.41, 0.47, 0.61, 1.00)
	colors[clr.ScrollbarGrabActive]    = ImVec4(0.51, 0.57, 0.71, 1.00)
	colors[clr.CheckMark]              = ImVec4(0.26, 0.59, 0.98, 1.00)
	colors[clr.SliderGrab]             = ImVec4(0.24, 0.52, 0.88, 1.00)
	colors[clr.SliderGrabActive]       = ImVec4(0.26, 0.59, 0.98, 1.00)
	colors[clr.Button]                 = ImVec4(0.26, 0.59, 0.98, 0.40)
	colors[clr.ButtonHovered]          = ImVec4(0.26, 0.59, 0.98, 1.00)
	colors[clr.ButtonActive]           = ImVec4(0.06, 0.53, 0.98, 1.00)
	colors[clr.Header]                 = ImVec4(0.26, 0.59, 0.98, 0.31)
	colors[clr.HeaderHovered]          = ImVec4(0.26, 0.59, 0.98, 0.80)
	colors[clr.HeaderActive]           = ImVec4(0.26, 0.59, 0.98, 1.00)
	colors[clr.Separator]              = colors[clr.Border]
	colors[clr.SeparatorHovered]       = ImVec4(0.26, 0.59, 0.98, 0.78)
	colors[clr.SeparatorActive]        = ImVec4(0.26, 0.59, 0.98, 1.00)
	colors[clr.ResizeGrip]             = ImVec4(0.26, 0.59, 0.98, 0.25)
	colors[clr.ResizeGripHovered]      = ImVec4(0.26, 0.59, 0.98, 0.67)
	colors[clr.ResizeGripActive]       = ImVec4(0.26, 0.59, 0.98, 0.95)
	colors[clr.CloseButton]            = ImVec4(0.9, 0.5, 0.0, 0.8)
	colors[clr.CloseButtonHovered]     = ImVec4(0.98, 0.39, 0.36, 1.00)
	colors[clr.CloseButtonActive]      = ImVec4(0.98, 0.39, 0.36, 1.00)
	colors[clr.PlotLines]              = ImVec4(0.61, 0.61, 0.61, 1.00)
	colors[clr.PlotLinesHovered]       = ImVec4(1.00, 0.43, 0.35, 1.00)
	colors[clr.PlotHistogram]          = ImVec4(0.90, 0.70, 0.00, 1.00)
	colors[clr.PlotHistogramHovered]   = ImVec4(1.00, 0.60, 0.00, 1.00)
	colors[clr.TextSelectedBg]         = ImVec4(0.26, 0.59, 0.98, 0.35)
	colors[clr.ModalWindowDarkening]   = ImVec4(0.80, 0.80, 0.80, 0.35)
	imgui.GetIO().Fonts:Clear()
	glyph_ranges_cyrillic = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
	imgui.GetIO().Fonts:AddFontFromFileTTF(getFolderPath(0x14) .. '\\trebucbd.ttf', 14.0*global_scale.v, nil, glyph_ranges_cyrillic)
	largerFont = imgui.GetIO().Fonts:AddFontFromFileTTF(font_path, 20.0*global_scale.v, nil, glyph_ranges_cyrillic)
	medFont = imgui.GetIO().Fonts:AddFontFromFileTTF(font_path, 16.0*global_scale.v, nil, glyph_ranges_cyrillic)
	imgui.RebuildFonts()
end
apply_custom_style()
-------------------------------- WINDOWS IMGUI
local window_states = {}

window_states['main'] = imgui.ImBool(false)
window_states['confirmation'] = imgui.ImBool(false) -- подтверждение сохранения 
window_states['m'] = imgui.ImBool(false)
window_states['n'] = imgui.ImBool(false) -- 
window_states['target'] = imgui.ImBool(false) -- меню взаимодейсвия
window_states['target_next'] = imgui.ImBool(false)
window_states['update'] = imgui.ImBool(false)
window_states['pravila'] = imgui.ImBool(false) -- окно обновления
window_states['blacklist'] = imgui.ImBool(false)
window_states['update'] = imgui.ImBool(false)
window_states['editRP'] = imgui.ImBool(false)
window_states['editlec'] = imgui.ImBool(false)
window_states['mmblack'] = imgui.ImBool(false)
window_states['loadscript'] = imgui.ImBool(false)
window_states['efir'] = imgui.ImBool(false)
-------------------------------- AUTOEDIT
local iniMain = ({
	price = {
		'Цена: {price}',
		'Бюджет: {price}',
		'Цена договорная',
		'Бюджет свободный'
	},
	window = {
		id = -1,
		title = '',
		regNick = '',
		regAd = ''
	},
	main = {
		teg = ''
	}
})
local stepSetting = -1

AEname = imgui.ImBuffer('', 35)
AEsmallName = imgui.ImBuffer('', 10)
AEbool = imgui.ImBool(false)
patPatB = imgui.ImBuffer('', 128)
iniName2 = imgui.ImBuffer('', 20)
iniNotFound = imgui.ImBuffer('', 50)
edit_buffer = imgui.ImBuffer('',128)

local main_window = imgui.ImBool(false)
local edit_window = imgui.ImBool(false)
local set_window = imgui.ImBool(false)

function main()
	if not isSampLoaded() or not isSampfuncsLoaded() then return end
	while not isSampAvailable() do wait(100) end
	math.randomseed(os.time())
	
	wait(500)
	downloadText = 'Проверяем наличие обновлений...'
	imgui.Process = true
	window_states['loadscript'].v = true
	
	-------------------------------- ПРОВЕРКА ОБНОВЛЕНИЙ
	--[[local resd, resinfo = downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/update_v1.json', os.getenv('TEMP') .. '\\versions.json', true, true)
	if resd then
		local info = decodeJson(resinfo)
		if info.updatetext and info.latest_number and info.latest and info.msg and info.msg_auto then
			updatetext = info.updatetext .. '\n'
			updatever = info.latest
			msgdev = info.msg .. '\n'
			msgauto = info.msg_auto .. '\n'
			version = tonumber(info.latest_number)
			if version > tonumber(thisScript().version_num) then
				downloadText = 'Найдено обновление! Ожидание входа..'
				repeat
					wait(10)
				until sampIsLocalPlayerSpawned()
				window_states['loadscript'].v = false
				window_states['update'].v = true
				while true do wait(100) end
			end
		else
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Не удалось проверить наличие обновлений (#1).", 0xCECECE)
			thisScript():unload()
			return
		end
	else
		print(resinfo)
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Не удалось проверить наличие обновлений (#2). Перезагружаемся...", 0xCECECE)
		thisScript():reload()
		return
	end-]]

	-- из проверки обновлений

	updatetext = "." .. '\n'
	updatever = "." .. '\n'
	msgdev = u8"Сообщение разработчика для MMEDITOR".. '\n'
	msgauto = u8"Сообщение для AUTOEDIT" .. '\n'
	
	local ip, _ = sampGetCurrentServerAddress()
	lastip = ip
	if string.find(ip,"54.37.142.72") then
		ServerHero = 'Red'
		urlServer = 'https://forum.advance-rp.ru/forums/tv-i-radio.27/'
	elseif string.find(ip,"185.169.134.238") then	
		ServerHero = 'Green'
		urlServer = 'https://forum.advance-rp.ru/forums/tv-i-radio.84/'
	elseif string.find(ip,"54.37.142.74") then
		ServerHero = 'Blue'
		urlServer = 'https://forum.advance-rp.ru/forums/tv-i-radio.239/'
	elseif string.find(ip,"54.37.142.75") then
		ServerHero = 'Lime'
		urlServer = 'https://forum.advance-rp.ru/forums/tv-i-radio.584/'
	elseif string.find(ip,"185.169.134.157") then
		ServerHero = 'Chocolate'
		urlServer = 'https://forum.advance-rp.ru/forums/tv-i-radio.709/'
	else
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Скрипт предназначен для серверов Advance RolePlay.", 0xCECECE)
		thisScript():unload()
		return
	end
	downloadText = 'Ожидание входа...'
	repeat
    	wait(10)
	until sampIsLocalPlayerSpawned()
	if res3 and ini.LIBmsg.lib1 then
		ini.LIBmsg.lib1 = false
		inicfg.save(ini, './MME/setting.ini')
	else
		if ini.LIBmsg.lib1 then
			downloadText = 'Установка библиотек...'
			msgscript('Мы обнаружили, что у вас не установлена библиотека LuaSocket.')
			msgscript('Пользователи {ff6666}Windows XP{CECECE}, введите - /noupd. Windows 7 и выше - /upd')
			sampRegisterChatCommand('noupd', function() 
				ini.LIBmsg.lib1 = false
				inicfg.save(ini, './MME/setting.ini')
			end)
			sampRegisterChatCommand('upd', function() 
				lua_thread.create(function() downloadLib(false) end)
			end)
		end
	end
	
	while ini.LIBmsg.lib1 do
		wait(100)
	end
	if not string.find(imgui._VERSION, '^1.1.3$') then
		msgscript('{fff099}MM Editor использует версию imgui 1.1.3. Ваша версия: ' .. imgui._VERSION .. '. Во избежание ошибок...')
		msgscript('{fff099}Удалите файлы imgui.lua и MoonImGui.dll в GTA/moonloader/lib (перед этим нужно выйти из игры)')
	end
	downloadText = 'Ожидание входа...'
	-------------------------------- REGISTRATION
	local result, id = sampGetPlayerIdByCharHandle(playerPed)
	PlayerNickHero = sampGetPlayerNickname(id)
	PlayerNameHero = string.gsub(PlayerNickHero, '_', ' ')
	SumHero = 0
	regDialogOpen = true
	sampSendChat("/mn")
	while ScriptUse == 3 do
		wait(0)
	end
	if ScriptUse == 0 then
		thisScript():unload()
		return
	end
	-------------------------------- ПОЛУЧЕНИЕ НОМЕРА АККАУНТА
	ScriptUse = 2
	regDialogOpen = true
	sampSendChat("/mn")
	while ScriptUse == 2 do
		wait(0)
	end
	-------------------------------- DIRECTORY CREATE
	if not doesDirectoryExist("moonloader\\Mass Media Editor") then
		createDirectory("moonloader\\Mass Media Editor")
	end
	if not doesDirectoryExist("moonloader\\config\\AutoEdit") then
		createDirectory("moonloader\\config\\AutoEdit")
	end
	if not doesDirectoryExist("moonloader\\Mass Media Editor\\Help") then
		createDirectory("moonloader\\Mass Media Editor\\Help")
	end
	if not doesFileExist("moonloader\\Mass Media Editor\\anagramm_1.txt") then
		local fpath = "moonloader\\Mass Media Editor\\anagramm_1.txt"
		downloadText = 'Загрузка файла анаграмм... (1/3)'
		downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/dicts/anagramm_1.txt', fpath, false, false)
	end
	if not doesFileExist("moonloader\\Mass Media Editor\\anagramm_2.txt") then
		local fpath = "moonloader\\Mass Media Editor\\anagramm_2.txt"
		downloadText = 'Загрузка файла анаграмм... (2/3)'
		downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/dicts/anagramm_2.txt', fpath, false, false)
	end
	if not doesFileExist("moonloader\\Mass Media Editor\\anagramm_3.txt") then
		local fpath = "moonloader\\Mass Media Editor\\anagramm_3.txt"
		downloadText = 'Загрузка файла анаграмм... (3/3)'
		downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/dicts/anagramm_3.txt', fpath, false, false)
	end
	-------------------------------- DOWNLOAD PRAVILA
	
	if not doesFileExist("moonloader\\Mass Media Editor\\Help\\diallistppo.txt") then
		downloadText = 'Загрузка устава, ПРО, ППЭ...'
		downloadPRAVILA()
	else
		readPRAVILA()
	end
	downloadText = 'Загрузка файла конфигурации...'
	-------------------------------- CONFIG FILE

	urlblacklist = ""
	dataYst = "xx.xx.xxxx"
	dataPro = "xx.xx.xxxx"
	dataPpo = "xx.xx.xxxx"
	sobesZakon = "20"
	sobesLVL = "3"
	editdev = true
	AutoEditdev = true
	MMEditMSG = false
	msgedit = "-"
	--[[
	local resd, resinfo = downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/Help_'.. urlencode(ServerHero) ..'/config.json', os.getenv('TEMP') .. '\\config.json', true, true)
	if resd then
		local info = decodeJson(resinfo)
		if info.lvl and info.zakon and info.urlblacklist and info.datayst and info.datapro and info.datappo and info.msg and info.edit ~= nil and info.MMmsg ~= nil then
			urlblacklist = info.urlblacklist
			MMEditMSG = info.MMmsg
			sobesLVL = info.lvl
			sobesZakon = info.zakon
			dataYst = info.datayst
			dataPro = info.datapro
			dataPpo = info.datappo
			AutoEditdev = info.AutoEdit
			editdev = info.edit
			msgedit = u8:decode(info.msg)
		else
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Не удалось загрузить файл конфигурации (#1).", 0xCECECE)
			thisScript():unload()
			return
		end
	else
		print(resinfo)
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Не удалось загрузить файл конфигурации (#2). Перезагружаемся...", 0xCECECE)
		thisScript():reload()
		return
	end
	]]

	downloadText = 'Загрузка файла настроек...'
	-- вырезано
	Mainmsg = u8'На данный момент управляющему СМИ запрещено отправлять новости.'
	LastChangeName = 'Admin'
	MainmsgTime = 'xx.xx.xxxx'
	donateNicksServer = {}
	
	downloadText = 'Обновление файла черного списка...'
	blackdownload(false)
	window_states['loadscript'].v = false
	--------------------------------
	-------------------------------- AUTOEDIT
	main_ini = inicfg.load(iniMain, 'AutoEdit/AutoEdit_setting.ini')
	pattern_ini = inicfg.load({}, 'AutoEdit/AutoEdit_pattern.ini')

	bufferOfPrice = {}
	bufferNameOfPrice = {'При продаже:', 'При покупке:', 'При продаже (сумма не определена):', 'При покупке (сумма не определена):'}
	for i = 1, 4 do
		bufferOfPrice[i] = imgui.ImBuffer(u8(main_ini.price[i]), 50)
	end

	buffWindId =  imgui.ImInt(main_ini.window.id)
	buffWindTitle = imgui.ImBuffer(tostring(u8(main_ini.window.title)), 128)
	buffWindNick = imgui.ImBuffer(tostring(u8(main_ini.window.regNick)), 128)
	buffWindAd = imgui.ImBuffer(tostring(u8(main_ini.window.regAd)), 128)

	iniLoaded = {}
	local res = getFileIni(true)
	for i = 1, #res do
		iniLoaded[#iniLoaded + 1] = inicfg.load(nil, 'AutoEdit/' .. res[i])
		--sampAddChatMessage(iniLoaded[i].setting.name .. ' ' .. i,-1)
	end
	stepSetting = 0
	-------------------------------- AUTOEDIT^
	if donateNicksServer[PlayerNickHero] then
		msgscript("Привет, " .. RangNameHero .. " {".. donateNicksServer[PlayerNickHero] .."}" .. PlayerNameHero .. "{CECECE}! Скрипт успешно загружен.")
		array_windows_mmeditor = {'Главное меню','Состояние','Управление СМИ', 'Донат','Группа ВК', 'Препочтения', 'Клавиши', 'Оформление','Старший состав', 'Гос. новости', 'Отыгровки','Спасибо Вам...!', 'Шпаргалки', 'О скрипте/Команды'}
	else
		msgscript("Привет, " .. RangNameHero .. " " .. PlayerNameHero .. "! Скрипт успешно загружен.")
		array_windows_mmeditor = {'Главное меню','Состояние','Управление СМИ', 'Донат','Группа ВК', 'Препочтения', 'Клавиши', 'Оформление','Старший состав', 'Гос. новости', 'Отыгровки','Спасибо им...!', 'Шпаргалки', 'О скрипте/Команды'}
		ini.Prefs['pref14'] = true
		prefBools['pref14'] = imgui.ImBool(ini.Prefs['pref14'])
	end
	
	msgscript("Меню скрипта - /mmeditor или клавиша " .. keysToText(ini.Key1) .. ".")
	-------------------------------- COMMANDS
	sampRegisterChatCommand('r', rchat)
	sampRegisterChatCommand('autoedit', loadsettings)
	sampRegisterChatCommand('f', fchat)
	sampRegisterChatCommand("ff",ff)
	sampRegisterChatCommand("rr",rr)
	sampRegisterChatCommand("mmeditor", w_mmeditor)
	sampRegisterChatCommand("gos", loadgos)
	sampRegisterChatCommand("lec", loadlec)
	sampRegisterChatCommand("smsn",smsn)
	sampRegisterChatCommand("act",actdialog)
	sampRegisterChatCommand('hist', hist)
	sampRegisterChatCommand('tvlf', tvlift)
	sampRegisterChatCommand('stand', standon)
	sampRegisterChatCommand("uninv", uninvite)
	sampRegisterChatCommand("efir", efiron)
	sampRegisterChatCommand("anag", anagramm)
	sampRegisterChatCommand("mmblack", function() window_states['mmblack'].v = not window_states['mmblack'].v end)
	sampRegisterChatCommand('mmefir', function() 
	window_states['efir'].v = not window_states['efir'].v 
	end)
	sampRegisterChatCommand('dauto', function(t)
		editFrom = 'in customizing...'
		editOriginal = t
		edit_buffer.v = u8(main_ini.main.teg .. ' ' .. AutoEdit(t))
		editappear = true
		edit_window.v = true
	end)
	--------------------------------
	lua_thread.create(function()
		while true do
			if os.date('%M', os.time()) == '55' then
				sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} До зарплаты осталось 5 минут.", 0xCECECE)
				if ini.Prefs.pref6 then
					sampSendChat('/do Пришло уведомление на телефон.')
				end
				wait(60000)
			end
			wait(1000)
		end
	end)
	while true do
		wait(0)
		if not sampIsChatInputActive() and not isSampfuncsConsoleActive() and not sampIsDialogActive() and not (window_states['main'].v and selectedm == 7) then
			if checkKeys(ini['Key1']) then
				while checkKeys(ini['Key1']) do 
					wait(50) 
				end
				w_mmeditor()
			elseif checkKeys(ini['Key2']) then
				while checkKeys(ini['Key2']) do 
					wait(50)
				end
				if editdev then
					if RangHero > 2 then
						if editflood == true then
							sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Ловля отключена.", 0xCECECE)
							editflood = false
						else
							sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Ловля включена. Строка «Нет новых объявлений» не отображается.", 0xCECECE)
							editflood = true
							lua_thread.create(function ()
							while editflood == true do
								if not sampIsChatInputActive() and not isSampfuncsConsoleActive() and not sampIsDialogActive() and not edit_window.v then
									sampSendChat("/edit")
									wait(2000)
								end
								wait(100)
							end
						end)
						end
					else
						sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Ловля доступна с 3 ранга.", 0xCECECE)
					end
				else
					sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} " .. msgedit, 0xCECECE)
				end
			elseif checkKeys(ini['Key3']) then
				while checkKeys(ini['Key3']) do 
					wait(50)
				end
				loadgos()
			elseif checkKeys(ini['Key4']) then
				while checkKeys(ini['Key4']) do 
					wait(50)
				end
				loadlec()
			elseif checkKeys(ini['Key5']) then
				while checkKeys(ini['Key5']) do 
					wait(50)
				end
				window_states['pravila'].v = not window_states['pravila'].v
			end
			local valid, ped = getCharPlayerIsTargeting(PLAYER_HANDLE) -- получить хендл персонажа, в которого целится игрок
			if valid and doesCharExist(ped) and checkKeys(ini['Key6']) then -- если цель есть и персонаж существует
				while checkKeys(ini['Key6']) do 
					wait(50) 
				end
				result__, idTarget = sampGetPlayerIdByCharHandle(ped) -- получить samp-ид игрока по хендлу персонажа
				if result__ then -- проверить, прошло ли получение ида успешно
					nameTarget = sampGetPlayerNickname(idTarget)
					TargetName = string.gsub(nameTarget, '_', ' ')
					window_states['target_next'].v = false
					window_states['target'].v = true
				end
			end
		end
	end
end

function explode_argb(argb)
  local a = bit.band(bit.rshift(argb, 24), 0xFF)
  local r = bit.band(bit.rshift(argb, 16), 0xFF)
  local g = bit.band(bit.rshift(argb, 8), 0xFF)
  local b = bit.band(argb, 0xFF)
  return a, r, g, b
end
-------------------------------- AUTOEDIT
function loadsettings()
	if stepSetting ~= 0 then return end

	mainListSelect = 0
	patListSelect = nil
	iniListSelect = nil
	main_window.v = not main_window.v
	--[[imgui.Text(u8(texta))
		imgui.InputText('', AEname)
		local res, s = pcall(string.match, texta, u8:decode(AEname.v))
		if s and res then
			imgui.Text(u8(s))
		end--]]
end

function callbackPat(i)
	if i == #pattern_ini + 1 then return '------ Добавить ------' 
	else return pattern_ini[i].name end
end
function callbackIni(i)
	if i == #iniLoaded + 1 then return '------ Добавить ------' 
	else return iniLoaded[i].setting.name end
end
function callbackIniList(i)
	if i == #iniLoaded[iniListSelect].main + 1 then return '------ Добавить ------' 
	else return iniLoaded[iniListSelect].main[i] end
end
local edit_callback = imgui.ImCallback(function (data)
	if editappear then
		data.SelectionStart = data.SelectionEnd
		editappear = false
		--data.BufDirty = true
		--data.CursorPos = -1
	end
	if editcursorpos then
		data.CursorPos = editcursorpos
		--editcursorpos = nil
	end
	if data.CursorPos == editcursorpos then
		editcursorpos = nil
	end
	--sampAddChatMessage(data.CursorPos, -1)
end)

function imgui_set_window()
	imgui.SetNextWindowPos(imgui.ImVec2(4.2*resx/5, 4*resy/5), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(250*global_scale.v, 100*global_scale.v)) 
	imgui.Begin('SetWindow', nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoFocusOnAppearing)
	if stepSetting == 2 then
		imgui.TextColoredRGB('{99ff99}Наверное, мы его нашли',2)
		imgui.Separator()
		imgui.Spacing()
		imgui.TextColoredRGB('Заголовок: ' .. showTitle .. '\nID: ' .. showId .. '\t\tСтиль: ' .. showStyle, 2)
		imgui.Spacing()
		imgui.Separator()
		imgui.TextColoredRGB('Отредактируйте объявление', 2)
	elseif stepSetting == 3 then
		imgui.TextColoredRGB('{99ff99}Если позади остался диалог,\n{99ff99}закройте его', 2)
		imgui.Spacing()
		imgui.Separator()
		imgui.Spacing()
		imgui.TextColoredRGB('Если мешает окно настройки,\nперенесите его в сторону', 2)
	else
		imgui.TextColoredRGB('{99ff99}Давайте начнем!', 2)
		imgui.Separator()
		imgui.Spacing()
		imgui.TextColoredRGB('Откройте диалог с\nредактированием объявлений\n{808080}Используйте ESC, чтобы выйти', 2)
	end
	imgui.End()
	if stepSetting == 3 then
		imgui.ShowCursor = true
		imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
		imgui.SetNextWindowSize(imgui.ImVec2(500*global_scale.v, 370*global_scale.v))
		imgui.Begin(u8'Привязка диалога', nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
			imgui.TextColoredRGB('Вам предстоит указать строку с объявлением и ником\nДля этого нужно использовать рег. выражения (подсказка ниже)\n{99ff99}Текст диалога (экранированы знаки переноса (\\n) и табуляций (\\t)):', 2)
			imgui.Spacing()
				imgui.BeginChild('bind window', imgui.ImVec2(485*global_scale.v, 100*global_scale.v), true)
					imgui.TextWrapped(u8(tostring(showText)))
				imgui.EndChild()
			imgui.Spacing()
			imgui.SetCursorPosX(242*global_scale.v - imgui.CalcTextSize(u8'Регулярное выражение объявления:').x / 2)
			imgui.Text(u8'Регулярное выражение объявления:')
			imgui.SetCursorPosX(86*global_scale.v)
			imgui.InputText(' ', buffWindAd)
			local res1, s1 = pcall(string.match, showDText, unScreenSymbols(u8:decode(buffWindAd.v)))
			imgui.SetCursorPosX(60*global_scale.v)
			imgui.Text(u8'Результат: ')
			if s1 and res1 then
				imgui.SameLine()
				imgui.TextWrapped(screenSymbols(u8(s1)))
			end
			imgui.Spacing()
			imgui.SetCursorPosX(242*global_scale.v - imgui.CalcTextSize(u8'Регулярное выражение ника (можно оставить пустым):').x / 2)
			imgui.Text(u8'Регулярное выражение ника (можно оставить пустым):')
			imgui.SetCursorPosX(86*global_scale.v)
			imgui.InputText('', buffWindNick)
			local res2, s2 = pcall(string.match, showDText, unScreenSymbols(u8:decode(buffWindNick.v)))
			imgui.SetCursorPosX(60*global_scale.v)
			imgui.Text(u8'Результат: ')
			if s2 and res2 then
				imgui.SameLine()
				imgui.TextWrapped(screenSymbols(u8(s2)))
			end
			imgui.Spacing()
			imgui.SetCursorPosX(92*global_scale.v)
			if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then		
				if res1 and s1 then
					main_ini.window.id = showId
					main_ini.window.title = showTitle
					main_ini.window.regAd = u8:decode(buffWindAd.v)
					if res2 and s2 then
						main_ini.window.regNick = u8:decode(buffWindNick.v)
					else
						main_ini.window.regNick = ''
					end
					local ok = inicfg.save(main_ini, 'AutoEdit/AutoEdit_setting.ini')
					if ok then
						printStringNow('SAVED!', 1500)
					else
						printStringNow('ERROR!', 1500)
					end
					stepSetting = 0
					set_window.v = false
				else
					printStringNow('ERROR OF AD!', 1500)
				end
			end
			imgui.SameLine()
			if imgui.Button(u8("Отменить"), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				stepSetting = 0
				set_window.v = false
			end
			imgui.Spacing()
			imgui.SetCursorPosX(242*global_scale.v - imgui.CalcTextSize(u8'Подсказка по регулярным выражениям (?)').x / 2)
			imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), u8'Подсказка по регулярным выражениям (?)')
			if imgui.IsItemHovered() then
				imgui.SetTooltip(u8([[Суть регулярного выражения - «выцепить» нужную строку. Чтобы это сделать, нужно
произвести «захват» строки. Для этого нужно между «постоянными» строками
написать нужное регулярное выражение. Регулярные выражения вы можете
посмотреть в интернете, но для большинства случаев понадобиться лишь два:

(.-) - захватывает минимальное совпадение, (.+) - максимальное совпадение

Пример их различия:
Текст: \nРаз\nДва\nТри\n
Выражение: \n(.-)\n		Результат: Раз
Выражение: \n(.+)\n		Результат: Раз\nДва\nТри

Пример использования:
Часть текста: \nТекст объявления: куплю дом\n
Шаблон: \nТекст объявления: (.-)\n
Результат: куплю дом]]))
			end
		imgui.End()
	end
end

function imgui_main_window()
	imgui.ShowCursor = true
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(700*global_scale.v, 425*global_scale.v))
	imgui.Begin("Advanced AutoEdit", main_window, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.MenuBar)
	if imgui.BeginMenuBar() then
		if imgui.BeginMenu(u8'Меню') then
			if imgui.MenuItem(u8'Главное меню') then
				mainListSelect = 0
			end
			if imgui.MenuItem(u8'Группа скрипта') then
				os.execute('explorer "' .. thisScript().url ..'"')
			end
			imgui.EndMenu()
		end
		if imgui.BeginMenu(u8'Настройки') then
			if imgui.MenuItem(u8'Общие') then
				buffWindId.v = main_ini.window.id
				buffWindTitle.v = tostring(u8(main_ini.window.title))
				buffWindNick.v = tostring(u8(main_ini.window.regNick))
				buffWindAd.v = tostring(u8(main_ini.window.regAd))
				AEname.v = tostring(u8(main_ini.main.teg))
				mainListSelect = 1
			end
			if imgui.MenuItem(u8'Шаблоны') then
				mainListSelect = 2
				patListSelect = nil
			end
			if imgui.MenuItem(u8'Замены (теги)') then
				mainListSelect = 3
				iniListSelect = nil
			end
			imgui.EndMenu()
		end
		if imgui.BeginMenu(u8'Инструкция') then
			if imgui.MenuItem(u8'О шаблонах') then
				mainListSelect = 4
			end
			if imgui.MenuItem(u8'О заменах (тегах)') then
				mainListSelect = 5
			end
			if imgui.MenuItem(u8'Принцип работы') then
				mainListSelect = 6
			end
			if imgui.MenuItem(u8'Порядок настройки') then
				mainListSelect = 7
			end
			if imgui.MenuItem(u8'Тема с готовыми настройками') then
				os.execute('explorer "https://vk.com/topic-177496337_44195419"')
			end
			if imgui.MenuItem(u8'Видеоинструкция (скоро)') then
			end
			imgui.EndMenu()
		end
		if imgui.BeginMenu(u8'Донат') then
			if imgui.MenuItem(u8'Здесь пока его нет') then
			end
			if imgui.MenuItem(u8'Но можете отблагодарить') then
			end
			if imgui.MenuItem(u8'Группа ВК всегда есть :)') then
			end
			imgui.EndMenu()
		end
		imgui.EndMenuBar()
	end
	if mainListSelect == 0 then
		--imgui.TextColoredRGB('{99ff99}Добро пожаловать в Advanced AutoEdit v' .. thisScript().version .. '\nЗдесь будут сообщения о багах, акциях, обновлениях и другом',2)
		imgui.TextColoredRGB('{99ff99}Добро пожаловать в Advanced AutoEdit v1.0\nЗдесь будут сообщения о багах, акциях, обновлениях и другом',2)
		imgui.Separator()
		imgui.TextColoredRGB('{99ccff}Сообщение разработчика',2)
		imgui.Separator()
		imgui.BeginChild('message_dev', imgui.ImVec2(684*global_scale.v, 275*global_scale.v), false)
			for str in string.gmatch(msgauto, '.-\n') do
				imgui.TextWrapped(str)
			end
		imgui.EndChild()
		imgui.Separator()
		imgui.Spacing()
		if imgui.Button(u8'Открыть группу скрипта ВКонтакте',imgui.ImVec2(-0.1, 0)) then
			os.execute('explorer "' .. thisScript().url ..'"')
		end
	elseif mainListSelect == 1 then
		imgui.BeginChild('price_settings', imgui.ImVec2(350*global_scale.v, 365*global_scale.v), true)
			imgui.Spacing()
			imgui.TextColoredRGB('{99ff99}Редактирование тегов цен\nТег "price" заменится на сумму\nНе используйте теги цен в качестве главных тегов', 2)
			imgui.Spacing()
			imgui.Separator()
			for i = 1, 4 do
				imgui.Spacing()
				imgui.SetCursorPosX(175*global_scale.v - imgui.CalcTextSize(u8(bufferNameOfPrice[i])).x / 2)
				imgui.Text(u8(bufferNameOfPrice[i]))
				imgui.SetCursorPosX(75*global_scale.v)
				imgui.PushItemWidth(200*global_scale.v)
				imgui.InputText('                           ' .. i,bufferOfPrice[i])
				imgui.PopItemWidth()
			end
			imgui.Spacing()
			
			imgui.SetCursorPosX(100*global_scale.v)
			imgui.PushID(1)
			if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				for i = 1, 4 do
					main_ini.price[i] = u8:decode(bufferOfPrice[i].v)
				end
				local ok = inicfg.save(main_ini, 'AutoEdit/AutoEdit_setting.ini')
				if ok then
					printStringNow('SAVED!', 1500)
				else
					printStringNow('ERROR!', 1500)
				end
			end
			imgui.PopID()
			imgui.Spacing()
			imgui.Separator()
			imgui.Spacing()
			imgui.SetCursorPosX(135*global_scale.v)
			imgui.PushItemWidth(80*global_scale.v)
			imgui.InputText(u8'тег', AEname)
			imgui.SameLine()
			imgui.Text('(?)')
			if imgui.IsItemHovered() then 
				imgui.SetTooltip(u8'Этот тег будет всегда ставиться перед объявлением') 
			end
			imgui.PopItemWidth()
			imgui.Spacing()
			imgui.SetCursorPosX(100*global_scale.v)
			imgui.PushID(3)
			if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				main_ini.main.teg = u8:decode(AEname.v)
				local ok = inicfg.save(main_ini, 'AutoEdit/AutoEdit_setting.ini')
				if ok then
					printStringNow('SAVED!', 1500)
				else
					printStringNow('ERROR!', 1500)
				end
			end
			imgui.PopID()
		imgui.EndChild()
		imgui.SameLine()
		imgui.BeginChild('wind_settings', imgui.ImVec2(326*global_scale.v, 365*global_scale.v), true)
			imgui.Spacing()
			imgui.TextColoredRGB('{99ff99}Привязка скрипта к окну редактирования\nЗдесь можно указать параметры диалога вручную\nили настроить автоматически\nЗаголовок окна можно указать рег. выражением', 2)
			imgui.Spacing()
			imgui.Separator()
			imgui.SetCursorPosX(163*global_scale.v - imgui.CalcTextSize(u8'ID диалога:').x / 2)
			imgui.Text(u8'ID диалога:')
			imgui.PushItemWidth(80*global_scale.v)
			imgui.SetCursorPosX(123*global_scale.v)
			imgui.InputInt('    ', buffWindId)
			imgui.Spacing()
			imgui.SetCursorPosX(163*global_scale.v - imgui.CalcTextSize(u8'Заголовок диалога:').x / 2)
			imgui.Text(u8'Заголовок диалога:')
			imgui.PushItemWidth(200*global_scale.v)
			imgui.SetCursorPosX(63*global_scale.v)
			imgui.InputText('', buffWindTitle)
			imgui.Spacing()
			imgui.SetCursorPosX(163*global_scale.v - imgui.CalcTextSize(u8'Регулярное выражение объявления:').x / 2)
			imgui.Text(u8'Регулярное выражение объявления:')
			imgui.SetCursorPosX(63*global_scale.v)
			imgui.InputText('  ', buffWindAd)
			imgui.Spacing()
			imgui.SetCursorPosX(163*global_scale.v - imgui.CalcTextSize(u8'Регулярное выражение ника:').x / 2)
			imgui.Text(u8'Регулярное выражение ника:')
			imgui.SetCursorPosX(63*global_scale.v)
			imgui.InputText('   ', buffWindNick)
			imgui.Spacing()

			imgui.SetCursorPosX(88*global_scale.v)
			imgui.PushID(2)
			if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then

				main_ini.window.id = buffWindId.v
				main_ini.window.title = u8:decode(buffWindTitle.v)
				main_ini.window.regNick = u8:decode(buffWindNick.v)
				main_ini.window.regAd = u8:decode(buffWindAd.v)

				local ok = inicfg.save(main_ini, 'AutoEdit/AutoEdit_setting.ini')
				if ok then
					printStringNow('SAVED!', 1500)
				else
					printStringNow('ERROR!', 1500)
				end
			end
			imgui.PopID()
			imgui.SetCursorPosX(88*global_scale.v)
			if imgui.CustomButton(u8'Мастер настроек', imgui.ImVec4(0.0, 0.60, 0.0, 1.0), imgui.ImVec4(0.1, 0.8, 0.1, 1.0), imgui.ImVec4(0.0, 0.4, 0.0, 1.0), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				main_window.v = false
				stepSetting = 1
				set_window.v = true
			end
			imgui.SetCursorPosX(63*global_scale.v)
			if imgui.Button(u8("Установить для Advance RP"), imgui.ImVec2(200*global_scale.v, 20*global_scale.v)) then
				buffWindId.v = 224
				buffWindTitle.v = u8'Публикация объявления'
				buffWindNick.v = u8'Отправитель:%s+(%S+)\\n'
				buffWindAd.v = u8'Текст:%s+{......}(.-)\\n'
			end
		imgui.EndChild()
	elseif mainListSelect == 2 then
		imgui.BeginChild('choose_shab', imgui.ImVec2(150*global_scale.v, 365*global_scale.v), true)
		imgui.TextColoredRGB('{99ff99}Шаблоны', 2)
		imgui.Separator()
		for i = 1, #pattern_ini + 1 do
			if imgui.Selectable(u8(callbackPat(i)), patListSelect == i, imgui.SelectableFlags.SpanAllColumns) then
				listOfIni = ''
				for b = 1, #iniLoaded do
					if b == #iniLoaded then
						listOfIni = listOfIni .. '{' .. iniLoaded[b].setting.name2 .. '} - ' .. iniLoaded[b].setting.name .. ', {price1} - Цена покупки, {price2} - Цена продажи'
					else
						listOfIni = listOfIni .. '{' .. iniLoaded[b].setting.name2 .. '} - ' .. iniLoaded[b].setting.name .. ', '
					end
				end
				patListSelect = i
				if patListSelect == #pattern_ini + 1 then
					AEname.v = ''
					patPatB.v = ''
					AEsmallName.v = ''
					AEbool.v = false
				else
					AEname.v = u8(pattern_ini[i].name)
					patPatB.v = u8(pattern_ini[i].pat)
					AEsmallName.v = u8(pattern_ini[i].separ)
					AEbool.v = pattern_ini[i].separbool
				end
			end
		end
		imgui.EndChild()
		imgui.SameLine()
		imgui.BeginGroup()
		if patListSelect then
			imgui.BeginChild('edit_shab', imgui.ImVec2(523*global_scale.v, 335*global_scale.v), true)
			imgui.TextColoredRGB('{ff6666}Доступные теги:', 2)
			imgui.Separator()
			imgui.TextWrapped(u8(listOfIni))
			imgui.Separator()
			imgui.TextColoredRGB('{99ff99}Каждое объявление должно содержать {ff6666}главные{99ff99} теги\n{99ff99}Если нет совпадений по ним, то шаблон пропускается\n{99ff99}Главный тег указывается как {{ff6666}!{99ff99}тег}', 2)
			imgui.Separator()
			imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8'Название:').x / 2)
			imgui.Text(u8'Название:')
			imgui.SetCursorPosX(187*global_scale.v)
			imgui.PushItemWidth(150*global_scale.v)
			imgui.InputText(' ', AEname)
			imgui.PopItemWidth()
			imgui.Spacing()
			imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8'Шаблон:').x / 2)
			imgui.Text(u8'Шаблон:')
			imgui.SetCursorPosX(87*global_scale.v)
			imgui.PushItemWidth(350*global_scale.v)
			imgui.InputText('  ', patPatB)
			imgui.PopItemWidth()
			if not string.find(patPatB.v, '{!.-}') then
				imgui.TextColoredRGB('{ff6666}Шаблон не содержит главных тегов', 2)
			end
			imgui.Spacing()
			imgui.SetCursorPosX(242*global_scale.v - imgui.CalcTextSize(u8'Разделить объявление (?) ').x / 2)
			imgui.Text(u8'Разделить объявление (?) ')
			if imgui.IsItemHovered() then 
				imgui.SetTooltip(u8'При поиске совпадений тегов для замены проверяет каждую часть шаблона и объявления отдельно\n- Обязан содержать разделительное слово в шаблоне\n- Позволяет использовать 2 одинаковых тега в одном шаблоне\n- Обычно используйте при обмене\nПример: {!obmen} {!auto} на {!auto}. (Разделительное слово "на")') 
			end
			imgui.SameLine()
			imgui.ToggleButton("patSeparBool", AEbool)
			if AEbool.v then
				imgui.SetCursorPosX(237*global_scale.v - imgui.CalcTextSize(u8'Разделительное слово: ').x / 2)
				imgui.Text(u8'Разделительное слово: ')
				imgui.SameLine()
				imgui.PushItemWidth(50*global_scale.v)
				imgui.InputText('   ', AEsmallName)
				imgui.PopItemWidth()
				if not string.find(patPatB.v, ' ' .. AEsmallName.v .. ' ') then
					imgui.TextColoredRGB('{ff6666}Разделительного слова нет в шаблоне', 2)
				end
			end
			imgui.EndChild()
			imgui.BeginChild('buttons_shab', imgui.ImVec2(395*global_scale.v, 25*global_scale.v), false)
				if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
					if patListSelect ~= #pattern_ini + 1 then
						pattern_ini[patListSelect]['name'] = u8:decode(AEname.v)
						pattern_ini[patListSelect]['pat'] = u8:decode(patPatB.v)
						pattern_ini[patListSelect]['separbool'] = AEbool.v
						pattern_ini[patListSelect]['separ'] = u8:decode(AEsmallName.v)	
					else
						pattern_ini[patListSelect] = {
							name = u8:decode(AEname.v),
							pat = u8:decode(patPatB.v),
							separbool = AEbool.v,
							separ = u8:decode(AEsmallName.v)
						}
					end
					local ok = inicfg.save(pattern_ini, 'AutoEdit/AutoEdit_pattern.ini')
					if ok then
						printStringNow('SAVED!', 1500)
					else
						printStringNow('ERROR!', 1500)
					end
				end
				imgui.SameLine()
				if patListSelect ~= #pattern_ini + 1 then
					if imgui.CustomButton(u8'Удалить', imgui.ImVec4(1.0, 0.15, 0.15, 1.0), imgui.ImVec4(1.0, 0.4, 0.4, 1.0), imgui.ImVec4(1.0, 0.1, 0.1, 1.0), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
						if patListSelect == #pattern_ini then
							AEname.v = ''
							patPatB.v = ''
							AEsmallName.v = ''
							AEbool.v = false
						end
						table.remove(pattern_ini, patListSelect)
						local ok = inicfg.save(pattern_ini, 'AutoEdit/AutoEdit_pattern.ini')
						if ok then
							printStringNow('SAVED!', 1500)
						else
							printStringNow('ERROR!', 1500)
						end
					end
					imgui.SameLine()
				end
				if imgui.Button(u8("^"), imgui.ImVec2(25*global_scale.v, 20*global_scale.v)) then
					mainListSelect = 3
					iniListSelect = nil
				end
			imgui.EndChild()
		end
		imgui.EndGroup()
	elseif mainListSelect == 3 then
		imgui.BeginChild('choose_section', imgui.ImVec2(150*global_scale.v, 365*global_scale.v), true)
		imgui.TextColoredRGB('{99ff99}Раздел', 2)
		imgui.Separator()
		for i = 1, #iniLoaded + 1 do -- Список разделов 
			if imgui.Selectable(u8(callbackIni(i)), iniListSelect == i, imgui.SelectableFlags.SpanAllColumns) then
				iniListSelect = i
				iniListMainSelect = nil
				if iniListSelect == #iniLoaded + 1 then
					AEname.v = ''
					iniName2.v = ''
					iniNotFound.v = ''
					AEbool.v = false
					AEsmallName.v = ''
				else
					AEname.v = u8(iniLoaded[i].setting.name)
					iniName2.v = u8(iniLoaded[i].setting.name2)
					iniNotFound.v = u8(iniLoaded[i].setting.notFound)
					AEbool.v = iniLoaded[i].setting.searchNext
					AEsmallName.v = u8(iniLoaded[i].setting.splitWord)
				end
			end
		end
		imgui.EndChild()
		if iniLoaded[iniListSelect] then
			imgui.SameLine()
			imgui.BeginChild('choose_words', imgui.ImVec2(150*global_scale.v, 365*global_scale.v), true)
			imgui.TextColoredRGB('{99ff99}Слова замены', 2)
			imgui.Separator()
			for i = 1, #iniLoaded[iniListSelect].main + 1 do -- Список слов
				if imgui.Selectable(u8(callbackIniList(i)), iniListMainSelect == i, imgui.SelectableFlags.SpanAllColumns) then
					iniListMainSelect = i
					buffer_autoedit = {}
					if #iniLoaded[iniListSelect].main + 1 ~= iniListMainSelect then
						patPatB.v = u8(iniLoaded[iniListSelect].main[iniListMainSelect])
						for a = 1, #iniLoaded[iniListSelect][iniListMainSelect] do
							buffer_autoedit[a] = imgui.ImBuffer(u8(iniLoaded[iniListSelect][iniListMainSelect][a]), 150)
						end
					else
						patPatB.v = ''
						buffer_autoedit[1] = imgui.ImBuffer('', 150)
					end
				end
			end
			imgui.EndChild()
			imgui.SameLine()
			imgui.BeginGroup()
			if iniListMainSelect then
				imgui.BeginChild('edit_words', imgui.ImVec2(363*global_scale.v, 335*global_scale.v), true)
				imgui.TextColoredRGB('{ff6666}Каждая строка - вариация одного и того же слова\nВ каждой строке ищется хотя бы одно совпадение\nЧтобы указать слова, которые не должны быть найдены\nв объявлении, используйте "un," в начале строки', 2)
				imgui.Separator()
				imgui.Spacing()		
				imgui.SetCursorPosX(181*global_scale.v - imgui.CalcTextSize(u8'Заменить на:').x / 2)
				imgui.Text(u8'Заменить на:')
				imgui.PushItemWidth(250*global_scale.v)
				imgui.SetCursorPosX(55*global_scale.v)
				imgui.InputText('  ', patPatB)
				imgui.PopItemWidth()
				imgui.Spacing()
				imgui.SetCursorPosX(181*global_scale.v - imgui.CalcTextSize(u8'Слова-определители:').x / 2)
				imgui.Text(u8'Слова-определители:')
				for i = 1, #buffer_autoedit do
					imgui.PushItemWidth(250*global_scale.v)
					imgui.SetCursorPosX(55*global_scale.v)
					imgui.InputText(tostring(i), buffer_autoedit[i])
					imgui.PopItemWidth()
					if i == #buffer_autoedit and i ~= 1 then
						imgui.SameLine()
						if imgui.SmallButton('X') then
							table.remove(buffer_autoedit, i)
						end
					end
				end
				if #buffer_autoedit < 7 then
					imgui.SetCursorPosX(144*global_scale.v)
					if imgui.Button(u8("Добавить"), imgui.ImVec2(75*global_scale.v, 20*global_scale.v)) then
						buffer_autoedit[#buffer_autoedit + 1] = imgui.ImBuffer('', 150)
					end
					imgui.SameLine()
				end
				imgui.EndChild()
				imgui.BeginChild('buttons_words', imgui.ImVec2(350*global_scale.v, 25*global_scale.v), false)
					if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
						if iniLoaded[iniListSelect][iniListMainSelect] then
							if #buffer_autoedit < #iniLoaded[iniListSelect][iniListMainSelect] then
								for i = #iniLoaded[iniListSelect][iniListMainSelect], #buffer_autoedit, -1 do
									iniLoaded[iniListSelect][iniListMainSelect][i] = nil
								end
							end
							for i = 1, #buffer_autoedit do
								iniLoaded[iniListSelect][iniListMainSelect][i] = u8:decode(buffer_autoedit[i].v)
							end
							iniLoaded[iniListSelect].main[iniListMainSelect] = u8:decode(patPatB.v)
						else
							iniLoaded[iniListSelect][iniListMainSelect] = {}
							iniLoaded[iniListSelect].main[iniListMainSelect] = u8:decode(patPatB.v)
							for i = 1, #buffer_autoedit do
								iniLoaded[iniListSelect][iniListMainSelect][i] = u8:decode(buffer_autoedit[i].v)
							end
						end
						local ok = inicfg.save(iniLoaded[iniListSelect], 'AutoEdit/ini' .. iniListSelect .. '.ini')
						if ok then
							printStringNow('SAVED!', 1500)
						else
							printStringNow('ERROR!', 1500)
						end
					end
					imgui.SameLine()
					if iniLoaded[iniListSelect][iniListMainSelect] then
						if imgui.CustomButton(u8'Удалить ветку', imgui.ImVec4(1.0, 0.15, 0.15, 1.0), imgui.ImVec4(1.0, 0.4, 0.4, 1.0), imgui.ImVec4(1.0, 0.1, 0.1, 1.0), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
							table.remove(iniLoaded[iniListSelect], iniListMainSelect)
							table.remove(iniLoaded[iniListSelect].main, iniListMainSelect)
							iniListMainSelect = nil
							local ok = inicfg.save(iniLoaded[iniListSelect], 'AutoEdit/ini' .. iniListSelect .. '.ini')
							if ok then
								printStringNow('SAVED!', 1500)
							else
								printStringNow('ERROR!', 1500)
							end
						end
						imgui.SameLine()
					end
					if imgui.Button(u8("^"), imgui.ImVec2(25*global_scale.v, 20*global_scale.v)) then
						mainListSelect = 2
						patListSelect = nil
					end
				imgui.EndChild()
			else
				imgui.BeginChild('edit_words', imgui.ImVec2(363*global_scale.v, 335*global_scale.v), true)
					imgui.TextColoredRGB('{ff6666}Указывайте тег, который не был ещё использован\nТег может содержать всё объявление целиком\nТег указывается без {}', 2)
					imgui.Separator()
					imgui.Spacing()
					imgui.PushItemWidth(150*global_scale.v)
					imgui.SetCursorPosX(181*global_scale.v - imgui.CalcTextSize(u8'Название:').x / 2)
					imgui.Text(u8'Название:')
					imgui.SetCursorPosX(106*global_scale.v)
					imgui.InputText(' ', AEname)
					imgui.SetCursorPosX(181*global_scale.v - imgui.CalcTextSize(u8'Тег:').x / 2)
					imgui.Text(u8'Тег:')
					imgui.SetCursorPosX(106*global_scale.v)
					imgui.InputText('  ', iniName2)
					imgui.Spacing()
					imgui.SetCursorPosX(181*global_scale.v - imgui.CalcTextSize(u8'Если не найдено (?):').x / 2)
					imgui.Text(u8'Если не найдено (?):')
					if imgui.IsItemHovered() then 
						imgui.SetTooltip(u8'Не используйте это, если этот тег является в шаблоне главным\nЕсли в данном теге ничего не найдено, то он заменится на слово ниже\nОставьте строку пустой, если не хотите это использовать') 
					end
					imgui.SetCursorPosX(106*global_scale.v)
					imgui.InputText('   ', iniNotFound)
					imgui.PopItemWidth()
					imgui.SetCursorPosX(161*global_scale.v - imgui.CalcTextSize(u8'Искать далее ').x / 2)
					imgui.Text(u8'Искать далее ')
					imgui.SameLine()
					imgui.ToggleButton('iniSearch', AEbool)
					if AEbool.v then
						imgui.SetCursorPosX(147*global_scale.v - imgui.CalcTextSize(u8'Соединяющее слово (?)').x / 2)
						imgui.Text(u8'Соединяющее слово (?)')
						if imgui.IsItemHovered() then 
							imgui.SetTooltip(u8'При нескольких совпадениях слова будут соединины этим словом\nИспользуйте "0" в качестве пробела') 
						end
						imgui.SameLine()
						imgui.PushItemWidth(50*global_scale.v)
						imgui.InputText('    ', AEsmallName)
						imgui.PopItemWidth()
					end
				imgui.EndChild()
				imgui.BeginChild('buttons_words', imgui.ImVec2(350*global_scale.v, 25*global_scale.v), false)
					if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
						iniLoaded[iniListSelect].setting.name = u8:decode(AEname.v)
						iniLoaded[iniListSelect].setting.name2 = u8:decode(iniName2.v)
						iniLoaded[iniListSelect].setting.searchNext = AEbool.v
						iniLoaded[iniListSelect].setting.notFound = u8:decode(iniNotFound.v)
						iniLoaded[iniListSelect].setting.splitWord = u8:decode(AEsmallName.v)
						local ok = inicfg.save(iniLoaded[iniListSelect], 'AutoEdit/ini' .. iniListSelect .. '.ini')
						if ok then
							printStringNow('SAVED!', 1500)
						else
							printStringNow('ERROR!', 1500)
						end
					end
					imgui.SameLine()
					if imgui.CustomButton(u8'Удалить раздел', imgui.ImVec4(1.0, 0.15, 0.15, 1.0), imgui.ImVec4(1.0, 0.4, 0.4, 1.0), imgui.ImVec4(1.0, 0.1, 0.1, 1.0), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
						os.remove('./moonloader/config/AutoEdit/ini' .. #iniLoaded .. '.ini')
						table.remove(iniLoaded, iniListSelect)
						iniListSelect = nil
						for i = 1, #iniLoaded do
							local ok = inicfg.save(iniLoaded[i], 'AutoEdit/ini' .. i .. '.ini')
							if not ok then
								sampAddChatMessage('Произошла некоторая ошибка', -1)
							end
						end
					end
				imgui.EndChild()
			end
			imgui.EndGroup()
		elseif iniListSelect == #iniLoaded + 1 then
			imgui.SameLine()
			imgui.BeginGroup()
				imgui.BeginChild('edit_wordsMain', imgui.ImVec2(523*global_scale.v, 335*global_scale.v), true)
					imgui.TextColoredRGB('{ff6666}Указывайте тег, который не был ещё использован\nТег может содержать всё объявление целиком\nОставьте строку "Если не найдено" пустой, если тег является главным', 2)
					imgui.Separator()
					imgui.PushItemWidth(150*global_scale.v)
					imgui.SetCursorPosX(131*global_scale.v - imgui.CalcTextSize(u8'Название:').x / 2)
					imgui.Text(u8'Название:')
					imgui.SameLine()
					imgui.Indent(370*global_scale.v)
					imgui.Text(u8'Тег:')
					imgui.SetCursorPosX(53*global_scale.v)
					imgui.InputText(' ', AEname)
					imgui.SameLine()
					imgui.Unindent(60*global_scale.v)
					imgui.InputText('  ', iniName2)
					imgui.Spacing()
					imgui.SetCursorPosX(261*global_scale.v - imgui.CalcTextSize(u8'Если не найдено (?):').x / 2)
					imgui.Text(u8'Если не найдено (?):')
					if imgui.IsItemHovered() then 
						imgui.SetTooltip(u8'Не используйте это, если этот тег является в шаблоне главным\nЕсли в данном теге ничего не найдено, то он заменится на слово ниже\nОставьте строку пустой, если не хотите это использовать') 
					end
					imgui.SetCursorPosX(186*global_scale.v)
					imgui.InputText('   ', iniNotFound)
					imgui.PopItemWidth()
					imgui.SetCursorPosX(241*global_scale.v - imgui.CalcTextSize(u8'Искать далее ').x / 2)
					imgui.Text(u8'Искать далее ')
					imgui.SameLine()
					imgui.ToggleButton('iniSearch', AEbool)
					if AEbool.v then
						imgui.SetCursorPosX(236*global_scale.v - imgui.CalcTextSize(u8'Соединяющее слово (?)').x / 2)
						imgui.Text(u8'Соединяющее слово (?)')
						if imgui.IsItemHovered() then 
							imgui.SetTooltip(u8'При нескольких совпадениях слова будут соединины этим словом\nИспользуйте "0" в качестве пробела') 
						end
						imgui.SameLine()
						imgui.PushItemWidth(50*global_scale.v)
						imgui.InputText('    ', AEsmallName)
						imgui.PopItemWidth()
					end
				imgui.EndChild()
				imgui.BeginChild('buttons_wordsMain', imgui.ImVec2(395*global_scale.v, 25*global_scale.v), false)
					if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
						iniLoaded[#iniLoaded + 1] = {
							setting = {
								name = u8:decode(AEname.v),
								name2 = u8:decode(iniName2.v),
								searchNext = AEbool.v,
								notFound = u8:decode(iniNotFound.v),
								splitWord = u8:decode(AEsmallName.v)
							},
							main = {}
						}
						local ok = inicfg.save(iniLoaded[#iniLoaded], 'AutoEdit/ini' .. iniListSelect .. '.ini')
						if ok then
							printStringNow('SAVED!', 1500)
						else
							printStringNow('ERROR!', 1500)
						end
					end
				imgui.EndChild()
			imgui.EndGroup()
		end
	elseif mainListSelect == 4 then
		imgui.TextColoredRGB([[Шаблоны указывают скрипту, как ему переделать объявление, а также содержит теги поиска.
 
{ff6666}Замечания о шаблонах:
- Теги цен в шаблоне нельзя указывать главными.
- Шаблон обязан содержать главные теги.
- В одном шаблоне не должно быть одинаковые тегов. Исключение: при включенной опции «Разделить
объявление» можно использовать 2 одинаковых тега по разные стороны разделительного слова.
- Разделительное слово в самом шаблоне должно быть выделено пробелами. Пример: « на ».
 
{ff6666}Разъяснение некоторых настроек и определений шаблона:
{99ff99}- «Главный тег»
Каждый тег содержит набор слов для поиска совпадений по объявлению. Если хотя бы 1 главный тег
не найдет совпадающих слов, то шаблон будет пропущен. Подробнее об этом инструкции тегов.
{99ff99}- «Название»
Название есть название. Используется для удобства ориентирования.
{99ff99}- «Разделить объявление» (вкл/выкл)
При включенной опции предлагает ввести разделительное слово.
{99ff99}- «Разделительное слово»
Указывает скрипту каким словом разбить объявление. Оно обязано быть и в самом шаблоне.
 
{ff6666}Примеры шаблонов и тегов:
{auto} > Автомобили > Bullet (бул)
{sell} > Продажа > Продам (прод)
{price} (Цена продажи)
 
Шаблон: {sell} автомобиль марки «{auto}». {price1}
Объявление: продам булку
Конечное объявление: Продам автомобиль марки «Bullet». Цена договорная
]])
	elseif mainListSelect == 5 then
		imgui.TextColoredRGB([[Теги заменяются на найденные в них слова. «Слова-определители» сократим до «СО».
 
{ff6666}Замечания о тегах:
- Если тег является главным в каком-либо шаблоне, то в настройке «Если не найдено» нужно оставить пустоту.
- Слова-определители (СО) перечисляются через запятую без пробелов. Пример: «бул,bull»
- Если вы хотите указать СО, которые НЕ должны быть найдены в объявлении, то в начале строке напишите
«un,», а далее перечисляйте СО. Пример: «un,булка,bull»
- Каждая строка ОС указывает на одну и ту же вариацию слова.
- Используйте 0 в качестве пробела при настройке соединительного слова.
 
{ff6666}Разъяснение некоторых настроек и определений тегов:
{99ff99}- «Название»
Используется для удобства ориентирования и может быть любым
{99ff99}- «Тег»
Используется при составлении шаблонов. Именно его скрипт заменяет на найденное слово. Пишется без
фигурных скобок, маленькими английскими буквами.
{99ff99}- «Если не найдено»
Может использоваться, если тег в шаблоне является не главным. Если в теге не будет ничего не найдено, он
заменится на указанный текст.
{99ff99}- «Искать далее» (вкл/выкл) и «Соединяющее слово»
При этой опции скрипт будет искать все совпадения слов, а не первое попавшееся. Например, скрипт найдёт по
этому тегу несколько автомобилей, то он заменит тег всеми найденными автомобилями и напишет их через
соединительное слово. Пример: «Bullet, Sultan» (соединительное слово «,»)]])
	elseif mainListSelect == 6 then
		imgui.TextColoredRGB([[Скрипт перебирает все шаблоны. Далее в каждом шаблоне проверяет теги. В каждом теге содержаться
слова замены, на которые тег будет заменятся. В свою же очередь слова замены содержат слова-определители,
по которым ищется совпадение.
 
Наглядный пример:
auto (тег) > Bullet > бул,bull (слова-определители)
		> Sultan > султ,sult (слова-определители)
		...
 
В шаблоне есть обычные теги и главные. Если хотя бы в одном главном теге {!тег} нет совпадений, то шаблон
пропускается. Если в обычных тегах нет совпадений, то они просто убираются или заменяются на текст, который
указан в настройках.]])
	elseif mainListSelect == 7 then
		imgui.TextColoredRGB([[{99ff99}Порядок настройки AutoEdit:
 
{ff6666}1.{ffffff} Переходим в Настройки>Замены (теги).
{ff6666}2.{ffffff} Создаём необходимые теги (автомобили, мотоциклы, местоположения…)
{ff6666}3.{ffffff} Начинаем их заполнять. Для этого нужно нажать по названию раздела и в следующем столбце «Слова замены»
нажать на кнопку «Добавить» и указать слово, на которое будет заменяться тег, и его слова-определители.
Подробнее об этом в настройках тегов.
{ff6666}4.{ffffff} Повторяем пункт №3 пока не заполним раздел полностью. В итоге должны получится несколько разделов со
своими словами замены и словами-определителями.
{ff6666}5.{ffffff} Начинаем создавать шаблоны опираясь на созданные теги. Для этого переходим в Настройки>Шаблоны.
{ff6666}6.{ffffff} Создаём новый шаблон. Для этого нажимаем на кнопку «Добавить», указываем любое название и вводим сам
шаблон, используя созданные нами теги. О шаблонах написано в инструкции шаблонов.
{ff6666}7.{ffffff} Переходим во вкладку Настроки>Общие. Нам нужно настроить привязку к окну редактирования. Есть несколько
путей: установить для Advance RP и сохранить, ввести всё самому и сохранить или воспользоваться мастером
настроек и следовать инструкциям.
 
Если всё сделано правильно, то скрипт должен редактировать сам все объявления по шаблонам, которые вы
создали. Если возникают вопросы, то пишите в группу скрипта.]])
	end
	imgui.End()
end
function imgui_edit_window()
	imgui.ShowCursor = true
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(600*global_scale.v, 160*global_scale.v))
	imgui.Begin(u8"Публикация объявления", nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
	imgui.Text(u8('Отправитель объявления: ' .. editFrom))
	imgui.Text(u8('Текст объявления: ' .. editOriginal))
	imgui.PushItemWidth(585*global_scale.v)
	imgui.Spacing()
	local ind = 38
	imgui.Indent(ind*global_scale.v)
	local xCor = 120
	if imgui.Button(u8'Вставка \"Как есть\"', imgui.ImVec2(120*global_scale.v, 20*global_scale.v)) then
		edit_buffer.v = u8(main_ini.main.teg .. ' ' .. editOriginal)
		editappear = true
	end
	local xCor = xCor + 18 + ind
	imgui.SameLine(xCor*global_scale.v)
	if imgui.Button(u8'AutoEdit', imgui.ImVec2(120*global_scale.v, 20*global_scale.v)) then
		edit_buffer.v = u8(main_ini.main.teg .. ' ' .. AutoEdit(editOriginal))
		editappear = true
	end
	local xCor = xCor + 130
	imgui.SameLine(xCor*global_scale.v)
	if imgui.Button(u8'Только тег', imgui.ImVec2(120*global_scale.v, 20*global_scale.v)) then
		edit_buffer.v = u8(main_ini.main.teg .. ' ')
		editappear = true
	end
	local xCor = xCor + 130
	imgui.SameLine(xCor*global_scale.v)
	
	if imgui.Button(u8('ПРО'), imgui.ImVec2(120*global_scale.v, 20*global_scale.v)) then
		edit_buffer.v = u8(main_ini.main.teg .. ' ПРО')
		editappear = true
	end
	
	imgui.Unindent(ind*global_scale.v)
	imgui.Spacing()
	if imgui.InputText(u8'     esaaeditasd ', edit_buffer, 32 + imgui.InputTextFlags.CallbackAlways, edit_callback) == true then
		if u8:decode(edit_buffer.v):find(' ПРО') then
			sampSendDialogResponse(main_ini.window.id, 0, 0, u8:decode(edit_buffer.v))
		else
			sampSendDialogResponse(main_ini.window.id, 1, 0, u8:decode(edit_buffer.v))
		end
		edit_window.v = false
	end
	if (editappear) then
		imgui.SetKeyboardFocusHere(-1)
	end
	imgui.Spacing()
	imgui.PopItemWidth()
	imgui.Indent(25*global_scale.v)
	if imgui.Button(u8'Отправить', imgui.ImVec2(150*global_scale.v, 25*global_scale.v)) then
		sampSendDialogResponse(main_ini.window.id, 1, 0, u8:decode(edit_buffer.v))
		edit_window.v = false
	end
	imgui.SameLine(420*global_scale.v)
	if imgui.Button(u8'Отклонить', imgui.ImVec2(150*global_scale.v, 25*global_scale.v)) then
		sampSendDialogResponse(main_ini.window.id, 0, 0, u8:decode(edit_buffer.v))
		edit_window.v = false
	end
	imgui.End()
end

addEventHandler("onWindowMessage", function (msg, wparam, lparam)
    if wparam == key.VK_ESCAPE then
		if set_window.v and stepSetting ~= 3 then 
			set_window.v = false
			stepSetting = 0
			consumeWindowMessage(true, true)
		end
    end
end)

function screenSymbols(text)
	local text = string.gsub(text, '\n', '\\n')
	local text = string.gsub(text, '\t', '\\t')
	return text
end

function unScreenSymbols(text)
	local text = string.gsub(text, '\\n', '\n')
	local text = string.gsub(text, '\\t', '\t')
	return text
end

function AutoEdit(text)
	for i = 1, #pattern_ini do
		if pattern_ini[i].separbool then
			if string.find(text, ' ' .. pattern_ini[i].separ .. ' ') and string.find(pattern_ini[i].pat, ' ' .. pattern_ini[i].separ .. ' ') then
				local text2 = {string.match(text, '(.*) ' .. pattern_ini[i].separ .. ' (.*)')}
				local pat = {string.match(pattern_ini[i].pat, '(.*) ' .. pattern_ini[i].separ .. ' (.*)')}
				local finded = {}
				for i = 1, #iniLoaded do
					finded[iniLoaded[i].setting.name2] = {search(text2[1], iniLoaded[i]), search(text2[2], iniLoaded[i])}
				end
				local res = accord(pat, finded, pattern_ini[i].separ, text)
				if res then
					if u8(res):find('\"\"') then
						editcursorpos = u8(main_ini.main.teg .. ' ' .. res):find('\"\"')
					end
					return res
				end
			end
		else
			local pat = {pattern_ini[i].pat}
			local finded = {}
			for i = 1, #iniLoaded do
				finded[iniLoaded[i].setting.name2] = {search(text, iniLoaded[i])}
			end
			local res = accord(pat, finded, nil, text)
			if res then
				if u8(res):find('\"\"') then
					editcursorpos = u8(main_ini.main.teg .. ' ' .. res):find('\"\"')
				end
				return res
			end
		end
	end
	return ''
end

function accord(pat, find, sep, text)
	local accord_pat = nil
	for i = 1, 2 do
		if pat[i] == nil then 
			break
		end
		if accord_pat == nil then
			accord_pat = pat[1]
		else
			accord_pat = accord_pat .. pat[i]
		end
		local pats = find_pat(pat[i])
		for b = 1, #pats[1] do
			if not find[pats[1][b]] then
				return false
			end
			if find[pats[1][b]][i][1] then
				accord_pat = string.gsub(accord_pat,'{!'.. pats[1][b] .. '}', find[pats[1][b]][i][1])
			else
				return false
			end
		end
		for b = 1, #pats[2] do
			if not find[pats[2][b]] and not string.find(pats[2][b], 'price(%d)') then break end
			if string.find(pats[2][b], '^price%d$') then
				accord_pat = string.gsub(accord_pat,'{'.. pats[2][b] .. '}', search_price(text, tonumber(string.match(pats[2][b],'(%d)'))))
			else
				if find[pats[2][b]][i][1] then
					accord_pat = string.gsub(accord_pat,'{'.. pats[2][b] .. '}', find[pats[2][b]][i][1])
				else
					accord_pat = string.gsub(accord_pat,'{'.. pats[2][b] .. '}', '')
				end
			end
		end
		if i == 1 and pat[2] then
			accord_pat = accord_pat .. ' ' .. sep .. ' '
		elseif i == 2 or (i == 1 and not pat[2]) then
			return accord_pat
		end
	end
end

function find_pat(pat)
	local main_pat = {}
	local other_pat = {}
	for line in string.gmatch(pat, '{(.-)}') do
		if string.find(line,'!') then
			main_pat[#main_pat + 1] = string.match(line, '!(.*)')
		else
			other_pat[#other_pat + 1] = line
		end
	end
	return {main_pat, other_pat}
end

function search_price(text, choose)
	local str = ' ' .. string.gsub(string.rlower(text), '[%:%-%/\\%|\"%?%!%(%)_]', " ") .. ' ' 
	local str = str:gsub("([^0-9])[%,%.]([^0-9])", "%1 %2")
	local str = str:gsub("([^0-9])[%,%.]([0-9])", "%1 %2")
	local str = str:gsub("([0-9])[%,%.]([^0-9])", "%1 %2")
	local price = 0
	local sumstr = ""
	if string.find(str, "догов") or string.find(str, "своб") then
		if choose == 1 then
			return main_ini.price[4]
		else
			return main_ini.price[3]
		end
		price = 2
	end
	
	if (price == 0) then
		if (string.match(str,"([0-9][0-9%.,%s]*)%s?[krкл][krкл]%s", 1) or string.match(str,"([0-9][0-9%.,%s]*)%s?лям", 1) or string.match(str,"([0-9][0-9%.,%s]*)%s?млн", 1)) then
			price = 1
			sum = string.match(str,"([0-9][0-9%.,%s]*)%s?[krкл][krкл]%s", 1) or string.match(str,"([0-9][0-9%.,%s]*)%s?лям", 1) or string.match(str,"([0-9][0-9%.,%s]*)%s?млн", 1)
			if (string.find(sum, "%.")) then
				pos = string.find(sum,"%.")
			else 
				pos = string.find(sum,"%,")
			end
			sum = string.gsub(sum, " ", "")
			if (not pos) then
				pos = string.len(sum) + 1
			end
			
			--if (pos)
			--{
			sum = string.sub(sum,1,pos-1) .. string.sub(sum,pos+1)
			btbt = 6 - (string.len(sum) - pos + 1)
			for i = 1, btbt do
				sum = sum .. 0
			end
			len = (string.len(sum) - 1) / 3
			for i = 1, len do
				sum = string.sub(sum,1,(string.len(sum) - 3*i - (i - 1))) .. "." .. string.sub(sum, string.len(sum) - 3*i - (i -1) + 1) 
			end
			sum = string.gsub(sum, "^[0][0%.]*", '')
			sumstr = sumstr .. (sum .. "$")
			sumstrlen = string.len(sum) + 1
			--}
			--else sumstr = sumstr . strToANSISymbols(sum . ".000.000$")
		--end
		
		elseif (string.match(str,"([0-9][0-9%.,%s]*)%s?[krкл]%s", 1) or string.match(str,"([0-9][0-9%.,%s]*)%s?тыс", 1)) then
			price = 1
			sum = string.match(str,"([0-9][0-9%.,%s]*)%s?[krкл]%s", 1) or string.match(str,"([0-9][0-9%.,%s]*)%s?тыс", 1)
			if (string.find(sum, "%.")) then
				pos = string.find(sum,"%.")
			else 
				pos = string.find(sum,"%,")
			end

			sum = string.gsub(sum, " ", "")
			if (not pos) then
				pos = string.len(sum) + 1
			end

			--if (pos)
			--{
			sum = string.sub(sum,1, pos-1) .. string.sub(sum, pos)
			--sampAddChatMessage(sum, -1)
			btbt = 3 - (string.len(sum) - pos + 1)
			--addChatMessage(btbt)
			for i = 1, btbt do
				sum = sum .. '0'
			end
			--sampAddChatMessage(sum, -1)
			len = (string.len(sum) - 1) / 3
			for i = 1, len do
				sum = string.sub(sum, 1, (string.len(sum) - 3*i - (i - 1))) .. "." .. string.sub(sum, string.len(sum) - 3*i - (i - 1) + 1) 
			end
			--sampAddChatMessage(sum, -1)
			sum = string.gsub(sum, "^[0][0%.]*", '')
			sumstr = sumstr .. (sum .. "$")
			sumstrlen = string.len(sum) + 1
			--}
			--else {
			--	sumstr = sumstr . strToANSISymbols(sum . ".000$")
			--	sumstrlen = string.len(sum) + 5
			--}
		--end

		elseif (string.match(str,"([0-9][0-9%.,%s]*[0-9])")) then
			--AddChatMessage(sum1)
			sum = string.match(str,"([0-9][0-9%.,%s]*[0-9])", 1)
			
			price = 1
			--sum = string.match(str,"([0-9][0-9%.,%s]*)%s?[krкл][krкл]%s", 1) or string.match(str,"([0-9][0-9%.,%s]*)%s?лям", 1) or string.match(str,"([0-9][0-9%.,%s]*)%s?млн", 1)
			if (string.find(sum, "%.")) then
				pos = string.find(sum,"%.")
			else 
				pos = string.find(sum,"%,")
			end

			sum = string.gsub(sum, " ", "")
			if (not pos) then
				pos = string.len(sum) + 1
			end

			sum = string.gsub(sum, "%,", '.')
			numbersum = tonumber(sum)
			sum = string.gsub(sum, "%.", '')
			sum = string.gsub(sum, "%,", '')
			sum = string.gsub(sum, "%s", '')
			if (numbersum and numbersum < 100 and what ~= 4) then
				btbt = 6 - (string.len(sum) - pos + 1)
				--addChatMessage(btbt)
				for i = 1, btbt do
					sum = sum .. '0'
				end
			elseif (numbersum and numbersum < 1000 and what ~= 4) then
				btbt = 3 - (string.len(sum) - pos + 1)
				--addChatMessage(btbt)
				for i = 1, btbt do
					sum = sum .. '0'
				end
			end
			len = (string.len(sum) - 1) / 3
			for i = 1, len do
				sum = string.sub(sum,1,(string.len(sum) - 3*i - (i - 1))) .. "." .. string.sub(sum, string.len(sum) - 3*i - (i -1) + 1) 
			end
			sumstr = sumstr .. (sum .. "$")
			sumstrlen = string.len(sum) + 1
		end
		if (price == 0) then
			if choose == 1 then
				return main_ini.price[4]
			else
				return main_ini.price[3]
			end
		else 
			if choose == 1 then
				return string.gsub(main_ini.price[2],'{price}', sumstr)
			else
				return string.gsub(main_ini.price[1],'{price}', sumstr)
			end
		end
	end
end

function search(str, ini)
	str = ' ' .. string.gsub(string.rlower(str), '[%:%-%/\\%|\"%?%!%(%)_]', " ") .. ' ' 
	local res = {}
	
	for a = 1, #ini do -- счётчик [a]
		local main_break = false
		local count = 0
		for b = 1, #ini[a] do -- счетчик [a] b =
			if main_break then break end
			local words = split(ini[a][b], ',') -- слова
			if words[1] == 'un' then
				for i = 1, #words do -- счётчик слов в b = i
					if string.find(str, words[i]) then
						main_break = true
						break
					else
						if i == #words then
							count =  count + 1
							if count == #ini[a] then
								res[#res + 1] = ini.main[a]
								if ini.setting.searchNext then break
								else return res end
							end
						end
					end
				end
			else
				for i = 1, #words do -- счётчик слов в b = i
					if string.find(str, words[i]) then
						count = count + 1
						if count == #ini[a] then
							res[#res + 1] = ini.main[a]
							if ini.setting.searchNext then break
							else return res end
						else break end
					else
						if i == #words then
							main_break = true
						end
					end
				end
			end
		end
	end
	
	if #res == 0 then 
		if ini.setting.notFound ~= '' then
			return {ini.setting.notFound}
		else
			return {false}
		end
	elseif #res > 1 then
		local temp = ''
		local splitw = string.gsub(ini.setting.splitWord, '0',' ')
		for i = 1, #res do
			if i == #res then
				temp = temp .. res[i]
			else
				temp = temp .. res[i] .. splitw
			end
		end
		return {temp}
	end
	return res
end

function imgui.TextColoredRGB(text, pos)
    local width = imgui.GetWindowWidth()
    local style = imgui.GetStyle()
    local colors = style.Colors
    local ImVec4 = imgui.ImVec4

    local explode_argb = function(argb)
        local a = bit.band(bit.rshift(argb, 24), 0xFF)
        local r = bit.band(bit.rshift(argb, 16), 0xFF)
        local g = bit.band(bit.rshift(argb, 8), 0xFF)
        local b = bit.band(argb, 0xFF)
        return a, r, g, b
    end

    local getcolor = function(color)
        if color:sub(1, 6):upper() == 'SSSSSS' then
            local r, g, b = colors[1].x, colors[1].y, colors[1].z
            local a = tonumber(color:sub(7, 8), 16) or colors[1].w * 255
            return ImVec4(r, g, b, a / 255)
        end
        local color = type(color) == 'string' and tonumber(color, 16) or color
        if type(color) ~= 'number' then return end
        local r, g, b, a = explode_argb(color)
        return imgui.ImColor(r, g, b, a):GetVec4()
    end

    local render_text = function(text_)
        for w in text_:gmatch('[^\r\n]+') do
            local textsize = w:gsub('{.-}', '')
			if pos == 2 then
				local text_width = imgui.CalcTextSize(u8(textsize))
				imgui.SetCursorPosX( width / 2 - text_width .x / 2 )
			end
            local text, colors_, m = {}, {}, 1
            w = w:gsub('{(......)}', '{%1FF}')
            while w:find('{........}') do
                local n, k = w:find('{........}')
                local color = getcolor(w:sub(n + 1, k - 1))
                if color then
                    text[#text], text[#text + 1] = w:sub(m, n - 1), w:sub(k + 1, #w)
                    colors_[#colors_ + 1] = color
                    m = n
                end
                w = w:sub(1, n - 1) .. w:sub(k + 1, #w)
            end
            if text[0] then
                for i = 0, #text do
                    imgui.TextColored(colors_[i] or colors[1], u8(text[i]))
                    imgui.SameLine(nil, 0)
                end
                imgui.NewLine()
            else
                imgui.Text(u8(w))
            end
        end
    end
    render_text(text)
end
function getFileIni(mod)
	if mod then
		local files = {}
		local handleFile, nameFile = findFirstFile('moonloader/config/AutoEdit/ini*.ini')
		while nameFile do
			if handleFile then
				if not nameFile then 
					findClose(handleFile)
				else
					files[#files+1] = nameFile
					nameFile = findNextFile(handleFile)
				end
			end
		end
		local out = {}
		for i = 1, #files do
			out[tonumber(string.match(files[i],'ini(%d+).ini'))] = files[i]
		end
		return out
	else
		local files = {}
		local handleFile, nameFile = findFirstFile('moonloader/Mass Media Editor/Help/*.txt')
		while nameFile do
			if handleFile then
				if not nameFile then 
					findClose(handleFile)
				else
					files[#files+1] = nameFile
					nameFile = findNextFile(handleFile)
				end
			end
		end
		return files
	end
end
function imgui.CustomButton(name, color, colorHovered, colorActive, size)
    local clr = imgui.Col
    imgui.PushStyleColor(clr.Button, color)
    imgui.PushStyleColor(clr.ButtonHovered, colorHovered)
    imgui.PushStyleColor(clr.ButtonActive, colorActive)
    if not size then size = imgui.ImVec2(0, 0) end
    local result = imgui.Button(name, size)
    imgui.PopStyleColor(3)
    return result
end
local lu_rus, ul_rus = {}, {}
for i = 192, 223 do
    local A, a = string.char(i), string.char(i + 32)
    ul_rus[A] = a
    lu_rus[a] = A
end
local E, e = string.char(168), string.char(184)
ul_rus[E] = e
lu_rus[e] = E
function string.rlower(s)
    s = string.lower(s)
    local len, res = #s, {}
    for i = 1, len do
        local ch = string.sub(s, i, i)
        res[i] = ul_rus[ch] or ch
    end
    return table.concat(res)
end
function string.rupper(s)
    s = string.upper(s)
    local len, res = #s, {}
    for i = 1, len do
        local ch = string.sub(s, i, i)
        res[i] = lu_rus[ch] or ch
    end
    return table.concat(res)
end
-------------------------------- AUTOEDIT^

function loadgos()
	regedit = false
	if selected == #inig + 1 then
		selected = 1
	end
	window_states['m'].v = not window_states['m'].v 
end

function loadlec()
	reglec = false
	if selectedlec == #inilec + 1 then
		selected = 1
	end
	window_states['editlec'].v = not window_states['editlec'].v 
end

function anagramm(var)
	if string.find(var, '^1$') or string.find(var, '^2$') or string.find(var, '^3$') then
		lua_thread.create(function()
			wait(100)
			if string.find(var,'1') then
				local linea = 0
				local words = {}
				for line in io.lines('moonloader\\Mass Media Editor\\anagramm_1.txt') do
					linea = linea + 1
					words[linea] = line
				end
				local randomwords = math.random(1, #words)
				local letter = stringToArray(words[randomwords])
				for i = 1, 50 do 
					local j = math.random(i, #letter) 
					letter[i], letter[j] = letter[j], letter[i]
				end
				local anagramm = ''
				for i = 1, #letter do
					anagramm = letter[i] .. '.' .. anagramm
				end
				sampSetChatInputEnabled(true)
				if string.find(PodrHero,"Радиоцентр") then
					sampSetChatInputText('/t ' .. anagramm)
				elseif string.find(PodrHero,"центр") then
					sampSetChatInputText('/u ' .. anagramm)
				else
					sampSetChatInputText(anagramm)
				end
				msgscript('Анаграмма (' .. anagramm .. ') слова "' .. words[randomwords] .. '".')
				local words = {}
			elseif string.find(var,'2') then
				local linea = 0
				local words = {}
				for line in io.lines('moonloader\\Mass Media Editor\\anagramm_2.txt') do
					linea = linea + 1
					words[linea] = line
				end
				local randomwords = math.random(1, #words)
				local letter = stringToArray(words[randomwords])
				for i = 1, 50 do 
					local j = math.random(i, #letter) 
					letter[i], letter[j] = letter[j], letter[i]
				end
				local anagramm = ''
				for i = 1, #letter do
					anagramm = letter[i] .. '.' .. anagramm
				end
				sampSetChatInputEnabled(true)
				if string.find(PodrHero,"Радиоцентр") then
					sampSetChatInputText('/t ' .. anagramm)
				elseif string.find(PodrHero,"центр") then
					sampSetChatInputText('/u ' .. anagramm)
				else
					sampSetChatInputText(anagramm)
				end
				msgscript('Анаграмма (' .. anagramm .. ') слова "' .. words[randomwords] .. '".')
				local words = {}
			elseif string.find(var,'3') then
				local linea = 0
				local words = {}
				for line in io.lines('moonloader\\Mass Media Editor\\anagramm_3.txt') do
					linea = linea + 1
					words[linea] = line
				end
				local randomwords = math.random(1, #words)
				local letter = stringToArray(words[randomwords])
				for i = 1, 50 do 
					local j = math.random(i, #letter) 
					letter[i], letter[j] = letter[j], letter[i]
				end
				local anagramm = ''
				for i = 1, #letter do
					anagramm = letter[i] .. '.' .. anagramm
				end
				sampSetChatInputEnabled(true)
				if string.find(PodrHero,"Радиоцентр") then
					sampSetChatInputText('/t ' .. anagramm)
				elseif string.find(PodrHero,"центр") then
					sampSetChatInputText('/u ' .. anagramm)
				else
					sampSetChatInputText(anagramm)
				end
				msgscript('Анаграмма (' .. anagramm .. ') слова "' .. words[randomwords] .. '".')
				local words = {}
			end
		end)
	else
		msgscript('Используйте /anag [1(сущ)/2(глаг)/3(прил)]')
		msgscript('Пример: /anag 1 выведет анаграмму существительного.')
	end
end

function stringToArray(str)
	local t = {}
	for i = 1, #str do
		t[i] = str:sub(i, i)
	end
	return t
end

function efiron()
	if not RPactive then
		RPactive = true
		if RPefir then
			lua_thread.create(function()
				if ini.Prefs.pref13 then
					for str in string.gmatch(string.gsub(iniRP[13]['RP'], '\\n', '\n') .. '\n', '.-\n') do
						local str = string.gsub(str, '\n', '')
						if string.match(str, '^%d+$') then
							wait(string.match(str,'(%d+)'))
						else
							if (str:sub(1,1) == '/') then
								sampSendChat(str)
							else
								sampSendChat('/t ' .. str)
							end
						end
					end
				end
				if ini.Prefs.pref7 then
					wait(1000)
					for str in string.gmatch(string.gsub(iniRP[11]['RP'], '\\n', '\n') .. '\n', '.-\n') do
						local str = string.gsub(str, '\n', '')
						if string.match(str, '^%d+$') then
							wait(string.match(str,'(%d+)'))
						else
							sampSendChat(str)
						end
					end
				else
					sampSendChat('/efir')
				end
				RPactive = false
			end)
		else
			lua_thread.create(function() 
				if ini.Prefs.pref7 then
					for str in string.gmatch(string.gsub(iniRP[10]['RP'], '\\n', '\n') .. '\n', '.-\n') do
						local str = string.gsub(str, '\n', '')
						if string.match(str, '^%d+$') then
							wait(string.match(str,'(%d+)'))
						else
							sampSendChat(str)
						end
					end
					wait(1000)
				else
					sampSendChat('/efir')
				end
				if ini.Prefs.pref13 then
					for str in string.gmatch(string.gsub(iniRP[12]['RP'], '\\n', '\n') .. '\n', '.-\n') do
						local str = string.gsub(str, '\n', '')
						if string.match(str, '^%d+$') then
							wait(string.match(str,'(%d+)'))
						else
							if (str:sub(1,1) == '/') then
								sampSendChat(str)
							else
								sampSendChat('/t ' .. str)
							end
						end
					end
				end
				RPactive = false
			end)
		end
	end
end

function uninvite(var)
	if (RangHero < 8) then
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Увольнять сотрудников можно начиная с 8 ранга.", 0xCECECE)
		return
	end
	if RPactive then return end
	if string.match(var,"^%d+%s.*") then
		local id, prich = string.match(var,"^(%d+)%s(.*)")
		if sampIsPlayerConnected(id) then
			RPactive = true
			local nickuninv = sampGetPlayerNickname(id)
			local nameuninv = string.gsub(nickuninv, '_', ' ')
			lua_thread.create(function()
				for str in string.gmatch(string.gsub(iniRP[8]['RP'], '\\n', '\n') .. '\n', '.-\n') do
					local str = string.gsub(str, '\n', '')
					if string.match(str, '^%d+$') then
						wait(string.match(str,'(%d+)'))
					else
						local str = string.gsub(str, '{work}', nameuninv)
						sampSendChat(str)
					end
				end
				wait(200)
			if ini.Prefs.pref3 and Podr1Hero == "" then
				sampSendChat("/f " .. ini.Tags.f .. " Сотрудник " .. nameuninv .. " уволен. Причина: " .. prich)
				wait(200)
			elseif ini.Prefs.pref3 then
				sampSendChat("/r " .. ini.Tags.r .. " Сотрудник " .. nameuninv .. " уволен. Причина: " .. prich)
				wait(200)
			end
				sampSendChat('/uninvite ' .. id .. ' ' .. prich)
				RPactive = false
			end)
		else
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Игрок не подключен к серверу.", 0xCECECE)
		end
	else
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Используйте /uninv [id] [причина]", 0xCECECE)
	end
end

function standon()
	if not RPactive then
		RPactive = true
		if RPpalata then
			lua_thread.create(function()
				if ini.Prefs.pref8 then
					for str in string.gmatch(string.gsub(iniRP[7]['RP'], '\\n', '\n') .. '\n', '.-\n') do
						local str = string.gsub(str, '\n', '')
						if string.match(str, '^%d+$') then
							wait(string.match(str,'(%d+)'))
						else
							sampSendChat(str)
						end
					end
				else
					sampSendChat('/stand')
				end
				RPpalata = false
				RPactive = false
			end)
			-- разобрать
		else
			lua_thread.create(function() 
				if ini.Prefs.pref8 then
					for str in string.gmatch(string.gsub(iniRP[6]['RP'], '\\n', '\n') .. '\n', '.-\n') do
						local str = string.gsub(str, '\n', '')
						if string.match(str, '^%d+$') then
							wait(string.match(str,'(%d+)'))
						else
							sampSendChat(str)
						end
					end
				else
					sampSendChat('/stand')
				end
				RPpalata = true
				RPactive = false
			end)
		end
	end
end

function tvlift(kek)
	if string.match(kek,"^%d+") then
		if isCharInArea3d(playerPed, 1839.5557,-1264.6527,13.4299,1765.8602,-1319.9817,134.1671, false) then
			liftnumber = tonumber(kek)
			if liftnumber > 0 and liftnumber < 22 then
				liftnumberd = 21 - liftnumber
				sampSendChat("/me нажа" .. Sex1Hero .. " на кнопку лифта, выбрав " .. liftnumber .. " этаж")
				dialogLift = true
				sampSendChat("/tvlift")
			else
				sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Корректно введите номер этажа (1-21).", 0xCECECE)
			end
		else
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Вы должны находится рядом с лифтом.", 0xCECECE)
		end
	else
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Используйте /tvlf [этаж]", 0xCECECE)
	end
end

function actdialog(kek)
	if string.match(kek,"^%d+$") then
		if sampIsPlayerConnected(kek) then
			idTarget = kek
			nameTarget = sampGetPlayerNickname(idTarget)
			TargetName = string.gsub(nameTarget, '_', ' ')
			window_states['target_next'].v = false
			window_states['target'].v = true
		else
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Игрок не подключен к серверу.", 0xCECECE)
		end
	else
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Используйте /act [id]", 0xCECECE)
	end
end

function hist(kek)
	if string.match(kek,"^%d+$") then
		if sampIsPlayerConnected(kek) then
			sampSendChat("/history "..sampGetPlayerNickname(kek))
		else
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Игрок не подключен к серверу.", 0xCECECE)
		end
	else
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Используйте /hist [id]", 0xCECECE)
	end
end

function smsn(kek)
	if string.match(kek,"^%d+ .*") then
		local kek1, kek2 = string.match(kek,"^(%d+) (.*)")
		sampSendChat("/sms " .. kek1 .. " (( " .. kek2 .. " ))")
	else
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Используйте /smsn [номер] [текст]", 0xCECECE)
	end
end

function downloadPRAVILA()
	local files_p = getFileIni(false)
	
	for i = 1, #files_p do
		os.remove('moonloader\\Mass Media Editor\\Help\\' .. files_p[i])
	end
	
	charterNameTable = {}
	charterTable = {}
	proNameTable = {}
	proTable = {}
	ppeNameTable = {}
	ppeTable = {}
	
	
	local r, f = downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/Help_' .. urlencode(ServerHero) ..'/diallistyst.txt', 'moonloader\\Mass Media Editor\\Help\\diallistyst.txt', true, false)
	
	if r then
		local linecount = 1
		
		for line in io.lines('moonloader\\Mass Media Editor\\Help\\diallistyst.txt') do
			charterNameTable[linecount] = line
			
			local r1, info = downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/Help_' .. urlencode(ServerHero) ..'/yst1_' .. linecount .. '.txt', 'moonloader\\Mass Media Editor\\Help\\yst1_' .. linecount .. '.txt', true, false)
			
			charterTable[linecount] = info
			linecount = linecount + 1
		end
	else
		print(f)
	end
	
	local r, f = downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/Help_' .. urlencode(ServerHero) ..'/diallistpro.txt', 'moonloader\\Mass Media Editor\\Help\\diallistpro.txt', true, false)
	
	if r then
		local linecount = 1
		
		for line in io.lines('moonloader\\Mass Media Editor\\Help\\diallistpro.txt') do
			proNameTable[linecount] = line
			
			local r1, info = downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/Help_' .. urlencode(ServerHero) ..'/pro2_' .. linecount .. '.txt', 'moonloader\\Mass Media Editor\\Help\\pro2_' .. linecount .. '.txt', true, false)
			
			proTable[linecount] = info
			linecount = linecount + 1
		end
	else
		print(f)
	end
	
	local r, f = downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/Help_' .. urlencode(ServerHero) ..'/diallistppo.txt', 'moonloader\\Mass Media Editor\\Help\\diallistppo.txt', true, false)
	
	if r then
		local linecount = 1
		
		for line in io.lines('moonloader\\Mass Media Editor\\Help\\diallistppo.txt') do
			ppeNameTable[linecount] = line
			
			local r1, info = downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/Help_' .. urlencode(ServerHero) ..'/ppo3_' .. linecount .. '.txt', 'moonloader\\Mass Media Editor\\Help\\ppo3_' .. linecount .. '.txt', true, false)
			
			ppeTable[linecount] = info
			linecount = linecount + 1
		end
	else
		print(f)
	end
	
	blockButton.pravila = false
end

function readPRAVILA()
	local linecount = 1
	for line in io.lines('moonloader\\Mass Media Editor\\Help\\diallistyst.txt') do
		charterNameTable[linecount] = line
		local file = io.open('moonloader\\Mass Media Editor\\Help\\yst1_' .. linecount .. '.txt', 'r')
		if file then
			charterTable[linecount] = file:read('*a') .. '\n'
			file:close()
		end	
		linecount = linecount + 1
	end
	
	
	local linecount = 1
	for line in io.lines('moonloader\\Mass Media Editor\\Help\\diallistpro.txt') do
		proNameTable[linecount] = line
		local file = io.open('moonloader\\Mass Media Editor\\Help\\pro2_' .. linecount .. '.txt', 'r')
		if file then
			proTable[linecount] = file:read('*a') .. '\n'
			file:close()
		end
		linecount = linecount + 1
	end
	

	local linecount = 1
	for line in io.lines('moonloader\\Mass Media Editor\\Help\\diallistppo.txt') do
		ppeNameTable[linecount] = line
		local file = io.open('moonloader\\Mass Media Editor\\Help\\ppo3_' .. linecount .. '.txt', 'r')
		if file then
			ppeTable[linecount] = file:read('*a') .. '\n'
			file:close()
		end	
		linecount = linecount + 1
	end
end

function w_mmeditor()
	mainMSG_buffer = imgui.ImBuffer(Mainmsg, 4096)
	selectedm = 1
	window_states['main'].v = not window_states['main'].v
end

function sampev.onSendCommand(command)
	if (string.match(command, '^/c 60$') or string.match(command, '^/c 060$')) and not RPactive then
		dialogTime = true
		RPactive = true
		lua_thread.create(function ()
			while dialogTime do wait(0) end
			if ini.Prefs.pref1 then
				for str in string.gmatch(string.gsub(iniRP[3]['RP'], '\\n', '\n') .. '\n', '.-\n') do
					local str = string.gsub(str, '\n', '')
					if string.match(str, '^%d+$') then
						wait(string.match(str,'(%d+)'))
					else
						local str = string.gsub(str, '{time}', timenowhour .. "%:" .. timenowmin)
						local str = string.gsub(str, '{data}', timenowdata)
						sampSendChat(str)
					end
				end
			end
			if ini.Prefs.pref2 then
				wait(200)
				local outhour =  timenowhouronl - timenowhouronl1
				local outmin = timenowminonl - timenowminonl1
				if string.find(outmin,"-") then
					outmin = outmin + 60
					outhour = outhour - 1
				end
				local minutesStr = ' минут.'
				local minutes = 60 - tonumber(timenowmin)
				if (minutes == 1 or minutes == 21 or minutes == 31 or minutes == 41 or minutes == 51) then minutesStr = ' минута.' end
				if ((minutes > 1 and minutes < 5) or (minutes > 21 and minutes < 25) or (minutes > 31 and minutes < 35) or (minutes > 41 and minutes < 45) or (minutes > 51 and minutes < 55)) then minutesStr = ' минуты.' end
				sampAddChatMessage('{3399FF}[MM Editor]:{CECECE} До зарплаты осталось ' .. minutes .. minutesStr .. " Чистый онлайн: " .. outhour .. " ч " .. outmin .. " мин.", 0xCECECE)
			end
			RPactive = false
		end)
	elseif string.match(command,'^/find$') and ini.Prefs.pref4 then
		dialogFind = true
		if not RPactive and ini.Prefs.pref4 then
			RPactive = true
			lua_thread.create(function()
				while dialogFind do wait(0) end
				for str in string.gmatch(string.gsub(iniRP[4]['RP'], '\\n', '\n') .. '\n', '.-\n') do
					local str = string.gsub(str, '\n', '')
					if string.match(str, '^%d+$') then
						wait(string.match(str,'(%d+)'))
					else
						if string.find(str, '{work}') then
							if not (numberfind == "" or numberfind == nil) then
								local str = string.gsub(str, '{work}', numberfind)
								sampSendChat(str)
							end
						else
							sampSendChat(str)
						end
					end
				end
				RPactive = false
			end)
		end
	elseif string.match(command,'^/audience$') and not RPactive and ini.Prefs.pref5 then
		RPactive = true
		lua_thread.create(function()
			dialogAudience = true
			while dialogAudience do wait(0) end
			for str in string.gmatch(string.gsub(iniRP[14]['RP'], '\\n', '\n') .. '\n', '.-\n') do
				local str = string.gsub(str, '\n', '')
				if string.match(str, '^%d+$') then
					wait(string.match(str,'(%d+)'))
				else
					if string.find(PodrHero,"центр") then
						local str = string.gsub(str, '{num}', numberaudience)
						sampSendChat(str)
					else
						sampSendChat(str)
					end
				end
			end
			RPactive = false
		end)
	end
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)

	if regDialogOpen and string.find(title,"Меню игрока") then
		if ScriptUse == 2 then
			sampSendDialogResponse(dialogId, 1, 11, -1)
		else
			sampSendDialogResponse(dialogId, 1, 0, -1)
		end
		return false
	elseif regDialogOpen and string.find(title,"Статистика игрока") then
		local text1 = string.match(text,"Организация:\t\t\t{.-}(.-)\n")
		PodrHero = string.match(text,"Подразделение:\t\t{.-}(.-)\n")
		SexHero = string.find(text,"Мужской") and "Мужской" or "Женский"
		Sex1Hero = string.find(text,"Мужской") and "л" or "ла"
		Sex2Hero = string.find(text,"Мужской") and "ся" or "ась"
		Sex3Hero = string.find(text,"Мужской") and "ел" or "ла"
		RangHero = tonumber(string.match(text,"Ранг:\t\t\t\t{.-}(%d+)\n"))
		PhoneHero = string.match(text,"Номер телефона:\t\t{.-}(%d+)\n")
		RangNameHero = string.match(text,"Должность:\t\t\t{.-}(.-)\n")
		isWorkHero = not string.match(text,"Работа:\t\t\t\t{.-}Безработный\n") and true or false
		
		if text1 ~= nil then
			if not string.find(string.rlower(text1), "средства массовой") then
				msgscript('Вы не сотрудник СМИ.')
				ScriptUse = 0
				return false
			end
		else
			msgscript('Вы не сотрудник СМИ.')
			ScriptUse = 0
			return false
		end
		if string.find(PodrHero,"ЛС") then
			Podr1Hero = "ЛС"
			PodrTeg = "LS |"
			RadioTown = 'Los Santos'
		elseif string.find(PodrHero,"СФ") then
			Podr1Hero = "СФ"
			PodrTeg = "SF |"
			RadioTown = 'San Fierro'
		elseif string.find(PodrHero,"ЛВ") then
			Podr1Hero = "ЛВ"
			PodrTeg = "LV |"
			RadioTown = 'Las Venturas'
		elseif string.find(PodrHero,"Телецентр") then
			Podr1Hero = "ТВ"
			PodrTeg = "TV |"
		elseif string.find(PodrHero,"ТВ%-Радио") then
			Podr1Hero = ""
			PodrTeg = "MM |"
		end
		if (ini.Tags.f == 'default') then
			ini.Tags.f = PodrTeg
			f_buffer = imgui.ImBuffer(u8(ini.Tags.f), 128)
		end
		regDialogOpen = false
		ScriptUse = 1
		return false
	elseif regDialogOpen and string.find(title,"Донат") then
		AcconoutHero = string.match(text, 'Номер аккаунта:.-(%d+)')
		regDialogOpen = false
		ScriptUse = 1
		return false
	elseif dialogTime and string.find(title,"Точное время") then
		timenowhour = string.match(text,"{FFFFFF}Текущее время:		{3399FF}(%d+):%d+")
		timenowmin = string.match(text,"{FFFFFF}Текущее время:		{3399FF}%d+:(%d+)")
		timenowdata = string.match(text,"Сегодняшняя дата:		{66CC00}(.-)\n")
		timenowhouronl, timenowminonl = string.match(text,"Время в игре сегодня:		{ffcc00}(%d+) ч (%d+) мин")
		timenowhouronl1, timenowminonl1 = string.match(text,"AFK за сегодня:		{FF7000}(%d+) ч (%d+) мин")
		dialogTime = false
	elseif string.find(title,"Последние гос. новости") and newsDialogOpen then
		newstext = ''
		for str in string.gmatch(text .. '\n', '.-\n') do
			newstext = newstext .. str
		end
		newstext = string.gsub(newstext, '{.-}', ' ')
		newsDialogOpen = false
		window_states['m'].v = false
		window_states['n'].v = true
		return false
	elseif style == 1 and stepSetting == 1 then
		showId = dialogId
		showStyle = style
		showTitle = title
		showDText = text
		local text = string.gsub(text, '\n', '\\n\n')
		local text = string.gsub(text, '\t', '\\t\t')
		showText = text
		stepSetting = 2
	elseif dialogHistoryOpen and string.find(title,"Прошлые имена") then
		local text = string.gsub(text, '{.-}', '')
		if string.find(text, "История изменения") then
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} История изменения имён этого игрока пуста.", 0xCECECE)
		else
			for nickname in string.gmatch(text, '\t(.-)\n') do
				blcheck(nickname)
			end
			if (button2 ~= '') then
				sampSendDialogResponse(dialogId, 1, -1, '')
			return false
			else
				sampSendDialogResponse(dialogId, 1, -1, '')
				dialogHistoryOpen = false
				window_states['blacklist'].v = true
			return false
			end
		end
		dialogHistoryOpen = false
		return false
	elseif dialogLift and string.find(title,"Лифт") then
		sampSendDialogResponse(dialogId, 1, liftnumberd, -1)
		dialogLift = false
		return false
	elseif dialogFind and string.find(title,"В подразделении") then
		numberfind = string.match(title, "%(онлайн (%d+)%)")
		dialogFind = false
	elseif dialogAudience and string.find(title,"Статистика") then
		if string.find(PodrHero,"Радиоцентр") then
			numberaudience = string.match(text, "Радио ".. Podr1Hero ..":	(%d+) слушателей")
		elseif string.find(PodrHero,"центр") then
			numberaudience = string.match(text, "ТВ%-центр:	(%d+) слушателей")
		end
		dialogAudience = false
	elseif dialogId == 0 and text:match('Вы уволились с работы') then
		isWorkHero = false
	end
	if stepSetting == 0 then
		if string.find(title, main_ini.window.title) and dialogId == main_ini.window.id and style == 1 then --if string.find(title, '{......}Публикация объявления')
			editFrom = string.match(text, unScreenSymbols(main_ini.window.regNick))
			editOriginal = string.match(text, unScreenSymbols(main_ini.window.regAd))
			edit_buffer.v = u8(main_ini.main.teg .. ' ' .. AutoEdit(editOriginal))
			editappear = true
			edit_window.v = true
			return false
		end
	end
end

function sampev.onServerMessage(color, text)
	if editflood and text == "Не флудите" then
		msgscript("Ловля отключена из-за анти-флуда.")
		editflood = false
		return false
	elseif editflood and text == 'Нет новых объявлений' then
		return false
	elseif string.find(text,'^%[R%] .+ .-%[%d+%]:') and donateNicksServer ~= nil and ini.Prefs.pref14 then
		local rang, nick, id, texts = string.match(text, '^%[R%] (.+) (.-)%[(%d+)%]: (.*)')
		if donateNicksServer[nick] then
			sampAddChatMessage('[R] ' .. rang .. ' {' .. donateNicksServer[nick] .. '}' .. nick ..'{33CC66}['.. id .. ']: ' .. texts, bit.rshift(color, 8))
			return false
		end
	elseif string.find(text,'^%[F%] .+ .-%[%d+%]:') and donateNicksServer ~= nil and ini.Prefs.pref14 then
		local rang, nick, id, texts = string.match(text, '^%[F%] (.+) (.-)%[(%d+)%]: (.*)')
		if donateNicksServer[nick] then
			sampAddChatMessage('[F] ' .. rang .. ' {' .. donateNicksServer[nick] .. '}' .. nick ..'{6699CC}['.. id .. ']: ' .. texts, bit.rshift(color, 8))
			return false
		end
	elseif dialogLift and text == 'Лифт занят' then
		dialogLift = false
		sampSendChat("/do Лифт занят.")
		return false
	elseif color == 1724645631 then 
		local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
		if text:match('%[E%] .+ ' .. sampGetPlayerNickname(id) .. '%[' .. id .. '%] подключился к эфиру') then 
			RPefir = true
			efirTime = os.time()
		end
	elseif color == -10092289 then
		local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
		if text:match('%[E%] .+ ' .. sampGetPlayerNickname(id) .. '%[' .. id .. '%] отключился от эфира') then
			RPefir = false
			if efirTime then
				sampAddChatMessage(os.date("{3399FF}[MM Editor]:{CECECE} Ваш эфир продлился %M мин и %S сек!", os.time() - efirTime), 0xCECECE)
			end
			efirTime = nil
		end
	elseif color == -10046721 then
		--printStringNow(text:match('SMS: .* | Отправитель: [a-zA-Z_]+ %[т.(%d+)%]$'), 2000)
		local sms = {}
		sms['text'] = text:match('SMS: (.*) | Отправитель: .* %[т.%d+%]$')
		sms['number'] = text:match('SMS: .* | Отправитель: .* %[т.(%d+)%]$')
		sms['name'] = text:match('SMS: .* | Отправитель: (.*) %[т.%d+%]$')
		sms['time'] = os.time()
		table.insert(smsTable, sms)
	elseif color == -65281 and text:match('.* позвонил на радио. Вывести в эфир: /bring (%d+)') and RPefir then
		callTable[tonumber(text:match('.* позвонил на радио. Вывести в эфир: /bring (%d+)'))] = true
	elseif color == -65281 and text:match('.*%[(%d+)%] был {00cc66}подключен {FFFF00}к радиоцентру работником .*%[%d+%]') and RPefir then
		callTime = os.time()
		callerID = tonumber(text:match('.*%[(%d+)%] был {00cc66}подключен {FFFF00}к радиоцентру работником .*%[%d+%]'))
	elseif color == -65281 and (text:match('.*%[(%d+)%] был {ff6600}отключён {FFFF00}от радиоцентра работником .*%[%d+%]') or text:match('.*%[(%d+)%] покидает прямой эфир')) and RPefir then
		callTime = null
		callerID = -1
	elseif color == -65281 and text:match('^Поздравляем! {.-}Вы устроились') then
		isWorkHero = true
	end
end

function join_argb(a, r, g, b)
    local argb = b  -- b
    argb = bit.bor(argb, bit.lshift(g, 8))  -- g
    argb = bit.bor(argb, bit.lshift(r, 16)) -- r
    argb = bit.bor(argb, bit.lshift(a, 24)) -- a
    return argb
end

function sampev.onSendDialogResponse(dialogId, button, listboxId, input)
	if stepSetting == 2 then
		stepSetting = 3
	end
end

function sampev.onSendChat(text)
	if RPefir and text:sub(1,1) ~= '/' and ini.Prefs.pref12 then
		sampSendChat('/t ' .. text)
		return false
	end
end

function sampev.onInitGame()
	local ip, _ = sampGetCurrentServerAddress()
	if lastip ~= nil then
		if not string.find(ip,lastip) then
			thisScript():reload()
		end
	end
end

function msgscript(var)
	sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} " .. var, 0xCECECE)
end

function blackdownload(notif)
	if urlblacklist == '' then
		if notif then
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} ЧС СМИ не подключен к форуму. Обратитесь к разработчику (для управляющих СМИ).", 0xCECECE)
		end
		blacklistactive = false
		return
	end
	if notif then
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Начинаем обновлять ЧС СМИ. Ожидайте...", 0xCECECE)
	end
	local fpath = os.getenv('TEMP') .. '\\blacklist.txt'
	local resb, f = downloadMaster(urlblacklist, fpath, true, true)
	if resb then
		local f = string.match(f,'<body.->(.*)</body>')
		if string.find(f,"MM1END") then
			blacklisttext = ''
			local fileblack = io.open("moonloader\\Mass Media Editor\\blacklist.txt", 'w')
			for i = 1, 5 do
				if string.find(f,"MM" .. i .."END") and string.find(f,"MM" .. i) then
					local mmtext = string.gsub(string.gsub(string.sub(f, string.find(f, 'MM' .. i), string.find(f,'MM' .. i .. 'END')), '<.->', ''), ' ', '_')
					blacklisttext = blacklisttext .. mmtext
					fileblack:write(mmtext)
				else
					break
				end
			end
			fileblack:close()
			if notif then
				sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Файл черного списка успешно обновлён.", 0xCECECE)
			end
			
			blacklistactive = true
			blockButton.blacklist = false
		else
			blacklistactive = false
			blockButton.blacklist = false
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Тема ЧС СМИ не настроена, или форум не доступен.", 0xCECECE)
		end
	else
		blacklistactive = false
		blockButton.blacklist = false
		sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Форум не доступен или тема ЧС СМИ удалена.", 0xCECECE)
		print(f)
	end
end

function checkblacklist()
	local f = io.open('moonloader\\Mass Media Editor\\blacklist.txt','r')
	blacklisttext = f:read('*a')
	f:close()
	lua_thread.create(function ()
		sampSendChat("/me доста" .. Sex1Hero .. " планшет")
		wait(1200)
		sampSendChat("/me заш" .. Sex3Hero .. " в базу данных СМИ")
		wait(1200)
		sampSendChat("/me проверяет имя " .. TargetName .. " на наличие в ЧС СМИ")
		wait(1200)
		if string.find(blacklisttext,nameTarget) then
			sampSendChat("/do Результат: " .. TargetName .. " находится в чёрном списке СМИ.")
			wait(100)
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Игрок состоит в черном списке СМИ.", 0xCECECE)
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Строка из ЧС: " .. string.gsub(string.sub(u8:decode(blacklisttext), string.find(u8:decode(blacklisttext), nameTarget .. '.-\n')), '_', ' '), 0xCECECE)
			return
		else
			sampSendChat("/do Результат: " .. TargetName .. " не находится в чёрном списке СМИ.")
			wait(100)
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Игрок не состоит в черном списке СМИ. Проверяем историю ников...", 0xCECECE)
			wait(500)
		end
		sampSendChat("/history " .. nameTarget)
		blaclistdo = {}
		dialogHistoryOpen = true
	end)
end

function blcheck(nickname)
	if (string.find(blacklisttext, nickname)) then
		blaclistdo[#blaclistdo + 1] = {nick = nickname, stats = u8("Состоит"), line = string.gsub(string.sub(blacklisttext, string.find(blacklisttext, nickname .. '.-\n')), '_', ' ')}
	else
		blaclistdo[#blaclistdo + 1] = {nick = nickname, stats = u8("Не состоит")}
	end
end

function savedColorNick()
	if saveCOLOR then
		--вырезано
	else
		printStringNow('CHANGE THE COLOR!', 1500)
	end
end

function windows_mmeditor()
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(700*global_scale.v, 402*global_scale.v)) 
	imgui.Begin('Mass Media Editor (' .. ServerHero .. ')', window_states['main'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
	imgui.BeginChild('main_window1', imgui.ImVec2(150*global_scale.v, 365*global_scale.v), true)
	imgui.TextColored(imgui.ImVec4(1, 0.6, 0.2, 1.0), u8'>>Главный раздел')
	for i = 1, 5 do
		imgui.PushID(i)
		if imgui.Selectable(u8(array_windows_mmeditor[i]), selectedm == i, imgui.SelectableFlags.SpanAllColumns) then
			lastselected = selectedm
			selectedm = i
		end
		imgui.PopID()
	end
	imgui.TextColored(imgui.ImVec4(1, 0.6, 0.2, 1.0), u8'\n>>Настройки')
	for i = 6, 11 do
		imgui.PushID(i)
		if imgui.Selectable(u8(array_windows_mmeditor[i]), selectedm == i, imgui.SelectableFlags.SpanAllColumns) then
			lastselected = selectedm
			selectedm = i
			if selectedm == 6 then
				for i = 1, #prefTable do
					prefBools['pref' .. i].v = ini.Prefs['pref' .. i]
				end
				for i = 1, #efirsetTable do
					efirBools['pref' .. i] = imgui.ImBool(ini.Efir['pref' .. i])
				end
				r_buffer.v = u8(ini.Tags.r)
				f_buffer.v = u8(ini.Tags.f)
			elseif selectedm == 7 then
				imgui.GetIO().KeysDown[19] = false
				choiceNum = 0
			elseif selectedm == 8 then
				styleWindowOpen = true
				if listDonators ~= nil then
					if SumHero >= 130 then
						local a, r, g, b = explode_argb('0x'.. donateNicksServer[PlayerNickHero])
						colorNICK = imgui.ImFloat3(r/255, g/255, b/255)
						saveCOLOR = nil
					end
				end
			elseif selectedm == 9 then
				quest_buffer = imgui.ImBuffer(u8(ini[questionTypesFull[comboQuestionType.v + 1]][questionTypes[comboQuestionType.v + 1] .. comboQuestion.v + 1]), 128)
			end
		end
		imgui.PopID()
	end
	imgui.TextColored(imgui.ImVec4(1, 0.6, 0.2, 1.0), u8'\n>>Информация')
	for i = 12, 14 do
		imgui.PushID(i)
		if imgui.Selectable(u8(array_windows_mmeditor[i]), selectedm == i, imgui.SelectableFlags.SpanAllColumns) then
			lastselected = selectedm
			selectedm = i
		end
		imgui.PopID()
	end
	imgui.EndChild()
	imgui.SameLine()
	imgui.BeginChild('main_window2', imgui.ImVec2(530*global_scale.v, 370*global_scale.v), false)
	if selectedm == 1 then
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"MM Editor v" .. thisScript().version .. u8" приветствует Вас, " .. PlayerNameHero .. "!").x / 2)
		imgui.TextColored(imgui.ImVec4(1, 0.6, 0.2, 1.0), u8"MM Editor v" .. thisScript().version .. u8" приветствует Вас, " .. PlayerNameHero .. "!")
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"В данном окне содержатся новости СМИ и скрипта").x / 2)
		imgui.Text(u8'В данном окне содержатся новости СМИ и скрипта')
		imgui.Separator()
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Сообщение разработчика:").x / 2)
		imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8"Сообщение разработчика:")
		imgui.Separator()
		imgui.BeginChild('upds1', imgui.ImVec2(530*global_scale.v,120*global_scale.v))
		for str in string.gmatch(msgdev, '.-\n') do
			imgui.TextWrapped(str)
		end
		imgui.EndChild()
		imgui.Separator()
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Новости от управляющего СМИ " .. LastChangeName .. " (" .. MainmsgTime .."):").x / 2)
		imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8"Новости от управляющего СМИ " .. LastChangeName .. " (" .. MainmsgTime .."):")
		imgui.Separator()
		imgui.BeginChild('msgbymm', imgui.ImVec2(530*global_scale.v,125*global_scale.v))
		for str in string.gmatch(Mainmsg .. '\n', '.-\n') do
			imgui.TextWrapped(str)
		end
		imgui.EndChild()
		imgui.Spacing()
		if imgui.Button(u8'Открыть раздел СМИ ' .. ServerHero .. u8' сервера',imgui.ImVec2(-0.1, 0)) then
			os.execute('explorer "' .. urlServer ..'"')
		end
	elseif selectedm == 2 then
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"В данном окне отображается статус скрипта.").x / 2)
		imgui.Text(u8'В данном окне отображается статус скрипта.')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Здесь можно найти настройки и информацию Вашего сервера").x / 2)
		imgui.Text(u8'Здесь можно найти настройки и информацию Вашего сервера')
		imgui.Spacing()
		imgui.Separator()
		imgui.Spacing()
		imgui.Indent(60*global_scale.v)
		imgui.Text('AutoEdit:')
		imgui.SameLine()
		if AutoEditdev then
			imgui.TextColored(imgui.ImVec4(0,1,0,1),u8'включен')
		else
			imgui.TextColored(imgui.ImVec4(1.0, 0.38, 0.38, 1.0),u8'отключен')
		end
		imgui.SameLine(350*global_scale.v)
		imgui.Text(u8'Законки:')
		imgui.SameLine()
		imgui.TextColored(imgui.ImVec4(0,1,0,1),sobesZakon)
		imgui.Text(u8'Ловля:')
		imgui.SameLine()
		if editdev then
			imgui.TextColored(imgui.ImVec4(0,1,0,1),u8'включена')
		else
			imgui.TextColored(imgui.ImVec4(1.0, 0.38, 0.38, 1.0),u8'отключена')
		end
		imgui.SameLine(350*global_scale.v)
		imgui.Text(u8'Уровень:')
		imgui.SameLine()
		imgui.TextColored(imgui.ImVec4(0,1,0,1),sobesLVL)
		imgui.Unindent(60*global_scale.v)
		imgui.Spacing()
		imgui.Separator()
		imgui.Spacing()
		imgui.SetCursorPosX(265*global_scale.v - imgui.CalcTextSize(u8"Возможность управлющего СМИ отправлять новости: отключена").x / 2)
		imgui.Text(u8'Возможность управлющего СМИ отправлять новости:')
		imgui.SameLine()
		if MMEditMSG then
			imgui.TextColored(imgui.ImVec4(0,1,0,1),u8'включена')
		else
			imgui.TextColored(imgui.ImVec4(1.0, 0.38, 0.38, 1.0),u8'отключена')
		end
		imgui.Spacing()
		imgui.Separator()
		imgui.Spacing()
		imgui.SetCursorPosX(265*global_scale.v - imgui.CalcTextSize(u8"Текст ошибки при отключенной ловле/AutoEdit:").x / 2)
		imgui.Text(u8'Текст ошибки при отключенной ловле/AutoEdit:')
		imgui.SetCursorPosX(265*global_scale.v - imgui.CalcTextSize(u8(msgedit)).x / 2)
		imgui.TextColored(imgui.ImVec4(1, 0.6, 0.2, 1.0), u8(msgedit))
		imgui.Spacing()
		imgui.Separator()
		imgui.SetCursorPosX(265*global_scale.v - imgui.CalcTextSize(u8'Последнее обновление устава (хостинг): ' .. dataYst).x / 2)
		imgui.Text(u8'\n\n\n\n\nПоследнее обновление устава (хостинг): ' .. dataYst)
		imgui.SetCursorPosX(265*global_scale.v - imgui.CalcTextSize(u8'Последнее обновление ПРО (хостинг): ' .. dataPro).x / 2)
		imgui.Text(u8'Последнее обновление ПРО (хостинг): ' .. dataPro)
		imgui.SetCursorPosX(265*global_scale.v - imgui.CalcTextSize(u8'Последнее обновление ППЭ (хостинг): ' .. dataPpo).x / 2)
		imgui.Text(u8'Последнее обновление ППЭ (хостинг): ' .. dataPpo)
	elseif selectedm == 3 then
		selected_3()
	elseif selectedm == 4 then
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Так как скрипт разрабатывается на бесплатной основе,").x / 2)
		imgui.Text(u8'\nТак как скрипт разрабатывается на бесплатной основе,')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Вы можете поддержать его разработку и при этом получить цвет ника! ([F][R])").x / 2)
		imgui.Text(u8'Вы можете поддержать его разработку и при этом получить цвет ника! ([F][R])')
		imgui.Separator()
		imgui.Spacing()
		imgui.SetCursorPosX(100*global_scale.v - imgui.CalcTextSize(u8"Цвет ника").x / 2)
		imgui.TextColoredRGB('{ffb833}Цвет ника')
		imgui.SameLine()
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Цвет ника").x / 2)
		imgui.TextColoredRGB('{ffa500}Цвет ника')
		imgui.SameLine()
		imgui.SetCursorPosX(424*global_scale.v - imgui.CalcTextSize(u8"Цвет ника").x / 2)
		imgui.TextColoredRGB('{ff6666}Цвет ника')
		imgui.SetCursorPosX(100*global_scale.v - 150*global_scale.v / 2)
		if imgui.Button(u8'Проверить ник #1', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			testnick('fff099')
		end
		imgui.SameLine()
		imgui.SetCursorPosX(262*global_scale.v - 150*global_scale.v / 2)
		if imgui.Button(u8'Проверить ник #2', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			testnick('ffb833')
		end
		imgui.SameLine()
		imgui.SetCursorPosX(424*global_scale.v - 150*global_scale.v / 2)
		if imgui.Button(u8'Проверить ник #3', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			testnick('ff6666')
		end
		imgui.SetCursorPosX(100*global_scale.v - imgui.CalcTextSize(u8"20р/навсегда").x / 2)
		imgui.TextColoredRGB('{b3b3b3}20р/навсегда')
		imgui.SameLine()
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"35р/навсегда").x / 2)
		imgui.TextColoredRGB('{b3b3b3}35р/навсегда')
		imgui.SameLine()
		imgui.SetCursorPosX(424*global_scale.v - imgui.CalcTextSize(u8"60р/навсегда").x / 2)
		imgui.TextColoredRGB('{b3b3b3}60р/навсегда')
		imgui.Spacing()
		imgui.Separator()
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"'В дополнение: с любой суммы Вы сможете отключать цвет ников в чате.").x / 2)
		imgui.Text(u8'В дополнение: с любой суммы Вы сможете отключать цвет ников в чате.')
		imgui.TextColoredRGB('{ba66ff}Ник выбранного Вами цвета (почти любого) доступен со 130 рублей.',2)
		imgui.Separator()
		imgui.Spacing()
		imgui.TextColoredRGB('Как получить:\n{ffffff}В комментарии укажите {ffd700}номер аккаунта и сервер{ffffff} (если не указано!)', 2)
		imgui.Spacing()
		imgui.SetCursorPosX(262*global_scale.v - 150*global_scale.v / 2 - 150*global_scale.v / 2 - imgui.CalcTextSize(u8" или ").x / 2)
		if imgui.Button(u8'Yandex Money', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			
		end
		-- https://yoomoney.ru/quickpay/confirm.xml?receiver=410019014512803&quickpay-form=shop&targets=Sponsor%20this%20project&paymentType=SB&sum=150
		imgui.SameLine()
		imgui.Text(u8' или ')
		imgui.SameLine()
		if imgui.Button(u8'Qiwi Wallet', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			
		end
		imgui.Spacing()
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"После оплаты доната в 130р, пришлите цвет ника сюда:").x / 2)
		imgui.Text(u8'После оплаты доната в 130р, пришлите цвет ника сюда:')
		imgui.Spacing()
		imgui.SetCursorPosX(262*global_scale.v - 150*global_scale.v / 2)
		if imgui.Button(u8'Написать', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			
		end
		imgui.Spacing()
		imgui.Separator()
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Также Вы будете указаны в благодарственном списке в разделе информации").x / 2)
		imgui.Text(u8'Также Вы будете указаны в благодарственном списке в разделе информации')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Цвет ника будет виден у игроков со скриптом").x / 2)
		imgui.Text(u8'Цвет ника будет виден у игроков со скриптом')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Один ник - один аккаунт. Суммы донатов накапливаются.").x / 2)
		imgui.Text(u8'Один ник - один аккаунт. Суммы донатов накапливаются.')
	elseif selectedm == 5 then
		os.execute('explorer "' .. thisScript().url ..'"')
		selectedm = lastselected
	elseif selectedm == 6 then
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Здесь Вы можете включить или выключить отыгровки и ещё кое-что").x / 2)
		imgui.Text(u8'Здесь Вы можете включить или выключить отыгровки и ещё кое-что')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Для подробностей наведите мышку на текст").x / 2)
		imgui.Text(u8'Для подробностей наведите мышку на текст')
		imgui.Separator()
		imgui.Spacing()
		imgui.BeginGroup()
		for l = 1, 8 do
			imgui.AlignTextToFramePadding()
			imgui.Text(u8(prefTable[l]))
			if imgui.IsItemHovered() then 
				imgui.SetTooltip(u8(prefTable_info[l])) 
			end
			imgui.SameLine(250*global_scale.v)
			imgui.ToggleButton("Test#s#" .. l, prefBools['pref' .. l])
		end
		imgui.EndGroup()
		imgui.SameLine()
		imgui.BeginGroup()
		for l = 9, 14 do
			imgui.AlignTextToFramePadding()
			imgui.Text(u8(prefTable[l]))
			if imgui.IsItemHovered() then 
				imgui.SetTooltip(u8(prefTable_info[l])) 
			end
			imgui.SameLine(200*global_scale.v)
			if imgui.ToggleButton("Test#s#" .. l, prefBools['pref' .. l]) and l == 14 and not donateNicksServer[PlayerNickHero] then
				prefBools['pref14'].v = true
				msgscript('Отключить могут только те, кто поддержал скрипт.')
			end
		end
		imgui.EndGroup()
		imgui.Separator()
		imgui.BeginGroup()
		for l = 1, 2 do
			imgui.AlignTextToFramePadding()
			imgui.Text(u8(efirsetTable[l]))
			if imgui.IsItemHovered() then 
				imgui.SetTooltip(u8(prefTable_info[l + #prefTable])) 
			end
			imgui.SameLine(250*global_scale.v)
			imgui.ToggleButton("Test#ss#" .. l, efirBools['pref' .. l])
		end
		imgui.EndGroup()
		imgui.SameLine()
		imgui.BeginGroup()
		for l = 3, 4 do
			imgui.AlignTextToFramePadding()
			imgui.Text(u8(efirsetTable[l]))
			if imgui.IsItemHovered() then 
				imgui.SetTooltip(u8(prefTable_info[l + #prefTable])) 
			end
			imgui.SameLine(200*global_scale.v)
			imgui.ToggleButton("Test#ss#" .. l, efirBools['pref' .. l])
		end
		imgui.EndGroup()
		imgui.Separator()
		imgui.Spacing()
		imgui.PushItemWidth(150*global_scale.v)
		imgui.SetCursorPosX(121*global_scale.v - 150*global_scale.v / 2)
		imgui.InputText(u8'Тэг /r', r_buffer)
		imgui.SameLine()
		imgui.SetCursorPosX(383*global_scale.v - 150*global_scale.v / 2)
		imgui.InputText(u8'Тэг /f', f_buffer)
		imgui.PopItemWidth()
		imgui.Spacing()
		imgui.SetCursorPosX(262*global_scale.v - 150*global_scale.v / 2)
		if imgui.Button(u8'Сохранить', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			for i = 1, #prefTable do
				ini.Prefs['pref' .. i] = prefBools['pref' .. i].v
			end
			for i = 1, #efirsetTable do
				ini.Efir['pref' .. i] = efirBools['pref' .. i].v
			end
			ini.Tags.f = u8:decode(f_buffer.v)
			ini.Tags.r = u8:decode(r_buffer.v)
			ok = inicfg.save(ini, './MME/setting.ini')
			if ok then
				printStringNow('SAVED!', 1500)
			else
				printStringNow('ERROR!', 1500)
			end
		end
	elseif selectedm == 7 then
		selected_7()
	elseif selectedm == 8 then
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Изменение шрифта и размера окон").x / 2)
		imgui.Text(u8'Изменение шрифта и размера окон')
		if listDonators ~= nil then
			if SumHero >= 130 then
				imgui.TextColoredRGB('{99ff99}А для тебя можно ещё изменить цвет ника (раз в день)', 2)
			end
		end
		imgui.Separator()
		imgui.Spacing()
		imgui.PushItemWidth(320*global_scale.v)
		imgui.SetCursorPosX(262*global_scale.v - (320*global_scale.v + imgui.CalcTextSize(u8"Размеры окон и шрифта").x) / 2)
		if imgui.SliderFloat(u8"Размеры окон и шрифта", global_scale_slider, 1.0, 2) then
			if (global_scale_slider.v >= 1.0 and global_scale_slider.v <= 2.0) then
				global_scale.v = global_scale_slider.v
				lua_thread.create(function()
					wait(0)
					apply_custom_style()
				end)
			end
		end
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Подсказка: в ползунок можно ввести число от 1 до 2, нажав на него CTRL + ЛКМ.").x / 2)
		imgui.Text(u8'Подсказка: в ползунок можно ввести число от 1 до 2, нажав на него CTRL + ЛКМ.')
		imgui.SetCursorPosX(262*global_scale.v - 150*global_scale.v / 2 - 150*global_scale.v / 2)
		if imgui.Button(u8'Сохранить', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			ini.Look.scale = global_scale.v
			ok = inicfg.save(ini, './MME/setting.ini')
			if ok then
				printStringNow('SAVED!', 1500)
			else
				printStringNow('ERROR!', 1500)
			end
		end
		imgui.SameLine()
		if imgui.Button(u8'Восстановить', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			global_scale_slider.v = 1.0
			global_scale.v = global_scale_slider.v
			lua_thread.create(function()
				wait(0)
				apply_custom_style()
			end)
			ini.Look.scale = global_scale.v
			ok = inicfg.save(ini, './MME/setting.ini')
			if ok then
				printStringNow('SAVED!', 1500)
			else
				printStringNow('ERROR!', 1500)
			end
		end
		imgui.Spacing()
		imgui.Separator()
		if listDonators ~= nil then
			if SumHero >= 130 then
				imgui.Spacing()
				imgui.TextColoredRGB('Нажмите на цветной квадратик, чтобы открыть палитру цветов',2)
				imgui.TextColoredRGB('Установлены ограничения на некоторые цвета',2)
				imgui.SetCursorPosX(100*global_scale.v)
				if imgui.ColorEdit3(u8'цвет ника', colorNICK) then
					local clr = join_argb(0, colorNICK.v[1] * 255, colorNICK.v[2] * 255, colorNICK.v[3] * 255)
					saveCOLOR = ('%06X'):format(clr)
					local r, g, b = hex2rgb(saveCOLOR)
					if (r < 50 and g < 50) or (r < 50 and b < 50) or (g < 50 and b < 50) then 
						colorIsTrue = false 
					else 
						colorIsTrue = true 
					end
				end
				imgui.Spacing()
				imgui.SetCursorPosX(262*global_scale.v - (150*global_scale.v + 150*global_scale.v)/2)
				if imgui.Button(u8'Проверить', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
					if saveCOLOR then
						testnick(saveCOLOR)
					else
						printStringNow('CHANGE THE COLOR!', 1500)
					end
				end
				imgui.SameLine()
				if (blockButton.color or not saveCOLOR or not colorIsTrue) then
					if imgui.CustomButton(u8'Сохранить цвет', imgui.ImVec4(0.5, 0.5, 0.5, 1.0), imgui.ImVec4(0.5, 0.5, 0.5, 1.0), imgui.ImVec4(0.5, 0.5, 0.5, 1.0), imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
					end
				else
					if imgui.Button(u8'Сохранить цвет', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
						savedColorNick()
					end
				end
			end
		end
	elseif selectedm == 9 then
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Настройки лекций, гос. новостей").x / 2)
		imgui.Text(u8'Настройки лекций, гос. новостей')
		imgui.Separator()
		imgui.Spacing()
		imgui.SetCursorPosX(262*global_scale.v - 150*global_scale.v / 2)
		if imgui.Button(u8'Меню лекций', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			window_states['main'].v = false
			loadlec()
			window_states['editlec'].v = true
			lastselected = selectedm
		end
		imgui.Spacing()
		imgui.SetCursorPosX(262*global_scale.v - 150*global_scale.v / 2)
		if imgui.Button(u8'Меню гос. новостей', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			window_states['main'].v = false
			loadgos()
			window_states['m'].v = true
			lastselected = selectedm
		end
		imgui.Spacing()
		imgui.Separator()
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Вопросы для экзаменов").x / 2)
		imgui.Text(u8'Вопросы для экзаменов')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Сохраняйте каждый отредактированный вопрос").x / 2)
		imgui.Text(u8'Сохраняйте каждый отредактированный вопрос')
		imgui.Separator()
		imgui.Spacing()
		imgui.PushItemWidth(150*global_scale.v)
		imgui.SetCursorPosX(131*global_scale.v - 150*global_scale.v / 2)
		if imgui.Combo('                    ', comboQuestionType, u8'Устав СМИ\0ПРО\0ППЭ\0\0') then
			quest_buffer = imgui.ImBuffer(u8(ini[questionTypesFull[comboQuestionType.v + 1]][questionTypes[comboQuestionType.v + 1] .. comboQuestion.v + 1]), 128)
		end
		imgui.SameLine(0, 148*global_scale.v)
		imgui.SetCursorPosX(393*global_scale.v - 150*global_scale.v / 2)
		if imgui.Combo('                          ', comboQuestion, u8'Вопрос 1\0Вопрос 2\0Вопрос 3\0Вопрос 4\0Вопрос 5\0Вопрос 6\0Вопрос 7\0Вопрос 8\0Вопрос 9\0\0') then
			quest_buffer = imgui.ImBuffer(u8(ini[questionTypesFull[comboQuestionType.v + 1]][questionTypes[comboQuestionType.v + 1] .. comboQuestion.v + 1]), 128)
		end
		imgui.PopItemWidth()
		imgui.Spacing()
		imgui.PushItemWidth(466*global_scale.v)
		imgui.SetCursorPosX(262*global_scale.v - 466*global_scale.v / 2)
		if imgui.InputText('          dzqi', quest_buffer) then
			
		end
		imgui.PopItemWidth()
		imgui.Spacing()
		imgui.SetCursorPosX(262*global_scale.v - 150*global_scale.v / 2)
		if imgui.Button(u8'Сохранить', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			ini[questionTypesFull[comboQuestionType.v + 1]][questionTypes[comboQuestionType.v + 1] .. comboQuestion.v + 1] = u8:decode(quest_buffer.v)
			ok = inicfg.save(ini, './MME/setting.ini')
			if ok then
				printStringNow('SAVED!', 1500)
			else
				printStringNow('ERROR!', 1500)
			end
		end
	elseif selectedm == 10 then
		window_states['main'].v = false
		loadgos()
	elseif selectedm == 11 then
		window_states['main'].v = false
		window_states['editRP'].v = true
	elseif selectedm == 12 then
		if listDonators ~= nil then
			imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Здесь перечислены игроки, которые поддержали разработку скрипта").x / 2)
			imgui.TextColored(imgui.ImVec4(1, 0.6, 0.2, 1.0),u8'Здесь перечислены игроки, которые поддержали разработку скрипта')
			imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Спасибо им!").x / 2)
			imgui.TextColored(imgui.ImVec4(0,1,0,1),u8'Спасибо им!')
			imgui.Separator()
			imgui.BeginChild('upds3w2', imgui.ImVec2(532*global_scale.v,300*global_scale.v))
			for i = 1, #listDonators do
				imgui.TextColoredRGB('{'.. listDonators[i].color ..'}' .. listDonators[i].nick .. '{ffffff} ('.. listDonators[i].server ..') поддержал развитие скрипта. {ffd700}Спасибо!')
			end
			imgui.EndChild()
			if imgui.Button(u8'Не так сложно стать в их числе :)', imgui.ImVec2(btn_size)) then
				selectedm = 4
			end
		else
			imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Раздел временно не доступен").x / 2)
			imgui.TextColored(imgui.ImVec4(1, 0.6, 0.2, 1.0),u8'Раздел временно не доступен')
		end
	elseif selectedm == 13 then
		window_states['main'].v = false
		window_states['pravila'].v = true
	elseif selectedm == 14 then
		--imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8()).x / 2)
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize("Mass Media Editor Lua v" .. thisScript().version).x / 2)
		imgui.TextColored(imgui.ImVec4(1, 0.6, 0.2, 1.0), "Mass Media Editor Lua v" .. thisScript().version)
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('Разработчик: Skelmer (Igor Novikov #Green)')).x / 2)
		imgui.TextColoredRGB('{00bfff}Разработчик:{ffffff} Skelmer (Igor Novikov #Green)')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('Некоторые функции взяты на форуме blast.hk')).x / 2)
		imgui.TextColoredRGB('{b3b3b3}Некоторые функции взяты на форуме blast.hk')
		imgui.Separator()
		imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 2))
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('Mass Media Editor (MM Editor) - универсальный скрипт сотрудников СМИ')).x / 2)
		imgui.TextColoredRGB('{00bfff}Mass Media Editor{ffffff} (MM Editor) - универсальный скрипт сотрудников СМИ')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('разрабатываемый с 23 февраля 2017 года человеком с ником Memento Mori.')).x / 2)
		imgui.TextColoredRGB('{ffffff}разрабатываемый с 23 февраля 2017 года человеком с ником {00bfff}Memento Mori{ffffff}.')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('Изначально скрипт был написан на AutoHotkey, и составлял из себя только шпаргалку,')).x / 2)
		imgui.Text(u8'Изначально скрипт был написан на AutoHotkey, и составлял из себя только шпаргалку,')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('чекер ЧС и ловлю объявлений. За год работы MM Editor AHK обновился более 34 раз с')).x / 2)
		imgui.Text(u8'чекер ЧС и ловлю объявлений. За год работы MM Editor AHK обновился более 34 раз с')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('более 100 изменений и завершил свою работу 1 февраля 2018 года. За этот год')).x / 2)
		imgui.Text(u8'более 100 изменений и завершил свою работу 1 февраля 2018 года. За этот год')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('разработку скрипта поддерживали Emily Lutes и Czar. Спасибо им!')).x / 2)
		imgui.TextColoredRGB('{ffffff}разработку скрипта поддерживали {00bfff}Emily Lutes{ffffff} и {00bfff}Czar{ffffff}. Спасибо им!')
		imgui.PopStyleVar()
		imgui.Spacing()
		imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 2))
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('В декабре 2017 года стал разрабатываться MM Editor на Lua, и его первая версия вышла')).x / 2)
		imgui.Text(u8'В декабре 2017 года стал разрабатываться MM Editor на Lua, и его первая версия вышла')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('15 января 2018 года. Скрипт изначально разрабатывался с Aniki Gasai, который подарил')).x / 2)
		imgui.TextColoredRGB('{ffffff}15 января 2018 года. Скрипт изначально разрабатывался с {00bfff}Aniki Gasai{ffffff}, который подарил')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('скрипту AutoEdit, бинд клавиш и другие функции. Сейчас же MM Editor продолжает')).x / 2)
		imgui.Text(u8'скрипту AutoEdit, бинд клавиш и другие функции. Сейчас же MM Editor продолжает')
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8('разрабатываться и обновляться.')).x / 2)
		imgui.Text(u8'разрабатываться и обновляться.')
		imgui.PopStyleVar()
		imgui.Separator()
		imgui.Indent(20*global_scale.v)
		imgui.TextColoredRGB('{ff9933}Команды: ')
		imgui.SameLine(100*global_scale.v)
		imgui.BeginGroup()
		imgui.TextColoredRGB('{ffff00}/mmeditor{ffffff} - главное меню')
		imgui.TextColoredRGB('{ffff00}/mmblack{ffffff} - меню черного списка')
		imgui.TextColoredRGB('{ffff00}/rr /ff{ffffff} - Non-RP чаты')
		imgui.TextColoredRGB('{ffff00}/gos{ffffff} - гос. новости')
		imgui.TextColoredRGB('{ffff00}/lec{ffffff} - лекции')
		imgui.TextColoredRGB('{ffff00}/uninv{ffffff} - уволить')
		imgui.TextColoredRGB('{ffff00}/autoedit{ffffff} - меню AAEdit')
		imgui.EndGroup()
		imgui.SameLine()
		imgui.BeginGroup()
		imgui.TextColoredRGB('{ffff00}/act{ffffff} - окно взаимодействия')
		imgui.TextColoredRGB('{ffff00}/tvlf{ffffff} - лифт телецентра')
		imgui.TextColoredRGB('{ffff00}/anag{ffffff} - анаграммы')
		imgui.TextColoredRGB('{ffff00}/hist{ffffff} - истории ников по ID')
		imgui.TextColoredRGB('{ffff00}/smsn{ffffff} - Non-RP SMS')
		imgui.TextColoredRGB('{ffff00}/mmefir{ffffff} - меню эфиров')
		imgui.TextColoredRGB('{ffff00}/dauto [text]{ffffff} - тест-команда AAEdit')
		imgui.EndGroup()
	end
	imgui.EndChild()
	imgui.End()
end

function hex2rgb(hex)
    hex = hex:gsub("#","")
    return tonumber("0x"..hex:sub(1,2)), tonumber("0x"..hex:sub(3,4)), tonumber("0x"..hex:sub(5,6))
end

function selected_3()
	imgui.TextColoredRGB('{99ff99}Раньше здесь можно было управлять глобальными настройками скрипта...', 2)
	imgui.TextColoredRGB('{99ff99}Теперь только новости. Их можно увидеть в главном меню скрипта.', 2)
	imgui.Spacing()
	imgui.Separator()
	if res3 then
		if MMEditMSG then
			imgui.Spacing()
			imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Введите новости СМИ, они отобразятся в главном окне").x / 2)
			imgui.Text(u8'Введите новости СМИ, они отобразятся в главном окне')
			imgui.InputTextMultiline(u8'    НОВОСТИ СМИ', mainMSG_buffer, imgui.ImVec2(520*global_scale.v, 100*global_scale.v))
			imgui.Spacing()
			imgui.SetCursorPosX(262*global_scale.v - 150*global_scale.v / 2)
			imgui.PushID(2)
			if imgui.Button(u8'Сохранить', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				if RangHero == 10 and Podr1Hero == '' then
					window_save = true
					window_states['confirmation'].v = true
				else
					msgscript('Данная функция предназначена для Управляющего СМИ.')
				end
			end
			imgui.PopID()
		else
			imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"На данный момент управление новостями отключено").x / 2)
			imgui.Text(u8'На данный момент управление новостями отключено')
			imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Загружены стандартные настройки").x / 2)
			imgui.Text(u8'Загружены стандартные настройки')
		end
	else
		imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Пользователи Windows XP не могут использовать данную функцию").x / 2)
		imgui.SetCursorPosY(370*global_scale.v / 2)
		imgui.Text(u8'Пользователи Windows XP не могут использовать данную функцию')
	end
end

function testnick(colorr)
	local result, id = sampGetPlayerIdByCharHandle(playerPed)
	sampAddChatMessage('[R] ' .. RangNameHero .. ' {' .. colorr .. '}' .. PlayerNickHero ..'{33CC66}['.. id .. ']: Так будет выглядить мой ник в чате у других игроков', 0x33CC66)
	sampAddChatMessage('[F] ' .. RangNameHero .. ' {' .. colorr .. '}' .. PlayerNickHero ..'{6699CC}['.. id .. ']: Так будет выглядить мой ник в чате у других игроков', 0x6699CC)
end

function selected_7()
	imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Настройка быстрого доступа").x / 2)
	imgui.Text(u8'Настройка быстрого доступа')
	imgui.SetCursorPosX(262*global_scale.v - imgui.CalcTextSize(u8"Не назначайте одинаковые клавиши и не забывайте сохранять").x / 2)
	imgui.Text(u8'Не назначайте одинаковые клавиши и не забывайте сохранять')
	imgui.Separator()
	imgui.Spacing()
	imgui.Indent(55*global_scale.v)
	for j = 1, #keymapTable do
		imgui.Spacing()
		imgui.Text(u8(keymapTable[j]))
		imgui.SameLine(300*global_scale.v)
		if j == choiceNum then
			imgui.TextColored(imgui.ImVec4(1,0,0,1), keysToText(ini['Key' .. j]))
		else
			imgui.TextColored(imgui.ImVec4(1,1,1,1), keysToText(ini['Key' .. j]))
		end
		imgui.SameLine(410*global_scale.v)
		imgui.PushID(j)
		local btn_text = 'Изменить'
		if choiceNum == j then btn_text = 'Сохранить' end
		if imgui.SmallButton(u8(btn_text)) then
			if choiceNum == j then
				choiceNum = 0
			else
				choiceNum = j
				--ini['Key' .. choiceNum] = {}
			end
		end
		imgui.PopID()
	end
	--imgui.Text("Keys down:")
	for i = 0, #imgui.GetIO().KeysDown do
		if imgui.GetIO().KeysDown[i] then
			--imgui.Text(key.id_to_name(i-1) .. ' - ' .. i .. '\n')
			if choiceNum ~= 0 then
				keysCount = 1
				ini['Key' .. choiceNum] = {}
				for k = 0, #imgui.GetIO().KeysDown do
					if (imgui.GetIO().KeysDown[k]) then
						ini['Key' .. choiceNum][keysCount] = k
						keysCount = keysCount + 1
					end
				end
				if (i ~= 19 and i ~= 18 and i ~= 17) then
					choiceNum = 0
				end
			end
		end
	end
	imgui.Spacing()
	imgui.SetCursorPosX(265*global_scale.v - 150*global_scale.v / 2)
	if imgui.Button(u8'Сохранить', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
		choiceNum = 0
		ok = inicfg.save(ini, './MME/setting.ini')
		if ok then
			printStringNow('SAVED!', 1500)
		else
			printStringNow('ERROR!', 1500)
		end
	end
end

function imgui.ToggleButton(str_id, bool)

   local rBool = false

   if LastActiveTime == nil then
      LastActiveTime = {}
   end
   if LastActive == nil then
      LastActive = {}
   end

   local function ImSaturate(f)
      return f < 0.0 and 0.0 or (f > 1.0 and 1.0 or f)
   end
 
   local p = imgui.GetCursorScreenPos()
   local draw_list = imgui.GetWindowDrawList()

   local height = imgui.GetTextLineHeightWithSpacing() + (imgui.GetStyle().FramePadding.y / 2)
   local width = height * 1.55
   local radius = height * 0.50
   local ANIM_SPEED = 0.15

   if imgui.InvisibleButton(str_id, imgui.ImVec2(width, height)) then
      bool.v = not bool.v
      rBool = true
      LastActiveTime[tostring(str_id)] = os.clock()
      LastActive[str_id] = true
   end

   local t = bool.v and 1.0 or 0.0

   if LastActive[str_id] then
      local time = os.clock() - LastActiveTime[tostring(str_id)]
      if time <= ANIM_SPEED then
         local t_anim = ImSaturate(time / ANIM_SPEED)
         t = bool.v and t_anim or 1.0 - t_anim
      else
         LastActive[str_id] = false
      end
   end

   local col_bg
   if imgui.IsItemHovered() then
      col_bg = imgui.GetColorU32(imgui.GetStyle().Colors[imgui.Col.FrameBgHovered])
   else
      col_bg = imgui.GetColorU32(imgui.GetStyle().Colors[imgui.Col.FrameBg])
   end

   draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), col_bg, height * 0.5)
   draw_list:AddCircleFilled(imgui.ImVec2(p.x + radius + t * (width - radius * 2.0), p.y + radius), radius - 1.5, imgui.GetColorU32(bool.v and imgui.GetStyle().Colors[imgui.Col.ButtonActive] or imgui.GetStyle().Colors[imgui.Col.Button]))

   return rBool
end

function selected_MM_send()
	if window_save then
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(530*global_scale.v, 220*global_scale.v)) 
	imgui.Begin(u8"Вы уверены?", nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)
		imgui.SetCursorPosX(265*global_scale.v - imgui.CalcTextSize(u8"Ваш текст новости:").x / 2)
		imgui.Text(u8'Ваш текст новости:')
		imgui.BeginChild('msgbymm1', imgui.ImVec2(520*global_scale.v,140*global_scale.v))
		if mainMSG_buffer.v == '' then
			imgui.Text(u8'Управляющий СМИ ещё не отправлял новостей.')
		else
			for str in string.gmatch(mainMSG_buffer.v .. '\n', '.-\n') do
				imgui.TextWrapped(str)
			end
		end
		imgui.EndChild()
	end
	imgui.Indent(100*global_scale.v)
	if imgui.Button(u8'Отправить', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			-- вырезано
	end
	imgui.SameLine(270*global_scale.v)
	if imgui.Button(u8'Отмена',imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
		window_states['confirmation'].v = false
	end
	imgui.End()
end

--@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function imgui.OnDrawFrame()
	imgui.SetMouseCursor(imgui.MouseCursor.None)
	imgui.ShowCursor = false
	if window_states['loadscript'].v then
		imgui.SetNextWindowPos(imgui.ImVec2(50*global_scale.v,7*resy/10), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
		imgui.SetNextWindowSize(imgui.ImVec2(250*global_scale.v, 30*global_scale.v)) 
		imgui.Begin('Download', nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoFocusOnAppearing)
		imgui.Text(u8(downloadText))
		imgui.End()
	end
	if window_states['main'].v then
		imgui.ShowCursor = true
		windows_mmeditor()
	end
	if window_states['confirmation'].v  then
		imgui.ShowCursor = true
		selected_MM_send()
	end
	if window_states['n'].v then
		imgui.ShowCursor = true
		newsWindow()
	end
	if window_states['m'].v then
		imgui.ShowCursor = true
		newWindow()
	end
	if window_states['pravila'].v then
		imgui.ShowCursor = true
		windows_pravila()
	end
	if editflood then
		imgui.SetNextWindowPos(imgui.ImVec2(50*global_scale.v, 3*resy/4 - 30*global_scale.v/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
		imgui.SetNextWindowSize(imgui.ImVec2(87*global_scale.v, 30*global_scale.v)) 
		imgui.Begin('Editflood', nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoFocusOnAppearing)
		if not sampIsChatInputActive() and not isSampfuncsConsoleActive() and not sampIsDialogActive() and not (window_states['main'].v and selectedm == 7) and not edit_window.v then
			imgui.TextColored(imgui.ImVec4(0.2, 1, 0.2, 1), u8'Идёт ловля!')
		else
			imgui.TextColored(imgui.ImVec4(1, 0.2, 0.2, 1), u8'Идёт ловля!')
		end
		imgui.End()
	end
	if window_states['target'].v then
		imgui.ShowCursor = true
		imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		if Podr1Hero == 'ТВ' then
			if RangHero > 8 then
				imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 220*global_scale.v))
			elseif RangHero > 7 then
				imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 200*global_scale.v))
			elseif RangHero > 6 then
				imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 153*global_scale.v))
			elseif RangHero > 5 then
				imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 130*global_scale.v))
			else
				imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 80*global_scale.v))
			end
		else
			if RangHero > 8 then
				imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 200*global_scale.v))
			elseif RangHero > 7 then
				imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 178*global_scale.v))
			elseif RangHero > 5 then
				imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 130*global_scale.v))
			else
				imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 80*global_scale.v))
			end
		end
		imgui.Begin(u8"Взаимодействие с игроком " .. nameTarget, window_states['target'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
		if RangHero > 5 then
			if imgui.Button(u8'Собеседование',btn_size) then
				next_window = 1
				window_states['target'].v = false
				window_states['target_next'].v = true
			end
			if imgui.Button(u8'Принять экзамен',btn_size) then
				window_states['target'].v = false
				next_window = 5
				window_states['target_next'].v = true
			end
		end
		if imgui.Button(u8'Продать газету',btn_size) then
			if not RPactive then
				window_states['target'].v = false
				RPactive = true
				lua_thread.create(function ()
					if ini.Prefs.pref9 then
						for str in string.gmatch(string.gsub(iniRP[5]['RP'], '\\n', '\n') .. '\n', '.-\n') do
							local str = string.gsub(str, '\n', '')
							if string.match(str, '^%d+$') then
								wait(string.match(str,'(%d+)'))
							else
								local str = string.gsub(str, '{name}', TargetName)
								sampSendChat(str)
							end
						end
					end
					sampSendChat('/sale ' .. idTarget)
					RPactive = false
				end)
			end
		end
		if imgui.Button(u8'Показать удостоверение',btn_size) then
			if not RPactive then
				RPactive = true
				lua_thread.create(function()
				local TargetName = string.gsub(nameTarget, '_', ' ')
				sampSendChat("/me доста" .. Sex1Hero .. " удостоверение, затем предъяви" .. Sex1Hero .. " его " .. TargetName)
				wait(500)
				sampSendChat("/do В документе указано: " .. RangNameHero .. ", " .. PodrHero .. ", №" .. PhoneHero .. ".")
				wait(2000)
				sampSendChat("/me убра" .. Sex1Hero .. " удостоверение")
				RPactive = false
				end)
				window_states['target'].v = false
			end
		end
		if RangHero > 6 and Podr1Hero == 'ТВ' then 
			if imgui.Button(u8'Выдать временный скин',btn_size) then
				mskin_buffer = imgui.ImInt(1)
				window_states['target'].v = false
				next_window = 4
				window_states['target_next'].v = true
			end
		end
		if RangHero > 7 then
			if imgui.Button(u8'Изменить скин',btn_size) then
				if not RPactive then
					RPactive = true
					window_states['target'].v = false
					lua_thread.create(function()
					sampSendChat("/me откры" .. Sex1Hero .. " сумку, после чего доста" .. Sex1Hero .. " оттуда форму")
					wait(800)
					sampSendChat("/me переда" .. Sex1Hero .. " форму сотруднику " .. TargetName)
					wait(800)
					sampSendChat('/changeskin ' .. idTarget)
					RPactive = false
					end)
				end
			end
			if imgui.Button(u8'Уволить (вблизи)',btn_size) then
				uninvite_buffer = imgui.ImBuffer('', 128)
				window_states['target'].v = false
				next_window = 3
				window_states['target_next'].v = true
			end
		end
		if RangHero > 8 then
			if imgui.Button(u8'Изменить ранг',btn_size) then
				window_states['target'].v = false
				next_window = 7
				window_states['target_next'].v = true
			end
		end
		imgui.End()
	end
	if styleWindowOpen and not (window_states['main'].v and selectedm == 8) then
		styleWindowOpen = false
		global_scale.v = ini.Look.scale
		global_scale_slider.v = ini.Look.scale
		lua_thread.create(function()
			wait(0)
			apply_custom_style()
		end)
	end
	if edit_window.v then
		imgui_edit_window()
	end
	if set_window.v then
		imgui_set_window()
	else
		if main_window.v then
			imgui_main_window()
		end
	end
	if window_states['blacklist'].v then
		imgui.ShowCursor = true
		imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
		imgui.SetNextWindowSize(imgui.ImVec2(700*global_scale.v, 400*global_scale.v)) 
		imgui.Begin(u8"История ников игрока " .. nameTarget, window_states['blacklist'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
		imgui.Columns(3, 'xdajs', true)
		imgui.Separator()
		imgui.Text(u8'Ник')
		imgui.SetColumnWidth(-1, 150*global_scale.v)
		imgui.NextColumn()
		imgui.Text(u8'Состояние')
		imgui.SetColumnWidth(-1, 80*global_scale.v)
		imgui.NextColumn()
		imgui.Text(u8'Строка из черного списка')
		imgui.NextColumn()
		imgui.Separator()
		for i = 1, #blaclistdo do
			imgui.Text(blaclistdo[i]['nick'])
	        imgui.NextColumn()
			if string.find(blaclistdo[i]['stats'], u8"Не состоит") then
				imgui.TextColored(imgui.ImVec4(0.4, 1.0, 0.4, 1.0), blaclistdo[i]['stats'])
			else
				imgui.TextColored(imgui.ImVec4(1.0, 0.4, 0.4, 1.0), blaclistdo[i]['stats'])
			end
	        imgui.NextColumn()
			if blaclistdo[i]['line'] ~= nil then
				imgui.TextWrapped(blaclistdo[i]['line'])
			end
			imgui.NextColumn()
		end
		imgui.End()
	end
	if window_states['target_next'].v then
		imgui.ShowCursor = true
		imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		if next_window == 1 then
			imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 270*global_scale.v))
			imgui.Begin(u8"Собеседование с игроком " .. nameTarget, window_states['target_next'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
			if imgui.Button(u8'Приветствие',btn_size) then
				--window_states['interview'].v = false
				local rand = math.random(1, 3)
				lua_thread.create(function ()
				if rand == 1 then
					sampSendChat("Доброго времени суток, я " .. RangNameHero .. " " .. PlayerNameHero .. ". Вы на собеседование?")
				elseif rand == 2 then
					sampSendChat("Приветствую, я " .. RangNameHero .. " " .. PlayerNameHero .. ". Вы на собеседование?")
				elseif rand == 3 then
					sampSendChat("Здравствуйте, я " .. RangNameHero .. " " .. PlayerNameHero .. ". Вы на собеседование?")
				end
			end)
			end
			if imgui.Button(u8'Попросить документы',btn_size) then
				--window_states['interview'].v = false
				if not RPactive then
					RPactive = true
					local rand = math.random(1, 2)
					lua_thread.create(function ()
						if rand == 1 then
							sampSendChat("Не могли бы Вы показать свои документы?")
							wait(1000)
							sampSendChat("Я хоте" .. Sex1Hero .. " бы взглянуть на Ваш паспорт и лицензии.")
						elseif rand == 2 then
							sampSendChat("Могу ли я посмотреть на Ваши документы?")
							wait(1000)
							sampSendChat("Мне нужен Ваш паспорт и лицензии.")
						end
						RPactive = false
					end)
				end
			end
			if imgui.Button(u8'Проверить на ЧС СМИ',btn_size) then
				--window_states['interview'].v = false
				if blacklistactive then
					checkblacklist()
				else
					sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} ЧС СМИ временно не работает или не подключен к форуму.", 0xCECECE)
					sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Обратитесь к разработчику.", 0xCECECE)
				end
			end
			if imgui.Button(u8'Проверить на знание RP (RP чат)',btn_size) then
				--window_states['interview'].v = false
				local rand = math.random(1, 4)
				lua_thread.create(function ()
					if rand == 1 then
						sampSendChat("Сколько Вам лет?")
					elseif rand == 2 then
						sampSendChat("Где Вы живёте?")
					elseif rand == 3 then
						sampSendChat("Как Вы думаете, что такое «ДМ»?")
					elseif rand == 4 then
						sampSendChat("Как Вы думаете, что такое «Скайп»?")
					end
				end)
			end
			if imgui.Button(u8'Проверить на знание RP (Non-RP чат)',btn_size) then
			--	window_states['interview'].v = false
				local rand = math.random(1, 7)
				lua_thread.create(function ()
				if ini.Prefs.pref10 then
					PhoneTerm = ' в /sms ' .. PhoneHero .. ' (( ))'
				else
					PhoneTerm = ''
				end
				if rand == 1 then
					sampSendChat("/n Что такое MG | TK" .. PhoneTerm)
				elseif rand == 2 then
					sampSendChat("/n Что такое PG | DM" .. PhoneTerm)
				elseif rand == 3 then
					sampSendChat("/n Что такое MG | DB" .. PhoneTerm)
				elseif rand == 4 then
					sampSendChat("/n Что такое RP | DB" .. PhoneTerm)
				elseif rand == 5 then
					sampSendChat("/n Что такое IC | MG" .. PhoneTerm)
				elseif rand == 6 then
					sampSendChat("/n Что такое PG | SK" .. PhoneTerm)
				elseif rand == 7 then
					sampSendChat("/n Что такое TK | MG" .. PhoneTerm)
				end
			end)
			end
			if imgui.Button(u8'Выдать трудовой договор',btn_size) then
			--	window_states['interview'].v = false
				if not RPactive then
					RPactive = true
					lua_thread.create(function ()
						for str in string.gmatch(string.gsub(iniRP[1]['RP'], '\\n', '\n') .. '\n', '.-\n') do
							local str = string.gsub(str, '\n', '')
							if string.match(str, '^%d+$') then
								wait(string.match(str,'(%d+)'))
							else
								local str = string.gsub(str, '{name}', TargetName)
								sampSendChat(str)
							end
						end
						RPactive = false
					end)
				end
			end
			if imgui.Button(u8'Принять на работу (с 9 ранга)', btn_size) then
				if RangHero > 8 then
					if not RPactive then
						RPactive = true
						window_states['target_next'].v = false
						lua_thread.create(function ()
							sampSendChat("/do В руках пакет.")
							wait(1000)
							sampSendChat("/do В пакете лежит: форма, рация, бейджик.")
							wait(1000)
							sampSendChat("/me переда" .. Sex1Hero .. " пакет " .. TargetName)
							wait(800)
							sampSendChat("/invite " .. idTarget)
							RPactive = false
						end)
					end
				else
					sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Данная функция доступна с 9 ранга.", 0xCECECE)
				end
			end
			if imgui.Button(u8'Провести инструктаж',btn_size) then
			--	window_states['interview'].v = false
				if not RPactive then
					RPactive = true
					lua_thread.create(function ()
						for str in string.gmatch(string.gsub(iniRP[2]['RP'], '\\n', '\n') .. '\n', '.-\n') do
							local str = string.gsub(str, '\n', '')
							if string.match(str, '^%d+$') then
								wait(string.match(str,'(%d+)'))
							else
								local str = string.gsub(str, '{name}', TargetName)
								sampSendChat(str)
							end
						end
						RPactive = false
					end)
				end
			end
			if imgui.Button(u8'Отказать в трудоустройстве',btn_size) then
				next_window = 2
			end
			imgui.Indent(65*global_scale.v)
			if imgui.Button(u8'Назад',imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				window_states['target_next'].v = false
				window_states['target'].v = true
			end
		elseif next_window == 2 then
			imgui.SetNextWindowSize(imgui.ImVec2(300*global_scale.v, 245*global_scale.v)) 
			imgui.Begin(u8"Выберите причину отказа", window_states['target_next'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
			local TargetName = string.gsub(nameTarget, '_', ' ')
			if imgui.Button(u8'Маленький уровень',btn_size) then
				window_states['target_next'].v = false
				lua_thread.create(function ()
					sampSendChat("Извините, но Вы слишком мало проживаете в нашем штате.")
					wait(900)
					sampSendChat("/n В СМИ можно вступить с " .. sobesLVL .. " уровня.")
				end)
			end
			if imgui.Button(u8'Non-RP ник',btn_size) then
				window_states['target_next'].v = false
				lua_thread.create(function ()
					sampSendChat("Простите, но в вашем паспорте опечатка.")
					wait(900)
					sampSendChat("/n У Вас Non-RP ник.")
				end)
			end
			if imgui.Button(u8'Розыск или маленькая законопослушность',btn_size) then
				window_states['target_next'].v = false
				if not RPactive then
					RPactive = true
					lua_thread.create(function ()
						sampSendChat("/me доста" .. Sex1Hero .. " планшет")
						wait(1200)
						sampSendChat("/me отправи" .. Sex1Hero .. " запрос по паспорту " .. TargetName .. " в МВД")
						wait(1200)
						sampSendChat("/do Ответ получен.")
						wait(1200)
						sampSendChat("Извините, но я не могу Вас принять. Вы не законопослушны.")
						wait(900)
						sampSendChat("/n У Вас розыск или мало законопослушности (Нужно " .. sobesZakon .. "+).")
						RPactive = false
					end)
				end
			end
			if imgui.Button(u8'Незнание RP терминов (RP чат)',btn_size) then
				window_states['target_next'].v = false
				lua_thread.create(function ()
					sampSendChat("Прошу прощения, но Вы бредите. Отрезвейте и приходите нам в другой раз.")
					wait(900)
					sampSendChat("/n Вы не знаете RP термины. Их можно посмотреть на форуме.")
				end)
			end
			if imgui.Button(u8'Незнание RP терминов (Non-RP чат)',btn_size) then
				window_states['target_next'].v = false
				lua_thread.create(function ()
					sampSendChat("/me внимательно посмотре" .. Sex1Hero .. " на " .. TargetName)
					wait(900)
					sampSendChat("Извините, но Вы как-то нездорово выглядите. Сходите к врачу.")
					wait(900)
					sampSendChat("/n Вы не знаете RP термины. Их можно посмотреть на форуме.")
				end)
			end
			if imgui.Button(u8'Варн (с 9 ранга)',btn_size) then
				if RangHero > 8 then
					window_states['target_next'].v = false
					lua_thread.create(function ()
						sampSendChat("/me внимательно посмотре" .. Sex1Hero .. " на " .. TargetName)
						wait(900)
						sampSendChat("Извините, но Вы как-то нездорово выглядите. Сходите к врачу.")
						wait(900)
						sampSendChat("/n У Вас предупреждение (варн). С варном нельзя принять.")
					end)
				else
					sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Данная функция доступна с 9 ранга.", 0xCECECE)
				end
			end
			if imgui.Button(u8'Состоит в черном списке СМИ', btn_size) then
				window_states['target_next'].v = false
				sampSendChat("Извините, Вы нам не подходите, так как состоите в черном списке СМИ.")
			end
			if imgui.Button(u8'Нет прав',btn_size) then
				window_states['target_next'].v = false
				lua_thread.create(function ()
					sampSendChat("Извините, но у Вас нет прав.")
				end)
			end
			imgui.Indent(65*global_scale.v)
			if imgui.Button(u8'Назад',imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				next_window = 1
			end
		elseif next_window == 3 then 
			imgui.SetNextWindowSize(imgui.ImVec2(280*global_scale.v, 120*global_scale.v)) 
			imgui.Begin(u8"Увольнение сотрудника " .. nameTarget, window_states['target_next'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
			imgui.Text(u8'Введите причину увольнения:')
			imgui.PushItemWidth(264*global_scale.v)
			imgui.InputText('       1', uninvite_buffer)
			if imgui.Button(u8'Уволить', btn_size) then
				if uninvite_buffer.v ~= '' then
					if not RPactive then
						RPactive = true
						window_states['target_next'].v = false
						lua_thread.create(function ()
							sampSendChat("/me снял бейджик у сотрудника")
							wait(1000)
							sampSendChat("Рацию и форму сдадите в кабинете")
							wait(500)
							sampSendChat("/r " .. ini.Tags.r .. " Сотрудник " .. TargetName .. " уволен. Причина: " .. u8:decode(uninvite_buffer.v))
							wait(200)
							sampSendChat('/uninvite ' .. idTarget .. ' ' .. u8:decode(uninvite_buffer.v))
							RPactive = false
						end)
					end
				else
					printStringNow('ENTER TEXT!', 1500)
				end
			end
			imgui.Indent(55*global_scale.v)
			if imgui.Button(u8'Назад',imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			   window_states['target_next'].v = false
			   window_states['target'].v = true
			end
		elseif next_window == 4 then
			imgui.SetNextWindowSize(imgui.ImVec2(280*global_scale.v, 120*global_scale.v)) 
			imgui.Begin(u8"Изменение скина " .. nameTarget, window_states['mskin'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
			imgui.Text(u8'Введите номер скина (1-73,75-311):')
			imgui.PushItemWidth(264*global_scale.v)
			if imgui.InputInt('       17', mskin_buffer) then
				if mskin_buffer.v < 1 or mskin_buffer.v == 74 or mskin_buffer.v > 311 then
					mskin_buffer.v = 1
				end
			end
			if imgui.Button(u8'Выдать', btn_size) then
				if not RPactive then
					window_states['target_next'].v = false
					RPactive = true
					lua_thread.create(function ()
						for str in string.gmatch(string.gsub(iniRP[9]['RP'], '\\n', '\n') .. '\n', '.-\n') do
							local str = string.gsub(str, '\n', '')
							if string.match(str, '^%d+$') then
								wait(string.match(str,'(%d+)'))
							else
								local str = string.gsub(str,'{name}',TargetName)
								sampSendChat(str)
							end
						end
						wait(500)
						sampSendChat("/makeskin " .. idTarget .. " " .. mskin_buffer.v)
						RPactive = false
					end)
				end
			end
			imgui.Indent(55*global_scale.v)
			if imgui.Button(u8'Назад',imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
			   window_states['target_next'].v = false
			   window_states['target'].v = true
			end
		elseif next_window == 5 then
			imgui.SetNextWindowSize(imgui.ImVec2(300*global_scale.v, 150*global_scale.v))
			imgui.Begin(u8"Экзамен для сотрудника " .. nameTarget, window_states['target_next'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
			if imgui.Button(u8'Дать листок для экзаменов',btn_size) then
				if not RPactive then
					RPactive = true
					lua_thread.create(function ()
					sampSendChat("/me взя" .. Sex1Hero .. " блокнот")
					wait(1000)
					sampSendChat("/me оторва" .. Sex1Hero .. " лист от блокнота")
					wait(1000)
					sampSendChat("/me переда" .. Sex1Hero .. " ручку и лист " .. TargetName)
					wait(1000)
					sampSendChat("Ответы будете записывать на лист бумаги.")
					wait(1000)
					sampSendChat("/n /do Ответ")
					RPactive = false
					end)
				end
			end
			if imgui.Button(u8'Задать вопрос по Уставу СМИ/ПРО/ППЭ',btn_size) then
				next_window = 6
			end
			if imgui.Button(u8'Одобрить сдачу экзамена',btn_size) then
				window_states['target_next'].v = false
				sampSendChat('Поздравляю, Вы успешно сдали экзамен!')
			end
			if imgui.Button(u8'Отправить на пересдачу',btn_size) then
				window_states['target_next'].v = false
				sampSendChat('К сожалению, Вы провалили экзамен. Приходите на пересдачу')
			end
			imgui.Indent(65*global_scale.v)
			if imgui.Button(u8'Назад',imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				window_states['target_next'].v = false
				window_states['target'].v = true
			end
		elseif next_window == 6 then
			imgui.SetNextWindowSize(imgui.ImVec2(480*global_scale.v, 105*global_scale.v))
			imgui.Begin(u8"Вопросы", window_states['target_next'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
			imgui.PushItemWidth(150*global_scale.v)
			if imgui.Combo('    ', comboQuestionType, u8'Устав СМИ\0ПРО\0ППЭ\0\0') then
				quest_buffer = imgui.ImBuffer(u8(ini[questionTypesFull[comboQuestionType.v + 1]][questionTypes[comboQuestionType.v + 1] .. comboQuestion.v + 1]), 128)
			end
			imgui.SameLine(0, 148*global_scale.v)
			if imgui.Combo('      23', comboQuestion, u8'Вопрос 1\0Вопрос 2\0Вопрос 3\0Вопрос 4\0Вопрос 5\0Вопрос 6\0Вопрос 7\0Вопрос 8\0Вопрос 9\0\0') then
				quest_buffer = imgui.ImBuffer(u8(ini[questionTypesFull[comboQuestionType.v + 1]][questionTypes[comboQuestionType.v + 1] .. comboQuestion.v + 1]), 128)
			end
			imgui.PopItemWidth()
			imgui.SetCursorPosX(240*global_scale.v - imgui.CalcTextSize(quest_buffer.v).x / 2)
			imgui.Text(quest_buffer.v)
			imgui.Indent(75*global_scale.v)
			if imgui.Button(u8'Задать вопрос',imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				sampSendChat(u8:decode(quest_buffer.v))
			end
			imgui.SameLine(245*global_scale.v)
			if imgui.Button(u8'Назад',imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				next_window = 5
			end
		elseif next_window == 7 then
			imgui.SetNextWindowSize(imgui.ImVec2(310*global_scale.v, 125*global_scale.v)) 
			imgui.Begin(u8"Изменения ранга игрока " .. nameTarget, window_states['target_next'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
			if imgui.Button(u8'Отыгровка выдачи бейджика',btn_size) then
				if not RPactive then
					RPactive = true
					lua_thread.create(function()
					sampSendChat("/do В руках новый бейджик.")
					wait(1000)
					sampSendChat("/me переда" .. Sex1Hero .. " бейджик " .. TargetName)
					RPactive = false
					end)
				end
			end
			if imgui.Button(u8'Повысить ранг',btn_size) then
				sampSendChat('/rang ' .. idTarget .. ' +')
			end
			if imgui.Button(u8'Понизить ранг',btn_size) then
				sampSendChat('/rang ' .. idTarget .. ' -')
			end
			imgui.Indent(65*global_scale.v)
			if imgui.Button(u8'Назад',imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				next_window = 5
			end
		end
		imgui.End()
	end
	if window_states['update'].v then
		imgui.ShowCursor = true
		imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
		imgui.SetNextWindowSize(imgui.ImVec2(600*global_scale.v, 230*global_scale.v)) 
		imgui.Begin(u8"Обновление Mass Media Editor", nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)
		imgui.SetCursorPosX(300*global_scale.v - imgui.CalcTextSize(u8"Найдено обновление версии " .. updatever .. u8". Изменения:\n").x / 2)
		imgui.Text(u8"Найдено обновление версии " .. updatever .. u8". Изменения:\n")
		imgui.BeginChild('Saodsd', imgui.ImVec2(586*global_scale.v,130*global_scale.v), true)
		imgui.TextWrapped(updatetext)
		imgui.EndChild()
		imgui.SetCursorPosX(300*global_scale.v - imgui.CalcTextSize(u8"Обновляем?").x / 2)
		imgui.Text(u8"Обновляем?\n")
		imgui.SetCursorPosX(300*global_scale.v - 100*global_scale.v / 2)
		if imgui.Button(u8("Обновляем"), imgui.ImVec2(100*global_scale.v,25*global_scale.v)) then
			sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Начинаем обновлять MM Editor...", 0xCECECE)
			window_states['update'].v = false
			lua_thread.create(function()
			local res = downloadMaster('https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/master/MMEditor.luac',thisScript().path, false, false)
				if res then
					thisScript():reload()
				else
					sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} Произошла ошибка обновления скрипта. Перезагружаемся...", 0xCECECE)
					thisScript():reload()
				end
			end)
		end
		imgui.End()
	end
	if window_states['editRP'].v then
		imgui.ShowCursor = true
		rpEDIT()
	end
	if window_states['editlec'].v then
		imgui.ShowCursor = true
		lecEDIT()
	end
	if window_states['mmblack'].v then
		imgui.ShowCursor = true
		mmblack_window()
	end
	if window_states['efir'].v then
		imgui.ShowCursor = true
		if comboEfir.v == 0 then
			imgui.SetNextWindowSize(imgui.ImVec2(480*global_scale.v, 255*global_scale.v))
		else
			--imgui.SetWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
			imgui.SetNextWindowSize(imgui.ImVec2(480*global_scale.v, 457*global_scale.v))
		end 
		imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.Begin(u8"Управление эфиром", window_states['efir'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
		imgui.PushItemWidth(150*global_scale.v)
		imgui.Combo('        ', comboEfir, u8'Эфир\0Викторина\0\0')
		imgui.PopItemWidth()
		imgui.PushFont(medFont)
		if efirTime then
			imgui.SameLine(195*global_scale.v)
			imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8'ON AIR ' .. os.date('%M:%S', os.time() - efirTime))
		else
			imgui.SameLine(210*global_scale.v)
			imgui.TextColored(imgui.ImVec4(1, 0.5, 0.5, 1.0), u8'OFF AIR')		
		end
		imgui.PopFont()
		imgui.SameLine(320*global_scale.v)
		imgui.PushItemWidth(150*global_scale.v)
		if efirTime then
			if imgui.Button(u8'Отключиться от эфира', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				efiron()
			end
		else
			if imgui.Button(u8'Подключиться к эфиру', imgui.ImVec2(150*global_scale.v, 20*global_scale.v)) then
				efiron()
			end
		end
		local function compare(a, b) return a['score'] > b['score'] end
		--local function compare2(a, b) return scoreTable[a]['score'] > scoreTable[b]['score'] end
		if (comboEfir.v == 0) then
			imgui.Separator()
			imgui.PushFont(medFont)
			if (callerID == -1 or not efirTime) then
				imgui.SetCursorPosX(240*global_scale.v - imgui.CalcTextSize(u8"В настоящий момент никто не подключен к эфиру").x / 2)
				imgui.Text(u8'В настоящий момент никто не подключен к эфиру')
			else
				if sampGetPlayerNickname(callerID) then
					--imgui.SetCursorPosX(240*global_scale.v - imgui.CalcTextSize(u8'К эфиру подключен ' .. sampGetPlayerNickname(callerID)).x / 2)
					if (callTime) then
						imgui.SetCursorPosX(240*global_scale.v - (imgui.CalcTextSize(u8'В эфире ' .. sampGetPlayerNickname(callerID) .. os.date(' %M:%S', os.time() - callTime)).x + 80*global_scale.v) / 2)
						imgui.Text(u8'В эфире ' .. sampGetPlayerNickname(callerID) .. os.date(' %M:%S', os.time() - callTime))
						imgui.SameLine((240*global_scale.v + (imgui.CalcTextSize(u8'В эфире ' .. sampGetPlayerNickname(callerID) .. os.date(' %M:%S', os.time() - callTime)).x - 60*global_scale.v) / 2))
						if imgui.SmallButton(u8'Отключить') then
							sampSendChat('/bring -1')
						end
					end
				else
					imgui.SetCursorPosX(240*global_scale.v - imgui.CalcTextSize(u8"В настоящий момент никто не подключен к эфиру").x / 2)
					imgui.Text(u8'В настоящий момент никто не подключен к эфиру')
				end
			end
			imgui.PopFont()
			imgui.BeginChild('efir1', imgui.ImVec2(470*global_scale.v,150*global_scale.v))
			imgui.Columns(4, 'xd', true)
    		imgui.Separator()
		    imgui.Text(u8'Имя')
		    imgui.SetColumnWidth(-1, 180*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text('ID')
		    imgui.SetColumnWidth(-1, 40*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text(u8'Принять вызов')
		    imgui.SetColumnWidth(-1, 130*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text(u8'Удалить из списка')
		    imgui.SetColumnWidth(-1, 230*global_scale.v)
		    imgui.Separator()
		    imgui.NextColumn()
			for i = 0, 999 do
				if (callTable[i] ~= nil) then
					local nickname = sampGetPlayerNickname(i)
					if (nickname ~= nil) then
					  --col = sampGetPlayerColor(i)
					  --imgui.TextColored(imgui.ImVec4(bit.rshift(bit.lshift(col,8),24)/255, bit.rshift(bit.lshift(col,16),24)/255, bit.rshift(bit.lshift(col,24), 24)/255, 1.0), nickname)
					  imgui.Text(nickname)
					  imgui.NextColumn()
					  imgui.Text(tostring(i))
					  imgui.NextColumn()
					  imgui.PushID(i)
					  if imgui.SmallButton(u8'Принять вызов') then
					  	sampSendChat('/bring ' .. i)
						if ini.Efir.pref2 then
					  		callTable = {}
					  	end
					  	callTable[i] = nil
					  end
					  imgui.PopID()
					  imgui.NextColumn()
					  imgui.PushID(i)
					  if imgui.SmallButton(u8'Удалить') then
					    callTable[i] = nil
					  end
					  imgui.PopID()
					  imgui.Separator()
					  imgui.NextColumn()
					end
				end
			end
			imgui.EndChild()
			if imgui.Button(u8'Очистить список',btn_size) then
				callTable = {}
			end
		else
			imgui.Separator()
			imgui.PushFont(medFont)
			imgui.SetCursorPosX(240*global_scale.v - imgui.CalcTextSize(u8"Последние SMS-сообщения").x / 2)
			imgui.Text(u8'Последние SMS-сообщения')
			imgui.PopFont()
			if imgui.IsItemHovered() then
				imgui.SetTooltip(u8'Таблица с последними SMS-сообщениями на номер радиоцентра.')
			end
			imgui.BeginChild('efir3', imgui.ImVec2(470*global_scale.v,150*global_scale.v))
			imgui.Columns(4, 'xddd', true)
    		imgui.Separator()
		    imgui.Text(u8'Время')
		    imgui.SetColumnWidth(-1, 70*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text(u8'Номер')
		    imgui.SetColumnWidth(-1, 70*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text(u8'Сообщение')
		    imgui.SetColumnWidth(-1, 250*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text(u8'Засчитать')
		    imgui.SetColumnWidth(-1, 80*global_scale.v)
		    imgui.Separator()
		    imgui.NextColumn()
		    for i, k in ipairs(smsTable) do
			  imgui.Text(os.date('%H:%M:%S', k['time']))
			  imgui.NextColumn()
			  imgui.Text(k['number'])
			  imgui.NextColumn()
			  imgui.Text(u8(k['text']))
			  imgui.NextColumn()
			  imgui.PushID(i)
			  if imgui.SmallButton(u8'Засчитать') then
			  	if k['score'] == nil then
			  		k['score'] = 1
			  	else
			  		--k['score'] = k['score'] + 1
			  	end
 			  	if numberToID[(k['number'])] == nil then
 			  		id = #scoreTable + 1
				  	table.insert(scoreTable, k)
				  	numberToID[k['number']] = id
				  	k['score'] = 1
				else
					scoreTable[numberToID[k['number']]]['score'] = scoreTable[numberToID[k['number']]]['score'] + 1
				end
				if ini.Efir.pref1 then
					sampSendChat('/t Стоп!')
				end
				if ini.Efir.pref3 then
			  		smsTable = {}
			  	end
				if ini.Efir.pref4 then
				  	table.sort(scoreTable, compare)
				  	for i, thing in ipairs(scoreTable) do
				  		numberToID[thing['number']] = i
				  	end
				end
				msgscript('Вы засчитали ответ игроку с номером ' .. k['number'] .. '. Его номер скопирован в буфер обмена.')
				setClipboardText(k['number'])
			  	ok = inicfg.save(scoreTable, './MME/scores.ini')
			  end
			  imgui.PopID()
			  imgui.Separator()
			  imgui.NextColumn()
			end
		    imgui.EndChild()
		    imgui.PushID(1)
		    if imgui.Button(u8'Очистить список',btn_size) then
				smsTable = {}
				--scoreTable = {}
			end
			imgui.PopID()

			imgui.Separator()
		    --
		    imgui.PushFont(medFont)
			imgui.SetCursorPosX(240*global_scale.v - imgui.CalcTextSize(u8"Баллы за викторину").x / 2)
			imgui.Text(u8'Баллы за викторину')
			imgui.PopFont()
			imgui.BeginChild('efir2', imgui.ImVec2(470*global_scale.v,150*global_scale.v))
			imgui.Columns(5, 'xdd', true)
    		imgui.Separator()
		    imgui.Text(u8'Номер')
		    imgui.SetColumnWidth(-1, 70*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text(u8'Имя')
		    imgui.SetColumnWidth(-1, 270*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text(u8'Баллы')
		    imgui.SetColumnWidth(-1, 60*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text(u8'+')
		    imgui.SetColumnWidth(-1, 35*global_scale.v)
		    imgui.NextColumn()
		    imgui.Text(u8'-')
		    imgui.SetColumnWidth(-1, 35*global_scale.v)
		    imgui.Separator()
		    imgui.NextColumn()
			for i, k in ipairs(scoreTable) do
				  imgui.Text(tostring(k['number']))
				  imgui.NextColumn()
				  imgui.Text(k['name'])
				  imgui.NextColumn()
				  imgui.Text(tostring(k['score']))
				  imgui.NextColumn()
				  imgui.PushID(i)
				  if imgui.SmallButton(u8'+') then
				  	k['score'] = k['score'] + 1
					if ini.Efir.pref4 then
					  	table.sort(scoreTable, compare)
					  	for i, thing in ipairs(scoreTable) do
					  		numberToID[thing['number']] = i
					  	end
					end
				  	ok = inicfg.save(scoreTable, './MME/scores.ini')
				  end
				  imgui.PopID()
				  imgui.NextColumn()
				  imgui.PushID(i)
				  if imgui.SmallButton(u8'-') then
				  	if k['score'] > 0 then
				   		k['score'] = k['score'] - 1
						if ini.Efir.pref4 then
						  	table.sort(scoreTable, compare)
						  	for i, thing in ipairs(scoreTable) do
						  		numberToID[thing['number']] = i
						  	end
						end
					  	ok = inicfg.save(scoreTable, './MME/scores.ini')
				   		--table.sort(numberToID, compare)
				   	end
				  end
				  imgui.PopID()
				  imgui.Separator()
				  imgui.NextColumn()
			end			
			imgui.EndChild()
			imgui.PushID(2)
			if imgui.Button(u8'Очистить список',btn_size) then
				--smsTable = {}
				scoreTable = {}
				numberToID = {}
				os.remove('moonloader/config/MME/scores.ini')
			end
			imgui.PopID()
		end
		imgui.End()
	end
end

function mmblack_window()
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(700*global_scale.v, 400*global_scale.v)) 
	imgui.Begin(u8'Черный список СМИ', window_states['mmblack'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
	if blacklistactive then
		imgui.BeginChild('download_blacklist', imgui.ImVec2(690*global_scale.v, 340*global_scale.v), false)
		for str in string.gmatch(blacklisttext .. '\n', '.-\n') do
			imgui.TextWrapped(str)
		end
		imgui.EndChild()
		if blockButton.blacklist then
			imgui.CustomButton(u8'Обновить', imgui.ImVec4(0.5, 0.5, 0.5, 1.0), imgui.ImVec4(0.5, 0.5, 0.5, 1.0), imgui.ImVec4(0.5, 0.5, 0.5, 1.0), btn_size)
		else
			if imgui.Button(u8'Обновить', btn_size) then
				blockButton.blacklist = true
				lua_thread.create(function() blackdownload(true) end)
			end
		end
	else
		imgui.SetCursorPosX(350*global_scale.v - imgui.CalcTextSize(u8'Черный список временно не допустен или не подключен к форуму').x / 2)
		imgui.SetCursorPosY(200*global_scale.v)
		imgui.Text(u8'Черный список временно не допустен или не подключен к форуму')
	end
	imgui.End()
end

function windows_pravila()
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(700*global_scale.v, 400*global_scale.v)) 
	imgui.Begin(u8'Шпаргалки', window_states['pravila'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
	imgui.PushItemWidth(150*global_scale.v)
	imgui.SetCursorPosX(100*global_scale.v)
	imgui.Combo('    ', comboPravila, u8'Устав СМИ\0ПРО\0ППЭ\0\0')
	imgui.PopItemWidth()
	imgui.SameLine()
	imgui.SetCursorPosX(450*global_scale.v)
	if blockButton.pravila then
		imgui.CustomButton(u8'Обновить', imgui.ImVec4(0.5, 0.5, 0.5, 1.0), imgui.ImVec4(0.5, 0.5, 0.5, 1.0), imgui.ImVec4(0.5, 0.5, 0.5, 1.0), imgui.ImVec2(150*global_scale.v,20*global_scale.v))
	else
		if imgui.Button(u8'Обновить', imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
			blockButton.pravila = true
			lua_thread.create(function() downloadPRAVILA(true) end)
		end
	end
	imgui.SameLine()
	if comboPravila.v == 0 then
		imgui.SetCursorPosX(350*global_scale.v - imgui.CalcTextSize(u8'Версия на хостинге ' .. dataYst).x / 2)
		imgui.Text(u8'Версия на хостинге ' .. dataYst)
		for i = 1, #charterNameTable do
			if charterTable[i] then
				if imgui.CollapsingHeader(charterNameTable[i]) then
					imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 0))
					for str in string.gmatch(charterTable[i] .. '\n', '.-\n') do
						imgui.TextWrapped(str)
					end
					imgui.PopStyleVar()	
				end
			end
		end
	elseif comboPravila.v == 1 then
		imgui.SetCursorPosX(350*global_scale.v - imgui.CalcTextSize(u8'Версия на хостинге ' .. dataPro).x / 2)
		imgui.Text(u8'Версия на хостинге ' .. dataPro)
		for i = 1, #proNameTable do
			if proTable[i] then
				if imgui.CollapsingHeader(proNameTable[i]) then
					imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 0))
					for str in string.gmatch(proTable[i] .. '\n', '.-\n') do
						imgui.TextWrapped(str)
					end
					imgui.PopStyleVar()
				end
			end
		end
	elseif comboPravila.v == 2 then
		imgui.SetCursorPosX(350*global_scale.v - imgui.CalcTextSize(u8'Версия на хостинге ' .. dataPpo).x / 2)
		imgui.Text(u8'Версия на хостинге ' .. dataPpo)
		for i = 1, #ppeNameTable do
			if ppeTable[i] then
				if imgui.CollapsingHeader(ppeNameTable[i]) then
					imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 0))
					for str in string.gmatch(ppeTable[i] .. '\n', '.-\n') do
						imgui.TextWrapped(str)
					end
					imgui.PopStyleVar()
				end
			end
		end
	end
	imgui.End()
end

function asd(var) -- CALLBACK NAMES PROFILE GNEWS
	if var == #inig + 1 then
		return 'Создать профиль'
	else
		if inig[var]['name'] == '' then
			return 'Профиль ' .. var
		else
			return inig[var]['name']
		end
	end
end

function newWindow() -- GNEWS
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(700*global_scale.v, 350*global_scale.v)) 
	imgui.Begin(u8'Настройка и отправка гос. новостей', window_states['m'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
		imgui.BeginChild('main_gwindow1', imgui.ImVec2(150*global_scale.v, 315*global_scale.v), true)
		for i = 1, #inig + 1 do
			imgui.PushID(i)
			if imgui.Selectable(u8(asd(i)), selected == i, imgui.SelectableFlags.SpanAllColumns) then
				if selected ~= i then
					regedit = false
				end
				selected = i
				if selected ~= #inig + 1 then
					gnews1_buffer = imgui.ImBuffer(u8(inig[selected]['Gos1']), 150)
					gnews2_buffer = imgui.ImBuffer(u8(inig[selected]['Gos2']), 150)
					gnews3_buffer = imgui.ImBuffer(u8(inig[selected]['Gos3']), 150)
					gnews_reminder_buffer = imgui.ImBuffer(u8(inig[selected]['Gosn']), 150)
					gnews_end_buffer = imgui.ImBuffer(u8(inig[selected]['Gose']), 150)
					gnews_dop = imgui.ImBuffer(u8(inig[selected]['Gosd']), 150)
					gnews_name = imgui.ImBuffer(u8(inig[selected]['name']), 32)
					gnews_time = imgui.ImInt(inig[selected]['time'])
				else
					gnews1_buffer = imgui.ImBuffer('', 150)
					gnews2_buffer = imgui.ImBuffer('', 150)
					gnews3_buffer = imgui.ImBuffer('', 150)
					gnews_reminder_buffer = imgui.ImBuffer('', 150)
					gnews_end_buffer = imgui.ImBuffer('', 150)
					gnews_dop = imgui.ImBuffer('', 150)
					gnews_name = imgui.ImBuffer('', 32)
					gnews_time = imgui.ImInt(1000)
					regedit = true
				end
			end
			imgui.PopID()
		end
		imgui.EndChild()
	imgui.SameLine()
		imgui.BeginGroup()
			imgui.BeginChild('main_gwindow2', imgui.ImVec2(530*global_scale.v, 285*global_scale.v), false)
			if regedit then
				--imgui.LockPlayer = true
				if selected == #inig + 1 then
					imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Создание нового профиля. Заполнять все значения необязательно').x / 2)
					imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8'Создание нового профиля. Заполнять все значения необязательно')
				else
					imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Отредактируйте гос. новости (/gnews вводить не нужно)').x / 2)
					imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8'Отредактируйте гос. новости (/gnews вводить не нужно)')
				end
				imgui.Separator()
				imgui.Spacing()
				imgui.SetCursorPosX(135*global_scale.v - imgui.CalcTextSize(u8'Название профиля:').x / 2)
				imgui.Text(u8'Название профиля:')
				imgui.SameLine(322*global_scale.v)
				imgui.Text(u8'Задержка межстрок (мс):')
				imgui.PushItemWidth(116*global_scale.v)
				imgui.SetCursorPosX(135*global_scale.v - 116*global_scale.v / 2)
				imgui.InputText('               			', gnews_name)
				imgui.PopItemWidth()
				imgui.SameLine(350*global_scale.v)
				imgui.PushItemWidth(100*global_scale.v)
				if imgui.InputInt('               			 ', gnews_time) then
					if gnews_time.v < 100 then
						gnews_time.v = 1000
					end
				end
				imgui.PopItemWidth()
				imgui.PushItemWidth(466*global_scale.v)
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'3 строки:').x / 2)
				imgui.Text(u8'3 строки:')
				imgui.SetCursorPosX(32*global_scale.v)
				imgui.InputText('               1', gnews1_buffer)
				imgui.SetCursorPosX(32*global_scale.v)
				imgui.InputText('               2', gnews2_buffer)
				imgui.SetCursorPosX(32*global_scale.v)
				imgui.InputText('               3', gnews3_buffer)
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Напоминание:').x / 2)
				imgui.Text(u8'Напоминание:')
				imgui.SetCursorPosX(32*global_scale.v)
				imgui.InputText('               н', gnews_reminder_buffer)
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Конец:').x / 2)
				imgui.Text(u8'Конец:')
				imgui.SetCursorPosX(32*global_scale.v)
				imgui.InputText('               к', gnews_end_buffer)
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Доп. строка:').x / 2)
				imgui.Text(u8'Доп. строка:')
				imgui.SetCursorPosX(32*global_scale.v)
				imgui.InputText('               sd', gnews_dop)
				imgui.PopItemWidth()
			else
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Текущее время: ' .. os.date('%X')).x / 2)
				imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8'Текущее время: ' .. os.date('%X'))
				imgui.Separator()
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(inig[selected]['Gos1'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8(inig[selected]['Gos1']))
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(inig[selected]['Gos2'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8(inig[selected]['Gos2']))
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(inig[selected]['Gos3'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8(inig[selected]['Gos3']))
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - 150*global_scale.v / 2)
				if imgui.Button(u8("Подать 3 строки"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
					if not RPactive then
						RPactive = true
						lua_thread.create(function ()
							sampSendChat('/gnews ' .. inig[selected]['Gos1'])
							wait(inig[selected]['time'])
							sampSendChat('/gnews ' .. inig[selected]['Gos2'])
							wait(inig[selected]['time'])
							sampSendChat('/gnews ' .. inig[selected]['Gos3'])
							RPactive = false
						end)
					end
				end
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(inig[selected]['Gosn'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8(inig[selected]['Gosn']))
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - 150*global_scale.v / 2)
				if imgui.Button(u8("Подать напоминание"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then 
					sampSendChat('/gnews ' .. inig[selected]['Gosn'])
				end
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(inig[selected]['Gose'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0),u8(inig[selected]['Gose']))
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - 150*global_scale.v / 2)
				if imgui.Button(u8("Подать конец"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
					sampSendChat('/gnews ' .. inig[selected]['Gose'])
				end
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(inig[selected]['Gosd'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8(inig[selected]['Gosd']))
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - 150*global_scale.v / 2)
				if imgui.Button(u8("Подать доп. строку"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then 
					sampSendChat('/gnews ' .. inig[selected]['Gosd'])
				end
			end
			imgui.EndChild()
			imgui.BeginChild('button_gwindow', imgui.ImVec2(530*global_scale.v, 25*global_scale.v), false)
			if regedit then
				if selected ~= #inig + 1 then
					if imgui.Button(u8("Подача"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then 
						regedit = false
					end
					imgui.SameLine()
				end
				if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then 
					if selected ~= #inig + 1 then
						inig[selected]['Gos1'] = u8:decode(gnews1_buffer.v)
						inig[selected]['Gos2'] = u8:decode(gnews2_buffer.v)
						inig[selected]['Gos3'] = u8:decode(gnews3_buffer.v)
						inig[selected]['Gosn'] = u8:decode(gnews_reminder_buffer.v)
						inig[selected]['Gose'] = u8:decode(gnews_end_buffer.v)
						inig[selected]['Gosd'] = u8:decode(gnews_dop.v)
						inig[selected]['name'] = u8:decode(gnews_name.v)
						inig[selected]['time'] = gnews_time.v
						ok = inicfg.save(gnewsIni, './MME/gnews_set.ini')
						if ok then
							printStringNow('SAVED!', 1500)
						else
							printStringNow('ERROR!', 1500)
						end
					else
						inig[selected] = {
							Gos1 = u8:decode(gnews1_buffer.v),
							Gos2 = u8:decode(gnews2_buffer.v),
							Gos3 = u8:decode(gnews3_buffer.v),
							Gosn = u8:decode(gnews_reminder_buffer.v),
							Gose = u8:decode(gnews_end_buffer.v),
							Gosd = u8:decode(gnews_dop.v),
							name = u8:decode(gnews_name.v),
							time = gnews_time.v
						}
						ok = inicfg.save(gnewsIni, './MME/gnews_set.ini')
						if ok then
							printStringNow('SAVED!', 1500)
						else
							printStringNow('ERROR!', 1500)
						end
						regedit = false
					end
				end
				if selected ~= 1 and selected ~= #inig + 1 then
					imgui.SameLine()
					if imgui.Button(u8("Удалить профиль"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
						for i = 1, #inig do
							if i >= selected then
								if inig[i + 1] ~= nil then
									inig[i] = inig[i + 1]
								else
									inig[i] = nil
								end
							end
						end
						ok = inicfg.save(gnewsIni, './MME/gnews_set.ini')
						if ok then
							printStringNow('SAVED!', 1500)
						else
							printStringNow('ERROR!', 1500)
						end
						regedit = false
						selected = selected - 1
					end
				end
			else
				if imgui.Button(u8("Изменить"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then 
					regedit = true
				end
				imgui.SameLine()
				if imgui.Button(u8("Гос. новости"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
					newsDialogOpen = true
					sampSendChat('/news')
				end
				imgui.SameLine()
				if imgui.Button(u8("В главное меню"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
					window_states['m'].v = false
					selectedm = lastselected
					window_states['main'].v = true
				end
			end
			imgui.EndChild()
		imgui.EndGroup()
	imgui.End()
end

function newsWindow() -- SHOWGNEWS
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(720*global_scale.v, 370*global_scale.v)) 
	imgui.Begin(u8'Последние гос. новости', window_states['n'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
	imgui.BeginChild('newstextS', imgui.ImVec2(708*global_scale.v, 305*global_scale.v), false)
	imgui.TextWrapped(u8(newstext))
	imgui.EndChild()
	imgui.SetCursorPosX(285*global_scale.v)
	if imgui.Button(u8"Назад", imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
		window_states['n'].v = false
		window_states['m'].v = true
	end
	imgui.End()
end

function namelec(var)
	if var == #inilec + 1 then
		return 'Создать лекцию'
	else
		if inilec[var]['name'] == '' then
			return 'Леция #' .. var
		else
			return inilec[var]['name']
		end
	end
end

function lecEDIT() 
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(700*global_scale.v, 250*global_scale.v)) 
	imgui.Begin(u8'Настройка и отправка лекций', window_states['editlec'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
		imgui.BeginChild('main_lecwindow1', imgui.ImVec2(150*global_scale.v, 215*global_scale.v), true)
		for i = 1, #inilec + 1 do
			imgui.PushID(i)
			if imgui.Selectable(u8(namelec(i)), selectedlec == i, imgui.SelectableFlags.SpanAllColumns) then
				if selectedlec ~= i then
					reglec = false
				end
				selectedlec = i
				if selectedlec ~= #inilec + 1 then
					lec1_buffer = imgui.ImBuffer(u8(inilec[selectedlec]['lec1']), 150)
					lec2_buffer = imgui.ImBuffer(u8(inilec[selectedlec]['lec2']), 150)
					lec3_buffer = imgui.ImBuffer(u8(inilec[selectedlec]['lec3']), 150)
					lec_name = imgui.ImBuffer(u8(inilec[selectedlec]['name']), 32)
					lec_time = imgui.ImInt(inilec[selectedlec]['time'])
				else
					lec1_buffer = imgui.ImBuffer('', 150)
					lec2_buffer = imgui.ImBuffer('', 150)
					lec3_buffer = imgui.ImBuffer('', 150)
					lec_name = imgui.ImBuffer('', 32)
					lec_time = imgui.ImInt(1000)
					reglec = true
				end
			end
			imgui.PopID()
		end
		imgui.EndChild()
	imgui.SameLine()
		imgui.BeginGroup()
			imgui.BeginChild('main_lecwindow2', imgui.ImVec2(530*global_scale.v, 185*global_scale.v), false)
			if reglec then
				--imgui.LockPlayer = true
				if selectedlec == #inilec + 1 then
					imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Создание новой лекции. Заполнять все значения необязательно').x / 2)
					imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8'Создание новой лекции. Заполнять все значения необязательно')
				else
					imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Отредактируйте лекцию (/r /f вводить не нужно)').x / 2)
					imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8'Отредактируйте лекцию (/r /f вводить не нужно)')
				end
				imgui.Separator()
				imgui.Spacing()
				imgui.SetCursorPosX(135*global_scale.v - imgui.CalcTextSize(u8'Название профиля:').x / 2)
				imgui.Text(u8'Название профиля:')
				imgui.SameLine(322*global_scale.v)
				imgui.Text(u8'Задержка межстрок (мс):')
				imgui.PushItemWidth(116*global_scale.v)
				imgui.SetCursorPosX(135*global_scale.v - 116*global_scale.v / 2)
				imgui.InputText('               			', lec_name)
				imgui.PopItemWidth()
				imgui.SameLine(350*global_scale.v)
				imgui.PushItemWidth(100*global_scale.v)
				if imgui.InputInt('               			 ', lec_time) then
					if lec_time.v < 100 then
						lec_time.v = 1000
					end
				end
				imgui.PopItemWidth()
				imgui.PushItemWidth(466*global_scale.v)
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Лекция').x / 2)
				imgui.Text(u8'Лекция:')
				imgui.SetCursorPosX(32*global_scale.v)
				imgui.InputText('               1s', lec1_buffer)
				imgui.SetCursorPosX(32*global_scale.v)
				imgui.InputText('               2s', lec2_buffer)
				imgui.SetCursorPosX(32*global_scale.v)
				imgui.InputText('               3s', lec3_buffer)
				imgui.PopItemWidth()
			else
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8('Лекция отправляется с тегом в /f /r чаты')).x / 2)
				imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8('Лекция отправляется с тегом в /f /r чаты'))
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8'Задержка между строками: ' .. inilec[selectedlec]['time']).x / 2)
				imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8'Задержка между строками: ' .. inilec[selectedlec]['time'])
				imgui.Separator()
				imgui.Spacing()
				imgui.PushItemWidth(75*global_scale.v)
				imgui.SetCursorPosX(270*global_scale.v - 75*global_scale.v / 2)
				imgui.Combo('             ', comboLecRadio, u8'R-чат\0F-чат\0\0')
				imgui.PopItemWidth()
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(inilec[selectedlec]['lec1'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8(inilec[selectedlec]['lec1']))
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(inilec[selectedlec]['lec2'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8(inilec[selectedlec]['lec2']))
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(inilec[selectedlec]['lec3'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.6, 0.8, 1.0, 1.0), u8(inilec[selectedlec]['lec3']))
				imgui.Spacing()
				imgui.SetCursorPosX(270*global_scale.v - 150*global_scale.v / 2)
				if imgui.Button(u8("Подать лекцию"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
					if RangHero > 6 then
						lua_thread.create(function ()
							if comboLecRadio.v == 0 then
								sampSendChat('/r ' .. ini.Tags.r .. ' ' .. inilec[selectedlec]['lec1'])
								wait(inilec[selectedlec]['time'])
								sampSendChat('/r ' .. ini.Tags.r .. ' ' .. inilec[selectedlec]['lec2'])
								wait(inilec[selectedlec]['time'])
								sampSendChat('/r ' .. ini.Tags.r .. ' ' .. inilec[selectedlec]['lec3'])
							else
								sampSendChat('/f ' .. ini.Tags.f .. ' ' .. inilec[selectedlec]['lec1'])
								wait(inilec[selectedlec]['time'])
								sampSendChat('/f ' .. ini.Tags.f .. ' ' .. inilec[selectedlec]['lec2'])
								wait(inilec[selectedlec]['time'])
								sampSendChat('/f ' .. ini.Tags.f .. ' ' .. inilec[selectedlec]['lec3'])
							end
						end)
					else
						msgscript('Лекции можно подавать с 7 ранга.')
					end
				end
			end
			imgui.EndChild()
			imgui.BeginChild('button_lecwindow', imgui.ImVec2(530*global_scale.v, 25*global_scale.v), false)
				if reglec then
					if selectedlec ~= #inilec + 1 then
						if imgui.Button(u8("Подача"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then 
							reglec = false
						end
						imgui.SameLine()
					end
					if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then 
						if selectedlec ~= #inilec + 1 then
							inilec[selectedlec]['lec1'] = u8:decode(lec1_buffer.v)
							inilec[selectedlec]['lec2'] = u8:decode(lec2_buffer.v)
							inilec[selectedlec]['lec3'] = u8:decode(lec3_buffer.v)
							inilec[selectedlec]['name'] = u8:decode(lec_name.v)
							inilec[selectedlec]['time'] = lec_time.v
							ok = inicfg.save(lectureIni, './MME/lec_set.ini')
							if ok then
								printStringNow('SAVED!', 1500)
							else
								printStringNow('ERROR!', 1500)
							end
						else
							inilec[selectedlec] = {
								lec1 = u8:decode(lec1_buffer.v),
								lec2 = u8:decode(lec2_buffer.v),
								lec3 = u8:decode(lec3_buffer.v),
								name = u8:decode(lec_name.v),
								time = lec_time.v
							}
							ok = inicfg.save(lectureIni, './MME/lec_set.ini')
							if ok then
								printStringNow('SAVED!', 1500)
							else
								printStringNow('ERROR!', 1500)
							end
							reglec = false
						end
					end
					if selectedlec ~= 1 and selectedlec ~= #inilec + 1 then
						imgui.SameLine()
						if imgui.Button(u8("Удалить лекцию"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
							for i = 1, #inilec do
								if i >= selectedlec then
									if inilec[i + 1] ~= nil then
										inilec[i] = inilec[i + 1]
									else
										inilec[i] = nil
									end
								end
							end
							ok = inicfg.save(lectureIni, './MME/lec_set.ini')
							if ok then
								printStringNow('SAVED!', 1500)
							else
								printStringNow('ERROR!', 1500)
							end
							reglec = false
							selectedlec = selectedlec - 1
						end
					end
				else
					if imgui.Button(u8("Изменить"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then 
						reglec = true
					end
					imgui.SameLine()
					if imgui.Button(u8("В главное меню"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
						window_states['editlec'].v = false
						selectedm = lastselected
						window_states['main'].v = true
					end
				end
			imgui.EndChild()
		imgui.EndGroup()
	imgui.End()
end

function nameRP(var) -- CALLBACK NAMES PROFILE RP
	if iniRP[var]['name'] == '' then
		return 'Отыгровка #' .. var
	else
		return iniRP[var]['name']
	end
end

function rpEDIT()
	imgui.SetNextWindowPos(imgui.ImVec2(resx/2, resy/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5)) 
	imgui.SetNextWindowSize(imgui.ImVec2(700*global_scale.v, 350*global_scale.v)) 
	imgui.Begin(u8'Настройка отыгровок', window_states['editRP'], imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
		imgui.BeginChild('main_RPwindow1', imgui.ImVec2(150*global_scale.v, 315*global_scale.v), true)
		for i = 1, #iniRP do
			imgui.PushID(i)
			if imgui.Selectable(u8(nameRP(i)), selectedRP == i, imgui.SelectableFlags.SpanAllColumns) then
				selectedRP = i
				editRP_buffer = imgui.ImBuffer(string.gsub(u8(iniRP[selectedRP]['RP']), '\\n', '\n'), 4096)
			end
			imgui.PopID()
		end
		imgui.EndChild()
	imgui.SameLine()
		imgui.BeginGroup()
			imgui.BeginChild('main_RPwindow2', imgui.ImVec2(530*global_scale.v, 285*global_scale.v), false)
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8(iniRP[selectedRP]['name'] .. '. ' .. iniRP[selectedRP]['tags'])).x / 2)
				imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8(iniRP[selectedRP]['name'] .. '. ' .. iniRP[selectedRP]['tags']))
				imgui.SetCursorPosX(270*global_scale.v - imgui.CalcTextSize(u8('Между строками укажите задержку в милисекундах (1 с = 1000 мс)')).x / 2)
				imgui.TextColored(imgui.ImVec4(0.5, 1, 0.5, 1.0), u8('Между строками укажите задержку в милисекундах (1 с = 1000 мс)'))
				imgui.Separator()
				imgui.InputTextMultiline(u8'     RP_selected' .. selectedRP, editRP_buffer, imgui.ImVec2(520*global_scale.v, 230*global_scale.v))
			imgui.EndChild()
			imgui.BeginChild('button_RPwindow', imgui.ImVec2(530*global_scale.v, 25*global_scale.v), false)
				if imgui.Button(u8("Сохранить"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
					for i = 1, #iniRP do
						if i == selectedRP then
							iniRP[selectedRP]['RP'] = string.gsub(u8:decode(editRP_buffer.v), '\n', '\\n')
						else
							iniRP[i]['RP'] = string.gsub(iniRP[i]['RP'], '\n', '\\n')
						end
					end
					
					ok = inicfg.save(RPIni, './MME/RP_set.ini')
					if ok then
						printStringNow('SAVED!', 1500)
					else
						printStringNow('ERROR!', 1500)
					end
				end
				imgui.SameLine()
				if imgui.Button(u8("В главное меню"), imgui.ImVec2(150*global_scale.v,20*global_scale.v)) then
					window_states['editRP'].v = false
					selectedm = lastselected
					window_states['main'].v = true
				end
			imgui.EndChild()
		imgui.EndGroup()
	imgui.End()
end

function rchat(args)
	if #args ~= 0 then
		if not (args:find('%(%(') and args:find('%)%)')) and (args:sub(1,4) ~= ini.Tags.r) then -- and ini.Prefs.pref7
			sampSendChat('/r ' .. ini.Tags.r .. ' ' .. args)
		else
			sampSendChat('/r ' .. args)
		end
	else
		sampSendChat('/r')
	end
end

function fchat(args)
	if #args ~= 0 then
		if not (args:find('%(%(') and args:find('%)%)')) and (args:sub(1,4) ~= ini.Tags.f) then -- ini.Prefs.pref7 and
			sampSendChat('/f ' .. ini.Tags.f .. ' ' .. args)
		else
			sampSendChat('/f ' .. args)
		end
	else
		sampSendChat('/f')
	end
end

function ff(args)
	if #args ~= 0 then
		local send = isWorkHero and "/f 1 (( " .. args .. " ))" or "/f (( " .. args .. " ))"
		sampSendChat(send)
	else
		msgscript("Используйте /ff [текст]")
	end
end

function rr(args)
	if #args ~= 0 then
		sampSendChat("/r (( " .. args .. " ))")
	else
		msgscript("Используйте /rr [текст]")
	end
end
--internal

--multiple keys press check
function checkKeys(keysTable)
	if #keysTable == 0 then return false end
	for i = 1, #keysTable do
		if not isKeyDown(keysTable[i] - 1) then
			return false
		end
	end
	return true
end

--same as previous, but using imgui lib
function imguiCheckKeys(keysTable)
	if #keysTable == 0 then return false end
	for i = 1, #keysTable do
		if not imgui.IsKeyDown(keysTable[i] - 1) then
			return false
		end
	end
	return true
end


--multiple keys text representation
function keysToText(keysTable)
	local text = ''
	if #keysTable == 0 then return 'N/A' end
	for i = 1, #keysTable do
		if i == #keysTable then
			text = text .. key.id_to_name(keysTable[i] - 1)
		else
			text = text .. key.id_to_name(keysTable[i] - 1) .. '+'
		end
	end
	return text
end