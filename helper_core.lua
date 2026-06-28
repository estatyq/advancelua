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
local ffi = require 'ffi'
local sampev = require 'lib.samp.events'
local encoding = require 'encoding'
local json = require 'json'
local memory = require 'memory'
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
local max_calls_session = imgui.new.int(50)
local call_current_nick = ""
local call_current_phone = ""
local last_called = {}
local call_cooldown_hours = imgui.new.int(1)  -- don't re-call same person for N hours

-- Переменные для модуля "MM Editor" (СМИ Редактор)
local mm_auto_format = imgui.new.bool(true)
local mm_auto_send = imgui.new.bool(false)
local mm_send_delay = imgui.new.int(3000)
local mm_tag = imgui.new.char[8]("LV")
local ae_active = imgui.new.bool(false)
local ae_dialog_id = -1
local ae_original_text = ""
local ae_formatted_text = ""
local ae_input_buf = imgui.new.char[1024]("")
local ae_focus = false
local test_input = imgui.new.char[128]("")
local test_output = ""
local mm_rules = {
-- Машины
{abbreviation = "булка", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "булку", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "булки", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "булке", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "булкой", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "инф", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "инфу", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "инфе", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "инфы", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "инфом", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "туризмо", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "турик", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "турика", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "турику", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "турике", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "банши", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "баншу", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "банше", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "баншей", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "чито", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "читу", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "чите", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "супергт", replacement = "а/м марки \"Super GT\" FT"},
{abbreviation = "супергта", replacement = "а/м марки \"Super GT\" FT"},
{abbreviation = "супергту", replacement = "а/м марки \"Super GT\" FT"},
{abbreviation = "стингер", replacement = "а/м марки \"Stinger\" FT"},
{abbreviation = "стингера", replacement = "а/м марки \"Stinger\" FT"},
{abbreviation = "стингеру", replacement = "а/м марки \"Stinger\" FT"},
{abbreviation = "комета", replacement = "а/м марки \"Comet\" FT"},
{abbreviation = "комету", replacement = "а/м марки \"Comet\" FT"},
{abbreviation = "кометы", replacement = "а/м марки \"Comet\" FT"},
{abbreviation = "комете", replacement = "а/м марки \"Comet\" FT"},
{abbreviation = "феникс", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "феникса", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "фениксу", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "чампион", replacement = "а/м марки \"Champion\" FT"},
{abbreviation = "чампиона", replacement = "а/м марки \"Champion\" FT"},
{abbreviation = "чампиону", replacement = "а/м марки \"Champion\" FT"},
{abbreviation = "альфа", replacement = "а/м марки \"Alpha\" FT"},
{abbreviation = "альфу", replacement = "а/м марки \"Alpha\" FT"},
{abbreviation = "альфы", replacement = "а/м марки \"Alpha\" FT"},
{abbreviation = "кловер", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "кловера", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "кловеру", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "кловеры", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "сабре", replacement = "а/м марки \"Sabre\" FT"},
{abbreviation = "сабра", replacement = "а/м марки \"Sabre\" FT"},
{abbreviation = "сабру", replacement = "а/м марки \"Sabre\" FT"},
{abbreviation = "сабры", replacement = "а/м марки \"Sabre\" FT"},
{abbreviation = "вуду", replacement = "а/м марки \"Voodoo\" FT"},
{abbreviation = "вуды", replacement = "а/м марки \"Voodoo\" FT"},
{abbreviation = "сламван", replacement = "а/м марки \"Slamvan\" FT"},
{abbreviation = "сламвана", replacement = "а/м марки \"Slamvan\" FT"},
{abbreviation = "сламвану", replacement = "а/м марки \"Slamvan\" FT"},
{abbreviation = "ремингтон", replacement = "а/м марки \"Remington\" FT"},
{abbreviation = "ремингтона", replacement = "а/м марки \"Remington\" FT"},
{abbreviation = "ремингтону", replacement = "а/м марки \"Remington\" FT"},
{abbreviation = "бравура", replacement = "а/м марки \"Bravura\" FT"},
{abbreviation = "бравуру", replacement = "а/м марки \"Bravura\" FT"},
{abbreviation = "бравуры", replacement = "а/м марки \"Bravura\" FT"},
{abbreviation = "блейд", replacement = "а/м марки \"Blade\" FT"},
{abbreviation = "блейда", replacement = "а/м марки \"Blade\" FT"},
{abbreviation = "блейду", replacement = "а/м марки \"Blade\" FT"},
{abbreviation = "тампла", replacement = "а/м марки \"Tampa\" FT FT"},
{abbreviation = "тамплу", replacement = "а/м марки \"Tampa\" FT FT"},
{abbreviation = "торнадо", replacement = "а/м марки \"Tornado\" FT"},
{abbreviation = "торнадоа", replacement = "а/м марки \"Tornado\" FT"},
{abbreviation = "торнадоу", replacement = "а/м марки \"Tornado\" FT"},
{abbreviation = "султан", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "султана", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "султану", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "султаны", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "султане", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "султаном", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "сультан", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "сультана", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "сультану", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "сультаны", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "елегию", replacement = "а/м марки \"Elegy\" FT"},
{abbreviation = "еледжи", replacement = "а/м марки \"Elegy\" FT"},
{abbreviation = "елеги", replacement = "а/м марки \"Elegy\" FT"},
{abbreviation = "елегия", replacement = "а/м марки \"Elegy\" FT"},
{abbreviation = "елеге", replacement = "а/м марки \"Elegy\" FT"},
{abbreviation = "флеш", replacement = "а/м марки \"Flash\" FT"},
{abbreviation = "флеша", replacement = "а/м марки \"Flash\" FT"},
{abbreviation = "флешу", replacement = "а/м марки \"Flash\" FT"},
{abbreviation = "джестер", replacement = "а/м марки \"Jester\" FT"},
{abbreviation = "джестера", replacement = "а/м марки \"Jester\" FT"},
{abbreviation = "джестеру", replacement = "а/м марки \"Jester\" FT"},
{abbreviation = "стратум", replacement = "а/м марки \"Stratum\" FT"},
{abbreviation = "стратума", replacement = "а/м марки \"Stratum\" FT"},
{abbreviation = "стратуму", replacement = "а/м марки \"Stratum\" FT"},
{abbreviation = "уран", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "урана", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "урану", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "ураны", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "салат", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "салата", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "салату", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "стрикер", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "стрикера", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "адреналин", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "адреналина", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "пикап", replacement = "а/м марки \"Picador\" FT"},
{abbreviation = "пикапа", replacement = "а/м марки \"Picador\" FT"},
{abbreviation = "пикапу", replacement = "а/м марки \"Picador\" FT"},
{abbreviation = "соляр", replacement = "а/м марки \"Solair\" FT"},
{abbreviation = "соляра", replacement = "а/м марки \"Solair\" FT"},
{abbreviation = "соляру", replacement = "а/м марки \"Solair\" FT"},
{abbreviation = "винсаг", replacement = "а/м марки \"Windsor\" FT"},
{abbreviation = "винсага", replacement = "а/м марки \"Windsor\" FT"},
{abbreviation = "винсагу", replacement = "а/м марки \"Windsor\" FT"},
{abbreviation = "шафтер", replacement = "а/м марки \"Stafford\" FT"},
{abbreviation = "шафтера", replacement = "а/м марки \"Stafford\" FT"},
{abbreviation = "шафтеру", replacement = "а/м марки \"Stafford\" FT"},
{abbreviation = "хантер", replacement = "а/м марки \"Huntley\" FT"},
{abbreviation = "хантера", replacement = "а/м марки \"Huntley\" FT"},
{abbreviation = "хантеру", replacement = "а/м марки \"Huntley\" FT"},
{abbreviation = "ранчер", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "ранчера", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "ранчеру", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "ранчо", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "ранчоа", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "йосемити", replacement = "а/м марки \"Yosemite\" FT"},
{abbreviation = "йосемитиа", replacement = "а/м марки \"Yosemite\" FT"},
{abbreviation = "бобкэт", replacement = "а/м марки \"Bobcat\" FT"},
{abbreviation = "бобкэта", replacement = "а/м марки \"Bobcat\" FT"},
{abbreviation = "бобкэту", replacement = "а/м марки \"Bobcat\" FT"},
{abbreviation = "премьер", replacement = "а/м марки \"Premier\" FT"},
{abbreviation = "премьера", replacement = "а/м марки \"Premier\" FT"},
{abbreviation = "премьеру", replacement = "а/м марки \"Premier\" FT"},
{abbreviation = "стретч", replacement = "а/м марки \"Stretch\" FT"},
{abbreviation = "стретча", replacement = "а/м марки \"Stretch\" FT"},
{abbreviation = "стретчу", replacement = "а/м марки \"Stretch\" FT"},
{abbreviation = "адмирал", replacement = "а/м марки \"Admiral\" FT"},
{abbreviation = "адмирала", replacement = "а/м марки \"Admiral\" FT"},
{abbreviation = "адмиралу", replacement = "а/м марки \"Admiral\" FT"},
{abbreviation = "вашингтон", replacement = "а/м марки \"Washington\" FT"},
{abbreviation = "вашингтона", replacement = "а/м марки \"Washington\" FT"},
{abbreviation = "вашингтону", replacement = "а/м марки \"Washington\" FT"},
{abbreviation = "винвуд", replacement = "а/м марки \"Willard\" FT"},
{abbreviation = "винвуда", replacement = "а/м марки \"Willard\" FT"},
{abbreviation = "эмперор", replacement = "а/м марки \"Emperor\" FT"},
{abbreviation = "эмперора", replacement = "а/м марки \"Emperor\" FT"},
{abbreviation = "эмперору", replacement = "а/м марки \"Emperor\" FT"},
{abbreviation = "элеганс", replacement = "а/м марки \"Elegant\" FT"},
{abbreviation = "элеганса", replacement = "а/м марки \"Elegant\" FT"},
{abbreviation = "элегансу", replacement = "а/м марки \"Elegant\" FT"},
{abbreviation = "глендейл", replacement = "а/м марки \"Glendale\" FT"},
{abbreviation = "глендейла", replacement = "а/м марки \"Glendale\" FT"},
{abbreviation = "глендейлу", replacement = "а/м марки \"Glendale\" FT"},
{abbreviation = "манана", replacement = "а/м марки \"Manana\" FT"},
{abbreviation = "манану", replacement = "а/м марки \"Manana\" FT"},
{abbreviation = "мананы", replacement = "а/м марки \"Manana\" FT"},
{abbreviation = "манане", replacement = "а/м марки \"Manana\" FT"},
{abbreviation = "блиста", replacement = "а/м марки \"Blista\" FT"},
{abbreviation = "блисту", replacement = "а/м марки \"Blista\" FT"},
{abbreviation = "блисты", replacement = "а/м марки \"Blista\" FT"},
{abbreviation = "фортун", replacement = "а/м марки \"Fortune\" FT"},
{abbreviation = "фортуна", replacement = "а/м марки \"Fortune\" FT"},
{abbreviation = "фортуну", replacement = "а/м марки \"Fortune\" FT"},
{abbreviation = "сентинел", replacement = "а/м марки \"Sentinel\" FT"},
{abbreviation = "сентинела", replacement = "а/м марки \"Sentinel\" FT"},
{abbreviation = "сентинелу", replacement = "а/м марки \"Sentinel\" FT"},
{abbreviation = "букер", replacement = "а/м марки \"Buccaneer\" FT"},
{abbreviation = "букера", replacement = "а/м марки \"Buccaneer\" FT"},
{abbreviation = "букеру", replacement = "а/м марки \"Buccaneer\" FT"},
{abbreviation = "хёрмит", replacement = "а/м марки \"Hermes\" FT"},
{abbreviation = "хёрмита", replacement = "а/м марки \"Hermes\" FT"},
{abbreviation = "хёрмиту", replacement = "а/м марки \"Hermes\" FT"},
{abbreviation = "маджестик", replacement = "а/м марки \"Majestic\" FT"},
{abbreviation = "маджестика", replacement = "а/м марки \"Majestic\" FT"},
{abbreviation = "невада", replacement = "а/м марки \"Nevada\" FT"},
{abbreviation = "неваду", replacement = "а/м марки \"Nevada\" FT"},
{abbreviation = "невады", replacement = "а/м марки \"Nevada\" FT"},
{abbreviation = "примо", replacement = "а/м марки \"Primo\" FT"},
{abbreviation = "примоа", replacement = "а/м марки \"Primo\" FT"},
{abbreviation = "хоткнайф", replacement = "а/м марки \"Hotknife\" FT"},
{abbreviation = "хоткнайфа", replacement = "а/м марки \"Hotknife\" FT"},
{abbreviation = "хоткнайфу", replacement = "а/м марки \"Hotknife\" FT"},
{abbreviation = "дюна", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "дюну", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "дюны", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "дюне", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "монстр", replacement = "а/м марки \"Monster\" FT"},
{abbreviation = "монстра", replacement = "а/м марки \"Monster\" FT"},
{abbreviation = "монстру", replacement = "а/м марки \"Monster\" FT"},
{abbreviation = "монстры", replacement = "а/м марки \"Monster\" FT"},
{abbreviation = "бандито", replacement = "а/м марки \"Bandito\" FT"},
{abbreviation = "бандита", replacement = "а/м марки \"Bandito\" FT"},
{abbreviation = "бандиту", replacement = "а/м марки \"Bandito\" FT"},
{abbreviation = "кальцо", replacement = "а/м марки \"Calcium\" FT"},
{abbreviation = "кальцию", replacement = "а/м марки \"Calcium\" FT"},
{abbreviation = "кальция", replacement = "а/м марки \"Calcium\" FT"},
{abbreviation = "патриот", replacement = "а/м марки \"Patriot\" FT"},
{abbreviation = "патриота", replacement = "а/м марки \"Patriot\" FT"},
{abbreviation = "патриоту", replacement = "а/м марки \"Patriot\" FT"},
{abbreviation = "хотринг", replacement = "а/м марки \"Hotring\" FT"},
{abbreviation = "хотринга", replacement = "а/м марки \"Hotring\" FT"},
{abbreviation = "хотрингу", replacement = "а/м марки \"Hotring\" FT"},
{abbreviation = "хотрингер", replacement = "а/м марки \"Hotring\" FT"},
{abbreviation = "хотрингера", replacement = "а/м марки \"Hotring\" FT"},
{abbreviation = "багги", replacement = "а/м марки \"Bandito\" FT"},
{abbreviation = "баггиа", replacement = "а/м марки \"Bandito\" FT"},
{abbreviation = "крэйг", replacement = "а/м марки \"Crane\" FT"},
{abbreviation = "крэйга", replacement = "а/м марки \"Crane\" FT"},
{abbreviation = "инфернус", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "инфернуса", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "инфернусу", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "буллет", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "буллета", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "буллету", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "турисмо", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "турисмоа", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "ковбой", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "ковбоя", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "сэлбрайт", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "сэлбрайта", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "тампико", replacement = "а/м марки \"Tampa\" FT FT"},
{abbreviation = "фортуне", replacement = "а/м марки \"Fortune\" FT"},
{abbreviation = "фортунеа", replacement = "а/м марки \"Fortune\" FT"},
{abbreviation = "элегант", replacement = "а/м марки \"Elegant\" FT"},
{abbreviation = "элеганта", replacement = "а/м марки \"Elegant\" FT"},
{abbreviation = "октан", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "октана", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "октану", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "зр350", replacement = "а/м марки \"ZR-350\" FT"},
{abbreviation = "зр350а", replacement = "а/м марки \"ZR-350\" FT"},
{abbreviation = "зр", replacement = "а/м марки \"ZR-350\" FT"},
{abbreviation = "зра", replacement = "а/м марки \"ZR-350\" FT"},
{abbreviation = "файрберд", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "файрберда", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "чирок", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "чирока", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "банка", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "банку", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "шевроле", replacement = "а/м марки \"Chevrolet\" FT"},
{abbreviation = "шевролеа", replacement = "а/м марки \"Chevrolet\" FT"},
{abbreviation = "ламбо", replacement = "а/м марки \"Lamborghini\" FT"},
{abbreviation = "ламбу", replacement = "а/м марки \"Lamborghini\" FT"},
{abbreviation = "бмв", replacement = "а/м марки \"BMW\" FT"},
{abbreviation = "бмву", replacement = "а/м марки \"BMW\" FT"},
{abbreviation = "мерс", replacement = "а/м марки \"Mercedes\" FT"},
{abbreviation = "мерса", replacement = "а/м марки \"Mercedes\" FT"},
{abbreviation = "мерсу", replacement = "а/м марки \"Mercedes\" FT"},
{abbreviation = "тойота", replacement = "а/м марки \"Toyota\" FT"},
{abbreviation = "тойоту", replacement = "а/м марки \"Toyota\" FT"},
{abbreviation = "тойоты", replacement = "а/м марки \"Toyota\" FT"},
{abbreviation = "ауди", replacement = "а/м марки \"Audi\" FT"},
{abbreviation = "аудиа", replacement = "а/м марки \"Audi\" FT"},
{abbreviation = "порше", replacement = "а/м марки \"Porsche\" FT"},
{abbreviation = "поршеа", replacement = "а/м марки \"Porsche\" FT"},
{abbreviation = "феррари", replacement = "а/м марки \"Ferrari\" FT"},
{abbreviation = "феррариа", replacement = "а/м марки \"Ferrari\" FT"},
{abbreviation = "лексус", replacement = "а/м марки \"Lexus\" FT"},
{abbreviation = "лексуса", replacement = "а/м марки \"Lexus\" FT"},
{abbreviation = "хонда", replacement = "а/м марки \"Honda\" FT"},
{abbreviation = "хонду", replacement = "а/м марки \"Honda\" FT"},
{abbreviation = "хонды", replacement = "а/м марки \"Honda\" FT"},
{abbreviation = "ниссан", replacement = "а/м марки \"Nissan\" FT"},
{abbreviation = "ниссана", replacement = "а/м марки \"Nissan\" FT"},
{abbreviation = "мазда", replacement = "а/м марки \"Mazda\" FT"},
{abbreviation = "мазду", replacement = "а/м марки \"Mazda\" FT"},
{abbreviation = "мазды", replacement = "а/м марки \"Mazda\" FT"},
{abbreviation = "субару", replacement = "а/м марки \"Subaru\" FT"},
{abbreviation = "субаруа", replacement = "а/м марки \"Subaru\" FT"},
{abbreviation = "митсубиси", replacement = "а/м марки \"Mitsubishi\" FT"},
{abbreviation = "крайслер", replacement = "а/м марки \"Chrysler\" FT"},
{abbreviation = "крайслера", replacement = "а/м марки \"Chrysler\" FT"},
{abbreviation = "форд", replacement = "а/м марки \"Ford\" FT"},
{abbreviation = "форда", replacement = "а/м марки \"Ford\" FT"},
{abbreviation = "форду", replacement = "а/м марки \"Ford\" FT"},
{abbreviation = "вольво", replacement = "а/м марки \"Volvo\" FT"},
{abbreviation = "бьюик", replacement = "а/м марки \"Buick\" FT"},
{abbreviation = "бьюика", replacement = "а/м марки \"Buick\" FT"},
{abbreviation = "кадиллак", replacement = "а/м марки \"Cadillac\" FT"},
{abbreviation = "кадиллака", replacement = "а/м марки \"Cadillac\" FT"},
{abbreviation = "понтиак", replacement = "а/м марки \"Pontiac\" FT"},
{abbreviation = "понтиака", replacement = "а/м марки \"Pontiac\" FT"},
{abbreviation = "додж", replacement = "а/м марки \"Dodge\" FT"},
{abbreviation = "доджа", replacement = "а/м марки \"Dodge\" FT"},
{abbreviation = "доджу", replacement = "а/м марки \"Dodge\" FT"},
{abbreviation = "ягуар", replacement = "а/м марки \"Jaguar\" FT"},
{abbreviation = "ягуара", replacement = "а/м марки \"Jaguar\" FT"},
{abbreviation = "бентли", replacement = "а/м марки \"Bentley\" FT"},
{abbreviation = "бентлиа", replacement = "а/м марки \"Bentley\" FT"},
{abbreviation = "роллсройс", replacement = "а/м марки \"Rolls-Royce\" FT"},
{abbreviation = "мазерати", replacement = "а/м марки \"Maserati\" FT"},
{abbreviation = "астонмартин", replacement = "а/м марки \"Aston Martin\" FT"},
{abbreviation = "бугатти", replacement = "а/м марки \"Bugatti\" FT"},
{abbreviation = "тачку", replacement = "а/м"},
{abbreviation = "тачка", replacement = "а/м"},
{abbreviation = "тачки", replacement = "а/м"},
{abbreviation = "тачке", replacement = "а/м"},
{abbreviation = "таз", replacement = "а/м"},
{abbreviation = "таза", replacement = "а/м"},
{abbreviation = "тазу", replacement = "а/м"},
{abbreviation = "машину", replacement = "а/м"},
{abbreviation = "машина", replacement = "а/м"},
{abbreviation = "машины", replacement = "а/м"},
{abbreviation = "машине", replacement = "а/м"},
{abbreviation = "авто", replacement = "а/м"},
{abbreviation = "автоа", replacement = "а/м"},
{abbreviation = "лодка", replacement = "лодку"},
{abbreviation = "лодку", replacement = "лодку"},
{abbreviation = "лодки", replacement = "лодку"},
{abbreviation = "лодке", replacement = "лодку"},
{abbreviation = "яхта", replacement = "яхту"},
{abbreviation = "яхту", replacement = "яхту"},
{abbreviation = "яхты", replacement = "яхту"},
{abbreviation = "яхте", replacement = "яхту"},
{abbreviation = "самолет", replacement = "самолёт"},
{abbreviation = "самолёт", replacement = "самолёт"},
{abbreviation = "самолёта", replacement = "самолёт"},
{abbreviation = "вертолет", replacement = "вертолёт"},
{abbreviation = "вертолёт", replacement = "вертолёт"},
{abbreviation = "вертолёта", replacement = "вертолёт"},
-- Мото
{abbreviation = "нрг", replacement = "мото марки \"NRG-500\" FT"},
{abbreviation = "нргу", replacement = "мото марки \"NRG-500\" FT"},
{abbreviation = "нрга", replacement = "мото марки \"NRG-500\" FT"},
{abbreviation = "нрге", replacement = "мото марки \"NRG-500\" FT"},
{abbreviation = "нрги", replacement = "мото марки \"NRG-500\" FT"},
{abbreviation = "фрей", replacement = "мото марки \"Freeway\" FT"},
{abbreviation = "фрея", replacement = "мото марки \"Freeway\" FT"},
{abbreviation = "фрею", replacement = "мото марки \"Freeway\" FT"},
{abbreviation = "вейб", replacement = "мото марки \"Wayfarer\" FT"},
{abbreviation = "вейба", replacement = "мото марки \"Wayfarer\" FT"},
{abbreviation = "вейбу", replacement = "мото марки \"Wayfarer\" FT"},
{abbreviation = "санч", replacement = "мото марки \"Sanchez\" FT"},
{abbreviation = "санчез", replacement = "мото марки \"Sanchez\" FT"},
{abbreviation = "санча", replacement = "мото марки \"Sanchez\" FT"},
{abbreviation = "санчу", replacement = "мото марки \"Sanchez\" FT"},
{abbreviation = "пжж", replacement = "мото марки \"PCJ-600\" FT"},
{abbreviation = "пжжа", replacement = "мото марки \"PCJ-600\" FT"},
{abbreviation = "пжжу", replacement = "мото марки \"PCJ-600\" FT"},
{abbreviation = "фцз", replacement = "мото марки \"FCR-900\" FT"},
{abbreviation = "фцза", replacement = "мото марки \"FCR-900\" FT"},
{abbreviation = "фцзу", replacement = "мото марки \"FCR-900\" FT"},
{abbreviation = "фаггио", replacement = "мото марки \"Faggio\" FT"},
{abbreviation = "фагио", replacement = "мото марки \"Faggio\" FT"},
{abbreviation = "фаггиу", replacement = "мото марки \"Faggio\" FT"},
{abbreviation = "бф", replacement = "мото марки \"BF-400\" FT"},
{abbreviation = "бфа", replacement = "мото марки \"BF-400\" FT"},
{abbreviation = "эндюро", replacement = "мото марки \"Enduro\" FT"},
{abbreviation = "эндюра", replacement = "мото марки \"Enduro\" FT"},
{abbreviation = "ангел", replacement = "мото марки \"Angel\" FT"},
{abbreviation = "ангела", replacement = "мото марки \"Angel\" FT"},
-- Велосипеды
{abbreviation = "бмх", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "бмха", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "бмху", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "байк", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "байка", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "байку", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "велик", replacement = "велосипед"},
{abbreviation = "велика", replacement = "велосипед"},
{abbreviation = "велику", replacement = "велосипед"},
{abbreviation = "велосипед", replacement = "велосипед"},
{abbreviation = "велосипеда", replacement = "велосипед"},
-- Города
{abbreviation = "лс", replacement = "Los Santos"},
{abbreviation = "лос сантос", replacement = "Los Santos"},
{abbreviation = "сф", replacement = "San Fierro"},
{abbreviation = "санфиеро", replacement = "San Fierro"},
{abbreviation = "сан фиерро", replacement = "San Fierro"},
{abbreviation = "лв", replacement = "Las Venturas"},
{abbreviation = "las venturas", replacement = "Las Venturas"},
{abbreviation = "lv", replacement = "Las Venturas"},
{abbreviation = "штат", replacement = "штат"},
{abbreviation = "штата", replacement = "штат"},
-- Районы
{abbreviation = "гетто", replacement = "East Los Santos"},
{abbreviation = "геттоа", replacement = "East Los Santos"},
{abbreviation = "ждлс", replacement = "East Los Santos"},
{abbreviation = "жёлс", replacement = "East Los Santos"},
{abbreviation = "гантон", replacement = "Ganton"},
{abbreviation = "гантона", replacement = "Ganton"},
{abbreviation = "гантону", replacement = "Ganton"},
{abbreviation = "идл", replacement = "Idlewood"},
{abbreviation = "идлвуд", replacement = "Idlewood"},
{abbreviation = "джеф", replacement = "Jefferson"},
{abbreviation = "джеферсон", replacement = "Jefferson"},
{abbreviation = "глен", replacement = "Glen Park"},
{abbreviation = "глена", replacement = "Glen Park"},
{abbreviation = "верон", replacement = "Verona Beach"},
{abbreviation = "верона", replacement = "Verona Beach"},
{abbreviation = "верону", replacement = "Verona Beach"},
{abbreviation = "вилл", replacement = "Willowfield"},
{abbreviation = "виллоу", replacement = "Willowfield"},
{abbreviation = "элкорона", replacement = "El Corona"},
{abbreviation = "элтех", replacement = "El Corona"},
{abbreviation = "элтек", replacement = "El Corona"},
{abbreviation = "комфтон", replacement = "Commerce"},
{abbreviation = "коммерс", replacement = "Commerce"},
{abbreviation = "маркет", replacement = "Market"},
{abbreviation = "маркета", replacement = "Market"},
{abbreviation = "шром", replacement = "Chinatown"},
{abbreviation = "пальмино", replacement = "Palomino Creek"},
{abbreviation = "палминас", replacement = "Palomino Creek"},
{abbreviation = "монтгомери", replacement = "Montgomery"},
{abbreviation = "монтгомеря", replacement = "Montgomery"},
{abbreviation = "диллимор", replacement = "Dillimore"},
{abbreviation = "диллимора", replacement = "Dillimore"},
{abbreviation = "блюбери", replacement = "Blueberry"},
{abbreviation = "бляберри", replacement = "Blueberry"},
{abbreviation = "чайнатаун", replacement = "Chinatown SF"},
{abbreviation = "дохерти", replacement = "Doherty"},
{abbreviation = "кингс", replacement = "Kings"},
{abbreviation = "кингса", replacement = "Kings"},
{abbreviation = "парадизо", replacement = "Paradiso"},
{abbreviation = "стрип", replacement = "The Strip"},
{abbreviation = "стрипа", replacement = "The Strip"},
{abbreviation = "рокшор", replacement = "Rockshore"},
{abbreviation = "рокшора", replacement = "Rockshore"},
{abbreviation = "пилон", replacement = "Pilgrim"},
{abbreviation = "пилона", replacement = "Pilgrim"},
{abbreviation = "авалон", replacement = "Avalon"},
{abbreviation = "авалона", replacement = "Avalon"},
{abbreviation = "драгон", replacement = "Dragons Dojo"},
{abbreviation = "драгона", replacement = "Dragons Dojo"},
-- Районы (деревни/посёлки/округа)
{abbreviation = "флинт", replacement = "Flint County"},
{abbreviation = "флинта", replacement = "Flint County"},
{abbreviation = "флинт кантри", replacement = "Flint County"},
{abbreviation = "флинт кантриа", replacement = "Flint County"},
{abbreviation = "пк", replacement = "Palomino Creek"},
{abbreviation = "палмино", replacement = "Palomino Creek"},
{abbreviation = "палминас", replacement = "Palomino Creek"},
{abbreviation = "паломино", replacement = "Palomino Creek"},
{abbreviation = "паломино крик", replacement = "Palomino Creek"},
{abbreviation = "монтгомери", replacement = "Montgomery"},
{abbreviation = "монтгомеря", replacement = "Montgomery"},
{abbreviation = "диллимор", replacement = "Dillimore"},
{abbreviation = "диллимора", replacement = "Dillimore"},
{abbreviation = "блюбери", replacement = "Blueberry"},
{abbreviation = "бляберри", replacement = "Blueberry"},
{abbreviation = "блюберри", replacement = "Blueberry"},
{abbreviation = "ель куебрадос", replacement = "El Quebrados"},
{abbreviation = "ель куебрадос", replacement = "El Quebrados"},
{abbreviation = "куебрадос", replacement = "El Quebrados"},
{abbreviation = "форт карсон", replacement = "Fort Carson"},
{abbreviation = "форт карсона", replacement = "Fort Carson"},
{abbreviation = "форт", replacement = "Fort Carson"},
{abbreviation = "карсон", replacement = "Fort Carson"},
{abbreviation = "тиера робада", replacement = "Tierra Robada"},
{abbreviation = "тиера", replacement = "Tierra Robada"},
{abbreviation = "робада", replacement = "Tierra Robada"},
{abbreviation = "ангел пайн", replacement = "Angel Pine"},
{abbreviation = "ангел пайн", replacement = "Angel Pine"},
{abbreviation = "ангел", replacement = "Angel Pine"},
{abbreviation = "норт рок", replacement = "North Rock"},
{abbreviation = "норт", replacement = "North Rock"},
{abbreviation = "эшберри", replacement = "Ashberry"},
{abbreviation = "эшберри", replacement = "Ashberry"},
{abbreviation = "хилтоп", replacement = "Hilltop"},
{abbreviation = "хилтопа", replacement = "Hilltop"},
{abbreviation = "валле", replacement = "Valle Ocultado"},
{abbreviation = "валле оклудадо", replacement = "Valle Ocultado"},
{abbreviation = "оклудадо", replacement = "Valle Ocultado"},
{abbreviation = "арко дель оесте", replacement = "Arco del Oeste"},
{abbreviation = "арко", replacement = "Arco del Oeste"},
{abbreviation = "бейсайд", replacement = "Bayside"},
{abbreviation = "бейсайд", replacement = "Bayside"},
{abbreviation = "бэйсайд", replacement = "Bayside"},
{abbreviation = "эл кебрадос", replacement = "El Quebrados"},
{abbreviation = "эль кебрадос", replacement = "El Quebrados"},
{abbreviation = "грин палмс", replacement = "Green Palms"},
{abbreviation = "грин", replacement = "Green Palms"},
{abbreviation = "палмс", replacement = "Green Palms"},
{abbreviation = "юнион станция", replacement = "Union Station"},
{abbreviation = "юнион", replacement = "Union Station"},
{abbreviation = "крик", replacement = "Palomino Creek"},
{abbreviation = "кантри", replacement = "Flint County"},
{abbreviation = "вайтвуд", replacement = "Whitewood"},
{abbreviation = "вайтвуд бич", replacement = "Whitewood Beach"},
{abbreviation = "вайтвуда", replacement = "Whitewood"},
{abbreviation = "прайм", replacement = "Prickle Pine"},
{abbreviation = "прикл пайн", replacement = "Prickle Pine"},
{abbreviation = "прикл", replacement = "Prickle Pine"},
{abbreviation = "рокшор", replacement = "Rockshore"},
{abbreviation = "рокшор вест", replacement = "Rockshore West"},
{abbreviation = "рокшора", replacement = "Rockshore"},
{abbreviation = "стрип", replacement = "The Strip"},
{abbreviation = "стрипа", replacement = "The Strip"},
{abbreviation = "олд вегас", replacement = "Old Venturas"},
{abbreviation = "олдвегас", replacement = "Old Venturas"},
{abbreviation = "нью вегас", replacement = "New Venturas"},
{abbreviation = "ньювегас", replacement = "New Venturas"},
{abbreviation = "каменный сад", replacement = "Rockshore"},
{abbreviation = "каменная", replacement = "Rockshore"},
{abbreviation = "пилбокс", replacement = "Pilbox"},
{abbreviation = "пилбокса", replacement = "Pilbox"},
{abbreviation = "ройал", replacement = "Royal Casino"},
{abbreviation = "ройала", replacement = "Royal Casino"},
{abbreviation = "калигула", replacement = "Caligulas Palace"},
{abbreviation = "калигулы", replacement = "Caligulas Palace"},
{abbreviation = "пират", replacement = "Pirates in Mens Pants"},
{abbreviation = "пирата", replacement = "Pirates in Mens Pants"},
{abbreviation = "визаж", replacement = "Visage"},
{abbreviation = "визажа", replacement = "Visage"},

-- Недвижимость
{abbreviation = "кв", replacement = "квартиру"},
{abbreviation = "квартира", replacement = "квартиру"},
{abbreviation = "квартиру", replacement = "квартиру"},
{abbreviation = "квартиры", replacement = "квартиру"},
{abbreviation = "особняк", replacement = "особняк"},
{abbreviation = "особняка", replacement = "особняк"},
{abbreviation = "особняку", replacement = "особняк"},
{abbreviation = "виллу", replacement = "виллу"},
{abbreviation = "вилла", replacement = "виллу"},
{abbreviation = "виллы", replacement = "виллу"},
{abbreviation = "биз", replacement = "бизнес"},
{abbreviation = "бизик", replacement = "бизнес"},
{abbreviation = "бизнес", replacement = "бизнес"},
{abbreviation = "бизнеса", replacement = "бизнес"},
{abbreviation = "бизнесу", replacement = "бизнес"},
{abbreviation = "завод", replacement = "производство"},
{abbreviation = "завода", replacement = "производство"},
{abbreviation = "заводу", replacement = "производство"},
{abbreviation = "фабрика", replacement = "производство"},
{abbreviation = "фабрику", replacement = "производство"},
{abbreviation = "фабрики", replacement = "производство"},
{abbreviation = "фактория", replacement = "производство"},
{abbreviation = "факторию", replacement = "производство"},
{abbreviation = "заправка", replacement = "АЗС"},
{abbreviation = "азс", replacement = "АЗС"},
{abbreviation = "заправку", replacement = "АЗС"},
{abbreviation = "бензоль", replacement = "АЗС"},
{abbreviation = "отель", replacement = "отель"},
{abbreviation = "мотель", replacement = "отель"},
{abbreviation = "отеля", replacement = "отель"},
{abbreviation = "мотеля", replacement = "отель"},
{abbreviation = "маг", replacement = "магазин"},
{abbreviation = "магазин", replacement = "магазин"},
{abbreviation = "магазина", replacement = "магазин"},
{abbreviation = "хатка", replacement = "магазин"},
{abbreviation = "хатку", replacement = "магазин"},
{abbreviation = "хатки", replacement = "магазин"},
{abbreviation = "барах", replacement = "барах"},
{abbreviation = "бараху", replacement = "барах"},
{abbreviation = "барахи", replacement = "барах"},
{abbreviation = "барахе", replacement = "барах"},
{abbreviation = "клуб", replacement = "клуб"},
{abbreviation = "клуба", replacement = "клуб"},
{abbreviation = "клубу", replacement = "клуб"},
{abbreviation = "казино", replacement = "казино"},
{abbreviation = "казик", replacement = "казино"},
{abbreviation = "казика", replacement = "казино"},
{abbreviation = "казику", replacement = "казино"},
{abbreviation = "качалка", replacement = "тренажёрный зал"},
{abbreviation = "качалку", replacement = "тренажёрный зал"},
{abbreviation = "качалки", replacement = "тренажёрный зал"},
{abbreviation = "качалке", replacement = "тренажёрный зал"},
{abbreviation = "спортзал", replacement = "тренажёрный зал"},
{abbreviation = "спортзала", replacement = "тренажёрный зал"},
{abbreviation = "зал", replacement = "тренажёрный зал"},
{abbreviation = "закусочная", replacement = "закусочную"},
{abbreviation = "закусочную", replacement = "закусочную"},
{abbreviation = "столовая", replacement = "столовую"},
{abbreviation = "столовую", replacement = "столовую"},
{abbreviation = "бар", replacement = "бар"},
{abbreviation = "бара", replacement = "бар"},
{abbreviation = "бару", replacement = "бар"},
{abbreviation = "ресторан", replacement = "ресторан"},
{abbreviation = "ресторана", replacement = "ресторан"},
{abbreviation = "кафе", replacement = "кафе"},
{abbreviation = "аптека", replacement = "аптеку"},
{abbreviation = "аптеку", replacement = "аптеку"},
{abbreviation = "аптеки", replacement = "аптеку"},
{abbreviation = "склад", replacement = "склад"},
{abbreviation = "склада", replacement = "склад"},
{abbreviation = "складу", replacement = "склад"},
{abbreviation = "ангар", replacement = "ангар"},
{abbreviation = "ангара", replacement = "ангар"},
{abbreviation = "причал", replacement = "причал"},
{abbreviation = "причала", replacement = "причал"},
{abbreviation = "ферма", replacement = "ферму"},
{abbreviation = "ферму", replacement = "ферму"},
{abbreviation = "фермы", replacement = "ферму"},
{abbreviation = "шахта", replacement = "шахту"},
{abbreviation = "шахту", replacement = "шахту"},
{abbreviation = "шахты", replacement = "шахту"},
{abbreviation = "лесопилка", replacement = "лесопилку"},
{abbreviation = "лесопилку", replacement = "лесопилку"},
{abbreviation = "порт", replacement = "порт"},
{abbreviation = "порта", replacement = "порт"},
{abbreviation = "порту", replacement = "порт"},
{abbreviation = "верфь", replacement = "верфь"},
{abbreviation = "верфи", replacement = "верфь"},
{abbreviation = "хранилище", replacement = "хранилище"},
{abbreviation = "хранилища", replacement = "хранилище"},
{abbreviation = "электростанция", replacement = "электростанцию"},
{abbreviation = "электростанцию", replacement = "электростанцию"},
{abbreviation = "мэрия", replacement = "мэрию"},
{abbreviation = "мэрию", replacement = "мэрию"},
{abbreviation = "мэрии", replacement = "мэрию"},
{abbreviation = "мэрие", replacement = "мэрию"},
{abbreviation = "мерия", replacement = "мэрию"},
{abbreviation = "мерию", replacement = "мэрию"},
{abbreviation = "полиция", replacement = "полицию"},
{abbreviation = "полицию", replacement = "полицию"},
{abbreviation = "полиции", replacement = "полицию"},
{abbreviation = "больница", replacement = "больницу"},
{abbreviation = "больницу", replacement = "больницу"},
{abbreviation = "больницы", replacement = "больницу"},
{abbreviation = "школа", replacement = "школу"},
{abbreviation = "школу", replacement = "школу"},
{abbreviation = "школы", replacement = "школу"},
{abbreviation = "церковь", replacement = "церковь"},
{abbreviation = "церкви", replacement = "церковь"},
{abbreviation = "банк", replacement = "банк"},
{abbreviation = "банка", replacement = "банк"},
{abbreviation = "банку", replacement = "банк"},
{abbreviation = "стадион", replacement = "стадион"},
{abbreviation = "стадиона", replacement = "стадион"},
{abbreviation = "стадиону", replacement = "стадион"},
-- Предметы
{abbreviation = "сим", replacement = "SIM-card"},
{abbreviation = "симка", replacement = "SIM-card"},
{abbreviation = "симку", replacement = "SIM-card"},
{abbreviation = "симки", replacement = "SIM-card"},
{abbreviation = "тел", replacement = "телефон"},
{abbreviation = "телефон", replacement = "телефон"},
{abbreviation = "телефона", replacement = "телефон"},
{abbreviation = "номер", replacement = "тел. номер"},
{abbreviation = "номера", replacement = "тел. номер"},
{abbreviation = "одежду", replacement = "одежду"},
{abbreviation = "одежда", replacement = "одежду"},
{abbreviation = "одежды", replacement = "одежду"},
{abbreviation = "одежду", replacement = "одежду"},
{abbreviation = "скин", replacement = "одежду"},
{abbreviation = "скина", replacement = "одежду"},
{abbreviation = "скину", replacement = "одежду"},
{abbreviation = "аксессуар", replacement = "аксессуар"},
{abbreviation = "аксесуар", replacement = "аксессуар"},
{abbreviation = "аксессуара", replacement = "аксессуар"},
{abbreviation = "меч", replacement = "аксессуар \"Меч\""},
{abbreviation = "меча", replacement = "аксессуар \"Меч\""},
{abbreviation = "рюкзак", replacement = "аксессуар \"Рюкзак\""},
{abbreviation = "рюкзака", replacement = "аксессуар \"Рюкзак\""},
{abbreviation = "часы", replacement = "аксессуар \"Часы\""},
{abbreviation = "очки", replacement = "аксессуар \"Очки\""},
{abbreviation = "шляпу", replacement = "аксессуар \"Шляпа\""},
{abbreviation = "шляпа", replacement = "аксессуар \"Шляпа\""},
{abbreviation = "маску", replacement = "аксессуар \"Маска\""},
{abbreviation = "маска", replacement = "аксессуар \"Маска\""},
{abbreviation = "парашют", replacement = "аксессуар \"Парашют\""},
{abbreviation = "парашюты", replacement = "аксессуар \"Парашют\""},
{abbreviation = "бинты", replacement = "аптечку"},
{abbreviation = "бинтов", replacement = "аптечку"},
{abbreviation = "аптечка", replacement = "аптечку"},
{abbreviation = "аптечку", replacement = "аптечку"},
{abbreviation = "аптеки", replacement = "аптечку"},
{abbreviation = "еда", replacement = "еду"},
{abbreviation = "еду", replacement = "еду"},
{abbreviation = "еды", replacement = "еду"},
{abbreviation = "вода", replacement = "воду"},
{abbreviation = "воду", replacement = "воду"},
{abbreviation = "воды", replacement = "воду"},
{abbreviation = "бронежилет", replacement = "бронежилет"},
{abbreviation = "бронежилета", replacement = "бронежилет"},
{abbreviation = "бинокль", replacement = "бинокль"},
{abbreviation = "бинокля", replacement = "бинокль"},
{abbreviation = "фонарик", replacement = "фонарик"},
{abbreviation = "фонарика", replacement = "фонарик"},
{abbreviation = "радио", replacement = "радио"},
{abbreviation = "радиоа", replacement = "радио"},
{abbreviation = "гитара", replacement = "гитару"},
{abbreviation = "гитару", replacement = "гитару"},
{abbreviation = "гитары", replacement = "гитару"},
{abbreviation = "мяч", replacement = "мяч"},
{abbreviation = "мяча", replacement = "мяч"},
{abbreviation = "удочка", replacement = "удочку"},
{abbreviation = "удочку", replacement = "удочку"},
{abbreviation = "удочки", replacement = "удочку"},
-- Оружие
{abbreviation = "дигл", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "дигла", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "диглу", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "шотган", replacement = "оружие \"Shotgun\""},
{abbreviation = "шотгана", replacement = "оружие \"Shotgun\""},
{abbreviation = "дробовик", replacement = "оружие \"Shotgun\""},
{abbreviation = "м4", replacement = "оружие \"M4\""},
{abbreviation = "м4а1", replacement = "оружие \"M4\""},
{abbreviation = "ак", replacement = "оружие \"AK-47\""},
{abbreviation = "ака", replacement = "оружие \"AK-47\""},
{abbreviation = "смг", replacement = "оружие \"SMG\""},
{abbreviation = "смга", replacement = "оружие \"SMG\""},
{abbreviation = "узи", replacement = "оружие \"Uzi\""},
{abbreviation = "узиа", replacement = "оружие \"Uzi\""},
{abbreviation = "тэк", replacement = "оружие \"TEC-9\""},
{abbreviation = "тека", replacement = "оружие \"TEC-9\""},
{abbreviation = "снайпа", replacement = "оружие \"Sniper Rifle\""},
{abbreviation = "снайпу", replacement = "оружие \"Sniper Rifle\""},
{abbreviation = "снайперка", replacement = "оружие \"Sniper Rifle\""},
{abbreviation = "снайперку", replacement = "оружие \"Sniper Rifle\""},
{abbreviation = "нож", replacement = "оружие \"Knife\""},
{abbreviation = "ножа", replacement = "оружие \"Knife\""},
{abbreviation = "биту", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "бита", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "катана", replacement = "аксессуар \"Katana\""},
{abbreviation = "катану", replacement = "аксессуар \"Katana\""},
{abbreviation = "гранату", replacement = "оружие \"Grenade\""},
{abbreviation = "граната", replacement = "оружие \"Grenade\""},
{abbreviation = "тазер", replacement = "оружие \"Taser\""},
{abbreviation = "тазера", replacement = "оружие \"Taser\""},
{abbreviation = "пистолет", replacement = "оружие \"Pistol\""},
{abbreviation = "пистолета", replacement = "оружие \"Pistol\""},
{abbreviation = "револьвер", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "револьвера", replacement = "оружие \"Desert Eagle\""},
-- Деньги
{abbreviation = "кк", replacement = ".000.000$"},
{abbreviation = "млн", replacement = ".000.000$"},
{abbreviation = "ккк", replacement = ".000.000$"},
{abbreviation = "миллиард", replacement = ".000.000.000$"},
{abbreviation = "млрд", replacement = ".000.000.000$"},
{abbreviation = "миллиарда", replacement = ".000.000.000$"},
{abbreviation = "миллион", replacement = ".000.000$"},
{abbreviation = "миллиона", replacement = ".000.000$"},
-- Цена
{abbreviation = "дог", replacement = "Цена: договорная"},
{abbreviation = "договор", replacement = "Цена: договорная"},
{abbreviation = "торг", replacement = "Цена: договорная"},
{abbreviation = "обмен", replacement = "обмен"},
{abbreviation = "бартер", replacement = "обмен"},
{abbreviation = "дешево", replacement = "по низкой цене"},
{abbreviation = "дёшево", replacement = "по низкой цене"},
{abbreviation = "недорого", replacement = "по низкой цене"},
-- Услуги
{abbreviation = "услуг", replacement = "услуги"},
{abbreviation = "услуги", replacement = "услуги"},
{abbreviation = "перевозк", replacement = "перевозки"},
{abbreviation = "перевозки", replacement = "перевозки"},
{abbreviation = "доставка", replacement = "доставка"},
{abbreviation = "доставку", replacement = "доставка"},
{abbreviation = "такси", replacement = "такси"},
{abbreviation = "эвакуатор", replacement = "эвакуатор"},
{abbreviation = "эвакуатора", replacement = "эвакуатор"},
{abbreviation = "ремонт", replacement = "ремонт"},
{abbreviation = "ремонта", replacement = "ремонт"},
{abbreviation = "тюнинг", replacement = "тюнинг"},
{abbreviation = "тюнинга", replacement = "тюнинг"},
{abbreviation = "покраска", replacement = "покраска"},
{abbreviation = "покраску", replacement = "покраска"},
{abbreviation = "охрана", replacement = "охрана"},
{abbreviation = "охрану", replacement = "охрана"},
-- Семья
{abbreviation = "семья", replacement = "семья"},
{abbreviation = "семью", replacement = "семья"},
{abbreviation = "семьи", replacement = "семья"},
{abbreviation = "родственников", replacement = "родственников"},
{abbreviation = "родня", replacement = "родственников"},
{abbreviation = "родню", replacement = "родственников"},
-- Лицензии
{abbreviation = "права", replacement = "вод. права"},
{abbreviation = "прав", replacement = "вод. права"},
{abbreviation = "лицензия", replacement = "лицензия"},
{abbreviation = "лицензию", replacement = "лицензия"},
{abbreviation = "лицензии", replacement = "лицензия"},
{abbreviation = "лиц", replacement = "лицензия"},
{abbreviation = "медкарта", replacement = "мед. карта"},
{abbreviation = "медкарту", replacement = "мед. карта"},
-- Работа/Организации
{abbreviation = "сми", replacement = "СМИ"},
{abbreviation = "смиа", replacement = "СМИ"},
{abbreviation = "собеседование", replacement = "собеседование"},
{abbreviation = "собеседованиеа", replacement = "собеседование"},
{abbreviation = "мэрия", replacement = "мэрию"},
{abbreviation = "мэрию", replacement = "мэрию"},
{abbreviation = "мэрии", replacement = "мэрию"},
{abbreviation = "полиция", replacement = "полицию"},
{abbreviation = "полицию", replacement = "полицию"},
{abbreviation = "полиции", replacement = "полицию"},
{abbreviation = "фбр", replacement = "ФБР"},
{abbreviation = "фбра", replacement = "ФБР"},
{abbreviation = "мчс", replacement = "МЧС"},
{abbreviation = "мчса", replacement = "МЧС"},
{abbreviation = "армия", replacement = "армию"},
{abbreviation = "армию", replacement = "армию"},
{abbreviation = "армии", replacement = "армию"},
{abbreviation = "больница", replacement = "больницу"},
{abbreviation = "больницу", replacement = "больницу"},
{abbreviation = "больницы", replacement = "больницу"},
{abbreviation = "школа", replacement = "школу"},
{abbreviation = "школу", replacement = "школу"},
{abbreviation = "школы", replacement = "школу"},
{abbreviation = "инструктор", replacement = "инструктора"},
{abbreviation = "инструктора", replacement = "инструктора"},
{abbreviation = "работа", replacement = "работу"},
{abbreviation = "работу", replacement = "работу"},
{abbreviation = "работы", replacement = "работу"},
{abbreviation = "вакансия", replacement = "вакансию"},
{abbreviation = "вакансию", replacement = "вакансию"},
{abbreviation = "вакансии", replacement = "вакансию"},
{abbreviation = "набор", replacement = "набор"},
{abbreviation = "набора", replacement = "набор"},
{abbreviation = "собеседование", replacement = "собеседование"},
{abbreviation = "собеседования", replacement = "собеседование"},
-- Транспорт
{abbreviation = "поезд", replacement = "поезд"},
{abbreviation = "поезда", replacement = "поезд"},
{abbreviation = "поезду", replacement = "поезд"},
{abbreviation = "автобус", replacement = "автобус"},
{abbreviation = "автобуса", replacement = "автобус"},
{abbreviation = "автобусу", replacement = "автобус"},
{abbreviation = "трамвай", replacement = "трамвай"},
{abbreviation = "трамвая", replacement = "трамвай"},
{abbreviation = "трамваю", replacement = "трамвай"},
{abbreviation = "грузовик", replacement = "грузовик"},
{abbreviation = "грузовика", replacement = "грузовик"},
{abbreviation = "грузовику", replacement = "грузовик"},
{abbreviation = "фура", replacement = "грузовик"},
{abbreviation = "фуру", replacement = "грузовик"},
{abbreviation = "фуры", replacement = "грузовик"},
{abbreviation = "тягач", replacement = "тягач"},
{abbreviation = "тягача", replacement = "тягач"},
{abbreviation = "сэлбрайт", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "ковбой", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "чирок", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "банка", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "файрберд", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "октан", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "зр350", replacement = "а/м марки \"ZR-350\" FT"},
{abbreviation = "зр", replacement = "а/м марки \"ZR-350\" FT"},
{abbreviation = "инфернус", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "инфернуса", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "буллет", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "буллета", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "турисмо", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "ковер", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "элегант", replacement = "а/м марки \"Elegant\" FT"},
{abbreviation = "элеганта", replacement = "а/м марки \"Elegant\" FT"},
{abbreviation = "фортуне", replacement = "а/м марки \"Fortune\" FT"},
{abbreviation = "тампико", replacement = "а/м марки \"Tampa\" FT FT"},
{abbreviation = "глендейл", replacement = "а/м марки \"Glendale\" FT"},
{abbreviation = "глендейла", replacement = "а/м марки \"Glendale\" FT"},
{abbreviation = "эмперор", replacement = "а/м марки \"Emperor\" FT"},
{abbreviation = "эмперора", replacement = "а/м марки \"Emperor\" FT"},
{abbreviation = "невада", replacement = "а/м марки \"Nevada\" FT"},
{abbreviation = "неваду", replacement = "а/м марки \"Nevada\" FT"},
{abbreviation = "примо", replacement = "а/м марки \"Primo\" FT"},
{abbreviation = "маджестик", replacement = "а/м марки \"Majestic\" FT"},
{abbreviation = "маджестика", replacement = "а/м марки \"Majestic\" FT"},
{abbreviation = "винвуд", replacement = "а/м марки \"Willard\" FT"},
{abbreviation = "винвуда", replacement = "а/м марки \"Willard\" FT"},
{abbreviation = "вашингтон", replacement = "а/м марки \"Washington\" FT"},
{abbreviation = "вашингтона", replacement = "а/м марки \"Washington\" FT"},
{abbreviation = "адмирал", replacement = "а/м марки \"Admiral\" FT"},
{abbreviation = "адмирала", replacement = "а/м марки \"Admiral\" FT"},
{abbreviation = "ранчер", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "ранчера", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "ранчо", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "бобкэт", replacement = "а/м марки \"Bobcat\" FT"},
{abbreviation = "бобкэта", replacement = "а/м марки \"Bobcat\" FT"},
{abbreviation = "йосемити", replacement = "а/м марки \"Yosemite\" FT"},
{abbreviation = "валдшнеп", replacement = "а/м марки \"Walton\" FT"},
{abbreviation = "валдшнепа", replacement = "а/м марки \"Walton\" FT"},
{abbreviation = "торнадо", replacement = "а/м марки \"Tornado\" FT"},
{abbreviation = "торнадоа", replacement = "а/м марки \"Tornado\" FT"},
{abbreviation = "блейд", replacement = "а/м марки \"Blade\" FT"},
{abbreviation = "блейда", replacement = "а/м марки \"Blade\" FT"},
{abbreviation = "тампла", replacement = "а/м марки \"Tampa\" FT FT"},
{abbreviation = "тамплу", replacement = "а/м марки \"Tampa\" FT FT"},
{abbreviation = "альфа", replacement = "а/м марки \"Alpha\" FT"},
{abbreviation = "альфу", replacement = "а/м марки \"Alpha\" FT"},
{abbreviation = "комета", replacement = "а/м марки \"Comet\" FT"},
{abbreviation = "комету", replacement = "а/м марки \"Comet\" FT"},
{abbreviation = "стингер", replacement = "а/м марки \"Stinger\" FT"},
{abbreviation = "стингера", replacement = "а/м марки \"Stinger\" FT"},
{abbreviation = "супергт", replacement = "а/м марки \"Super GT\" FT"},
{abbreviation = "супергта", replacement = "а/м марки \"Super GT\" FT"},
{abbreviation = "чампион", replacement = "а/м марки \"Champion\" FT"},
{abbreviation = "чампиона", replacement = "а/м марки \"Champion\" FT"},
{abbreviation = "букер", replacement = "а/м марки \"Buccaneer\" FT"},
{abbreviation = "букера", replacement = "а/м марки \"Buccaneer\" FT"},
{abbreviation = "хёрмит", replacement = "а/м марки \"Hermes\" FT"},
{abbreviation = "хёрмита", replacement = "а/м марки \"Hermes\" FT"},
{abbreviation = "сентинел", replacement = "а/м марки \"Sentinel\" FT"},
{abbreviation = "сентинела", replacement = "а/м марки \"Sentinel\" FT"},
{abbreviation = "фортун", replacement = "а/м марки \"Fortune\" FT"},
{abbreviation = "фортуна", replacement = "а/м марки \"Fortune\" FT"},
{abbreviation = "фортуну", replacement = "а/м марки \"Fortune\" FT"},
{abbreviation = "блиста", replacement = "а/м марки \"Blista\" FT"},
{abbreviation = "блисту", replacement = "а/м марки \"Blista\" FT"},
{abbreviation = "манана", replacement = "а/м марки \"Manana\" FT"},
{abbreviation = "манану", replacement = "а/м марки \"Manana\" FT"},
{abbreviation = "пикап", replacement = "а/м марки \"Picador\" FT"},
{abbreviation = "пикапа", replacement = "а/м марки \"Picador\" FT"},
{abbreviation = "соляр", replacement = "а/м марки \"Solair\" FT"},
{abbreviation = "соляра", replacement = "а/м марки \"Solair\" FT"},
{abbreviation = "винсаг", replacement = "а/м марки \"Windsor\" FT"},
{abbreviation = "винсага", replacement = "а/м марки \"Windsor\" FT"},
{abbreviation = "шафтер", replacement = "а/м марки \"Stafford\" FT"},
{abbreviation = "шафтера", replacement = "а/м марки \"Stafford\" FT"},
{abbreviation = "хантер", replacement = "а/м марки \"Huntley\" FT"},
{abbreviation = "хантера", replacement = "а/м марки \"Huntley\" FT"},
{abbreviation = "патриот", replacement = "а/м марки \"Patriot\" FT"},
{abbreviation = "патриота", replacement = "а/м марки \"Patriot\" FT"},
{abbreviation = "монстр", replacement = "а/м марки \"Monster\" FT"},
{abbreviation = "монстра", replacement = "а/м марки \"Monster\" FT"},
{abbreviation = "бандито", replacement = "а/м марки \"Bandito\" FT"},
{abbreviation = "бандита", replacement = "а/м марки \"Bandito\" FT"},
{abbreviation = "кальцо", replacement = "а/м марки \"Calcium\" FT"},
{abbreviation = "кальция", replacement = "а/м марки \"Calcium\" FT"},
{abbreviation = "хотринг", replacement = "а/м марки \"Hotring\" FT"},
{abbreviation = "хотринга", replacement = "а/м марки \"Hotring\" FT"},
{abbreviation = "хотрингер", replacement = "а/м марки \"Hotring\" FT"},
{abbreviation = "багги", replacement = "а/м марки \"Bandito\" FT"},
{abbreviation = "крэйг", replacement = "а/м марки \"Crane\" FT"},
{abbreviation = "стретч", replacement = "а/м марки \"Stretch\" FT"},
{abbreviation = "стретча", replacement = "а/м марки \"Stretch\" FT"},
{abbreviation = "премьер", replacement = "а/м марки \"Premier\" FT"},
{abbreviation = "премьера", replacement = "а/м марки \"Premier\" FT"},
{abbreviation = "бравура", replacement = "а/м марки \"Bravura\" FT"},
{abbreviation = "бравуру", replacement = "а/м марки \"Bravura\" FT"},
{abbreviation = "сламван", replacement = "а/м марки \"Slamvan\" FT"},
{abbreviation = "сламвана", replacement = "а/м марки \"Slamvan\" FT"},
{abbreviation = "ремингтон", replacement = "а/м марки \"Remington\" FT"},
{abbreviation = "ремингтона", replacement = "а/м марки \"Remington\" FT"},
{abbreviation = "флеш", replacement = "а/м марки \"Flash\" FT"},
{abbreviation = "флеша", replacement = "а/м марки \"Flash\" FT"},
{abbreviation = "джестер", replacement = "а/м марки \"Jester\" FT"},
{abbreviation = "джестера", replacement = "а/м марки \"Jester\" FT"},
{abbreviation = "стратум", replacement = "а/м марки \"Stratum\" FT"},
{abbreviation = "стратума", replacement = "а/м марки \"Stratum\" FT"},
{abbreviation = "уран", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "урана", replacement = "а/м марки \"Uranus\" FT"},
{abbreviation = "салат", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "салата", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "стрикер", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "адреналин", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "адреналина", replacement = "а/м марки \"Sultan RS\" FT"},
{abbreviation = "хоткнайф", replacement = "а/м марки \"Hotknife\" FT"},
{abbreviation = "хоткнайфа", replacement = "а/м марки \"Hotknife\" FT"},
{abbreviation = "дюна", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "дюну", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "дюны", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "сабре", replacement = "а/м марки \"Sabre\" FT"},
{abbreviation = "сабра", replacement = "а/м марки \"Sabre\" FT"},
{abbreviation = "сабру", replacement = "а/м марки \"Sabre\" FT"},
{abbreviation = "вуду", replacement = "а/м марки \"Voodoo\" FT"},
{abbreviation = "кловер", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "кловера", replacement = "а/м марки \"Clover\" FT"},
{abbreviation = "булка", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "булку", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "булки", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "инф", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "инфу", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "туризмо", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "турик", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "банши", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "баншу", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "чито", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "читу", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "феникс", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "феникса", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "тахома", replacement = "а/м марки \"Tahoma\" FT"},
{abbreviation = "тахому", replacement = "а/м марки \"Tahoma\" FT"},
{abbreviation = "султан", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "султана", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "султану", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "сультан", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "елегию", replacement = "а/м марки \"Elegy\" FT"},
{abbreviation = "еледжи", replacement = "а/м марки \"Elegy\" FT"},
{abbreviation = "елеги", replacement = "а/м марки \"Elegy\" FT"},
{abbreviation = "елегия", replacement = "а/м марки \"Elegy\" FT"},
{abbreviation = "нрг", replacement = "мото марки \"NRG-500\" FT"},
{abbreviation = "нргу", replacement = "мото марки \"NRG-500\" FT"},
{abbreviation = "нрга", replacement = "мото марки \"NRG-500\" FT"},
{abbreviation = "нрге", replacement = "мото марки \"NRG-500\" FT"},
{abbreviation = "фрей", replacement = "мото марки \"Freeway\" FT"},
{abbreviation = "фрея", replacement = "мото марки \"Freeway\" FT"},
{abbreviation = "фрею", replacement = "мото марки \"Freeway\" FT"},
{abbreviation = "вейб", replacement = "мото марки \"Wayfarer\" FT"},
{abbreviation = "вейба", replacement = "мото марки \"Wayfarer\" FT"},
{abbreviation = "санч", replacement = "мото марки \"Sanchez\" FT"},
{abbreviation = "санчез", replacement = "мото марки \"Sanchez\" FT"},
{abbreviation = "санча", replacement = "мото марки \"Sanchez\" FT"},
{abbreviation = "санчу", replacement = "мото марки \"Sanchez\" FT"},
{abbreviation = "пжж", replacement = "мото марки \"PCJ-600\" FT"},
{abbreviation = "пжжа", replacement = "мото марки \"PCJ-600\" FT"},
{abbreviation = "фцз", replacement = "мото марки \"FCR-900\" FT"},
{abbreviation = "фцза", replacement = "мото марки \"FCR-900\" FT"},
{abbreviation = "фаггио", replacement = "мото марки \"Faggio\" FT"},
{abbreviation = "фагио", replacement = "мото марки \"Faggio\" FT"},
{abbreviation = "бф", replacement = "мото марки \"BF-400\" FT"},
{abbreviation = "эндюро", replacement = "мото марки \"Enduro\" FT"},
{abbreviation = "ангел", replacement = "мото марки \"Angel\" FT"},
{abbreviation = "флинт", replacement = "Flint County"},
{abbreviation = "флинта", replacement = "Flint County"},
{abbreviation = "флинт кантри", replacement = "Flint County"},
{abbreviation = "пк", replacement = "Palomino Creek"},
{abbreviation = "паломино", replacement = "Palomino Creek"},
{abbreviation = "паломино крик", replacement = "Palomino Creek"},
{abbreviation = "куебрадос", replacement = "El Quebrados"},
{abbreviation = "ель куебрадос", replacement = "El Quebrados"},
{abbreviation = "эль кебрадос", replacement = "El Quebrados"},
{abbreviation = "форт карсон", replacement = "Fort Carson"},
{abbreviation = "форт", replacement = "Fort Carson"},
{abbreviation = "карсон", replacement = "Fort Carson"},
{abbreviation = "тиера робада", replacement = "Tierra Robada"},
{abbreviation = "тиера", replacement = "Tierra Robada"},
{abbreviation = "робада", replacement = "Tierra Robada"},
{abbreviation = "ангел пайн", replacement = "Angel Pine"},
{abbreviation = "ангел", replacement = "Angel Pine"},
{abbreviation = "бейсайд", replacement = "Bayside"},
{abbreviation = "бэйсайд", replacement = "Bayside"},
{abbreviation = "норт рок", replacement = "North Rock"},
{abbreviation = "норт", replacement = "North Rock"},
{abbreviation = "валле", replacement = "Valle Ocultado"},
{abbreviation = "оклудадо", replacement = "Valle Ocultado"},
{abbreviation = "арко", replacement = "Arco del Oeste"},
{abbreviation = "грин палмс", replacement = "Green Palms"},
{abbreviation = "грин", replacement = "Green Palms"},
{abbreviation = "палмс", replacement = "Green Palms"},
{abbreviation = "юнион", replacement = "Union Station"},
{abbreviation = "крик", replacement = "Palomino Creek"},
{abbreviation = "кантри", replacement = "Flint County"},
{abbreviation = "вайтвуд", replacement = "Whitewood"},
{abbreviation = "прайм", replacement = "Prickle Pine"},
{abbreviation = "прикл", replacement = "Prickle Pine"},
{abbreviation = "пилбокс", replacement = "Pilbox"},
{abbreviation = "ройал", replacement = "Royal Casino"},
{abbreviation = "калигула", replacement = "Caligulas Palace"},
{abbreviation = "пират", replacement = "Pirates in Mens Pants"},
{abbreviation = "визаж", replacement = "Visage"},
{abbreviation = "олд вегас", replacement = "Old Venturas"},
{abbreviation = "олдвегас", replacement = "Old Venturas"},
{abbreviation = "нью вегас", replacement = "New Venturas"},
{abbreviation = "ньювегас", replacement = "New Venturas"},
{abbreviation = "гетто", replacement = "East Los Santos"},
{abbreviation = "ждлс", replacement = "East Los Santos"},
{abbreviation = "жёлс", replacement = "East Los Santos"},
{abbreviation = "гантон", replacement = "Ganton"},
{abbreviation = "гантона", replacement = "Ganton"},
{abbreviation = "идл", replacement = "Idlewood"},
{abbreviation = "идлвуд", replacement = "Idlewood"},
{abbreviation = "джеф", replacement = "Jefferson"},
{abbreviation = "джеферсон", replacement = "Jefferson"},
{abbreviation = "глен", replacement = "Glen Park"},
{abbreviation = "верон", replacement = "Verona Beach"},
{abbreviation = "верона", replacement = "Verona Beach"},
{abbreviation = "вилл", replacement = "Willowfield"},
{abbreviation = "виллоу", replacement = "Willowfield"},
{abbreviation = "элкорона", replacement = "El Corona"},
{abbreviation = "элтех", replacement = "El Corona"},
{abbreviation = "элтек", replacement = "El Corona"},
{abbreviation = "комфтон", replacement = "Commerce"},
{abbreviation = "коммерс", replacement = "Commerce"},
{abbreviation = "маркет", replacement = "Market"},
{abbreviation = "шром", replacement = "Chinatown"},
{abbreviation = "монтгомери", replacement = "Montgomery"},
{abbreviation = "диллимор", replacement = "Dillimore"},
{abbreviation = "блюбери", replacement = "Blueberry"},
{abbreviation = "бляберри", replacement = "Blueberry"},
{abbreviation = "чайнатаун", replacement = "Chinatown SF"},
{abbreviation = "дохерти", replacement = "Doherty"},
{abbreviation = "кингс", replacement = "Kings"},
{abbreviation = "парадизо", replacement = "Paradiso"},
{abbreviation = "стрип", replacement = "The Strip"},
{abbreviation = "рокшор", replacement = "Rockshore"},
{abbreviation = "пилон", replacement = "Pilgrim"},
{abbreviation = "авалон", replacement = "Avalon"},
{abbreviation = "драгон", replacement = "Dragons Dojo"},
{abbreviation = "кв", replacement = "квартиру"},
{abbreviation = "квартира", replacement = "квартиру"},
{abbreviation = "квартиру", replacement = "квартиру"},
{abbreviation = "квартиры", replacement = "квартиру"},
{abbreviation = "особняк", replacement = "особняк"},
{abbreviation = "особняка", replacement = "особняк"},
{abbreviation = "виллу", replacement = "виллу"},
{abbreviation = "вилла", replacement = "виллу"},
{abbreviation = "биз", replacement = "бизнес"},
{abbreviation = "бизик", replacement = "бизнес"},
{abbreviation = "бизнес", replacement = "бизнес"},
{abbreviation = "бизнеса", replacement = "бизнес"},
{abbreviation = "завод", replacement = "производство"},
{abbreviation = "завода", replacement = "производство"},
{abbreviation = "фабрика", replacement = "производство"},
{abbreviation = "фабрику", replacement = "производство"},
{abbreviation = "фактория", replacement = "производство"},
{abbreviation = "факторию", replacement = "производство"},
{abbreviation = "заправка", replacement = "АЗС"},
{abbreviation = "азс", replacement = "АЗС"},
{abbreviation = "заправку", replacement = "АЗС"},
{abbreviation = "бензоль", replacement = "АЗС"},
{abbreviation = "отель", replacement = "отель"},
{abbreviation = "мотель", replacement = "отель"},
{abbreviation = "маг", replacement = "магазин"},
{abbreviation = "магазин", replacement = "магазин"},
{abbreviation = "магазина", replacement = "магазин"},
{abbreviation = "хатка", replacement = "магазин"},
{abbreviation = "хатку", replacement = "магазин"},
{abbreviation = "барах", replacement = "барах"},
{abbreviation = "бараху", replacement = "барах"},
{abbreviation = "барахи", replacement = "барах"},
{abbreviation = "клуб", replacement = "клуб"},
{abbreviation = "казино", replacement = "казино"},
{abbreviation = "казик", replacement = "казино"},
{abbreviation = "качалка", replacement = "тренажёрный зал"},
{abbreviation = "качалку", replacement = "тренажёрный зал"},
{abbreviation = "спортзал", replacement = "тренажёрный зал"},
{abbreviation = "закусочная", replacement = "закусочную"},
{abbreviation = "столовая", replacement = "столовую"},
{abbreviation = "бар", replacement = "бар"},
{abbreviation = "ресторан", replacement = "ресторан"},
{abbreviation = "кафе", replacement = "кафе"},
{abbreviation = "аптека", replacement = "аптеку"},
{abbreviation = "склад", replacement = "склад"},
{abbreviation = "ангар", replacement = "ангар"},
{abbreviation = "причал", replacement = "причал"},
{abbreviation = "ферма", replacement = "ферму"},
{abbreviation = "шахта", replacement = "шахту"},
{abbreviation = "лесопилка", replacement = "лесопилку"},
{abbreviation = "порт", replacement = "порт"},
{abbreviation = "верфь", replacement = "верфь"},
{abbreviation = "хранилище", replacement = "хранилище"},
{abbreviation = "электростанция", replacement = "электростанцию"},
{abbreviation = "мэрия", replacement = "мэрию"},
{abbreviation = "мерия", replacement = "мэрию"},
{abbreviation = "полиция", replacement = "полицию"},
{abbreviation = "больница", replacement = "больницу"},
{abbreviation = "школа", replacement = "школу"},
{abbreviation = "церковь", replacement = "церковь"},
{abbreviation = "банк", replacement = "банк"},
{abbreviation = "стадион", replacement = "стадион"},
{abbreviation = "сим", replacement = "SIM-card"},
{abbreviation = "симка", replacement = "SIM-card"},
{abbreviation = "симку", replacement = "SIM-card"},
{abbreviation = "тел", replacement = "телефон"},
{abbreviation = "номер", replacement = "тел. номер"},
{abbreviation = "одежду", replacement = "одежду"},
{abbreviation = "скин", replacement = "одежду"},
{abbreviation = "аксессуар", replacement = "аксессуар"},
{abbreviation = "аксесуар", replacement = "аксессуар"},
{abbreviation = "меч", replacement = "аксессуар \"Меч\""},
{abbreviation = "рюкзак", replacement = "аксессуар \"Рюкзак\""},
{abbreviation = "часы", replacement = "аксессуар \"Часы\""},
{abbreviation = "очки", replacement = "аксессуар \"Очки\""},
{abbreviation = "шляпу", replacement = "аксессуар \"Шляпа\""},
{abbreviation = "маску", replacement = "аксессуар \"Маска\""},
{abbreviation = "парашют", replacement = "аксессуар \"Парашют\""},
{abbreviation = "бинты", replacement = "аптечку"},
{abbreviation = "аптечка", replacement = "аптечку"},
{abbreviation = "еда", replacement = "еду"},
{abbreviation = "вода", replacement = "воду"},
{abbreviation = "бронежилет", replacement = "бронежилет"},
{abbreviation = "бинокль", replacement = "бинокль"},
{abbreviation = "фонарик", replacement = "фонарик"},
{abbreviation = "радио", replacement = "радио"},
{abbreviation = "гитара", replacement = "гитару"},
{abbreviation = "мяч", replacement = "мяч"},
{abbreviation = "удочка", replacement = "удочку"},
{abbreviation = "лодка", replacement = "лодку"},
{abbreviation = "яхта", replacement = "яхту"},
{abbreviation = "самолет", replacement = "самолёт"},
{abbreviation = "вертолет", replacement = "вертолёт"},
{abbreviation = "дигл", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "дигла", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "шотган", replacement = "оружие \"Shotgun\""},
{abbreviation = "дробовик", replacement = "оружие \"Shotgun\""},
{abbreviation = "м4", replacement = "оружие \"M4\""},
{abbreviation = "ак", replacement = "оружие \"AK-47\""},
{abbreviation = "смг", replacement = "оружие \"SMG\""},
{abbreviation = "узи", replacement = "оружие \"Uzi\""},
{abbreviation = "тэк", replacement = "оружие \"TEC-9\""},
{abbreviation = "снайпа", replacement = "оружие \"Sniper Rifle\""},
{abbreviation = "снайперку", replacement = "оружие \"Sniper Rifle\""},
{abbreviation = "нож", replacement = "оружие \"Knife\""},
{abbreviation = "биту", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "пистолет", replacement = "оружие \"Pistol\""},
{abbreviation = "револьвер", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "катана", replacement = "аксессуар \"Katana\""},
{abbreviation = "катану", replacement = "аксессуар \"Katana\""},
{abbreviation = "гранату", replacement = "оружие \"Grenade\""},
{abbreviation = "тазер", replacement = "оружие \"Taser\""},
{abbreviation = "кк", replacement = ".000.000$"},
{abbreviation = "млн", replacement = ".000.000$"},
{abbreviation = "ккк", replacement = ".000.000$"},
{abbreviation = "миллиард", replacement = ".000.000.000$"},
{abbreviation = "млрд", replacement = ".000.000.000$"},
{abbreviation = "дог", replacement = "Цена: договорная"},
{abbreviation = "договор", replacement = "Цена: договорная"},
{abbreviation = "торг", replacement = "Цена: договорная"},
{abbreviation = "обмен", replacement = "обмен"},
{abbreviation = "бартер", replacement = "обмен"},
{abbreviation = "сми", replacement = "СМИ"},
{abbreviation = "собеседование", replacement = "собеседование"},
{abbreviation = "вакансия", replacement = "вакансию"},
{abbreviation = "работа", replacement = "работу"},
{abbreviation = "фбр", replacement = "ФБР"},
{abbreviation = "мчс", replacement = "МЧС"},
{abbreviation = "армия", replacement = "армию"},
{abbreviation = "семья", replacement = "семья"},
{abbreviation = "родственников", replacement = "родственников"},
{abbreviation = "права", replacement = "вод. права"},
{abbreviation = "лицензия", replacement = "лицензия"},
{abbreviation = "лиц", replacement = "лицензия"},
{abbreviation = "поезд", replacement = "поезд"},
{abbreviation = "автобус", replacement = "автобус"},
{abbreviation = "трамвай", replacement = "трамвай"},
{abbreviation = "грузовик", replacement = "грузовик"},
{abbreviation = "фура", replacement = "грузовик"},
{abbreviation = "тягач", replacement = "тягач"},
{abbreviation = "бмх", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "велик", replacement = "велосипед"},
{abbreviation = "гринвуд", replacement = "а/м марки \"Greenwood\" FT"},
{abbreviation = "гринвуда", replacement = "а/м марки \"Greenwood\" FT"},
{abbreviation = "гринвуду", replacement = "а/м марки \"Greenwood\" FT"},
{abbreviation = "саванна", replacement = "а/м марки \"Savanna\" FT"},
{abbreviation = "саванну", replacement = "а/м марки \"Savanna\" FT"},
{abbreviation = "саванны", replacement = "а/м марки \"Savanna\" FT"},
{abbreviation = "тумми", replacement = "а/м марки \"Tahoma\" FT"},
{abbreviation = "чайтон", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "карт", replacement = "а/м марки \"Kart\""},
{abbreviation = "карта", replacement = "а/м марки \"Kart\""},
{abbreviation = "мрак", replacement = "а/м марки \"Bravura\" FT"},
{abbreviation = "мрака", replacement = "а/м марки \"Bravura\" FT"},
{abbreviation = "мраку", replacement = "а/м марки \"Bravura\" FT"},
{abbreviation = "санд king", replacement = "а/м марки \"Sandking\" FT"},
{abbreviation = "сандкинг", replacement = "а/м марки \"Sandking\" FT"},
{abbreviation = "сандкинга", replacement = "а/м марки \"Sandking\" FT"},
{abbreviation = "меска", replacement = "а/м марки \"Mesa\" FT"},
{abbreviation = "месу", replacement = "а/м марки \"Mesa\" FT"},
{abbreviation = "меса", replacement = "а/м марки \"Mesa\" FT"},
{abbreviation = "месы", replacement = "а/м марки \"Mesa\" FT"},
{abbreviation = "мунбим", replacement = "а/м марки \"Moonbeam\" FT"},
{abbreviation = "мунбима", replacement = "а/м марки \"Moonbeam\" FT"},
{abbreviation = "пони", replacement = "а/м марки \"Pony\" FT"},
{abbreviation = "пониа", replacement = "а/м марки \"Pony\" FT"},
{abbreviation = "регина", replacement = "а/м марки \"Regina\" FT"},
{abbreviation = "регину", replacement = "а/м марки \"Regina\" FT"},
{abbreviation = "регины", replacement = "а/м марки \"Regina\" FT"},
{abbreviation = "ромеро", replacement = "а/м марки \"Romero\" FT"},
{abbreviation = "ромероа", replacement = "а/м марки \"Romero\" FT"},
{abbreviation = "стокер", replacement = "а/м марки \"Stocker\""},
{abbreviation = "стокера", replacement = "а/м марки \"Stocker\""},
{abbreviation = "топфан", replacement = "а/м марки \"Topfun\""},
{abbreviation = "топфана", replacement = "а/м марки \"Topfun\""},
{abbreviation = "трактор", replacement = "а/м марки \"Tractor\""},
{abbreviation = "трактора", replacement = "а/м марки \"Tractor\""},
{abbreviation = "трактору", replacement = "а/м марки \"Tractor\""},
{abbreviation = "вудуп", replacement = "а/м марки \"Woodpecker\""},
{abbreviation = "вудупа", replacement = "а/м марки \"Woodpecker\""},
{abbreviation = "флэтбед", replacement = "а/м марки \"Flatbed\" FT"},
{abbreviation = "флэтбеда", replacement = "а/м марки \"Flatbed\" FT"},
{abbreviation = "лайнер", replacement = "а/м марки \"Linerunner\" FT"},
{abbreviation = "лайнера", replacement = "а/м марки \"Linerunner\" FT"},
{abbreviation = "лайнрунер", replacement = "а/м марки \"Linerunner\" FT"},
{abbreviation = "лайнрунера", replacement = "а/м марки \"Linerunner\" FT"},
{abbreviation = "роудтрейн", replacement = "а/м марки \"Roadtrain\" FT"},
{abbreviation = "роудтрейна", replacement = "а/м марки \"Roadtrain\" FT"},
{abbreviation = "танкер", replacement = "а/м марки \"Tanker\" FT"},
{abbreviation = "танкера", replacement = "а/м марки \"Tanker\" FT"},
{abbreviation = "дум", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "дума", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "думу", replacement = "а/м марки \"Dune\" FT"},
{abbreviation = "хантер2", replacement = "а/м марки \"Hunter\" FT"},
{abbreviation = "хантера2", replacement = "а/м марки \"Hunter\" FT"},
{abbreviation = "сиспарроу", replacement = "а/м марки \"Sparrow\" FT"},
{abbreviation = "сиспарроуа", replacement = "а/м марки \"Sparrow\" FT"},
{abbreviation = "спарроу", replacement = "а/м марки \"Sparrow\" FT"},
{abbreviation = "спарроуа", replacement = "а/м марки \"Sparrow\" FT"},
{abbreviation = "левиафан", replacement = "а/м марки \"Leviathan\" FT"},
{abbreviation = "левиафана", replacement = "а/м марки \"Leviathan\" FT"},
{abbreviation = "карго", replacement = "а/м марки \"Cargo\""},
{abbreviation = "каргоа", replacement = "а/м марки \"Cargo\""},
{abbreviation = "андровер", replacement = "а/м марки \"Andromada\" FT"},
{abbreviation = "андровера", replacement = "а/м марки \"Andromada\" FT"},
{abbreviation = "небула", replacement = "а/м марки \"Nebula\" FT"},
{abbreviation = "небулу", replacement = "а/м марки \"Nebula\" FT"},
{abbreviation = "небулы", replacement = "а/м марки \"Nebula\" FT"},
{abbreviation = "зомби2", replacement = "а/м марки \"Zombie\" FT"},
{abbreviation = "зомбиа", replacement = "а/м марки \"Zombie\" FT"},
{abbreviation = "файр", replacement = "а/м марки \"Firetruck\" FT"},
{abbreviation = "файра", replacement = "а/м марки \"Firetruck\" FT"},
{abbreviation = "пожарка", replacement = "а/м марки \"Firetruck\" FT"},
{abbreviation = "пожарку", replacement = "а/м марки \"Firetruck\" FT"},
{abbreviation = "пожарки", replacement = "а/м марки \"Firetruck\" FT"},
{abbreviation = "скорая", replacement = "а/м марки \"Ambulance\" FT"},
{abbreviation = "скорую", replacement = "а/м марки \"Ambulance\" FT"},
{abbreviation = "скорой", replacement = "а/м марки \"Ambulance\" FT"},
{abbreviation = "амбуланс", replacement = "а/м марки \"Ambulance\" FT"},
{abbreviation = "амбуланса", replacement = "а/м марки \"Ambulance\" FT"},
{abbreviation = "энфорсер", replacement = "а/м марки \"Enforcer\" FT"},
{abbreviation = "энфорсера", replacement = "а/м марки \"Enforcer\" FT"},
{abbreviation = "рио", replacement = "а/м марки \"Rio\" FT"},
{abbreviation = "риоа", replacement = "а/м марки \"Rio\" FT"},
{abbreviation = "астр", replacement = "а/м марки \"Astro\" FT"},
{abbreviation = "астра", replacement = "а/м марки \"Astro\" FT"},
{abbreviation = "астру", replacement = "а/м марки \"Astro\" FT"},
{abbreviation = "астры", replacement = "а/м марки \"Astro\" FT"},
{abbreviation = "вуду2", replacement = "а/м марки \"Voodoo\" FT"},
{abbreviation = "вуды2", replacement = "а/м марки \"Voodoo\" FT"},
{abbreviation = "карма", replacement = "а/м марки \"Karma\" FT"},
{abbreviation = "карму", replacement = "а/м марки \"Karma\" FT"},
{abbreviation = "кармы", replacement = "а/м марки \"Karma\" FT"},
{abbreviation = "клео", replacement = "а/м марки \"Cleo\" FT"},
{abbreviation = "клеоа", replacement = "а/м марки \"Cleo\" FT"},
{abbreviation = "фурион", replacement = "а/м марки \"Fury\" FT"},
{abbreviation = "фуриона", replacement = "а/м марки \"Fury\" FT"},
{abbreviation = "фуриону", replacement = "а/м марки \"Fury\" FT"},
{abbreviation = "хаку", replacement = "а/м марки \"Hakuchou\" FT"},
{abbreviation = "хакуа", replacement = "а/м марки \"Hakuchou\" FT"},
{abbreviation = "хакуча", replacement = "а/м марки \"Hakuchou\" FT"},
{abbreviation = "хакучи", replacement = "а/м марки \"Hakuchou\" FT"},
{abbreviation = "нэо", replacement = "а/м марки \"Neo\" FT"},
{abbreviation = "нэоа", replacement = "а/м марки \"Neo\" FT"},
{abbreviation = "фьюри", replacement = "а/м марки \"Fury\" FT"},
{abbreviation = "фьюриа", replacement = "а/м марки \"Fury\" FT"},
{abbreviation = "биффа", replacement = "а/м марки \"Biff\" FT"},
{abbreviation = "биффу", replacement = "а/м марки \"Biff\" FT"},
{abbreviation = "биффы", replacement = "а/м марки \"Biff\" FT"},
{abbreviation = "бифф", replacement = "а/м марки \"Biff\" FT"},
{abbreviation = "инкассатор", replacement = "а/м марки \"Securicar\" FT"},
{abbreviation = "инкассатора", replacement = "а/м марки \"Securicar\" FT"},
{abbreviation = "инкас", replacement = "а/м марки \"Securicar\" FT"},
{abbreviation = "инкаса", replacement = "а/м марки \"Securicar\" FT"},
{abbreviation = "секурикар", replacement = "а/м марки \"Securicar\" FT"},
{abbreviation = "мистер", replacement = "а/м марки \"Mr. Whoopee\" FT"},
{abbreviation = "вупи", replacement = "а/м марки \"Mr. Whoopee\" FT"},
{abbreviation = "вупиа", replacement = "а/м марки \"Mr. Whoopee\" FT"},
{abbreviation = "хотдог", replacement = "а/м марки \"Hotdog\" FT"},
{abbreviation = "хотдога", replacement = "а/м марки \"Hotdog\" FT"},
{abbreviation = "квартал", replacement = "Queens"},
{abbreviation = "квартала", replacement = "Queens"},
{abbreviation = "хашбери", replacement = "Hashbury"},
{abbreviation = "хашбериа", replacement = "Hashbury"},
{abbreviation = "гарсия", replacement = "Garcia"},
{abbreviation = "гарсии", replacement = "Garcia"},
{abbreviation = "санчео", replacement = "Sanchez SF"},
{abbreviation = "элфла", replacement = "El Fuego"},
{abbreviation = "элфуэго", replacement = "El Fuego"},
{abbreviation = "бэйсайд", replacement = "Bayside"},
{abbreviation = "бэйсайда", replacement = "Bayside"},
{abbreviation = "бэйсайду", replacement = "Bayside"},
{abbreviation = "крэйг", replacement = "Craig"},
{abbreviation = "крэйга", replacement = "Craig"},
{abbreviation = "честнат", replacement = "Chestnut"},
{abbreviation = "честната", replacement = "Chestnut"},
{abbreviation = "хайланд", replacement = "Highland"},
{abbreviation = "хайланда", replacement = "Highland"},
{abbreviation = "вэлли", replacement = "Valley"},
{abbreviation = "вэллиа", replacement = "Valley"},
{abbreviation = "хилсайд", replacement = "Hillside"},
{abbreviation = "хилсайда", replacement = "Hillside"},
{abbreviation = "санта", replacement = "Santa Flora"},
{abbreviation = "санта флора", replacement = "Santa Flora"},
{abbreviation = "сантафлора", replacement = "Santa Flora"},
{abbreviation = "эйнджел", replacement = "Angel Pine"},
{abbreviation = "эйнджела", replacement = "Angel Pine"},
{abbreviation = "куэбрадос", replacement = "El Quebrados"},
{abbreviation = "куэбрадоса", replacement = "El Quebrados"},
{abbreviation = "тиерра", replacement = "Tierra Robada"},
{abbreviation = "тиерраа", replacement = "Tierra Robada"},
{abbreviation = "тиерры", replacement = "Tierra Robada"},
{abbreviation = "флинт2", replacement = "Flint County"},
{abbreviation = "флинт2а", replacement = "Flint County"},
{abbreviation = "вайтвуд2", replacement = "Whitewood"},
{abbreviation = "вайтвуда", replacement = "Whitewood"},
{abbreviation = "рокшор2", replacement = "Rockshore"},
{abbreviation = "рокшора2", replacement = "Rockshore"},
{abbreviation = "рокшору", replacement = "Rockshore"},
{abbreviation = "рокшоры", replacement = "Rockshore"},
{abbreviation = "спринг", replacement = "Springfield"},
{abbreviation = "спринга", replacement = "Springfield"},
{abbreviation = "белл", replacement = "Bell"},
{abbreviation = "белла", replacement = "Bell"},
{abbreviation = "харбор", replacement = "Harbor"},
{abbreviation = "харбора", replacement = "Harbor"},
{abbreviation = "док", replacement = "Dock"},
{abbreviation = "дока", replacement = "Dock"},
{abbreviation = "доки", replacement = "Dock"},
{abbreviation = "порт2", replacement = "Port"},
{abbreviation = "порта2", replacement = "Port"},
{abbreviation = "бэй", replacement = "Bay"},
{abbreviation = "бэя", replacement = "Bay"},
{abbreviation = "бэйс", replacement = "Bays"},
{abbreviation = "бэйса", replacement = "Bays"},
{abbreviation = "кросс", replacement = "Cross"},
{abbreviation = "кросса", replacement = "Cross"},
{abbreviation = "хилл", replacement = "Hill"},
{abbreviation = "хилла", replacement = "Hill"},
{abbreviation = "парк", replacement = "Park"},
{abbreviation = "парка", replacement = "Park"},
{abbreviation = "вью", replacement = "View"},
{abbreviation = "вьюа", replacement = "View"},
{abbreviation = "хейтс", replacement = "Heights"},
{abbreviation = "хейтса", replacement = "Heights"},
{abbreviation = "тауэр", replacement = "Tower"},
{abbreviation = "тауэра", replacement = "Tower"},
{abbreviation = "бридж", replacement = "Bridge"},
{abbreviation = "бриджа", replacement = "Bridge"},
{abbreviation = "авеню", replacement = "Avenue"},
{abbreviation = "авенюа", replacement = "Avenue"},
{abbreviation = "стрит", replacement = "Street"},
{abbreviation = "стрита", replacement = "Street"},
{abbreviation = "роуд", replacement = "Road"},
{abbreviation = "роуда", replacement = "Road"},
{abbreviation = "плаза", replacement = "Plaza"},
{abbreviation = "плазы", replacement = "Plaza"},
{abbreviation = "сквер", replacement = "Square"},
{abbreviation = "сквера", replacement = "Square"},
{abbreviation = "барбершоп", replacement = "парикмахерскую"},
{abbreviation = "барбершопа", replacement = "парикмахерскую"},
{abbreviation = "парикмахерская", replacement = "парикмахерскую"},
{abbreviation = "парикмахерскую", replacement = "парикмахерскую"},
{abbreviation = "салон", replacement = "салон красоты"},
{abbreviation = "салона", replacement = "салон красоты"},
{abbreviation = "салону", replacement = "салон красоты"},
{abbreviation = "тату", replacement = "тату-салон"},
{abbreviation = "тату-салон", replacement = "тату-салон"},
{abbreviation = "тату-салона", replacement = "тату-салон"},
{abbreviation = "пиццерия", replacement = "пиццерию"},
{abbreviation = "пиццерию", replacement = "пиццерию"},
{abbreviation = "пиццерии", replacement = "пиццерию"},
{abbreviation = "пицца", replacement = "пиццерию"},
{abbreviation = "пиццы", replacement = "пиццерию"},
{abbreviation = "бордель", replacement = "бордель"},
{abbreviation = "борделя", replacement = "бордель"},
{abbreviation = "борделю", replacement = "бордель"},
{abbreviation = "стриптиз", replacement = "стриптиз-клуб"},
{abbreviation = "стриптиз-клуб", replacement = "стриптиз-клуб"},
{abbreviation = "стриптиз-клуба", replacement = "стриптиз-клуб"},
{abbreviation = "джентльмен", replacement = "стриптиз-клуб"},
{abbreviation = "автомойка", replacement = "автомойку"},
{abbreviation = "автомойку", replacement = "автомойку"},
{abbreviation = "автомойки", replacement = "автомойку"},
{abbreviation = "мойка", replacement = "автомойку"},
{abbreviation = "мойку", replacement = "автомойку"},
{abbreviation = "шиномонтаж", replacement = "шиномонтаж"},
{abbreviation = "шиномонтажа", replacement = "шиномонтаж"},
{abbreviation = "сто", replacement = "СТО"},
{abbreviation = "стоа", replacement = "СТО"},
{abbreviation = "техцентр", replacement = "техцентр"},
{abbreviation = "техцентра", replacement = "техцентр"},
{abbreviation = "автосервис", replacement = "автосервис"},
{abbreviation = "автосервиса", replacement = "автосервис"},
{abbreviation = "шиномонтажка", replacement = "шиномонтаж"},
{abbreviation = "шиномонтажку", replacement = "шиномонтаж"},
{abbreviation = "прачечная", replacement = "прачечную"},
{abbreviation = "прачечную", replacement = "прачечную"},
{abbreviation = "прачечной", replacement = "прачечную"},
{abbreviation = "химчистка", replacement = "химчистку"},
{abbreviation = "химчистку", replacement = "химчистку"},
{abbreviation = "химчистки", replacement = "химчистку"},
{abbreviation = "пункт", replacement = "пункт"},
{abbreviation = "пункта", replacement = "пункт"},
{abbreviation = "ломбард", replacement = "ломбард"},
{abbreviation = "ломбарда", replacement = "ломбард"},
{abbreviation = "ломбарду", replacement = "ломбард"},
{abbreviation = "ювелирный", replacement = "ювелирный магазин"},
{abbreviation = "ювелирного", replacement = "ювелирный магазин"},
{abbreviation = "ювелирка", replacement = "ювелирный магазин"},
{abbreviation = "ювелирку", replacement = "ювелирный магазин"},
{abbreviation = "ювелирки", replacement = "ювелирный магазин"},
{abbreviation = "оружейный", replacement = "оружейный магазин"},
{abbreviation = "оружейного", replacement = "оружейный магазин"},
{abbreviation = "оружейка", replacement = "оружейный магазин"},
{abbreviation = "оружейку", replacement = "оружейный магазин"},
{abbreviation = "оружейки", replacement = "оружейный магазин"},
{abbreviation = "электро", replacement = "электронику"},
{abbreviation = "электронику", replacement = "электронику"},
{abbreviation = "электроники", replacement = "электронику"},
{abbreviation = "компьютерный", replacement = "компьютерный магазин"},
{abbreviation = "компьютерного", replacement = "компьютерный магазин"},
{abbreviation = "комп", replacement = "компьютерный магазин"},
{abbreviation = "компа", replacement = "компьютерный магазин"},
{abbreviation = "спорттовары", replacement = "спорттовары"},
{abbreviation = "спорттоваров", replacement = "спорттовары"},
{abbreviation = "хозяйственный", replacement = "хозяйственный магазин"},
{abbreviation = "хозяйственного", replacement = "хозяйственный магазин"},
{abbreviation = "хозмаг", replacement = "хозяйственный магазин"},
{abbreviation = "хозмага", replacement = "хозяйственный магазин"},
{abbreviation = "продукты", replacement = "продуктовый магазин"},
{abbreviation = "продуктовый", replacement = "продуктовый магазин"},
{abbreviation = "продуктового", replacement = "продуктовый магазин"},
{abbreviation = "продмаг", replacement = "продуктовый магазин"},
{abbreviation = "продмага", replacement = "продуктовый магазин"},
{abbreviation = "супермаркет", replacement = "супермаркет"},
{abbreviation = "супермаркета", replacement = "супермаркет"},
{abbreviation = "супермаркету", replacement = "супермаркет"},
{abbreviation = "мини", replacement = "мини-маркет"},
{abbreviation = "мини-маркет", replacement = "мини-маркет"},
{abbreviation = "мини-маркета", replacement = "мини-маркет"},
{abbreviation = "ларек", replacement = "ларек"},
{abbreviation = "ларька", replacement = "ларек"},
{abbreviation = "ларьку", replacement = "ларек"},
{abbreviation = "киоск", replacement = "киоск"},
{abbreviation = "киоска", replacement = "киоск"},
{abbreviation = "палатка", replacement = "палатку"},
{abbreviation = "палатку", replacement = "палатку"},
{abbreviation = "палатки", replacement = "палатку"},
{abbreviation = "тент", replacement = "тент"},
{abbreviation = "тента", replacement = "тент"},
{abbreviation = "навес", replacement = "навес"},
{abbreviation = "навеса", replacement = "навес"},
{abbreviation = "гараж", replacement = "гараж"},
{abbreviation = "гаража", replacement = "гараж"},
{abbreviation = "гаражу", replacement = "гараж"},
{abbreviation = "гаражи", replacement = "гараж"},
{abbreviation = "бункер", replacement = "бункер"},
{abbreviation = "бункера", replacement = "бункер"},
{abbreviation = "бункеру", replacement = "бункер"},
{abbreviation = "подвал", replacement = "подвал"},
{abbreviation = "подвала", replacement = "подвал"},
{abbreviation = "чердак", replacement = "чердак"},
{abbreviation = "чердака", replacement = "чердак"},
{abbreviation = "мансарда", replacement = "мансарду"},
{abbreviation = "мансарду", replacement = "мансарду"},
{abbreviation = "мансарды", replacement = "мансарду"},
{abbreviation = "дача", replacement = "дачу"},
{abbreviation = "дачу", replacement = "дачу"},
{abbreviation = "дачи", replacement = "дачу"},
{abbreviation = "коттедж", replacement = "коттедж"},
{abbreviation = "коттеджа", replacement = "коттедж"},
{abbreviation = "коттеджу", replacement = "коттедж"},
{abbreviation = "таунхаус", replacement = "таунхаус"},
{abbreviation = "таунхауса", replacement = "таунхаус"},
{abbreviation = "таунхаусу", replacement = "таунхаус"},
{abbreviation = "бунгало", replacement = "бунгало"},
{abbreviation = "бунгалоа", replacement = "бунгало"},
{abbreviation = "времянка", replacement = "времянку"},
{abbreviation = "времянку", replacement = "времянку"},
{abbreviation = "времянки", replacement = "времянку"},
{abbreviation = "халупа", replacement = "халупу"},
{abbreviation = "халупу", replacement = "халупу"},
{abbreviation = "халупы", replacement = "халупу"},
{abbreviation = "лачуга", replacement = "лачугу"},
{abbreviation = "лачугу", replacement = "лачугу"},
{abbreviation = "лачуги", replacement = "лачугу"},
{abbreviation = "шалаш", replacement = "шалаш"},
{abbreviation = "шалаша", replacement = "шалаш"},
{abbreviation = "земля", replacement = "землю"},
{abbreviation = "землю", replacement = "землю"},
{abbreviation = "земли", replacement = "землю"},
{abbreviation = "участок", replacement = "участок"},
{abbreviation = "участка", replacement = "участок"},
{abbreviation = "участку", replacement = "участок"},
{abbreviation = "территория", replacement = "территорию"},
{abbreviation = "территорию", replacement = "территорию"},
{abbreviation = "территории", replacement = "территорию"},
{abbreviation = "площадь", replacement = "площадь"},
{abbreviation = "площади", replacement = "площадь"},
{abbreviation = "патроны", replacement = "патроны"},
{abbreviation = "патронов", replacement = "патроны"},
{abbreviation = "обойма", replacement = "обойму"},
{abbreviation = "обойму", replacement = "обойму"},
{abbreviation = "магазин", replacement = "магазин для оружия"},
{abbreviation = "магазина", replacement = "магазин для оружия"},
{abbreviation = "прицел", replacement = "прицел"},
{abbreviation = "прицела", replacement = "прицел"},
{abbreviation = "глушитель", replacement = "глушитель"},
{abbreviation = "глушителя", replacement = "глушитель"},
{abbreviation = "фонарик2", replacement = "фонарик"},
{abbreviation = "компас", replacement = "компас"},
{abbreviation = "компаса", replacement = "компас"},
{abbreviation = "карта", replacement = "карту"},
{abbreviation = "карту", replacement = "карту"},
{abbreviation = "карты", replacement = "карту"},
{abbreviation = "бинокль2", replacement = "бинокль"},
{abbreviation = "бинокля", replacement = "бинокль"},
{abbreviation = "термос", replacement = "термос"},
{abbreviation = "термоса", replacement = "термос"},
{abbreviation = "зажигалка", replacement = "зажигалку"},
{abbreviation = "зажигалку", replacement = "зажигалку"},
{abbreviation = "зажигалки", replacement = "зажигалку"},
{abbreviation = "сигареты", replacement = "сигареты"},
{abbreviation = "сигарет", replacement = "сигареты"},
{abbreviation = "алкоголь", replacement = "алкоголь"},
{abbreviation = "алкоголя", replacement = "алкоголь"},
{abbreviation = "пиво", replacement = "пиво"},
{abbreviation = "пива", replacement = "пиво"},
{abbreviation = "водка", replacement = "водку"},
{abbreviation = "водку", replacement = "водку"},
{abbreviation = "водки", replacement = "водку"},
{abbreviation = "виски", replacement = "виски"},
{abbreviation = "вискиа", replacement = "виски"},
{abbreviation = "вино", replacement = "вино"},
{abbreviation = "вина", replacement = "вино"},
{abbreviation = "кофе", replacement = "кофе"},
{abbreviation = "кофеа", replacement = "кофе"},
{abbreviation = "чай", replacement = "чай"},
{abbreviation = "чая", replacement = "чай"},
{abbreviation = "сок", replacement = "сок"},
{abbreviation = "сока", replacement = "сок"},
{abbreviation = "молоко", replacement = "молоко"},
{abbreviation = "молока", replacement = "молоко"},
{abbreviation = "хлеб", replacement = "хлеб"},
{abbreviation = "хлеба", replacement = "хлеб"},
{abbreviation = "мясо", replacement = "мясо"},
{abbreviation = "мяса", replacement = "мясо"},
{abbreviation = "рыба", replacement = "рыбу"},
{abbreviation = "рыбу", replacement = "рыбу"},
{abbreviation = "рыбы", replacement = "рыбу"},
{abbreviation = "фрукты", replacement = "фрукты"},
{abbreviation = "фруктов", replacement = "фрукты"},
{abbreviation = "овощи", replacement = "овощи"},
{abbreviation = "овощей", replacement = "овощи"},
{abbreviation = "конфеты", replacement = "конфеты"},
{abbreviation = "конфет", replacement = "конфеты"},
{abbreviation = "шоколад", replacement = "шоколад"},
{abbreviation = "шоколада", replacement = "шоколад"},
{abbreviation = "печенье", replacement = "печенье"},
{abbreviation = "печенья", replacement = "печенье"},
{abbreviation = "торт", replacement = "торт"},
{abbreviation = "торта", replacement = "торт"},
{abbreviation = "мороженое", replacement = "мороженое"},
{abbreviation = "мороженого", replacement = "мороженое"},
{abbreviation = "пицца2", replacement = "пиццу"},
{abbreviation = "пиццу", replacement = "пиццу"},
{abbreviation = "бургер", replacement = "бургер"},
{abbreviation = "бургера", replacement = "бургер"},
{abbreviation = "гамбургер", replacement = "гамбургер"},
{abbreviation = "гамбургера", replacement = "гамбургер"},
{abbreviation = "хотдог2", replacement = "хотдог"},
{abbreviation = "хотдога2", replacement = "хотдог"},
{abbreviation = "сэндвич", replacement = "сэндвич"},
{abbreviation = "сэндвича", replacement = "сэндвич"},
{abbreviation = "салат", replacement = "салат"},
{abbreviation = "салата", replacement = "салат"},
{abbreviation = "суши", replacement = "суши"},
{abbreviation = "роллы", replacement = "роллы"},
{abbreviation = "роллов", replacement = "роллы"},
{abbreviation = "лапша", replacement = "лапшу"},
{abbreviation = "лапшу", replacement = "лапшу"},
{abbreviation = "лапши", replacement = "лапшу"},
{abbreviation = "пельмени", replacement = "пельмени"},
{abbreviation = "пельменей", replacement = "пельмени"},
{abbreviation = "борщ", replacement = "борщ"},
{abbreviation = "борща", replacement = "борщ"},
{abbreviation = "суп", replacement = "суп"},
{abbreviation = "супа", replacement = "суп"},
{abbreviation = "обрез", replacement = "оружие \"Sawn-off Shotgun\""},
{abbreviation = "обреза", replacement = "оружие \"Sawn-off Shotgun\""},
{abbreviation = "обрезу", replacement = "оружие \"Sawn-off Shotgun\""},
{abbreviation = "двустволка", replacement = "оружие \"Sawn-off Shotgun\""},
{abbreviation = "двустволку", replacement = "оружие \"Sawn-off Shotgun\""},
{abbreviation = "помпа", replacement = "оружие \"Combat Shotgun\""},
{abbreviation = "помпу", replacement = "оружие \"Combat Shotgun\""},
{abbreviation = "помпы", replacement = "оружие \"Combat Shotgun\""},
{abbreviation = "комбат", replacement = "оружие \"Combat Shotgun\""},
{abbreviation = "комбата", replacement = "оружие \"Combat Shotgun\""},
{abbreviation = "микро", replacement = "оружие \"Micro SMG\""},
{abbreviation = "микроа", replacement = "оружие \"Micro SMG\""},
{abbreviation = "микроу", replacement = "оружие \"Micro SMG\""},
{abbreviation = "мп5", replacement = "оружие \"MP5\""},
{abbreviation = "мп5а", replacement = "оружие \"MP5\""},
{abbreviation = "глок", replacement = "оружие \"Pistol\""},
{abbreviation = "глока", replacement = "оружие \"Pistol\""},
{abbreviation = "кольт", replacement = "оружие \"Pistol\""},
{abbreviation = "кольта", replacement = "оружие \"Pistol\""},
{abbreviation = "беретта", replacement = "оружие \"Pistol\""},
{abbreviation = "беретту", replacement = "оружие \"Pistol\""},
{abbreviation = "дезерт", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "дезерта", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "игл", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "игла", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "слон", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "слона", replacement = "оружие \"Desert Eagle\""},
{abbreviation = "калаш", replacement = "оружие \"AK-47\""},
{abbreviation = "калаша", replacement = "оружие \"AK-47\""},
{abbreviation = "калаша", replacement = "оружие \"AK-47\""},
{abbreviation = "м16", replacement = "оружие \"M4\""},
{abbreviation = "м16а", replacement = "оружие \"M4\""},
{abbreviation = "галил", replacement = "оружие \"AK-47\""},
{abbreviation = "галила", replacement = "оружие \"AK-47\""},
{abbreviation = "стечкин", replacement = "оружие \"TEC-9\""},
{abbreviation = "стечкина", replacement = "оружие \"TEC-9\""},
{abbreviation = "скорпион", replacement = "оружие \"TEC-9\""},
{abbreviation = "скорпиона", replacement = "оружие \"TEC-9\""},
{abbreviation = "кукри", replacement = "оружие \"Knife\""},
{abbreviation = "кукриа", replacement = "оружие \"Knife\""},
{abbreviation = "мачете", replacement = "оружие \"Machete\""},
{abbreviation = "мачетеа", replacement = "оружие \"Machete\""},
{abbreviation = "дубину", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "дубина", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "дубины", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "дубинка", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "дубинку", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "дубинки", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "клюшка", replacement = "оружие \"Hockey Stick\""},
{abbreviation = "клюшку", replacement = "оружие \"Hockey Stick\""},
{abbreviation = "клюшки", replacement = "оружие \"Hockey Stick\""},
{abbreviation = "лапта", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "лапту", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "лапты", replacement = "оружие \"Baseball Bat\""},
{abbreviation = "ракета", replacement = "оружие \"Rocket Launcher\""},
{abbreviation = "ракету", replacement = "оружие \"Rocket Launcher\""},
{abbreviation = "ракеты", replacement = "оружие \"Rocket Launcher\""},
{abbreviation = "базука", replacement = "оружие \"Rocket Launcher\""},
{abbreviation = "базуку", replacement = "оружие \"Rocket Launcher\""},
{abbreviation = "базуки", replacement = "оружие \"Rocket Launcher\""},
{abbreviation = "гранатомет", replacement = "оружие \"Rocket Launcher\""},
{abbreviation = "гранатомета", replacement = "оружие \"Rocket Launcher\""},
{abbreviation = "огнемет", replacement = "оружие \"Flamethrower\""},
{abbreviation = "огнемета", replacement = "оружие \"Flamethrower\""},
{abbreviation = "миниган", replacement = "оружие \"Minigun\""},
{abbreviation = "минигана", replacement = "оружие \"Minigun\""},
{abbreviation = "мини", replacement = "оружие \"Minigun\""},
{abbreviation = "миниа", replacement = "оружие \"Minigun\""},
{abbreviation = "массаж", replacement = "массаж"},
{abbreviation = "массажа", replacement = "массаж"},
{abbreviation = "стрижка", replacement = "стрижку"},
{abbreviation = "стрижку", replacement = "стрижку"},
{abbreviation = "стрижки", replacement = "стрижку"},
{abbreviation = "маникюр", replacement = "маникюр"},
{abbreviation = "маникюра", replacement = "маникюр"},
{abbreviation = "педикюр", replacement = "педикюр"},
{abbreviation = "педикюра", replacement = "педикюр"},
{abbreviation = "бритье", replacement = "бритье"},
{abbreviation = "бритья", replacement = "бритье"},
{abbreviation = "укладка", replacement = "укладку"},
{abbreviation = "укладку", replacement = "укладку"},
{abbreviation = "окраска", replacement = "окраску"},
{abbreviation = "окраску", replacement = "окраску"},
{abbreviation = "окраски", replacement = "окраску"},
{abbreviation = "наращивание", replacement = "наращивание"},
{abbreviation = "наращивания", replacement = "наращивание"},
{abbreviation = "пирсинг", replacement = "пирсинг"},
{abbreviation = "пирсинга", replacement = "пирсинг"},
{abbreviation = "татуировка", replacement = "татуировку"},
{abbreviation = "татуировку", replacement = "татуировку"},
{abbreviation = "татуировки", replacement = "татуировку"},
{abbreviation = "репетитор", replacement = "репетитора"},
{abbreviation = "репетитора", replacement = "репетитора"},
{abbreviation = "обучение", replacement = "обучение"},
{abbreviation = "обучения", replacement = "обучение"},
{abbreviation = "курсы", replacement = "курсы"},
{abbreviation = "курсов", replacement = "курсы"},
{abbreviation = "тренинг", replacement = "тренинг"},
{abbreviation = "тренинга", replacement = "тренинг"},
{abbreviation = "тренинги", replacement = "тренинг"},
{abbreviation = "семинар", replacement = "семинар"},
{abbreviation = "семинара", replacement = "семинар"},
{abbreviation = "лекция", replacement = "лекцию"},
{abbreviation = "лекцию", replacement = "лекцию"},
{abbreviation = "лекции", replacement = "лекцию"},
{abbreviation = "консультация", replacement = "консультацию"},
{abbreviation = "консультацию", replacement = "консультацию"},
{abbreviation = "консультации", replacement = "консультацию"},
{abbreviation = "лечение", replacement = "лечение"},
{abbreviation = "лечения", replacement = "лечение"},
{abbreviation = "терапия", replacement = "терапию"},
{abbreviation = "терапию", replacement = "терапию"},
{abbreviation = "диагностика", replacement = "диагностику"},
{abbreviation = "диагностику", replacement = "диагностику"},
{abbreviation = "диагностики", replacement = "диагностику"},
{abbreviation = "ремонт2", replacement = "ремонт"},
{abbreviation = "настройка", replacement = "настройку"},
{abbreviation = "настройку", replacement = "настройку"},
{abbreviation = "настройки", replacement = "настройку"},
{abbreviation = "установка", replacement = "установку"},
{abbreviation = "установку", replacement = "установку"},
{abbreviation = "установки", replacement = "установку"},
{abbreviation = "монтаж", replacement = "монтаж"},
{abbreviation = "монтажа", replacement = "монтаж"},
{abbreviation = "демонтаж", replacement = "демонтаж"},
{abbreviation = "демонтажа", replacement = "демонтаж"},
{abbreviation = "перевозка", replacement = "перевозку"},
{abbreviation = "перевозку", replacement = "перевозку"},
{abbreviation = "перевозки", replacement = "перевозку"},
{abbreviation = "грузоперевозки", replacement = "грузоперевозки"},
{abbreviation = "грузоперевозок", replacement = "грузоперевозки"},
{abbreviation = "логистика", replacement = "логистику"},
{abbreviation = "логистику", replacement = "логистику"},
{abbreviation = "склад2", replacement = "складирование"},
{abbreviation = "хранение", replacement = "хранение"},
{abbreviation = "хранения", replacement = "хранение"},
{abbreviation = "охрана2", replacement = "охрана"},
{abbreviation = "охрану2", replacement = "охрану"},
{abbreviation = "сигнализация", replacement = "сигнализацию"},
{abbreviation = "сигнализацию", replacement = "сигнализацию"},
{abbreviation = "сигнализации", replacement = "сигнализацию"},
{abbreviation = "видеонаблюдение", replacement = "видеонаблюдение"},
{abbreviation = "видеонаблюдения", replacement = "видеонаблюдение"},
{abbreviation = "уборка", replacement = "уборку"},
{abbreviation = "уборку", replacement = "уборку"},
{abbreviation = "уборки", replacement = "уборку"},
{abbreviation = "клининг", replacement = "клининг"},
{abbreviation = "клининга", replacement = "клининг"},
{abbreviation = "стирка", replacement = "стирку"},
{abbreviation = "стирку", replacement = "стирку"},
{abbreviation = "стирки", replacement = "стирку"},
{abbreviation = "химчистка2", replacement = "химчистку"},
{abbreviation = "глажка", replacement = "глажку"},
{abbreviation = "глажку", replacement = "глажку"},
{abbreviation = "глажки", replacement = "глажку"},
{abbreviation = "ремонт3", replacement = "починку"},
{abbreviation = "починку", replacement = "починку"},
{abbreviation = "починки", replacement = "починку"},
{abbreviation = "наладка", replacement = "наладку"},
{abbreviation = "наладку", replacement = "наладку"},
{abbreviation = "наладки", replacement = "наладку"},
{abbreviation = "заправка2", replacement = "заправку"},
{abbreviation = "заправку2", replacement = "заправку"},
{abbreviation = "дозаправка", replacement = "дозаправку"},
{abbreviation = "дозаправку", replacement = "дозаправку"},
{abbreviation = "эвакуатор2", replacement = "эвакуатор"},
{abbreviation = "буксировка", replacement = "буксировку"},
{abbreviation = "буксировку", replacement = "буксировку"},
{abbreviation = "буксировки", replacement = "буксировку"},
{abbreviation = "запуск", replacement = "запуск двигателя"},
{abbreviation = "запуска", replacement = "запуск двигателя"},
{abbreviation = "прикуривание", replacement = "прикуривание"},
{abbreviation = "прикуривания", replacement = "прикуривание"},
{abbreviation = "замена", replacement = "замену"},
{abbreviation = "замену", replacement = "замену"},
{abbreviation = "замены", replacement = "замену"},
{abbreviation = "масло", replacement = "замену масла"},
{abbreviation = "масла", replacement = "замену масла"},
{abbreviation = "фильтр", replacement = "фильтр"},
{abbreviation = "фильтра", replacement = "фильтр"},
{abbreviation = "шины", replacement = "шины"},
{abbreviation = "шин", replacement = "шины"},
{abbreviation = "покрышки", replacement = "покрышки"},
{abbreviation = "покрышек", replacement = "покрышки"},
{abbreviation = "диски", replacement = "диски"},
{abbreviation = "дисков", replacement = "диски"},
{abbreviation = "колеса", replacement = "колеса"},
{abbreviation = "колес", replacement = "колеса"},
{abbreviation = "аккумулятор", replacement = "аккумулятор"},
{abbreviation = "аккумулятора", replacement = "аккумулятор"},
{abbreviation = "телефон2", replacement = "телефон"},
{abbreviation = "телефона2", replacement = "телефон"},
{abbreviation = "смартфон", replacement = "смартфон"},
{abbreviation = "смартфона", replacement = "смартфон"},
{abbreviation = "айфон", replacement = "смартфон"},
{abbreviation = "айфона", replacement = "смартфон"},
{abbreviation = "андроид", replacement = "смартфон"},
{abbreviation = "планшет", replacement = "планшет"},
{abbreviation = "планшета", replacement = "планшет"},
{abbreviation = "ноутбук", replacement = "ноутбук"},
{abbreviation = "ноутбука", replacement = "ноутбук"},
{abbreviation = "компьютер", replacement = "компьютер"},
{abbreviation = "компьютера", replacement = "компьютер"},
{abbreviation = "монитор", replacement = "монитор"},
{abbreviation = "монитора", replacement = "монитор"},
{abbreviation = "клавиатура", replacement = "клавиатуру"},
{abbreviation = "клавиатуру", replacement = "клавиатуру"},
{abbreviation = "мышь", replacement = "мышь"},
{abbreviation = "мыши", replacement = "мышь"},
{abbreviation = "принтер", replacement = "принтер"},
{abbreviation = "принтера", replacement = "принтер"},
{abbreviation = "наушники", replacement = "наушники"},
{abbreviation = "наушников", replacement = "наушники"},
{abbreviation = "колонка", replacement = "колонку"},
{abbreviation = "колонку", replacement = "колонку"},
{abbreviation = "колонки", replacement = "колонку"},
{abbreviation = "микрофон", replacement = "микрофон"},
{abbreviation = "микрофона", replacement = "микрофон"},
{abbreviation = "камера", replacement = "камеру"},
{abbreviation = "камеру", replacement = "камеру"},
{abbreviation = "камеры", replacement = "камеру"},
{abbreviation = "фотоаппарат", replacement = "фотоаппарат"},
{abbreviation = "фотоаппарата", replacement = "фотоаппарат"},
{abbreviation = "объектив", replacement = "объектив"},
{abbreviation = "объектива", replacement = "объектив"},
{abbreviation = "штатив", replacement = "штатив"},
{abbreviation = "штатива", replacement = "штатив"},
{abbreviation = "очки2", replacement = "очки"},
{abbreviation = "линзы", replacement = "линзы"},
{abbreviation = "линзов", replacement = "линзы"},
{abbreviation = "сумка", replacement = "сумку"},
{abbreviation = "сумку", replacement = "сумку"},
{abbreviation = "сумки", replacement = "сумку"},
{abbreviation = "рюкзак2", replacement = "рюкзак"},
{abbreviation = "рюкзака2", replacement = "рюкзак"},
{abbreviation = "чемодан", replacement = "чемодан"},
{abbreviation = "чемодана", replacement = "чемодан"},
{abbreviation = "портфель", replacement = "портфель"},
{abbreviation = "портфеля", replacement = "портфель"},
{abbreviation = "кошелек", replacement = "кошелек"},
{abbreviation = "кошелька", replacement = "кошелек"},
{abbreviation = "зонт", replacement = "зонт"},
{abbreviation = "зонта", replacement = "зонт"},
{abbreviation = "ключ", replacement = "ключ"},
{abbreviation = "ключа", replacement = "ключ"},
{abbreviation = "ключи", replacement = "ключи"},
{abbreviation = "ключей", replacement = "ключи"},
{abbreviation = "замок", replacement = "замок"},
{abbreviation = "замка", replacement = "замок"},
{abbreviation = "цепь", replacement = "цепь"},
{abbreviation = "цепи", replacement = "цепь"},
{abbreviation = "цепь2", replacement = "цепь"},
{abbreviation = "брелок", replacement = "брелок"},
{abbreviation = "брелока", replacement = "брелок"},
{abbreviation = "значок", replacement = "значок"},
{abbreviation = "значка", replacement = "значок"},
{abbreviation = "медаль", replacement = "медаль"},
{abbreviation = "медали", replacement = "медаль"},
{abbreviation = "кубок", replacement = "кубок"},
{abbreviation = "кубка", replacement = "кубок"},
{abbreviation = "грамота", replacement = "грамоту"},
{abbreviation = "грамоту", replacement = "грамоту"},
{abbreviation = "диплом", replacement = "диплом"},
{abbreviation = "диплома", replacement = "диплом"},
{abbreviation = "сертификат", replacement = "сертификат"},
{abbreviation = "сертификата", replacement = "сертификат"},
{abbreviation = "купон", replacement = "купон"},
{abbreviation = "купона", replacement = "купон"},
{abbreviation = "ваучер", replacement = "ваучер"},
{abbreviation = "ваучера", replacement = "ваучер"},
{abbreviation = "билет", replacement = "билет"},
{abbreviation = "билета", replacement = "билет"},
{abbreviation = "абонемент", replacement = "абонемент"},
{abbreviation = "абонемента", replacement = "абонемент"},
{abbreviation = "пропуск", replacement = "пропуск"},
{abbreviation = "пропуска", replacement = "пропуск"},
{abbreviation = "бенсон", replacement = "а/м марки \"Benson\" FT"},
{abbreviation = "бенсона", replacement = "а/м марки \"Benson\" FT"},
{abbreviation = "бенсону", replacement = "а/м марки \"Benson\" FT"},
{abbreviation = "боксвилл", replacement = "а/м марки \"Boxville\" FT"},
{abbreviation = "боксвилла", replacement = "а/м марки \"Boxville\" FT"},
{abbreviation = "борд", replacement = "а/м марки \"Bord\" FT"},
{abbreviation = "борда", replacement = "а/м марки \"Bord\" FT"},
{abbreviation = "калвер", replacement = "а/м марки \"Culver\" FT"},
{abbreviation = "калвера", replacement = "а/м марки \"Culver\" FT"},
{abbreviation = "дюнес", replacement = "а/м марки \"Dunes\" FT"},
{abbreviation = "дюнеса", replacement = "а/м марки \"Dunes\" FT"},
{abbreviation = "форд2", replacement = "а/м марки \"Ford\" FT"},
{abbreviation = "форда2", replacement = "а/м марки \"Ford\" FT"},
{abbreviation = "ханли", replacement = "а/м марки \"Hanley\" FT"},
{abbreviation = "ханлиа", replacement = "а/м марки \"Hanley\" FT"},
{abbreviation = "хантер3", replacement = "а/м марки \"Hunter\" FT"},
{abbreviation = "хантера3", replacement = "а/м марки \"Hunter\" FT"},
{abbreviation = "ларго", replacement = "а/м марки \"Largo\" FT"},
{abbreviation = "ларгоа", replacement = "а/м марки \"Largo\" FT"},
{abbreviation = "локус", replacement = "а/м марки \"Locust\" FT"},
{abbreviation = "локуса", replacement = "а/м марки \"Locust\" FT"},
{abbreviation = "маверик", replacement = "а/м марки \"Maverick\" FT FT"},
{abbreviation = "маверика", replacement = "а/м марки \"Maverick\" FT FT"},
{abbreviation = "мерит", replacement = "а/м марки \"Merit\" FT"},
{abbreviation = "мерита", replacement = "а/м марки \"Merit\" FT"},
{abbreviation = "мэверик", replacement = "а/м марки \"Maverick\" FT FT"},
{abbreviation = "мэверика", replacement = "а/м марки \"Maverick\" FT FT"},
{abbreviation = "нэссон", replacement = "а/м марки \"Nesson\" FT"},
{abbreviation = "нэссона", replacement = "а/м марки \"Nesson\" FT"},
{abbreviation = "полар", replacement = "а/м марки \"Polar\" FT"},
{abbreviation = "полара", replacement = "а/м марки \"Polar\" FT"},
{abbreviation = "рэнчер2", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "рэнчера2", replacement = "а/м марки \"Rancher\" FT"},
{abbreviation = "санчо", replacement = "а/м марки \"Sanchez\""},
{abbreviation = "санчоа", replacement = "а/м марки \"Sanchez\""},
{abbreviation = "симплон", replacement = "а/м марки \"Simpleon\" FT"},
{abbreviation = "симплона", replacement = "а/м марки \"Simpleon\" FT"},
{abbreviation = "симпл", replacement = "а/м марки \"Simpleon\" FT"},
{abbreviation = "спринтер", replacement = "а/м марки \"Sprinter\" FT"},
{abbreviation = "спринтера", replacement = "а/м марки \"Sprinter\" FT"},
{abbreviation = "сток", replacement = "а/м марки \"Stock\" FT"},
{abbreviation = "стока", replacement = "а/м марки \"Stock\" FT"},
{abbreviation = "трэш", replacement = "а/м марки \"Trash\" FT"},
{abbreviation = "трэша", replacement = "а/м марки \"Trash\" FT"},
{abbreviation = "трэшмастер", replacement = "а/м марки \"Trashmaster\" FT"},
{abbreviation = "трэшмастера", replacement = "а/м марки \"Trashmaster\" FT"},
{abbreviation = "урал", replacement = "а/м марки \"Ural\" FT"},
{abbreviation = "урала", replacement = "а/м марки \"Ural\" FT"},
{abbreviation = "уралу", replacement = "а/м марки \"Ural\" FT"},
{abbreviation = "вэн", replacement = "а/м марки \"Van\" FT"},
{abbreviation = "вэна", replacement = "а/м марки \"Van\" FT"},
{abbreviation = "вэну", replacement = "а/м марки \"Van\" FT"},
{abbreviation = "вэнс", replacement = "а/м марки \"Vance\" FT"},
{abbreviation = "вэнса", replacement = "а/м марки \"Vance\" FT"},
{abbreviation = "вэнсон", replacement = "а/м марки \"Venson\" FT"},
{abbreviation = "вэнсона", replacement = "а/м марки \"Venson\" FT"},
{abbreviation = "йолк", replacement = "а/м марки \"Yolk\" FT"},
{abbreviation = "йолка", replacement = "а/м марки \"Yolk\" FT"},
{abbreviation = "зомби3", replacement = "а/м марки \"Zombie\" FT"},
{abbreviation = "зомбиа3", replacement = "а/м марки \"Zombie\" FT"},
{abbreviation = "буллет2", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "буллета2", replacement = "а/м марки \"Bullet\" FT"},
{abbreviation = "инфернус2", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "инфернуса2", replacement = "а/м марки \"Infernus\" FT"},
{abbreviation = "турисмо2", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "турисмоа2", replacement = "а/м марки \"Turismo\" FT"},
{abbreviation = "чирок2", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "чирока2", replacement = "а/м марки \"Cheetah\" FT"},
{abbreviation = "банши2", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "банши2а", replacement = "а/м марки \"Banshee\" FT"},
{abbreviation = "феникс2", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "феникса2", replacement = "а/м марки \"Phoenix\" FT"},
{abbreviation = "супергт2", replacement = "а/м марки \"Super GT\" FT"},
{abbreviation = "супергта2", replacement = "а/м марки \"Super GT\" FT"},
{abbreviation = "стингер2", replacement = "а/м марки \"Stinger\" FT"},
{abbreviation = "стингера2", replacement = "а/м марки \"Stinger\" FT"},
{abbreviation = "комета2", replacement = "а/м марки \"Comet\" FT"},
{abbreviation = "комету2", replacement = "а/м марки \"Comet\" FT"},
{abbreviation = "бмх2", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "бмха2", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "бмху2", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "байк2", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "байка2", replacement = "велосипед марки \"BMX\" FT"},
{abbreviation = "велика2", replacement = "велосипед"},
{abbreviation = "велику2", replacement = "велосипед"},
{abbreviation = "велик2", replacement = "велосипед"},
{abbreviation = "катер", replacement = "лодку"},
{abbreviation = "катера", replacement = "лодку"},
{abbreviation = "катеру", replacement = "лодку"},
{abbreviation = "лодка2", replacement = "лодку"},
{abbreviation = "лодку2", replacement = "лодку"},
{abbreviation = "лодки2", replacement = "лодку"},
{abbreviation = "яхта2", replacement = "яхту"},
{abbreviation = "яхту2", replacement = "яхту"},
{abbreviation = "яхты2", replacement = "яхту"},
{abbreviation = "баркас", replacement = "лодку"},
{abbreviation = "баркаса", replacement = "лодку"},
{abbreviation = "шлюпка", replacement = "лодку"},
{abbreviation = "шлюпку", replacement = "лодку"},
{abbreviation = "байдарка", replacement = "лодку"},
{abbreviation = "байдарку", replacement = "лодку"},
{abbreviation = "каноэ", replacement = "лодку"},
{abbreviation = "каноэа", replacement = "лодку"},
{abbreviation = "плот", replacement = "лодку"},
{abbreviation = "плота", replacement = "лодку"},
{abbreviation = "вертолет2", replacement = "вертолёт"},
{abbreviation = "вертолёт2", replacement = "вертолёт"},
{abbreviation = "вертолёта2", replacement = "вертолёт"},
{abbreviation = "самолет2", replacement = "самолёт"},
{abbreviation = "самолёт2", replacement = "самолёт"},
{abbreviation = "самолёта2", replacement = "самолёт"},
{abbreviation = "самолёту2", replacement = "самолёт"},
{abbreviation = "кукурузник", replacement = "самолёт"},
{abbreviation = "кукурузника", replacement = "самолёт"},
{abbreviation = "кукурузнику", replacement = "самолёт"},
{abbreviation = "истребитель", replacement = "самолёт"},
{abbreviation = "истребителя", replacement = "самолёт"},
{abbreviation = "бомбардировщик", replacement = "самолёт"},
{abbreviation = "бомбардировщика", replacement = "самолёт"},
{abbreviation = "дирижабль", replacement = "дирижабль"},
{abbreviation = "дирижабля", replacement = "дирижабль"},
{abbreviation = "воздушный", replacement = "шар"},
{abbreviation = "шар", replacement = "шар"},
{abbreviation = "шара", replacement = "шар"},
{abbreviation = "парашют2", replacement = "аксессуар \"Парашют\""},
{abbreviation = "парашюты2", replacement = "аксессуар \"Парашют\""},
{abbreviation = "дельтаплан", replacement = "дельтаплан"},
{abbreviation = "дельтаплана", replacement = "дельтаплан"},
{abbreviation = "эхо", replacement = "East Los Santos"},
{abbreviation = "эхоа", replacement = "East Los Santos"},
{abbreviation = "эхо парк", replacement = "East Los Santos"},
{abbreviation = "айдинлвуд", replacement = "Idlewood"},
{abbreviation = "айдинлвуда", replacement = "Idlewood"},
{abbreviation = "джеф2", replacement = "Jefferson"},
{abbreviation = "джеф2а", replacement = "Jefferson"},
{abbreviation = "глен2", replacement = "Glen Park"},
{abbreviation = "глена2", replacement = "Glen Park"},
{abbreviation = "виллоу", replacement = "Willowfield"},
{abbreviation = "виллоуфилд2", replacement = "Willowfield"},
{abbreviation = "элкорона2", replacement = "El Corona"},
{abbreviation = "элкорона2а", replacement = "El Corona"},
{abbreviation = "коммерс2", replacement = "Commerce"},
{abbreviation = "маркет2", replacement = "Market"},
{abbreviation = "маркета2", replacement = "Market"},
{abbreviation = "конференс", replacement = "Conference Center"},
{abbreviation = "конференса", replacement = "Conference Center"},
{abbreviation = "персхинг", replacement = "Pershing Square"},
{abbreviation = "персхинга", replacement = "Pershing Square"},
{abbreviation = "першинг", replacement = "Pershing Square"},
{abbreviation = "першинга", replacement = "Pershing Square"},
{abbreviation = "сити", replacement = "City Hall"},
{abbreviation = "сити2", replacement = "City Hall"},
{abbreviation = "таун", replacement = "Downtown"},
{abbreviation = "тауна", replacement = "Downtown"},
{abbreviation = "даунтаун", replacement = "Downtown"},
{abbreviation = "даунтауна", replacement = "Downtown"},
{abbreviation = "плаза2", replacement = "Pershing Square"},
{abbreviation = "гарсия2", replacement = "Garcia"},
{abbreviation = "гарсии2", replacement = "Garcia"},
{abbreviation = "хашбери2", replacement = "Hashbury"},
{abbreviation = "хашбериа2", replacement = "Hashbury"},
{abbreviation = "дохерти2", replacement = "Doherty"},
{abbreviation = "дохертиа2", replacement = "Doherty"},
{abbreviation = "кингс2", replacement = "Kings"},
{abbreviation = "кингса2", replacement = "Kings"},
{abbreviation = "парадизо2", replacement = "Paradiso"},
{abbreviation = "парадизоа2", replacement = "Paradiso"},
{abbreviation = "квартал2", replacement = "Queens"},
{abbreviation = "квартала2", replacement = "Queens"},
{abbreviation = "сантафлора2", replacement = "Santa Flora"},
{abbreviation = "санта2", replacement = "Santa Flora"},
{abbreviation = "фостер", replacement = "Foster Valley"},
{abbreviation = "фостера", replacement = "Foster Valley"},
{abbreviation = "фостер2", replacement = "Foster Valley"},
{abbreviation = "фостера2", replacement = "Foster Valley"},
{abbreviation = "гарберри", replacement = "Garberry"},
{abbreviation = "гарберриа", replacement = "Garberry"},
{abbreviation = "эшберри2", replacement = "Ashberry"},
{abbreviation = "эшберри2а", replacement = "Ashberry"},
{abbreviation = "бэйсайд2", replacement = "Bayside"},
{abbreviation = "бэйсайд2а", replacement = "Bayside"},
{abbreviation = "бэйсайду2", replacement = "Bayside"},
{abbreviation = "стрип2", replacement = "The Strip"},
{abbreviation = "стрипа2", replacement = "The Strip"},
{abbreviation = "рокшор2", replacement = "Rockshore"},
{abbreviation = "рокшора2", replacement = "Rockshore"},
{abbreviation = "пилон2", replacement = "Pilgrim"},
{abbreviation = "пилона2", replacement = "Pilgrim"},
{abbreviation = "авалон2", replacement = "Avalon"},
{abbreviation = "авалона2", replacement = "Avalon"},
{abbreviation = "драгон2", replacement = "Dragons Dojo"},
{abbreviation = "драгона2", replacement = "Dragons Dojo"},
{abbreviation = "прайм2", replacement = "Prickle Pine"},
{abbreviation = "прикл2", replacement = "Prickle Pine"},
{abbreviation = "вайтвуд2", replacement = "Whitewood"},
{abbreviation = "вайтвуда2", replacement = "Whitewood"},
{abbreviation = "пилбокс2", replacement = "Pilbox"},
{abbreviation = "пилбокса2", replacement = "Pilbox"},
{abbreviation = "ройал2", replacement = "Royal Casino"},
{abbreviation = "калигула2", replacement = "Caligulas Palace"},
{abbreviation = "пират2", replacement = "Pirates in Mens Pants"},
{abbreviation = "визаж2", replacement = "Visage"},
{abbreviation = "флинт3", replacement = "Flint County"},
{abbreviation = "флинта3", replacement = "Flint County"},
{abbreviation = "пк2", replacement = "Palomino Creek"},
{abbreviation = "паломино2", replacement = "Palomino Creek"},
{abbreviation = "монтгомери2", replacement = "Montgomery"},
{abbreviation = "диллимор2", replacement = "Dillimore"},
{abbreviation = "блюбери2", replacement = "Blueberry"},
{abbreviation = "бляберри2", replacement = "Blueberry"},
{abbreviation = "форт2", replacement = "Fort Carson"},
{abbreviation = "карсон2", replacement = "Fort Carson"},
{abbreviation = "тиера2", replacement = "Tierra Robada"},
{abbreviation = "робада2", replacement = "Tierra Robada"},
{abbreviation = "ангел2", replacement = "Angel Pine"},
{abbreviation = "норт2", replacement = "North Rock"},
{abbreviation = "валле2", replacement = "Valle Ocultado"},
{abbreviation = "арко2", replacement = "Arco del Oeste"},
{abbreviation = "грин2", replacement = "Green Palms"},
{abbreviation = "палмс2", replacement = "Green Palms"},
{abbreviation = "юнион2", replacement = "Union Station"},
{abbreviation = "крик2", replacement = "Palomino Creek"},
{abbreviation = "куэбрадос", replacement = "El Quebrados"},
{abbreviation = "куэбрадоса", replacement = "El Quebrados"},
{abbreviation = "элькебрадос", replacement = "El Quebrados"},
{abbreviation = "элькуебрадос", replacement = "El Quebrados"},
{abbreviation = "аэропорт", replacement = "Airport"},
{abbreviation = "аэропорта", replacement = "Airport"},
{abbreviation = "аэропорту", replacement = "Airport"},
{abbreviation = "аэро", replacement = "Airport"},
{abbreviation = "аэроа", replacement = "Airport"},
{abbreviation = "порт3", replacement = "Port"},
{abbreviation = "порта3", replacement = "Port"},
{abbreviation = "вокзал", replacement = "Station"},
{abbreviation = "вокзала", replacement = "Station"},
{abbreviation = "станция", replacement = "Station"},
{abbreviation = "станции", replacement = "Station"},
{abbreviation = "станцию", replacement = "Station"},
{abbreviation = "метро", replacement = "Metro"},
{abbreviation = "метроа", replacement = "Metro"},
{abbreviation = "остановка", replacement = "остановку"},
{abbreviation = "остановку", replacement = "остановку"},
{abbreviation = "перекресток", replacement = "перекресток"},
{abbreviation = "перекрестка", replacement = "перекресток"},
{abbreviation = "развязка", replacement = "развязку"},
{abbreviation = "развязку", replacement = "развязку"},
{abbreviation = "мост", replacement = "мост"},
{abbreviation = "моста", replacement = "мост"},
{abbreviation = "тоннель", replacement = "тоннель"},
{abbreviation = "тоннеля", replacement = "тоннель"},
{abbreviation = "трасса", replacement = "трассу"},
{abbreviation = "трассу", replacement = "трассу"},
{abbreviation = "шоссе", replacement = "шоссе"},
{abbreviation = "шоссеа", replacement = "шоссе"},
{abbreviation = "автострада", replacement = "автостраду"},
{abbreviation = "автостраду", replacement = "автостраду"},
{abbreviation = "дорога", replacement = "дорогу"},
{abbreviation = "дорогу", replacement = "дорогу"},
{abbreviation = "улица", replacement = "улицу"},
{abbreviation = "улицу", replacement = "улицу"},
{abbreviation = "переулок", replacement = "переулок"},
{abbreviation = "переулка", replacement = "переулок"},
{abbreviation = "проспект", replacement = "проспект"},
{abbreviation = "проспекта", replacement = "проспект"},
{abbreviation = "бульвар", replacement = "бульвар"},
{abbreviation = "бульвара", replacement = "бульвар"},
{abbreviation = "набережная", replacement = "набережную"},
{abbreviation = "набережную", replacement = "набережную"},
{abbreviation = "пляж", replacement = "пляж"},
{abbreviation = "пляжа", replacement = "пляж"},
{abbreviation = "берег", replacement = "берег"},
{abbreviation = "берега", replacement = "берег"},
{abbreviation = "остров", replacement = "остров"},
{abbreviation = "острова", replacement = "остров"},
{abbreviation = "полуостров", replacement = "полуостров"},
{abbreviation = "полуострова", replacement = "полуостров"},
{abbreviation = "залив", replacement = "залив"},
{abbreviation = "залива", replacement = "залив"},
{abbreviation = "бухта", replacement = "бухту"},
{abbreviation = "бухту", replacement = "бухту"},
{abbreviation = "мыс", replacement = "мыс"},
{abbreviation = "мыса", replacement = "мыс"},
{abbreviation = "гора", replacement = "гору"},
{abbreviation = "гору", replacement = "гору"},
{abbreviation = "холм", replacement = "холм"},
{abbreviation = "холма", replacement = "холм"},
{abbreviation = "долина", replacement = "долину"},
{abbreviation = "долину", replacement = "долину"},
{abbreviation = "пустыня", replacement = "пустыню"},
{abbreviation = "пустыню", replacement = "пустыню"},
{abbreviation = "лес", replacement = "лес"},
{abbreviation = "леса", replacement = "лес"},
{abbreviation = "поле", replacement = "поле"},
{abbreviation = "поля", replacement = "поле"},
{abbreviation = "озеро", replacement = "озеро"},
{abbreviation = "озера", replacement = "озеро"},
{abbreviation = "река", replacement = "реку"},
{abbreviation = "реку", replacement = "реку"},
{abbreviation = "канал", replacement = "канал"},
{abbreviation = "канала", replacement = "канал"},
{abbreviation = "водопад", replacement = "водопад"},
{abbreviation = "водопада", replacement = "водопад"},
{abbreviation = "каньон", replacement = "каньон"},
{abbreviation = "каньона", replacement = "каньон"},
{abbreviation = "ущелье", replacement = "ущелье"},
{abbreviation = "ущелья", replacement = "ущелье"},
{abbreviation = "пещера", replacement = "пещеру"},
{abbreviation = "пещеру", replacement = "пещеру"},
{abbreviation = "руины", replacement = "руины"},
{abbreviation = "руин", replacement = "руины"},
{abbreviation = "крепость", replacement = "крепость"},
{abbreviation = "крепости", replacement = "крепость"},
{abbreviation = "замок", replacement = "замок"},
{abbreviation = "замка", replacement = "замок"},
{abbreviation = "башня", replacement = "башню"},
{abbreviation = "башню", replacement = "башню"},
{abbreviation = "колокол", replacement = "колокол"},
{abbreviation = "колокола", replacement = "колокол"},
{abbreviation = "маяк", replacement = "маяк"},
{abbreviation = "маяка", replacement = "маяк"},
{abbreviation = "плотина", replacement = "плотину"},
{abbreviation = "плотину", replacement = "плотину"},
{abbreviation = "шлюз", replacement = "шлюз"},
{abbreviation = "шлюза", replacement = "шлюз"},
{abbreviation = "мельница", replacement = "мельницу"},
{abbreviation = "мельницу", replacement = "мельницу"},
{abbreviation = "фабрика2", replacement = "фабрику"},
{abbreviation = "завод2", replacement = "завод"},
{abbreviation = "шахта2", replacement = "шахту"},
{abbreviation = "карьер", replacement = "карьер"},
{abbreviation = "карьера", replacement = "карьер"},
{abbreviation = "рудник", replacement = "рудник"},
{abbreviation = "рудника", replacement = "рудник"},
{abbreviation = "шахта3", replacement = "шахту"},
{abbreviation = "барбершоп2", replacement = "парикмахерскую"},
{abbreviation = "барбер", replacement = "парикмахерскую"},
{abbreviation = "цирюльня", replacement = "парикмахерскую"},
{abbreviation = "цирюльню", replacement = "парикмахерскую"},
{abbreviation = "парикмахерская2", replacement = "парикмахерскую"},
{abbreviation = "салон2", replacement = "салон красоты"},
{abbreviation = "салона2", replacement = "салон красоты"},
{abbreviation = "спа", replacement = "СПА"},
{abbreviation = "спаа", replacement = "СПА"},
{abbreviation = "бани", replacement = "баню"},
{abbreviation = "баню", replacement = "баню"},
{abbreviation = "бanya", replacement = "баню"},
{abbreviation = "сауна", replacement = "сауну"},
{abbreviation = "сауну", replacement = "сауну"},
{abbreviation = "сауны", replacement = "сауну"},
{abbreviation = "бассейн", replacement = "бассейн"},
{abbreviation = "бассейна", replacement = "бассейн"},
{abbreviation = "аквапарк", replacement = "аквапарк"},
{abbreviation = "аквапарка", replacement = "аквапарк"},
{abbreviation = "парк2", replacement = "парк"},
{abbreviation = "парка2", replacement = "парк"},
{abbreviation = "сквер2", replacement = "сквер"},
{abbreviation = "сквера2", replacement = "сквер"},
{abbreviation = "сад", replacement = "сад"},
{abbreviation = "сада", replacement = "сад"},
{abbreviation = "огород", replacement = "огород"},
{abbreviation = "огорода", replacement = "огород"},
{abbreviation = "теплица", replacement = "теплицу"},
{abbreviation = "теплицу", replacement = "теплицу"},
{abbreviation = "оранжерея", replacement = "оранжерею"},
{abbreviation = "оранжерею", replacement = "оранжерею"},
{abbreviation = "питомник", replacement = "питомник"},
{abbreviation = "питомника", replacement = "питомник"},
{abbreviation = "зоопарк", replacement = "зоопарк"},
{abbreviation = "зоопарка", replacement = "зоопарк"},
{abbreviation = "конюшня", replacement = "конюшню"},
{abbreviation = "конюшню", replacement = "конюшню"},
{abbreviation = "ферма2", replacement = "ферму"},
{abbreviation = "ферму2", replacement = "ферму"},
{abbreviation = "пасека", replacement = "пасеку"},
{abbreviation = "пасеку", replacement = "пасеку"},
{abbreviation = "ульи", replacement = "пасеку"},
{abbreviation = "пасека2", replacement = "пасеку"},
{abbreviation = "рыбхоз", replacement = "рыбхоз"},
{abbreviation = "рыбхоза", replacement = "рыбхоз"},
{abbreviation = "пруд", replacement = "пруд"},
{abbreviation = "пруда", replacement = "пруд"},
{abbreviation = "озеро2", replacement = "озеро"},
{abbreviation = "пляж2", replacement = "пляж"},
{abbreviation = "причал2", replacement = "причал"},
{abbreviation = "якорь2", replacement = "причал"},
{abbreviation = "верфь2", replacement = "верфь"},
{abbreviation = "док2", replacement = "док"},
{abbreviation = "склад2", replacement = "склад"},
{abbreviation = "склада2", replacement = "склад"},
{abbreviation = "ангар2", replacement = "ангар"},
{abbreviation = "ангара2", replacement = "ангар"},
{abbreviation = "депо", replacement = "депо"},
{abbreviation = "депоа", replacement = "депо"},
{abbreviation = "гараж2", replacement = "гараж"},
{abbreviation = "гаража2", replacement = "гараж"},
{abbreviation = "стоянка", replacement = "стоянку"},
{abbreviation = "стоянку", replacement = "стоянку"},
{abbreviation = "парковка", replacement = "парковку"},
{abbreviation = "парковку", replacement = "парковку"},
{abbreviation = "автостоянка", replacement = "автостоянку"},
{abbreviation = "автостоянку", replacement = "автостоянку"},
{abbreviation = "мойка2", replacement = "автомойку"},
{abbreviation = "мойку2", replacement = "автомойку"},
{abbreviation = "шиномонтаж2", replacement = "шиномонтаж"},
{abbreviation = "сто2", replacement = "СТО"},
{abbreviation = "техцентр2", replacement = "техцентр"},
{abbreviation = "автосервис2", replacement = "автосервис"},
{abbreviation = "ремзона", replacement = "ремзону"},
{abbreviation = "ремзону", replacement = "ремзону"},
{abbreviation = "пункт2", replacement = "пункт"},
{abbreviation = "пункта2", replacement = "пункт"},
{abbreviation = "офис", replacement = "офис"},
{abbreviation = "офиса", replacement = "офис"},
{abbreviation = "офису", replacement = "офис"},
{abbreviation = "контора", replacement = "контору"},
{abbreviation = "контору", replacement = "контору"},
{abbreviation = "конторы", replacement = "контору"},
{abbreviation = "бюро", replacement = "бюро"},
{abbreviation = "бюроа", replacement = "бюро"},
{abbreviation = "агентство", replacement = "агентство"},
{abbreviation = "агентства", replacement = "агентство"},
{abbreviation = "представительство", replacement = "представительство"},
{abbreviation = "представительства", replacement = "представительство"},
{abbreviation = "отделение", replacement = "отделение"},
{abbreviation = "отделения", replacement = "отделение"},
{abbreviation = "филиал", replacement = "филиал"},
{abbreviation = "филиала", replacement = "филиал"},
{abbreviation = "цех", replacement = "цех"},
{abbreviation = "цеха", replacement = "цех"},
{abbreviation = "лаборатория", replacement = "лабораторию"},
{abbreviation = "лабораторию", replacement = "лабораторию"},
{abbreviation = "мастерская", replacement = "мастерскую"},
{abbreviation = "мастерскую", replacement = "мастерскую"},
{abbreviation = "мастерские", replacement = "мастерскую"},
{abbreviation = "ателье", replacement = "ателье"},
{abbreviation = "ательеа", replacement = "ателье"},
{abbreviation = "студия", replacement = "студию"},
{abbreviation = "студию", replacement = "студию"},
{abbreviation = "студии", replacement = "студию"},
{abbreviation = "фотостудия", replacement = "фотостудию"},
{abbreviation = "фотостудию", replacement = "фотостудию"},
{abbreviation = "музыкальная", replacement = "музыкальную студию"},
{abbreviation = "танцевальная", replacement = "танцевальную студию"},
{abbreviation = "тренажерный", replacement = "тренажёрный зал"},
{abbreviation = "тренажёрный", replacement = "тренажёрный зал"},
{abbreviation = "спортзал2", replacement = "тренажёрный зал"},
{abbreviation = "качалка2", replacement = "тренажёрный зал"},
{abbreviation = "качалку2", replacement = "тренажёрный зал"},
{abbreviation = "фитнес", replacement = "фитнес-клуб"},
{abbreviation = "фитнеса", replacement = "фитнес-клуб"},
{abbreviation = "фитнес-клуб", replacement = "фитнес-клуб"},
{abbreviation = "фитнес-клуба", replacement = "фитнес-клуб"},
{abbreviation = "кроссфит", replacement = "кроссфит"},
{abbreviation = "йога", replacement = "йога-студию"},
{abbreviation = "йога-студию", replacement = "йога-студию"},
{abbreviation = "пилатес", replacement = "студию пилатеса"},
{abbreviation = "единоборства", replacement = "зал единоборств"},
{abbreviation = "бокс", replacement = "боксерский зал"},
{abbreviation = "боксерский", replacement = "боксерский зал"},
{abbreviation = "спорт", replacement = "спортзал"},
{abbreviation = "спорта", replacement = "спортзал"},
{abbreviation = "школа2", replacement = "школу"},
{abbreviation = "школу2", replacement = "школу"},
{abbreviation = "училище", replacement = "училище"},
{abbreviation = "училища", replacement = "училище"},
{abbreviation = "колледж", replacement = "колледж"},
{abbreviation = "колледжа", replacement = "колледж"},
{abbreviation = "университет", replacement = "университет"},
{abbreviation = "университета", replacement = "университет"},
{abbreviation = "институт", replacement = "институт"},
{abbreviation = "института", replacement = "институт"},
{abbreviation = "академия", replacement = "академию"},
{abbreviation = "академию", replacement = "академию"},
{abbreviation = "лицей2", replacement = "лицей"},
{abbreviation = "лицея", replacement = "лицей"},
{abbreviation = "детсад", replacement = "детский сад"},
{abbreviation = "детский", replacement = "детский сад"},
{abbreviation = "ясли", replacement = "ясли"},
{abbreviation = "яслей", replacement = "ясли"},
{abbreviation = "хоспис", replacement = "хоспис"},
{abbreviation = "хосписа", replacement = "хоспис"},
{abbreviation = "санаторий", replacement = "санаторий"},
{abbreviation = "санатория", replacement = "санаторий"},
{abbreviation = "пансионат", replacement = "пансионат"},
{abbreviation = "пансионата", replacement = "пансионат"},
{abbreviation = "курорт", replacement = "курорт"},
{abbreviation = "курорта", replacement = "курорт"},
{abbreviation = "турбаза", replacement = "турбазу"},
{abbreviation = "турбазу", replacement = "турбазу"},
{abbreviation = "кемпинг", replacement = "кемпинг"},
{abbreviation = "кемпинга", replacement = "кемпинг"},
{abbreviation = "мотель2", replacement = "отель"},
{abbreviation = "отель2", replacement = "отель"},
{abbreviation = "гостиница", replacement = "гостиницу"},
{abbreviation = "гостиницу", replacement = "гостиницу"},
{abbreviation = "хостел", replacement = "хостел"},
{abbreviation = "хостела", replacement = "хостел"},
{abbreviation = "общежитие", replacement = "общежитие"},
{abbreviation = "общежития", replacement = "общежитие"},
{abbreviation = "квартира2", replacement = "квартиру"},
{abbreviation = "квартиру2", replacement = "квартиру"},
{abbreviation = "студия2", replacement = "квартиру-студию"},
{abbreviation = "комната", replacement = "комнату"},
{abbreviation = "комнату", replacement = "комнату"},
{abbreviation = "комнаты", replacement = "комнату"},
{abbreviation = "койка", replacement = "койко-место"},
{abbreviation = "койку", replacement = "койко-место"},
{abbreviation = "койки", replacement = "койко-место"},
{abbreviation = "койко-место", replacement = "койко-место"},
{abbreviation = "спальня", replacement = "спальню"},
{abbreviation = "спальню", replacement = "спальню"},
{abbreviation = "гостиная", replacement = "гостиную"},
{abbreviation = "гостиную", replacement = "гостиную"},
{abbreviation = "кухня", replacement = "кухню"},
{abbreviation = "кухню", replacement = "кухню"},
{abbreviation = "ванная", replacement = "ванную"},
{abbreviation = "ванную", replacement = "ванную"},
{abbreviation = "балкон", replacement = "балкон"},
{abbreviation = "балкона", replacement = "балкон"},
{abbreviation = "терраса", replacement = "террасу"},
{abbreviation = "террасу", replacement = "террасу"},
{abbreviation = "веранда", replacement = "веранду"},
{abbreviation = "веранду", replacement = "веранду"},
{abbreviation = "беседка", replacement = "беседку"},
{abbreviation = "беседку", replacement = "беседку"},
{abbreviation = "навес2", replacement = "навес"},
{abbreviation = "тент2", replacement = "тент"},
{abbreviation = "сарай", replacement = "сарай"},
{abbreviation = "сарая", replacement = "сарай"},
{abbreviation = "амбар", replacement = "амбар"},
{abbreviation = "амбара", replacement = "амбар"},
{abbreviation = "хлев", replacement = "хлев"},
{abbreviation = "хлева", replacement = "хлев"},
{abbreviation = "курятник", replacement = "курятник"},
{abbreviation = "курятника", replacement = "курятник"},
{abbreviation = "конура", replacement = "конуру"},
{abbreviation = "конуру", replacement = "конуру"},
{abbreviation = "будка", replacement = "будку"},
{abbreviation = "будку", replacement = "будку"},
{abbreviation = "колодец", replacement = "колодец"},
{abbreviation = "колодца", replacement = "колодец"},
{abbreviation = "скважина", replacement = "скважину"},
{abbreviation = "скважину", replacement = "скважину"},
{abbreviation = "септик", replacement = "септик"},
{abbreviation = "септика", replacement = "септик"},
{abbreviation = "канализация", replacement = "канализацию"},
{abbreviation = "канализацию", replacement = "канализацию"},
{abbreviation = "электричество", replacement = "электричество"},
{abbreviation = "электричества", replacement = "электричество"},
{abbreviation = "генератор", replacement = "генератор"},
{abbreviation = "генератора", replacement = "генератор"},
{abbreviation = "солнечная", replacement = "солнечную панель"},
{abbreviation = "ветряк", replacement = "ветряк"},
{abbreviation = "ветряка", replacement = "ветряк"},
{abbreviation = "турбина", replacement = "турбину"},
{abbreviation = "турбину", replacement = "турбину"},
{abbreviation = "футболка", replacement = "футболку"},
{abbreviation = "футболку", replacement = "футболку"},
{abbreviation = "майка", replacement = "майку"},
{abbreviation = "майку", replacement = "майку"},
{abbreviation = "рубашка", replacement = "рубашку"},
{abbreviation = "рубашку", replacement = "рубашку"},
{abbreviation = "брюки", replacement = "брюки"},
{abbreviation = "брюк", replacement = "брюки"},
{abbreviation = "джинсы", replacement = "джинсы"},
{abbreviation = "джинсов", replacement = "джинсы"},
{abbreviation = "шорты", replacement = "шорты"},
{abbreviation = "шорт", replacement = "шорты"},
{abbreviation = "юбка", replacement = "юбку"},
{abbreviation = "юбку", replacement = "юбку"},
{abbreviation = "платье", replacement = "платье"},
{abbreviation = "платья", replacement = "платье"},
{abbreviation = "костюм", replacement = "костюм"},
{abbreviation = "костюма", replacement = "костюм"},
{abbreviation = "пиджак", replacement = "пиджак"},
{abbreviation = "пиджака", replacement = "пиджак"},
{abbreviation = "жилет", replacement = "жилет"},
{abbreviation = "жилета", replacement = "жилет"},
{abbreviation = "свитер", replacement = "свитер"},
{abbreviation = "свитера", replacement = "свитер"},
{abbreviation = "кофта", replacement = "кофту"},
{abbreviation = "кофту", replacement = "кофту"},
{abbreviation = "куртка", replacement = "куртку"},
{abbreviation = "куртку", replacement = "куртку"},
{abbreviation = "пальто", replacement = "пальто"},
{abbreviation = "пальтоа", replacement = "пальто"},
{abbreviation = "шуба", replacement = "шубу"},
{abbreviation = "шубу", replacement = "шубу"},
{abbreviation = "дубленка", replacement = "дубленку"},
{abbreviation = "дубленку", replacement = "дубленку"},
{abbreviation = "пуховик", replacement = "пуховик"},
{abbreviation = "пуховика", replacement = "пуховик"},
{abbreviation = "ветровка", replacement = "ветровку"},
{abbreviation = "ветровку", replacement = "ветровку"},
{abbreviation = "парка", replacement = "парку"},
{abbreviation = "парку", replacement = "парку"},
{abbreviation = "тренч", replacement = "тренч"},
{abbreviation = "тренча", replacement = "тренч"},
{abbreviation = "плащ", replacement = "плащ"},
{abbreviation = "плаща", replacement = "плащ"},
{abbreviation = "галстук", replacement = "галстук"},
{abbreviation = "галстука", replacement = "галстук"},
{abbreviation = "бабочка", replacement = "бабочку"},
{abbreviation = "бабочку", replacement = "бабочку"},
{abbreviation = "ремень", replacement = "ремень"},
{abbreviation = "ремня", replacement = "ремень"},
{abbreviation = "пояс", replacement = "пояс"},
{abbreviation = "пояса", replacement = "пояс"},
{abbreviation = "шарф", replacement = "шарф"},
{abbreviation = "шарфа", replacement = "шарф"},
{abbreviation = "перчатки", replacement = "перчатки"},
{abbreviation = "перчаток", replacement = "перчатки"},
{abbreviation = "варежки", replacement = "варежки"},
{abbreviation = "варежек", replacement = "варежки"},
{abbreviation = "носки", replacement = "носки"},
{abbreviation = "носков", replacement = "носки"},
{abbreviation = "чулки", replacement = "чулки"},
{abbreviation = "чулок", replacement = "чулки"},
{abbreviation = "колготки", replacement = "колготки"},
{abbreviation = "колготок", replacement = "колготки"},
{abbreviation = "трусы", replacement = "трусы"},
{abbreviation = "трусов", replacement = "трусы"},
{abbreviation = "бюстгальтер", replacement = "бюстгальтер"},
{abbreviation = "бра", replacement = "бюстгальтер"},
{abbreviation = "нижнее", replacement = "нижнее белье"},
{abbreviation = "белье", replacement = "нижнее белье"},
{abbreviation = "белья", replacement = "нижнее белье"},
{abbreviation = "пижама", replacement = "пижаму"},
{abbreviation = "пижаму", replacement = "пижаму"},
{abbreviation = "халат", replacement = "халат"},
{abbreviation = "халата", replacement = "халат"},
{abbreviation = "купальник", replacement = "купальник"},
{abbreviation = "купальника", replacement = "купальник"},
{abbreviation = "бикини", replacement = "бикини"},
{abbreviation = "бикиниа", replacement = "бикини"},
{abbreviation = "сланцы", replacement = "сланцы"},
{abbreviation = "сланцев", replacement = "сланцы"},
{abbreviation = "шлепанцы", replacement = "шлепанцы"},
{abbreviation = "шлепанцев", replacement = "шлепанцы"},
{abbreviation = "вьетнамки", replacement = "вьетнамки"},
{abbreviation = "вьетнамок", replacement = "вьетнамки"},
{abbreviation = "босоножки", replacement = "босоножки"},
{abbreviation = "босоножек", replacement = "босоножки"},
{abbreviation = "сандалии", replacement = "сандалии"},
{abbreviation = "сандалий", replacement = "сандалии"},
{abbreviation = "кеды", replacement = "кеды"},
{abbreviation = "кедов", replacement = "кеды"},
{abbreviation = "кроссовки", replacement = "кроссовки"},
{abbreviation = "кроссовок", replacement = "кроссовки"},
{abbreviation = "туфли", replacement = "туфли"},
{abbreviation = "туфель", replacement = "туфли"},
{abbreviation = "ботинки", replacement = "ботинки"},
{abbreviation = "ботинок", replacement = "ботинки"},
{abbreviation = "сапоги", replacement = "сапоги"},
{abbreviation = "сапог", replacement = "сапоги"},
{abbreviation = "валенки", replacement = "валенки"},
{abbreviation = "валенок", replacement = "валенки"},
{abbreviation = "угги", replacement = "угги"},
{abbreviation = "уггов", replacement = "угги"},
{abbreviation = "мокасины", replacement = "мокасины"},
{abbreviation = "мокасин", replacement = "мокасины"},
{abbreviation = "лоферы", replacement = "лоферы"},
{abbreviation = "лоферов", replacement = "лоферы"},
{abbreviation = "эспадрильи", replacement = "эспадрильи"},
{abbreviation = "эспадрилий", replacement = "эспадрильи"},
{abbreviation = "обувь", replacement = "обувь"},
{abbreviation = "обуви", replacement = "обувь"},
{abbreviation = "кросовки", replacement = "кроссовки"},
{abbreviation = "кросовок", replacement = "кроссовки"},
{abbreviation = "часы2", replacement = "аксессуар \"Часы\""},
{abbreviation = "часов2", replacement = "аксессуар \"Часы\""},
{abbreviation = "браслет", replacement = "браслет"},
{abbreviation = "браслета", replacement = "браслет"},
{abbreviation = "кольцо", replacement = "кольцо"},
{abbreviation = "кольца", replacement = "кольцо"},
{abbreviation = "серьги", replacement = "серьги"},
{abbreviation = "серег", replacement = "серьги"},
{abbreviation = "цепочка", replacement = "цепочку"},
{abbreviation = "цепочку", replacement = "цепочку"},
{abbreviation = "кулон", replacement = "кулон"},
{abbreviation = "кулона", replacement = "кулон"},
{abbreviation = "брошь", replacement = "брошь"},
{abbreviation = "броши", replacement = "брошь"},
{abbreviation = "заколка", replacement = "заколку"},
{abbreviation = "заколку", replacement = "заколку"},
{abbreviation = "обруч", replacement = "обруч"},
{abbreviation = "обруча", replacement = "обруч"},
{abbreviation = "корона", replacement = "корону"},
{abbreviation = "корону", replacement = "корону"},
{abbreviation = "диадема", replacement = "диадему"},
{abbreviation = "диадему", replacement = "диадему"},
{abbreviation = "галстук2", replacement = "галстук"},
{abbreviation = "зажим", replacement = "зажим"},
{abbreviation = "зажима", replacement = "зажим"},
{abbreviation = "портупея", replacement = "портупею"},
{abbreviation = "портупею", replacement = "портупею"},
{abbreviation = "подтяжки", replacement = "подтяжки"},
{abbreviation = "подтяжек", replacement = "подтяжки"},
{abbreviation = "телефон3", replacement = "телефон"},
{abbreviation = "смартфон2", replacement = "смартфон"},
{abbreviation = "айфон2", replacement = "смартфон"},
{abbreviation = "айфона2", replacement = "смартфон"},
{abbreviation = "самсунг", replacement = "смартфон"},
{abbreviation = "самсунга", replacement = "смартфон"},
{abbreviation = "нокиа", replacement = "смартфон"},
{abbreviation = "нокиаа", replacement = "смартфон"},
{abbreviation = "сяоми", replacement = "смартфон"},
{abbreviation = "хонор", replacement = "смартфон"},
{abbreviation = "хуавей", replacement = "смартфон"},
{abbreviation = "планшет2", replacement = "планшет"},
{abbreviation = "айпад", replacement = "планшет"},
{abbreviation = "айпада", replacement = "планшет"},
{abbreviation = "лэптоп", replacement = "ноутбук"},
{abbreviation = "лэптопа", replacement = "ноутбук"},
{abbreviation = "макбук", replacement = "ноутбук"},
{abbreviation = "макбука", replacement = "ноутбук"},
{abbreviation = "пк", replacement = "компьютер"},
{abbreviation = "пка", replacement = "компьютер"},
{abbreviation = "системник", replacement = "компьютер"},
{abbreviation = "системника", replacement = "компьютер"},
{abbreviation = "процессор", replacement = "процессор"},
{abbreviation = "процессора", replacement = "процессор"},
{abbreviation = "видеокарта", replacement = "видеокарту"},
{abbreviation = "видеокарту", replacement = "видеокарту"},
{abbreviation = "озу", replacement = "оперативную память"},
{abbreviation = "оперативная", replacement = "оперативную память"},
{abbreviation = "память", replacement = "память"},
{abbreviation = "памяти", replacement = "память"},
{abbreviation = "жесткий", replacement = "жесткий диск"},
{abbreviation = "диск", replacement = "диск"},
{abbreviation = "диска", replacement = "диск"},
{abbreviation = "ссд", replacement = "SSD накопитель"},
{abbreviation = "ссда", replacement = "SSD накопитель"},
{abbreviation = "хард", replacement = "жесткий диск"},
{abbreviation = "харда", replacement = "жесткий диск"},
{abbreviation = "флешка", replacement = "флешку"},
{abbreviation = "флешку", replacement = "флешку"},
{abbreviation = "флешки", replacement = "флешку"},
{abbreviation = "флэшка", replacement = "флешку"},
{abbreviation = "флэшку", replacement = "флешку"},
{abbreviation = "юзб", replacement = "USB-накопитель"},
{abbreviation = "юсб", replacement = "USB-накопитель"},
{abbreviation = "роутер", replacement = "роутер"},
{abbreviation = "роутера", replacement = "роутер"},
{abbreviation = "модем", replacement = "модем"},
{abbreviation = "модема", replacement = "модем"},
{abbreviation = "свитч", replacement = "коммутатор"},
{abbreviation = "хаб", replacement = "концентратор"},
{abbreviation = "патч", replacement = "патч-корд"},
{abbreviation = "кабель", replacement = "кабель"},
{abbreviation = "кабеля", replacement = "кабель"},
{abbreviation = "провод", replacement = "провод"},
{abbreviation = "провода", replacement = "провод"},
{abbreviation = "удлинитель", replacement = "удлинитель"},
{abbreviation = "удлинителя", replacement = "удлинитель"},
{abbreviation = "сетевой", replacement = "сетевой фильтр"},
{abbreviation = "блок", replacement = "блок питания"},
{abbreviation = "блока", replacement = "блок питания"},
{abbreviation = "бп", replacement = "блок питания"},
{abbreviation = "бпа", replacement = "блок питания"},
{abbreviation = "куллер", replacement = "кулер"},
{abbreviation = "кулера", replacement = "кулер"},
{abbreviation = "кулер", replacement = "кулер"},
{abbreviation = "куллеры", replacement = "кулер"},
{abbreviation = "термопаста", replacement = "термопасту"},
{abbreviation = "термопасту", replacement = "термопасту"},
{abbreviation = "материнка", replacement = "материнскую плату"},
{abbreviation = "материнскую", replacement = "материнскую плату"},
{abbreviation = "плата", replacement = "плату"},
{abbreviation = "плату", replacement = "плату"},
{abbreviation = "платы", replacement = "плату"},
{abbreviation = "звуковая", replacement = "звуковую карту"},
{abbreviation = "сетевая", replacement = "сетевую карту"},
{abbreviation = "твтюнер", replacement = "ТВ-тюнер"},
{abbreviation = "вебка", replacement = "веб-камеру"},
{abbreviation = "веб-камеру", replacement = "веб-камеру"},
{abbreviation = "веб-камера", replacement = "веб-камеру"},
{abbreviation = "вебкамера", replacement = "веб-камеру"},
{abbreviation = "телевизор", replacement = "телевизор"},
{abbreviation = "телевизора", replacement = "телевизор"},
{abbreviation = "тв", replacement = "телевизор"},
{abbreviation = "тва", replacement = "телевизор"},
{abbreviation = "яндекств", replacement = "телевизор"},
{abbreviation = "смарттв", replacement = "телевизор"},
{abbreviation = "холодильник", replacement = "холодильник"},
{abbreviation = "холодильника", replacement = "холодильник"},
{abbreviation = "морозилка", replacement = "морозилку"},
{abbreviation = "морозилку", replacement = "морозилку"},
{abbreviation = "стиралка", replacement = "стиральную машину"},
{abbreviation = "стиральная", replacement = "стиральную машину"},
{abbreviation = "стиральную", replacement = "стиральную машину"},
{abbreviation = "посудомойка", replacement = "посудомойку"},
{abbreviation = "посудомойку", replacement = "посудомойку"},
{abbreviation = "посудомоечная", replacement = "посудомойку"},
{abbreviation = "печь", replacement = "печь"},
{abbreviation = "печи", replacement = "печь"},
{abbreviation = "духовка", replacement = "духовку"},
{abbreviation = "духовку", replacement = "духовку"},
{abbreviation = "плита", replacement = "плиту"},
{abbreviation = "плиту", replacement = "плиту"},
{abbreviation = "варочная", replacement = "варочную панель"},
{abbreviation = "микроволновка", replacement = "микроволновку"},
{abbreviation = "микроволновку", replacement = "микроволновку"},
{abbreviation = "микроволновая", replacement = "микроволновку"},
{abbreviation = "миксер", replacement = "миксер"},
{abbreviation = "миксера", replacement = "миксер"},
{abbreviation = "блендер", replacement = "блендер"},
{abbreviation = "блендера", replacement = "блендер"},
{abbreviation = "комбайн", replacement = "кухонный комбайн"},
{abbreviation = "тостер", replacement = "тостер"},
{abbreviation = "тостера", replacement = "тостер"},
{abbreviation = "кофеварка", replacement = "кофеварку"},
{abbreviation = "кофеварку", replacement = "кофеварку"},
{abbreviation = "кофемашина", replacement = "кофемашину"},
{abbreviation = "кофемашину", replacement = "кофемашину"},
{abbreviation = "чайник", replacement = "чайник"},
{abbreviation = "чайника", replacement = "чайник"},
{abbreviation = "кипятильник", replacement = "кипятильник"},
{abbreviation = "термос2", replacement = "термос"},
{abbreviation = "термоса2", replacement = "термос"},
{abbreviation = "пылесос", replacement = "пылесос"},
{abbreviation = "пылесоса", replacement = "пылесос"},
{abbreviation = "робот", replacement = "робот-пылесос"},
{abbreviation = "робота", replacement = "робот-пылесос"},
{abbreviation = "швабра", replacement = "швабру"},
{abbreviation = "швабру", replacement = "швабру"},
{abbreviation = "ведро", replacement = "ведро"},
{abbreviation = "ведра", replacement = "ведро"},
{abbreviation = "щетка", replacement = "щетку"},
{abbreviation = "щетку", replacement = "щетку"},
{abbreviation = "совок", replacement = "совок"},
{abbreviation = "совка", replacement = "совок"},
{abbreviation = "утюг", replacement = "утюг"},
{abbreviation = "утюга", replacement = "утюг"},
{abbreviation = "парогенератор", replacement = "парогенератор"},
{abbreviation = "парогенератора", replacement = "парогенератор"},
{abbreviation = "кондиционер", replacement = "кондиционер"},
{abbreviation = "кондиционера", replacement = "кондиционер"},
{abbreviation = "обогреватель", replacement = "обогреватель"},
{abbreviation = "обогревателя", replacement = "обогреватель"},
{abbreviation = "радиатор", replacement = "радиатор"},
{abbreviation = "радиатора", replacement = "радиатор"},
{abbreviation = "батарея", replacement = "батарею"},
{abbreviation = "батарею", replacement = "батарею"},
{abbreviation = "камин", replacement = "камин"},
{abbreviation = "камина", replacement = "камин"},
{abbreviation = "печка", replacement = "печку"},
{abbreviation = "печку", replacement = "печку"},
{abbreviation = "буржуйка", replacement = "буржуйку"},
{abbreviation = "буржуйку", replacement = "буржуйку"},
{abbreviation = "люстра", replacement = "люстру"},
{abbreviation = "люстру", replacement = "люстру"},
{abbreviation = "лампа", replacement = "лампу"},
{abbreviation = "лампу", replacement = "лампу"},
{abbreviation = "лампы", replacement = "лампу"},
{abbreviation = "торшер", replacement = "торшер"},
{abbreviation = "торшера", replacement = "торшер"},
{abbreviation = "бра2", replacement = "светильник"},
{abbreviation = "светильник", replacement = "светильник"},
{abbreviation = "светильника", replacement = "светильник"},
{abbreviation = "фонарь", replacement = "фонарь"},
{abbreviation = "фонаря", replacement = "фонарь"},
{abbreviation = "прожектор", replacement = "прожектор"},
{abbreviation = "прожектора", replacement = "прожектор"},
{abbreviation = "гирлянда", replacement = "гирлянду"},
{abbreviation = "гирлянду", replacement = "гирлянду"},
{abbreviation = "диско", replacement = "диско-шар"},
{abbreviation = "шар2", replacement = "диско-шар"},
{abbreviation = "диван", replacement = "диван"},
{abbreviation = "дивана", replacement = "диван"},
{abbreviation = "кресло", replacement = "кресло"},
{abbreviation = "кресла", replacement = "кресло"},
{abbreviation = "стул", replacement = "стул"},
{abbreviation = "стула", replacement = "стул"},
{abbreviation = "стулья", replacement = "стулья"},
{abbreviation = "стульев", replacement = "стулья"},
{abbreviation = "табурет", replacement = "табурет"},
{abbreviation = "табурета", replacement = "табурет"},
{abbreviation = "табуретка", replacement = "табуретку"},
{abbreviation = "табуретку", replacement = "табуретку"},
{abbreviation = "стол", replacement = "стол"},
{abbreviation = "стола", replacement = "стол"},
{abbreviation = "столы", replacement = "столы"},
{abbreviation = "столов", replacement = "столы"},
{abbreviation = "журнальный", replacement = "журнальный столик"},
{abbreviation = "столик", replacement = "столик"},
{abbreviation = "столика", replacement = "столик"},
{abbreviation = "тумба", replacement = "тумбу"},
{abbreviation = "тумбу", replacement = "тумбу"},
{abbreviation = "тумбы", replacement = "тумбу"},
{abbreviation = "комод", replacement = "комод"},
{abbreviation = "комода", replacement = "комод"},
{abbreviation = "шкаф", replacement = "шкаф"},
{abbreviation = "шкафа", replacement = "шкаф"},
{abbreviation = "шкафы", replacement = "шкафы"},
{abbreviation = "шкафов", replacement = "шкафы"},
{abbreviation = "гардероб", replacement = "гардероб"},
{abbreviation = "гардероба", replacement = "гардероб"},
{abbreviation = "вешалка", replacement = "вешалку"},
{abbreviation = "вешалку", replacement = "вешалку"},
{abbreviation = "полка", replacement = "полку"},
{abbreviation = "полку", replacement = "полку"},
{abbreviation = "полки", replacement = "полку"},
{abbreviation = "стеллаж", replacement = "стеллаж"},
{abbreviation = "стеллажа", replacement = "стеллаж"},
{abbreviation = "этажерка", replacement = "этажерку"},
{abbreviation = "этажерку", replacement = "этажерку"},
{abbreviation = "кровать", replacement = "кровать"},
{abbreviation = "кровати", replacement = "кровать"},
{abbreviation = "кроватей", replacement = "кровать"},
{abbreviation = "матрас", replacement = "матрас"},
{abbreviation = "матраса", replacement = "матрас"},
{abbreviation = "матрац", replacement = "матрас"},
{abbreviation = "матраца", replacement = "матрас"},
{abbreviation = "подушка", replacement = "подушку"},
{abbreviation = "подушку", replacement = "подушку"},
{abbreviation = "подушки", replacement = "подушку"},
{abbreviation = "одеяло", replacement = "одеяло"},
{abbreviation = "одеяла", replacement = "одеяло"},
{abbreviation = "плед", replacement = "плед"},
{abbreviation = "пледа", replacement = "плед"},
{abbreviation = "покрывало", replacement = "покрывало"},
{abbreviation = "покрывала", replacement = "покрывало"},
{abbreviation = "простыня", replacement = "простыню"},
{abbreviation = "простыню", replacement = "простыню"},
{abbreviation = "пододеяльник", replacement = "пододеяльник"},
{abbreviation = "пододеяльника", replacement = "пододеяльник"},
{abbreviation = "наволочка", replacement = "наволочку"},
{abbreviation = "наволочку", replacement = "наволочку"},
{abbreviation = "зеркало", replacement = "зеркало"},
{abbreviation = "зеркала", replacement = "зеркало"},
{abbreviation = "картина", replacement = "картину"},
{abbreviation = "картину", replacement = "картину"},
{abbreviation = "постер", replacement = "постер"},
{abbreviation = "постера", replacement = "постер"},
{abbreviation = "ковер", replacement = "ковер"},
{abbreviation = "ковра", replacement = "ковер"},
{abbreviation = "ковры", replacement = "ковры"},
{abbreviation = "ковров", replacement = "ковры"},
{abbreviation = "палас", replacement = "палас"},
{abbreviation = "паласа", replacement = "палас"},
{abbreviation = "дорожка", replacement = "дорожку"},
{abbreviation = "дорожку", replacement = "дорожку"},
{abbreviation = "циновка", replacement = "циновку"},
{abbreviation = "циновку", replacement = "циновку"},
{abbreviation = "штора", replacement = "штору"},
{abbreviation = "штору", replacement = "штору"},
{abbreviation = "шторы", replacement = "шторы"},
{abbreviation = "штор", replacement = "шторы"},
{abbreviation = "жалюзи", replacement = "жалюзи"},
{abbreviation = "жалюзиа", replacement = "жалюзи"},
{abbreviation = "карниз", replacement = "карниз"},
{abbreviation = "карниза", replacement = "карниз"},
{abbreviation = "подушка2", replacement = "подушку"},
{abbreviation = "декор", replacement = "декор"},
{abbreviation = "декора", replacement = "декор"},
{abbreviation = "сувенир", replacement = "сувенир"},
{abbreviation = "сувенира", replacement = "сувенир"},
{abbreviation = "статуэтка", replacement = "статуэтку"},
{abbreviation = "статуэтку", replacement = "статуэтку"},
{abbreviation = "ваза", replacement = "вазу"},
{abbreviation = "вазу", replacement = "вазу"},
{abbreviation = "вазы", replacement = "вазу"},
{abbreviation = "горшок", replacement = "горшок"},
{abbreviation = "горшка", replacement = "горшок"},
{abbreviation = "вазон", replacement = "вазон"},
{abbreviation = "вазона", replacement = "вазон"},
{abbreviation = "цветок", replacement = "цветок"},
{abbreviation = "цветка", replacement = "цветок"},
{abbreviation = "растение", replacement = "растение"},
{abbreviation = "растения", replacement = "растение"},
{abbreviation = "букет", replacement = "букет"},
{abbreviation = "букета", replacement = "букет"},
{abbreviation = "медикаменты", replacement = "медикаменты"},
{abbreviation = "лекарства", replacement = "лекарства"},
{abbreviation = "лекарств", replacement = "лекарства"},
{abbreviation = "таблетки", replacement = "таблетки"},
{abbreviation = "таблеток", replacement = "таблетки"},
{abbreviation = "антибиотик", replacement = "антибиотик"},
{abbreviation = "антибиотика", replacement = "антибиотик"},
{abbreviation = "витамины", replacement = "витамины"},
{abbreviation = "витаминов", replacement = "витамины"},
{abbreviation = "анальгин", replacement = "анальгин"},
{abbreviation = "анальгина", replacement = "анальгин"},
{abbreviation = "аспирин", replacement = "аспирин"},
{abbreviation = "аспирина", replacement = "аспирин"},
{abbreviation = "ношпа", replacement = "ношпу"},
{abbreviation = "ношпу", replacement = "ношпу"},
{abbreviation = "активированный", replacement = "активированный уголь"},
{abbreviation = "уголь", replacement = "активированный уголь"},
{abbreviation = "угля", replacement = "активированный уголь"},
{abbreviation = "йод", replacement = "йод"},
{abbreviation = "йода", replacement = "йод"},
{abbreviation = "зеленка", replacement = "зеленку"},
{abbreviation = "зеленку", replacement = "зеленку"},
{abbreviation = "перекись", replacement = "перекись"},
{abbreviation = "перекиси", replacement = "перекись"},
{abbreviation = "пластырь", replacement = "пластырь"},
{abbreviation = "пластыря", replacement = "пластырь"},
{abbreviation = "бинт", replacement = "бинт"},
{abbreviation = "бинта", replacement = "бинт"},
{abbreviation = "марля", replacement = "марлю"},
{abbreviation = "марлю", replacement = "марлю"},
{abbreviation = "шприц", replacement = "шприц"},
{abbreviation = "шприца", replacement = "шприц"},
{abbreviation = "мазь", replacement = "мазь"},
{abbreviation = "мази", replacement = "мазь"},
{abbreviation = "крем", replacement = "крем"},
{abbreviation = "крема", replacement = "крем"},
{abbreviation = "гель", replacement = "гель"},
{abbreviation = "геля", replacement = "гель"},
{abbreviation = "спрей", replacement = "спрей"},
{abbreviation = "спрея", replacement = "спрей"},
{abbreviation = "молоток", replacement = "молоток"},
{abbreviation = "молотка", replacement = "молоток"},
{abbreviation = "отвертка", replacement = "отвертку"},
{abbreviation = "отвертку", replacement = "отвертку"},
{abbreviation = "плоскогубцы", replacement = "плоскогубцы"},
{abbreviation = "пассатижи", replacement = "пассатижи"},
{abbreviation = "кусачки", replacement = "кусачки"},
{abbreviation = "ключ2", replacement = "ключ"},
{abbreviation = "гаечный", replacement = "гаечный ключ"},
{abbreviation = "торцевой", replacement = "торцевой ключ"},
{abbreviation = "разводной", replacement = "разводной ключ"},
{abbreviation = "трещотка2", replacement = "трещотку"},
{abbreviation = "трещотку", replacement = "трещотку"},
{abbreviation = "пила", replacement = "пилу"},
{abbreviation = "пилу", replacement = "пилу"},
{abbreviation = "ножовка", replacement = "ножовку"},
{abbreviation = "ножовку", replacement = "ножовку"},
{abbreviation = "болгарка", replacement = "болгарку"},
{abbreviation = "болгарку", replacement = "болгарку"},
{abbreviation = "дрель", replacement = "дрель"},
{abbreviation = "дрели", replacement = "дрель"},
{abbreviation = "шуруповерт", replacement = "шуруповерт"},
{abbreviation = "шуруповерта", replacement = "шуруповерт"},
{abbreviation = "перфоратор", replacement = "перфоратор"},
{abbreviation = "перфоратора", replacement = "перфоратор"},
{abbreviation = "гвоздодер", replacement = "гвоздодер"},
{abbreviation = "лом", replacement = "лом"},
{abbreviation = "лома", replacement = "лом"},
{abbreviation = "топор", replacement = "топор"},
{abbreviation = "топора", replacement = "топор"},
{abbreviation = "колун", replacement = "колун"},
{abbreviation = "колуна", replacement = "колун"},
{abbreviation = "кувалда", replacement = "кувалду"},
{abbreviation = "кувалду", replacement = "кувалду"},
{abbreviation = "зубило", replacement = "зубило"},
{abbreviation = "зубила", replacement = "зубило"},
{abbreviation = "напильник", replacement = "напильник"},
{abbreviation = "напильника", replacement = "напильник"},
{abbreviation = "наждачка", replacement = "наждачку"},
{abbreviation = "наждачку", replacement = "наждачку"},
{abbreviation = "рулетка2", replacement = "рулетку"},
{abbreviation = "рулетку2", replacement = "рулетку"},
{abbreviation = "уровень", replacement = "уровень"},
{abbreviation = "уровня", replacement = "уровень"},
{abbreviation = "отвес", replacement = "отвес"},
{abbreviation = "отвеса", replacement = "отвес"},
{abbreviation = "угольник", replacement = "угольник"},
{abbreviation = "угольника", replacement = "угольник"},
{abbreviation = "штангенциркуль", replacement = "штангенциркуль"},
{abbreviation = "микрометр", replacement = "микрометр"},
{abbreviation = "лестница", replacement = "лестницу"},
{abbreviation = "лестницу", replacement = "лестницу"},
{abbreviation = "стремянка", replacement = "стремянку"},
{abbreviation = "стремянку", replacement = "стремянку"},
{abbreviation = "тали", replacement = "таль"},
{abbreviation = "таль", replacement = "таль"},
{abbreviation = "домкрат", replacement = "домкрат"},
{abbreviation = "домкрата", replacement = "домкрат"},
{abbreviation = "тиски", replacement = "тиски"},
{abbreviation = "тисков", replacement = "тиски"},
{abbreviation = "наковальня", replacement = "наковальню"},
{abbreviation = "наковальню", replacement = "наковальню"},
{abbreviation = "горн", replacement = "горн"},
{abbreviation = "горна", replacement = "горн"},
{abbreviation = "паяльник", replacement = "паяльник"},
{abbreviation = "паяльника", replacement = "паяльник"},
{abbreviation = "тестер", replacement = "мультиметр"},
{abbreviation = "мультиметр", replacement = "мультиметр"},
{abbreviation = "мультиметра", replacement = "мультиметр"},
{abbreviation = "осциллограф", replacement = "осциллограф"},
{abbreviation = "гвозди", replacement = "гвозди"},
{abbreviation = "гвоздей", replacement = "гвозди"},
{abbreviation = "шурупы", replacement = "шурупы"},
{abbreviation = "шурупов", replacement = "шурупы"},
{abbreviation = "саморезы", replacement = "саморезы"},
{abbreviation = "саморезов", replacement = "саморезы"},
{abbreviation = "болты", replacement = "болты"},
{abbreviation = "болтов", replacement = "болты"},
{abbreviation = "гайки", replacement = "гайки"},
{abbreviation = "гаек", replacement = "гайки"},
{abbreviation = "шайбы", replacement = "шайбы"},
{abbreviation = "шайб", replacement = "шайбы"},
{abbreviation = "гровер", replacement = "гровер"},
{abbreviation = "гровера", replacement = "гровер"},
{abbreviation = "анкер", replacement = "анкер"},
{abbreviation = "анкера", replacement = "анкер"},
{abbreviation = "дюбель", replacement = "дюбель"},
{abbreviation = "дюбеля", replacement = "дюбель"},
{abbreviation = "заклепка", replacement = "заклепку"},
{abbreviation = "заклепку", replacement = "заклепку"},
{abbreviation = "проволока", replacement = "проволоку"},
{abbreviation = "проволоку", replacement = "проволоку"},
{abbreviation = "веревка", replacement = "веревку"},
{abbreviation = "веревку", replacement = "веревку"},
{abbreviation = "шнур", replacement = "шнур"},
{abbreviation = "шнура", replacement = "шнур"},
{abbreviation = "цепь3", replacement = "цепь"},
{abbreviation = "цепи3", replacement = "цепь"},
{abbreviation = "трос", replacement = "трос"},
{abbreviation = "троса", replacement = "трос"},
{abbreviation = "лента", replacement = "ленту"},
{abbreviation = "ленту", replacement = "ленту"},
{abbreviation = "скотч", replacement = "скотч"},
{abbreviation = "скотча", replacement = "скотч"},
{abbreviation = "изолента", replacement = "изоленту"},
{abbreviation = "изоленту", replacement = "изоленту"},
{abbreviation = "герметик", replacement = "герметик"},
{abbreviation = "герметика", replacement = "герметик"},
{abbreviation = "клей", replacement = "клей"},
{abbreviation = "клея", replacement = "клей"},
{abbreviation = "цемент", replacement = "цемент"},
{abbreviation = "цемента", replacement = "цемент"},
{abbreviation = "бетон", replacement = "бетон"},
{abbreviation = "бетона", replacement = "бетон"},
{abbreviation = "кирпич", replacement = "кирпич"},
{abbreviation = "кирпича", replacement = "кирпич"},
{abbreviation = "блок", replacement = "блок"},
{abbreviation = "блока2", replacement = "блок"},
{abbreviation = "плита2", replacement = "плиту"},
{abbreviation = "панель", replacement = "панель"},
{abbreviation = "панели", replacement = "панель"},
{abbreviation = "гипс", replacement = "гипс"},
{abbreviation = "гипса", replacement = "гипс"},
{abbreviation = "штукатурка", replacement = "штукатурку"},
{abbreviation = "штукатурку", replacement = "штукатурку"},
{abbreviation = "шпатлевка", replacement = "шпатлевку"},
{abbreviation = "шпатлевку", replacement = "шпатлевку"},
{abbreviation = "грунтовка", replacement = "грунтовку"},
{abbreviation = "грунтовку", replacement = "грунтовку"},
{abbreviation = "краска", replacement = "краску"},
{abbreviation = "краску", replacement = "краску"},
{abbreviation = "краски2", replacement = "краску"},
{abbreviation = "эмаль", replacement = "эмаль"},
{abbreviation = "эмали", replacement = "эмаль"},
{abbreviation = "лак", replacement = "лак"},
{abbreviation = "лака", replacement = "лак"},
{abbreviation = "морилка", replacement = "морилку"},
{abbreviation = "морилку", replacement = "морилку"},
{abbreviation = "антисептик", replacement = "антисептик"},
{abbreviation = "антисептика", replacement = "антисептик"},
{abbreviation = "пена", replacement = "монтажную пену"},
{abbreviation = "монтажная", replacement = "монтажную пену"},
{abbreviation = "монтажную", replacement = "монтажную пену"},
{abbreviation = "пену", replacement = "монтажную пену"},
{abbreviation = "утеплитель", replacement = "утеплитель"},
{abbreviation = "утеплителя", replacement = "утеплитель"},
{abbreviation = "изоляция", replacement = "изоляцию"},
{abbreviation = "изоляцию", replacement = "изоляцию"},
{abbreviation = "пленка", replacement = "пленку"},
{abbreviation = "пленку", replacement = "пленку"},
{abbreviation = "рубероид", replacement = "рубероид"},
{abbreviation = "рубероида", replacement = "рубероид"},
{abbreviation = "шифер", replacement = "шифер"},
{abbreviation = "шифера", replacement = "шифер"},
{abbreviation = "черепица", replacement = "черепицу"},
{abbreviation = "черепицу", replacement = "черепицу"},
{abbreviation = "металлочерепица", replacement = "металлочерепицу"},
{abbreviation = "профнастил", replacement = "профнастил"},
{abbreviation = "сайдинг", replacement = "сайдинг"},
{abbreviation = "сайдинга", replacement = "сайдинг"},
{abbreviation = "вагонка", replacement = "вагонку"},
{abbreviation = "вагонку", replacement = "вагонку"},
{abbreviation = "доска", replacement = "доску"},
{abbreviation = "доску", replacement = "доску"},
{abbreviation = "брус", replacement = "брус"},
{abbreviation = "бруса", replacement = "брус"},
{abbreviation = "бревно", replacement = "бревно"},
{abbreviation = "бревна", replacement = "бревно"},
{abbreviation = "фанера", replacement = "фанеру"},
{abbreviation = "фанеру", replacement = "фанеру"},
{abbreviation = "дсп", replacement = "ДСП"},
{abbreviation = "двп", replacement = "ДВП"},
{abbreviation = "мдф", replacement = "МДФ"},
{abbreviation = "осб", replacement = "ОСБ"},
{abbreviation = "оргалит", replacement = "оргалит"},
{abbreviation = "оргалита", replacement = "оргалит"},
{abbreviation = "стекло", replacement = "стекло"},
{abbreviation = "стекла", replacement = "стекло"},
{abbreviation = "зеркало2", replacement = "зеркало"},
{abbreviation = "пластик", replacement = "пластик"},
{abbreviation = "пластика", replacement = "пластик"},
{abbreviation = "металл", replacement = "металл"},
{abbreviation = "металла", replacement = "металл"},
{abbreviation = "алюминий", replacement = "алюминий"},
{abbreviation = "алюминия", replacement = "алюминий"},
{abbreviation = "медь", replacement = "медь"},
{abbreviation = "меди", replacement = "медь"},
{abbreviation = "латунь", replacement = "латунь"},
{abbreviation = "латуни", replacement = "латунь"},
{abbreviation = "бронза", replacement = "бронзу"},
{abbreviation = "бронзу", replacement = "бронзу"},
{abbreviation = "чугун", replacement = "чугун"},
{abbreviation = "чугуна", replacement = "чугун"},
{abbreviation = "сталь", replacement = "сталь"},
{abbreviation = "стали", replacement = "сталь"},
{abbreviation = "железо", replacement = "железо"},
{abbreviation = "железа", replacement = "железо"},
{abbreviation = "свинец", replacement = "свинец"},
{abbreviation = "свинца", replacement = "свинец"},
{abbreviation = "оцинковка", replacement = "оцинковку"},
{abbreviation = "оцинковку", replacement = "оцинковку"},
{abbreviation = "24/7", replacement = "магазин \"24/7\""},
{abbreviation = "24-7", replacement = "магазин \"24/7\""},
{abbreviation = "247", replacement = "магазин \"24/7\""},
{abbreviation = "круглосуточный", replacement = "магазин \"24/7\""},
{abbreviation = "круглосуточного", replacement = "магазин \"24/7\""},
{abbreviation = "кругосут", replacement = "магазин \"24/7\""},
{abbreviation = "св", replacement = "а/м марки \"Sultan\" FT"},
{abbreviation = "закуп", replacement = "закупка"},
{abbreviation = "закупка", replacement = "закупка"},
{abbreviation = "закупки", replacement = "закупка"},
{abbreviation = "закупаю", replacement = "закупаю"},
{abbreviation = "закупаешь", replacement = "закупаешь"},
{abbreviation = "скупаю", replacement = "скупаю"},
{abbreviation = "скупка", replacement = "скупка"},
{abbreviation = "скупки", replacement = "скупка"},
{abbreviation = "скупаю", replacement = "скупаю"},
{abbreviation = "принимаю", replacement = "принимаю заказы"},
{abbreviation = "заказы", replacement = "заказы"},
{abbreviation = "заказов", replacement = "заказы"},
{abbreviation = "на заказ", replacement = "на заказ"},
{abbreviation = "под заказ", replacement = "под заказ"},
{abbreviation = "рп", replacement = "RP"},
{abbreviation = "рпа", replacement = "RP"},
{abbreviation = "дрп", replacement = "DRP"},
{abbreviation = "арп", replacement = "ARP"},
{abbreviation = "адванс", replacement = "Advance RP"},
{abbreviation = "адванса", replacement = "Advance RP"},
{abbreviation = "пр", replacement = "PRO"},
{abbreviation = "нонрп", replacement = "non-RP"},
{abbreviation = "нонрп", replacement = "non-RP"},
{abbreviation = "мг", replacement = "MG"},
{abbreviation = "мгш", replacement = "MG"},
{abbreviation = "дм", replacement = "DM"},
{abbreviation = "дмш", replacement = "DM"},
{abbreviation = "тк", replacement = "TK"},
{abbreviation = "ск", replacement = "SK"},
{abbreviation = "пг", replacement = "PG"},
{abbreviation = "рк", replacement = "RK"},
{abbreviation = "автошкола", replacement = "автошколу"},
{abbreviation = "автошколу", replacement = "автошколу"},
{abbreviation = "школа вождения", replacement = "автошколу"},
{abbreviation = "страйкбол", replacement = "страйкбольный клуб"},
{abbreviation = "пейнтбол", replacement = "пейнтбольный клуб"},
{abbreviation = "лазертаг", replacement = "лазертаг"},
{abbreviation = "квест", replacement = "квест-комнату"},
{abbreviation = "квесты", replacement = "квест-комнаты"},
{abbreviation = "квестов", replacement = "квест-комнаты"},
{abbreviation = "квестовая", replacement = "квест-комнату"},
{abbreviation = "комната", replacement = "комнату"},
{abbreviation = "комнату", replacement = "комнату"},
{abbreviation = "комнаты", replacement = "комнату"},
{abbreviation = "квартира3", replacement = "квартиру"},
{abbreviation = "апартаменты", replacement = "апартаменты"},
{abbreviation = "апартаментов", replacement = "апартаменты"},
{abbreviation = "пентхаус", replacement = "пентхаус"},
{abbreviation = "пентхауса", replacement = "пентхаус"},
{abbreviation = "лофт", replacement = "лофт"},
{abbreviation = "лофта", replacement = "лофт"},
{abbreviation = "студия3", replacement = "студию"},
{abbreviation = "резиденция", replacement = "резиденцию"},
{abbreviation = "резиденцию", replacement = "резиденцию"},
{abbreviation = "поместье", replacement = "поместье"},
{abbreviation = "поместья", replacement = "поместье"},
{abbreviation = "усадьба", replacement = "усадьбу"},
{abbreviation = "усадьбу", replacement = "усадьбу"},
{abbreviation = "дворец", replacement = "дворец"},
{abbreviation = "дворца", replacement = "дворец"},
{abbreviation = "тазик", replacement = "а/м"},
{abbreviation = "тазика", replacement = "а/м"},
{abbreviation = "коробка", replacement = "а/м"},
{abbreviation = "коробку", replacement = "а/м"},
{abbreviation = "ведро", replacement = "а/м"},
{abbreviation = "ведра", replacement = "а/м"},
{abbreviation = "корыто", replacement = "а/м"},
{abbreviation = "корыта", replacement = "а/м"},
{abbreviation = "селедка", replacement = "а/м"},
{abbreviation = "селедку", replacement = "а/м"},
{abbreviation = "бричка", replacement = "а/м"},
{abbreviation = "бричку", replacement = "а/м"},
{abbreviation = "колымага", replacement = "а/м"},
{abbreviation = "колымагу", replacement = "а/м"},
{abbreviation = "драндулет", replacement = "а/м"},
{abbreviation = "драндулета", replacement = "а/м"},
{abbreviation = "конфетка", replacement = "а/м"},
{abbreviation = "конфетку", replacement = "а/м"},
{abbreviation = "пушка", replacement = "а/м"},
{abbreviation = "пушку", replacement = "а/м"},
{abbreviation = "ласточка", replacement = "а/м"},
{abbreviation = "ласточку", replacement = "а/м"},
{abbreviation = "рублей", replacement = "рублей"},
{abbreviation = "рубля", replacement = "рублей"},
{abbreviation = "баксов", replacement = "$"},
{abbreviation = "бакса", replacement = "$"},
{abbreviation = "зеленых", replacement = "$"},
{abbreviation = "зеленых2", replacement = "$"},
{abbreviation = "тугриков", replacement = "$"},
{abbreviation = "монет", replacement = "$"},
{abbreviation = "кредитов", replacement = "$"},
{abbreviation = "денег", replacement = "денег"},
{abbreviation = "бюджет", replacement = "бюджет"},
{abbreviation = "бюджета", replacement = "бюджет"},
{abbreviation = "бюджет2", replacement = "бюджет"},
{abbreviation = "сумма", replacement = "сумма"},
{abbreviation = "суммы", replacement = "сумма"},
{abbreviation = "стоимость", replacement = "стоимость"},
{abbreviation = "стоимости", replacement = "стоимость"},
{abbreviation = "прайс", replacement = "прайс"},
{abbreviation = "прайса", replacement = "прайс"},
{abbreviation = "расценки", replacement = "расценки"},
{abbreviation = "расценок", replacement = "расценки"},
{abbreviation = "тариф", replacement = "тариф"},
{abbreviation = "тарифа", replacement = "тариф"},
{abbreviation = "тарифы", replacement = "тарифы"},
{abbreviation = "тарифов", replacement = "тарифы"},
{abbreviation = "срочно", replacement = "срочно"},
{abbreviation = "срочная", replacement = "срочная"},
{abbreviation = "срочную", replacement = "срочную"},
{abbreviation = "срочное", replacement = "срочное"},
{abbreviation = "быстро", replacement = "быстро"},
{abbreviation = "недорого2", replacement = "по доступной цене"},
{abbreviation = "выгодно", replacement = "выгодно"},
{abbreviation = "дешево2", replacement = "по низкой цене"},
{abbreviation = "дёшево2", replacement = "по низкой цене"},
{abbreviation = "оптом", replacement = "оптом"},
{abbreviation = "в розницу", replacement = "в розницу"},
{abbreviation = "розницу", replacement = "в розницу"},
{abbreviation = "в наличии", replacement = "в наличии"},
{abbreviation = "наличии", replacement = "в наличии"},
{abbreviation = "под заказ2", replacement = "под заказ"},
{abbreviation = "предзаказ", replacement = "предзаказ"},
{abbreviation = "предзаказа", replacement = "предзаказ"},
{abbreviation = "резерв", replacement = "резерв"},
{abbreviation = "резерва", replacement = "резерв"},
{abbreviation = "бронь", replacement = "бронь"},
{abbreviation = "брони", replacement = "бронь"},
{abbreviation = "брони2", replacement = "бронь"},
{abbreviation = "участок2", replacement = "участок"},
{abbreviation = "участка2", replacement = "участок"},
{abbreviation = "надел", replacement = "надел"},
{abbreviation = "надела", replacement = "надел"},
{abbreviation = "паевой", replacement = "паевой взнос"},
{abbreviation = "пай", replacement = "пай"},
{abbreviation = "пая", replacement = "пай"},
{abbreviation = "доля", replacement = "долю"},
{abbreviation = "долю", replacement = "долю"},
{abbreviation = "доли", replacement = "долю"},
{abbreviation = "часть", replacement = "часть"},
{abbreviation = "части", replacement = "часть"},
{abbreviation = "акция", replacement = "акцию"},
{abbreviation = "акцию", replacement = "акцию"},
{abbreviation = "акции", replacement = "акцию"},
{abbreviation = "акций", replacement = "акции"},
{abbreviation = "дивиденды", replacement = "дивиденды"},
{abbreviation = "дивидендов", replacement = "дивиденды"},
{abbreviation = "бизнес2", replacement = "бизнес"},
{abbreviation = "доля2", replacement = "долю в бизнесе"},
{abbreviation = "франшиза", replacement = "франшизу"},
{abbreviation = "франшизу", replacement = "франшизу"},
{abbreviation = "франшизы", replacement = "франшизу"},
{abbreviation = "лицензия2", replacement = "лицензию"},
{abbreviation = "разрешение", replacement = "разрешение"},
{abbreviation = "разрешения", replacement = "разрешение"},
{abbreviation = "патент", replacement = "патент"},
{abbreviation = "патента", replacement = "патент"},
{abbreviation = "сертификат2", replacement = "сертификат"},
{abbreviation = "свидетельство", replacement = "свидетельство"},
{abbreviation = "свидетельства", replacement = "свидетельство"},
{abbreviation = "договор2", replacement = "договор"},
{abbreviation = "договора2", replacement = "договор"},
{abbreviation = "контракт", replacement = "контракт"},
{abbreviation = "контракта", replacement = "контракт"},
{abbreviation = "аренда", replacement = "аренду"},
{abbreviation = "аренду", replacement = "аренду"},
{abbreviation = "аренды", replacement = "аренду"},
{abbreviation = "сдаю", replacement = "сдаю"},
{abbreviation = "сдается", replacement = "сдается"},
{abbreviation = "сниму", replacement = "сниму"},
{abbreviation = "ищу2", replacement = "ищу"},
{abbreviation = "предлагаю", replacement = "предлагаю"},
{abbreviation = "предлагаем", replacement = "предлагаем"},
{abbreviation = "распродаю", replacement = "распродаю"},
{abbreviation = "распродажа", replacement = "распродажа"},
{abbreviation = "распродажи", replacement = "распродажа"},
{abbreviation = "ликвидация", replacement = "ликвидация"},
{abbreviation = "ликвидации", replacement = "ликвидация"},
{abbreviation = "закрытие", replacement = "закрытие"},
{abbreviation = "закрытия", replacement = "закрытие"},
{abbreviation = "переезд", replacement = "переезд"},
{abbreviation = "переезда", replacement = "переезд"},
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
local turbo_cruise_enabled = imgui.new.bool(false)
local cruise_active = false

-- Горячие клавиши на команды
-- key: VK код клавиши, command: команда, name: описание
local keybinds = {
    {key = 0x4C, command = "/lock",   enabled = true,  name = "Закрыть/открыть машину"},
    {key = 0x4B, command = "/e",     enabled = true,  name = "Завести/заглушить двигатель"},
}
-- VK коды для справки: 0x4C=L, 0x4B=K, 0x4A=J, 0x4D=M, 0x4E=N, 0x50=P, 0x52=R, 0x54=T
local key_names = {
    [0x4A] = "J", [0x4B] = "K", [0x4C] = "L", [0x4D] = "M", [0x4E] = "N",
    [0x4F] = "O", [0x50] = "P", [0x51] = "Q", [0x52] = "R", [0x54] = "T",
    [0x55] = "U", [0x56] = "V", [0x57] = "W", [0x58] = "X", [0x59] = "Y",
    [0x5A] = "Z", [0x31] = "1", [0x32] = "2", [0x33] = "3", [0x34] = "4",
    [0x35] = "5", [0x36] = "6", [0x37] = "7", [0x38] = "8", [0x39] = "9",
    [0x30] = "0", [0x20] = "Space", [0x0D] = "Enter",
}
local new_bind_key = imgui.new.int(0x4C)
local new_bind_command = imgui.new.char[128]("")
local new_bind_name = imgui.new.char[128]("")
local cruise_speed = 0.0

-- Погода и Время (Визуал)
local weather_locked = imgui.new.bool(false)
local weather_id = imgui.new.int(1)
local time_locked = imgui.new.bool(false)
local time_hour = imgui.new.int(12)

-- Визуальный скин-ченджер
local skin_changer_id = imgui.new.int(0)

-- Переменные для модуля "Авто-объявления (Auto-Ad)"
local aad_active = false
local aad_text = ""
local aad_delay = imgui.new.int(15000)
local aad_templates = {}
local aad_history = {}
local static_aad_buf = nil
local last_ad_sent_time = 0
local aad_waiting_for_publish = false

-- Переменная для определения фракции
local selected_faction = imgui.new.int(0)

-- Forward declarations (функции определяются позже, но используются в модулях)
local isModuleEnabled
local saved_module_states
local modules
local factionScannerWorker
local chatScannerWorker
local sendAdCommand


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
-- Auto-resume AAD if it was active before reload
if aad_active and aad_text ~= "" then
lua_thread.create(function()
wait(3000)  -- wait for SAMP to be ready
if aad_active and aad_text ~= "" then
sampAddChatMessage("[Helper] Авто-реклама возобновлена", 0x00FF00)
sendAdCommand(aad_text)
end
end)
end
if not doesDirectoryExist(getWorkingDirectory() .. "/config") then
createDirectory(getWorkingDirectory() .. "/config")
    -- Load keybinds
    if settings.keybinds then
        keybinds = {}
        for _, kb in ipairs(settings.keybinds) do
            table.insert(keybinds, {key = kb.key, command = kb.command, enabled = kb.enabled, name = kb.name})
        end
        -- If empty, use defaults
        if #keybinds == 0 then
            keybinds = {
                {key = 0x4C, command = "/lock",   enabled = true,  name = "Закрыть/открыть машину"},
                {key = 0x4B, command = "/e",     enabled = true,  name = "Завести/заглушить двигатель"},
            }
        end
    end

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
if parsed.mm_tag ~= nil then imgui.StrCopy(mm_tag, u8:encode(parsed.mm_tag, encoding.default)) end
if parsed.strobe_speed ~= nil then strobe_speed[0] = parsed.strobe_speed end
if parsed.strobe_mode ~= nil then strobe_mode[0] = parsed.strobe_mode end
if parsed.weather_locked ~= nil then weather_locked[0] = parsed.weather_locked end
if parsed.weather_id ~= nil then weather_id[0] = parsed.weather_id end
if parsed.time_locked ~= nil then time_locked[0] = parsed.time_locked end
if parsed.time_hour ~= nil then time_hour[0] = parsed.time_hour end
if parsed.aad_delay ~= nil then aad_delay[0] = parsed.aad_delay end
if parsed.aad_active ~= nil then aad_active = parsed.aad_active end
if parsed.aad_text ~= nil then aad_text = parsed.aad_text end
if parsed.aad_templates ~= nil then aad_templates = parsed.aad_templates end
if parsed.aad_history ~= nil then aad_history = parsed.aad_history end
if parsed.last_called ~= nil then last_called = parsed.last_called end
if parsed.call_cooldown_hours ~= nil then call_cooldown_hours[0] = parsed.call_cooldown_hours end
if parsed.module_states then saved_module_states = parsed.module_states end
-- Миграция: конвертируем старые CP1251 шаблоны/историю в UTF-8
local function needsUtf8Convert(s)
    if type(s) ~= "string" then return false end
    -- CP1251 Cyrillic: single bytes 0xC0-0xFF
    -- UTF-8 Cyrillic: 2-byte sequences 0xD0/0xD1 + 0x80-0xBF
    -- If string has raw bytes > 0x7F that aren't valid UTF-8, it's CP1251
    local decoded = u8:decode(s)
    if decoded and #decoded > 0 and decoded ~= s then
        return false  -- valid UTF-8 (decode succeeded and produced different string)
    end
    -- Try: if encode(decode(s)) == s, it's already UTF-8
    -- If decode strips bytes (//IGNORE), it's CP1251
    if #decoded < #s then return true end  -- bytes were stripped = CP1251
    return false
end

local function migrateToUtf8(s)
    if type(s) ~= "string" then return s end
    if not needsUtf8Convert(s) then return s end
    -- s is CP1251, convert to UTF-8
    return u8:encode(s)
end

if aad_templates then
    for i, tpl in ipairs(aad_templates) do
        local converted = migrateToUtf8(tpl)
        if converted ~= tpl then
            aad_templates[i] = converted
        end
    end
    -- saveSettings() не вызываем здесь - функция определена ниже
    -- Конвертация в памяти, сохранится при следующем изменении настроек
end

if aad_history then
    for i, hist in ipairs(aad_history) do
        local converted = migrateToUtf8(hist)
        if converted ~= hist then
            aad_history[i] = converted
        end
    end
end
end
end
end

-- Сохранение настроек
local function saveSettings()
-- Save module enabled states
local module_states = {}
if modules then
for _, mod in ipairs(modules) do
module_states[mod.id] = mod.enabled
end
end
-- Save keybinds
local kb = {}
for _, bind in ipairs(keybinds) do
table.insert(kb, {key = bind.key, command = bind.command, enabled = bind.enabled, name = bind.name})
end
local settings = {
current_server = current_server_idx[0],
rp_weapons = rp_weapons_enabled[0],
rp_phone = rp_phone_enabled[0],
rp_mask = rp_mask_enabled[0],
rp_heal = rp_heal_enabled[0],
mm_auto_format = mm_auto_format[0],
mm_auto_send = mm_auto_send[0],
mm_send_delay = mm_send_delay[0],
mm_tag = u8:decode(ffi.string(mm_tag)),
strobe_speed = strobe_speed[0],
strobe_mode = strobe_mode[0],
weather_locked = weather_locked[0],
weather_id = weather_id[0],
time_locked = time_locked[0],
time_hour = time_hour[0],
aad_delay = aad_delay[0],
aad_active = aad_active,
aad_text = aad_text,
aad_templates = aad_templates,
aad_history = aad_history,
last_called = last_called,
call_cooldown_hours = call_cooldown_hours[0],
keybinds = kb,
module_states = module_states
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

-- Strip SAMP color codes
formatted = formatted:gsub("{%x+}", "")

-- Detect and extract existing tag prefix (LV |, LS |, SF |, TV |, MM |, etc.)
local detected_tag = nil
local tag_match = formatted:match("^%s*([A-Za-z%A-Z%d]+)%s*|%s*")
if tag_match then
detected_tag = tag_match:gsub("%s+", "")
formatted = formatted:gsub("^%s*[A-Za-z%A-Z%d]+%s*|%s*", "")
end

-- Detect car keywords (to skip city removal for cars)
local is_car = false
local car_keywords = {"булк", "инф", "туризм", "турик", "кловер", "хоткнайф", "дюн", "сультан", "султан", "елег", "банш", "чито", "феникс", "тахом", "премьер", "стретч", "бравур", "сабре", "вуду", "сламван", "ремингтон", "флеш", "джестер", "стратум", "уран", "блист", "баффал", "зомби", "ламбо", "бмв", "мерс", "тойот", "монстр", "бандит", "комет", "стингер", "супергт", "манан", "пикап", "соляр", "винсаг", "шафтер", "альпин", "беггал", "кальц", "салат", "стрикер", "адреналин", "нрг", "фрей", "вейб", "санч", "пжж", "фцз", "фаггио", "фагио", "бмх", "эндюро", "мото", "машин", "а/м", "м/ц", "тачк", "таз", "байк", "велосипед", "велик"}
for _, word in ipairs(car_keywords) do
if lower:find(word) then
is_car = true
break
end
end

-- Convert numbers with slang: 50kk -> 50.000.000$, 5mln -> 5.000.000$, 1kkk -> 1.000.000.000$
formatted = formatted:gsub("(%d+)%s*[кk][кk]", "%1.000.000$")
formatted = formatted:gsub("(%d+)%s*[кk][кk][кk]", "%1.000.000.000$")
formatted = formatted:gsub("(%d+)%s*[мm][лl][нn]", "%1.000.000$")
formatted = formatted:gsub("(%d+)%s*[мm][лl][рp][дd]", "%1.000.000.000$")
formatted = formatted:gsub("(%d+)%s*[мm][иi][лl][лl][иi][аa][рp][дd]", "%1.000.000.000$")
formatted = formatted:gsub("(%d+)%s*[мm][иi][лl][лl][иi][оo][нn]", "%1.000.000$")

-- Apply replacement rules
for _, rule in ipairs(mm_rules) do
local abbr = rule.abbreviation
local stem = abbr
if abbr:len() > 3 then stem = abbr:sub(1, -2) end
local pattern
if abbr:len() <= 2 then
pattern = "([%s%,%.])" .. abbr .. "([%s%,%.])"
else
pattern = "([%s%,%.])" .. stem .. "[^%s%,%.]*([%s%,%.])"
end
formatted = (" " .. formatted .. " "):gsub(pattern, function(left, right)
return left .. rule.replacement .. right
end)
formatted = formatted:sub(2, -2)
if abbr:len() <= 2 then
if formatted:lower() == abbr then
formatted = rule.replacement
end
else
if formatted:lower():match("^" .. stem) then
formatted = rule.replacement
end
end
end

-- Auto-add location for "kuplyu" if no location mentioned
local has_location = false
local loc_words = {"Los Santos", "San Fierro", "Las Venturas", "East", "Ganton", "Idlewood", "Jefferson", "Glen", "Willowfield", "El Corona", "Commerce", "Market", "Verona", "Chinatown", "Palomino", "Montgomery", "Dillimore", "Blueberry", "Flint", "Fort Carson", "Tierra", "Angel", "Bayside", "North Rock", "Valle", "Arco", "Green Palms", "Union", "Strip", "Rockshore", "Pilgrim", "Avalon", "Prickle", "Whitewood", "Pilbox", "Doherty", "Kings", "Paradiso", "Queens", "Hashbury", "Garcia", "Santa Flora", "Foster", "Venturas", "штат", "город", "район"}
for _, word in ipairs(loc_words) do
if formatted:lower():find(word:lower()) then
has_location = true
break
end
end
local is_buy = false
if lower:find("^[кК]уплю") then
is_buy = true
end
if is_buy and not has_location then
-- Insert "v lyuboy tochke shtata" after the verb+item, before budget/price
formatted = formatted:gsub(
"(куплю%s+[^%.%d]+)%s+(бюджет|цена|тел|звон|обмен|$)",
"%1 в любой точке штата. %2"
)
-- If no budget/price keyword, append before end
if not formatted:find("в любой точке") then
formatted = formatted:gsub("^(Куплю%s+.+)$", "%1 в любой точке штата")
end
end

-- Clean up whitespace
formatted = formatted:gsub("%s+", " ")
formatted = formatted:gsub("^%s+", "")
formatted = formatted:gsub("%s+$", "")

-- Add "Цена: " before dollar amounts if not already present
-- Only match full number+dollar at word boundary, not partial
formatted = formatted:gsub("([%s])(%d+%.%d+%$)", "%1Цена: %2")
formatted = formatted:gsub("^(%d+%.%d+%$)", "Цена: %1")

-- Punctuation and price formatting
local fl = formatted:lower()

-- Check if has price already (use formatted text after replacements)
local has_price = false
if fl:find("%$") or fl:find("цена") or fl:find("дог") or fl:find("торг") or fl:find("обмен") or fl:find("бартер") or fl:find("бесплатн") or fl:find("бюджет") then
has_price = true
end

-- Check if is ad using ORIGINAL text (before replacements)
local is_ad = false
if lower:find("^[пП]родам") or lower:find("^[кК]уплю") or lower:find("^[оО]бменяю") or lower:find("^семья") or lower:find("^ищу") or lower:find("^сдаю") or lower:find("^сниму") or lower:find("^предлагаю") or lower:find("^распродаю") or lower:find("^закуп") or lower:find("^скуп") then
is_ad = true
end

-- Add period before keywords if missing
formatted = formatted:gsub("%s+(бюджет)", ". %1")
formatted = formatted:gsub("%s+(Цена)", ". %1")
formatted = formatted:gsub("%s+(тел)", ". %1")
formatted = formatted:gsub("%s+(Звон)", ". %1")
formatted = formatted:gsub("%s+(Обмен)", ". %1")

-- Fix double periods
formatted = formatted:gsub("%.+%.", ".")
formatted = formatted:gsub("%. %.", ". ")

-- Capitalize after period
formatted = formatted:gsub("%. (.)", function(c) return ". " .. cp1251_upper(c) end)

-- Auto-add price if ad but no price specified
if is_ad and not has_price then
formatted = formatted .. ". Цена: договорная"
end

-- Ensure ends with period
if #formatted > 0 and not formatted:sub(-1):match("[%.,%!%?]") then
formatted = formatted .. "."
end

-- Fix ". ." -> "."
formatted = formatted:gsub("%. %.", ".")
formatted = formatted:gsub("%s+$", "")

-- Add server tag prefix (use detected tag if found, otherwise configured tag)
local tag = detected_tag or u8:decode(ffi.string(mm_tag))
if tag and tag ~= "" then
formatted = tag .. " | " .. formatted
end

-- Capitalize first letter of actual text (after "TAG | ")
-- Lua :upper() only handles ASCII, so we manually handle CP1251 Cyrillic
local function cp1251_upper(ch)
local b = ch:byte()
if b >= 97 and b <= 122 then return string.char(b - 32) end
if b >= 224 and b <= 255 then return string.char(b - 32) end
if b == 184 then return string.char(168) end
return ch
end
local pipe_pos = formatted:find(" | ")
if pipe_pos then
local after_pipe = pipe_pos + 3
if after_pipe <= #formatted then
formatted = formatted:sub(1, after_pipe - 1) .. cp1251_upper(formatted:sub(after_pipe, after_pipe)) .. formatted:sub(after_pipe + 1)
end
else
if #formatted > 0 then
formatted = cp1251_upper(formatted:sub(1, 1)) .. formatted:sub(2)
end
end

return formatted
end

-- Проверка онлайна (Встроенными методами)
local function isPlayerOnline(nickname)
if not isSampAvailable() then return false end
local _, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
for i = 0, sampGetMaxPlayerId() do
if sampIsPlayerConnected(i) then
local nick = sampGetPlayerNickname(i)
if nick == nickname then
if i == myid then return false end
return true, i
end
end
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
modules = {
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
imgui.InputInt(u8"Не звонить человека (часов)", call_cooldown_hours, 0, 24)
imgui.PopItemWidth()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

local called_recently = 0
for nick, t in pairs(last_called) do
if os.time() - t < call_cooldown_hours[0] * 3600 then called_recently = called_recently + 1 end
end
imgui.TextColored(imgui.ImVec4(0.7, 0.7, 1, 1), u8"Прогресс:")
imgui.BulletText(u8"Позвонили за время кулдауна: " .. called_recently)

imgui.Spacing()
if imgui.Button(u8"Сбросить историю звонков") then
last_called = {}
saveSettings()
sampAddChatMessage("[Helper] История звонков сброшена", 0x00FF00)
end
imgui.SameLine()
if imgui.Button(u8"Очистить БД") then
player_db = {}
last_called = {}
saveDatabase()
saveSettings()
sampAddChatMessage("[Helper] БА очищена", 0x00FF00)
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if call_active then
imgui.TextColored(imgui.ImVec4(0, 1, 0, 1), u8"Статус: Идет обзвон...")
imgui.Text(u8"Звоним: " .. u8(call_current_nick) .. " (" .. call_current_phone .. ")")
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
imgui.TextColored(is_on ~= "" and imgui.ImVec4(0, 1, 0, 1) or imgui.ImVec4(0.7, 0.7, 0.7, 1), u8(nick) .. " | Тел: " .. data.phone .. is_on)
if data.ad and data.ad ~= "" then
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextWrapped("-> " .. u8(data.ad))
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
id = "auto_ad",
name = u8" Авто-Объявления",
description = u8"Автоматически отправляет объявления с заданным интервалом. Поддерживает шаблоны и историю.",
enabled = false,
drawSettings = function()
    static_aad_buf = static_aad_buf or imgui.new.char[128](u8(aad_text))
    local aad_active_bool = imgui.new.bool(aad_active)
    if imgui.Checkbox(u8"Активировать авто-объявления##checkbox_aad", aad_active_bool) then
        aad_active = aad_active_bool[0]
        if aad_active then
            aad_text = u8:decode(ffi.string(static_aad_buf))
            sendAdCommand(aad_text)
        end
    end

    imgui.PushItemWidth(350)
    if imgui.InputText(u8"Текст объявления##input_aad", static_aad_buf, 128) then
        aad_text = u8:decode(ffi.string(static_aad_buf))
    end
    if imgui.SliderInt(u8"Интервал между подачами (мс)##delay_aad", aad_delay, 3000, 30000) then saveSettings() end
    imgui.PopItemWidth()

    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"-> Вы можете также использовать команду: /aad [текст]")
    imgui.Spacing()

    imgui.Columns(2, "aad_columns", true)
    imgui.SetColumnWidth(0, 290)
    imgui.SetColumnWidth(1, 290)

    imgui.TextColored(imgui.ImVec4(0.3, 0.8, 1, 1), u8"Шаблоны объявлений:")
    imgui.SameLine()
    if imgui.Button(u8"Добавить##add_tpl", imgui.ImVec2(70, 20)) then
        local current_str = ffi.string(static_aad_buf)  -- UTF-8 for ImGui display
        if current_str ~= "" then
            local exists = false
            for _, val in ipairs(aad_templates) do
                if val == current_str then exists = true break end
            end
            if not exists then
                table.insert(aad_templates, current_str)
                saveSettings()
            end
        end
    end

    imgui.BeginChild("templates_child", imgui.ImVec2(280, 150), true)
    if #aad_templates > 0 then
        for idx, tpl in ipairs(aad_templates) do
            imgui.PushIDStr("tpl_" .. idx)
            if imgui.Button(u8"Выбрать") then
                for i = 0, 127 do static_aad_buf[i] = 0 end
                ffi.copy(static_aad_buf, tpl)
                aad_text = u8:decode(tpl)  -- UTF-8 -> CP1251 for sending
                saveSettings()
            end
            imgui.SameLine()
            if imgui.Button(u8"X") then
                table.remove(aad_templates, idx)
                saveSettings()
                imgui.PopID()
                break
            end
            imgui.SameLine()
            imgui.Text(tpl)  -- already UTF-8
            imgui.PopID()
        end
    else
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"Нет сохраненных шаблонов.")
    end
    imgui.EndChild()

    imgui.NextColumn()

    imgui.TextColored(imgui.ImVec4(1, 0.7, 0.3, 1), u8"История объявлений:")
    imgui.SameLine()
    if imgui.Button(u8"Очистить##clear_hist", imgui.ImVec2(70, 20)) then
        aad_history = {}
        saveSettings()
    end

    imgui.BeginChild("history_child", imgui.ImVec2(280, 150), true)
    if #aad_history > 0 then
        for idx, hist in ipairs(aad_history) do
            imgui.PushIDStr("hist_" .. idx)
            if imgui.Button(u8"Выбрать") then
                for i = 0, 127 do static_aad_buf[i] = 0 end
                ffi.copy(static_aad_buf, hist)
                aad_text = u8:decode(hist)  -- UTF-8 -> CP1251 for sending
                saveSettings()
            end
            imgui.SameLine()
            if imgui.Button(u8"X") then
                table.remove(aad_history, idx)
                saveSettings()
                imgui.PopID()
                break
            end
            imgui.SameLine()
            imgui.Text(hist)  -- already UTF-8
            imgui.PopID()
        end
    else
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"История пуста.")
    end
    imgui.EndChild()

    imgui.Columns(1)
    imgui.Spacing()
end,
onToggle = function(state) end
},
{
id = "mm_editor",
name = u8" MM Editor (СМИ)",
description = u8"Помощник для сотрудников радиоцентра (СМИ). Автоматически заменяет сокращения при редактировании объявлений с учетом правил ПРО (город пишется для домов/бизнесов, но стирается для автомобилей).",
enabled = false,
drawSettings = function()
imgui.Text(u8"Тег объявления:")
imgui.SameLine()
imgui.PushItemWidth(60)
if imgui.InputText("##mm_tag", mm_tag, ffi.sizeof(mm_tag)) then saveSettings() end
imgui.PopItemWidth()
imgui.SameLine()
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"Например: LV, LS, SF, TV")
imgui.Spacing()
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
local raw_text = u8:decode(ffi.string(test_input))  -- UTF-8 -> CP1251
test_output = u8:encode(formatAdText(raw_text))  -- CP1251 -> UTF-8 for ImGui
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
imgui.Text(u8(rule.abbreviation) .. " -> " .. u8(rule.replacement))  -- CP1251 -> UTF-8
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
local abbr = u8:decode(ffi.string(static_new_abbr)):lower()  -- UTF-8 -> CP1251
local repl = u8:decode(ffi.string(static_new_repl))  -- UTF-8 -> CP1251
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
enabled = true,
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
        imgui.Checkbox(u8"Турбо-круиз (риск бана!)", turbo_cruise_enabled)
        imgui.Text(u8"Круиз: C=вкл/выкл  W=+5  S=-5")

