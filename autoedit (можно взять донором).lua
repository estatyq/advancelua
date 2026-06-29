script_name("MM Editor v2.0.0")
script_authors("Skelmer")
script_version("Final Beta")
script_version_number(1)
script_description("Mass Media Editor for Advance RolePlay")
script_moonloader(026)
script_url("https://vk.com/mmeditor")

local sampev =          require 'lib.samp.events'
local imgui =           require 'mimgui'
local faicon =          require 'fa-icons'
local imgui_addon =     require 'mimgui_addons'
local md5 =             require 'md5'
local rkeys =           require 'rkeys'
local copas =           require 'copas'
local http =            require "copas.http"

--local dl = require "SA-MP API.init"

dlstatus = require('moonloader').download_status
local as_action = require('moonloader').audiostream_state
local ffi = require 'ffi'
local memory = require 'memory'
local str, sizeof = ffi.string, ffi.sizeof
local vkeys = require 'vkeys'
local wm = require 'windows.message'
local encoding = require 'encoding'
encoding.default = 'CP1251'
u8 = encoding.UTF8

ffi.cdef[[
	struct stChatInfo {
		int					pagesize;
	} __attribute__ ((packed));

	int __stdcall GetVolumeInformationA(
	const char* lpRootPathName,
	char* lpVolumeNameBuffer,
	uint32_t nVolumeNameSize,
	uint32_t* lpVolumeSerialNumber,
	uint32_t* lpMaximumComponentLength,
	uint32_t* lpFileSystemFlags,
	char* lpFileSystemNameBuffer,
	uint32_t nFileSystemNameSize
	);
]]

local w, h = getScreenResolution()

local dir = { -- главные директории скрипта
	main = 'moonloader\\config\\Mass Media Editor\\',
	settings = 'moonloader\\config\\Mass Media Editor\\Default\\',
	github = 'https://raw.githubusercontent.com/SkelmerIgor/MMEditorLua/main/ARP/',
	host = 'host',
	temp = os.getenv('TEMP') .. '\\',
}

local rules = { } -- шпоры
local notf = {news = '', rezHost = false } -- файл настроек скрипта (повторяемость уведомлений и др)
local user = { server = { }, } -- информация об игроке id (акк), rang (номер ранга), rangName, podr, nick
local userTarget = { } -- id, name, nick
local loadText = '' -- текст информационного оверлея
hook = {dia = {}, msg = {}} -- Хуки диалогов, сообщений
hook.dia.id = 0
hook.msg.id = 0

local serverList = { -- список серверов
	{
		name = 'Red',
		ip = '185.169.134.237',
		url = 'https://forum.advance-rp.ru/forums/.27/',
	},
	{
		name = 'Green',
		ip = '185.169.134.238',
		url = 'https://forum.advance-rp.ru/forums/.84/',
	},
	{
		name = 'Blue',
		ip = '185.169.134.239',
		url = 'https://forum.advance-rp.ru/forums/.239/',
	},
	{
		name = 'Lime',
		ip = '185.169.134.156',
		url = 'https://forum.advance-rp.ru/forums/.584/',
	},
	{
		name = 'Chocolate',
		ip = '185.169.134.157',
		url = 'https://forum.advance-rp.ru/forums/.709/',
	},
}
local win_status = { -- статус окон imgui
	edit = imgui.new.bool(), -- окно редактирования
	find = imgui.new.bool(), -- окно /find
	findInfo = imgui.new.bool(), -- доп. инф. окно /find
	rules = imgui.new.bool(), -- окно шпор
	update = imgui.new.bool(), -- окно обновления
	settingsMenu = imgui.new.bool(), -- настройка отыгровок
	main = imgui.new.bool(), -- главное меню
	act = imgui.new.bool(), -- меню взаимодействия
	efir = imgui.new.bool(), -- меню эфиров
	info = imgui.new.bool(), -- информационный оверлей
}

local chaptersRp = {
	u8'Информация',
	u8'Мои отыгровки',
	u8'[ПКМ] Старший состав',
	u8'[ПКМ] Собеседование',
	u8'[ПКМ] Пользовательские',
	u8'[FIND] Старший состав',
	u8'[FIND] Пользовательские',
}
local typeRp = {
	u8"Пользовательские",
	u8"Радиоэфиры",
}
local settingsRp = { -- Настройки менюшек и отыгровок (3-7)

	setList = imgui.new.int(0),
	items = imgui.new['const char*'][#chaptersRp](chaptersRp),

	myRpList = imgui.new.int(0),
	myRpItems = imgui.new['const char*'][#typeRp](typeRp),

	temp = {
		name = imgui.new.char[44](),
		text = imgui.new.char[16384](),
		cmd = imgui.new.char[44](),
		key = { v = {} },
	},

	tegsSeparator = 1, -- Половины суммы тегов с округлением вверх
	curTegs = 0, -- Раздел специального тега
	sumTegs = 0, -- Общее количество тегов

	-- type - тип окна: 1 - инпут, 2 - лист
	-- list -  список, select - то что выбрали
	-- buf - буфер для инпута
	-- textBL - выбор текста для черного списка
	-- is - статус окна: -1 - отмена, 1 - открыто, 2 - выбрано
	window = {type = 0, list = {}, buf = imgui.new.char[64](), select = 0, is = -1, textBL = ''},

	wait = false, -- ожидание продолжение отыгровки
	waitBL = false, -- ожидание проверки черного списка

	active = imgui.new.bool(), -- Активность отыгровки/Оверлей
	selectedButton = 1, -- [окно find/target] Какой раздел открыт
	selected = 1, -- [настройка] Номер пункта (а ниже)

	-- settingsRp.set[i][a] -- i Раздел, a - Пункт
	set = {
		{{name = 'Основное', text = ''}, {name = 'Пример', text = ''}, {name = 'Описание тегов', text = ''}},
		{},{},{},{},{},{},
	},
	tegs = {
		{ -- Общее
			{'<time>','Время компьютера', function() return os.date('%X', os.time()) end},
			{'<date>','Дата компьютера', function() return os.date('%d.%m.%Y', os.time()) end},
			{'<myFio>', 'Ваше имя и фамилия', function() return user.fullName end},
			{'<myName>', 'Ваше имя', function() return user.name end},
			{'<myNick>', 'Ваш никнейм', function() return user.nick end},
			{'<myRang>', 'Ваш ранг', function() return user.rangName end},
			{'<myPodr>', 'Ваше подразделение', function() return user.podr end},
			{'<myId>', 'Ваш ID', function() local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED); return id end},
			{'<myPhone>', 'Ваш номер телефона', function() return user.phone end},
		},
		{ -- Для ПКМ (таргет)
			{'<tFio>','Имя и фам. игрока', function() return userTarget.name end},
			{'<tName>','Имя игрока', function() return (userTarget.nick):match('(.-)_') end},
			{'<tNick>','Никнейм игрока', function() return userTarget.nick end},
			{'<tId>','ID игрока', function() return userTarget.id end},
		},
		{ -- Для /find
			{'<fFio>','Имя и фам. игрока', function() return (listFind[listFind.selected].nick):gsub('_',' ') end},
			{'<fName>','Имя игрока', function() return (listFind[listFind.selected].nick):match('(.-)_') end},
			{'<fNick>','Никнейм игрока', function() return listFind[listFind.selected].nick end},
			{'<fId>','ID игрока', function() return listFind[listFind.selected].id end},
			{'<fNumber>','Номер телефона игрока', function() return listFind[listFind.selected].phone end},
			{'<fRName>','Имя ранга игрока', function() return listFind[listFind.selected].podr end},
		},
	}
}

local efir = {

	-- для focusChat
	bufName = imgui.new.char[128](),
	bufMsg = imgui.new.char[128](),
	bufColor = imgui.new.int(),
	bufPhone = imgui.new.char[128](),
	bufAnag = imgui.new.char[128](),
	bufAnagSub = imgui.new.char[128](),

	firstLetter = imgui.new.bool(), -- анаграмма

	bufRpShow = imgui.new.char[16384](), -- показ Rp перед отправкой
	bufNote = imgui.new.char[16384](), -- заметки
	selected = 0, -- для блокировки сообщений

	firstRpList = imgui.new.int(0),
	lastRpList = imgui.new.int(0),
	firstRpItems = nil,
	firstRpChapter = {},

	time = 0,

	calc = {
		sms = 0,
		calls = 0,
		efirLine = 0,
	},

	on = false, -- начат ли эфир

	buttonResult = false, -- кнопки "Результаты прошешдщего эфира"
	lastResults = {
		score = {},
		calc = {},
		date = nil,
		time = nil,
	},

	msg_last = false, -- был ли фикс сообщений
	msg_id = 1, -- количество сообщений после фикс сообщения

	pg_size_efir = 0, -- pagesize во время эфира
	pg_size_old = 0, -- pagesize до эфира

	to = {
		calls = { },
		connected = { },
		sms = { },
		score = { },
	},

	--[[to = {
		calls = {
			{
				id = 10,
				nick = 'Igor_Novikov'
			},
			{
				id = 111,
				nick = 'Joel_Nielsen'
			},
			{
				id = 23,
				nick = 'Svetlana_Dragunova'
			},
			{
				id = 888,
				nick = 'Kristen_Dewmans'
			},
		},
		connected = {
			{
				id = 555,
				nick = 'Sophia_Jayson'
			},
			{
				id = 899,
				nick = 'Robert_Jayson'
			},
		},
		sms = {
			{
				nick = 'Joel_Nielsen',
				sms = 'Самое крутое сообщение на всем белом свете',
				phone = 444222,
			},
			{
				nick = 'Sophia_Jayson',
				sms = 'Самое крутое сообщение на всем белом свете',
				phone = 123123,
			},
			{
				nick = 'Svetlana_Dragunova',
				sms = 'Самое крутое сообщение на всем белом свете',
				phone = 552222,
			},
			{
				nick = 'Kristen_Dewmans',
				sms = 'Самое крутое сообщение на всем белом свете',
				phone = 422211,
			},
		},
		score = {
			{
				nick = 'Kristen_Dewmans',
				phone = 422211,
				score = 9,
			},
			{
				nick = 'Joel_Nielsen',
				phone = 444222,
				score = 10,
			},
			{
				nick = 'Sophia_Jayson',
				phone = 123123,
				score = 7,
			},
		}
	},-- ]]

	win = {
		calls = imgui.new.bool(),
		sms = imgui.new.bool(),
		onefir = imgui.new.bool(),
	},

	set = { -- сохраняемые настройки

		bool = {false, false, false, false}, -- фокус, авторазмер, автоскрин, авто /t
		focusChat = {
			{msg="^.- Отправитель: .- %(тел%. .-%)",name="Объявление 1",color=16711935}
		},

		bufNum = {15,}, -- pagesize, volume
		dataRp = {}, -- отыгровки

		note = '', -- заметки эфира
		anagSub = '', -- разделитель анарамм
		firstRp = nil, -- выбор РП при начале эфира
		lastRp = nil, -- выбор РП при завершении эфира
		firstLetter = false, -- для анаграмм

	}
}

local settings = {
	scriptBool = { true, true, true, },
	scriptBuf = { '', '', '', 'LS - ПРО', '3000', 'LS'},
	keys = {
		{ v = {vkeys.VK_M}, },
		{ v = {vkeys.VK_CONTROL, vkeys.VK_1}, },
		{ v = {vkeys.VK_CONTROL, vkeys.VK_2}, },
		{ v = {vkeys.VK_R}, },
		{ v = {vkeys.VK_F2}, },
		{ v = {}, },
		{ v = {}, },
	},
}
local settingsInfo = {
	scriptBool = {
		{
			name = 'Выводить чистый онлайн в чат',
			dis = 'При просмотре времени выводит в чат чистый онлайн',
		},
		{
			name = 'Интерактивный список сотрудников',
			dis = 'Заменяет обычное окно /find на интерактивное',
		},
		{
			name = 'Скриптовое окно редактирования объявлений',
			dis = 'Заменяет обычное окно редактирования на обновленное',
		},
	},
	efirBool = {
		{
			name = 'Фильтр чата',
			dis = 'Скрывает лишние сообщения из чата, чтобы\nне мешать эфиру',
		},
		{
			name = 'Авторазмер чата',
			dis = 'Задает размер чата во время эфира и возвращает его размер после эфира',
		},
		{
			name = 'Автоскриншот эфира',
			dis = 'Делает скриншот, когда последняя строка эфира уходит из чата',
		},
		{
			name = 'Автоматически подставлять /t',
			dis = 'При отправке сообщений в обычный чат команда /t\nперед сообщениями будет подставляться автоматически\n\nПри использовании обычных команд /t не будет использоваться',
		},
	},
	scriptBuf = {
		{
			name = 'Тег в рацию [R]',
			dis = 'Автоматически после вашего сообщения подставляет тег в [R] рацию. Оставьте пустым, для отключения',
		},
		{
			name = 'Тег в рацию [F]',
			dis = 'Автоматически после вашего сообщения подставляет тег в [F] рацию. Оставьте пустым, для отключения',
		},
		{
			name = 'Тег в обычный чат',
			dis = 'Автоматически после вашего сообщения в чат подставляет тег. Обычно используется для автоакцента',
		},
		{
			name = 'Текст отклонения «Вставка ПРО»',
			dis = 'Устанавливает текст при нажатии на эту кнопку в редактировании объявлений',
		},
		{
			name = 'Задержка при поиске объявлений, мс',
			dis = 'Устанавливает интервал ввода /edit',
		},
		{
			name = 'Тег перед объявлением',
			dis = 'Тег подставляется автоматически при начале редактирования объявления',
		},
	},
	keys = {
		{
			name = 'Открыть главное меню',
			mod = 1,
			func = function () mainMenu.selected = {1, 1}; win_status.main[0] = not win_status.main[0] end,
		},
		{
			name = 'Открыть шпаргалки',
			mod = 1,
			func = function () win_status.rules[0] = not win_status.rules[0] end,
		},
		{
			name = 'Открыть мои отыгровки',
			mod = 1,
			func = function ()

				updateChapterRp(2)
				settingsRp.selected = 0
				settingsRp.myRpList[0] = 0
				settingsRp.setList[0] = 1
				win_status.settingsMenu[0] = true

			end,
		},
		{
			name = 'Открыть меню взаимодействия (ПКМ + ...)',
			mod = 3,
			func = function ()

				local valid, ped = getCharPlayerIsTargeting(PLAYER_HANDLE)

				if valid and doesCharExist(ped) then

					local res, id = sampGetPlayerIdByCharHandle(ped)

					if res then

						userTarget.id = id
						userTarget.nick = sampGetPlayerNickname(userTarget.id)
						userTarget.name = string.gsub(userTarget.nick, '_', ' ')

						win_status.act[0] = true

					end

				end

			end,
		},
		{
			name = 'Начать/завершить поиск объявлений',
			mod = 1,
			func = function ()

				if editVars.waitCar then return end

				editVars.flood = not editVars.flood

				if editVars.flood then

					win_status.info[0] = true
					loadText = 'Идет поиск новых объявлений...'

					hook.msg[editVars.idHookFlood].run = true

				else

					hook.msg[editVars.idHookFlood].run = false
					win_status.info[0] = false

				end

			end,
		},
		{
			name = 'Продолжить отыгровку (/mmnext)',
			mod = 1,
			func = function ()

				settingsRp.wait = false

			end,
		},
		{
			name = 'Остановить отыгровку (/mmstop)',
			mod = 1,
			func = function ()

				if threadRp then

					if not (threadRp:status() == 'dead') then

						threadRp:terminate()
						util.scriptmsg('Отыгровка принудительно остановлена.')

					end

				end

				settingsRp.active[0] = false
			end,
		},
	},
}

mainMenu = { -- Окна главного меню (/MMEDITOR) / Ужасы

	selected = {1,1},

	bufNews = imgui.new.char[16384](),
	bufBLThread = imgui.new.int(0),
	buttonNewsActive = true,
	sendNewsButton = function ()
		if mainMenu.buttonNewsActive then

			if imgui.Button(faicon(0xf0c7) .. u8' Отправить', imgui.ImVec2(-0.1, 0)) then
				imgui.OpenPopup(u8'Подтверждение')
			end

		else

			local color = imgui.ImVec4(0.5, 0.5, 0.5, 1.0)

			imgui.CustomButton(faicon(0xf0c7) .. u8' Отправить', color, color, color, imgui.ImVec2(-0.1, 0))

			-- imgui_addon.Spinner("##sendnews", 7, 2, imgui.ColorConvertFloat4ToU32(color)

		end
	end,

	news = {},

	{
		name = '>> Главный раздел',
		part = {'Новости', 'Меню эфиров', 'Группа скрипта', 'Донат',},
		func = {

	function () -- 1

		imgui.CustomText(u8('{ff9933}MM Editor v' .. thisScript().version .. ' приветствует Вас, ' .. user.fullName .. '!'), 2)
		imgui.CustomText(u8('Здесь Вы можете найти новости скрипта и управляющего СМИ'), 2)

		imgui.Separator()
		imgui.CustomText(u8'{99ccff}Новости скрипта', 2)
		imgui.Separator()

		imgui.BeginChild('##news1', imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 128))

		--[[
		for i = #updateMessage.message, 1, -1 do
			local text = ('\t[%s]\t%s\n\n'):format(updateMessage.message[i].date, updateMessage.message[i].text)
			imgui.TextWrapped(text)
		end
		--]]
		-- TextWrapped из комментария
		imgui.TextWrapped(u8'Бета скрипта')

		imgui.EndChild()

		imgui.Separator()
		imgui.CustomText(u8'{99ccff}Новости управляющего СМИ ' .. mainMenu.news.nick .. ' (' .. mainMenu.news.time .. '):', 2)
		imgui.Separator()

		imgui.BeginChild('##news2', imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 119))

		for str in string.gmatch(mainMenu.news.msg .. '\n', '.-\n') do -- Текст
			imgui.TextWrapped(str)
		end

		imgui.EndChild()

		imgui.Separator()
		imgui.Spacing()

		if imgui.Button(faicon.ICON_NEWSPAPER_O .. u8(' Открыть раздел СМИ ' .. serverList[user.server.id].name .. ' сервера'), imgui.ImVec2(-0.1, 0)) then
			os.execute('explorer "' .. serverList[user.server.id].url ..'"')
		end

	end,

	function ()

		win_status.main[0] = false
		openMenuPreEfir()

	end,

	function () -- 3

		mainMenu.selected = {1, 1}
		os.execute('explorer "' .. thisScript().url ..'"')

	end,

	function () -- 4

		imgui.CustomText(u8'Кек лол', 2)

	end, -------------------------------------------------- BEFORE

		},
		beforeFunc = {

	function ()

	end,
	function ()

	end,
	function ()

	end,
	function ()

	end,

		},
	}, -------------------------------------------------- УПРАВЛЕНИЕ СМИ
	{
		name = '>> Управление СМИ',
		part = {'Новости для СМИ', 'Редактор устава', 'Черный список'},
		func = {

	function () -- 1

		local wsize = imgui.GetWindowSize()

		--if user.podrNum ~= 5 and updateMessage.servers[user.server.id].msg then
		if true then

			imgui.SetCursorPosY(wsize.y * 0.45)
			imgui.CustomText(u8'Отправлять новости для СМИ может только управляющий СМИ', 2)

			goto skipSendNews

		end

		imgui.Separator()
		imgui.CustomText(u8'Отправка новостей для СМИ', 2)
		imgui.CustomText(u8'Новости будут отображаться в главном разделе скрипта', 2)
		imgui.Separator()
		imgui.Spacing()
		imgui.CustomText(faicon.ICON_NEWSPAPER_O .. u8' Текст новости:', 2)

		imgui.InputTextMultiline('##textNews', mainMenu.bufNews, sizeof(mainMenu.bufNews),
			imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 269))

		imgui.Spacing()
		imgui.Separator()
		imgui.Spacing()

		mainMenu.sendNewsButton()

		if imgui.BeginPopupModal(u8'Подтверждение', nil, imgui.WindowFlags.AlwaysAutoResize) then

			imgui.CustomText(u8'Проверьте свою новость', 2)
			imgui.Spacing()

			imgui.BeginChild('##newsCheck', imgui.ImVec2(500, 200), true)

			if not (str(mainMenu.bufNews):len() > 0) then

				imgui.TextWrapped(u8('Управляющий СМИ ' .. serverList[user.server.id].name .. ' сервера ещё не отправлял гос. новостей'))

			else

				for str in string.gmatch(str(mainMenu.bufNews) .. '\n', '.-\n') do -- Текст
					imgui.TextWrapped(str)
				end

			end

			imgui.EndChild()

			imgui.SetCursorPosX(wsize.x * 0.5 - 150 - 8)
			if imgui.Button(faicon(0xf0c7) .. u8 ' Сохранить', imgui.ImVec2(150, 0)) then

				-- вырезано. Отправка новостей

			end

			imgui.SameLine()

			if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(150, 0)) then

				imgui.CloseCurrentPopup()

			end
			imgui.EndPopup()
		end

		::skipSendNews::
	end,

	function() -- 2

		local wsize = imgui.GetWindowSize()

		imgui.SetCursorPosY(wsize.y * 0.46)
		imgui.CustomText(faicon.ICON_SPINNER .. u8' Эта крутая штука ещё разрабатывается! ' .. faicon.ICON_SPINNER, 2)

	end,

	function() -- 3

		local wsize = imgui.GetWindowSize()

		imgui.BeginChild('##menuPart1BL', imgui.ImVec2(0, wsize.y - 33), false)

		local online = blackList.set.bool and blackList.url and true or false

		imgui.Separator()
			imgui.CustomText(u8'Статус черного списка', 2)
		imgui.Separator()
		imgui.Spacing()
				imgui.SetCursorPosX(wsize.x * (1/10))
				imgui.CustomText(u8'Тип черного списка')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (10/15))
				imgui.CustomText(online and u8'{00ff00}онлайн' or u8'{ff6161}оффлайн')

				imgui.SetCursorPosX(wsize.x * (1/10))
				imgui.CustomText(u8'Номер темы ЧС')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (10/15))
				imgui.CustomText(blackList.url and tostring(blackList.url) or u8'нет')

				imgui.SetCursorPosX(wsize.x * (1/10))
				imgui.CustomText(u8'Указал тему ЧС')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (10/15))
				imgui.CustomText(blackList.nick and blackList.nick or u8'нет')
		imgui.Spacing()
		imgui.Separator()
			imgui.CustomText(u8'Настройки черного списка', 2)
		imgui.Separator()
		imgui.Spacing()

		imgui.SetCursorPosX(wsize.x * (1/12))

		imgui_addon.ToggleButton('##boolBL1', blackListTemp.bool[1])

		imgui.SameLine()
		imgui.SetCursorPosX(wsize.x * (3/12))
		imgui.AlignTextToFramePadding()

		imgui.CustomText(u8('Получать черный список онлайн'))

		imgui.SameLine()
		imgui.SetCursorPosX(wsize.x * (10.5/12))
		imgui.AlignTextToFramePadding()

		imgui.CustomText(faicon(0xf05a))
		if imgui.IsItemHovered() then
			imgui.SetTooltip(u8('В случае недоступности ЧС СМИ, будет доступен оффлайн файл.'))
		end

		imgui.Spacing()
		imgui.Separator()
			imgui.CustomText(u8'Дополнительные параметры', 2)
		imgui.Separator()
		imgui.Spacing()

		imgui.SetCursorPosY(wsize.y - 150)
		imgui.SetCursorPosX(wsize.x * 0.5 - 350 * 0.5 - imgui.GetStyle().ItemSpacing.x)
		if imgui.Button(faicon(0xf044) .. u8 ' Просмотреть/редактировать черный список', imgui.ImVec2(350, 0)) then
			imgui.StrCopy(mainMenu.bufNews, u8(blackList.set.text))
			imgui.OpenPopup(u8'Настройка черного списка')
		end

		if imgui.BeginPopupModal(u8'Настройка черного списка', nil, imgui.WindowFlags.AlwaysAutoResize) then

			local onlyRead = (blackList.set.bool and blackList.url) and imgui.InputTextFlags.ReadOnly or 0

			imgui.Separator()
				imgui.CustomText(u8'Файл черного списка ', 2)
				imgui.SameLine(nil, 0)
					imgui.CustomText(faicon(0xf05a))

				if imgui.IsItemHovered() then
					imgui.SetTooltip(u8('При онлайн обновлении ЧС редактирование файла недоступно.\n\nПримечание: при показе результата проверки ЧС будете выведена вся строка\nсодержащая ник игрока, поэтому лучший формат записи: Ник - Причина.'))
				end
			imgui.Separator()

			imgui.InputTextMultiline('##textBList', mainMenu.bufNews, sizeof(mainMenu.bufNews),
				imgui.ImVec2(508, 300), onlyRead)

			updateButtonBL()

			imgui.SameLine()

			if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(250, 0)) then

				imgui.CloseCurrentPopup()

			end

			imgui.EndPopup()
		end

		imgui.SetCursorPosX(wsize.x * 0.5 - 350 * 0.5 - imgui.GetStyle().ItemSpacing.x)
		if imgui.Button(faicon(0xf013) .. u8 ' Указать тему черного списка', imgui.ImVec2(350, 0)) then

			if user.rang < 9 then

				blackList.test_text = nil
				blackList.sended = nil
				mainMenu.bufBLThread[0] = blackList.url or blackList.tmp_th

				imgui.OpenPopup(u8"Онлайн черный список")

			else

				util.scriptmsg('Указать тему черного списка могут только лидеры.', 2)

			end

		end

		if imgui.BeginPopupModal(u8"Онлайн черный список", nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize) then

			imgui.SetWindowSizeVec2(imgui.ImVec2(500, 300))

			local wsize = imgui.GetWindowSize()

			imgui.Indent(50)
			imgui.BeginGroup()
			imgui.CustomText(u8'Введите номер темы с ЧС ')
			imgui.SameLine(nil, 0)
			imgui.CustomText(faicon(0xf05a))
			if imgui.IsItemHovered() then
				imgui.SetTooltip(u8('Номер темы можно посмотреть в ссылке на тему - это число в конце ссылки "/name.123456/"'))
			end

			imgui.PushItemWidth(165)
			imgui.InputInt('##bufOnlineBL', mainMenu.bufBLThread)
			imgui.PopItemWidth()

			imgui.EndGroup()
			imgui.SameLine(300)
			imgui.BeginGroup()
			imgui.SetCursorPosY(35)
			if imgui.Button(faicon.ICON_CHECK .. u8' Тестировать', imgui.ImVec2(160, 0)) then

				blackList.test_text = nil
				blackList.sended = nil

				getOnlineBL(mainMenu.bufBLThread[0])

			end
			imgui.EndGroup()
			imgui.Unindent(50)

			imgui.BeginChild('##onlineBL', imgui.ImVec2(0, wsize.y - 130), true)

			if blackList.sended == true then

				imgui.SetCursorPosY(wsize.y / 2 - 70)
				imgui.CustomText(u8('Номер темы черного списка успешно изменен'), 2)

			elseif blackList.sended == false then

				imgui.SetCursorPosY(wsize.y / 2 - 70)
				imgui.CustomText(u8('Что-то пошло не так. Попробуйте позже'), 2)

			elseif not blackList.update then

				imgui.SetCursorPosY(wsize.y / 2 - 105)
				imgui.SetCursorPosX(wsize.x / 2 - 45)
				imgui_addon.Spinner("##loadBL", 40, 4, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.5, 0.5, 0.5, 1.0)))
				imgui.SetCursorPosY(wsize.y / 2 - 70)
				imgui.CustomText(u8('Загрузка'), 2)

			elseif blackList.test_text == false then

				imgui.SetCursorPosY(wsize.y / 2 - 70)
				imgui.CustomText(u8('Теги ЧС СМИ не найдены, либо форум недоступен'), 2)

			elseif blackList.test_text then

				imgui.TextWrapped(u8(blackList.test_text))

			else

				imgui.SetCursorPosY(wsize.y / 2 - 70)
				imgui.CustomText(u8('Введите номер темы ЧС и протестируйте'), 2)

			end

			imgui.EndChild()

			imgui.Spacing()

			if blackList.test_text and blackList.update then

				if imgui.Button(faicon(0xf0c1) .. u8' Сохранить ссылку на тему', imgui.ImVec2(-0.1, 0)) then

					sendOnlineBL(blackList.tmp_th)

				end

			else

				local color = imgui.ImVec4(0.5, 0.5, 0.5, 1.0)

				imgui.CustomButton(faicon(0xf0c1) .. u8' Сохранить ссылку на тему', color, color, color, imgui.ImVec2(-0.1,0))

			end


			if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(-0.1, 0)) then

				imgui.CloseCurrentPopup()

			end

			imgui.EndPopup()
		end

		imgui.SetCursorPosX(wsize.x * 0.5 - 350 * 0.5 - imgui.GetStyle().ItemSpacing.x)
		if imgui.Button(faicon(0xf05a) .. u8 ' Как использовать (FAQ)', imgui.ImVec2(350, 0)) then



		end

		imgui.EndChild()
		imgui.Separator()
		imgui.Spacing()

		if imgui.Button(faicon(0xf0c7) .. u8 ' Сохранить все настройки', imgui.ImVec2(-0.1, 0)) then

			blackList.set.bool = blackListTemp.bool[1][0]
			util.saveSettings(blackList.set, dir.settings .. "blacklist.json")

			printString("~y~Saved!", 1500)
		end

	end,-------------------------------------------------- BEFORE

		},
		beforeFunc = {

	function()
		imgui.StrCopy(mainMenu.bufNews, mainMenu.news.msg)
	end,
	function()
	end,
	function()

		blackListTemp = {
			bool = {},
		}

		blackListTemp.bool[1] = imgui.new.bool(blackList.set.bool)
		--for i = 1, #blackList.bool do blackListTemp.bool[i] = imgui.new.bool(blackList.bool[i]) end

	end,

		},
	}, -------------------------------------------------- НАСТРОЙКИ
	{
		name = '>> Настройки',
		part = {'Основные', 'Клавиши', 'AutoEdit', 'Отыгровка'},
		func = {

	function () -- 1
		local wsize = imgui.GetWindowSize()

		imgui.BeginChild('##menuPart1', imgui.ImVec2(0, wsize.y - 33), false)

		imgui.Separator()
			imgui.CustomText(u8'Настройка предпочтений', 2)
		imgui.Separator()
		imgui.Spacing()

		for i = 1, #tempSettings.bool do

			imgui.SetCursorPosX(wsize.x * (1/12))

			imgui_addon.ToggleButton('##boolscript' .. i, tempSettings.bool[i])

			imgui.SameLine()
			imgui.SetCursorPosX(wsize.x * (3/12))
			imgui.AlignTextToFramePadding()

			imgui.CustomText(u8(settingsInfo.scriptBool[i].name))

			imgui.SameLine()
			imgui.SetCursorPosX(wsize.x * (10.5/12))
			imgui.AlignTextToFramePadding()

			imgui.CustomText(faicon(0xf05a))
			if imgui.IsItemHovered() then
				imgui.SetTooltip(u8(settingsInfo.scriptBool[i].dis))
			end

		end

		imgui.Spacing()
		imgui.Separator()
			imgui.CustomText(u8'Настройка тегов и текста', 2)
		imgui.Separator()
		imgui.Spacing()

		for i = 1, #tempSettings.buf do

			if i == 4 then
				imgui.Spacing()
				imgui.Separator()
					imgui.CustomText(u8'Основные настройки редактирования объявлений', 2)
				imgui.Separator()
				imgui.Spacing()
			end
			imgui.SetCursorPosX(wsize.x * (1/12))
			imgui.AlignTextToFramePadding()

			imgui.CustomText(u8(settingsInfo.scriptBuf[i].name))

			imgui.SameLine()
			imgui.SetCursorPosX(wsize.x * (7.5/12))
			imgui.PushItemWidth(100)

			imgui.InputText("##bufsettings" .. i, tempSettings.buf[i], sizeof(tempSettings.buf[i]))

			imgui.PopItemWidth()
			imgui.SameLine()
			imgui.SetCursorPosX(wsize.x * (10.5/12))
			imgui.AlignTextToFramePadding()

			imgui.CustomText(faicon(0xf05a))
			if imgui.IsItemHovered() then
				imgui.SetTooltip(u8(settingsInfo.scriptBuf[i].dis))
			end

		end

		--imgui.Text('\n\n\n\n\n\n')

		--imgui.Spacing()
		--imgui.Spacing()
		--imgui.Spacing()
		imgui.EndChild()
		imgui.Separator()
		imgui.Spacing()

		if imgui.Button(faicon(0xf0c7) .. u8 ' Сохранить все настройки', imgui.ImVec2(-0.1, 0)) then
			tempToSettings()
			printString("~y~Saved!", 1500)
		end
	end,

	function () -- 2

		local wsize = imgui.GetWindowSize()

		imgui.BeginChild('##menuPart2', imgui.ImVec2(0, wsize.y - 33), false)

		imgui.Separator()
			imgui.CustomText(u8'Настройка клавиш ', 2)
		imgui.SameLine(nil, 0)
			imgui.CustomText(faicon(0xf05a))

		if imgui.IsItemHovered() then
			imgui.SetTooltip(u8('Баг: при разворачивании игры, залипает первая клавиша, на которую игру сворачивали.\nИсправление: просто нажать на неё.\n\nПримечание: бинд можно отключить, просто удалив клавишу с помощью Backspace.'))
		end

		imgui.Separator()
		imgui.Spacing()

		for i = 1, #tempSettings.keys do

			imgui.SetCursorPosX(wsize.x * (1/12))
			imgui.AlignTextToFramePadding()

			imgui.CustomText(u8(settingsInfo.keys[i].name))

			imgui.SameLine()
			imgui.SetCursorPosX(wsize.x * (9/12))

			if imgui_addon.HotKey('##tempKeys' .. i, tempSettings.keys[i], 75, 20) then

				if i == 4 and #tempSettings.keys[i].v > 1 then -- Проверка для ПКМ + ...

					tempSettings.keys[i] = { v = settings.keys[i].v }
					util.scriptmsg('Для меню взаимодействия указывается одна клавиша. (ПКМ + ...)')

					printString("~r~Only one key!", 1500)

				end

				for a = 1, #tempSettings.keys do -- Проверка на существующие комбинации

					if a ~= i and tempSettings.keys[a].v[1] == tempSettings.keys[i].v[1]
						and tempSettings.keys[a].v[2] == tempSettings.keys[i].v[2]
						and tempSettings.keys[a].v[1] ~= nil and tempSettings.keys[i].v[1] ~= nil then

						tempSettings.keys[i] = { v = settings.keys[i].v }
						printString("~r~Already used!", 1500)

					end

				end

			end
		end

		imgui.EndChild()

		imgui.Separator()
		imgui.Spacing()

		if imgui.Button(faicon(0xf0c7) .. u8 ' Сохранить все настройки', imgui.ImVec2(-0.1, 0)) then
			tempToSettings()
			printString("~y~Saved!", 1500)
		end
	end,

	function () -- 3

	end,

	function () -- 4

		settingsRp.setList[0] = 0 -- Раздел информации
		settingsRp.selected = 1 -- "Пример"
		settingsRp.myRpList[0] = 0 -- Устанавливает пользовательский раздел в своих отыгровках

		win_status.main[0] = false
		win_status.settingsMenu[0] = true

	end, -------------------------------------------------- BEFORE

		},
		beforeFunc = {

	function ()
		setTempSettingsScript()
	end,
	function ()
		setTempSettingsScript()
	end,
	function ()

	end,

		},
	}, -------------------------------------------------- ИНФО
	{
		name = '>> Информация',
		part = {'Помощь', 'Шпаргалки', },
		func = {

	function () -- 1

		local wsize = imgui.GetWindowSize()

		imgui.SetCursorPosY(wsize.y * 0.17)

		imgui.CustomText(u8'Разработчик: {ff9933}Skelmer', 2)
		imgui.CustomText(u8'{ff9933}Mass Media Editor{FFFFFF} версии ' .. thisScript().version, 2)
		imgui.CustomText(u8'Разработан специально для серверов Advance RolePlay', 2)

		imgui.Spacing()
		imgui.SetCursorPosX(wsize.x * (0.5) - 140 * 3 * 0.5 - imgui.GetStyle().ItemSpacing.x)

		if imgui.Button(faicon(0xf0c1) .. u8' Группа скрипта', imgui.ImVec2(140, 20)) then
			os.execute('explorer "' .. thisScript().url ..'"')
		end

		imgui.SameLine()

		if imgui.Button(faicon(0xf06a) .. u8' Решение проблем', imgui.ImVec2(140, 20)) then
			os.execute('explorer "https://vk.com/topic-177496337_42380309"')
		end

		imgui.SameLine()

		if imgui.Button(faicon.ICON_ANGLE_DOUBLE_UP .. u8' Предложения', imgui.ImVec2(140, 20)) then
			os.execute('explorer "https://vk.com/topic-177496337_42380302"')
		end

		imgui.SetCursorPosY(wsize.y * 0.6)

		imgui.Separator()
		imgui.CustomText(u8'Команды скрипта', 2)
		imgui.Separator()
		imgui.Spacing()

		imgui.SetCursorPosX(wsize.x * 0.035)

		imgui.BeginGroup()
		imgui.CustomText(u8'{ffff00}/mmeditor*{ffffff} - главное меню')
		imgui.CustomText(u8'{ffff00}/mmrules*{ffffff} - открыть шпаргалки')
		imgui.CustomText(u8'{ffff00}/mmact [id]*{ffffff} - меню взаимодействия')
		imgui.EndGroup()

		imgui.SameLine(nil, 45)

		imgui.BeginGroup()
		imgui.CustomText(u8'{ffff00}/mmnext*{ffffff} - продолжить отыгровку')
		imgui.CustomText(u8'{ffff00}/mmstop*{ffffff} - остановить отыгровку')
		imgui.CustomText(u8'{ffff00}/mmefir{ffffff} - меню радиоэфиров')
		imgui.CustomText(u8'{ffff00}/smsn{ffffff} - Non-RP чат SMS')
		imgui.EndGroup()

		imgui.Spacing()
		imgui.Spacing()
		imgui.CustomText(u8'{ffff00}*{ffffff} - альтернатива клавишам', 2)
		--[[imgui.CustomText(u8'- Стандартные библиотеки MoonLoader: {ff9933}vkeys{FFFFFF}, {ff9933}SAMP Events{FFFFFF}, {ff9933}FFI{FFFFFF} и др.')
		imgui.Spacing()
		imgui.CustomText(u8'- Графическая библиотека {ff9933}Dear Imgui{FFFFFF} v' .. imgui._VERSION)
		imgui.Spacing()
		imgui.CustomText(u8'- Модуль иконок {ff9933}FA-ICONS-4{FFFFFF} (legend2360 & FYP @ blast.hk)')
		imgui.Spacing()
		imgui.CustomText(u8'- Модуль для графической библиотеки {ff9933}ImGui Addons{FFFFFF} v'.. imgui_addon._VERSION ..' (DonHomka @ blast.hk)')
		imgui.Spacing()
		imgui.CustomText(u8'- Библиотеки для работы с {ff9933}сетью{ffffff}.')
		imgui.Spacing()
		imgui.CustomText(u8'- Модуль горячих клавиш {ff9933}rKeys{FFFFFF} v' .. rkeys._VERSION .. ' (DonHomka @ blast.hk)')-]]

	end,
	-- 3
	function () win_status.main[0] = false; win_status.rules[0] = true end,
	-------------------------------------------------- BEFORE
		},
		beforeFunc = { },
	},
}

