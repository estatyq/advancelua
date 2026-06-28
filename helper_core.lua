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
local test_input = imgui.new.char[128]("")
local test_output = ""
local mm_rules = {
-- Машины
{abbreviation = "булка", replacement = "а/м марки \"Bullet\""},
{abbreviation = "булку", replacement = "а/м марки \"Bullet\""},
{abbreviation = "булки", replacement = "а/м марки \"Bullet\""},
{abbreviation = "булке", replacement = "а/м марки \"Bullet\""},
{abbreviation = "булкой", replacement = "а/м марки \"Bullet\""},
{abbreviation = "инф", replacement = "а/м марки \"Infernus\""},
{abbreviation = "инфу", replacement = "а/м марки \"Infernus\""},
{abbreviation = "инфе", replacement = "а/м марки \"Infernus\""},
{abbreviation = "инфы", replacement = "а/м марки \"Infernus\""},
{abbreviation = "инфом", replacement = "а/м марки \"Infernus\""},
{abbreviation = "туризмо", replacement = "а/м марки \"Turismo\""},
{abbreviation = "турик", replacement = "а/м марки \"Turismo\""},
{abbreviation = "турика", replacement = "а/м марки \"Turismo\""},
{abbreviation = "турику", replacement = "а/м марки \"Turismo\""},
{abbreviation = "турике", replacement = "а/м марки \"Turismo\""},
{abbreviation = "банши", replacement = "а/м марки \"Banshee\""},
{abbreviation = "баншу", replacement = "а/м марки \"Banshee\""},
{abbreviation = "банше", replacement = "а/м марки \"Banshee\""},
{abbreviation = "баншей", replacement = "а/м марки \"Banshee\""},
{abbreviation = "чито", replacement = "а/м марки \"Cheetah\""},
{abbreviation = "читу", replacement = "а/м марки \"Cheetah\""},
{abbreviation = "чите", replacement = "а/м марки \"Cheetah\""},
{abbreviation = "супергт", replacement = "а/м марки \"Super GT\""},
{abbreviation = "супергта", replacement = "а/м марки \"Super GT\""},
{abbreviation = "супергту", replacement = "а/м марки \"Super GT\""},
{abbreviation = "стингер", replacement = "а/м марки \"Stinger\""},
{abbreviation = "стингера", replacement = "а/м марки \"Stinger\""},
{abbreviation = "стингеру", replacement = "а/м марки \"Stinger\""},
{abbreviation = "комета", replacement = "а/м марки \"Comet\""},
{abbreviation = "комету", replacement = "а/м марки \"Comet\""},
{abbreviation = "кометы", replacement = "а/м марки \"Comet\""},
{abbreviation = "комете", replacement = "а/м марки \"Comet\""},
{abbreviation = "феникс", replacement = "а/м марки \"Phoenix\""},
{abbreviation = "феникса", replacement = "а/м марки \"Phoenix\""},
{abbreviation = "фениксу", replacement = "а/м марки \"Phoenix\""},
{abbreviation = "чампион", replacement = "а/м марки \"Champion\""},
{abbreviation = "чампиона", replacement = "а/м марки \"Champion\""},
{abbreviation = "чампиону", replacement = "а/м марки \"Champion\""},
{abbreviation = "альфа", replacement = "а/м марки \"Alpha\""},
{abbreviation = "альфу", replacement = "а/м марки \"Alpha\""},
{abbreviation = "альфы", replacement = "а/м марки \"Alpha\""},
{abbreviation = "кловер", replacement = "а/м марки \"Clover\""},
{abbreviation = "кловера", replacement = "а/м марки \"Clover\""},
{abbreviation = "кловеру", replacement = "а/м марки \"Clover\""},
{abbreviation = "кловеры", replacement = "а/м марки \"Clover\""},
{abbreviation = "сабре", replacement = "а/м марки \"Sabre\""},
{abbreviation = "сабра", replacement = "а/м марки \"Sabre\""},
{abbreviation = "сабру", replacement = "а/м марки \"Sabre\""},
{abbreviation = "сабры", replacement = "а/м марки \"Sabre\""},
{abbreviation = "вуду", replacement = "а/м марки \"Voodoo\""},
{abbreviation = "вуды", replacement = "а/м марки \"Voodoo\""},
{abbreviation = "сламван", replacement = "а/м марки \"Slamvan\""},
{abbreviation = "сламвана", replacement = "а/м марки \"Slamvan\""},
{abbreviation = "сламвану", replacement = "а/м марки \"Slamvan\""},
{abbreviation = "ремингтон", replacement = "а/м марки \"Remington\""},
{abbreviation = "ремингтона", replacement = "а/м марки \"Remington\""},
{abbreviation = "ремингтону", replacement = "а/м марки \"Remington\""},
{abbreviation = "бравура", replacement = "а/м марки \"Bravura\""},
{abbreviation = "бравуру", replacement = "а/м марки \"Bravura\""},
{abbreviation = "бравуры", replacement = "а/м марки \"Bravura\""},
{abbreviation = "блейд", replacement = "а/м марки \"Blade\""},
{abbreviation = "блейда", replacement = "а/м марки \"Blade\""},
{abbreviation = "блейду", replacement = "а/м марки \"Blade\""},
{abbreviation = "тампла", replacement = "а/м марки \"Tampa\""},
{abbreviation = "тамплу", replacement = "а/м марки \"Tampa\""},
{abbreviation = "торнадо", replacement = "а/м марки \"Tornado\""},
{abbreviation = "торнадоа", replacement = "а/м марки \"Tornado\""},
{abbreviation = "торнадоу", replacement = "а/м марки \"Tornado\""},
{abbreviation = "султан", replacement = "а/м марки \"Sultan\""},
{abbreviation = "султана", replacement = "а/м марки \"Sultan\""},
{abbreviation = "султану", replacement = "а/м марки \"Sultan\""},
{abbreviation = "султаны", replacement = "а/м марки \"Sultan\""},
{abbreviation = "султане", replacement = "а/м марки \"Sultan\""},
{abbreviation = "султаном", replacement = "а/м марки \"Sultan\""},
{abbreviation = "сультан", replacement = "а/м марки \"Sultan\""},
{abbreviation = "сультана", replacement = "а/м марки \"Sultan\""},
{abbreviation = "сультану", replacement = "а/м марки \"Sultan\""},
{abbreviation = "сультаны", replacement = "а/м марки \"Sultan\""},
{abbreviation = "елегию", replacement = "а/м марки \"Elegy\""},
{abbreviation = "еледжи", replacement = "а/м марки \"Elegy\""},
{abbreviation = "елеги", replacement = "а/м марки \"Elegy\""},
{abbreviation = "елегия", replacement = "а/м марки \"Elegy\""},
{abbreviation = "елеге", replacement = "а/м марки \"Elegy\""},
{abbreviation = "флеш", replacement = "а/м марки \"Flash\""},
{abbreviation = "флеша", replacement = "а/м марки \"Flash\""},
{abbreviation = "флешу", replacement = "а/м марки \"Flash\""},
{abbreviation = "джестер", replacement = "а/м марки \"Jester\""},
{abbreviation = "джестера", replacement = "а/м марки \"Jester\""},
{abbreviation = "джестеру", replacement = "а/м марки \"Jester\""},
{abbreviation = "стратум", replacement = "а/м марки \"Stratum\""},
{abbreviation = "стратума", replacement = "а/м марки \"Stratum\""},
{abbreviation = "стратуму", replacement = "а/м марки \"Stratum\""},
{abbreviation = "уран", replacement = "а/м марки \"Uranus\""},
{abbreviation = "урана", replacement = "а/м марки \"Uranus\""},
{abbreviation = "урану", replacement = "а/м марки \"Uranus\""},
{abbreviation = "ураны", replacement = "а/м марки \"Uranus\""},
{abbreviation = "салат", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "салата", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "салату", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "стрикер", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "стрикера", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "адреналин", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "адреналина", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "пикап", replacement = "а/м марки \"Picador\""},
{abbreviation = "пикапа", replacement = "а/м марки \"Picador\""},
{abbreviation = "пикапу", replacement = "а/м марки \"Picador\""},
{abbreviation = "соляр", replacement = "а/м марки \"Solair\""},
{abbreviation = "соляра", replacement = "а/м марки \"Solair\""},
{abbreviation = "соляру", replacement = "а/м марки \"Solair\""},
{abbreviation = "винсаг", replacement = "а/м марки \"Windsor\""},
{abbreviation = "винсага", replacement = "а/м марки \"Windsor\""},
{abbreviation = "винсагу", replacement = "а/м марки \"Windsor\""},
{abbreviation = "шафтер", replacement = "а/м марки \"Stafford\""},
{abbreviation = "шафтера", replacement = "а/м марки \"Stafford\""},
{abbreviation = "шафтеру", replacement = "а/м марки \"Stafford\""},
{abbreviation = "хантер", replacement = "а/м марки \"Huntley\""},
{abbreviation = "хантера", replacement = "а/м марки \"Huntley\""},
{abbreviation = "хантеру", replacement = "а/м марки \"Huntley\""},
{abbreviation = "ранчер", replacement = "а/м марки \"Rancher\""},
{abbreviation = "ранчера", replacement = "а/м марки \"Rancher\""},
{abbreviation = "ранчеру", replacement = "а/м марки \"Rancher\""},
{abbreviation = "ранчо", replacement = "а/м марки \"Rancher\""},
{abbreviation = "ранчоа", replacement = "а/м марки \"Rancher\""},
{abbreviation = "йосемити", replacement = "а/м марки \"Yosemite\""},
{abbreviation = "йосемитиа", replacement = "а/м марки \"Yosemite\""},
{abbreviation = "бобкэт", replacement = "а/м марки \"Bobcat\""},
{abbreviation = "бобкэта", replacement = "а/м марки \"Bobcat\""},
{abbreviation = "бобкэту", replacement = "а/м марки \"Bobcat\""},
{abbreviation = "премьер", replacement = "а/м марки \"Premier\""},
{abbreviation = "премьера", replacement = "а/м марки \"Premier\""},
{abbreviation = "премьеру", replacement = "а/м марки \"Premier\""},
{abbreviation = "стретч", replacement = "а/м марки \"Stretch\""},
{abbreviation = "стретча", replacement = "а/м марки \"Stretch\""},
{abbreviation = "стретчу", replacement = "а/м марки \"Stretch\""},
{abbreviation = "адмирал", replacement = "а/м марки \"Admiral\""},
{abbreviation = "адмирала", replacement = "а/м марки \"Admiral\""},
{abbreviation = "адмиралу", replacement = "а/м марки \"Admiral\""},
{abbreviation = "вашингтон", replacement = "а/м марки \"Washington\""},
{abbreviation = "вашингтона", replacement = "а/м марки \"Washington\""},
{abbreviation = "вашингтону", replacement = "а/м марки \"Washington\""},
{abbreviation = "винвуд", replacement = "а/м марки \"Willard\""},
{abbreviation = "винвуда", replacement = "а/м марки \"Willard\""},
{abbreviation = "эмперор", replacement = "а/м марки \"Emperor\""},
{abbreviation = "эмперора", replacement = "а/м марки \"Emperor\""},
{abbreviation = "эмперору", replacement = "а/м марки \"Emperor\""},
{abbreviation = "элеганс", replacement = "а/м марки \"Elegant\""},
{abbreviation = "элеганса", replacement = "а/м марки \"Elegant\""},
{abbreviation = "элегансу", replacement = "а/м марки \"Elegant\""},
{abbreviation = "глендейл", replacement = "а/м марки \"Glendale\""},
{abbreviation = "глендейла", replacement = "а/м марки \"Glendale\""},
{abbreviation = "глендейлу", replacement = "а/м марки \"Glendale\""},
{abbreviation = "манана", replacement = "а/м марки \"Manana\""},
{abbreviation = "манану", replacement = "а/м марки \"Manana\""},
{abbreviation = "мананы", replacement = "а/м марки \"Manana\""},
{abbreviation = "манане", replacement = "а/м марки \"Manana\""},
{abbreviation = "блиста", replacement = "а/м марки \"Blista\""},
{abbreviation = "блисту", replacement = "а/м марки \"Blista\""},
{abbreviation = "блисты", replacement = "а/м марки \"Blista\""},
{abbreviation = "фортун", replacement = "а/м марки \"Fortune\""},
{abbreviation = "фортуна", replacement = "а/м марки \"Fortune\""},
{abbreviation = "фортуну", replacement = "а/м марки \"Fortune\""},
{abbreviation = "сентинел", replacement = "а/м марки \"Sentinel\""},
{abbreviation = "сентинела", replacement = "а/м марки \"Sentinel\""},
{abbreviation = "сентинелу", replacement = "а/м марки \"Sentinel\""},
{abbreviation = "букер", replacement = "а/м марки \"Buccaneer\""},
{abbreviation = "букера", replacement = "а/м марки \"Buccaneer\""},
{abbreviation = "букеру", replacement = "а/м марки \"Buccaneer\""},
{abbreviation = "хёрмит", replacement = "а/м марки \"Hermes\""},
{abbreviation = "хёрмита", replacement = "а/м марки \"Hermes\""},
{abbreviation = "хёрмиту", replacement = "а/м марки \"Hermes\""},
{abbreviation = "маджестик", replacement = "а/м марки \"Majestic\""},
{abbreviation = "маджестика", replacement = "а/м марки \"Majestic\""},
{abbreviation = "невада", replacement = "а/м марки \"Nevada\""},
{abbreviation = "неваду", replacement = "а/м марки \"Nevada\""},
{abbreviation = "невады", replacement = "а/м марки \"Nevada\""},
{abbreviation = "примо", replacement = "а/м марки \"Primo\""},
{abbreviation = "примоа", replacement = "а/м марки \"Primo\""},
{abbreviation = "хоткнайф", replacement = "а/м марки \"Hotknife\""},
{abbreviation = "хоткнайфа", replacement = "а/м марки \"Hotknife\""},
{abbreviation = "хоткнайфу", replacement = "а/м марки \"Hotknife\""},
{abbreviation = "дюна", replacement = "а/м марки \"Dune\""},
{abbreviation = "дюну", replacement = "а/м марки \"Dune\""},
{abbreviation = "дюны", replacement = "а/м марки \"Dune\""},
{abbreviation = "дюне", replacement = "а/м марки \"Dune\""},
{abbreviation = "монстр", replacement = "а/м марки \"Monster\""},
{abbreviation = "монстра", replacement = "а/м марки \"Monster\""},
{abbreviation = "монстру", replacement = "а/м марки \"Monster\""},
{abbreviation = "монстры", replacement = "а/м марки \"Monster\""},
{abbreviation = "бандито", replacement = "а/м марки \"Bandito\""},
{abbreviation = "бандита", replacement = "а/м марки \"Bandito\""},
{abbreviation = "бандиту", replacement = "а/м марки \"Bandito\""},
{abbreviation = "кальцо", replacement = "а/м марки \"Calcium\""},
{abbreviation = "кальцию", replacement = "а/м марки \"Calcium\""},
{abbreviation = "кальция", replacement = "а/м марки \"Calcium\""},
{abbreviation = "патриот", replacement = "а/м марки \"Patriot\""},
{abbreviation = "патриота", replacement = "а/м марки \"Patriot\""},
{abbreviation = "патриоту", replacement = "а/м марки \"Patriot\""},
{abbreviation = "хотринг", replacement = "а/м марки \"Hotring\""},
{abbreviation = "хотринга", replacement = "а/м марки \"Hotring\""},
{abbreviation = "хотрингу", replacement = "а/м марки \"Hotring\""},
{abbreviation = "хотрингер", replacement = "а/м марки \"Hotring\""},
{abbreviation = "хотрингера", replacement = "а/м марки \"Hotring\""},
{abbreviation = "багги", replacement = "а/м марки \"Bandito\""},
{abbreviation = "баггиа", replacement = "а/м марки \"Bandito\""},
{abbreviation = "крэйг", replacement = "а/м марки \"Crane\""},
{abbreviation = "крэйга", replacement = "а/м марки \"Crane\""},
{abbreviation = "инфернус", replacement = "а/м марки \"Infernus\""},
{abbreviation = "инфернуса", replacement = "а/м марки \"Infernus\""},
{abbreviation = "инфернусу", replacement = "а/м марки \"Infernus\""},
{abbreviation = "буллет", replacement = "а/м марки \"Bullet\""},
{abbreviation = "буллета", replacement = "а/м марки \"Bullet\""},
{abbreviation = "буллету", replacement = "а/м марки \"Bullet\""},
{abbreviation = "турисмо", replacement = "а/м марки \"Turismo\""},
{abbreviation = "турисмоа", replacement = "а/м марки \"Turismo\""},
{abbreviation = "ковбой", replacement = "а/м марки \"Clover\""},
{abbreviation = "ковбоя", replacement = "а/м марки \"Clover\""},
{abbreviation = "сэлбрайт", replacement = "а/м марки \"Sultan\""},
{abbreviation = "сэлбрайта", replacement = "а/м марки \"Sultan\""},
{abbreviation = "тампико", replacement = "а/м марки \"Tampa\""},
{abbreviation = "фортуне", replacement = "а/м марки \"Fortune\""},
{abbreviation = "фортунеа", replacement = "а/м марки \"Fortune\""},
{abbreviation = "элегант", replacement = "а/м марки \"Elegant\""},
{abbreviation = "элеганта", replacement = "а/м марки \"Elegant\""},
{abbreviation = "октан", replacement = "а/м марки \"Uranus\""},
{abbreviation = "октана", replacement = "а/м марки \"Uranus\""},
{abbreviation = "октану", replacement = "а/м марки \"Uranus\""},
{abbreviation = "зр350", replacement = "а/м марки \"ZR-350\""},
{abbreviation = "зр350а", replacement = "а/м марки \"ZR-350\""},
{abbreviation = "зр", replacement = "а/м марки \"ZR-350\""},
{abbreviation = "зра", replacement = "а/м марки \"ZR-350\""},
{abbreviation = "файрберд", replacement = "а/м марки \"Phoenix\""},
{abbreviation = "файрберда", replacement = "а/м марки \"Phoenix\""},
{abbreviation = "чирок", replacement = "а/м марки \"Cheetah\""},
{abbreviation = "чирока", replacement = "а/м марки \"Cheetah\""},
{abbreviation = "банка", replacement = "а/м марки \"Banshee\""},
{abbreviation = "банку", replacement = "а/м марки \"Banshee\""},
{abbreviation = "шевроле", replacement = "а/м марки \"Chevrolet\""},
{abbreviation = "шевролеа", replacement = "а/м марки \"Chevrolet\""},
{abbreviation = "ламбо", replacement = "а/м марки \"Lamborghini\""},
{abbreviation = "ламбу", replacement = "а/м марки \"Lamborghini\""},
{abbreviation = "бмв", replacement = "а/м марки \"BMW\""},
{abbreviation = "бмву", replacement = "а/м марки \"BMW\""},
{abbreviation = "мерс", replacement = "а/м марки \"Mercedes\""},
{abbreviation = "мерса", replacement = "а/м марки \"Mercedes\""},
{abbreviation = "мерсу", replacement = "а/м марки \"Mercedes\""},
{abbreviation = "тойота", replacement = "а/м марки \"Toyota\""},
{abbreviation = "тойоту", replacement = "а/м марки \"Toyota\""},
{abbreviation = "тойоты", replacement = "а/м марки \"Toyota\""},
{abbreviation = "ауди", replacement = "а/м марки \"Audi\""},
{abbreviation = "аудиа", replacement = "а/м марки \"Audi\""},
{abbreviation = "порше", replacement = "а/м марки \"Porsche\""},
{abbreviation = "поршеа", replacement = "а/м марки \"Porsche\""},
{abbreviation = "феррари", replacement = "а/м марки \"Ferrari\""},
{abbreviation = "феррариа", replacement = "а/м марки \"Ferrari\""},
{abbreviation = "лексус", replacement = "а/м марки \"Lexus\""},
{abbreviation = "лексуса", replacement = "а/м марки \"Lexus\""},
{abbreviation = "хонда", replacement = "а/м марки \"Honda\""},
{abbreviation = "хонду", replacement = "а/м марки \"Honda\""},
{abbreviation = "хонды", replacement = "а/м марки \"Honda\""},
{abbreviation = "ниссан", replacement = "а/м марки \"Nissan\""},
{abbreviation = "ниссана", replacement = "а/м марки \"Nissan\""},
{abbreviation = "мазда", replacement = "а/м марки \"Mazda\""},
{abbreviation = "мазду", replacement = "а/м марки \"Mazda\""},
{abbreviation = "мазды", replacement = "а/м марки \"Mazda\""},
{abbreviation = "субару", replacement = "а/м марки \"Subaru\""},
{abbreviation = "субаруа", replacement = "а/м марки \"Subaru\""},
{abbreviation = "митсубиси", replacement = "а/м марки \"Mitsubishi\""},
{abbreviation = "крайслер", replacement = "а/м марки \"Chrysler\""},
{abbreviation = "крайслера", replacement = "а/м марки \"Chrysler\""},
{abbreviation = "форд", replacement = "а/м марки \"Ford\""},
{abbreviation = "форда", replacement = "а/м марки \"Ford\""},
{abbreviation = "форду", replacement = "а/м марки \"Ford\""},
{abbreviation = "вольво", replacement = "а/м марки \"Volvo\""},
{abbreviation = "бьюик", replacement = "а/м марки \"Buick\""},
{abbreviation = "бьюика", replacement = "а/м марки \"Buick\""},
{abbreviation = "кадиллак", replacement = "а/м марки \"Cadillac\""},
{abbreviation = "кадиллака", replacement = "а/м марки \"Cadillac\""},
{abbreviation = "понтиак", replacement = "а/м марки \"Pontiac\""},
{abbreviation = "понтиака", replacement = "а/м марки \"Pontiac\""},
{abbreviation = "додж", replacement = "а/м марки \"Dodge\""},
{abbreviation = "доджа", replacement = "а/м марки \"Dodge\""},
{abbreviation = "доджу", replacement = "а/м марки \"Dodge\""},
{abbreviation = "ягуар", replacement = "а/м марки \"Jaguar\""},
{abbreviation = "ягуара", replacement = "а/м марки \"Jaguar\""},
{abbreviation = "бентли", replacement = "а/м марки \"Bentley\""},
{abbreviation = "бентлиа", replacement = "а/м марки \"Bentley\""},
{abbreviation = "роллсройс", replacement = "а/м марки \"Rolls-Royce\""},
{abbreviation = "мазерати", replacement = "а/м марки \"Maserati\""},
{abbreviation = "астонмартин", replacement = "а/м марки \"Aston Martin\""},
{abbreviation = "бугатти", replacement = "а/м марки \"Bugatti\""},
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
{abbreviation = "нрг", replacement = "мото марки \"NRG-500\""},
{abbreviation = "нргу", replacement = "мото марки \"NRG-500\""},
{abbreviation = "нрга", replacement = "мото марки \"NRG-500\""},
{abbreviation = "нрге", replacement = "мото марки \"NRG-500\""},
{abbreviation = "нрги", replacement = "мото марки \"NRG-500\""},
{abbreviation = "фрей", replacement = "мото марки \"Freeway\""},
{abbreviation = "фрея", replacement = "мото марки \"Freeway\""},
{abbreviation = "фрею", replacement = "мото марки \"Freeway\""},
{abbreviation = "вейб", replacement = "мото марки \"Wayfarer\""},
{abbreviation = "вейба", replacement = "мото марки \"Wayfarer\""},
{abbreviation = "вейбу", replacement = "мото марки \"Wayfarer\""},
{abbreviation = "санч", replacement = "мото марки \"Sanchez\""},
{abbreviation = "санчез", replacement = "мото марки \"Sanchez\""},
{abbreviation = "санча", replacement = "мото марки \"Sanchez\""},
{abbreviation = "санчу", replacement = "мото марки \"Sanchez\""},
{abbreviation = "пжж", replacement = "мото марки \"PCJ-600\""},
{abbreviation = "пжжа", replacement = "мото марки \"PCJ-600\""},
{abbreviation = "пжжу", replacement = "мото марки \"PCJ-600\""},
{abbreviation = "фцз", replacement = "мото марки \"FCR-900\""},
{abbreviation = "фцза", replacement = "мото марки \"FCR-900\""},
{abbreviation = "фцзу", replacement = "мото марки \"FCR-900\""},
{abbreviation = "фаггио", replacement = "мото марки \"Faggio\""},
{abbreviation = "фагио", replacement = "мото марки \"Faggio\""},
{abbreviation = "фаггиу", replacement = "мото марки \"Faggio\""},
{abbreviation = "бф", replacement = "мото марки \"BF-400\""},
{abbreviation = "бфа", replacement = "мото марки \"BF-400\""},
{abbreviation = "эндюро", replacement = "мото марки \"Enduro\""},
{abbreviation = "эндюра", replacement = "мото марки \"Enduro\""},
{abbreviation = "ангел", replacement = "мото марки \"Angel\""},
{abbreviation = "ангела", replacement = "мото марки \"Angel\""},
-- Велосипеды
{abbreviation = "бмх", replacement = "велосипед марки \"BMX\""},
{abbreviation = "бмха", replacement = "велосипед марки \"BMX\""},
{abbreviation = "бмху", replacement = "велосипед марки \"BMX\""},
{abbreviation = "байк", replacement = "велосипед марки \"BMX\""},
{abbreviation = "байка", replacement = "велосипед марки \"BMX\""},
{abbreviation = "байку", replacement = "велосипед марки \"BMX\""},
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
{abbreviation = "катана", replacement = "оружие \"Katana\""},
{abbreviation = "катану", replacement = "оружие \"Katana\""},
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
{abbreviation = "сэлбрайт", replacement = "а/м марки \"Sultan\""},
{abbreviation = "ковбой", replacement = "а/м марки \"Clover\""},
{abbreviation = "чирок", replacement = "а/м марки \"Cheetah\""},
{abbreviation = "банка", replacement = "а/м марки \"Banshee\""},
{abbreviation = "файрберд", replacement = "а/м марки \"Phoenix\""},
{abbreviation = "октан", replacement = "а/м марки \"Uranus\""},
{abbreviation = "зр350", replacement = "а/м марки \"ZR-350\""},
{abbreviation = "зр", replacement = "а/м марки \"ZR-350\""},
{abbreviation = "инфернус", replacement = "а/м марки \"Infernus\""},
{abbreviation = "инфернуса", replacement = "а/м марки \"Infernus\""},
{abbreviation = "буллет", replacement = "а/м марки \"Bullet\""},
{abbreviation = "буллета", replacement = "а/м марки \"Bullet\""},
{abbreviation = "турисмо", replacement = "а/м марки \"Turismo\""},
{abbreviation = "ковер", replacement = "а/м марки \"Clover\""},
{abbreviation = "элегант", replacement = "а/м марки \"Elegant\""},
{abbreviation = "элеганта", replacement = "а/м марки \"Elegant\""},
{abbreviation = "фортуне", replacement = "а/м марки \"Fortune\""},
{abbreviation = "тампико", replacement = "а/м марки \"Tampa\""},
{abbreviation = "глендейл", replacement = "а/м марки \"Glendale\""},
{abbreviation = "глендейла", replacement = "а/м марки \"Glendale\""},
{abbreviation = "эмперор", replacement = "а/м марки \"Emperor\""},
{abbreviation = "эмперора", replacement = "а/м марки \"Emperor\""},
{abbreviation = "невада", replacement = "а/м марки \"Nevada\""},
{abbreviation = "неваду", replacement = "а/м марки \"Nevada\""},
{abbreviation = "примо", replacement = "а/м марки \"Primo\""},
{abbreviation = "маджестик", replacement = "а/м марки \"Majestic\""},
{abbreviation = "маджестика", replacement = "а/м марки \"Majestic\""},
{abbreviation = "винвуд", replacement = "а/м марки \"Willard\""},
{abbreviation = "винвуда", replacement = "а/м марки \"Willard\""},
{abbreviation = "вашингтон", replacement = "а/м марки \"Washington\""},
{abbreviation = "вашингтона", replacement = "а/м марки \"Washington\""},
{abbreviation = "адмирал", replacement = "а/м марки \"Admiral\""},
{abbreviation = "адмирала", replacement = "а/м марки \"Admiral\""},
{abbreviation = "ранчер", replacement = "а/м марки \"Rancher\""},
{abbreviation = "ранчера", replacement = "а/м марки \"Rancher\""},
{abbreviation = "ранчо", replacement = "а/м марки \"Rancher\""},
{abbreviation = "бобкэт", replacement = "а/м марки \"Bobcat\""},
{abbreviation = "бобкэта", replacement = "а/м марки \"Bobcat\""},
{abbreviation = "йосемити", replacement = "а/м марки \"Yosemite\""},
{abbreviation = "валдшнеп", replacement = "а/м марки \"Walton\""},
{abbreviation = "валдшнепа", replacement = "а/м марки \"Walton\""},
{abbreviation = "торнадо", replacement = "а/м марки \"Tornado\""},
{abbreviation = "торнадоа", replacement = "а/м марки \"Tornado\""},
{abbreviation = "блейд", replacement = "а/м марки \"Blade\""},
{abbreviation = "блейда", replacement = "а/м марки \"Blade\""},
{abbreviation = "тампла", replacement = "а/м марки \"Tampa\""},
{abbreviation = "тамплу", replacement = "а/м марки \"Tampa\""},
{abbreviation = "альфа", replacement = "а/м марки \"Alpha\""},
{abbreviation = "альфу", replacement = "а/м марки \"Alpha\""},
{abbreviation = "комета", replacement = "а/м марки \"Comet\""},
{abbreviation = "комету", replacement = "а/м марки \"Comet\""},
{abbreviation = "стингер", replacement = "а/м марки \"Stinger\""},
{abbreviation = "стингера", replacement = "а/м марки \"Stinger\""},
{abbreviation = "супергт", replacement = "а/м марки \"Super GT\""},
{abbreviation = "супергта", replacement = "а/м марки \"Super GT\""},
{abbreviation = "чампион", replacement = "а/м марки \"Champion\""},
{abbreviation = "чампиона", replacement = "а/м марки \"Champion\""},
{abbreviation = "букер", replacement = "а/м марки \"Buccaneer\""},
{abbreviation = "букера", replacement = "а/м марки \"Buccaneer\""},
{abbreviation = "хёрмит", replacement = "а/м марки \"Hermes\""},
{abbreviation = "хёрмита", replacement = "а/м марки \"Hermes\""},
{abbreviation = "сентинел", replacement = "а/м марки \"Sentinel\""},
{abbreviation = "сентинела", replacement = "а/м марки \"Sentinel\""},
{abbreviation = "фортун", replacement = "а/м марки \"Fortune\""},
{abbreviation = "фортуна", replacement = "а/м марки \"Fortune\""},
{abbreviation = "фортуну", replacement = "а/м марки \"Fortune\""},
{abbreviation = "блиста", replacement = "а/м марки \"Blista\""},
{abbreviation = "блисту", replacement = "а/м марки \"Blista\""},
{abbreviation = "манана", replacement = "а/м марки \"Manana\""},
{abbreviation = "манану", replacement = "а/м марки \"Manana\""},
{abbreviation = "пикап", replacement = "а/м марки \"Picador\""},
{abbreviation = "пикапа", replacement = "а/м марки \"Picador\""},
{abbreviation = "соляр", replacement = "а/м марки \"Solair\""},
{abbreviation = "соляра", replacement = "а/м марки \"Solair\""},
{abbreviation = "винсаг", replacement = "а/м марки \"Windsor\""},
{abbreviation = "винсага", replacement = "а/м марки \"Windsor\""},
{abbreviation = "шафтер", replacement = "а/м марки \"Stafford\""},
{abbreviation = "шафтера", replacement = "а/м марки \"Stafford\""},
{abbreviation = "хантер", replacement = "а/м марки \"Huntley\""},
{abbreviation = "хантера", replacement = "а/м марки \"Huntley\""},
{abbreviation = "патриот", replacement = "а/м марки \"Patriot\""},
{abbreviation = "патриота", replacement = "а/м марки \"Patriot\""},
{abbreviation = "монстр", replacement = "а/м марки \"Monster\""},
{abbreviation = "монстра", replacement = "а/м марки \"Monster\""},
{abbreviation = "бандито", replacement = "а/м марки \"Bandito\""},
{abbreviation = "бандита", replacement = "а/м марки \"Bandito\""},
{abbreviation = "кальцо", replacement = "а/м марки \"Calcium\""},
{abbreviation = "кальция", replacement = "а/м марки \"Calcium\""},
{abbreviation = "хотринг", replacement = "а/м марки \"Hotring\""},
{abbreviation = "хотринга", replacement = "а/м марки \"Hotring\""},
{abbreviation = "хотрингер", replacement = "а/м марки \"Hotring\""},
{abbreviation = "багги", replacement = "а/м марки \"Bandito\""},
{abbreviation = "крэйг", replacement = "а/м марки \"Crane\""},
{abbreviation = "стретч", replacement = "а/м марки \"Stretch\""},
{abbreviation = "стретча", replacement = "а/м марки \"Stretch\""},
{abbreviation = "премьер", replacement = "а/м марки \"Premier\""},
{abbreviation = "премьера", replacement = "а/м марки \"Premier\""},
{abbreviation = "бравура", replacement = "а/м марки \"Bravura\""},
{abbreviation = "бравуру", replacement = "а/м марки \"Bravura\""},
{abbreviation = "сламван", replacement = "а/м марки \"Slamvan\""},
{abbreviation = "сламвана", replacement = "а/м марки \"Slamvan\""},
{abbreviation = "ремингтон", replacement = "а/м марки \"Remington\""},
{abbreviation = "ремингтона", replacement = "а/м марки \"Remington\""},
{abbreviation = "флеш", replacement = "а/м марки \"Flash\""},
{abbreviation = "флеша", replacement = "а/м марки \"Flash\""},
{abbreviation = "джестер", replacement = "а/м марки \"Jester\""},
{abbreviation = "джестера", replacement = "а/м марки \"Jester\""},
{abbreviation = "стратум", replacement = "а/м марки \"Stratum\""},
{abbreviation = "стратума", replacement = "а/м марки \"Stratum\""},
{abbreviation = "уран", replacement = "а/м марки \"Uranus\""},
{abbreviation = "урана", replacement = "а/м марки \"Uranus\""},
{abbreviation = "салат", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "салата", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "стрикер", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "адреналин", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "адреналина", replacement = "а/м марки \"Sultan RS\""},
{abbreviation = "хоткнайф", replacement = "а/м марки \"Hotknife\""},
{abbreviation = "хоткнайфа", replacement = "а/м марки \"Hotknife\""},
{abbreviation = "дюна", replacement = "а/м марки \"Dune\""},
{abbreviation = "дюну", replacement = "а/м марки \"Dune\""},
{abbreviation = "дюны", replacement = "а/м марки \"Dune\""},
{abbreviation = "сабре", replacement = "а/м марки \"Sabre\""},
{abbreviation = "сабра", replacement = "а/м марки \"Sabre\""},
{abbreviation = "сабру", replacement = "а/м марки \"Sabre\""},
{abbreviation = "вуду", replacement = "а/м марки \"Voodoo\""},
{abbreviation = "кловер", replacement = "а/м марки \"Clover\""},
{abbreviation = "кловера", replacement = "а/м марки \"Clover\""},
{abbreviation = "булка", replacement = "а/м марки \"Bullet\""},
{abbreviation = "булку", replacement = "а/м марки \"Bullet\""},
{abbreviation = "булки", replacement = "а/м марки \"Bullet\""},
{abbreviation = "инф", replacement = "а/м марки \"Infernus\""},
{abbreviation = "инфу", replacement = "а/м марки \"Infernus\""},
{abbreviation = "туризмо", replacement = "а/м марки \"Turismo\""},
{abbreviation = "турик", replacement = "а/м марки \"Turismo\""},
{abbreviation = "банши", replacement = "а/м марки \"Banshee\""},
{abbreviation = "баншу", replacement = "а/м марки \"Banshee\""},
{abbreviation = "чито", replacement = "а/м марки \"Cheetah\""},
{abbreviation = "читу", replacement = "а/м марки \"Cheetah\""},
{abbreviation = "феникс", replacement = "а/м марки \"Phoenix\""},
{abbreviation = "феникса", replacement = "а/м марки \"Phoenix\""},
{abbreviation = "тахома", replacement = "а/м марки \"Tahoma\""},
{abbreviation = "тахому", replacement = "а/м марки \"Tahoma\""},
{abbreviation = "султан", replacement = "а/м марки \"Sultan\""},
{abbreviation = "султана", replacement = "а/м марки \"Sultan\""},
{abbreviation = "султану", replacement = "а/м марки \"Sultan\""},
{abbreviation = "сультан", replacement = "а/м марки \"Sultan\""},
{abbreviation = "елегию", replacement = "а/м марки \"Elegy\""},
{abbreviation = "еледжи", replacement = "а/м марки \"Elegy\""},
{abbreviation = "елеги", replacement = "а/м марки \"Elegy\""},
{abbreviation = "елегия", replacement = "а/м марки \"Elegy\""},
{abbreviation = "нрг", replacement = "мото марки \"NRG-500\""},
{abbreviation = "нргу", replacement = "мото марки \"NRG-500\""},
{abbreviation = "нрга", replacement = "мото марки \"NRG-500\""},
{abbreviation = "нрге", replacement = "мото марки \"NRG-500\""},
{abbreviation = "фрей", replacement = "мото марки \"Freeway\""},
{abbreviation = "фрея", replacement = "мото марки \"Freeway\""},
{abbreviation = "фрею", replacement = "мото марки \"Freeway\""},
{abbreviation = "вейб", replacement = "мото марки \"Wayfarer\""},
{abbreviation = "вейба", replacement = "мото марки \"Wayfarer\""},
{abbreviation = "санч", replacement = "мото марки \"Sanchez\""},
{abbreviation = "санчез", replacement = "мото марки \"Sanchez\""},
{abbreviation = "санча", replacement = "мото марки \"Sanchez\""},
{abbreviation = "санчу", replacement = "мото марки \"Sanchez\""},
{abbreviation = "пжж", replacement = "мото марки \"PCJ-600\""},
{abbreviation = "пжжа", replacement = "мото марки \"PCJ-600\""},
{abbreviation = "фцз", replacement = "мото марки \"FCR-900\""},
{abbreviation = "фцза", replacement = "мото марки \"FCR-900\""},
{abbreviation = "фаггио", replacement = "мото марки \"Faggio\""},
{abbreviation = "фагио", replacement = "мото марки \"Faggio\""},
{abbreviation = "бф", replacement = "мото марки \"BF-400\""},
{abbreviation = "эндюро", replacement = "мото марки \"Enduro\""},
{abbreviation = "ангел", replacement = "мото марки \"Angel\""},
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
{abbreviation = "катана", replacement = "оружие \"Katana\""},
{abbreviation = "катану", replacement = "оружие \"Katana\""},
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
{abbreviation = "бмх", replacement = "велосипед марки \"BMX\""},
{abbreviation = "велик", replacement = "велосипед"},
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

-- Detect car keywords (to skip city removal for cars)
local is_car = false
local car_keywords = {"булк", "инф", "туризм", "турик", "кловер", "хоткнайф", "дюн", "сультан", "султан", "елег", "банш", "чито", "феникс", "тахом", "премьер", "стретч", "бравур", "сабре", "вуду", "сламван", "ремингтон", "флеш", "джестер", "стратум", "уран", "блист", "баффал", "зомби", "ламбо", "бмв", "мерс", "тойот", "монстр", "бандит", "комет", "стингер", "супергт", "манан", "пикап", "соляр", "винсаг", "шафтер", "альпин", "беггал", "кальц", "салат", "стрикер", "адреналин", "нрг", "фрей", "вейб", "санч", "пжж", "фцз", "фаггио", "фагио", "бмх", "эндюро", "мото", "машин", "а/м", "м/ц", "тачк", "таз", "байк", "велосипед", "велик"}
for _, word in ipairs(car_keywords) do
if lower:find(word) then
is_car = true
break
end
end

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

-- Clean up whitespace
formatted = formatted:gsub("%s+", " ")
formatted = formatted:gsub("^%s+", "")
formatted = formatted:gsub("%s+$", "")

-- Auto-add price if selling/buying but no price specified
local has_price = false
local fl = formatted:lower()
if fl:find("дог") or fl:find("торг") or fl:find("обмен") or fl:find("бартер") or fl:find("дешев") or fl:find("дёшев") or fl:find("недорого") or fl:find("%$") or fl:find("кк") or fl:find("млн") or fl:find("миллиард") or fl:find("млрд") or fl:find("миллион") then
has_price = true
end
local is_ad = false
if fl:find("продам") or fl:find("куплю") or fl:find("обменяю") or fl:find("прод") or fl:find("куп") then
is_ad = true
end
if is_ad and not has_price then
formatted = formatted .. ". Цена: договорная"
end

-- Add server tag prefix
local tag = u8:decode(ffi.string(mm_tag))
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
        local ae_enter = imgui.InputText("##ae_input", ae_input_buf, ffi.sizeof(ae_input_buf), imgui.InputTextFlags.EnterReturnsTrue)
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

        if imgui.Button(u8"Отмена", imgui.ImVec2(120, 30)) then
            if ae_dialog_id >= 0 then
                sampSendDialogResponse(ae_dialog_id, 0, -1, "")
            end
            ae_active[0] = false
        end

        imgui.End()
    end
)