imgui.PushItemWidth(150)
if imgui.SliderInt(u8"Скорость стробоскопов (мс)", strobe_speed, 50, 600) then saveSettings() end

local strobe_items = u8"Обе вместе" .. "\0" .. u8"Попеременно" .. "\0" .. u8"Гирлянда (по одной)" .. "\0" .. u8"Двойной лево/право" .. "\0" .. u8"Быстрый оба (3х)" .. "\0" .. u8"Очень быстрый оба (5х)" .. "\0" .. u8"Полицейский 1" .. "\0" .. u8"Полицейский 2 (3+3+обе)" .. "\0" .. u8"Полицейский 3 (быстрый)" .. "\0" .. u8"SOS (Морзе)" .. "\0" .. u8"Волна" .. "\0" .. u8"Импульс (вспышка+пауза)" .. "\0" .. u8"Двойная гирлянда" .. "\0" .. u8"Тройная вспышка (спец)" .. "\0" .. u8"Зигзаг" .. "\0" .. u8"Энергичный (2х2)" .. "\0" .. u8"Маяк (медленный)" .. "\0" .. u8"Перекрёстный" .. "\0" .. u8"Каскад (нарастающий)" .. "\0"

if imgui.ComboStr(u8"Режим стробоскопов", strobe_mode, strobe_items) then
saveSettings()
end
imgui.PopItemWidth()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextColored(imgui.ImVec4(0, 1, 0.7, 1), u8"Окружение (Локально):")