editVars = { -- переменные для окна редактирования

	from = '', -- отправитель
	ad = '', -- объявление

	appear = false, -- сфокусировать на инпуте
	updAd = false, -- обновление пришедшедших объявлений
	flood = false, -- поиск объявлений
	waitCar = false, -- ожидание остановки машины

	idHookSymb = nil, -- хук сообщения об "Объявление содержит недопустимые символы"
	idHookNo = nil, -- хук сообщения об "Нет новых объявлений"
	idAd = 224, -- номер диалога объявлений
	idHookFlood = nil, -- хук сообщения о флуде

	inputEdit = imgui.new.char[256](),
	x = 0, y = 0,
	adList = {},
}
local editList = {ad = {}, fav = {}}

function editList.add(text)

	local ad = editList.ad

	table.insert(ad, 1, tostring(text))

end
function editList.addFav(id)

	local fav = editList.fav
	local ad = editList.ad

	table.insert(fav, 1, ad[id])
	table.remove(ad, id)

end
function editList.remFav(id)

	local fav = editList.fav
	local ad = editList.ad

	table.insert(ad, 1, fav[id])
	table.remove(fav, id)

end

local searchInput = imgui.new.char[64]() -- инпут поиска в шпорах
local isScriptActive = false -- готовность скрипта к работе

local isOpenStats = false -- окно статистики
local isStatsType = nil -- 1 - проверка статистика, 2 - проверка № аккаунта

util = {} -- утилиты
function util.download(url, dir, read, delete) -- урл, директория, прочесть, удалить

	print(dir)

	local OK = false
	local dtime = os.time() + 10 -- Таймер загрузки

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

		if os.time() > dtime then return false, 'Время ожидания скачивания файла истекло.' end

		wait(1000)

	end

	local dtime = os.time() + 5 -- Таймер чтения
	local file = io.open(dir)

	while file == nil do

		if os.time() > dtime then return false, 'Файл был загружен, но так и не открылся.' end

		wait(100)

	end

	if read then

		local info = file:read('*a')

		file:close()

		if delete then os.remove(dir) end

		return true, info

	end

	if delete and not read then

		file:close()
		os.remove(dir)

	end

	if not delete and not read then file:close() end

	return true
end
function util.fileRead(dir)

	if doesFileExist(dir) then

		local f = io.open(dir, 'r')

		if f then

			local text = f:read('*a')
			f:close()

			return text
		end

	end
end
function util.fileWrite(dir, text, noReWrite)
	local f = noReWrite and io.open(dir, 'a') or io.open(dir, 'w')
	f:write(text)
	f:close()
end
function util.scriptmsg(msg, type_msg)

	local switch_msg = {
		function(text) sampAddChatMessage("{3399FF}[MM Editor]:{CECECE} " .. tostring(msg), 0xCECECE) end, -- простое
		function(text) sampAddChatMessage("{3399FF}[MM Editor]:{fff099} " .. tostring(msg), 0xCECECE) end, -- warn
		function(text) sampAddChatMessage("{CECECE}[MM Editor]:{ff6666} " .. tostring(msg), 0xCECECE) end, -- error
		function(text) sampAddChatMessage(tostring(text), -1) end, -- simple
	}

	switch_msg[type(type_msg) == 'number' and type_msg or 1](msg or '')
end
function util.urlencode(url)

	if url == nil then return end

	url = tostring(url)
	url = url:gsub("\n", "\r\n")
	url = string.gsub(url, "([^%w _%%%-%.~])", function(c) return string.format("%%%02X", string.byte(c)) end)
	url = url:gsub(" ", "+")

	return url
end
function util.saveSettings(array, dir)

	local settings = array or {}

	util.fileWrite(dir, encodeJson(settings))
end
function util.textToJson(text)

	if text == nil then return end

	text:gsub('\t','\\t'):gsub('\n','\\n'):gsub('"','\"')

	return text
end
function util.jsonToText(text)

	if text == nil then return end

	text:gsub('\\t','\t'):gsub('\\n','\n'):gsub('\"','"')

	return text
end
function util.getKeysName(keys)

	if type(keys) ~= "table" then return false end

	local tKeysName = {}

	for k, v in ipairs(keys) do tKeysName[k] = vkeys.id_to_name(v) end

	if #tKeysName == 0 then return u8'—' end

	return table.concat(tKeysName, " + ")

end
function util.split(str, delim, plain)
	local tokens, pos, plain = {}, 1, not (plain == false) --[[ delimiter is plain text by default ]]
	repeat
		local npos, epos = string.find(str, delim, pos, plain)
		table.insert(tokens, string.sub(str, pos, npos and npos - 1))
		pos = epos and epos + 1
	until not pos
	return tokens
end
function util.request(url, desc, body)

	local n = 0

	if desc then print('[REQUEST] ' .. desc) end

	::request::

	local response, code, headers, status = request.run(url, request.build(body))

	n = n + 1

	if response == nil and n ~= 4 then
		print('[REQUEST] Повтор запроса через 3 секунды... ')
		wait(3000)
		goto request
	else
		return response, code, headers, status
	end

end
function util.getPageSize()
	return ffi.cast('struct stChatInfo**', getModuleHandle( 'samp.dll' ) + 0x21A0E4)[0].pagesize
end
function util.setPageSize(lines)

	local lines = type(lines) == 'number' and lines or 10
	local CChat__SetPageSize = getModuleHandle("samp.dll") + 0x636D0;
	local pChat = sampGetChatInfoPtr();
	ffi.cast("int(__thiscall*)(uintptr_t, int)", CChat__SetPageSize)(pChat, lines)

end
function util.takeScreen()
	memory.setuint8(sampGetBase() + 0x119CBC, 1)
end
function util.printTable(...)

	local args = {...}
	function table.val_to_str( v )
			if "string" == type( v ) then
			v = string.gsub( v, "\n", "\\n" )
			if string.match( string.gsub(v,"[^'\"]",""), '^"+$' ) then
					return "'" .. v .. "'"
			end
			return '"' .. string.gsub(v,'"', '\\"' ) .. '"'
			else
			return "table" == type( v ) and table.tostring( v ) or tostring( v )
			end
	end
	function table.key_to_str( k )
			if "string" == type( k ) and string.match( k, "^[_%a][_%a%d]*$" ) then
			return k
			else
			return "[" .. table.val_to_str( k ) .. "]"
			end
	end
	function table.tostring( tbl )
		local result, done = {}, {}
		for k, v in ipairs( tbl ) do
			table.insert( result, table.val_to_str( v ) )
			done[ k ] = true
		end
		for k, v in pairs( tbl ) do
			if not done[ k ] then
					table.insert( result, table.key_to_str( k ) .. "=" .. table.val_to_str( v ) )
			end
		end
		return "{" .. table.concat( result, "," ) .. "}"
	end
	for i, arg in ipairs(args) do
		if type(arg) == "table" then
			args[i] = table.tostring(arg)
		end
	end
	print(table.unpack(args))
end
function util.getSerialNumber()
	local serial = ffi.new("unsigned long[1]", 0)
	ffi.C.GetVolumeInformationA(nil, nil, 0, serial, nil, nil, nil, 0)
	return serial[0]
end

function playerLogin()

	loadText = 'Ожидаем вход игрока...'

	user.server.ip, _ = sampGetCurrentServerAddress()

	for i = 1, #serverList do
		if serverList[i].ip == user.server.ip then user.server.id = i break end
	end

	if not user.server.id then

		util.scriptmsg('Скрипт предназначен для Advance RolePlay серверов.', 2)
		util.scriptmsg('В группе скрипта можно найти версию для Diamond RolePlay.', 2)

		thisScript():unload(); wait(1000)
	end

	local timer = os.time() + 120

	while not sampIsLocalPlayerSpawned() do

		if os.time() >= timer then

			util.scriptmsg('Скрипт не смог обнаружить появление игрока.', 2)
			util.scriptmsg('Возможно, требуется сообщить об этом разработчику, либо перезайти в игру.', 2)

			thisScript():unload(); wait(1000)
		end

		wait(10)
	end

	while true do -- Проверка на ебучее инф. сообщения даймонда
		wait(2000)
		if not sampIsDialogActive() then break end
		loadText = 'Ожидаем закрытия окна...'
	end

	loadText = 'Проверяем статистику игрока...'

	local timer = os.time() + 5

	local warningStats = function()
		util.scriptmsg('Скрипт не смог проверить статистику, так как окно статистики так и не открылось.', 2)
		util.scriptmsg('Возможно, требуется сообщить об этом разработчику, либо перезайти в игру.', 2)

		thisScript():unload(); wait(1000)
	end

	hook.dia.create('Меню (статистика)', nil, 'Меню игрока', true, function(dialogId)

		hook.dia.create('Статистика игрока', nil, 'Статистика игрока', true, function(dialogId, _, text)

			local _, id = sampGetPlayerIdByCharHandle(playerPed)

			user.nick = sampGetPlayerNickname(id)
			user.rang = tonumber(string.match(text,"Ранг:\t\t\t\t{.-}(%d+)\n"))
			user.podr = string.match(text,"Подразделение:\t\t{.-}(.-)\n")
			user.rangName = string.match(text,"Должность:\t\t\t{.-}(.-)\n")
			user.phone = string.match(text,"Номер телефона:\t\t{.-}(%d+)\n")

			user.fullName = (user.nick):gsub('_', ' ')
			user.name = (user.fullName):match('(.-) .-')
			user.family = (user.fullName):match('.- (.-)')

			user.isWork = not string.match(text,"Работа:\t\t\t\t{.-}Безработный\n") and true or false

			if user.podr:find('ЛС') or user.podr:find('Сантос') then user.podrNum = 1
			elseif user.podr:find('СФ') or user.podr:find('Фиерро') then user.podrNum = 2
			elseif user.podr:find('ЛВ') or user.podr:find('Вентурас') then user.podrNum = 3
			elseif user.podr:find('центр') then user.podrNum = 4
			elseif user.podr:find('ТВ') or user.podr:find('Мин') then user.podrNum = 5
			else user.podrNum = 0 end

			sampSendDialogResponse(dialogId, 1, -1, -1)
			return false

		end)

		sampSendDialogResponse(dialogId, 1, 0, -1)
		return false

	end)

	sampSendChat('/mn')

	while user.rangName == nil do

		if os.time() >= timer then warningStats() end

		wait(0)
	end

	sampSendChat('/mn')

	hook.dia.create('Меню (номер аккаунта)', nil, 'Меню игрока', true, function(dialogId)

		hook.dia.create('Донат (меню)', nil, 'Донат |', true, function(dialogId)
			
			hook.dia.create('Донат (номер аккаунта)', nil, 'Донат', true, function(dialogId, _, text)
				hook.dia.create('Донат (меню)', nil, 'Донат |', true, function(dialogId)

					sampSendDialogResponse(dialogId, 0, -1, -1)
					return false

				end)
				
				user.id = tonumber(string.match(text, 'Номер аккаунта:.-(%d+)'))
				sampSendDialogResponse(dialogId, 1, -1, -1)
				return false
			
			end)
			
			sampSendDialogResponse(dialogId, 1, 0, -1)
			return false

		end)

		sampSendDialogResponse(dialogId, 1, 11, -1)
		return false

	end)

	while user.id == nil do

		if os.time() >= timer then warningStats() end

		wait(0)
	end

	if not (user.id and user.rang and user.rangName and user.podr) then

		util.scriptmsg('Скрипт не смог проверить статистику, так как не смог найти необходимые данные.', 3)
		util.scriptmsg('Возможно, требуется сообщить об этом разработчику.', 3)

		print(user.id, user.rang, user.rangName, user.podr)

		thisScript():unload(); wait(1000)
	end

	-- создание папки сервера

	dir.settings = dir.main .. serverList[user.server.id].name .. '\\'
	if not doesDirectoryExist(dir.settings) then createDirectory(dir.settings) end

end
function updateScript()

	loadText = 'Проверяем наличие обновлений...'

	local res = util.request(dir.github .. 'update.json', 'Проверка обновлений.')
	--local res, respons = util.download(dir.github .. 'update.json', dir.temp .. 'update.json', true, true)

	if res then

		updateMessage = decodeJson(res)

		if updateMessage then

			if not updateMessage.online then

				util.scriptmsg('В скрипте что-то сломалось, поэтому он отключен на технические работы.', 2)
				thisScript():unload(); wait(1000)

			end

			if updateMessage.verNum > thisScript().version_num then

				loadText = 'Найдено обновление. Ожидаем вход...'

				while not sampIsLocalPlayerSpawned() do wait(10) end

				loadText = 'Найдено обновление'

				win_status.update[0] = true

				while true do wait(100) end

			end

		else

			util.scriptmsg('Не удалось проверить наличие обновлений. Файл обновления поврежден.', 3)
			thisScript():unload(); wait(1000)

		end

	else

		util.scriptmsg('Не удалось проверить наличие обновлений. Файл обновления не загрузился.', 2)
		thisScript():unload(); wait(1000)

	end

end
function updateHost()

	loadText = 'Получаем обновления с хостинга...'

	local body = { }

	mainMenu.news.nick = 'Admin'
	mainMenu.news.time = 'xx.xx.xx'
	mainMenu.news.msg = u8('Новости пока никто не отправлял, либо они недоступны')
	donators = {}

	--[[
	::retry::

	local res = util.request(dir.host, 'Запрос хостинга.', body)
	local data = decodeJson(res)

	if not data and not notf.rezHost then

		print('Переход на резервный хостинг...')

		dir.host = ''
		notf.rezHost = true

		util.saveSettings(notf, dir.settings .. 'notf.json')

		goto retry

	end

	if data then

		local donate = data.donate or {}
		local news = data.news or {}

		if md5.sumhexa(tostring(news.msg) .. tostring(news.nick) .. kek .. tostring(news.date)) == data.method then

			-- Преобразование в Nick_Name = Server
			for _, val in ipairs(donate) do donators[val.nick] = val.color end

			if data.blacklist then blackList.url = tonumber(data.blacklist.thread); blackList.nick = data.blacklist.nick end

			if not (news.nick == '-') then

				mainMenu.news.nick = news.nick
				mainMenu.news.time = news.date
				mainMenu.news.msg = news.msg

			end

		end

	end
	--]]
end
function loadAnagramm()

	for i = 1, 3 do

		local file = dir.main .. 'words.json'

		if not doesFileExist(file) then

			loadText = 'Загружаем анаграммы для эфира...'

			local res = util.request(dir.github .. 'words.json', 'Скачивание слов для анаграмм.')

			util.fileWrite(file, res)

		end

	end

end

function main()

	if not isSampLoaded() or not isSampfuncsLoaded() then return end
	while not isSampAvailable() do wait(100) end

	local access, _, code = os.rename(script.this.path, script.this.path)

	if not access and code == 13 then

		util.scriptmsg('Нет разрешений на запись файлов скрипта. Смените директорию игры.', 3)
		util.scriptmsg('Пример директории: ' .. getGameDirectory():sub(1, 2) .. '\\Games\\GTA San Andreas.', 3)

		thisScript():unload(); wait(1000)

	end

	math.randomseed(os.time())

	win_status.info[0] = true
	--updateScript()

	if not doesDirectoryExist(dir.main) then createDirectory(dir.main) end

	playerLogin()

	readFileNotf()

	updateHost()

	loadAnagramm()

	readAndLoadBL()

	win_status.info[0] = false

	readMainSettings()
	readEfirSettings()
	readSettingsRp()

	local tableKey = {} -- Переводим ID клавиш в их название
	for i = 1, #settings.keys[1].v do tableKey[#tableKey + 1] = vkeys.id_to_name(settings.keys[1].v[i]) end

	local colorNick = donators[user.nick] and '{' .. donators[user.nick] .. '}' or '{CECECE}'
	local keyMenu = #tableKey == 0 and '.' or ' или клавиша ' .. table.concat(tableKey, " + ") .. '.'

	util.scriptmsg(('Привет, %s %s%s{CECECE}! Скрипт успешно загружен.'):format(util.lower(user.rangName), colorNick, user.fullName))
	util.scriptmsg(('Главное меню скрипта - /mmeditor%s'):format(keyMenu))

	sampRegisterChatCommand('mmeditor', function () mainMenu.selected = {1,1}; win_status.main[0] = not win_status.main[0] end)
	sampRegisterChatCommand('mmrules', function () win_status.rules[0] = not win_status.rules[0] end)
	sampRegisterChatCommand('mmact', cmdAct)
	sampRegisterChatCommand('mmnext', function () settingsRp.wait = false end)
	sampRegisterChatCommand('mmstop', stopRp)
	sampRegisterChatCommand('mmefir', function () openMenuPreEfir() end)

	isScriptActive = true

	hookInit()
	-- updateRules()
	rules = {}
	scriptNotf()

	while true do

		if editVars.flood then

			local win = false

			for k, v in pairs(win_status) do

				if v[0] and not (k == 'info') then win = true end

			end

			if sampIsChatInputActive() or isSampfuncsConsoleActive() or sampIsDialogActive() or editVars.waitCar then win = true end

			if not win then

				loadText = 'Идет поиск новых объявлений...'

				hook.msg[editVars.idHookNo].run = true

				sampSendChat('/edit')

			else

				if not editVars.waitCar then loadText = 'Поиск объявлений приостановлен' end

			end

			wait(tonumber(settings.scriptBuf[5]))
		end
		wait(0)
	end

	--[[addEventHandler('onWindowMessage', function(msg, wparam, lparam)

		if msg == wm.WM_KEYDOWN or msg == wm.WM_SYSKEYDOWN then

			if sampIsDialogActive() or sampIsChatInputActive() then return end

			if wparam == vkeys.VK_L then

			end

		end

	end)]]
end

-- Настройка повторяемости уведомлений и их показ
function readFileNotf()

	local file = dir.settings .. 'notf.json'

	if doesFileExist(file) then

		local text = util.fileRead(file)
		local res = decodeJson(text) or {}

		if res.news then notf.news = res.news end
		if type(res.rezHost) == 'boolean' then notf.rezHost = res.rezHost end

		if notf.rezHost then dir.host = 'rezerv.host' end

	else

		util.saveSettings(notf, file)

	end

end
function scriptNotf()

	if notf.news == '' then notf.news = mainMenu.news.time end

	if mainMenu.news.time ~= notf.news then

		util.scriptmsg('Появилась {00c77b}новая новость{fff099} от управляющего СМИ. Посмотрите в главном меню!', 2)
		notf.news = mainMenu.news.time

	end

	util.saveSettings(notf, dir.settings .. 'notf.json')

end

-- Инициализация хуков
function hookInit()

	local dia = hook.dia
	local msg = hook.msg

	-- ДИАЛОГИ name, id, title, ones, func(dialogId, title, text, button1, button2)

	dia.create('Редактирование объявления', editVars.idAd, 'Публикация объявления', false, function(_, _, text)

		if not settings.scriptBool[3] then return true end

		editVars.ad = text:match('Текст:%s+{FFCC15}(.-)\n')
		editVars.from = text:match('Отправитель:%s+(.-)\n')
		imgui.StrCopy(editVars.inputEdit, '')

		editVars.appear = true

		lua_thread.create(function() -- чтобы объявление не вылетало во время вождения транспортом

			if not editVars.flood then win_status.edit[0] = true return end

			editVars.waitCar = true
			local flash = true

			while true do

				if isCharInAnyCar(PLAYER_PED) then

					local car = storeCarCharIsInNoSave(PLAYER_PED) -- игрок в машине или нет

					if isCharInCar(PLAYER_PED, car) then

						if getDriverOfCar(car) == PLAYER_PED then

							local speed = getCarSpeed(car)

							if not (speed < 10) then

								win_status.info[0] = flash
								loadText = '' .. 'Объявление найдено. Остановите т/с'

								goto flash

							end

						end

					end

				end

				win_status.edit[0] = true; editVars.waitCar = false; win_status.info[0] = true; break

				::flash::

				wait(flash and 1200 or 500)
				flash = not flash

			end

		end)
		return false

	end)

	dia.create('Точное время', nil, 'Точное время', false, function(_, _, text)

		if not settings.scriptBool[1] then return true end

		local h1, m1 = text:match('Время в игре сегодня:\t\t{.-}(%d+) ч (%d+) мин')
		local h2, m2 = text:match('AFK за сегодня:\t\t{.-}(%d+) ч (%d+) мин')
		local h1, m1, h2, m2 = tonumber(h1), tonumber(m1), tonumber(h2), tonumber(m2)

		local h = m1 < m2 and h1 - h2 - 1 or h1 - h2
		local m = m1 < m2 and 60 + (m1 - m2) or m1 - m2

		util.scriptmsg(('Ваш чистый онлайн: %s ч %s мин.'):format(h, m))

		return true
	end)

	dia.create('Список сотрудников', 63, 'онлайн', false, function(_, _, text)

		if not settings.scriptBool[2] then return true end

		local i = 1
		listFind = {}

		for line in string.gmatch(text, '%d+%..-\n') do

			listFind[i] = {}
			local reason

			listFind[i].nick, listFind[i].id, listFind[i].rang, listFind[i].podr, listFind[i].phone, reason
			= line:match("%d+%. (.-)%[(%d+)%]\t(%d+) ранг. (.-)\t(%d+)\t(.-)\n")

			listFind[i].lvl = 0

			listFind[i].afk = false
			listFind[i].mute = false
			listFind[i].jail = false

			local reason = util.split(reason, ", ")
			--util.printTable(reason); print(#reason)
			for a = 1, #reason do

				if reason[a]:match('паузе') then listFind[i].afk = reason[a]
				elseif reason[a]:match('тычк') then listFind[i].mute = reason[a]
				elseif reason[a]:match('тюрьм') then listFind[i].jail = reason[a] end

			end

			i = i + 1

		end

		listFind.selected = 0

		if not win_status.find[0] then win_status.find[0] = true else return false end -- чтобы не создавать новый поток при обновлении окна /find

		lua_thread.create(function() -- закрытие диалога после закрытия окна find (чтобы текстдравы не ломались)

			while win_status.find[0] do wait(0) end

			sampSendDialogResponse(63, 0, -1, -1)

		end)

		return false
	end)

	dia.create('Инфо о сотруднике', 64, 'сотруднике', false, function(_, _, text)

		if not settings.scriptBool[2] then return true end

		listFindInfo = text

		sampSendDialogResponse(64, 1, -1, -1)

		return false
	end)

	blackList.idDia = dia.create('История ников', '.*', 'Прошлые имена', false, function(dialogId, _, text, _, button2)

		local text = text:gsub('{.-}', '')

		if not string.find(text, "История изменения") then

			for nickname in string.gmatch(text, '\t(.-)\n') do

				if blackList.str then break end

				local str = checkNickBL(nickname)

				if str then blackList.str = str end

			end

		end

		hook.dia[blackList.idDia].run = button2 ~= ''

		sampSendDialogResponse(dialogId, 1, -1, -1)

		return false

	end)
	dia[blackList.idDia].run = false

	dia.create('Врем. работа (увол.)', 0, '.*', false, function(_, _, text)

		if text:match('Вы уволились с работы') then user.isWork = false end

		return true

	end)

	-- СООБЩЕНИЯ return true - важен

	msg.create('Врем. работа (устр.)',
		-65281, '^Поздравляем! {.-}Вы устроились', false, function(_, text)

		user.isWork = true

		return true

	end)

	msg.create('Сборщик объявлений',
		13369599, '.- | Отправил .-%[%d+%] %(тел. .-%)', false, function(_, text)

		editList.add(text:match('(.*) | Отправил .-%[%d+%] %(тел. .-%)'))

		return true
	end)

	editVars.idHookSymb = msg.create('Скрытие сообщения о символах',
		-1717986817, '^Объявление содержит недопустимые символы$', true, function()

		return false
	end)
	msg[editVars.idHookSymb].run = false

	editVars.idHookNo = msg.create('Скрытие сообщения об объявлениях',
		-825307393, '^Нет новых объявлений$', true, function()

		return false
	end)
	msg[editVars.idHookNo].run = false

	editVars.idHookFlood = msg.create('Сообщение о флуде',
		1802202111, '^Не флудите$', true, function()

		editVars.flood = false
		win_status.info[0] = false

		util.scriptmsg('Поиск объявлений остановлен из-за анти-флуда.')

		return false
	end)
	msg[editVars.idHookFlood].run = false


	msg.create('Эфир начат',
		1724645631, '%[E%] .- подключился', false, function(_, text)

		local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED)

		if not text:match('%[E%] .+ ' .. sampGetPlayerNickname(id) .. '%[' .. id .. '%] подключился к эфиру') then return true end

		efir.on = true
		efir.time = os.time()

		openMenuEfir()

		if efir.set.bool[2] then -- авторазмер

			efir.pg_size_old = util.getPageSize()
			util.setPageSize(efir.set.bufNum[1])

		end

		efir.calc.efirLine = efir.calc.efirLine + 1

		return true

	end)

	msg.create('Эфир окончен',
		-10092289, '%[E%] .- отключился', false, function(_, text)

		local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED)

		if not text:match('%[E%] .+ ' .. sampGetPlayerNickname(id) .. '%[' .. id .. '%] отключился от эфира') then return true end

		efir.on = false

		endEfir()

		if efir.set.bool[2] then -- авторазмер

			util.setPageSize(efir.pg_size_old)

		end

		if efir.win.onefir[0] then

			efir.win.calls[0] = false
			efir.win.sms[0] = false
			efir.win.onefir[0] = false

		end

		return true

	end)

	msg.create('Эфир SMS',
		-10046721, 'SMS: .- | Отправитель: .- %[т.%d+%]$', false, function(_, text)

		if not efir.on then return true end

		efir.calc.sms = efir.calc.sms + 1

		local sms, nick, phone = text:match('SMS: (.*) | Отправитель: (.-) %[т.(%d+)%]$')

		efir.to.sms[#efir.to.sms + 1] = {
			nick = nick,
			sms = sms,
			phone = tonumber(phone),
		}

		efir.calc.efirLine = efir.calc.efirLine + 1

		return true

	end)

	msg.create('Подключение слушателя',
		-65281, '.-%[%d+%] был {.-}подключен {.-}', false, function(_, text)

		if not efir.on then return true end

		local nick = text:match('(.-)%[%d+%] был')
		setCalls(1, nick, 2)

		efir.calc.efirLine = efir.calc.efirLine + 1

		return true

	end)

	msg.create('Слушатель отключился',
		-65281, '.-%[%d+%] покидает прямой эфир', false, function(_, text)

		if not efir.on then return true end

		local nick = text:match('(.-)%[%d+%] покидает')
		setCalls(2, nick, 2)

		efir.calc.efirLine = efir.calc.efirLine + 1

		return true

	end)

	msg.create('Отключение слушателя',
		-65281, '.-%[%d+%] был {.-}отключён {.-}', false, function(_, text)

		if not efir.on then return true end

		local nick = text:match('(.-)%[%d+%] был')
		setCalls(2, nick, 2)

		efir.calc.efirLine = efir.calc.efirLine + 1

		return true

	end)

	msg.create('Звонок в эфир',
		-65281, '.- позвонил на радио. Вывести', false, function(_, text)

		if not efir.on then return true end

		efir.calc.calls = efir.calc.calls + 1
		efir.calc.efirLine = efir.calc.efirLine + 1

		local nick = text:match('(.-) позвонил')
		setCalls(nil, nick)

		return true

	end)

	msg.create('Фильтр чата эфира', -- !!!!!!!!!!!!!!! return false
		-65281, '.- позвонил на радио. Вывести', false, function(color, text)

		if efir.set.bool[1] and efir.on then

			for i = 1, #efir.set.focusChat do

				local s = efir.set.focusChat[i]

				if color == s.color and text:find(s.msg) then return false end -- {color, 'БАН' .. '\t' .. text}

			end

		end

		return true

	end)

	msg.create('Фикс сообщения эфира',
		-1717960705, '%[.-%]', false, function(color, text)

		if not efir.on then return true end

		efir.calc.efirLine = efir.calc.efirLine + 1

		if not efir.msg_last and efir.set.bool[3] then

			efir.msg_id = 1 -- счетчик сообщений от зафиксированного сообщения
			efir.msg_last = true -- последние сообщение эфира зафиксировано
			efir.pg_size_efir = util.getPageSize()

		end

		return true

	end)

	msg.create('Чат эфира', '.*', '.*', false, function(color, text)

		if not efir.on then return true end

		if efir.msg_last and efir.set.bool[3] then

			efir.msg_id = efir.msg_id + 1

			if efir.msg_id > efir.pg_size_efir then

				util.takeScreen()
				efir.msg_last = false

			end

		end

		return true

	end)

	msg.create('Донат [F]',
		1721355519, '%[F%] .-%[%d+%]:', false, function(color, text)

		local rang, nick, id, write = string.match(text, '^%[F%] (.+) (.-)%[(%d+)%]: (.*)')

		if donators[nick] then return {color, '[F] ' .. rang .. ' {' .. donators[nick] .. '}' .. nick ..'{6699CC}['.. id .. ']: ' .. write} end

		return true

	end)

	msg.create('Донат [R]',
		869033727, '%[R%] .-%[%d+%]:', false, function(color, text)

		local rang, nick, id, write = string.match(text, '^%[R%] (.+) (.-)%[(%d+)%]: (.*)')

		if donators[nick] then return {color, '[R] ' .. rang .. ' {' .. donators[nick] .. '}' .. nick ..'{33CC66}['.. id .. ']: ' .. write} end

		return true

	end)

	--[[
	if efir.on then -- Есть return false


		if color == msg[9].id and text:find(msg[9].title) then -- подключение слушателя
		end

		if color == msg[15].id and text:find(msg[15].title) then -- звонки уже принимаются

			efir.isTo = true

		end

		if color == msg[14].id and text:find(msg[14].title) then -- слушатель отключился
		end

		if color == msg[10].id and text:find(msg[10].title) then -- отключить слушателя
		end

		if color == msg[13].id and text:find(msg[13].title) then -- отключить всех от эфира

			efir.to.connected = {}

		end

		if color == msg[8].id and text:find(msg[8].title) then -- звонок в студию
		end

		if color == msg[12].id and text:find(msg[12].title) then -- звонки и sms выкл

			efir.isTo = false
			efir.to.connected = {}
			efir.to.calls = {}

		end

		if color == msg[11].id and text:find(msg[11].title) then -- звонки и sms вкл

			efir.isTo = true

		end

		if efir.set.bool[1] then -- блок сообщений

		end

		if (color == msg[5].id and (text:find(msg[5].title) or text:find(msg[6].title))) or (color == msg[7].id and text:find(msg[7].title)) then


		end

		if efir.msg_last and efir.set.bool[3] then


		end

	end--]]

end

-- Функции команд
function cmdAct(text)

	local id = tonumber(text:match('(%d+)'))

	if not id then util.scriptmsg('Используйте /mmact [id]') return end

	local res, handle = sampGetCharHandleBySampPlayerId(id)

	if not res then util.scriptmsg('Игрок должен находиться рядом.') return end

	local x1, y1 = getCharCoordinates(PLAYER_PED)
	local x2, y2 = getCharCoordinates(handle)

	if math.sqrt((x1-x2)^2 + (y1-y2)^2) > 5 then util.scriptmsg('Игрок должен находиться рядом.') return end

	userTarget.id = id
	userTarget.nick = sampGetPlayerNickname(userTarget.id)
	userTarget.name = string.gsub(userTarget.nick, '_', ' ')

	win_status.act[0] = true

end