if imgui.Checkbox(u8"Зафиксировать погоду", weather_locked) then saveSettings() end
if weather_locked[0] then
imgui.PushItemWidth(250)
if imgui.SliderInt(u8"ID Погоды", weather_id, 0, 45) then saveSettings() end
imgui.PopItemWidth()
imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), u8"Популярные ID: 1-2 (ясно), 8 (шторм), 9 (туман), 19 (песок)")
end

if imgui.Checkbox(u8"Зафиксировать время суток", time_locked) then saveSettings() end
if time_locked[0] then
imgui.PushItemWidth(250)
if imgui.SliderInt(u8"Часы", time_hour, 0, 23) then saveSettings() end
imgui.PopItemWidth()
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextColored(imgui.ImVec4(0, 1, 0.7, 1), u8"Скин-Ченджер (Локально):")
imgui.PushItemWidth(150)
imgui.InputInt(u8"ID Скина (0-311)", skin_changer_id)
imgui.PopItemWidth()

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
id = "keybinds",
name = u8" Горячие клавиши",
description = u8"Привязка команд к клавишам. Нажмите клавишу - выполнится команда.\nНе срабатывает при открытом чате или диалоге.",
enabled = true,
drawSettings = function()
imgui.Text(u8"Текущие бинды:")
imgui.Spacing()
for i, bind in ipairs(keybinds) do
local en = imgui.new.bool(bind.enabled)
if imgui.Checkbox("##en" .. i, en) then
bind.enabled = en[0]
saveSettings()
end
imgui.SameLine()
local kname = key_names[bind.key] or ("0x" .. string.format("%02X", bind.key))
imgui.Text(u8:decode("[" .. kname .. "] " .. bind.name .. "  (" .. bind.command .. ")"))
imgui.SameLine(350)
if imgui.Button(u8"Удалить##del" .. i) then
table.remove(keybinds, i)
saveSettings()
break
end
end
imgui.Spacing()
imgui.Separator()
imgui.Spacing()
imgui.Text(u8"Добавить новый бинд:")
imgui.PushItemWidth(100)
-- Key selector
local key_opts = ""
local key_keys = {}
for k, v in pairs(key_names) do
table.insert(key_keys, k)
end
table.sort(key_keys)
for _, k in ipairs(key_keys) do
key_opts = key_opts .. key_names[k] .. "\0"
end
if imgui.BeginCombo("##newkey", key_names[new_bind_key[0]] or "Выбрать") then
for _, k in ipairs(key_keys) do
if imgui.Selectable(key_names[k], new_bind_key[0] == k) then
new_bind_key[0] = k
end
end
imgui.EndCombo()
end
imgui.SameLine()
imgui.PushItemWidth(150)
imgui.InputText("##newcmd", new_bind_command, 128)
imgui.SameLine()
imgui.PushItemWidth(150)
imgui.InputText("##newname", new_bind_name, 128)
imgui.SameLine()
if imgui.Button(u8" + Добавить ") then
local cmd = ffi.string(new_bind_command)
local nm = ffi.string(new_bind_name)
if cmd ~= "" then
if nm == "" then nm = cmd end
table.insert(keybinds, {key = new_bind_key[0], command = cmd, enabled = true, name = nm})
new_bind_command[0] = 0
new_bind_name[0] = 0
saveSettings()
end
end
imgui.PopItemWidth()
imgui.Spacing()
imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1), u8"Формат команды: /lock, /e, /me открыл дверь и т.д.")
end,
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