-- Тема
function apply_custom_style()

	local style = imgui.GetStyle()
	local colors = style.Colors
	local clr = imgui.Col
	local ImVec4 = imgui.ImVec4

	style.WindowRounding = 5.0
	style.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)
	style.ChildRounding = 2.0
	style.FrameRounding = 2.0
	style.ItemSpacing = imgui.ImVec2(8.0, 4.0)
	style.ScrollbarSize = 10.0
	style.ScrollbarRounding = 0
	style.GrabMinSize = 8.0
	style.GrabRounding = 1.0
	style.WindowPadding = imgui.ImVec2(8.0, 8.0)
	style.FramePadding = imgui.ImVec2(4.0, 3.0)
	style.DisplayWindowPadding = imgui.ImVec2(22.0, 22.0)
	style.DisplaySafeAreaPadding = imgui.ImVec2(4.0, 4.0)

	colors[clr.Text]                   = ImVec4(1.00, 1.00, 1.00, 1.00)
	colors[clr.TextDisabled]           = ImVec4(0.50, 0.50, 0.50, 1.00)
	colors[clr.WindowBg]               = ImVec4(0.00, 0.00, 0.03, 0.90)
	colors[clr.PopupBg]                = ImVec4(0.00, 0.00, 0.03, 0.95)
	colors[clr.Border]                 = ImVec4(0.43, 0.43, 0.50, 0.30)
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
	colors[clr.PlotLines]              = ImVec4(0.61, 0.61, 0.61, 1.00)
	colors[clr.PlotLinesHovered]       = ImVec4(1.00, 0.43, 0.35, 1.00)
	colors[clr.PlotHistogram]          = ImVec4(0.90, 0.70, 0.00, 1.00)
	colors[clr.PlotHistogramHovered]   = ImVec4(1.00, 0.60, 0.00, 1.00)
	colors[clr.TextSelectedBg]         = ImVec4(0.26, 0.59, 0.98, 0.35)
	--colors[clr.ModalWindowDimBg]       = ImVec4(1.00, 0.98, 0.95, 0.53) -- затемнение при Modal окне

end
imgui.OnInitialize(function()
	apply_custom_style() -- применим кастомный стиль
	local defGlyph = imgui.GetIO().Fonts.ConfigData.Data[0].GlyphRanges
	imgui.GetIO().Fonts:Clear() -- очистим шрифты
	local font_config = imgui.ImFontConfig() -- у каждого шрифта есть свой конфиг
	font_config.SizePixels = 14.0;
	font_config.GlyphExtraSpacing.x = 0.1
	-- основной шрифт
	local def = imgui.GetIO().Fonts:AddFontFromFileTTF(getFolderPath(0x14) .. '\\trebucbd.ttf', font_config.SizePixels, font_config, defGlyph)

	local config = imgui.ImFontConfig()
	config.MergeMode = true
	config.PixelSnapH = true
	config.FontDataOwnedByAtlas = false
	config.GlyphOffset.y = 1.0 -- смещение на 1 пиксеот вниз
	local fa_glyph_ranges = imgui.new.ImWchar[3]({ faicon.min_range, faicon.max_range, 0 })
	-- иконки
	local faicon = imgui.GetIO().Fonts:AddFontFromMemoryCompressedBase85TTF(faicon.get_font_data_base85(), font_config.SizePixels, config, fa_glyph_ranges)

	imgui.GetIO().ConfigWindowsMoveFromTitleBarOnly = true
	imgui.GetIO().IniFilename = nil
end)

-- Черный список
blackList = {
	set = {bool = true, text = '',},
	update = true, -- возможность производить сетевые действия с ЧС
	test_text = nil, -- полученный ЧС
	tmp_th = 0, -- последняя успешная проверка номера темы
	sended = nil, -- успех отправки номера темы
	str = nil, -- найденная строка ЧС
}
function readAndLoadBL()

	local file = dir.settings .. 'blacklist.json'

	if doesFileExist(file) then

		local text = util.fileRead(file)
		local info = decodeJson(text) or {}

		if type(info.bool) == 'boolean' then blackList.set.bool = info.bool end

		if blackList.set.bool and blackList.url then -- есть ссылка и включена настройка

			loadText = 'Загружаем черный список...'

			getOnlineBL(blackList.url)

			while not blackList.update do wait(0) end

			if blackList.test_text then -- false - нет тегов, либо форум недоступен

				blackList.set.text = blackList.test_text
				util.saveSettings(blackList.set, dir.settings .. "blacklist.json")

			else

				blackList.url = nil
				blackList.set.text = info.text

			end

		else

			blackList.set.text = info.text

		end

	else

		if blackList.url and blackList.set.bool then getOnlineBL(blackList.url) else return end

		loadText = 'Загружаем черный список...'

		while not blackList.update do wait(0) end

		if blackList.test_text then

			blackList.url = nil
			blackList.set.text = blackList.test_text
			util.saveSettings(blackList.set, dir.settings .. "blacklist.json")

		end

	end

end
function updateButtonBL()

	if blackList.update and blackList.url and blackList.set.bool then

		if imgui.Button(faicon(0xf021) .. u8' Обновить', imgui.ImVec2(250,0)) then

			blackList.update = false

			request.run('https://forum.advance-rp.ru/threads/.'.. tostring(blackList.url)..'/', nil,
			function(response, code, headers, status)
				if response then
					getOnlineBL(nil, response)
				else
					print(url, 'Error', code)
				end
			end)
		end

	else

		if blackList.url and blackList.set.bool then

			local color = imgui.ImVec4(0.5, 0.5, 0.5, 1.0)

			imgui.CustomButton(faicon(0xf021) .. u8' Обновление...', color, color, color, imgui.ImVec2(250,0))

		else

			if imgui.Button(faicon(0xf0c7) .. u8 ' Сохранить', imgui.ImVec2(250, 0)) then

				blackList.set.text = u8:decode(str(mainMenu.bufNews))
				util.saveSettings(blackList.set, dir.settings .. "blacklist.json")

				printString("~y~Saved!", 1500)
			end

		end

	end
end
function getOnlineBL(url, res)

	blackList.update = false
	blackList.tmp_th = tonumber(url)

	if not url and res then

		blackList.update = true

		res = res:match('<body.->(.*)</body>'):gsub('<.->', ''):gsub('%[.-%]', ''):gsub('&.-;', ''):gsub('\t', '')

		local black = ''

		for str in string.gmatch(res, '%-M%-(.-)%-ME%-') do black = black .. str end

		if black ~= '' then

			blackList.set.text = black:gsub('\n\n', '\n')
			imgui.StrCopy(mainMenu.bufNews, blackList.set.text)
			util.saveSettings(blackList.set, dir.settings .. "blacklist.json")

		end

		return
	end

	request.run('https://forum.advance-rp.ru/threads/.'.. tostring(url)..'/', nil,
		function(res, code, headers, status)

			if res then

				res = res:match('<body>(.*)</body>'):gsub('<.->', ''):gsub('%[.-%]', ''):gsub('&.-;', ''):gsub('\t', '')

				local black = ''

				for str in string.gmatch(res, '%-M%-(.-)%-ME%-') do black = black .. str end

				blackList.test_text = black == '' and false or black:gsub('\n\n', '\n')

			else

				blackList.test_text = false

			end

			blackList.update = true

		end)


end
function sendOnlineBL(url)

	-- вырезано. Отправка ссылки черного листа на сервер для дальнейшего использования другими игроками

end
function checkNickBL(nick) -- проверяет ник игрока на ЧС и возвращает строку

	local text = (blackList.set.text .. '\n'):gsub(' ', '_')
	local id_1, id_2 = text:find(nick .. '.-\n')

	if id_1 and id_2 then return text:gsub('_', ' '):sub(id_1, id_2) end

	return false

end
function startCheckBL(nick)

	blackList.str = nil

	local str = checkNickBL(nick)

	if not str then

		hook.dia[blackList.idDia].run = true
		sampSendChat('/history ' .. nick)

	else

		blackList.str = str

	end

	while hook.dia[blackList.idDia].run do wait(0) end

	return blackList.str or false

end

-- Информационный оверлей
imgui.OnFrame(
	function () return win_status.info[0] end,
	function (player)

		player.HideCursor = true

		local posX, posY = w - 150, h - 50

		if isCharInAnyCar(PLAYER_PED) then

			local car = storeCarCharIsInNoSave(PLAYER_PED)

			if isCharInCar(PLAYER_PED, car) then

				if getDriverOfCar(car) == PLAYER_PED then posY = h - 120 end

			end

		end

		imgui.SetNextWindowPos(imgui.ImVec2(posX,posY), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(250, 50))
		imgui.SetNextWindowBgAlpha(0.65)

		local flags = imgui.WindowFlags.NoDecoration + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoNav

		imgui.Begin('##overlayInfo', nil, flags)

		imgui.CustomText(u8'{ff9933}Mass Media Editor', 2)
		imgui.Separator()
		imgui.CustomText(u8(loadText), 2)

		imgui.End()
	end
)

-- Окно редактирования
local edit_callback = ffi.cast('int (*)(ImGuiInputTextCallbackData* data)', function (data)

	if editVars.appear then
		data.CursorPos = data.BufTextLen
		editVars.appear = false
	end

	return 0
end)
imgui.OnFrame(
	function () return win_status.edit[0] end,
	function (player)

		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(700, 180), imgui.Cond.FirstUseEver)
		imgui.Begin(faicon(0xf044) .. u8" Редактирование объявления", nil,
			imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

		local wsize = imgui.GetWindowSize()
		local pos = imgui.GetWindowPos()
		editVars.x, editVars.y = pos.x, pos.y

		imgui.CustomText(faicon(0xf007) .. u8" Отправитель объявления: " .. u8(editVars.from))
		imgui.CustomText(faicon(0xf15c) .. u8" Объявление: ")

		imgui.SameLine(0,0)
		imgui.TextWrapped(u8(editVars.ad))

		imgui.Spacing()
		imgui.SetCursorPos(imgui.ImVec2(wsize.x * (1/5) - 70, 90 - 8))

		if imgui.Button(faicon(0xf24d) .. u8' Вставка "Как есть"', imgui.ImVec2(140, 20)) then
			imgui.StrCopy(editVars.inputEdit, u8(settings.scriptBuf[6] .. ' ' .. editVars.ad))
			editVars.appear = true
		end

		imgui.SameLine()
		imgui.SetCursorPosX(wsize.x * (4/5) - 70)

		if imgui.Button(faicon(0xf071) .. u8' Вставка "ПРО"', imgui.ImVec2(140, 20)) then
			imgui.StrCopy(editVars.inputEdit, u8(settings.scriptBuf[6] .. ' ' .. settings.scriptBuf[4]))
			editVars.appear = true
		end

		imgui.Spacing()
		imgui.SetCursorPosX(wsize.x / 2 - 300)
		imgui.PushItemWidth(600)

		imgui.InputTextWithHint(
			"##editInput",
			u8'Текст объявления...',
			editVars.inputEdit,
			sizeof(editVars.inputEdit),
			imgui.InputTextFlags.CallbackAlways,
			edit_callback
		)

		imgui.PopItemWidth()
		imgui.Spacing()
		imgui.SetCursorPosX(wsize.x * (1/5) - 75)

		if editVars.appear then imgui.SetKeyboardFocusHere(-1) end

		if imgui.Button(faicon(0xf058) .. u8 ' Отправить', imgui.ImVec2(150, 25)) then
			if str(editVars.inputEdit):len() ~= 0 then
				win_status.edit[0] = false
				sampSendDialogResponse(editVars.idAd, 1, -1, u8:decode(str(editVars.inputEdit)))
			end
		end

		imgui.SameLine()
		imgui.SetCursorPosX(wsize.x / 2 - 90)

		if imgui.Button(faicon.ICON_PENCIL .. u8' AutoEdit', imgui.ImVec2(90, 20)) then
			imgui.StrCopy(editVars.inputEdit, u8(''))
			editVars.appear = true
		end

		imgui.SameLine()

		if imgui.Button(faicon(0xf0e2) .. u8' Отменить', imgui.ImVec2(90, 20)) then
			win_status.edit[0] = false
			hook.msg[editVars.idHookSymb].run = true
			editVars.flood = false
			win_status.info[0] = false
			sampSendDialogResponse(editVars.idAd, 1, -1, '{}')
		end

		imgui.SameLine()
		imgui.SetCursorPosX(wsize.x * (4/5) - 75)

		if imgui.Button(faicon(0xf057) .. u8' Отклонить', imgui.ImVec2(150, 25)) then
			win_status.edit[0] = false
			sampSendDialogResponse(editVars.idAd, 0, -1, u8:decode(str(editVars.inputEdit)))
		end

		imgui.End()
	end
)
imgui.OnFrame(
	function () return win_status.edit[0] end,
	function (player)

		imgui.SetNextWindowPos(imgui.ImVec2(editVars.x + 350, editVars.y + 130 + 185), nil, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(700, 260), imgui.Cond.FirstUseEver)

		local flags = imgui.WindowFlags.NoDecoration + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoNav

		imgui.Begin('##listAds', nil, flags)

		local wsize = imgui.GetWindowSize()

		local searchText = util.upper(u8:decode(str(editVars.inputEdit)))
		local goSearch = searchText:len() ~= 0

		imgui.Spacing()

		imgui.BeginChild('##listAd', imgui.ImVec2(imgui.GetWindowContentRegionWidth(), wsize.y - 45), false)
		imgui.Separator()
		imgui.Columns(2, nil, false)
		imgui.SetColumnWidth(-1, 26)
		imgui.CustomText(faicon.ICON_STAR)

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, wsize.x - 30)
		imgui.CenterColumnText(u8'Объявления')

		imgui.SameLine()

		imgui.CustomText(faicon(0xf05a))
		if imgui.IsItemHovered() then
			imgui.SetTooltip(u8('ПКМ убирает/добавляет объявление в избранное\n\nПримечание: в списке объявлений находятся объявления только из чата'))
		end

		imgui.NextColumn()
		imgui.Separator()

		for i = 1, #editList.ad + #editList.fav do

			local ad, fav = editList.ad, editList.fav
			local a = #fav < i and i - #fav or i -- разница между ad и fav
			local current = #fav < i and ad[a] or fav[i] -- fav или ad

			if goSearch then

				local current = util.upper(current)

				if not (current:find(searchText, 1, true)) then
					goto nextSearch
				end

			end

			if imgui.Selectable('##' .. i, false, imgui.SelectableFlags.SpanAllColumns) then

				imgui.StrCopy(editVars.inputEdit, u8(current))

				editVars.appear = true

			end

			if imgui.IsItemHovered() and imgui.IsMouseClicked(1) then -- КЛИК ПКМ
				if a == i and #fav ~= 0 then editList.remFav(i) else editList.addFav(a) end
			end

			imgui.SameLine(-0.1,1)
			imgui.CustomText((a == i and #fav ~= 0) and '{ffff00}' .. faicon.ICON_STAR or '')

			imgui.NextColumn()

			imgui.CustomText(u8(current))

			imgui.NextColumn()

			::nextSearch::

		end

		imgui.EndChild()



		imgui.End()
	end
)

-- Окно /find
--listFind = {} -- id, name, lvl, phone, afk, mute, rang, podr
imgui.OnFrame(
	function () return win_status.find[0] end,
	function (player)
		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(590, 18*(#listFind) + 62 + 20))
		imgui.Begin(faicon(0xf0c0) .. u8" Список сотрудников онлайн##find", win_status.find,
			imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
		imgui.Columns(4, '##findcolumn', true)
		imgui.Separator()
		imgui.SetColumnWidth(-1, 220)
		imgui.CenterColumnText(faicon(0xf2c2) .. u8' Никнейм')
		imgui.NextColumn()
		imgui.SetColumnWidth(-1, 215)
		imgui.CenterColumnText(faicon(0xf163) .. u8' Должность')
		imgui.NextColumn()
		imgui.SetColumnWidth(-1, 85)
		imgui.CenterColumnText(faicon(0xf10b) .. u8' Телефон')
		imgui.NextColumn()
		imgui.SetColumnWidth(-1, 70)
		imgui.CenterColumnText(u8'Статус')
		imgui.Separator()
		for i = 1, #listFind do
			imgui.NextColumn()
				if imgui.Selectable(('%s [%s]##%d'):format(listFind[i].nick, listFind[i].id, i),
				listFind.selected == i, imgui.SelectableFlags.SpanAllColumns) then
					listFind.selected = i
					imgui.OpenPopup("findPopup")
				end
			imgui.NextColumn()
				imgui.CustomText(('[%s] %s'):format(listFind[i].rang, u8(listFind[i].podr)))
			imgui.NextColumn()
				imgui.CustomText(listFind[i].phone)
			imgui.NextColumn()
				if listFind[i].afk then
					imgui.CustomText(faicon(0xf017))
					if imgui.IsItemHovered() then
						imgui.SetTooltip(u8(listFind[i].afk))
					end
					imgui.SameLine()
				end
				if listFind[i].mute then
					imgui.Indent(21)
					imgui.CustomText(faicon.ICON_VOLUME_DOWN)
					if imgui.IsItemHovered() then
						imgui.SetTooltip(u8(listFind[i].mute))
					end
					imgui.Unindent(21)
					imgui.SameLine()
				end
				if listFind[i].jail then
					imgui.Indent(40)
					imgui.CustomText(faicon(0xf05e))
					if imgui.IsItemHovered() then
						imgui.SetTooltip(u8(listFind[i].jail))
					end
					imgui.Unindent(40)
					imgui.SameLine()
				end
				imgui.Text('')
			--imgui.Separator()
		end
		imgui.Columns(1)
		imgui.Separator()
		imgui.CustomText(u8'Всего онлайн: ' .. #listFind, 2)
		if imgui.BeginPopup("findPopup") then

			imgui.CustomText(u8'Взаимодействие с ' .. listFind[listFind.selected].nick)

			if imgui.Button(faicon(0xf05a) .. u8 ' Подробнее', imgui.ImVec2(-0.1, 0)) then

				sampSendDialogResponse(63, 1, listFind.selected - 1, -1)
				imgui.CloseCurrentPopup()

				listFindInfo = nil
				listFind.selected = 0
				win_status.findInfo[0] = true

			end

			if imgui.Button(faicon.ICON_USER_SECRET .. u8 ' Старший состав', imgui.ImVec2(-0.1, 0)) then
				settingsRp.selectedButton = 6
				imgui.OpenPopup("customPopupF")
			end

			if imgui.Button(faicon.ICON_PLUS_CIRCLE .. u8 ' Пользовательские', imgui.ImVec2(-0.1, 0)) then
				settingsRp.selectedButton = 7
				imgui.OpenPopup("customPopupF")
			end

			if imgui.BeginPopup("customPopupF") then

				popupForRp()

				imgui.EndPopup()

			end

			imgui.EndPopup()
		end
		imgui.End()
	end
)
imgui.OnFrame(
	function () return win_status.findInfo[0] end,
	function (player)
		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(400, 232))

		imgui.Begin("##findInfo", nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoNav + imgui.WindowFlags.NoDecoration)

		imgui.BeginChild("##findInfoChild", imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 192), true)

		if listFindInfo then

			imgui.CustomText(u8(listFindInfo))

		else

			local wsize = imgui.GetWindowSize()

			imgui.SetCursorPosY(wsize.y / 2 - 35)
			imgui.SetCursorPosX(wsize.x / 2 - 40)
			imgui_addon.Spinner("##loadRules", 40, 4, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.5, 0.5, 0.5, 1.0)))
			imgui.SetCursorPosY(wsize.y / 2)
			imgui.CustomText(u8('Загрузка'), 2)
		end

		imgui.EndChild()

		if imgui.Button(u8 ' Закрыть', imgui.ImVec2(-0.1, 0)) then
			win_status.findInfo[0] = false
		end

		imgui.End()
	end
)

-- Окно шпор
local isUpdateRules = true
function updateRules(res)

	--[[local res, info = util.download(
		dir.github .. 'rules_' .. user.server.id .. '.json',
		dir.temp .. 'rules.json',
		true, true
	)--]]

	if not res then
		res = util.request(dir.github .. 'rules_' .. user.server.id .. '.json', 'Проверка правил.')
	end

	if res then

		util.fileWrite(dir.settings .. "rules.json", res)
		rules = decodeJson(res) or {}

	else

		util.scriptmsg('Произошла ошибка обновления шпаргалок.')

		if doesFileExist(dir.settings .. "rules.json") then

			local infoFile = util.fileRead(dir.settings .. 'rules.json')
			rules = decodeJson(infoFile) or {}

			util.scriptmsg('Загружены шпаргалки из файла.')
		end

	end

	rules = rules or {}
	isUpdateRules = true

end
function updateButton()
	if isUpdateRules then

		if imgui.Button(faicon(0xf021) .. u8' Обновить', imgui.ImVec2(150,20)) then

			isUpdateRules = false

			request.run(dir.github .. 'rules_' .. user.server.id .. '.json', nil,
			function(response, code, headers, status)
				if response then
					updateRules(response)
				else
					print(url, 'Error', code)
				end
			end)
		end

	else

		local color = imgui.ImVec4(0.5, 0.5, 0.5, 1.0)

		imgui.CustomButton(faicon(0xf021) .. u8' Обновить', color, color, color, imgui.ImVec2(150,20))
		imgui.SameLine()
		imgui_addon.Spinner("##loadRules", 7, 2, imgui.ColorConvertFloat4ToU32(color))

	end
end
imgui.OnFrame(
	function () return win_status.rules[0] end,
	function (player)
		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(750, 450))

		imgui.Begin(faicon(0xf02e) .. u8' Шпаргалки##shpor', win_status.rules,
			imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

		local wsize = imgui.GetWindowSize()

		if rules[1] == nil then

			imgui.SetCursorPosY(wsize.y / 2 - 20)
			imgui.CustomText(faicon(0xf071) .. u8' Шпаргалки временно недоступны ' .. faicon(0xf071), 2)

			imgui.Spacing()

			imgui.SetCursorPosX(wsize.x / 2 - 75)
			updateButton()

			goto rulesNil
		end

		imgui.SetCursorPosX(wsize.x * (1/5) - 75)
		updateButton()

		imgui.SameLine()

		imgui.CustomText(u8'Версия ' .. rules[1].date, 2)
		imgui.SameLine()

		imgui.SetCursorPosX(wsize.x * (4/5) - 75)
		imgui.PushItemWidth(150)
		imgui.InputTextWithHint("##searchInput", faicon(0xf002) .. u8' Поиск...', searchInput, sizeof(searchInput))
		imgui.PopItemWidth()

		imgui.Spacing()

		imgui.BeginChild("##childRules", imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 385), true)

		if imgui.BeginTabBar("##shporTabs") then

			local searchText = util.upper(u8:decode(str(searchInput)))
			local goSearch = searchText:len() ~= 0

			for i = 1, #rules do -- Табы

				if imgui.BeginTabItem(rules[i].name .. "##" .. i) then

					for a = 1, #rules[i].contents do -- Главы

						local rulesText, rulesHead = util.upper(u8:decode(rules[i].contents[a].text)),
						util.upper(u8:decode(rules[i].contents[a].head))

						if goSearch then
							if not (rulesText:find(searchText, 1, true) or rulesHead:find(searchText, 1, true)) then
								goto nextSearch
							end
						end

						if imgui.CollapsingHeader(rules[i].contents[a].head) then

							for str in string.gmatch(rules[i].contents[a].text .. '\n', '.-\n') do -- Текст
								imgui.TextWrapped(str)
							end

						end
						::nextSearch::
					end

					imgui.EndTabItem()
				end
			end

			imgui.EndTabItem()
		end

		imgui.EndChild()

		::rulesNil::

		imgui.End()
	end
)

-- Окно обновления
imgui.OnFrame(
	function () return win_status.update[0] end,
	function (player)
		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(600, 300))

		imgui.Begin(faicon(0xf021) .. u8' Автообновление', nil,
			imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)

		imgui.CustomText(u8(('Найдено обновление MM Editor ARP %s'):format(updateMessage.verName)), 2)

		imgui.BeginChild("##childUpdate", imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 215), true)

			for i = 1, #updateMessage.update - thisScript().version_num do

				local text = ('\t[%s]\t%s\n\n'):format(updateMessage.update[i].date, updateMessage.update[i].text)
				imgui.TextWrapped(text)

			end

		imgui.EndChild()

		imgui.Spacing()

		if imgui.Button(u8'Загрузить обновление',imgui.ImVec2(-0.1, 0)) then

			win_status.update[0] = false

			lua_thread.create(function()

				local res = util.download(dir.github .. 'MMEditorDRP.luac', thisScript().path, false, false)

				if res then
					thisScript():reload()
				else

					util.scriptmsg('Не удалось загрузить обновленный скрипт.', 3)
					util.scriptmsg('Решение распространненых проблем можно найти в группе ВК скрипта.', 3)

					thisScript():unload()
				end

			end)
		end

		imgui.End()
	end
)

-- Окно взаимодействия
imgui.OnFrame(
	function () return win_status.act[0] end,
	function (player)

		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(330, 105))

		imgui.Begin(faicon(0xf007) .. u8" Взаимодействие с игроком " .. userTarget.nick, win_status.act,
			imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

		if imgui.Button(faicon.ICON_USER_SECRET .. u8 ' Старший состав', imgui.ImVec2(-0.1, 0)) then
			settingsRp.selectedButton = 3
			imgui.OpenPopup("customPopupT")
		end

		if imgui.Button(faicon(0xf11c) .. u8 ' Собеседование', imgui.ImVec2(-0.1, 0)) then
			settingsRp.selectedButton = 4
			imgui.OpenPopup("customPopupT")
		end

		if imgui.Button(faicon.ICON_PLUS_CIRCLE .. u8 ' Пользовательские', imgui.ImVec2(-0.1, 0)) then
			settingsRp.selectedButton = 5
			imgui.OpenPopup("customPopupT")
		end

		if imgui.BeginPopup("customPopupT") then

			popupForRp()

			imgui.EndPopup()
		end

		imgui.End()
	end
)

-- Меню эфиров
function readEfirSettings()

	local dir = dir.settings .. 'settingsEfir.json'

	if doesFileExist(dir) then

		local text = util.fileRead(dir)
		local info = decodeJson(text) or {}

		local rp = info.dataRp
		local focusChat = info.focusChat
		local bool = info.bool
		local bufNum = info.bufNum
		local bufNote = info.note
		local firstRp = info.firstRp
		local lastRp = info.lastRp
		local bufAnagSub = info.anagSub
		local firstLetter = info.firstLetter

		if rp then

			for a, data in ipairs(rp) do

				efir.set.dataRp[a] = {
					name = data.name,
					text = data.text,
				}

			end

		end

		if focusChat then

			if #focusChat > 0 then efir.set.focusChat = {} end -- есди в файле настроек меньше focusChat, чем в дефолте скрипта, то он бы оставил разницу

			for a, data in ipairs(focusChat) do

				efir.set.focusChat[a] = {
					name = data.name,
					msg = data.msg,
					color = data.color,
				}

			end


		end

		if bool then

			for i = 1, #efir.set.bool do efir.set.bool[i] = bool[i] or false end

		end

		if bufNum then

			for i = 1, #efir.set.bufNum do efir.set.bufNum[i] = bufNum[i] end

		end

		if bufNote ~= nil then efir.set.note = bufNote end
		if bufAnagSub ~= nil then efir.set.anagSub = bufAnagSub end
		if firstRp ~= nil then efir.firstRpList = imgui.new.int(firstRp - 1) end
		if lastRp ~= nil then efir.lastRpList = imgui.new.int(lastRp - 1) end
		if firstLetter ~= nil then efir.firstLetter = imgui.new.bool(firstLetter) end

	end

end
function setTempSettingsEfir()
	tempSettingsEfir = {
		bool = {},
		bufNum = {},
	}

	for i = 1, #efir.set.bool do tempSettingsEfir.bool[i] = imgui.new.bool(efir.set.bool[i]) end
	for i = 1, #efir.set.bufNum do tempSettingsEfir.bufNum[i] = imgui.new.int(efir.set.bufNum[i]) end

end
function updateFirstCombo(sbros) -- составитель Combo "отыгровка в начале эфира"

	efir.firstRpChapter = {u8'нет'}

	for i, data in ipairs(efir.set.dataRp) do
		efir.firstRpChapter[#efir.firstRpChapter + 1] = u8(data.name)
	end

	if sbros then
		efir.firstRpList[0] = 0
		efir.lastRpList[0] = 0
	end

	efir.firstRpItems = imgui.new['const char*'][#efir.firstRpChapter](efir.firstRpChapter)

end
function openMenuPreEfir()

	if not efir.on then

		setTempSettingsEfir()
		updateFirstCombo()

		win_status.efir[0] = true

	else

		efir.win.onefir[0] = true

	end

end
function openMenuEfir()

	updateFirstCombo()

	imgui.StrCopy(efir.bufNote, u8(efir.set.note))

	imgui.StrCopy(efir.bufAnagSub, u8(efir.set.anagSub))
	imgui.StrCopy(efir.bufMsg, '')
	imgui.StrCopy(efir.bufAnag, '')

	efir.calc.sms = 0
	efir.calc.calls = 0
	efir.calc.efirLine = 0

	if win_status.efir[0] then

		win_status.efir[0] = false
		efir.win.calls[0] = false
		efir.win.sms[0] = false
		efir.win.onefir[0] = true

	end

end
function endEfir()

	efir.set.note = u8:decode(str(efir.bufNote))
	efir.set.lastRp = efir.lastRpList[0] + 1
	efir.set.anagSub = u8:decode(str(efir.bufAnagSub))
	efir.set.firstLetter = efir.firstLetter[0]

	util.saveSettings(efir.set, dir.settings .. 'settingsEfir.json')

	local tableToSafe = {
		calc = efir.calc,
		score = efir.to.score,
		date = os.date("%d.%m.%Y %X", efir.time),
		time = os.date("%M:%S", os.time() - efir.time),
	}

	util.saveSettings(tableToSafe, dir.settings .. 'lastEfir.json')

end
function changeScore(nick, phone, score, math, onlysort)

	local is = false

	if onlysort then goto sort end

	for i, data in ipairs(efir.to.score) do

		if data.nick == nick then

			data.score = math and data.score + score or score
			data.phone = phone
			is = true
			break

		end

	end

	if not is then

		local table = efir.to.score

		table[#table + 1] = {
			nick = nick or 'Somebody',
			phone = phone or 0,
			score = score,
		}

	end

	::sort::

	table.sort(efir.to.score, function(a, b) return (a.score > b.score) end)

end
function getWordForAnag(type_an)

	local type_an = type(type_an) == 'number' and type_an or 1

	local getFile = function(num) return dir.main .. 'anagramm_' .. num .. '.txt' end

	local json = util.fileRead(dir.main .. 'words.json')
	local words = decodeJson(json) or {}

	local word = words[type_an][math.random(1, #words[type_an])]

	return word

end
function createAnag(word, sub, firstLetter)

	local sub = sub and sub or ''

	local stringToArray = function (str)
		local t = {}
		for i = 1, #str do
			t[i] = str:sub(i, i)
		end
		return t
	end
	local shuffle = function (array)
		for i = 1, #array do
			local j = math.random(#array)
			array[i], array[j] = array[j], array[i]
		end
		return array
	end

	local letters = stringToArray(word)
	if firstLetter then letters[1] = util.upper(letters[1]) end
	local anagramm = table.concat(shuffle(letters), sub)

	return anagramm

end

imgui.OnFrame( -- меню предэфира
	function () return win_status.efir[0] end,
	function (player)

		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(600, 350))

		imgui.Begin(faicon.ICON_BULLHORN .. u8' Меню эфиров',
		win_status.efir, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

		local wsize = imgui.GetWindowSize()

		if buttonResult then

			local info = efir.lastResults

			if info.date ~= nil then

				imgui.Separator()
				imgui.CustomText(u8'Статистика последнего эфира (' .. info.date .. ')', 2)
				imgui.Separator()
				imgui.Spacing()

				imgui.SetCursorPosY(wsize.y - 285)
				imgui.SetCursorPosX(wsize.x * (2/12))
				imgui.CustomText(u8'Время проведенного эфира:')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (9/12))
				imgui.CustomText(info.time)

				imgui.SetCursorPosX(wsize.x * (2/12))
				imgui.CustomText(u8'Количество строк эфира:')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (9/12))
				imgui.CustomText(tostring(info.calc.efirLine))

				imgui.SetCursorPosX(wsize.x * (2/12))
				imgui.CustomText(u8'Принято всего SMS-сообщений:')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (9/12))
				imgui.CustomText(tostring(info.calc.sms))

				imgui.SetCursorPosX(wsize.x * (2/12))
				imgui.CustomText(u8'Количество позвонивших в студию:')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (9/12))
				imgui.CustomText(tostring(info.calc.calls))

				imgui.Spacing()

				imgui.SetCursorPosY(wsize.y - 194)
				imgui.BeginChild('##efirResults', imgui.ImVec2(0, 156), true)

				imgui.Columns(5, nil, false)
				imgui.VerticalSeparator()
				imgui.SetColumnWidth(-1, 30)
				imgui.CenterColumnText(u8'№')

				imgui.NextColumn()
				imgui.VerticalSeparator()
				imgui.SetColumnWidth(-1, 95)
				imgui.CenterColumnText(faicon(0xf10b) .. u8' Телефон')

				imgui.NextColumn()
				imgui.VerticalSeparator()
				imgui.SetColumnWidth(-1, 240)
				imgui.CenterColumnText(faicon(0xf2c2) .. u8' Никнейм')

				imgui.NextColumn()
				imgui.VerticalSeparator()
				imgui.SetColumnWidth(-1, 40)
				imgui.CenterColumnText(faicon.ICON_STAR)
				if imgui.IsItemHovered() then
					imgui.SetTooltip(u8('Количество баллов'))
				end

				imgui.NextColumn()
				imgui.VerticalSeparator()
				imgui.CenterColumnText(faicon(0xf013) .. u8' Действие')

				imgui.NextColumn()
				imgui.Separator()

				for i = 1, #efir.lastResults.score do

					local info = efir.lastResults.score[i]

					if info ~= nil then

						imgui.CustomText(tostring(i))

						imgui.NextColumn()
							imgui.CustomText(tostring(info.phone))
							if imgui.IsItemClicked(1) then setClipboardText(tostring(info.phone)) end

						imgui.NextColumn()
							imgui.CustomText(info.nick)
							if imgui.IsItemClicked(1) then setClipboardText(info.nick) end

						imgui.NextColumn()
							imgui.CustomText(tostring(info.score))

						imgui.NextColumn()
							imgui.PushIDInt(i)
							--if imgui.Button(faicon.ICON_CLONE .. u8' ник', imgui.ImVec2(50, 0)) then
							if imgui.SmallButton(u8'Коп. ник') then

								setClipboardText(info.nick)

							end
							imgui.SameLine()
							--if imgui.Button(faicon.ICON_CLONE .. u8' номер', imgui.ImVec2(50, 0)) then
							if imgui.SmallButton(u8'Коп. номер') then

								setClipboardText(info.phone)

							end
							imgui.PopID()

						imgui.NextColumn()

					end

				end

				imgui.EndChild()

			else

				imgui.SetCursorPosY(wsize.y * 0.465)
				imgui.CustomText(u8'Нет данных о прошедшем эфире',2)

			end

			imgui.SetCursorPosY(wsize.y - 34)
			imgui.Spacing()

			if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(-0.1, 0)) then
				buttonResult = false
			end

			goto skipEfir
		end

		imgui.BeginChild('##preEfir', imgui.ImVec2(0, wsize.y - 92), false)

		imgui.Separator()
			imgui.CustomText(u8'Предэфирные настройки', 2)
		imgui.Separator()
		imgui.Spacing()

		for i = 1, #tempSettingsEfir.bool do

			imgui.SetCursorPosX(wsize.x * (1/12))

			imgui_addon.ToggleButton('##boolEfir' .. i, tempSettingsEfir.bool[i])

			imgui.SameLine()
			imgui.SetCursorPosX(wsize.x * (2.5/12))
			imgui.AlignTextToFramePadding()

			imgui.CustomText(u8(settingsInfo.efirBool[i].name))

			if not tempSettingsEfir.bool[i][0] then goto skip end

			if settingsInfo.efirBool[i].name == 'Фильтр чата' then

				imgui.SameLine()

				imgui.SetCursorPosX(wsize.x * (8/12) - 76.5 * 0.5)
				imgui.AlignTextToFramePadding()

				if imgui.SmallButton(u8' Настроить ') then
					efir.selected = 0
					imgui.OpenPopup(u8'Настройка блокировки сообщений')
				end

				if imgui.BeginPopupModal(u8'Настройка блокировки сообщений', nil, imgui.WindowFlags.AlwaysAutoResize) then

					imgui.BeginChild('##blockChat', imgui.ImVec2(600, 400), true)

					imgui.Columns(3, nil, false)
					imgui.SetColumnWidth(-1, 150)
					imgui.CenterColumnText(u8"Название")

					imgui.NextColumn()
					imgui.VerticalSeparator()
					imgui.SetColumnWidth(-1, 300)
					imgui.CenterColumnText(u8'Сообщение')

					imgui.NextColumn()
					imgui.VerticalSeparator()
					imgui.CenterColumnText(u8'Цвет')

					imgui.NextColumn()
					imgui.Separator()

					for i, data in ipairs(efir.set.focusChat) do

						if imgui.Selectable('##' .. i, efir.selected == i, imgui.SelectableFlags.SpanAllColumns) then
							efir.selected = i
						end
						imgui.SameLine()
						local name = (data.name):len() > 0 and u8(data.name) or u8'—'
						imgui.CenterColumnText(name)

						imgui.NextColumn()

						imgui.CenterColumnText(u8(data.msg))

						imgui.NextColumn()
						imgui.CenterColumnText(tostring(data.color))

						imgui.NextColumn()

					end

					imgui.EndChild()
					imgui.Spacing()

					if imgui.Button(faicon.ICON_PLUS_CIRCLE .. u8 ' Создать', imgui.ImVec2(144, 0)) then

						efir.bufColor[0] = 0
						imgui.StrCopy(efir.bufMsg, '')
						imgui.StrCopy(efir.bufName, '')
						efir.selected = 0

						imgui.OpenPopup(u8'Редактирование блокировки сообщений')

					end

					imgui.SameLine()

					if imgui.Button(faicon(0xf044) .. u8 ' Редактировать', imgui.ImVec2(144, 0)) then

						if efir.selected ~= 0 then

							local data = efir.set.focusChat[efir.selected]

							efir.bufColor[0] = data.color
							imgui.StrCopy(efir.bufMsg, u8(data.msg))
							imgui.StrCopy(efir.bufName, u8(data.name))

							imgui.OpenPopup(u8'Редактирование блокировки сообщений')

						else

							printString("~y~Choose parameter!", 1500)

						end

					end

					imgui.SameLine()

					if imgui.CustomButton(faicon(0xf057) .. u8' Удалить', imgui.ImVec4(1.0, 0.15, 0.15, 1.0), imgui.ImVec4(1.0, 0.4, 0.4, 1.0), imgui.ImVec4(1.0, 0.1, 0.1, 1.0), imgui.ImVec2(144, 20)) then

						if settingsRp.selected ~= 0 then

							table.remove(efir.set.focusChat, settingsRp.selected)
							settingsRp.selected = 0

							util.saveSettings(efir.set, dir.settings .. 'settingsEfir.json')

							printString("~y~Deleted!", 1500)

						else

							printString("~y~Choose message!", 1500)

						end

					end

					imgui.SameLine()

					if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(144, 0)) then

						imgui.CloseCurrentPopup()

					end

					if imgui.BeginPopupModal(u8'Редактирование блокировки сообщений', nil, imgui.WindowFlags.AlwaysAutoResize) then

						imgui.CustomText(u8('Можно использовать регулярные выражения'), 2)
						imgui.Spacing()
						imgui.Separator()
						imgui.Spacing()
						imgui.Columns(3, nil, false)
						imgui.SetColumnWidth(-1, 170)
						imgui.CenterColumnText(u8'Название')
						imgui.NextColumn()
						imgui.SetColumnWidth(-1, 300)
						imgui.CenterColumnText(u8'Сообщение')
						imgui.NextColumn()
						imgui.SetColumnWidth(-1, 150)
						imgui.CenterColumnText(u8'Цвет сообщения')
						imgui.Columns()

						imgui.PushItemWidth(150)
						imgui.InputText("##efirName", efir.bufName, sizeof(efir.bufName))
						imgui.PopItemWidth()
						imgui.SameLine()

						imgui.PushItemWidth(300)
						imgui.InputText("##efirMsg", efir.bufMsg, sizeof(efir.bufMsg))
						imgui.PopItemWidth()

						imgui.SameLine()
						imgui.PushItemWidth(150)
						imgui.InputInt('##efirColor', efir.bufColor)
						imgui.PopItemWidth()

						imgui.Spacing()
						imgui.SetCursorPosX(imgui.GetWindowContentRegionWidth() * 0.5 - 150 + 4)
						if imgui.Button(faicon(0xf0c7) .. u8 ' Сохранить', imgui.ImVec2(150, 0)) then

							local name = u8:decode(str(efir.bufName))
							local msg = u8:decode(str(efir.bufMsg))
							local color = efir.bufColor[0]

							if msg:len() > 0 then

								if efir.selected ~= 0 then

									efir.set.focusChat[efir.selected].color = color
									efir.set.focusChat[efir.selected].msg = msg
									efir.set.focusChat[efir.selected].name = name

								else

									efir.set.focusChat[#efir.set.focusChat + 1] = {
										color = color,
										msg = msg,
										name = name,
									}

								end

								util.saveSettings(efir.set, dir.settings .. 'settingsEfir.json')

								imgui.CloseCurrentPopup()
								printString("~y~Saved!", 1500)

							else
								printString("~y~Write message!", 1500)
							end

						end

						imgui.SameLine()

						if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(150, 0)) then

							imgui.CloseCurrentPopup()

						end

						imgui.EndPopup()
					end

					imgui.EndPopup()

				end

			elseif settingsInfo.efirBool[i].name == 'Авторазмер чата' then

				imgui.SameLine()

				imgui.SetCursorPosX(wsize.x * (8/12) - 75 * 0.5)
				imgui.AlignTextToFramePadding()
				imgui.PushItemWidth(75)

				if imgui.InputInt('##intBuf', tempSettingsEfir.bufNum[1]) then

					if tempSettingsEfir.bufNum[1][0] < 10 or tempSettingsEfir.bufNum[1][0] > 20 then

						tempSettingsEfir.bufNum[1][0] = efir.set.bufNum[1]
						printString("~r~Between 10-20!", 1500)

					end

				end
				imgui.PopItemWidth()
			end
			--[[if settingsInfo.efirBool[i].name == 'Подложка' then

				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (8/12) - 100*0.5 - 3.5 - 25*0.5 - 2)

				if imgui.Button(playsound ~= nil and faicon.ICON_STOP or faicon.ICON_PLAY, imgui.ImVec2(23,20)) then

					if playsound ~= nil then

						setAudioStreamState(playsound, as_action.STOP)
						playsound = nil

					else

						playsound = loadAudioStream('moonloader/config/Mass Media Editor/music/bg.mp3')
						setAudioStreamState(playsound, as_action.PLAY)
						setAudioStreamVolume(playsound, math.floor(tempSettingsEfir.bufNum[2][0]))
						setAudioStreamLooped(playsound, true)

					end

				end

				imgui.SameLine()

				imgui.CustomSlider('#slider', 0, 100, 100, tempSettingsEfir.bufNum[2])
				if playsound ~= nil then setAudioStreamVolume(playsound, math.floor(tempSettingsEfir.bufNum[2][0])) end

			end]]

			::skip::

			imgui.SameLine()

			imgui.SetCursorPosX(wsize.x * (10.5/12))
			imgui.AlignTextToFramePadding()

			imgui.CustomText(faicon(0xf05a))
			if imgui.IsItemHovered() then
				imgui.SetTooltip(u8(settingsInfo.efirBool[i].dis))
			end

		end

		imgui.Spacing()
		imgui.Separator()
			imgui.CustomText(u8'Дополнительные опции', 2)
		imgui.Separator()
		imgui.Spacing()

		imgui.SetCursorPosX(wsize.x * 0.5 - 300 * 0.5 - imgui.GetStyle().ItemSpacing.x)
		imgui.SetCursorPosY(wsize.y - 178)

		if imgui.Button(faicon(0xf013) .. u8 ' Открыть отыгровки для эфира', imgui.ImVec2(300, 0)) then

			win_status.efir[0] = false

			updateChapterRp(2, 2)
			settingsRp.selected = 0
			settingsRp.myRpList[0] = 1
			settingsRp.setList[0] = 1

			win_status.settingsMenu[0] = true

		end
		imgui.SetCursorPosX(wsize.x * 0.5 - 300 * 0.5 - imgui.GetStyle().ItemSpacing.x)
		if imgui.Button(faicon(0xf02e) .. u8 ' Отредактировать заметки', imgui.ImVec2(300, 0)) then

			imgui.StrCopy(efir.bufNote, u8(efir.set.note))
			imgui.OpenPopup(u8'Редактирование заметок')

		end
		if imgui.BeginPopupModal(u8'Редактирование заметок', nil, imgui.WindowFlags.AlwaysAutoResize) then
			imgui.CustomText(u8'Заметки можно будет копировать во время эфира', 2)
			imgui.Separator()
			imgui.Spacing()

			imgui.InputTextMultiline('##textNote', efir.bufNote, sizeof(efir.bufNote),
				imgui.ImVec2(500, 250))

			if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(-0.1, 0)) then

				efir.set.note = u8:decode(str(efir.bufNote))
				util.saveSettings(efir.set, dir.settings .. 'settingsEfir.json')

				imgui.CloseCurrentPopup()

			end
			imgui.EndPopup()
		end
		imgui.SetCursorPosX(wsize.x * 0.5 - 300 * 0.5 - imgui.GetStyle().ItemSpacing.x)
		if imgui.Button(faicon.ICON_STAR .. u8 ' Результаты прошедшего эфира', imgui.ImVec2(300, 0)) then
		--if imgui.CustomButton(faicon.ICON_STAR .. u8 ' Результаты прошедшего эфира', imgui.ImVec4(0.84, 0.43, 0.00, 1.0), imgui.ImVec4(1.00, 0.54, 0.04, 1.0), imgui.ImVec4(0.81, 0.39, 0.07, 1.0), imgui.ImVec2(300, 0)) then

			local dir = dir.settings .. 'lastEfir.json'

			if doesFileExist(dir) then

				local text = util.fileRead(dir)
				local info = decodeJson(text) or {}

				local calc = info.calc
				local score = info.score
				local date = info.date
				local time = info.time

				efir.lastResults = {
					calc = calc or {},
					score = score or {},
					date = date,
					time = time,
				}

			else

				efir.lastResults = {
					calc = {},
					score = {},
					date = nil,
					time = nil,
				}

			end

			buttonResult = true

		end

		imgui.EndChild()
		imgui.Separator()
		imgui.Spacing()

		imgui.SetCursorPosX(wsize.x * 0.5 - 550 * 0.5)
		if imgui.CustomButton(faicon.ICON_MICROPHONE .. u8' Начать радиоэфир!', imgui.ImVec4(0.04, 0.51, 0.00, 1.0), imgui.ImVec4(0.04, 0.61, 0.00, 1.0), imgui.ImVec4(0.0, 0.4, 0.0, 1.0), imgui.ImVec2(550, 0)) then

			for i = 1, #efir.set.bool do efir.set.bool[i] = tempSettingsEfir.bool[i][0] end
			for i = 1, #efir.set.bufNum do efir.set.bufNum[i]  = tempSettingsEfir.bufNum[i][0] end

			efir.set.note = u8:decode(str(efir.bufNote))
			efir.set.firstRp = efir.firstRpList[0] + 1

			util.saveSettings(efir.set, dir.settings .. 'settingsEfir.json')

			local numRp = efir.set.firstRp - 1

			if numRp ~= 0 then

				settingsRp.selectedButton = 2
				local rp = efir.set.dataRp[numRp].text
				playRp(rp:find('/efir') and rp or rp .. '\n<1500>\n/efir')
			else

				sampSendChat('/efir')

			end

		end

		imgui.SetCursorPosX(wsize.x * 0.5 - 300 * 0.5)
		imgui.AlignTextToFramePadding()
		imgui.CustomText(u8'Отыгровка в начале эфира:')

		imgui.SameLine()

		imgui.PushItemWidth(150)
		imgui.Combo('##firstRpEfir', efir.firstRpList, efir.firstRpItems, #efir.firstRpChapter)
		imgui.PopItemWidth()

		::skipEfir::

		imgui.End()

	end
)
imgui.OnFrame( -- меню эфира во время эфира
	function () return efir.win.onefir[0] end,
	function (player)

		imgui.SetNextWindowPos(imgui.ImVec2(w - 200, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(300, 280))

		imgui.Begin(faicon.ICON_BULLHORN .. u8' Меню эфира',
		efir.win.onefir, imgui.WindowFlags.NoResize)

		local wsize = imgui.GetWindowSize()

		if imgui.BeginTabBar("##efirMenu") then

			if imgui.BeginTabItem(u8'Инфо') then

				imgui.Separator()
				imgui.CustomText(u8'Вы в эфире (' .. os.date("%M:%S", os.time() - efir.time) .. ')', 2)
				imgui.Separator()
				imgui.Spacing()

				imgui.SetCursorPosX(wsize.x * (1/7))
				imgui.CustomText(u8'Принято SMS:')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (8/10))
				imgui.CustomText(tostring(efir.calc.sms))

				imgui.SetCursorPosX(wsize.x * (1/7))
				imgui.CustomText(u8'Позвонивших:')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (8/10))
				imgui.CustomText(tostring(efir.calc.calls))

				imgui.SetCursorPosX(wsize.x * (1/7))
				imgui.CustomText(u8'Строк эфира:')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (8/10))
				imgui.CustomText(tostring(efir.calc.efirLine))

				imgui.Spacing()
				imgui.Separator()
				imgui.CustomText(u8'Управление окнами', 2)
				imgui.Separator()
				imgui.Spacing()

				imgui.SetCursorPosX(wsize.x * (1/7))
				imgui.CustomText(u8'Управление SMS и баллами')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (8/10))
				imgui_addon.ToggleButton('##boolSMS', efir.win.sms)

				imgui.SetCursorPosX(wsize.x * (1/7))
				imgui.CustomText(u8'Управление звонками')
				imgui.SameLine()
				imgui.SetCursorPosX(wsize.x * (8/10))
				imgui_addon.ToggleButton('##boolCalls', efir.win.calls)

				imgui.Spacing()
				imgui.Separator()
				imgui.Spacing()

				if imgui.Button(faicon.ICON_MICROPHONE .. u8' Завершить эфир', imgui.ImVec2(-0.1, 0)) then

					efir.set.lastRp = efir.lastRpList[0] + 1

					util.saveSettings(efir.set, dir.settings .. 'settingsEfir.json')

					local numRp = efir.set.lastRp - 1

					if numRp ~= 0 then

						settingsRp.selectedButton = 2
						local rp = efir.set.dataRp[numRp].text
						playRp(rp:find('/efir') and rp or rp .. '\n<1500>\n/efir')

					else

						sampSendChat('/efir')

					end

				end

				imgui.SetCursorPosX(wsize.x * (1/10))
				imgui.AlignTextToFramePadding()
				imgui.CustomText(u8'Отыгровка завершения:')

				imgui.SameLine()

				imgui.PushItemWidth(100)
				imgui.Combo('##lastRpEfir', efir.lastRpList, efir.firstRpItems, #efir.firstRpChapter)
				imgui.PopItemWidth()
				imgui.EndTabItem()

			end
			if imgui.BeginTabItem(u8'Анаграммы') then

				imgui.Spacing()
				imgui.CustomText(u8'Сгенерируйте слово или введите его:', 2)
				imgui.Spacing()

				imgui.SetCursorPosX(wsize.x * 0.5 - 68)
				if imgui.SmallButton(u8'Сущ.') then
					local word = getWordForAnag(1)
					imgui.StrCopy(efir.bufMsg, u8(word))
				end
				imgui.SameLine()
				if imgui.SmallButton(u8'Глаг.') then
					local word = getWordForAnag(2)
					imgui.StrCopy(efir.bufMsg, u8(word))
				end
				imgui.SameLine()
				if imgui.SmallButton(u8'Прил.') then
					local word = getWordForAnag(3)
					imgui.StrCopy(efir.bufMsg, u8(word))
				end

				imgui.SetCursorPosX(wsize.x * 0.5 - 100)

				imgui.PushItemWidth(200)
				imgui.InputTextWithHint("##anagrammEfir1", u8'Слово...', efir.bufMsg, sizeof(efir.bufMsg))
				imgui.PopItemWidth()

				imgui.Spacing()
				imgui.SetCursorPosX(wsize.x * 0.5 - 50)
				if imgui.SmallButton(u8'Перемешать') then

					local wordF, subF = u8:decode(str(efir.bufMsg)), u8:decode(str(efir.bufAnagSub))
					local anag = createAnag(wordF, subF, efir.firstLetter[0])

					imgui.StrCopy(efir.bufAnag, u8(anag))

				end
				imgui.Spacing()

				imgui.SetCursorPosX(wsize.x * 0.5 - 100)
				imgui.PushItemWidth(200)
				imgui.InputTextWithHint("##anagrammEfir2", u8'Анаграмма...', efir.bufAnag, sizeof(efir.bufAnag), imgui.InputTextFlags.ReadOnly)
				imgui.PopItemWidth()

				imgui.Spacing()
				imgui.SetCursorPosX(wsize.x * 0.5 - 60)
				if imgui.SmallButton(u8'Отправить в чат') then

					local anag = u8:decode(str(efir.bufAnag))
					if anag ~= '' then
						sampSendChat(anag)
					end

				end

				imgui.Spacing()
				imgui.Separator()
				imgui.CustomText(u8'Настройки' , 2)
				imgui.Separator()
				imgui.Spacing()

				imgui.SetCursorPosX(wsize.x * (1/10))
				imgui.CustomText(u8'Разделитель')
				imgui.SameLine(nil, 30)
				imgui.CustomText(u8'Первая буква большая')

				imgui.SetCursorPosX(wsize.x * (1/10) + 13)
				imgui.PushItemWidth(50)
				imgui.InputText("##anagrammEfir3", efir.bufAnagSub, sizeof(efir.bufAnagSub))
				imgui.PopItemWidth()

				imgui.SameLine(nil, 94)

				imgui_addon.ToggleButton('##firstLetter', efir.firstLetter)

				imgui.EndTabItem()
			end
			if imgui.BeginTabItem(u8'Заметки') then

				imgui.InputTextMultiline('##textNote', efir.bufNote, sizeof(efir.bufNote),
					imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 220))

				imgui.EndTabItem()
			end
			if imgui.BeginTabItem(u8'Отыгровки') then

				imgui.Columns(3, nil, false)
				imgui.VerticalSeparator()
				imgui.SetColumnWidth(-1, 30)
				imgui.CenterColumnText(u8'№')

				imgui.NextColumn()
				imgui.VerticalSeparator()
				imgui.SetColumnWidth(-1, 230)
				imgui.CenterColumnText(faicon.ICON_PLAY .. u8' Отыгровка')

				imgui.NextColumn()
				imgui.VerticalSeparator()
				imgui.CenterColumnText(faicon(0xf013))

				imgui.NextColumn()
				imgui.Separator()

				for i, data in ipairs(efir.set.dataRp) do

					imgui.CustomText(tostring(i))

					imgui.NextColumn()
						imgui.CustomText(u8(data.name))

					imgui.NextColumn()
						imgui.PushIDInt(i)
						if imgui.SmallButton(u8'>') then
							imgui.StrCopy(efir.bufRpShow, u8(data.text))
							imgui.OpenPopup(u8'Запуск отыгровки')
						end


					if imgui.BeginPopupModal(u8'Запуск отыгровки', nil, imgui.WindowFlags.AlwaysAutoResize) then

						imgui.InputTextMultiline('##bufShowRp', efir.bufRpShow, sizeof(efir.bufRpShow),
							imgui.ImVec2(450, 250), imgui.InputTextFlags.ReadOnly)

						imgui.SetCursorPosX(450 * 0.5 - 2 * 150 * 0.5)
						if imgui.Button(faicon.ICON_PLAY .. u8' Запустить', imgui.ImVec2(150, 0)) then

							settingsRp.selectedButton = 2
							playRp(data.text)

							imgui.CloseCurrentPopup()

						end
						imgui.SameLine()
						if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(150, 0)) then

							imgui.CloseCurrentPopup()

						end
						imgui.EndPopup()
					end
					imgui.PopID()
					imgui.NextColumn()

				end

				imgui.EndTabItem()
			end

			imgui.EndTabItem()
		end

		imgui.End()
	end
)
function setCalls(make, nick, num)

	local make = type(make) == 'number' and make or 1 -- 1 добавить, 2 удалить
	local num = type(num) == 'number' and num or 1 -- 1 позвонившие, 2 подключенные

	local id = sampGetPlayerIdByNickname(nick)

	if num == 1 then

		efir.to.calls[#efir.to.calls + 1] = {
			id = id or -1,
			nick = nick,
		}

	else

		local tables = efir.to.calls

		if make == 1 then

			efir.to.connected[#efir.to.connected + 1] = {
				id = id or -1,
				nick = nick,
			}

		else

			tables = efir.to.connected

		end

		for i = 1, #tables do

			local info = tables[i]

			if info ~= nil then

				if info.nick == nick then

					table.remove(tables, i)
					break
				end

			end

		end

	end