-- Restore module enabled states from saved settings
if saved_module_states then
for _, mod in ipairs(modules) do
if saved_module_states[mod.id] ~= nil then
mod.enabled = saved_module_states[mod.id]
end
end
end

sampAddChatMessage("Helper Core v0.9 (28.06.2026) загружен. Меню: F11", 0x00FF00)
sampAddChatMessage("Стробы: J=вкл/выкл, N=режим | Круиз: C, W/S=скорость | Бинды: L=/lock, K=/e", 0xFFFFFF)

-- Регистрируем команду открытия меню
sampRegisterChatCommand("helper", function()
show_main_window[0] = not show_main_window[0]
end)

sampRegisterChatCommand("aad", function(arg)
    if aad_active then
        aad_active = false
        aad_text = ""
        sampAddChatMessage("[Helper] Auto-Ad остановлен.", 0xFF0000)
    else
        if not arg or arg == "" then
            sampAddChatMessage("[Helper] Использование: /aad [текст объявления]", 0xFF0000)
        else
            aad_active = true
            aad_text = arg
            sampAddChatMessage("[Helper] Auto-Ad запущен! Текст: " .. arg, 0x00FF00)
            sendAdCommand(aad_text)
        end
    end
end)



-- Регистрируем команду смены скина
sampRegisterChatCommand("fskin", function(arg)
local id = tonumber(arg)
if id and id >= 0 and id <= 311 then
skin_changer_id[0] = id
applyLocalSkin(id)
else
sampAddChatMessage("[Helper] Использование: /fskin [0-311]", 0xFF0000)
end
end)