end
imgui.OnFrame( -- звонки
	function () return efir.win.calls[0] end,
	function (player)

		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(410, 202))

		imgui.Begin(faicon.ICON_PHONE .. u8' Звонки',
		efir.win.calls, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

		local wsize = imgui.GetWindowSize()

		imgui.BeginChild('##calls', imgui.ImVec2(394, 142), true)

		imgui.Columns(2, nil, false)
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 270)
		imgui.CenterColumnText(faicon(0xf2c2) .. u8' Никнейм')

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.CenterColumnText(faicon(0xf013) .. u8' Действие')

		imgui.NextColumn()
		imgui.Separator()

		for i = 1, #efir.to.connected do

			local info = efir.to.connected[i]

			if info ~= nil then

				if sampIsPlayerConnected(info.id) then

					local nick = sampGetPlayerNickname(info.id)
					if nick ~= info.nick then table.remove(efir.to.connected, i); goto skip end

				else

					table.remove(efir.to.connected, i)
					goto skip

				end

				imgui.CustomText(faicon.ICON_PHONE .. ' {ffff00}' .. info.nick .. ' [' .. info.id .. ']')

				imgui.NextColumn()
					imgui.Text(' ')
					imgui.SameLine()
					imgui.PushIDInt(i)
					if imgui.SmallButton(u8'Отключить') then

						sampSendChat('/bring -1')

					end
					imgui.PopID()

				imgui.NextColumn()

				::skip::

			end

		end

		for i = 1, #efir.to.calls do

			local info = efir.to.calls[i]

			if info ~= nil then

				if sampIsPlayerConnected(info.id) then

					local nick = sampGetPlayerNickname(info.id)
					if nick ~= info.nick then table.remove(efir.to.calls, i); goto skip end

				else

					table.remove(efir.to.calls, i)
					goto skip

				end

				imgui.CustomText(info.nick .. ' [' .. info.id .. ']')

				imgui.NextColumn()
					imgui.Text('')

					imgui.SameLine()

					imgui.PushIDInt(i)

					if imgui.SmallButton(u8'Принять') then

						sampSendChat('/bring ' .. info.id)

					end

					imgui.SameLine()

					if imgui.SmallButton(faicon.ICON_TRASH) then

						table.remove(efir.to.calls, i)

					end

					imgui.PopID()

				imgui.NextColumn()

				::skip::

			end
		end

		imgui.EndChild()
		imgui.SetCursorPosX(wsize.x * 0.5 - 1 * 250 * 0.5 - imgui.GetStyle().ItemSpacing.x)

		if imgui.Button(faicon.ICON_TRASH .. u8' Очистить позвонивших', imgui.ImVec2(250, 0)) then
			efir.to.calls = {}
		end

		imgui.End()
	end
)
imgui.OnFrame( -- SMS
	function () return efir.win.sms[0] end,
	function (player)

		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(550, 363))

		imgui.Begin(faicon.ICON_COMMENTS_O .. u8' SMS и баллы',
		efir.win.sms, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

		local wsize = imgui.GetWindowSize()

		imgui.BeginChild('##smsefir', imgui.ImVec2(534, 155), true)
		imgui.Columns(4, nil, false)
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 30)
		imgui.CenterColumnText(u8'№')

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 85)
		imgui.CenterColumnText(faicon(0xf10b) .. u8' Телефон')

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 310)
		imgui.CenterColumnText(faicon(0xf27a) .. u8' SMS')

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.CenterColumnText(faicon(0xf013) .. u8' Действие')

		imgui.NextColumn()
		imgui.Separator()

		for i = 1, #efir.to.sms do

			local info = efir.to.sms[i]

			if info ~= nil then

				imgui.CustomText(tostring(i))

				imgui.NextColumn()
					imgui.CustomText(tostring(info.phone))

				imgui.NextColumn()
					imgui.CustomText(u8(info.sms))

				imgui.NextColumn()

					imgui.PushIDInt(i)
					if imgui.SmallButton(u8'+1 балл') then

						util.scriptmsg('Вы засчитали ответ игроку с номером {fff099}' .. info.phone .. '{CECECE}. Его номер скопирован в буфер обмена.')

						setClipboardText(info.phone)
						changeScore(info.nick, info.phone, 1, true)
						efir.to.sms = { }

					end
					imgui.SameLine()
					if imgui.SmallButton(faicon.ICON_TRASH) then

						table.remove(efir.to.sms, i)

					end
					imgui.PopID()

				imgui.NextColumn()

			end

		end
		imgui.EndChild()

		if imgui.Button(faicon.ICON_TRASH .. u8 ' Очистить сообщения', imgui.ImVec2(-0.1, 0)) then efir.to.sms = { } end

		imgui.BeginChild('##scoreefir', imgui.ImVec2(534, 120), true)

		imgui.Columns(5, nil, false)
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 30)
		imgui.CenterColumnText(u8'№')

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 85)
		imgui.CenterColumnText(faicon(0xf10b) .. u8' Телефон')

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 280)
		imgui.CenterColumnText(faicon(0xf2c2) .. u8' Никнейм')

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 30)
		imgui.CenterColumnText(faicon.ICON_STAR)
		if imgui.IsItemHovered() then
			imgui.SetTooltip(u8('Количество баллов'))
		end

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.CenterColumnText(faicon(0xf013) .. u8' Действие')

		imgui.NextColumn()
		imgui.Separator()

		for i = 1, #efir.to.score do

			local info = efir.to.score[i]

			if info ~= nil then

				imgui.CustomText(tostring(i))

				imgui.NextColumn()
					imgui.CustomText(tostring(info.phone))
					if imgui.IsItemClicked(1) then setClipboardText(tostring(info.phone)) end

				imgui.NextColumn()
					imgui.CustomText(info.nick)

				imgui.NextColumn()
					imgui.CustomText(tostring(info.score))

				imgui.NextColumn()

					imgui.PushIDInt(i)
					if imgui.SmallButton(u8'+ 1') then
						info.score = info.score + 1
						changeScore(nil, nil, nil, nil, true)
					end
					imgui.SameLine()
					if imgui.SmallButton(u8'- 1') then
						info.score = info.score - 1
						changeScore(nil, nil, nil, nil, true)
					end
					imgui.SameLine()
					if imgui.SmallButton(faicon.ICON_TRASH) then
						util.scriptmsg('Вы удалили {fff099}' .. info.nick .. '{CECECE} из списка лидеров с {fff099}('.. info.score ..'){CECECE} баллами.')
						table.remove(efir.to.score, i)
						changeScore(nil, nil, nil, nil, true)

					end
					imgui.PopID()

				imgui.NextColumn()

			end

		end

		imgui.EndChild()

		imgui.SetCursorPosX(wsize.x * 0.5 - 2 * 200 * 0.5 - imgui.GetStyle().ItemSpacing.x)
		if imgui.Button(faicon.ICON_PLUS_CIRCLE.. u8' Добавить свое', imgui.ImVec2(200, 0)) then
			efir.bufColor[0] = 0
			imgui.StrCopy(efir.bufName, '')
			imgui.StrCopy(efir.bufPhone, '')
			imgui.OpenPopup(u8'Добавить в список лидеров')
		end
		imgui.SameLine()
		if imgui.Button(faicon.ICON_TRASH .. u8' Очистить баллы', imgui.ImVec2(200, 0)) then
			efir.to.score = {}
		end

		if imgui.BeginPopupModal(u8'Добавить в список лидеров', nil, imgui.WindowFlags.AlwaysAutoResize) then

			imgui.Columns(3, nil, false)
			imgui.SetColumnWidth(-1, 260)
			imgui.CenterColumnText(u8'Ник')
			imgui.NextColumn()
			imgui.SetColumnWidth(-1, 90)
			imgui.CenterColumnText(u8'Телефон')
			imgui.NextColumn()
			imgui.CenterColumnText(u8'Баллы')
			imgui.Columns()

			imgui.PushItemWidth(250)
			imgui.InputText("##nameBuf", efir.bufName, sizeof(efir.bufName))
			imgui.PopItemWidth()
			imgui.SameLine()

			imgui.PushItemWidth(85)
			imgui.InputText("##phoneBuf", efir.bufPhone, sizeof(efir.bufPhone))
			imgui.PopItemWidth()

			imgui.SameLine()
			imgui.PushItemWidth(80)
			imgui.InputInt('##scoreBuf', efir.bufColor)
			imgui.PopItemWidth()

			imgui.Spacing()
			imgui.SetCursorPosX(imgui.GetWindowContentRegionWidth() * 0.5 - 2 * 150 * 0.5 - imgui.GetStyle().ItemSpacing.x)

			if imgui.Button(faicon(0xf0c7) .. u8 ' Сохранить', imgui.ImVec2(150, 0)) then

				local nick = u8:decode(str(efir.bufName))
				local score = efir.bufColor[0]
				local phone = u8:decode(str(efir.bufPhone))

				changeScore(nick, phone, score)

				imgui.CloseCurrentPopup()

			end

			imgui.SameLine()

			if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(150, 0)) then

				imgui.CloseCurrentPopup()

			end
			imgui.EndPopup()
		end

		imgui.End()
	end
)

-- Для меню основных настроек и клавиш
function setTempSettingsScript()
	tempSettings = {
		keys = {},
		bool = {},
		buf = {},
	}

	for i = 1, #settings.scriptBool do tempSettings.bool[i] = imgui.new.bool(settings.scriptBool[i]) end
	for i = 1, #settings.scriptBuf do tempSettings.buf[i] = imgui.new.char[32](u8(settings.scriptBuf[i])) end
	for i = 1, #settings.keys do tempSettings.keys[i] = { v = settings.keys[i].v, } end

	--win_status.settings[0] = true
end
function tempToSettings()

	for i = 1, #tempSettings.bool do settings.scriptBool[i] = tempSettings.bool[i][0] end
	for i = 1, #tempSettings.buf do settings.scriptBuf[i] = u8:decode(str(tempSettings.buf[i])) end
	for i = 1, #tempSettings.keys do

		local comboSet = i == 4 and {vkeys.VK_RBUTTON, settings.keys[i].v[1]}
			or settings.keys[i].v
		local comboTemp = i == 4 and {vkeys.VK_RBUTTON, tempSettings.keys[i].v[1]}
			or tempSettings.keys[i].v

		local res, data = rkeys.getHotKey(comboSet)

		if res then

			if #tempSettings.keys[i].v > 0 then -- не ставить comboTemp, так как выше добавляет ПКМ
				rkeys.changeHotKey(data.id, comboTemp)
			else
				rkeys.unRegisterHotKey(comboSet)
			end

		else

			rkeys.registerHotKey(comboTemp, settingsInfo.keys[i].mod, settingsInfo.keys[i].func)

		end

		settings.keys[i] = { v = tempSettings.keys[i].v, }

	end

	util.saveSettings(settings, dir.settings .. 'settings.json')

end
function readMainSettings()

	local dirset = dir.settings .. 'settings.json'

	if doesFileExist(dirset) then

		local text = util.fileRead(dirset)
		local info = decodeJson(text) or {}

		if info.scriptBool and info.scriptBuf and info.keys then

			for i = 1, #settings.scriptBool do
				if type(info.scriptBool[i]) == 'boolean' then
					settings.scriptBool[i] = info.scriptBool[i]
				end
			end

			for i = 1, #settings.scriptBuf do
				if info.scriptBuf[i] then
					settings.scriptBuf[i] = info.scriptBuf[i]
				end
			end

			for i = 1, #settings.keys do
				if info.keys[i] then
					settings.keys[i] = { v = info.keys[i].v }
				end
			end

			util.saveSettings(settings, dir.settings .. 'settings.json')

		end
	end

	for i, data in ipairs(settings.keys) do

		if #data.v > 0 then

			rkeys.registerHotKey(
				i == 4 and {vkeys.VK_RBUTTON, data.v[1]} or data.v,
				settingsInfo.keys[i].mod, settingsInfo.keys[i].func
			)

		end

	end

end

-- Главное меню
imgui.OnFrame(
	function () return win_status.main[0] end,
	function (player)

		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(700, 408))

		imgui.Begin(faicon.ICON_DIAMOND .. ' Mass Media Editor (' .. serverList[user.server.id].name .. ')',
			win_status.main, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

		imgui.BeginChild('##menuList', imgui.ImVec2(150, 0), true, imgui.WindowFlags.NoScrollbar)

		for i = 1, #mainMenu do

			imgui.CustomText('{ff9933}' .. u8(mainMenu[i].name))

			for a = 1, #mainMenu[i].part do

				if imgui.Selectable(u8(mainMenu[i].part[a]), mainMenu.selected[1] == i and mainMenu.selected[2] == a,
					imgui.SelectableFlags.SpanAllColumns) then

					mainMenu.selected = {i, a}
					if mainMenu[i].beforeFunc[a] then mainMenu[i].beforeFunc[a]() end

				end

			end

			if i ~= #mainMenu then imgui.Text('') end

		end

		imgui.EndChild()

		imgui.SameLine()

		imgui.BeginChild('##menuPart', imgui.ImVec2(0, 0), false)

		for i = 1, #mainMenu do

			for a = 1, #mainMenu[i].part do

				if mainMenu.selected[1] == i and mainMenu.selected[2] == a then

					mainMenu[i].func[a]()

				end

			end

		end

		imgui.EndChild()
		imgui.End()
	end
)

-- Настройка меню окон и отыгровок
function readSettingsRp()

	local dir = dir.settings .. 'settingsRp.json'

	if doesFileExist(dir) then

		local text = util.fileRead(dir)
		local info = decodeJson(text) or {}

		for i = 2, #chaptersRp do

			if info[i] == nil then goto skipreadRp end

			for a, data in ipairs(info[i]) do

				if i == 2 then

					settingsRp.set[i][a] = {
						name = data.name,
						text = data.text,
						cmd = data.cmd,
						key = { v = data.key.v }
					}

					if #data.key.v > 0 then

						rkeys.registerHotKey(data.key.v, 1, function()

							settingsRp.selectedButton = 2
							playRp(settingsRp.set[2][a].text, nil, true)

						end)

					end

				else

					settingsRp.set[i][a] = {
						name = data.name,
						text = data.text,
					}

				end

			end

			::skipreadRp::

		end

	end

end
function setCurTeg(chapter) -- устанавливает доп. теги, длину тегов и их указывает половину
	if chapter == 2 then

		settingsRp.sumTegs = #settingsRp.tegs[1]
		settingsRp.tegsSeparator = math.ceil(settingsRp.sumTegs * 0.5)
		settingsRp.curTegs = 1

	elseif chapter < 6 then

		settingsRp.sumTegs = #settingsRp.tegs[1] + #settingsRp.tegs[2]
		settingsRp.tegsSeparator = math.ceil(settingsRp.sumTegs * 0.5)
		settingsRp.curTegs = 2

	else

		settingsRp.sumTegs = #settingsRp.tegs[1] + #settingsRp.tegs[3]
		settingsRp.tegsSeparator = math.ceil(settingsRp.sumTegs * 0.5)
		settingsRp.curTegs = 3

	end
end
function updateChapterRp(chapter, type) -- обновляет инпуты и теги

	setCurTeg(chapter)

	if chapter == 2 and type == 2 then -- свои отыгровки > радиоэфиры

		if efir.set.dataRp[settingsRp.selected] then

			imgui.StrCopy(settingsRp.temp.name, u8(util.jsonToText(efir.set.dataRp[settingsRp.selected].name or '')))
			imgui.StrCopy(settingsRp.temp.text, u8(util.jsonToText(efir.set.dataRp[settingsRp.selected].text or '')))

		else

			imgui.StrCopy(settingsRp.temp.name, '')
			imgui.StrCopy(settingsRp.temp.text, '')

		end

		return
	end

	if settingsRp.set[chapter][settingsRp.selected] then

		imgui.StrCopy(settingsRp.temp.name, u8(util.jsonToText(settingsRp.set[chapter][settingsRp.selected].name or '')))
		imgui.StrCopy(settingsRp.temp.text, u8(util.jsonToText(settingsRp.set[chapter][settingsRp.selected].text or '')))

		if chapter == 2 then -- свои отыгровки

			imgui.StrCopy(settingsRp.temp.cmd, u8(util.jsonToText(settingsRp.set[chapter][settingsRp.selected].cmd or '')))
			settingsRp.temp.key = {v = settingsRp.set[chapter][settingsRp.selected].key.v}

		end

	else

		imgui.StrCopy(settingsRp.temp.name, '')
		imgui.StrCopy(settingsRp.temp.text, '')

		if chapter == 2 then  -- свои отыгровки

			imgui.StrCopy(settingsRp.temp.cmd, '')
			settingsRp.temp.key = {v = {}}

		end

	end

end
function showListTegs(i) -- imgui, вызывается в цикле for, показывает теги

	local name, des -- имя тега и его описание

	if settingsRp.tegs[1][i] then

		name, des = settingsRp.tegs[1][i][1], settingsRp.tegs[1][i][2]

	else

		local id = i - #settingsRp.tegs[1]
		name, des = settingsRp.tegs[settingsRp.curTegs][id][1], settingsRp.tegs[settingsRp.curTegs][id][2]

	end

	if imgui.SmallButton('C##' .. i) then setClipboardText(name) end

	imgui.SameLine()

	imgui.CustomText( ('{ff9933}%s{ffffff} - %s'):format(name, u8(des) ))

end
function windowSettingsRp(numItem, sizeList, sizeFor) -- основное окно создание пунктов и отыгровок

	local nameList = settingsRp.selected == sizeList + 1 and u8'Создать пункт...'
		or u8(settingsRp.set[numItem][settingsRp.selected].name)

	local wsize = imgui.GetWindowSize()

	imgui.BeginChild('##settingsRp' .. numItem, imgui.ImVec2(0, wsize.y - 35), false)

	imgui.CustomText(chaptersRp[numItem] .. ' > ' .. nameList, 2)

	imgui.Spacing()
	imgui.Separator()

	imgui.CustomText(u8'Доступные теги:', 2)

	imgui.Separator()
	imgui.Spacing()

	imgui.BeginChild('##tegsList' .. numItem, imgui.ImVec2(0, 70), false)

	imgui.BeginGroup()

	for i = 1, settingsRp.tegsSeparator do showListTegs(i) end

	imgui.EndGroup()

	imgui.SameLine()

	imgui.BeginGroup()

	for i = settingsRp.tegsSeparator + 1, settingsRp.sumTegs do showListTegs(i) end

	imgui.EndGroup()

	imgui.EndChild()

	imgui.Spacing()
	imgui.Separator()
	imgui.Spacing()

	imgui.SetCursorPosX(wsize.x * 0.5 - 75)

	imgui.PushItemWidth(150)
	imgui.InputTextWithHint('##namesettingsRp', u8'Название пункта...', settingsRp.temp.name, sizeof(settingsRp.temp.name))
	imgui.PopItemWidth()

	imgui.Spacing()

	imgui.CustomText(u8'Текст вашей отыгровки', 2)

	imgui.Spacing()

	imgui.InputTextMultiline('##textsettingsRp', settingsRp.temp.text, sizeof(settingsRp.temp.text),
		imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 138))
	imgui.EndChild()

	imgui.Separator()
	imgui.Spacing()

	if imgui.Button(faicon(0xf0c7) .. u8 ' Сохранить', imgui.ImVec2(150, 0)) then

		if settingsRp.selected == sizeFor then -- Создание

			settingsRp.set[numItem][settingsRp.selected] = {
				name = util.textToJson(u8:decode(str(settingsRp.temp.name))),
				text = util.textToJson(u8:decode(str(settingsRp.temp.text))),
			}

		else -- Перезапись

			settingsRp.set[numItem][settingsRp.selected].name = util.textToJson(u8:decode(str(settingsRp.temp.name)))
			settingsRp.set[numItem][settingsRp.selected].text = util.textToJson(u8:decode(str(settingsRp.temp.text)))

		end

		util.saveSettings(settingsRp.set, dir.settings .. 'settingsRp.json')

		printString("~y~Saved!", 1500)
	end

	imgui.SameLine()

	if imgui.Button(faicon.ICON_CHECK .. u8 ' Проверить', imgui.ImVec2(150, 0)) then

		settingsRp.selectedButton = numItem
		playRp(util.textToJson(u8:decode(str(settingsRp.temp.text))), true)

	end

	if settingsRp.selected ~= sizeFor then

		imgui.SameLine()

		if imgui.CustomButton(faicon(0xf057) .. u8' Удалить', imgui.ImVec4(1.0, 0.15, 0.15, 1.0), imgui.ImVec4(1.0, 0.4, 0.4, 1.0), imgui.ImVec4(1.0, 0.1, 0.1, 1.0), imgui.ImVec2(150, 20)) then

			table.remove(settingsRp.set[numItem], settingsRp.selected)
			updateChapterRp(numItem)

			util.saveSettings(settingsRp.set, dir.settings .. 'settingsRp.json')
			printString("~y~Deleted!", 1500)

		end
	end

end
function windowMyRp(sizeList) -- создание своих отыгровок

	local isEfir = settingsRp.myRpList[0] == 1

	imgui.BeginChild('##myRp', imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 315), true)

		if isEfir then

			imgui.Columns(2, nil, false)
			imgui.SetColumnWidth(-1, 30)
			imgui.CenterColumnText(u8"№")

			imgui.NextColumn()
			imgui.VerticalSeparator()
			imgui.CenterColumnText(u8"Название")

			imgui.NextColumn()
			imgui.Separator()

			for i, data in ipairs(efir.set.dataRp) do

				if imgui.Selectable(tostring(i), settingsRp.selected == i, imgui.SelectableFlags.SpanAllColumns) then
					settingsRp.selected = i
				end

				imgui.NextColumn()

				local name = (data.name):len() > 0 and u8(data.name) or u8'—'
				imgui.CenterColumnText(name)

				imgui.NextColumn()
			end

			goto efir

		end

		imgui.Columns(4, nil, false)
		imgui.SetColumnWidth(-1, 30)
		imgui.CenterColumnText(u8"№")

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 350)
		imgui.CenterColumnText(u8"Название")

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.SetColumnWidth(-1, 150)
		imgui.CenterColumnText(u8"Команда")

		imgui.NextColumn()
		imgui.VerticalSeparator()
		imgui.CenterColumnText(u8"Бинд")

		imgui.NextColumn()
		imgui.Separator()

		for i, data in ipairs(settingsRp.set[2]) do

			if imgui.Selectable(tostring(i), settingsRp.selected == i, imgui.SelectableFlags.SpanAllColumns) then
				settingsRp.selected = i
			end

			imgui.NextColumn()

			local name = (data.name):len() > 0 and u8(data.name) or u8'—'
			imgui.CenterColumnText(name)

			imgui.NextColumn()

			local cmd = (data.cmd):len() > 0 and u8('/' .. data.cmd) or u8'—'
			imgui.CenterColumnText(cmd)

			imgui.NextColumn()
			imgui.CenterColumnText(util.getKeysName(data.key.v))

			imgui.NextColumn()
		end

		::efir::

	imgui.EndChild()

	--local wsize = imgui.GetWindowSize()

	--imgui.SetCursorPosX(wsize.x * 0.5 - 450 * 0.5)
	if not isEfir then

		if imgui.Button(faicon.ICON_PLAY .. u8 ' Запустить', imgui.ImVec2(165, 0)) then

			if settingsRp.selected ~= 0 then

				settingsRp.selectedButton = 2
				playRp(settingsRp.set[2][settingsRp.selected].text)

			else

				printString("~y~Choose RP!", 1500)

			end

		end

		imgui.SameLine()
	end

	if imgui.Button(faicon.ICON_PLUS_CIRCLE .. u8 ' Создать', imgui.ImVec2(isEfir and 223 or 165, 0)) then

		settingsRp.selected = 0 -- указывает на то, что это создание, а не редактирование
		updateChapterRp(2, isEfir and 2)

		imgui.OpenPopup(u8'Создание своей отыгровки')

	end

	imgui.SameLine()

	if imgui.Button(faicon(0xf044) .. u8 ' Редактировать', imgui.ImVec2(isEfir and 222 or 165, 0)) then

		if settingsRp.selected ~= 0 then

			updateChapterRp(2, isEfir and 2)
			imgui.OpenPopup(u8'Создание своей отыгровки')

		else

			printString("~y~Choose RP!", 1500)

		end

	end

	imgui.SameLine()

	if imgui.CustomButton(faicon(0xf057) .. u8' Удалить', imgui.ImVec4(1.0, 0.15, 0.15, 1.0), imgui.ImVec4(1.0, 0.4, 0.4, 1.0), imgui.ImVec4(1.0, 0.1, 0.1, 1.0), imgui.ImVec2(isEfir and 223 or 165, 20)) then

		if settingsRp.selected ~= 0 then

			if not isEfir then

				local keys = settingsRp.set[2][settingsRp.selected].key.v

				if #keys > 0 then rkeys.unRegisterHotKey(keys) end

				table.remove(settingsRp.set[2], settingsRp.selected)
				settingsRp.selected = 0

				util.saveSettings(settingsRp.set, dir.settings .. 'settingsRp.json')

			else

				table.remove(efir.set.dataRp, settingsRp.selected)
				settingsRp.selected = 0
				updateFirstCombo(true)
				util.saveSettings(efir.set, dir.settings .. 'settingsEfir.json')

			end

			imgui.CloseCurrentPopup()
			printString("~y~Deleted!", 1500)

		else

			printString("~y~Choose RP!", 1500)

		end

	end

	if imgui.BeginPopupModal(u8'Создание своей отыгровки', nil, imgui.WindowFlags.AlwaysAutoResize) then

		imgui.Separator()

		imgui.CustomText(u8'Доступные теги:', 2)

		imgui.Separator()
		imgui.Spacing()

		imgui.BeginChild('##tegsList2', imgui.ImVec2(500, 70), false)

		imgui.BeginGroup()
		for i = 1, settingsRp.tegsSeparator do showListTegs(i) end
		imgui.EndGroup()

		imgui.SameLine()

		imgui.BeginGroup()
		for i = settingsRp.tegsSeparator + 1, settingsRp.sumTegs do

			imgui.SetCursorPosX(500 * 0.5)
			showListTegs(i)

		end
		imgui.EndGroup()

		imgui.EndChild()

		imgui.Separator()
		imgui.Spacing()

		imgui.PushItemWidth(isEfir and 500 or 240)
		imgui.InputTextWithHint('##nameMyRp', u8'Название...', settingsRp.temp.name, sizeof(settingsRp.temp.name))
		imgui.PopItemWidth()

		if not isEfir then

			imgui.SameLine()

			imgui.PushItemWidth(120)
			imgui.InputTextWithHint('##cmdMyRp', u8'Команда без /...', settingsRp.temp.cmd, sizeof(settingsRp.temp.cmd))
			imgui.PopItemWidth()

			imgui.SameLine()

			if imgui_addon.HotKey('##keyMyRp', settingsRp.temp.key, 120, 20) then

				if rkeys.isHotKeyDefined(settingsRp.temp.key.v) then

					printString("~r~Already used!", 1500)
					settingsRp.temp.key.v = { }

				end

			end

		end

		imgui.Spacing()

		imgui.CustomText(u8'Текст вашей отыгровки', 2)

		imgui.Spacing()

		imgui.InputTextMultiline('##textsettingsRp', settingsRp.temp.text, sizeof(settingsRp.temp.text),
			imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 138))

		imgui.Separator()
		imgui.Spacing()

		if imgui.Button(faicon(0xf0c7) .. u8 ' Сохранить', imgui.ImVec2(246, 0)) then

			if isEfir then

				local id = settingsRp.selected == 0 and sizeList + 1 or settingsRp.selected

				if id == sizeList + 1 then -- Создание

					efir.set.dataRp[id] = {
						name = util.textToJson(u8:decode(str(settingsRp.temp.name))),
						text = util.textToJson(u8:decode(str(settingsRp.temp.text))),
					}

				else -- Перезапись

					efir.set.dataRp[id].name = util.textToJson(u8:decode(str(settingsRp.temp.name)))
					efir.set.dataRp[id].text = util.textToJson(u8:decode(str(settingsRp.temp.text)))

				end

				util.saveSettings(efir.set, dir.settings .. 'settingsEfir.json')
				imgui.CloseCurrentPopup()
				updateFirstCombo(true)
				printString("~y~Saved!", 1500)

				goto skipmyRp

			end

			local id = settingsRp.selected == 0 and sizeList + 1 or settingsRp.selected

			local comboSet = settingsRp.selected == 0 and {} or settingsRp.set[2][id].key.v
			local comboTemp = settingsRp.temp.key.v

			local res, data = rkeys.getHotKey(comboSet)

			if res then

				if #comboTemp > 0 then
					rkeys.changeHotKey(data.id, comboTemp)
				else
					rkeys.unRegisterHotKey(comboSet)
				end

			else

				if #comboTemp > 0 then

					rkeys.registerHotKey(comboTemp, 1, function()

						settingsRp.selectedButton = 2
						playRp(util.textToJson(u8:decode(str(settingsRp.temp.text))), nil, true)

					end)

				end

			end

			if id == sizeList + 1 then -- Создание

				settingsRp.set[2][id] = {
					name = util.textToJson(u8:decode(str(settingsRp.temp.name))),
					text = util.textToJson(u8:decode(str(settingsRp.temp.text))),
					cmd = util.textToJson(u8:decode(str(settingsRp.temp.cmd))),
					key = { v = settingsRp.temp.key.v, }
				}

			else -- Перезапись

				settingsRp.set[2][id].name = util.textToJson(u8:decode(str(settingsRp.temp.name)))
				settingsRp.set[2][id].text = util.textToJson(u8:decode(str(settingsRp.temp.text)))
				settingsRp.set[2][id].cmd = util.textToJson(u8:decode(str(settingsRp.temp.cmd)))
				settingsRp.set[2][id].key = { v = settingsRp.temp.key.v, }

			end

			util.saveSettings(settingsRp.set, dir.settings .. 'settingsRp.json')
			imgui.CloseCurrentPopup()
			printString("~y~Saved!", 1500)

			::skipmyRp::

		end

		imgui.SameLine()

		if imgui.Button(faicon(0xf0e2) .. u8' Назад', imgui.ImVec2(246, 0)) then

			imgui.CloseCurrentPopup()

		end

		imgui.EndPopup()
	end
end
function windowInfoRp()

	local wsize = imgui.GetWindowSize()

	imgui.CustomText(u8(settingsRp.set[1][settingsRp.selected].name), 2)

	imgui.Spacing()
	imgui.Separator()

	if settingsRp.selected == 1 then
		imgui.CustomText(u8'\tБиндер делится на 2 части: {ffff00}свои отыгровки{ffffff} и {ffff00}отыгровки с взаимодействием окон{ffffff}')
		imgui.CustomText(u8'(члены организации онлайн и меню взаимодействия).')
		imgui.Text('')
		imgui.CustomText(u8'\t{ff9933}В обеих частях общие составляющие:')
		imgui.CustomText(u8'\t{ffff00}-{ffffff} Заменяемые теги <myName> и др.')
		imgui.CustomText(u8'\t{ffff00}-{ffffff} Задержка <1000> и др. (задержка в мс, 1000 мс = 1 сек).')
		imgui.CustomText(u8'\t{ffff00}-{ffffff} Ожидание <0> (продолжить командами).')
		imgui.CustomText(u8'\t{ffff00}-{ffffff} Тег закрытия окна вызова #close:')
		imgui.CustomText(u8'\t{ffff00}-{ffffff} Теги создания диалоговых окон #input:, #list: {текст1}{текст2}.')
		imgui.CustomText(u8'\t{ffff00}-{ffffff} Заменяемый тег окон {w}.')
		imgui.CustomText(u8'\t{ffff00}-{ffffff} Случайный текст r:{текст1}{текст2}:r.')
		imgui.Text('')
		imgui.CustomText(u8'\tЧтобы остановить отыгровку, нужно написать {ffff00}/mmstop')
		imgui.CustomText(u8'\tЧтобы продолжить отыгровку (при <0>), нужно написать {ffff00}/mmnext')
		imgui.Text('')
		imgui.CustomText(u8'\t{ff9933}Пояснение для заменяемого тега окон ({w}):{ffffff} тег заменяет информация, полученная')
		imgui.CustomText(u8'из созданных диалоговых окон (например, текст из выбранного списка). Если {ffff00}окон')
		imgui.CustomText(u8'{ffff00}несколько{ffffff}, то тег заменится на {ffff00}первое попавшиеся вышестоящие{ffffff} над ним окно.')
	elseif settingsRp.selected == 2 then

		imgui.CustomText(u8'\tВ данном примере будут затронуты {ffff00}все возможности{ffffff} отыгровки, комментарии к')
		imgui.CustomText(u8'коду будут помечаться как «{09ab3f}-- комментарий{ffffff}». Пример будет рассчитан на меню')
		imgui.CustomText(u8'взаимодействие ({ffff00}/mmact{ffffff}).')

		imgui.Text('')

		imgui.SetCursorPosX(wsize.x * 0.5 - (imgui.GetWindowContentRegionWidth() - 50) * 0.5)
		imgui.BeginChild('##exampleRp', imgui.ImVec2(imgui.GetWindowContentRegionWidth() - 50, 220), true)
		local text = u8[[
			{e3a3ff}#close:{09ab3f} -- закрываем меню взаимодействия
			{09ab3f}-- Рандомный тект ниже заменится на одно из предложений
			{e3a3ff}r:{Здравствуйте}{Добрый день}{Приветствую}r{ffffff}, меня зовут {ffff00}<myFio>{ffffff}.
			{e3a3ff}<1000>{09ab3f} -- задержка в 1 секунду
			Вы на собеседование?
			{e3a3ff}<0> {09ab3f}-- создаём ожидание, /mmnext - продолжить, /mmstop - остановить
			Пожалуйста, покажите Ваш паспорт.
			{e3a3ff}<0>
			/me достал трудовой договор
			{e3a3ff}<1000>
			{e3a3ff}#list: {LS}%{SF}%{LV}{09ab3f} -- создаем список с выбором
			/me в графе радиоцентр поставил галочку «{ffff00}{w}{ffffff}»
			{e3a3ff}<1000>
			/me в графе гражданин написал «{ffff00}<tFio>{ffffff}».
			{e3a3ff}#input:{09ab3f} -- создаём окно для ввода текста
			/me вписал должность «{ffff00}{w}{ffffff}».]]
		imgui.CustomText(text:gsub('            ',''))
		imgui.EndChild()
		imgui.Text('')
		imgui.CustomText(u8'\tСкопировать результат (КОПИРОВАТЬ НА РУС. РАССКЛАДКЕ):')
		imgui.SameLine()
		local text = [[#close:
			r:{Здравствуйте}{Добрый день}{Приветствую}:r, меня зовут <myFio>.
			<1000>
			Вы на собеседование?
			<0>
			Пожалуйста, покажите Ваш паспорт.
			<0>
			/me достал трудовой договор
			<1000>
			#list: {LS}{SF}{LV}
			/me в графе радиоцентр поставил галочку «{w}»
			<1000>
			/me в графе гражданин написал «<tFio>».
			#input:
			/me вписал должность «{w}».]]
		if imgui.SmallButton(u8'cкопировать') then setClipboardText(text:gsub('            ','')); printString("~y~Copied!", 1500) end
	end
end
function popupForRp() -- дополнительный popup, показывает созданные пункты

	local chap = settingsRp.selectedButton

	if #settingsRp.set[chap] == 0 then
		imgui.CustomText(u8'Кажется здесь пусто.', 2)
		imgui.CustomText(u8'Создайте новый пункт в настройках!',2)

		if imgui.Button(u8'Создать!', imgui.ImVec2(-0.1, 0)) then

			win_status.find[0], win_status.act[0] = false, false

			mainMenu[3].func[4]()

		end

	else

		for i = 1, #settingsRp.set[chap] do

			if imgui.Button(u8(settingsRp.set[chap][i].name .. '##' .. i), imgui.ImVec2(200, 20)) then
				imgui.CloseCurrentPopup()
				playRp(settingsRp.set[chap][i].text)
			end

		end

	end