-- РЕГИСТРАЦИЯ КОМАНД ДЛЯ АВТО-ОТЫГРОВОК
-- RP отыгровки теперь через sampev.onSendChat (см. ниже)

-- Запуск потоков
lua_thread.create(factionScannerWorker)
lua_thread.create(weaponTrackWorker)
lua_thread.create(cruiseControlWorker)
lua_thread.create(environmentWorker)

-- Поток считывания чата (альтернатива onServerMessage без SAMP.Lua)
lua_thread.create(chatScannerWorker)

-- Поток отслеживания диалоговых окон (альтернатива onShowDialog без SAMP.Lua)

while true do
wait(0)

-- Клавиша F11
if wasKeyPressed(0x7A) and not sampIsChatInputActive() and not sampIsDialogActive() then
show_main_window[0] = not show_main_window[0]
end

-- Клавиша J для стробоскопов в машине
if wasKeyPressed(0x4A) and isCharInAnyCar(PLAYER_PED) and not sampIsChatInputActive() and not sampIsDialogActive() then -- J
strobe_enabled[0] = not strobe_enabled[0]
strobe_active = strobe_enabled[0]
if strobe_active then
lua_thread.create(strobeWorker)
end
sampAddChatMessage(u8:decode("[Helper] Стробоскопы: " .. (strobe_enabled[0] and "{00FF00}ВКЛ{FFFFFF} (выкл - J)" or "{FF0000}ВЫКЛ")), 0xFFFFFF)
end