end
function playRp(text, test, nothread)

	if settingsRp.active[0] then return end

	settingsRp.active[0] = true

	local text = util.jsonToText(text) .. '\n'
	local chap = settingsRp.selectedButton

	setCurTeg(chap)

	local typeTeg = settingsRp.curTegs -- 1 - мои отыгровки, 2 - MMACT, 3 - FIND

	-- Замена рандома

	for line in string.gmatch(text, 'r:(.-):r') do

		local randText = {}

		for rand in string.gmatch(line, '{(.-)}') do randText[#randText + 1] = rand end

		local id = math.random(1, #randText)

		text = text:gsub('r:' .. line .. ':r', randText[id], 1)

	end

	-- Замена тегов
	for i = 1, settingsRp.sumTegs do

		if settingsRp.tegs[1][i] then -- общие теги

			local textTeg = test and settingsRp.tegs[1][i][1] .. '{00c77b}:OK{CECECE}' or settingsRp.tegs[1][i][3]()

			text = text:gsub(settingsRp.tegs[1][i][1], textTeg)

		else -- отличие от общих

			local id = i - #settingsRp.tegs[1]
			local textTeg = test and settingsRp.tegs[typeTeg][id][1] .. '{00c77b}:OK{CECECE}' or settingsRp.tegs[typeTeg][id][3]()

			text = text:gsub(settingsRp.tegs[typeTeg][id][1], textTeg)

		end

	end

	local parserRp = function (text, test)

		if test then util.scriptmsg('{fff099}Тест отыгровки. Захваченые теги будут помечаться <тег>:OK.') end

		for line in string.gmatch(text, '(.-)\n') do

			if line == '' then goto skip end

			if line:find('^#.-:') then -- открытие доп окон отыгровок

				settingsRp.window.is = -1 -- доп окно активно, -2 - не относится к доп окнам, -1 - default/отмена, 1 - активно, 2 - отправка {w}
				settingsRp.window.select = 0 -- установка SELECT в окне доп. пунктов
				settingsRp.window.list = {} -- выбор в окне с пунктами
				settingsRp.window.textBL = '' -- текст замены черного списка
				imgui.StrCopy(settingsRp.window.buf, '') -- установка INPUT в окне с вводом

				local teg = line:match('#(.-):')

				if teg:lower() == 'input' and settingsRp.window.is == -1 then

					settingsRp.window.type = 1
					settingsRp.window.is = 1

				elseif teg:lower() == 'list' and settingsRp.window.is == -1 then

					for list in string.gmatch(line, '{(.-)}') do
						settingsRp.window.list[#settingsRp.window.list + 1] = list
					end

					settingsRp.window.type = 2
					settingsRp.window.is = 1

				elseif teg:lower() == 'close' then

					if typeTeg == 2 then win_status.act[0] = false
					elseif typeTeg == 3 then win_status.find[0] = false
					elseif typeTeg == 1 then win_status.settingsMenu[0] = false end

					settingsRp.window.is = -2

				elseif teg:lower() == 'bl' and typeTeg == 2 then

					settingsRp.window.type = 3
					settingsRp.window.is = -2
					local nickCheck = userTarget.nick or 'Andrey_Ringo' -- userTarget.nick

					settingsRp.waitBL = true
					local res = startCheckBL(nickCheck)
					settingsRp.waitBL = false

					local msg = res and '{ff6666}состоит{CECECE}' or '{00c77b}не состоит{CECECE}'

					util.scriptmsg('Игрок '.. nickCheck ..' '.. msg ..' в черном списке.')
					if res then util.scriptmsg('Строка из ЧС: ' .. res) end

					if line:find(':.-/.-') then

						local yes, no = line:match(':(.-)/(.+)')

						settingsRp.window.is = 2
						settingsRp.window.textBL = res and yes or no

					end

					wait(1500)

				end

				while settingsRp.window.is == 1 do wait(0) end -- ожидаем закрытия окна

				if settingsRp.window.is == -1 then settingsRp.active[0] = false return end

				goto skip

			end

			if line:find('^<%d+>') then -- задержка

				local time = tonumber(line:match('<(%d+)>'))

				if time == 0 then -- ожидать отыгровку при задержке в <0>

					settingsRp.wait = true

					while settingsRp.wait do wait(0) end

				end

				wait(time)

				goto skip

			end

			if settingsRp.window.is == 2 and line:find('{w}') then

				local bufText = u8:decode(str(settingsRp.window.buf))
				local select = settingsRp.window.select
				local type = settingsRp.window.type
				local BL = settingsRp.window.textBL

				if type == 1 then
					line = line:gsub('{w}', bufText)
				elseif type == 2 then
					line = line:gsub('{w}', settingsRp.window.list[select])
				elseif type == 3 then
					line = line:gsub('{w}', BL)
				end

			end

			if test then
				util.scriptmsg(line)
			else
				sampSendChat(line)
			end

			if not settingsRp.active[0] then util.scriptmsg('Отыгровка принудительно остановлена.') return end

			::skip::
		end

		settingsRp.active[0] = false
	end

	if nothread then
		parserRp(text, test)
	else
		threadRp = lua_thread.create(parserRp, text, test)
	end

end
function stopRp()

	if threadRp then

		if not (threadRp:status() == 'dead') then

			threadRp:terminate()
			util.scriptmsg('Отыгровка принудительно остановлена.')

		end

	end

	settingsRp.active[0] = false

end
imgui.OnFrame(
	function () return win_status.settingsMenu[0] and not settingsRp.active[0] end,
	function (player)

		imgui.SetNextWindowPos(imgui.ImVec2(w / 2, h / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(700, 400))

		imgui.Begin(faicon(0xf013) .. u8' Настройка пунктов меню и отыгровок',
			win_status.settingsMenu, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

		local wsize = imgui.GetWindowSize()

		imgui.BeginGroup()
		imgui.PushItemWidth(150)

		if imgui.Combo('##settingsRpCombo', settingsRp.setList, settingsRp.items, #chaptersRp) then

			local n = settingsRp.setList[0] + 1
			settingsRp.selected = n == 2 and 0 or 1
			settingsRp.myRpList[0] = 0
			updateChapterRp(n, 1)

		end

		imgui.PopItemWidth()

		local numItem = settingsRp.setList[0] + 1 -- Номер раздела
		local sizeList = settingsRp.myRpList[0] == 0 and #settingsRp.set[numItem] or #efir.set.dataRp -- Размер раздела
		local sizeFor = numItem == 1 and sizeList or sizeList + 1 -- Добавляет "Создать пункт"

		if numItem == 2 then -- МОИ ОТЫГРОВКИ

			imgui.SameLine()
			imgui.CustomText(u8'Настройка ваших отыгровок', 2)
			imgui.SameLine()
			imgui.SetCursorPosX(wsize.x - 150 - 44)
			imgui.CustomText(u8'Тип:')
			imgui.SameLine()

			imgui.PushItemWidth(150)

			if imgui.Combo('##typeMyRp', settingsRp.myRpList, settingsRp.myRpItems, #typeRp) then

				local n = settingsRp.myRpList[0] + 1 -- тип моих отыгровок (личные, эфиры)
				settingsRp.selected = 0

			end
			goto skipChild
		end

		imgui.BeginChild('##settingsRpList', imgui.ImVec2(150, 0), true)

		for i = 1, sizeFor do

			imgui.PushIDInt(i)

			if imgui.Selectable(i == sizeList + 1 and faicon.ICON_PLUS_CIRCLE .. u8' Создать пункт...'
				or u8(settingsRp.set[numItem][i].name), settingsRp.selected == i,
				imgui.SelectableFlags.SpanAllColumns) then

				settingsRp.selected = i
				updateChapterRp(numItem)

			end

			imgui.PopID()

		end

		imgui.EndChild()

		::skipChild::
		imgui.EndGroup()

		if numItem == 2 then windowMyRp(sizeList); goto skipChildTwo end

		imgui.SameLine()

		imgui.BeginChild('##settingsRpInfo', imgui.ImVec2(0, 0), false)
			if numItem > 2 then windowSettingsRp(numItem, sizeList, sizeFor)
			elseif numItem == 1 then windowInfoRp() end
		imgui.EndChild()

		::skipChildTwo::
		imgui.End()
	end
)

-- Оверлей РП отыгровок
imgui.OnFrame(
	function () return settingsRp.active[0] end,
	function (player)

		player.HideCursor = settingsRp.window.is ~= 1 and true or false

		local posX, posY = w - 125, h - 75

		if isCharInAnyCar(PLAYER_PED) then

			local car = storeCarCharIsInNoSave(PLAYER_PED)

			if isCharInCar(PLAYER_PED, car) then

				if getDriverOfCar(car) == PLAYER_PED then posY = h - 145 end

			end

		end

		if win_status.info[0] then posY = posY - 60 end

		imgui.SetNextWindowPos(imgui.ImVec2(posX, posY), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(200, 100))
		imgui.SetNextWindowBgAlpha(0.65)

		local flags = imgui.WindowFlags.NoDecoration + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoNav

		imgui.Begin('##overlayRp', nil, flags)

		imgui.CustomText(u8'Статус отыгровки', 2)

		imgui.Separator()
		imgui.Spacing()

		local status = 'Отыгровка работает...'

		if settingsRp.window.is == 1 then status = 'Ожидание ввода...'
		elseif settingsRp.waitBL then status = 'Проверка на ЧС...'
		elseif settingsRp.wait then status = 'Ожидание команды...' end


		imgui.CustomText(u8('{ff9933}' .. status), 2)

		imgui.Spacing()
		imgui.Separator()

		imgui.CustomText(u8'Остановить: /mmstop*', 2)
		imgui.CustomText(u8'Продолжить: /mmnext*', 2)

		if settingsRp.window.is == 1 and not imgui.IsPopupOpen(u8"Дополнительное окно отыгровки") then
			imgui.OpenPopup(u8"Дополнительное окно отыгровки")
		end

		if imgui.BeginPopupModal(u8"Дополнительное окно отыгровки", nil, imgui.WindowFlags.AlwaysAutoResize) then

			local wsize = imgui.GetWindowSize()

			imgui.Spacing()
			imgui.CustomText(u8'Нажмите кнопку "Отмена", чтобы прервать отыгровку')
			imgui.Spacing()

			if settingsRp.window.type == 1 then

				imgui.PushItemWidth(350)
				imgui.InputTextWithHint( "##plusRpInput", u8'Введите текст...', settingsRp.window.buf, sizeof(settingsRp.window.buf))
				imgui.PopItemWidth()

			else

				imgui.BeginChild('##childRpplus', imgui.ImVec2(imgui.GetWindowContentRegionWidth(), 85), true)

				for a = 1, #settingsRp.window.list do

					if imgui.Selectable(u8(settingsRp.window.list[a]), settingsRp.window.select == a) then

						settingsRp.window.select = a

					end

				end

				imgui.EndChild()

			end

			imgui.Spacing()

			imgui.SetCursorPosX(wsize.x * 0.5 - 150 - 5)

			if imgui.Button(u8'Отправить##Rp', imgui.ImVec2(150,20)) then

				if (settingsRp.window.type == 2 and settingsRp.window.select ~= 0)
					or (settingsRp.window.type == 1 and (u8:decode(str(settingsRp.window.buf))):len() ~= 0)  then

					settingsRp.window.is = 2
					imgui.CloseCurrentPopup()

				else
					printString("~y~Write or choose something!", 1500)
				end

			end

			imgui.SameLine()

			if imgui.Button(u8'Отменить##Rp', imgui.ImVec2(150, 0)) then

				settingsRp.window.is = -1
				imgui.CloseCurrentPopup()

			end

			imgui.EndPopup()

		end
		imgui.End()
	end
)

function hook.dia.create(name, id, title, ones, func)

	if type(func) ~= 'function' then print('DIAHOOK: нет функции') return end

	local newId = hook.dia.id + 1

	hook.dia[#hook.dia + 1] = {
		name = type(name) == 'string' and name or 'Новый диалог #' .. (#hook.dia + 1),  -- название для отображения
		idsys = newId,                                                                  -- id hook диалога
		id = type(id) == 'number' and id or '.*',                                       -- id для поиска
		title = type(title) and title or '.*',                                          -- title для поиска
		ones = type(ones) == 'boolean' and ones or false,                               -- хоок на 1 раз
		func = func,                                                                    -- функция хука
		run = true,                                                                     -- работает ли хук
	}

	hook.dia.id = hook.dia.id + 1

	return newId
end
function hook.msg.create(name, id, text, ones, func)

	if type(func) ~= 'function' then print('DIAHOOK: нет функции') return end

	local newId = hook.msg.id + 1

	hook.msg[#hook.msg + 1] = {
		name = type(name) == 'string' and name or 'Новое сообщение #' .. (#hook.msg + 1),   -- название для отображения
		idsys = newId,                                                                      -- id hook сообщения
		id = type(id) == 'number' and id or '.*',                                           -- id цвета для поиска
		text = type(text) and text or '.*',                                                 -- text для поиска
		ones = type(ones) == 'boolean' and ones or false,                                   -- хоок на 1 раз
		func = func,                                                                        -- функция хука
		run = true,                                                                         -- работает ли хук
	}

	hook.msg.id = hook.msg.id + 1

	return newId
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)

	for i = 1, #hook.dia do

		local dia = hook.dia[i]

		if tostring(dialogId):find('^'.. dia.id .. '$') and title:find(dia.title) and dia.run then

			if dia.ones then dia.run = false end

			return dia.func(dialogId, title, text, button1, button2)

		end

	end


	--[[

	if dialogId == settingsSys.dialogList[1].id and title:find(settingsSys.dialogList[1].title) and settings.scriptBool[2] then

		local i = 1
		listFind = {}

		for line in string.gmatch(text, '{FFFFFF}%d+.-\n') do

			listFind[i] = {}
			local nick

			listFind[i].id, listFind[i].lvl, listFind[i].phone, listFind[i].rang, listFind[i].podr,
			listFind[i].warn, nick = line:match("{FFFFFF}(%d+)\t(%d+)\t\t(.-)\t\t\t\t(%d+) (.-)\t\t(%d)/%d\t(.-)\n")

			listFind[i].voice = nick:find('VOICE') and true or false --
			listFind[i].afk = nick:match('{009933}%[(.-)%]{FFFFFF}') or false --
			listFind[i].mute = nick:match('{FF764B}%[ .- %]{FFFFFF}') and true or false --
			listFind[i].nick = nick:gsub('{009933}.-{FFFFFF}', ''):gsub('%[VOICE%]',''):gsub('{FF764B}.-{FFFFFF}',''):gsub('%s+', '')

			i = i + 1

		end

		table.sort(listFind, function (a, b) return (tonumber(a.rang) > tonumber(b.rang)) end)

		listFind.selected = 0
		win_status.find[0] = true

		sampSendDialogResponse(dialogId, 0, 1, -1)

		return false

	end

	if editVars.updAd then

		editVars.updAd = false

		if dialogId == settingsSys.dialogList[2].id and title:find(settingsSys.dialogList[2].title) then
			sampSendDialogResponse(dialogId, 0, 1, -1)
			return false
		end

	end

	if dialogId == dia[3].id and title:find(dia[3].title) and not editVars.updAd and settings.scriptBool[3] then

		editVars.ad = text:match('Текст:%s+{FFCC15}(.-)\n')
		editVars.from = text:match('Отправитель:%s+(.-)\n')
		imgui.StrCopy(editVars.inputEdit, '')
		imgui.StrCopy(editList.search, '')

		editVars.appear = true
		win_status.edit[0] = true

		return true

	end
	-]]

end
function sampev.onServerMessage(color, text)

	for i = 1, #hook.msg do

		local msg = hook.msg[i]

		if tostring(color):find('^'.. msg.id .. '$') and text:find(msg.text) and msg.run then

			if msg.ones then msg.run = false end

			local callBack = msg.func(color, text)

			if not callBack or type(callBack) == 'table' then return type(callBack) == 'table' and callBack or false end

		end

	end

end
function sampev.onSendCommand(text)

	if not isScriptActive then return true end

	local args = util.split(text, " ")
	local cmd = util.lower(table.remove(args, 1)):gsub('/', '')
	local text = table.concat(args,' ')
	local text_sms = table.concat(args, ' ', 2)

	if cmd == 'r' and (settings.scriptBuf[1]):len() ~= 0 then return {'/r ' .. settings.scriptBuf[1] .. ' ' .. text} end
	if cmd == 'f' and (settings.scriptBuf[2]):len() ~= 0 then return {'/f ' .. settings.scriptBuf[2] .. ' ' .. text} end
	if cmd == 'smsn' and text_sms:len() ~= 0 then return {'/sms '.. args[1] ..' (( ' .. text_sms .. ' ))'} end

	if settingsRp.active[0] then return true end

	for i = 1, #settingsRp.set[2] do

		local cmdRp = settingsRp.set[2][i].cmd

		if cmdRp:len() > 0 then

			if (cmd .. ' ' .. text):find('^' .. cmdRp) then

				settingsRp.selectedButton = 2
				playRp(settingsRp.set[2][i].text)

				return false

			end

		end

	end

end
function sampev.onSendChat(text)

	if not isScriptActive then return true end

	if (settings.scriptBuf[3]):len() ~= 0 then return {settings.scriptBuf[3] .. ' ' .. text} end
	if efir.set.bool[4] then return {'/t ' .. text} end

end

function onScriptTerminate(LuaScript, quitGame)
	if LuaScript == thisScript() then

		if efir.on then

			print('Экстренное сохранение настроек эфира.')
			endEfir()

		end

	end
end

function rkeys.onHotKey(id, data)

	if not isScriptActive then return false end

	if isSampfuncsConsoleActive() or sampIsChatInputActive() or sampIsDialogActive() or isGamePaused() then
		return false
	end

	for k, v in pairs(win_status) do

		--if v[0] and k == 'info' then return true end

		if v[0] and k ~= 'info' and
			(not (#data.keys > 1)
			or (mainMenu.selected[1] == 3 and mainMenu.selected[2] == 2 and k == 'main')) then

		return false end

	end

	for k, v in pairs(efir.win) do

		if v[0] and not (#data.keys > 1) then return false end

	end

	if win_status.settingsMenu[0] and not settingsRp.active[0] then return false end

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
function imgui.CustomText(text, pos, iscolumn)
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
		--[[if color:sub(1, 6):upper() == 'SSSSSS' then
			local r, g, b = colors[1].x, colors[1].y, colors[1].z
			local a = tonumber(color:sub(7, 8), 16) or colors[1].w * 255
			return ImVec4(r, g, b, a / 255)
		end--]]
		local color = type(color) == 'string' and tonumber(color, 16) or color
		if type(color) ~= 'number' then return end
		local r, g, b, a = explode_argb(color)
		return ImVec4(r / 255, g / 255, b / 255, a / 255)
	end

	local render_text = function(text_)
		local text_ = tostring(text_)
		for wCustom in text_:gmatch('[^\r\n]+') do
			local textsize = wCustom:gsub('{......}', '')
			if pos == 2 then
				local text_width = imgui.CalcTextSize(textsize)
				local column = iscolumn and imgui.GetColumnOffset() or 0
				imgui.SetCursorPosX(column + width * 0.5 - text_width.x * 0.5 )
			end
			local text, colors_, m = {}, {}, 1
			wCustom = wCustom:gsub('{(......)}', '{%1FF}')
			while wCustom:find('{........}') do
				local n, k = wCustom:find('{........}')
				local color = getcolor(wCustom:sub(n + 1, k - 1))
				if color then
					text[#text], text[#text + 1] = wCustom:sub(m, n - 1), wCustom:sub(k + 1, #wCustom)
					colors_[#colors_ + 1] = color
					m = n
				end
				wCustom = wCustom:sub(1, n - 1) .. wCustom:sub(k + 1, #wCustom)
			end
			if text[0] then
				for i = 0, #text do
					imgui.TextColored(colors_[i] or colors[imgui.Col.Text], (text[i]))
					imgui.SameLine(nil, 0)
				end
				imgui.NewLine()
			else
				imgui.Text(wCustom)
			end
		end
	end
	render_text(text)
end
function imgui.CustomSlider(str_id, min, max, width, int) -- by aurora
	local p = imgui.GetCursorScreenPos()
	local draw_list = imgui.GetWindowDrawList()
	local pos = imgui.GetWindowPos()
	local posx, posy = getCursorPos()
	local n = max - min
	if int[0] == 0 then
		int[0] = min
	end
	local col_bg_active = imgui.GetColorU32Vec4(imgui.GetStyle().Colors[imgui.Col.ButtonActive])
	local col_bg_notactive = imgui.GetColorU32Vec4(imgui.GetStyle().Colors[imgui.Col.ModalWindowDimBg])
	draw_list:AddRectFilled(imgui.ImVec2(p.x + 7, p.y + 12), imgui.ImVec2(p.x + (width/n)*(int[0]-min), p.y + 12), col_bg_active, 5.0)
	draw_list:AddRectFilled(imgui.ImVec2(p.x + (width/n)*(int[0]-min), p.y + 12), imgui.ImVec2(p.x + width, p.y + 12), col_bg_notactive, 5.0)
	for i = 0, n do
		if posx > (p.x + i*width/(max+1) ) and posx < (p.x + (i+1)*width/(max+1)) and posy > p.y + 2 and posy < p.y + 22 and imgui.IsMouseDown(0) then
			int[0] = i + min
			draw_list:AddCircleFilled(imgui.ImVec2(p.x + (width/n)*(int[0]-min) + 4,  p.y + 7*2 - 2), 7+2, col_bg_active)
		end
	end
	--imgui.SetCursorPos(imgui.ImVec2(p.x + width + 6 - pos.x, p.y - 8 - pos.y))
	--imgui.Text(tostring(int[0]))
	draw_list:AddCircleFilled(imgui.ImVec2(p.x + (width/n)*(int[0]-min) + 4,  p.y + 7*2 - 2), 7, col_bg_active)
	--imgui.SetCursorPos(imgui.ImVec2(p.x - width - 6 - pos.x, p.y + 8 + pos.y))
	--imgui.NewLine()
	return int
end
function imgui.CenterColumnText(text, onlypos)
	imgui.SetCursorPosX((imgui.GetColumnOffset() + (imgui.GetColumnWidth() / 2)) - imgui.CalcTextSize(text).x / 2)
	if not onlypos then imgui.Text(text) end
end
function imgui.VerticalSeparator()
	local pos = imgui.GetCursorScreenPos()
	local drawlist = imgui.GetWindowDrawList()
	local color = imgui.GetColorU32Vec4(imgui.GetStyle().Colors[imgui.Col.Separator])
	drawlist:AddLine(imgui.ImVec2(pos.x - 8, pos.y - 12), imgui.ImVec2(pos.x, 0xFFFFFF), color)
end

local russian_characters = {
	[168] = 'Ё', [184] = 'ё', [192] = 'А', [193] = 'Б', [194] = 'В', [195] = 'Г', [196] = 'Д', [197] = 'Е', [198] = 'Ж', [199] = 'З', [200] = 'И', [201] = 'Й', [202] = 'К', [203] = 'Л', [204] = 'М', [205] = 'Н', [206] = 'О', [207] = 'П', [208] = 'Р', [209] = 'С', [210] = 'Т', [211] = 'У', [212] = 'Ф', [213] = 'Х', [214] = 'Ц', [215] = 'Ч', [216] = 'Ш', [217] = 'Щ', [218] = 'Ъ', [219] = 'Ы', [220] = 'Ь', [221] = 'Э', [222] = 'Ю', [223] = 'Я', [224] = 'а', [225] = 'б', [226] = 'в', [227] = 'г', [228] = 'д', [229] = 'е', [230] = 'ж', [231] = 'з', [232] = 'и', [233] = 'й', [234] = 'к', [235] = 'л', [236] = 'м', [237] = 'н', [238] = 'о', [239] = 'п', [240] = 'р', [241] = 'с', [242] = 'т', [243] = 'у', [244] = 'ф', [245] = 'х', [246] = 'ц', [247] = 'ч', [248] = 'ш', [249] = 'щ', [250] = 'ъ', [251] = 'ы', [252] = 'ь', [253] = 'э', [254] = 'ю', [255] = 'я',
}
function util.lower(s)

	s = s:lower()

	local strlen = s:len()

	if strlen == 0 then return s end

	local output = ''

	for i = 1, strlen do
		local ch = s:byte(i)
		if ch >= 192 and ch <= 223 then -- upper russian characters
			output = output .. russian_characters[ch + 32]
		elseif ch == 168 then -- Ё
			output = output .. russian_characters[184]
		else
			output = output .. string.char(ch)
		end
	end
	return output
end
function util.upper(s)

	s = s:upper()

	local strlen = s:len()

	if strlen == 0 then return s end

	local output = ''
	for i = 1, strlen do
		local ch = s:byte(i)
		if ch >= 224 and ch <= 255 then -- lower russian characters
			output = output .. russian_characters[ch - 32]
		elseif ch == 184 then -- ё
			output = output .. russian_characters[168]
		else
			output = output .. string.char(ch)
		end
	end
	return output
end

request = { }
function request.run(request, body, handler) -- copas.http
	-- start polling task
	if not copas.running then
		copas.running = true
		lua_thread.create(function()
			wait(0)
			while not copas.finished() do
				local ok, err = copas.step(0)
				if ok == nil then error(err) end
				wait(0)
			end
			copas.running = false
		end)
	end
	-- do request
	if handler then
		return copas.addthread(function(r, b, h)
			copas.setErrorHandler(function(err) h(nil, err) end)
			h(http.request(r, b))
		end, request, body, handler)
	else
		local results
		local thread = copas.addthread(function(r, b)
			copas.setErrorHandler(function(err) results = {nil, err} end)
			results = table.pack(http.request(r, b))
		end, request, body)
		while coroutine.status(thread) ~= 'dead' do wait(0) end
		return table.unpack(results)
	end
end
function request.build(query)
	if query == nil then return end
	local buff=""
	for k, v in pairs(query) do
		if type(v) == 'table' then
			for _, m in ipairs(v) do
				buff = buff.. string.format("%s[]=%s&", k, util.urlencode(m))
			end
		else buff = buff.. string.format("%s=%s&", k, util.urlencode(v)) end
	end
	local buff = string.reverse(string.gsub(string.reverse(buff), "&", "", 1))
	return buff
end

function sampGetPlayerIdByNickname(nick)

	local nick = tostring(nick) or ''
	local _, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)

	if nick == sampGetPlayerNickname(myid) then return myid end

	for i = 0, 1003 do
		if sampIsPlayerConnected(i) and sampGetPlayerNickname(i) == nick then return i end
	end

	return nil
end