-- Клавиша N для смены режима стробоскопов (только если включены и в машине)
if wasKeyPressed(0x4E) and isCharInAnyCar(PLAYER_PED) and strobe_enabled[0] and not sampIsChatInputActive() and not sampIsDialogActive() then -- N
local strobe_mode_names = {
    [1]="Мигающие", [2]="Попеременно", [3]="Вспышки (обе)", [4]="Бегущий Л/П",
    [5]="Бегущий 3шт", [6]="Бегущий 5шт", [7]="Сирена 1", [8]="Сирена 2 (3+3+обе)",
    [9]="Сирена 3 (классика)", [10]="SOS (морзе)", [11]="Гирлянда", [12]="Двойной (лево+право)",
    [13]="Двойной попеременно", [14]="Двойной бегущий (волна)", [15]="Маяк", [16]="Частые (2х2)",
    [17]="Ритм (ускоренный)", [18]="Перекрёсток", [19]="Патруль (мигалка)",
}
strobe_mode[0] = strobe_mode[0] + 1
if strobe_mode[0] > 19 then strobe_mode[0] = 1 end
saveSettings()
local mname = strobe_mode_names[strobe_mode[0]] or ("#" .. strobe_mode[0])
sampAddChatMessage(u8:decode("[Helper] Стробоскоп режим: {00FF00}" .. mname .. " {FFFFFF}(N - следующий)"), 0xFFFFFF)
end

-- Обработка биндов клавиш на команды
if not sampIsChatInputActive() and not sampIsDialogActive() then
for _, bind in ipairs(keybinds) do
if bind.enabled and wasKeyPressed(bind.key) then
sampSendChat(bind.command)
break
end
end
end

end
end

-- ПОТОК ДЛЯ СКАНИРОВАНИЯ ИГРОВОГО ЧАТА (без SAMP.Lua)
-- СКАНЕР ФРАКЦИЙ (для авто-отыгровки)
factionScannerWorker = function()
    local last_dialog_id = -1
    local faction_names = {
        [1] = "МВД (Полиция)",
        [2] = "МЗ (Больница/МЧС)",
        [3] = "МО (Армия)",
        [4] = "Мэрия (Администрация)",
        [5] = "СМИ (Журналисты)",
        [6] = "Банды (Гетто)",
        [7] = "Мафии"
    }

    while true do
        wait(500)
        if isSampAvailable() and sampIsDialogActive() then
            local current_dialog_id = sampGetCurrentDialogId()
            if current_dialog_id ~= last_dialog_id then
                last_dialog_id = current_dialog_id
                local title = sampGetDialogCaption() or ""
                local text = sampGetDialogText() or ""
                if title:find("Организация") or title:find("Паспорт") or title:find("Удостоверение") or text:find("Подразделение:") then
                    local detected_faction = nil
                    if text:find("МВД") or text:find("Полиция") or text:find("Департамент") or text:find("Шерифа") then
                        detected_faction = 1
                    elseif text:find("Больница") or text:find("МЧС") or text:find("Медик") or text:find("Санитар") or text:find("Врач") then
                        detected_faction = 2
                    elseif text:find("Армия") or text:find("МО") or text:find("Военком") then
                        detected_faction = 3
                    elseif text:find("Мэрия") or text:find("Администрация") or text:find("Мэр") or text:find("Депутат") or text:find("Прокурор") then
                        detected_faction = 4
                    elseif text:find("СМИ") or text:find("Журналист") or text:find("Радио") or text:find("Телевидение") then
                        detected_faction = 5
                    elseif text:find("Grove") or text:find("Гроув") or text:find("Ballas") or text:find("Баллас") or text:find("Vagos") or text:find("Вагос") or text:find("Aztec") or text:find("Ацтек") or text:find("Rifa") or text:find("Рифа") then
                        detected_faction = 6
                    elseif text:find("Мафия") or text:find("Бандит") or text:find("Yakuza") or text:find("La Cosa Nostra") or text:find("LCN") or text:find("Картель") or text:find("Триада") then
                        detected_faction = 7
                    end
                    if detected_faction and selected_faction[0] ~= detected_faction then
                        selected_faction[0] = detected_faction
                        saveSettings()
                        sampAddChatMessage("[Helper] Определена фракция: {00FF00}" .. faction_names[detected_faction] .. "{FFFFFF}. Настройки обновлены.", 0xFFFFFF)
                    end
                end
            end
        else
            last_dialog_id = -1
        end
    end
end

-- Проверка включен ли модуль
isModuleEnabled = function(id)
    if not modules then return false end
    for _, mod in ipairs(modules) do
        if mod.id == id then
            return mod.enabled
        end
    end
    return false
end

-- Отправка объявления
sendAdCommand = function(text)
    if text and text ~= "" then
        sampSendChat("/ad " .. text)
        last_ad_sent_time = os.time()
        aad_waiting_for_publish = true
        if #aad_history == 0 or aad_history[#aad_history] ~= u8:encode(text) then
            table.insert(aad_history, u8:encode(text))  -- CP1251 -> UTF-8 for display
            if #aad_history > 20 then
                table.remove(aad_history, 1)
            end
            saveSettings()
        end
    end
end

-- Перехват команд для авто-РП отыгровок
-- Добавляет /me перед серверными командами
function sampev.onSendChat(message)
    if isModuleEnabled("auto_rp") then
        local cmd = message:match("^/(%w+)")
        if cmd then
            -- /call <number>
            if (cmd == "call" or cmd == "c") and rp_phone_enabled[0] then
                local arg = message:match("^/call%s+(.+)")
                if arg and arg ~= "" then
                    lua_thread.create(function()
                        sampSendChat(u8:decode("/me достал мобильный телефон и набрал номер " .. arg))
                        wait(100)
                    end)
                end
            -- /h or /hangup
            elseif (cmd == "h" or cmd == "hangup") and rp_phone_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me закрыл телефон и убрал его в карман"))
                    wait(100)
                end)
            -- /mask
            elseif cmd == "mask" and rp_mask_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me надел на лицо маску и скрыл свое лицо"))
                    wait(100)
                end)
            -- /healme
            elseif cmd == "healme" and rp_heal_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me достал аптечку, открыл ее и применил"))
                    wait(100)
                end)
            -- /drugs
            elseif cmd == "drugs" and rp_heal_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me достал шприц и сделал укол"))
                    wait(100)
                end)
            -- /e (engine)
            elseif cmd == "e" and rp_weapons_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me завел двигатель"))
                    wait(100)
                end)
            end
        end
    end
    return true  -- let the message go to server
end

-- Блокируем серверную синхронизацию времени и погоды
function sampev.onSetPlayerTime(hour, minute)
    if time_locked[0] then
        return false  -- блокируем сервер, не меняем время
    end
end

function sampev.onSetWeather(weatherId)
    if weather_locked[0] then
        return false  -- блокируем сервер, не меняем погоду
    end
end

-- Обработчик сообщений сервера (SAMP events)
function sampev.onServerMessage(color, text)
    -- Ищем в оригинальном CP1251 тексте
    local sender, phone = text:match("Отправил%s+([A-Za-z0-9_]+)%[%d+%]%s+%(тел%.%s*(%d+)%)")
    if not sender or not phone then
        sender, phone = text:match("([A-Za-z0-9_]+)%[%d+%]%s+%(тел%.%s*(%d+)%)")
    end
    if not sender or not phone then
        sender, phone = text:match("([A-Za-z0-9_]+).-%(тел%.%s*(%d+)%)")
    end
    local text_utf8 = u8:encode(text, encoding.default)

    if sender and phone then
        local result, my_id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        local my_name = result and sampGetPlayerNickname(my_id) or ""

        if sender == my_name then
            if aad_active and aad_text ~= "" then
                lua_thread.create(function()
                    sampAddChatMessage("[Helper] Объявление опубликовано. Следующая подача через " .. (aad_delay[0]/1000) .. " сек...", 0x00FFFF)
                    wait(aad_delay[0])
                    if aad_active and aad_text ~= "" then
                        sendAdCommand(aad_text)
                    end
                end)
            end
        elseif isModuleEnabled("autocall_db") then
            player_db[sender] = {
                phone = phone,
                time = os.date("%Y-%m-%d %H:%M:%S"),
                ad = ""
            }
            saveDatabase()
            sampAddChatMessage("[Helper DB] Новый контакт: " .. sender .. " (Тел: " .. phone .. ")", 0x00FF90)
        end
    end
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if not isModuleEnabled("mm_editor") or not mm_auto_format[0] then
        return
    end
    -- text is CP1251 from SAMP, patterns are CP1251 in this file
    if title:find("публикац") or title:find("объявлен") or text:find("Текст:") then
        local original = text:match("Текст:(.-)Введите") or text:match("Текст:%s*(.+)") or ""
        original = original:gsub("{%x+}", "")
        original = original:gsub("^%s+", ""):gsub("%s+$", "")
        if original ~= "" then
            local formatted = formatAdText(original)
            ae_dialog_id = dialogId
            ae_original_text = u8:encode(original, encoding.default)
            ae_formatted_text = u8:encode(formatted, encoding.default)
            imgui.StrCopy(ae_input_buf, u8:encode(formatted, encoding.default))
            ae_active[0] = true
            ae_focus = true
            return false
        end
    end
end

function chatScannerWorker()
local processed_chat = {}
local processed_chat_count = 0

while true do
wait(50) -- Сканируем каждые 50 мс

if isModuleEnabled("autocall_db") and isSampAvailable() then
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
-- Ищем в оригинальном CP1251 тексте
local sender, phone = text:match("Отправитель:%s*([A-Za-z0-9_]+).-[Тт]ел%s*:%s*(%d+)")
if not sender or not phone then
sender, phone = text:match("([A-Za-z0-9_]+)%s*%.%s*[Тт]ел%s*:%s*(%d+)")
end
local text_utf8 = u8:encode(text, encoding.default)

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
function applyLocalSkin(skinId)
lua_thread.create(function()
if skinId >= 0 and skinId <= 311 and skinId ~= 74 then
requestModel(skinId)
loadAllModelsNow()
if isModelAvailable(skinId) then
local charPtr = getCharPointer(PLAYER_PED)
if charPtr and charPtr >= 1 then
-- CPed::SetModel - функция по адресу 0x5E4880
-- void __thiscall SetModel(int thisPtr, int modelId)
pcall(function()
ffi.cast("void (__thiscall *)(int, int)", 0x5E4880)(charPtr, skinId)
end)
clearCharTasks(PLAYER_PED)
markModelAsNoLongerNeeded(skinId)
sampAddChatMessage("[Helper] Скин успешно изменен на ID: " .. skinId, 0x00FF00)
else
sampAddChatMessage("[Helper] Не удалось получить указатель на персонажа.", 0xFF0000)
end
else
sampAddChatMessage("[Helper] Ошибка загрузки модели скина.", 0xFF0000)
end
else
sampAddChatMessage("[Helper] Некорректный ID скина (допустимо 0-311, кроме 74).", 0xFF0000)
end
end)
end

-- РАБОТА С ПОГОДОЙ И ВРЕМЕНЕМ
function environmentWorker()
while memory == nil do wait(500) end
local last_w = -1
local last_t = -1
while true do
wait(0)  -- every frame, no delay
-- Погода: пишем напрямую в память
if weather_locked[0] then
local w = weather_id[0]
if w ~= last_w then
last_w = w
pcall(forceWeatherNow, w)
end
-- Поддерживаем каждый кадр
pcall(memory.write, 0xC81320, w, 1, false)
else
last_w = -1
end
-- Время: пишем напрямую + сбрасываем таймер
if time_locked[0] then
local h = time_hour[0]
if h ~= last_t then
last_t = h
end
-- Час + минуты + секунды + таймер
pcall(memory.write, 0xB70153, h, 1, false)
pcall(memory.write, 0xB70152, 0, 1, false)
pcall(memory.write, 0xB70158, 0, 4, false)
else
last_t = -1
end
end
end

-- РАБОТА СТРОБОСКОПОВ
-- Последовательности мигания фар для стробоскопа
-- Каждый шаг: {left_light_state, right_light_state}
-- 0 = выключена, 2 = включена (значения для setCarLightDamageStatus)
-- Последовательности мигания фар для стробоскопа
-- Каждый шаг: {left_light, right_light}
-- 0 = фара ВКЛ (целая, светит), 1 = фара ВЫКЛ (повреждена, не светит)
-- Индексы фар GTA SA: 0=перед-лево, 1=перед-право, 2=зад-лево, 3=зад-право
-- Последовательности мигания фар для стробоскопа
-- Каждый шаг: {left_light, right_light}
-- 0 = фара ВКЛ (целая, светит), 1 = фара ВЫКЛ (повреждена, не светит)
-- 0 = фара ВКЛ (целая, светит), 1 = фара ВЫКЛ (повреждена, не светит)
-- {left, right} - состояние левой и правой передней фары
local strobe_sequences = {
    -- Базовые режимы
    [0] = {{0, 0}, {1, 1}, {0, 0}, {1, 1}},                                      -- Обе вместе
    [1] = {{0, 1}, {1, 0}, {0, 1}, {1, 0}},                                      -- Попеременно (лево-право)
    [2] = {{0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 1}, {1, 0}},      -- Гирлянда (быстро по одной)

    -- Многократные вспышки
    [3] = {{0, 1}, {0, 1}, {1, 0}, {1, 0}},                                      -- Двойной лево, двойной право
    [4] = {{0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}},                      -- Быстрый оба (тройной)
    [5] = {{0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}}, -- Очень быстрый оба

    -- Полицейский стиль
    [6] = {{0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 0}, {1, 1}, {0, 0}, {1, 1}},      -- Полицейский (попеременно + обе)
    [7] = {{0, 1}, {0, 1}, {0, 1}, {1, 0}, {1, 0}, {1, 0}, {0, 0}, {1, 1}},      -- Полицейский 2 (3х лево, 3х право, обе)
    [8] = {{0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 0}, {0, 0}, {1, 1}, {1, 1}}, -- Полицейский 3 (быстро попеременно + двойной обе)

    -- SOS (азбука Морзе: ... --- ...)
    -- ... = 3 коротких, --- = 3 длинных, ... = 3 коротких
    -- Короткий = 1 шаг ВКЛ, 1 шаг ВЫКЛ
    -- Длинный = 3 шага ВКЛ, 1 шаг ВЫКЛ
    -- Пауза между буквами = 3 шага ВЫКЛ
    [9] = {
        {0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1},  -- S: . . .
        {1, 1}, {1, 1}, {1, 1},                            -- пауза
        {0, 0}, {0, 0}, {0, 0}, {1, 1},                    -- O: - (длинный)
        {0, 0}, {0, 0}, {0, 0}, {1, 1},                    -- O: -
        {0, 0}, {0, 0}, {0, 0}, {1, 1},                    -- O: -
        {1, 1}, {1, 1}, {1, 1},                            -- пауза
        {0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1},  -- S: . . .
        {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1},            -- длинная пауза
    },

    -- Волна (плавное перетекание лево -> обе -> право -> обе -> ...)
    [10] = {{0, 1}, {0, 0}, {1, 0}, {0, 0}, {0, 1}, {0, 0}, {1, 0}, {0, 0}},

    -- Импульс (короткие яркие вспышки с длинными паузами)
    [11] = {{0, 0}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}},  -- Одна вспышка + длинная пауза

    -- Двойная гирлянда (по одной, но с паузой между парами)
    [12] = {{0, 1}, {1, 0}, {1, 1}, {0, 1}, {1, 0}, {1, 1}},

    -- Тройная вспышка (как у спецтранспорта)
    [13] = {{0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}, {1, 1}, {1, 1}, {1, 1}},

    -- Зигзаг (лево-обе-право-обе-лево-обе-право-обе быстро)
    [14] = {{0, 1}, {0, 0}, {1, 0}, {0, 0}, {0, 1}, {0, 0}, {1, 0}, {0, 0}, {0, 1}, {0, 0}, {1, 0}, {0, 0}},

    -- Энергичный (быстрые двойные вспышки по сторонам)
    [15] = {{0, 1}, {0, 1}, {1, 1}, {1, 0}, {1, 0}, {1, 1}},

    -- Маяк (медленные одиночные вспышки обеими)
    [16] = {{0, 0}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}},

    -- Перекрёстный (лево-право-обе-пауза, быстро)
    [17] = {{0, 1}, {1, 0}, {0, 0}, {1, 1}, {0, 1}, {1, 0}, {0, 0}, {1, 1}},

    -- Каскад (нарастающая частота)
    [18] = {{0, 0}, {1, 1}, {1, 1}, {1, 1},
            {0, 0}, {1, 1}, {1, 1},
            {0, 0}, {1, 1},
            {0, 0}, {1, 1},
            {0, 0}, {1, 1}, {1, 1},
            {0, 0}, {1, 1}, {1, 1}, {1, 1}},
}

-- Загружаем memory и bit для прямого доступа к CDamageManager
local has_memory, memory = pcall(require, 'memory')
local has_bit, bit = pcall(require, 'bit')

-- Установить состояние фар через прямую запись в память
-- CAutomobile + 0x5A0 = m_damageManager (CDamageManager)
-- CDamageManager + 0x10 = m_nLightsStatus (uint32, 2 бита на фару)
-- LIGHT_FRONT_LEFT  = bits 0-1 (0 = OK/светит, 2 = damaged/не светит)
-- LIGHT_FRONT_RIGHT = bits 2-3 (0 = OK/светит, 2 = damaged/не светит)
-- LIGHT_REAR_RIGHT  = bits 4-5
-- LIGHT_REAR_LEFT   = bits 6-7
local function setLightState(car, leftOn, rightOn)
    if not has_memory or not has_bit then
        setCarLightsOn(car, leftOn or rightOn)
        return
    end
    local carPtr = getCarPointer(car)
    if not carPtr or carPtr == 0 then
        setCarLightsOn(car, leftOn or rightOn)
        return
    end
    -- Адрес m_nLightsStatus: carPtr + 0x5A0 + 0x10 = carPtr + 0x5B0
    local lightAddr = carPtr + 0x5B0
    -- Читаем текущее состояние (4 байта, true = virtual protect)
    local lightVal = memory.read(lightAddr, 4, true) or 0
    -- Сбрасываем биты передних фар (bits 0-3)
    lightVal = bit.band(lightVal, 0xFFFFFFF0)
    -- Устанавливаем: 2 = DAMSTATE_DAMAGED (не светит)
    if not leftOn then lightVal = bit.bor(lightVal, 0x02) end   -- bits 0-1 = 2 (front-left damaged)
    if not rightOn then lightVal = bit.bor(lightVal, 0x08) end  -- bits 2-3 = 2 (front-right damaged)
    -- Пишем обратно (4 байта, true = virtual protect)
    memory.write(lightAddr, lightVal, 4, true)
end

-- Восстановить все фары (все целые = 0)
local function restoreAllLights(car)
    if has_memory and has_bit then
        local carPtr = getCarPointer(car)
        if carPtr and carPtr ~= 0 then
            local lightAddr = carPtr + 0x5B0
            local lightVal = memory.read(lightAddr, 4, false) or 0
            -- Сбрасываем все 8 бит (4 фары * 2 бита)
            lightVal = bit.band(lightVal, 0xFFFFFF00)
            memory.write(lightAddr, lightVal, 4, false)
            return
        end
    end
    -- Fallback
    if type(setCarLightDamageStatus) == "function" then
        pcall(setCarLightDamageStatus, car, 0, 0)
        pcall(setCarLightDamageStatus, car, 1, 0)
        pcall(setCarLightDamageStatus, car, 2, 0)
        pcall(setCarLightDamageStatus, car, 3, 0)
    end
end

function strobeWorker()
    local step = 1
    local last_car = nil
    local lights_initialized = false

    while strobe_active and strobe_enabled[0] do
        if isCharInAnyCar(PLAYER_PED) then
            local car = storeCarCharIsInNoSave(PLAYER_PED)
            if car and doesVehicleExist(car) then
                -- Включаем базовые фары при входе в машину (один раз)
                if not lights_initialized or car ~= last_car then
                    setCarLightsOn(car, true)
                    lights_initialized = true
                    last_car = car
                    step = 1
                end

                local mode = strobe_mode[0]
                local seq = strobe_sequences[mode]
                if not seq then seq = strobe_sequences[0] end

                local current_step = seq[step]
                if current_step then
                    local leftOn = (current_step[1] == 0)
                    local rightOn = (current_step[2] == 0)
                    setLightState(car, leftOn, rightOn)
                end

                step = step + 1
                if step > #seq then step = 1 end

                local delay = strobe_speed[0]
                wait(delay)
            else
                break
            end
        else
            break
        end
    end

    strobe_active = false

    -- Восстанавливаем фары при выходе
    if last_car and doesVehicleExist(last_car) then
        restoreAllLights(last_car)
    end
end


function getActiveVehicleSpeed(car)
    -- getCarVelocity не существует в MoonLoader, используем getCarSpeed
    local spd = getCarSpeed(car)
    local angle = getCarHeading(car)
    local rad = math.rad(angle)
    local x = -math.sin(rad) * (spd or 0)
    local y = math.cos(rad) * (spd or 0)
    return x, y, 0
end

-- СЛЕЖЕНИЕ ЗА ОРУЖИЕМ
local engine_debug_done = false
function isCarEngineOn(car)
    if not has_memory then
        if not engine_debug_done then
            sampAddChatMessage("[Helper] ENGINE DEBUG: no memory module", 0xFF0000)
            engine_debug_done = true
        end
        return true
    end
    local carPtr = getCarPointer(car)
    if not carPtr or carPtr == 0 then
        if not engine_debug_done then
            sampAddChatMessage("[Helper] ENGINE DEBUG: carPtr=nil/0", 0xFF0000)
            engine_debug_done = true
        end
        return true
    end
    -- Try multiple offsets to find the right one
    local val_428 = memory.read(carPtr + 0x428, 1, true) or -1
    local val_461 = memory.read(carPtr + 0x461, 1, true) or -1
    local val_462 = memory.read(carPtr + 0x462, 1, true) or -1
    if not engine_debug_done then
        sampAddChatMessage("[Helper] ENGINE DEBUG: carPtr=" .. tostring(carPtr) .. " 0x428=" .. tostring(val_428) .. " 0x461=" .. tostring(val_461) .. " 0x462=" .. tostring(val_462), 0x00FFFF)
        engine_debug_done = true
    end
    -- Use 0x428 for now
    return val_428 ~= 0
end

function cruiseControlWorker()
    local cruise_speed = 0
    local c_pressed = false
    local w_pressed = false
    local s_pressed = false
    local gas_on = false
    local gas_timer = 0
    local last_z = 0
    local z_check_time = 0
    local turbo_cooldown = 0
    local last_heading = 0
    local last_heading_time = 0
    local last_applied_speed = 0
    local last_speed_for_crash = 0
    local crash_cooldown = 0
    local ramp_step = 3
    local ramp_active = false
    while true do
        if isCharInAnyCar(PLAYER_PED) then
            local car = storeCarCharIsInNoSave(PLAYER_PED)
            if car and doesVehicleExist(car) then
                if isKeyDown(0x43) and not sampIsDialogActive() and not sampIsChatInputActive() then
                    if not c_pressed then
                        c_pressed = true
                        if not cruise_active then
                            local spd = getCarSpeed(car)
                            if spd and spd > 0.1 then
                                cruise_speed = spd
                                cruise_active = true
                                local mode = turbo_cruise_enabled[0] and "Turbo" or "Normal"
                                sampAddChatMessage("[Helper] Cruise ON [" .. mode .. "] W=+5 S=-5 C=off", 0x00FF00)
                            else
                                sampAddChatMessage("[Helper] Cruise: too slow", 0xFFAA00)
                            end
                        else
                            cruise_active = false
                            if gas_on then
                                setGameKeyState(16, 0)
                                gas_on = false
                            end
                            sampAddChatMessage("[Helper] Cruise: OFF", 0xFF0000)
                        end
                    end
                    wait(200)
                else
                    c_pressed = false
                end

                if cruise_active then
                    local is_turbo = turbo_cruise_enabled[0]

                    if isKeyDown(0x57) and not sampIsChatInputActive() then
                        if not w_pressed then
                            w_pressed = true
                            cruise_speed = cruise_speed + 5
                            sampAddChatMessage("[Helper] Cruise: " .. string.format("%.0f", cruise_speed) .. " (+5)", 0x00FFFF)
                        end
                        wait(150)
                    else
                        w_pressed = false
                    end

                    if isKeyDown(0x53) and not sampIsChatInputActive() then
                        if not s_pressed then
                            s_pressed = true
                            cruise_speed = math.max(5, cruise_speed - 5)
                            sampAddChatMessage("[Helper] Cruise: " .. string.format("%.0f", cruise_speed) .. " (-5)", 0x00FFFF)
                        end
                        wait(150)
                    else
                        s_pressed = false
                    end

                    local in_air = isCarInAirProper(car)
                    local current_speed = getCarSpeed(car)
                    local now = os.clock()

                    if is_turbo then
                        if gas_on then
                            setGameKeyState(16, 0)
                            gas_on = false
                        end

                        -- Engine check: if engine is OFF, turbo does nothing
                        if not isCarEngineOn(car) then
                            wait(100)
                        elseif last_speed_for_crash > 10 and current_speed < last_speed_for_crash * 0.6 then
                            crash_cooldown = 150
                            ramp_active = false
                            ramp_step = 2
                        end
                        last_speed_for_crash = current_speed or 0

                        if crash_cooldown > 0 then
                            crash_cooldown = crash_cooldown - 1
                            if crash_cooldown == 0 then
                                ramp_active = false
                                ramp_step = 3
                            end
                            wait(20)
                        else
                            -- Only check: not in air + has speed + below target
                            -- z_delta/h_delta removed - they blocked resume after crash
                            if not ramp_active then
                                ramp_active = true
                                ramp_step = 3
                            end

                            local can_apply = not in_air
                                           and current_speed
                                           and current_speed < cruise_speed
                            if can_apply then
                                -- Smooth ramp: start +3, grow +1 every frame, max +20
                                ramp_step = math.min(ramp_step + 1, 20)
                                local new_speed = current_speed + ramp_step
                                setCarForwardSpeed(car, new_speed)
                                last_applied_speed = new_speed
                            end
                            wait(10)
                        end
                    else
                        if in_air or not current_speed then
                            if gas_on then
                                setGameKeyState(16, 0)
                                gas_on = false
                            end
                        elseif current_speed >= cruise_speed and gas_on then
                            setGameKeyState(16, 0)
                            gas_on = false
                        elseif current_speed < cruise_speed * 0.95 and not gas_on then
                            setGameKeyState(16, 255)
                            gas_on = true
                        end
                        if gas_on then
                            setGameKeyState(16, 255)
                        end
                    end

                    wait(0)
                else
                    if gas_on then
                        setGameKeyState(16, 0)
                        gas_on = false
                    end
                    wait(50)
                end
            else
                cruise_active = false
                if gas_on then
                    setGameKeyState(16, 0)
                    gas_on = false
                end
                wait(200)
            end
        else
            cruise_active = false
            if gas_on then
                setGameKeyState(16, 0)
                gas_on = false
            end
            wait(500)
        end
    end
end

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
if isModuleEnabled("auto_rp") and rp_weapons_enabled[0] then
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
if os.time() - last_time > call_cooldown_hours[0] * 3600 then
call_current_nick = target.nick
call_current_phone = target.phone

sampAddChatMessage(u8:decode("[Helper] Обзвон: Звоним " .. target.nick .. " (Тел: " .. target.phone .. ") [" .. (called_count+1) .. "/" .. limit .. "]"), 0xFFFF00)

-- Вызов /call отыграется автоматически, так как мы зарегистрировали команду call
sampSendChat("/c " .. target.phone)

last_called[target.nick] = os.time()
called_count = called_count + 1
saveSettings()

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
imgui.Begin(u8"Universal Helper Platform v0.9 (28.06.2026)", show_main_window, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

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

-- AutoEdit ImGui Window
imgui.OnFrame(
    function() return ae_active[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowSize(imgui.ImVec2(600, 280), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8"AutoEdit - Редактор объявления", nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

        imgui.Text(u8"Оригинальный текст:")
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
        imgui.TextWrapped(ae_original_text)
        imgui.PopStyleColor()
        imgui.Separator()

        imgui.Text(u8"Отформатированный результат:")
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.8, 0.5, 1))
        imgui.TextWrapped(ae_formatted_text)
        imgui.PopStyleColor()
        imgui.Separator()

        imgui.Text(u8"Редактировать:")
        imgui.PushItemWidth(-1)
        if ae_focus then imgui.SetKeyboardFocusHere(0) end
        local ae_enter = imgui.InputText("##ae_input", ae_input_buf, ffi.sizeof(ae_input_buf), imgui.InputTextFlags.EnterReturnsTrue)
        ae_focus = false
        imgui.PopItemWidth()

        imgui.Spacing()

        if ae_enter or imgui.Button(u8"Отправить##send", imgui.ImVec2(120, 30)) then
            if ae_dialog_id >= 0 then
                local input_text = u8:decode(ffi.string(ae_input_buf))
                sampSendDialogResponse(ae_dialog_id, 1, -1, input_text)
            end
            ae_active[0] = false
        end

        imgui.SameLine()

        if imgui.Button(u8"Отклонить (ПРО)", imgui.ImVec2(160, 30)) or imgui.GetIO().KeysDown[0x1B] then
            if ae_dialog_id >= 0 then
                local tag = u8:decode(ffi.string(mm_tag))
                local reject_text = "ПРО"
                if tag and tag ~= "" then
                    reject_text = tag .. " | ПРО"
                end
                imgui.StrCopy(ae_input_buf, u8:encode(reject_text, encoding.default))
                sampSendDialogResponse(ae_dialog_id, 0, -1, reject_text)
            end
            ae_active[0] = false
        end

        imgui.End()
    end
)


