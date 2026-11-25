--[[
Universal Game Helper Core for SAMP (MoonLoader / Lua)

Этот файл является ядром и каркасом вашей будущей платформы.
Здесь реализован минималистичный интерфейс на mimgui (разделенный на вкладки/модули),
механизм динамического подключения функций, парсинг объявлений СМИ для базы номеров,
проверка онлайна игроков, автоматизированный обзвон, СМИ Редактор (MM Editor),
справочник точных команд Advance RP, автоматические RP отыгровки,
стробоскопы, круиз-контроль, а также смена погоды/времени и скин-ченджер.

ВЕРСИЯ 1.0: AutoEdit с автозаменой, историей объявлений, JSON fallback. 
Скрипт работает «из коробки» на чистом MoonLoader без установки сторонних плагинов!

Установка:
1. Установите MoonLoader v0.26+.
2. Поместите этот файл в папку `GTA San Andreas/moonloader/`.
3. Открыть меню: клавиша F11 или команда /helper.
]]

script_name("Helper Core")
script_author("Advance RP Helper")
script_description("Universal Helper Platform for Advance RP")
script_dependencies("SAMP.Lua", "mimgui")
script_properties("work-in-pause")

local SCRIPT_VERSION = 'v2.6 (26.11.2026)'
local SCRIPT_VER_NUM = '2.6'
jit.off()

-- ============================================================================
-- Thread-Safe Main Loop Task Queue & Debounced Storage
-- (Prevents crash 0x6AE877F1 / luaL_unref caused by spawning threads inside DirectX Present hook)
-- ============================================================================
-- ============================================================================
-- Thread GC Protection Shield
-- (Prevents crash 0x6AE877D6 / 0x643877D6 in MoonLoader.asi lua_thread destructor
-- by keeping a permanent anchor so MoonLoader's buggy C++ luaL_unref is never called by GC)
-- ============================================================================
__raw_thread_create = lua_thread.create
__thread_anchor_pool = __thread_anchor_pool or {}

lua_thread.create = function(fn, ...)
    if type(fn) ~= "function" then
        print("[Helper Warning] lua_thread.create called with non-function: " .. tostring(fn))
        return nil
    end
    local ok, res = pcall(__raw_thread_create, fn, ...)
    if ok and res then
        __thread_anchor_pool[res] = true
        return res
    elseif not ok then
        print("[Helper Thread Error] " .. tostring(res))
        return nil
    end
    return res
end

task_queue = {}
function queueTask(fn)
    if type(fn) == "function" then
        task_queue[#task_queue + 1] = fn
    end
end

scheduled_tasks = {}
function scheduleTask(delay_ms, fn)
    if type(fn) ~= "function" then return end
    local d = tonumber(delay_ms) or 0
    if d < 0 then d = 0 end
    scheduled_tasks[#scheduled_tasks + 1] = {
        run_at = os.clock() + (d / 1000.0),
        fn = fn
    }
end

function sendChatSequence(steps)
    if type(steps) ~= "table" then return end
    local total_ms = 0
    for _, step in ipairs(steps) do
        if type(step) == "table" then
            total_ms = total_ms + math.max(0, tonumber(step.delay_ms) or 0)
            local msg = step.msg
            if type(msg) == "string" and msg ~= "" then
                scheduleTask(total_ms, function()
                    if isSampAvailable() then
                        sampSendChat(msg)
                    end
                end)
            end
        end
    end
end

settings_dirty = false
function requestSaveSettings()
    settings_dirty = true
end

db_dirty = false
function requestSaveDatabase()
    db_dirty = true
end

rules_dirty = false
function requestSaveRules()
    rules_dirty = true
end

corrections_dirty = false
function requestSaveCorrections()
    corrections_dirty = true
end

ad_history_dirty = false
function requestSaveAdHistory()
    ad_history_dirty = true
end

rp_settings_dirty = false
function requestSaveRpSettings()
    rp_settings_dirty = true
end

blacklist_dirty = false
function requestSaveBlacklist()
    blacklist_dirty = true
end

local imgui = require 'mimgui'
local ffi = require 'ffi'
-- Safe string copy with bounds check (prevents FFI buffer overflow crash)
function utf8SafePrefixLength(s, maxBytes)
    if maxBytes <= 0 then return 0 end
    if #s <= maxBytes then return #s end
    local start = maxBytes
    while start > 0 do
        local b = s:byte(start)
        if b < 0x80 or b > 0xBF then break end
        start = start - 1
    end
    if start == 0 then return 0 end
    local lead = s:byte(start)
    local sequenceLength = 1
    if lead >= 0xC2 and lead <= 0xDF then
        sequenceLength = 2
    elseif lead >= 0xE0 and lead <= 0xEF then
        sequenceLength = 3
    elseif lead >= 0xF0 and lead <= 0xF4 then
        sequenceLength = 4
    end
    if start + sequenceLength - 1 > maxBytes then return start - 1 end
    return maxBytes
end
function safeStrCopy(dst, src, dstSize)
    dstSize = tonumber(dstSize) or ffi.sizeof(dst)
    if dstSize <= 0 then return end
    if src == nil then dst[0] = 0 return end
    local s = type(src) == "string" and src or ffi.string(src)
    local maxLength = dstSize - 1
    if #s > maxLength then s = s:sub(1, utf8SafePrefixLength(s, maxLength)) end
    ffi.copy(dst, s, #s)
    dst[#s] = 0  -- null terminator
end
local sampev = require 'lib.samp.events'
local encoding = require 'encoding'
local json = nil
local ok_json = pcall(function() json = require 'json' end)
if not ok_json or not json then
-- Safe built-in JSON fallback for save/load
json = {
encode = function(t)
local seen = {}
local function escapeStr(str)
    local out = str:gsub('\\', '\\\\')
        :gsub('"', '\\"')
        :gsub('\b', '\\b')
        :gsub('\f', '\\f')
        :gsub('\n', '\\n')
        :gsub('\r', '\\r')
        :gsub('\t', '\\t')
        :gsub('[%z\1-\31]', function(c)
            return string.format('\\u%04x', c:byte())
        end)
    return '"' .. out .. '"'
end
local function enc(v)
    local tv = type(v)
    if tv == 'string' then
        return escapeStr(v)
    elseif tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return '0' end
        return tostring(v)
    elseif tv == 'boolean' then
        return v and 'true' or 'false'
    elseif tv == 'table' then
        if seen[v] then return 'null' end
        seen[v] = true
        local max_idx, count = 0, 0
        local is_array = true
        for k, _ in pairs(v) do
            if type(k) == 'number' and k >= 1 and math.floor(k) == k then
                if k > max_idx then max_idx = k end
                count = count + 1
            else
                is_array = false
                break
            end
        end
        local res
        if is_array and count > 0 and max_idx == count then
            local arr = {}
            for i = 1, max_idx do
                arr[i] = enc(v[i])
            end
            res = '[' .. table.concat(arr, ',') .. ']'
        else
            local obj = {}
            for k, val in pairs(v) do
                if type(k) == 'string' or type(k) == 'number' then
                    obj[#obj + 1] = escapeStr(tostring(k)) .. ':' .. enc(val)
                end
            end
            res = '{' .. table.concat(obj, ',') .. '}'
        end
        seen[v] = nil
        return res
    end
    return 'null'
end
return enc(t)
end,
decode = function(s)
if type(s) ~= 'string' then return nil end
local len = #s
local pos = 1
local function skipWs()
    local _, next_end = s:find('^[ \t\r\n]+', pos)
    if next_end then pos = next_end + 1 end
end
local function codepointToUtf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
    else
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + (math.floor(cp / 64) % 64), 0x80 + (cp % 64))
    end
end
local function parseString()
    if s:sub(pos, pos) ~= '"' then return nil, false end
    pos = pos + 1
    local parts = {}
    local esc_map = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', ['b'] = '\b', ['f'] = '\f', ['n'] = '\n', ['r'] = '\r', ['t'] = '\t'}
    while pos <= len do
        local ch = s:sub(pos, pos)
        if ch == '"' then
            pos = pos + 1
            return table.concat(parts), true
        elseif ch == '\\' then
            pos = pos + 1
            if pos > len then return nil, false end
            local esc = s:sub(pos, pos)
            if esc_map[esc] then
                parts[#parts + 1] = esc_map[esc]
                pos = pos + 1
            elseif esc == 'u' then
                local hex = s:sub(pos + 1, pos + 4)
                if #hex == 4 and hex:match('^%x%x%x%x$') then
                    local cp = tonumber(hex, 16)
                    parts[#parts + 1] = codepointToUtf8(cp)
                    pos = pos + 5
                else
                    return nil, false
                end
            else
                parts[#parts + 1] = esc
                pos = pos + 1
            end
        else
            parts[#parts + 1] = ch
            pos = pos + 1
        end
    end
    return nil, false
end
local parseValue
local function parseObject()
    pos = pos + 1
    local t = {}
    skipWs()
    if pos <= len and s:sub(pos, pos) == '}' then
        pos = pos + 1
        return t, true
    end
    while pos <= len do
        skipWs()
        local key, ok_k = parseString()
        if not ok_k then return nil, false end
        skipWs()
        if s:sub(pos, pos) ~= ':' then return nil, false end
        pos = pos + 1
        local v, ok_v = parseValue()
        if not ok_v then return nil, false end
        t[key] = v
        skipWs()
        local sep = s:sub(pos, pos)
        if sep == '}' then
            pos = pos + 1
            return t, true
        elseif sep == ',' then
            pos = pos + 1
        else
            return nil, false
        end
    end
    return nil, false
end
local function parseArray()
    pos = pos + 1
    local t = {}
    skipWs()
    if pos <= len and s:sub(pos, pos) == ']' then
        pos = pos + 1
        return t, true
    end
    while pos <= len do
        local v, ok_v = parseValue()
        if not ok_v then return nil, false end
        t[#t + 1] = v
        skipWs()
        local sep = s:sub(pos, pos)
        if sep == ']' then
            pos = pos + 1
            return t, true
        elseif sep == ',' then
            pos = pos + 1
        else
            return nil, false
        end
    end
    return nil, false
end
parseValue = function()
    skipWs()
    if pos > len then return nil, false end
    local c = s:sub(pos, pos)
    if c == '{' then
        return parseObject()
    elseif c == '[' then
        return parseArray()
    elseif c == '"' then
        return parseString()
    elseif s:sub(pos, pos + 3) == 'true' then
        pos = pos + 4
        return true, true
    elseif s:sub(pos, pos + 4) == 'false' then
        pos = pos + 5
        return false, true
    elseif s:sub(pos, pos + 3) == 'null' then
        pos = pos + 4
        return nil, true
    else
        local num = s:match('^%-?%d+%.?%d*[eE]?[+-]?%d*', pos)
        if num and num ~= '' and tonumber(num) ~= nil then
            pos = pos + #num
            return tonumber(num), true
        end
    end
    return nil, false
end
local res, ok_val = parseValue()
if not ok_val then return nil end
return res
end
}
print('[helper_core] json library not found, using built-in fallback')
end
local mem_ok, memory = pcall(require, 'memory')
if not mem_ok then print('[helper_core] WARNING: memory library not available') memory = nil end
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local WINDOW_TITLE = u8:encode("Universal Helper Platform " .. SCRIPT_VERSION)
local ORIG_BTN_TEXT = u8:encode(string.char(0xCE,0xF0,0xE8,0xE3,0xE8,0xED,0xE0,0xEB))

function fileExists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

function writeJsonAtomic(path, value)
    local encodeOk, data = pcall(json.encode, value)
    if not encodeOk or type(data) ~= "string" then
        return false, tostring(data)
    end
    local tempPath = path .. ".tmp"
    local backupPath = path .. ".bak"
    local file, openError = io.open(tempPath, "wb")
    if not file then return false, tostring(openError) end
    local writeOk, writeError = pcall(function()
        file:write(data)
        file:flush()
    end)
    file:close()
    if not writeOk then
        os.remove(tempPath)
        return false, tostring(writeError)
    end
    os.remove(backupPath)
    local hadOriginal = fileExists(path)
    if hadOriginal and not os.rename(path, backupPath) then
        os.remove(tempPath)
        return false, "backup rename failed"
    end
    if os.rename(tempPath, path) then
        if hadOriginal then os.remove(backupPath) end
        return true
    end
    if hadOriginal then os.rename(backupPath, path) end
    os.remove(tempPath)
    return false, "replace rename failed"
end

function readJsonFile(path)
    for _, candidate in ipairs({path, path .. ".tmp", path .. ".bak"}) do
        local file = io.open(candidate, "rb")
        if file then
            local content = file:read("*a")
            file:close()
            if content and content ~= "" then
                local ok, parsed = pcall(json.decode, content)
                if ok and type(parsed) == "table" then return parsed end
            end
        end
    end
    return nil
end

-- Инициализируем переменные для GUI
show_main_window = imgui.new.bool(false)
active_module_idx = 1
pending_module_idx = nil
module_switch_blank_frames = 0

-- Путь к базам данных
local db_path = getWorkingDirectory() .. "/config/helper_db.json"
local rules_path = getWorkingDirectory() .. "/config/helper_mm_rules.json"
local settings_path = getWorkingDirectory() .. "/config/helper_settings.json"

player_db = {}
current_server_idx = imgui.new.int(0)
server_names = {u8"Advance RP", u8"Diamond RP", u8"Arizona RP", u8"Evolve RP"}

-- Переменные для модуля "Сбор и обзвон"
call_active = false
call_worker_running = false
call_delay = imgui.new.int(7000)
max_calls_session = imgui.new.int(50)
call_current_nick = ""
call_current_phone = ""
last_called = {}
call_cooldown_hours = imgui.new.int(1)  -- don't re-call same person for N hours
call_no_repeat = imgui.new.bool(true)  -- skip anyone in call history regardless of cooldown
call_skip_today = imgui.new.bool(true)  -- skip anyone already called today
call_history_show = imgui.new.bool(false)  -- toggle call history view
db_search_buf = imgui.new.char[65]("")
db_sms_buf = imgui.new.char[129]("")
last_sms_phone = ""
last_sms_nick = ""
last_sms_time = 0
online_list_cache = {}
online_list_cache_time = 0
online_nicks_cache = {}
online_ids_to_nicks = {}
online_nicks_to_ids = {}
online_cache_last_refresh = 0
my_cached_nick = ""
my_cached_id = -1
player_db_queue = {}  -- queue of {sender=, phone=} to apply safely in main loop
db_sorted_cache = {}  -- cached sorted db_list, rebuilt every 3 seconds
db_sorted_cache_time = 0
last_called_queue = {}  -- queue of {nick=, time=} to apply safely in main loop
online_nicks_initialized = false

-- Periodic refresh of online nicks cache from main loop (safe, avoids missing join/quit events)
function refreshOnlineNicksCache()
    if not isSampAvailable() then return end
    local id_ok, myid = pcall(function()
        local ok, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
        return ok and pid or -1
    end)
    if not id_ok or myid < 0 then return end
    my_cached_id = myid
    local ok_mynick, mn = pcall(sampGetPlayerNickname, myid)
    if ok_mynick and type(mn) == "string" then
        my_cached_nick = mn
    end

    local new_cache = {}
    local new_ids = {}
    local new_nicks_to_ids = {}
    local ok_max, max_id = pcall(sampGetMaxPlayerId, false)
    if not ok_max or type(max_id) ~= "number" then return end
    for i = 0, max_id do
        local ok_c, conn = pcall(sampIsPlayerConnected, i)
        if ok_c and conn then
            local ok_n, nick = pcall(sampGetPlayerNickname, i)
            if ok_n and type(nick) == "string" and nick ~= "" and i ~= myid then
                new_cache[nick] = true
                new_ids[i] = nick
                new_nicks_to_ids[cp1251_lower(nick)] = { id = i, nick = nick }
            end
        end
    end
    online_nicks_cache = new_cache
    online_ids_to_nicks = new_ids
    online_nicks_to_ids = new_nicks_to_ids
    online_nicks_initialized = true
    online_cache_last_refresh = os.time()
end

-- Safe online check using cache only (case-insensitive, no SAMP API calls)
function isOnlineCached(nickname)
    if type(nickname) ~= "string" or nickname == "" then return false end
    if online_nicks_cache[nickname] == true then return true end
    return online_nicks_to_ids[cp1251_lower(nickname)] ~= nil
end

function getOnlinePlayerIdByNick(nickname)
    if type(nickname) ~= "string" or nickname == "" then return nil end
    local entry = online_nicks_to_ids[cp1251_lower(nickname)]
    return entry and entry.id or nil
end

function canCallNick(nick)
    local lt = last_called[nick] or 0
    if lt == 0 then return true end
    if call_no_repeat[0] then return false end
    if call_skip_today[0] and os.date("%Y-%m-%d", lt) == os.date("%Y-%m-%d") then
        return false
    end
    return (os.time() - lt) > (call_cooldown_hours[0] * 3600)
end

function markPhoneCalled(phone_str)
    if type(phone_str) ~= "string" or phone_str == "" then return end
    local now_ts = os.time()
    for nick, data in pairs(player_db) do
        if type(data) == "table" and tostring(data.phone or "") == phone_str then
            table.insert(last_called_queue, {nick = nick, time = now_ts})
        end
    end
end

function findContactByQuery(query)
    if type(query) ~= "string" then return nil end
    local q = cp1251_lower(query:gsub("^%s+", ""):gsub("%s+$", ""))
    if q == "" then return nil end
    local best = nil
    local best_score = -1
    for nick, data in pairs(player_db) do
        if type(data) == "table" and type(data.phone) == "string" and data.phone ~= "" then
            local nl = cp1251_lower(nick)
            local score = -1
            if nl == q then
                score = 30
            elseif nl:sub(1, #q) == q then
                score = 20
            elseif nl:find(q, 1, true) then
                score = 10
            end
            if score > 0 then
                if isOnlineCached(nick) then score = score + 5 end
                if score > best_score then
                    best_score = score
                    best = { nick = nick, phone = data.phone, online = isOnlineCached(nick) }
                end
            end
        end
    end
    return best
end

-- Переменные для модуля "MM Editor" (СМИ Редактор)
mm_auto_format = imgui.new.bool(true)
mm_auto_send = imgui.new.bool(false)
mm_send_delay = imgui.new.int(3000)
mm_tag = imgui.new.char[9]("LV")
ae_active = imgui.new.bool(false)
ae_dialog_id = -1
ae_original_text = ""
ae_formatted_text = ""
ae_input_buf = imgui.new.char[1025]("")
ae_focus = false
ae_ignore_enter = 0  -- grace period frames to ignore stale Enter from chat command
ae_enter_was_down = false  -- track Enter key release before allowing send
ae_esc_was_down = false  -- track Esc key release before allowing reject
ad_history = {}
ad_history_path = (getFolderPath(0x1C) or (getWorkingDirectory() .. "\\config")) .. "\\helper_ad_history.json"
ae_show_history = imgui.new.bool(false)
ae_open_queue = nil  -- queued dialog open from onShowDialog (processed in main loop to avoid race with render thread)
ae_autosend_deadline = nil
ae_last_buf_snapshot = ""

function loadAdHistory()
local parsed = readJsonFile(ad_history_path)
if parsed then
local cleaned = {}
for _, entry in ipairs(parsed) do
if type(entry) == "string" and not entry:find("%z") and #entry <= 4096 then
cleaned[#cleaned + 1] = entry
if #cleaned >= 20 then break end
end
end
ad_history = cleaned
end
end

function saveAdHistory()
local ok, err = writeJsonAtomic(ad_history_path, ad_history)
if not ok then print("[helper_core] saveAdHistory error: " .. tostring(err)) end
end

function addAdToHistory(ad_text)
if ad_text and ad_text ~= "" and ad_text ~= "ПРО" then
for _, h in ipairs(ad_history) do
if h == ad_text then return end
end
table.insert(ad_history, 1, ad_text)
if #ad_history > 20 then table.remove(ad_history, #ad_history) end
requestSaveAdHistory()
end
end

-- Самообучение: запоминаем правки пользователя в AutoEdit как кандидаты на новые правила
edit_corrections = {}
corrections_path = (getFolderPath(0x1C) or (getWorkingDirectory() .. "\\config")) .. "\\helper_edit_corrections.json"

function loadCorrections()
local parsed = readJsonFile(corrections_path)
if parsed then
local cleaned = {}
for _, entry in ipairs(parsed) do
if type(entry) == "table" and type(entry.abbr) == "string" and type(entry.repl) == "string" and not entry.abbr:find("%z") and not entry.repl:find("%z") and #entry.abbr <= 128 and #entry.repl <= 512 then
cleaned[#cleaned + 1] = {abbr = entry.abbr, repl = entry.repl}
if #cleaned >= 20 then break end
end
end
edit_corrections = cleaned
end
end

function saveCorrections()
local ok, err = writeJsonAtomic(corrections_path, edit_corrections)
if not ok then print("[helper_core] saveCorrections error: " .. tostring(err)) end
end

-- Возвращает изменённый участок между двумя строками (общий префикс/суффикс отбрасываются)
function wordDiffMiddle(a, b)
local aw, bw = {}, {}
for w in a:gmatch("%S+") do table.insert(aw, w) end
for w in b:gmatch("%S+") do table.insert(bw, w) end
local i = 1
while i <= #aw and i <= #bw and aw[i] == bw[i] do i = i + 1 end
local ja, jb = #aw, #bw
local j = 0
while (ja - j) >= i and (jb - j) >= i and aw[ja - j] == bw[jb - j] do j = j + 1 end
local a_mid = (i <= ja - j) and table.concat(aw, " ", i, ja - j) or ""
local b_mid = (i <= jb - j) and table.concat(bw, " ", i, jb - j) or ""
return a_mid, b_mid
end

-- Запоминает правку, если она короткая, непустая и ещё не записана
function recordEditCorrection(suggested, final_text)
if suggested == final_text then return end
local a_mid, b_mid = wordDiffMiddle(suggested, final_text)
if a_mid == "" or b_mid == "" or a_mid == b_mid then return end
if #a_mid > 30 or #b_mid > 100 then return end
for _, c in ipairs(edit_corrections) do
if c.abbr == a_mid and c.repl == b_mid then return end
end
table.insert(edit_corrections, 1, {abbr = a_mid, repl = b_mid})
if #edit_corrections > 20 then table.remove(edit_corrections, #edit_corrections) end
requestSaveCorrections()
end

loadAdHistory()
loadCorrections()
test_input = imgui.new.char[129]("")
test_output = ""
mm_rule_filter = imgui.new.char[65]("")
mm_rule_page = 1
mm_rule_revision = 0
mm_rule_filter_cache = {query = nil, revision = -1, count = -1, indices = {}}
mm_last_deleted_rule = nil
mm_rule_status = ""
mm_ui_page = 1
mm_pending_ui_page = nil
mm_ui_last_logged_page = -1
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
{abbreviation = "лодки", replacement = "лодку"},
{abbreviation = "лодке", replacement = "лодку"},
{abbreviation = "яхта", replacement = "яхту"},
{abbreviation = "яхты", replacement = "яхту"},
{abbreviation = "яхте", replacement = "яхту"},
{abbreviation = "самолет", replacement = "самолёт"},
{abbreviation = "самолёта", replacement = "самолёт"},
{abbreviation = "вертолет", replacement = "вертолёт"},
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
{abbreviation = "паломино", replacement = "Palomino Creek"},
{abbreviation = "паломино крик", replacement = "Palomino Creek"},
{abbreviation = "блюберри", replacement = "Blueberry"},
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
{abbreviation = "норт рок", replacement = "North Rock"},
{abbreviation = "норт", replacement = "North Rock"},
{abbreviation = "эшберри", replacement = "Ashberry"},
{abbreviation = "хилтоп", replacement = "Hilltop"},
{abbreviation = "хилтопа", replacement = "Hilltop"},
{abbreviation = "валле", replacement = "Valle Ocultado"},
{abbreviation = "валле оклудадо", replacement = "Valle Ocultado"},
{abbreviation = "оклудадо", replacement = "Valle Ocultado"},
{abbreviation = "арко дель оесте", replacement = "Arco del Oeste"},
{abbreviation = "арко", replacement = "Arco del Oeste"},
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
{abbreviation = "рокшор вест", replacement = "Rockshore West"},
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
{abbreviation = "квартиры", replacement = "квартиру"},
{abbreviation = "особняка", replacement = "особняк"},
{abbreviation = "особняку", replacement = "особняк"},
{abbreviation = "вилла", replacement = "виллу"},
{abbreviation = "виллы", replacement = "виллу"},
{abbreviation = "биз", replacement = "бизнес"},
{abbreviation = "бизик", replacement = "бизнес"},
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
{abbreviation = "мотель", replacement = "отель"},
{abbreviation = "отеля", replacement = "отель"},
{abbreviation = "мотеля", replacement = "отель"},
{abbreviation = "маг", replacement = "магазин"},
{abbreviation = "магазина", replacement = "магазин"},
{abbreviation = "хатка", replacement = "магазин"},
{abbreviation = "хатку", replacement = "магазин"},
{abbreviation = "хатки", replacement = "магазин"},
{abbreviation = "бараху", replacement = "барах"},
{abbreviation = "барахи", replacement = "барах"},
{abbreviation = "барахе", replacement = "барах"},
{abbreviation = "клуба", replacement = "клуб"},
{abbreviation = "клубу", replacement = "клуб"},
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
{abbreviation = "столовая", replacement = "столовую"},
{abbreviation = "бара", replacement = "бар"},
{abbreviation = "бару", replacement = "бар"},
{abbreviation = "ресторана", replacement = "ресторан"},
{abbreviation = "аптека", replacement = "аптеку"},
{abbreviation = "аптеки", replacement = "аптеку"},
{abbreviation = "склада", replacement = "склад"},
{abbreviation = "складу", replacement = "склад"},
{abbreviation = "ангара", replacement = "ангар"},
{abbreviation = "причала", replacement = "причал"},
{abbreviation = "ферма", replacement = "ферму"},
{abbreviation = "фермы", replacement = "ферму"},
{abbreviation = "шахта", replacement = "шахту"},
{abbreviation = "шахты", replacement = "шахту"},
{abbreviation = "лесопилка", replacement = "лесопилку"},
{abbreviation = "порта", replacement = "порт"},
{abbreviation = "порту", replacement = "порт"},
{abbreviation = "верфи", replacement = "верфь"},
{abbreviation = "хранилища", replacement = "хранилище"},
{abbreviation = "электростанция", replacement = "электростанцию"},
{abbreviation = "мэрия", replacement = "мэрию"},
{abbreviation = "мэрии", replacement = "мэрию"},
{abbreviation = "мэрие", replacement = "мэрию"},
{abbreviation = "мерия", replacement = "мэрию"},
{abbreviation = "мерию", replacement = "мэрию"},
{abbreviation = "полиция", replacement = "полицию"},
{abbreviation = "полиции", replacement = "полицию"},
{abbreviation = "больница", replacement = "больницу"},
{abbreviation = "больницы", replacement = "больницу"},
{abbreviation = "школа", replacement = "школу"},
{abbreviation = "школы", replacement = "школу"},
{abbreviation = "церкви", replacement = "церковь"},
{abbreviation = "банка", replacement = "банк"},
{abbreviation = "банку", replacement = "банк"},
{abbreviation = "стадиона", replacement = "стадион"},
{abbreviation = "стадиону", replacement = "стадион"},
-- Предметы
{abbreviation = "сим", replacement = "SIM-card"},
{abbreviation = "симка", replacement = "SIM-card"},
{abbreviation = "симку", replacement = "SIM-card"},
{abbreviation = "симки", replacement = "SIM-card"},
{abbreviation = "тел", replacement = "телефон"},
{abbreviation = "телефона", replacement = "телефон"},
{abbreviation = "номер", replacement = "тел. номер"},
{abbreviation = "номера", replacement = "тел. номер"},
{abbreviation = "одежда", replacement = "одежду"},
{abbreviation = "одежды", replacement = "одежду"},
{abbreviation = "скин", replacement = "одежду"},
{abbreviation = "скина", replacement = "одежду"},
{abbreviation = "скину", replacement = "одежду"},
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
{abbreviation = "еда", replacement = "еду"},
{abbreviation = "еды", replacement = "еду"},
{abbreviation = "вода", replacement = "воду"},
{abbreviation = "воды", replacement = "воду"},
{abbreviation = "бронежилета", replacement = "бронежилет"},
{abbreviation = "бинокля", replacement = "бинокль"},
{abbreviation = "фонарика", replacement = "фонарик"},
{abbreviation = "радиоа", replacement = "радио"},
{abbreviation = "гитара", replacement = "гитару"},
{abbreviation = "гитары", replacement = "гитару"},
{abbreviation = "мяча", replacement = "мяч"},
{abbreviation = "удочка", replacement = "удочку"},
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
{abbreviation = "миллиард", replacement = ".000.000.000$"},
{abbreviation = "млрд", replacement = ".000.000.000$"},
{abbreviation = "миллиарда", replacement = ".000.000.000$"},
{abbreviation = "миллион", replacement = ".000.000$"},
{abbreviation = "миллиона", replacement = ".000.000$"},
-- Цена
{abbreviation = "бартер", replacement = "обмен"},
{abbreviation = "дешево", replacement = "по низкой цене"},
{abbreviation = "дёшево", replacement = "по низкой цене"},
{abbreviation = "недорого", replacement = "по низкой цене"},
-- Услуги
{abbreviation = "услуг", replacement = "услуги"},
{abbreviation = "перевозк", replacement = "перевозки"},
{abbreviation = "доставку", replacement = "доставка"},
{abbreviation = "эвакуатора", replacement = "эвакуатор"},
{abbreviation = "ремонта", replacement = "ремонт"},
{abbreviation = "тюнинга", replacement = "тюнинг"},
{abbreviation = "покраску", replacement = "покраска"},
{abbreviation = "охрану", replacement = "охрана"},
-- Семья
{abbreviation = "семью", replacement = "семья"},
{abbreviation = "семьи", replacement = "семья"},
{abbreviation = "родня", replacement = "родственников"},
{abbreviation = "родню", replacement = "родственников"},
-- Лицензии
{abbreviation = "права", replacement = "вод. права"},
{abbreviation = "прав", replacement = "вод. права"},
{abbreviation = "лицензию", replacement = "лицензия"},
{abbreviation = "лицензии", replacement = "лицензия"},
{abbreviation = "лиц", replacement = "лицензия"},
{abbreviation = "медкарта", replacement = "мед. карта"},
{abbreviation = "медкарту", replacement = "мед. карта"},
-- Работа/Организации
{abbreviation = "сми", replacement = "СМИ"},
{abbreviation = "смиа", replacement = "СМИ"},
{abbreviation = "собеседованиеа", replacement = "собеседование"},
{abbreviation = "фбр", replacement = "ФБР"},
{abbreviation = "фбра", replacement = "ФБР"},
{abbreviation = "мчс", replacement = "МЧС"},
{abbreviation = "мчса", replacement = "МЧС"},
{abbreviation = "армия", replacement = "армию"},
{abbreviation = "армии", replacement = "армию"},
{abbreviation = "инструктор", replacement = "инструктора"},
{abbreviation = "работа", replacement = "работу"},
{abbreviation = "работы", replacement = "работу"},
{abbreviation = "вакансия", replacement = "вакансию"},
{abbreviation = "вакансии", replacement = "вакансию"},
{abbreviation = "набора", replacement = "набор"},
{abbreviation = "собеседования", replacement = "собеседование"},
-- Транспорт
{abbreviation = "поезда", replacement = "поезд"},
{abbreviation = "поезду", replacement = "поезд"},
{abbreviation = "автобуса", replacement = "автобус"},
{abbreviation = "автобусу", replacement = "автобус"},
{abbreviation = "трамвая", replacement = "трамвай"},
{abbreviation = "трамваю", replacement = "трамвай"},
{abbreviation = "грузовика", replacement = "грузовик"},
{abbreviation = "грузовику", replacement = "грузовик"},
{abbreviation = "фура", replacement = "грузовик"},
{abbreviation = "фуру", replacement = "грузовик"},
{abbreviation = "фуры", replacement = "грузовик"},
{abbreviation = "тягача", replacement = "тягач"},
{abbreviation = "ковер", replacement = "а/м марки \"Clover\""},
{abbreviation = "валдшнеп", replacement = "а/м марки \"Walton\""},
{abbreviation = "валдшнепа", replacement = "а/м марки \"Walton\""},
{abbreviation = "тахома", replacement = "а/м марки \"Tahoma\""},
{abbreviation = "тахому", replacement = "а/м марки \"Tahoma\""},
{abbreviation = "гринвуд", replacement = "а/м марки \"Greenwood\""},
{abbreviation = "гринвуда", replacement = "а/м марки \"Greenwood\""},
{abbreviation = "гринвуду", replacement = "а/м марки \"Greenwood\""},
{abbreviation = "саванна", replacement = "а/м марки \"Savanna\""},
{abbreviation = "саванну", replacement = "а/м марки \"Savanna\""},
{abbreviation = "саванны", replacement = "а/м марки \"Savanna\""},
{abbreviation = "тумми", replacement = "а/м марки \"Tahoma\""},
{abbreviation = "чайтон", replacement = "а/м марки \"Cheetah\""},
{abbreviation = "карт", replacement = "а/м марки \"Kart\""},
{abbreviation = "карта", replacement = "а/м марки \"Kart\""},
{abbreviation = "мрак", replacement = "а/м марки \"Bravura\""},
{abbreviation = "мрака", replacement = "а/м марки \"Bravura\""},
{abbreviation = "мраку", replacement = "а/м марки \"Bravura\""},
{abbreviation = "санд king", replacement = "а/м марки \"Sandking\""},
{abbreviation = "сандкинг", replacement = "а/м марки \"Sandking\""},
{abbreviation = "сандкинга", replacement = "а/м марки \"Sandking\""},
{abbreviation = "меска", replacement = "а/м марки \"Mesa\""},
{abbreviation = "месу", replacement = "а/м марки \"Mesa\""},
{abbreviation = "меса", replacement = "а/м марки \"Mesa\""},
{abbreviation = "месы", replacement = "а/м марки \"Mesa\""},
{abbreviation = "мунбим", replacement = "а/м марки \"Moonbeam\""},
{abbreviation = "мунбима", replacement = "а/м марки \"Moonbeam\""},
{abbreviation = "пони", replacement = "а/м марки \"Pony\""},
{abbreviation = "пониа", replacement = "а/м марки \"Pony\""},
{abbreviation = "регина", replacement = "а/м марки \"Regina\""},
{abbreviation = "регину", replacement = "а/м марки \"Regina\""},
{abbreviation = "регины", replacement = "а/м марки \"Regina\""},
{abbreviation = "ромеро", replacement = "а/м марки \"Romero\""},
{abbreviation = "ромероа", replacement = "а/м марки \"Romero\""},
{abbreviation = "стокер", replacement = "а/м марки \"Stocker\""},
{abbreviation = "стокера", replacement = "а/м марки \"Stocker\""},
{abbreviation = "топфан", replacement = "а/м марки \"Topfun\""},
{abbreviation = "топфана", replacement = "а/м марки \"Topfun\""},
{abbreviation = "трактор", replacement = "а/м марки \"Tractor\""},
{abbreviation = "трактора", replacement = "а/м марки \"Tractor\""},
{abbreviation = "трактору", replacement = "а/м марки \"Tractor\""},
{abbreviation = "вудуп", replacement = "а/м марки \"Woodpecker\""},
{abbreviation = "вудупа", replacement = "а/м марки \"Woodpecker\""},
{abbreviation = "флэтбед", replacement = "а/м марки \"Flatbed\""},
{abbreviation = "флэтбеда", replacement = "а/м марки \"Flatbed\""},
{abbreviation = "лайнер", replacement = "а/м марки \"Linerunner\""},
{abbreviation = "лайнера", replacement = "а/м марки \"Linerunner\""},
{abbreviation = "лайнрунер", replacement = "а/м марки \"Linerunner\""},
{abbreviation = "лайнрунера", replacement = "а/м марки \"Linerunner\""},
{abbreviation = "роудтрейн", replacement = "а/м марки \"Roadtrain\""},
{abbreviation = "роудтрейна", replacement = "а/м марки \"Roadtrain\""},
{abbreviation = "танкер", replacement = "а/м марки \"Tanker\""},
{abbreviation = "танкера", replacement = "а/м марки \"Tanker\""},
{abbreviation = "дум", replacement = "а/м марки \"Dune\""},
{abbreviation = "дума", replacement = "а/м марки \"Dune\""},
{abbreviation = "думу", replacement = "а/м марки \"Dune\""},
{abbreviation = "сиспарроу", replacement = "а/м марки \"Sparrow\""},
{abbreviation = "сиспарроуа", replacement = "а/м марки \"Sparrow\""},
{abbreviation = "спарроу", replacement = "а/м марки \"Sparrow\""},
{abbreviation = "спарроуа", replacement = "а/м марки \"Sparrow\""},
{abbreviation = "левиафан", replacement = "а/м марки \"Leviathan\""},
{abbreviation = "левиафана", replacement = "а/м марки \"Leviathan\""},
{abbreviation = "карго", replacement = "а/м марки \"Cargo\""},
{abbreviation = "каргоа", replacement = "а/м марки \"Cargo\""},
{abbreviation = "андровер", replacement = "а/м марки \"Andromada\""},
{abbreviation = "андровера", replacement = "а/м марки \"Andromada\""},
{abbreviation = "небула", replacement = "а/м марки \"Nebula\""},
{abbreviation = "небулу", replacement = "а/м марки \"Nebula\""},
{abbreviation = "небулы", replacement = "а/м марки \"Nebula\""},
{abbreviation = "зомбиа", replacement = "а/м марки \"Zombie\""},
{abbreviation = "файр", replacement = "а/м марки \"Firetruck\""},
{abbreviation = "файра", replacement = "а/м марки \"Firetruck\""},
{abbreviation = "пожарка", replacement = "а/м марки \"Firetruck\""},
{abbreviation = "пожарку", replacement = "а/м марки \"Firetruck\""},
{abbreviation = "пожарки", replacement = "а/м марки \"Firetruck\""},
{abbreviation = "скорая", replacement = "а/м марки \"Ambulance\""},
{abbreviation = "скорую", replacement = "а/м марки \"Ambulance\""},
{abbreviation = "скорой", replacement = "а/м марки \"Ambulance\""},
{abbreviation = "амбуланс", replacement = "а/м марки \"Ambulance\""},
{abbreviation = "амбуланса", replacement = "а/м марки \"Ambulance\""},
{abbreviation = "энфорсер", replacement = "а/м марки \"Enforcer\""},
{abbreviation = "энфорсера", replacement = "а/м марки \"Enforcer\""},
{abbreviation = "рио", replacement = "а/м марки \"Rio\""},
{abbreviation = "риоа", replacement = "а/м марки \"Rio\""},
{abbreviation = "астр", replacement = "а/м марки \"Astro\""},
{abbreviation = "астра", replacement = "а/м марки \"Astro\""},
{abbreviation = "астру", replacement = "а/м марки \"Astro\""},
{abbreviation = "астры", replacement = "а/м марки \"Astro\""},
{abbreviation = "карма", replacement = "а/м марки \"Karma\""},
{abbreviation = "карму", replacement = "а/м марки \"Karma\""},
{abbreviation = "кармы", replacement = "а/м марки \"Karma\""},
{abbreviation = "клео", replacement = "а/м марки \"Cleo\""},
{abbreviation = "клеоа", replacement = "а/м марки \"Cleo\""},
{abbreviation = "фурион", replacement = "а/м марки \"Fury\""},
{abbreviation = "фуриона", replacement = "а/м марки \"Fury\""},
{abbreviation = "фуриону", replacement = "а/м марки \"Fury\""},
{abbreviation = "хаку", replacement = "а/м марки \"Hakuchou\""},
{abbreviation = "хакуа", replacement = "а/м марки \"Hakuchou\""},
{abbreviation = "хакуча", replacement = "а/м марки \"Hakuchou\""},
{abbreviation = "хакучи", replacement = "а/м марки \"Hakuchou\""},
{abbreviation = "нэо", replacement = "а/м марки \"Neo\""},
{abbreviation = "нэоа", replacement = "а/м марки \"Neo\""},
{abbreviation = "фьюри", replacement = "а/м марки \"Fury\""},
{abbreviation = "фьюриа", replacement = "а/м марки \"Fury\""},
{abbreviation = "биффа", replacement = "а/м марки \"Biff\""},
{abbreviation = "биффу", replacement = "а/м марки \"Biff\""},
{abbreviation = "биффы", replacement = "а/м марки \"Biff\""},
{abbreviation = "бифф", replacement = "а/м марки \"Biff\""},
{abbreviation = "инкассатор", replacement = "а/м марки \"Securicar\""},
{abbreviation = "инкассатора", replacement = "а/м марки \"Securicar\""},
{abbreviation = "инкас", replacement = "а/м марки \"Securicar\""},
{abbreviation = "инкаса", replacement = "а/м марки \"Securicar\""},
{abbreviation = "секурикар", replacement = "а/м марки \"Securicar\""},
{abbreviation = "мистер", replacement = "а/м марки \"Mr. Whoopee\""},
{abbreviation = "вупи", replacement = "а/м марки \"Mr. Whoopee\""},
{abbreviation = "вупиа", replacement = "а/м марки \"Mr. Whoopee\""},
{abbreviation = "хотдог", replacement = "а/м марки \"Hotdog\""},
{abbreviation = "хотдога", replacement = "а/м марки \"Hotdog\""},
{abbreviation = "квартал", replacement = "Queens"},
{abbreviation = "квартала", replacement = "Queens"},
{abbreviation = "хашбери", replacement = "Hashbury"},
{abbreviation = "хашбериа", replacement = "Hashbury"},
{abbreviation = "гарсия", replacement = "Garcia"},
{abbreviation = "гарсии", replacement = "Garcia"},
{abbreviation = "санчео", replacement = "Sanchez SF"},
{abbreviation = "элфла", replacement = "El Fuego"},
{abbreviation = "элфуэго", replacement = "El Fuego"},
{abbreviation = "бэйсайда", replacement = "Bayside"},
{abbreviation = "бэйсайду", replacement = "Bayside"},
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
{abbreviation = "флинт2а", replacement = "Flint County"},
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
{abbreviation = "салон", replacement = "салон красоты"},
{abbreviation = "салона", replacement = "салон красоты"},
{abbreviation = "салону", replacement = "салон красоты"},
{abbreviation = "тату", replacement = "тату-салон"},
{abbreviation = "тату-салона", replacement = "тату-салон"},
{abbreviation = "пиццерия", replacement = "пиццерию"},
{abbreviation = "пиццерии", replacement = "пиццерию"},
{abbreviation = "пицца", replacement = "пиццерию"},
{abbreviation = "пиццы", replacement = "пиццерию"},
{abbreviation = "борделя", replacement = "бордель"},
{abbreviation = "борделю", replacement = "бордель"},
{abbreviation = "стриптиз", replacement = "стриптиз-клуб"},
{abbreviation = "стриптиз-клуба", replacement = "стриптиз-клуб"},
{abbreviation = "джентльмен", replacement = "стриптиз-клуб"},
{abbreviation = "автомойка", replacement = "автомойку"},
{abbreviation = "автомойки", replacement = "автомойку"},
{abbreviation = "мойка", replacement = "автомойку"},
{abbreviation = "мойку", replacement = "автомойку"},
{abbreviation = "шиномонтажа", replacement = "шиномонтаж"},
{abbreviation = "сто", replacement = "СТО"},
{abbreviation = "стоа", replacement = "СТО"},
{abbreviation = "техцентра", replacement = "техцентр"},
{abbreviation = "автосервиса", replacement = "автосервис"},
{abbreviation = "шиномонтажка", replacement = "шиномонтаж"},
{abbreviation = "шиномонтажку", replacement = "шиномонтаж"},
{abbreviation = "прачечная", replacement = "прачечную"},
{abbreviation = "прачечной", replacement = "прачечную"},
{abbreviation = "химчистка", replacement = "химчистку"},
{abbreviation = "химчистки", replacement = "химчистку"},
{abbreviation = "пункта", replacement = "пункт"},
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
{abbreviation = "электроники", replacement = "электронику"},
{abbreviation = "компьютерный", replacement = "компьютерный магазин"},
{abbreviation = "компьютерного", replacement = "компьютерный магазин"},
{abbreviation = "комп", replacement = "компьютерный магазин"},
{abbreviation = "компа", replacement = "компьютерный магазин"},
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
{abbreviation = "супермаркета", replacement = "супермаркет"},
{abbreviation = "супермаркету", replacement = "супермаркет"},
{abbreviation = "мини", replacement = "мини-маркет"},
{abbreviation = "мини-маркета", replacement = "мини-маркет"},
{abbreviation = "ларька", replacement = "ларек"},
{abbreviation = "ларьку", replacement = "ларек"},
{abbreviation = "киоска", replacement = "киоск"},
{abbreviation = "палатка", replacement = "палатку"},
{abbreviation = "палатки", replacement = "палатку"},
{abbreviation = "тента", replacement = "тент"},
{abbreviation = "навеса", replacement = "навес"},
{abbreviation = "гаража", replacement = "гараж"},
{abbreviation = "гаражу", replacement = "гараж"},
{abbreviation = "гаражи", replacement = "гараж"},
{abbreviation = "бункера", replacement = "бункер"},
{abbreviation = "бункеру", replacement = "бункер"},
{abbreviation = "подвала", replacement = "подвал"},
{abbreviation = "чердака", replacement = "чердак"},
{abbreviation = "мансарда", replacement = "мансарду"},
{abbreviation = "мансарды", replacement = "мансарду"},
{abbreviation = "дача", replacement = "дачу"},
{abbreviation = "дачи", replacement = "дачу"},
{abbreviation = "коттеджа", replacement = "коттедж"},
{abbreviation = "коттеджу", replacement = "коттедж"},
{abbreviation = "таунхауса", replacement = "таунхаус"},
{abbreviation = "таунхаусу", replacement = "таунхаус"},
{abbreviation = "бунгалоа", replacement = "бунгало"},
{abbreviation = "времянка", replacement = "времянку"},
{abbreviation = "времянки", replacement = "времянку"},
{abbreviation = "халупа", replacement = "халупу"},
{abbreviation = "халупы", replacement = "халупу"},
{abbreviation = "лачуга", replacement = "лачугу"},
{abbreviation = "лачуги", replacement = "лачугу"},
{abbreviation = "шалаша", replacement = "шалаш"},
{abbreviation = "земля", replacement = "землю"},
{abbreviation = "земли", replacement = "землю"},
{abbreviation = "участка", replacement = "участок"},
{abbreviation = "участку", replacement = "участок"},
{abbreviation = "территория", replacement = "территорию"},
{abbreviation = "территории", replacement = "территорию"},
{abbreviation = "площади", replacement = "площадь"},
{abbreviation = "патронов", replacement = "патроны"},
{abbreviation = "обойма", replacement = "обойму"},
{abbreviation = "прицела", replacement = "прицел"},
{abbreviation = "глушителя", replacement = "глушитель"},
{abbreviation = "компаса", replacement = "компас"},
{abbreviation = "карты", replacement = "карту"},
{abbreviation = "термоса", replacement = "термос"},
{abbreviation = "зажигалка", replacement = "зажигалку"},
{abbreviation = "зажигалки", replacement = "зажигалку"},
{abbreviation = "сигарет", replacement = "сигареты"},
{abbreviation = "алкоголя", replacement = "алкоголь"},
{abbreviation = "пива", replacement = "пиво"},
{abbreviation = "водка", replacement = "водку"},
{abbreviation = "водки", replacement = "водку"},
{abbreviation = "вискиа", replacement = "виски"},
{abbreviation = "вина", replacement = "вино"},
{abbreviation = "кофеа", replacement = "кофе"},
{abbreviation = "чая", replacement = "чай"},
{abbreviation = "сока", replacement = "сок"},
{abbreviation = "молока", replacement = "молоко"},
{abbreviation = "хлеба", replacement = "хлеб"},
{abbreviation = "мяса", replacement = "мясо"},
{abbreviation = "рыба", replacement = "рыбу"},
{abbreviation = "рыбы", replacement = "рыбу"},
{abbreviation = "фруктов", replacement = "фрукты"},
{abbreviation = "овощей", replacement = "овощи"},
{abbreviation = "конфет", replacement = "конфеты"},
{abbreviation = "шоколада", replacement = "шоколад"},
{abbreviation = "печенья", replacement = "печенье"},
{abbreviation = "торта", replacement = "торт"},
{abbreviation = "мороженого", replacement = "мороженое"},
{abbreviation = "бургера", replacement = "бургер"},
{abbreviation = "гамбургера", replacement = "гамбургер"},
{abbreviation = "сэндвича", replacement = "сэндвич"},
{abbreviation = "роллов", replacement = "роллы"},
{abbreviation = "лапша", replacement = "лапшу"},
{abbreviation = "лапши", replacement = "лапшу"},
{abbreviation = "пельменей", replacement = "пельмени"},
{abbreviation = "борща", replacement = "борщ"},
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
{abbreviation = "миниа", replacement = "оружие \"Minigun\""},
{abbreviation = "массажа", replacement = "массаж"},
{abbreviation = "стрижка", replacement = "стрижку"},
{abbreviation = "стрижки", replacement = "стрижку"},
{abbreviation = "маникюра", replacement = "маникюр"},
{abbreviation = "педикюра", replacement = "педикюр"},
{abbreviation = "бритья", replacement = "бритье"},
{abbreviation = "укладка", replacement = "укладку"},
{abbreviation = "окраска", replacement = "окраску"},
{abbreviation = "окраски", replacement = "окраску"},
{abbreviation = "наращивания", replacement = "наращивание"},
{abbreviation = "пирсинга", replacement = "пирсинг"},
{abbreviation = "татуировка", replacement = "татуировку"},
{abbreviation = "татуировки", replacement = "татуировку"},
{abbreviation = "репетитор", replacement = "репетитора"},
{abbreviation = "обучения", replacement = "обучение"},
{abbreviation = "курсов", replacement = "курсы"},
{abbreviation = "тренинга", replacement = "тренинг"},
{abbreviation = "тренинги", replacement = "тренинг"},
{abbreviation = "семинара", replacement = "семинар"},
{abbreviation = "лекция", replacement = "лекцию"},
{abbreviation = "лекции", replacement = "лекцию"},
{abbreviation = "консультация", replacement = "консультацию"},
{abbreviation = "консультации", replacement = "консультацию"},
{abbreviation = "лечения", replacement = "лечение"},
{abbreviation = "терапия", replacement = "терапию"},
{abbreviation = "диагностика", replacement = "диагностику"},
{abbreviation = "диагностики", replacement = "диагностику"},
{abbreviation = "настройка", replacement = "настройку"},
{abbreviation = "настройки", replacement = "настройку"},
{abbreviation = "установка", replacement = "установку"},
{abbreviation = "установки", replacement = "установку"},
{abbreviation = "монтажа", replacement = "монтаж"},
{abbreviation = "демонтажа", replacement = "демонтаж"},
{abbreviation = "перевозка", replacement = "перевозку"},
{abbreviation = "перевозки", replacement = "перевозку"},
{abbreviation = "грузоперевозок", replacement = "грузоперевозки"},
{abbreviation = "логистика", replacement = "логистику"},
{abbreviation = "хранения", replacement = "хранение"},
{abbreviation = "сигнализация", replacement = "сигнализацию"},
{abbreviation = "сигнализации", replacement = "сигнализацию"},
{abbreviation = "видеонаблюдения", replacement = "видеонаблюдение"},
{abbreviation = "уборка", replacement = "уборку"},
{abbreviation = "уборки", replacement = "уборку"},
{abbreviation = "клининга", replacement = "клининг"},
{abbreviation = "стирка", replacement = "стирку"},
{abbreviation = "стирки", replacement = "стирку"},
{abbreviation = "глажка", replacement = "глажку"},
{abbreviation = "глажки", replacement = "глажку"},
{abbreviation = "починки", replacement = "починку"},
{abbreviation = "наладка", replacement = "наладку"},
{abbreviation = "наладки", replacement = "наладку"},
{abbreviation = "дозаправка", replacement = "дозаправку"},
{abbreviation = "буксировка", replacement = "буксировку"},
{abbreviation = "буксировки", replacement = "буксировку"},
{abbreviation = "запуск", replacement = "запуск двигателя"},
{abbreviation = "запуска", replacement = "запуск двигателя"},
{abbreviation = "прикуривания", replacement = "прикуривание"},
{abbreviation = "замена", replacement = "замену"},
{abbreviation = "замены", replacement = "замену"},
{abbreviation = "масло", replacement = "замену масла"},
{abbreviation = "масла", replacement = "замену масла"},
{abbreviation = "фильтра", replacement = "фильтр"},
{abbreviation = "шин", replacement = "шины"},
{abbreviation = "покрышек", replacement = "покрышки"},
{abbreviation = "дисков", replacement = "диски"},
{abbreviation = "колес", replacement = "колеса"},
{abbreviation = "аккумулятора", replacement = "аккумулятор"},
{abbreviation = "смартфона", replacement = "смартфон"},
{abbreviation = "айфон", replacement = "смартфон"},
{abbreviation = "айфона", replacement = "смартфон"},
{abbreviation = "андроид", replacement = "смартфон"},
{abbreviation = "планшета", replacement = "планшет"},
{abbreviation = "ноутбука", replacement = "ноутбук"},
{abbreviation = "компьютера", replacement = "компьютер"},
{abbreviation = "монитора", replacement = "монитор"},
{abbreviation = "клавиатура", replacement = "клавиатуру"},
{abbreviation = "мыши", replacement = "мышь"},
{abbreviation = "принтера", replacement = "принтер"},
{abbreviation = "наушников", replacement = "наушники"},
{abbreviation = "колонка", replacement = "колонку"},
{abbreviation = "колонки", replacement = "колонку"},
{abbreviation = "микрофона", replacement = "микрофон"},
{abbreviation = "камера", replacement = "камеру"},
{abbreviation = "камеры", replacement = "камеру"},
{abbreviation = "фотоаппарата", replacement = "фотоаппарат"},
{abbreviation = "объектива", replacement = "объектив"},
{abbreviation = "штатива", replacement = "штатив"},
{abbreviation = "линзов", replacement = "линзы"},
{abbreviation = "сумка", replacement = "сумку"},
{abbreviation = "сумки", replacement = "сумку"},
{abbreviation = "чемодана", replacement = "чемодан"},
{abbreviation = "портфеля", replacement = "портфель"},
{abbreviation = "кошелька", replacement = "кошелек"},
{abbreviation = "зонта", replacement = "зонт"},
{abbreviation = "ключа", replacement = "ключ"},
{abbreviation = "ключей", replacement = "ключи"},
{abbreviation = "замка", replacement = "замок"},
{abbreviation = "цепи", replacement = "цепь"},
{abbreviation = "брелока", replacement = "брелок"},
{abbreviation = "значка", replacement = "значок"},
{abbreviation = "медали", replacement = "медаль"},
{abbreviation = "кубка", replacement = "кубок"},
{abbreviation = "грамота", replacement = "грамоту"},
{abbreviation = "диплома", replacement = "диплом"},
{abbreviation = "сертификата", replacement = "сертификат"},
{abbreviation = "купона", replacement = "купон"},
{abbreviation = "ваучера", replacement = "ваучер"},
{abbreviation = "билета", replacement = "билет"},
{abbreviation = "абонемента", replacement = "абонемент"},
{abbreviation = "пропуска", replacement = "пропуск"},
{abbreviation = "бенсон", replacement = "а/м марки \"Benson\""},
{abbreviation = "бенсона", replacement = "а/м марки \"Benson\""},
{abbreviation = "бенсону", replacement = "а/м марки \"Benson\""},
{abbreviation = "боксвилл", replacement = "а/м марки \"Boxville\""},
{abbreviation = "боксвилла", replacement = "а/м марки \"Boxville\""},
{abbreviation = "борд", replacement = "а/м марки \"Bord\""},
{abbreviation = "борда", replacement = "а/м марки \"Bord\""},
{abbreviation = "калвер", replacement = "а/м марки \"Culver\""},
{abbreviation = "калвера", replacement = "а/м марки \"Culver\""},
{abbreviation = "дюнес", replacement = "а/м марки \"Dunes\""},
{abbreviation = "дюнеса", replacement = "а/м марки \"Dunes\""},
{abbreviation = "ханли", replacement = "а/м марки \"Hanley\""},
{abbreviation = "ханлиа", replacement = "а/м марки \"Hanley\""},
{abbreviation = "ларго", replacement = "а/м марки \"Largo\""},
{abbreviation = "ларгоа", replacement = "а/м марки \"Largo\""},
{abbreviation = "локус", replacement = "а/м марки \"Locust\""},
{abbreviation = "локуса", replacement = "а/м марки \"Locust\""},
{abbreviation = "маверик", replacement = "а/м марки \"Maverick\""},
{abbreviation = "маверика", replacement = "а/м марки \"Maverick\""},
{abbreviation = "мерит", replacement = "а/м марки \"Merit\""},
{abbreviation = "мерита", replacement = "а/м марки \"Merit\""},
{abbreviation = "мэверик", replacement = "а/м марки \"Maverick\""},
{abbreviation = "мэверика", replacement = "а/м марки \"Maverick\""},
{abbreviation = "нэссон", replacement = "а/м марки \"Nesson\""},
{abbreviation = "нэссона", replacement = "а/м марки \"Nesson\""},
{abbreviation = "полар", replacement = "а/м марки \"Polar\""},
{abbreviation = "полара", replacement = "а/м марки \"Polar\""},
{abbreviation = "санчо", replacement = "а/м марки \"Sanchez\""},
{abbreviation = "санчоа", replacement = "а/м марки \"Sanchez\""},
{abbreviation = "симплон", replacement = "а/м марки \"Simpleon\""},
{abbreviation = "симплона", replacement = "а/м марки \"Simpleon\""},
{abbreviation = "симпл", replacement = "а/м марки \"Simpleon\""},
{abbreviation = "спринтер", replacement = "а/м марки \"Sprinter\""},
{abbreviation = "спринтера", replacement = "а/м марки \"Sprinter\""},
{abbreviation = "стока", replacement = "а/м марки \"Stock\""},
{abbreviation = "трэш", replacement = "а/м марки \"Trash\""},
{abbreviation = "трэша", replacement = "а/м марки \"Trash\""},
{abbreviation = "трэшмастер", replacement = "а/м марки \"Trashmaster\""},
{abbreviation = "трэшмастера", replacement = "а/м марки \"Trashmaster\""},
{abbreviation = "урал", replacement = "а/м марки \"Ural\""},
{abbreviation = "урала", replacement = "а/м марки \"Ural\""},
{abbreviation = "уралу", replacement = "а/м марки \"Ural\""},
{abbreviation = "вэн", replacement = "а/м марки \"Van\""},
{abbreviation = "вэна", replacement = "а/м марки \"Van\""},
{abbreviation = "вэну", replacement = "а/м марки \"Van\""},
{abbreviation = "вэнс", replacement = "а/м марки \"Vance\""},
{abbreviation = "вэнса", replacement = "а/м марки \"Vance\""},
{abbreviation = "вэнсон", replacement = "а/м марки \"Venson\""},
{abbreviation = "вэнсона", replacement = "а/м марки \"Venson\""},
{abbreviation = "йолк", replacement = "а/м марки \"Yolk\""},
{abbreviation = "йолка", replacement = "а/м марки \"Yolk\""},
{abbreviation = "банши2а", replacement = "а/м марки \"Banshee\""},
{abbreviation = "катер", replacement = "лодку"},
{abbreviation = "катера", replacement = "лодку"},
{abbreviation = "катеру", replacement = "лодку"},
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
{abbreviation = "кукурузник", replacement = "самолёт"},
{abbreviation = "кукурузника", replacement = "самолёт"},
{abbreviation = "кукурузнику", replacement = "самолёт"},
{abbreviation = "истребитель", replacement = "самолёт"},
{abbreviation = "истребителя", replacement = "самолёт"},
{abbreviation = "бомбардировщик", replacement = "самолёт"},
{abbreviation = "бомбардировщика", replacement = "самолёт"},
{abbreviation = "дирижабля", replacement = "дирижабль"},
{abbreviation = "воздушный", replacement = "шар"},
{abbreviation = "шара", replacement = "шар"},
{abbreviation = "дельтаплана", replacement = "дельтаплан"},
{abbreviation = "эхо", replacement = "East Los Santos"},
{abbreviation = "эхоа", replacement = "East Los Santos"},
{abbreviation = "эхо парк", replacement = "East Los Santos"},
{abbreviation = "айдинлвуд", replacement = "Idlewood"},
{abbreviation = "айдинлвуда", replacement = "Idlewood"},
{abbreviation = "джеф2а", replacement = "Jefferson"},
{abbreviation = "элкорона2а", replacement = "El Corona"},
{abbreviation = "конференс", replacement = "Conference Center"},
{abbreviation = "конференса", replacement = "Conference Center"},
{abbreviation = "персхинг", replacement = "Pershing Square"},
{abbreviation = "персхинга", replacement = "Pershing Square"},
{abbreviation = "першинг", replacement = "Pershing Square"},
{abbreviation = "першинга", replacement = "Pershing Square"},
{abbreviation = "сити", replacement = "City Hall"},
{abbreviation = "таун", replacement = "Downtown"},
{abbreviation = "тауна", replacement = "Downtown"},
{abbreviation = "даунтаун", replacement = "Downtown"},
{abbreviation = "даунтауна", replacement = "Downtown"},
{abbreviation = "фостер", replacement = "Foster Valley"},
{abbreviation = "фостера", replacement = "Foster Valley"},
{abbreviation = "гарберри", replacement = "Garberry"},
{abbreviation = "гарберриа", replacement = "Garberry"},
{abbreviation = "эшберри2а", replacement = "Ashberry"},
{abbreviation = "бэйсайд2а", replacement = "Bayside"},
{abbreviation = "элькебрадос", replacement = "El Quebrados"},
{abbreviation = "элькуебрадос", replacement = "El Quebrados"},
{abbreviation = "аэропорт", replacement = "Airport"},
{abbreviation = "аэропорта", replacement = "Airport"},
{abbreviation = "аэропорту", replacement = "Airport"},
{abbreviation = "аэро", replacement = "Airport"},
{abbreviation = "аэроа", replacement = "Airport"},
{abbreviation = "вокзал", replacement = "Station"},
{abbreviation = "вокзала", replacement = "Station"},
{abbreviation = "станция", replacement = "Station"},
{abbreviation = "станции", replacement = "Station"},
{abbreviation = "станцию", replacement = "Station"},
{abbreviation = "метро", replacement = "Metro"},
{abbreviation = "метроа", replacement = "Metro"},
{abbreviation = "остановка", replacement = "остановку"},
{abbreviation = "перекрестка", replacement = "перекресток"},
{abbreviation = "развязка", replacement = "развязку"},
{abbreviation = "моста", replacement = "мост"},
{abbreviation = "тоннеля", replacement = "тоннель"},
{abbreviation = "трасса", replacement = "трассу"},
{abbreviation = "шоссеа", replacement = "шоссе"},
{abbreviation = "автострада", replacement = "автостраду"},
{abbreviation = "дорога", replacement = "дорогу"},
{abbreviation = "улица", replacement = "улицу"},
{abbreviation = "переулка", replacement = "переулок"},
{abbreviation = "проспекта", replacement = "проспект"},
{abbreviation = "бульвара", replacement = "бульвар"},
{abbreviation = "набережная", replacement = "набережную"},
{abbreviation = "пляжа", replacement = "пляж"},
{abbreviation = "берега", replacement = "берег"},
{abbreviation = "острова", replacement = "остров"},
{abbreviation = "полуострова", replacement = "полуостров"},
{abbreviation = "залива", replacement = "залив"},
{abbreviation = "бухта", replacement = "бухту"},
{abbreviation = "мыса", replacement = "мыс"},
{abbreviation = "гора", replacement = "гору"},
{abbreviation = "холма", replacement = "холм"},
{abbreviation = "долина", replacement = "долину"},
{abbreviation = "пустыня", replacement = "пустыню"},
{abbreviation = "леса", replacement = "лес"},
{abbreviation = "поля", replacement = "поле"},
{abbreviation = "озера", replacement = "озеро"},
{abbreviation = "река", replacement = "реку"},
{abbreviation = "канала", replacement = "канал"},
{abbreviation = "водопада", replacement = "водопад"},
{abbreviation = "каньона", replacement = "каньон"},
{abbreviation = "ущелья", replacement = "ущелье"},
{abbreviation = "пещера", replacement = "пещеру"},
{abbreviation = "руин", replacement = "руины"},
{abbreviation = "крепости", replacement = "крепость"},
{abbreviation = "башня", replacement = "башню"},
{abbreviation = "колокола", replacement = "колокол"},
{abbreviation = "маяка", replacement = "маяк"},
{abbreviation = "плотина", replacement = "плотину"},
{abbreviation = "шлюза", replacement = "шлюз"},
{abbreviation = "мельница", replacement = "мельницу"},
{abbreviation = "карьера", replacement = "карьер"},
{abbreviation = "рудника", replacement = "рудник"},
{abbreviation = "барбер", replacement = "парикмахерскую"},
{abbreviation = "цирюльня", replacement = "парикмахерскую"},
{abbreviation = "цирюльню", replacement = "парикмахерскую"},
{abbreviation = "спа", replacement = "СПА"},
{abbreviation = "спаа", replacement = "СПА"},
{abbreviation = "бани", replacement = "баню"},
{abbreviation = "бanya", replacement = "баню"},
{abbreviation = "сауна", replacement = "сауну"},
{abbreviation = "сауны", replacement = "сауну"},
{abbreviation = "бассейна", replacement = "бассейн"},
{abbreviation = "аквапарка", replacement = "аквапарк"},
{abbreviation = "сада", replacement = "сад"},
{abbreviation = "огорода", replacement = "огород"},
{abbreviation = "теплица", replacement = "теплицу"},
{abbreviation = "оранжерея", replacement = "оранжерею"},
{abbreviation = "питомника", replacement = "питомник"},
{abbreviation = "зоопарка", replacement = "зоопарк"},
{abbreviation = "конюшня", replacement = "конюшню"},
{abbreviation = "пасека", replacement = "пасеку"},
{abbreviation = "ульи", replacement = "пасеку"},
{abbreviation = "рыбхоза", replacement = "рыбхоз"},
{abbreviation = "пруда", replacement = "пруд"},
{abbreviation = "депоа", replacement = "депо"},
{abbreviation = "стоянка", replacement = "стоянку"},
{abbreviation = "парковка", replacement = "парковку"},
{abbreviation = "автостоянка", replacement = "автостоянку"},
{abbreviation = "ремзона", replacement = "ремзону"},
{abbreviation = "офиса", replacement = "офис"},
{abbreviation = "офису", replacement = "офис"},
{abbreviation = "контора", replacement = "контору"},
{abbreviation = "конторы", replacement = "контору"},
{abbreviation = "бюроа", replacement = "бюро"},
{abbreviation = "агентства", replacement = "агентство"},
{abbreviation = "представительства", replacement = "представительство"},
{abbreviation = "отделения", replacement = "отделение"},
{abbreviation = "филиала", replacement = "филиал"},
{abbreviation = "цеха", replacement = "цех"},
{abbreviation = "лаборатория", replacement = "лабораторию"},
{abbreviation = "мастерская", replacement = "мастерскую"},
{abbreviation = "мастерские", replacement = "мастерскую"},
{abbreviation = "ательеа", replacement = "ателье"},
{abbreviation = "студия", replacement = "студию"},
{abbreviation = "студии", replacement = "студию"},
{abbreviation = "фотостудия", replacement = "фотостудию"},
{abbreviation = "музыкальная", replacement = "музыкальную студию"},
{abbreviation = "танцевальная", replacement = "танцевальную студию"},
{abbreviation = "тренажерный", replacement = "тренажёрный зал"},
{abbreviation = "тренажёрный", replacement = "тренажёрный зал"},
{abbreviation = "фитнес", replacement = "фитнес-клуб"},
{abbreviation = "фитнеса", replacement = "фитнес-клуб"},
{abbreviation = "фитнес-клуба", replacement = "фитнес-клуб"},
{abbreviation = "йога", replacement = "йога-студию"},
{abbreviation = "пилатес", replacement = "студию пилатеса"},
{abbreviation = "единоборства", replacement = "зал единоборств"},
{abbreviation = "бокс", replacement = "боксерский зал"},
{abbreviation = "боксерский", replacement = "боксерский зал"},
{abbreviation = "спорт", replacement = "спортзал"},
{abbreviation = "спорта", replacement = "спортзал"},
{abbreviation = "училища", replacement = "училище"},
{abbreviation = "колледжа", replacement = "колледж"},
{abbreviation = "университета", replacement = "университет"},
{abbreviation = "института", replacement = "институт"},
{abbreviation = "академия", replacement = "академию"},
{abbreviation = "лицея", replacement = "лицей"},
{abbreviation = "детсад", replacement = "детский сад"},
{abbreviation = "детский", replacement = "детский сад"},
{abbreviation = "яслей", replacement = "ясли"},
{abbreviation = "хосписа", replacement = "хоспис"},
{abbreviation = "санатория", replacement = "санаторий"},
{abbreviation = "пансионата", replacement = "пансионат"},
{abbreviation = "курорта", replacement = "курорт"},
{abbreviation = "турбаза", replacement = "турбазу"},
{abbreviation = "кемпинга", replacement = "кемпинг"},
{abbreviation = "гостиница", replacement = "гостиницу"},
{abbreviation = "хостела", replacement = "хостел"},
{abbreviation = "общежития", replacement = "общежитие"},
{abbreviation = "комната", replacement = "комнату"},
{abbreviation = "комнаты", replacement = "комнату"},
{abbreviation = "койка", replacement = "койко-место"},
{abbreviation = "койку", replacement = "койко-место"},
{abbreviation = "койки", replacement = "койко-место"},
{abbreviation = "спальня", replacement = "спальню"},
{abbreviation = "гостиная", replacement = "гостиную"},
{abbreviation = "кухня", replacement = "кухню"},
{abbreviation = "ванная", replacement = "ванную"},
{abbreviation = "балкона", replacement = "балкон"},
{abbreviation = "терраса", replacement = "террасу"},
{abbreviation = "веранда", replacement = "веранду"},
{abbreviation = "беседка", replacement = "беседку"},
{abbreviation = "сарая", replacement = "сарай"},
{abbreviation = "амбара", replacement = "амбар"},
{abbreviation = "хлева", replacement = "хлев"},
{abbreviation = "курятника", replacement = "курятник"},
{abbreviation = "конура", replacement = "конуру"},
{abbreviation = "будка", replacement = "будку"},
{abbreviation = "колодца", replacement = "колодец"},
{abbreviation = "скважина", replacement = "скважину"},
{abbreviation = "септика", replacement = "септик"},
{abbreviation = "канализация", replacement = "канализацию"},
{abbreviation = "электричества", replacement = "электричество"},
{abbreviation = "генератора", replacement = "генератор"},
{abbreviation = "солнечная", replacement = "солнечную панель"},
{abbreviation = "ветряка", replacement = "ветряк"},
{abbreviation = "турбина", replacement = "турбину"},
{abbreviation = "футболка", replacement = "футболку"},
{abbreviation = "майка", replacement = "майку"},
{abbreviation = "рубашка", replacement = "рубашку"},
{abbreviation = "брюк", replacement = "брюки"},
{abbreviation = "джинсов", replacement = "джинсы"},
{abbreviation = "шорт", replacement = "шорты"},
{abbreviation = "юбка", replacement = "юбку"},
{abbreviation = "платья", replacement = "платье"},
{abbreviation = "костюма", replacement = "костюм"},
{abbreviation = "пиджака", replacement = "пиджак"},
{abbreviation = "жилета", replacement = "жилет"},
{abbreviation = "свитера", replacement = "свитер"},
{abbreviation = "кофта", replacement = "кофту"},
{abbreviation = "куртка", replacement = "куртку"},
{abbreviation = "пальтоа", replacement = "пальто"},
{abbreviation = "шуба", replacement = "шубу"},
{abbreviation = "дубленка", replacement = "дубленку"},
{abbreviation = "пуховика", replacement = "пуховик"},
{abbreviation = "ветровка", replacement = "ветровку"},
{abbreviation = "тренча", replacement = "тренч"},
{abbreviation = "плаща", replacement = "плащ"},
{abbreviation = "галстука", replacement = "галстук"},
{abbreviation = "бабочка", replacement = "бабочку"},
{abbreviation = "ремня", replacement = "ремень"},
{abbreviation = "пояса", replacement = "пояс"},
{abbreviation = "шарфа", replacement = "шарф"},
{abbreviation = "перчаток", replacement = "перчатки"},
{abbreviation = "варежек", replacement = "варежки"},
{abbreviation = "носков", replacement = "носки"},
{abbreviation = "чулок", replacement = "чулки"},
{abbreviation = "колготок", replacement = "колготки"},
{abbreviation = "трусов", replacement = "трусы"},
{abbreviation = "бра", replacement = "бюстгальтер"},
{abbreviation = "нижнее", replacement = "нижнее белье"},
{abbreviation = "белье", replacement = "нижнее белье"},
{abbreviation = "белья", replacement = "нижнее белье"},
{abbreviation = "пижама", replacement = "пижаму"},
{abbreviation = "халата", replacement = "халат"},
{abbreviation = "купальника", replacement = "купальник"},
{abbreviation = "бикиниа", replacement = "бикини"},
{abbreviation = "сланцев", replacement = "сланцы"},
{abbreviation = "шлепанцев", replacement = "шлепанцы"},
{abbreviation = "вьетнамок", replacement = "вьетнамки"},
{abbreviation = "босоножек", replacement = "босоножки"},
{abbreviation = "сандалий", replacement = "сандалии"},
{abbreviation = "кедов", replacement = "кеды"},
{abbreviation = "кроссовок", replacement = "кроссовки"},
{abbreviation = "туфель", replacement = "туфли"},
{abbreviation = "ботинок", replacement = "ботинки"},
{abbreviation = "сапог", replacement = "сапоги"},
{abbreviation = "валенок", replacement = "валенки"},
{abbreviation = "уггов", replacement = "угги"},
{abbreviation = "мокасин", replacement = "мокасины"},
{abbreviation = "лоферов", replacement = "лоферы"},
{abbreviation = "эспадрилий", replacement = "эспадрильи"},
{abbreviation = "обуви", replacement = "обувь"},
{abbreviation = "кросовки", replacement = "кроссовки"},
{abbreviation = "кросовок", replacement = "кроссовки"},
{abbreviation = "браслета", replacement = "браслет"},
{abbreviation = "кольца", replacement = "кольцо"},
{abbreviation = "серег", replacement = "серьги"},
{abbreviation = "цепочка", replacement = "цепочку"},
{abbreviation = "кулона", replacement = "кулон"},
{abbreviation = "броши", replacement = "брошь"},
{abbreviation = "заколка", replacement = "заколку"},
{abbreviation = "обруча", replacement = "обруч"},
{abbreviation = "корона", replacement = "корону"},
{abbreviation = "диадема", replacement = "диадему"},
{abbreviation = "зажима", replacement = "зажим"},
{abbreviation = "портупея", replacement = "портупею"},
{abbreviation = "подтяжек", replacement = "подтяжки"},
{abbreviation = "самсунг", replacement = "смартфон"},
{abbreviation = "самсунга", replacement = "смартфон"},
{abbreviation = "нокиа", replacement = "смартфон"},
{abbreviation = "нокиаа", replacement = "смартфон"},
{abbreviation = "сяоми", replacement = "смартфон"},
{abbreviation = "хонор", replacement = "смартфон"},
{abbreviation = "хуавей", replacement = "смартфон"},
{abbreviation = "айпад", replacement = "планшет"},
{abbreviation = "айпада", replacement = "планшет"},
{abbreviation = "лэптоп", replacement = "ноутбук"},
{abbreviation = "лэптопа", replacement = "ноутбук"},
{abbreviation = "макбук", replacement = "ноутбук"},
{abbreviation = "макбука", replacement = "ноутбук"},
{abbreviation = "пка", replacement = "компьютер"},
{abbreviation = "системник", replacement = "компьютер"},
{abbreviation = "системника", replacement = "компьютер"},
{abbreviation = "процессора", replacement = "процессор"},
{abbreviation = "видеокарта", replacement = "видеокарту"},
{abbreviation = "озу", replacement = "оперативную память"},
{abbreviation = "оперативная", replacement = "оперативную память"},
{abbreviation = "памяти", replacement = "память"},
{abbreviation = "жесткий", replacement = "жесткий диск"},
{abbreviation = "диска", replacement = "диск"},
{abbreviation = "ссд", replacement = "SSD накопитель"},
{abbreviation = "ссда", replacement = "SSD накопитель"},
{abbreviation = "хард", replacement = "жесткий диск"},
{abbreviation = "харда", replacement = "жесткий диск"},
{abbreviation = "флешка", replacement = "флешку"},
{abbreviation = "флешки", replacement = "флешку"},
{abbreviation = "флэшка", replacement = "флешку"},
{abbreviation = "флэшку", replacement = "флешку"},
{abbreviation = "юзб", replacement = "USB-накопитель"},
{abbreviation = "юсб", replacement = "USB-накопитель"},
{abbreviation = "роутера", replacement = "роутер"},
{abbreviation = "модема", replacement = "модем"},
{abbreviation = "свитч", replacement = "коммутатор"},
{abbreviation = "хаб", replacement = "концентратор"},
{abbreviation = "патч", replacement = "патч-корд"},
{abbreviation = "кабеля", replacement = "кабель"},
{abbreviation = "провода", replacement = "провод"},
{abbreviation = "удлинителя", replacement = "удлинитель"},
{abbreviation = "сетевой", replacement = "сетевой фильтр"},
{abbreviation = "блок", replacement = "блок питания"},
{abbreviation = "блока", replacement = "блок питания"},
{abbreviation = "бп", replacement = "блок питания"},
{abbreviation = "бпа", replacement = "блок питания"},
{abbreviation = "куллер", replacement = "кулер"},
{abbreviation = "кулера", replacement = "кулер"},
{abbreviation = "куллеры", replacement = "кулер"},
{abbreviation = "термопаста", replacement = "термопасту"},
{abbreviation = "материнка", replacement = "материнскую плату"},
{abbreviation = "материнскую", replacement = "материнскую плату"},
{abbreviation = "плата", replacement = "плату"},
{abbreviation = "платы", replacement = "плату"},
{abbreviation = "звуковая", replacement = "звуковую карту"},
{abbreviation = "сетевая", replacement = "сетевую карту"},
{abbreviation = "твтюнер", replacement = "ТВ-тюнер"},
{abbreviation = "вебка", replacement = "веб-камеру"},
{abbreviation = "веб-камера", replacement = "веб-камеру"},
{abbreviation = "вебкамера", replacement = "веб-камеру"},
{abbreviation = "телевизора", replacement = "телевизор"},
{abbreviation = "тв", replacement = "телевизор"},
{abbreviation = "тва", replacement = "телевизор"},
{abbreviation = "яндекств", replacement = "телевизор"},
{abbreviation = "смарттв", replacement = "телевизор"},
{abbreviation = "холодильника", replacement = "холодильник"},
{abbreviation = "морозилка", replacement = "морозилку"},
{abbreviation = "стиралка", replacement = "стиральную машину"},
{abbreviation = "стиральная", replacement = "стиральную машину"},
{abbreviation = "стиральную", replacement = "стиральную машину"},
{abbreviation = "посудомойка", replacement = "посудомойку"},
{abbreviation = "посудомоечная", replacement = "посудомойку"},
{abbreviation = "печи", replacement = "печь"},
{abbreviation = "духовка", replacement = "духовку"},
{abbreviation = "плита", replacement = "плиту"},
{abbreviation = "варочная", replacement = "варочную панель"},
{abbreviation = "микроволновка", replacement = "микроволновку"},
{abbreviation = "микроволновая", replacement = "микроволновку"},
{abbreviation = "миксера", replacement = "миксер"},
{abbreviation = "блендера", replacement = "блендер"},
{abbreviation = "комбайн", replacement = "кухонный комбайн"},
{abbreviation = "тостера", replacement = "тостер"},
{abbreviation = "кофеварка", replacement = "кофеварку"},
{abbreviation = "кофемашина", replacement = "кофемашину"},
{abbreviation = "чайника", replacement = "чайник"},
{abbreviation = "пылесоса", replacement = "пылесос"},
{abbreviation = "робот", replacement = "робот-пылесос"},
{abbreviation = "робота", replacement = "робот-пылесос"},
{abbreviation = "швабра", replacement = "швабру"},
{abbreviation = "ведра", replacement = "ведро"},
{abbreviation = "щетка", replacement = "щетку"},
{abbreviation = "совка", replacement = "совок"},
{abbreviation = "утюга", replacement = "утюг"},
{abbreviation = "парогенератора", replacement = "парогенератор"},
{abbreviation = "кондиционера", replacement = "кондиционер"},
{abbreviation = "обогревателя", replacement = "обогреватель"},
{abbreviation = "радиатора", replacement = "радиатор"},
{abbreviation = "батарея", replacement = "батарею"},
{abbreviation = "камина", replacement = "камин"},
{abbreviation = "печка", replacement = "печку"},
{abbreviation = "буржуйка", replacement = "буржуйку"},
{abbreviation = "люстра", replacement = "люстру"},
{abbreviation = "лампа", replacement = "лампу"},
{abbreviation = "лампы", replacement = "лампу"},
{abbreviation = "торшера", replacement = "торшер"},
{abbreviation = "светильника", replacement = "светильник"},
{abbreviation = "фонаря", replacement = "фонарь"},
{abbreviation = "прожектора", replacement = "прожектор"},
{abbreviation = "гирлянда", replacement = "гирлянду"},
{abbreviation = "диско", replacement = "диско-шар"},
{abbreviation = "дивана", replacement = "диван"},
{abbreviation = "кресла", replacement = "кресло"},
{abbreviation = "стула", replacement = "стул"},
{abbreviation = "стульев", replacement = "стулья"},
{abbreviation = "табурета", replacement = "табурет"},
{abbreviation = "табуретка", replacement = "табуретку"},
{abbreviation = "стола", replacement = "стол"},
{abbreviation = "столов", replacement = "столы"},
{abbreviation = "журнальный", replacement = "журнальный столик"},
{abbreviation = "столика", replacement = "столик"},
{abbreviation = "тумба", replacement = "тумбу"},
{abbreviation = "тумбы", replacement = "тумбу"},
{abbreviation = "комода", replacement = "комод"},
{abbreviation = "шкафа", replacement = "шкаф"},
{abbreviation = "шкафов", replacement = "шкафы"},
{abbreviation = "гардероба", replacement = "гардероб"},
{abbreviation = "вешалка", replacement = "вешалку"},
{abbreviation = "полка", replacement = "полку"},
{abbreviation = "полки", replacement = "полку"},
{abbreviation = "стеллажа", replacement = "стеллаж"},
{abbreviation = "этажерка", replacement = "этажерку"},
{abbreviation = "кровати", replacement = "кровать"},
{abbreviation = "кроватей", replacement = "кровать"},
{abbreviation = "матраса", replacement = "матрас"},
{abbreviation = "матрац", replacement = "матрас"},
{abbreviation = "матраца", replacement = "матрас"},
{abbreviation = "подушка", replacement = "подушку"},
{abbreviation = "подушки", replacement = "подушку"},
{abbreviation = "одеяла", replacement = "одеяло"},
{abbreviation = "пледа", replacement = "плед"},
{abbreviation = "покрывала", replacement = "покрывало"},
{abbreviation = "простыня", replacement = "простыню"},
{abbreviation = "пододеяльника", replacement = "пододеяльник"},
{abbreviation = "наволочка", replacement = "наволочку"},
{abbreviation = "зеркала", replacement = "зеркало"},
{abbreviation = "картина", replacement = "картину"},
{abbreviation = "постера", replacement = "постер"},
{abbreviation = "ковра", replacement = "ковер"},
{abbreviation = "ковров", replacement = "ковры"},
{abbreviation = "паласа", replacement = "палас"},
{abbreviation = "дорожка", replacement = "дорожку"},
{abbreviation = "циновка", replacement = "циновку"},
{abbreviation = "штора", replacement = "штору"},
{abbreviation = "штор", replacement = "шторы"},
{abbreviation = "жалюзиа", replacement = "жалюзи"},
{abbreviation = "карниза", replacement = "карниз"},
{abbreviation = "декора", replacement = "декор"},
{abbreviation = "сувенира", replacement = "сувенир"},
{abbreviation = "статуэтка", replacement = "статуэтку"},
{abbreviation = "ваза", replacement = "вазу"},
{abbreviation = "вазы", replacement = "вазу"},
{abbreviation = "горшка", replacement = "горшок"},
{abbreviation = "вазона", replacement = "вазон"},
{abbreviation = "цветка", replacement = "цветок"},
{abbreviation = "растения", replacement = "растение"},
{abbreviation = "букета", replacement = "букет"},
{abbreviation = "лекарств", replacement = "лекарства"},
{abbreviation = "таблеток", replacement = "таблетки"},
{abbreviation = "антибиотика", replacement = "антибиотик"},
{abbreviation = "витаминов", replacement = "витамины"},
{abbreviation = "анальгина", replacement = "анальгин"},
{abbreviation = "аспирина", replacement = "аспирин"},
{abbreviation = "ношпа", replacement = "ношпу"},
{abbreviation = "активированный", replacement = "активированный уголь"},
{abbreviation = "уголь", replacement = "активированный уголь"},
{abbreviation = "угля", replacement = "активированный уголь"},
{abbreviation = "йода", replacement = "йод"},
{abbreviation = "зеленка", replacement = "зеленку"},
{abbreviation = "перекиси", replacement = "перекись"},
{abbreviation = "пластыря", replacement = "пластырь"},
{abbreviation = "бинта", replacement = "бинт"},
{abbreviation = "марля", replacement = "марлю"},
{abbreviation = "шприца", replacement = "шприц"},
{abbreviation = "мази", replacement = "мазь"},
{abbreviation = "крема", replacement = "крем"},
{abbreviation = "геля", replacement = "гель"},
{abbreviation = "спрея", replacement = "спрей"},
{abbreviation = "молотка", replacement = "молоток"},
{abbreviation = "отвертка", replacement = "отвертку"},
{abbreviation = "гаечный", replacement = "гаечный ключ"},
{abbreviation = "торцевой", replacement = "торцевой ключ"},
{abbreviation = "разводной", replacement = "разводной ключ"},
{abbreviation = "пила", replacement = "пилу"},
{abbreviation = "ножовка", replacement = "ножовку"},
{abbreviation = "болгарка", replacement = "болгарку"},
{abbreviation = "дрели", replacement = "дрель"},
{abbreviation = "шуруповерта", replacement = "шуруповерт"},
{abbreviation = "перфоратора", replacement = "перфоратор"},
{abbreviation = "лома", replacement = "лом"},
{abbreviation = "топора", replacement = "топор"},
{abbreviation = "колуна", replacement = "колун"},
{abbreviation = "кувалда", replacement = "кувалду"},
{abbreviation = "зубила", replacement = "зубило"},
{abbreviation = "напильника", replacement = "напильник"},
{abbreviation = "наждачка", replacement = "наждачку"},
{abbreviation = "уровня", replacement = "уровень"},
{abbreviation = "отвеса", replacement = "отвес"},
{abbreviation = "угольника", replacement = "угольник"},
{abbreviation = "лестница", replacement = "лестницу"},
{abbreviation = "стремянка", replacement = "стремянку"},
{abbreviation = "тали", replacement = "таль"},
{abbreviation = "домкрата", replacement = "домкрат"},
{abbreviation = "тисков", replacement = "тиски"},
{abbreviation = "наковальня", replacement = "наковальню"},
{abbreviation = "горна", replacement = "горн"},
{abbreviation = "паяльника", replacement = "паяльник"},
{abbreviation = "тестер", replacement = "мультиметр"},
{abbreviation = "мультиметра", replacement = "мультиметр"},
{abbreviation = "гвоздей", replacement = "гвозди"},
{abbreviation = "шурупов", replacement = "шурупы"},
{abbreviation = "саморезов", replacement = "саморезы"},
{abbreviation = "болтов", replacement = "болты"},
{abbreviation = "гаек", replacement = "гайки"},
{abbreviation = "шайб", replacement = "шайбы"},
{abbreviation = "гровера", replacement = "гровер"},
{abbreviation = "анкера", replacement = "анкер"},
{abbreviation = "дюбеля", replacement = "дюбель"},
{abbreviation = "заклепка", replacement = "заклепку"},
{abbreviation = "проволока", replacement = "проволоку"},
{abbreviation = "веревка", replacement = "веревку"},
{abbreviation = "шнура", replacement = "шнур"},
{abbreviation = "троса", replacement = "трос"},
{abbreviation = "лента", replacement = "ленту"},
{abbreviation = "скотча", replacement = "скотч"},
{abbreviation = "изолента", replacement = "изоленту"},
{abbreviation = "герметика", replacement = "герметик"},
{abbreviation = "клея", replacement = "клей"},
{abbreviation = "цемента", replacement = "цемент"},
{abbreviation = "бетона", replacement = "бетон"},
{abbreviation = "кирпича", replacement = "кирпич"},
{abbreviation = "панели", replacement = "панель"},
{abbreviation = "гипса", replacement = "гипс"},
{abbreviation = "штукатурка", replacement = "штукатурку"},
{abbreviation = "шпатлевка", replacement = "шпатлевку"},
{abbreviation = "грунтовка", replacement = "грунтовку"},
{abbreviation = "краска", replacement = "краску"},
{abbreviation = "эмали", replacement = "эмаль"},
{abbreviation = "лака", replacement = "лак"},
{abbreviation = "морилка", replacement = "морилку"},
{abbreviation = "антисептика", replacement = "антисептик"},
{abbreviation = "пена", replacement = "монтажную пену"},
{abbreviation = "монтажная", replacement = "монтажную пену"},
{abbreviation = "монтажную", replacement = "монтажную пену"},
{abbreviation = "пену", replacement = "монтажную пену"},
{abbreviation = "утеплителя", replacement = "утеплитель"},
{abbreviation = "изоляция", replacement = "изоляцию"},
{abbreviation = "пленка", replacement = "пленку"},
{abbreviation = "рубероида", replacement = "рубероид"},
{abbreviation = "шифера", replacement = "шифер"},
{abbreviation = "черепица", replacement = "черепицу"},
{abbreviation = "металлочерепица", replacement = "металлочерепицу"},
{abbreviation = "сайдинга", replacement = "сайдинг"},
{abbreviation = "вагонка", replacement = "вагонку"},
{abbreviation = "доска", replacement = "доску"},
{abbreviation = "бруса", replacement = "брус"},
{abbreviation = "бревна", replacement = "бревно"},
{abbreviation = "фанера", replacement = "фанеру"},
{abbreviation = "дсп", replacement = "ДСП"},
{abbreviation = "двп", replacement = "ДВП"},
{abbreviation = "мдф", replacement = "МДФ"},
{abbreviation = "осб", replacement = "ОСБ"},
{abbreviation = "оргалита", replacement = "оргалит"},
{abbreviation = "стекла", replacement = "стекло"},
{abbreviation = "пластика", replacement = "пластик"},
{abbreviation = "металла", replacement = "металл"},
{abbreviation = "алюминия", replacement = "алюминий"},
{abbreviation = "меди", replacement = "медь"},
{abbreviation = "латуни", replacement = "латунь"},
{abbreviation = "бронза", replacement = "бронзу"},
{abbreviation = "чугуна", replacement = "чугун"},
{abbreviation = "стали", replacement = "сталь"},
{abbreviation = "железа", replacement = "железо"},
{abbreviation = "свинца", replacement = "свинец"},
{abbreviation = "оцинковка", replacement = "оцинковку"},
{abbreviation = "24/7", replacement = "магазин \"24/7\""},
{abbreviation = "24-7", replacement = "магазин \"24/7\""},
{abbreviation = "247", replacement = "магазин \"24/7\""},
{abbreviation = "круглосуточный", replacement = "магазин \"24/7\""},
{abbreviation = "круглосуточного", replacement = "магазин \"24/7\""},
{abbreviation = "кругосут", replacement = "магазин \"24/7\""},
{abbreviation = "св", replacement = "а/м марки \"Sultan\""},
{abbreviation = "закуп", replacement = "закупка"},
{abbreviation = "закупки", replacement = "закупка"},
{abbreviation = "скупки", replacement = "скупка"},
{abbreviation = "принимаю", replacement = "принимаю заказы"},
{abbreviation = "заказов", replacement = "заказы"},
{abbreviation = "рп", replacement = "RP"},
{abbreviation = "рпа", replacement = "RP"},
{abbreviation = "дрп", replacement = "DRP"},
{abbreviation = "арп", replacement = "ARP"},
{abbreviation = "адванс", replacement = "Advance RP"},
{abbreviation = "адванса", replacement = "Advance RP"},
{abbreviation = "пр", replacement = "PRO"},
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
{abbreviation = "школа вождения", replacement = "автошколу"},
{abbreviation = "страйкбол", replacement = "страйкбольный клуб"},
{abbreviation = "пейнтбол", replacement = "пейнтбольный клуб"},
{abbreviation = "квест", replacement = "квест-комнату"},
{abbreviation = "квесты", replacement = "квест-комнаты"},
{abbreviation = "квестов", replacement = "квест-комнаты"},
{abbreviation = "квестовая", replacement = "квест-комнату"},
{abbreviation = "апартаментов", replacement = "апартаменты"},
{abbreviation = "пентхауса", replacement = "пентхаус"},
{abbreviation = "лофта", replacement = "лофт"},
{abbreviation = "резиденция", replacement = "резиденцию"},
{abbreviation = "поместья", replacement = "поместье"},
{abbreviation = "усадьба", replacement = "усадьбу"},
{abbreviation = "дворца", replacement = "дворец"},
{abbreviation = "тазик", replacement = "а/м"},
{abbreviation = "тазика", replacement = "а/м"},
{abbreviation = "коробка", replacement = "а/м"},
{abbreviation = "коробку", replacement = "а/м"},
{abbreviation = "ведро", replacement = "а/м"},
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
{abbreviation = "рубля", replacement = "рублей"},
{abbreviation = "баксов", replacement = "$"},
{abbreviation = "бакса", replacement = "$"},
{abbreviation = "зеленых", replacement = "$"},
{abbreviation = "тугриков", replacement = "$"},
{abbreviation = "монет", replacement = "$"},
{abbreviation = "кредитов", replacement = "$"},
{abbreviation = "бюджета", replacement = "бюджет"},
{abbreviation = "суммы", replacement = "сумма"},
{abbreviation = "стоимости", replacement = "стоимость"},
{abbreviation = "прайса", replacement = "прайс"},
{abbreviation = "расценок", replacement = "расценки"},
{abbreviation = "тарифа", replacement = "тариф"},
{abbreviation = "тарифов", replacement = "тарифы"},
{abbreviation = "розницу", replacement = "в розницу"},
{abbreviation = "наличии", replacement = "в наличии"},
{abbreviation = "предзаказа", replacement = "предзаказ"},
{abbreviation = "резерва", replacement = "резерв"},
{abbreviation = "брони", replacement = "бронь"},
{abbreviation = "надела", replacement = "надел"},
{abbreviation = "паевой", replacement = "паевой взнос"},
{abbreviation = "пая", replacement = "пай"},
{abbreviation = "доля", replacement = "долю"},
{abbreviation = "доли", replacement = "долю"},
{abbreviation = "части", replacement = "часть"},
{abbreviation = "акция", replacement = "акцию"},
{abbreviation = "акции", replacement = "акцию"},
{abbreviation = "акций", replacement = "акции"},
{abbreviation = "дивидендов", replacement = "дивиденды"},
{abbreviation = "франшиза", replacement = "франшизу"},
{abbreviation = "франшизы", replacement = "франшизу"},
{abbreviation = "разрешения", replacement = "разрешение"},
{abbreviation = "патента", replacement = "патент"},
{abbreviation = "свидетельства", replacement = "свидетельство"},
{abbreviation = "контракта", replacement = "контракт"},
{abbreviation = "аренда", replacement = "аренду"},
{abbreviation = "аренды", replacement = "аренду"},
{abbreviation = "распродажи", replacement = "распродажа"},
{abbreviation = "ликвидации", replacement = "ликвидация"},
{abbreviation = "закрытия", replacement = "закрытие"},
{abbreviation = "переезда", replacement = "переезд"},
{abbreviation = "фт", replacement = "FT"},
-- Бизнесы
{abbreviation = "магазин оружия", replacement = "оружейный магазин"},
{abbreviation = "париках", replacement = "салон красоты"},
{abbreviation = "парикам", replacement = "салон красоты"},
{abbreviation = "парикахма", replacement = "салон красоты"},
{abbreviation = "парикахмерская", replacement = "салон красоты"},
{abbreviation = "бургер", replacement = "Burger Shot"},
{abbreviation = "клаш", replacement = "Clucking Bell"},
{abbreviation = "клакинг", replacement = "Clucking Bell"},
{abbreviation = "тюнинг", replacement = "тюнинг-центр"},
{abbreviation = "тюнинг центр", replacement = "тюнинг-центр"},
{abbreviation = "секс шоп", replacement = "секс-шоп"},
{abbreviation = "пиротехника", replacement = "магазин пиротехники"},
{abbreviation = "пиро", replacement = "магазин пиротехники"},
{abbreviation = "развлекательный", replacement = "развлекательный центр"},
{abbreviation = "развлекатель", replacement = "развлекательный центр"},
{abbreviation = "риелтор", replacement = "риелторское агентство"},
{abbreviation = "риелторское", replacement = "риелторское агентство"},
{abbreviation = "риелторск", replacement = "риелторское агентство"},
{abbreviation = "статистики", replacement = "управление статистики"},
{abbreviation = "мебель", replacement = "мебельный салон"},
{abbreviation = "мебельный", replacement = "мебельный салон"},
{abbreviation = "сантехника", replacement = "салон сантехники"},
{abbreviation = "сантех", replacement = "салон сантехники"},
{abbreviation = "стройматериалы", replacement = "магазин стройматериалов"},
{abbreviation = "строймат", replacement = "магазин стройматериалов"},
{abbreviation = "аренда авто", replacement = "аренда эксклюзивных авто"},
{abbreviation = "хранение тс", replacement = "хранение транспорта"},
{abbreviation = "хранение акс", replacement = "хранение аксессуаров"},
-- Государственные организации
{abbreviation = "мерии", replacement = "мэрия"},
{abbreviation = "администрация", replacement = "администрация президента"},
{abbreviation = "президента", replacement = "администрация президента"},
{abbreviation = "болница", replacement = "больница"},
-- Банды и мафии
{abbreviation = "балас", replacement = "Ballas"},
{abbreviation = "баллас", replacement = "Ballas"},
{abbreviation = "гров", replacement = "Grove Street"},
{abbreviation = "гроув", replacement = "Grove Street"},
{abbreviation = "азтек", replacement = "Aztecas"},
{abbreviation = "азтекс", replacement = "Aztecas"},
{abbreviation = "вагос", replacement = "Vagos"},
{abbreviation = "вагоз", replacement = "Vagos"},
{abbreviation = "рус маф", replacement = "русская мафия"},
{abbreviation = "лакоста", replacement = "La Cosa Nostra"},
{abbreviation = "ла коста", replacement = "La Cosa Nostra"},
{abbreviation = "лакоста ностра", replacement = "La Cosa Nostra"},
{abbreviation = "якудза", replacement = "Yakuza"},
{abbreviation = "якуца", replacement = "Yakuza"},
{abbreviation = "якудзы", replacement = "Yakuza"},
-- Правоохранительные органы
{abbreviation = "лвпд", replacement = "LVPD"},
{abbreviation = "lspd", replacement = "LSPD"},
{abbreviation = "sfpd", replacement = "SFPD"},
-- Армия
{abbreviation = "ввс", replacement = "ВВС"},
{abbreviation = "вмф", replacement = "ВМФ"},
-- Дополнения Advance RP
{abbreviation = "дог", replacement = "договорная"},
}

local default_mm_rules = {}
for _ri, _rr in ipairs(mm_rules) do
    default_mm_rules[_ri] = {abbreviation = _rr.abbreviation, replacement = _rr.replacement}
end

-- Переменные для модуля "Авто-отыгровки (Auto-RP)"
rp_weapons_enabled = imgui.new.bool(true)
rp_phone_enabled = imgui.new.bool(true)
rp_mask_enabled = imgui.new.bool(true)
rp_heal_enabled = imgui.new.bool(true)
rp_engine_enabled = imgui.new.bool(true)
rp_docs_enabled = imgui.new.bool(true)
rp_gender = imgui.new.int(0) -- 0 = Мужской, 1 = Женский
rp_current_weapon_id = 0
rp_sending_internal = false
rp_event_cooldowns = {}
aad_next_scheduled = false

local function rpVerb(male, female)
    return rp_gender[0] == 1 and female or male
end

weapon_info = {
    [1]  = { name = "кастет",                 kind = "pocket" },
    [2]  = { name = "клюшку",                 kind = "back" },
    [3]  = { name = "дубинку",                kind = "belt" },
    [4]  = { name = "нож",                    kind = "sheath" },
    [5]  = { name = "биту",                   kind = "back" },
    [6]  = { name = "лопату",                 kind = "back" },
    [7]  = { name = "кий",                    kind = "back" },
    [8]  = { name = "катану",                 kind = "back" },
    [9]  = { name = "бензопилу",              kind = "back" },
    [22] = { name = "Colt 45",                kind = "pistol" },
    [23] = { name = "пистолет с глушителем",  kind = "pistol" },
    [24] = { name = "Desert Eagle",           kind = "pistol" },
    [25] = { name = "Shotgun",                kind = "shotgun" },
    [26] = { name = "Sawn-off Shotgun",       kind = "shotgun" },
    [27] = { name = "Combat Shotgun",         kind = "shotgun" },
    [28] = { name = "Micro Uzi",              kind = "smg" },
    [29] = { name = "MP5",                    kind = "smg" },
    [30] = { name = 'автомат "AK-47"',        kind = "rifle" },
    [31] = { name = 'автомат "M4"',           kind = "rifle" },
    [32] = { name = "Tec-9",                  kind = "smg" },
    [33] = { name = "винтовку",               kind = "rifle" },
    [34] = { name = "снайперскую винтовку",   kind = "rifle" },
    [41] = { name = "баллончик с краской",    kind = "pocket" },
    [42] = { name = "огнетушитель",           kind = "back" },
    [43] = { name = "фотоаппарат",            kind = "neck" },
}

-- Переменные для модуля "Транспорт и Визуал (Vehicles & Visuals)"
strobe_enabled = imgui.new.bool(false)
strobe_speed = imgui.new.int(150)
strobe_mode = imgui.new.int(0)
strobe_active = false
strobe_worker_running = false
cruise_enabled = imgui.new.bool(false)
turbo_cruise_enabled = imgui.new.bool(false)
turbo_boost_mode = imgui.new.int(0) -- 0=Alt+W, 1=Shift+W, 2=Круиз C/W/S
turbo_power = imgui.new.int(3)      -- 1..8
turbo_max_speed = imgui.new.int(55) -- 25..90 (GTA ед.)
turbo_turn_assist = imgui.new.bool(true)
sport_boost_active = false
cruise_active = false
find_ui_enabled = imgui.new.bool(true)
find_wait_until = 0

-- Горячие клавиши на команды
-- key: VK код клавиши, command: команда, name: описание
keybinds = {
    {key = 0x4C, command = "/lock",   enabled = true,  name = "Закрыть/открыть машину"},
    {key = 0x4B, command = "/e",     enabled = true,  name = "Завести/заглушить двигатель"},
}
-- VK коды для справки: 0x4C=L, 0x4B=K, 0x4A=J, 0x4D=M, 0x4E=N, 0x50=P, 0x52=R, 0x54=T
key_names = {
    [0x41] = "A", [0x42] = "B", [0x43] = "C", [0x44] = "D", [0x45] = "E",
    [0x46] = "F", [0x47] = "G", [0x48] = "H", [0x49] = "I", [0x4A] = "J",
    [0x4B] = "K", [0x4C] = "L", [0x4D] = "M", [0x4E] = "N", [0x4F] = "O",
    [0x50] = "P", [0x51] = "Q", [0x52] = "R", [0x53] = "S", [0x54] = "T",
    [0x55] = "U", [0x56] = "V", [0x57] = "W", [0x58] = "X", [0x59] = "Y",
    [0x5A] = "Z",
    [0x30] = "0", [0x31] = "1", [0x32] = "2", [0x33] = "3", [0x34] = "4",
    [0x35] = "5", [0x36] = "6", [0x37] = "7", [0x38] = "8", [0x39] = "9",
    [0x60] = "Num 0", [0x61] = "Num 1", [0x62] = "Num 2", [0x63] = "Num 3",
    [0x64] = "Num 4", [0x65] = "Num 5", [0x66] = "Num 6", [0x67] = "Num 7",
    [0x68] = "Num 8", [0x69] = "Num 9",
    [0x71] = "F2", [0x72] = "F3", [0x73] = "F4", [0x74] = "F5", [0x75] = "F6",
    [0x76] = "F7", [0x77] = "F8", [0x78] = "F9", [0x79] = "F10",
    [0x2D] = "Insert", [0x2E] = "Delete", [0x24] = "Home", [0x23] = "End",
    [0x21] = "PgUp", [0x22] = "PgDn", [0x20] = "Space", [0x0D] = "Enter",
}
bind_mod_names = { [0] = "", [1] = "Alt+", [2] = "Ctrl+", [3] = "Shift+" }
new_bind_key = imgui.new.int(0x4C)
new_bind_mod = imgui.new.int(0)
new_bind_type = imgui.new.int(0) -- 0 = Команда, 1 = РП-отыгровка
new_bind_rp_chapter = imgui.new.int(0)
new_bind_rp_idx = imgui.new.int(0)
new_bind_command = imgui.new.char[129]("")
new_bind_name = imgui.new.char[129]("")

-- Исправление раскладки в чате (EN <-> RU)
layout_fix_enabled = imgui.new.bool(true)
layout_fix_key = imgui.new.int(0x71) -- F2
layout_fix_keys = {
    { vk = 0x71, label = "F2" },
    { vk = 0x72, label = "F3" },
    { vk = 0x73, label = "F4" },
    { vk = 0x13, label = "Pause" },
    { vk = 0x2D, label = "Insert" },
}

-- Авто-тег рации (/r, /f, /d)
radio_tag_text = imgui.new.char[33]("")
radio_tag_r = imgui.new.bool(false)
radio_tag_f = imgui.new.bool(false)
radio_tag_d = imgui.new.bool(false)
radio_auto_punct = imgui.new.bool(false)

-- Фильтр чата / анти-спам
chat_filter_enabled = imgui.new.bool(false)
cf_hide_ads = imgui.new.bool(false)
cf_hide_efir = imgui.new.bool(false)
cf_hide_system = imgui.new.bool(false)
cf_ad_whitelist_buf = imgui.new.char[257]("")
cf_blacklist_buf = imgui.new.char[257]("")
cf_trigger_buf = imgui.new.char[257]("")
cf_hidden_count = 0
cf_last_trigger_sound = 0

-- Авто-перенос длинных строк
line_wrap_enabled = imgui.new.bool(true)
line_wrap_limit = imgui.new.int(108)
line_wrap_delay = imgui.new.int(650)

-- Флаг быстрого реконнекта
reconnect_pending = false
-- Phase 2 (v2.2): Быстрое меню СКМ, меню по прицелу ПКМ + X/R/E, авто-стробы при сирене
P2 = P2 or {
    siren_was_on = false,
    siren_started_strobe = false,
    wheel_menu_need_pos = false,
    wheel_fav_ch = imgui.new.int(0),
    wheel_fav_idx = imgui.new.int(0),
    wheel_fav_editor = imgui.new.bool(false),
}
wheel_menu_enabled = imgui.new.bool(true)
wheel_menu_show = imgui.new.bool(false)
wheel_menu_pos = { x = 0, y = 0 }
wheel_menu_key_idx = imgui.new.int(0) -- 0=СКМ (0x04), 1=G (0x47), 2=B (0x42), 3=Z (0x5A), 4=V (0x56)
wheel_fav_slots = {} -- до 6 избранных отыгровок { chapter = 1..3, index = 1..N }
target_menu_key_idx = imgui.new.int(0) -- 0=X (0x58), 1=R (0x52), 2=E (0x45)
target_menu_autorp = imgui.new.bool(true)
siren_auto_strobe = imgui.new.bool(false)
P3 = P3 or {}
P3.gnews_status = ""
P3.lect_status = ""
P3.lect_thread = nil
P3.lect_loaded_ref = nil
P3.lecturer_loaded = false

gnews_sched_time_buf = imgui.new.char[17]("18:30:00")
gnews_sched_active = false
gnews_sched_target_ts = nil
gnews_sched_target_str = ""
gnews_sched_warned_15 = false
gnews_l_template_buf = imgui.new.char[129](u8"[%s] Занимаю волну гос. новостей на %s.")
gnews_sched_hud_str = ""

P3_lecturer_path = getWorkingDirectory() .. "/config/helper_lecturer.json"
P3_default_lecturer_templates = {
    {
        name = "Собеседование в гос. орг.",
        text = "Здравствуйте, вы на собеседование? Представьтесь, пожалуйста.\n<0>\nПокажите ваш паспорт, мед. карту и пакет лицензий.\n/me протянул руку и взял документы у гражданина напротив\n<0>\n/me внимательно проверил документы и вернул их владельцу\nСколько лет вы проживаете в штате и где работали ранее?\n<0>\nХорошо, вы нам подходите. Ожидайте оформления формы и рации."
    },
    {
        name = "Вступительная лекция",
        text = "Приветствую новых сотрудников! Прослушайте вводную лекцию.\nРабочий день начинается строго по графику вашей организации.\nВ рабочее время запрещено покидать пост или офис без разрешения.\nСоблюдайте субординацию, устав и выполняйте приказы руководства.\nСон (AFK) разрешён только в комнате отдыха или ординаторской.\nПо всем вопросам обращайтесь к старшему составу или в рацию.\nСпасибо за внимание, желаю успешной службы и карьерного роста!"
    },
    {
        name = "Правила рации (/r и /f)",
        text = "Сейчас я напомню правила пользования служебной рацией.\nЛокальная рация (/r) служит для докладов и связи внутри филиала.\nОбщая волна (/f) используется только с тегом подразделения.\nВ рации запрещены: мат, оскорбления, флуд и продажа имущества.\nВся внеигровая информация (OOC) пишется строго в двойных скобках (( )).\nЗа нарушение правил рации выдаётся выговор или увольнение."
    },
    {
        name = "Правило Миранды (МВД)",
        text = "Вы задержаны! Вы имеете полное право хранить молчание.\nВсё, что вы скажете, может и будет использовано против вас в суде.\nВаш адвокат может присутствовать при допросе.\nЕсли вы не можете оплатить адвоката, его предоставит государство.\nВы понимаете свои права?"
    },
    {
        name = "Правила ПРО и эфира (СМИ)",
        text = "Напоминаю сотрудникам СМИ правила редактирования объявлений (ПРО).\nУказывайте тег города (LS/SF/LV), корректные названия авто и цены.\nЗапрещено допускать сокращения вроде «булка» или «кк» в готовом тексте.\nПеред началом эфира (/t) проверяйте аппаратуру и занимайте волну.\nВ эфире соблюдайте грамотность и уважительное обращение к слушателям."
    },
    {
        name = "Инструктаж интернов (МЗ)",
        text = "Добро пожаловать в Министерство Здравоохранения, коллеги!\nОказание помощи пациентам проводится строго с РП-отыгровкой и по ЕЦП.\nВыдача лекарств в палате оформляется через /medhelp, в карете — /heal.\nУважайте каждого пациента и не отказывайте в лечении без причины.\nСоблюдайте чистоту в палатах и держите спецтранспорт заправленным."
    },
    {
        name = "Инструктаж новобранцев (МО)",
        text = "Здравия желаю, бойцы! Прослушайте инструктаж для новобранцев.\nВаша главная задача — охрана территории базы и КПП, доклады в /r.\nОткрывать огонь без предупреждения разрешено только при нападении.\nЗапрещено брать боеприпасы и технику базы без приказа офицера.\nОбращайтесь к старшим по званию строго по уставу: «Товарищ ...»."
    },
}
P3_lecturer_templates = {}
for idx, tpl in ipairs(P3_default_lecturer_templates) do
    P3_lecturer_templates[idx] = { name = tpl.name, text = tpl.text }
end
lect_selected = 1
lect_delay_ms = imgui.new.int(2000)
lect_running = false
lect_paused = false
lect_step = 0
lect_total = 0
lect_name_buf = imgui.new.char[65]("")
lect_text_buf = imgui.new.char[4097]("")
lect_loaded_idx = -1
P4 = P4 or {}
P4_codex_path = getWorkingDirectory() .. "/config/helper_codex.json"
P4_server_names = { [0] = "Blue", [1] = "Red", [2] = "Green", [3] = "Chocolate" }
P4_ecp_cmds = { [0] = "medhelp", [1] = "heal", [2] = "medcard", [3] = "analysis" }

function P4_buildDefaultCodex(server_idx)
    local sidx = tonumber(server_idx) or 0
    if sidx < 0 or sidx > 3 then sidx = 0 end
    sidx = math.floor(sidx)
    local srv_name = P4_server_names[sidx] or "Blue"

    local p_medhelp = 500
    local p_heal = 500
    local p_heal_gov = 300
    local p_mc1 = 1500
    local p_mc2 = 2500
    local p_mc3 = 3500
    local p_analys = 1000
    if sidx == 1 then
        p_mc1, p_mc2, p_mc3 = 2000, 3000, 4000
    elseif sidx == 2 then
        p_heal = 600
    elseif sidx == 3 then
        p_medhelp, p_heal_gov = 400, 250
        p_mc2, p_mc3, p_analys = 2000, 3000, 800
    end

    return {
        server_idx = sidx,
        server_name = srv_name,
        uk = {
            { code = "1.1",  title = "Нападение на гражданское лицо",                stars = 2, rp = "/me открыл бортовой компьютер и объявил гражданина в розыск по ст. 1.1 УК" },
            { code = "1.2",  title = "Вооружённое нападение на гражданское лицо",    stars = 4, rp = "/me передал приметы вооружённого нападавшего диспетчеру по рации" },
            { code = "2.1",  title = "Нападение на сотрудника МВД / ФБР",            stars = 4, rp = "/me доложил в рацию о нападении на сотрудника и внёс в базу розыска" },
            { code = "2.2",  title = "Вооружённое нападение на гос. сотрудника",    stars = 6, rp = "/me активировал тревожный сигнал и передал данные стрелка в розыск" },
            { code = "3.1",  title = "Угон транспортного средства",                  stars = 2, rp = "/me зафиксировал угон транспорта и передал ориентировку патрулям" },
            { code = "3.2",  title = "Повреждение имущества и вандализм",           stars = 1, rp = "/me оформил запись в бортовом компьютере о порче имущества" },
            { code = "4.1",  title = "Незаконное ношение и хранение оружия",        stars = 3, rp = "/me внёс данные о нелегальном оружии в базу розыска МВД" },
            { code = "4.2",  title = "Незаконная продажа и сбыт оружия",            stars = 4, rp = "/me передал в рацию ориентировку за нелегальный сбыт оружия" },
            { code = "5.1",  title = "Хранение наркотических веществ",              stars = 3, rp = "/me зафиксировал хранение запрещённых веществ и объявил в розыск" },
            { code = "5.2",  title = "Сбыт или перевозка наркотических веществ",    stars = 5, rp = "/me передал данные о распространении наркотиков в федеральный розыск" },
            { code = "6.1",  title = "Неподчинение законному требованию МВД",       stars = 2, rp = "/me передал по рации информацию о неподчинении гражданина" },
            { code = "6.2",  title = "Попытка скрыться от преследования (побег)",   stars = 3, rp = "/me передал ориентировку на скрывающегося нарушителя всем постам" },
            { code = "7.1",  title = "Дача или попытка дачи взятки",                stars = 3, rp = "/me зафиксировал попытку подкупа должностного лица и внёс в базу" },
            { code = "8.1",  title = "Хулиганство и нарушение общественного порядка",stars = 1, rp = "/me оформил розыск за нарушение общественного порядка" },
            { code = "8.2",  title = "Оскорбление сотрудника правоохранительных органов", stars = 2, rp = "/me зафиксировал оскорбление при исполнении и внёс в базу МВД" },
            { code = "9.1",  title = "Проникновение на охраняемую территорию",       stars = 3, rp = "/me доложил о проникновении на закрытый объект и выдал розыск" },
            { code = "10.1", title = "Похищение человека или захват заложников",    stars = 6, rp = "/me объявил код перехвата по факту похищения и внёс в розыск" },
            { code = "11.1", title = "Теракт и угроза общественной безопасности",   stars = 6, rp = "/me передал экстренную ориентировку по факту угрозы теракта" },
            { code = "12.1", title = "Ложный вызов экстренных служб",               stars = 2, rp = "/me зафиксировал ложный вызов в диспетчерской базе данных" },
            { code = "13.1", title = "Угроза убийством или тяжким вредом",          stars = 3, rp = "/me внёс в базу розыска гражданина за угрозу жизни" },
        },
        ak = {
            { code = "1.1", title = "Превышение установленной скорости",            fine = 1500, rp = "/me заполнил бланк штрафа за превышение скорости и передал водителю" },
            { code = "1.2", title = "Выезд на полосу встречного движения",         fine = 2000, rp = "/me выписал постановление о штрафе за выезд на встречную полосу" },
            { code = "1.3", title = "Парковка в неположенном месте",                fine = 1000, rp = "/me оформил штрафную квитанцию за нарушение правил парковки" },
            { code = "1.4", title = "Проезд на запрещающий сигнал светофора",      fine = 1500, rp = "/me заполнил квитанцию о нарушении сигнала светофора" },
            { code = "1.5", title = "Движение без включённых фар ночью",           fine = 1000, rp = "/me выписал штраф за движение без ближнего света фар" },
            { code = "2.1", title = "Вождение в состоянии опьянения",               fine = 3000, rp = "/me оформил протокол и выписал штраф за нетрезвое вождение" },
            { code = "2.2", title = "Создание ДТП и аварийной ситуации",          fine = 2500, rp = "/me составил протокол ДТП и вручил водителю штрафную квитанцию" },
            { code = "3.1", title = "Мелкое хулиганство в общественном месте",      fine = 1000, rp = "/me оформил административный штраф за мелкое хулиганство" },
            { code = "3.2", title = "Переход проезжей части в неположенном месте", fine = 500,  rp = "/me выписал предупредительный штраф пешеходу за нарушение ПДД" },
            { code = "4.1", title = "Отказ от предъявления документов",           fine = 2000, rp = "/me оформил административный протокол за отказ предъявить документы" },
        },
        ecp = {
            { name = "Обычное лечение (/medhelp)",           cmd = "medhelp",  med_type = 0, price = p_medhelp,  rp = "/me осмотрел пациента и назначил курс лечения" },
            { name = "Лечение в карете скорой (/heal)",      cmd = "heal",     med_type = 0, price = p_heal,     rp = "/me открыл медицинский саквояж и оказал первую помощь" },
            { name = "Льготное лечение гос./новичков (/heal)",cmd = "heal",     med_type = 0, price = p_heal_gov, rp = "/me подготовил препараты и оформил льготное лечение" },
            { name = "Медкарта Тип 1 — Годен",               cmd = "medcard",  med_type = 1, price = p_mc1,      rp = "/me заполнил бланк медицинской карты 1-го типа и поставил печать" },
            { name = "Медкарта Тип 2 — Наблюдение",          cmd = "medcard",  med_type = 2, price = p_mc2,      rp = "/me оформил медицинскую карту 2-го типа с отметкой врача" },
            { name = "Медкарта Тип 3 — Ограничения",         cmd = "medcard",  med_type = 3, price = p_mc3,      rp = "/me выдал медицинскую карту 3-го типа с результатами комиссии" },
            { name = "Осмотр и анализы (/analysis)",         cmd = "analysis", med_type = 0, price = p_analys,   rp = "/me взял пробы для лабораторного анализа и занёс данные в карту" },
        },
    }
end

P4_codex = P4_buildDefaultCodex(0)

P4_megaphone_lines = {
    "Водитель, прижмитесь к обочине и заглушите двигатель! Работает полиция!",
    "Немедленно остановите транспортное средство и оставайтесь в машине!",
    "Повторяю: остановитесь у обочины, иначе мы будем вынуждены открыть огонь!",
    "Гражданин, оставайтесь на месте! Любое сопротивление усугубит ваше положение!",
}

P4_weapon_names = {
    [0]  = "Кулак",
    [1]  = "Кастет",
    [2]  = "Клюшка",
    [3]  = "Дубинка",
    [4]  = "Нож",
    [5]  = "Бита",
    [6]  = "Лопата",
    [7]  = "Кий",
    [8]  = "Катана",
    [9]  = "Бензопила",
    [14] = "Букет",
    [15] = "Трость",
    [16] = "Граната",
    [17] = "Слезоточивый газ",
    [18] = "Молотов",
    [22] = "Colt 45",
    [23] = "SD Pistol",
    [24] = "Desert Eagle",
    [25] = "Shotgun",
    [26] = "Sawn-off",
    [27] = "Combat Shotgun",
    [28] = "Micro Uzi",
    [29] = "MP5",
    [30] = "AK-47",
    [31] = "M4",
    [32] = "Tec-9",
    [33] = "Rifle",
    [34] = "Sniper Rifle",
    [35] = "RPG",
    [36] = "HS Rocket",
    [37] = "Огнемёт",
    [38] = "Minigun",
    [39] = "Взрывпакет",
    [41] = "Баллончик",
    [42] = "Огнетушитель",
    [43] = "Фотоаппарат",
    [46] = "Парашют",
    [49] = "Транспорт (ДБ)",
    [50] = "Лопасти",
    [51] = "Взрыв",
    [53] = "Вода",
    [54] = "Падение/Удар",
}

P4_bodypart_names = {
    [3] = "Торс",
    [4] = "Пах",
    [5] = "Л.рука",
    [6] = "П.рука",
    [7] = "Л.нога",
    [8] = "П.нога",
    [9] = "Голова",
}

suw_show = imgui.new.bool(false)
suw_target_id = imgui.new.int(0)
suw_search_buf = imgui.new.char[65]("")
suw_custom_stars = imgui.new.int(2)
suw_custom_reason = imgui.new.char[129]("")
suw_tab = 1
suw_use_rp = imgui.new.bool(true)

medui_show = imgui.new.bool(false)
medui_target_id = imgui.new.int(0)
medui_use_rp = imgui.new.bool(true)

p4_ui_page = 1
p4_autorp_enabled = imgui.new.bool(true)

dmg_enabled = imgui.new.bool(false)
dmg_show_hud = imgui.new.bool(true)
dmg_log = {}
dmg_last_hud = ""
dmg_last_ts = 0
dmg_log_show = imgui.new.bool(false)

p4_codex_server = imgui.new.int(0)
p4_uk_edit_idx = 0
p4_uk_code_buf = imgui.new.char[17]("")
p4_uk_title_buf = imgui.new.char[257]("")
p4_uk_stars = imgui.new.int(2)
p4_uk_rp_buf = imgui.new.char[385]("")

p4_ak_edit_idx = 0
p4_ak_code_buf = imgui.new.char[17]("")
p4_ak_title_buf = imgui.new.char[257]("")
p4_ak_fine = imgui.new.int(1500)
p4_ak_rp_buf = imgui.new.char[385]("")

p4_ecp_edit_idx = 0
p4_ecp_name_buf = imgui.new.char[65]("")
p4_ecp_cmd_idx = imgui.new.int(0)
p4_ecp_med_type = imgui.new.int(1)
p4_ecp_price = imgui.new.int(500)
p4_ecp_rp_buf = imgui.new.char[385]("")
p4_status_msg = ""
P5 = P5 or {}
P5.last_cam_clock = 0
P5.had_input_in_sec = false
P5.buyfast_items = {
    { label = "Аптечка", keywords = { "аптеч" }, aliases = { "аптеч", "heal", "med" } },
    { label = "Маска", keywords = { "маск" }, aliases = { "маск", "mask" } },
    { label = "Ремкомплект", keywords = { "ремкомпл", "рем.компл", "рем-компл", "рем. компл" }, aliases = { "рем", "repair" } },
    { label = "Канистра", keywords = { "канистр" }, aliases = { "канистр", "fuel" } },
    { label = "Телефон / Сим", keywords = { "телефон", "сим-карт", "сим карт", "симка", "sim-card", "sim card" }, aliases = { "телеф", "сим", "sim" } }
}

-- Дрон / Свободная камера (/cam) — строго выключена по умолчанию
cam_feature_enabled = imgui.new.bool(false)
cam_active = false
cam_speed = imgui.new.float(0.6)
cam_x = 0
cam_y = 0
cam_z = 0
cam_yaw = 0
cam_pitch = 0
cam_controls_locked = false

-- Полуавтоматическая быстрая покупка в 24/7 и Аптеке (/buyfast) — выключена по умолчанию
buyfast_enabled = imgui.new.bool(false)
buyfast_item_idx = imgui.new.int(0)
buyfast_armed_until = 0
buyfast_last_fire = 0

-- Опциональный трекер активного онлайна и AFK в /hud — выключен по умолчанию
session_track_enabled = imgui.new.bool(false)
session_active_sec = 0
session_afk_sec = 0
session_last_px = nil
session_last_py = nil
session_idle_sec = 0
session_hud_str = ""
-- Фаза 6 (v2.6): Конструктор локаций /location (бесплатный аналог TitanLocation)
P6 = P6 or {}
P6_loc_path = getWorkingDirectory() .. "/config/helper_locations.json"
P6_decor_cats = {
    "Сцены / Стойки / Металл",
    "Ограждения / Заборы / Знаки",
    "Мебель / Интерьер",
    "Свет / Техника / Эффекты",
    "Улица / Природа / Декор",
    "Стены / Блоки / Конструкции",
    "Разное"
}
P6_decor_catalog = {
    { id = 11544, cat = 1, name = "Пожарная металл. лестница (des_ntfrescape2)" },
    { id = 1231, cat = 4, name = "Двойной уличный фонарь (Streetlamp2)" },
    { id = 1234, cat = 2, name = "Дорожный знак телефона (phonesign)" },
    { id = 1238, cat = 2, name = "Дорожный конус (trafficcone)" },
    { id = 1258, cat = 5, name = "Почтовый ящик металлический (Mpostbox1)" },
    { id = 1262, cat = 2, name = "Светофор уличный (MTraffic4)" },
    { id = 1280, cat = 3, name = "Парковая скамейка (parkbench1)" },
    { id = 1331, cat = 5, name = "Уличная мусорка бетонная (BinNt01_LA)" },
    { id = 1347, cat = 5, name = "Урна уличная круглая (CJ_WASTEBIN)" },
    { id = 1360, cat = 5, name = "Куст декоративный в горшке (CJ_BUSH_PROP3)" },
    { id = 1363, cat = 5, name = "Телефонный киоск уличный (CJ_PHONE_KIOSK)" },
    { id = 1421, cat = 7, name = "Стопка картонных коробок (DYN_BOXES)" },
    { id = 1426, cat = 1, name = "Строительные леса металл. (DYN_SCAFFOLD)" },
    { id = 1450, cat = 7, name = "Деревянный ящик грузовой (DYN_CRATE_3)" },
    { id = 1454, cat = 5, name = "Тюк сена декоративный (DYN_H_BALE2)" },
    { id = 14780, cat = 1, name = "Боксёрский ринг / стойки (in_bxing04)" },
    { id = 1481, cat = 5, name = "Мангал / барбекю-гриль (DYN_BAR_B_Q)" },
    { id = 1518, cat = 4, name = "Телевизор ретро на тумбе (DYN_TV_2)" },
    { id = 1568, cat = 4, name = "Китайский уличный фонарь (chinalamp_sf)" },
    { id = 1597, cat = 7, name = "Аварийный спасательный плот (cntrlrsac1)" },
    { id = 1607, cat = 5, name = "Дельфин (фигура) (dolphin)" },
    { id = 1608, cat = 5, name = "Акула (фигура) (shark)" },
    { id = 1609, cat = 5, name = "Черепаха (фигура) (turtle)" },
    { id = 16092, cat = 1, name = "Металлическая ферма / опора труб (des_pipestrut05)" },
    { id = 16342, cat = 4, name = "Генераторная турбина ГЭС (dam_genturbine04)" },
    { id = 16442, cat = 6, name = "Светящиеся полосы / вывеска (desn2_stripsigs1)" },
    { id = 1646, cat = 5, name = "Пляжное полотенце свёрнутое (lounge_towel_up)" },
    { id = 1712, cat = 3, name = "Диван светлый офисный (kb_couch05)" },
    { id = 1723, cat = 3, name = "Секция сидений для зала 1 (mrk_seating1)" },
    { id = 1724, cat = 3, name = "Секция сидений для зала 2 (mrk_seating1b)" },
    { id = 1736, cat = 5, name = "Голова оленя на стену (CJ_Stags_head)" },
    { id = 18275, cat = 1, name = "Финишная арка велогонки (cw2_mtbfinish)" },
    { id = 1829, cat = 3, name = "Металлический сейф открытый (man_safenew)" },
    { id = 1840, cat = 1, name = "Напольная колонка (динамик) (speaker_2)" },
    { id = 1946, cat = 1, name = "Баскетбольный мяч (baskt_ball_hi)" },
    { id = 19569, cat = 7, name = "Пакет молока (коробка) (MilkCarton1)" },
    { id = 19637, cat = 7, name = "Ящик зелёных яблок (GreenApplesCrate1)" },
    { id = 19638, cat = 7, name = "Ящик апельсинов (OrangesCrate1)" },
    { id = 19878, cat = 1, name = "Скейтборд (Skateboard1)" },
    { id = 1997, cat = 7, name = "Больничная тележка с подносом (hos_trolley)" },
    { id = 2096, cat = 3, name = "Кресло-качалка классическое (CJ_RockingChair)" },
    { id = 2146, cat = 7, name = "Стойка-тележка для багажа (CJ_TROLLY1)" },
    { id = 2164, cat = 3, name = "Медицинский шкаф офисный (MED_OFFICE_UNIT_5)" },
    { id = 2165, cat = 3, name = "Медицинский рабочий стол (MED_OFFICE_DESK_1)" },
    { id = 2222, cat = 6, name = "Ржавая металлическая балка (rustyhigh)" },
    { id = 2342, cat = 3, name = "Витрина с пончиками (donut_disp)" },
    { id = 2357, cat = 3, name = "Обеденный стол сервированный (DUNC_DINNING)" },
    { id = 2405, cat = 5, name = "Доска для сёрфинга (CJ_SURF_BOARD2)" },
    { id = 2510, cat = 7, name = "Модель самолёта большая 2 (MODEL_PLANE_BIG2)" },
    { id = 2630, cat = 1, name = "Велотренажёр для зала (gym_bike)" },
    { id = 2755, cat = 6, name = "Стена додзё деревянная (Dojo_Wall)" },
    { id = 2773, cat = 1, name = "Барная стойка аэропорта (CJ_AIRPRT_BAR)" },
    { id = 2840, cat = 7, name = "Упаковка еды на вынос (GB_takeaway05)" },
    { id = 2918, cat = 7, name = "Морская мина (kmb_mine)" },
    { id = 2993, cat = 1, name = "Флажок финиша / старта (kmb_goflag)" },
    { id = 3031, cat = 4, name = "Спутниковая антенна большая (wong_dish)" },
    { id = 3350, cat = 1, name = "Студийный микрофон на стойке (torino_mic)" },
    { id = 3441, cat = 1, name = "Декоративная колонна Luxor (luxorpillar02_lvs)" },
    { id = 3533, cat = 1, name = "Сценическая ферма-колонна (trdpillar01)" },
    { id = 354, cat = 4, name = "Сигнальная ракета / факел (flare)" },
    { id = 3663, cat = 1, name = "Ступени / подиум широкий (lasstepsa_LAS)" },
    { id = 3790, cat = 4, name = "Ракета боевая (декор) (missile_01_SFXR)" },
    { id = 5130, cat = 6, name = "Индустриальный блок / конструкция (imcompstrs02)" },
    { id = 902, cat = 5, name = "Морская звезда (Starfish)" },
    { id = 910, cat = 3, name = "Стойка с бюстом / шкафчик (BUST_CABINET_4)" },
    { id = 946, cat = 1, name = "Баскетбольное кольцо со щитом (bskball_lax)" },
    { id = 9525, cat = 6, name = "Промышленный резервуар / будка (boigas_sfw03)" },
    { id = 967, cat = 2, name = "КПП / будка со шлагбаумом (bar_gatebox01)" },
    { id = 10281, cat = 2, name = "Рекламный / дорожный щит SF (michsign_sfe)" },
    { id = 11700, cat = 2, name = "Дорожный знак (SAMP 47) (SAMPRoadSign47)" },
    { id = 11717, cat = 3, name = "Кожаный диван Вузи (WooziesCouch1)" },
    { id = 11720, cat = 3, name = "Двуспальная кровать (SweetsBed1)" },
    { id = 11724, cat = 3, name = "Каминный портал каменный (FireplaceSurround1)" },
    { id = 11725, cat = 3, name = "Камин декоративный (Fireplace1)" },
    { id = 11733, cat = 5, name = "Деревянная лошадка-качалка (WRockingHorse1)" },
    { id = 11734, cat = 3, name = "Деревянное кресло-качалка (WRockingChair1)" },
    { id = 1369, cat = 7, name = "Инвалидная коляска (CJ_WHEELCHAIR1)" },
    { id = 1372, cat = 5, name = "Большой мусорный контейнер (CJ_Dump2_LOW)" },
    { id = 14467, cat = 5, name = "Статуя декоративная (Бюст/Монумент) (carter_statue)" },
    { id = 1491, cat = 2, name = "Дверь межкомнатная белая (Gen_doorINT01)" },
    { id = 1504, cat = 2, name = "Дверь входная 06 (Gen_doorEXT06)" },
    { id = 1505, cat = 2, name = "Дверь входная 07 (Gen_doorEXT07)" },
    { id = 1506, cat = 2, name = "Дверь входная 08 (Gen_doorEXT08)" },
    { id = 1507, cat = 2, name = "Дверь входная 09 (Gen_doorEXT09)" },
    { id = 1523, cat = 2, name = "Дверь входная 10 (Gen_doorEXT10)" },
    { id = 1557, cat = 2, name = "Дверь входная 19 (Gen_doorEXT19)" },
    { id = 1569, cat = 2, name = "Дверь металлическая с ручкой (ADAM_V_DOOR)" },
    { id = 16151, cat = 1, name = "Барная стойка НЛО (ufo_bar)" },
    { id = 1714, cat = 3, name = "Офисное вращающееся кресло (kb_swivelchair1)" },
    { id = 1735, cat = 3, name = "Мягкое домашнее кресло (CJ_EASYCHAIR1)" },
    { id = 1768, cat = 3, name = "Диван домашний классический (LOW_COUCH_3)" },
    { id = 1769, cat = 3, name = "Кресло мягкое одиночное (LOW_SINGLE_3)" },
    { id = 1771, cat = 3, name = "Двухъярусная кровать (CJ_bunk_bed1)" },
    { id = 1825, cat = 3, name = "Столик со стульями комплект (kb_table_chairs1)" },
    { id = 1851, cat = 7, name = "Игральный кубик большой (dice1)" },
    { id = 18643, cat = 4, name = "Лазерная указка / луч (LaserPointer1)" },
    { id = 18647, cat = 4, name = "Неоновая трубка красная (RedNeonTube1)" },
    { id = 18648, cat = 4, name = "Неоновая трубка синяя (BlueNeonTube1)" },
    { id = 18649, cat = 4, name = "Неоновая трубка зелёная (GreenNeonTube1)" },
    { id = 18650, cat = 4, name = "Неоновая трубка жёлтая (YellowNeonTube1)" },
    { id = 18651, cat = 4, name = "Неоновая трубка розовая (PinkNeonTube1)" },
    { id = 18652, cat = 4, name = "Неоновая трубка белая (WhiteNeonTube1)" },
    { id = 18653, cat = 4, name = "Диско-шар / свет красный (DiscoLightRed)" },
    { id = 18654, cat = 4, name = "Диско-шар / свет зелёный (DiscoLightGreen)" },
    { id = 18655, cat = 4, name = "Диско-шар / свет синий (DiscoLightBlue)" },
    { id = 18656, cat = 4, name = "Световой луч / прожектор белый (LightBeamWhite)" },
    { id = 18657, cat = 4, name = "Световой луч / прожектор красный (LightBeamRed)" },
    { id = 18658, cat = 4, name = "Световой луч / прожектор синий (LightBeamBlue)" },
    { id = 18690, cat = 4, name = "Эффект огня большой (авто) (fire_car)" },
    { id = 18691, cat = 4, name = "Эффект сильного пламени (fire_large)" },
    { id = 18692, cat = 4, name = "Эффект среднего огня (fire_med)" },
    { id = 18693, cat = 4, name = "Эффект пламени малый (Flame99)" },
    { id = 18761, cat = 1, name = "Стартовая/финишная линия гонки (RaceFinishLine1)" },
    { id = 18762, cat = 6, name = "Бетонная плита 1x1x5 м (Concrete1mx1mx5m)" },
    { id = 18763, cat = 6, name = "Бетонная плита 3x3x5 м (Concrete3mx3mx5m)" },
    { id = 18764, cat = 6, name = "Бетонная плита 5x5x5 м (Concrete5mx5mx5m)" },
    { id = 18765, cat = 6, name = "Бетонная площадка 10x10x5 м (Concrete10mx10mx5m)" },
    { id = 18766, cat = 6, name = "Бетонная полоса 10x1x5 м (Concrete10mx1mx5m)" },
    { id = 18767, cat = 1, name = "Бетонная лестница 1H (ConcreteStair1H)" },
    { id = 18848, cat = 4, name = "Зенитная установка ПВО (декор) (SamSiteNonDynamic)" },
    { id = 18856, cat = 2, name = "Металлическая клетка 5x5x3 м (Cage5mx5mx3m)" },
    { id = 18880, cat = 4, name = "Дорожная камера контроля скорости (SpeedCamera1)" },
    { id = 1895, cat = 3, name = "Колесо фортуны (казино) (wheel_o_fortune)" },
    { id = 19054, cat = 5, name = "Новогодний подарок (коробка 1) (XmasBox1)" },
    { id = 19055, cat = 5, name = "Новогодний подарок (коробка 2) (XmasBox2)" },
    { id = 19056, cat = 5, name = "Новогодний подарок (коробка 3) (XmasBox3)" },
    { id = 19057, cat = 5, name = "Новогодний подарок (коробка 4) (XmasBox4)" },
    { id = 19058, cat = 5, name = "Новогодний подарок (коробка 5) (XmasBox5)" },
    { id = 19059, cat = 5, name = "Ёлочный шар 1 (XmasOrb1)" },
    { id = 19060, cat = 5, name = "Ёлочный шар 2 (XmasOrb2)" },
    { id = 19061, cat = 5, name = "Ёлочный шар 3 (XmasOrb3)" },
    { id = 19062, cat = 5, name = "Ёлочный шар 4 (XmasOrb4)" },
    { id = 19063, cat = 5, name = "Ёлочный шар 5 (XmasOrb5)" },
    { id = 19064, cat = 5, name = "Новогодний колпак Санты (SantaHat1)" },
    { id = 19076, cat = 5, name = "Новогодняя ёлка наряженная (XmasTree1)" },
    { id = 19078, cat = 5, name = "Фигурка попугая (TheParrot1)" },
    { id = 19089, cat = 2, name = "Канат / оградительная верёвка (Rope3)" },
    { id = 19090, cat = 5, name = "Помпон синий (декор) (PomPomBlue)" },
    { id = 19091, cat = 5, name = "Помпон красный (декор) (PomPomRed)" },
    { id = 19092, cat = 5, name = "Помпон зелёный (декор) (PomPomGreen)" },
    { id = 19121, cat = 4, name = "Светящийся столбик 1 (белый) (BollardLight1)" },
    { id = 19122, cat = 4, name = "Светящийся столбик 2 (синий) (BollardLight2)" },
    { id = 19123, cat = 4, name = "Светящийся столбик 3 (зелёный) (BollardLight3)" },
    { id = 19124, cat = 4, name = "Светящийся столбик 4 (красный) (BollardLight4)" },
    { id = 19125, cat = 4, name = "Светящийся столбик 5 (жёлтый) (BollardLight5)" },
    { id = 19126, cat = 4, name = "Светящийся столбик 6 (оранж.) (BollardLight6)" },
    { id = 19127, cat = 4, name = "Светящийся столбик 7 (фиол.) (BollardLight7)" },
    { id = 19128, cat = 1, name = "Светящийся танцпол 1 (DanceFloor1)" },
    { id = 19129, cat = 1, name = "Светящийся танцпол 2 (DanceFloor2)" },
    { id = 19159, cat = 1, name = "Зеркальный диско-шар (MirrorBall1)" },
    { id = 19164, cat = 3, name = "Настенная карта GTA SA (верт.) (GTASAMap1vert)" },
    { id = 19165, cat = 3, name = "Настенная карта GTA SA 2 (GTASAMap2)" },
    { id = 19166, cat = 3, name = "Настенная карта GTA SA 3 (GTASAMap3)" },
    { id = 19168, cat = 3, name = "Настенная карта GTA SA 5 (GTASAMap5)" },
    { id = 19169, cat = 3, name = "Настенная карта GTA SA 6 (GTASAMap6)" },
    { id = 19170, cat = 3, name = "Настенная карта GTA SA 7 (GTASAMap7)" },
    { id = 19171, cat = 3, name = "Настенная карта GTA SA 8 (GTASAMap8)" },
    { id = 19172, cat = 3, name = "Картина на стену SAMP 1 (SAMPPicture1)" },
    { id = 19173, cat = 3, name = "Картина на стену SAMP 2 (SAMPPicture2)" },
    { id = 19174, cat = 3, name = "Картина на стену SAMP 3 (SAMPPicture3)" },
    { id = 19175, cat = 3, name = "Картина на стену SAMP 4 (SAMPPicture4)" },
    { id = 19303, cat = 1, name = "Секция моста / эстакады 19 (subbridge19)" },
    { id = 19314, cat = 5, name = "Рога быка настенные (bullhorns01)" },
    { id = 19315, cat = 5, name = "Фигура оленя декоративная (deer01)" },
    { id = 19317, cat = 1, name = "Бас-гитара декоративная (bassguitar01)" },
    { id = 19318, cat = 1, name = "Электрогитара Flying V (flyingv01)" },
    { id = 19319, cat = 1, name = "Электрогитара Warlock (warlock01)" },
    { id = 19320, cat = 5, name = "Хэллоуинская тыква (pumpkin01)" },
    { id = 19339, cat = 5, name = "Гроб деревянный (декор) (coffin01)" },
    { id = 19341, cat = 5, name = "Пасхальное яйцо 1 (easter_egg01)" },
    { id = 19342, cat = 5, name = "Пасхальное яйцо 2 (easter_egg02)" },
    { id = 19343, cat = 5, name = "Пасхальное яйцо 3 (easter_egg03)" },
    { id = 19344, cat = 5, name = "Пасхальное яйцо 4 (easter_egg04)" },
    { id = 19345, cat = 5, name = "Пасхальное яйцо 5 (easter_egg05)" },
    { id = 19375, cat = 6, name = "Модуль стены 023 (wall023)" },
    { id = 19376, cat = 6, name = "Модуль стены 024 (wall024)" },
    { id = 19378, cat = 6, name = "Модуль стены 026 (wall026)" },
    { id = 19379, cat = 6, name = "Модуль стены 027 (wall027)" },
    { id = 19380, cat = 6, name = "Модуль стены 028 (wall028)" },
    { id = 19381, cat = 6, name = "Модуль стены 029 (wall029)" },
    { id = 19383, cat = 6, name = "Модуль стены 031 (wall031)" },
    { id = 19384, cat = 6, name = "Модуль стены 032 (wall032)" },
    { id = 19385, cat = 6, name = "Модуль стены 033 (wall033)" },
    { id = 19386, cat = 6, name = "Модуль стены 034 (wall034)" },
    { id = 19387, cat = 6, name = "Модуль стены 035 (wall035)" },
    { id = 19388, cat = 6, name = "Модуль стены 036 (wall036)" },
    { id = 19389, cat = 6, name = "Модуль стены 037 (wall037)" },
    { id = 19390, cat = 6, name = "Модуль стены 038 (wall038)" },
    { id = 19391, cat = 6, name = "Модуль стены 039 (wall039)" },
    { id = 19392, cat = 6, name = "Модуль стены 040 (wall040)" },
    { id = 19393, cat = 6, name = "Модуль стены 041 (wall041)" },
    { id = 19394, cat = 6, name = "Модуль стены 042 (wall042)" },
    { id = 19395, cat = 6, name = "Модуль стены 043 (wall043)" },
    { id = 19396, cat = 6, name = "Модуль стены 044 (wall044)" },
    { id = 19397, cat = 6, name = "Модуль стены 045 (wall045)" },
    { id = 19398, cat = 6, name = "Модуль стены 046 (wall046)" },
    { id = 19399, cat = 6, name = "Модуль стены 047 (wall047)" },
    { id = 19400, cat = 6, name = "Модуль стены 048 (wall048)" },
    { id = 19401, cat = 6, name = "Модуль стены 049 (wall049)" },
    { id = 19402, cat = 6, name = "Модуль стены 050 (wall050)" },
    { id = 19403, cat = 6, name = "Модуль стены 051 (wall051)" },
    { id = 19404, cat = 6, name = "Модуль стены 052 (wall052)" },
    { id = 19405, cat = 6, name = "Модуль стены 053 (wall053)" },
    { id = 19406, cat = 6, name = "Модуль стены 054 (wall054)" },
    { id = 19407, cat = 6, name = "Модуль стены 055 (wall055)" },
    { id = 19408, cat = 6, name = "Модуль стены 056 (wall056)" },
    { id = 19409, cat = 6, name = "Модуль стены 057 (wall057)" },
    { id = 19410, cat = 6, name = "Модуль стены 058 (wall058)" },
    { id = 19411, cat = 6, name = "Модуль стены 059 (wall059)" },
    { id = 19412, cat = 6, name = "Модуль стены 060 (wall060)" },
    { id = 19413, cat = 6, name = "Модуль стены 061 (wall061)" },
    { id = 19414, cat = 6, name = "Модуль стены 062 (wall062)" },
    { id = 19415, cat = 6, name = "Модуль стены 063 (wall063)" },
    { id = 19416, cat = 6, name = "Модуль стены 064 (wall064)" },
    { id = 19417, cat = 6, name = "Модуль стены 065 (wall065)" },
    { id = 19426, cat = 6, name = "Модуль стены 066 (wall066)" },
    { id = 19427, cat = 6, name = "Модуль стены 067 (wall067)" },
    { id = 19428, cat = 6, name = "Модуль стены 068 (wall068)" },
    { id = 19429, cat = 6, name = "Модуль стены 069 (wall069)" },
    { id = 19430, cat = 6, name = "Модуль стены 070 (wall070)" },
    { id = 19431, cat = 6, name = "Модуль стены 071 (wall071)" },
    { id = 19432, cat = 6, name = "Модуль стены 072 (wall072)" },
    { id = 19433, cat = 6, name = "Модуль стены 073 (wall073)" },
    { id = 19434, cat = 6, name = "Модуль стены 074 (wall074)" },
    { id = 19435, cat = 6, name = "Модуль стены 075 (wall075)" },
    { id = 19436, cat = 6, name = "Модуль стены 076 (wall076)" },
    { id = 19437, cat = 6, name = "Модуль стены 077 (wall077)" },
    { id = 19438, cat = 6, name = "Модуль стены 078 (wall078)" },
    { id = 19439, cat = 6, name = "Модуль стены 079 (wall079)" },
    { id = 19440, cat = 6, name = "Модуль стены 080 (wall080)" },
    { id = 19441, cat = 6, name = "Модуль стены 081 (wall081)" },
    { id = 19442, cat = 6, name = "Модуль стены 082 (wall082)" },
    { id = 19443, cat = 6, name = "Модуль стены 083 (wall083)" },
    { id = 19444, cat = 6, name = "Модуль стены 084 (wall084)" },
    { id = 19445, cat = 6, name = "Модуль стены 085 (wall085)" },
    { id = 19446, cat = 6, name = "Модуль стены 086 (wall086)" },
    { id = 19447, cat = 6, name = "Модуль стены 087 (wall087)" },
    { id = 19448, cat = 6, name = "Модуль стены 088 (wall088)" },
    { id = 19449, cat = 6, name = "Модуль стены 089 (wall089)" },
    { id = 19450, cat = 6, name = "Модуль стены 090 (wall090)" },
    { id = 19451, cat = 6, name = "Модуль стены 091 (wall091)" },
    { id = 19452, cat = 6, name = "Модуль стены 092 (wall092)" },
    { id = 19453, cat = 6, name = "Модуль стены 093 (wall093)" },
    { id = 19454, cat = 6, name = "Модуль стены 094 (wall094)" },
    { id = 19455, cat = 6, name = "Модуль стены 095 (wall095)" },
    { id = 19456, cat = 6, name = "Модуль стены 096 (wall096)" },
    { id = 19457, cat = 6, name = "Модуль стены 097 (wall097)" },
    { id = 19458, cat = 6, name = "Модуль стены 098 (wall098)" },
    { id = 19459, cat = 6, name = "Модуль стены 099 (wall099)" },
    { id = 19460, cat = 6, name = "Модуль стены 100 (wall100)" },
    { id = 19461, cat = 6, name = "Модуль стены 101 (wall101)" },
    { id = 19462, cat = 6, name = "Модуль стены 102 (wall102)" },
    { id = 19463, cat = 6, name = "Модуль стены 103 (wall103)" },
    { id = 19464, cat = 6, name = "Модуль стены 104 (wall104)" },
    { id = 19465, cat = 6, name = "Модуль стены 105 (wall105)" },
    { id = 19466, cat = 6, name = "Оконная рама со стеклом (window001)" },
    { id = 19525, cat = 5, name = "Свадебный торт большой (WeddingCake1)" },
    { id = 19570, cat = 7, name = "Стеклянная бутылка молока (MilkBottle1)" },
    { id = 19576, cat = 7, name = "Красное яблоко (Apple2)" },
    { id = 19577, cat = 7, name = "Помидор (Tomato1)" },
    { id = 19578, cat = 7, name = "Банан (Banana1)" },
    { id = 19579, cat = 7, name = "Батон хлеба (BreadLoaf1)" },
    { id = 19580, cat = 7, name = "Пицца целая (Pizza1)" },
    { id = 19581, cat = 7, name = "Сковорода кухонная 1 (MarcosFryingPan1)" },
    { id = 19582, cat = 7, name = "Стейк готовый (MarcosSteak1)" },
    { id = 19583, cat = 7, name = "Кухонный нож (MarcosKnife1)" },
    { id = 19584, cat = 7, name = "Кастрюля с крышкой (MarcosSaucepan1)" },
    { id = 19585, cat = 7, name = "Противень / сковорода 2 (MarcosPan1)" },
    { id = 19586, cat = 7, name = "Кухонная лопатка (MarcosSpatula1)" },
    { id = 19608, cat = 1, name = "Деревянная сцена (подиум) (WoodenStage1)" },
    { id = 19609, cat = 1, name = "Барабанная установка (DrumKit1)" },
    { id = 19610, cat = 1, name = "Ручной микрофон (Microphone1)" },
    { id = 19611, cat = 1, name = "Стойка для микрофона (MicrophoneStand1)" },
    { id = 19612, cat = 1, name = "Гитарный усилитель / комбик 1 (GuitarAmp1)" },
    { id = 19613, cat = 1, name = "Гитарный усилитель / комбик 2 (GuitarAmp2)" },
    { id = 19614, cat = 1, name = "Гитарный усилитель / комбик 3 (GuitarAmp3)" },
    { id = 19615, cat = 1, name = "Гитарный усилитель / комбик 4 (GuitarAmp4)" },
    { id = 19616, cat = 1, name = "Гитарный усилитель / комбик 5 (GuitarAmp5)" },
    { id = 19624, cat = 7, name = "Чемодан / кейс чёрный (Case1)" },
    { id = 19640, cat = 3, name = "Пустой торговый стеллаж (EmptyShopShelf1)" },
    { id = 19641, cat = 2, name = "Секция забора деревянная (FenceSection1)" },
    { id = 1978, cat = 3, name = "Стол для рулетки (казино) (roulette_tbl)" },
    { id = 19789, cat = 6, name = "Строительный куб 1x1 м (Cube1mx1m)" },
    { id = 19833, cat = 5, name = "Корова (фигура) (Cow1)" },
    { id = 19948, cat = 2, name = "Дорожный знак (SAMP 1) (SAMPRoadSign1)" },
    { id = 19949, cat = 2, name = "Дорожный знак (SAMP 2) (SAMPRoadSign2)" },
    { id = 19950, cat = 2, name = "Дорожный знак (SAMP 3) (SAMPRoadSign3)" },
    { id = 19951, cat = 2, name = "Дорожный знак (SAMP 4) (SAMPRoadSign4)" },
    { id = 19952, cat = 2, name = "Дорожный знак (SAMP 5) (SAMPRoadSign5)" },
    { id = 19953, cat = 2, name = "Дорожный знак (SAMP 6) (SAMPRoadSign6)" },
    { id = 19954, cat = 2, name = "Дорожный знак (SAMP 7) (SAMPRoadSign7)" },
    { id = 19955, cat = 2, name = "Дорожный знак (SAMP 8) (SAMPRoadSign8)" },
    { id = 19956, cat = 2, name = "Дорожный знак (SAMP 9) (SAMPRoadSign9)" },
    { id = 19957, cat = 2, name = "Дорожный знак (SAMP 10) (SAMPRoadSign10)" },
    { id = 19964, cat = 2, name = "Дорожный знак (SAMP 17) (SAMPRoadSign17)" },
    { id = 19966, cat = 2, name = "Дорожный знак (SAMP 19) (SAMPRoadSign19)" },
    { id = 19967, cat = 2, name = "Дорожный знак (SAMP 20) (SAMPRoadSign20)" },
    { id = 19976, cat = 2, name = "Дорожный знак (SAMP 29) (SAMPRoadSign29)" },
    { id = 19978, cat = 2, name = "Дорожный знак (SAMP 31) (SAMPRoadSign31)" },
    { id = 19979, cat = 2, name = "Дорожный знак (SAMP 32) (SAMPRoadSign32)" },
    { id = 2029, cat = 3, name = "Обеденный стол элитный (SWANK_DINNING_1)" },
    { id = 2104, cat = 1, name = "Hi-Fi музыкальный центр (SWANK_HI_FI)" },
    { id = 2124, cat = 3, name = "Обеденный стул элитный 1 (SWANK_DIN_CHAIR_1)" },
    { id = 2161, cat = 3, name = "Офисный шкаф-тумба 4 (MED_OFFICE_UNIT_4)" },
    { id = 2167, cat = 3, name = "Офисная тумба 7 (MED_OFFICE_UNIT_7)" },
    { id = 2199, cat = 3, name = "Офисная мебель / стол ПК (MED_OFFICE6_MC_1)" },
    { id = 2226, cat = 1, name = "Домашняя аудиосистема (LOW_HI_FI_3)" },
    { id = 2229, cat = 1, name = "Концертная колонка (большая) (SWANK_SPEAKER)" },
    { id = 2232, cat = 1, name = "Сценическая колонка средняя (MED_SPEAKER_4)" },
    { id = 2299, cat = 3, name = "Большая элитная кровать (SWANK_BED_6)" },
    { id = 2320, cat = 4, name = "Телевизор напольный / плазма (CJ_TELE_5)" },
    { id = 2605, cat = 3, name = "Полицейский рабочий стол (POLCE_DESK1)" },
    { id = 2610, cat = 3, name = "Архивная тумба с ящиками (CJ_P_FILEING2)" },
    { id = 2644, cat = 3, name = "Столик кафе / закусочной (CJ_BURG_TABLE)" },
    { id = 2690, cat = 7, name = "Огнетушитель красный (CJ_FIRE_EXT)" },
    { id = 2745, cat = 7, name = "Манекен / фигурка витрины (CJ_STAT_3)" },
    { id = 2778, cat = 3, name = "Игровой автомат 1 (CJ_COIN_OP_1)" },
    { id = 2779, cat = 3, name = "Игровой автомат 2 (CJ_COIN_OP_2)" },
    { id = 2785, cat = 3, name = "Ряд игровых слот-автоматов (CJ_SLOT_BANK)" },
    { id = 2872, cat = 3, name = "Игровой автомат 3 (CJ_COIN_OP_3)" },
    { id = 2936, cat = 5, name = "Большой природный валун (kmb_rock)" },
    { id = 3462, cat = 6, name = "Декоративная арка / вывеска LV (csrangel_lvs)" },
    { id = 3471, cat = 5, name = "Статуя китайского льва (vgschinalion1)" },
    { id = 3593, cat = 6, name = "Остов сгоревшего автомобиля (la_fuckcar2)" },
    { id = 638, cat = 5, name = "Клумба с кустом декоративная (kb_planter+bush)" },
    { id = 653, cat = 5, name = "Кактус пустынный малый (sjmcacti03)" },
    { id = 753, cat = 5, name = "Группа кактусов (sm_descactiigrpb)" },
    { id = 792, cat = 5, name = "Уличное дерево городское (aw_streettree1)" },
    { id = 808, cat = 5, name = "Куст декоративный зелёный (genVEG_bush12)" },
    { id = 826, cat = 5, name = "Высокая декоративная трава (genVEG_tallgrass10)" },
    { id = 837, cat = 5, name = "Сухое дерево 1 (DEAD_TREE_1)" },
    { id = 838, cat = 5, name = "Сухое дерево 9 (DEAD_TREE_9)" },
    { id = 841, cat = 5, name = "Сухое дерево 13 (DEAD_TREE_13)" },
    { id = 848, cat = 5, name = "Сухое дерево 20 (DEAD_TREE_20)" },
    { id = 863, cat = 5, name = "Пустынное растение (sand_plant03)" },
    { id = 892, cat = 5, name = "Лиственное дерево среднее (Hazelweetree_PO)" },
    { id = 904, cat = 5, name = "Дерево Джошуа (пустыня) (sand_josh1)" },
    { id = 906, cat = 5, name = "Груда камней и обломков (p_rubblebig)" },
    { id = 942, cat = 7, name = "Ящик/контейнер технический 2 (CJ_DF_UNIT_2)" },
    { id = 949, cat = 5, name = "Комнатное растение в горшке 4 (Plant_Pot_4)" },
    { id = 950, cat = 5, name = "Комнатное растение в горшке 12 (Plant_Pot_12)" },
    { id = 970, cat = 2, name = "Низкий деревянный забор (fencesmallb)" },
    { id = 983, cat = 2, name = "Секция забора с решёткой (fenceshit3)" },
    { id = 984, cat = 2, name = "Сетчатый металлический забор (fenceshit2)" },
    { id = 19865, cat = 2, name = "Лёгкий деревянный забор (MIFenceWood1)" },
    { id = 750, cat = 1, name = "Колонна-постамент каменная (sm_scrb_column2)" },
    { id = 915, cat = 4, name = "Вентилятор кондиционера промышл. (AIRCON_FAN)" },
    { id = 920, cat = 4, name = "Жёлтый электрогенератор (Y_GENERATOR)" },
    { id = 951, cat = 4, name = "Монитор / телевизор настенный (CJ_VIEW_TELE2)" },
    { id = 1215, cat = 4, name = "Низкий уличный фонарик (bollardlight)" },
    { id = 1216, cat = 5, name = "Телефонная будка синяя (phonebooth1)" },
    { id = 1256, cat = 3, name = "Каменная садовая скамья (Stonebench1)" },
    { id = 1319, cat = 2, name = "Светоотражающий дорожный столбик (ws_ref_bollard)" },
    { id = 1364, cat = 5, name = "Декоративный стриженый куст (CJ_BUSH_PROP)" },
    { id = 1368, cat = 3, name = "Скамейка уличная с навесом (CJ_BLOCKER_BENCH)" },
    { id = 1697, cat = 6, name = "Вентиляционный короб на крышу (roofstuff16)" },
    { id = 1770, cat = 3, name = "Обеденный стол простой (LOW_DINNING_2)" },
    { id = 2032, cat = 3, name = "Обеденный стол средний (MED_DINNING_2)" },
    { id = 2117, cat = 3, name = "Обеденный стол элитный 5 (SWANK_DINNING_5)" },
    { id = 2211, cat = 3, name = "Офисная секция стола (MED_OFFICE9_UNIT_2)" },
    { id = 2627, cat = 1, name = "Беговая дорожка (спортзал) (gym_treadmill)" },
    { id = 2631, cat = 1, name = "Гимнастический мат 1 (gym_mat1)" },
    { id = 2632, cat = 1, name = "Гимнастический мат 2 (gym_mat02)" },
    { id = 2985, cat = 4, name = "Станковый пулемёт Minigun (декор) (minigun_base)" },
    { id = 3935, cat = 5, name = "Статуя-скульптура золотая (statue)" },
    { id = 19867, cat = 5, name = "Почтовый ящик на столбе (MailBox1)" },
    { id = 997, cat = 2, name = "Деревянный дорожный барьер (lhouse_barrier3)" },
    { id = 1255, cat = 3, name = "Пляжный шезлонг / лежак (lounger)" },
    { id = 1281, cat = 3, name = "Парковый деревянный стол (parktable1)" },
    { id = 1828, cat = 3, name = "Ковёр напольный с рисунком (man_sdr_rug)" },
    { id = 2063, cat = 3, name = "Зелёный стеллаж для вещей (CJ_GREENSHELVES)" },
    { id = 2064, cat = 4, name = "Полевая пушка (декор) (CJ_FEILDGUN)" },
    { id = 2097, cat = 3, name = "Ванна классическая (Bath_high)" },
    { id = 2123, cat = 3, name = "Обеденный стул элитный 4 (SWANK_DIN_CHAIR_4)" },
    { id = 2343, cat = 3, name = "Кресло парикмахерское / барбера (CJ_BARB_CHAIR_2)" },
    { id = 2434, cat = 1, name = "Стойка фастфуда угловая 2b (CJ_FF_CONTER_2b)" },
    { id = 2435, cat = 1, name = "Стойка фастфуда прямая 2 (CJ_FF_CONTER_2)" },
    { id = 2439, cat = 1, name = "Стойка фастфуда прямая 3 (CJ_FF_CONTER_3)" },
    { id = 2440, cat = 1, name = "Стойка фастфуда угловая 3b (CJ_FF_CONTER_3b)" },
    { id = 2484, cat = 7, name = "Модель парусной яхты (MODEL_YAUGHT)" },
    { id = 2512, cat = 7, name = "Модель самолёта большая 3 (MODEL_PLANE_BIG3)" },
    { id = 2525, cat = 3, name = "Унитаз керамический (CJ_TOILET4)" },
    { id = 2526, cat = 3, name = "Ванна стандартная (CJ_BATH4)" },
    { id = 2527, cat = 3, name = "Душевая кабина (CJ_SHOWER4)" },
    { id = 2699, cat = 3, name = "Вешалка-стойка для одежды (CJ_DUDS_RAIL02)" },
    { id = 2762, cat = 3, name = "Столик фастфуда Cluckin Bell 1 (CJ_CHICK_TABLE)" },
    { id = 2763, cat = 3, name = "Столик фастфуда Cluckin Bell 2 (CJ_CHICK_TABLE_2)" },
    { id = 2764, cat = 3, name = "Столик пиццерии красный (CJ_PIZZA_TABLE03)" },
    { id = 2909, cat = 2, name = "Ворота подъездные металлические (kmb_frontgate)" },
    { id = 2930, cat = 2, name = "Ворота в китайском стиле (chinaTgate)" },
    { id = 2983, cat = 7, name = "Вентиль / маховик на трубу (will_valve)" },
    { id = 2984, cat = 3, name = "Биотуалет переносной (portaloo)" },
    { id = 3039, cat = 1, name = "Торговый прилавок / стенд 1 (ct_stall1)" },
    { id = 3040, cat = 1, name = "Торговый прилавок / стенд 2 (ct_stall2)" },
    { id = 3041, cat = 3, name = "Складной столик / верстак (ct_table)" },
    { id = 3264, cat = 2, name = "Табличка «Частная территория» (privatesign3)" },
    { id = 3273, cat = 4, name = "Трансформаторная подстанция (substa_transf2_)" },
    { id = 3472, cat = 4, name = "Цирковой декоративный фонарь (circuslampost03)" },
    { id = 3496, cat = 1, name = "Баскетбольный щит с сеткой (vgsxrefbballnet)" },
    { id = 8572, cat = 1, name = "Широкая лестница (казино LV) (vgsSstairs02_lvs)" },
    { id = 14532, cat = 3, name = "Тумба-подставка под ТВ (tv_stand_driv)" },
    { id = 19304, cat = 1, name = "Секция моста / эстакады 20 (subbridge20)" },
    { id = 19589, cat = 5, name = "Пустой строительный контейнер (скип) (RubbishSkipEmpty1)" },
    { id = 19632, cat = 5, name = "Поленница / дрова для костра (FireWood1)" },
    { id = 19795, cat = 2, name = "Тюремные решётчатые ворота (вост.) (LSPrisonGateEast)" },
    { id = 19796, cat = 2, name = "Тюремные решётчатые ворота (юг) (LSPrisonGateSouth)" },
    { id = 19799, cat = 2, name = "Бронированная дверь хранилища (CaligulasVaultDoor)" },
    { id = 19831, cat = 5, name = "Барбекю-гриль закрытый (Barbeque1)" },
    { id = 19868, cat = 2, name = "Сетчатый забор-рабица 1 (MeshFence1)" },
    { id = 19869, cat = 2, name = "Сетчатый забор-рабица 2 (MeshFence2)" },
    { id = 19870, cat = 2, name = "Металлические распашные ворота (MetalGate1)" },
    { id = 19899, cat = 3, name = "Шкаф для инструментов красный 1 (ToolCabinet1)" },
    { id = 19900, cat = 3, name = "Шкаф для инструментов красный 2 (ToolCabinet2)" },
    { id = 19903, cat = 4, name = "Диагностический компьютер СТО (MechanicComputer1)" },
    { id = 19915, cat = 3, name = "Кухонная плита (CutsceneCooker1)" },
    { id = 19916, cat = 3, name = "Холодильник металлический (CutsceneFridge1)" },
    { id = 19917, cat = 4, name = "Двигатель автомобиля на стенде (CutsceneEngine1)" },
    { id = 19943, cat = 1, name = "Каменная колонна с капителью (StonePillar1)" },
    { id = 19999, cat = 3, name = "Стул режиссёра / складной 2 (CutsceneChair2)" },
    { id = 334, cat = 7, name = "Полицейская дубинка (декор) (nitestick)" },
    { id = 355, cat = 7, name = "Автомат AK-47 (декор) (ak47)" },
    { id = 356, cat = 7, name = "Штурмовая винтовка M4 (декор) (m4)" },
    { id = 357, cat = 7, name = "Охотничье ружьё (декор) (cuntgun)" },
    { id = 939, cat = 7, name = "Ящик/контейнер технический 1 (CJ_DF_UNIT)" },
    { id = 1081, cat = 7, name = "Автомобильное колесо спорт 4 (wheel_sr4)" },
    { id = 1084, cat = 7, name = "Автомобильное колесо 5 (wheel_lr5)" },
    { id = 1086, cat = 1, name = "Автомагнитола / стереосистема (stereo)" },
    { id = 1228, cat = 2, name = "Дорожное ограждение бело-красное (roadworkbarrier1)" },
    { id = 1327, cat = 7, name = "Старая автомобильная шина (junk_tyre)" },
    { id = 1342, cat = 5, name = "Уличная тележка с едой (noodlecart_prop)" },
    { id = 1348, cat = 7, name = "Кислородные баллоны на тележке (CJ_O2Tanks)" },
    { id = 1358, cat = 5, name = "Мусорный контейнер синий (CJ_SKIP_Rubbish)" },
    { id = 1361, cat = 5, name = "Куст круглый декоративный (CJ_BUSH_PROP2)" },
    { id = 1425, cat = 2, name = "Дорожный барьер ремонтный (DYN_ROADBARRIER_3)" },
    { id = 1435, cat = 2, name = "Бетонно-пластиковый барьер 5b (DYN_ROADBARRIER_5b)" },
    { id = 1440, cat = 7, name = "Штабель картонных коробок (DYN_BOX_PILE_3)" },
    { id = 1509, cat = 7, name = "Бутылка вина (DYN_WINE_3)" },
    { id = 1544, cat = 7, name = "Бутылка напитка / пива (CJ_BEER_B_1)" },
    { id = 1550, cat = 7, name = "Мешок с деньгами (CJ_MONEY_BAG)" },
    { id = 1575, cat = 7, name = "Пакет с белым порошком (реквизит) (drug_white)" },
    { id = 1580, cat = 7, name = "Пакет с красным порошком (реквизит) (drug_red)" },
    { id = 1622, cat = 4, name = "Камера видеонаблюдения купольная (nt_securecam2_01)" },
    { id = 1654, cat = 7, name = "Динамитная шашка с таймером (dynamite)" },
    { id = 1665, cat = 7, name = "Пепельница настольная (propashtray1)" },
    { id = 1776, cat = 3, name = "Торговый автомат со снеками (CJ_CANDYVENDOR)" },
    { id = 1886, cat = 4, name = "Камера видеонаблюдения настенная (shop_sec_cam)" },
    { id = 2030, cat = 3, name = "Обеденный стол 1 (MED_DINNING_1)" },
    { id = 2050, cat = 7, name = "Стрелковая мишень силуэт 2 (CJ_TARGET2)" },
    { id = 2051, cat = 7, name = "Стрелковая мишень силуэт 4 (CJ_TARGET4)" },
    { id = 2111, cat = 3, name = "Обеденный стол низкий 5 (LOW_DINNING_5)" },
    { id = 2245, cat = 5, name = "Комнатный цветок в горшке 11 (Plant_Pot_11)" },
    { id = 2567, cat = 3, name = "Складской стеллаж металлический (ab_warehouseShelf)" },
    { id = 2737, cat = 7, name = "Полицейская машина-реквизит (POLICE_NB_car)" },
    { id = 2769, cat = 7, name = "Коробка бургера Burger Shot (CJ_CJ_BURG2)" },
    { id = 2804, cat = 7, name = "Кусок мяса на разделку (CJ_MEAT_1)" },
    { id = 2811, cat = 5, name = "Античный глиняный горшок (GB_romanpot01)" },
    { id = 2848, cat = 7, name = "Кухонная утварь / мусор (GB_kitchdirt02)" },
    { id = 2886, cat = 4, name = "Кодовая панель доступа (ключ-карта) (sec_keypad)" },
    { id = 2905, cat = 7, name = "Реквизит Хэллоуин (нога) (kmb_deadleg)" },
    { id = 2906, cat = 7, name = "Реквизит Хэллоуин (рука) (kmb_deadarm)" },
    { id = 2907, cat = 7, name = "Реквизит Хэллоуин (торс) (kmb_deadtorso)" },
    { id = 2908, cat = 7, name = "Реквизит Хэллоуин (голова) (kmb_deadhead)" },
    { id = 2932, cat = 6, name = "Морской контейнер синий (kmb_container_blue)" },
    { id = 2934, cat = 6, name = "Морской контейнер красный (kmb_container_red)" },
    { id = 2935, cat = 6, name = "Морской контейнер жёлтый (kmb_container_yel)" },
    { id = 2969, cat = 7, name = "Ящик с боеприпасами малый (level_ammobox)" },
    { id = 3014, cat = 7, name = "Оружейный ящик деревянный (cr_guncrate)" },
    { id = 3015, cat = 7, name = "Штабель ящиков с припасами (cr_cratestack)" },
    { id = 3092, cat = 7, name = "Манекен / реквизит сцены (dead_tied_cop)" },
    { id = 3111, cat = 3, name = "Чертёж здания на столе (st_arch_plan)" },
    { id = 3119, cat = 7, name = "Набор мелкого реквизита (cs_ry_props)" },
    { id = 3174, cat = 6, name = "Жилой трейлер / вагончик (sm_airstrm_sml_)" },
    { id = 3354, cat = 2, name = "Дверь дачная деревянная (отраж.) (burbdoor2REF)" },
    { id = 3393, cat = 6, name = "Стол/стойка Зоны 51 (a51_sdsk_ncol4_)" },
    { id = 3791, cat = 4, name = "Ракета промышленная 10 (missile_10_SFXR)" },
    { id = 3796, cat = 4, name = "Блок кондиционера наружный (acbox1_SFS)" },
    { id = 5259, cat = 6, name = "Платформа дока / склада (las2dkwar01)" },
    { id = 8623, cat = 5, name = "Пышный кустарник LV (bush03_lvs)" },
    { id = 11293, cat = 6, name = "Промышленные цистерны / баки (facttanks_SFSe08)" },
    { id = 11461, cat = 1, name = "Вышка водонапорная / башня (des_nwwtower)" },
    { id = 11709, cat = 3, name = "Раковина металлическая двойная (AbattoirSink1)" },
    { id = 11710, cat = 2, name = "Светящаяся табличка Пожарный выход (FireExitSign1)" },
    { id = 11711, cat = 2, name = "Светящаяся табличка ВЫХОД (Exit) (ExitSign1)" },
    { id = 11716, cat = 7, name = "Металлический нож (MetalKnife1)" },
    { id = 11738, cat = 7, name = "Медицинский чемоданчик (аптечка) (MedicCase1)" },
    { id = 11744, cat = 7, name = "Тарелка столовая белая (MPlate1)" },
    { id = 11749, cat = 7, name = "Металлические наручники (CSHandcuffs1)" },
    { id = 13028, cat = 2, name = "Дверь/ворота покрасочной камеры (CE_spraydoor1)" },
    { id = 13188, cat = 2, name = "Дверь деревянная классическая (burbdoor2)" },
    { id = 14804, cat = 5, name = "Комнатное растение крупное (BDups_plant)" },
    { id = 18671, cat = 4, name = "Распылитель автомойки / дым (carwashspray)" },
    { id = 18715, cat = 4, name = "Эффект густого дыма большой (prt_smoke_huge)" },
    { id = 18723, cat = 4, name = "Эффект дымовой шашки (riot_smoke)" },
    { id = 18726, cat = 4, name = "Эффект дымовой завесы 30 м (smoke30m)" },
    { id = 18739, cat = 5, name = "Эффект фонтана воды (water_fountain)" },
    { id = 19141, cat = 7, name = "Шлем спецназа SWAT (SWATHelmet1)" },
    { id = 19306, cat = 1, name = "Секция подъёмного моста 2 (verticalift_bridg2)" },
    { id = 19307, cat = 1, name = "Секция подъёмного моста 1 (verticalift_bridge)" },
    { id = 19515, cat = 7, name = "Бронежилет SWAT серый (SWATAgrey)" },
    { id = 19563, cat = 7, name = "Пакет сока 1 (JuiceBox1)" },
    { id = 19564, cat = 7, name = "Пакет сока 2 (JuiceBox2)" },
    { id = 19568, cat = 7, name = "Ведёрко мороженого (IcecreamContainer2)" },
    { id = 19627, cat = 7, name = "Гаечный ключ (Wrench1)" },
    { id = 19806, cat = 4, name = "Хрустальная люстра потолочная (Chandelier1)" },
    { id = 19808, cat = 4, name = "Компьютерная клавиатура (Keyboard1)" },
    { id = 19817, cat = 1, name = "Эстакада / рампа для авто 1 (CarFixerRamp1)" },
    { id = 19818, cat = 7, name = "Бокал для вина (WineGlass1)" },
    { id = 19819, cat = 7, name = "Коктейльный бокал (CocktailGlass1)" },
    { id = 19820, cat = 7, name = "Бутылка алкоголя 1 (AlcoholBottle1)" },
    { id = 19822, cat = 7, name = "Бутылка алкоголя 3 (AlcoholBottle3)" },
    { id = 19824, cat = 7, name = "Бутылка алкоголя 5 (AlcoholBottle5)" },
    { id = 19835, cat = 7, name = "Кофейная чашка (CoffeeCup1)" },
    { id = 19836, cat = 7, name = "Лужа красной краски / реквизит (BloodPool1)" },
    { id = 19872, cat = 1, name = "Эстакада / рампа для авто 2 (CarFixerRamp2)" },
    { id = 19873, cat = 7, name = "Рулон туалетной бумаги (ToiletPaperRoll1)" },
    { id = 19874, cat = 7, name = "Кусок мыла (SoapBar1)" },
    { id = 19882, cat = 7, name = "Стейк на тарелке 2 (MarcosSteak2)" },
    { id = 19893, cat = 4, name = "Ноутбук SAMP чёрный (LaptopSAMP1)" },
    { id = 19894, cat = 4, name = "Ноутбук SAMP серебристый (LaptopSAMP2)" },
    { id = 19914, cat = 7, name = "Бейсбольная бита (реквизит) (CutsceneBat1)" },
    { id = 19942, cat = 4, name = "Полицейская рация портативная (PoliceRadio1)" },
    { id = 19994, cat = 3, name = "Стул режиссёра / складной 1 (CutsceneChair1)" },
}
P6_decor_by_id = {}
for _, _p6_it in ipairs(P6_decor_catalog) do
    P6_decor_by_id[_p6_it.id] = _p6_it
end
P6_loc_favorites = {}
P6_loc_recents = {}
P6_loc_registry = {}

loc_ui_show = imgui.new.bool(false)
loc_ui_tab = 1
loc_cat_filter = imgui.new.int(0)
loc_sort_mode = imgui.new.int(0)
loc_compact_cards = imgui.new.bool(false)
loc_search_buf = imgui.new.char[65]("")
loc_selected_id = 0
loc_cache_previews = imgui.new.bool(false)
loc_textures = {}
loc_use_short_cmd = imgui.new.bool(true)

tedit_show = imgui.new.bool(false)
tedit_active = false
tedit_player_obj = false
tedit_obj_id = -1
tedit_handle = nil
tedit_model = 0
tedit_pos = {x = 0.0, y = 0.0, z = 0.0}
tedit_rot = {x = 0.0, y = 0.0, z = 0.0}
tedit_step_pos = imgui.new.float(0.10)
tedit_step_rot = imgui.new.float(5.0)
tedit_undo = {}
tedit_redo = {}
tedit_clipboard = nil
tedit_offset = {x = imgui.new.float(0.0), y = imgui.new.float(0.0), z = imgui.new.float(0.0)}
tedit_dup_pending = false
loc_bp_json_path = getWorkingDirectory() .. "/config/helper_loc_blueprint.json"
loc_status_msg = ""
loc_mid_helper_idx = 0

P6.fav_map = {}
P6.fav_src_ref = nil
P6.fav_only = imgui.new.bool(false)
P6.recent_only = imgui.new.bool(false)
P6.cat_page = 1
P6.dl_pending = {}
P6.dl_queue = {}
P6.dl_active_count = 0
P6.dirty_edit = false
P6.edit_start_pos = nil
P6.dup_model = 0
P6.tedit_dismissed = false
P6.tedit_win_open = imgui.new.bool(true)
P6.cached_srv_name = ""
P6.reg_profile_view = ""
P6.reg_clear_confirm = false
P6.manual_x = imgui.new.float(0.0)
P6.manual_y = imgui.new.float(0.0)
P6.manual_z = imgui.new.float(0.0)
P6.manual_rx = imgui.new.float(0.0)
P6.manual_ry = imgui.new.float(0.0)
P6.manual_rz = imgui.new.float(0.0)
P6.tex_order = {}

cruise_speed = 0.0

-- Погода и Время (Визуал)
weather_locked = imgui.new.bool(false)
weather_id = imgui.new.int(1)
time_locked = imgui.new.bool(false)
time_hour = imgui.new.int(12)

-- Визуальный скин-ченджер
skin_changer_id = imgui.new.int(0)

-- Компактный HUD (время, PayDay, FPS/Ping, КД, финансы, статусы)
hud_enabled = imgui.new.bool(false)
hud_show_cooldowns = imgui.new.bool(true)
hud_show_finance = imgui.new.bool(true)
hud_cache = {
    time_str = "00:00:00",
    payday_str = "00м 00с",
    ping = 0,
    wp_text = "",
    last_update = 0
}
user_waypoints = {}
active_waypoint = nil
wp_name_buf = imgui.new.char[65]("")
wp_search_buf = imgui.new.char[65]("")
export_path = getWorkingDirectory() .. "/config/helper_export.json"
export_status_text = ""
preset_status_text = ""

-- Таймеры откатов (КД) команд
cmd_cooldown_durations = { ad = 60, gnews = 60, healme = 30, mask = 30, fill = 15 }
cmd_cooldowns = {}

-- Трекер финансов за сессию
finance_enabled = imgui.new.bool(true)
finance_last_money = nil
finance_income = 0
finance_expense = 0
finance_log = {}
last_finance_hint = ""
last_finance_hint_time = 0

-- Список друзей и звуковые уведомления
friends_list = {}
friends_notify = imgui.new.bool(true)
friend_add_nick = imgui.new.char[65]("")
friend_add_note = imgui.new.char[65]("")
sound_enabled = imgui.new.bool(true)
sound_sms = imgui.new.bool(true)
sound_mention = imgui.new.bool(true)
sound_efir_call = imgui.new.bool(true)
sound_ad_pub = imgui.new.bool(true)
sound_friend = imgui.new.bool(true)
mention_last_sound_time = 0

local function playAlertSound(sid)
    if sound_enabled[0] then
        local s_id = sid or 1057
        queueTask(function()
            pcall(addOneOffSound, 0.0, 0.0, 0.0, s_id)
        end)
    end
end

-- Меню взаимодействия по прицелу (ПКМ + X)
target_menu_enabled = imgui.new.bool(true)
target_menu_show = imgui.new.bool(false)
target_menu_id = -1
target_menu_nick = ""
target_menu_phone = ""
target_pay_amount = imgui.new.int(1000)

-- Скрин для отчёта (/ss)
ss_delay = imgui.new.int(700)

-- История и поиск по чату (/clog)
chat_log_history = {}
clog_show = imgui.new.bool(false)
clog_search_buf = imgui.new.char[65]("")

-- Авто-проверка обновлений с GitHub
check_updates_enabled = imgui.new.bool(true)
update_status_text = ""
update_checking = false
qol_ui_page = 1

-- Безопасный арифметический парсер для /calc (без loadstring)
calc_multipliers = {
    ["kkk"] = 1000000000, ["ккк"] = 1000000000, ["млрд"] = 1000000000,
    ["kk"] = 1000000, ["кк"] = 1000000, ["млн"] = 1000000,
    ["k"] = 1000, ["к"] = 1000, ["тыс"] = 1000,
}

local function evalCalcExpr(expr)
    if type(expr) ~= "string" then return nil, "Пустое выражение" end
    local s = cp1251_lower(expr):gsub("%s+", "")
    if s == "" then return nil, "Пустое выражение" end

    local tokens = {}
    local i = 1
    local len = #s
    while i <= len do
        local ch = s:sub(i, i)
        if ch == "+" or ch == "-" or ch == "*" or ch == "/" or ch == "(" or ch == ")" then
            tokens[#tokens + 1] = {kind = "op", val = ch}
            i = i + 1
        elseif ch:match("%d") then
            local num_str = s:match("^%d+[%.%,]?%d*", i)
            if not num_str then return nil, "Ошибка числа" end
            i = i + #num_str
            local val = tonumber((num_str:gsub(",", ".")))
            if not val then return nil, "Ошибка числа" end
            local suf = s:match("^[a-z\168\184\192-\255]+", i)
            if suf then
                local mult = calc_multipliers[suf]
                if not mult then return nil, "Неизвестный суффикс: " .. suf end
                val = val * mult
                i = i + #suf
            end
            tokens[#tokens + 1] = {kind = "num", val = val}
        else
            return nil, "Недопустимый символ: " .. ch
        end
    end

    local pos = 1
    local parseExpr

    local function parseFactor()
        local tok = tokens[pos]
        if not tok then return nil, "Неожиданный конец выражения" end
        if tok.kind == "op" and (tok.val == "+" or tok.val == "-") then
            pos = pos + 1
            local v, err = parseFactor()
            if not v then return nil, err end
            return tok.val == "-" and -v or v
        elseif tok.kind == "op" and tok.val == "(" then
            pos = pos + 1
            local v, err = parseExpr()
            if not v then return nil, err end
            if not tokens[pos] or tokens[pos].kind ~= "op" or tokens[pos].val ~= ")" then
                return nil, "Не закрыта скобка ')'"
            end
            pos = pos + 1
            return v
        elseif tok.kind == "num" then
            pos = pos + 1
            return tok.val
        end
        return nil, "Ошибка синтаксиса"
    end

    local function parseTerm()
        local left, err = parseFactor()
        if not left then return nil, err end
        while tokens[pos] and tokens[pos].kind == "op" and (tokens[pos].val == "*" or tokens[pos].val == "/") do
            local op = tokens[pos].val
            pos = pos + 1
            local right, rerr = parseFactor()
            if not right then return nil, rerr end
            if op == "*" then
                left = left * right
            else
                if right == 0 then return nil, "Деление на ноль" end
                left = left / right
            end
        end
        return left
    end

    parseExpr = function()
        local left, err = parseTerm()
        if not left then return nil, err end
        while tokens[pos] and tokens[pos].kind == "op" and (tokens[pos].val == "+" or tokens[pos].val == "-") do
            local op = tokens[pos].val
            pos = pos + 1
            local right, rerr = parseTerm()
            if not right then return nil, rerr end
            left = op == "+" and (left + right) or (left - right)
        end
        return left
    end

    local res, err = parseExpr()
    if not res then return nil, err end
    if pos <= #tokens then return nil, "Лишние символы в конце выражения" end
    if res ~= res or res == math.huge or res == -math.huge then
        return nil, "Переполнение результата"
    end
    return res
end

-- Переменные для модуля "Авто-объявления (Auto-Ad)"
aad_active = false
aad_text = ""
aad_delay = imgui.new.int(15000)
aad_templates = {}
aad_history = {}
static_aad_buf = nil
last_ad_sent_time = 0
aad_waiting_for_publish = false

-- Переменная для определения фракции
selected_faction = imgui.new.int(0)

-- Forward declarations (функции определяются позже, но используются в модулях)
local isModuleEnabled
local saved_module_states
local modules
local factionScannerWorker
local chatScannerWorker
local sendAdCommand


-- СПРАВОЧНИК КОМАНД ADVANCE RP
advance_commands = {
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
function loadDatabases()
if not doesDirectoryExist(getWorkingDirectory() .. "/config") then
createDirectory(getWorkingDirectory() .. "/config")
end

local parsed_db = readJsonFile(db_path)
if type(parsed_db) == "table" then
    local cleaned_db = {}
    for nick, v in pairs(parsed_db) do
        if type(nick) == "string" and nick ~= "" and not nick:find("%z") and #nick <= 64
            and type(v) == "table" and type(v.phone) == "string" and not v.phone:find("%z") then
            cleaned_db[nick] = {
                phone = v.phone,
                time = type(v.time) == "string" and not v.time:find("%z") and v.time or "",
                ad = type(v.ad) == "string" and not v.ad:find("%z") and v.ad or ""
            }
        end
    end
    player_db = cleaned_db
end

local parsed_rules = readJsonFile(rules_path)
if type(parsed_rules) == "table" then
local cleaned = {}
for _, rule in ipairs(parsed_rules) do
if type(rule) == "table" and type(rule.abbreviation) == "string" and type(rule.replacement) == "string" and rule.abbreviation ~= "" and not rule.abbreviation:find("%z") and not rule.replacement:find("%z") and #rule.abbreviation <= 128 and #rule.replacement <= 512 then
cleaned[#cleaned + 1] = {abbreviation = rule.abbreviation, replacement = rule.replacement}
if #cleaned >= 5000 then break end
end
end
if #cleaned > 0 then
    local sanitized, changed = sanitizeAndDedupeRules(cleaned)
    if #sanitized > 0 then
        mm_rules = sanitized
        mm_rule_revision = mm_rule_revision + 1
        if changed then requestSaveRules() end
    end
end
end

local parsed = readJsonFile(settings_path)
if parsed then
if type(parsed.gnews) == "table" and type(parsed.gnews.profiles) == "table" and #parsed.gnews.profiles >= 1 then
    local cleaned_profiles = {}
    for _, prof in ipairs(parsed.gnews.profiles) do
        if type(prof) == "table" then
            local function cleanGStr(sv, def_v)
                if type(sv) == "string" and not sv:find("%z") then return sv end
                return def_v
            end
            local item = {
                name = cleanGStr(prof.name, "Профиль " .. tostring(#cleaned_profiles + 1)),
                tag = cleanGStr(prof.tag, ""),
                line1 = cleanGStr(prof.line1, ""),
                line2 = cleanGStr(prof.line2, ""),
                line3 = cleanGStr(prof.line3, ""),
                remind = cleanGStr(prof.remind, ""),
                finish = cleanGStr(prof.finish, ""),
                extra = cleanGStr(prof.extra, "")
            }
            if type(prof.delay) == "number" then
                item.delay = math.max(1000, math.min(5000, math.floor(prof.delay)))
            end
            cleaned_profiles[#cleaned_profiles + 1] = item
            if #cleaned_profiles >= 50 then break end
        end
    end
    if #cleaned_profiles >= 1 then
        local sel = tonumber(parsed.gnews.selected) or 1
        sel = math.max(1, math.min(#cleaned_profiles, math.floor(sel)))
        local dly = tonumber(parsed.gnews.delay) or 1500
        dly = math.max(1000, math.min(5000, math.floor(dly)))
        gnews_settings = {
            selected = sel,
            delay = dly,
            profiles = cleaned_profiles
        }
    end
end
if type(parsed.current_server) == "number" then current_server_idx[0] = math.max(0, math.min(#server_names - 1, math.floor(parsed.current_server))) end
if type(parsed.rp_weapons) == "boolean" then rp_weapons_enabled[0] = parsed.rp_weapons end
if type(parsed.rp_phone) == "boolean" then rp_phone_enabled[0] = parsed.rp_phone end
if type(parsed.rp_mask) == "boolean" then rp_mask_enabled[0] = parsed.rp_mask end
if type(parsed.rp_heal) == "boolean" then rp_heal_enabled[0] = parsed.rp_heal end
if type(parsed.rp_engine) == "boolean" then rp_engine_enabled[0] = parsed.rp_engine end
if type(parsed.rp_docs) == "boolean" then rp_docs_enabled[0] = parsed.rp_docs end
if type(parsed.rp_gender) == "number" then rp_gender[0] = (parsed.rp_gender == 1) and 1 or 0 end
if type(parsed.mm_auto_format) == "boolean" then mm_auto_format[0] = parsed.mm_auto_format end
if type(parsed.mm_auto_send) == "boolean" then mm_auto_send[0] = parsed.mm_auto_send end
if type(parsed.mm_send_delay) == "number" then mm_send_delay[0] = math.max(500, math.min(8000, math.floor(parsed.mm_send_delay))) end
if type(parsed.mm_tag) == "string" then
local tagOk, encodedTag = pcall(function() return u8:encode(parsed.mm_tag, encoding.default) end)
if tagOk and type(encodedTag) == "string" then safeStrCopy(mm_tag, encodedTag, ffi.sizeof(mm_tag)) end
end
if type(parsed.strobe_speed) == "number" then strobe_speed[0] = math.max(1, math.min(1000, math.floor(parsed.strobe_speed))) end
if type(parsed.strobe_mode) == "number" then strobe_mode[0] = math.max(0, math.min(18, math.floor(parsed.strobe_mode))) end
if type(parsed.turbo_cruise) == "boolean" then turbo_cruise_enabled[0] = parsed.turbo_cruise end
if type(parsed.turbo_boost_mode) == "number" then turbo_boost_mode[0] = math.max(0, math.min(2, math.floor(parsed.turbo_boost_mode))) end
if type(parsed.turbo_power) == "number" then turbo_power[0] = math.max(1, math.min(8, math.floor(parsed.turbo_power))) end
if type(parsed.turbo_max_speed) == "number" then turbo_max_speed[0] = math.max(25, math.min(90, math.floor(parsed.turbo_max_speed))) end
if type(parsed.turbo_turn_assist) == "boolean" then turbo_turn_assist[0] = parsed.turbo_turn_assist end
if type(parsed.find_ui_enabled) == "boolean" then find_ui_enabled[0] = parsed.find_ui_enabled end
if type(parsed.user_waypoints) == "table" then
    local cleaned_wp = {}
    for _, wp in ipairs(parsed.user_waypoints) do
        if type(wp) == "table" and type(wp.name) == "string" and #wp.name > 0 and #wp.name <= 64
            and not wp.name:find("%z") and type(wp.x) == "number" and type(wp.y) == "number" then
            cleaned_wp[#cleaned_wp + 1] = {
                name = wp.name,
                x = wp.x,
                y = wp.y,
                z = type(wp.z) == "number" and wp.z or 0
            }
            if #cleaned_wp >= 100 then break end
        end
    end
    user_waypoints = cleaned_wp
end
if type(parsed.hud_enabled) == "boolean" then hud_enabled[0] = parsed.hud_enabled end
if type(parsed.hud_show_cooldowns) == "boolean" then hud_show_cooldowns[0] = parsed.hud_show_cooldowns end
if type(parsed.hud_show_finance) == "boolean" then hud_show_finance[0] = parsed.hud_show_finance end
if type(parsed.finance_enabled) == "boolean" then finance_enabled[0] = parsed.finance_enabled end
if type(parsed.friends_notify) == "boolean" then friends_notify[0] = parsed.friends_notify end
if type(parsed.sound_enabled) == "boolean" then sound_enabled[0] = parsed.sound_enabled end
if type(parsed.sound_sms) == "boolean" then sound_sms[0] = parsed.sound_sms end
if type(parsed.sound_mention) == "boolean" then sound_mention[0] = parsed.sound_mention end
if type(parsed.sound_efir_call) == "boolean" then sound_efir_call[0] = parsed.sound_efir_call end
if type(parsed.sound_ad_pub) == "boolean" then sound_ad_pub[0] = parsed.sound_ad_pub end
if type(parsed.sound_friend) == "boolean" then sound_friend[0] = parsed.sound_friend end
if type(parsed.target_menu_enabled) == "boolean" then target_menu_enabled[0] = parsed.target_menu_enabled end
if type(parsed.ss_delay) == "number" then ss_delay[0] = math.max(200, math.min(2500, math.floor(parsed.ss_delay))) end
if type(parsed.check_updates_enabled) == "boolean" then check_updates_enabled[0] = parsed.check_updates_enabled end
if type(parsed.friends_list) == "table" then
    local cleaned_f = {}
    for k, v in pairs(parsed.friends_list) do
        if type(k) == "string" and #k <= 64 and type(v) == "table" and type(v.nick) == "string" and #v.nick <= 64 then
            cleaned_f[k] = { nick = v.nick, note = type(v.note) == "string" and v.note:sub(1, 128) or "" }
        end
    end
    friends_list = cleaned_f
end
if type(parsed.weather_locked) == "boolean" then weather_locked[0] = parsed.weather_locked end
if type(parsed.weather_id) == "number" then weather_id[0] = math.max(0, math.min(255, math.floor(parsed.weather_id))) end
if type(parsed.time_locked) == "boolean" then time_locked[0] = parsed.time_locked end
if type(parsed.time_hour) == "number" then time_hour[0] = math.max(0, math.min(23, math.floor(parsed.time_hour))) end
if type(parsed.aad_delay) == "number" then aad_delay[0] = math.max(3000, math.min(30000, math.floor(parsed.aad_delay))) end
if type(parsed.aad_active) == "boolean" then aad_active = parsed.aad_active end
if type(parsed.aad_text) == "string" and #parsed.aad_text <= 4096 then aad_text = parsed.aad_text end
if type(parsed.aad_templates) == "table" then
local cleaned = {}
for _, value in ipairs(parsed.aad_templates) do
if type(value) == "string" and not value:find("%z") and #value <= 4096 then cleaned[#cleaned + 1] = value end
if #cleaned >= 100 then break end
end
aad_templates = cleaned
end
if type(parsed.aad_history) == "table" then
local cleaned = {}
for _, value in ipairs(parsed.aad_history) do
if type(value) == "string" and not value:find("%z") and #value <= 4096 then cleaned[#cleaned + 1] = value end
if #cleaned >= 100 then break end
end
aad_history = cleaned
end
if type(parsed.last_called) == "table" then
local cleaned = {}
for nick, calledAt in pairs(parsed.last_called) do
if type(nick) == "string" and type(calledAt) == "number" and #nick <= 64 then cleaned[nick] = calledAt end
end
last_called = cleaned
end
if type(parsed.call_delay) == "number" then call_delay[0] = math.max(2000, math.min(15000, math.floor(parsed.call_delay))) end
if type(parsed.max_calls_session) == "number" then max_calls_session[0] = math.max(1, math.min(500, math.floor(parsed.max_calls_session))) end
if type(parsed.call_cooldown_hours) == "number" then call_cooldown_hours[0] = math.max(0, math.min(168, math.floor(parsed.call_cooldown_hours))) end
if type(parsed.call_no_repeat) == "boolean" then call_no_repeat[0] = parsed.call_no_repeat end
if type(parsed.call_skip_today) == "boolean" then call_skip_today[0] = parsed.call_skip_today end
if type(parsed.module_states) == "table" then saved_module_states = parsed.module_states end
if type(parsed.layout_fix_enabled) == "boolean" then layout_fix_enabled[0] = parsed.layout_fix_enabled end
if type(parsed.layout_fix_key) == "number" then layout_fix_key[0] = math.floor(parsed.layout_fix_key) end
if type(parsed.radio_tag_text) == "string" then
    local rOk, rEnc = pcall(function() return u8:encode(parsed.radio_tag_text, encoding.default) end)
    if rOk and type(rEnc) == "string" then safeStrCopy(radio_tag_text, rEnc, ffi.sizeof(radio_tag_text)) end
end
if type(parsed.radio_tag_r) == "boolean" then radio_tag_r[0] = parsed.radio_tag_r end
if type(parsed.radio_tag_f) == "boolean" then radio_tag_f[0] = parsed.radio_tag_f end
if type(parsed.radio_tag_d) == "boolean" then radio_tag_d[0] = parsed.radio_tag_d end
if type(parsed.radio_auto_punct) == "boolean" then radio_auto_punct[0] = parsed.radio_auto_punct end
if type(parsed.chat_filter_enabled) == "boolean" then chat_filter_enabled[0] = parsed.chat_filter_enabled end
if type(parsed.cf_hide_ads) == "boolean" then cf_hide_ads[0] = parsed.cf_hide_ads end
if type(parsed.cf_hide_efir) == "boolean" then cf_hide_efir[0] = parsed.cf_hide_efir end
if type(parsed.cf_hide_system) == "boolean" then cf_hide_system[0] = parsed.cf_hide_system end
if type(parsed.cf_ad_whitelist) == "string" then
    local wOk, wEnc = pcall(function() return u8:encode(parsed.cf_ad_whitelist, encoding.default) end)
    if wOk and type(wEnc) == "string" then safeStrCopy(cf_ad_whitelist_buf, wEnc, ffi.sizeof(cf_ad_whitelist_buf)) end
end
if type(parsed.cf_blacklist) == "string" then
    local bOk, bEnc = pcall(function() return u8:encode(parsed.cf_blacklist, encoding.default) end)
    if bOk and type(bEnc) == "string" then safeStrCopy(cf_blacklist_buf, bEnc, ffi.sizeof(cf_blacklist_buf)) end
end
if type(parsed.cf_triggers) == "string" then
    local tOk, tEnc = pcall(function() return u8:encode(parsed.cf_triggers, encoding.default) end)
    if tOk and type(tEnc) == "string" then safeStrCopy(cf_trigger_buf, tEnc, ffi.sizeof(cf_trigger_buf)) end
end
if type(parsed.line_wrap_enabled) == "boolean" then line_wrap_enabled[0] = parsed.line_wrap_enabled end
if type(parsed.line_wrap_limit) == "number" then line_wrap_limit[0] = math.max(70, math.min(122, math.floor(parsed.line_wrap_limit))) end
if type(parsed.line_wrap_delay) == "number" then line_wrap_delay[0] = math.max(350, math.min(1500, math.floor(parsed.line_wrap_delay))) end
if type(parsed.wheel_menu_enabled) == "boolean" then wheel_menu_enabled[0] = parsed.wheel_menu_enabled end
if type(parsed.wheel_menu_key_idx) == "number" then wheel_menu_key_idx[0] = math.max(0, math.min(4, math.floor(parsed.wheel_menu_key_idx))) end
if type(parsed.target_menu_key_idx) == "number" then target_menu_key_idx[0] = math.max(0, math.min(2, math.floor(parsed.target_menu_key_idx))) end
if type(parsed.target_menu_autorp) == "boolean" then target_menu_autorp[0] = parsed.target_menu_autorp end
if type(parsed.siren_auto_strobe) == "boolean" then siren_auto_strobe[0] = parsed.siren_auto_strobe end
if type(parsed.wheel_favs) == "table" then
    local cleaned_favs = {}
    for _, item in ipairs(parsed.wheel_favs) do
        if type(item) == "table" and type(item.chapter) == "number" and type(item.index) == "number" then
            local ch = math.floor(item.chapter)
            local idx = math.floor(item.index)
            if ch >= 1 and ch <= 3 and idx >= 1 and idx <= 500 then
                cleaned_favs[#cleaned_favs + 1] = { chapter = ch, index = idx }
                if #cleaned_favs >= 6 then break end
            end
        end
    end
    wheel_fav_slots = cleaned_favs
end
if type(parsed.gnews_l_template) == "string" and parsed.gnews_l_template ~= "" then
    local lEnc = encodeCp1251Safe(parsed.gnews_l_template)
    if lEnc ~= "" then safeStrCopy(gnews_l_template_buf, lEnc, ffi.sizeof(gnews_l_template_buf)) end
end
if type(parsed.lect_delay_ms) == "number" then
    lect_delay_ms[0] = math.max(800, math.min(6000, math.floor(parsed.lect_delay_ms)))
end
if type(P3_loadLecturer) == "function" then pcall(P3_loadLecturer) end
if type(parsed.p4_autorp_enabled) == "boolean" then p4_autorp_enabled[0] = parsed.p4_autorp_enabled end
if type(parsed.dmg_enabled) == "boolean" then dmg_enabled[0] = parsed.dmg_enabled end
if type(parsed.dmg_show_hud) == "boolean" then dmg_show_hud[0] = parsed.dmg_show_hud end
if type(parsed.p4_codex_server) == "number" then p4_codex_server[0] = math.max(0, math.min(3, math.floor(parsed.p4_codex_server))) end
pcall(P4_loadCodex)
if type(parsed.cam_feature_enabled) == "boolean" then cam_feature_enabled[0] = parsed.cam_feature_enabled end
if type(parsed.cam_speed) == "number" and parsed.cam_speed == parsed.cam_speed then
    cam_speed[0] = math.max(0.1, math.min(3.0, parsed.cam_speed))
end
if type(parsed.buyfast_enabled) == "boolean" then buyfast_enabled[0] = parsed.buyfast_enabled end
if type(parsed.buyfast_item_idx) == "number" and parsed.buyfast_item_idx == parsed.buyfast_item_idx then
    buyfast_item_idx[0] = math.max(0, math.min(4, math.floor(parsed.buyfast_item_idx)))
end
if type(parsed.session_track_enabled) == "boolean" then session_track_enabled[0] = parsed.session_track_enabled end
if type(parsed.loc_cat_filter) == "number" then loc_cat_filter[0] = math.max(0, math.min(7, math.floor(parsed.loc_cat_filter))) end
if type(parsed.loc_sort_mode) == "number" then loc_sort_mode[0] = math.max(0, math.min(2, math.floor(parsed.loc_sort_mode))) end
if type(parsed.loc_compact_cards) == "boolean" then loc_compact_cards[0] = parsed.loc_compact_cards end
if type(parsed.loc_use_short_cmd) == "boolean" then loc_use_short_cmd[0] = parsed.loc_use_short_cmd end
if type(parsed.loc_cache_previews) == "boolean" then loc_cache_previews[0] = parsed.loc_cache_previews end
if type(parsed.loc_cat_page) == "number" then P6.cat_page = math.max(1, math.floor(parsed.loc_cat_page)) end
if type(parsed.loc_favorites) == "table" then
    P6_loc_favorites = P6_sanitizeIdArray(parsed.loc_favorites, 522)
    P6_rebuildFavMap()
end
if type(parsed.loc_recents) == "table" then
    P6_loc_recents = P6_sanitizeIdArray(parsed.loc_recents, 30)
end
pcall(P6_loadLocations)
if type(parsed.keybinds) == "table" then
keybinds = {}
for _, kb in ipairs(parsed.keybinds) do
if type(kb) == "table" and type(kb.key) == "number" and type(kb.name) == "string" and kb.key >= 0 and kb.key <= 255 and #kb.name <= 128 then
local cmd_s = type(kb.command) == "string" and kb.command or ""
if #cmd_s <= 128 then
table.insert(keybinds, {
    key = math.floor(kb.key),
    mod = type(kb.mod) == "number" and math.max(0, math.min(3, math.floor(kb.mod))) or 0,
    action_type = (kb.action_type == "rp") and "rp" or "cmd",
    rp_chapter = type(kb.rp_chapter) == "number" and math.max(1, math.min(3, math.floor(kb.rp_chapter))) or 1,
    rp_index = type(kb.rp_index) == "number" and math.max(1, math.min(500, math.floor(kb.rp_index))) or 1,
    command = cmd_s,
    enabled = kb.enabled ~= false,
    name = kb.name
})
end
if #keybinds >= 100 then break end
end
end
if #keybinds == 0 then
keybinds = {
{key = 0x4C, command = "/lock", enabled = true, name = "Lock/Unlock"},
{key = 0x4B, command = "/e", enabled = true, name = "Engine On/Off"}
}
end
end
-- Миграция: конвертируем старые CP1251 шаблоны/историю в UTF-8
local function needsUtf8Convert(s)
    if type(s) ~= "string" then return false end
    local i = 1
    local len = #s
    while i <= len do
        local b = s:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b >= 0xC2 and b <= 0xDF then
            local b2 = s:byte(i + 1)
            if not b2 or b2 < 0x80 or b2 > 0xBF then return true end
            i = i + 2
        elseif b >= 0xE0 and b <= 0xEF then
            local b2, b3 = s:byte(i + 1), s:byte(i + 2)
            if not b2 or not b3 or b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then return true end
            i = i + 3
        elseif b >= 0xF0 and b <= 0xF4 then
            local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            if not b2 or not b3 or not b4 or b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then return true end
            i = i + 4
        else
            return true
        end
    end
    return false
end

local function migrateToUtf8(s)
    if type(s) ~= "string" then return s end
    if not needsUtf8Convert(s) then return s end
    -- s is CP1251, convert to UTF-8
    local encodeOk, encoded = pcall(function() return u8:encode(s) end)
    return encodeOk and encoded or ""
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

-- Auto-resume AAD AFTER settings are loaded
if aad_active and aad_text ~= "" then
    scheduleTask(3000, function()
        if aad_active and aad_text ~= "" and isSampAvailable() then
            sampAddChatMessage("[Helper] Авто-реклама возобновлена", 0x00FF00)
            sendAdCommand(aad_text)
        end
    end)
end
end

-- Сохранение настроек
function saveSettings()
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
table.insert(kb, {
    key = bind.key,
    mod = bind.mod or 0,
    action_type = bind.action_type or "cmd",
    rp_chapter = bind.rp_chapter or 1,
    rp_index = bind.rp_index or 1,
    command = bind.command or "",
    enabled = bind.enabled,
    name = bind.name
})
end
local settings = {
gnews = gnews_settings,
current_server = current_server_idx[0],
rp_weapons = rp_weapons_enabled[0],
rp_phone = rp_phone_enabled[0],
rp_mask = rp_mask_enabled[0],
rp_heal = rp_heal_enabled[0],
rp_engine = rp_engine_enabled[0],
rp_docs = rp_docs_enabled[0],
rp_gender = rp_gender[0],
mm_auto_format = mm_auto_format[0],
mm_auto_send = mm_auto_send[0],
mm_send_delay = mm_send_delay[0],
mm_tag = decodeUtf8Safe(ffi.string(mm_tag)),
strobe_speed = strobe_speed[0],
strobe_mode = strobe_mode[0],
turbo_cruise = turbo_cruise_enabled[0],
turbo_boost_mode = turbo_boost_mode[0],
turbo_power = turbo_power[0],
turbo_max_speed = turbo_max_speed[0],
turbo_turn_assist = turbo_turn_assist[0],
find_ui_enabled = find_ui_enabled[0],
user_waypoints = user_waypoints,
hud_enabled = hud_enabled[0],
hud_show_cooldowns = hud_show_cooldowns[0],
hud_show_finance = hud_show_finance[0],
finance_enabled = finance_enabled[0],
friends_notify = friends_notify[0],
friends_list = friends_list,
sound_enabled = sound_enabled[0],
sound_sms = sound_sms[0],
sound_mention = sound_mention[0],
sound_efir_call = sound_efir_call[0],
sound_ad_pub = sound_ad_pub[0],
sound_friend = sound_friend[0],
target_menu_enabled = target_menu_enabled[0],
ss_delay = ss_delay[0],
check_updates_enabled = check_updates_enabled[0],
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
call_delay = call_delay[0],
max_calls_session = max_calls_session[0],
call_cooldown_hours = call_cooldown_hours[0],
call_no_repeat = call_no_repeat[0],
call_skip_today = call_skip_today[0],
layout_fix_enabled = layout_fix_enabled[0],
layout_fix_key = layout_fix_key[0],
radio_tag_text = decodeUtf8Safe(ffi.string(radio_tag_text)),
radio_tag_r = radio_tag_r[0],
radio_tag_f = radio_tag_f[0],
radio_tag_d = radio_tag_d[0],
radio_auto_punct = radio_auto_punct[0],
chat_filter_enabled = chat_filter_enabled[0],
cf_hide_ads = cf_hide_ads[0],
cf_hide_efir = cf_hide_efir[0],
cf_hide_system = cf_hide_system[0],
cf_ad_whitelist = decodeUtf8Safe(ffi.string(cf_ad_whitelist_buf)),
cf_blacklist = decodeUtf8Safe(ffi.string(cf_blacklist_buf)),
cf_triggers = decodeUtf8Safe(ffi.string(cf_trigger_buf)),
line_wrap_enabled = line_wrap_enabled[0],
line_wrap_limit = line_wrap_limit[0],
line_wrap_delay = line_wrap_delay[0],
wheel_menu_enabled = wheel_menu_enabled[0],
wheel_menu_key_idx = wheel_menu_key_idx[0],
target_menu_key_idx = target_menu_key_idx[0],
target_menu_autorp = target_menu_autorp[0],
siren_auto_strobe = siren_auto_strobe[0],
wheel_favs = wheel_fav_slots,
gnews_l_template = decodeUtf8Safe(ffi.string(gnews_l_template_buf)),
lect_delay_ms = lect_delay_ms[0],
p4_autorp_enabled = p4_autorp_enabled[0],
dmg_enabled = dmg_enabled[0],
dmg_show_hud = dmg_show_hud[0],
p4_codex_server = p4_codex_server[0],
cam_feature_enabled = cam_feature_enabled[0],
cam_speed = cam_speed[0],
buyfast_enabled = buyfast_enabled[0],
buyfast_item_idx = buyfast_item_idx[0],
session_track_enabled = session_track_enabled[0],
loc_cat_filter = loc_cat_filter[0],
loc_sort_mode = loc_sort_mode[0],
loc_compact_cards = loc_compact_cards[0],
loc_use_short_cmd = loc_use_short_cmd[0],
loc_cache_previews = loc_cache_previews[0],
loc_cat_page = P6.cat_page or 1,
loc_favorites = P6_loc_favorites,
loc_recents = P6_loc_recents,
keybinds = kb,
module_states = module_states
}
local ok, err = writeJsonAtomic(settings_path, settings)
if not ok then print("[helper_core] saveSettings error: " .. tostring(err)) end
end

function saveDatabase()
local ok, err = writeJsonAtomic(db_path, player_db)
if not ok then print("[helper_core] saveDatabase error: " .. tostring(err)) end
end

function saveRules()
local ok, err = writeJsonAtomic(rules_path, mm_rules)
if not ok then print("[helper_core] saveRules error: " .. tostring(err)) end
end

-- Умное форматирование ПРО
en_to_ru_map = {
    ["q"]="й", ["w"]="ц", ["e"]="у", ["r"]="к", ["t"]="е", ["y"]="н", ["u"]="г", ["i"]="ш", ["o"]="щ", ["p"]="з", ["["]="х", ["]"]="ъ",
    ["a"]="ф", ["s"]="ы", ["d"]="в", ["f"]="а", ["g"]="п", ["h"]="р", ["j"]="о", ["k"]="л", ["l"]="д", [";"]="ж", ["'"]="э",
    ["z"]="я", ["x"]="ч", ["c"]="с", ["v"]="м", ["b"]="и", ["n"]="т", ["m"]="ь", [","]="б", ["."]="ю", ["`"]="ё",
    ["Q"]="Й", ["W"]="Ц", ["E"]="У", ["R"]="К", ["T"]="Е", ["Y"]="Н", ["U"]="Г", ["I"]="Ш", ["O"]="Щ", ["P"]="З", ["{"]="Х", ["}"]="Ъ",
    ["A"]="Ф", ["S"]="Ы", ["D"]="В", ["F"]="А", ["G"]="П", ["H"]="Р", ["J"]="О", ["K"]="Л", ["L"]="Д", [":"]="Ж", ['"']="Э",
    ["Z"]="Я", ["X"]="Ч", ["C"]="С", ["V"]="М", ["B"]="И", ["N"]="Т", ["M"]="Ь", ["<"]="Б", [">"]="Ю", ["~"]="Ё",
}
ru_to_en_map = {}
for k, v in pairs(en_to_ru_map) do
    ru_to_en_map[v] = k
end
layout_punct_end = { [","]=true, ["."]=true, [":"]=true, ['"']=true }
layout_cmd_skip_arg = { sms=true, c=true, call=true, w=true, pay=true, id=true, pass=true, lic=true, med=true }

function convertLayoutText(str)
    if type(str) ~= "string" or str == "" then return str end
    local prefix = ""
    local body = str
    local cmd_m, rest_m = str:match("^(/%S+)%s*(.*)$")
    if cmd_m then
        prefix = cmd_m
        body = rest_m or ""
        local cmd_low = cmd_m:sub(2):lower()
        if layout_cmd_skip_arg[cmd_low] and body ~= "" then
            local arg1, tail = body:match("^(%S+)(.*)$")
            if arg1 and (arg1:match("^%d+$") or arg1:find("_", 1, true)) then
                prefix = prefix .. " " .. arg1
                body = tail:gsub("^%s+", "")
            end
        end
        if body ~= "" then prefix = prefix .. " " end
    end
    if body == "" then return str end

    local lat_cnt, cyr_cnt = 0, 0
    for i = 1, #body do
        local b = body:byte(i)
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
            lat_cnt = lat_cnt + 1
        elseif b == 168 or b == 184 or (b >= 192 and b <= 255) then
            cyr_cnt = cyr_cnt + 1
        end
    end
    local to_en = (cyr_cnt > lat_cnt)

    local out = {}
    local i = 1
    local len = #body
    while i <= len do
        local ch = body:sub(i, i)
        if ch:match("%s") then
            out[#out + 1] = ch
            i = i + 1
        else
            local j = i
            while j <= len and not body:sub(j, j):match("%s") do
                j = j + 1
            end
            local tok = body:sub(i, j - 1)
            if tok:find("_", 1, true) or tok:match("^https?://") then
                out[#out + 1] = tok
            elseif to_en then
                local parts = {}
                for k = 1, #tok do
                    local c = tok:sub(k, k)
                    parts[#parts + 1] = ru_to_en_map[c] or c
                end
                out[#out + 1] = table.concat(parts)
            else
                -- EN -> RU: keep trailing sentence punctuation if token has no internal mapped punctuation
                local has_internal_punct = false
                for k = 1, #tok - 1 do
                    if layout_punct_end[tok:sub(k, k)] then
                        has_internal_punct = true
                        break
                    end
                end
                local parts = {}
                for k = 1, #tok do
                    local c = tok:sub(k, k)
                    if k == #tok and layout_punct_end[c] and not has_internal_punct then
                        parts[#parts + 1] = c
                    else
                        parts[#parts + 1] = en_to_ru_map[c] or c
                    end
                end
                out[#out + 1] = table.concat(parts)
            end
            i = j
        end
    end
    return prefix .. table.concat(out)
end

function cp1251_upper(ch)
local b = ch:byte()
if b >= 97 and b <= 122 then return string.char(b - 32) end
if b >= 224 and b <= 255 then return string.char(b - 32) end
if b == 184 then return string.char(168) end
return ch
end

function cp1251_lower(value)
return (value:gsub(".", function(ch)
local b = ch:byte()
if b >= 65 and b <= 90 then return string.char(b + 32) end
if b >= 192 and b <= 223 then return string.char(b + 32) end
if b == 168 then return string.char(184) end
return ch
end))
end

function sanitizeAndDedupeRules(list)
    if type(list) ~= "table" then return {}, false end
    local bad_pairs = {
        ["полиция"] = {["LVPD"] = true},
        ["полицейские"] = {["LVPD"] = true},
        ["аренда"] = {["аренда эксклюзивных авто"] = true},
        ["банка"] = {['а/м марки "Banshee"'] = true},
        ["банку"] = {['а/м марки "Banshee"'] = true},
        ["склад"] = {["хранение аксессуаров"] = true},
        ["ресторан"] = {["закусочная"] = true},
        ["баллы"] = {["Ballas"] = true},
        ["русская"] = {["русская мафия"] = true},
        ["одежда"] = {["магазин одежды"] = true},
        ["одежды"] = {["магазин одежды"] = true},
        ["аптеки"] = {["аптечку"] = true},
        ["ангел"] = {["Angel Pine"] = true},
        ["сток"] = {['а/м марки "Stock"'] = true},
        ["ккк"] = {[".000.000$"] = true},
    }
    local out = {}
    local seen = {}
    local changed = false
    for _, rule in ipairs(list) do
        if type(rule) == "table" and type(rule.abbreviation) == "string" and type(rule.replacement) == "string" then
            local a = rule.abbreviation
            local r = rule.replacement
            local al = cp1251_lower(a)
            local is_synth = al:find("[\184\224-\255][\184\224-\255]+[23]$") ~= nil
            local is_noop = (a == r)
            local is_bad = bad_pairs[al] and bad_pairs[al][r] == true
            if is_synth or is_noop or is_bad or seen[al] then
                changed = true
            else
                seen[al] = true
                out[#out + 1] = {abbreviation = a, replacement = r}
            end
        else
            changed = true
        end
    end
    if not seen["дог"] then
        out[#out + 1] = {abbreviation = "дог", replacement = "договорная"}
        changed = true
    end
    return out, changed
end

function getFilteredRuleIndices(query)
query = cp1251_lower(query or "")
if mm_rule_filter_cache.query == query and mm_rule_filter_cache.revision == mm_rule_revision and mm_rule_filter_cache.count == #mm_rules then
return mm_rule_filter_cache.indices
end
local indices = {}
for idx, rule in ipairs(mm_rules) do
if type(rule) == "table" and type(rule.abbreviation) == "string" and type(rule.replacement) == "string" then
local abbreviation = cp1251_lower(rule.abbreviation)
local replacement = cp1251_lower(rule.replacement)
if query == "" or abbreviation:find(query, 1, true) or replacement:find(query, 1, true) then
indices[#indices + 1] = idx
end
end
end
mm_rule_filter_cache = {query = query, revision = mm_rule_revision, count = #mm_rules, indices = indices}
return indices
end

-- Escape special Lua pattern characters in a string
function escapePattern(s)
    return (s:gsub("([%%%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

-- Truncate UTF-8 string at a valid character boundary (prevents invalid UTF-8 crash)
function safeUtf8Truncate(s, maxBytes)
    if #s <= maxBytes then return s end
    local cut = maxBytes
    -- Scan backwards to find a valid UTF-8 boundary
    -- Continuation bytes are 0x80-0xBF (10xxxxxx)
    cut = utf8SafePrefixLength(s, cut)
    return s:sub(1, cut) .. "..."
end

-- Remove invalid UTF-8 sequences from a string (prevents ImGui glyph crash)
function sanitizeUtf8(s)
    if s == nil then return "" end
    local result = {}
    local i = 1
    local len = #s
    while i <= len do
        local b = s:byte(i)
        if b < 0x80 then
            -- ASCII byte
            result[#result + 1] = s:sub(i, i)
            i = i + 1
        elseif b >= 0xC2 and b <= 0xDF then
            -- 2-byte sequence: need 1 continuation byte
            if i + 1 <= len then
                local b2 = s:byte(i + 1)
                if b2 >= 0x80 and b2 <= 0xBF then
                    result[#result + 1] = s:sub(i, i + 1)
                    i = i + 2
                else
                    i = i + 1 -- skip invalid
                end
            else
                i = i + 1 -- incomplete, skip
            end
        elseif b >= 0xE0 and b <= 0xEF then
            -- 3-byte sequence: need 2 continuation bytes
            if i + 2 <= len then
                local b2 = s:byte(i + 1)
                local b3 = s:byte(i + 2)
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                    result[#result + 1] = s:sub(i, i + 2)
                    i = i + 3
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        elseif b >= 0xF0 and b <= 0xF4 then
            -- 4-byte sequence: need 3 continuation bytes
            if i + 3 <= len then
                local b2 = s:byte(i + 1)
                local b3 = s:byte(i + 2)
                local b4 = s:byte(i + 3)
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
                    result[#result + 1] = s:sub(i, i + 3)
                    i = i + 4
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        else
            -- Invalid lead byte (0x80-0xBF continuation without lead, or 0xF5-0xFF)
            i = i + 1
        end
    end
    return table.concat(result)
end

function encodeCp1251Safe(value)
    local source = type(value) == "string" and value or tostring(value or "")
    source = source:gsub("%z", "")
    local ok, result = pcall(function() return u8:encode(source, encoding.default) end)
    if not ok or type(result) ~= "string" then return "" end
    return sanitizeUtf8(result)
end

function decodeUtf8Safe(value)
    local source = sanitizeUtf8(type(value) == "string" and value or tostring(value or ""))
    local ok, result = pcall(function() return u8:decode(source) end)
    if not ok or type(result) ~= "string" then return "" end
    return result:gsub("%z", "")
end

mm_rule_index = {revision = -1, count = -1, exact = {}, base_map = {}, multi_by_first = {}}

local function isWordByte(b)
    if not b then return false end
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
        or b == 95 or b == 47 or b == 168 or b == 184 or (b >= 192 and b <= 255)
end

local function tokenizeAd(s)
    local tokens = {}
    local len = #s
    local i = 1
    while i <= len do
        local b = s:byte(i)
        if isWordByte(b) then
            local j = i + 1
            while j <= len do
                local nb = s:byte(j)
                if isWordByte(nb) or (nb == 45 and j < len and isWordByte(s:byte(j - 1)) and isWordByte(s:byte(j + 1))) then
                    j = j + 1
                else
                    break
                end
            end
            local tok = s:sub(i, j - 1)
            tokens[#tokens + 1] = {is_word = true, text = tok, lower = cp1251_lower(tok)}
            i = j
        else
            local j = i + 1
            while j <= len and not isWordByte(s:byte(j)) do
                j = j + 1
            end
            tokens[#tokens + 1] = {is_word = false, text = s:sub(i, j - 1)}
            i = j
        end
    end
    return tokens
end

local function splitWordsLower(s)
    local words = {}
    local tokens = tokenizeAd(s)
    for _, tok in ipairs(tokens) do
        if tok.is_word then
            words[#words + 1] = tok.lower
        end
    end
    return words
end

local function buildRuleIndex()
    if mm_rule_index.revision == mm_rule_revision and mm_rule_index.count == #mm_rules then
        return mm_rule_index
    end
    local exact = {}
    local base_map = {}
    local multi_by_first = {}
    local vowel_bytes = {[224]=true, [243]=true, [229]=true, [251]=true, [232]=true, [255]=true, [254]=true}

    for _, rule in ipairs(mm_rules) do
        if type(rule) == "table" and type(rule.abbreviation) == "string" and type(rule.replacement) == "string" and rule.abbreviation ~= "" then
            local words = splitWordsLower(rule.abbreviation)
            if #words == 1 then
                local w = words[1]
                exact[w] = rule.replacement
                if #w >= 5 and vowel_bytes[w:byte(#w)] then
                    local stem = w:sub(1, -2)
                    if #stem >= 4 and not base_map[stem] then
                        base_map[stem] = rule.replacement
                    end
                end
            elseif #words >= 2 then
                local first = words[1]
                multi_by_first[first] = multi_by_first[first] or {}
                multi_by_first[first][#multi_by_first[first] + 1] = {words = words, repl = rule.replacement}
            end
        end
    end

    for _, list in pairs(multi_by_first) do
        table.sort(list, function(a, b) return #a.words > #b.words end)
    end

    mm_rule_index = {
        revision = mm_rule_revision,
        count = #mm_rules,
        exact = exact,
        base_map = base_map,
        multi_by_first = multi_by_first,
    }
    return mm_rule_index
end

ru_endings = {"ой", "ей", "ом", "ем", "ам", "ям", "ах", "ях", "ов", "ев", "а", "у", "е", "ы", "и", "о", "я", "ю"}

local function applyRulesSinglePass(text)
    local idx = buildRuleIndex()
    local tokens = tokenizeAd(text)
    local out = {}
    local i = 1
    local n = #tokens

    while i <= n do
        local tok = tokens[i]
        if not tok.is_word then
            out[#out + 1] = tok.text
            i = i + 1
        else
            local matched_multi = nil
            local matched_end_i = nil
            local mlist = idx.multi_by_first[tok.lower]
            if mlist then
                for _, entry in ipairs(mlist) do
                    local wcount = #entry.words
                    local ti = i
                    local ok = true
                    for wi = 2, wcount do
                        local sep = tokens[ti + 1]
                        local nxt = tokens[ti + 2]
                        if not sep or sep.is_word or not sep.text:match("^%s+$") or not nxt or not nxt.is_word or nxt.lower ~= entry.words[wi] then
                            ok = false
                            break
                        end
                        ti = ti + 2
                    end
                    if ok then
                        matched_multi = entry.repl
                        matched_end_i = ti
                        break
                    end
                end
            end

            if matched_multi then
                out[#out + 1] = matched_multi
                i = matched_end_i + 1
            elseif idx.exact[tok.lower] then
                out[#out + 1] = idx.exact[tok.lower]
                i = i + 1
            elseif #tok.lower >= 5 then
                local w = tok.lower
                local stem_repl = nil
                for _, suf in ipairs(ru_endings) do
                    local slen = #suf
                    if #w - slen >= 4 and w:sub(#w - slen + 1) == suf then
                        local base = w:sub(1, #w - slen)
                        stem_repl = idx.exact[base] or idx.base_map[base]
                        if stem_repl then break end
                    end
                end
                out[#out + 1] = stem_repl or tok.text
                i = i + 1
            else
                out[#out + 1] = tok.text
                i = i + 1
            end
        end
    end

    return table.concat(out)
end

local function formatNumberWithDots(num)
    local n = math.floor((tonumber(num) or 0) + 0.5)
    local s = string.format("%.0f", n)
    while true do
        local next_s, count = s:gsub("^(%-?%d+)(%d%d%d)", "%1.%2")
        s = next_s
        if count == 0 then break end
    end
    return s
end

slang_money_units = {
    ["ккк"] = 1000000000, ["kkk"] = 1000000000, ["ккk"] = 1000000000, ["кkк"] = 1000000000, ["kкк"] = 1000000000,
    ["млрд"] = 1000000000, ["mlrd"] = 1000000000, ["миллиард"] = 1000000000, ["миллиарда"] = 1000000000, ["миллиардов"] = 1000000000,
    ["кк"] = 1000000, ["kk"] = 1000000, ["кk"] = 1000000, ["kк"] = 1000000,
    ["млн"] = 1000000, ["mln"] = 1000000, ["миллион"] = 1000000, ["миллиона"] = 1000000, ["миллионов"] = 1000000,
    ["к"] = 1000, ["k"] = 1000, ["тыс"] = 1000, ["tys"] = 1000,
}

local function replaceAllSlangMoney(str)
    local pat = "([^A-Za-z0-9_\168\184\192-\255])(%d+[%.%,]?%d*)(%s*)([A-Za-z\168\184\192-\255]+)([^A-Za-z0-9_\168\184\192-\255])"
    local out = {}
    local pos = 1
    while true do
        local s_i, e_i, pre, numStr, sp, unit, post = str:find(pat, pos)
        if not s_i then
            out[#out + 1] = str:sub(pos)
            break
        end
        out[#out + 1] = str:sub(pos, s_i - 1)
        local mult = slang_money_units[cp1251_lower(unit)]
        local val = mult and tonumber((numStr:gsub(",", "."))) or nil
        if mult and val then
            out[#out + 1] = pre .. formatNumberWithDots(val * mult) .. "$"
        else
            out[#out + 1] = pre .. numStr .. sp .. unit
        end
        pos = e_i
    end
    return table.concat(out)
end

ae_prep_fix_map = {
    ["у"]      = {["мэрию"]="мэрии", ["полицию"]="полиции", ["больницу"]="больницы", ["школу"]="школы", ["церковь"]="церкви", ["электростанцию"]="электростанции", ["банк"]="банка", ["стадион"]="стадиона"},
    ["возле"]  = {["мэрию"]="мэрии", ["полицию"]="полиции", ["больницу"]="больницы", ["школу"]="школы", ["церковь"]="церкви", ["электростанцию"]="электростанции", ["банк"]="банка", ["стадион"]="стадиона"},
    ["около"]  = {["мэрию"]="мэрии", ["полицию"]="полиции", ["больницу"]="больницы", ["школу"]="школы", ["церковь"]="церкви", ["электростанцию"]="электростанции", ["банк"]="банка", ["стадион"]="стадиона"},
    ["от"]     = {["мэрию"]="мэрии", ["полицию"]="полиции", ["больницу"]="больницы", ["школу"]="школы", ["церковь"]="церкви", ["электростанцию"]="электростанции", ["банк"]="банка", ["стадион"]="стадиона"},
    ["из"]     = {["мэрию"]="мэрии", ["полицию"]="полиции", ["больницу"]="больницы", ["школу"]="школы", ["церковь"]="церкви", ["электростанцию"]="электростанции", ["банк"]="банка", ["стадион"]="стадиона"},
    ["к"]      = {["мэрию"]="мэрии", ["полицию"]="полиции", ["больницу"]="больнице", ["школу"]="школе", ["церковь"]="церкви", ["электростанцию"]="электростанции", ["банк"]="банку", ["стадион"]="стадиону"},
    ["за"]     = {["мэрию"]="мэрией", ["полицию"]="полицией", ["больницу"]="больницей", ["школу"]="школой", ["церковь"]="церковью", ["электростанцию"]="электростанцией", ["банк"]="банком", ["стадион"]="стадионом"},
    ["под"]    = {["мэрию"]="мэрией", ["полицию"]="полицией", ["больницу"]="больницей", ["школу"]="школой", ["церковь"]="церковью", ["электростанцию"]="электростанцией", ["банк"]="банком", ["стадион"]="стадионом"},
    ["над"]    = {["мэрию"]="мэрией", ["полицию"]="полицией", ["больницу"]="больницей", ["школу"]="школой", ["церковь"]="церковью", ["электростанцию"]="электростанцией", ["банк"]="банком", ["стадион"]="стадионом"},
    ["перед"]  = {["мэрию"]="мэрией", ["полицию"]="полицией", ["больницу"]="больницей", ["школу"]="школой", ["церковь"]="церковью", ["электростанцию"]="электростанцией", ["банк"]="банком", ["стадион"]="стадионом"},
    ["в"]      = {["мэрию"]="мэрии", ["полицию"]="полиции", ["больницу"]="больнице", ["школу"]="школе", ["церковь"]="церкви", ["электростанцию"]="электростанции", ["банк"]="банке", ["стадион"]="стадионе"},
    ["на"]     = {["мэрию"]="мэрии", ["полицию"]="полиции", ["больницу"]="больнице", ["школу"]="школе", ["церковь"]="церкви", ["электростанцию"]="электростанции", ["банк"]="банке", ["стадион"]="стадионе"},
}

ae_car_keywords = {"булк", "инф", "туризм", "турик", "кловер", "хоткнайф", "дюн", "сультан", "султан", "елег", "элеги", "банш", "чито", "чит", "феникс", "тахом", "премьер", "стретч", "бравур", "сабре", "вуду", "сламван", "ремингтон", "флеш", "джестер", "стратум", "уран", "блист", "баффал", "зомби", "ламбо", "бмв", "мерс", "тойот", "монстр", "бандит", "комет", "стингер", "супергт", "манан", "пикап", "соляр", "винсаг", "шафтер", "альпин", "беггал", "кальц", "салат", "стрикер", "адреналин", "нрг", "фрей", "вейб", "санч", "пжж", "фцз", "фаггио", "фагио", "бмх", "эндюро", "мото", "машин", "а/м", "м/ц", "тачк", "таз", "байк", "велосипед", "велик", "лодк", "яхт", "самол", "вертол", "грузовик", "тягач"}
ae_realestate_keywords = {"дом", "жиль", "квартир", "особняк", "вилл", "времянк", "бизнес", "азс", "магазин", "отель", "казино", "бар", "закусочн", "столов", "ресторан", "кафе", "аптек", "гараж", "ферм", "клуб", "зал", "парковк", "салон", "предприят", "склад", "шахт", "завод", "производств"}
ae_loc_words = {"los santos", "san fierro", "las venturas", "east", "ganton", "idlewood", "jefferson", "glen", "willowfield", "el corona", "commerce", "market", "verona", "chinatown", "palomino", "montgomery", "dillimore", "blueberry", "flint", "fort carson", "tierra", "angel", "bayside", "north rock", "valle", "arco", "green palms", "union", "strip", "rockshore", "pilgrim", "avalon", "prickle", "whitewood", "pilbox", "doherty", "kings", "paradiso", "queens", "hashbury", "garcia", "santa flora", "foster", "venturas", "штат", "город", "район", "гетто"}

function formatAdText(text)
    local formatted = type(text) == "string" and text or ""

    -- Strip SAMP color codes and trim
    formatted = formatted:gsub("{%x+}", "")
    formatted = formatted:gsub("^%s+", ""):gsub("%s+$", "")
    if formatted == "" then return "" end

    -- Extract tag prefix only if <= 12 bytes and no spaces (avoids corrupting ads with "|" in body)
    local detected_tag = nil
    local tag_match = formatted:match("^%s*([A-Za-z%d_%-\168\184\192-\255]+)%s*|%s*")
    if tag_match and #tag_match <= 12 then
        detected_tag = tag_match
        formatted = formatted:gsub("^%s*[A-Za-z%d_%-\168\184\192-\255]+%s*|%s*", "", 1)
    end

    local lower = cp1251_lower(formatted)

    -- Convert slang money amounts (case-insensitive, word-boundary safe)
    formatted = " " .. formatted .. " "
    formatted = replaceAllSlangMoney(formatted)
    formatted = formatted:sub(2, -2)

    -- Single-pass tokenized rules replacement (prevents cascading corruption)
    formatted = applyRulesSinglePass(formatted)
    if #formatted > 1000 then formatted = formatted:sub(1, 1000) end

    -- Normalize case-insensitive Russian prepositions + nouns
    formatted = " " .. formatted .. " "
    for _ = 1, 2 do
        formatted = formatted:gsub("(%s)([^%s%,%.]+)%s+([^%s%,%.]+)([%s%,%.])", function(sp, prep, word, tail)
            local pmap = ae_prep_fix_map[cp1251_lower(prep)]
            if pmap then
                local repl = pmap[cp1251_lower(word)]
                if repl then
                    return sp .. prep .. " " .. repl .. tail
                end
            end
            return sp .. prep .. " " .. word .. tail
        end)
    end
    formatted = formatted:gsub("^%s+", ""):gsub("%s+$", "")

    -- Normalize leading ALL-CAPS action verb
    local action_verbs = {
        ["продам"] = "Продам",
        ["куплю"] = "Куплю",
        ["обменяю"] = "Обменяю",
        ["сдам"] = "Сдам",
        ["сниму"] = "Сниму",
    }
    local first_word = formatted:match("^(%S+)")
    if first_word then
        local norm_verb = action_verbs[cp1251_lower(first_word)]
        if norm_verb then
            formatted = norm_verb .. formatted:sub(#first_word + 1)
        end
    end

    -- Detect intent and item categories on both original and formatted text
    local fmt_lower = cp1251_lower(formatted)
    local is_buy = lower:find("^куплю") ~= nil or fmt_lower:find("^куплю") ~= nil
    local is_sell = lower:find("^продам") ~= nil or fmt_lower:find("^продам") ~= nil
    local is_trade = lower:find("^обменяю") ~= nil or fmt_lower:find("^обменяю") ~= nil
    local is_rent_out = lower:find("^сдам") ~= nil or fmt_lower:find("^сдам") ~= nil
    local is_rent_seek = lower:find("^сниму") ~= nil or fmt_lower:find("^сниму") ~= nil

    local is_car = false
    for _, word in ipairs(ae_car_keywords) do
        if lower:find(word, 1, true) or fmt_lower:find(word, 1, true) then
            is_car = true
            break
        end
    end

    local is_realestate = false
    for _, word in ipairs(ae_realestate_keywords) do
        if lower:find(word, 1, true) or fmt_lower:find(word, 1, true) then
            is_realestate = true
            break
        end
    end

    local has_location = false
    for _, word in ipairs(ae_loc_words) do
        if fmt_lower:find(word, 1, true) then
            has_location = true
            break
        end
    end

    -- Clean up whitespace before structural punctuation rules
    formatted = formatted:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    -- Add "в любой точке штата" ONLY for real estate buy/rent-seek without location
    if (is_buy or is_rent_seek) and is_realestate and not is_car and not has_location then
        local b_pos = cp1251_lower(formatted):find("%s+бюджет[%s:%.,]")
        if not b_pos then
            b_pos = cp1251_lower(formatted):find("%s+бюджет$")
        end
        if b_pos then
            formatted = formatted:sub(1, b_pos - 1) .. " в любой точке штата" .. formatted:sub(b_pos)
        else
            formatted = formatted .. " в любой точке штата"
        end
    end

    -- Insert period before "бюджет" and capitalize consistently
    formatted = formatted:gsub("([^%.%!%?%s])%s+[Бб][Юю][Дд][Жж][Ее][Тт]([%s:%.,])", "%1. Бюджет%2")
    formatted = formatted:gsub("([^%.%!%?%s])%s+[Бб][Юю][Дд][Жж][Ее][Тт]$", "%1. Бюджет")
    formatted = formatted:gsub("([%.%!%?])%s+[Бб][Юю][Дд][Жж][Ее][Тт]([%s:%.,])", "%1 Бюджет%2")
    formatted = formatted:gsub("^(%s*)[Бб][Юю][Дд][Жж][Ее][Тт]([%s:%.,])", "%1Бюджет%2")

    -- Normalize "договорная" / "цена договорная"
    formatted = formatted:gsub("([^%.%!%?%s])%s+[Цц][Ее][Нн][Аа]%s+[Дд][Оо][Гг][Оо][Вв][Оо][Рр][Нн][Аа][Яя]([%s%.%,]*)$", "%1. Цена договорная")
    formatted = formatted:gsub("(%S+)%s+[Дд][Оо][Гг][Оо][Вв][Оо][Рр][Нн][Аа][Яя]([%s%.%,]*)$", function(prev, tail)
        local pl = cp1251_lower(prev)
        if pl == "цена" or pl == "цена:" then
            return prev .. " договорная"
        elseif prev:sub(-1) == "." then
            return prev .. " Цена договорная"
        end
        return prev .. ". Цена договорная"
    end)

    -- Add "Цена " before bare dollar amount (unless preceded by цена/бюджет/доплата/от/до)
    formatted = " " .. formatted
    formatted = formatted:gsub("(%S*)%s+(%d[%d%.]*%$)", function(prev_raw, amt)
        local pw = cp1251_lower(prev_raw)
        if pw == "" then
            return " Цена " .. amt
        elseif pw == "цена" or pw == "цена:" or pw == "бюджет" or pw == "бюджет:" or pw == "доплата" or pw == "от" or pw == "до" then
            return prev_raw .. " " .. amt
        elseif prev_raw:sub(-1) == "." then
            return prev_raw .. " Цена " .. amt
        else
            return prev_raw .. ". Цена " .. amt
        end
    end)
    formatted = formatted:gsub("^%s+", "")
    formatted = formatted:gsub("([^%.%!%?%s])%s+[Цц][Ее][Нн][Аа]%s+(%d[%d%.]*%$)", "%1. Цена %2")
    formatted = formatted:gsub("([%.%!%?])%s+[Цц][Ее][Нн][Аа]([%s:%.,])", "%1 Цена%2")

    -- Check if ad already specifies price
    local fl = cp1251_lower(formatted)
    local has_price = fl:find("%$") or fl:find("цена") or fl:find("дог") or fl:find("торг") or fl:find("обмен") or fl:find("бартер") or fl:find("бесплатн") or fl:find("бюджет")
    if (is_buy or is_sell or is_rent_out or is_rent_seek) and not has_price then
        formatted = formatted .. ". Цена договорная"
    end

    -- Trade surcharge normalization
    if is_trade and fl:find("доплат") and not (fl:find("доплата с мо") or fl:find("доплата с ваш")) then
        local doplata_mine = fl:find("мо[йяеиёю]") or fl:find("мен[яе]") or fl:find("доплачива")
        local doplata_theirs = fl:find("ваш") or fl:find("вас")
        if doplata_theirs and not doplata_mine then
            formatted = formatted .. ". Доплата с вашей стороны"
        elseif doplata_mine and not doplata_theirs then
            formatted = formatted .. ". Доплата с моей стороны"
        end
    end

    -- Cleanup periods and spacing
    formatted = formatted:gsub("%.+", ".")
    formatted = formatted:gsub("%. %.", ".")
    formatted = formatted:gsub("%s+%.", ".")
    formatted = formatted:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    -- Add server tag prefix
    local tag = detected_tag or decodeUtf8Safe(ffi.string(mm_tag))
    if tag and tag ~= "" then
        formatted = tag .. " | " .. formatted
    end

    -- Capitalize first letter after "TAG | "
    local pipe_pos = formatted:find(" | ", 1, true)
    if pipe_pos then
        local after_pipe = pipe_pos + 3
        if after_pipe <= #formatted then
            formatted = formatted:sub(1, after_pipe - 1) .. cp1251_upper(formatted:sub(after_pipe, after_pipe)) .. formatted:sub(after_pipe + 1)
        end
    elseif #formatted > 0 then
        formatted = cp1251_upper(formatted:sub(1, 1)) .. formatted:sub(2)
    end

    -- Trim to SAMP /edit limit while keeping whole words
    local MAX_AD_LEN = 128
    if #formatted > MAX_AD_LEN then
        formatted = formatted:gsub("%. Цена договорная$", "")
        formatted = formatted:gsub(" в любой точке штата%.?", "")
        if #formatted > MAX_AD_LEN then
            local tag_part = ""
            local body = formatted
            local pp = formatted:find(" | ", 1, true)
            if pp then
                tag_part = formatted:sub(1, pp + 2)
                body = formatted:sub(pp + 3)
            end
            local max_body = MAX_AD_LEN - #tag_part
            if max_body > 0 and #body > max_body then
                local cut = body:sub(1, max_body)
                local trimmed = cut:match("^(.*)%s+%S*$")
                if trimmed and #trimmed > 0 then
                    body = trimmed
                else
                    body = cut
                end
                formatted = tag_part .. body
            end
        end
    end

    return formatted
end

-- Проверка онлайна (Встроенными методами)
function isPlayerOnline(nickname)
-- Use cache for safety (render thread safe)
return isOnlineCached(nickname)
end

-- Сбор онлайн игроков
function getOnlinePlayersFromDb()
local online_list = {}
for nick, data in pairs(player_db) do
if isOnlineCached(nick) then
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

-- ===== РП-ДВИЖОК: КАСТОМНЫЕ ОТЫГРОВКИ =====

-- Данные игрока (заполняются playerLogin)
user = {
    nick = "", fullName = "", name = "", family = "",
    rang = 0, rangName = "", podr = "", podrNum = 0,
    phone = "", id = -1, isWork = false
}

-- Данные цели (для /mmact)
userTarget = { id = -1, nick = "", name = "" }

-- Настройки РП-отыгровок
rp_settings = {
    active = imgui.new.bool(false),
    wait = false,
    selected = 1,
    setList = imgui.new.int(0),
    -- Главы: [1]=общие, [2]=мои, [3]=для цели
    set = { [1] = {}, [2] = {}, [3] = {} },
    -- Окно ввода/выбора
    window = {
        type = 0, list = {},
        buf = imgui.new.char[257](""),
        select = 0, is = -1,
    },
    -- Редактирование
    temp = {
        name = imgui.new.char[65](""),
        text = imgui.new.char[16385](""),
        cmd = imgui.new.char[33](""),
    },
}

-- Теги для отыгровок
rp_tegs = {
    {   -- Общие теги
        {'<time>', function() return os.date('%X', os.time()) end},
        {'<date>', function() return os.date('%d.%m.%Y', os.time()) end},
        {'<myFio>', function() return user.fullName end},
        {'<myName>', function() return user.name end},
        {'<myNick>', function() return user.nick end},
        {'<myRang>', function() return user.rangName end},
        {'<myPodr>', function() return user.podr end},
        {'<myId>', function() local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED); return tostring(id) end},
        {'<myPhone>', function() return user.phone end},
    },
    {   -- Теги цели (/mmact)
        {'<tFio>', function() return userTarget.name end},
        {'<tName>', function() return (userTarget.nick):match('(.-)_') or userTarget.name end},
        {'<tNick>', function() return userTarget.nick end},
        {'<tId>', function() return tostring(userTarget.id) end},
    },
}

rp_cur_tegs = 1
rp_sum_tegs = 0
rp_thread = nil
rp_reading_stats = false
rp_stats_step = "idle"
rp_stats_text = ""
rp_show_window = imgui.new.bool(false)
rp_show_edit = imgui.new.bool(false)
rp_edit_chapter = 1
rp_edit_index = 0
rp_path = (getFolderPath(0x1C) or (getWorkingDirectory() .. "\\config")) .. "\\helper_rp_settings.json"

function setCurTeg(chapter)
    if chapter == 2 then
        rp_sum_tegs = #rp_tegs[1]
        rp_cur_tegs = 1
    else
        rp_sum_tegs = #rp_tegs[1] + #rp_tegs[2]
        rp_cur_tegs = 2
    end
end

function saveRpSettings()
    local ok, err = writeJsonAtomic(rp_path, rp_settings.set)
    if not ok then print("[helper_core] saveRpSettings error: " .. tostring(err)) end
end


function initDefaultRp()
    if rp_settings.set[1] and #rp_settings.set[1] > 0 then return end

    -- Глава 1: Общие отыгровки (вспомогательные — то, что НЕ срабатывает автоматически)
    -- Авто-отыгровки (телефон, оружие, маска, аптечка) работают от событий в auto_rp
    rp_settings.set[1] = {
        {
            name = "Закурить",
            text = "/me достал пачку сигарет из кармана\n<600>\n/me вытащил сигарету из пачки\n<400>\n/me убрал пачку обратно в карман\n<400>\n/me поднёс зажигалку к сигарете\n<500>\n/do Сигарета зажжена, дым идёт"
        },
        {
            name = "Затушить сигарету",
            text = "/me бросил сигарету на землю\n<400>\n/me затушил сигарету ногой\n<300>\n/do Сигарета потушена"
        },
        {
            name = "Напиться воды",
            text = "/me достал бутылку воды\n<500>\n/me открутил крышку бутылки\n<400>\n/me сделал несколько глотков воды\n<600>\n/me закрутил крышку обратно\n<400>\n/do Бутылка убрана"
        },
        {
            name = "Показать паспорт",
            text = "/me достал паспорт из внутреннего кармана\n<500>\n/me открыл паспорт на нужной странице\n<400>\n/me показал паспорт\n<800>\n/do Паспорт открыт, фото и данные видны"
        },
        {
            name = "Показать медкарту",
            text = "/me достал медицинскую карту из папки\n<500>\n/me раскрыл медкарту\n<400>\n/me показал медкарту\n<800>\n/do Медкарта раскрыта"
        },
        {
            name = "Показать лицензии",
            text = "/me достал папку с лицензиями\n<500>\n/me открыл папку\n<400>\n/me показал лицензии\n<800>\n/do Лицензии видны"
        },
        {
            name = "Осмотреться",
            text = "/me осмотрелся по сторонам\n<800>\n/do Внимательно изучает окружение"
        },
        {
            name = "Достать рацию",
            text = "/me снял рацию с пояса\n<400>\n/me нажал кнопку вызова\n<300>\n/do Рация в руке, канал активен"
        },
        {
            name = "Убрать рацию",
            text = "/me отпустил кнопку вызова\n<300>\n/me повесил рацию на пояс\n<400>\n/do Рация на поясе"
        },
        {
            name = "Заправить машину",
            text = "/me вышел из машины\n<500>\n/me достал шланг с колонки\n<400>\n/me вставил пистолет в бензобак\n<800>\n/do Топливо поступает в бак\n<2000>\n/me вытащил пистолет из бензобака\n<400>\n/me повесил шланг обратно на колонку"
        },
        {
            name = "Открыть капот",
            text = "/me подошёл к машине\n<400>\n/me потянул за рычаг капота\n<300>\n/me открыл капот машины\n<400>\n/do Капот открыт"
        },
        {
            name = "Закрыть капот",
            text = "/me захлопнул капот машины\n<400>\n/do Капот закрыт"
        },
        {
            name = "Залезть в багажник",
            text = "/me открыл багажник машины\n<400>\n/me достал нужную вещь из багажника\n<500>\n/me закрыл багажник\n<300>\n/do Багажник закрыт"
        },
        {
            name = "Постучать в дверь",
            text = "/me подошёл к двери\n<400>\n/me постучал в дверь\n<500>\n/do Стук в дверь"
        },
        {
            name = "Открыть дверь дома",
            text = "/me достал ключи из кармана\n<400>\n/me вставил ключ в замочную скважину\n<500>\n/me повернул ключ и открыл дверь\n<400>\n/me вошёл в помещение\n<300>\n/me закрыл дверь за собой"
        },
        {
            name = "Выпить кофе",
            text = "/me достал стаканчик с кофе\n<500>\n/me сделал глоток кофе\n<600>\n/do Тёплый кофе согревает\n<400>\n/me поставил стаканчик на стол"
        },
        {
            name = "Достать блокнот",
            text = "/me достал блокнот из кармана\n<400>\n/me раскрыл блокнот\n<300>\n/me достал ручку\n<400>\n/do Блокнот раскрыт, ручка в руке"
        },
        {
            name = "Убрать блокнот",
            text = "/me закрыл блокнот\n<300>\n/me убрал блокнот и ручку в карман\n<400>\n/do Блокнот в кармане"
        },
        {
            name = "Надеть наушники",
            text = "/me достал наушники из кармана\n<400>\n/me надел наушники на голову\n<300>\n/do Наушники надеты"
        },
        {
            name = "Снять наушники",
            text = "/me снял наушники с головы\n<300>\n/me убрал наушники в карман\n<400>\n/do Наушники убраны"
        },
    }

    -- Глава 2: Мои отыгровки (пустые — пользователь заполняет сам)
    rp_settings.set[2] = {}

    -- Глава 3: Для цели (/mmact) — сложные интерактивные отыгровки
    rp_settings.set[3] = {
        {
            name = "Проверка документов",
            text = "/me обратился к гражданину\n<500>\nr:{Здравствуйте}{Добрый день}r, я <myRang> <myPodr>.\n<800>\n/me предъявил удостоверение\n<600>\n/do Удостоверение в руке\n<1000>\nПрошу предъявить документы.\n<0>\n/me убрал удостоверение\n<400>\n/do Ожидание ответа"
        },
        {
            name = "Досмотр личности",
            text = "/me подошёл к <tFio>\n<500>\n/me положил руку на плечо\n<400>\nr:{Стойте}{Остановитесь}r, необходимо пройти досмотр.\n<1000>\n/me достал рацию с пояса\n<400>\n/me передал данные по рации\n<800>\n/do Рация издаёт щелчок\n<600>\n/me убрал рацию на пояс"
        },
        {
            name = "Обыск",
            text = "/me подошёл к <tFio> сзади\n<500>\n/me зафиксировал руки задержанного\n<400>\n/do Руки зафиксированы\n<600>\n/me провёл ощупывание карманов\n<800>\n/me проверил внутренние карманы\n<600>\n/me осмотрел поясницу\n<500>\n/do Обыск завершён"
        },
        {
            name = "Задержание",
            text = "/me резким движением заломил руку <tFio>\n<500>\n/do Рука заломлена за спину\n<400>\n/me достал наручники с пояса\n<300>\n/me надел наручники на запястья\n<500>\n/do Наручники надеты, руки зафиксированы\n<400>\nВы задержаны. Следуйте за мной."
        },
        {
            name = "Посадить в машину",
            text = "/me открыл заднюю дверь патрульной машины\n<500>\n/me надавил на голову <tFio>, усаживая в салон\n<600>\n/do Задержанный в салоне\n<400>\n/me закрыл дверь машины\n<300>\n/do Дверь закрыта"
        },
        {
            name = "Высадить из машины",
            text = "/me открыл дверь машины\n<400>\n/me взял <tFio> за руку\n<400>\n/me помог выйти из салона\n<500>\n/do Задержанный на улице"
        },
        {
            name = "Штраф",
            text = "/me подошёл к <tFio>\n<400>\n/me достал блокнот с квитанциями\n<500>\n/me заполнил квитанцию\n<800>\n/me оторвал квитанцию от блокнота\n<400>\n/me протянул квитанцию\n<600>\n/do Квитанция передана"
        },
        {
            name = "Медосмотр",
            text = "/me подошёл к <tFio>\n<400>\n/me достал стетоскоп\n<500>\n/me приложил стетоскоп к груди\n<800>\n/do Слушает сердцебиение\n<600>\n/me убрал стетоскоп\n<400>\n/me достал тонометр\n<500>\n/me измерил давление\n<800>\n/do Давление измерено"
        },
        {
            name = "Лечение",
            text = "/me достал аптечку\n<500>\n/me открыл аптечку\n<400>\n/me достал бинт\n<300>\n/me обработал рану <tFio>\n<800>\n/me наложил повязку\n<600>\n/do Рана обработана, повязка наложена\n<400>\n/me убрал аптечку"
        },
        {
            name = "Допрос",
            text = "/me сел напротив <tFio>\n<500>\n/me достал блокнот и ручку\n<400>\n/do Блокнот раскрыт\n<600>\nr:{Расскажите}{Объясните}r, что произошло.\n<0>\n/me записал показания в блокнот\n<800>\n/do Ручка скрипит по бумаге"
        },
        {
            name = "Приветствие цели",
            text = "/me подошёл к <tFio>\n<400>\nr:{Здравствуйте}{Приветствую}{Добрый день}r.\n<800>\n/do Лёгкий кивок головой"
        },
        {
            name = "Рукопожатие",
            text = "/me протянул руку <tFio>\n<500>\n/me пожал руку\n<400>\n/do Крепкое рукопожатие"
        },
    }

    saveRpSettings()
end

function loadRpSettings()
    local parsed = readJsonFile(rp_path)
    if parsed then
        for k, values in pairs(parsed) do
            local chapter = tonumber(k)
            if chapter and chapter >= 1 and chapter <= 100 and type(values) == "table" then
                local cleaned = {}
                for _, value in ipairs(values) do
                    if type(value) == "table" and type(value.name) == "string" and type(value.text) == "string" and not value.name:find("%z") and not value.text:find("%z") and #value.name <= 256 and #value.text <= 16384 then
                        cleaned[#cleaned + 1] = {name = value.name, text = value.text}
                        if #cleaned >= 500 then break end
                    end
                end
                rp_settings.set[chapter] = cleaned
            end
        end
    end
    -- Если файл пустой или нет — загружаем дефолтные отыгровки
    initDefaultRp()
end

-- playerLogin: авто-определение фракции/ранга/подразделения
function playerLogin()
    if rp_reading_stats then return end
    rp_reading_stats = true
    rp_stats_text = ""
    rp_stats_step = "waiting"  -- waiting -> menu -> stats -> done

    lua_thread.create(function()
        wait(500)
        -- Сначала пробуем /stats напрямую (быстрее)
        sampSendChat("/stats")

        local timer = os.time() + 3
        while rp_stats_step == "waiting" and os.time() < timer do wait(100) end

        -- Если /stats не открыл статистику — пробуем через /mn
        if rp_stats_step == "waiting" then
            sampSendChat("/mn")
            timer = os.time() + 5
            while rp_stats_step == "waiting" and os.time() < timer do wait(100) end
        end

        -- Если открылось меню — ждём пока пройдём через него к статистике
        if rp_stats_step == "menu" then
            timer = os.time() + 5
            while rp_stats_step ~= "done" and os.time() < timer do wait(100) end
        end

        -- Ждём получения текста статистики
        timer = os.time() + 5
        while rp_stats_step == "stats" and os.time() < timer do wait(100) end

        if rp_stats_text ~= "" then
            local id_ok2, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
            if not id_ok2 then
                rp_reading_stats = false
                rp_stats_step = "done"
                return
            end
            user.nick = sampGetPlayerNickname(pid)
            user.rang = tonumber(rp_stats_text:match("Ранг:%s*{.-}(%d+)") or "0")
            user.podr = rp_stats_text:match("Подразделение:%s*{.-}(.-)\n") or ""
            user.rangName = rp_stats_text:match("Должность:%s*{.-}(.-)\n") or ""
            user.phone = rp_stats_text:match("Телефон:%s*{.-}(%d+)") or ""

            user.fullName = (user.nick):gsub('_', ' ')
            user.name = (user.fullName):match('^(%S+)') or user.fullName
            user.family = (user.fullName):match('%s+(%S+)$') or ""
            user.isWork = not rp_stats_text:find("Уволен")

            local pl = cp1251_lower(user.podr)
            if pl:find("полиц") or pl:find("пд") then user.podrNum = 1
            elseif pl:find("фсб") or pl:find("фсин") then user.podrNum = 2
            elseif pl:find("мчс") or pl:find("больниц") or pl:find("мед") then user.podrNum = 3
            elseif pl:find("арм") or pl:find("мо") then user.podrNum = 4
            elseif pl:find("фбр") then user.podrNum = 5
            else user.podrNum = 0 end

            user.id = pid
            sampAddChatMessage("[Helper] РП-данные загружены: " .. user.fullName .. " | " .. user.rangName .. " | " .. user.podr, 0x00FF00)
        else
            sampAddChatMessage("[Helper] Не удалось прочитать статистику. Попробуйте /rplogin", 0xFF0000)
        end
        rp_reading_stats = false
        rp_stats_step = "done"
    end)
end


function stopRp()
    if rp_thread then
        local status = rp_thread:status()
        if status ~= "dead" then
            rp_thread:terminate()
            sampAddChatMessage("[Helper] Отыгровка остановлена", 0xFFAA00)
        end
    end
    rp_settings.active[0] = false
    rp_settings.wait = false
    rp_settings.window.is = -1
end

function playRp(text, test)
    if rp_settings.active[0] then
        queueTask(function() sampAddChatMessage("[Helper] Отыгровка уже идет. /mmstop для остановки", 0xFF0000) end)
        return
    end
    rp_settings.active[0] = true

    rp_thread = lua_thread.create(function()
        local ok, err = pcall(function()
        local chapter = rp_settings.setList[0] + 1
        setCurTeg(chapter)
        local typeTeg = rp_cur_tegs

        text = text .. '\n'

        -- Рандомизация r:{...}{...}:r
        for line in string.gmatch(text, 'r:(.-):r') do
            local randText = {}
            for rand in string.gmatch(line, '{(.-)}') do
                randText[#randText + 1] = rand
            end
            if #randText > 0 then
                local id = math.random(1, #randText)
                local safeRand = tostring(randText[id] or ''):gsub('%%', '%%%%')
                text = text:gsub('r:' .. escapePattern(line) .. ':r', safeRand, 1)
            end
        end

        -- Замена тегов
        for i = 1, rp_sum_tegs do
            if rp_tegs[1][i] then
                local textTeg = test and (rp_tegs[1][i][1] .. ":OK") or rp_tegs[1][i][2]()
                text = text:gsub(escapePattern(rp_tegs[1][i][1]), tostring(textTeg or ""):gsub("%%", "%%%%"))
            else
                local id = i - #rp_tegs[1]
                if rp_tegs[typeTeg][id] then
                    local textTeg = test and (rp_tegs[typeTeg][id][1] .. ":OK") or rp_tegs[typeTeg][id][2]()
                    text = text:gsub(escapePattern(rp_tegs[typeTeg][id][1]), tostring(textTeg or ""):gsub("%%", "%%%%"))
                end
            end
        end

        if test then
            sampAddChatMessage("[Helper] Тест отыгровки. Теги заменены на <тег>:OK", 0x00FF00)
        end

        -- Построчная обработка
        for line in string.gmatch(text, '(.-)\n') do
            if line == '' then goto skip end
            if not rp_settings.active[0] then break end

            -- Пауза <N>
            if line:find('^<%d+>') then
                local time = tonumber(line:match('<(%d+)>'))
                if time == 0 then
                    rp_settings.wait = true
                    sampAddChatMessage("[Helper] Пауза. /mmnext - продолжить, /mmstop - остановить", 0xFFAA00)
                    while rp_settings.wait and rp_settings.active[0] do wait(0) end
                else
                    wait(time)
                end
                goto skip
            end

            -- Окно ввода #input:
            if line:find('^#input:') then
                rp_settings.window.type = 1
                rp_settings.window.is = 1
                rp_settings.window.select = 0
                safeStrCopy(rp_settings.window.buf, "", ffi.sizeof(rp_settings.window.buf))
                while rp_settings.window.is == 1 and rp_settings.active[0] do wait(0) end
                goto skip
            end

            -- Окно выбора #list: {a}{b}{c}
            if line:find('^#list:') then
                rp_settings.window.type = 2
                rp_settings.window.is = 1
                rp_settings.window.select = 0
                rp_settings.window.list = {}
                for item in string.gmatch(line, '{(.-)}') do
                    rp_settings.window.list[#rp_settings.window.list + 1] = item
                end
                while rp_settings.window.is == 1 and rp_settings.active[0] do wait(0) end
                goto skip
            end

            -- Закрыть окно #close:
            if line:find('^#close:') then
                rp_settings.window.is = -1
                goto skip
            end

            -- Подстановка {w}
            if rp_settings.window.is == 2 and line:find('{w}') then
                if rp_settings.window.type == 1 then
                    local bufText = decodeUtf8Safe(ffi.string(rp_settings.window.buf))
                    line = line:gsub('{w}', bufText)
                elseif rp_settings.window.type == 2 then
                    line = line:gsub('{w}', rp_settings.window.list[rp_settings.window.select] or "")
                end
            end

            -- Отправка строки
            if test then
                sampAddChatMessage("[TEST] " .. line, 0x00FFAA)
            else
                sampSendChat(line)
                wait(500)
            end

            ::skip::
        end

        end)
        rp_settings.active[0] = false
        rp_settings.window.is = -1
        if not ok then
            sampAddChatMessage("[Helper] RP error: " .. tostring(err), 0xFF0000)
        elseif not test then
            sampAddChatMessage("[Helper] Отыгровка завершена", 0x00FF00)
        end
    end)
end

-- /mmact [id] — выбор цели для отыгровки
function cmdAct(text)
    local id = tonumber(text:match('(%d+)'))
    if not id then
        sampAddChatMessage("[Helper] Используйте: /mmact [id]", 0xFFAA00)
        return
    end
    local res, handle = sampGetCharHandleBySampPlayerId(id)
    if not res then
        sampAddChatMessage("[Helper] Игрок не найден", 0xFF0000)
        return
    end
    local x1, y1 = getCharCoordinates(PLAYER_PED)
    local x2, y2 = getCharCoordinates(handle)
    if math.sqrt((x1-x2)^2 + (y1-y2)^2) > 5 then
        sampAddChatMessage("[Helper] Игрок слишком далеко. Подойдите ближе.", 0xFF0000)
        return
    end
    userTarget.id = id
    userTarget.nick = sampGetPlayerNickname(id)
    userTarget.name = userTarget.nick:gsub('_', ' ')
    rp_show_window[0] = true
    sampAddChatMessage("[Helper] Цель: " .. userTarget.name .. " [ID:" .. id .. "]", 0x00FF00)
end

-- ===== КОНЕЦ РП-ДВИЖКА =====


-- ===== СМИ-ФУНКЦИИ =====

-- Анаграммы: список слов для радио/ТВ игр
anag_cat_names = {
    [1] = "СМИ и Радио",
    [2] = "Города и Транспорт",
    [3] = "Техника и Профессии",
    [4] = "Природа и Космос",
    [5] = "Разное",
}
anag_words = {
    [1] = {
        "радиоволна", "радиорубка", "телецентр", "телевидение", "фельетон", "корреспондент", "журналист", "редактор", "публикация", "заголовок",
        "объявление", "интервью", "репортаж", "диктофон", "микрофон", "телестудия", "телебашня", "передача", "трансляция", "программа",
        "сенсация", "хроника", "новости", "журнал", "газета", "колонка", "рубрика", "редакция", "типография", "выпуск",
        "подписка", "реклама", "баннер", "афиша", "сценарий", "дикция", "ведущий", "слушатель", "зритель", "аудитория",
        "рейтинг", "анонс", "брифинг", "прессрелиз", "комментарий", "обозреватель", "оператор", "камера", "наушники", "аппаратура",
        "частота", "антенна", "спутник", "сигнал"
    },
    [2] = {
        "автомобиль", "мотоцикл", "вертолёт", "самолёт", "теплоход", "велосипед", "грузовик", "внедорожник", "спорткар", "кабриолет",
        "лимузин", "автобус", "трамвай", "троллейбус", "поезд", "вокзал", "аэропорт", "автострада", "перекрёсток", "светофор",
        "магистраль", "эстакада", "тоннель", "развязка", "парковка", "заправка", "спидометр", "двигатель", "трансмиссия", "подвеска",
        "тормоза", "глушитель", "спойлер", "багажник", "бампер", "прицеп", "квартал", "проспект", "бульвар", "площадь",
        "набережная", "небоскрёб", "мегаполис", "пригород", "городок", "райцентр", "порт", "причал", "гавань", "маяк",
        "мост", "кольцо", "объезд", "шоссе"
    },
    [3] = {
        "компьютер", "процессор", "монитор", "клавиатура", "смартфон", "планшет", "сервер", "интернет", "компилятор", "алгоритм",
        "инженер", "программист", "механик", "электрик", "водитель", "пилот", "капитан", "архитектор", "строитель", "врач",
        "хирург", "фельдшер", "фармацевт", "спасатель", "пожарный", "полицейский", "детектив", "следователь", "прокурор", "адвокат",
        "судья", "дипломат", "экономист", "бухгалтер", "банкир", "менеджер", "директор", "секретарь", "переводчик", "дизайнер",
        "фотограф", "музыкант", "композитор", "художник", "скульптор", "учитель", "профессор", "биолог", "химик", "физик",
        "астроном", "геолог", "агроном", "фермер"
    },
    [4] = {
        "галактика", "созвездие", "планета", "комета", "метеорит", "астероид", "орбита", "телескоп", "космодром", "вселенная",
        "затмение", "туманность", "атмосфера", "стратосфера", "ураган", "торнадо", "молния", "гром", "радуга", "облако",
        "снегопад", "гололёд", "листопад", "оттепель", "океан", "море", "водопад", "ледник", "айсберг", "вулкан",
        "пещера", "каньон", "равнина", "долина", "пустыня", "джунгли", "тайга", "тундра", "остров", "полуостров",
        "архипелаг", "лагуна", "родник", "ручей", "озеро", "болото", "вершина", "скала", "хребет", "рассвет",
        "закат", "горизонт", "экватор", "полюс"
    },
    [5] = {
        "библиотека", "университет", "музей", "театр", "кинотеатр", "филармония", "стадион", "бассейн", "тренировка", "чемпионат",
        "олимпиада", "медаль", "кубок", "победитель", "соперник", "марафон", "шахматы", "бильярд", "праздник", "фестиваль",
        "карнавал", "фейерверк", "подарок", "сюрприз", "путешествие", "экскурсия", "экспедиция", "компас", "рюкзак", "палатка",
        "костёр", "гитара", "пианино", "скрипка", "барабан", "оркестр", "шоколад", "мороженое", "апельсин", "мандарин",
        "ананас", "виноград", "клубника", "земляника", "арбуз", "завтрак", "ужин", "ресторан", "гостиница", "чемодан",
        "билет", "паспорт", "документ", "печать"
    },
}

anag_decks = {}
anag_active = false
anag_current_word = ""
anag_current_result = ""

local function getAnagramPool(type_num)
    local pool = {}
    if type_num and type_num >= 1 and type_num <= #anag_words then
        for _, w in ipairs(anag_words[type_num]) do pool[#pool + 1] = w end
    else
        for cat_id = 1, #anag_words do
            for _, w in ipairs(anag_words[cat_id]) do pool[#pool + 1] = w end
        end
    end
    return pool
end

function drawNextAnagramWord(type_num)
    local key = tonumber(type_num) or 0
    if key < 0 or key > #anag_words then key = 0 end
    local pool = getAnagramPool(key)
    local total = #pool
    if total == 0 then return nil, 0, 0 end

    local deck = anag_decks[key]
    if not deck or #deck == 0 then
        deck = {}
        for i = 1, total do deck[i] = pool[i] end
        for i = total, 2, -1 do
            local j = math.random(i)
            deck[i], deck[j] = deck[j], deck[i]
        end
        if total > 1 and deck[#deck] == anag_current_word then
            deck[1], deck[#deck] = deck[#deck], deck[1]
        end
        anag_decks[key] = deck
    end

    local word = table.remove(deck)
    return word, #deck, total
end

function createAnagram(word, separator, firstLetter)
    local sep = separator or "."
    local letters = {}
    for i = 1, #word do
        letters[i] = word:sub(i, i)
    end
    for attempt = 1, 10 do
        for i = #letters, 2, -1 do
            local j = math.random(i)
            letters[i], letters[j] = letters[j], letters[i]
        end
        if table.concat(letters) ~= word then break end
    end
    if #letters > 1 and table.concat(letters) == word then
        local first = table.remove(letters, 1)
        letters[#letters + 1] = first
    end
    if firstLetter and #letters > 0 then
        letters[1] = cp1251_upper(letters[1])
    end
    return table.concat(letters, sep)
end

function startAnagram(type_num)
    local cat = 0
    if type_num ~= nil and tostring(type_num):gsub("%s+", "") ~= "" then
        cat = tonumber(type_num)
        if not cat or cat < 0 or cat > #anag_words then
            sampAddChatMessage("[Helper] Использование: /anag [0-5] (0=все 270+, 1=СМИ, 2=транспорт, 3=техника, 4=природа, 5=разное)", 0xFFAA00)
            return
        end
    end
    local word, rem, total = drawNextAnagramWord(cat)
    if not word then
        sampAddChatMessage("[Helper] Нет слов для анаграммы категории " .. tostring(cat), 0xFF0000)
        return
    end
    local anagram = createAnagram(word, ".", true)
    anag_current_word = word
    anag_current_result = anagram
    anag_active = true

    sampSetChatInputEnabled(true)
    local prefix = ""
    if user.podr and cp1251_lower(user.podr):find("радио", 1, true) then
        prefix = "/t "
    elseif user.podr and cp1251_lower(user.podr):find("центр", 1, true) then
        prefix = "/u "
    end
    sampSetChatInputText(prefix .. anagram)
    sampAddChatMessage("[Helper] Анаграмма: " .. anagram .. " (слово: " .. word .. " | осталось " .. rem .. "/" .. total .. ")", 0x00FF00)
end

-- ===== РЕЖИССЁР ЭФИРОВ И ВИКТОРИН =====
quiz_capitals = {
    {q = "Франция", a = "Париж"}, {q = "Япония", a = "Токио"}, {q = "Бразилия", a = "Бразилиа"}, {q = "Австралия", a = "Канберра"},
    {q = "Канада", a = "Оттава"}, {q = "Турция", a = "Анкара"}, {q = "Швейцария", a = "Берн"}, {q = "Египет", a = "Каир"},
    {q = "Италия", a = "Рим"}, {q = "Испания", a = "Мадрид"}, {q = "Германия", a = "Берлин"}, {q = "Великобритания", a = "Лондон"},
    {q = "Китай", a = "Пекин"}, {q = "Индия", a = "Нью-Дели|Дели"}, {q = "Южная Корея", a = "Сеул"}, {q = "Польша", a = "Варшава"},
    {q = "Чехия", a = "Прага"}, {q = "Греция", a = "Афины"}, {q = "Норвегия", a = "Осло"}, {q = "Швеция", a = "Стокгольм"},
    {q = "Финляндия", a = "Хельсинки"}, {q = "Португалия", a = "Лиссабон"}, {q = "Австрия", a = "Вена"}, {q = "Венгрия", a = "Будапешт"},
    {q = "Аргентина", a = "Буэнос-Айрес"}, {q = "Мексика", a = "Мехико"}, {q = "США", a = "Вашингтон"}, {q = "Нидерланды", a = "Амстердам"},
    {q = "Бельгия", a = "Брюссель"}, {q = "Ирландия", a = "Дублин"}, {q = "Дания", a = "Копенгаген"}, {q = "Исландия", a = "Рейкьявик"},
    {q = "Румыния", a = "Бухарест"}, {q = "Болгария", a = "София"}, {q = "Сербия", a = "Белград"}, {q = "Хорватия", a = "Загреб"},
    {q = "Словакия", a = "Братислава"}, {q = "Словения", a = "Любляна"}, {q = "Грузия", a = "Тбилиси"}, {q = "Армения", a = "Ереван"},
    {q = "Азербайджан", a = "Баку"}, {q = "Казахстан", a = "Астана"}, {q = "Узбекистан", a = "Ташкент"}, {q = "Таиланд", a = "Бангкок"},
    {q = "Вьетнам", a = "Ханой"}, {q = "Индонезия", a = "Джакарта"}, {q = "Малайзия", a = "Куала-Лумпур"}, {q = "Иран", a = "Тегеран"},
    {q = "Израиль", a = "Иерусалим"}, {q = "Марокко", a = "Рабат"}, {q = "Кения", a = "Найроби"}, {q = "Перу", a = "Лима"},
    {q = "Чили", a = "Сантьяго"}, {q = "Колумбия", a = "Богота"}, {q = "Куба", a = "Гавана"}, {q = "Новая Зеландия", a = "Веллингтон"},
    {q = "Украина", a = "Киев"}, {q = "Беларусь", a = "Минск"}, {q = "Россия", a = "Москва"}, {q = "Латвия", a = "Рига"},
    {q = "Литва", a = "Вильнюс"}, {q = "Эстония", a = "Таллин|Таллинн"},
}
quiz_trivia = {
    {q = "Самая большая планета Солнечной системы?", a = "Юпитер"},
    {q = "Ближайшая к Солнцу планета?", a = "Меркурий"},
    {q = "Красная планета Солнечной системы?", a = "Марс"},
    {q = "Самая высокая гора Земли?", a = "Эверест|Джомолунгма"},
    {q = "Самый большой океан на Земле?", a = "Тихий"},
    {q = "Какая река считается самой длинной в Южной Америке?", a = "Амазонка"},
    {q = "Химический символ золота?", a = "Au"},
    {q = "Сколько градусов в прямом угле?", a = "90"},
    {q = "Сколько минут в трёх часах?", a = "180"},
    {q = "Сколько игроков одной команды на футбольном поле?", a = "11"},
    {q = "Сколько игроков в баскетбольной команде на площадке?", a = "5"},
    {q = "Сколько цветов у олимпийских колец?", a = "5"},
    {q = "Сколько континентов на Земле?", a = "6|7"},
    {q = "Какой газ составляет около 78% атмосферы Земли?", a = "Азот"},
    {q = "Самый твёрдый природный минерал?", a = "Алмаз"},
    {q = "Какой металл остаётся жидким при комнатной температуре?", a = "Ртуть"},
    {q = "Самое быстрое наземное животное?", a = "Гепард"},
    {q = "Самое крупное животное на планете Земля?", a = "Кит|Синий кит"},
    {q = "Сколько нот в классическом звукоряде?", a = "7"},
    {q = "Сколько дней в високосном году?", a = "366"},
    {q = "Сколько минут в одних сутках?", a = "1440"},
    {q = "Квадратный корень из числа 144?", a = "12"},
    {q = "Сколько граней у обычного игрального кубика?", a = "6"},
    {q = "Кто написал роман «Война и мир»?", a = "Толстой|Лев Толстой"},
    {q = "Кто изобрёл таблицу химических элементов?", a = "Менделеев"},
    {q = "Кто первым в мире полетел в космос?", a = "Гагарин|Юрий Гагарин"},
    {q = "Какой прибор измеряет атмосферное давление?", a = "Барометр"},
    {q = "Какой прибор измеряет силу электрического тока?", a = "Амперметр"},
    {q = "Какая единица измерения электрического сопротивления?", a = "Ом"},
    {q = "На каком материке расположена пустыня Сахара?", a = "Африка"},
    {q = "Самое глубокое озеро на Земле?", a = "Байкал"},
    {q = "Самое большое по площади государство мира?", a = "Россия"},
    {q = "В каком городе находится Колизей?", a = "Рим"},
    {q = "В какой стране изобрели порох и бумагу?", a = "Китай"},
    {q = "Как называется наука о звёздах и планетах?", a = "Астрономия"},
    {q = "Сколько струн у классической шестиструнной гитары?", a = "6"},
    {q = "Какой месяц в году бывает самым коротким?", a = "Февраль"},
    {q = "Какой цвет получается при смешении синего и жёлтого?", a = "Зелёный|Зеленый"},
    {q = "Вода закипает при нормальном давлении при скольких градусах Цельсия?", a = "100"},
    {q = "Сколько сантиметров в одном километре?", a = "100000"},
    {q = "Как называется главная артерия, выходящая из сердца?", a = "Аорта"},
    {q = "Какая планета известна своими яркими кольцами?", a = "Сатурн"},
    {q = "Сколько букв в современном русском алфавите?", a = "33"},
    {q = "Какой город называют столицей моды в Италии?", a = "Милан"},
    {q = "Какая птица является самой крупной нелетающей птицей в мире?", a = "Страус"},
}

smi_ui_page = 1
quiz_popout_show = imgui.new.bool(false)
quiz_bank_idx = imgui.new.int(0)    -- 0=Анаграммы, 1=Столицы, 2=Математика, 3=Эрудиция, 4=Свой вопрос
quiz_channel_idx = imgui.new.int(0) -- 0=/t, 1=/u
quiz_win_score = imgui.new.int(5)
quiz_auto_point = imgui.new.bool(true)
quiz_q_buf = imgui.new.char[257]("")
quiz_a_buf = imgui.new.char[129]("")
quiz_round_active = false
quiz_round_num = 0
quiz_expected_answer = ""
quiz_winner_nick = ""
quiz_winner_phone = ""
quiz_winner_text = ""
quiz_scores = {}
quiz_decks = {}
quiz_last_pick = {}

function normalizeQuizAnswer(s)
    if type(s) ~= "string" then return "" end
    local out = cp1251_lower(s)
    out = out:gsub("\184", "\229") -- ё -> е
    out = out:gsub("[%p%c]+", " ")
    out = out:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return out
end

function isQuizAnswerMatch(sms_body, expected_pipe_str)
    local norm_sms = normalizeQuizAnswer(sms_body)
    if norm_sms == "" or type(expected_pipe_str) ~= "string" or expected_pipe_str == "" then
        return false
    end
    for part in string.gmatch(expected_pipe_str, "[^|]+") do
        local norm_exp = normalizeQuizAnswer(part)
        if norm_exp ~= "" and norm_sms == norm_exp then
            return true
        end
    end
    return false
end

local function drawFromQuizDeck(deck_key, items)
    local n = #items
    if n == 0 then return nil end
    local deck = quiz_decks[deck_key]
    if not deck or #deck == 0 then
        deck = {}
        for i = 1, n do deck[i] = i end
        for i = n, 2, -1 do
            local j = math.random(i)
            deck[i], deck[j] = deck[j], deck[i]
        end
        if n > 1 and deck[#deck] == quiz_last_pick[deck_key] then
            deck[1], deck[#deck] = deck[#deck], deck[1]
        end
        quiz_decks[deck_key] = deck
    end
    local idx = table.remove(deck)
    quiz_last_pick[deck_key] = idx
    return items[idx]
end

local function generateQuizMath()
    local kind = math.random(1, 4)
    local q_str, ans
    if kind == 1 then
        local a, b, c = math.random(4, 15), math.random(3, 14), math.random(5, 45)
        ans = a * b + c
        q_str = string.format("%d * %d + %d", a, b, c)
    elseif kind == 2 then
        local a, b = math.random(5, 16), math.random(4, 14)
        local prod = a * b
        local c = math.random(1, prod)
        ans = prod - c
        q_str = string.format("%d * %d - %d", a, b, c)
    elseif kind == 3 then
        local a, b, c = math.random(15, 95), math.random(12, 85), math.random(5, 65)
        ans = a + b + c
        q_str = string.format("%d + %d + %d", a, b, c)
    else
        local d = math.random(3, 12)
        local q = math.random(4, 19)
        local c = math.random(3, 40)
        ans = q + c
        q_str = string.format("%d / %d + %d", q * d, d, c)
    end
    return q_str, tostring(ans)
end

local function getQuizPrefix()
    return (quiz_channel_idx[0] == 1) and "/u " or "/t "
end

function quizPickNext()
    local b = quiz_bank_idx[0]
    local q_cp, a_cp = "", ""
    if b == 0 then
        local w = drawNextAnagramWord(0)
        if w then
            local an = createAnagram(w, ".", true)
            anag_current_word = w
            anag_current_result = an
            q_cp = "Соберите слово (" .. #w .. " букв): " .. an
            a_cp = w
        end
    elseif b == 1 then
        local item = drawFromQuizDeck("capitals", quiz_capitals)
        if item then
            q_cp = "Столица страны " .. item.q .. "?"
            a_cp = item.a
        end
    elseif b == 2 then
        local expr, ans = generateQuizMath()
        q_cp = "Решите пример: " .. expr .. " = ?"
        a_cp = ans
    elseif b == 3 then
        local item = drawFromQuizDeck("trivia", quiz_trivia)
        if item then
            q_cp = item.q
            a_cp = item.a
        end
    else
        return
    end
    safeStrCopy(quiz_q_buf, encodeCp1251Safe(q_cp), ffi.sizeof(quiz_q_buf))
    safeStrCopy(quiz_a_buf, encodeCp1251Safe(a_cp), ffi.sizeof(quiz_a_buf))
    quiz_expected_answer = a_cp
end

function quizSendQuestion()
    local q_cp = decodeUtf8Safe(ffi.string(quiz_q_buf)):gsub("^%s+", ""):gsub("%s+$", "")
    local a_cp = decodeUtf8Safe(ffi.string(quiz_a_buf)):gsub("^%s+", ""):gsub("%s+$", "")
    if q_cp == "" then
        sampAddChatMessage("[Викторина] Сначала выберите или введите вопрос!", 0xFFAA00)
        return
    end
    quiz_expected_answer = a_cp
    quiz_winner_nick = ""
    quiz_winner_phone = ""
    quiz_winner_text = ""
    quiz_round_num = quiz_round_num + 1
    quiz_round_active = (a_cp ~= "")
    local line = getQuizPrefix() .. "Вопрос №" .. quiz_round_num .. ": " .. q_cp
    if #line > 125 then line = line:sub(1, 125) end
    if isSampAvailable() then sampSendChat(line) end
    sampAddChatMessage("[Викторина] Вопрос №" .. quiz_round_num .. " отправлен. Ждём ответ в SMS: " .. (a_cp ~= "" and a_cp or "(без авто-проверки)"), 0x00CCFF)
end

function quizAnnounceWinner()
    if quiz_winner_nick == "" then
        sampAddChatMessage("[Викторина] Победитель раунда пока не определён.", 0xFFAA00)
        return
    end
    local primary_ans = (quiz_expected_answer:match("^([^|]+)") or quiz_expected_answer)
    local pts = quiz_scores[quiz_winner_nick] or 0
    local nice_nick = quiz_winner_nick:gsub("_", " ")
    local msg = getQuizPrefix() .. "Верно! Первым ответил " .. nice_nick .. " (" .. primary_ans .. "). Счёт: " .. pts .. "/" .. quiz_win_score[0] .. "."
    if #msg > 125 then msg = msg:sub(1, 125) end
    quiz_round_active = false
    if isSampAvailable() then sampSendChat(msg) end
end

function quizAnnounceFinalWinner()
    local best_nick, best_pts = nil, -1
    for nick, pts in pairs(quiz_scores) do
        if pts > best_pts then
            best_pts = pts
            best_nick = nick
        end
    end
    if not best_nick then
        sampAddChatMessage("[Викторина] Таблица лидеров пуста.", 0xFFAA00)
        return
    end
    local msg = getQuizPrefix() .. "Победитель нашей викторины — " .. best_nick:gsub("_", " ") .. " (" .. best_pts .. " баллов)! Поздравляем!"
    if #msg > 125 then msg = msg:sub(1, 125) end
    quiz_round_active = false
    if isSampAvailable() then sampSendChat(msg) end
end

local function drawQuizDirectorUI(id_suffix)
    imgui.PushItemWidth(170)
    local bank_items = u8"Анаграммы (270+)" .. "\0" .. u8"Столицы мира (60+)" .. "\0" .. u8"Математика (авто)" .. "\0" .. u8"Эрудиция (45+)" .. "\0" .. u8"Свой вопрос" .. "\0"
    imgui.ComboStr(u8"Режим##qz_bank" .. id_suffix, quiz_bank_idx, bank_items)
    imgui.SameLine()
    imgui.PushItemWidth(115)
    local chan_items = u8"/t (Радио)" .. "\0" .. u8"/u (ТВ)" .. "\0"
    imgui.ComboStr(u8"Канал##qz_chan" .. id_suffix, quiz_channel_idx, chan_items)
    imgui.PopItemWidth()
    imgui.PopItemWidth()

    imgui.PushItemWidth(110)
    imgui.InputInt(u8"До баллов##qz_win" .. id_suffix, quiz_win_score)
    if quiz_win_score[0] < 1 then quiz_win_score[0] = 1 end
    if quiz_win_score[0] > 50 then quiz_win_score[0] = 50 end
    imgui.PopItemWidth()
    imgui.SameLine()
    imgui.Checkbox(u8"+1 балл при совпадении SMS##qz_ap" .. id_suffix, quiz_auto_point)

    imgui.TextUnformatted(u8"Вопрос в эфир:")
    imgui.PushItemWidth(-1)
    imgui.InputText("##qz_q" .. id_suffix, quiz_q_buf, ffi.sizeof(quiz_q_buf))
    imgui.PopItemWidth()

    imgui.TextUnformatted(u8"Эталон ответа (синонимы через |):")
    imgui.PushItemWidth(-1)
    imgui.InputText("##qz_a" .. id_suffix, quiz_a_buf, ffi.sizeof(quiz_a_buf))
    imgui.PopItemWidth()

    if imgui.Button(u8"Новый вопрос##qz_pick" .. id_suffix, imgui.ImVec2(125, 26)) then
        quizPickNext()
    end
    imgui.SameLine()
    if imgui.Button(u8"В эфир##qz_send" .. id_suffix, imgui.ImVec2(95, 26)) then
        queueTask(quizSendQuestion)
    end
    imgui.SameLine()
    if imgui.Button(u8"Стоп раунд##qz_stop" .. id_suffix, imgui.ImVec2(95, 26)) then
        quiz_round_active = false
    end

    if quiz_winner_nick ~= "" then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 1.0, 0.4, 1.0))
        imgui.TextUnformatted(encodeCp1251Safe("Победитель раунда: " .. quiz_winner_nick .. " [т." .. quiz_winner_phone .. "] -> " .. quiz_winner_text))
        imgui.PopStyleColor()
    elseif quiz_round_active then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.85, 0.25, 1.0))
        imgui.TextUnformatted(encodeCp1251Safe("Раунд №" .. quiz_round_num .. " активен: ждём верное SMS (" .. quiz_expected_answer .. ")"))
        imgui.PopStyleColor()
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65, 0.65, 0.65, 1.0))
        imgui.TextUnformatted(u8"Раунд на паузе. Сгенерируйте и отправьте вопрос.")
        imgui.PopStyleColor()
    end

    if imgui.Button(u8"Озвучить ответ##qz_ann" .. id_suffix, imgui.ImVec2(130, 26)) then
        queueTask(quizAnnounceWinner)
    end
    imgui.SameLine()
    if imgui.Button(u8"Объявить итог##qz_fin" .. id_suffix, imgui.ImVec2(125, 26)) then
        queueTask(quizAnnounceFinalWinner)
    end
    imgui.SameLine()
    if imgui.Button(u8"Сбросить счёт##qz_rst" .. id_suffix, imgui.ImVec2(115, 26)) then
        quiz_scores = {}
        quiz_round_num = 0
        quiz_round_active = false
        quiz_winner_nick = ""
    end

    imgui.Separator()
    imgui.TextUnformatted(u8"Таблица лидеров (баллы):")
    imgui.BeginChild("##qz_scores" .. id_suffix, imgui.ImVec2(0, 125), true)
    local rows = {}
    for nk, sc in pairs(quiz_scores) do
        rows[#rows + 1] = { nick = nk, pts = sc }
    end
    table.sort(rows, function(a, b)
        if a.pts ~= b.pts then return a.pts > b.pts end
        return a.nick < b.nick
    end)
    if #rows == 0 then
        imgui.TextUnformatted(u8"Пока никто не набрал баллов.")
    else
        for ridx, r in ipairs(rows) do
            local win_mark = (r.pts >= quiz_win_score[0]) and " [ФИНИШ!]" or ""
            if r.pts >= quiz_win_score[0] then
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.85, 0.2, 1.0))
            else
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85, 0.95, 1.0, 1.0))
            end
            imgui.TextUnformatted(encodeCp1251Safe(ridx .. ". " .. r.nick .. " — " .. r.pts .. win_mark))
            imgui.PopStyleColor()
            imgui.SameLine(275)
            if imgui.SmallButton("+##qzp_" .. id_suffix .. ridx) then
                quiz_scores[r.nick] = (quiz_scores[r.nick] or 0) + 1
            end
            imgui.SameLine()
            if imgui.SmallButton("-##qzm_" .. id_suffix .. ridx) then
                local nv = (quiz_scores[r.nick] or 0) - 1
                quiz_scores[r.nick] = nv > 0 and nv or nil
                break
            end
        end
    end
    imgui.EndChild()
end

-- tvlift: лифт в ТВ-башне
tvlift_active = false
tvlift_target_item = nil
function cmdTvlift(floor_str)
    local floor = tonumber(floor_str)
    if not floor then
        sampAddChatMessage("[Helper] Использование: /tvlf [этаж 1-21]", 0xFFAA00)
        return
    end
    if not isCharInArea3d(PLAYER_PED, 1839.5557, -1264.6527, 13.4299, 1765.8602, -1319.9817, 134.1671, false) then
        sampAddChatMessage("[Helper] Вы должны находиться рядом с лифтом ТВ-башни.", 0xFF0000)
        return
    end
    if floor < 1 or floor > 21 then
        sampAddChatMessage("[Helper] Этаж должен быть от 1 до 21.", 0xFF0000)
        return
    end
    sampSendChat("/me " .. rpVerb("нажал", "нажала") .. " на кнопку лифта, выбрав " .. floor .. " этаж")
    tvlift_target_item = 21 - floor
    tvlift_active = true
    scheduleTask(5000, function()
        tvlift_active = false
        tvlift_target_item = nil
    end)
    sampSendChat("/tvlift")
end

-- uninvite: увольнение с РП-отыгровкой
function cmdUninvite(arg)
    local id, reason = arg:match("^(%d+)%s+(.*)")
    if not id then
        sampAddChatMessage("[Helper] Использование: /uninv [id] [причина]", 0xFFAA00)
        return
    end
    id = tonumber(id)
    if not sampIsPlayerConnected(id) then
        sampAddChatMessage("[Helper] Игрок не подключен к серверу.", 0xFF0000)
        return
    end
    local nick = sampGetPlayerNickname(id)
    local name = nick:gsub('_', ' ')

    lua_thread.create(function()
        -- РП-отыгровка увольнения
        sampSendChat("/me достал папку с личными делами сотрудников")
        wait(800)
        sampSendChat("/me открыл папку и нашёл дело " .. name)
        wait(800)
        sampSendChat("/do Папка раскрыта на нужной странице")
        wait(600)
        sampSendChat("/me выписал заявление на увольнение")
        wait(800)
        sampSendChat("/me поставил подпись и печать на заявлении")
        wait(600)
        sampSendChat("/me убрал папку в шкаф")
        wait(500)
        -- Сообщение в рацию
        if user.podr and user.podr ~= "" then
            sampSendChat("/r Сотрудник " .. name .. " уволен. Причина: " .. reason)
            wait(300)
        end
        -- Само увольнение
        sampSendChat("/uninvite " .. id .. " " .. reason)
        sampAddChatMessage("[Helper] Увольнение " .. name .. " выполнено. Причина: " .. reason, 0x00FF00)
    end)
end

-- Эфир: авто-отыгровка начала/конца эфира
efir_active = false
efir_stats = { sms = 0, calls = 0, lines = 0, start_time = 0 }
efir_start_text = "/me надел наушники и настроил микрофон\n<800>\n/do Микрофон включён, наушники надеты\n<500>\n/efir"
efir_end_text = "/me снял наушники\n<500>\n/do Наушники сняты, микрофон выключен\n<400>\n/efir"

function cmdEfir()
    if efir_active then
        sampAddChatMessage("[Helper] Эфир уже активен. Используйте /mmstop для остановки.", 0xFFAA00)
        return
    end
    efir_active = true
    efir_stats.start_time = os.time()
    efir_stats.sms = 0
    efir_stats.calls = 0
    efir_stats.lines = 0
    playRp(efir_start_text, false)
    sampAddChatMessage("[Helper] Эфир начат. /endefir для завершения.", 0x00FF00)
end

function cmdEndEfir()
    if not efir_active then
        sampAddChatMessage("[Helper] Эфир не активен.", 0xFFAA00)
        return
    end
    playRp(efir_end_text, false)
    efir_active = false
    efir_stats.start_time = 0
    efir_stats.sms = 0
    efir_stats.calls = 0
    efir_stats.lines = 0
    sampAddChatMessage("[Helper] Эфир завершён.", 0x00FF00)
end

-- /find: поиск сотрудников с парсингом диалога
find_list = {}
find_selected = 0
find_show = imgui.new.bool(false)

function cmdFind()
    if find_ui_enabled[0] then
        find_wait_until = os.clock() + 5.0
    end
    sampSendChat("/find")
end

-- Чёрный список СМИ
blacklist_data = {}
blacklist_show = imgui.new.bool(false)
blacklist_url = ""

function loadBlacklist()
    local path = (getFolderPath(0x1C) or (getWorkingDirectory() .. "\\config")) .. "\\helper_blacklist.json"
    local parsed = readJsonFile(path)
    if parsed then
        local cleaned = {}
        for nick, data in pairs(parsed) do
            if type(nick) == "string" and #nick <= 64 and type(data) == "table" and type(data.reason) == "string" and #data.reason <= 1024 then
                cleaned[nick] = {reason = data.reason, added = type(data.added) == "string" and data.added or ""}
            end
        end
        blacklist_data = cleaned
    end
end

function saveBlacklist()
    local path = (getFolderPath(0x1C) or (getWorkingDirectory() .. "\\config")) .. "\\helper_blacklist.json"
    local ok, err = writeJsonAtomic(path, blacklist_data)
    if not ok then print("[helper_core] saveBlacklist error: " .. tostring(err)) end
end

function addBlacklistNick(nick, reason)
    nick = nick:lower()
    blacklist_data[nick] = { reason = reason or "", added = os.date("%d.%m.%Y") }
    saveBlacklist()
    sampAddChatMessage("[Helper] " .. nick .. " добавлен в чёрный список", 0x00FF00)
end

function removeBlacklistNick(nick)
    nick = nick:lower()
    if blacklist_data[nick] then
        blacklist_data[nick] = nil
        saveBlacklist()
        sampAddChatMessage("[Helper] " .. nick .. " удалён из чёрного списка", 0x00FF00)
    else
        sampAddChatMessage("[Helper] " .. nick .. " не найден в чёрном списке", 0xFFAA00)
    end
end

function checkBlacklistNick(nick)
    if not nick then return false end
    return blacklist_data[nick:lower()] ~= nil
end

-- Эфир-статистика
function cmdEfirStats()
    if efir_stats.start_time == 0 then
        sampAddChatMessage("[Helper] Эфир ещё не начат. /mmefir для старта.", 0xFFAA00)
        return
    end
    local elapsed = os.time() - efir_stats.start_time
    local mins = math.floor(elapsed / 60)
    local secs = elapsed % 60
    sampAddChatMessage(string.format("[Helper] Эфир-статистика: %dм %dс | SMS: %d | Звонки: %d | Строк: %d",
        mins, secs, efir_stats.sms, efir_stats.calls, efir_stats.lines), 0x00FFCC)
end

-- Авто-ответ на звонки в эфире
auto_answer_enabled = imgui.new.bool(false)
auto_answer_text = imgui.new.char[257]("")
auto_answer_last_time = 0

function cmdAutoAnswer(arg)
    if arg and arg ~= "" then
        safeStrCopy(auto_answer_text, encodeCp1251Safe(arg), ffi.sizeof(auto_answer_text))
        auto_answer_enabled[0] = true
        sampAddChatMessage("[Helper] Авто-ответ включён: " .. arg, 0x00FF00)
    else
        auto_answer_enabled[0] = not auto_answer_enabled[0]
        if auto_answer_enabled[0] then
            local txt = decodeUtf8Safe(ffi.string(auto_answer_text))
            sampAddChatMessage("[Helper] Авто-ответ включён: " .. txt, 0x00FF00)
        else
            sampAddChatMessage("[Helper] Авто-ответ выключен", 0xFFAA00)
        end
    end
end

-- ===== КОНЕЦ СМИ-ФУНКЦИЙ =====
-- СПИСОК МОДУЛЕЙ
function drawMmGeneralPage()
imgui.TextUnformatted(u8"Тег объявления:")
imgui.SameLine()
imgui.PushItemWidth(60)
imgui.InputText("##mm_tag", mm_tag, ffi.sizeof(mm_tag))
if imgui.IsItemDeactivatedAfterEdit() then requestSaveSettings() end
imgui.PopItemWidth()
imgui.SameLine()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"Например: LV, LS, SF, TV")
imgui.PopStyleColor()
imgui.Spacing()
if imgui.Checkbox(u8"Авто-форматирование при открытии редактора", mm_auto_format) then requestSaveSettings() end
if imgui.Checkbox(u8"Авто-отправка объявлений (Auto-Edit)", mm_auto_send) then requestSaveSettings() end

if mm_auto_send[0] then
imgui.PushItemWidth(150)
if imgui.SliderInt(u8"Задержка отправки (мс)", mm_send_delay, 500, 8000) then requestSaveSettings() end
imgui.PopItemWidth()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.8, 0, 1))
imgui.TextUnformatted(u8" Внимание: Используйте задержку от 2000 мс для безопасности от админов!")
imgui.PopStyleColor()
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

end

function drawMmTestPage()
imgui.TextUnformatted(u8"Тест автозамены:")
imgui.InputText(u8"Введите черновик", test_input, 129)

if imgui.Button(u8"Проверить замену") then
local raw_text = decodeUtf8Safe(ffi.string(test_input))  -- UTF-8 -> CP1251
local fmt_ok, fmt_result = pcall(formatAdText, raw_text)
if fmt_ok then test_output = encodeCp1251Safe(fmt_result) else test_output = u8"Error: " .. tostring(fmt_result) end
end

if test_output ~= "" then
imgui.TextUnformatted(u8"Результат:")
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.8, 1))
imgui.PushTextWrapPos(0)
imgui.TextUnformatted(sanitizeUtf8(#test_output > 500 and safeUtf8Truncate(test_output, 500) or test_output))
imgui.PopTextWrapPos()
imgui.PopStyleColor()
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

end

function drawMmRulesPage()
imgui.TextUnformatted(u8"Правила замены сокращений (База):")
if imgui.InputText(u8"Поиск правил##mm_rule_filter", mm_rule_filter, ffi.sizeof(mm_rule_filter)) then mm_rule_page = 1 end
local filterText = decodeUtf8Safe(ffi.string(mm_rule_filter))
local filteredRules = getFilteredRuleIndices(filterText)
local pageSize = 6
local pageCount = math.max(1, math.ceil(#filteredRules / pageSize))
if mm_rule_page < 1 then mm_rule_page = 1 end
if mm_rule_page > pageCount then mm_rule_page = pageCount end
imgui.TextUnformatted(u8"Найдено: " .. #filteredRules .. " / " .. #mm_rules)
imgui.SameLine(280)
if imgui.SmallButton(u8"Назад##mm_rules_prev") and mm_rule_page > 1 then mm_rule_page = mm_rule_page - 1 end
imgui.SameLine()
imgui.TextUnformatted(u8"Страница " .. mm_rule_page .. "/" .. pageCount)
imgui.SameLine()
if imgui.SmallButton(u8"Далее##mm_rules_next") and mm_rule_page < pageCount then mm_rule_page = mm_rule_page + 1 end
local removeRuleIndex = nil
imgui.Spacing()
if #filteredRules == 0 then
imgui.TextUnformatted(u8"Нет совпадений")
else
local firstRule = (mm_rule_page - 1) * pageSize + 1
local lastRule = math.min(firstRule + pageSize - 1, #filteredRules)
for position = firstRule, lastRule do
local idx = filteredRules[position]
local rule = mm_rules[idx]
local ruleText = encodeCp1251Safe(rule.abbreviation) .. " -> " .. encodeCp1251Safe(rule.replacement)
if #ruleText > 120 then ruleText = safeUtf8Truncate(ruleText, 120) end
imgui.TextUnformatted(sanitizeUtf8(ruleText))
imgui.SameLine(430)
if imgui.SmallButton("X##mm_rule_" .. idx) then removeRuleIndex = idx end
imgui.Separator()
end
end
imgui.Spacing()
if removeRuleIndex then
local removedRule = table.remove(mm_rules, removeRuleIndex)
if removedRule then
mm_last_deleted_rule = {index = removeRuleIndex, rule = removedRule}
mm_rule_revision = mm_rule_revision + 1
mm_rule_status = u8"Удалено"
requestSaveRules()
end
end
if mm_last_deleted_rule then
if imgui.SmallButton(u8"Отменить удаление##mm_rule_undo") then
local restoreIndex = math.max(1, math.min(mm_last_deleted_rule.index, #mm_rules + 1))
table.insert(mm_rules, restoreIndex, mm_last_deleted_rule.rule)
mm_last_deleted_rule = nil
mm_rule_revision = mm_rule_revision + 1
mm_rule_status = u8"Восстановлено"
requestSaveRules()
end
end
if mm_rule_status ~= "" then
if mm_last_deleted_rule then imgui.SameLine() end
imgui.TextUnformatted(sanitizeUtf8(mm_rule_status))
end

static_new_abbr = static_new_abbr or imgui.new.char[65]("")
static_new_repl = static_new_repl or imgui.new.char[257]("")
imgui.InputText(u8"Сокращение", static_new_abbr, 65)
imgui.InputText(u8"Замена на...", static_new_repl, 257)
if imgui.Button(u8"Добавить правило") then
local abbr = cp1251_lower(decodeUtf8Safe(ffi.string(static_new_abbr)))  -- UTF-8 -> CP1251
local repl = decodeUtf8Safe(ffi.string(static_new_repl))  -- UTF-8 -> CP1251
if abbr ~= "" and repl ~= "" then
local duplicate = false
for _, rule in ipairs(mm_rules) do
if type(rule) == "table" and type(rule.abbreviation) == "string" and cp1251_lower(rule.abbreviation) == abbr then duplicate = true break end
end
if duplicate then
mm_rule_status = u8"Дубликат сокращения"
else
table.insert(mm_rules, {abbreviation = abbr, replacement = repl})
mm_rule_revision = mm_rule_revision + 1
mm_rule_page = 1
mm_rule_status = u8"Добавлено"
requestSaveRules()
safeStrCopy(static_new_abbr, "", ffi.sizeof(static_new_abbr))
safeStrCopy(static_new_repl, "", ffi.sizeof(static_new_repl))
end
end
end

imgui.Spacing()
mm_reset_confirm_until = mm_reset_confirm_until or 0
if os.clock() < mm_reset_confirm_until then
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.75, 0.2, 0.2, 1.0))
    if imgui.Button(u8"Точно сбросить? (нажмите ещё раз)##mm_rules_reset_yes") then
        local fresh = {}
        for i, r in ipairs(default_mm_rules) do
            fresh[i] = {abbreviation = r.abbreviation, replacement = r.replacement}
        end
        mm_rules = fresh
        mm_rule_revision = mm_rule_revision + 1
        mm_rule_page = 1
        mm_last_deleted_rule = nil
        mm_reset_confirm_until = 0
        mm_rule_status = u8"Сброшено к стандарту (" .. #mm_rules .. u8" правил)"
        requestSaveRules()
    end
    imgui.PopStyleColor()
else
    if imgui.Button(u8"Сбросить правила к стандарту##mm_rules_reset") then
        mm_reset_confirm_until = os.clock() + 4.0
    end
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()
end

function drawMmSuggestionsPage()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 0.8, 1, 1))
imgui.TextUnformatted(u8"Обучение (предложения из ваших правок в AutoEdit):")
imgui.PopStyleColor()
if #edit_corrections == 0 then
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"Пока нет предложений. Поправьте текст перед отправкой в окне AutoEdit - здесь появится предложение добавить правило.")
imgui.PopStyleColor()
else
imgui.Spacing()
for idx = 1, math.min(#edit_corrections, 6) do
local corr = edit_corrections[idx]
imgui.PushIDStr("corr_" .. idx)
local _corr_text = encodeCp1251Safe(corr.abbr) .. " -> " .. encodeCp1251Safe(corr.repl)
            if #_corr_text > 80 then _corr_text = safeUtf8Truncate(_corr_text, 80) end
            imgui.TextUnformatted(sanitizeUtf8(_corr_text))
imgui.SameLine(320)
if imgui.SmallButton(u8"Использовать") then
safeStrCopy(static_new_abbr, encodeCp1251Safe(corr.abbr), ffi.sizeof(static_new_abbr))
safeStrCopy(static_new_repl, encodeCp1251Safe(corr.repl), ffi.sizeof(static_new_repl))
mm_rule_status = u8"Подставлено из обучения — нажмите 'Добавить правило'"
mm_pending_ui_page = 3
end
imgui.SameLine()
if imgui.SmallButton(u8"X") then
table.remove(edit_corrections, idx)
requestSaveCorrections()
imgui.PopID()
break
end
imgui.PopID()
imgui.Separator()
end
imgui.Spacing()
end
end

function drawMmEditorSettings()
static_new_abbr = static_new_abbr or imgui.new.char[65]("")
static_new_repl = static_new_repl or imgui.new.char[257]("")
if imgui.Button(u8"Основные##mm_ui_general") and mm_ui_page ~= 1 then mm_pending_ui_page = 1 end
imgui.SameLine()
if imgui.Button(u8"Тест##mm_ui_test") and mm_ui_page ~= 2 then mm_pending_ui_page = 2 end
imgui.SameLine()
if imgui.Button(u8"Правила##mm_ui_rules") and mm_ui_page ~= 3 then mm_pending_ui_page = 3 end
imgui.SameLine()
if imgui.Button(u8"Обучение (" .. #edit_corrections .. ")##mm_ui_suggestions") and mm_ui_page ~= 4 then mm_pending_ui_page = 4 end
imgui.Separator()
if mm_pending_ui_page ~= nil then
mm_ui_page = mm_pending_ui_page
mm_pending_ui_page = nil
imgui.TextUnformatted(u8"Переключение вкладки...")
return
end
if mm_ui_page == 2 then
drawMmTestPage()
elseif mm_ui_page == 3 then
drawMmRulesPage()
elseif mm_ui_page == 4 then
drawMmSuggestionsPage()
else
drawMmGeneralPage()
end
end

-- ============================================================================
-- GNEWS (Государственные Новости Advance RP)
-- ============================================================================
gnews_active = false
gnews_current_step = 0
gnews_thread = nil

gnews_settings = {
    selected = 1,
    delay = 1500,
    profiles = {
        {
            name = "СМИ г. Los Santos",
            tag = "LS",
            line1 = "Уважаемые жители штата! Минуточку внимания.",
            line2 = "В радиоцентр г. Los Santos проходит собеседование в холле.",
            line3 = "Критерии: 3 года в штате, знание ПРО, опрятный вид.",
            remind = "Напоминаю, собеседование в радиоцентр г. Los Santos продолжается.",
            finish = "Собеседование в радиоцентр г. Los Santos окончено. Всем спасибо.",
            extra = "Технические неполадки на волне вещания. Просим прощения."
        },
        {
            name = "Мэрия г. Los Santos",
            tag = "Мэрия ЛС",
            line1 = "Уважаемые граждане штата! Прошу минуточку внимания.",
            line2 = "В холле Мэрии г. Los Santos проходит собеседование на должность Охранника.",
            line3 = "При себе иметь паспорт, лицензии и быть опрятно одетым.",
            remind = "Собеседование в Мэрию г. Los Santos продолжается в холле здания.",
            finish = "Собеседование в Мэрию г. Los Santos окончено. Спасибо за внимание.",
            extra = "Технические неполадки со связью. Просим прощения."
        },
        {
            name = "Больница г. Los Santos",
            tag = "HLS",
            line1 = "Уважаемые жители штата! Минуточку внимания.",
            line2 = "В холле Больницы г. Los Santos проходит собеседование на должность Интерна.",
            line3 = "Критерии: от 3-х лет в штате, паспорт, пакет лицензий.",
            remind = "Напоминаем, собеседование в Больницу г. Los Santos продолжается.",
            finish = "Собеседование в Больницу г. Los Santos окончено. Не болейте!",
            extra = "Технические неполадки государственной волны. Приносим извинения."
        },
        {
            name = "Сухопутные Войска",
            tag = "СВ",
            line1 = "Внимание жители штата! Начинается призыв в Сухопутные Войска.",
            line2 = "Призыв проходит в военкомате штата. Навигатор: 4 - 0.",
            line3 = "При себе иметь: паспорт, мед. карту, пакет лицензий.",
            remind = "Призыв в Сухопутные Войска продолжается в военкомате штата.",
            finish = "Призыв в ряды Сухопутных Войск окончен. Всем спасибо за службу.",
            extra = "Помехи на волне Министерства Обороны. Просим прощения."
        },
        {
            name = "Полиция г. Los Santos",
            tag = "LSPD",
            line1 = "Уважаемые граждане! В департаменте полиции г. Los Santos открыты вакансии.",
            line2 = "Собеседование проходит в холле департамента г. Los Santos.",
            line3 = "Критерии: от 5 лет в штате, военный билет, пакет лицензий.",
            remind = "Собеседование в полицию г. Los Santos продолжается в холле.",
            finish = "Собеседование в полицию г. Los Santos окончено.",
            extra = "Технические неполадки на волне МВД. Извиняемся."
        }
    }
}

-- FFI Buffers for GNEWS UI
gnews_buf_name = imgui.new.char[65]("")
gnews_buf_tag = imgui.new.char[33]("")
gnews_buf_line1 = imgui.new.char[257]("")
gnews_buf_line2 = imgui.new.char[257]("")
gnews_buf_line3 = imgui.new.char[257]("")
gnews_buf_remind = imgui.new.char[257]("")
gnews_buf_finish = imgui.new.char[257]("")
gnews_buf_extra = imgui.new.char[257]("")
gnews_delay_val = imgui.new.int(1500)
gnews_loaded_idx = -1

function syncGnewsBuffers(idx)
    idx = idx or gnews_settings.selected
    local p = gnews_settings.profiles[idx]
    if not p then return end
    safeStrCopy(gnews_buf_name, encodeCp1251Safe(p.name or ""), ffi.sizeof(gnews_buf_name))
    safeStrCopy(gnews_buf_tag, encodeCp1251Safe(p.tag or ""), ffi.sizeof(gnews_buf_tag))
    safeStrCopy(gnews_buf_line1, encodeCp1251Safe(p.line1 or ""), ffi.sizeof(gnews_buf_line1))
    safeStrCopy(gnews_buf_line2, encodeCp1251Safe(p.line2 or ""), ffi.sizeof(gnews_buf_line2))
    safeStrCopy(gnews_buf_line3, encodeCp1251Safe(p.line3 or ""), ffi.sizeof(gnews_buf_line3))
    safeStrCopy(gnews_buf_remind, encodeCp1251Safe(p.remind or ""), ffi.sizeof(gnews_buf_remind))
    safeStrCopy(gnews_buf_finish, encodeCp1251Safe(p.finish or ""), ffi.sizeof(gnews_buf_finish))
    safeStrCopy(gnews_buf_extra, encodeCp1251Safe(p.extra or ""), ffi.sizeof(gnews_buf_extra))
    gnews_delay_val[0] = math.max(1000, math.min(5000, p.delay or gnews_settings.delay or 1500))
    gnews_loaded_idx = idx
end

function saveCurrentGnewsProfile()
    local idx = gnews_settings.selected
    local p = gnews_settings.profiles[idx]
    if not p then return end
    p.name = decodeUtf8Safe(ffi.string(gnews_buf_name))
    p.tag = decodeUtf8Safe(ffi.string(gnews_buf_tag))
    p.line1 = decodeUtf8Safe(ffi.string(gnews_buf_line1))
    p.line2 = decodeUtf8Safe(ffi.string(gnews_buf_line2))
    p.line3 = decodeUtf8Safe(ffi.string(gnews_buf_line3))
    p.remind = decodeUtf8Safe(ffi.string(gnews_buf_remind))
    p.finish = decodeUtf8Safe(ffi.string(gnews_buf_finish))
    p.extra = decodeUtf8Safe(ffi.string(gnews_buf_extra))
    p.delay = gnews_delay_val[0]
    gnews_settings.delay = gnews_delay_val[0]
    requestSaveSettings()
end

function formatGnewsLine(tag, text)
    if not text or text == "" then return "" end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if tag and tag ~= "" then
        if not text:find("^%[") and not text:find("^" .. escapePattern(tag)) then
            if not tag:find("%|") and not tag:find("%]") then
                return tag .. " | " .. text
            else
                return tag .. " " .. text
            end
        end
    end
    return text
end

function gnewsPublishLines(lines, delay_ms)
    if not isSampAvailable() then return end
    if gnews_active then
        sampAddChatMessage("[Helper] Гос. новости уже подаются! Для отмены нажмите 'Остановить'.", 0xFFAA00)
        return
    end
    if type(lines) ~= "table" or #lines == 0 then
        sampAddChatMessage("[Helper] Ошибка: список строк /gnews пуст!", 0xFF0000)
        return
    end
    for idx, text in ipairs(lines) do
        if type(text) ~= "string" or text == "" then
            sampAddChatMessage("[Helper] Ошибка: строка #" .. idx .. " в /gnews пуста!", 0xFF4444)
            return
        end
        local cmd_full = "/gnews " .. text
        if #cmd_full > 128 then
            sampAddChatMessage("[Helper] Ошибка: строка #" .. idx .. " для /gnews превышает 128 байт (" .. #cmd_full .. ")!", 0xFF4444)
            return
        end
    end
    delay_ms = math.max(800, math.min(10000, tonumber(delay_ms) or 1500))
    gnews_active = true
    cmd_cooldowns["gnews"] = os.time() + (cmd_cooldown_durations["gnews"] or 60)
    gnews_thread = lua_thread.create(function()
        if isSampAvailable() then
            sampAddChatMessage("[Helper] Подача гос. новостей начата (" .. #lines .. " строк, КД " .. delay_ms .. "мс)...", 0x00FF90)
        end
        for idx, text in ipairs(lines) do
            if not gnews_active or not isSampAvailable() then
                gnews_active = false
                break
            end
            gnews_current_step = idx
            pcall(sampSendChat, "/gnews " .. text)
            if idx < #lines then
                wait(delay_ms)
            end
        end
        if isSampAvailable() then
            if gnews_active then
                sampAddChatMessage("[Helper] Подача гос. новостей успешно завершена!", 0x00FF00)
            else
                sampAddChatMessage("[Helper] Подача гос. новостей была остановлена.", 0xFF6600)
            end
        end
        gnews_active = false
        gnews_current_step = 0
        gnews_thread = nil
    end)
end

function stopGnews()
    if gnews_active then
        gnews_active = false
        if gnews_thread then
            pcall(function() gnews_thread:terminate() end)
            gnews_thread = nil
        end
        gnews_current_step = 0
        if isSampAvailable() then
            sampAddChatMessage("[Helper] Подача гос. новостей остановлена.", 0xFF6600)
        end
    end
end

function sendGnewsSingle(text)
    if not isSampAvailable() then return end
    if not text or text == "" then
        sampAddChatMessage("[Helper] Ошибка: строка пуста!", 0xFF0000)
        return
    end
    local cmd_full = "/gnews " .. text
    if #cmd_full > 128 then
        sampAddChatMessage("[Helper] Ошибка: строка /gnews превышает 128 байт (" .. #cmd_full .. ")!", 0xFF0000)
        return
    end
    cmd_cooldowns["gnews"] = os.time() + (cmd_cooldown_durations["gnews"] or 60)
    pcall(sampSendChat, cmd_full)
    sampAddChatMessage("[Helper] Отправлена строка в /gnews", 0x00FF90)
end

function drawGnewsSettings()
    if gnews_loaded_idx ~= gnews_settings.selected then
        syncGnewsBuffers(gnews_settings.selected)
    end

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.8, 1))
    imgui.TextUnformatted(u8"Автопубликация Гос. Новостей (/gnews) - Advance RP")
    imgui.PopStyleColor()
    imgui.Spacing()

    -- Profile selector
    imgui.TextUnformatted(u8"Профиль:")
    imgui.SameLine()
    imgui.PushItemWidth(260)
    local cur_profile = gnews_settings.profiles[gnews_settings.selected]
    local cur_name = cur_profile and cur_profile.name or "---"
    if imgui.BeginCombo("##GnewsProfileSelect", encodeCp1251Safe(cur_name)) then
        for p_idx, prof in ipairs(gnews_settings.profiles) do
            local is_sel = (gnews_settings.selected == p_idx)
            local disp_name = (type(prof.name) == "string" and prof.name ~= "") and encodeCp1251Safe(prof.name) or ("#" .. p_idx)
            if imgui.Selectable(disp_name .. "##gnews_prof_" .. p_idx, is_sel) then
                if gnews_settings.selected ~= p_idx then
                    saveCurrentGnewsProfile()
                    gnews_settings.selected = p_idx
                    syncGnewsBuffers(p_idx)
                end
            end
        end
        imgui.EndCombo()
    end
    imgui.PopItemWidth()

    imgui.SameLine()
    if imgui.Button(u8"+ Новый##gnews_new") then
        saveCurrentGnewsProfile()
        table.insert(gnews_settings.profiles, {
            name = "Новый профиль",
            tag = "Гос",
            line1 = "",
            line2 = "",
            line3 = "",
            remind = "",
            finish = "",
            extra = "",
            delay = 1500
        })
        gnews_settings.selected = #gnews_settings.profiles
        syncGnewsBuffers(gnews_settings.selected)
        requestSaveSettings()
    end

    imgui.SameLine()
    if imgui.Button(u8"Сохранить##gnews_save") then
        saveCurrentGnewsProfile()
        queueTask(function() sampAddChatMessage("[Helper] Профиль гос. новостей сохранен!", 0x00FF00) end)
    end

    if #gnews_settings.profiles > 1 then
        imgui.SameLine()
        if imgui.Button(u8"Удалить##gnews_del") then
            table.remove(gnews_settings.profiles, gnews_settings.selected)
            if gnews_settings.selected > #gnews_settings.profiles then
                gnews_settings.selected = #gnews_settings.profiles
            end
            syncGnewsBuffers(gnews_settings.selected)
            requestSaveSettings()
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Profile Edit Fields
    imgui.Columns(2, "gnews_profile_cols", false)
    imgui.SetColumnWidth(0, 320)
    imgui.SetColumnWidth(1, 460)

    imgui.TextUnformatted(u8"Название профиля:")
    imgui.PushItemWidth(300)
    if imgui.InputText("##gnews_name", gnews_buf_name, ffi.sizeof(gnews_buf_name)) then
        saveCurrentGnewsProfile()
    end
    imgui.PopItemWidth()

    imgui.NextColumn()

    imgui.TextUnformatted(u8"Тег / Префикс (например: LS, Мэрия ЛС, СВ, HLS):")
    imgui.PushItemWidth(250)
    if imgui.InputText("##gnews_tag", gnews_buf_tag, ffi.sizeof(gnews_buf_tag)) then
        saveCurrentGnewsProfile()
    end
    imgui.PopItemWidth()

    imgui.Columns(1)
    imgui.Spacing()

    -- 3 Main lines
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 0.8, 1, 1))
    imgui.TextUnformatted(u8"Основное вещание в 3 строки:")
    imgui.PopStyleColor()

    local gnews_tag_cp = decodeUtf8Safe(ffi.string(gnews_buf_tag))
    local function drawGnewsLineField(label, id_str, buf)
        local line_cp = decodeUtf8Safe(ffi.string(buf))
        local full_len = #formatGnewsLine(gnews_tag_cp, line_cp)
        imgui.TextUnformatted(label)
        if line_cp ~= "" then
            imgui.SameLine(430)
            local lcol = full_len > 128 and imgui.ImVec4(1.0, 0.25, 0.25, 1.0) or imgui.ImVec4(0.45, 0.85, 0.5, 1.0)
            imgui.PushStyleColor(imgui.Col.Text, lcol)
            imgui.TextUnformatted(u8"Длина: " .. tostring(full_len) .. " / 128")
            imgui.PopStyleColor()
        end
        imgui.PushItemWidth(-1)
        if imgui.InputText(id_str, buf, ffi.sizeof(buf)) then saveCurrentGnewsProfile() end
        imgui.PopItemWidth()
    end

    drawGnewsLineField(u8"1 строка:", "##gnews_l1", gnews_buf_line1)
    drawGnewsLineField(u8"2 строка:", "##gnews_l2", gnews_buf_line2)
    drawGnewsLineField(u8"3 строка:", "##gnews_l3", gnews_buf_line3)

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Reminder, Finish, Extra
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.8, 0.3, 1))
    imgui.TextUnformatted(u8"Одиночные строки (напоминание / окончание / тех. неполадки):")
    imgui.PopStyleColor()

    imgui.TextUnformatted(u8"Напоминание о собеседовании:")
    imgui.PushItemWidth(-1)
    if imgui.InputText("##gnews_rem", gnews_buf_remind, ffi.sizeof(gnews_buf_remind)) then saveCurrentGnewsProfile() end
    imgui.PopItemWidth()

    imgui.TextUnformatted(u8"Окончание собеседования:")
    imgui.PushItemWidth(-1)
    if imgui.InputText("##gnews_fin", gnews_buf_finish, ffi.sizeof(gnews_buf_finish)) then saveCurrentGnewsProfile() end
    imgui.PopItemWidth()

    imgui.TextUnformatted(u8"Технические неполадки:")
    imgui.PushItemWidth(-1)
    if imgui.InputText("##gnews_ext", gnews_buf_extra, ffi.sizeof(gnews_buf_extra)) then saveCurrentGnewsProfile() end
    imgui.PopItemWidth()

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Delay slider
    imgui.TextUnformatted(u8"Интервал между строками (Advance RP рекомендует 1500-2000 мс):")
    imgui.PushItemWidth(250)
    if imgui.SliderInt(u8"мс##gnews_delay", gnews_delay_val, 1000, 5000) then
        saveCurrentGnewsProfile()
    end
    imgui.PopItemWidth()

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Action Buttons!
    if gnews_active then
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 1))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1))
        if imgui.Button(u8"ОСТАНОВИТЬ ВЕЩАНИЕ (" .. gnews_current_step .. "/3)", imgui.ImVec2(280, 36)) then
            queueTask(stopGnews)
        end
        imgui.PopStyleColor(3)
    else
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.1, 0.6, 0.3, 1))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.2, 0.8, 0.4, 1))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.0, 0.5, 0.2, 1))
        if imgui.Button(u8"ПОДАТЬ 3 СТРОКИ (/gnews)", imgui.ImVec2(240, 36)) then
            saveCurrentGnewsProfile()
            local p = gnews_settings.profiles[gnews_settings.selected]
            if p then
                local l1 = formatGnewsLine(p.tag, p.line1)
                local l2 = formatGnewsLine(p.tag, p.line2)
                local l3 = formatGnewsLine(p.tag, p.line3)
                local lines = {}
                if l1 ~= "" then table.insert(lines, l1) end
                if l2 ~= "" then table.insert(lines, l2) end
                if l3 ~= "" then table.insert(lines, l3) end
                if #lines > 0 then
                    local d = gnews_delay_val[0]
                    queueTask(function() gnewsPublishLines(lines, d) end)
                else
                    queueTask(function() sampAddChatMessage("[Helper] Ошибка: строки 1-3 пусты!", 0xFF0000) end)
                end
            end
        end
        imgui.PopStyleColor(3)
    end

    imgui.SameLine()
    if imgui.Button(u8"Подать Напоминание", imgui.ImVec2(160, 36)) then
        saveCurrentGnewsProfile()
        local p = gnews_settings.profiles[gnews_settings.selected]
        if p then
            local t = formatGnewsLine(p.tag, p.remind)
            queueTask(function() sendGnewsSingle(t) end)
        end
    end

    imgui.SameLine()
    if imgui.Button(u8"Подать Окончание", imgui.ImVec2(160, 36)) then
        saveCurrentGnewsProfile()
        local p = gnews_settings.profiles[gnews_settings.selected]
        if p then
            local t = formatGnewsLine(p.tag, p.finish)
            queueTask(function() sendGnewsSingle(t) end)
        end
    end

    imgui.Spacing()
    if imgui.Button(u8"Тех. Неполадки", imgui.ImVec2(160, 32)) then
        saveCurrentGnewsProfile()
        local p = gnews_settings.profiles[gnews_settings.selected]
        if p then
            local t = formatGnewsLine(p.tag, p.extra)
            queueTask(function() sendGnewsSingle(t) end)
        end
    end
    imgui.SameLine()
    if imgui.Button(u8"Предпросмотр (в чат)##gnews_preview", imgui.ImVec2(190, 32)) then
        saveCurrentGnewsProfile()
        local p = gnews_settings.profiles[gnews_settings.selected]
        if p then
            local l1 = formatGnewsLine(p.tag, p.line1)
            local l2 = formatGnewsLine(p.tag, p.line2)
            local l3 = formatGnewsLine(p.tag, p.line3)
            queueTask(function()
                sampAddChatMessage("[Helper GNEWS Предпросмотр]:", 0x00CCFF)
                if l1 ~= "" then sampAddChatMessage("  1: /gnews " .. l1, 0xCECECE) end
                if l2 ~= "" then sampAddChatMessage("  2: /gnews " .. l2, 0xCECECE) end
                if l3 ~= "" then sampAddChatMessage("  3: /gnews " .. l3, 0xCECECE) end
            end)
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 0.9, 1.0, 1.0))
    imgui.TextUnformatted(u8"Планировщик волны (/gnews) и бронь в /l:")
    imgui.PopStyleColor()

    imgui.PushItemWidth(120)
    imgui.InputText(u8"Время волны (ЧЧ:ММ:СС)##gnews_sched_time", gnews_sched_time_buf, ffi.sizeof(gnews_sched_time_buf))
    imgui.PopItemWidth()

    imgui.PushItemWidth(340)
    imgui.InputText(u8"Шаблон /l##gnews_l_tpl", gnews_l_template_buf, ffi.sizeof(gnews_l_template_buf))
    if imgui.IsItemDeactivatedAfterEdit() then requestSaveSettings() end
    imgui.PopItemWidth()

    if imgui.Button(u8"Запланировать##gnews_sched_start", imgui.ImVec2(140, 28)) then
        saveCurrentGnewsProfile()
        local sched_t = decodeUtf8Safe(ffi.string(gnews_sched_time_buf))
        queueTask(function() P3_scheduleGnews(sched_t) end)
    end
    imgui.SameLine()
    if imgui.Button(u8"Отменить##gnews_sched_cancel", imgui.ImVec2(105, 28)) then
        queueTask(P3_cancelGnewsSchedule)
    end
    imgui.SameLine()
    if imgui.Button(u8"Занять в /l##gnews_book_l", imgui.ImVec2(130, 28)) then
        saveCurrentGnewsProfile()
        local sched_t = decodeUtf8Safe(ffi.string(gnews_sched_time_buf))
        queueTask(function() P3_sendGnewsBookingL(sched_t) end)
    end

    if gnews_sched_active and gnews_sched_target_ts then
        local rem = math.max(0, gnews_sched_target_ts - os.time())
        local rem_txt = P3_formatDurationShort and P3_formatDurationShort(rem) or (tostring(rem) .. "с")
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 1.0, 0.5, 1.0))
        imgui.TextUnformatted(encodeCp1251Safe("Таймер активен на " .. gnews_sched_target_str .. " | Осталось: " .. rem_txt))
        imgui.PopStyleColor()
    elseif P3.gnews_status and P3.gnews_status ~= "" then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.75, 0.3, 1.0))
        imgui.TextUnformatted(encodeCp1251Safe(P3.gnews_status))
        imgui.PopStyleColor()
    end

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.55, 1.0))
    imgui.TextUnformatted(u8"-> За 15 сек до волны сработает звук; ровно в ЧЧ:ММ:СС подаются 3 строки /gnews")
    imgui.PopStyleColor()
    imgui.Spacing()
end

modules = {
{
id = "gnews",
name = u8" Гос. Новости (/gnews)",
description = u8"Автоматическая подача государственных новостей (/gnews) на Advance RP с профилями, 3 строками вещания, напоминаниями и настраиваемым интервалом.",
enabled = true,
drawSettings = drawGnewsSettings,
onToggle = function(state) end
},

{
id = "autocall_db",
name = u8" Сбор и Обзвон",
description = u8"Скрипт автоматически сканирует чат СМИ на сервере, извлекает ники продавцов и их номера телефонов, сохраняя их в базу.\nЗатем вы можете в 1 клик прозвонить 1-3 случайных игроков, которые сейчас ОНЛАЙН, без спама одним и тем же лицам.",
enabled = false,
drawSettings = function()
local total_records = 0
for _ in pairs(player_db) do total_records = total_records + 1 end

imgui.TextUnformatted(u8"Статистика:")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"Всего контактов в базе: " .. total_records)

if os.time() - online_list_cache_time > 3 then
    online_list_cache = getOnlinePlayersFromDb()
    online_list_cache_time = os.time()
end
local online_list = online_list_cache
local callable_online = 0
for _, entry in ipairs(online_list) do
    if canCallNick(entry.nick) then callable_online = callable_online + 1 end
end
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"Контактов онлайн: " .. #online_list .. u8" | Можно позвонить сейчас: " .. callable_online)

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextUnformatted(u8"Настройки обзвона:")
imgui.PushItemWidth(150)
if imgui.SliderInt(u8"Задержка вызова (мс)", call_delay, 2000, 15000) then requestSaveSettings() end
if imgui.InputInt(u8"Лимит звонков за сессию", max_calls_session) then
    if max_calls_session[0] < 1 then max_calls_session[0] = 1 end
    if max_calls_session[0] > 500 then max_calls_session[0] = 500 end
    requestSaveSettings()
end
if imgui.SliderInt(u8"Не звонить повторно (часов)", call_cooldown_hours, 0, 24) then
    if call_cooldown_hours[0] < 0 then call_cooldown_hours[0] = 0 end
    if call_cooldown_hours[0] > 24 then call_cooldown_hours[0] = 24 end
    requestSaveSettings()
end
imgui.PopItemWidth()
if imgui.Checkbox(u8"Не звонить тем, кому уже звонили сегодня", call_skip_today) then requestSaveSettings() end
if imgui.Checkbox(u8"Не повторять вообще (полная история)", call_no_repeat) then requestSaveSettings() end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"Учитываются как авто-обзвон, так и ручные /c [номер] и /calln [ник].")
imgui.PopStyleColor()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

local called_recently = 0
if call_no_repeat[0] then
    called_recently = 0
    for nick, t in pairs(last_called) do called_recently = called_recently + 1 end
else
    for nick, t in pairs(last_called) do
    if os.time() - t < call_cooldown_hours[0] * 3600 then called_recently = called_recently + 1 end
    end
end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 1, 1))
imgui.TextUnformatted(u8"Прогресс:")
imgui.PopStyleColor()
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"Позвонили за время кулдауна: " .. called_recently)

imgui.Spacing()
if imgui.Button(u8"Сбросить историю звонков") then
last_called_queue = {{nick = "__CLEAR__", time = 0}}
requestSaveSettings() queueTask(function() sampAddChatMessage("[Helper] История звонков сброшена", 0x00FF00) end)
end
imgui.SameLine()
if imgui.Button(u8"Очистить БД") then
player_db_queue = {{sender = "__CLEAR__", phone = ""}}
last_called_queue = {{nick = "__CLEAR__", time = 0}}
requestSaveDatabase() requestSaveSettings() queueTask(function() sampAddChatMessage("[Helper] БА очищена", 0x00FF00) end)
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if call_active then
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0, 1))
imgui.TextUnformatted(u8"Статус: Идет обзвон...")
imgui.PopStyleColor()
imgui.TextUnformatted(u8"Звоним: " .. encodeCp1251Safe(call_current_nick) .. " (" .. call_current_phone .. ")")
if imgui.Button(u8"Остановить обзвон") then call_active = false end
else
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.5, 0, 1))
imgui.TextUnformatted(u8"Статус: Ожидание")
imgui.PopStyleColor()
if #online_list > 0 then
if imgui.Button(u8" Обзвонить онлайн-игроков") then
if not call_worker_running then
call_active = true
call_worker_running = true
show_main_window[0] = false
queueTask(function() lua_thread.create(onlineCallWorker, online_list) end)
end
end
else
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1))
imgui.TextUnformatted(u8"Нет контактов онлайн для обзвона")
imgui.PopStyleColor()
end
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextUnformatted(u8"Телефонная книга (команды: /calln [ник], /smsn [ник] [текст], /lsms [текст]):")
imgui.PushItemWidth(250)
imgui.InputText(u8"Поиск контакта##db_search", db_search_buf, ffi.sizeof(db_search_buf))
imgui.PopItemWidth()

if os.time() - db_sorted_cache_time > 3 then
    db_sorted_cache = {}
    for nick, data in pairs(player_db) do
        table.insert(db_sorted_cache, {nick = nick, data = data})
    end
    table.sort(db_sorted_cache, function(a, b) return a.nick < b.nick end)
    db_sorted_cache_time = os.time()
end

local db_q = cp1251_lower(decodeUtf8Safe(ffi.string(db_search_buf)))
imgui.BeginChild("##db_contacts_scroll", imgui.ImVec2(0, 190), true)
local shown_db = 0
for i = 1, #db_sorted_cache do
    local entry = db_sorted_cache[i]
    local phone_s = tostring(entry.data and entry.data.phone or "")
    local match_q = (db_q == "") or cp1251_lower(entry.nick):find(db_q, 1, true) or phone_s:find(db_q, 1, true)
    if match_q then
        shown_db = shown_db + 1
        local pid_on = getOnlinePlayerIdByNick(entry.nick)
        local status_on = pid_on and (" [ID:" .. pid_on .. "]") or ""
        local called_mark = (not canCallNick(entry.nick)) and u8" [звонили]" or ""
        if pid_on then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 1.0, 0.4, 1.0))
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85, 0.85, 0.85, 1.0))
        end
        imgui.TextUnformatted(encodeCp1251Safe(entry.nick .. status_on .. " | " .. phone_s) .. called_mark)
        imgui.PopStyleColor()
        imgui.SameLine(370)
        if imgui.SmallButton(u8"Звонок##db_call_" .. i) then
            local pnum = phone_s
            local cnick = entry.nick
            queueTask(function()
                if isSampAvailable() and pnum ~= "" then
                    sampSendChat("/c " .. pnum)
                    table.insert(last_called_queue, {nick = cnick, time = os.time()})
                end
            end)
        end
        if shown_db >= 60 then break end
    end
end
if shown_db == 0 then
    imgui.TextUnformatted(u8"Контакты не найдены.")
end
imgui.EndChild()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if imgui.Button(u8"Показать историю звонков") then
    call_history_show[0] = not call_history_show[0]
end

if call_history_show[0] then
    imgui.Spacing()
    local hist_count = 0
    for _ in pairs(last_called) do hist_count = hist_count + 1 end
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 1, 1))
    imgui.TextUnformatted(u8"История звонков (" .. hist_count .. "):")
    imgui.PopStyleColor()
    if hist_count == 0 then
        imgui.TextUnformatted(u8"История пуста.")
    else
        local sorted = {}
        for nick, t in pairs(last_called) do
            table.insert(sorted, {nick = nick, time = t})
        end
        table.sort(sorted, function(a, b) return a.time > b.time end)
        local hist_show = math.min(#sorted, 20)
        for i = 1, hist_show do
            local entry = sorted[i]
            local phone = ""
            if player_db[entry.nick] then phone = player_db[entry.nick].phone or "" end
            local time_str = os.date("%d.%m %H:%M", entry.time)
            imgui.TextUnformatted(encodeCp1251Safe(entry.nick) .. " | " .. phone .. " | " .. time_str)
        end
    end
end
end,
onToggle = function(state)
if not state then call_active = false call_worker_running = false end
end
},
{
id = "auto_ad",
name = u8" Авто-Объявления",
description = u8"Автоматически отправляет объявления с заданным интервалом. Поддерживает шаблоны и историю.",
enabled = false,
drawSettings = (function()
    local static_aad_last_synced = nil
    return function()
    static_aad_buf = static_aad_buf or imgui.new.char[257]("")
    if static_aad_last_synced ~= aad_text then
        safeStrCopy(static_aad_buf, encodeCp1251Safe(aad_text), ffi.sizeof(static_aad_buf))
        static_aad_last_synced = aad_text
    end
static_aad_active = static_aad_active or imgui.new.bool(false)
    static_aad_active[0] = aad_active
    if imgui.Checkbox(u8"Активировать авто-объявления##checkbox_aad", static_aad_active) then
        aad_active = static_aad_active[0]
        if aad_active then
            aad_text = decodeUtf8Safe(ffi.string(static_aad_buf))
            static_aad_last_synced = aad_text
            queueTask(function() sendAdCommand(aad_text) end)
        end
    end

    imgui.PushItemWidth(350)
    if imgui.InputText(u8"Текст объявления##input_aad", static_aad_buf, ffi.sizeof(static_aad_buf)) then
        aad_text = decodeUtf8Safe(ffi.string(static_aad_buf))
        static_aad_last_synced = aad_text
    end
    if imgui.SliderInt(u8"Интервал между подачами (мс)##delay_aad", aad_delay, 3000, 30000) then requestSaveSettings() end
    imgui.PopItemWidth()

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))

    imgui.TextUnformatted(u8"-> Вы можете также использовать команду: /aad [текст]")

    imgui.PopStyleColor()
    imgui.Spacing()

    imgui.Columns(2, "aad_columns", true)
    imgui.SetColumnWidth(0, 290)
    imgui.SetColumnWidth(1, 290)

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 0.8, 1, 1))

    imgui.TextUnformatted(u8"Шаблоны объявлений:")

    imgui.PopStyleColor()
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
                requestSaveSettings()
            end
        end
    end

    imgui.BeginChild("templates_child", imgui.ImVec2(280, 150), true)
    if #aad_templates > 0 then
        for idx, tpl in ipairs(aad_templates) do
            imgui.PushIDStr("tpl_" .. idx)
            if imgui.Button(u8"Выбрать") then
                safeStrCopy(static_aad_buf, tpl, ffi.sizeof(static_aad_buf))
                aad_text = decodeUtf8Safe(tpl)  -- UTF-8 -> CP1251 for sending
                static_aad_last_synced = aad_text
                requestSaveSettings()
            end
            imgui.SameLine()
            if imgui.Button(u8"X") then
                table.remove(aad_templates, idx)
                requestSaveSettings()
                imgui.PopID()
                break
            end
            imgui.SameLine()
            imgui.TextUnformatted(sanitizeUtf8(type(tpl) == "string" and tpl or tostring(tpl)))  -- already UTF-8
            imgui.PopID()
        end
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
        imgui.TextUnformatted(u8"Нет сохраненных шаблонов.")
        imgui.PopStyleColor()
    end
    imgui.EndChild()

    imgui.NextColumn()

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.7, 0.3, 1))

    imgui.TextUnformatted(u8"История объявлений:")

    imgui.PopStyleColor()
    imgui.SameLine()
    if imgui.Button(u8"Очистить##clear_hist", imgui.ImVec2(70, 20)) then
        aad_history = {}
        requestSaveSettings()
    end

    imgui.BeginChild("history_child", imgui.ImVec2(280, 150), true)
    if #aad_history > 0 then
        for idx, hist in ipairs(aad_history) do
            imgui.PushIDStr("hist_" .. idx)
            if imgui.Button(u8"Выбрать") then
                safeStrCopy(static_aad_buf, hist, ffi.sizeof(static_aad_buf))
                aad_text = decodeUtf8Safe(hist)  -- UTF-8 -> CP1251 for sending
                static_aad_last_synced = aad_text
                requestSaveSettings()
            end
            imgui.SameLine()
            if imgui.Button(u8"X") then
                table.remove(aad_history, idx)
                requestSaveSettings()
                imgui.PopID()
                break
            end
            imgui.SameLine()
            imgui.TextUnformatted(sanitizeUtf8(type(hist) == "string" and hist or tostring(hist)))  -- already UTF-8
            imgui.PopID()
        end
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
        imgui.TextUnformatted(u8"История пуста.")
        imgui.PopStyleColor()
    end
    imgui.EndChild()

    imgui.Columns(1)
    imgui.Spacing()
end
end)(),
onToggle = function(state) end
},
{
id = "mm_editor",
name = u8" MM Editor (СМИ)",
description = u8"Помощник для сотрудников радиоцентра (СМИ). Автоматически заменяет сокращения при редактировании объявлений с учетом правил ПРО (город пишется для домов/бизнесов, но стирается для автомобилей).",
enabled = false,
drawSettings = drawMmEditorSettings,
onToggle = function(state) end
},
{
id = "auto_rp",
enabled = true,
name = u8" Авто-Отыгровки",
description = u8"Авто-отыгровки от игровых событий и команд (через SAMP onSendCommand): смена почти любого оружия, звонки/SMS, /call, /c 60, /h, /mask, /healme, /drugs, /e (двигатель), /pass, /lic, /med.",
drawSettings = function()
imgui.TextUnformatted(u8"Пол отыгровок:")
imgui.SameLine()
imgui.PushItemWidth(160)
local gender_items = u8"Мужской" .. "\0" .. u8"Женский" .. "\0"
if imgui.ComboStr("##rp_gender", rp_gender, gender_items) then requestSaveSettings() end
imgui.PopItemWidth()
imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if imgui.Checkbox(u8"Отыгровка смены оружия (в руках / за спину)", rp_weapons_enabled) then requestSaveSettings() end
local w_info = weapon_info[rp_current_weapon_id]
local w_name = rp_current_weapon_id == 0 and "Кулаки / пусто" or (w_info and w_info.name or ("ID " .. tostring(rp_current_weapon_id)))
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.8, 0.5, 1))
imgui.TextUnformatted(u8"-> Текущее оружие в руках: " .. encodeCp1251Safe(w_name))
imgui.PopStyleColor()

if imgui.Checkbox(u8"Отыгровка звонков, SMS и часов (/call, /c, /h)", rp_phone_enabled) then requestSaveSettings() end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> Срабатывает на команды /call, /c, /c 60, /h и входящие звонки/SMS")
imgui.PopStyleColor()

if imgui.Checkbox(u8"Отыгровка надевания маски (/mask)", rp_mask_enabled) then requestSaveSettings() end
if imgui.Checkbox(u8"Отыгровка аптечки и лекарств (/healme, /drugs)", rp_heal_enabled) then requestSaveSettings() end
if imgui.Checkbox(u8"Отыгровка двигателя (/e)", rp_engine_enabled) then requestSaveSettings() end
if imgui.Checkbox(u8"Отыгровка показа документов (/pass, /lic, /med)", rp_docs_enabled) then requestSaveSettings() end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()
if imgui.Button(u8"Тест отыгровки (в чат локально)") then
    local sample = "/me " .. rpVerb("достал", "достала") .. ' пистолет "Desert Eagle" из кобуры'
    queueTask(function()
        if isSampAvailable() then
            sampAddChatMessage("[Helper RP Тест] " .. sample, 0x00FFAA)
        end
    end)
end
end,
onToggle = function(state) end
},
{
id = "vehicle_visuals",
name = u8" Транспорт и Визуал",
description = u8"Функции для водителей и визуальная кастомизация мира. Включает стробоскопы фарами, круиз-контроль, локальную смену погоды/времени и скин-ченджер.",
enabled = false,
drawSettings = function()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"Стробоскопы и Круиз:")
imgui.PopStyleColor()
if imgui.Checkbox(u8"Включить стробоскопы", strobe_enabled) then
if strobe_enabled[0] then
strobe_active = true
if not strobe_worker_running then
queueTask(function() if not strobe_worker_running then lua_thread.create(strobeWorker) end end)
end
else
strobe_active = false
end
end
imgui.SameLine(220)
        if imgui.Checkbox(u8"Турбо / Спорт-режим (фан, риск бана!)", turbo_cruise_enabled) then requestSaveSettings() end
        imgui.TextUnformatted(u8"Обычный круиз: C=вкл/выкл  W=+5  S=-5 (при активном модуле)")
        if turbo_cruise_enabled[0] then
            imgui.PushItemWidth(220)
            local boost_modes = u8"Спорт-кнопка (Alt + W)" .. "\0" .. u8"Спорт-кнопка (Shift + W)" .. "\0" .. u8"Классический круиз (C, W/S)" .. "\0"
            if imgui.ComboStr(u8"Режим турбо", turbo_boost_mode, boost_modes) then requestSaveSettings() end
            if imgui.SliderInt(u8"Сила ускорения", turbo_power, 1, 8) then requestSaveSettings() end
            if imgui.SliderInt(u8"Лимит скорости (GTA ед.)", turbo_max_speed, 25, 90) then requestSaveSettings() end
            imgui.PopItemWidth()
            if imgui.Checkbox(u8"Пауза буста в поворотах (A/D) и на тормозе (S/Space)", turbo_turn_assist) then requestSaveSettings() end
        end

imgui.PushItemWidth(150)
if imgui.SliderInt(u8"Скорость стробоскопов (мс)", strobe_speed, 50, 600) then requestSaveSettings() end

local strobe_items = u8"Обе вместе" .. "\0" .. u8"Попеременно" .. "\0" .. u8"Гирлянда (по одной)" .. "\0" .. u8"Двойной лево/право" .. "\0" .. u8"Быстрый оба (3х)" .. "\0" .. u8"Очень быстрый оба (5х)" .. "\0" .. u8"Полицейский 1" .. "\0" .. u8"Полицейский 2 (3+3+обе)" .. "\0" .. u8"Полицейский 3 (быстрый)" .. "\0" .. u8"SOS (Морзе)" .. "\0" .. u8"Волна" .. "\0" .. u8"Импульс (вспышка+пауза)" .. "\0" .. u8"Двойная гирлянда" .. "\0" .. u8"Тройная вспышка (спец)" .. "\0" .. u8"Зигзаг" .. "\0" .. u8"Энергичный (2х2)" .. "\0" .. u8"Маяк (медленный)" .. "\0" .. u8"Перекрёстный" .. "\0" .. u8"Каскад (нарастающий)" .. "\0"

if imgui.ComboStr(u8"Режим стробоскопов", strobe_mode, strobe_items) then
requestSaveSettings()
end
imgui.PopItemWidth()
if imgui.Checkbox(u8"Авто-стробы при включённой сирене", siren_auto_strobe) then
    if not siren_auto_strobe[0] then
        P2.siren_was_on = false
        if P2.siren_started_strobe then
            P2.siren_started_strobe = false
            strobe_active = false
            strobe_enabled[0] = false
        end
    end
    requestSaveSettings()
end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.55, 1))
imgui.TextUnformatted(u8"-> Включает стробы при мигалке (МВД/МЗ) и возвращает фары при выключении")
imgui.PopStyleColor()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))

imgui.TextUnformatted(u8"Окружение (Локально):")

imgui.PopStyleColor()

if imgui.Checkbox(u8"Зафиксировать погоду", weather_locked) then requestSaveSettings() end
if weather_locked[0] then
imgui.PushItemWidth(250)
if imgui.SliderInt(u8"ID Погоды", weather_id, 0, 45) then requestSaveSettings() end
imgui.PopItemWidth()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"Популярные ID: 1-2 (ясно), 8 (шторм), 9 (туман), 19 (песок)")
imgui.PopStyleColor()
end

if imgui.Checkbox(u8"Зафиксировать время суток", time_locked) then requestSaveSettings() end
if time_locked[0] then
imgui.PushItemWidth(250)
if imgui.SliderInt(u8"Часы", time_hour, 0, 23) then requestSaveSettings() end
imgui.PopItemWidth()
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))

imgui.TextUnformatted(u8"Скин-Ченджер (Локально):")

imgui.PopStyleColor()
imgui.PushItemWidth(150)
imgui.InputInt(u8"ID Скина (0-311)", skin_changer_id)
imgui.PopItemWidth()

if imgui.Button(u8"Применить скин") then
local sid = skin_changer_id[0]
queueTask(function() applyLocalSkin(sid) end)
end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> Вы также можете ввести команду в чат: /fskin [ID]")
imgui.PopStyleColor()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"Инфо-панель (HUD) и Калькулятор:")
imgui.PopStyleColor()
if imgui.Checkbox(u8"Показывать компактный HUD (Время / PayDay / Статусы)", hud_enabled) then
    requestSaveSettings()
end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> Команды: /hud (вкл/выкл HUD), /calc [пример] (напр. /calc 1.5кк * 3 + 500к)")
imgui.PopStyleColor()
imgui.Spacing()
imgui.Separator()
imgui.Spacing()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"Свободная камера (Дрон /cam):")
imgui.PopStyleColor()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.65, 0.2, 1.0))
imgui.TextUnformatted(u8"(только для скринов/осмотра, соблюдайте правила сервера!)")
imgui.PopStyleColor()
if imgui.Checkbox(u8"Разрешить свободную камеру (/cam)", cam_feature_enabled) then
    if not cam_feature_enabled[0] and cam_active then
        queueTask(P5_exitFreeCam)
    end
    requestSaveSettings()
end
imgui.PushItemWidth(200)
if imgui.SliderFloat(u8"Скорость полёта", cam_speed, 0.1, 3.0, "%.2f") then
    requestSaveSettings()
end
imgui.PopItemWidth()
if imgui.Button(u8"Вкл/Выкл /cam##p5_cam_toggle", imgui.ImVec2(145, 26)) then
    queueTask(P5_toggleFreeCam)
end
imgui.SameLine()
if cam_active then
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 1.0, 0.4, 1.0))
    imgui.TextUnformatted(u8"Статус: АКТИВНА")
    imgui.PopStyleColor()
else
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1.0))
    imgui.TextUnformatted(u8"Статус: выкл")
    imgui.PopStyleColor()
end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.55, 1.0))
imgui.TextUnformatted(u8"-> WASD — полёт, Space/Shift — вверх/вниз, Q/E и Стрелки — обзор")
imgui.TextUnformatted(u8"-> Выход и возврат камеры: Backspace, F11 или /cam")
imgui.PopStyleColor()
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
description = u8"Привязка команд и многострочных отыгровок РП-движка к клавишам и комбинациям (Alt/Ctrl/Shift + A-Z, 0-9, F2-F10, Numpad).\nНе срабатывает при открытом чате или диалоге.",
enabled = true,
drawSettings = function()
imgui.TextUnformatted(u8"Текущие бинды:")
imgui.Spacing()
for i, bind in ipairs(keybinds) do
static_bind_en = static_bind_en or imgui.new.bool(false); static_bind_en[0] = bind.enabled; local en = static_bind_en
if imgui.Checkbox("##en" .. i, en) then
bind.enabled = en[0]
requestSaveSettings()
end
imgui.SameLine()
local mprefix = bind_mod_names[bind.mod or 0] or ""
local kname = mprefix .. (key_names[bind.key] or ("0x" .. string.format("%02X", bind.key)))
local desc_txt
if bind.action_type == "rp" then
    local ch_list = rp_settings.set[bind.rp_chapter or 1]
    local rp_item = ch_list and ch_list[bind.rp_index or 1]
    local rp_label = rp_item and rp_item.name or ("#" .. tostring(bind.rp_index or 1))
    desc_txt = "[" .. kname .. "] " .. bind.name .. "  (RP: " .. rp_label .. ")"
else
    desc_txt = "[" .. kname .. "] " .. bind.name .. "  (" .. (bind.command or "") .. ")"
end
imgui.TextUnformatted(encodeCp1251Safe(desc_txt))
imgui.SameLine(400)
if imgui.Button(u8"Удалить##del" .. i) then
table.remove(keybinds, i)
requestSaveSettings()
break
end
end
imgui.Spacing()
imgui.Separator()
imgui.Spacing()
imgui.TextUnformatted(u8"Добавить новый бинд:")

local key_keys = {}
for k, _ in pairs(key_names) do
    table.insert(key_keys, k)
end
table.sort(key_keys)

imgui.PushItemWidth(90)
local mod_items = u8"Нет" .. "\0Alt\0Ctrl\0Shift\0"
imgui.ComboStr(u8"Мод.##new_bind_mod", new_bind_mod, mod_items)
imgui.PopItemWidth()

imgui.SameLine()
imgui.PushItemWidth(100)
if imgui.BeginCombo("##newkey", key_names[new_bind_key[0]] or u8"Выбрать") then
for _, k in ipairs(key_keys) do
if imgui.Selectable(key_names[k] .. "##k_" .. k, new_bind_key[0] == k) then
new_bind_key[0] = k
end
end
imgui.EndCombo()
end
imgui.PopItemWidth()

imgui.SameLine()
imgui.PushItemWidth(140)
local type_items = u8"Команда чата" .. "\0" .. u8"РП-отыгровка" .. "\0"
imgui.ComboStr("##new_bind_type", new_bind_type, type_items)
imgui.PopItemWidth()

imgui.Spacing()
if new_bind_type[0] == 1 then
    local ch_items = u8"Общие" .. "\0" .. u8"Мои отыгровки" .. "\0" .. u8"Для цели" .. "\0"
    imgui.PushItemWidth(160)
    if imgui.ComboStr(u8"Глава##kb_rp_ch", new_bind_rp_chapter, ch_items) then
        new_bind_rp_idx[0] = 0
    end
    imgui.PopItemWidth()

    local ch = new_bind_rp_chapter[0] + 1
    local list = rp_settings.set[ch] or {}
    if new_bind_rp_idx[0] >= #list then new_bind_rp_idx[0] = 0 end
    local cur_rp = list[new_bind_rp_idx[0] + 1]
    local preview_rp = cur_rp and encodeCp1251Safe(cur_rp.name ~= "" and cur_rp.name or ("#" .. (new_bind_rp_idx[0] + 1))) or u8"(пусто)"
    imgui.SameLine()
    imgui.PushItemWidth(220)
    if imgui.BeginCombo(u8"Отыгровка##kb_rp_item", preview_rp) then
        for idx, rp in ipairs(list) do
            local rname = encodeCp1251Safe(rp.name ~= "" and rp.name or ("#" .. idx))
            if imgui.Selectable(rname .. "##kb_rp_" .. idx, new_bind_rp_idx[0] == (idx - 1)) then
                new_bind_rp_idx[0] = idx - 1
            end
        end
        imgui.EndCombo()
    end
    imgui.PopItemWidth()

    imgui.PushItemWidth(200)
    imgui.InputText(u8"Название##newname", new_bind_name, ffi.sizeof(new_bind_name))
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.Button(u8"+ Добавить РП-бинд") and cur_rp then
        local nm = decodeUtf8Safe(ffi.string(new_bind_name))
        if nm == "" then nm = cur_rp.name ~= "" and cur_rp.name or "RP" end
        table.insert(keybinds, {
            key = new_bind_key[0],
            mod = new_bind_mod[0],
            action_type = "rp",
            rp_chapter = ch,
            rp_index = new_bind_rp_idx[0] + 1,
            command = "",
            enabled = true,
            name = nm
        })
        safeStrCopy(new_bind_name, "", ffi.sizeof(new_bind_name))
        requestSaveSettings()
    end
else
    imgui.PushItemWidth(180)
    imgui.InputText(u8"Команда##newcmd", new_bind_command, ffi.sizeof(new_bind_command))
    imgui.PopItemWidth()
    imgui.SameLine()
    imgui.PushItemWidth(160)
    imgui.InputText(u8"Название##newname", new_bind_name, ffi.sizeof(new_bind_name))
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.Button(u8" + Добавить ") then
        local cmd = decodeUtf8Safe(ffi.string(new_bind_command))
        local nm = decodeUtf8Safe(ffi.string(new_bind_name))
        if cmd ~= "" then
            if nm == "" then nm = cmd end
            table.insert(keybinds, {
                key = new_bind_key[0],
                mod = new_bind_mod[0],
                action_type = "cmd",
                rp_chapter = 1,
                rp_index = 1,
                command = cmd,
                enabled = true,
                name = nm
            })
            safeStrCopy(new_bind_command, "", ffi.sizeof(new_bind_command))
            safeStrCopy(new_bind_name, "", ffi.sizeof(new_bind_name))
            requestSaveSettings()
        end
    end
end
imgui.Spacing()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
imgui.TextUnformatted(u8"Команды (/lock, /e, /me ...) или готовые многострочные отыгровки РП-движка.")
imgui.PopStyleColor()
end,
},
{
id = "commands_guide",
name = u8" Справочник Команд",
description = u8"Полный и точный список команд сервера Advance RP по фракциям. Дважды кликните по любой команде в списке, чтобы скопировать её в буфер обмена.",
enabled = true,
drawSettings = function()
imgui.TextUnformatted(u8"Выберите категорию фракций:")
static_selected_cat = static_selected_cat or imgui.new.int(1)
if static_selected_cat[0] < 1 then static_selected_cat[0] = 1 end
if static_selected_cat[0] > #advance_commands then static_selected_cat[0] = #advance_commands end

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

local cat_idx = math.max(1, math.min(#advance_commands, static_selected_cat[0]))
local active_cat = advance_commands[cat_idx]
imgui.BeginChild("commands_scroll", imgui.ImVec2(0, 180), true)
for _, cmd in ipairs(active_cat.cmds) do
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 0.9, 0.7, 1))
imgui.TextUnformatted(cmd.name)
imgui.PopStyleColor()

if imgui.IsItemHovered() then
imgui.BeginTooltip()
imgui.TextUnformatted(u8"Двойной клик: скопировать в буфер")
imgui.EndTooltip()
if imgui.IsMouseDoubleClicked(0) then
local clip_txt = cmd.name
queueTask(function()
    if type(setClipboardText) == "function" then pcall(setClipboardText, clip_txt) end
    sampAddChatMessage("[Helper] Скопировано в буфер: " .. clip_txt, 0x00FFFF)
end)
end
end

imgui.SameLine(180)
imgui.PushTextWrapPos(0)
imgui.TextUnformatted(cmd.desc)
imgui.PopTextWrapPos()
imgui.Separator()
end
imgui.EndChild()
end,
onToggle = function(state) end
},
{
id = "rp_engine",
name = u8" РП-Движок (Отыгровки)",
description = u8"Кастомные РП-отыгровки с поддержкой тегов, пауз, рандома и интерактивных окон. Команды: /mmact [id], /mmnext, /mmstop, /rpeditor, /rptest, /rplogin.",
enabled = true,
drawSettings = function()
if imgui.Button(u8"Открыть редактор отыгровок", imgui.ImVec2(220, 30)) then rp_show_edit[0] = true end
imgui.SameLine()
if imgui.Button(u8"Загрузить статистику", imgui.ImVec2(150, 30)) then queueTask(playerLogin) end
imgui.Spacing()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.8, 0.5, 1))
imgui.TextUnformatted(u8"Игрок: " .. encodeCp1251Safe(user.fullName))
imgui.TextUnformatted(u8"Должность: " .. encodeCp1251Safe(user.rangName))
imgui.TextUnformatted(u8"Подразделение: " .. encodeCp1251Safe(user.podr))
imgui.TextUnformatted(u8"Телефон: " .. encodeCp1251Safe(user.phone))
imgui.PopStyleColor()
imgui.Spacing()
imgui.Separator()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))
imgui.TextUnformatted(u8"Команды:")
imgui.PopStyleColor()
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/mmact [id] — выбрать цель и открыть отыгровки")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/mmnext — продолжить отыгровку после паузы <0>")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/mmstop — остановить отыгровку")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/rpeditor — открыть редактор отыгровок")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/rptest — тест выбранной отыгровки")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/rplogin — загрузить статистику игрока")
end,
onToggle = function(state) end
},
{
id = "smi_tools",
name = u8" СМИ-Инструменты",
description = u8"Анаграммы (270+ без повторов), режиссёр викторин /quiz, эфир, чёрный список, /find окно, лифт ТВ-башни, авто-ответ. Команды: /anag, /quiz, /mmefir, /endefir, /find, /tvlf, /uninv, /autoans, /bladd, /bldel, /blcheck, /bllist, /efirstats.",
enabled = false,
drawSettings = function()
if imgui.Button(u8"Эфир и Инструменты##smi_tab1") then smi_ui_page = 1 end
imgui.SameLine()
if imgui.Button(u8"Режиссёр викторин (/quiz)##smi_tab2") then smi_ui_page = 2 end
imgui.Separator()
imgui.Spacing()

if smi_ui_page == 2 then
    drawQuizDirectorUI("_tab")
    imgui.Spacing()
    if imgui.Button(u8"Открепить в мини-окно (/quiz)##qz_pop_btn", imgui.ImVec2(240, 28)) then
        quiz_popout_show[0] = not quiz_popout_show[0]
    end
    return
end

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"Эфир:")
imgui.PopStyleColor()
if imgui.Button(u8"Начать эфир", imgui.ImVec2(120, 30)) then queueTask(cmdEfir) end
imgui.SameLine()
if imgui.Button(u8"Завершить эфир", imgui.ImVec2(120, 30)) then queueTask(cmdEndEfir) end
imgui.SameLine()
if imgui.Button(u8"Статистика", imgui.ImVec2(100, 30)) then queueTask(cmdEfirStats) end

imgui.Spacing()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"Авто-ответ на звонки:")
imgui.PopStyleColor()
if imgui.Checkbox(u8"Включить авто-ответ", auto_answer_enabled) then end
imgui.PushItemWidth(300)
imgui.InputText(u8"##autoans_text", auto_answer_text, 257)
imgui.PopItemWidth()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> Текст будет отправлен в /t при входящем звонке во время эфира")
imgui.PopStyleColor()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"Анаграммы (270+ слов, колода без повторов):")
imgui.PopStyleColor()
if imgui.Button(u8"Все (0)", imgui.ImVec2(75, 25)) then queueTask(function() startAnagram(0) end) end
imgui.SameLine()
if imgui.Button(u8"СМИ (1)", imgui.ImVec2(80, 25)) then queueTask(function() startAnagram(1) end) end
imgui.SameLine()
if imgui.Button(u8"Города (2)", imgui.ImVec2(95, 25)) then queueTask(function() startAnagram(2) end) end
imgui.SameLine()
if imgui.Button(u8"Техника (3)", imgui.ImVec2(95, 25)) then queueTask(function() startAnagram(3) end) end
if imgui.Button(u8"Природа (4)", imgui.ImVec2(95, 25)) then queueTask(function() startAnagram(4) end) end
imgui.SameLine()
if imgui.Button(u8"Разное (5)", imgui.ImVec2(95, 25)) then queueTask(function() startAnagram(5) end) end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"Чёрный список и сотрудники:")
imgui.PopStyleColor()
if imgui.Checkbox(u8"Оформлять /find в окно (только при команде /find)", find_ui_enabled) then requestSaveSettings() end
if imgui.Button(u8"Открыть ЧС", imgui.ImVec2(120, 30)) then blacklist_show[0] = true end
imgui.SameLine()
if imgui.Button(u8"Поиск сотрудников", imgui.ImVec2(150, 30)) then queueTask(cmdFind) end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))
imgui.TextUnformatted(u8"Команды:")
imgui.PopStyleColor()
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/quiz — мини-окно режиссёра викторин")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/anag [0-5] — анаграмма без повторов (0=все)")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/mmefir — начать эфир (авто-РП)")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/endefir — завершить эфир (авто-РП)")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/efirstats — статистика эфира")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/find — поиск сотрудников")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/tvlf [этаж] — лифт ТВ-башни")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/uninv [id] [причина] — увольнение с РП")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/autoans [текст] — авто-ответ на звонки")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/bladd [ник] [причина] — добавить в ЧС")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/bldel [ник] — удалить из ЧС")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/blcheck [ник] — проверить ник в ЧС")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/bllist — показать весь ЧС")
end,
onToggle = function(state) end
},
{
id = "qol_tools",
name = u8" Утилиты и Чат",
description = u8"Раскладка в чате, авто-тег рации, фильтр чата, перенос длинных строк, /rec, /hist, друзья, звуки, меню игрока (ПКМ+X), /ss, /clog, финансы, GPS (/wp), пресеты и бэкап.",
enabled = true,
drawSettings = function()
    if imgui.Button(u8"Чат и Рация##qol_tab1", imgui.ImVec2(150, 24)) then qol_ui_page = 1 end
    imgui.SameLine()
    if imgui.Button(u8"Фильтр и Перенос##qol_tab6", imgui.ImVec2(150, 24)) then qol_ui_page = 6 end
    imgui.SameLine()
    if imgui.Button(u8"Друзья и Звуки##qol_tab2", imgui.ImVec2(150, 24)) then qol_ui_page = 2 end
    if imgui.Button(u8"Финансы и Обновы##qol_tab3", imgui.ImVec2(150, 24)) then qol_ui_page = 3 end
    imgui.SameLine()
    if imgui.Button(u8"GPS (/wp)##qol_tab4", imgui.ImVec2(150, 24)) then qol_ui_page = 4 end
    imgui.SameLine()
    if imgui.Button(u8"Профили и Бэкап##qol_tab5", imgui.ImVec2(150, 24)) then qol_ui_page = 5 end
    imgui.Separator()
    imgui.Spacing()

    if qol_ui_page == 1 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Исправление раскладки в открытом чате (EN <-> RU):")
        imgui.PopStyleColor()
        if imgui.Checkbox(u8"Включить исправление раскладки", layout_fix_enabled) then requestSaveSettings() end
        imgui.PushItemWidth(120)
        local cur_lk_label = "F2"
        for _, lk in ipairs(layout_fix_keys) do
            if lk.vk == layout_fix_key[0] then cur_lk_label = lk.label break end
        end
        if imgui.BeginCombo(u8"Клавиша##layout_fix_key", cur_lk_label) then
            for _, lk in ipairs(layout_fix_keys) do
                if imgui.Selectable(lk.label .. "##lfk_" .. lk.vk, layout_fix_key[0] == lk.vk) then
                    layout_fix_key[0] = lk.vk
                    requestSaveSettings()
                end
            end
            imgui.EndCombo()
        end
        imgui.PopItemWidth()

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Авто-тег рации (/r, /f, /d):")
        imgui.PopStyleColor()
        imgui.PushItemWidth(200)
        imgui.InputText(u8"Тег рации (напр. [LV-FM])##radio_tag", radio_tag_text, ffi.sizeof(radio_tag_text))
        if imgui.IsItemDeactivatedAfterEdit() then requestSaveSettings() end
        imgui.PopItemWidth()
        if imgui.Checkbox(u8"Подставлять в /r", radio_tag_r) then requestSaveSettings() end
        imgui.SameLine()
        if imgui.Checkbox(u8"в /f", radio_tag_f) then requestSaveSettings() end
        imgui.SameLine()
        if imgui.Checkbox(u8"в /d", radio_tag_d) then requestSaveSettings() end
        if imgui.Checkbox(u8"Заглавная буква и точка в конце (без OOC)", radio_auto_punct) then requestSaveSettings() end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Быстрые утилиты:")
        imgui.PopStyleColor()
        if imgui.Checkbox(u8"Меню на игрока рядом (ПКМ + X)", target_menu_enabled) then requestSaveSettings() end
        imgui.PushItemWidth(160)
        if imgui.ComboStr(u8"Клавиша меню цели (ПКМ + ...)##p2_tm_key", target_menu_key_idx, "X\0R\0E\0") then
            requestSaveSettings()
        end
        imgui.PopItemWidth()
        if imgui.Checkbox(u8"Авто-РП отыгровка в меню цели", target_menu_autorp) then
            requestSaveSettings()
        end
        if imgui.Checkbox(u8"Быстрое меню на СКМ (/wheelmenu)", wheel_menu_enabled) then
            requestSaveSettings()
        end
        imgui.SameLine()
        imgui.PushItemWidth(145)
        if imgui.ComboStr(u8"Клавиша##p2_wheel_key", wheel_menu_key_idx, u8"СКМ (колёсико)" .. "\0G\0B\0Z\0V\0") then
            requestSaveSettings()
        end
        imgui.PopItemWidth()
        if imgui.Button(u8"Избранные РП для СКМ (" .. #wheel_fav_slots .. "/6)##p2_fav_toggle") then
            P2.wheel_fav_editor[0] = not P2.wheel_fav_editor[0]
        end
        imgui.SameLine()
        if imgui.Button(u8"Открыть быстрое меню##p2_wheel_open") then
            wheel_menu_show[0] = not wheel_menu_show[0]
            if wheel_menu_show[0] then P2.wheel_menu_need_pos = true end
        end
        if P2.wheel_fav_editor[0] then
            P2_drawWheelFavSelector()
        end
        imgui.PushItemWidth(160)
        if imgui.SliderInt(u8"Задержка скрина /ss (мс)", ss_delay, 300, 2000) then requestSaveSettings() end
        imgui.PopItemWidth()
        if imgui.Button(u8"Открыть поиск чата (/clog)") then clog_show[0] = true end
        imgui.SameLine()
        if imgui.Button(u8"Скрин с /c 60 (/ss)") then
            queueTask(function()
                if isSampAvailable() then
                    sampSendChat("/c 60")
                    scheduleTask(ss_delay[0], function()
                        pcall(setVirtualKeyDown, 0x77, true)
                        scheduleTask(80, function() pcall(setVirtualKeyDown, 0x77, false) end)
                    end)
                end
            end)
        end
        imgui.SameLine()
        if imgui.Button(u8"Реконнект (/rec)##qol_rec_btn") then
            queueTask(function() cmdReconnect("2") end)
        end
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1))
        imgui.TextUnformatted(u8"/rec [сек] — реконнект (0=отмена) | /hist [ID/ник] — история ников")
        imgui.PopStyleColor()

    elseif qol_ui_page == 2 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Звуковые уведомления:")
        imgui.PopStyleColor()
        if imgui.Checkbox(u8"Включить звуки", sound_enabled) then requestSaveSettings() end
        if sound_enabled[0] then
            if imgui.Checkbox(u8"Входящее SMS", sound_sms) then requestSaveSettings() end
            imgui.SameLine()
            if imgui.Checkbox(u8"Упоминание ника", sound_mention) then requestSaveSettings() end
            if imgui.Checkbox(u8"Звонок в эфир", sound_efir_call) then requestSaveSettings() end
            imgui.SameLine()
            if imgui.Checkbox(u8"Выход моего /ad", sound_ad_pub) then requestSaveSettings() end
            if imgui.Checkbox(u8"Вход/выход друга", sound_friend) then requestSaveSettings() end
        end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Список друзей / коллег (/fadd, /fdel, /friends):")
        imgui.PopStyleColor()
        if imgui.Checkbox(u8"Писать в чат о входе/выходе друзей", friends_notify) then requestSaveSettings() end
        imgui.PushItemWidth(160)
        imgui.InputText(u8"Ник##fr_nick", friend_add_nick, ffi.sizeof(friend_add_nick))
        imgui.SameLine()
        imgui.InputText(u8"Заметка##fr_note", friend_add_note, ffi.sizeof(friend_add_note))
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(u8"+ Друг##fr_add") then
            local fnick = decodeUtf8Safe(ffi.string(friend_add_nick)):gsub("^%s+", ""):gsub("%s+$", "")
            local fnote = decodeUtf8Safe(ffi.string(friend_add_note)):gsub("^%s+", ""):gsub("%s+$", "")
            if fnick ~= "" then
                friends_list[cp1251_lower(fnick)] = { nick = fnick, note = fnote }
                safeStrCopy(friend_add_nick, "", ffi.sizeof(friend_add_nick))
                safeStrCopy(friend_add_note, "", ffi.sizeof(friend_add_note))
                requestSaveSettings()
            end
        end

        imgui.BeginChild("##friends_scroll", imgui.ImVec2(0, 140), true)
        local f_cnt = 0
        local f_keys = {}
        for k, _ in pairs(friends_list) do f_keys[#f_keys + 1] = k end
        table.sort(f_keys)
        for idx, fk in ipairs(f_keys) do
            f_cnt = f_cnt + 1
            local f = friends_list[fk]
            local fid = getOnlinePlayerIdByNick(f.nick)
            if fid then
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 1.0, 0.4, 1.0))
            else
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65, 0.65, 0.65, 1.0))
            end
            local line_s = f.nick .. (fid and (" [ID:" .. fid .. "]") or " [офф]") .. (f.note ~= "" and (" — " .. f.note) or "")
            imgui.TextUnformatted(encodeCp1251Safe(line_s))
            imgui.PopStyleColor()
            imgui.SameLine(380)
            if imgui.SmallButton("X##fr_del_" .. idx) then
                friends_list[fk] = nil
                requestSaveSettings()
                break
            end
        end
        if f_cnt == 0 then
            imgui.TextUnformatted(u8"Список друзей пуст.")
        end
        imgui.EndChild()

    elseif qol_ui_page == 3 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Финансы за сессию и HUD:")
        imgui.PopStyleColor()
        if imgui.Checkbox(u8"Отслеживать баланс денег", finance_enabled) then requestSaveSettings() end
        if imgui.Checkbox(u8"Показывать КД команд в /hud", hud_show_cooldowns) then requestSaveSettings() end
        if imgui.Checkbox(u8"Показывать баланс сессии в /hud", hud_show_finance) then requestSaveSettings() end
        if imgui.Checkbox(u8"Показывать активное время и AFK в /hud (опционально)", session_track_enabled) then
            if not session_track_enabled[0] then
                session_hud_str = ""
                session_idle_sec = 0
                session_last_px = nil
                session_last_py = nil
            end
            requestSaveSettings()
        end
        imgui.SameLine()
        if imgui.SmallButton(u8"Сбросить##sess_reset") then
            session_active_sec = 0
            session_afk_sec = 0
            session_idle_sec = 0
            session_hud_str = ""
        end
        if session_track_enabled[0] and session_hud_str ~= "" then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.95, 0.65, 1.0))
            imgui.TextUnformatted(encodeCp1251Safe(session_hud_str))
            imgui.PopStyleColor()
        end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Полуавтоматическая покупка в 24/7 / Аптеке (/buyfast):")
        imgui.PopStyleColor()
        if imgui.Checkbox(u8"Включить быструю покупку (/buyfast)", buyfast_enabled) then
            if not buyfast_enabled[0] then
                buyfast_armed_until = 0
            end
            requestSaveSettings()
        end
        imgui.PushItemWidth(210)
        local bf_combo_items = u8"Аптечка" .. "\0" .. u8"Маска" .. "\0" .. u8"Ремкомплект" .. "\0" .. u8"Канистра" .. "\0" .. u8"Телефон / Сим-карта" .. "\0"
        if imgui.ComboStr(u8"Что покупать##bf_item", buyfast_item_idx, bf_combo_items) then
            requestSaveSettings()
        end
        imgui.PopItemWidth()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.55, 1.0))
        imgui.TextUnformatted(u8"-> Введите /buyfast и откройте диалог 24/7 или аптеки (без флуда пакетами)")
        imgui.PopStyleColor()

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        local net = finance_income - finance_expense
        local net_col = net >= 0 and imgui.ImVec4(0.3, 1.0, 0.4, 1.0) or imgui.ImVec4(1.0, 0.35, 0.35, 1.0)
        imgui.TextUnformatted(u8"Приход: +" .. formatNumberWithDots(finance_income) .. u8"$ | Расход: -" .. formatNumberWithDots(finance_expense) .. "$")
        imgui.PushStyleColor(imgui.Col.Text, net_col)
        imgui.TextUnformatted(u8"Итог сессии: " .. (net >= 0 and "+" or "-") .. formatNumberWithDots(math.abs(net)) .. "$")
        imgui.PopStyleColor()
        if imgui.SmallButton(u8"Сбросить счётчик##fin_reset") then
            finance_income = 0
            finance_expense = 0
            finance_log = {}
        end
        imgui.BeginChild("##fin_log_scroll", imgui.ImVec2(0, 110), true)
        if #finance_log == 0 then
            imgui.TextUnformatted(u8"Пока операций не зафиксировано.")
        else
            for _, item in ipairs(finance_log) do
                local sign = item.delta >= 0 and "+" or "-"
                local col = item.delta >= 0 and imgui.ImVec4(0.3, 1.0, 0.4, 1.0) or imgui.ImVec4(1.0, 0.4, 0.4, 1.0)
                imgui.PushStyleColor(imgui.Col.Text, col)
                local txt = "[" .. item.time .. "] " .. sign .. formatNumberWithDots(math.abs(item.delta)) .. "$" .. (item.note ~= "" and (" — " .. item.note) or "")
                imgui.TextUnformatted(encodeCp1251Safe(txt))
                imgui.PopStyleColor()
            end
        end
        imgui.EndChild()

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Обновления с GitHub (estatyq/advancelua):")
        imgui.PopStyleColor()
        if imgui.Checkbox(u8"Авто-проверка обновлений при запуске", check_updates_enabled) then requestSaveSettings() end
        if imgui.Button(update_checking and u8"Проверка..." or u8"Проверить обновления сейчас") and not update_checking then
            queueTask(function() checkGithubUpdates(true) end)
        end
        if update_status_text ~= "" then
            imgui.SameLine()
            imgui.TextUnformatted(sanitizeUtf8(update_status_text))
        end

    elseif qol_ui_page == 4 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Личный GPS и путевые точки (/wp, /wpsave, /wpclear):")
        imgui.PopStyleColor()

        if active_waypoint then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 1.0, 0.4, 1.0))
            imgui.TextUnformatted(u8"Активна цель: " .. encodeCp1251Safe(hud_cache.wp_text ~= "" and hud_cache.wp_text or active_waypoint.name))
            imgui.PopStyleColor()
            imgui.SameLine()
            if imgui.SmallButton(u8"Снять метку##wp_clr_btn") then
                queueTask(function() clearWaypointTarget(false) end)
            end
        else
            imgui.TextUnformatted(u8"Активная метка: нет")
        end

        imgui.PushItemWidth(220)
        imgui.InputText(u8"Название новой точки##wp_new_name", wp_name_buf, ffi.sizeof(wp_name_buf))
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(u8"Сохранить позицию##wp_save_btn", imgui.ImVec2(145, 24)) then
            local nm = decodeUtf8Safe(ffi.string(wp_name_buf)):gsub("^%s+", ""):gsub("%s+$", "")
            safeStrCopy(wp_name_buf, "", ffi.sizeof(wp_name_buf))
            queueTask(function() saveCurrentWaypoint(nm) end)
        end

        imgui.PushItemWidth(260)
        imgui.InputText(u8"Поиск по точкам##wp_search", wp_search_buf, ffi.sizeof(wp_search_buf))
        imgui.PopItemWidth()
        local wp_q = cp1251_lower(decodeUtf8Safe(ffi.string(wp_search_buf)):gsub("^%s+", ""):gsub("%s+$", ""))

        imgui.TextUnformatted(u8"Мои сохранённые точки:")
        imgui.BeginChild("##wp_user_scroll", imgui.ImVec2(0, 110), true)
        local u_shown = 0
        for idx, wp in ipairs(user_waypoints) do
            if wp_q == "" or cp1251_lower(wp.name):find(wp_q, 1, true) then
                u_shown = u_shown + 1
                imgui.TextUnformatted(encodeCp1251Safe(wp.name .. string.format(" (%.0f, %.0f)", wp.x, wp.y)))
                imgui.SameLine(315)
                if imgui.SmallButton(u8"Ехать##wp_ugo_" .. idx) then
                    local w = wp
                    queueTask(function() setWaypointTarget(w.name, w.x, w.y, w.z) end)
                end
                imgui.SameLine()
                if imgui.SmallButton("X##wp_udel_" .. idx) then
                    table.remove(user_waypoints, idx)
                    requestSaveSettings()
                    break
                end
            end
        end
        if u_shown == 0 then
            imgui.TextUnformatted(u8"Нет сохранённых точек (или не найдено).")
        end
        imgui.EndChild()

        imgui.TextUnformatted(u8"Ключевые места Advance RP:")
        imgui.BeginChild("##wp_preset_scroll", imgui.ImVec2(0, 145), true)
        local p_shown = 0
        for idx, wp in ipairs(preset_waypoints) do
            if wp_q == "" or cp1251_lower(wp.name):find(wp_q, 1, true) then
                p_shown = p_shown + 1
                imgui.TextUnformatted(encodeCp1251Safe(wp.name))
                imgui.SameLine(315)
                if imgui.SmallButton(u8"Ехать##wp_pgo_" .. idx) then
                    local w = wp
                    queueTask(function() setWaypointTarget(w.name, w.x, w.y, w.z) end)
                end
            end
        end
        if p_shown == 0 then
            imgui.TextUnformatted(u8"Ничего не найдено.")
        end
        imgui.EndChild()

    elseif qol_ui_page == 5 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Быстрые пресеты под фракцию (1 клик):")
        imgui.PopStyleColor()
        imgui.TextUnformatted(u8"Включает нужные модули, РП и профиль GNEWS (личные базы не удаляются).")

        if imgui.Button(u8"СМИ##pr_smi", imgui.ImVec2(120, 28)) then queueTask(function() applyFactionPreset("smi") end) end
        imgui.SameLine()
        if imgui.Button(u8"МВД (Полиция)##pr_mvd", imgui.ImVec2(125, 28)) then queueTask(function() applyFactionPreset("mvd") end) end
        imgui.SameLine()
        if imgui.Button(u8"МЗ (Больница)##pr_mz", imgui.ImVec2(125, 28)) then queueTask(function() applyFactionPreset("mz") end) end

        if imgui.Button(u8"МО (Армия)##pr_mo", imgui.ImVec2(120, 28)) then queueTask(function() applyFactionPreset("mo") end) end
        imgui.SameLine()
        if imgui.Button(u8"Мэрия##pr_mayor", imgui.ImVec2(125, 28)) then queueTask(function() applyFactionPreset("mayor") end) end
        imgui.SameLine()
        if imgui.Button(u8"Гражданский##pr_civ", imgui.ImVec2(125, 28)) then queueTask(function() applyFactionPreset("civ") end) end

        if preset_status_text ~= "" then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 1.0, 0.4, 1.0))
            imgui.TextUnformatted(sanitizeUtf8(preset_status_text))
            imgui.PopStyleColor()
        end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Экспорт и импорт всей конфигурации (1 файл):")
        imgui.PopStyleColor()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1.0))
        imgui.TextUnformatted(u8"Файл: moonloader/config/helper_export.json")
        imgui.PopStyleColor()

        if imgui.Button(u8"Экспорт в файл##cfg_export", imgui.ImVec2(150, 30)) then
            queueTask(exportAllConfig)
        end
        imgui.SameLine()
        if imgui.Button(u8"Импорт из файла##cfg_import", imgui.ImVec2(150, 30)) then
            queueTask(importAllConfig)
        end
        if export_status_text ~= "" then
            imgui.TextUnformatted(sanitizeUtf8(export_status_text))
        end

    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Умный фильтр чата и анти-спам:")
        imgui.PopStyleColor()
        if imgui.Checkbox(u8"Включить фильтр чата", chat_filter_enabled) then requestSaveSettings() end
        if imgui.Checkbox(u8"Скрывать чужие объявления (/ad)", cf_hide_ads) then requestSaveSettings() end
        imgui.PushItemWidth(260)
        imgui.InputText(u8"Белый список /ad (через запятую)##cf_wl", cf_ad_whitelist_buf, ffi.sizeof(cf_ad_whitelist_buf))
        if imgui.IsItemDeactivatedAfterEdit() then requestSaveSettings() end
        imgui.PopItemWidth()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.55, 1))
        imgui.TextUnformatted(u8"-> Объявления со словами из белого списка пропускаются со звуком")
        imgui.PopStyleColor()

        if imgui.Checkbox(u8"Скрывать эфиры (/t, /u) вне своего эфира", cf_hide_efir) then requestSaveSettings() end
        if imgui.Checkbox(u8"Скрывать системные подсказки и рекламу сервера", cf_hide_system) then requestSaveSettings() end

        imgui.PushItemWidth(260)
        imgui.InputText(u8"Чёрный список фраз (через запятую)##cf_bl", cf_blacklist_buf, ffi.sizeof(cf_blacklist_buf))
        if imgui.IsItemDeactivatedAfterEdit() then requestSaveSettings() end
        imgui.InputText(u8"Триггеры уведомлений (звук при совпадении)##cf_tr", cf_trigger_buf, ffi.sizeof(cf_trigger_buf))
        if imgui.IsItemDeactivatedAfterEdit() then requestSaveSettings() end
        imgui.PopItemWidth()

        imgui.TextUnformatted(u8"Скрыто строк за сессию: " .. tostring(cf_hidden_count))
        imgui.SameLine()
        if imgui.SmallButton(u8"Сбросить##cf_rst") then
            cf_hidden_count = 0
        end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
        imgui.TextUnformatted(u8"Авто-перенос длинных строк (чат, /me, /do, /r, /f, /d, /s, /w, /t, /u):")
        imgui.PopStyleColor()
        if imgui.Checkbox(u8"Включить авто-перенос длинных строк", line_wrap_enabled) then requestSaveSettings() end
        imgui.PushItemWidth(170)
        if imgui.SliderInt(u8"Макс. длина части (симв.)", line_wrap_limit, 70, 122) then requestSaveSettings() end
        if imgui.SliderInt(u8"Пауза между частями (мс)", line_wrap_delay, 350, 1500) then requestSaveSettings() end
        imgui.PopItemWidth()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.55, 1))
        imgui.TextUnformatted(u8"-> Делит текст по словам с «...», сохраняя команду и тег рации (до 4 частей)")
        imgui.PopStyleColor()
    end
end,
onToggle = function(state) end
}
,
{
id = "lecturer",
name = u8" Лектор и Собесы",
description = u8"Многострочный диктор для собеседований, вступительных лекций, инструктажей и правил. Поддержка паузы <0>, таймеров <мс>, гибкой задержки и команды /lect.",
enabled = true,
drawSettings = function() if P3_drawLecturerUI then P3_drawLecturerUI() end end,
onToggle = function(state) end
}
,{
    id = "faction_tools",
    name = u8" МВД и МЗ Спецмодуль",
    description = u8"Умная выдача розыска и штрафов (/suw [ID]), справочник УК/АК с поиском, мегафон (/m), помощник медика и ЕЦП (/medui [ID]), опциональное Авто-РП МВД/МЗ и локальный Damage Informer (/dmglog).",
    enabled = true,
    drawSettings = function() if P4_drawFactionUI then P4_drawFactionUI() end end,
    onToggle = function(state) end
}
,
{
    id = "location_builder",
    name = u8" Конструктор /location",
    description = u8"Полный бесплатный аналог TitanLocation: каталог 522 официальных объектов Advance RP (/loc 1), точный редактор координат и поворотов с Undo/Redo, копированием и дубликатом (/tedit, /tcopy, /tpaste, /tdup), а также реестр локации с экспортом чертежей (/loc 2).",
    enabled = true,
    drawSettings = function()
        if P6_drawLocationModuleSettings then
            P6_drawLocationModuleSettings()
        end
    end,
    onToggle = function(state)
        if not state then
            tedit_active = false
            tedit_dup_pending = false
            tedit_show[0] = false
        end
    end
}

}

local function parseVerTuple(v)
    local maj, min = tostring(v or ""):match("(%d+)%.(%d+)")
    if not maj then return 0 end
    return tonumber(maj) * 1000 + tonumber(min)
end

function checkGithubUpdates(manual)
    if update_checking or type(downloadUrlToFile) ~= "function" then
        if manual and isSampAvailable() then
            sampAddChatMessage("[Helper] Проверка обновлений недоступна в этой сборке.", 0xFFAA00)
        end
        return
    end
    update_checking = true
    update_status_text = u8"Запрос GitHub..."
    local tmp_path = (getFolderPath(0x1C) or (getWorkingDirectory() .. "\\config")) .. "\\helper_ver_check.tmp"
    os.remove(tmp_path)
    local dl_ok, dlstatus = pcall(require, "moonloader")
    local end_status = (dl_ok and dlstatus and dlstatus.download_status and dlstatus.download_status.STATUS_ENDDOWNLOADDATA) or 6
    local finished = false

    scheduleTask(15000, function()
        if not finished then
            finished = true
            update_checking = false
            update_status_text = u8"Таймаут проверки"
            os.remove(tmp_path)
        end
    end)

    local ok_dl = pcall(downloadUrlToFile, "https://raw.githubusercontent.com/estatyq/advancelua/main/README.md", tmp_path, function(id, status, p1, p2)
        if finished then return end
        if status == end_status then
            finished = true
            update_checking = false
            local f = io.open(tmp_path, "rb")
            local content = f and f:read(512) or nil
            if f then f:close() end
            os.remove(tmp_path)
            local remote_ver = content and content:match("Universal Helper Platform v(%d+%.%d+)") or nil
            if remote_ver then
                if parseVerTuple(remote_ver) > parseVerTuple(SCRIPT_VER_NUM) then
                    update_status_text = u8"Доступна новая v" .. remote_ver
                    queueTask(function()
                        if isSampAvailable() then
                            sampAddChatMessage("[Helper] Доступно обновление на GitHub: v" .. remote_ver .. " (текущая v" .. SCRIPT_VER_NUM .. ")", 0x00FF90)
                        end
                    end)
                else
                    update_status_text = u8"Актуальная версия (v" .. SCRIPT_VER_NUM .. ")"
                    if manual then
                        queueTask(function()
                            if isSampAvailable() then
                                sampAddChatMessage("[Helper] Установлена актуальная версия v" .. SCRIPT_VER_NUM, 0x00FF00)
                            end
                        end)
                    end
                end
            else
                update_status_text = u8"Не удалось прочитать версию"
                if manual then
                    queueTask(function()
                        if isSampAvailable() then
                            sampAddChatMessage("[Helper] Не удалось получить версию с GitHub.", 0xFFAA00)
                        end
                    end)
                end
            end
        end
    end)
    if not ok_dl then
        finished = true
        update_checking = false
        update_status_text = u8"Ошибка запроса"
    end
end

preset_waypoints = {
    {name = "Мэрия г. Los Santos", x = 1481.0, y = -1771.0, z = 18.8},
    {name = "Мэрия г. San Fierro", x = -2765.0, y = 375.5, z = 6.3},
    {name = "Мэрия г. Las Venturas", x = 2389.0, y = 2466.0, z = 10.8},
    {name = "Полиция LSPD", x = 1555.0, y = -1675.6, z = 16.2},
    {name = "Полиция SFPD", x = -1605.5, y = 710.3, z = 13.9},
    {name = "Полиция LVPD", x = 2287.0, y = 2431.0, z = 10.8},
    {name = "Больница г. Los Santos", x = 1172.0, y = -1323.0, z = 15.4},
    {name = "Больница г. San Fierro", x = -2655.0, y = 639.0, z = 14.5},
    {name = "Больница г. Las Venturas", x = 1607.5, y = 1815.5, z = 10.8},
    {name = "Телецентр г. Los Santos", x = 1802.7, y = -1292.3, z = 13.6},
    {name = "Радиоцентр ЛС (LS-FM)", x = 1003.0, y = -1351.0, z = 13.3},
    {name = "Автошкола г. San Fierro", x = -2026.5, y = -101.8, z = 35.2},
    {name = "Аэропорт Los Santos", x = 1958.0, y = -2183.0, z = 13.5},
    {name = "Аэропорт San Fierro", x = -1421.0, y = -287.0, z = 14.1},
    {name = "Аэропорт Las Venturas", x = 1677.0, y = 1447.0, z = 10.8},
    {name = "ЖД Вокзал Los Santos", x = 1753.0, y = -1944.0, z = 13.6},
    {name = "ЖД Вокзал San Fierro", x = -1969.0, y = 137.0, z = 27.7},
    {name = "Казино 4 Дракона (LV)", x = 2020.0, y = 1007.0, z = 10.8},
    {name = "Казино Калигула (LV)", x = 2195.0, y = 1677.0, z = 12.4},
    {name = "Банк г. Los Santos", x = 1462.0, y = -1011.0, z = 26.8},
    {name = "Пляж Санта-Мария (Маяк)", x = 369.0, y = -2054.0, z = 7.8},
    {name = "Зона 51 (Сухопутные Войска)", x = 213.0, y = 1911.0, z = 17.6},
    {name = "ВМФ (Авианосец СФ)", x = -1352.0, y = 492.0, z = 11.2},
    {name = "Гора Чиллиад (Вершина)", x = -2325.0, y = -1637.0, z = 483.7},
}

function setWaypointTarget(name, x, y, z)
    pcall(placeWaypoint, x, y, z or 0)
    active_waypoint = { name = name, x = x, y = y, z = z or 0 }
    local dist_txt = ""
    local ok_c, px, py = pcall(getCharCoordinates, PLAYER_PED)
    if ok_c and type(px) == "number" and type(py) == "number" then
        local d = math.floor(math.sqrt((px - x)^2 + (py - y)^2) + 0.5)
        dist_txt = " (" .. d .. "м)"
    end
    hud_cache.wp_text = name .. dist_txt
    if isSampAvailable() then
        sampAddChatMessage("[GPS] Маршрут проложен: {00FF90}" .. hud_cache.wp_text, 0x00CCFF)
    end
end

function clearWaypointTarget(silent)
    active_waypoint = nil
    hud_cache.wp_text = ""
    pcall(function() if type(removeWaypoint) == "function" then removeWaypoint() end end)
    if not silent and isSampAvailable() then
        sampAddChatMessage("[GPS] Метка маршрута снята.", 0xFFAA00)
    end
end

function saveCurrentWaypoint(name)
    if not name or name == "" then
        if isSampAvailable() then sampAddChatMessage("[GPS] Введите название точки: /wpsave [название]", 0xFFAA00) end
        return
    end
    local ok_c, px, py, pz = pcall(getCharCoordinates, PLAYER_PED)
    if not ok_c or type(px) ~= "number" then
        if isSampAvailable() then sampAddChatMessage("[GPS] Не удалось получить текущие координаты.", 0xFF0000) end
        return
    end
    local low_n = cp1251_lower(name)
    for _, wp in ipairs(user_waypoints) do
        if cp1251_lower(wp.name) == low_n then
            wp.name = name
            wp.x = px
            wp.y = py
            wp.z = pz or 0
            requestSaveSettings()
            if isSampAvailable() then sampAddChatMessage("[GPS] Точка обновлена: " .. name, 0x00FF90) end
            return
        end
    end
    user_waypoints[#user_waypoints + 1] = { name = name, x = px, y = py, z = pz or 0 }
    requestSaveSettings()
    if isSampAvailable() then sampAddChatMessage("[GPS] Точка сохранена: " .. name, 0x00FF90) end
end

function findAndSetWaypoint(query)
    local q = cp1251_lower((query or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if q == "" then
        if isSampAvailable() then
            sampAddChatMessage("[GPS] /wp [название], /wpsave [имя], /wpclear. Своих точек: " .. #user_waypoints .. ", пресетов: " .. #preset_waypoints, 0x00CCFF)
        end
        return
    end
    for _, wp in ipairs(user_waypoints) do
        if cp1251_lower(wp.name):find(q, 1, true) then
            setWaypointTarget(wp.name, wp.x, wp.y, wp.z)
            return
        end
    end
    for _, wp in ipairs(preset_waypoints) do
        if cp1251_lower(wp.name):find(q, 1, true) then
            setWaypointTarget(wp.name, wp.x, wp.y, wp.z)
            return
        end
    end
    if isSampAvailable() then
        sampAddChatMessage("[GPS] Точка не найдена: " .. query, 0xFFAA00)
    end
end

faction_presets = {
    smi = {
        label = "СМИ",
        faction_id = 5,
        gnews_match = {"радио", "сми"},
        gnews_fallback = 1,
        default_tag = "[LS-FM]",
        modules = { mm_editor = true, smi_tools = true, autocall_db = true, gnews = true, auto_rp = true, rp_engine = true, keybinds = true, commands_guide = true, qol_tools = true, auto_ad = false, vehicle_visuals = false },
        rp = { weapons = false, phone = true, mask = false, heal = true, engine = true, docs = true },
    },
    mvd = {
        label = "МВД",
        faction_id = 1,
        gnews_match = {"полиц", "lspd"},
        gnews_fallback = 5,
        default_tag = "[LSPD]",
        modules = { gnews = true, auto_rp = true, rp_engine = true, vehicle_visuals = true, keybinds = true, commands_guide = true, qol_tools = true, mm_editor = false, smi_tools = false, autocall_db = false, auto_ad = false },
        rp = { weapons = true, phone = true, mask = true, heal = true, engine = true, docs = true },
    },
    mz = {
        label = "МЗ",
        faction_id = 2,
        gnews_match = {"больниц", "hls"},
        gnews_fallback = 3,
        default_tag = "[HLS]",
        modules = { gnews = true, auto_rp = true, rp_engine = true, keybinds = true, commands_guide = true, qol_tools = true, mm_editor = false, smi_tools = false, autocall_db = false, auto_ad = false, vehicle_visuals = false },
        rp = { weapons = false, phone = true, mask = true, heal = true, engine = true, docs = true },
    },
    mo = {
        label = "МО",
        faction_id = 3,
        gnews_match = {"войск", "арм"},
        gnews_fallback = 4,
        default_tag = "[МО]",
        modules = { gnews = true, auto_rp = true, rp_engine = true, keybinds = true, commands_guide = true, qol_tools = true, mm_editor = false, smi_tools = false, autocall_db = false, auto_ad = false, vehicle_visuals = false },
        rp = { weapons = true, phone = true, mask = true, heal = true, engine = true, docs = true },
    },
    mayor = {
        label = "Мэрия",
        faction_id = 4,
        gnews_match = {"мэр"},
        gnews_fallback = 2,
        default_tag = "[Мэрия]",
        modules = { gnews = true, auto_rp = true, rp_engine = true, keybinds = true, commands_guide = true, qol_tools = true, mm_editor = false, smi_tools = false, autocall_db = false, auto_ad = false, vehicle_visuals = false },
        rp = { weapons = false, phone = true, mask = false, heal = true, engine = true, docs = true },
    },
    civ = {
        label = "Гражданский",
        faction_id = 0,
        modules = { autocall_db = true, auto_ad = true, auto_rp = true, vehicle_visuals = true, keybinds = true, commands_guide = true, qol_tools = true, mm_editor = false, smi_tools = false, gnews = false, rp_engine = false },
        rp = { weapons = false, phone = true, mask = true, heal = true, engine = true, docs = true },
    },
}

function applyFactionPreset(preset_id)
    local p = faction_presets[preset_id]
    if not p then return end
    for _, mod in ipairs(modules) do
        if p.modules[mod.id] ~= nil then
            mod.enabled = p.modules[mod.id]
        end
    end
    selected_faction[0] = p.faction_id
    rp_weapons_enabled[0] = p.rp.weapons
    rp_phone_enabled[0] = p.rp.phone
    rp_mask_enabled[0] = p.rp.mask
    rp_heal_enabled[0] = p.rp.heal
    rp_engine_enabled[0] = p.rp.engine
    rp_docs_enabled[0] = p.rp.docs

    if p.gnews_match and gnews_settings and gnews_settings.profiles then
        local matched_idx = nil
        for idx, prof in ipairs(gnews_settings.profiles) do
            local nm = cp1251_lower(prof.name or "")
            for _, pat in ipairs(p.gnews_match) do
                if nm:find(pat, 1, true) then
                    matched_idx = idx
                    break
                end
            end
            if matched_idx then break end
        end
        if not matched_idx and p.gnews_fallback and gnews_settings.profiles[p.gnews_fallback] then
            matched_idx = p.gnews_fallback
        end
        if matched_idx then
            gnews_settings.selected = matched_idx
            gnews_loaded_idx = -1
        end
    end

    if p.default_tag then
        local cur_tag = decodeUtf8Safe(ffi.string(radio_tag_text)):gsub("^%s+", ""):gsub("%s+$", "")
        if cur_tag == "" then
            safeStrCopy(radio_tag_text, encodeCp1251Safe(p.default_tag), ffi.sizeof(radio_tag_text))
            radio_tag_r[0] = true
        end
    end

    requestSaveSettings()
    preset_status_text = u8("Применён пресет: " .. p.label)
    if isSampAvailable() then
        sampAddChatMessage("[Helper] Применён пресет фракции: {00FF90}" .. p.label, 0x00CCFF)
    end
end

function exportAllConfig()
    if not doesDirectoryExist(getWorkingDirectory() .. "/config") then
        createDirectory(getWorkingDirectory() .. "/config")
    end
    saveSettings()
    local cur_settings = readJsonFile(settings_path) or {}
    local def_map = {}
    for _, r in ipairs(default_mm_rules) do
        def_map[cp1251_lower(r.abbreviation)] = r.replacement
    end
    local custom_rules = {}
    for _, r in ipairs(mm_rules) do
        local low = cp1251_lower(r.abbreviation or "")
        if low ~= "" and def_map[low] ~= r.replacement then
            custom_rules[#custom_rules + 1] = { abbreviation = r.abbreviation, replacement = r.replacement }
        end
    end
    local bundle = {
        format_version = 2,
        script_version = SCRIPT_VER_NUM,
        exported_at = os.date("%Y-%m-%d %H:%M:%S"),
        settings = cur_settings,
        rp_settings = (rp_settings and rp_settings.set) or {},
        blacklist = blacklist_data or {},
        corrections = edit_corrections or {},
        custom_rules = custom_rules,
        chat_filter = {
            enabled = chat_filter_enabled[0],
            hide_ads = cf_hide_ads[0],
            hide_efir = cf_hide_efir[0],
            hide_system = cf_hide_system[0],
            whitelist = decodeUtf8Safe(ffi.string(cf_ad_whitelist_buf)),
            blacklist = decodeUtf8Safe(ffi.string(cf_blacklist_buf)),
            triggers = decodeUtf8Safe(ffi.string(cf_trigger_buf))
        },
        lecturer_templates = P3_lecturer_templates or {},
        codex = P4_codex or {},
        locations = P6_loc_registry or {},
        location_favorites = P6_loc_favorites or {},
    }
    local ok, err = writeJsonAtomic(export_path, bundle)
    if ok then
        export_status_text = u8"Экспортировано: helper_export.json (" .. #custom_rules .. u8" доп. правил)"
        if isSampAvailable() then
            sampAddChatMessage("[Helper] Конфиг экспортирован в moonloader/config/helper_export.json", 0x00FF90)
        end
    else
        export_status_text = u8"Ошибка экспорта: " .. tostring(err)
        if isSampAvailable() then
            sampAddChatMessage("[Helper] Ошибка экспорта: " .. tostring(err), 0xFF4444)
        end
    end
end

function importAllConfig()
    local bundle = readJsonFile(export_path)
    if not bundle or type(bundle.settings) ~= "table" then
        export_status_text = u8"Файл helper_export.json не найден или повреждён"
        if isSampAvailable() then
            sampAddChatMessage("[Helper] Импорт не удался: проверьте moonloader/config/helper_export.json", 0xFF4444)
        end
        return
    end
    local cfg_dir = getWorkingDirectory() .. "/config"
    if type(doesDirectoryExist) == "function" and not doesDirectoryExist(cfg_dir) then
        createDirectory(cfg_dir)
    end
    local cleaned_settings = P5_cleanImportValue(bundle.settings, 0)
    if type(cleaned_settings) ~= "table" then
        export_status_text = u8"Файл helper_export.json повреждён (settings)"
        return
    end
    local ok_s, err_s = writeJsonAtomic(settings_path, cleaned_settings)
    if not ok_s then
        export_status_text = u8"Ошибка записи настроек: " .. tostring(err_s)
        return
    end
    if type(bundle.rp_settings) == "table" and rp_settings then
        for k, vals in pairs(bundle.rp_settings) do
            local ch = tonumber(k)
            if ch and ch >= 1 and ch <= 100 and type(vals) == "table" then
                local cleaned_rp = {}
                for _, entry in ipairs(vals) do
                    if type(entry) == "table" and type(entry.name) == "string" and type(entry.text) == "string"
                        and not entry.name:find("%z") and not entry.text:find("%z")
                        and #entry.name <= 256 and #entry.text <= 16384 then
                        cleaned_rp[#cleaned_rp + 1] = { name = entry.name, text = entry.text }
                        if #cleaned_rp >= 500 then break end
                    end
                end
                rp_settings.set[ch] = cleaned_rp
            end
        end
        saveRpSettings()
    end
    if type(bundle.blacklist) == "table" then
        local cleaned_bl = {}
        for nick, data in pairs(bundle.blacklist) do
            if type(nick) == "string" and #nick <= 64 and type(data) == "table" and type(data.reason) == "string" then
                cleaned_bl[nick] = { reason = data.reason, added = type(data.added) == "string" and data.added or "" }
            end
        end
        blacklist_data = cleaned_bl
        saveBlacklist()
    end
    if type(bundle.corrections) == "table" then
        local cleaned_cor = {}
        for _, entry in ipairs(bundle.corrections) do
            if type(entry) == "table" and type(entry.abbr) == "string" and type(entry.repl) == "string" then
                cleaned_cor[#cleaned_cor + 1] = { abbr = entry.abbr, repl = entry.repl }
                if #cleaned_cor >= 500 then break end
            end
        end
        edit_corrections = cleaned_cor
        saveCorrections()
    end
    if type(bundle.custom_rules) == "table" then
        local merged = {}
        for _, r in ipairs(default_mm_rules) do
            merged[#merged + 1] = { abbreviation = r.abbreviation, replacement = r.replacement }
        end
        for _, r in ipairs(bundle.custom_rules) do
            if type(r) == "table" and type(r.abbreviation) == "string" and type(r.replacement) == "string" and r.abbreviation ~= "" then
                merged[#merged + 1] = { abbreviation = r.abbreviation, replacement = r.replacement }
            end
        end
        local sanitized = sanitizeAndDedupeRules(merged)
        mm_rules = sanitized
        mm_rule_revision = mm_rule_revision + 1
        saveRules()
    end

    if type(bundle.chat_filter) == "table" and cleaned_settings.chat_filter_enabled == nil then
        local cf = bundle.chat_filter
        if type(cf.enabled) == "boolean" then chat_filter_enabled[0] = cf.enabled end
        if type(cf.hide_ads) == "boolean" then cf_hide_ads[0] = cf.hide_ads end
        if type(cf.hide_efir) == "boolean" then cf_hide_efir[0] = cf.hide_efir end
        if type(cf.hide_system) == "boolean" then cf_hide_system[0] = cf.hide_system end
        if type(cf.whitelist) == "string" then
            local ok_w, enc_w = pcall(function() return u8:encode(cf.whitelist, encoding.default) end)
            if ok_w and type(enc_w) == "string" then safeStrCopy(cf_ad_whitelist_buf, enc_w, ffi.sizeof(cf_ad_whitelist_buf)) end
        end
        if type(cf.blacklist) == "string" then
            local ok_b, enc_b = pcall(function() return u8:encode(cf.blacklist, encoding.default) end)
            if ok_b and type(enc_b) == "string" then safeStrCopy(cf_blacklist_buf, enc_b, ffi.sizeof(cf_blacklist_buf)) end
        end
        if type(cf.triggers) == "string" then
            local ok_t, enc_t = pcall(function() return u8:encode(cf.triggers, encoding.default) end)
            if ok_t and type(enc_t) == "string" then safeStrCopy(cf_trigger_buf, enc_t, ffi.sizeof(cf_trigger_buf)) end
        end
    end
    if type(bundle.lecturer_templates) == "table" then
        local cleaned_lt = P5_cleanImportValue(bundle.lecturer_templates, 0)
        if type(cleaned_lt) == "table" then
            local valid_lt = {}
            for _, entry in ipairs(cleaned_lt) do
                if type(entry) == "table" and type(entry.name) == "string" and type(entry.text) == "string"
                    and #entry.name <= 256 and #entry.text <= 16384 then
                    valid_lt[#valid_lt + 1] = { name = entry.name, text = entry.text }
                    if #valid_lt >= 200 then break end
                end
            end
            if #valid_lt > 0 or next(cleaned_lt) == nil then
                P3_lecturer_templates = valid_lt
                if lect_loaded_idx ~= nil then lect_loaded_idx = -1 end
                if type(P3_saveLecturer) == "function" then pcall(P3_saveLecturer) end
            end
        end
    end
    if type(bundle.codex) == "table" then
        local cleaned_cdx = P5_cleanImportValue(bundle.codex, 0)
        if type(cleaned_cdx) == "table" and (type(cleaned_cdx.uk) == "table" or type(cleaned_cdx.ak) == "table" or type(cleaned_cdx.ecp) == "table") then
            P4_codex = cleaned_cdx
            if type(P4_saveCodex) == "function" then pcall(P4_saveCodex) end
        end
    end
    local imported_loc = nil
    if type(bundle.locations) == "table" then
        local cleaned_loc = P5_cleanImportValue(bundle.locations, 0)
        if type(cleaned_loc) == "table" and (P6_loc_registry ~= nil or next(cleaned_loc) ~= nil) then
            imported_loc = cleaned_loc
            P6_loc_registry = cleaned_loc
            if type(P6_saveLocations) == "function" then pcall(P6_saveLocations) end
        end
    end
    local imported_fav = nil
    if type(bundle.location_favorites) == "table" then
        local cleaned_fav = P5_cleanImportValue(bundle.location_favorites, 0)
        if type(cleaned_fav) == "table" then
            imported_fav = cleaned_fav
        end
    end
    loadDatabases()
    if imported_loc ~= nil then
        P6_loc_registry = imported_loc
    end
    if imported_fav ~= nil then
        if type(P6_sanitizeIdArray) == "function" then
            P6_loc_favorites = P6_sanitizeIdArray(imported_fav, 522)
        else
            P6_loc_favorites = imported_fav
        end
        if type(P6_rebuildFavMap) == "function" then pcall(P6_rebuildFavMap) end
        if type(P6_saveLocations) == "function" then pcall(P6_saveLocations) end
        saveSettings()
    elseif imported_loc ~= nil and type(P6_saveLocations) == "function" then
        pcall(P6_saveLocations)
    end
    if saved_module_states then
        for _, mod in ipairs(modules) do
            if saved_module_states[mod.id] ~= nil then
                mod.enabled = saved_module_states[mod.id]
            end
        end
    end
    gnews_loaded_idx = -1
    export_status_text = u8"Конфигурация успешно импортирована!"
    if isSampAvailable() then
        sampAddChatMessage("[Helper] Конфигурация импортирована из helper_export.json!", 0x00FF90)
    end
end

-- ===== ФАЗА 2 (v2.2): КОЛЕСО СКМ, МЕНЮ ЦЕЛИ И АВТО-СТРОБЫ =====
function getTargetMenuVk()
    local idx = target_menu_key_idx and target_menu_key_idx[0] or 0
    if idx == 1 then return 0x52 end -- R
    if idx == 2 then return 0x45 end -- E
    return 0x58 -- X
end

function getWheelMenuVk()
    local idx = wheel_menu_key_idx and wheel_menu_key_idx[0] or 0
    if idx == 1 then return 0x47 end -- G
    if idx == 2 then return 0x42 end -- B
    if idx == 3 then return 0x5A end -- Z
    if idx == 4 then return 0x56 end -- V
    return 0x04 -- VK_MBUTTON (СКМ)
end

function P2_truncCp1251(s, max_bytes)
    if type(s) ~= "string" then return "" end
    if #s <= max_bytes then return s end
    if max_bytes <= 2 then return s:sub(1, max_bytes) end
    return s:sub(1, max_bytes - 2) .. ".."
end

function P2_toggleWheelMenu()
    wheel_menu_show[0] = not wheel_menu_show[0]
    if wheel_menu_show[0] then
        P2.wheel_menu_need_pos = true
    end
end

function P2_sendWithOptionalRp(cmd, rp_text)
    if type(cmd) ~= "string" or cmd == "" then return end
    if target_menu_autorp and target_menu_autorp[0] and type(rp_text) == "string" and rp_text ~= "" then
        scheduleTask(0, function()
            if isSampAvailable() then
                rp_sending_internal = true
                pcall(sampSendChat, rp_text)
                rp_sending_internal = false
            end
        end)
        scheduleTask(250, function()
            if isSampAvailable() then
                rp_sending_internal = true
                pcall(sampSendChat, cmd)
                rp_sending_internal = false
            end
        end)
    else
        if isSampAvailable() then
            rp_sending_internal = true
            pcall(sampSendChat, cmd)
            rp_sending_internal = false
        end
    end
end

function P2_openTargetSu(tid)
    local id_num = tonumber(tid)
    if not id_num or id_num < 0 then return end
    if type(P4_openSuMenu) == "function" then
        P4_openSuMenu(id_num)
    elseif isSampAvailable() then
        pcall(sampSetChatInputEnabled, true)
        pcall(sampSetChatInputText, "/su " .. tostring(id_num) .. " ")
    end
end

function P2_openTargetTicket(tid)
    local id_num = tonumber(tid)
    if not id_num or id_num < 0 then return end
    if isSampAvailable() then
        pcall(sampSetChatInputEnabled, true)
        pcall(sampSetChatInputText, "/ticket " .. tostring(id_num) .. " ")
    end
end

function P2_openTargetMed(tid)
    local id_num = tonumber(tid)
    if not id_num or id_num < 0 then return end
    if type(P4_openMedMenu) == "function" then
        P4_openMedMenu(id_num)
    else
        local rp = "/me " .. rpVerb("осмотрел", "осмотрела") .. " пациента и " .. rpVerb("оказал", "оказала") .. " медицинскую помощь"
        P2_sendWithOptionalRp("/medhelp " .. tostring(id_num), rp)
    end
end

function P2_runQuickScreenshot()
    if not isSampAvailable() then return end
    sampSendChat("/c 60")
    scheduleTask(ss_delay[0], function()
        pcall(setVirtualKeyDown, 0x77, true)
        scheduleTask(80, function()
            pcall(setVirtualKeyDown, 0x77, false)
        end)
    end)
end

function P2_tickSirenAutoStrobe()
    local mod_on = isModuleEnabled("vehicle_visuals")
    local opt_on = siren_auto_strobe and siren_auto_strobe[0]
    local in_car = isCharInAnyCar(PLAYER_PED)
    local car = in_car and storeCarCharIsInNoSave(PLAYER_PED) or nil
    local car_ok = (car ~= nil and doesVehicleExist(car))
    local is_driver = false
    if car_ok then
        if type(getDriverOfCar) == "function" then
            local ok_drv, drv = pcall(getDriverOfCar, car)
            is_driver = ok_drv and (drv == PLAYER_PED)
        else
            is_driver = true
        end
    end

    if P2.last_siren_car and (not car_ok or not is_driver or P2.last_siren_car ~= car) then
        local old_car = P2.last_siren_car
        P2.last_siren_car = nil
        P2.siren_was_on = false
        if P2.siren_started_strobe then
            P2.siren_started_strobe = false
            strobe_active = false
            strobe_enabled[0] = false
        end
        if old_car and doesVehicleExist(old_car) then
            pcall(restoreAllLights, old_car)
        end
    end

    if not mod_on or not opt_on or not car_ok or not is_driver then
        if P2.siren_was_on or P2.siren_started_strobe then
            P2.siren_was_on = false
            if P2.siren_started_strobe then
                P2.siren_started_strobe = false
                strobe_active = false
                strobe_enabled[0] = false
                if car_ok and is_driver then
                    pcall(restoreAllLights, car)
                elseif P2.last_siren_car and doesVehicleExist(P2.last_siren_car) then
                    pcall(restoreAllLights, P2.last_siren_car)
                end
            end
        end
        if not car_ok or not is_driver then
            P2.last_siren_car = nil
        end
        return
    end

    if type(isCarSirenOn) ~= "function" then
        return
    end

    local ok_s, siren_val = pcall(isCarSirenOn, car)
    if not ok_s then return end
    local siren_on = (siren_val == true or siren_val == 1)

    if siren_on and not P2.siren_was_on then
        P2.siren_was_on = true
        P2.last_siren_car = car
        if not strobe_active or not strobe_enabled[0] then
            P2.siren_started_strobe = true
            strobe_enabled[0] = true
            strobe_active = true
            if not strobe_worker_running then
                queueTask(function()
                    if not strobe_worker_running then
                        lua_thread.create(strobeWorker)
                    end
                end)
            end
        end
    elseif siren_on then
        P2.last_siren_car = car
    elseif not siren_on and P2.siren_was_on then
        P2.siren_was_on = false
        if P2.siren_started_strobe then
            P2.siren_started_strobe = false
            if strobe_active or strobe_enabled[0] then
                strobe_active = false
                strobe_enabled[0] = false
                pcall(restoreAllLights, car)
            end
            P2.last_siren_car = nil
        end
    end
end

function P2_getWheelDisplayItems()
    local items = {}
    local sets = (rp_settings and rp_settings.set) or {}
    if #wheel_fav_slots > 0 then
        for i, fav in ipairs(wheel_fav_slots) do
            if i > 6 then break end
            local ch = fav.chapter or 1
            local idx = fav.index or 1
            local list = sets[ch]
            local rp = list and list[idx]
            if rp and type(rp.text) == "string" and rp.text ~= "" then
                local nm = (type(rp.name) == "string" and rp.name ~= "") and rp.name or ("РП #" .. idx)
                items[#items + 1] = { name = nm, text = rp.text, chapter = ch }
            end
        end
    else
        local def_list = sets[1] or {}
        for idx = 1, math.min(6, #def_list) do
            local rp = def_list[idx]
            if rp and type(rp.text) == "string" and rp.text ~= "" then
                local nm = (type(rp.name) == "string" and rp.name ~= "") and rp.name or ("РП #" .. idx)
                items[#items + 1] = { name = nm, text = rp.text, chapter = 1 }
            end
        end
    end
    return items
end

function P2_drawWheelFavSelector()
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 0.9, 1.0, 1.0))
    imgui.TextUnformatted(u8"Избранные РП-отыгровки для быстрого меню (до 6):")
    imgui.PopStyleColor()

    local ch_names = { [1] = "Общие", [2] = "Мои", [3] = "Цель" }
    if #wheel_fav_slots == 0 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1))
        imgui.TextUnformatted(u8"Список пуст (по умолчанию показываются первые 6 из главы 'Общие').")
        imgui.PopStyleColor()
    else
        for i, item in ipairs(wheel_fav_slots) do
            local ch = item.chapter or 1
            local idx = item.index or 1
            local list = (rp_settings and rp_settings.set and rp_settings.set[ch]) or {}
            local rp = list[idx]
            local rname = rp and P2_truncCp1251(rp.name ~= "" and rp.name or ("#" .. idx), 34) or ("Удалена #" .. idx)
            local label = string.format("%d. [%s] %s", i, ch_names[ch] or "?", rname)
            imgui.TextUnformatted(encodeCp1251Safe(label))
            imgui.SameLine(390)
            if imgui.SmallButton("X##p2_fdel_" .. i) then
                table.remove(wheel_fav_slots, i)
                requestSaveSettings()
                break
            end
        end
        if imgui.SmallButton(u8"Очистить избранное##p2_fclear") then
            wheel_fav_slots = {}
            requestSaveSettings()
        end
    end

    if #wheel_fav_slots < 6 then
        imgui.Spacing()
        imgui.PushItemWidth(150)
        if imgui.ComboStr(u8"Глава##p2_fch", P2.wheel_fav_ch, u8"Общие" .. "\0" .. u8"Мои отыгровки" .. "\0" .. u8"Для цели" .. "\0") then
            P2.wheel_fav_idx[0] = 0
        end
        imgui.PopItemWidth()

        local ch = (P2.wheel_fav_ch[0] or 0) + 1
        local list = (rp_settings and rp_settings.set and rp_settings.set[ch]) or {}
        if P2.wheel_fav_idx[0] >= #list then P2.wheel_fav_idx[0] = 0 end
        local cur_rp = list[P2.wheel_fav_idx[0] + 1]
        local preview = cur_rp and encodeCp1251Safe(cur_rp.name ~= "" and cur_rp.name or ("#" .. (P2.wheel_fav_idx[0] + 1))) or u8"(пусто)"

        imgui.SameLine()
        imgui.PushItemWidth(200)
        if imgui.BeginCombo(u8"Скрипт##p2_fitem", preview) then
            for idx, rp in ipairs(list) do
                local rname = encodeCp1251Safe(rp.name ~= "" and rp.name or ("#" .. idx))
                if imgui.Selectable(rname .. "##p2_fpick_" .. idx, P2.wheel_fav_idx[0] == (idx - 1)) then
                    P2.wheel_fav_idx[0] = idx - 1
                end
            end
            imgui.EndCombo()
        end
        imgui.PopItemWidth()

        imgui.SameLine()
        if imgui.Button(u8"+ Закрепить##p2_fadd") and cur_rp then
            local sel_idx = P2.wheel_fav_idx[0] + 1
            local dup = false
            for _, ex in ipairs(wheel_fav_slots) do
                if ex.chapter == ch and ex.index == sel_idx then
                    dup = true
                    break
                end
            end
            if not dup and #wheel_fav_slots < 6 then
                wheel_fav_slots[#wheel_fav_slots + 1] = { chapter = ch, index = sel_idx }
                requestSaveSettings()
            end
        end
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.75, 0.3, 1.0))
        imgui.TextUnformatted(u8"Достигнут лимит (6/6). Удалите слот, чтобы добавить новый.")
        imgui.PopStyleColor()
    end
    imgui.Spacing()
end
function P3_formatDurationShort(sec)
    local s = math.max(0, math.floor(tonumber(sec) or 0))
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local r = s % 60
    if h > 0 then
        return string.format("%dч %02dм %02dс", h, m, r)
    end
    return string.format("%02dм %02dс", m, r)
end

function P3_formatGnewsHud(rem)
    return "GNEWS: " .. P3_formatDurationShort(rem)
end

function P3_parseNextScheduleTs(hhmmss, now_ts)
    if type(hhmmss) ~= "string" then
        return nil, "Введите время в формате ЧЧ:ММ:СС"
    end
    local clean = hhmmss:gsub("^%s+", ""):gsub("%s+$", "")
    local hs, ms, ss = clean:match("^(%d%d?):(%d%d):(%d%d)$")
    if not hs then
        return nil, "Неверный формат! Используйте ЧЧ:ММ:СС (напр. 18:30:00)"
    end
    local h = tonumber(hs)
    local m = tonumber(ms)
    local s = tonumber(ss)
    if not h or not m or not s or h < 0 or h > 23 or m < 0 or m > 59 or s < 0 or s > 59 then
        return nil, "Неверное время! Часы 0-23, мин/сек 0-59"
    end
    local base_now = tonumber(now_ts) or os.time()
    local dt = os.date("*t", base_now)
    dt.hour = h
    dt.min = m
    dt.sec = s
    dt.isdst = nil
    local target_ts = os.time(dt)
    if not target_ts then
        return nil, "Ошибка расчёта времени"
    end
    if target_ts <= base_now then
        dt.day = dt.day + 1
        dt.isdst = nil
        target_ts = os.time(dt)
        if not target_ts then
            return nil, "Ошибка расчёта времени"
        end
    end
    return target_ts, nil
end

function P3_scheduleGnews(time_str)
    local raw = time_str
    if raw == nil then
        raw = decodeUtf8Safe(ffi.string(gnews_sched_time_buf))
    end
    local now_ts = os.time()
    local target_ts, err = P3_parseNextScheduleTs(raw, now_ts)
    if not target_ts then
        P3.gnews_status = err or "Ошибка времени"
        if isSampAvailable() then
            sampAddChatMessage("[GNEWS Таймер] " .. P3.gnews_status, 0xFF5555)
        end
        return false
    end
    local target_str = os.date("%H:%M:%S", target_ts)
    safeStrCopy(gnews_sched_time_buf, encodeCp1251Safe(target_str), ffi.sizeof(gnews_sched_time_buf))
    gnews_sched_target_ts = target_ts
    gnews_sched_target_str = target_str
    gnews_sched_warned_15 = false
    gnews_sched_active = true
    local rem = math.max(0, target_ts - now_ts)
    gnews_sched_hud_str = P3_formatGnewsHud(rem)
    P3.gnews_status = "Запланировано на " .. target_str
    if isSampAvailable() then
        sampAddChatMessage("[GNEWS Таймер] Волна запланирована на " .. target_str .. " (через " .. P3_formatDurationShort(rem) .. ")", 0x00CCFF)
    end
    return true
end

function P3_cancelGnewsSchedule()
    local was_active = gnews_sched_active
    gnews_sched_active = false
    gnews_sched_target_ts = nil
    gnews_sched_target_str = ""
    gnews_sched_warned_15 = false
    gnews_sched_hud_str = ""
    P3.gnews_status = was_active and "Таймер отменён" or ""
    if was_active and isSampAvailable() then
        sampAddChatMessage("[GNEWS Таймер] Автоподача гос. новостей отменена.", 0xFFAA00)
    end
end

function P3_formatBookingText(tpl, tag, hhmm)
    local s = tostring(tpl or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then s = "[%s] Занимаю волну гос. новостей на %s." end
    local safe_tag = tostring(tag or "ГОС"):gsub("%%", "%%%%")
    local safe_time = tostring(hhmm or "00:00"):gsub("%%", "%%%%")
    s = s:gsub("{tag}", safe_tag):gsub("{time}", safe_time)
    local count = 0
    for _ in s:gmatch("%%s") do count = count + 1 end
    if count >= 2 then
        s = s:gsub("%%s", safe_tag, 1)
        s = s:gsub("%%s", safe_time, 1)
        s = s:gsub("%%s", "")
    elseif count == 1 then
        if s:find("%[%s*%%s%s*%]") then
            s = s:gsub("%%s", safe_tag, 1)
        else
            s = s:gsub("%%s", safe_time, 1)
        end
    end
    if s:sub(1, 3):lower() == "/l " then
        s = s:sub(4)
    end
    return s
end

function P3_sendGnewsBookingL(time_str)
    local raw_t = time_str
    if raw_t == nil then
        raw_t = decodeUtf8Safe(ffi.string(gnews_sched_time_buf))
    end
    local clean_t = tostring(raw_t or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local hh, mm = clean_t:match("^(%d%d?):(%d%d)")
    local h = tonumber(hh)
    local m = tonumber(mm)
    if not h or not m or h < 0 or h > 23 or m < 0 or m > 59 then
        P3.gnews_status = "Укажите время ЧЧ:ММ:СС для /l"
        if isSampAvailable() then
            sampAddChatMessage("[GNEWS /l] Укажите корректное время ЧЧ:ММ:СС (напр. 18:30:00).", 0xFF5555)
        end
        return false
    end
    local hhmm = string.format("%02d:%02d", h, m)
    local p = gnews_settings and gnews_settings.profiles and gnews_settings.profiles[gnews_settings.selected]
    local tag = (p and type(p.tag) == "string" and p.tag ~= "") and p.tag or "ГОС"
    local tpl = decodeUtf8Safe(ffi.string(gnews_l_template_buf))
    local msg = P3_formatBookingText(tpl, tag, hhmm)
    if msg == "" then return false end
    if isSampAvailable() then
        pcall(sampSendChat, "/l " .. msg)
        sampAddChatMessage("[GNEWS /l] Отправлено: /l " .. msg, 0x00FF90)
    end
    P3.gnews_status = "Отправлено в /l на " .. hhmm
    requestSaveSettings()
    return true
end

function P3_syncLecturerBuffers(idx)
    idx = idx or lect_selected
    local tpl = P3_lecturer_templates[idx]
    if not tpl then
        safeStrCopy(lect_name_buf, "", ffi.sizeof(lect_name_buf))
        safeStrCopy(lect_text_buf, "", ffi.sizeof(lect_text_buf))
        lect_loaded_idx = -1
        P3.lect_loaded_ref = nil
        return
    end
    safeStrCopy(lect_name_buf, encodeCp1251Safe(tpl.name or ""), ffi.sizeof(lect_name_buf))
    safeStrCopy(lect_text_buf, encodeCp1251Safe(tpl.text or ""), ffi.sizeof(lect_text_buf))
    lect_loaded_idx = idx
    P3.lect_loaded_ref = tpl
end

function P3_resetLecturerDefaults()
    local out = {}
    for i, tpl in ipairs(P3_default_lecturer_templates) do
        out[i] = { name = tpl.name, text = tpl.text }
    end
    P3_lecturer_templates = out
    lect_selected = 1
    lect_loaded_idx = -1
    P3.lect_loaded_ref = nil
    P3.lect_status = "Восстановлены шаблоны по умолчанию"
end

function P3_saveLecturer()
    if type(doesDirectoryExist) == "function" and not doesDirectoryExist(getWorkingDirectory() .. "/config") then
        createDirectory(getWorkingDirectory() .. "/config")
    end
    local ok, err = writeJsonAtomic(P3_lecturer_path, P3_lecturer_templates)
    if not ok then
        print("[helper_core] P3_saveLecturer error: " .. tostring(err))
        P3.lect_status = "Ошибка сохранения"
        return false
    end
    P3.lect_status = "Шаблоны сохранены"
    return true
end

function P3_loadLecturer()
    P3.lecturer_loaded = true
    local parsed = readJsonFile(P3_lecturer_path)
    if type(parsed) == "table" and #parsed > 0 then
        local cleaned = {}
        for _, entry in ipairs(parsed) do
            if type(entry) == "table" and type(entry.name) == "string" and type(entry.text) == "string"
                and not entry.name:find("%z") and not entry.text:find("%z")
                and #entry.name <= 256 and #entry.text <= 16384 then
                cleaned[#cleaned + 1] = { name = entry.name, text = entry.text }
                if #cleaned >= 200 then break end
            end
        end
        if #cleaned > 0 then
            P3_lecturer_templates = cleaned
        end
    end
    if lect_selected < 1 then lect_selected = 1 end
    if lect_selected > #P3_lecturer_templates then lect_selected = math.max(1, #P3_lecturer_templates) end
    lect_loaded_idx = -1
    P3.lect_loaded_ref = nil
end

function P3_expandLecturerTags(line)
    if not line:find("<", 1, true) then return line end
    local res = line
    res = res:gsub("<time>", function() return os.date("%H:%M:%S") end)
    res = res:gsub("<date>", function() return os.date("%d.%m.%Y") end)
    if type(user) == "table" then
        res = res:gsub("<myFio>", function() return user.fullName or "" end)
        res = res:gsub("<myName>", function() return user.name or "" end)
        res = res:gsub("<myNick>", function() return user.nick or "" end)
        res = res:gsub("<myRang>", function() return user.rangName or "" end)
        res = res:gsub("<myPodr>", function() return user.podr or "" end)
    end
    return res
end

function P3_parseLectureSteps(raw_text)
    local norm = tostring(raw_text or ""):gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"
    local steps = {}
    local speech_count = 0
    for line in norm:gmatch("(.-)\n") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            local ms_str = trimmed:match("^<(%d+)>$")
            if ms_str then
                local ms = tonumber(ms_str) or 0
                if ms == 0 then
                    steps[#steps + 1] = { kind = "pause0" }
                else
                    steps[#steps + 1] = { kind = "wait", ms = math.max(50, math.min(60000, ms)) }
                end
            else
                local expanded = P3_expandLecturerTags(trimmed)
                steps[#steps + 1] = { kind = "say", text = expanded }
                speech_count = speech_count + 1
            end
        end
    end
    return steps, speech_count
end

function P3_resolveLecturerIndex(idx_or_name)
    if #P3_lecturer_templates == 0 then return nil end
    if idx_or_name == nil or idx_or_name == "" then
        if lect_selected >= 1 and lect_selected <= #P3_lecturer_templates then
            return lect_selected
        end
        return 1
    end
    if type(idx_or_name) == "number" then
        local idx = math.floor(idx_or_name)
        if idx >= 1 and idx <= #P3_lecturer_templates then return idx end
        return nil
    end
    local q = tostring(idx_or_name):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return lect_selected end
    if q:match("^%d+$") then
        local idx = tonumber(q)
        if idx and idx >= 1 and idx <= #P3_lecturer_templates then return idx end
        return nil
    end
    local q_low = cp1251_lower(q)
    for i, tpl in ipairs(P3_lecturer_templates) do
        if cp1251_lower(tpl.name or "") == q_low then return i end
    end
    for i, tpl in ipairs(P3_lecturer_templates) do
        if cp1251_lower(tpl.name or ""):find(q_low, 1, true) then return i end
    end
    return nil
end

function P3_stopLecturer()
    local was = lect_running
    lect_running = false
    lect_paused = false
    if P3.lect_thread then
        pcall(function()
            if P3.lect_thread:status() ~= "dead" then
                P3.lect_thread:terminate()
            end
        end)
        P3.lect_thread = nil
    end
    if was and isSampAvailable() then
        sampAddChatMessage("[Лектор] Выступление остановлено.", 0xFFAA00)
    end
end

function P3_togglePauseLecturer()
    if not lect_running then return end
    lect_paused = not lect_paused
    if isSampAvailable() then
        sampAddChatMessage(lect_paused and "[Лектор] Пауза. Нажмите 'Продолжить' или введите /lect next." or "[Лектор] Продолжаем выступление.", 0x00CCFF)
    end
end

function P3_startLecturer(idx_or_name)
    if lect_running then
        if isSampAvailable() then
            sampAddChatMessage("[Лектор] Выступление уже идёт! Используйте /lectstop для остановки.", 0xFFAA00)
        end
        return false
    end
    local idx = P3_resolveLecturerIndex(idx_or_name)
    local tpl = idx and P3_lecturer_templates[idx] or nil
    if not tpl then
        if isSampAvailable() then
            sampAddChatMessage("[Лектор] Шаблон не найден. Введите /lect для списка.", 0xFF5555)
        end
        return false
    end
    local steps, speech_count = P3_parseLectureSteps(tpl.text)
    if speech_count == 0 or #steps == 0 then
        if isSampAvailable() then
            sampAddChatMessage("[Лектор] Шаблон '" .. (tpl.name or "?") .. "' пуст.", 0xFF5555)
        end
        return false
    end

    lect_selected = idx
    lect_running = true
    lect_paused = false
    lect_step = 0
    lect_total = speech_count
    local delay_ms = math.max(800, math.min(6000, tonumber(lect_delay_ms[0]) or 2000))

    P3.lect_thread = lua_thread.create(function()
        local ok_run, err_run = pcall(function()
            if not isSampAvailable() then
                lect_running = false
                return
            end
            sampAddChatMessage("[Лектор] Старт: " .. (tpl.name or "?") .. " (" .. speech_count .. " фраз, /lectstop — стоп)", 0x00FF90)
            local total_steps = #steps
            local last_send_clock = 0
            for i = 1, total_steps do
                if not lect_running or not isSampAvailable() then
                    lect_running = false
                    break
                end
                while lect_paused and lect_running do
                    if not isSampAvailable() then lect_running = false; break end
                    wait(50)
                end
                if not lect_running or not isSampAvailable() then
                    lect_running = false
                    break
                end

                local st = steps[i]
                if st.kind == "pause0" then
                    lect_paused = true
                    if isSampAvailable() then
                        sampAddChatMessage("[Лектор] Пауза (<0>). Нажмите 'Продолжить' или введите /lect next.", 0xFFAA00)
                    end
                    while lect_paused and lect_running do
                        if not isSampAvailable() then lect_running = false; break end
                        wait(50)
                    end
                elseif st.kind == "wait" then
                    local rem_w = st.ms
                    while rem_w > 0 and lect_running do
                        if not isSampAvailable() then lect_running = false; break end
                        if lect_paused then
                            while lect_paused and lect_running do
                                if not isSampAvailable() then lect_running = false; break end
                                wait(50)
                            end
                        else
                            local chunk = math.min(50, rem_w)
                            wait(chunk)
                            rem_w = rem_w - chunk
                        end
                    end
                elseif st.kind == "say" then
                    local cmd_pref = st.text:match("^(/%w+%s+)")
                    local send_parts = nil
                    if cmd_pref then
                        send_parts = splitChatIntoChunks(cmd_pref, st.text:sub(#cmd_pref + 1), 120, 16)
                    else
                        send_parts = splitChatIntoChunks("", st.text, 120, 16)
                    end
                    if not send_parts then
                        send_parts = { st.text }
                    end

                    for _, part_txt in ipairs(send_parts) do
                        if not lect_running or not isSampAvailable() then
                            lect_running = false
                            break
                        end
                        if last_send_clock > 0 then
                            local elapsed_ms = (os.clock() - last_send_clock) * 1000
                            if elapsed_ms < 800 then
                                local need_ms = math.ceil(800 - elapsed_ms)
                                while need_ms > 0 and lect_running do
                                    if not isSampAvailable() then lect_running = false; break end
                                    if lect_paused then
                                        wait(50)
                                    else
                                        local chunk = math.min(50, need_ms)
                                        wait(chunk)
                                        need_ms = need_ms - chunk
                                    end
                                end
                            end
                        end
                        if not lect_running or not isSampAvailable() then
                            lect_running = false
                            break
                        end
                        rp_sending_internal = true
                        pcall(sampSendChat, part_txt)
                        rp_sending_internal = false
                        last_send_clock = os.clock()
                    end
                    if not lect_running then break end

                    lect_step = lect_step + 1
                    local nxt = steps[i + 1]
                    if nxt and nxt.kind == "say" then
                        local rem_d = delay_ms
                        while rem_d > 0 and lect_running do
                            if not isSampAvailable() then lect_running = false; break end
                            if lect_paused then
                                while lect_paused and lect_running do
                                    if not isSampAvailable() then lect_running = false; break end
                                    wait(50)
                                end
                            else
                                local chunk = math.min(50, rem_d)
                                wait(chunk)
                                rem_d = rem_d - chunk
                            end
                        end
                    end
                end
            end
        end)
        local finished = lect_running
        lect_running = false
        lect_paused = false
        P3.lect_thread = nil
        if not ok_run then
            if isSampAvailable() then
                sampAddChatMessage("[Лектор] Ошибка: " .. tostring(err_run), 0xFF5555)
            end
        elseif finished and isSampAvailable() then
            sampAddChatMessage("[Лектор] Завершено: " .. (tpl.name or ""), 0x00FF90)
        end
    end)
    if not P3.lect_thread then
        lect_running = false
        lect_paused = false
        return false
    end
    return true
end

function P3_cmdLect(arg)
    local q = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then
        show_main_window[0] = true
        for i, mod in ipairs(modules) do
            if mod.id == "lecturer" then
                active_module_idx = i
                pending_module_idx = nil
                break
            end
        end
        if isSampAvailable() then
            sampAddChatMessage("[Лектор] Команды: /lect [номер/название] | /lectstop — стоп | /lect next — продолжить", 0x00CCFF)
            for i, tpl in ipairs(P3_lecturer_templates) do
                sampAddChatMessage(string.format("  %d. %s", i, tpl.name or "?"), 0xCECECE)
            end
            if lect_running then
                sampAddChatMessage("[Лектор] Активно: шаг " .. lect_step .. "/" .. lect_total .. (lect_paused and " [ПАУЗА — /lect next]" or ""), 0xFFCC00)
            end
        end
        return
    end
    local q_low = cp1251_lower(q)
    if lect_running and (q_low == "next" or q_low == "resume" or q_low == "далее" or q_low == "продолжить") then
        if lect_paused then
            P3_togglePauseLecturer()
        elseif isSampAvailable() then
            sampAddChatMessage("[Лектор] Выступление уже идёт (пауза не активна).", 0xCECECE)
        end
        return
    end
    if lect_running and (q_low == "pause" or q_low == "пауза") then
        P3_togglePauseLecturer()
        return
    end
    if lect_running and (q_low == "stop" or q_low == "стоп") then
        P3_stopLecturer()
        return
    end
    P3_startLecturer(q)
end

function P3_drawLecturerUI()
    if #P3_lecturer_templates == 0 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.7, 0.3, 1.0))
        imgui.TextUnformatted(u8"Список шаблонов пуст.")
        imgui.PopStyleColor()
        if imgui.Button(u8"+ Новый шаблон##lect_add_empty", imgui.ImVec2(150, 28)) then
            P3_lecturer_templates[1] = { name = "Новый шаблон", text = "Первая строка\n<0>\nВторая строка" }
            lect_selected = 1
            P3_syncLecturerBuffers(1)
            queueTask(P3_saveLecturer)
        end
        imgui.SameLine()
        if imgui.Button(u8"Восстановить дефолты##lect_rst_empty", imgui.ImVec2(170, 28)) then
            P3_resetLecturerDefaults()
            P3_syncLecturerBuffers(1)
            queueTask(P3_saveLecturer)
        end
        return
    end

    if lect_selected < 1 then lect_selected = 1 end
    if lect_selected > #P3_lecturer_templates then lect_selected = #P3_lecturer_templates end
    local cur_tpl = P3_lecturer_templates[lect_selected]
    if lect_loaded_idx ~= lect_selected or P3.lect_loaded_ref ~= cur_tpl then
        P3_syncLecturerBuffers(lect_selected)
    end

    imgui.BeginChild("##lect_tpl_list", imgui.ImVec2(190, 235), true)
    imgui.TextUnformatted(u8"Шаблоны (" .. tostring(#P3_lecturer_templates) .. "):")
    imgui.Separator()
    for i, tpl in ipairs(P3_lecturer_templates) do
        local lbl_cp = tostring(i) .. ". " .. ((tpl.name and tpl.name ~= "") and tpl.name or "Без названия")
        if imgui.Selectable(encodeCp1251Safe(lbl_cp) .. "##lect_tpl_" .. i, lect_selected == i) then
            lect_selected = i
            P3_syncLecturerBuffers(i)
        end
    end
    imgui.EndChild()

    imgui.SameLine()

    imgui.BeginChild("##lect_tpl_edit", imgui.ImVec2(0, 235), true)
    imgui.TextUnformatted(u8"Название шаблона:")
    imgui.PushItemWidth(-1)
    if imgui.InputText("##lect_name", lect_name_buf, ffi.sizeof(lect_name_buf)) then
        cur_tpl.name = decodeUtf8Safe(ffi.string(lect_name_buf))
    end
    if imgui.IsItemDeactivatedAfterEdit() then
        queueTask(P3_saveLecturer)
    end
    imgui.PopItemWidth()

    imgui.TextUnformatted(u8"Текст (<0> = пауза, <1500> = мс):")
    if imgui.InputTextMultiline("##lect_text", lect_text_buf, ffi.sizeof(lect_text_buf), imgui.ImVec2(-1, 145)) then
        cur_tpl.text = decodeUtf8Safe(ffi.string(lect_text_buf))
    end
    if imgui.IsItemDeactivatedAfterEdit() then
        queueTask(P3_saveLecturer)
    end
    imgui.EndChild()

    imgui.Spacing()
    imgui.PushItemWidth(220)
    if imgui.SliderInt(u8"Задержка между строками (мс)##lect_delay", lect_delay_ms, 800, 6000) then
        requestSaveSettings()
    end
    imgui.PopItemWidth()

    imgui.Spacing()
    if imgui.Button(u8"Сохранить##lect_save", imgui.ImVec2(100, 28)) then
        cur_tpl.name = decodeUtf8Safe(ffi.string(lect_name_buf))
        cur_tpl.text = decodeUtf8Safe(ffi.string(lect_text_buf))
        queueTask(P3_saveLecturer)
    end
    imgui.SameLine()
    if imgui.Button(u8"+ Новый##lect_add", imgui.ImVec2(95, 28)) then
        local new_idx = #P3_lecturer_templates + 1
        P3_lecturer_templates[new_idx] = {
            name = "Шаблон " .. tostring(new_idx),
            text = "Первая фраза лекции.\n<0>\nВторая фраза лекции."
        }
        lect_selected = new_idx
        P3_syncLecturerBuffers(new_idx)
        queueTask(P3_saveLecturer)
    end
    if #P3_lecturer_templates > 1 then
        imgui.SameLine()
        if imgui.Button(u8"Удалить##lect_del", imgui.ImVec2(95, 28)) then
            table.remove(P3_lecturer_templates, lect_selected)
            if lect_selected > #P3_lecturer_templates then lect_selected = #P3_lecturer_templates end
            P3_syncLecturerBuffers(lect_selected)
            queueTask(P3_saveLecturer)
        end
    end
    imgui.SameLine()
    if imgui.Button(u8"Сбросить дефолты##lect_reset", imgui.ImVec2(145, 28)) then
        P3_resetLecturerDefaults()
        P3_syncLecturerBuffers(1)
        queueTask(P3_saveLecturer)
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    if lect_running then
        local st_col = lect_paused and imgui.ImVec4(1.0, 0.8, 0.25, 1.0) or imgui.ImVec4(0.3, 1.0, 0.5, 1.0)
        imgui.PushStyleColor(imgui.Col.Text, st_col)
        imgui.TextUnformatted(encodeCp1251Safe("Статус: строка " .. tostring(lect_step) .. " / " .. tostring(lect_total) .. (lect_paused and " [ПАУЗА]" or " [ИДЁТ]")))
        imgui.PopStyleColor()

        if imgui.Button((lect_paused and u8"Продолжить##lect_pause" or u8"Пауза##lect_pause"), imgui.ImVec2(140, 32)) then
            queueTask(P3_togglePauseLecturer)
        end
        imgui.SameLine()
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1.0))
        if imgui.Button(u8"Стоп (/lectstop)##lect_stop", imgui.ImVec2(160, 32)) then
            queueTask(P3_stopLecturer)
        end
        imgui.PopStyleColor(3)
    else
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.1, 0.6, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.2, 0.8, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.0, 0.5, 0.2, 1.0))
        if imgui.Button(u8"Запустить (/lect)##lect_start", imgui.ImVec2(170, 32)) then
            cur_tpl.name = decodeUtf8Safe(ffi.string(lect_name_buf))
            cur_tpl.text = decodeUtf8Safe(ffi.string(lect_text_buf))
            local sel_idx = lect_selected
            queueTask(function() P3_startLecturer(sel_idx) end)
        end
        imgui.PopStyleColor(3)
        if P3.lect_status and P3.lect_status ~= "" then
            imgui.SameLine()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.85, 1.0, 1.0))
            imgui.TextUnformatted(encodeCp1251Safe(P3.lect_status))
            imgui.PopStyleColor()
        end
    end

    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.55, 1.0))
    imgui.TextUnformatted(u8"Команды: /lect [номер/название] | /lect next | /lectstop")
    imgui.PopStyleColor()
end
function P4_sanitizeStr(val, max_len)
    if type(val) ~= "string" then return "" end
    local s = val:gsub("%z", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if max_len and #s > max_len then s = s:sub(1, max_len) end
    return s
end

function P4_saveCodex()
    if not doesDirectoryExist(getWorkingDirectory() .. "/config") then
        createDirectory(getWorkingDirectory() .. "/config")
    end
    local ok, err = writeJsonAtomic(P4_codex_path, P4_codex)
    if not ok then
        print("[helper_core] P4_saveCodex error: " .. tostring(err))
    end
    return ok
end

function P4_loadCodex()
    local parsed = readJsonFile(P4_codex_path)
    if type(parsed) ~= "table" then return false end
    local def = P4_buildDefaultCodex(parsed.server_idx or p4_codex_server[0])
    if type(parsed.server_idx) == "number" then
        local si = math.max(0, math.min(3, math.floor(parsed.server_idx)))
        def.server_idx = si
        def.server_name = P4_server_names[si] or "Blue"
        p4_codex_server[0] = si
    end
    if type(parsed.uk) == "table" and #parsed.uk > 0 then
        local cleaned_uk = {}
        for _, e in ipairs(parsed.uk) do
            if type(e) == "table" then
                local c = P4_sanitizeStr(e.code, 24)
                local t = P4_sanitizeStr(e.title, 128)
                if c ~= "" and t ~= "" then
                    cleaned_uk[#cleaned_uk + 1] = {
                        code = c,
                        title = t,
                        stars = math.max(1, math.min(6, math.floor(tonumber(e.stars) or 1))),
                        rp = P4_sanitizeStr(e.rp, 200),
                    }
                    if #cleaned_uk >= 200 then break end
                end
            end
        end
        if #cleaned_uk > 0 then def.uk = cleaned_uk end
    end
    if type(parsed.ak) == "table" and #parsed.ak > 0 then
        local cleaned_ak = {}
        for _, e in ipairs(parsed.ak) do
            if type(e) == "table" then
                local c = P4_sanitizeStr(e.code, 24)
                local t = P4_sanitizeStr(e.title, 128)
                if c ~= "" and t ~= "" then
                    cleaned_ak[#cleaned_ak + 1] = {
                        code = c,
                        title = t,
                        fine = math.max(100, math.min(50000, math.floor(tonumber(e.fine) or 1000))),
                        rp = P4_sanitizeStr(e.rp, 200),
                    }
                    if #cleaned_ak >= 200 then break end
                end
            end
        end
        if #cleaned_ak > 0 then def.ak = cleaned_ak end
    end
    if type(parsed.ecp) == "table" and #parsed.ecp > 0 then
        local cleaned_ecp = {}
        for _, e in ipairs(parsed.ecp) do
            if type(e) == "table" then
                local n = P4_sanitizeStr(e.name, 96)
                local cm = P4_sanitizeStr(e.cmd, 32)
                if cm == "" then cm = "medhelp" end
                if n ~= "" then
                    cleaned_ecp[#cleaned_ecp + 1] = {
                        name = n,
                        cmd = cm,
                        med_type = math.max(0, math.min(3, math.floor(tonumber(e.med_type) or 0))),
                        price = math.max(0, math.min(100000, math.floor(tonumber(e.price) or 500))),
                        rp = P4_sanitizeStr(e.rp, 200),
                    }
                    if #cleaned_ecp >= 100 then break end
                end
            end
        end
        if #cleaned_ecp > 0 then def.ecp = cleaned_ecp end
    end
    P4_codex = def
    return true
end

function P4_applyServerPreset(srv_idx, defer_save)
    local si = math.max(0, math.min(3, math.floor(tonumber(srv_idx) or 0)))
    p4_codex_server[0] = si
    P4_codex = P4_buildDefaultCodex(si)
    p4_uk_edit_idx = 0
    p4_ak_edit_idx = 0
    p4_ecp_edit_idx = 0
    if defer_save then
        queueTask(P4_saveCodex)
    else
        P4_saveCodex()
    end
    requestSaveSettings()
    p4_status_msg = "Применена база для сервера " .. (P4_server_names[si] or "Blue")
end

function P4_openSuMenu(pid)
    local raw = tostring(pid or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw ~= "" then
        local num = raw:match("^%d+$") and tonumber(raw) or nil
        if not num or num < 0 or num > 1004 then
            if isSampAvailable() then
                sampAddChatMessage("[Helper МВД] Укажите корректный ID игрока (0-1004): " .. raw, 0xFF4444)
            end
            return
        end
        suw_target_id[0] = num
    end
    suw_show[0] = true
end

function P4_openMedMenu(pid)
    local raw = tostring(pid or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw ~= "" then
        local num = raw:match("^%d+$") and tonumber(raw) or nil
        if not num or num < 0 or num > 1004 then
            if isSampAvailable() then
                sampAddChatMessage("[Helper МЗ] Укажите корректный ID игрока (0-1004): " .. raw, 0xFF4444)
            end
            return
        end
        medui_target_id[0] = num
    end
    medui_show[0] = true
end

function P4_sendInternalChat(msg)
    if type(msg) ~= "string" or msg == "" then return false end
    if not isSampAvailable() then return false end
    rp_sending_internal = true
    local ok, err = pcall(sampSendChat, msg)
    rp_sending_internal = false
    if not ok then print("[helper_core] P4_sendInternalChat error: " .. tostring(err)) end
    return ok
end

function P4_canRunActionDebounce()
    local now_ms = os.clock() * 1000
    if (now_ms - (P4.last_action_ms or 0)) < 800 then
        if isSampAvailable() then
            sampAddChatMessage("[Helper] Подождите 0.8 сек перед повторным действием.", 0xFFAA00)
        end
        return false
    end
    P4.last_action_ms = now_ms
    return true
end

function P4_issueWanted(pid, stars, reason, rp_line)
    if not isSampAvailable() then return false end
    local id_num = tonumber(pid)
    if not id_num or id_num < 0 or id_num > 1004 then
        sampAddChatMessage("[Helper МВД] Укажите корректный ID игрока (0-1004)", 0xFF4444)
        return false
    end
    if not P4_canRunActionDebounce() then return false end
    id_num = math.floor(id_num)
    local st = math.max(1, math.min(6, math.floor(tonumber(stars) or 1)))
    local rsn = P4_sanitizeStr(tostring(reason or ""), 64)
    if rsn == "" then rsn = "Нарушение УК" end
    local cmd_str = string.format("/su %d %d %s", id_num, st, rsn)
    if type(rp_line) == "string" and rp_line ~= "" then
        P4_sendInternalChat(rp_line)
        scheduleTask(350, function()
            if isSampAvailable() then
                P4_sendInternalChat(cmd_str)
            end
        end)
    else
        P4_sendInternalChat(cmd_str)
    end
    return true
end

function P4_issueTicket(pid, fine, reason, rp_line)
    if not isSampAvailable() then return false end
    local id_num = tonumber(pid)
    if not id_num or id_num < 0 or id_num > 1004 then
        sampAddChatMessage("[Helper МВД] Укажите корректный ID игрока (0-1004)", 0xFF4444)
        return false
    end
    if not P4_canRunActionDebounce() then return false end
    id_num = math.floor(id_num)
    local fn = math.max(100, math.min(50000, math.floor(tonumber(fine) or 1000)))
    local rsn = P4_sanitizeStr(tostring(reason or ""), 64)
    if rsn == "" then rsn = "Нарушение АК" end
    local cmd_str = string.format("/ticket %d %d %s", id_num, fn, rsn)
    if type(rp_line) == "string" and rp_line ~= "" then
        P4_sendInternalChat(rp_line)
        scheduleTask(350, function()
            if isSampAvailable() then
                P4_sendInternalChat(cmd_str)
            end
        end)
    else
        P4_sendInternalChat(cmd_str)
    end
    return true
end

function P4_formatEcpCommand(entry, pid)
    if type(entry) ~= "table" then return "" end
    local id_num = math.max(0, math.min(1004, math.floor(tonumber(pid) or 0)))
    local price = math.max(0, math.min(100000, math.floor(tonumber(entry.price) or 500)))
    local c = tostring(entry.cmd or "medhelp")
    if c == "medhelp" then
        return string.format("/medhelp %d", id_num)
    elseif c == "heal" then
        return string.format("/heal %d %d", id_num, price)
    elseif c == "medcard" then
        local mt = math.max(1, math.min(3, math.floor(tonumber(entry.med_type) or 1)))
        return string.format("/medcard %d %d %d", id_num, mt, price)
    elseif c == "analysis" then
        return string.format("/analysis %d", id_num)
    end
    return string.format("/%s %d", c, id_num)
end

function P4_runMedicAction(cmd_str, rp_line)
    if type(cmd_str) ~= "string" or cmd_str == "" then return false end
    if not isSampAvailable() then return false end
    if not P4_canRunActionDebounce() then return false end
    if type(rp_line) == "string" and rp_line ~= "" then
        P4_sendInternalChat(rp_line)
        scheduleTask(450, function()
            if isSampAvailable() then
                P4_sendInternalChat(cmd_str)
            end
        end)
    else
        P4_sendInternalChat(cmd_str)
    end
    return true
end

function P4_sendMegaphone(idx)
    local phrase = P4_megaphone_lines[idx]
    if type(phrase) == "string" and phrase ~= "" then
        return P4_sendInternalChat("/m " .. phrase)
    end
    return false
end

function P4_recordDamage(is_give, playerId, damage, weapon, bodypart)
    if not dmg_enabled[0] or not isModuleEnabled("faction_tools") then return end
    local pid = tonumber(playerId)
    local nick = "Неизвестно"
    if pid and pid >= 0 and pid <= 1004 then
        local cached = online_ids_to_nicks and online_ids_to_nicks[pid]
        if type(cached) == "string" and cached ~= "" then
            nick = cached
        elseif pid == my_cached_id and my_cached_nick ~= "" then
            nick = my_cached_nick
        else
            local ok_n, n = pcall(sampGetPlayerNickname, pid)
            if ok_n and type(n) == "string" and n ~= "" then nick = n end
        end
    elseif pid == 65535 then
        nick = "Среда/Удар"
    end
    local dmg_val = math.floor((tonumber(damage) or 0) + 0.5)
    local wid = tonumber(weapon) or 0
    local w_name = P4_weapon_names[wid] or ("Оружие #" .. tostring(wid))
    local bp_name = P4_bodypart_names[tonumber(bodypart) or -1] or ""
    local id_tag = (pid and pid >= 0 and pid <= 1004) and (" [" .. tostring(pid) .. "]") or ""
    local hud_line
    if is_give then
        hud_line = "+Хит: " .. nick .. id_tag .. " -" .. tostring(dmg_val) .. " (" .. w_name .. ")"
    else
        hud_line = "-Урон: " .. nick .. id_tag .. " -" .. tostring(dmg_val) .. " (" .. w_name .. ")"
    end
    local log_line = "[" .. os.date("%H:%M:%S") .. "] " .. hud_line .. (bp_name ~= "" and (" | " .. bp_name) or "")
    table.insert(dmg_log, 1, {
        give = is_give and true or false,
        pid = pid or -1,
        nick = nick,
        dmg = dmg_val,
        weapon = w_name,
        bodypart = bp_name,
        text = log_line,
    })
    while #dmg_log > 25 do
        table.remove(dmg_log)
    end
    dmg_last_hud = hud_line
    dmg_last_ts = os.time()
end

function P4_resetUkForm()
    p4_uk_edit_idx = 0
    safeStrCopy(p4_uk_code_buf, "", ffi.sizeof(p4_uk_code_buf))
    safeStrCopy(p4_uk_title_buf, "", ffi.sizeof(p4_uk_title_buf))
    p4_uk_stars[0] = 2
    safeStrCopy(p4_uk_rp_buf, "", ffi.sizeof(p4_uk_rp_buf))
end

function P4_resetAkForm()
    p4_ak_edit_idx = 0
    safeStrCopy(p4_ak_code_buf, "", ffi.sizeof(p4_ak_code_buf))
    safeStrCopy(p4_ak_title_buf, "", ffi.sizeof(p4_ak_title_buf))
    p4_ak_fine[0] = 1500
    safeStrCopy(p4_ak_rp_buf, "", ffi.sizeof(p4_ak_rp_buf))
end

function P4_resetEcpForm()
    p4_ecp_edit_idx = 0
    safeStrCopy(p4_ecp_name_buf, "", ffi.sizeof(p4_ecp_name_buf))
    p4_ecp_cmd_idx[0] = 0
    p4_ecp_med_type[0] = 1
    p4_ecp_price[0] = 500
    safeStrCopy(p4_ecp_rp_buf, "", ffi.sizeof(p4_ecp_rp_buf))
end

function P4_drawFactionUI()
    if imgui.Button(u8"МВД: /suw и УК/АК##p4_tab1", imgui.ImVec2(165, 24)) then p4_ui_page = 1 end
    imgui.SameLine()
    if imgui.Button(u8"МЗ: /medui и ЕЦП##p4_tab2", imgui.ImVec2(165, 24)) then p4_ui_page = 2 end
    imgui.SameLine()
    if imgui.Button(u8"Damage Informer##p4_tab3", imgui.ImVec2(165, 24)) then p4_ui_page = 3 end
    imgui.Separator()
    imgui.Spacing()

    if p4_ui_page == 1 then
        if imgui.Button(u8"Открыть окно /suw##p4_btn_suw", imgui.ImVec2(180, 26)) then
            suw_show[0] = true
        end
        imgui.SameLine()
        imgui.TextUnformatted(u8"Команда: /suw [ID игрока]")
        if imgui.Checkbox(u8"Авто-РП на /cuff, /uncuff, /search, /putpl, /arrest, /medhelp, /heal", p4_autorp_enabled) then
            requestSaveSettings()
        end
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1))
        imgui.TextUnformatted(u8"-> Ручной ввод /su [ID] [звёзды] [причина] в чат остаётся 100% нативным")
        imgui.PopStyleColor()
        imgui.Spacing()

        imgui.PushItemWidth(160)
        if imgui.ComboStr(u8"Сервер Advance RP##p4_srv_cmb", p4_codex_server, "Blue\0Red\0Green\0Chocolate\0") then
            requestSaveSettings()
        end
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(u8"Сбросить справочник под сервер##p4_srv_reset") then
            P4_applyServerPreset(p4_codex_server[0], true)
        end

        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 0.85, 1.0, 1))
        imgui.TextUnformatted(u8"Быстрый мегафон (/m):")
        imgui.PopStyleColor()
        for mi, mline in ipairs(P4_megaphone_lines) do
            if mi > 1 and mi ~= 3 then imgui.SameLine() end
            if imgui.Button(u8"Мегафон " .. mi .. "##p4_ui_m_" .. mi, imgui.ImVec2(130, 22)) then
                local midx = mi
                queueTask(function() P4_sendMegaphone(midx) end)
            end
            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.TextUnformatted(encodeCp1251Safe(mline))
                imgui.EndTooltip()
            end
        end

        imgui.Spacing()
        imgui.Separator()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.85, 0.35, 1))
        imgui.TextUnformatted(u8"Редактор статей УК (" .. #P4_codex.uk .. u8" шт.):")
        imgui.PopStyleColor()
        imgui.PushItemWidth(80)
        imgui.InputText(u8"Код##p4_uk_c", p4_uk_code_buf, ffi.sizeof(p4_uk_code_buf))
        imgui.SameLine()
        imgui.PushItemWidth(260)
        imgui.InputText(u8"Название##p4_uk_t", p4_uk_title_buf, ffi.sizeof(p4_uk_title_buf))
        imgui.PopItemWidth()
        imgui.PopItemWidth()
        imgui.PushItemWidth(140)
        imgui.SliderInt(u8"Звёзды##p4_uk_s", p4_uk_stars, 1, 6)
        imgui.PopItemWidth()
        imgui.PushItemWidth(380)
        imgui.InputText(u8"РП (/me)##p4_uk_rp", p4_uk_rp_buf, ffi.sizeof(p4_uk_rp_buf))
        imgui.PopItemWidth()
        local uk_btn_lbl = (p4_uk_edit_idx > 0) and u8"Сохранить УК##p4_uk_save" or u8"Добавить УК##p4_uk_save"
        if imgui.Button(uk_btn_lbl, imgui.ImVec2(130, 22)) then
            local c_cp = P4_sanitizeStr(decodeUtf8Safe(ffi.string(p4_uk_code_buf)), 24)
            local t_cp = P4_sanitizeStr(decodeUtf8Safe(ffi.string(p4_uk_title_buf)), 128)
            local r_cp = P4_sanitizeStr(decodeUtf8Safe(ffi.string(p4_uk_rp_buf)), 200)
            if c_cp ~= "" and t_cp ~= "" then
                local item = { code = c_cp, title = t_cp, stars = math.max(1, math.min(6, p4_uk_stars[0])), rp = r_cp }
                if p4_uk_edit_idx > 0 and P4_codex.uk[p4_uk_edit_idx] then
                    P4_codex.uk[p4_uk_edit_idx] = item
                    p4_status_msg = "Статья УК обновлена: " .. c_cp
                else
                    P4_codex.uk[#P4_codex.uk + 1] = item
                    p4_status_msg = "Статья УК добавлена: " .. c_cp
                end
                P4_resetUkForm()
                queueTask(P4_saveCodex)
            else
                p4_status_msg = "Заполните код и название статьи УК"
            end
        end
        imgui.SameLine()
        if imgui.Button(u8"Сброс формы##p4_uk_rst", imgui.ImVec2(110, 22)) then P4_resetUkForm() end

        imgui.BeginChild("##p4_uk_list", imgui.ImVec2(0, 130), true)
        for idx, art in ipairs(P4_codex.uk) do
            if imgui.SmallButton(u8"Ред.##uk_e_" .. idx) then
                p4_uk_edit_idx = idx
                safeStrCopy(p4_uk_code_buf, encodeCp1251Safe(art.code), ffi.sizeof(p4_uk_code_buf))
                safeStrCopy(p4_uk_title_buf, encodeCp1251Safe(art.title), ffi.sizeof(p4_uk_title_buf))
                p4_uk_stars[0] = art.stars or 1
                safeStrCopy(p4_uk_rp_buf, encodeCp1251Safe(art.rp or ""), ffi.sizeof(p4_uk_rp_buf))
            end
            imgui.SameLine()
            if imgui.SmallButton(u8"Удал.##uk_d_" .. idx) then
                table.remove(P4_codex.uk, idx)
                if p4_uk_edit_idx == idx then P4_resetUkForm()
                elseif p4_uk_edit_idx > idx then p4_uk_edit_idx = p4_uk_edit_idx - 1 end
                queueTask(P4_saveCodex)
                break
            end
            imgui.SameLine()
            imgui.TextUnformatted(encodeCp1251Safe("[" .. art.code .. "] " .. art.title .. " (" .. tostring(art.stars) .. " зв.)"))
        end
        imgui.EndChild()

        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 1.0, 0.65, 1))
        imgui.TextUnformatted(u8"Редактор статей АК (" .. #P4_codex.ak .. u8" шт.):")
        imgui.PopStyleColor()
        imgui.PushItemWidth(80)
        imgui.InputText(u8"Код##p4_ak_c", p4_ak_code_buf, ffi.sizeof(p4_ak_code_buf))
        imgui.SameLine()
        imgui.PushItemWidth(260)
        imgui.InputText(u8"Название##p4_ak_t", p4_ak_title_buf, ffi.sizeof(p4_ak_title_buf))
        imgui.PopItemWidth()
        imgui.PopItemWidth()
        imgui.PushItemWidth(140)
        imgui.InputInt(u8"Штраф ($)##p4_ak_f", p4_ak_fine)
        if p4_ak_fine[0] < 100 then p4_ak_fine[0] = 100 end
        if p4_ak_fine[0] > 50000 then p4_ak_fine[0] = 50000 end
        imgui.PopItemWidth()
        imgui.PushItemWidth(380)
        imgui.InputText(u8"РП (/me)##p4_ak_rp", p4_ak_rp_buf, ffi.sizeof(p4_ak_rp_buf))
        imgui.PopItemWidth()
        local ak_btn_lbl = (p4_ak_edit_idx > 0) and u8"Сохранить АК##p4_ak_save" or u8"Добавить АК##p4_ak_save"
        if imgui.Button(ak_btn_lbl, imgui.ImVec2(130, 22)) then
            local c_cp = P4_sanitizeStr(decodeUtf8Safe(ffi.string(p4_ak_code_buf)), 24)
            local t_cp = P4_sanitizeStr(decodeUtf8Safe(ffi.string(p4_ak_title_buf)), 128)
            local r_cp = P4_sanitizeStr(decodeUtf8Safe(ffi.string(p4_ak_rp_buf)), 200)
            if c_cp ~= "" and t_cp ~= "" then
                local item = { code = c_cp, title = t_cp, fine = math.max(100, math.min(50000, p4_ak_fine[0])), rp = r_cp }
                if p4_ak_edit_idx > 0 and P4_codex.ak[p4_ak_edit_idx] then
                    P4_codex.ak[p4_ak_edit_idx] = item
                    p4_status_msg = "Статья АК обновлена: " .. c_cp
                else
                    P4_codex.ak[#P4_codex.ak + 1] = item
                    p4_status_msg = "Статья АК добавлена: " .. c_cp
                end
                P4_resetAkForm()
                queueTask(P4_saveCodex)
            else
                p4_status_msg = "Заполните код и название статьи АК"
            end
        end
        imgui.SameLine()
        if imgui.Button(u8"Сброс формы##p4_ak_rst", imgui.ImVec2(110, 22)) then P4_resetAkForm() end

        imgui.BeginChild("##p4_ak_list", imgui.ImVec2(0, 110), true)
        for idx, art in ipairs(P4_codex.ak) do
            if imgui.SmallButton(u8"Ред.##ak_e_" .. idx) then
                p4_ak_edit_idx = idx
                safeStrCopy(p4_ak_code_buf, encodeCp1251Safe(art.code), ffi.sizeof(p4_ak_code_buf))
                safeStrCopy(p4_ak_title_buf, encodeCp1251Safe(art.title), ffi.sizeof(p4_ak_title_buf))
                p4_ak_fine[0] = art.fine or 1500
                safeStrCopy(p4_ak_rp_buf, encodeCp1251Safe(art.rp or ""), ffi.sizeof(p4_ak_rp_buf))
            end
            imgui.SameLine()
            if imgui.SmallButton(u8"Удал.##ak_d_" .. idx) then
                table.remove(P4_codex.ak, idx)
                if p4_ak_edit_idx == idx then P4_resetAkForm()
                elseif p4_ak_edit_idx > idx then p4_ak_edit_idx = p4_ak_edit_idx - 1 end
                queueTask(P4_saveCodex)
                break
            end
            imgui.SameLine()
            imgui.TextUnformatted(encodeCp1251Safe("[" .. art.code .. "] " .. art.title .. " (" .. tostring(art.fine) .. "$)"))
        end
        imgui.EndChild()

    elseif p4_ui_page == 2 then
        if imgui.Button(u8"Открыть окно медика (/medui)##p4_btn_medui", imgui.ImVec2(210, 26)) then
            medui_show[0] = true
        end
        imgui.SameLine()
        imgui.TextUnformatted(u8"Команда: /medui [ID пациента]")
        if imgui.Checkbox(u8"Авто-РП при ручном /medhelp и /heal", p4_autorp_enabled) then
            requestSaveSettings()
        end
        imgui.Separator()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 1.0, 0.75, 1))
        imgui.TextUnformatted(u8"Настройка ЕЦП МЗ (" .. #P4_codex.ecp .. u8" позиций):")
        imgui.PopStyleColor()

        imgui.PushItemWidth(300)
        imgui.InputText(u8"Услуга##p4_ecp_nm", p4_ecp_name_buf, ffi.sizeof(p4_ecp_name_buf))
        imgui.PopItemWidth()
        imgui.PushItemWidth(140)
        imgui.ComboStr(u8"Команда##p4_ecp_cmd", p4_ecp_cmd_idx, "/medhelp\0/heal\0/medcard\0/analysis\0")
        imgui.SameLine()
        imgui.InputInt(u8"Цена ($)##p4_ecp_pr", p4_ecp_price)
        if p4_ecp_price[0] < 0 then p4_ecp_price[0] = 0 end
        if p4_ecp_price[0] > 100000 then p4_ecp_price[0] = 100000 end
        imgui.PopItemWidth()
        if p4_ecp_cmd_idx[0] == 2 then
            imgui.PushItemWidth(140)
            imgui.SliderInt(u8"Тип медкарты##p4_ecp_mt", p4_ecp_med_type, 1, 3)
            imgui.PopItemWidth()
        end
        imgui.PushItemWidth(380)
        imgui.InputText(u8"РП (/me)##p4_ecp_rp", p4_ecp_rp_buf, ffi.sizeof(p4_ecp_rp_buf))
        imgui.PopItemWidth()

        local ecp_btn_lbl = (p4_ecp_edit_idx > 0) and u8"Сохранить ЕЦП##p4_ecp_save" or u8"Добавить ЕЦП##p4_ecp_save"
        if imgui.Button(ecp_btn_lbl, imgui.ImVec2(140, 22)) then
            local n_cp = P4_sanitizeStr(decodeUtf8Safe(ffi.string(p4_ecp_name_buf)), 96)
            local r_cp = P4_sanitizeStr(decodeUtf8Safe(ffi.string(p4_ecp_rp_buf)), 200)
            local c_str = P4_ecp_cmds[p4_ecp_cmd_idx[0]] or "medhelp"
            if n_cp ~= "" then
                local entry = {
                    name = n_cp,
                    cmd = c_str,
                    med_type = (c_str == "medcard") and math.max(1, math.min(3, p4_ecp_med_type[0])) or 0,
                    price = math.max(0, math.min(100000, p4_ecp_price[0])),
                    rp = r_cp,
                }
                if p4_ecp_edit_idx > 0 and P4_codex.ecp[p4_ecp_edit_idx] then
                    P4_codex.ecp[p4_ecp_edit_idx] = entry
                    p4_status_msg = "Позиция ЕЦП обновлена"
                else
                    P4_codex.ecp[#P4_codex.ecp + 1] = entry
                    p4_status_msg = "Позиция ЕЦП добавлена"
                end
                P4_resetEcpForm()
                queueTask(P4_saveCodex)
            else
                p4_status_msg = "Укажите название услуги ЕЦП"
            end
        end
        imgui.SameLine()
        if imgui.Button(u8"Сброс формы##p4_ecp_rst", imgui.ImVec2(110, 22)) then P4_resetEcpForm() end

        imgui.BeginChild("##p4_ecp_list", imgui.ImVec2(0, 190), true)
        for idx, e in ipairs(P4_codex.ecp) do
            if imgui.SmallButton(u8"Ред.##ecp_e_" .. idx) then
                p4_ecp_edit_idx = idx
                safeStrCopy(p4_ecp_name_buf, encodeCp1251Safe(e.name), ffi.sizeof(p4_ecp_name_buf))
                p4_ecp_price[0] = e.price or 500
                p4_ecp_med_type[0] = (e.med_type and e.med_type > 0) and e.med_type or 1
                p4_ecp_cmd_idx[0] = 0
                for ci, cname in pairs(P4_ecp_cmds) do
                    if cname == e.cmd then p4_ecp_cmd_idx[0] = ci break end
                end
                safeStrCopy(p4_ecp_rp_buf, encodeCp1251Safe(e.rp or ""), ffi.sizeof(p4_ecp_rp_buf))
            end
            imgui.SameLine()
            if imgui.SmallButton(u8"Удал.##ecp_d_" .. idx) then
                table.remove(P4_codex.ecp, idx)
                if p4_ecp_edit_idx == idx then P4_resetEcpForm()
                elseif p4_ecp_edit_idx > idx then p4_ecp_edit_idx = p4_ecp_edit_idx - 1 end
                queueTask(P4_saveCodex)
                break
            end
            imgui.SameLine()
            imgui.TextUnformatted(encodeCp1251Safe(e.name .. " — /" .. tostring(e.cmd) .. " (" .. tostring(e.price) .. "$)"))
        end
        imgui.EndChild()

    else
        if imgui.Checkbox(u8"Включить локальный Damage Informer (выключен по умолчанию)", dmg_enabled) then
            requestSaveSettings()
        end
        if imgui.Checkbox(u8"Показывать последний урон в /hud (6 секунд)", dmg_show_hud) then
            requestSaveSettings()
        end
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1))
        imgui.TextUnformatted(u8"-> Фиксирует входящий и исходящий урон через SAMP RPC (ничего не блокирует)")
        imgui.PopStyleColor()
        imgui.Spacing()
        if imgui.Button(u8"Открыть лог попаданий (/dmglog)##p4_open_dmg", imgui.ImVec2(215, 26)) then
            dmg_log_show[0] = true
        end
        imgui.SameLine()
        if imgui.Button(u8"Очистить лог##p4_clr_dmg", imgui.ImVec2(120, 26)) then
            dmg_log = {}
            dmg_last_hud = ""
            dmg_last_ts = 0
        end
        imgui.Spacing()
        imgui.TextUnformatted(u8"Записей в журнале: " .. #dmg_log .. " / 25")
        imgui.BeginChild("##p4_dmg_prev", imgui.ImVec2(0, 180), true)
        if #dmg_log == 0 then
            imgui.TextUnformatted(u8"Попаданий пока не зафиксировано.")
        else
            for _, entry in ipairs(dmg_log) do
                local col = entry.give and imgui.ImVec4(0.35, 1.0, 0.45, 1) or imgui.ImVec4(1.0, 0.4, 0.4, 1)
                imgui.PushStyleColor(imgui.Col.Text, col)
                imgui.TextUnformatted(encodeCp1251Safe(entry.text))
                imgui.PopStyleColor()
            end
        end
        imgui.EndChild()
    end

    if p4_status_msg ~= "" then
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35, 1.0, 0.55, 1))
        imgui.TextUnformatted(encodeCp1251Safe(p4_status_msg))
        imgui.PopStyleColor()
    end
end
function P5_cleanImportValue(val, depth, state)
    depth = depth or 0
    state = state or { count = 0 }
    if depth > 6 or state.count >= 50000 then return nil end
    local tv = type(val)
    if tv == "string" then
        if #val > 16384 then return val:sub(1, 16384):gsub("%z", "") end
        return val:gsub("%z", "")
    elseif tv == "number" then
        if val ~= val or val == math.huge or val == -math.huge then return 0 end
        return val
    elseif tv == "boolean" then
        return val
    elseif tv == "table" then
        local out = {}
        for k, item in pairs(val) do
            if state.count >= 50000 then break end
            if (type(k) == "string" and not k:find("%z") and #k <= 128) or type(k) == "number" then
                state.count = state.count + 1
                local cv = P5_cleanImportValue(item, depth + 1, state)
                if cv ~= nil then
                    out[k] = cv
                end
            end
        end
        return out
    end
    return nil
end

function P5_applyCameraPose()
    local cp = math.cos(cam_pitch)
    local fx = -math.sin(cam_yaw) * cp
    local fy = math.cos(cam_yaw) * cp
    local fz = math.sin(cam_pitch)
    if type(setFixedCameraPosition) == "function" then
        pcall(setFixedCameraPosition, cam_x, cam_y, cam_z, 0.0, 0.0, 0.0)
    end
    if type(pointCameraAtPoint) == "function" then
        pcall(pointCameraAtPoint, cam_x + fx * 10.0, cam_y + fy * 10.0, cam_z + fz * 10.0, 2)
    end
end

function P5_enterFreeCam()
    if cam_active then return end
    if not isSampAvailable() then return end
    if not cam_feature_enabled[0] then
        sampAddChatMessage("[Helper] Свободная камера отключена. Включите её в F11 -> Транспорт и Визуал.", 0xFFAA00)
        return
    end
    if type(isCharDead) == "function" then
        local ok_d, dead = pcall(isCharDead, PLAYER_PED)
        if ok_d and dead then return end
    end
    local ok_c, px, py, pz = pcall(getCharCoordinates, PLAYER_PED)
    if not ok_c or type(px) ~= "number" or type(py) ~= "number" or type(pz) ~= "number" then
        return
    end
    local ok_h, heading = pcall(getCharHeading, PLAYER_PED)
    local h_deg = (ok_h and type(heading) == "number") and heading or 0
    cam_yaw = math.rad(h_deg)
    cam_pitch = 0.0
    cam_x = px
    cam_y = py
    cam_z = pz + 1.5
    P5.cam_start_interior = (type(getActiveInterior) == "function") and (select(2, pcall(getActiveInterior)) or 0) or 0
    P5.cam_start_car = (type(isCharInAnyCar) == "function" and isCharInAnyCar(PLAYER_PED)) and storeCarCharIsInNoSave(PLAYER_PED) or nil
    if type(lockPlayerControl) == "function" then
        local ok_l = pcall(lockPlayerControl, true)
        cam_controls_locked = ok_l and true or false
    else
        cam_controls_locked = false
    end
    cam_active = true
    P5.last_cam_clock = os.clock()
    P5_applyCameraPose()
    if isSampAvailable() then
        sampAddChatMessage("[Helper] Дрон (/cam) {00FF00}ВКЛ{FFFFFF}. WASD + Space/Shift, Q/E и стрелки — обзор. Выход: Backspace / /cam", 0xFFFFFF)
    end
end

function P5_exitFreeCam()
    local was_active = cam_active
    cam_active = false
    P5.cam_start_car = nil
    if cam_controls_locked then
        if type(lockPlayerControl) == "function" then
            pcall(lockPlayerControl, false)
        end
        cam_controls_locked = false
    elseif type(lockPlayerControl) == "function" then
        pcall(lockPlayerControl, false)
    end
    if type(restoreCameraJumpcut) == "function" then
        pcall(restoreCameraJumpcut)
    end
    if type(setCameraBehindPlayer) == "function" then
        pcall(setCameraBehindPlayer)
    end
    if was_active and isSampAvailable() then
        sampAddChatMessage("[Helper] Дрон (/cam) {FF4444}ВЫКЛ{FFFFFF} — камера возвращена.", 0xFFFFFF)
    end
end

function P1_getImguiInputState()
    if type(imgui) ~= "table" or type(imgui.IsInitialized) ~= "function" or not imgui.IsInitialized() then
        return false, false
    end
    if type(imgui.GetRenderer) == "function" then
        local ok_r, r = pcall(imgui.GetRenderer)
        if not ok_r or not r or r.lost then
            return false, false
        end
    end
    if type(imgui.SwitchContext) == "function" then
        local ok_sw = pcall(imgui.SwitchContext)
        if not ok_sw then
            return false, false
        end
    end
    local ok_io, io = pcall(imgui.GetIO)
    if not ok_io or not io then
        return false, false
    end
    return (io.WantTextInput and true or false), (io.WantCaptureMouse and true or false)
end

function P5_toggleFreeCam()
    if cam_active then
        P5_exitFreeCam()
    else
        P5_enterFreeCam()
    end
end

function P5_tickFreeCam()
    if not cam_active then return end
    if not cam_feature_enabled[0] or not isSampAvailable() then
        P5_exitFreeCam()
        return
    end
    if type(isCharDead) == "function" then
        local ok_d, dead = pcall(isCharDead, PLAYER_PED)
        if ok_d and dead then
            P5_exitFreeCam()
            return
        end
    end
    if type(isCharInAnyCar) == "function" then
        local cur_car = isCharInAnyCar(PLAYER_PED) and storeCarCharIsInNoSave(PLAYER_PED) or nil
        if cur_car ~= P5.cam_start_car then
            P5_exitFreeCam()
            return
        end
    end
    if type(getActiveInterior) == "function" then
        local ok_i, cur_int = pcall(getActiveInterior)
        if ok_i and type(cur_int) == "number" and cur_int ~= (P5.cam_start_interior or 0) then
            P5_exitFreeCam()
            return
        end
    end
    local ui_busy = false
    if type(isGameWindowForeground) == "function" then
        local ok_fg, fg = pcall(isGameWindowForeground)
        if ok_fg and fg == false then ui_busy = true end
    end
    if not ui_busy and type(isPauseMenuActive) == "function" then
        local ok_pm, pm = pcall(isPauseMenuActive)
        if ok_pm and pm then ui_busy = true end
    end
    if not ui_busy and type(sampIsChatInputActive) == "function" and sampIsChatInputActive() then ui_busy = true end
    if not ui_busy and type(sampIsDialogActive) == "function" and sampIsDialogActive() then ui_busy = true end
    if not ui_busy then
        local w_txt = P1_getImguiInputState()
        if w_txt then ui_busy = true end
    end
    if not ui_busy then
        if wasKeyPressed(0x08) and not show_main_window[0] then
            P5_exitFreeCam()
            return
        end
    end

    local now = os.clock()
    local dt = now - (P5.last_cam_clock or now)
    P5.last_cam_clock = now
    if dt <= 0 or dt > 0.1 then dt = 0.016 end
    local spd = math.max(0.1, math.min(3.0, cam_speed[0])) * (dt * 30.0)
    local rot_spd = 1.8 * dt

    if not ui_busy then
        if isKeyDown(0x51) or isKeyDown(0x25) then
            cam_yaw = cam_yaw + rot_spd
        end
        if isKeyDown(0x45) or isKeyDown(0x27) then
            cam_yaw = cam_yaw - rot_spd
        end
        if isKeyDown(0x26) then
            cam_pitch = math.min(1.45, cam_pitch + rot_spd * 0.85)
        end
        if isKeyDown(0x28) then
            cam_pitch = math.max(-1.45, cam_pitch - rot_spd * 0.85)
        end

        local cp = math.cos(cam_pitch)
        local fx = -math.sin(cam_yaw) * cp
        local fy = math.cos(cam_yaw) * cp
        local fz = math.sin(cam_pitch)
        local rx = math.cos(cam_yaw)
        local ry = math.sin(cam_yaw)

        if isKeyDown(0x57) then
            cam_x = cam_x + fx * spd
            cam_y = cam_y + fy * spd
            cam_z = cam_z + fz * spd
        end
        if isKeyDown(0x53) then
            cam_x = cam_x - fx * spd
            cam_y = cam_y - fy * spd
            cam_z = cam_z - fz * spd
        end
        if isKeyDown(0x44) then
            cam_x = cam_x + rx * spd
            cam_y = cam_y + ry * spd
        end
        if isKeyDown(0x41) then
            cam_x = cam_x - rx * spd
            cam_y = cam_y - ry * spd
        end
        if isKeyDown(0x20) then
            cam_z = cam_z + spd
        end
        if isKeyDown(0x10) then
            cam_z = cam_z - spd
        end
    end
    P5_applyCameraPose()
end

function P5_isShopDialogTitle(title)
    local clean_title = cp1251_lower((tostring(title or "")):gsub("{%x+}", ""))
    return clean_title:find("магазин", 1, true) ~= nil
        or clean_title:find("24/7", 1, true) ~= nil
        or clean_title:find("аптек", 1, true) ~= nil
        or clean_title:find("товар", 1, true) ~= nil
end

function P5_isBuyButtonText(btn1)
    local b = cp1251_lower((tostring(btn1 or "")):gsub("{%x+}", "")):gsub("^%s+", ""):gsub("%s+$", "")
    if b == "" then return false end
    return b:find("куп", 1, true) ~= nil
        or b:find("выбр", 1, true) ~= nil
        or b:find("приоб", 1, true) ~= nil
        or b:find("взять", 1, true) ~= nil
        or b:find("далее", 1, true) ~= nil
        or b:find("оплат", 1, true) ~= nil
        or b:find("buy", 1, true) ~= nil
        or b:find("select", 1, true) ~= nil
        or b == "ок" or b == "ok"
end

function P5_matchBuyFastLine(title, text, item_idx, style)
    if not P5_isShopDialogTitle(title) then return nil end
    local idx_1 = math.max(0, math.min(4, math.floor(tonumber(item_idx) or 0))) + 1
    local entry = P5.buyfast_items[idx_1]
    if not entry or type(entry.keywords) ~= "table" then return nil end
    local line_idx = 0
    local skipped_header = (style ~= 5)
    for raw_line in string.gmatch(tostring(text or ""), "[^\r\n]+") do
        if not skipped_header then
            skipped_header = true
        else
            local clean_line = cp1251_lower(raw_line:gsub("{%x+}", ""))
            for _, kw in ipairs(entry.keywords) do
                if clean_line:find(kw, 1, true) then
                    return line_idx
                end
            end
            line_idx = line_idx + 1
        end
    end
    return nil
end

function P5_cmdBuyFast(arg)
    if not buyfast_enabled[0] then
        if isSampAvailable() then
            sampAddChatMessage("[Helper] /buyfast отключена. Включите её в F11 -> Утилиты и Чат -> вкладка 3.", 0xFFAA00)
        end
        return
    end
    local a = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if a ~= "" then
        local num = a:match("^%d+$") and tonumber(a) or nil
        if num and num >= 1 and num <= #P5.buyfast_items then
            buyfast_item_idx[0] = math.floor(num) - 1
            requestSaveSettings()
        else
            local alow = cp1251_lower(a)
            local found_arg = false
            for idx, item in ipairs(P5.buyfast_items) do
                local matched = false
                for _, kw in ipairs(item.keywords) do
                    if alow:find(kw, 1, true) then
                        matched = true
                        break
                    end
                end
                if not matched and type(item.aliases) == "table" then
                    for _, akw in ipairs(item.aliases) do
                        if alow:find(akw, 1, true) then
                            matched = true
                            break
                        end
                    end
                end
                if matched then
                    buyfast_item_idx[0] = idx - 1
                    requestSaveSettings()
                    found_arg = true
                    break
                end
            end
            if not found_arg then
                if isSampAvailable() then
                    sampAddChatMessage("[Helper] /buyfast: неизвестный товар '" .. a .. "'. Используйте 1-5 или: аптеч, маск, рем, канистр, сим.", 0xFF4444)
                end
                return
            end
        end
    end

    local target_entry = P5.buyfast_items[buyfast_item_idx[0] + 1] or P5.buyfast_items[1]
    local now = os.clock()
    if (now - buyfast_last_fire) < 1.5 then
        if isSampAvailable() then
            sampAddChatMessage("[Helper] /buyfast: подождите 1.5 сек перед следующей покупкой.", 0xFFAA00)
        end
        return
    end

    local dlg_open = false
    if type(sampIsDialogActive) == "function" then
        local ok_a, res_a = pcall(sampIsDialogActive)
        if ok_a and res_a then dlg_open = true end
    end

    if dlg_open and type(sampGetCurrentDialogId) == "function"
        and type(sampGetDialogCaption) == "function"
        and type(sampGetDialogText) == "function"
        and type(sampSendDialogResponse) == "function" then
        local ok_id, did = pcall(sampGetCurrentDialogId)
        local ok_c, dtitle = pcall(sampGetDialogCaption)
        local ok_t, dtext = pcall(sampGetDialogText)
        local dstyle = nil
        local style_ok = false
        if type(sampGetCurrentDialogType) == "function" then
            local ok_s, st = pcall(sampGetCurrentDialogType)
            if ok_s and type(st) == "number" then
                dstyle = st
                style_ok = (st == 2 or st == 4 or st == 5)
            end
        end
        local btn_ok = true
        if P5.last_dialog_id == did and type(P5.last_dialog_button1) == "string" then
            btn_ok = P5_isBuyButtonText(P5.last_dialog_button1)
        end
        if ok_id and ok_c and ok_t and style_ok and btn_ok then
            local bf_idx = P5_matchBuyFastLine(dtitle, dtext, buyfast_item_idx[0], dstyle)
            if bf_idx ~= nil then
                buyfast_armed_until = 0
                buyfast_last_fire = now
                pcall(sampSendDialogResponse, did, 1, bf_idx, "")
                if isSampAvailable() then
                    sampAddChatMessage("[Helper] Быстрая покупка: {00FF90}" .. target_entry.label, 0xFFFFFF)
                end
                return
            end
        end
    end

    buyfast_armed_until = now + 8.0
    if isSampAvailable() then
        sampAddChatMessage("[Helper] /buyfast готов (8 сек): откройте диалог 24/7 или аптеки. Цель: {00FF90}" .. target_entry.label, 0x00CCFF)
    end
end

function P5_formatDuration(sec)
    local s = math.max(0, math.floor(tonumber(sec) or 0))
    if s >= 3600 then
        return string.format("%dч %02dм", math.floor(s / 3600), math.floor((s % 3600) / 60))
    end
    return string.format("%02dм %02dс", math.floor(s / 60), s % 60)
end

function P5_pollSessionActivity()
    if not session_track_enabled[0] then return end
    if type(isGameWindowForeground) == "function" then
        local ok_fg, fg = pcall(isGameWindowForeground)
        if ok_fg and fg == false then return end
    end
    if type(isPauseMenuActive) == "function" then
        local ok_pm, pm = pcall(isPauseMenuActive)
        if ok_pm and pm then return end
    end
    local chat_or_dlg = false
    if type(sampIsChatInputActive) == "function" then
        local ok_ci, ci = pcall(sampIsChatInputActive)
        if ok_ci and ci then chat_or_dlg = true end
    end
    if not chat_or_dlg and type(sampIsDialogActive) == "function" then
        local ok_di, di = pcall(sampIsDialogActive)
        if ok_di and di then chat_or_dlg = true end
    end
    if chat_or_dlg then
        P5.had_input_in_sec = true
        return
    end
    if type(isKeyDown) == "function" then
        if isKeyDown(0x57) or isKeyDown(0x41) or isKeyDown(0x53) or isKeyDown(0x44)
            or isKeyDown(0x20) or isKeyDown(0x01) or isKeyDown(0x02) then
            P5.had_input_in_sec = true
        end
    end
end

function P5_tickSession1s()
    if not session_track_enabled[0] then
        session_hud_str = ""
        return
    end
    local paused = false
    if type(isGameWindowForeground) == "function" then
        local ok_fg, fg = pcall(isGameWindowForeground)
        if ok_fg and fg == false then paused = true end
    end
    if not paused and type(isPauseMenuActive) == "function" then
        local ok_pm, pm = pcall(isPauseMenuActive)
        if ok_pm and pm then paused = true end
    end

    local alive = true
    if type(isCharDead) == "function" then
        local ok_d, dead = pcall(isCharDead, PLAYER_PED)
        if ok_d and dead then alive = false end
    end

    local moved = false
    local ok_pos, px, py = pcall(getCharCoordinates, PLAYER_PED)
    if ok_pos and type(px) == "number" and type(py) == "number" then
        if session_last_px ~= nil and session_last_py ~= nil then
            local dx = px - session_last_px
            local dy = py - session_last_py
            if (dx * dx + dy * dy) > 0.04 then
                moved = true
            end
        end
        session_last_px = px
        session_last_py = py
    end

    local active_now = (not paused) and alive and (moved or P5.had_input_in_sec or cam_active)
    P5.had_input_in_sec = false

    if active_now then
        session_idle_sec = 0
        session_active_sec = session_active_sec + 1
    else
        session_idle_sec = session_idle_sec + 1
        if session_idle_sec >= 45 then
            session_afk_sec = session_afk_sec + 1
        else
            session_active_sec = session_active_sec + 1
        end
    end

    session_hud_str = string.format(
        "Онлайн: %s | AFK: %s%s",
        P5_formatDuration(session_active_sec),
        P5_formatDuration(session_afk_sec),
        (session_idle_sec >= 45) and " [AFK]" or ""
    )
end
-- ============================================================================
-- ФАЗА 6 (v2.6): Логика Конструктора локаций /location (TitanLocation-аналог)
-- ============================================================================

function P6_sanitizeIdArray(tbl, max_items)
    local out, seen = {}, {}
    local limit = max_items or 522
    if type(tbl) ~= "table" then return out end
    -- Поддержка как массива [11544, ...], так и словаря {"11544": true}
    for _, v in ipairs(tbl) do
        local id = tonumber(v)
        if id and id > 0 then
            id = math.floor(id)
            if not seen[id] then
                seen[id] = true
                out[#out + 1] = id
                if #out >= limit then return out end
            end
        end
    end
    for k, v in pairs(tbl) do
        if type(k) ~= "number" and v then
            local id = tonumber(k)
            if id and id > 0 then
                id = math.floor(id)
                if not seen[id] then
                    seen[id] = true
                    out[#out + 1] = id
                    if #out >= limit then return out end
                end
            end
        end
    end
    return out
end

function P6_rebuildFavMap()
    local normalized = P6_sanitizeIdArray(P6_loc_favorites, 522)
    if type(P6_loc_favorites) ~= "table" then
        P6_loc_favorites = normalized
    else
        for i = #P6_loc_favorites, 1, -1 do P6_loc_favorites[i] = nil end
        for k in pairs(P6_loc_favorites) do
            if type(k) ~= "number" then P6_loc_favorites[k] = nil end
        end
        for i, id in ipairs(normalized) do P6_loc_favorites[i] = id end
    end
    local map = {}
    for _, id in ipairs(P6_loc_favorites) do
        map[id] = true
    end
    P6.fav_map = map
    P6.fav_src_ref = P6_loc_favorites
end

function P6_isFavorite(id)
    if P6.fav_src_ref ~= P6_loc_favorites then
        P6_rebuildFavMap()
    end
    return P6.fav_map[id] == true
end

function P6_toggleFavorite(id)
    local num_id = tonumber(id)
    if not num_id or num_id <= 0 then return end
    num_id = math.floor(num_id)
    if P6.fav_src_ref ~= P6_loc_favorites then
        P6_rebuildFavMap()
    end
    if P6.fav_map[num_id] then
        for i = #P6_loc_favorites, 1, -1 do
            if P6_loc_favorites[i] == num_id then
                table.remove(P6_loc_favorites, i)
            end
        end
        P6.fav_map[num_id] = nil
        loc_status_msg = "Удалено из избранного: #" .. tostring(num_id)
    else
        table.insert(P6_loc_favorites, 1, num_id)
        P6.fav_map[num_id] = true
        loc_status_msg = "Добавлено в избранное: #" .. tostring(num_id)
    end
    P6.favorites_initialized = true
    requestSaveSettings()
    if not P6.loc_save_queued then
        P6.loc_save_queued = true
        queueTask(function()
            P6.loc_save_queued = false
            P6_saveLocations()
        end)
    end
end

function P6_getDecorName(id)
    local item = P6_decor_by_id[tonumber(id) or 0]
    if item then return item.name end
    return "Объект #" .. tostring(id or 0)
end

function P6_refreshProfileKey()
    if type(isSampAvailable) == "function" and isSampAvailable() then
        local ok_s, sname = pcall(sampGetCurrentServerName)
        if ok_s and type(sname) == "string" and sname ~= "" then
            sname = sname:gsub("{%x%x%x%x%x%x}", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if sname ~= "" then
                P6.cached_srv_name = sname
            end
        end
        if P6.cached_srv_name == "" and type(sampGetCurrentServerAddress) == "function" then
            local ok_a, ip, port = pcall(sampGetCurrentServerAddress)
            if ok_a and type(ip) == "string" and ip ~= "" then
                P6.cached_srv_name = ip .. (port and (":" .. tostring(port)) or "")
            end
        end
        if (not my_cached_nick or my_cached_nick == "") and type(sampGetPlayerIdByCharHandle) == "function" then
            local ok_id, res_id, myid = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
            if ok_id and res_id and type(myid) == "number" and myid >= 0 and type(sampGetPlayerNickname) == "function" then
                local ok_n, mn = pcall(sampGetPlayerNickname, myid)
                if ok_n and type(mn) == "string" and mn ~= "" then
                    my_cached_nick = mn
                end
            end
        end
    end
end

function P6_getProfileKey()
    local srv = P6.cached_srv_name or ""
    if srv == "" then
        local idx = (current_server_idx and current_server_idx[0] or 0) + 1
        local fallback_utf8 = (server_names and server_names[idx]) or "Advance RP"
        local dec = (type(decodeUtf8Safe) == "function") and decodeUtf8Safe(fallback_utf8) or "Advance RP"
        srv = (dec ~= "" and dec) or "Advance RP"
    end
    local nick = (type(my_cached_nick) == "string" and my_cached_nick ~= "") and my_cached_nick or "Offline"
    return srv .. " | " .. nick
end

function P6_ensureConfigDir()
    local cfg = getWorkingDirectory() .. "/config"
    if not doesDirectoryExist(cfg) then
        createDirectory(cfg)
    end
    return cfg
end

function P6_sanitizeRegistryObj(obj)
    if type(obj) ~= "table" then return nil end
    local model = tonumber(obj.model)
    local x, y, z = tonumber(obj.x), tonumber(obj.y), tonumber(obj.z)
    if not model or model < 0 or not x or not y or not z then return nil end
    local rx = tonumber(obj.rx) or 0.0
    local ry = tonumber(obj.ry) or 0.0
    local rz = tonumber(obj.rz) or 0.0
    local ts = tonumber(obj.ts) or os.time()
    local entry = {
        model = math.floor(model),
        x = math.floor(x * 10000 + 0.5) / 10000,
        y = math.floor(y * 10000 + 0.5) / 10000,
        z = math.floor(z * 10000 + 0.5) / 10000,
        rx = math.floor(rx * 10000 + 0.5) / 10000,
        ry = math.floor(ry * 10000 + 0.5) / 10000,
        rz = math.floor(rz * 10000 + 0.5) / 10000,
        ts = math.floor(ts)
    }
    if tonumber(obj.samp_obj_id) then
        entry.samp_obj_id = math.floor(tonumber(obj.samp_obj_id))
    end
    return entry
end

function P6_saveLocations()
    P6_ensureConfigDir()
    if type(P6_loc_registry) ~= "table" then P6_loc_registry = {} end
    local payload = {
        version = 1,
        profiles = P6_loc_registry,
        favorites = P6_loc_favorites or {}
    }
    local ok, err = writeJsonAtomic(P6_loc_path, payload)
    if not ok then
        print("[helper_core] P6_saveLocations error: " .. tostring(err))
    end
    return ok, err
end

function P6_loadLocations()
    local parsed = readJsonFile(P6_loc_path)
    if type(parsed) ~= "table" then return false end
    local src_profiles = nil
    if type(parsed.profiles) == "table" then
        src_profiles = parsed.profiles
    elseif parsed.version == nil then
        src_profiles = parsed
    end
    if type(src_profiles) == "table" then
        local cleaned_reg = {}
        for k, arr in pairs(src_profiles) do
            if type(k) == "string" and #k > 0 and #k <= 128 and type(arr) == "table" then
                local list = {}
                for _, item in ipairs(arr) do
                    local s_item = P6_sanitizeRegistryObj(item)
                    if s_item then
                        list[#list + 1] = s_item
                        if #list >= 2000 then break end
                    end
                end
                cleaned_reg[k] = list
            end
        end
        P6_loc_registry = cleaned_reg
    end
    if not P6.favorites_initialized then
        if (#P6_loc_favorites == 0) and type(parsed.favorites) == "table" then
            P6_loc_favorites = P6_sanitizeIdArray(parsed.favorites, 522)
            P6_rebuildFavMap()
        end
        P6.favorites_initialized = true
    end
    return true
end

function P6_getActiveProfileList(create_if_missing, key_override)
    local pk = (type(key_override) == "string" and key_override ~= "") and key_override or P6_getProfileKey()
    if type(P6_loc_registry) ~= "table" then P6_loc_registry = {} end
    if create_if_missing and type(P6_loc_registry[pk]) ~= "table" then
        P6_loc_registry[pk] = {}
    end
    return P6_loc_registry[pk], pk
end

function P6_recordSavedObject(model, pos, rot, samp_obj_id)
    local m = tonumber(model)
    if type(pos) ~= "table" then return false end
    local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
    if not x or not y or not z then return false end
    if not m or m <= 0 then m = (tonumber(tedit_model) or 0) end
    if m <= 0 then m = (tonumber(P6.dup_model) or 0) end
    local r = type(rot) == "table" and rot or {x = 0, y = 0, z = 0}
    local entry = P6_sanitizeRegistryObj({
        model = (m > 0) and m or 1,
        x = x, y = y, z = z,
        rx = tonumber(r.x) or 0,
        ry = tonumber(r.y) or 0,
        rz = tonumber(r.z) or 0,
        ts = os.time(),
        samp_obj_id = tonumber(samp_obj_id)
    })
    if not entry then return false end
    if m <= 0 then entry.model = 0 end

    local list, pk = P6_getActiveProfileList(true)
    local updated_idx = nil

    -- 1. Совпадение по активному SA-MP objectId + модели в этой сессии
    if entry.samp_obj_id and entry.samp_obj_id >= 0 then
        for i, cur in ipairs(list) do
            if cur.samp_obj_id == entry.samp_obj_id and (entry.model == 0 or cur.model == entry.model) then
                updated_idx = i
                break
            end
        end
    end
    -- 2. Совпадение по исходным координатам до начала перетаскивания (после реконнекта ID объекта меняется)
    if not updated_idx and type(P6.edit_start_pos) == "table" then
        local sp = P6.edit_start_pos
        local best_d = 0.35
        for i, cur in ipairs(list) do
            if entry.model == 0 or cur.model == entry.model then
                local dx, dy, dz = (cur.x - sp.x), (cur.y - sp.y), (cur.z - sp.z)
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d <= best_d then
                    best_d = d
                    updated_idx = i
                end
            end
        end
    end

    if updated_idx then
        if entry.model == 0 and list[updated_idx].model > 0 then
            entry.model = list[updated_idx].model
        end
        list[updated_idx] = entry
        loc_status_msg = string.format("Обновлён объект #%d (%s)", updated_idx, tostring(entry.model))
    else
        list[#list + 1] = entry
        loc_status_msg = string.format("Добавлен #%d в реестр (%s)", #list, tostring(entry.model))
    end
    P6.reg_profile_view = pk
    P6_saveLocations()
    return true
end

function P6_exportBlueprint(profile_key)
    P6_ensureConfigDir()
    local list, pk = P6_getActiveProfileList(false, profile_key)
    if type(list) ~= "table" or #list == 0 then
        loc_status_msg = "Нет объектов для экспорта в выбранном профиле"
        if isSampAvailable() then
            sampAddChatMessage("[Helper /location] " .. loc_status_msg, 0xFFAA00)
        end
        return false
    end
    local objects = {}
    for _, obj in ipairs(list) do
        local s_obj = P6_sanitizeRegistryObj(obj)
        if s_obj then
            s_obj.samp_obj_id = nil
            objects[#objects + 1] = s_obj
        end
    end
    local bp = {
        format = "arp_helper_location_blueprint",
        version = 1,
        source_profile = pk,
        exported_at = os.date("%Y-%m-%d %H:%M:%S"),
        count = #objects,
        objects = objects
    }
    local ok, err = writeJsonAtomic(loc_bp_json_path, bp)
    if ok then
        loc_status_msg = "Экспортировано объектов: " .. tostring(#objects) .. " -> helper_loc_blueprint.json"
        if isSampAvailable() then
            sampAddChatMessage("[Helper /location] Чертёж сохранён (" .. tostring(#objects) .. " об.) в config/helper_loc_blueprint.json", 0x00FF90)
        end
    else
        loc_status_msg = "Ошибка экспорта: " .. tostring(err)
        if isSampAvailable() then
            sampAddChatMessage("[Helper /location] Ошибка экспорта: " .. tostring(err), 0xFF4444)
        end
    end
    return ok
end

function P6_importBlueprint(replace_mode, profile_key)
    local parsed = readJsonFile(loc_bp_json_path)
    if type(parsed) ~= "table" then
        loc_status_msg = "Файл helper_loc_blueprint.json не найден или повреждён"
        if isSampAvailable() then
            sampAddChatMessage("[Helper /location] Не найден config/helper_loc_blueprint.json", 0xFF4444)
        end
        return false
    end
    local raw_objs = (type(parsed.objects) == "table") and parsed.objects or parsed
    if type(raw_objs) ~= "table" then
        loc_status_msg = "Некорректный формат чертежа"
        return false
    end
    local imported = {}
    for _, item in ipairs(raw_objs) do
        local s_obj = P6_sanitizeRegistryObj(item)
        if s_obj then
            s_obj.samp_obj_id = nil
            imported[#imported + 1] = s_obj
            if #imported >= 2000 then break end
        end
    end
    if #imported == 0 then
        loc_status_msg = "В чертеже нет валидных объектов"
        return false
    end
    local list, pk = P6_getActiveProfileList(true, profile_key)
    if replace_mode then
        P6_loc_registry[pk] = imported
    else
        for _, obj in ipairs(imported) do
            list[#list + 1] = obj
            if #list >= 2000 then break end
        end
    end
    P6.reg_profile_view = pk
    P6_saveLocations()
    loc_status_msg = (replace_mode and "Заменено" or "Добавлено") .. " из чертежа: " .. tostring(#imported) .. " об."
    if isSampAvailable() then
        sampAddChatMessage("[Helper /location] " .. loc_status_msg, 0x00FF90)
    end
    return true
end

function P6_normalizeAngle(deg)
    local a = tonumber(deg) or 0.0
    a = a % 360.0
    if a < 0 then a = a + 360.0 end
    a = math.floor(a * 10000 + 0.5) / 10000
    if a >= 360.0 then a = 0.0 end
    return a
end

function P6_round4(v)
    return math.floor((tonumber(v) or 0.0) * 10000 + 0.5) / 10000
end

function P6_quatToEuler(qx, qy, qz, qw)
    qx = tonumber(qx) or 0.0
    qy = tonumber(qy) or 0.0
    qz = tonumber(qz) or 0.0
    qw = tonumber(qw) or 1.0
    local norm = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if norm > 1e-6 then
        qx, qy, qz, qw = qx / norm, qy / norm, qz / norm, qw / norm
    else
        return 0.0, 0.0, 0.0
    end
    local sx = 2.0 * (qw * qx + qy * qz)
    if sx > 1.0 then sx = 1.0 elseif sx < -1.0 then sx = -1.0 end
    local rx = math.asin(sx)
    local ry, rz
    if math.abs(math.cos(rx)) > 1e-4 then
        ry = math.atan2(-2.0 * (qx * qz - qw * qy), 1.0 - 2.0 * (qx * qx + qy * qy))
        rz = math.atan2(-2.0 * (qx * qy - qw * qz), 1.0 - 2.0 * (qx * qx + qz * qz))
    else
        ry = 0.0
        rz = math.atan2(2.0 * (qx * qy + qw * qz), 1.0 - 2.0 * (qy * qy + qz * qz))
    end
    return P6_normalizeAngle(math.deg(rx)), P6_normalizeAngle(math.deg(ry)), P6_normalizeAngle(math.deg(rz))
end

function P6_syncManualBuffers()
    P6.manual_x[0] = tedit_pos.x or 0.0
    P6.manual_y[0] = tedit_pos.y or 0.0
    P6.manual_z[0] = tedit_pos.z or 0.0
    P6.manual_rx[0] = tedit_rot.x or 0.0
    P6.manual_ry[0] = tedit_rot.y or 0.0
    P6.manual_rz[0] = tedit_rot.z or 0.0
end

function P6_snapshotState()
    return {
        pos = {x = tedit_pos.x or 0.0, y = tedit_pos.y or 0.0, z = tedit_pos.z or 0.0},
        rot = {x = tedit_rot.x or 0.0, y = tedit_rot.y or 0.0, z = tedit_rot.z or 0.0}
    }
end

function P6_pushUndo()
    tedit_undo[#tedit_undo + 1] = P6_snapshotState()
    if #tedit_undo > 50 then
        table.remove(tedit_undo, 1)
    end
    tedit_redo = {}
end

function P6_applySnapshot(snap)
    if type(snap) ~= "table" then return end
    if type(snap.pos) == "table" then
        tedit_pos.x = tonumber(snap.pos.x) or 0.0
        tedit_pos.y = tonumber(snap.pos.y) or 0.0
        tedit_pos.z = tonumber(snap.pos.z) or 0.0
    end
    if type(snap.rot) == "table" then
        tedit_rot.x = tonumber(snap.rot.x) or 0.0
        tedit_rot.y = tonumber(snap.rot.y) or 0.0
        tedit_rot.z = tonumber(snap.rot.z) or 0.0
    end
    P6_syncManualBuffers()
end

-- Строго вызывается через queueTask / scheduleTask / main, НИКОГДА напрямую из ImGui!
function P6_applyLocalPreview()
    if type(isSampAvailable) ~= "function" or not isSampAvailable() then return false end
    local h = tedit_handle
    if tedit_obj_id and tedit_obj_id >= 0 and type(sampGetObjectHandleBySampId) == "function" then
        local ok_h, sh = pcall(sampGetObjectHandleBySampId, tedit_obj_id)
        if ok_h and type(sh) == "number" and sh > 0 then
            h = sh
        end
    end
    if not h or type(h) ~= "number" or h <= 0 or type(doesObjectExist) ~= "function" then
        return false
    end
    local ok_ex, exists = pcall(doesObjectExist, h)
    if not ok_ex or not exists then return false end
    tedit_handle = h
    if type(setObjectCoordinates) == "function" then
        pcall(setObjectCoordinates, h, tedit_pos.x, tedit_pos.y, tedit_pos.z)
    end
    if type(setObjectRotation) == "function" then
        pcall(setObjectRotation, h, tedit_rot.x, tedit_rot.y, tedit_rot.z)
    end
    return true
end

local function P6_hasValidEditState()
    if not tedit_active then
        loc_status_msg = "Редактирование объекта не активно (/location)"
        return false
    end
    if type(tedit_pos) ~= "table" or type(tedit_pos.x) ~= "number" or type(tedit_pos.y) ~= "number" or type(tedit_pos.z) ~= "number"
       or type(tedit_rot) ~= "table" or type(tedit_rot.x) ~= "number" or type(tedit_rot.y) ~= "number" or type(tedit_rot.z) ~= "number" then
        loc_status_msg = "Координаты объекта не инициализированы"
        return false
    end
    if not P6.edit_pos_ready and type(P6.edit_start_pos) ~= "table" then
        loc_status_msg = "Сдвиньте объект в SA-MP или дождитесь чтения координат"
        return false
    end
    return true
end

function P6_nudgeAxis(kind, axis, delta)
    if not P6_hasValidEditState() then return false end
    if axis ~= "x" and axis ~= "y" and axis ~= "z" then return false end
    local d = tonumber(delta)
    if not d then return false end
    if kind == "pos" then
        P6_pushUndo()
        tedit_pos[axis] = P6_round4((tedit_pos[axis] or 0.0) + d)
    elseif kind == "rot" then
        P6_pushUndo()
        tedit_rot[axis] = P6_normalizeAngle((tedit_rot[axis] or 0.0) + d)
    else
        return false
    end
    P6.dirty_edit = true
    P6_syncManualBuffers()
    queueTask(P6_applyLocalPreview)
    return true
end

function P6_levelHorizon()
    if not P6_hasValidEditState() then return false end
    P6_pushUndo()
    tedit_rot.x = 0.0
    tedit_rot.y = 0.0
    P6.dirty_edit = true
    P6_syncManualBuffers()
    loc_status_msg = "Горизонт выровнен (RX=0, RY=0)"
    queueTask(P6_applyLocalPreview)
    return true
end

function P6_applyManualInput()
    if not P6_hasValidEditState() then
        P6_syncManualBuffers()
        return false
    end
    P6_pushUndo()
    tedit_pos.x = P6_round4(P6.manual_x[0])
    tedit_pos.y = P6_round4(P6.manual_y[0])
    tedit_pos.z = P6_round4(P6.manual_z[0])
    tedit_rot.x = P6_normalizeAngle(P6.manual_rx[0])
    tedit_rot.y = P6_normalizeAngle(P6.manual_ry[0])
    tedit_rot.z = P6_normalizeAngle(P6.manual_rz[0])
    P6.dirty_edit = true
    P6_syncManualBuffers()
    queueTask(P6_applyLocalPreview)
    return true
end

function P6_undoEdit()
    if not P6_hasValidEditState() then return false end
    if #tedit_undo == 0 then return false end
    tedit_redo[#tedit_redo + 1] = P6_snapshotState()
    local prev = table.remove(tedit_undo)
    P6_applySnapshot(prev)
    P6.dirty_edit = true
    loc_status_msg = "Откат правки (осталось в стеке: " .. tostring(#tedit_undo) .. ")"
    queueTask(P6_applyLocalPreview)
    return true
end

function P6_redoEdit()
    if not P6_hasValidEditState() then return false end
    if #tedit_redo == 0 then return false end
    tedit_undo[#tedit_undo + 1] = P6_snapshotState()
    local nxt = table.remove(tedit_redo)
    P6_applySnapshot(nxt)
    P6.dirty_edit = true
    loc_status_msg = "Повтор правки (осталось повторов: " .. tostring(#tedit_redo) .. ")"
    queueTask(P6_applyLocalPreview)
    return true
end

function P6_copyParams()
    local src_model = tedit_model or 0
    local src_pos, src_rot = nil, nil
    if tedit_active or src_model > 0 or (math.abs(tedit_pos.x or 0) + math.abs(tedit_pos.y or 0) + math.abs(tedit_pos.z or 0) > 0.0001) then
        src_pos = {x = tedit_pos.x or 0, y = tedit_pos.y or 0, z = tedit_pos.z or 0}
        src_rot = {x = tedit_rot.x or 0, y = tedit_rot.y or 0, z = tedit_rot.z or 0}
    else
        local list = P6_getActiveProfileList(false)
        if type(list) == "table" and #list > 0 then
            local last = list[#list]
            src_model = last.model or 0
            src_pos = {x = last.x, y = last.y, z = last.z}
            src_rot = {x = last.rx, y = last.ry, z = last.rz}
        end
    end
    if not src_pos then
        loc_status_msg = "Нечего копировать: выберите или отредактируйте объект"
        return false
    end
    tedit_clipboard = {
        model = src_model,
        pos = src_pos,
        rot = src_rot
    }
    loc_status_msg = string.format("Скопировано: X=%.2f Y=%.2f Z=%.2f | RZ=%.1f", src_pos.x, src_pos.y, src_pos.z, src_rot.z)
    return true
end

function P6_pasteParams(mode)
    if type(tedit_clipboard) ~= "table" or type(tedit_clipboard.pos) ~= "table" then
        loc_status_msg = "Буфер /tcopy пуст"
        return false
    end
    local m = mode or "all"
    local cp = tedit_clipboard.pos
    local cr = tedit_clipboard.rot or {x = 0, y = 0, z = 0}
    P6_pushUndo()
    if m == "all" then
        tedit_pos.x = P6_round4(cp.x)
        tedit_pos.y = P6_round4(cp.y)
        tedit_pos.z = P6_round4(cp.z)
        tedit_rot.x = P6_normalizeAngle(cr.x)
        tedit_rot.y = P6_normalizeAngle(cr.y)
        tedit_rot.z = P6_normalizeAngle(cr.z)
        loc_status_msg = "Вставлены координаты и углы (/tpaste)"
    elseif m == "z" then
        tedit_pos.z = P6_round4(cp.z)
        loc_status_msg = string.format("Выровнена высота Z=%.3f", tedit_pos.z)
    elseif m == "rot" then
        tedit_rot.x = P6_normalizeAngle(cr.x)
        tedit_rot.y = P6_normalizeAngle(cr.y)
        tedit_rot.z = P6_normalizeAngle(cr.z)
        loc_status_msg = "Вставлены только углы поворота (RX/RY/RZ)"
    elseif m == "offset" then
        tedit_pos.x = P6_round4(cp.x + (tedit_offset.x[0] or 0))
        tedit_pos.y = P6_round4(cp.y + (tedit_offset.y[0] or 0))
        tedit_pos.z = P6_round4(cp.z + (tedit_offset.z[0] or 0))
        tedit_rot.x = P6_normalizeAngle(cr.x)
        tedit_rot.y = P6_normalizeAngle(cr.y)
        tedit_rot.z = P6_normalizeAngle(cr.z)
        loc_status_msg = string.format("Вставлено со смещением (dX=%.2f dY=%.2f dZ=%.2f)", tedit_offset.x[0], tedit_offset.y[0], tedit_offset.z[0])
    else
        table.remove(tedit_undo)
        return false
    end
    P6.dirty_edit = true
    P6_syncManualBuffers()
    queueTask(P6_applyLocalPreview)
    return true
end

function P6_duplicateLast()
    local src_model, src_pos, src_rot = 0, nil, nil
    if tedit_active then
        src_model = (tedit_model and tedit_model > 0) and tedit_model or (P6.dup_model or 0)
        src_pos = {x = tedit_pos.x, y = tedit_pos.y, z = tedit_pos.z}
        src_rot = {x = tedit_rot.x, y = tedit_rot.y, z = tedit_rot.z}
    else
        local list = P6_getActiveProfileList(false)
        if type(list) == "table" and #list > 0 then
            local last = list[#list]
            src_model = last.model or 0
            src_pos = {x = last.x, y = last.y, z = last.z}
            src_rot = {x = last.rx, y = last.ry, z = last.rz}
        elseif type(tedit_clipboard) == "table" and type(tedit_clipboard.pos) == "table" then
            src_model = tedit_clipboard.model or P6.dup_model or 0
            src_pos = {x = tedit_clipboard.pos.x, y = tedit_clipboard.pos.y, z = tedit_clipboard.pos.z}
            src_rot = {x = tedit_clipboard.rot.x, y = tedit_clipboard.rot.y, z = tedit_clipboard.rot.z}
        elseif type(P6.dup_source) == "table" and type(P6.dup_source.pos) == "table" then
            src_model = P6.dup_source.model or P6.dup_model or 0
            src_pos = {x = P6.dup_source.pos.x, y = P6.dup_source.pos.y, z = P6.dup_source.pos.z}
            src_rot = {x = P6.dup_source.rot.x, y = P6.dup_source.rot.y, z = P6.dup_source.rot.z}
        end
    end
    if not src_pos then
        loc_status_msg = "Нет исходного объекта для /tdup"
        return false
    end
    P6.dup_source = {model = src_model, pos = src_pos, rot = src_rot}
    P6.dup_pending_until = os.clock() + 20.0
    tedit_dup_pending = true
    if src_model > 0 then
        P6.dup_model = src_model
        queueTask(function()
            if type(setClipboardText) == "function" then
                pcall(setClipboardText, tostring(src_model))
            end
        end)
    end
    P6.tedit_dismissed = false
    tedit_show[0] = true
    loc_status_msg = "Дубликат готов (ID " .. tostring(src_model) .. "): поставьте объект в /location"
    return true
end

function P6_selectDecorId(id)
    local num_id = tonumber(id)
    if not num_id or num_id <= 0 then return false end
    num_id = math.floor(num_id)
    loc_selected_id = num_id
    for i = #P6_loc_recents, 1, -1 do
        if P6_loc_recents[i] == num_id then
            table.remove(P6_loc_recents, i)
        end
    end
    table.insert(P6_loc_recents, 1, num_id)
    while #P6_loc_recents > 30 do
        table.remove(P6_loc_recents)
    end
    if type(setClipboardText) == "function" then
        pcall(setClipboardText, tostring(num_id))
    end
    loc_status_msg = "ID " .. tostring(num_id) .. " скопирован в буфер обмена"
    requestSaveSettings()
    return true
end

local function isValidJpgFile(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local hdr = f:read(3)
    f:close()
    return type(hdr) == "string" and #hdr >= 3 and hdr:byte(1) == 0xFF and hdr:byte(2) == 0xD8
end

function P6_pumpPreviewDownloads()
    if type(downloadUrlToFile) ~= "function" then
        for _, dl_id in ipairs(P6.dl_queue) do P6.dl_pending[dl_id] = "err" end
        P6.dl_queue = {}
        return
    end
    P6_ensureConfigDir()
    local cache_dir = getWorkingDirectory() .. "/config/decor_cache"
    if not doesDirectoryExist(cache_dir) then
        createDirectory(cache_dir)
    end
    local dl_ok, dlstatus = pcall(require, "moonloader")
    local end_status = (dl_ok and dlstatus and dlstatus.download_status and dlstatus.download_status.STATUS_ENDDOWNLOADDATA) or 6
    local endex_status = (dl_ok and dlstatus and dlstatus.download_status and dlstatus.download_status.STATUSEX_ENDDOWNLOAD) or 58

    while P6.dl_active_count < 3 and #P6.dl_queue > 0 do
        local dl_id = table.remove(P6.dl_queue, 1)
        local dl_path = cache_dir .. "/" .. tostring(dl_id) .. ".jpg"
        if fileExists(dl_path) and not isValidJpgFile(dl_path) then
            os.remove(dl_path)
        end
        if fileExists(dl_path) then
            P6.dl_pending[dl_id] = "done"
        else
            P6.dl_active_count = P6.dl_active_count + 1
            local finished = false
            local finish_one = function(ok_flag)
                if finished then return end
                finished = true
                P6.dl_active_count = math.max(0, P6.dl_active_count - 1)
                if ok_flag and fileExists(dl_path) and isValidJpgFile(dl_path) then
                    P6.dl_pending[dl_id] = "done"
                    if loc_textures[dl_id] == false then loc_textures[dl_id] = nil end
                else
                    if fileExists(dl_path) then os.remove(dl_path) end
                    P6.dl_pending[dl_id] = "err"
                end
                queueTask(P6_pumpPreviewDownloads)
            end
            scheduleTask(15000, function() finish_one(false) end)
            local url = "https://adv-rp.com/media/object/" .. tostring(dl_id) .. ".jpg"
            local ok_dl = pcall(downloadUrlToFile, url, dl_path, function(did, status, p1, p2)
                if finished then return end
                if status == end_status or status == endex_status then
                    finish_one(true)
                end
            end)
            if not ok_dl then finish_one(false) end
        end
    end
end

function P6_requestPreviewDownload(id)
    local num_id = tonumber(id)
    if not num_id or num_id <= 0 then return false end
    num_id = math.floor(num_id)
    local cache_path = getWorkingDirectory() .. "/config/decor_cache/" .. tostring(num_id) .. ".jpg"
    if fileExists(cache_path) then
        P6.dl_pending[num_id] = "done"
        return true
    end
    if P6.dl_pending[num_id] == "loading" or P6.dl_pending[num_id] == "err" then
        return false
    end
    P6.dl_pending[num_id] = "loading"
    P6.dl_queue[#P6.dl_queue + 1] = num_id
    queueTask(P6_pumpPreviewDownloads)
    return true
end

function P6_getFilteredCatalog()
    local q = cp1251_lower(decodeUtf8Safe(ffi.string(loc_search_buf)):gsub("^%s+", ""):gsub("%s+$", ""))
    local cat = loc_cat_filter[0]
    local only_fav = P6.fav_only[0]
    local only_rec = P6.recent_only[0]
    local list = {}

    if only_rec then
        local seen = {}
        for _, rid in ipairs(P6_loc_recents) do
            local it = P6_decor_by_id[rid]
            if it and not seen[rid] then
                seen[rid] = true
                local ok_cat = (cat == 0) or (it.cat == cat)
                local ok_fav = (not only_fav) or P6_isFavorite(it.id)
                local ok_q = (q == "") or tostring(it.id):find(q, 1, true) or cp1251_lower(it.name):find(q, 1, true)
                if ok_cat and ok_fav and ok_q then
                    list[#list + 1] = it
                end
            end
        end
    else
        for _, it in ipairs(P6_decor_catalog) do
            local ok_cat = (cat == 0) or (it.cat == cat)
            local ok_fav = (not only_fav) or P6_isFavorite(it.id)
            local ok_q = (q == "") or tostring(it.id):find(q, 1, true) or cp1251_lower(it.name):find(q, 1, true)
            if ok_cat and ok_fav and ok_q then
                list[#list + 1] = it
            end
        end
    end

    local sort_m = loc_sort_mode[0]
    if sort_m == 1 then
        table.sort(list, function(a, b) return a.id < b.id end)
    elseif sort_m == 2 then
        table.sort(list, function(a, b)
            local la, lb = cp1251_lower(a.name), cp1251_lower(b.name)
            if la == lb then return a.id < b.id end
            return la < lb
        end)
    end
    return list
end

function P6_flushTexReleaseQueue()
    if type(P6.tex_release_queue) ~= "table" or #P6.tex_release_queue == 0 then return end
    local q = P6.tex_release_queue
    P6.tex_release_queue = {}
    if type(imgui.IsInitialized) == "function" and not imgui.IsInitialized() then return end
    if type(imgui.ReleaseTexture) == "function" then
        for _, old_tex in ipairs(q) do
            if old_tex and old_tex ~= false then
                pcall(imgui.ReleaseTexture, old_tex)
            end
        end
    end
end

function P6_getTextureForId(id)
    local cached = loc_textures[id]
    if cached ~= nil then
        if cached ~= false then
            local order = P6.tex_order
            local n = #order
            if n > 0 and order[n] ~= id then
                for i = n - 1, 1, -1 do
                    if order[i] == id then
                        table.remove(order, i)
                        order[#order + 1] = id
                        break
                    end
                end
            end
            return cached
        end
        return nil
    end
    if P6.dl_pending[id] == "loading" or P6.dl_pending[id] == "err" then
        return nil
    end
    local cache_path = getWorkingDirectory() .. "/config/decor_cache/" .. tostring(id) .. ".jpg"
    if fileExists(cache_path) then
        local ok_t, tex = pcall(imgui.CreateTextureFromFile, cache_path)
        if ok_t and tex then
            loc_textures[id] = tex
            P6.tex_order[#P6.tex_order + 1] = id
            if #P6.tex_order > 48 then
                local old_id = table.remove(P6.tex_order, 1)
                local old_tex = loc_textures[old_id]
                if old_tex and old_tex ~= false then
                    P6.tex_release_queue = P6.tex_release_queue or {}
                    P6.tex_release_queue[#P6.tex_release_queue + 1] = old_tex
                    queueTask(P6_flushTexReleaseQueue)
                end
                loc_textures[old_id] = nil
            end
            return tex
        else
            loc_textures[id] = false
        end
    elseif loc_cache_previews[0] and P6.dl_pending[id] == nil then
        queueTask(function() P6_requestPreviewDownload(id) end)
    end
    return nil
end

function P6_drawPrecisionPanel(id_suffix)
    local sfx = type(id_suffix) == "string" and id_suffix or ""
    if tedit_active then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.25, 1.0, 0.45, 1.0))
        imgui.TextUnformatted(u8"Редактирование объекта SA-MP ID: " .. tostring(tedit_obj_id) .. (tedit_player_obj and " (PlayerObj)" or " (Global)"))
        imgui.PopStyleColor()
        local m_name = P6_getDecorName(tedit_model)
        imgui.TextUnformatted(u8"Модель: #" .. tostring(tedit_model) .. u8" — " .. encodeCp1251Safe(m_name))
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.95, 0.78, 0.30, 1.0))
        imgui.TextUnformatted(u8"Ожидание входа в редактор /location (параметры можно подготовить заранее)")
        imgui.PopStyleColor()
    end

    if tedit_dup_pending then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35, 0.90, 1.0, 1.0))
        imgui.TextUnformatted(u8"Дубликат активен (ID " .. tostring(P6.dup_model) .. u8"): поставьте объект в /location!")
        imgui.PopStyleColor()
        imgui.SameLine()
        if imgui.SmallButton(u8"Отменить##p6_dup_cancel" .. sfx) then
            tedit_dup_pending = false
            loc_status_msg = "Ожидание дубликата отменено"
        end
    end

    imgui.Separator()
    imgui.TextUnformatted(u8"Шаг позиции:")
    for _, step_v in ipairs({0.01, 0.05, 0.10, 0.50, 1.00, 2.00}) do
        imgui.SameLine()
        local lbl = string.format("%.2f##p6_sp_%s_%s", step_v, tostring(step_v), sfx)
        if imgui.SmallButton(lbl) then tedit_step_pos[0] = step_v end
    end
    imgui.PushItemWidth(110)
    imgui.InputFloat(u8"Точный шаг (м)##p6_step_p" .. sfx, tedit_step_pos, 0.01, 0.10, "%.3f")
    imgui.PopItemWidth()
    if tedit_step_pos[0] < 0.001 then tedit_step_pos[0] = 0.001 end

    local pos_axes = {
        {key = "x", label = "X", ptr = P6.manual_x},
        {key = "y", label = "Y", ptr = P6.manual_y},
        {key = "z", label = "Z", ptr = P6.manual_z}
    }
    for _, ax in ipairs(pos_axes) do
        local k = ax.key
        local st = tedit_step_pos[0]
        if imgui.Button("-##p6_pm_" .. k .. sfx, imgui.ImVec2(28, 22)) then
            P6_nudgeAxis("pos", k, -st)
        end
        imgui.SameLine()
        if imgui.Button("+##p6_pp_" .. k .. sfx, imgui.ImVec2(28, 22)) then
            P6_nudgeAxis("pos", k, st)
        end
        imgui.SameLine()
        imgui.TextUnformatted(ax.label .. ": " .. string.format("%.3f", tedit_pos[k] or 0.0))
        imgui.SameLine(180)
        imgui.PushItemWidth(120)
        imgui.InputFloat("##p6_in_p_" .. k .. sfx, ax.ptr, 0.0, 0.0, "%.3f")
        if imgui.IsItemDeactivatedAfterEdit() then
            P6_applyManualInput()
        end
        imgui.PopItemWidth()
    end

    imgui.Separator()
    imgui.TextUnformatted(u8"Шаг поворота:")
    for _, deg_v in ipairs({1, 5, 15, 45, 90}) do
        imgui.SameLine()
        if imgui.SmallButton(tostring(deg_v) .. u8"°##p6_sr_" .. tostring(deg_v) .. sfx) then
            tedit_step_rot[0] = deg_v
        end
    end
    imgui.SameLine()
    if imgui.SmallButton(u8"Горизонт (0,0)##p6_lvl" .. sfx) then
        P6_levelHorizon()
    end
    imgui.PushItemWidth(110)
    imgui.InputFloat(u8"Точный угол (°)##p6_step_r" .. sfx, tedit_step_rot, 1.0, 5.0, "%.2f")
    imgui.PopItemWidth()
    if tedit_step_rot[0] < 0.05 then tedit_step_rot[0] = 0.05 end

    local rot_axes = {
        {key = "x", label = "RX", ptr = P6.manual_rx},
        {key = "y", label = "RY", ptr = P6.manual_ry},
        {key = "z", label = "RZ", ptr = P6.manual_rz}
    }
    for _, ax in ipairs(rot_axes) do
        local k = ax.key
        local st = tedit_step_rot[0]
        if imgui.Button("-##p6_rm_" .. k .. sfx, imgui.ImVec2(28, 22)) then
            P6_nudgeAxis("rot", k, -st)
        end
        imgui.SameLine()
        if imgui.Button("+##p6_rp_" .. k .. sfx, imgui.ImVec2(28, 22)) then
            P6_nudgeAxis("rot", k, st)
        end
        imgui.SameLine()
        imgui.TextUnformatted(ax.label .. ": " .. string.format("%.2f", tedit_rot[k] or 0.0))
        imgui.SameLine(180)
        imgui.PushItemWidth(120)
        imgui.InputFloat("##p6_in_r_" .. k .. sfx, ax.ptr, 0.0, 0.0, "%.2f")
        if imgui.IsItemDeactivatedAfterEdit() then
            P6_applyManualInput()
        end
        imgui.PopItemWidth()
    end

    imgui.Separator()
    if imgui.Button(u8"Отмена (" .. tostring(#tedit_undo) .. ")##p6_undo" .. sfx, imgui.ImVec2(140, 24)) then
        P6_undoEdit()
    end
    imgui.SameLine()
    if imgui.Button(u8"Повтор (" .. tostring(#tedit_redo) .. ")##p6_redo" .. sfx, imgui.ImVec2(140, 24)) then
        P6_redoEdit()
    end

    imgui.Spacing()
    if imgui.Button(u8"Копировать (/tcopy)##p6_copy" .. sfx, imgui.ImVec2(145, 24)) then
        P6_copyParams()
    end
    imgui.SameLine()
    if imgui.Button(u8"Дубликат (/tdup)##p6_dup" .. sfx, imgui.ImVec2(145, 24)) then
        queueTask(P6_duplicateLast)
    end

    if imgui.Button(u8"Вставить всё##p6_pa" .. sfx, imgui.ImVec2(105, 24)) then P6_pasteParams("all") end
    imgui.SameLine()
    if imgui.Button(u8"Только Z##p6_pz" .. sfx, imgui.ImVec2(85, 24)) then P6_pasteParams("z") end
    imgui.SameLine()
    if imgui.Button(u8"Только углы##p6_pr" .. sfx, imgui.ImVec2(100, 24)) then P6_pasteParams("rot") end
    imgui.SameLine()
    if imgui.Button(u8"+ Смещение##p6_po" .. sfx, imgui.ImVec2(95, 24)) then P6_pasteParams("offset") end

    imgui.PushItemWidth(72)
    imgui.InputFloat("dX##p6_ox" .. sfx, tedit_offset.x, 0.0, 0.0, "%.2f")
    imgui.SameLine()
    imgui.InputFloat("dY##p6_oy" .. sfx, tedit_offset.y, 0.0, 0.0, "%.2f")
    imgui.SameLine()
    imgui.InputFloat("dZ##p6_oz" .. sfx, tedit_offset.z, 0.0, 0.0, "%.2f")
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.SmallButton(u8"0##p6_o0" .. sfx) then
        tedit_offset.x[0] = 0.0; tedit_offset.y[0] = 0.0; tedit_offset.z[0] = 0.0
    end

    if tedit_clipboard then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65, 0.85, 1.0, 1.0))
        imgui.TextUnformatted(string.format(u8"Буфер: ID %d | Pos(%.2f, %.2f, %.2f) | Rot(%.1f, %.1f, %.1f)",
            tedit_clipboard.model or 0,
            tedit_clipboard.pos.x or 0, tedit_clipboard.pos.y or 0, tedit_clipboard.pos.z or 0,
            tedit_clipboard.rot.x or 0, tedit_clipboard.rot.y or 0, tedit_clipboard.rot.z or 0))
        imgui.PopStyleColor()
    end
    if loc_status_msg ~= "" then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 1.0, 0.7, 1.0))
        imgui.TextUnformatted(encodeCp1251Safe(loc_status_msg))
        imgui.PopStyleColor()
    end
end

function P6_drawCatalogTab()
    imgui.PushItemWidth(240)
    if imgui.InputText(u8"Поиск (ID или название)##p6_search", loc_search_buf, ffi.sizeof(loc_search_buf)) then
        P6.cat_page = 1
    end
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.SmallButton(u8"Сброс##p6_srch_clr") then
        safeStrCopy(loc_search_buf, "", ffi.sizeof(loc_search_buf))
        P6.cat_page = 1
    end
    imgui.SameLine()
    imgui.PushItemWidth(195)
    local cat_items = u8"Все категории (522)" .. "\0"
    for _, cname in ipairs(P6_decor_cats) do
        cat_items = cat_items .. encodeCp1251Safe(cname) .. "\0"
    end
    if imgui.ComboStr("##p6_cat_combo", loc_cat_filter, cat_items) then
        P6.cat_page = 1
        requestSaveSettings()
    end
    imgui.PopItemWidth()
    imgui.SameLine()
    imgui.PushItemWidth(145)
    if imgui.ComboStr("##p6_sort_combo", loc_sort_mode, u8"Как на adv-rp" .. "\0" .. u8"По ID (возр.)" .. "\0" .. u8"По названию" .. "\0") then
        P6.cat_page = 1
        requestSaveSettings()
    end
    imgui.PopItemWidth()

    if imgui.Checkbox(u8"Компактно##p6_cmp", loc_compact_cards) then requestSaveSettings() end
    imgui.SameLine()
    if imgui.Checkbox(u8"Избранное##p6_fav", P6.fav_only) then P6.cat_page = 1 end
    imgui.SameLine()
    if imgui.Checkbox(u8"Недавние##p6_rec", P6.recent_only) then P6.cat_page = 1 end
    imgui.SameLine()
    if imgui.Checkbox(u8"Превью JPG (adv-rp)##p6_prv", loc_cache_previews) then requestSaveSettings() end

    local filtered = P6_getFilteredCatalog()
    local per_page = loc_compact_cards[0] and 24 or 10
    local total_pages = math.max(1, math.ceil(#filtered / per_page))
    if P6.cat_page < 1 then P6.cat_page = 1 end
    if P6.cat_page > total_pages then P6.cat_page = total_pages end

    imgui.TextUnformatted(u8"Найдено: " .. tostring(#filtered) .. " / " .. tostring(#P6_decor_catalog))
    imgui.SameLine(230)
    if imgui.SmallButton(u8"<- Назад##p6_pg_prev") and P6.cat_page > 1 then
        P6.cat_page = P6.cat_page - 1
        requestSaveSettings()
    end
    imgui.SameLine()
    imgui.TextUnformatted(u8"Стр. " .. tostring(P6.cat_page) .. "/" .. tostring(total_pages))
    imgui.SameLine()
    if imgui.SmallButton(u8"Далее ->##p6_pg_next") and P6.cat_page < total_pages then
        P6.cat_page = P6.cat_page + 1
        requestSaveSettings()
    end

    if loc_selected_id > 0 then
        local sel_item = P6_decor_by_id[loc_selected_id]
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 0.9, 1.0, 1.0))
        imgui.TextUnformatted(u8"Выбран: #" .. tostring(loc_selected_id) .. u8" — " .. encodeCp1251Safe(sel_item and sel_item.name or ""))
        imgui.PopStyleColor()
        imgui.SameLine()
        if imgui.SmallButton(u8"В чат##p6_sel_chat") then
            local sid = loc_selected_id
            queueTask(function()
                P6_selectDecorId(sid)
                if isSampAvailable() then
                    pcall(sampSetChatInputEnabled, true)
                    pcall(sampSetChatInputText, tostring(sid))
                end
            end)
        end
        imgui.SameLine()
        if imgui.SmallButton(u8"Превью JPG##p6_sel_dl") then
            local sid = loc_selected_id
            queueTask(function() P6_requestPreviewDownload(sid) end)
        end
    end

    imgui.BeginChild("##p6_catalog_scroll", imgui.ImVec2(0, -28), true)
    if #filtered == 0 then
        imgui.TextUnformatted(u8"Ничего не найдено. Измените фильтры или строку поиска.")
    else
        local first_idx = (P6.cat_page - 1) * per_page + 1
        local last_idx = math.min(first_idx + per_page - 1, #filtered)
        for pos = first_idx, last_idx do
            local item = filtered[pos]
            local iid = item.id
            local is_fav = P6_isFavorite(iid)
            local is_sel = (loc_selected_id == iid)
            local fav_lbl = (is_fav and "[*]" or "[ ]") .. "##p6_fv_" .. tostring(iid)

            if loc_compact_cards[0] then
                if imgui.SmallButton(fav_lbl) then
                    P6_toggleFavorite(iid)
                end
                imgui.SameLine()
                if imgui.SmallButton(tostring(iid) .. "##p6_cp_" .. tostring(iid)) then
                    queueTask(function() P6_selectDecorId(iid) end)
                end
                imgui.SameLine()
                if imgui.SmallButton(u8"Чат##p6_ch_" .. tostring(iid)) then
                    queueTask(function()
                        P6_selectDecorId(iid)
                        if isSampAvailable() then
                            pcall(sampSetChatInputEnabled, true)
                            pcall(sampSetChatInputText, tostring(iid))
                        end
                    end)
                end
                imgui.SameLine()
                if is_sel then imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35, 1.0, 0.55, 1.0)) end
                imgui.TextUnformatted(encodeCp1251Safe(item.name))
                if is_sel then imgui.PopStyleColor() end
            else
                if loc_cache_previews[0] then
                    local tex = P6_getTextureForId(iid)
                    if tex then
                        imgui.Image(tex, imgui.ImVec2(48, 48))
                        imgui.SameLine()
                    end
                end
                imgui.BeginGroup()
                if is_sel then imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35, 1.0, 0.55, 1.0)) end
                imgui.TextUnformatted("#" .. tostring(iid) .. u8" — " .. encodeCp1251Safe(item.name))
                if is_sel then imgui.PopStyleColor() end
                local cname = P6_decor_cats[item.cat] or "Разное"
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65, 0.65, 0.70, 1.0))
                imgui.TextUnformatted(u8"Категория: " .. encodeCp1251Safe(cname))
                imgui.PopStyleColor()
                if imgui.SmallButton(u8"Копировать ID##p6_cc_" .. tostring(iid)) then
                    queueTask(function() P6_selectDecorId(iid) end)
                end
                imgui.SameLine()
                if imgui.SmallButton(u8"В чат##p6_cch_" .. tostring(iid)) then
                    queueTask(function()
                        P6_selectDecorId(iid)
                        if isSampAvailable() then
                            pcall(sampSetChatInputEnabled, true)
                            pcall(sampSetChatInputText, tostring(iid))
                        end
                    end)
                end
                imgui.SameLine()
                if imgui.SmallButton((is_fav and u8"Убрать из избр." or u8"В избранное") .. "##p6_cf_" .. tostring(iid)) then
                    P6_toggleFavorite(iid)
                end
                imgui.EndGroup()
                imgui.Separator()
            end
        end
    end
    imgui.EndChild()
end

function P6_drawRegistryTab()
    local active_pk = P6_getProfileKey()
    if P6.reg_profile_view == "" then P6.reg_profile_view = active_pk end
    local prof_keys = {}
    local seen_pk = {}
    if type(P6_loc_registry) == "table" then
        for k in pairs(P6_loc_registry) do
            prof_keys[#prof_keys + 1] = k
            seen_pk[k] = true
        end
    end
    if not seen_pk[active_pk] then prof_keys[#prof_keys + 1] = active_pk end
    table.sort(prof_keys)

    imgui.TextUnformatted(u8"Профиль:")
    imgui.SameLine()
    imgui.PushItemWidth(280)
    if imgui.BeginCombo("##p6_reg_prof", encodeCp1251Safe(P6.reg_profile_view)) then
        for _, pk in ipairs(prof_keys) do
            local cnt = (P6_loc_registry[pk] and #P6_loc_registry[pk]) or 0
            local lbl = encodeCp1251Safe(pk) .. " (" .. tostring(cnt) .. ")"
            if imgui.Selectable(lbl .. "##p6_pk_" .. encodeCp1251Safe(pk), P6.reg_profile_view == pk) then
                P6.reg_profile_view = pk
                loc_mid_helper_idx = 0
                P6.reg_clear_confirm = false
            end
        end
        imgui.EndCombo()
    end
    imgui.PopItemWidth()

    local list = (type(P6_loc_registry) == "table" and P6_loc_registry[P6.reg_profile_view]) or {}
    imgui.SameLine()
    if imgui.SmallButton(u8"Экспорт JSON##p6_bp_exp") then
        local view_pk = P6.reg_profile_view
        queueTask(function() P6_exportBlueprint(view_pk) end)
    end
    imgui.SameLine()
    if imgui.SmallButton(u8"Импорт (+)##p6_bp_imp_add") then
        local view_pk = P6.reg_profile_view
        queueTask(function() P6_importBlueprint(false, view_pk) end)
    end
    imgui.SameLine()
    if imgui.SmallButton(u8"Импорт (замена)##p6_bp_imp_rep") then
        local view_pk = P6.reg_profile_view
        queueTask(function() P6_importBlueprint(true, view_pk) end)
    end

    imgui.TextUnformatted(u8"Сохранённых объектов: " .. tostring(#list))
    imgui.SameLine()
    if not P6.reg_clear_confirm then
        if imgui.SmallButton(u8"Очистить профиль##p6_clr_req") and #list > 0 then
            P6.reg_clear_confirm = true
        end
    else
        if imgui.SmallButton(u8"Подтвердить очистку##p6_clr_ok") then
            P6_loc_registry[P6.reg_profile_view] = {}
            loc_mid_helper_idx = 0
            P6.reg_clear_confirm = false
            loc_status_msg = "Профиль реестра очищен"
            queueTask(P6_saveLocations)
        end
        imgui.SameLine()
        if imgui.SmallButton(u8"Отмена##p6_clr_no") then
            P6.reg_clear_confirm = false
        end
    end

    local child_h = (loc_mid_helper_idx > 0 and loc_mid_helper_idx <= #list) and 210 or -28
    imgui.BeginChild("##p6_reg_scroll", imgui.ImVec2(0, child_h), true)
    if #list == 0 then
        imgui.TextUnformatted(u8"Список пуст. Сохраните объект в /location (или импортируйте чертёж).")
    else
        local del_idx, move_up, move_dn = nil, nil, nil
        for i, obj in ipairs(list) do
            local mname = P6_getDecorName(obj.model)
            local is_hl = (loc_mid_helper_idx == i)
            if is_hl then imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35, 0.95, 1.0, 1.0)) end
            imgui.TextUnformatted(string.format(u8"#%d | ID %d — %s", i, obj.model or 0, encodeCp1251Safe(mname)))
            if is_hl then imgui.PopStyleColor() end
            imgui.TextUnformatted(string.format("   Pos: %.3f, %.3f, %.3f | Rot: %.1f, %.1f, %.1f",
                obj.x or 0, obj.y or 0, obj.z or 0, obj.rx or 0, obj.ry or 0, obj.rz or 0))
            if imgui.SmallButton(u8"ID##p6_rid_" .. i) then
                local mid = obj.model or 0
                queueTask(function()
                    if type(setClipboardText) == "function" then pcall(setClipboardText, tostring(mid)) end
                    loc_status_msg = "ID " .. tostring(mid) .. " скопирован"
                end)
            end
            imgui.SameLine()
            if imgui.SmallButton(u8"-> /tcopy##p6_rcp_" .. i) then
                tedit_clipboard = {
                    model = obj.model or 0,
                    pos = {x = obj.x or 0, y = obj.y or 0, z = obj.z or 0},
                    rot = {x = obj.rx or 0, y = obj.ry or 0, z = obj.rz or 0}
                }
                loc_status_msg = "Параметры #" .. tostring(i) .. " помещены в /tcopy"
            end
            imgui.SameLine()
            if i > 1 and imgui.SmallButton(u8"Вверх##p6_rup_" .. i) then move_up = i end
            if i > 1 then imgui.SameLine() end
            if i < #list and imgui.SmallButton(u8"Вниз##p6_rdn_" .. i) then move_dn = i end
            if i < #list then imgui.SameLine() end
            if imgui.SmallButton(u8"Помощник##p6_rmid_" .. i) then
                loc_mid_helper_idx = is_hl and 0 or i
            end
            imgui.SameLine()
            if imgui.SmallButton("X##p6_rdel_" .. i) then del_idx = i end
            imgui.Separator()
        end
        if move_up then
            list[move_up], list[move_up - 1] = list[move_up - 1], list[move_up]
            if loc_mid_helper_idx == move_up then
                loc_mid_helper_idx = move_up - 1
            elseif loc_mid_helper_idx == move_up - 1 then
                loc_mid_helper_idx = move_up
            end
            queueTask(P6_saveLocations)
        elseif move_dn then
            list[move_dn], list[move_dn + 1] = list[move_dn + 1], list[move_dn]
            if loc_mid_helper_idx == move_dn then
                loc_mid_helper_idx = move_dn + 1
            elseif loc_mid_helper_idx == move_dn + 1 then
                loc_mid_helper_idx = move_dn
            end
            queueTask(P6_saveLocations)
        elseif del_idx then
            table.remove(list, del_idx)
            if loc_mid_helper_idx == del_idx then
                loc_mid_helper_idx = 0
            elseif loc_mid_helper_idx > del_idx then
                loc_mid_helper_idx = loc_mid_helper_idx - 1
            end
            loc_status_msg = "Удалена запись #" .. tostring(del_idx) .. " из реестра"
            queueTask(P6_saveLocations)
        end
    end
    imgui.EndChild()

    if loc_mid_helper_idx > 0 and loc_mid_helper_idx <= #list then
        local target = list[loc_mid_helper_idx]
        imgui.Separator()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.85, 0.30, 1.0))
        imgui.TextUnformatted(u8"Пошаговый помощник для элемента #" .. tostring(loc_mid_helper_idx) .. " (ID " .. tostring(target.model) .. u8" из " .. tostring(#list) .. "):")
        imgui.PopStyleColor()
        imgui.PushTextWrapPos(0)
        imgui.TextUnformatted(u8"1. Если нужно сдвинуть объект #" .. tostring(loc_mid_helper_idx) .. u8" без удаления: скопируйте его координаты (-> /tcopy), откройте /location на сервере -> выберите строку #" .. tostring(loc_mid_helper_idx) .. u8" -> Редактировать -> /tpaste -> Сохранить.")
        imgui.TextUnformatted(u8"2. Если удалили объект #" .. tostring(loc_mid_helper_idx) .. u8" на сервере: все последующие элементы (#" .. tostring(loc_mid_helper_idx + 1) .. "..#" .. tostring(#list) .. u8") сместились на 1 вверх — нажмите «Синхр. удаление» ниже.")
        imgui.TextUnformatted(u8"3. Если заменяете модель в середине: скопируйте хвост (#" .. tostring(loc_mid_helper_idx + 1) .. "..#" .. tostring(#list) .. u8") по кнопкам ниже, удалите их с конца списка /location и пересоздайте с /tpaste.")
        imgui.PopTextWrapPos()
        if imgui.SmallButton(u8"Взять #" .. tostring(loc_mid_helper_idx) .. u8" в /tcopy + буфер ID##p6_mh_cp") then
            tedit_clipboard = {
                model = target.model or 0,
                pos = {x = target.x, y = target.y, z = target.z},
                rot = {x = target.rx, y = target.ry, z = target.rz}
            }
            local mid = target.model or 0
            queueTask(function()
                if type(setClipboardText) == "function" then pcall(setClipboardText, tostring(mid)) end
            end)
            loc_status_msg = "ID " .. tostring(mid) .. " и координаты #" .. tostring(loc_mid_helper_idx) .. " в буфере"
        end
        imgui.SameLine()
        if imgui.SmallButton(u8"Синхр. удаление #" .. tostring(loc_mid_helper_idx) .. u8" (сдвиг списка)##p6_mh_del") then
            table.remove(list, loc_mid_helper_idx)
            loc_mid_helper_idx = 0
            loc_status_msg = "Реестр сдвинут после удаления на сервере"
            queueTask(P6_saveLocations)
        end
        imgui.SameLine()
        if imgui.SmallButton(u8"Закрыть помощник##p6_mh_close") then
            loc_mid_helper_idx = 0
        end
        if loc_mid_helper_idx > 0 and loc_mid_helper_idx < #list then
            imgui.TextUnformatted(u8"Хвост для восстановления порядка (" .. tostring(#list - loc_mid_helper_idx) .. u8" шт.):")
            local use_tail_child = (#list > 6)
            if use_tail_child then
                imgui.BeginChild("##p6_mh_tail_scroll", imgui.ImVec2(0, 75), true)
            end
            for ti = loc_mid_helper_idx + 1, #list do
                local tail_obj = list[ti]
                if imgui.SmallButton(u8"#" .. tostring(ti) .. " (ID " .. tostring(tail_obj.model) .. ")##p6_mh_t_" .. tostring(ti)) then
                    P6.dup_source = {
                        model = tail_obj.model or 0,
                        pos = {x = tail_obj.x, y = tail_obj.y, z = tail_obj.z},
                        rot = {x = tail_obj.rx, y = tail_obj.ry, z = tail_obj.rz}
                    }
                    P6.dup_pending_until = os.clock() + 20.0
                    tedit_dup_pending = true
                    P6.dup_model = tail_obj.model or 0
                    local mid = tail_obj.model or 0
                    queueTask(function()
                        if type(setClipboardText) == "function" then pcall(setClipboardText, tostring(mid)) end
                    end)
                    loc_status_msg = "Готово восстановление #" .. tostring(ti) .. " (ID " .. tostring(mid) .. ")"
                end
                if ((ti - loc_mid_helper_idx) % 4 ~= 0) and (ti < #list) then imgui.SameLine() end
            end
            if use_tail_child then
                imgui.EndChild()
            end
        end
    end
end

function P6_drawLocationWindowUI(tab_override)
    if type(tab_override) == "number" and tab_override >= 1 and tab_override <= 3 then
        loc_ui_tab = tab_override
    end
    local tabs = {
        {id = 1, name = u8"1. Каталог 522"},
        {id = 2, name = u8"2. Реестр локации"},
        {id = 3, name = u8"3. Точный редактор"}
    }
    for idx, t in ipairs(tabs) do
        local active = (loc_ui_tab == t.id)
        if active then imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.22, 0.52, 0.82, 1.0)) end
        if imgui.Button(t.name .. "##p6_tab_" .. tostring(t.id), imgui.ImVec2(170, 26)) then
            loc_ui_tab = t.id
        end
        if active then imgui.PopStyleColor() end
        if idx < #tabs then imgui.SameLine() end
    end
    imgui.SameLine()
    if imgui.Button(u8"Окно /tedit##p6_pop_tedit", imgui.ImVec2(120, 26)) then
        P6.tedit_dismissed = false
        tedit_show[0] = not tedit_show[0]
    end
    imgui.Separator()

    if loc_ui_tab == 1 then
        P6_drawCatalogTab()
    elseif loc_ui_tab == 2 then
        P6_drawRegistryTab()
    else
        imgui.BeginChild("##p6_tedit_tab_wrap", imgui.ImVec2(0, -28), true)
        P6_drawPrecisionPanel("_tab")
        imgui.EndChild()
    end

    if loc_status_msg ~= "" and loc_ui_tab ~= 3 then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 1.0, 0.65, 1.0))
        imgui.TextUnformatted(encodeCp1251Safe(loc_status_msg))
        imgui.PopStyleColor()
    end
end

function P6_drawLocationModuleSettings()
    if imgui.Button(u8"Открыть Каталог 522 (/loc 1)##p6_m_cat", imgui.ImVec2(230, 28)) then
        loc_ui_tab = 1; loc_ui_show[0] = true
    end
    imgui.SameLine()
    if imgui.Button(u8"Открыть Реестр (/loc 2)##p6_m_reg", imgui.ImVec2(210, 28)) then
        loc_ui_tab = 2; loc_ui_show[0] = true
    end
    if imgui.Button(u8"Открыть Точный редактор (/tedit)##p6_m_ted", imgui.ImVec2(260, 26)) then
        P6.tedit_dismissed = false
        tedit_show[0] = not tedit_show[0]
    end

    imgui.Spacing()
    if imgui.Checkbox(u8"Регистрировать короткую команду /loc (резерв /tloc)", loc_use_short_cmd) then
        requestSaveSettings()
    end
    if imgui.Checkbox(u8"Подгружать превью-картинки объектов (adv-rp.com/decor)", loc_cache_previews) then
        requestSaveSettings()
    end
    if imgui.Checkbox(u8"Компактный режим списка каталога", loc_compact_cards) then
        requestSaveSettings()
    end

    imgui.Spacing()
    imgui.Separator()
    local prof_list = P6_getActiveProfileList(false)
    local reg_cnt = (type(prof_list) == "table") and #prof_list or 0
    imgui.TextUnformatted(u8"В базе объектов: " .. tostring(#P6_decor_catalog) .. u8" | Избранных: " .. tostring(#P6_loc_favorites) .. u8" | В текущем профиле: " .. tostring(reg_cnt))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65, 0.65, 0.70, 1.0))
    imgui.PushTextWrapPos(0)
    imgui.TextUnformatted(u8"Команды: /loc [1|2|3|поиск] или /tloc [1|2|3|поиск] — окно конструктора; /tedit — панель точного сдвига и вращения; /tcopy — копировать координаты и углы; /tpaste [all|z|rot|offset] — вставить; /tdup — быстрый дубликат объекта.")
    imgui.PopTextWrapPos()
    imgui.PopStyleColor()
end

function P6_cmdLoc(arg)
    P6_refreshProfileKey()
    local a = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if a == "1" then
        loc_ui_tab = 1
        loc_ui_show[0] = true
    elseif a == "2" then
        loc_ui_tab = 2
        loc_ui_show[0] = true
    elseif a == "3" then
        loc_ui_tab = 3
        loc_ui_show[0] = true
    elseif a == "" then
        loc_ui_show[0] = not loc_ui_show[0]
    else
        safeStrCopy(loc_search_buf, encodeCp1251Safe(a), ffi.sizeof(loc_search_buf))
        P6.cat_page = 1
        loc_ui_tab = 1
        loc_ui_show[0] = true
    end
end

function P6_cmdTedit()
    P6.tedit_dismissed = false
    tedit_show[0] = not tedit_show[0]
    if isSampAvailable() then
        sampAddChatMessage("[Helper /tedit] Точный редактор: " .. (tedit_show[0] and "{00FF00}ВКЛ" or "{FF5555}ВЫКЛ"), 0xFFFFFF)
    end
end

function P6_cmdTcopy()
    if P6_copyParams() then
        if isSampAvailable() then
            sampAddChatMessage("[Helper /tcopy] " .. loc_status_msg, 0x00FF90)
        end
    else
        if isSampAvailable() then
            sampAddChatMessage("[Helper /tcopy] " .. loc_status_msg, 0xFFAA00)
        end
    end
end

function P6_cmdTpaste(arg)
    local mode = (arg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if mode == "" then mode = "all" end
    if mode ~= "all" and mode ~= "z" and mode ~= "rot" and mode ~= "offset" then
        if isSampAvailable() then
            sampAddChatMessage("[Helper /tpaste] Использование: /tpaste [all|z|rot|offset]", 0xFFAA00)
        end
        return
    end
    local ok = P6_pasteParams(mode)
    if isSampAvailable() then
        sampAddChatMessage("[Helper /tpaste] " .. loc_status_msg, ok and 0x00FF90 or 0xFFAA00)
    end
end

function P6_cmdTdup()
    local ok = P6_duplicateLast()
    if isSampAvailable() then
        sampAddChatMessage("[Helper /tdup] " .. loc_status_msg, ok and 0x00FF90 or 0xFFAA00)
    end
end

-- ГЛАВНАЯ ФУНКЦИЯ (Точка входа)
function main()
while not isSampAvailable() do wait(100) end

-- Загружаем базы и настройки
local db_ok, db_err = pcall(loadDatabases)
if not db_ok then sampAddChatMessage("[Helper] loadDatabases error: " .. tostring(db_err), 0xFF0000) end

-- Restore module enabled states from saved settings
if saved_module_states then
for _, mod in ipairs(modules) do
if saved_module_states[mod.id] ~= nil then
mod.enabled = saved_module_states[mod.id]
end
end
end

sampAddChatMessage("Helper Core " .. SCRIPT_VERSION .. " загружен. Меню: F11", 0x00FF00)
sampAddChatMessage("Стробы: J/N | Круиз: C | /hud, /wp, /quiz, /rec, /hist, /loc, /cam, /calc | Меню: F11", 0xFFFFFF)

-- Регистрируем команду открытия меню

sampRegisterChatCommand("gnews_send", function()
    local p = gnews_settings.profiles[gnews_settings.selected]
    if p then
        local l1 = formatGnewsLine(p.tag, p.line1)
        local l2 = formatGnewsLine(p.tag, p.line2)
        local l3 = formatGnewsLine(p.tag, p.line3)
        local lines = {}
        if l1 ~= "" then table.insert(lines, l1) end
        if l2 ~= "" then table.insert(lines, l2) end
        if l3 ~= "" then table.insert(lines, l3) end
        if #lines > 0 then
            gnewsPublishLines(lines, gnews_settings.delay or 1500)
        else
            sampAddChatMessage("[Helper] Ошибка: строки 1-3 в профиле пусты!", 0xFF0000)
        end
    end
end)

sampRegisterChatCommand("gnews_stop", stopGnews)
sampRegisterChatCommand("gnews_remind", function()
    local p = gnews_settings.profiles[gnews_settings.selected]
    if p then
        local t = formatGnewsLine(p.tag, p.remind)
        sendGnewsSingle(t)
    end
end)
sampRegisterChatCommand("gnews_end", function()
    local p = gnews_settings.profiles[gnews_settings.selected]
    if p then
        local t = formatGnewsLine(p.tag, p.finish)
        sendGnewsSingle(t)
    end
end)

sampRegisterChatCommand("helper", function()
show_main_window[0] = not show_main_window[0]
end)

sampRegisterChatCommand("calln", function(arg)
    if not arg or arg:gsub("%s+", "") == "" then
        sampAddChatMessage("[Helper] Использование: /calln [ник или часть ника]", 0xFFAA00)
        return
    end
    local c = findContactByQuery(arg)
    if not c then
        sampAddChatMessage("[Helper] Контакт '" .. arg .. "' не найден в базе.", 0xFF5555)
        return
    end
    sampAddChatMessage("[Helper] Звонок " .. c.nick .. " (тел. " .. c.phone .. ")", 0x00FF90)
    sampSendChat("/c " .. c.phone)
    table.insert(last_called_queue, {nick = c.nick, time = os.time()})
end)

sampRegisterChatCommand("smsn", function(arg)
    local query, msg = (arg or ""):match("^(%S+)%s+(.+)$")
    if not query or not msg or msg == "" then
        sampAddChatMessage("[Helper] Использование: /smsn [ник] [текст]", 0xFFAA00)
        return
    end
    local c = findContactByQuery(query)
    if not c then
        sampAddChatMessage("[Helper] Контакт '" .. query .. "' не найден в базе.", 0xFF5555)
        return
    end
    sampAddChatMessage("[Helper SMS -> " .. c.nick .. " (" .. c.phone .. ")]: " .. msg, 0x00CCFF)
    sampSendChat("/sms " .. c.phone .. " " .. msg)
end)

sampRegisterChatCommand("lsms", function(arg)
    if last_sms_phone == "" then
        sampAddChatMessage("[Helper] Пока не было входящих SMS или звонков с известным номером.", 0xFFAA00)
        return
    end
    if not arg or arg:gsub("%s+", "") == "" then
        sampAddChatMessage("[Helper] Последний собеседник: " .. (last_sms_nick ~= "" and last_sms_nick or "?") .. " (тел. " .. last_sms_phone .. "). /lsms [текст]", 0x00CCFF)
        return
    end
    sampSendChat("/sms " .. last_sms_phone .. " " .. arg)
end)

sampRegisterChatCommand("ss", function()
    if not isSampAvailable() then return end
    sampSendChat("/c 60")
    scheduleTask(ss_delay[0], function()
        pcall(setVirtualKeyDown, 0x77, true)
        scheduleTask(80, function()
            pcall(setVirtualKeyDown, 0x77, false)
        end)
    end)
end)

sampRegisterChatCommand("clog", function(arg)
    if arg and arg ~= "" then
        safeStrCopy(clog_search_buf, encodeCp1251Safe(arg), ffi.sizeof(clog_search_buf))
    end
    clog_show[0] = true
end)

sampRegisterChatCommand("fadd", function(arg)
    local fnick, fnote = (arg or ""):match("^(%S+)%s*(.*)$")
    if not fnick or fnick == "" then
        sampAddChatMessage("[Helper] Использование: /fadd [ник] [заметка]", 0xFFAA00)
        return
    end
    friends_list[cp1251_lower(fnick)] = { nick = fnick, note = fnote or "" }
    requestSaveSettings()
    sampAddChatMessage("[Helper Друзья] Добавлен: " .. fnick, 0x00FF90)
end)

sampRegisterChatCommand("fdel", function(arg)
    local fnick = (arg or ""):gsub("%s+", "")
    if fnick == "" then
        sampAddChatMessage("[Helper] Использование: /fdel [ник]", 0xFFAA00)
        return
    end
    local key = cp1251_lower(fnick)
    if friends_list[key] then
        friends_list[key] = nil
        requestSaveSettings()
        sampAddChatMessage("[Helper Друзья] Удалён: " .. fnick, 0x00FF00)
    else
        sampAddChatMessage("[Helper Друзья] Не найден: " .. fnick, 0xFFAA00)
    end
end)

sampRegisterChatCommand("friends", function()
    local on_list, off_count = {}, 0
    for _, f in pairs(friends_list) do
        local fid = getOnlinePlayerIdByNick(f.nick)
        if fid then
            on_list[#on_list + 1] = f.nick .. " [ID:" .. fid .. "]"
        else
            off_count = off_count + 1
        end
    end
    if #on_list == 0 and off_count == 0 then
        sampAddChatMessage("[Helper Друзья] Список пуст. /fadd [ник]", 0xFFAA00)
    elseif #on_list == 0 then
        sampAddChatMessage("[Helper Друзья] Онлайн никого нет (оффлайн: " .. off_count .. ")", 0xCECECE)
    else
        sampAddChatMessage("[Helper Друзья Онлайн]: " .. table.concat(on_list, ", ") .. " (оффлайн: " .. off_count .. ")", 0x00FF90)
    end
end)

if check_updates_enabled[0] then
    scheduleTask(6000, function() checkGithubUpdates(false) end)
end

sampRegisterChatCommand("hud", function()
    hud_enabled[0] = not hud_enabled[0]
    requestSaveSettings()
    sampAddChatMessage("[Helper] Компактный HUD: " .. (hud_enabled[0] and "{00FF00}ВКЛ" or "{FF0000}ВЫКЛ"), 0xFFFFFF)
end)

sampRegisterChatCommand("calc", function(arg)
    if not arg or arg:gsub("%s+", "") == "" then
        sampAddChatMessage("[Helper] Использование: /calc [выражение] (напр. /calc (1.5кк + 500к) * 2)", 0xFFAA00)
        return
    end
    local val, err = evalCalcExpr(arg)
    if not val then
        sampAddChatMessage("[Helper Calc] " .. tostring(err), 0xFF5555)
        return
    end
    local is_int = math.abs(val - math.floor(val + 0.5)) < 1e-6
    local raw_str = is_int and string.format("%.0f", val) or string.format("%.2f", val)
    local money_str = formatNumberWithDots(val) .. "$"
    sampAddChatMessage("[Helper Calc] " .. arg .. " = {00FF90}" .. raw_str .. " {CECECE}(" .. money_str .. ")", 0x00CCFF)
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

-- РП-ДВИЖОК: кастомные отыгровки
loadRpSettings()
sampRegisterChatCommand('rplogin', function() playerLogin() end)
sampRegisterChatCommand('mmact', cmdAct)
sampRegisterChatCommand('mmnext', function() rp_settings.wait = false end)
sampRegisterChatCommand('mmstop', stopRp)
sampRegisterChatCommand('rpeditor', function() rp_show_edit[0] = not rp_show_edit[0] end)
sampRegisterChatCommand('rptest', function()
  local chapter = rp_settings.setList[0] + 1
  local sel = rp_settings.selected
  if rp_settings.set[chapter] and rp_settings.set[chapter][sel] then
    playRp(rp_settings.set[chapter][sel].text, true)
  end
end)

-- СМИ-ФУНКЦИИ: регистрация команд
loadBlacklist()
sampRegisterChatCommand('anag', function(arg) startAnagram(arg) end)
sampRegisterChatCommand('quiz', function() quiz_popout_show[0] = not quiz_popout_show[0] end)
sampRegisterChatCommand('wp', findAndSetWaypoint)
sampRegisterChatCommand('wpsave', saveCurrentWaypoint)
sampRegisterChatCommand('wpclear', function() clearWaypointTarget(false) end)
sampRegisterChatCommand('rec', cmdReconnect)
sampRegisterChatCommand('hist', cmdFastHistory)
sampRegisterChatCommand('wheelmenu', function() P2_toggleWheelMenu() end)
if not P3.lecturer_loaded and type(P3_loadLecturer) == "function" then pcall(P3_loadLecturer) end
sampRegisterChatCommand('lect', P3_cmdLect)
sampRegisterChatCommand('lectstop', P3_stopLecturer)
sampRegisterChatCommand('suw', function(arg)
    P4_openSuMenu(arg)
end)
sampRegisterChatCommand('medui', function(arg)
    P4_openMedMenu(arg)
end)
sampRegisterChatCommand('dmglog', function()
    dmg_log_show[0] = not dmg_log_show[0]
end)
sampRegisterChatCommand('cam', P5_toggleFreeCam)
sampRegisterChatCommand('buyfast', P5_cmdBuyFast)
if next(P6_loc_registry) == nil then pcall(P6_loadLocations) end
pcall(P6_refreshProfileKey)
scheduleTask(3000, P6_refreshProfileKey)
sampRegisterChatCommand('tloc', P6_cmdLoc)
sampRegisterChatCommand('tedit', P6_cmdTedit)
sampRegisterChatCommand('tcopy', P6_cmdTcopy)
sampRegisterChatCommand('tpaste', P6_cmdTpaste)
sampRegisterChatCommand('tdup', P6_cmdTdup)
if loc_use_short_cmd[0] then
    local ok_l = pcall(sampRegisterChatCommand, 'loc', P6_cmdLoc)
    if not ok_l then
        sampAddChatMessage("[Helper] /loc занята — используйте /tloc [1|2]", 0xFFAA00)
    end
end
sampRegisterChatCommand('tvlf', cmdTvlift)
sampRegisterChatCommand('uninv', cmdUninvite)
sampRegisterChatCommand('mmefir', cmdEfir)
sampRegisterChatCommand('endefir', cmdEndEfir)
sampRegisterChatCommand('efirstats', cmdEfirStats)
sampRegisterChatCommand('autoans', cmdAutoAnswer)
sampRegisterChatCommand('bladd', function(arg)
  local nick, reason = arg:match('^(%S+)%s*(.*)')
  if nick then addBlacklistNick(nick, reason) else sampAddChatMessage('[Helper] /bladd [ник] [причина]', 0xFFAA00) end
end)
sampRegisterChatCommand('bldel', function(arg)
  if arg and arg ~= '' then removeBlacklistNick(arg) else sampAddChatMessage('[Helper] /bldel [ник]', 0xFFAA00) end
end)
sampRegisterChatCommand('blcheck', function(arg)
  if arg and arg ~= '' then
    if checkBlacklistNick(arg) then sampAddChatMessage('[Helper] ' .. arg .. ' В чёрном списке!', 0xFF0000)
    else sampAddChatMessage('[Helper] ' .. arg .. ' не в чёрном списке', 0x00FF00) end
  else sampAddChatMessage('[Helper] /blcheck [ник]', 0xFFAA00) end
end)
sampRegisterChatCommand('bllist', function()
  local count = 0
  for nick, data in pairs(blacklist_data) do
    count = count + 1
    sampAddChatMessage('  ' .. nick .. ' — ' .. (data.reason or 'нет причины') .. ' (' .. (data.added or '?') .. ')', 0xCECECE)
  end
  if count == 0 then sampAddChatMessage('[Helper] Чёрный список пуст', 0xFFAA00)
  else sampAddChatMessage('[Helper] Всего в ЧС: ' .. count, 0x00FF00) end
end)

-- Запуск потоков
lua_thread.create(factionScannerWorker)
lua_thread.create(weaponTrackWorker)
lua_thread.create(cruiseControlWorker)
lua_thread.create(environmentWorker)

-- Парсер чата в главном цикле (безопасно)

-- Авто-загрузка РП-данных через 3 сек после старта
lua_thread.create(function() wait(3000) playerLogin() end)
-- Online nicks cache initialized from main loop, not from thread (avoids coroutine crash)

chatScanner_processed = chatScanner_processed or {}
chatScanner_processed_count = chatScanner_processed_count or 0
chatScanner_last_run = chatScanner_last_run or 0

function chatScannerTick()
if not isModuleEnabled("autocall_db") or not isSampAvailable() then return end
if os.time() - chatScanner_last_run < 1 then return end
chatScanner_last_run = os.time()

for i = 90, 99 do
local text, prefix, color, pcolor = sampGetChatString(i)
if text and text ~= "" and not chatScanner_processed[text] then
chatScanner_processed[text] = true
chatScanner_processed_count = chatScanner_processed_count + 1

if chatScanner_processed_count > 200 then
chatScanner_processed = {}
chatScanner_processed_count = 0
end

local sender, phone = text:match("Отправитель:%s*([A-Za-z0-9_]+).-[Тт]ел%s*:%s*(%d+)")
if not sender or not phone then
sender, phone = text:match("([A-Za-z0-9_]+)%s*%.%s*[Тт]ел%s*:%s*(%d+)")
end
local text_utf8 = encodeCp1251Safe(text)

if sender and phone then
local ad_text = text_utf8:match("Объявление:%s*(.-)%s*Отправитель:") or ""
table.insert(player_db_queue, {sender = sender, phone = phone, ad = ad_text})
sampAddChatMessage("[Helper DB] Добавлен контакт: " .. sender .. " (Тел: " .. phone .. ")", 0x00FF90)
end
end
end
end


-- Поток отслеживания диалоговых окон (альтернатива onShowDialog без SAMP.Lua)

local function mainFrameTick()

-- Process task queue from UI / callbacks (thread-safe, runs in main game tick)
local q_count = #task_queue
if q_count > 0 then
    for i = 1, math.min(q_count, 20) do
        local task = table.remove(task_queue, 1)
        if type(task) == "function" then
            local ok, err = pcall(task)
            if not ok then
                print("[Helper Core] Task queue error: " .. tostring(err))
            end
        end
    end
end

-- Process scheduled delayed tasks (replaces throwaway lua_threads)
if #scheduled_tasks > 0 then
    local now = os.clock()
    local due = {}
    local pending = {}
    for i = 1, #scheduled_tasks do
        local item = scheduled_tasks[i]
        if item.run_at <= now and #due < 20 then
            due[#due + 1] = item.fn
        else
            pending[#pending + 1] = item
        end
    end
    scheduled_tasks = pending
    for i = 1, #due do
        local ok, err = pcall(due[i])
        if not ok then
            print("[Helper Core] Scheduled task error: " .. tostring(err))
        end
    end
end

-- Process debounced saves safely in main loop
if settings_dirty then
    settings_dirty = false
    saveSettings()
end
if db_dirty then
    db_dirty = false
    saveDatabase()
end
if rules_dirty then
    rules_dirty = false
    saveRules()
end
if corrections_dirty then
    corrections_dirty = false
    saveCorrections()
end
if ad_history_dirty then
    ad_history_dirty = false
    saveAdHistory()
end
if rp_settings_dirty then
    rp_settings_dirty = false
    saveRpSettings()
end
if blacklist_dirty then
    blacklist_dirty = false
    saveBlacklist()
end


-- Periodically refresh online nicks cache from main loop (safe, avoids missing joins/quits)
if not online_nicks_initialized or (os.time() - online_cache_last_refresh) >= 5 then
    refreshOnlineNicksCache()
end

-- Scan chat for contacts (safe from main loop, not from thread)
chatScannerTick()

-- Refresh compact HUD snapshot once per second
local hud_now = os.time()
if hud_now ~= hud_cache.last_update then
    hud_cache.last_update = hud_now
    hud_cache.time_str = os.date("%H:%M:%S", hud_now)
    local m = tonumber(os.date("%M", hud_now)) or 0
    local s = tonumber(os.date("%S", hud_now)) or 0
    local rem_sec = (60 - m) * 60 - s
    if rem_sec == 3600 then rem_sec = 0 end
    hud_cache.payday_str = string.format("%02dм %02dс", math.floor(rem_sec / 60), rem_sec % 60)
    if isSampAvailable() then
        local ok_p, pval = pcall(function()
            local ok_id, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
            if ok_id then return sampGetPlayerPing(myid) end
            return 0
        end)
        if ok_p and type(pval) == "number" then hud_cache.ping = pval end
    end
    if active_waypoint then
        local ok_c, px, py = pcall(getCharCoordinates, PLAYER_PED)
        if ok_c and type(px) == "number" and type(py) == "number" then
            local dist = math.floor(math.sqrt((px - active_waypoint.x)^2 + (py - active_waypoint.y)^2) + 0.5)
            if dist <= 18 then
                local arrived_name = active_waypoint.name
                if sound_enabled[0] then playAlertSound(1057) end
                clearWaypointTarget(true)
                if isSampAvailable() then
                    sampAddChatMessage("[GPS] Вы прибыли к точке: {00FF90}" .. arrived_name, 0x00CCFF)
                end
            else
                hud_cache.wp_text = active_waypoint.name .. " (" .. dist .. "м)"
            end
        else
            hud_cache.wp_text = active_waypoint.name
        end
    else
        hud_cache.wp_text = ""
    end
    if gnews_sched_active and gnews_sched_target_ts then
        local rem = gnews_sched_target_ts - hud_now
        if rem > 0 then
            gnews_sched_hud_str = P3_formatGnewsHud(rem)
            if rem <= 15 and not gnews_sched_warned_15 then
                gnews_sched_warned_15 = true
                playAlertSound(1058)
                if isSampAvailable() then
                    sampAddChatMessage("[GNEWS Таймер] До подачи гос. новостей осталось " .. rem .. " сек!", 0xFFCC00)
                end
            end
        else
            gnews_sched_active = false
            gnews_sched_target_ts = nil
            gnews_sched_warned_15 = false
            gnews_sched_hud_str = ""
            P3.gnews_status = "Волна запущена (" .. (gnews_sched_target_str ~= "" and gnews_sched_target_str or os.date("%H:%M:%S", hud_now)) .. ")"
            gnews_sched_target_str = ""
            if not isModuleEnabled("gnews") then
                P3.gnews_status = "Отменено: модуль GNEWS выключен"
                if isSampAvailable() then
                    sampAddChatMessage("[GNEWS Таймер] Отменено: модуль GNEWS выключен!", 0xFFAA00)
                end
            elseif isSampAvailable() then
                if type(saveCurrentGnewsProfile) == "function" and gnews_loaded_idx == (gnews_settings and gnews_settings.selected) then
                    saveCurrentGnewsProfile()
                end
                local p = gnews_settings and gnews_settings.profiles and gnews_settings.profiles[gnews_settings.selected]
                if p then
                    local l1 = formatGnewsLine(p.tag, p.line1)
                    local l2 = formatGnewsLine(p.tag, p.line2)
                    local l3 = formatGnewsLine(p.tag, p.line3)
                    local lines = {}
                    if l1 ~= "" then lines[#lines + 1] = l1 end
                    if l2 ~= "" then lines[#lines + 1] = l2 end
                    if l3 ~= "" then lines[#lines + 1] = l3 end
                    if #lines > 0 then
                        gnewsPublishLines(lines, gnews_settings.delay or 1500)
                    else
                        sampAddChatMessage("[GNEWS Таймер] Ошибка: строки 1-3 выбранного профиля пусты!", 0xFF5555)
                    end
                end
            end
        end
    else
        gnews_sched_hud_str = ""
    end
    P5_tickSession1s()
    if finance_enabled[0] and isSampAvailable() then
        local ok_m, cur_m = pcall(getPlayerMoney, PLAYER_HANDLE)
        if ok_m and type(cur_m) == "number" then
            if finance_last_money == nil then
                finance_last_money = cur_m
            elseif cur_m ~= finance_last_money then
                local delta = cur_m - finance_last_money
                finance_last_money = cur_m
                if delta > 0 then
                    finance_income = finance_income + delta
                else
                    finance_expense = finance_expense + (-delta)
                end
                local hint = (os.time() - last_finance_hint_time <= 4) and last_finance_hint or ""
                table.insert(finance_log, 1, { time = os.date("%H:%M:%S"), delta = delta, note = hint })
                if #finance_log > 30 then table.remove(finance_log) end
            end
        end
    end
end

-- Process queued player_db changes (safe - not during ImGui render)
if #player_db_queue > 0 then
    for i = 1, #player_db_queue do
        local item = player_db_queue[i]
        if item.sender == "__CLEAR__" then
            player_db = {}
        else
            player_db[item.sender] = {
                phone = item.phone,
                time = os.date("%Y-%m-%d %H:%M:%S"),
                ad = item.ad or ""
            }
        end
    end
    player_db_queue = {}
    saveDatabase()
end

-- Process queued last_called changes (safe - not during ImGui render)
if #last_called_queue > 0 then
    for i = 1, #last_called_queue do
        local item = last_called_queue[i]
        if item.nick == "__CLEAR__" then
            last_called = {}
        else
            last_called[item.nick] = item.time
        end
    end
    last_called_queue = {}
    saveSettings()
end

-- Process queued AutoEdit dialog open (safe - not during ImGui render, avoids race with InputText)
if ae_open_queue then
    local q = ae_open_queue
    ae_open_queue = nil
    ae_dialog_id = q.dialog_id
    ae_original_text = encodeCp1251Safe(q.original)
    ae_formatted_text = encodeCp1251Safe(q.formatted)
    safeStrCopy(ae_input_buf, encodeCp1251Safe(q.formatted), ffi.sizeof(ae_input_buf))
    ae_last_buf_snapshot = ffi.string(ae_input_buf)
    if mm_auto_send[0] then
        ae_autosend_deadline = os.clock() + (mm_send_delay[0] / 1000.0)
    else
        ae_autosend_deadline = nil
    end
    ae_active[0] = true
    ae_focus = true
    ae_ignore_enter = 30  -- ignore stale Enter from /edit chat command (~0.5s)
    ae_enter_was_down = true  -- Enter was just pressed (for /edit), wait for release
    ae_esc_was_down = true  -- Esc may be held from chat, wait for release
end

-- Клавиша F11
if wasKeyPressed(0x7A) and not sampIsChatInputActive() and not sampIsDialogActive() then
show_main_window[0] = not show_main_window[0]
end

-- Меню взаимодействия по прицелу (ПКМ + X)
if target_menu_enabled[0] and not cam_active and not (type(isPauseMenuActive) == "function" and isPauseMenuActive()) and not sampIsChatInputActive() and not sampIsDialogActive() and wasKeyPressed(getTargetMenuVk and getTargetMenuVk() or 0x58) then
    local ok_t, valid, ped = pcall(getCharPlayerIsTargeting, PLAYER_HANDLE)
    if ok_t and valid and ped and doesCharExist(ped) then
        local ok_p, res_p, pid = pcall(sampGetPlayerIdByCharHandle, ped)
        if ok_p and res_p and type(pid) == "number" and pid >= 0 then
            local ok_n, tnick = pcall(sampGetPlayerNickname, pid)
            if ok_n and type(tnick) == "string" and tnick ~= "" then
                target_menu_id = pid
                target_menu_nick = tnick
                target_menu_phone = (player_db[tnick] and player_db[tnick].phone) and tostring(player_db[tnick].phone) or ""
                target_menu_show[0] = true
            end
        end
    end
end

local frame_paused = (type(isPauseMenuActive) == "function" and isPauseMenuActive())
local want_txt_input, want_mouse_input = P1_getImguiInputState()

-- Быстрое меню на СКМ (или переназначенную клавишу)
local wheel_vk = getWheelMenuVk()
if wheel_menu_enabled[0] and not frame_paused and not cam_active and not sampIsChatInputActive() and not sampIsDialogActive() and not isKeyDown(0x02) and not want_txt_input and (wheel_vk ~= 0x04 or not want_mouse_input) then
    if wasKeyPressed(wheel_vk) then
        P2_toggleWheelMenu()
    end
end

-- Авто-стробы при включении сирены
P2_tickSirenAutoStrobe()
if cam_active then P5_tickFreeCam() end
if session_track_enabled[0] then P5_pollSessionActivity() end

-- Клавиша J для стробоскопов в машине (только для водителя при включённом модуле)
if wasKeyPressed(0x4A) and isModuleEnabled("vehicle_visuals") and not frame_paused and not cam_active and not want_txt_input and isCharInAnyCar(PLAYER_PED) and not sampIsChatInputActive() and not sampIsDialogActive() then -- J
    local j_car = storeCarCharIsInNoSave(PLAYER_PED)
    local j_drv = (j_car ~= nil and doesVehicleExist(j_car)) and ((type(getDriverOfCar) ~= "function") or (getDriverOfCar(j_car) == PLAYER_PED))
    if j_drv then
        P2.siren_started_strobe = false
        strobe_enabled[0] = not strobe_enabled[0]
        strobe_active = strobe_enabled[0]
        if strobe_active and not strobe_worker_running then
            queueTask(function() if not strobe_worker_running then lua_thread.create(strobeWorker) end end)
        end
        sampAddChatMessage("[Helper] Стробоскопы: " .. (strobe_enabled[0] and "{00FF00}ВКЛ{FFFFFF} (выкл - J)" or "{FF0000}ВЫКЛ"), 0xFFFFFF)
    end
end

-- Клавиша N для смены режима стробоскопов (только если включены, модуль активен и за рулём)
if wasKeyPressed(0x4E) and isModuleEnabled("vehicle_visuals") and not frame_paused and not cam_active and not want_txt_input and isCharInAnyCar(PLAYER_PED) and strobe_enabled[0] and not sampIsChatInputActive() and not sampIsDialogActive() then -- N
    local n_car = storeCarCharIsInNoSave(PLAYER_PED)
    local n_drv = (n_car ~= nil and doesVehicleExist(n_car)) and ((type(getDriverOfCar) ~= "function") or (getDriverOfCar(n_car) == PLAYER_PED))
    if n_drv then
        local strobe_mode_names = {
            [0]="Обе вместе", [1]="Попеременно", [2]="Гирлянда (по одной)", [3]="Двойной лево/право",
            [4]="Быстрый оба (3х)", [5]="Очень быстрый оба (5х)", [6]="Полицейский 1",
            [7]="Полицейский 2 (3+3+обе)", [8]="Полицейский 3 (быстрый)", [9]="SOS (Морзе)",
            [10]="Волна", [11]="Импульс (вспышка+пауза)", [12]="Двойная гирлянда",
            [13]="Тройная вспышка (спец)", [14]="Зигзаг", [15]="Энергичный (2х2)",
            [16]="Маяк (медленный)", [17]="Перекрёстный", [18]="Каскад (нарастающий)",
        }
        strobe_mode[0] = (strobe_mode[0] + 1) % 19
        requestSaveSettings()
        local mname = strobe_mode_names[strobe_mode[0]] or ("#" .. strobe_mode[0])
        sampAddChatMessage("[Helper] Стробоскоп режим: {00FF00}" .. mname .. " {FFFFFF}(N - следующий)", 0xFFFFFF)
    end
end

-- Исправление раскладки в открытом чате (F2 по умолчанию)
if layout_fix_enabled[0] and sampIsChatInputActive() and not sampIsDialogActive() and wasKeyPressed(layout_fix_key[0]) then
    local ok_g, cur_txt = pcall(sampGetChatInputText)
    if ok_g and type(cur_txt) == "string" and cur_txt ~= "" then
        local conv = convertLayoutText(cur_txt)
        if conv ~= cur_txt then
            pcall(sampSetChatInputText, conv)
        end
    end
end

-- Обработка биндов клавиш (с модификаторами и поддержкой РП-движка)
if not cam_active and not frame_paused and not want_txt_input and not sampIsChatInputActive() and not sampIsDialogActive() then
local alt_down = isKeyDown(0x12)
local ctrl_down = isKeyDown(0x11)
local shift_down = isKeyDown(0x10)
for _, bind in ipairs(keybinds) do
if bind.enabled then
    local m = bind.mod or 0
    local mod_ok = (m == 0 and not alt_down and not ctrl_down and not shift_down)
        or (m == 1 and alt_down and not ctrl_down)
        or (m == 2 and ctrl_down and not alt_down)
        or (m == 3 and shift_down and not alt_down and not ctrl_down)
    if mod_ok and wasKeyPressed(bind.key) then
        if bind.action_type == "rp" then
            local ch = rp_settings.set[bind.rp_chapter or 1]
            local rp = ch and ch[bind.rp_index or 1]
            if rp and type(rp.text) == "string" and rp.text ~= "" then
                playRp(rp.text, false)
            end
        elseif bind.command and bind.command ~= "" then
            sampSendChat(bind.command)
        end
        break
    end
end
end
end

end

while true do
wait(0)
local ok_frame, err_frame = pcall(mainFrameTick)
if not ok_frame then
    local now_err = os.clock()
    if (now_err - (main_last_err_ts or 0)) >= 5.0 then
        main_last_err_ts = now_err
        print("[Helper Core] main loop error: " .. tostring(err_frame))
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
        if #aad_history == 0 or aad_history[#aad_history] ~= encodeCp1251Safe(text) then
            table.insert(aad_history, encodeCp1251Safe(text))  -- CP1251 -> UTF-8 for display
            if #aad_history > 20 then
                table.remove(aad_history, 1)
            end
            saveSettings()
        end
    end
end

-- ===== ФИЛЬТР ЧАТА, АВТО-ПЕРЕНОС, /rec И /hist =====
function parseCsvTerms(cp1251_str)
    local terms = {}
    if type(cp1251_str) ~= "string" or cp1251_str == "" then return terms end
    for item in string.gmatch(cp1251_str, "[^,;]+") do
        local t = cp1251_lower(item):gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then terms[#terms + 1] = t end
    end
    return terms
end

function splitChatIntoChunks(prefix, body, max_len, max_chunks)
    prefix = type(prefix) == "string" and prefix or ""
    body = type(body) == "string" and body or ""
    max_len = math.max(60, math.min(125, tonumber(max_len) or 108))
    max_chunks = math.max(2, math.floor(tonumber(max_chunks) or 4))
    if #prefix + #body <= max_len then return nil end

    local words = {}
    for w in string.gmatch(body, "%S+") do
        words[#words + 1] = w
    end
    if #words == 0 then return nil end

    local parts = {}
    local idx = 1
    while idx <= #words and #parts < max_chunks do
        local is_first = (#parts == 0)
        local is_last_slot = (#parts == max_chunks - 1)
        local reserve = (is_first or is_last_slot) and 3 or 6
        local cap = math.max(12, max_len - #prefix - reserve)
        local cur = ""
        while idx <= #words do
            local w = words[idx]
            if cur == "" then
                if #w <= cap then
                    cur = w
                    idx = idx + 1
                else
                    cur = w:sub(1, cap)
                    words[idx] = w:sub(cap + 1)
                    break
                end
            elseif #cur + 1 + #w <= cap then
                cur = cur .. " " .. w
                idx = idx + 1
            else
                break
            end
        end
        if cur ~= "" then
            parts[#parts + 1] = cur
        else
            break
        end
    end

    if idx <= #words and #parts > 0 then
        local tail_cap = math.max(12, math.max(max_len, 140) - #prefix - 6)
        local last = parts[#parts]
        while idx <= #words do
            local w = words[idx]
            if #last + 1 + #w <= tail_cap then
                last = last .. " " .. w
                idx = idx + 1
            else
                break
            end
        end
        parts[#parts] = last
    end

    if #parts <= 1 then return nil end
    local truncated_tail = (idx <= #words)
    local result = {}
    for i = 1, #parts do
        if i == 1 then
            result[i] = prefix .. parts[i] .. "..."
        elseif i < #parts then
            result[i] = prefix .. "..." .. parts[i] .. "..."
        else
            result[i] = prefix .. "..." .. parts[i] .. (truncated_tail and "..." or "")
        end
    end
    return result
end

function evaluateChatFilter(clean_msg, clean_lower, sender, phone)
    if type(clean_msg) ~= "string" or clean_msg == "" then return true end
    if clean_msg:match("^%[Helper[%s%]]") then return true end
    clean_lower = clean_lower or cp1251_lower(clean_msg)

    -- 1. Чёрный список слов/фраз (проверяется ДО триггеров и звуков)
    local blacklist = parseCsvTerms(decodeUtf8Safe(ffi.string(cf_blacklist_buf)))
    for _, term in ipairs(blacklist) do
        if clean_lower:find(term, 1, true) then
            cf_hidden_count = cf_hidden_count + 1
            return false
        end
    end

    -- 2. Фильтрация чужих /ad с белым списком ключевых слов
    if cf_hide_ads[0] then
        local is_ad = (sender ~= nil and phone ~= nil)
            or clean_lower:find("объявление:", 1, true)
            or (clean_lower:find("отправил ", 1, true) and clean_lower:find("(тел.", 1, true))
            or (clean_lower:find("проверил ", 1, true) and clean_lower:find("сми", 1, true))
        if is_ad then
            local is_own = (my_cached_nick ~= "" and sender and cp1251_lower(sender) == cp1251_lower(my_cached_nick))
            if not is_own then
                local whitelist = parseCsvTerms(decodeUtf8Safe(ffi.string(cf_ad_whitelist_buf)))
                local whitelisted = false
                for _, term in ipairs(whitelist) do
                    if clean_lower:find(term, 1, true) then
                        whitelisted = true
                        break
                    end
                end
                if whitelisted then
                    local now_c = os.clock()
                    if sound_enabled[0] and (now_c - cf_last_trigger_sound) >= 3.0 then
                        cf_last_trigger_sound = now_c
                        playAlertSound(1057)
                    end
                    return true
                end
                cf_hidden_count = cf_hidden_count + 1
                return false
            end
        end
    end

    -- 3. Скрытие эфиров (/t, /u), когда сам не ведёшь эфир
    if cf_hide_efir[0] and not efir_active then
        if clean_lower:find("[радио", 1, true)
            or clean_lower:find("[тв", 1, true)
            or clean_lower:find("радиостанция", 1, true)
            or clean_lower:find("прямой эфир", 1, true)
            or clean_lower:find("[эфир]", 1, true)
            or clean_lower:find("телецентр |", 1, true)
            or clean_lower:find("ls-fm |", 1, true)
            or clean_lower:find("sf-fm |", 1, true)
            or clean_lower:find("lv-fm |", 1, true) then
            cf_hidden_count = cf_hidden_count + 1
            return false
        end
    end

    -- 4. Скрытие системных подсказок и рекламы сервера
    if cf_hide_system[0] then
        if clean_lower:find("advance-rp.ru", 1, true)
            or clean_lower:find("vk.com/advance", 1, true)
            or clean_lower:find("подсказка:", 1, true)
            or clean_lower:find("донат-услуг", 1, true)
            or clean_lower:find("форум проекта", 1, true)
            or clean_lower:find("привяжите аккаунт", 1, true) then
            cf_hidden_count = cf_hidden_count + 1
            return false
        end
    end

    -- 5. Триггеры уведомлений (звук с анти-спам КД 4 сек, только для видимых строк)
    local triggers = parseCsvTerms(decodeUtf8Safe(ffi.string(cf_trigger_buf)))
    for _, term in ipairs(triggers) do
        if clean_lower:find(term, 1, true) then
            local now_c = os.clock()
            if (now_c - cf_last_trigger_sound) >= 4.0 then
                cf_last_trigger_sound = now_c
                if sound_enabled[0] then playAlertSound(1057) end
            end
            break
        end
    end

    return true
end

function cmdReconnect(arg)
    local raw = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local low = cp1251_lower(raw)
    if low == "cancel" or low == "0" or low == "stop" or low == "отмена" then
        if reconnect_pending then
            reconnect_pending = false
            pcall(sampSetGamestate, 1)
            sampAddChatMessage("[Helper] Ожидание реконнекта отменено.", 0xFFAA00)
        else
            sampAddChatMessage("[Helper] Активного реконнекта нет.", 0xCECECE)
        end
        return
    end
    if reconnect_pending then
        sampAddChatMessage("[Helper] Реконнект уже выполняется (отмена: /rec 0).", 0xFFAA00)
        return
    end
    local delay_sec = math.max(1, math.min(30, math.floor(tonumber(raw) or 2)))
    if cam_active and type(P5_exitFreeCam) == "function" then pcall(P5_exitFreeCam) end
    if lect_running and type(P3_stopLecturer) == "function" then pcall(P3_stopLecturer) end
    if gnews_active and type(stopGnews) == "function" then pcall(stopGnews) end
    call_active = false
    call_worker_running = false
    aad_active = false
    aad_next_scheduled = false
    if db_dirty then db_dirty = false; pcall(saveDatabase) end
    if rules_dirty then rules_dirty = false; pcall(saveRules) end
    if corrections_dirty then corrections_dirty = false; pcall(saveCorrections) end
    if ad_history_dirty then ad_history_dirty = false; pcall(saveAdHistory) end
    if rp_settings_dirty then rp_settings_dirty = false; pcall(saveRpSettings) end
    if blacklist_dirty then blacklist_dirty = false; pcall(saveBlacklist) end
    if settings_dirty then settings_dirty = false; pcall(saveSettings) end
    if P3 and P3.lecturer_loaded and type(P3_saveLecturer) == "function" then pcall(P3_saveLecturer) end
    if P4_codex and type(P4_saveCodex) == "function" then pcall(P4_saveCodex) end
    if P6_loc_registry and type(P6_saveLocations) == "function" then pcall(P6_saveLocations) end

    reconnect_pending = true
    sampAddChatMessage("[Helper] Реконнект через " .. delay_sec .. " сек... (отмена: /rec 0)", 0x00CCFF)
    lua_thread.create(function()
        pcall(sampDisconnectWithReason, false)
        local deadline = os.clock() + delay_sec
        while reconnect_pending and os.clock() < deadline do
            wait(100)
        end
        if not reconnect_pending then return end
        reconnect_pending = false
        pcall(sampSetGamestate, 1)
    end)
end

function cmdFastHistory(arg)
    local q = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then
        sampAddChatMessage("[Helper] Использование: /hist [ID или ник]", 0xFFAA00)
        return
    end
    local target_nick = nil
    if q:match("^%d+$") then
        local pid = tonumber(q)
        if pid then
            if pid == my_cached_id and my_cached_nick ~= "" then
                target_nick = my_cached_nick
            elseif sampIsPlayerConnected(pid) then
                target_nick = sampGetPlayerNickname(pid)
            elseif online_ids_to_nicks and online_ids_to_nicks[pid] then
                target_nick = online_ids_to_nicks[pid]
            else
                local ok_my, res_my, cur_myid = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
                if ok_my and res_my and type(cur_myid) == "number" and cur_myid == pid then
                    my_cached_id = cur_myid
                    local ok_mn, mn = pcall(sampGetPlayerNickname, cur_myid)
                    if ok_mn and type(mn) == "string" and mn ~= "" then
                        my_cached_nick = mn
                        target_nick = mn
                    end
                end
            end
            if not target_nick or target_nick == "" then
                sampAddChatMessage("[Helper] Игрок ID:" .. q .. " не найден онлайн.", 0xFF5555)
                return
            end
        end
    else
        local q_low = cp1251_lower(q)
        if online_nicks_to_ids then
            if online_nicks_to_ids[q_low] then
                target_nick = online_nicks_to_ids[q_low].nick
            else
                for k_low, info in pairs(online_nicks_to_ids) do
                    if k_low:find(q_low, 1, true) then
                        target_nick = info.nick
                        break
                    end
                end
            end
        end
        if not target_nick or target_nick == "" then
            target_nick = q
        end
    end
    if isSampAvailable() and target_nick and target_nick ~= "" then
        sampSendChat("/history " .. target_nick)
    end
end

-- Авто-перенос длинных строк обычного чата
function sampev.onSendChat(message)
    if rp_sending_internal or type(message) ~= "string" then return true end
    if not isModuleEnabled("qol_tools") or not line_wrap_enabled[0] then return true end
    if message:sub(1, 1) == "/" then return true end
    local chunks = splitChatIntoChunks("", message, line_wrap_limit[0])
    if chunks and #chunks > 1 then
        for i = 2, #chunks do
            local part = chunks[i]
            scheduleTask(line_wrap_delay[0] * (i - 1), function()
                if isSampAvailable() then
                    rp_sending_internal = true
                    pcall(sampSendChat, part)
                    rp_sending_internal = false
                end
            end)
        end
        return { chunks[1] }
    end
    return true
end

-- Перехват серверных команд для авто-РП отыгровок (SAMP отправляет /команды через RPC SendCommand)
function sampev.onSendCommand(command)
    if rp_sending_internal then return true end
    local cmd, rest = command:match("^/(%w+)%s*(.*)")
    if not cmd then return true end
    cmd = cmd:lower()

    if cmd == "find" and isModuleEnabled("smi_tools") and find_ui_enabled[0] then
        find_wait_until = os.clock() + 5.0
    end

    if efir_active and (cmd == "t" or cmd == "u") and rest ~= "" then
        efir_stats.lines = efir_stats.lines + 1
    end

    local cd_dur = cmd_cooldown_durations[cmd]
    if cd_dur then
        if (cmd ~= "ad" and cmd ~= "gnews") or rest ~= "" then
            cmd_cooldowns[cmd] = os.time() + cd_dur
        end
    end

    if (cmd == "c" or cmd == "call") and rest:match("^%d+$") and rest ~= "60" and rest ~= "060" then
        markPhoneCalled(rest)
    end

    local modified_cmd = nil
    local rtag_prefix = ""
    if ((cmd == "r" and radio_tag_r[0]) or (cmd == "f" and radio_tag_f[0]) or (cmd == "d" and radio_tag_d[0])) and rest ~= "" then
        local trimmed = rest:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" and not trimmed:match("^%(%(") then
            if radio_auto_punct[0] then
                trimmed = cp1251_upper(trimmed:sub(1, 1)) .. trimmed:sub(2)
                local last_ch = trimmed:sub(-1)
                if last_ch ~= "." and last_ch ~= "!" and last_ch ~= "?" and last_ch ~= ")" then
                    trimmed = trimmed .. "."
                end
            end
            local rtag = decodeUtf8Safe(ffi.string(radio_tag_text)):gsub("^%s+", ""):gsub("%s+$", "")
            if rtag ~= "" then
                rtag_prefix = rtag .. " "
                if trimmed:sub(1, #rtag) ~= rtag then
                    trimmed = rtag .. " " .. trimmed
                end
            end
            rest = trimmed
            modified_cmd = "/" .. cmd .. " " .. trimmed
        end
    end

    local wrap_cmds = { me = true, ["do"] = true, r = true, f = true, d = true, s = true, w = true, t = true, u = true }
    if isModuleEnabled("qol_tools") and line_wrap_enabled[0] and wrap_cmds[cmd] and rest ~= "" then
        local wrap_prefix = "/" .. cmd .. " "
        local wrap_body = rest
        if cmd == "w" then
            local w_id, w_body = rest:match("^(%S+)%s+(.+)")
            if w_id and w_body then
                wrap_prefix = "/w " .. w_id .. " "
                wrap_body = w_body
            else
                wrap_body = ""
            end
        elseif cmd == "r" or cmd == "f" or cmd == "d" then
            if rtag_prefix ~= "" and rest:sub(1, #rtag_prefix) == rtag_prefix then
                wrap_prefix = "/" .. cmd .. " " .. rtag_prefix
                wrap_body = rest:sub(#rtag_prefix + 1)
            end
        end
        if wrap_body ~= "" then
            local chunks = splitChatIntoChunks(wrap_prefix, wrap_body, line_wrap_limit[0])
            if chunks and #chunks > 1 then
                for i = 2, #chunks do
                    local part = chunks[i]
                    scheduleTask(line_wrap_delay[0] * (i - 1), function()
                        if isSampAvailable() then
                            rp_sending_internal = true
                            pcall(sampSendChat, part)
                            rp_sending_internal = false
                        end
                    end)
                end
                return { chunks[1] }
            end
        end
    end

    if modified_cmd then
        return { modified_cmd }
    end

    if isModuleEnabled("auto_rp") and not call_worker_running then
        local rp_line = nil
        if (cmd == "call" or cmd == "c") and rp_phone_enabled[0] then
            if rest == "60" or rest == "060" then
                rp_line = "/me " .. rpVerb("взглянул", "взглянула") .. " на наручные часы"
            elseif rest ~= "" then
                rp_line = "/me " .. rpVerb("достал", "достала") .. " телефон и " .. rpVerb("набрал", "набрала") .. " номер " .. rest
            end
        elseif (cmd == "h" or cmd == "hangup") and rp_phone_enabled[0] then
            rp_line = "/me " .. rpVerb("нажал", "нажала") .. " кнопку сброса и " .. rpVerb("убрал", "убрала") .. " телефон в карман"
        elseif cmd == "mask" and rp_mask_enabled[0] then
            rp_line = "/me " .. rpVerb("натянул", "натянула") .. " маску на лицо"
        elseif cmd == "healme" and rp_heal_enabled[0] then
            rp_line = "/me " .. rpVerb("достал", "достала") .. " аптечку и " .. rpVerb("принял", "приняла") .. " необходимые лекарства"
        elseif cmd == "drugs" and rp_heal_enabled[0] then
            rp_line = "/me " .. rpVerb("достал", "достала") .. " пакетик и " .. rpVerb("употребил", "употребила") .. " содержимое"
        elseif cmd == "e" and rp_engine_enabled[0] then
            if isCharInAnyCar(PLAYER_PED) then
                local car = storeCarCharIsInNoSave(PLAYER_PED)
                if car and doesVehicleExist(car) and isCarEngineOn(car) then
                    rp_line = "/me " .. rpVerb("заглушил", "заглушила") .. " двигатель"
                else
                    rp_line = "/me " .. rpVerb("завёл", "завела") .. " двигатель"
                end
            else
                rp_line = "/me " .. rpVerb("завёл", "завела") .. " двигатель"
            end
        elseif cmd == "pass" and rp_docs_enabled[0] then
            rp_line = "/me " .. rpVerb("достал", "достала") .. " паспорт из кармана и " .. rpVerb("показал", "показала") .. " его"
        elseif cmd == "lic" and rp_docs_enabled[0] then
            rp_line = "/me " .. rpVerb("достал", "достала") .. " папку с лицензиями и " .. rpVerb("показал", "показала") .. " её"
        elseif cmd == "med" and rp_docs_enabled[0] then
            rp_line = "/me " .. rpVerb("достал", "достала") .. " медицинскую карту и " .. rpVerb("показал", "показала") .. " её"
        elseif cmd == "cuff" and p4_autorp_enabled[0] and isModuleEnabled("faction_tools") and rest ~= "" then
            rp_line = "/me " .. rpVerb("снял", "сняла") .. " с пояса наручники и " .. rpVerb("защёлкнул", "защёлкнула") .. " их на запястьях задержанного"
        elseif cmd == "uncuff" and p4_autorp_enabled[0] and isModuleEnabled("faction_tools") and rest ~= "" then
            rp_line = "/me " .. rpVerb("достал", "достала") .. " ключ и " .. rpVerb("снял", "сняла") .. " наручники с задержанного"
        elseif cmd == "search" and p4_autorp_enabled[0] and isModuleEnabled("faction_tools") and rest ~= "" then
            rp_line = "/me " .. rpVerb("надел", "надела") .. " перчатки и " .. rpVerb("провёл", "провела") .. " первичный обыск"
        elseif cmd == "putpl" and p4_autorp_enabled[0] and isModuleEnabled("faction_tools") and rest ~= "" then
            rp_line = "/me " .. rpVerb("открыл", "открыла") .. " дверь патрульного авто и " .. rpVerb("посадил", "посадила") .. " задержанного в салон"
        elseif cmd == "arrest" and p4_autorp_enabled[0] and isModuleEnabled("faction_tools") and rest ~= "" then
            rp_line = "/me " .. rpVerb("сопроводил", "сопроводила") .. " задержанного к камере КПЗ и " .. rpVerb("передал", "передала") .. " его дежурному"
        elseif cmd == "medhelp" and p4_autorp_enabled[0] and isModuleEnabled("faction_tools") and rest ~= "" then
            rp_line = "/me " .. rpVerb("провёл", "провела") .. " осмотр пациента и " .. rpVerb("назначил", "назначила") .. " лечение"
        elseif cmd == "heal" and p4_autorp_enabled[0] and isModuleEnabled("faction_tools") and rest ~= "" then
            rp_line = "/me " .. rpVerb("достал", "достала") .. " медикаменты из сумки и " .. rpVerb("передал", "передала") .. " их пациенту"
        end

        if rp_line then
            local orig_cmd = command
            scheduleTask(0, function()
                if isSampAvailable() then
                    rp_sending_internal = true
                    pcall(sampSendChat, rp_line)
                    rp_sending_internal = false
                end
            end)
            scheduleTask(250, function()
                if isSampAvailable() then
                    rp_sending_internal = true
                    pcall(sampSendChat, orig_cmd)
                    rp_sending_internal = false
                end
            end)
            return false
        end
    end
    return true
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
    local clean_msg = text:gsub("{%x+}", "")
    local clean_trimmed = clean_msg:gsub("^%s+", ""):gsub("%s+$", "")
    local clean_lower = cp1251_lower(clean_trimmed)
    if isModuleEnabled("qol_tools") and chat_filter_enabled[0] then
        if evaluateChatFilter(clean_trimmed, clean_lower, sender, phone) == false then
            return false
        end
    end
    if clean_trimmed ~= "" then
        table.insert(chat_log_history, 1, { time = os.date("%H:%M:%S"), text = clean_trimmed })
        if #chat_log_history > 300 then table.remove(chat_log_history) end
    end
    if finance_enabled[0] and clean_lower ~= "" then
        if clean_lower:find("зарплат", 1, true) or clean_lower:find("payday", 1, true)
            or clean_lower:find("штраф", 1, true) or clean_lower:find("продал", 1, true)
            or clean_lower:find("купил", 1, true) or clean_lower:find("передал", 1, true)
            or clean_lower:find("налог", 1, true) or clean_lower:find("выигр", 1, true)
            or clean_lower:find("проигр", 1, true) or clean_lower:find("банкомат", 1, true) then
            last_finance_hint = clean_trimmed:sub(1, 56)
            last_finance_hint_time = os.time()
        end
    end

    local sms_nick, sms_phone = clean_msg:match("SMS:.-Отправитель:%s*([A-Za-z0-9_]+)%s*%[т%.%s*(%d+)%]")
    if not sms_nick or not sms_phone then
        sms_nick, sms_phone = clean_msg:match("SMS:.-Отправитель:%s*([A-Za-z0-9_]+).-%(тел%.%s*(%d+)%)")
    end
    if not sms_nick or not sms_phone then
        sms_nick, sms_phone = clean_msg:match("SMS:.-([A-Za-z0-9_]+)%s*%[т%.%s*(%d+)%]")
    end
    if sms_nick and sms_phone then
        last_sms_nick = sms_nick
        last_sms_phone = sms_phone
        last_sms_time = os.time()
        if sound_sms[0] then playAlertSound(1057) end
        local sms_body = clean_msg:match("SMS:%s*(.-)%s*|%s*Отправитель:")
            or clean_msg:match("SMS:%s*(.-)%s*Отправитель:")
        if quiz_round_active and quiz_winner_nick == "" and sms_body and quiz_expected_answer ~= "" then
            if isQuizAnswerMatch(sms_body, quiz_expected_answer) then
                quiz_round_active = false
                quiz_winner_nick = sms_nick
                quiz_winner_phone = sms_phone
                quiz_winner_text = sms_body:gsub("^%s+", ""):gsub("%s+$", "")
                if quiz_auto_point[0] then
                    quiz_scores[sms_nick] = (quiz_scores[sms_nick] or 0) + 1
                end
                playAlertSound(1058)
                local w_nick_cp = sms_nick
                local w_phone_cp = sms_phone
                local w_ans_cp = quiz_winner_text
                local w_pts = quiz_scores[sms_nick] or 0
                queueTask(function()
                    if isSampAvailable() then
                        sampAddChatMessage("[Викторина] Первый верный ответ: {00FF90}" .. w_nick_cp .. " [т." .. w_phone_cp .. "]{FFFFFF} -> " .. w_ans_cp .. " (Очков: " .. w_pts .. ")", 0x00CCFF)
                    end
                end)
            end
        end
        if isModuleEnabled("autocall_db") and not player_db[sms_nick] then
            table.insert(player_db_queue, {sender = sms_nick, phone = sms_phone})
        end
    else
        local caller_nick = clean_msg:match("[Вв]ам звонит%s+([A-Za-z0-9_]+)")
        if caller_nick and player_db[caller_nick] and player_db[caller_nick].phone then
            last_sms_nick = caller_nick
            last_sms_phone = tostring(player_db[caller_nick].phone)
            last_sms_time = os.time()
        end
    end

    local text_utf8 = encodeCp1251Safe(text)

    if sender and phone then
        local sender_cp = sender
        local phone_cp = phone
        queueTask(function()
            if not isSampAvailable() then return end
            local result, my_id = sampGetPlayerIdByCharHandle(PLAYER_PED)
            local my_name = result and sampGetPlayerNickname(my_id) or ""

            if sender_cp == my_name then
                if sound_ad_pub[0] then playAlertSound(1057) end
                if aad_active and aad_text ~= "" and not aad_next_scheduled then
                    aad_next_scheduled = true
                    sampAddChatMessage("[Helper] Объявление опубликовано. Следующая подача через " .. (aad_delay[0]/1000) .. " сек...", 0x00FFFF)
                    scheduleTask(aad_delay[0], function()
                        aad_next_scheduled = false
                        if aad_active and aad_text ~= "" and isSampAvailable() then
                            sendAdCommand(aad_text)
                        end
                    end)
                end
            elseif isModuleEnabled("autocall_db") then
                table.insert(player_db_queue, {sender = sender_cp, phone = phone_cp})
                sampAddChatMessage("[Helper DB] Новый контакт: " .. sender_cp .. " (Тел: " .. phone_cp .. ")", 0x00FF90)
            end
        end)
    end
    -- АВТО-ОТЫГРОВКИ ОТ СОБЫТИЙ СЕРВЕРА (модуль auto_rp)
    -- Отключены во время обзвона чтобы не плодить сообщения
    if isModuleEnabled("auto_rp") and not call_worker_running then
        local lower = cp1251_lower(text)
        local now_t = os.clock()
        local function canTriggerRpEvent(key)
            if rp_event_cooldowns[key] and (now_t - rp_event_cooldowns[key]) < 3.0 then
                return false
            end
            rp_event_cooldowns[key] = now_t
            return true
        end

        if rp_phone_enabled[0] and (lower:find("вам звонит", 1, true) or lower:find("входящий вызов", 1, true) or lower:find("входящий звонок", 1, true)) then
            if canTriggerRpEvent("incoming_call") then
                sendChatSequence({
                    { delay_ms = 200, msg = "/me " .. rpVerb("достал", "достала") .. " мобильный телефон из кармана" },
                    { delay_ms = 600, msg = "/me " .. rpVerb("посмотрел", "посмотрела") .. " на экран телефона, " .. rpVerb("увидел", "увидела") .. " входящий вызов" },
                    { delay_ms = 400, msg = "/do Телефон в руке, экран подсвечен входящим вызовом" },
                })
            end
        elseif rp_phone_enabled[0] and (lower:find("звонок завершен", 1, true) or lower:find("звонок завершён", 1, true) or lower:find("вы сбросили", 1, true) or lower:find("разговор окончен", 1, true) or lower:find("собеседник сбросил", 1, true)) then
            if canTriggerRpEvent("call_end") then
                sendChatSequence({
                    { delay_ms = 200, msg = "/me " .. rpVerb("нажал", "нажала") .. " кнопку сброса на телефоне" },
                    { delay_ms = 500, msg = "/me " .. rpVerb("убрал", "убрала") .. " мобильный телефон в карман" },
                })
            end
        elseif rp_phone_enabled[0] and (lower:find("sms:", 1, true) or lower:find("смс:", 1, true) or lower:find("вам пришло сообщение", 1, true) or lower:find("новое сообщение", 1, true)) then
            if canTriggerRpEvent("sms_recv") then
                sendChatSequence({
                    { delay_ms = 300, msg = "/me " .. rpVerb("достал", "достала") .. " мобильный телефон из кармана" },
                    { delay_ms = 500, msg = "/me " .. rpVerb("прочитал", "прочитала") .. " сообщение на экране телефона" },
                    { delay_ms = 800, msg = "/me " .. rpVerb("убрал", "убрала") .. " мобильный телефон в карман" },
                })
            end
        elseif rp_heal_enabled[0] and (lower:find("вы арестованы", 1, true) or lower:find("посажен в кпз", 1, true) or lower:find("отправлен в камеру", 1, true)) then
            if canTriggerRpEvent("arrested") then
                sendChatSequence({
                    { delay_ms = 500, msg = "/me " .. rpVerb("опустил", "опустила") .. " голову, принимая своё положение" },
                    { delay_ms = 600, msg = "/do Выражение лица — подавленное" },
                })
            end
        elseif rp_heal_enabled[0] and (lower:find("вы вылечены", 1, true) or lower:find("здоровие восстановлено", 1, true) or lower:find("здоровье восстановлено", 1, true)) then
            if canTriggerRpEvent("healed") then
                sendChatSequence({
                    { delay_ms = 300, msg = "/me облегчённо " .. rpVerb("выдохнул", "выдохнула") .. ", почувствовав облегчение" },
                    { delay_ms = 400, msg = "/do Самочувствие улучшилось" },
                })
            end
        end
    end

    -- Упоминание моего ника в чате
    if sound_mention[0] and my_cached_nick ~= "" and not clean_msg:match("^%[Helper[%s%]]") and not sms_nick then
        local my_low = cp1251_lower(my_cached_nick)
        local first_n = my_cached_nick:match("^([^_]+)")
        local first_low = first_n and cp1251_lower(first_n) or ""
        local is_self_sender = clean_lower:find(my_low .. "%[", 1, false) ~= nil
        if not is_self_sender then
            local mentioned = clean_lower:find(my_low, 1, true) ~= nil
                or (#first_low >= 4 and clean_lower:find(first_low, 1, true) ~= nil)
            if mentioned and (os.clock() - mention_last_sound_time) >= 5.0 then
                mention_last_sound_time = os.clock()
                playAlertSound(1057)
            end
        end
    end

    -- Лифт занят — сбрасываем ожидание
    if tvlift_active and text:find("Лифт занят", 1, true) then
        tvlift_active = false
        tvlift_target_item = nil
    end

    -- Эфир-статистика: подсчёт SMS и входящих звонков (строки /t /u считаются в onSendCommand)
    if efir_active then
        local elower = cp1251_lower(text)
        if elower:find("sms", 1, true) or elower:find("смс", 1, true) then
            efir_stats.sms = efir_stats.sms + 1
        end
        if elower:find("звонит в студию", 1, true) or elower:find("дозвонился", 1, true)
            or elower:find("входящий звонок", 1, true) or elower:find("входящий вызов", 1, true)
            or elower:find("вам звонит", 1, true) then
            efir_stats.calls = efir_stats.calls + 1
            if sound_efir_call[0] then playAlertSound(1057) end
            if auto_answer_enabled[0] then
                local answer = decodeUtf8Safe(ffi.string(auto_answer_text))
                local ans_lower = cp1251_lower(answer)
                local now_aa = os.clock()
                if answer ~= "" and not elower:find(ans_lower, 1, true) and (now_aa - auto_answer_last_time) >= 8.0 then
                    auto_answer_last_time = now_aa
                    scheduleTask(500, function()
                        if isSampAvailable() then
                            sampSendChat("/t " .. answer)
                        end
                    end)
                end
            end
        end
    end

end


-- Event handlers for maintaining online nicks cache
-- SAMP.Lua signature: onPlayerJoin(playerId, color, isNpc, nickname)
function sampev.onPlayerJoin(playerId, color, isNpc, nickname)
    if type(nickname) == "string" and nickname ~= "" then
        if playerId ~= my_cached_id then
            online_nicks_cache[nickname] = true
            online_ids_to_nicks[playerId] = nickname
            local low_nick = cp1251_lower(nickname)
            online_nicks_to_ids[low_nick] = { id = playerId, nick = nickname }
            local fr = friends_list[low_nick]
            if fr and friends_notify[0] then
                sampAddChatMessage("[Helper Друзья] + " .. fr.nick .. " [ID:" .. playerId .. "] зашёл на сервер", 0x00FF90)
                if sound_friend[0] then playAlertSound(1052) end
            end
        end
    end
end

function sampev.onPlayerQuit(playerId, reason)
    local name = online_ids_to_nicks[playerId]
    if name then
        local low_nick = cp1251_lower(name)
        online_nicks_cache[name] = nil
        online_ids_to_nicks[playerId] = nil
        online_nicks_to_ids[low_nick] = nil
        local fr = friends_list[low_nick]
        if fr and friends_notify[0] then
            sampAddChatMessage("[Helper Друзья] - " .. fr.nick .. " вышел с сервера", 0xFFAA00)
        end
    end
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
-- Перехват статистики для playerLogin (РП-движок)
    if rp_reading_stats then
        -- Диалог статистики — читаем и закрываем
        if title:find("Статистика") or title:find("статистика") then
            rp_stats_text = text
            rp_stats_step = "done"
            sampSendDialogResponse(dialogId, 1, -1, "")
            return false
        end
        -- Главное меню — нажимаем кнопку "Статистика" (обычно listitem 0 или 1)
        if title:find("Меню") or title:find("меню") or title:find("Главное") then
            rp_stats_step = "menu"
            -- Ищем пункт "Статистика" в тексте диалога
            local stats_item = -1
            local idx = 0
            for line in string.gmatch(text, "[^\n]+") do
                if line:find("Статистика") or line:find("статистика") or line:find("Стат") then
                    stats_item = idx
                    break
                end
                idx = idx + 1
            end
            if stats_item >= 0 then
                sampSendDialogResponse(dialogId, 1, stats_item, "")
            else
                -- Если не нашли — нажимаем пункт 0 (обычно статистика первая)
                sampSendDialogResponse(dialogId, 1, 0, "")
            end
            rp_stats_step = "stats"
            return false
        end
        -- Диалог лицензий — переходим дальше (на некоторых серверах статистика через лицензии)
        if title:find("Лицензии") or title:find("лицензии") or title:find("Документы") then
            sampSendDialogResponse(dialogId, 1, 0, "")
            rp_stats_step = "stats"
            return false
        end
    end
    -- Перехват диалога лифта ТВ-башни (/tvlf)
    if tvlift_active and tvlift_target_item ~= nil and title:find("Лифт") then
        local item_idx = tvlift_target_item
        tvlift_active = false
        tvlift_target_item = nil
        sampSendDialogResponse(dialogId, 1, item_idx, "")
        return false
    end

    -- Перехват /find: только при явном /find, правильном стиле диалога и реальных строках сотрудников
    if isModuleEnabled("smi_tools") and find_ui_enabled[0] and find_wait_until > os.clock()
       and style ~= 1 and style ~= 3 then
        local title_low = cp1251_lower(title or "")
        local is_gps_or_house = title_low:find("дом", 1, true)
            or title_low:find("gps", 1, true)
            or title_low:find("навигатор", 1, true)
            or title_low:find("бизнес", 1, true)
        local is_find_title = title_low:find("поиск", 1, true)
            or title_low:find("сотрудник", 1, true)
            or title_low:find("организац", 1, true)
            or title_low:find("онлайн", 1, true)
        if is_find_title and not is_gps_or_house then
            local temp_list = {}
            local i = 0
            for line in string.gmatch(text or "", "[^\n]+") do
                local clean_line = line:gsub("{%x+}", "")
                local nick, id, rang, podr, phone = clean_line:match("^%s*%d+%.%s*(.-)%[(%d+)%].-(%d+)%s*[Рр]анг%s*(.-)%s+(%d+)")
                if not nick then
                    nick, id, rang, podr, phone = clean_line:match("([A-Za-z0-9_]+)%[(%d+)%].-(%d+)%s*[Рр]анг%s*(.-)%s*(%d*)")
                end
                if nick then
                    i = i + 1
                    temp_list[i] = {
                        nick = nick:gsub("^%s+", ""):gsub("%s+$", ""),
                        id = tonumber(id) or 0,
                        rang = tonumber(rang) or 0,
                        podr = (podr or ""):gsub("^%s+", ""):gsub("%s+$", ""),
                        phone = phone or ""
                    }
                end
            end
            if #temp_list > 0 then
                find_wait_until = 0
                find_list = temp_list
                find_selected = 0
                find_show[0] = true
                sampAddChatMessage("[Helper] Найдено сотрудников: " .. #find_list, 0x00FF00)
                sampSendDialogResponse(dialogId, 0, -1, "")
                return false
            end
        end
    end

    P5.last_dialog_id = dialogId
    P5.last_dialog_button1 = button1
    if buyfast_enabled[0] and buyfast_armed_until > os.clock() and (os.clock() - buyfast_last_fire) >= 1.5
        and (style == 2 or style == 4 or style == 5) and P5_isBuyButtonText(button1) then
        local bf_idx = P5_matchBuyFastLine(title, text, buyfast_item_idx[0], style)
        if bf_idx ~= nil then
            buyfast_armed_until = 0
            buyfast_last_fire = os.clock()
            sampSendDialogResponse(dialogId, 1, bf_idx, "")
            return false
        end
    end
    if not isModuleEnabled("mm_editor") or not mm_auto_format[0] then
        return
    end
    -- text is CP1251 from SAMP, patterns are CP1251 in this file
    if title:find("публикац") or title:find("объявлен") or text:find("Текст:") then
        local original = text:match("Текст:(.-)Введите") or text:match("Текст:%s*(.+)") or ""
        original = original:gsub("{%x+}", "")
        original = original:gsub("^%s+", ""):gsub("%s+$", "")
        if original ~= "" then
            local fmt_ok, formatted = pcall(formatAdText, original)
            if not fmt_ok then
                sampAddChatMessage("[Helper] formatAdText error: " .. tostring(formatted), 0xFF0000)
                formatted = original
            end
            ae_open_queue = {dialog_id = dialogId, original = original, formatted = formatted}
            return false
        end
    end
end
function sampev.onSendGiveDamage(playerId, damage, weapon, bodypart)
    P4_recordDamage(true, playerId, damage, weapon, bodypart)
end

function sampev.onSendTakeDamage(playerId, damage, weapon, bodypart)
    P4_recordDamage(false, playerId, damage, weapon, bodypart)
end
function sampev.onEnterEditObject(playerObject, objectId)
    if type(isModuleEnabled) == "function" and not isModuleEnabled("location_builder") then return end
    tedit_active = true
    tedit_player_obj = playerObject and true or false
    tedit_obj_id = tonumber(objectId) or -1
    tedit_handle = nil
    tedit_model = 0
    tedit_undo = {}
    tedit_redo = {}
    P6.dirty_edit = false
    P6.edit_start_pos = nil
    P6.edit_start_rot = nil
    P6.edit_pos_ready = false
    P6.last_gizmo_pos = nil
    P6.last_gizmo_rot = nil
    P6.tedit_dismissed = false
    P6_refreshProfileKey()

    local captured_id = tedit_obj_id
    local captured_player_obj = tedit_player_obj
    scheduleTask(50, function()
        if not tedit_active or tedit_obj_id ~= captured_id or tedit_player_obj ~= captured_player_obj then return end
        if type(sampGetObjectHandleBySampId) == "function" and captured_id >= 0 then
            local ok_h, h = pcall(sampGetObjectHandleBySampId, captured_id)
            if ok_h and type(h) == "number" and h > 0 and type(doesObjectExist) == "function" then
                local ok_ex, exists = pcall(doesObjectExist, h)
                if ok_ex and exists then
                    tedit_handle = h
                    if type(getObjectModel) == "function" then
                        local ok_m, mid = pcall(getObjectModel, h)
                        if ok_m and type(mid) == "number" and mid > 0 then
                            tedit_model = mid
                            P6.dup_model = mid
                        end
                    end
                    if type(getObjectCoordinates) == "function" then
                        local ok_c, res_c, px, py, pz = pcall(getObjectCoordinates, h)
                        if ok_c and res_c and type(px) == "number" and type(py) == "number" and type(pz) == "number" then
                            tedit_pos = {x = P6_round4(px), y = P6_round4(py), z = P6_round4(pz)}
                            P6.edit_start_pos = {x = tedit_pos.x, y = tedit_pos.y, z = tedit_pos.z}
                            P6.edit_pos_ready = true
                            P6.last_gizmo_pos = {x = tedit_pos.x, y = tedit_pos.y, z = tedit_pos.z}
                        end
                    end
                    local got_rot = false
                    if type(getObjectQuaternion) == "function" then
                        local ok_q, qx, qy, qz, qw = pcall(getObjectQuaternion, h)
                        if ok_q and type(qx) == "number" and type(qy) == "number" and type(qz) == "number" and type(qw) == "number" then
                            local ex, ey, ez = P6_quatToEuler(qx, qy, qz, qw)
                            tedit_rot = {x = ex, y = ey, z = ez}
                            got_rot = true
                        end
                    end
                    if not got_rot and type(getObjectHeading) == "function" then
                        local ok_hd, hdg = pcall(getObjectHeading, h)
                        if ok_hd and type(hdg) == "number" then
                            tedit_rot = {x = 0.0, y = 0.0, z = P6_normalizeAngle(hdg)}
                            got_rot = true
                        end
                    end
                    if got_rot then
                        P6.edit_start_rot = {x = tedit_rot.x, y = tedit_rot.y, z = tedit_rot.z}
                        P6.last_gizmo_rot = {x = tedit_rot.x, y = tedit_rot.y, z = tedit_rot.z}
                    end
                    P6_syncManualBuffers()
                end
            end
        end
        if tedit_dup_pending then
            if P6.dup_pending_until and os.clock() > P6.dup_pending_until then
                tedit_dup_pending = false
                P6.dup_source = nil
                P6.dup_pending_until = nil
            else
                local dup_src = (type(P6.dup_source) == "table" and type(P6.dup_source.pos) == "table") and P6.dup_source or tedit_clipboard
                if type(dup_src) == "table" and type(dup_src.pos) == "table" then
                    local saved_cb = tedit_clipboard
                    tedit_clipboard = dup_src
                    local has_off = math.abs(tedit_offset.x[0] or 0) > 0.0005 or math.abs(tedit_offset.y[0] or 0) > 0.0005 or math.abs(tedit_offset.z[0] or 0) > 0.0005
                    P6_pasteParams(has_off and "offset" or "all")
                    tedit_clipboard = saved_cb
                    P6.edit_pos_ready = true
                    loc_status_msg = "Параметры дубликата применены к объекту!"
                end
                tedit_dup_pending = false
                P6.dup_source = nil
                P6.dup_pending_until = nil
            end
        end
    end)
end

function sampev.onSendEditObject(playerObject, objectId, response, position, rotation)
    if type(isModuleEnabled) == "function" and not isModuleEnabled("location_builder") then return end
    local ev_player_obj = playerObject and true or false
    local ev_obj_id = tonumber(objectId) or -1
    local same_obj = tedit_active and (tedit_obj_id == ev_obj_id) and (tedit_player_obj == ev_player_obj)
    if response == 2 then
        if same_obj and type(position) == "table" and type(rotation) == "table" then
            local gx = P6_round4(position.x)
            local gy = P6_round4(position.y)
            local gz = P6_round4(position.z)
            local grx = P6_normalizeAngle(rotation.x)
            local gry = P6_normalizeAngle(rotation.y)
            local grz = P6_normalizeAngle(rotation.z)
            if P6.edit_start_pos == nil then
                P6.edit_start_pos = {x = gx, y = gy, z = gz}
            end
            if P6.edit_start_rot == nil then
                P6.edit_start_rot = {x = grx, y = gry, z = grz}
            end
            if not P6.edit_pos_ready or not P6.dirty_edit then
                tedit_pos = {x = gx, y = gy, z = gz}
                tedit_rot = {x = grx, y = gry, z = grz}
                P6.edit_pos_ready = true
                P6.last_gizmo_pos = {x = gx, y = gy, z = gz}
                P6.last_gizmo_rot = {x = grx, y = gry, z = grz}
                P6_syncManualBuffers()
            else
                local ref_p = P6.last_gizmo_pos or P6.edit_start_pos or tedit_pos
                local ref_r = P6.last_gizmo_rot or P6.edit_start_rot or tedit_rot
                local function angDiff(a, b)
                    local d = math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) % 360.0
                    if d > 180.0 then d = 360.0 - d end
                    return d
                end
                local moved = (math.abs(gx - ref_p.x) > 0.01)
                    or (math.abs(gy - ref_p.y) > 0.01)
                    or (math.abs(gz - ref_p.z) > 0.01)
                    or (angDiff(grx, ref_r.x) > 0.01)
                    or (angDiff(gry, ref_r.y) > 0.01)
                    or (angDiff(grz, ref_r.z) > 0.01)
                P6.last_gizmo_pos = {x = gx, y = gy, z = gz}
                P6.last_gizmo_rot = {x = grx, y = gry, z = grz}
                if moved then
                    tedit_pos = {x = gx, y = gy, z = gz}
                    tedit_rot = {x = grx, y = gry, z = grz}
                    P6.dirty_edit = false
                    P6_syncManualBuffers()
                end
            end
        end
        return
    end
    if response == 1 then
        if tedit_model == 0 and type(sampGetObjectHandleBySampId) == "function" and type(getObjectModel) == "function" then
            local ok_h, h = pcall(sampGetObjectHandleBySampId, objectId)
            if ok_h and type(h) == "number" and h > 0 then
                local ok_m, mid = pcall(getObjectModel, h)
                if ok_m and type(mid) == "number" and mid > 0 then
                    tedit_model = mid
                end
            end
        end
        local final_pos, final_rot
        local was_dirty = same_obj and P6.dirty_edit
        if was_dirty then
            final_pos = {x = tedit_pos.x, y = tedit_pos.y, z = tedit_pos.z}
            final_rot = {x = tedit_rot.x, y = tedit_rot.y, z = tedit_rot.z}
            if position ~= nil then
                position.x = final_pos.x
                position.y = final_pos.y
                position.z = final_pos.z
            end
            if rotation ~= nil then
                rotation.x = final_rot.x
                rotation.y = final_rot.y
                rotation.z = final_rot.z
            end
        else
            local px = position and tonumber(position.x) or (tedit_pos.x or 0)
            local py = position and tonumber(position.y) or (tedit_pos.y or 0)
            local pz = position and tonumber(position.z) or (tedit_pos.z or 0)
            local rx = rotation and tonumber(rotation.x) or (tedit_rot.x or 0)
            local ry = rotation and tonumber(rotation.y) or (tedit_rot.y or 0)
            local rz = rotation and tonumber(rotation.z) or (tedit_rot.z or 0)
            final_pos = {x = P6_round4(px), y = P6_round4(py), z = P6_round4(pz)}
            final_rot = {x = P6_normalizeAngle(rx), y = P6_normalizeAngle(ry), z = P6_normalizeAngle(rz)}
        end
        P6_refreshProfileKey()
        P6_recordSavedObject(tedit_model, final_pos, final_rot, objectId)
        if tedit_model > 0 then P6.dup_model = tedit_model end
        tedit_active = false
        tedit_handle = nil
        tedit_undo = {}
        tedit_redo = {}
        P6.dirty_edit = false
        P6.edit_start_pos = nil
        P6.edit_start_rot = nil
        P6.edit_pos_ready = false
        P6.last_gizmo_pos = nil
        P6.last_gizmo_rot = nil
        if was_dirty then
            return {playerObject, objectId, response, position, rotation}
        end
    elseif response == 0 then
        local restore_h = tedit_handle
        local restore_id = ev_obj_id
        local restore_pos = same_obj and P6.edit_start_pos or nil
        local restore_rot = same_obj and P6.edit_start_rot or nil
        local was_dirty = same_obj and P6.dirty_edit
        tedit_active = false
        tedit_handle = nil
        tedit_undo = {}
        tedit_redo = {}
        P6.dirty_edit = false
        P6.edit_start_pos = nil
        P6.edit_start_rot = nil
        P6.edit_pos_ready = false
        P6.last_gizmo_pos = nil
        P6.last_gizmo_rot = nil
        if was_dirty and (type(restore_pos) == "table" or type(restore_rot) == "table") then
            if type(restore_pos) == "table" then
                tedit_pos = {x = restore_pos.x, y = restore_pos.y, z = restore_pos.z}
            end
            if type(restore_rot) == "table" then
                tedit_rot = {x = restore_rot.x, y = restore_rot.y, z = restore_rot.z}
            end
            P6_syncManualBuffers()
            queueTask(function()
                if type(isSampAvailable) ~= "function" or not isSampAvailable() then return end
                local h = restore_h
                if (not h or type(h) ~= "number" or h <= 0) and restore_id >= 0 and type(sampGetObjectHandleBySampId) == "function" then
                    local ok_h, sh = pcall(sampGetObjectHandleBySampId, restore_id)
                    if ok_h and type(sh) == "number" and sh > 0 then h = sh end
                end
                if h and type(h) == "number" and h > 0 and type(doesObjectExist) == "function" then
                    local ok_ex, exists = pcall(doesObjectExist, h)
                    if ok_ex and exists then
                        if type(restore_pos) == "table" and type(setObjectCoordinates) == "function" then
                            pcall(setObjectCoordinates, h, restore_pos.x, restore_pos.y, restore_pos.z)
                        end
                        if type(restore_rot) == "table" and type(setObjectRotation) == "function" then
                            pcall(setObjectRotation, h, restore_rot.x, restore_rot.y, restore_rot.z)
                        end
                    end
                end
            end)
        end
    end
end

function applyLocalSkin(skinId)
lua_thread.create(function()
if skinId >= 0 and skinId <= 311 and skinId ~= 74 then
if isCharInAnyCar(PLAYER_PED) then
    sampAddChatMessage("[Helper] Нельзя менять скин, находясь в транспорте!", 0xFF0000)
    return
end
requestModel(skinId)
loadAllModelsNow()
if isModelAvailable(skinId) then
local charPtr = getCharPointer(PLAYER_PED)
if charPtr and charPtr >= 1 then
-- CPed::SetModel - функция по адресу 0x5E4880
-- void __thiscall SetModel(int thisPtr, int modelId)
ffi.cast("void (__thiscall *)(int, int)", 0x5E4880)(charPtr, skinId)
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
wait(0)
if weather_locked[0] then
local w = weather_id[0]
if w ~= last_w then
last_w = w
if type(forceWeatherNow) == "function" then forceWeatherNow(w) end
end
if memory then memory.write(0xC81320, w, 1, false) end
else
last_w = -1
end
if time_locked[0] then
local h = time_hour[0]
if h ~= last_t then
last_t = h
end
if memory then memory.write(0xB70153, h, 1, false) end
if memory then memory.write(0xB70152, 0, 1, false) end
if memory then memory.write(0xB70158, 0, 4, false) end
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
strobe_sequences = {
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

-- Загружаем bit для прямого доступа к CDamageManager (memory уже загружен наверху через mem_ok/memory)
local has_bit, bit = pcall(require, 'bit')

-- Установить состояние фар через прямую запись в память
-- CAutomobile + 0x5A0 = m_damageManager (CDamageManager)
-- CDamageManager + 0x10 = m_nLightsStatus (uint32, 2 бита на фару)
-- LIGHT_FRONT_LEFT  = bits 0-1 (0 = OK/светит, 2 = damaged/не светит)
-- LIGHT_FRONT_RIGHT = bits 2-3 (0 = OK/светит, 2 = damaged/не светит)
-- LIGHT_REAR_RIGHT  = bits 4-5
-- LIGHT_REAR_LEFT   = bits 6-7
local NON_AUTO_MODELS = {
    [448]=true,[461]=true,[462]=true,[463]=true,[468]=true,[471]=true,[481]=true,
    [509]=true,[510]=true,[521]=true,[522]=true,[523]=true,[581]=true,[586]=true,
    [537]=true,[538]=true,[569]=true,[570]=true,[590]=true
}
local function isAutomobileVehicle(car)
    local ok, model = pcall(getCarModel, car)
    if not ok or type(model) ~= "number" then return false end
    if NON_AUTO_MODELS[model] then return false end
    if type(isThisModelACar) == "function" then
        return isThisModelACar(model)
    end
    return not ((type(isThisModelABoat) == "function" and isThisModelABoat(model))
        or (type(isThisModelAHeli) == "function" and isThisModelAHeli(model))
        or (type(isThisModelAPlane) == "function" and isThisModelAPlane(model)))
end

function setLightState(car, leftOn, rightOn)
    if not mem_ok or not memory or not has_bit or not isAutomobileVehicle(car) then
        setCarLightsOn(car, leftOn or rightOn)
        return
    end
    local carPtr = getCarPointer(car)
    if not carPtr or carPtr == 0 then
        setCarLightsOn(car, leftOn or rightOn)
        return
    end
    local lightAddr = carPtr + 0x5B0
    local lightVal = memory.read(lightAddr, 4, true) or 0
    lightVal = bit.band(lightVal, 0xFFFFFFF0)
    if not leftOn then lightVal = bit.bor(lightVal, 0x02) end
    if not rightOn then lightVal = bit.bor(lightVal, 0x08) end
    memory.write(lightAddr, lightVal, 4, true)
end

-- Восстановить все фары (все целые = 0)
function restoreAllLights(car)
    if mem_ok and memory and has_bit and isAutomobileVehicle(car) then
        local carPtr = getCarPointer(car)
        if carPtr and carPtr ~= 0 then
            local lightAddr = carPtr + 0x5B0
            local lightVal = memory.read(lightAddr, 4, false) or 0
            lightVal = bit.band(lightVal, 0xFFFFFF00)
            memory.write(lightAddr, lightVal, 4, false)
            return
        end
    end
end

function strobeWorker()
    if strobe_worker_running then return end
    strobe_worker_running = true
    local step = 1
    local last_car = nil
    local lights_initialized = false

    while strobe_active and strobe_enabled[0] do
        if isCharInAnyCar(PLAYER_PED) then
            local car = storeCarCharIsInNoSave(PLAYER_PED)
            local is_driver = false
            if car and doesVehicleExist(car) then
                if type(getDriverOfCar) == "function" then
                    local ok_drv, drv = pcall(getDriverOfCar, car)
                    is_driver = ok_drv and (drv == PLAYER_PED)
                else
                    is_driver = true
                end
            end
            if is_driver then
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
    strobe_enabled[0] = false
    strobe_worker_running = false

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
function P1_isCarEngineOn(car)
    if not mem_ok or not memory then
        return true
    end
    local carPtr = getCarPointer(car)
    if not carPtr or carPtr == 0 then
        return true
    end
    -- CVehicle + 0x428 (m_nVehicleFlags bit 4 = 0x10 = bEngineOn)
    local val_428 = memory.read(carPtr + 0x428, 1, false) or 0
    if has_bit and bit then
        return bit.band(val_428, 0x10) ~= 0
    end
    return (math.floor(val_428 / 16) % 2) == 1
end

function cruiseControlWorker()
    local cruise_speed = 0
    local c_pressed = false
    local w_pressed = false
    local s_pressed = false
    local gas_on = false
    local last_speed_for_crash = 0
    local crash_cooldown = 0
    local sport_ramp = 0
    local classic_ramp = 0
    local turn_release_until = 0
    while true do
        local mod_on = isModuleEnabled("vehicle_visuals")
        if mod_on and isCharInAnyCar(PLAYER_PED) then
            local car = storeCarCharIsInNoSave(PLAYER_PED)
            local is_driver = false
            if car and doesVehicleExist(car) and isAutomobileVehicle(car) then
                if type(getDriverOfCar) == "function" then
                    local ok_drv, drv = pcall(getDriverOfCar, car)
                    is_driver = ok_drv and (drv == PLAYER_PED)
                else
                    is_driver = true
                end
            end

            if is_driver then
                local now = os.clock()
                local ui_open = sampIsDialogActive() or sampIsChatInputActive()
                local steering = (not ui_open) and (isKeyDown(0x41) or isKeyDown(0x44))
                local braking = (not ui_open) and (isKeyDown(0x53) or isKeyDown(0x20))
                if steering then
                    turn_release_until = now + 0.15
                end
                local in_turn = turbo_turn_assist[0] and (steering or now < turn_release_until)
                local in_air = isCarInAirProper(car)
                local current_speed = getCarSpeed(car) or 0
                local engine_on = P1_isCarEngineOn(car)

                -- Включение/выключение круиза на C
                if isKeyDown(0x43) and not ui_open then
                    if not c_pressed then
                        c_pressed = true
                        if not cruise_active then
                            if current_speed > 0.1 then
                                cruise_speed = current_speed
                                cruise_active = true
                                classic_ramp = 0
                                local mode = (turbo_cruise_enabled[0] and turbo_boost_mode[0] == 2) and "Turbo" or "Normal"
                                sampAddChatMessage("[Helper] Cruise ON [" .. mode .. "] W=+5 S=-5 C=off", 0x00FF00)
                            else
                                sampAddChatMessage("[Helper] Cruise: too slow", 0xFFAA00)
                            end
                        else
                            cruise_active = false
                            classic_ramp = 0
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

                local sport_applied = false
                local classic_turbo_tick = false

                -- 1) Спорт-кнопка (режимы 0 = Alt+W, 1 = Shift+W)
                if turbo_cruise_enabled[0] and (turbo_boost_mode[0] == 0 or turbo_boost_mode[0] == 1) then
                    local boost_vk = (turbo_boost_mode[0] == 0) and 0x12 or 0xA0
                    local want_boost = (not ui_open) and isKeyDown(boost_vk) and isKeyDown(0x57)
                    if want_boost and not braking and not in_air and engine_on and current_speed >= 3.0 then
                        if in_turn then
                            sport_ramp = 0
                            sport_boost_active = false
                        elseif current_speed < turbo_max_speed[0] then
                            sport_ramp = math.min(1.0, sport_ramp + 0.12)
                            local step = (0.25 + turbo_power[0] * 0.28) * sport_ramp
                            local new_spd = math.min(turbo_max_speed[0], current_speed + step)
                            setCarForwardSpeed(car, new_spd)
                            sport_boost_active = true
                            sport_applied = true
                        else
                            sport_boost_active = true
                        end
                    else
                        sport_ramp = 0
                        sport_boost_active = false
                    end
                else
                    sport_ramp = 0
                    sport_boost_active = false
                end

                -- 2) Активный круиз (классический турбо или обычный газ)
                if cruise_active then
                    local is_classic_turbo = turbo_cruise_enabled[0] and (turbo_boost_mode[0] == 2)

                    if isKeyDown(0x57) and not ui_open then
                        if not w_pressed then
                            w_pressed = true
                            cruise_speed = math.min(90, cruise_speed + 5)
                            sampAddChatMessage("[Helper] Cruise: " .. string.format("%.0f", cruise_speed) .. " (+5)", 0x00FFFF)
                        end
                        wait(150)
                    else
                        w_pressed = false
                    end

                    if isKeyDown(0x53) and not ui_open then
                        if not s_pressed then
                            s_pressed = true
                            cruise_speed = math.max(5, cruise_speed - 5)
                            sampAddChatMessage("[Helper] Cruise: " .. string.format("%.0f", cruise_speed) .. " (-5)", 0x00FFFF)
                        end
                        wait(150)
                    else
                        s_pressed = false
                    end

                    if is_classic_turbo then
                        if gas_on then
                            setGameKeyState(16, 0)
                            gas_on = false
                        end
                        if last_speed_for_crash > 10 and current_speed < last_speed_for_crash * 0.6 then
                            crash_cooldown = 75
                            classic_ramp = 0
                        end
                        last_speed_for_crash = current_speed

                        if crash_cooldown > 0 then
                            crash_cooldown = crash_cooldown - 1
                            classic_ramp = 0
                        elseif engine_on and not in_air and not braking and not in_turn and current_speed >= 2.0 and current_speed < cruise_speed then
                            classic_ramp = math.min(1.0, classic_ramp + 0.12)
                            local step = (0.25 + turbo_power[0] * 0.28) * classic_ramp
                            local new_speed = math.min(cruise_speed, current_speed + step)
                            setCarForwardSpeed(car, new_speed)
                            classic_turbo_tick = true
                        elseif braking or in_turn then
                            classic_ramp = 0
                        end
                        wait(20)
                    elseif not sport_applied then
                        if in_air or not engine_on or braking then
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
                        wait(0)
                    else
                        if gas_on then
                            setGameKeyState(16, 0)
                            gas_on = false
                        end
                        wait(20)
                    end
                else
                    last_speed_for_crash = 0
                    crash_cooldown = 0
                    classic_ramp = 0
                    if gas_on then
                        setGameKeyState(16, 0)
                        gas_on = false
                    end
                    wait(sport_applied and 20 or 35)
                end
            else
                cruise_active = false
                sport_boost_active = false
                sport_ramp = 0
                classic_ramp = 0
                if gas_on then
                    setGameKeyState(16, 0)
                    gas_on = false
                end
                wait(200)
            end
        else
            cruise_active = false
            sport_boost_active = false
            sport_ramp = 0
            classic_ramp = 0
            if gas_on then
                setGameKeyState(16, 0)
                gas_on = false
            end
            wait(500)
        end
    end
end

local function formatWeaponPutAway(info)
    if not info then return nil end
    if info.kind == "pistol" then
        return "/me " .. rpVerb("поставил", "поставила") .. ' пистолет "' .. info.name .. '" на предохранитель и ' .. rpVerb("убрал", "убрала") .. " в кобуру"
    elseif info.kind == "sheath" then
        return "/me " .. rpVerb("убрал", "убрала") .. " " .. info.name .. " в ножны на поясе"
    elseif info.kind == "belt" then
        return "/me " .. rpVerb("повесил", "повесила") .. " " .. info.name .. " на пояс"
    elseif info.kind == "pocket" then
        return "/me " .. rpVerb("убрал", "убрала") .. " " .. info.name .. " в карман"
    elseif info.kind == "neck" then
        return "/me " .. rpVerb("повесил", "повесила") .. " " .. info.name .. " на шею"
    elseif info.kind == "back" then
        return "/me " .. rpVerb("убрал", "убрала") .. " " .. info.name .. " за спину"
    elseif info.kind == "shotgun" then
        return "/me " .. rpVerb("повесил", "повесила") .. ' дробовик "' .. info.name .. '" на плечо'
    elseif info.kind == "smg" then
        return "/me " .. rpVerb("повесил", "повесила") .. ' ПП "' .. info.name .. '" на плечо'
    else
        return "/me " .. rpVerb("повесил", "повесила") .. " " .. info.name .. " на плечо"
    end
end

local function formatWeaponDraw(info)
    if not info then return nil end
    if info.kind == "pistol" then
        return "/me резким движением " .. rpVerb("выхватил", "выхватила") .. ' пистолет "' .. info.name .. '" из кобуры'
    elseif info.kind == "sheath" then
        return "/me " .. rpVerb("вынул", "вынула") .. " " .. info.name .. " из ножен на поясе"
    elseif info.kind == "belt" then
        return "/me " .. rpVerb("снял", "сняла") .. " " .. info.name .. " с пояса"
    elseif info.kind == "pocket" then
        return "/me " .. rpVerb("достал", "достала") .. " " .. info.name .. " из кармана"
    elseif info.kind == "neck" then
        return "/me " .. rpVerb("взял", "взяла") .. " " .. info.name .. " в руки"
    elseif info.kind == "back" then
        return "/me " .. rpVerb("достал", "достала") .. " " .. info.name .. " из-за спины"
    elseif info.kind == "shotgun" then
        return "/me " .. rpVerb("снял", "сняла") .. ' дробовик "' .. info.name .. '" с плеча'
    elseif info.kind == "smg" then
        return "/me " .. rpVerb("снял", "сняла") .. ' ПП "' .. info.name .. '" с плеча и ' .. rpVerb("снял", "сняла") .. " с предохранителя"
    else
        return "/me " .. rpVerb("снял", "сняла") .. " " .. info.name .. " с плеча и " .. rpVerb("снял", "сняла") .. " с предохранителя"
    end
end

function weaponTrackWorker()
    local last_announced_weapon = nil
    local pending_weapon = nil
    local pending_since = 0

    while true do
        wait(100)
        pcall(function()
            if not isSampAvailable() or not doesCharExist(PLAYER_PED) then
                last_announced_weapon = nil
                pending_weapon = nil
                rp_current_weapon_id = 0
                return
            end

            local cur_w = getCurrentCharWeapon(PLAYER_PED) or 0
            rp_current_weapon_id = cur_w

            if last_announced_weapon == nil
                or not isModuleEnabled("auto_rp")
                or not rp_weapons_enabled[0]
                or isCharInAnyCar(PLAYER_PED)
                or sampIsDialogActive()
                or sampIsChatInputActive() then
                last_announced_weapon = cur_w
                pending_weapon = nil
                return
            end

            if cur_w ~= last_announced_weapon then
                if pending_weapon ~= cur_w then
                    pending_weapon = cur_w
                    pending_since = os.clock()
                elseif (os.clock() - pending_since) >= 0.35 then
                    local prev_info = weapon_info[last_announced_weapon]
                    local next_info = weapon_info[cur_w]
                    local steps = {}
                    if prev_info then
                        steps[#steps + 1] = { delay_ms = 0, msg = formatWeaponPutAway(prev_info) }
                    end
                    if next_info then
                        steps[#steps + 1] = { delay_ms = (#steps > 0 and 450 or 0), msg = formatWeaponDraw(next_info) }
                    end
                    last_announced_weapon = cur_w
                    pending_weapon = nil
                    if #steps > 0 then
                        sendChatSequence(steps)
                    end
                end
            else
                pending_weapon = nil
            end
        end)
    end
end

-- АСИНХРОННЫЙ ОБЗВОН ОНЛАЙН ИГРОКОВ
function onlineCallWorker(online_list)
local called_count = 0
local limit = max_calls_session[0]

if not isSampAvailable() then
call_active = false
call_worker_running = false
return
end

-- Защита: если с прошлой сессии (или краша) остался незавершённый звонок,
-- сбрасываем его перед стартом, чтобы не было конфликта состояний
sampSendChat("/h")
wait(300)

for i = #online_list, 2, -1 do
local j = math.random(i)
online_list[i], online_list[j] = online_list[j], online_list[i]
end

for _, target in ipairs(online_list) do
if not call_active or called_count >= limit or not isSampAvailable() then break end

local can_call = canCallNick(target.nick)
if can_call then
call_current_nick = target.nick
call_current_phone = target.phone

sampAddChatMessage("[Helper] Обзвон: Звоним " .. target.nick .. " (Тел: " .. target.phone .. ") [" .. (called_count+1) .. "/" .. limit .. "]", 0xFFFF00)
wait(500)

-- /c is same as /call on Advance RP
sampSendChat("/c " .. target.phone)

table.insert(last_called_queue, {nick = target.nick, time = os.time()})
called_count = called_count + 1

local timeLeft = call_delay[0]
while timeLeft > 0 and call_active do
wait(100)
timeLeft = timeLeft - 100
end

-- Вешаем трубку в любом случае: и если время вышло само, и если сессию
-- остановили вручную кнопкой "Стоп" посреди звонка (раньше в этом случае
-- /h не отправлялся, и звонок оставался висеть на сервере)
if isSampAvailable() then
sampSendChat("/h")
end

if not call_active then break end

wait(1000)
end
end

call_active = false
call_worker_running = false
call_current_nick = ""
call_current_phone = ""
requestSaveSettings()
sampAddChatMessage("[Helper] Сессия обзвона завершена. Обзвонили игроков: " .. called_count, 0x00FF00)
end

-- ==========================================
-- ОТРИСОВКА ИНТЕРФЕЙСА (MIMGUI)
-- ==========================================
function applyCustomStyle()
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
local renderer = imgui.GetRenderer()
if renderer and renderer.EndFrame then jit.off(renderer.EndFrame, true) end
end)

imgui.OnFrame(
function() return show_main_window[0] end,
function(player)
imgui.SetNextWindowSize(imgui.ImVec2(820, 560), imgui.Cond.FirstUseEver)
imgui.Begin(WINDOW_TITLE, show_main_window, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

-- Верхняя панель: Переключатель серверов
imgui.TextUnformatted(u8"Выбор текущего сервера:")
imgui.SameLine()
imgui.PushItemWidth(150)
if imgui.BeginCombo("##ServerSelector", server_names[current_server_idx[0] + 1]) then
for idx, srv_name in ipairs(server_names) do
local is_selected = (current_server_idx[0] == idx - 1)
if imgui.Selectable(srv_name, is_selected) then
current_server_idx[0] = idx - 1
requestSaveSettings() queueTask(function() sampAddChatMessage("[Helper] Сервер изменен на: " .. decodeUtf8Safe(server_names[current_server_idx[0] + 1]), 0x00FF90) end)
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
imgui.TextUnformatted(u8" Доступные Модули")
imgui.Separator()
imgui.Spacing()

for i, mod in ipairs(modules) do
local is_selected = (active_module_idx == i)
if imgui.Selectable(mod.name, is_selected, 0, imgui.ImVec2(0, 32)) then
if i ~= active_module_idx then
pending_module_idx = i
module_switch_blank_frames = 2
if modules[i] and modules[i].id == "mm_editor" then
mm_ui_page = 1
mm_pending_ui_page = nil
mm_ui_last_logged_page = -1
end
end
end

imgui.SameLine(180)
if mod.enabled then
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0, 1))
imgui.TextUnformatted("[ON]")
imgui.PopStyleColor()
else
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted("[OFF]")
imgui.PopStyleColor()
end
end
imgui.EndChild()

imgui.SameLine()

-- Правая колонка: Настройки модуля
local content_window_flags = 0
local content_module = modules[active_module_idx]
if content_module and content_module.id == "mm_editor" then
content_window_flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
end
imgui.BeginChild("content_panel", imgui.ImVec2(0, 0), true, content_window_flags)
if pending_module_idx then
imgui.SetScrollY(0)
imgui.TextUnformatted("Switching module safely...")
module_switch_blank_frames = module_switch_blank_frames - 1
if module_switch_blank_frames <= 0 then
active_module_idx = pending_module_idx
pending_module_idx = nil
end
else
local active_module = modules[active_module_idx]
if active_module then
imgui.TextUnformatted(active_module.name)
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
imgui.PushTextWrapPos(0)
imgui.TextUnformatted(active_module.description)
imgui.PopTextWrapPos()
imgui.PopStyleColor()
imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if active_module.id ~= "commands_guide" then
static_module_enabled = static_module_enabled or imgui.new.bool(false)
static_module_enabled[0] = active_module.enabled
if imgui.Checkbox(u8"Активировать модуль", static_module_enabled) then
active_module.enabled = static_module_enabled[0]
requestSaveSettings()
if active_module.onToggle then
active_module.onToggle(static_module_enabled[0])
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
imgui.TextUnformatted(u8"Выберите модуль слева.")
end
end
imgui.EndChild()
imgui.End()
end
)


-- РП-ДВИЖОК: Окно выбора отыгровки (для /mmact)
imgui.OnFrame(
    function() return rp_show_window[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(500, 400), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"РП-отыгровки (цель: " .. encodeCp1251Safe(userTarget.name) .. ")###rp_act_win", rp_show_window, imgui.WindowFlags.NoCollapse)

        local chapters = {u8"Общие", u8"Мои отыгровки", u8"Для цели"}
        imgui.TextUnformatted(u8"Глава:")
        imgui.SameLine()
        imgui.PushItemWidth(200)
        if imgui.ComboStr("##rp_chapter", rp_settings.setList, table.concat(chapters, "\0") .. "\0") then
            rp_settings.selected = 1
        end
        imgui.PopItemWidth()
        imgui.Separator()

        local chapter = rp_settings.setList[0] + 1
        local list = rp_settings.set[chapter] or {}

        imgui.BeginChild("##rp_list", imgui.ImVec2(0, 250), true)
        if #list > 0 then
            for i, rp in ipairs(list) do
                local name = (rp.name and rp.name ~= "") and encodeCp1251Safe(rp.name) or u8"(без названия)"
                if imgui.Selectable(name .. "##rp_sel_" .. i, rp_settings.selected == i) then
                    rp_settings.selected = i
                end
            end
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
            imgui.TextUnformatted(u8"Нет отыгровок. Откройте /rpeditor для создания.")
            imgui.PopStyleColor()
        end
        imgui.EndChild()

        if #list > 0 and rp_settings.selected <= #list then
            if imgui.Button(u8"Запустить", imgui.ImVec2(120, 30)) then
                local rpTxt = list[rp_settings.selected].text
                queueTask(function() playRp(rpTxt, false) end)
                rp_show_window[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"Тест", imgui.ImVec2(80, 30)) then
                local rpTxt = list[rp_settings.selected].text
                queueTask(function() playRp(rpTxt, true) end)
            end
            imgui.SameLine()
        end
        if imgui.Button(u8"Закрыть", imgui.ImVec2(80, 30)) then
            rp_show_window[0] = false
        end
        imgui.End()
    end
)

-- РП-ДВИЖОК: Окно редактора отыгровок (/rpeditor)
imgui.OnFrame(
    function() return rp_show_edit[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(700, 550), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"РП-Редактор отыгровок", rp_show_edit, imgui.WindowFlags.NoCollapse)

        local chapters = {u8"Общие", u8"Мои отыгровки", u8"Для цели"}
        imgui.TextUnformatted(u8"Глава:")
        imgui.SameLine()
        imgui.PushItemWidth(200)
        if imgui.ComboStr("##rp_edit_chapter", rp_settings.setList, table.concat(chapters, "\0") .. "\0") then
            rp_edit_index = 0
            rp_settings.selected = 1
        end
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(u8"+ Добавить") then
            local chapter = rp_settings.setList[0] + 1
            if not rp_settings.set[chapter] then rp_settings.set[chapter] = {} end
            table.insert(rp_settings.set[chapter], {name = "", text = ""})
            rp_edit_index = #rp_settings.set[chapter]
            safeStrCopy(rp_settings.temp.name, "", ffi.sizeof(rp_settings.temp.name))
            safeStrCopy(rp_settings.temp.text, "", ffi.sizeof(rp_settings.temp.text))
            requestSaveRpSettings()
        end

        imgui.Separator()

        local chapter = rp_settings.setList[0] + 1
        local list = rp_settings.set[chapter] or {}

        imgui.BeginChild("##rp_edit_list", imgui.ImVec2(200, 350), true)
        for i, rp in ipairs(list) do
            local name = (rp.name and rp.name ~= "") and encodeCp1251Safe(rp.name) or u8"(без названия #" .. i .. ")"
            if imgui.Selectable(name .. "##rp_ed_" .. i, rp_edit_index == i) then
                rp_edit_index = i
                safeStrCopy(rp_settings.temp.name, encodeCp1251Safe(rp.name or ""), ffi.sizeof(rp_settings.temp.name))
                safeStrCopy(rp_settings.temp.text, encodeCp1251Safe(rp.text or ""), ffi.sizeof(rp_settings.temp.text))
            end
        end
        imgui.EndChild()

        imgui.SameLine()
        imgui.BeginChild("##rp_edit_form", imgui.ImVec2(0, 350), true)
        if rp_edit_index > 0 and list[rp_edit_index] then
            imgui.TextUnformatted(u8"Название:")
            imgui.PushItemWidth(-1)
            imgui.InputText("##rp_name", rp_settings.temp.name, ffi.sizeof(rp_settings.temp.name))
            imgui.PopItemWidth()

            imgui.TextUnformatted(u8"Текст отыгровки:")
            imgui.PushItemWidth(-1)
            imgui.InputTextMultiline("##rp_text", rp_settings.temp.text, ffi.sizeof(rp_settings.temp.text), imgui.ImVec2(0, 200))
            imgui.PopItemWidth()

            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.8, 0.5, 1))

            imgui.TextUnformatted(u8"Теги: <myFio> <myName> <myRang> <myPodr> <myId> <myPhone> <time> <date>")

            imgui.PopStyleColor()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.8, 0.5, 1))
            imgui.TextUnformatted(u8"Цель: <tFio> <tName> <tNick> <tId>")
            imgui.PopStyleColor()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))
            imgui.TextUnformatted(u8"Пауза: <1000> (мс) или <0> (до /mmnext)")
            imgui.PopStyleColor()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))
            imgui.TextUnformatted(u8"Рандом: r:{вариант1}{вариант2}:r")
            imgui.PopStyleColor()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))
            imgui.TextUnformatted(u8"Ввод: #input: | Выбор: #list: {a}{b} | Подстановка: {w}")
            imgui.PopStyleColor()

            if imgui.Button(u8"Сохранить", imgui.ImVec2(100, 30)) then
                list[rp_edit_index].name = decodeUtf8Safe(ffi.string(rp_settings.temp.name))
                list[rp_edit_index].text = decodeUtf8Safe(ffi.string(rp_settings.temp.text))
                requestSaveRpSettings() queueTask(function() sampAddChatMessage("[Helper] Отыгровка сохранена", 0x00FF00) end)
            end
            imgui.SameLine()
            if imgui.Button(u8"Удалить", imgui.ImVec2(100, 30)) then
                table.remove(list, rp_edit_index)
                rp_edit_index = 0
                safeStrCopy(rp_settings.temp.name, "", ffi.sizeof(rp_settings.temp.name))
                safeStrCopy(rp_settings.temp.text, "", ffi.sizeof(rp_settings.temp.text))
                requestSaveRpSettings()
            end
            imgui.SameLine()
            if imgui.Button(u8"Тест", imgui.ImVec2(80, 30)) then
                local testText = decodeUtf8Safe(ffi.string(rp_settings.temp.text))
                queueTask(function() playRp(testText, true) end)
            end
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
            imgui.TextUnformatted(u8"Выберите отыгровку слева или нажмите '+ Добавить'")
            imgui.PopStyleColor()
        end
        imgui.EndChild()

        imgui.Separator()
        if imgui.Button(u8"Закрыть", imgui.ImVec2(100, 30)) then
            rp_show_edit[0] = false
        end
        imgui.End()
    end
)

-- РП-ДВИЖОК: Окно ввода/выбора (для #input: и #list:)
imgui.OnFrame(
    function() return rp_settings.window.is == 1 end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(400, 0), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"РП-Ввод", nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.AlwaysAutoResize)

        if rp_settings.window.type == 1 then
            imgui.TextUnformatted(u8"Введите текст:")
            imgui.PushItemWidth(-1)
            if imgui.InputText("##rp_input_w", rp_settings.window.buf, ffi.sizeof(rp_settings.window.buf), imgui.InputTextFlags.EnterReturnsTrue) then
                rp_settings.window.is = 2
            end
            imgui.PopItemWidth()
            imgui.SameLine()
            if imgui.Button(u8"OK", imgui.ImVec2(80, 30)) then
                rp_settings.window.is = 2
            end
        elseif rp_settings.window.type == 2 then
            imgui.TextUnformatted(u8"Выберите вариант:")
            for i, item in ipairs(rp_settings.window.list) do
                if imgui.Button(encodeCp1251Safe(item) .. "##rp_opt_" .. i, imgui.ImVec2(-1, 0)) then
                    rp_settings.window.select = i
                    rp_settings.window.is = 2
                end
            end
        end
        imgui.Spacing()
        if imgui.Button(u8"Отмена##rp_input_cancel", imgui.ImVec2(100, 26)) then
            queueTask(stopRp)
        end
        imgui.End()
    end
)


-- СМИ: Окно /find (список найденных сотрудников)
imgui.OnFrame(
    function() return find_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(600, 400), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"Поиск сотрудников (/find)", find_show, imgui.WindowFlags.NoCollapse)

        if #find_list > 0 then
            imgui.Columns(5, nil, false)
            imgui.SetColumnWidth(0, 35)
            imgui.SetColumnWidth(1, 180)
            imgui.SetColumnWidth(2, 55)
            imgui.SetColumnWidth(3, 55)
            imgui.TextUnformatted(u8"№")
            imgui.NextColumn()
            imgui.TextUnformatted(u8"Ник")
            imgui.NextColumn()
            imgui.TextUnformatted(u8"ID")
            imgui.NextColumn()
            imgui.TextUnformatted(u8"Ранг")
            imgui.NextColumn()
            imgui.TextUnformatted(u8"Подразделение")
            imgui.NextColumn()
            imgui.Separator()

            for i, p in ipairs(find_list) do
                if imgui.Selectable(tostring(i), find_selected == i, imgui.SelectableFlags.SpanAllColumns) then
                    find_selected = i
                end
                imgui.NextColumn()
                imgui.TextUnformatted(encodeCp1251Safe(p.nick))
                imgui.NextColumn()
                imgui.TextUnformatted(tostring(p.id))
                imgui.NextColumn()
                imgui.TextUnformatted(tostring(p.rang))
                imgui.NextColumn()
                imgui.TextUnformatted(encodeCp1251Safe(p.podr))
                imgui.NextColumn()
            end
            imgui.Columns(1)
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
            imgui.TextUnformatted(u8"Список пуст. Используйте /find")
            imgui.PopStyleColor()
        end

        imgui.Separator()
        if find_selected > 0 and find_list[find_selected] then
            local p = find_list[find_selected]
            if imgui.Button(u8"Позвонить", imgui.ImVec2(100, 30)) then
                local phone = p.phone
                queueTask(function() sampSendChat("/call " .. phone) end)
            end
            imgui.SameLine()
            if imgui.Button(u8"В ЧС", imgui.ImVec2(80, 30)) then
                local nick = p.nick
                queueTask(function() addBlacklistNick(nick, "Из /find") end)
            end
            imgui.SameLine()
            if imgui.Button(u8"mmact", imgui.ImVec2(80, 30)) then
                local pid = tostring(p.id)
                queueTask(function() cmdAct(pid) end)
            end
        end
        imgui.SameLine()
        if imgui.Button(u8"Закрыть", imgui.ImVec2(80, 30)) then
            find_show[0] = false
        end
        imgui.End()
    end
)

-- СМИ: Окно чёрного списка
imgui.OnFrame(
    function() return blacklist_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(500, 400), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"Чёрный список СМИ", blacklist_show, imgui.WindowFlags.NoCollapse)

        local count = 0
        for nick, data in pairs(blacklist_data) do
            count = count + 1
        end
        imgui.TextUnformatted(u8"Всего в списке: " .. count)
        imgui.Separator()

        imgui.BeginChild("##bl_list", imgui.ImVec2(0, 280), true)
        for nick, data in pairs(blacklist_data) do
            imgui.PushIDStr("bl_" .. nick)
            imgui.TextUnformatted(encodeCp1251Safe(nick))
            imgui.SameLine(200)
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
            imgui.TextUnformatted(encodeCp1251Safe(data.reason or ""))
            imgui.PopStyleColor()
            imgui.SameLine(350)
            if imgui.Button(u8"X") then
                queueTask(function() removeBlacklistNick(nick) end)
                imgui.PopID()
                break
            end
            imgui.PopID()
            imgui.Separator()
        end
        imgui.EndChild()

        if imgui.Button(u8"Закрыть", imgui.ImVec2(100, 30)) then
            blacklist_show[0] = false
        end
        imgui.End()
    end
)

-- AutoEdit ImGui Window
imgui.OnFrame(
    function() return ae_active[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowSize(imgui.ImVec2(640, 350), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8"AutoEdit - Редактор объявления", nil, imgui.WindowFlags.NoCollapse)

        imgui.TextUnformatted(u8"Оригинальный текст:")
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
        imgui.PushTextWrapPos(0)
        imgui.TextUnformatted(sanitizeUtf8(ae_original_text))
        imgui.PopTextWrapPos()
        imgui.PopStyleColor()
        imgui.Separator()

        imgui.TextUnformatted(u8"Отформатированный результат:")
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.8, 0.5, 1))
        imgui.PushTextWrapPos(0)
        imgui.TextUnformatted(sanitizeUtf8(ae_formatted_text))
        imgui.PopTextWrapPos()
        imgui.PopStyleColor()
        imgui.Separator()

        local cur_cp1251 = decodeUtf8Safe(ffi.string(ae_input_buf))
        local char_len = #cur_cp1251
        local len_color = char_len > 128 and imgui.ImVec4(1.0, 0.25, 0.25, 1.0)
            or (char_len > 100 and imgui.ImVec4(1.0, 0.85, 0.2, 1.0) or imgui.ImVec4(0.3, 0.9, 0.4, 1.0))

        imgui.TextUnformatted(u8"Редактировать:")
        imgui.SameLine(490)
        imgui.PushStyleColor(imgui.Col.Text, len_color)
        imgui.TextUnformatted(u8"Длина: " .. tostring(char_len) .. " / 128")
        imgui.PopStyleColor()

        imgui.PushItemWidth(-1)
        if ae_focus then imgui.SetKeyboardFocusHere(0) end
        local ae_enter = imgui.InputText("##ae_input", ae_input_buf, ffi.sizeof(ae_input_buf), imgui.InputTextFlags.EnterReturnsTrue)
        ae_focus = false
        imgui.PopItemWidth()

        local cur_buf_utf8 = ffi.string(ae_input_buf)
        if cur_buf_utf8 ~= ae_last_buf_snapshot then
            ae_last_buf_snapshot = cur_buf_utf8
            ae_autosend_deadline = nil
        end

        imgui.Spacing()
        local function aeQuickInsert(phrase)
            ae_autosend_deadline = nil
            local cur = decodeUtf8Safe(ffi.string(ae_input_buf))
            cur = cur:gsub("%s+$", "")
            if cur ~= "" and not cur:find("%.$") then cur = cur .. "." end
            if cur ~= "" then cur = cur .. " " .. phrase else cur = phrase end
            safeStrCopy(ae_input_buf, encodeCp1251Safe(cur), ffi.sizeof(ae_input_buf))
            ae_last_buf_snapshot = ffi.string(ae_input_buf)
        end
        local function aeSetTagPrefix(new_tag)
            ae_autosend_deadline = nil
            local cur = decodeUtf8Safe(ffi.string(ae_input_buf))
            local tm = cur:match("^%s*([A-Za-z%d_%-\168\184\192-\255]+)%s*|%s*")
            if tm and #tm <= 12 then
                cur = cur:gsub("^%s*[A-Za-z%d_%-\168\184\192-\255]+%s*|%s*", "", 1)
            end
            if new_tag and new_tag ~= "" then
                cur = new_tag .. " | " .. cur
            end
            safeStrCopy(ae_input_buf, encodeCp1251Safe(cur), ffi.sizeof(ae_input_buf))
            ae_last_buf_snapshot = ffi.string(ae_input_buf)
        end

        if imgui.SmallButton(u8"+ Цена договорная") then aeQuickInsert("Цена договорная") end
        imgui.SameLine()
        if imgui.SmallButton(u8"+ Доплата (моя)") then aeQuickInsert("Доплата с моей стороны") end
        imgui.SameLine()
        if imgui.SmallButton(u8"+ Доплата (ваша)") then aeQuickInsert("Доплата с вашей стороны") end

        for _, tname in ipairs({"LV", "LS", "SF", "TV"}) do
            if imgui.SmallButton(tname .. "##ae_tag_" .. tname) then
                aeSetTagPrefix(tname)
            end
            imgui.SameLine()
        end
        if imgui.SmallButton(u8"Переформ.##ae_reformat") then
            ae_autosend_deadline = nil
            local orig_cp = decodeUtf8Safe(ae_original_text)
            local ok_f, res_f = pcall(formatAdText, orig_cp)
            local new_cp = ok_f and res_f or orig_cp
            ae_formatted_text = encodeCp1251Safe(new_cp)
            safeStrCopy(ae_input_buf, ae_formatted_text, ffi.sizeof(ae_input_buf))
            ae_last_buf_snapshot = ffi.string(ae_input_buf)
        end

        local ae_autosend_fire = false
        if ae_autosend_deadline then
            local rem = ae_autosend_deadline - os.clock()
            if rem <= 0 then
                ae_autosend_fire = true
            else
                imgui.Spacing()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.85, 0.2, 1.0))
                imgui.TextUnformatted(string.format(u8"Авто-отправка через %.1f с...", rem))
                imgui.PopStyleColor()
                imgui.SameLine()
                if imgui.SmallButton(u8"Пауза##ae_pause_autosend") then
                    ae_autosend_deadline = nil
                end
            end
        end

        -- Grace period: ignore Enter until the key is released after opening.
        if ae_ignore_enter > 0 then
            ae_ignore_enter = ae_ignore_enter - 1
            ae_enter = false
        end
        local enter_key_down = imgui.GetIO().KeysDown[0x0D]
        if ae_enter_was_down then
            if not enter_key_down then
                ae_enter_was_down = false
            end
            ae_enter = false
        end
        local esc_key_down = imgui.GetIO().KeysDown[0x1B]
        if ae_esc_was_down then
            if not esc_key_down then
                ae_esc_was_down = false
            end
        end

        imgui.Spacing()

        if ae_enter or ae_autosend_fire or imgui.Button(u8"Отправить##send", imgui.ImVec2(120, 30)) then
            ae_autosend_deadline = nil
            if ae_dialog_id >= 0 then
                local input_text = decodeUtf8Safe(ffi.string(ae_input_buf))
                addAdToHistory(input_text)
                local suggested_cp1251 = decodeUtf8Safe(ae_formatted_text)
                if suggested_cp1251 then
                    recordEditCorrection(suggested_cp1251, input_text)
                end
                local dlg_id = ae_dialog_id
                queueTask(function() sampSendDialogResponse(dlg_id, 1, -1, input_text) end)
            end
            ae_active[0] = false
        end

        imgui.SameLine()

        if imgui.Button(ORIG_BTN_TEXT, imgui.ImVec2(100, 30)) then
            ae_autosend_deadline = nil
            if ae_dialog_id >= 0 then
                local orig_text = decodeUtf8Safe(ae_original_text)
                local tm = orig_text:match("^%s*([A-Za-z%d_%-\168\184\192-\255]+)%s*|%s*")
                if tm and #tm <= 12 then
                    orig_text = orig_text:gsub("^%s*[A-Za-z%d_%-\168\184\192-\255]+%s*|%s*", "", 1)
                end
                local tag = decodeUtf8Safe(ffi.string(mm_tag))
                if tag and tag ~= "" then
                    orig_text = tag .. " | " .. orig_text
                end
                local pipe_pos = orig_text:find(" | ", 1, true)
                if pipe_pos then
                    local after_pipe = pipe_pos + 3
                    if after_pipe <= #orig_text then
                        orig_text = orig_text:sub(1, after_pipe - 1) .. cp1251_upper(orig_text:sub(after_pipe, after_pipe)) .. orig_text:sub(after_pipe + 1)
                    end
                elseif #orig_text > 0 then
                    orig_text = cp1251_upper(orig_text:sub(1, 1)) .. orig_text:sub(2)
                end
                addAdToHistory(orig_text)
                local dlg_id = ae_dialog_id
                queueTask(function() sampSendDialogResponse(dlg_id, 1, -1, orig_text) end)
            end
            ae_active[0] = false
        end
        imgui.SameLine()

        if imgui.Button(u8"Отклонить (ПРО)", imgui.ImVec2(150, 30)) or (not ae_esc_was_down and imgui.GetIO().KeysDown[0x1B]) then
            ae_autosend_deadline = nil
            if ae_dialog_id >= 0 then
                local tag = decodeUtf8Safe(ffi.string(mm_tag))
                local reject_text = "ПРО"
                if tag and tag ~= "" then
                    reject_text = tag .. " | ПРО"
                end
                safeStrCopy(ae_input_buf, encodeCp1251Safe(reject_text), ffi.sizeof(ae_input_buf))
                ae_last_buf_snapshot = ffi.string(ae_input_buf)
                local dlg_id = ae_dialog_id
                queueTask(function() sampSendDialogResponse(dlg_id, 0, -1, reject_text) end)
            end
            ae_active[0] = false
        end

        imgui.SameLine()

        if imgui.Button(u8"История", imgui.ImVec2(90, 30)) then
            ae_show_history[0] = not ae_show_history[0]
        end

        if ae_show_history[0] and #ad_history > 0 then
            imgui.Separator()
            imgui.TextUnformatted(u8"Последние объявления:")
            imgui.BeginChild("##ae_hist_scroll", imgui.ImVec2(0, 120), true)
            for i, h in ipairs(ad_history) do
                local preview = encodeCp1251Safe(h:sub(1, 60) .. (h:len() > 60 and "..." or ""))
                if imgui.Button(preview .. "##ad_hist_" .. i, imgui.ImVec2(-1, 0)) then
                    ae_autosend_deadline = nil
                    safeStrCopy(ae_input_buf, encodeCp1251Safe(h), ffi.sizeof(ae_input_buf))
                    ae_last_buf_snapshot = ffi.string(ae_input_buf)
                end
            end
            imgui.EndChild()
        end

        imgui.End()
    end
)

-- Компактный HUD (перетаскиваемая мини-панель)
do
local hud_f = imgui.OnFrame(
    function() return hud_enabled[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x - 245, 16), imgui.Cond.FirstUseEver)
        local hud_flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoFocusOnAppearing
        if not show_main_window[0] then
            hud_flags = hud_flags + imgui.WindowFlags.NoInputs
        end
        imgui.Begin("##helper_compact_hud", nil, hud_flags)

        local fps = math.floor((imgui.GetIO().Framerate or 0) + 0.5)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85, 0.95, 1.0, 1.0))
        imgui.TextUnformatted(u8"Время: " .. hud_cache.time_str .. " | PayDay: " .. encodeCp1251Safe(hud_cache.payday_str))
        imgui.PopStyleColor()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65, 0.75, 0.85, 1.0))
        imgui.TextUnformatted("FPS: " .. tostring(fps) .. " | Ping: " .. tostring(hud_cache.ping))
        imgui.PopStyleColor()
        if hud_cache.wp_text ~= "" then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35, 0.9, 1.0, 1.0))
            imgui.TextUnformatted("GPS: " .. encodeCp1251Safe(hud_cache.wp_text))
            imgui.PopStyleColor()
        end
        if gnews_sched_hud_str and gnews_sched_hud_str ~= "" then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.85, 0.25, 1.0))
            imgui.TextUnformatted(encodeCp1251Safe(gnews_sched_hud_str))
            imgui.PopStyleColor()
        end
        if isModuleEnabled("faction_tools") and dmg_enabled[0] and dmg_show_hud[0] and dmg_last_hud ~= "" and (os.time() - dmg_last_ts) <= 6 then
            local d_col = (dmg_last_hud:sub(1, 1) == "+") and imgui.ImVec4(0.35, 1.0, 0.45, 1.0) or imgui.ImVec4(1.0, 0.35, 0.35, 1.0)
            imgui.PushStyleColor(imgui.Col.Text, d_col)
            imgui.TextUnformatted(encodeCp1251Safe(dmg_last_hud))
            imgui.PopStyleColor()
        end
        if session_track_enabled[0] and session_hud_str ~= "" then
            imgui.PushStyleColor(imgui.Col.Text, session_idle_sec >= 45 and imgui.ImVec4(1.0, 0.65, 0.3, 1.0) or imgui.ImVec4(0.55, 0.95, 0.65, 1.0))
            imgui.TextUnformatted(encodeCp1251Safe(session_hud_str))
            imgui.PopStyleColor()
        end

        local badges = {}
        if sport_boost_active then badges[#badges + 1] = {txt = u8"СПОРТ", col = imgui.ImVec4(1.0, 0.35, 0.2, 1.0)} end
        if cruise_active then badges[#badges + 1] = {txt = u8"КРУИЗ", col = imgui.ImVec4(0.2, 0.9, 1.0, 1.0)} end
        if strobe_active then badges[#badges + 1] = {txt = u8"СТРОБЫ", col = imgui.ImVec4(1.0, 0.8, 0.2, 1.0)} end
        if aad_active then badges[#badges + 1] = {txt = "AAD", col = imgui.ImVec4(0.3, 1.0, 0.4, 1.0)} end
        if efir_active then badges[#badges + 1] = {txt = u8"ЭФИР", col = imgui.ImVec4(1.0, 0.4, 0.8, 1.0)} end
        if call_active then badges[#badges + 1] = {txt = u8"ОБЗВОН", col = imgui.ImVec4(1.0, 0.6, 0.2, 1.0)} end
        if gnews_active then badges[#badges + 1] = {txt = "GNEWS", col = imgui.ImVec4(0.4, 0.8, 1.0, 1.0)} end

        if hud_show_finance[0] and finance_enabled[0] and (finance_income > 0 or finance_expense > 0) then
            local net = finance_income - finance_expense
            local ncol = net >= 0 and imgui.ImVec4(0.3, 1.0, 0.4, 1.0) or imgui.ImVec4(1.0, 0.35, 0.35, 1.0)
            imgui.PushStyleColor(imgui.Col.Text, ncol)
            imgui.TextUnformatted(u8"Баланс: " .. (net >= 0 and "+" or "-") .. formatNumberWithDots(math.abs(net)) .. "$")
            imgui.PopStyleColor()
        end

        if hud_show_cooldowns[0] then
            local now_cd = os.time()
            local cd_parts = {}
            for _, cname in ipairs({"ad", "gnews", "healme", "mask", "fill"}) do
                local exp = cmd_cooldowns[cname]
                if exp and exp > now_cd then
                    cd_parts[#cd_parts + 1] = "/" .. cname .. " " .. (exp - now_cd) .. u8"с"
                end
            end
            if #cd_parts > 0 then
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.8, 0.25, 1.0))
                imgui.TextUnformatted(u8"КД: " .. table.concat(cd_parts, " | "))
                imgui.PopStyleColor()
            end
        end

        if #badges > 0 then
            for idx, b in ipairs(badges) do
                if idx > 1 then imgui.SameLine() end
                imgui.PushStyleColor(imgui.Col.Text, b.col)
                imgui.TextUnformatted("[" .. b.txt .. "]")
                imgui.PopStyleColor()
            end
        end

        imgui.End()
    end
)
hud_f.HideCursor = true
end

-- Меню взаимодействия с игроком по прицелу (ПКМ + X)
imgui.OnFrame(
    function() return target_menu_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8"Взаимодействие с игроком##target_menu", target_menu_show, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.AlwaysAutoResize)

        local tid = target_menu_id
        local tnick = target_menu_nick
        local tphone = target_menu_phone
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 0.9, 1.0, 1.0))
        imgui.TextUnformatted(encodeCp1251Safe(tnick .. " [ID:" .. tostring(tid) .. "]"))
        imgui.PopStyleColor()
        if tphone ~= "" then
            imgui.TextUnformatted(u8"Телефон: " .. tphone)
        end
        imgui.Separator()

        if imgui.Button(u8"Паспорт (/pass)##tm_pass", imgui.ImVec2(140, 26)) then
            queueTask(function() if isSampAvailable() then sampSendChat("/pass " .. tid) end end)
            target_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"Лицензии (/lic)##tm_lic", imgui.ImVec2(140, 26)) then
            queueTask(function() if isSampAvailable() then sampSendChat("/lic " .. tid) end end)
            target_menu_show[0] = false
        end

        if imgui.Button(u8"Медкарта (/med)##tm_med", imgui.ImVec2(140, 26)) then
            queueTask(function() if isSampAvailable() then sampSendChat("/med " .. tid) end end)
            target_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"Цель РП (/mmact)##tm_act", imgui.ImVec2(140, 26)) then
            queueTask(function() cmdAct(tostring(tid)) end)
            target_menu_show[0] = false
        end

        imgui.PushItemWidth(140)
        imgui.InputInt("##tm_pay_amt", target_pay_amount)
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(u8"Передать (/pay)##tm_pay", imgui.ImVec2(140, 24)) then
            local amt = math.max(1, target_pay_amount[0])
            queueTask(function() if isSampAvailable() then sampSendChat("/pay " .. tid .. " " .. amt) end end)
            target_menu_show[0] = false
        end

        if tphone ~= "" then
            if imgui.Button(u8"Позвонить (" .. tphone .. ")##tm_call", imgui.ImVec2(180, 26)) then
                queueTask(function() if isSampAvailable() then sampSendChat("/c " .. tphone) end end)
                target_menu_show[0] = false
            end
            imgui.SameLine()
        end
        if imgui.Button(u8"Копировать ник##tm_copy", imgui.ImVec2(130, 26)) then
            local clip_txt = tnick
            queueTask(function()
                if type(setClipboardText) == "function" then pcall(setClipboardText, clip_txt) end
                sampAddChatMessage("[Helper] Ник скопирован: " .. clip_txt, 0x00FF90)
            end)
            target_menu_show[0] = false
        end

        imgui.Separator()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 0.85, 1.0, 1.0))
        imgui.TextUnformatted(u8"МВД / МЗ / Доп. действия:")
        imgui.PopStyleColor()
        imgui.SameLine()
        if imgui.Checkbox(u8"Авто-РП##tm_autorp", target_menu_autorp) then requestSaveSettings() end

        if imgui.Button(u8"Розыск (/su)##tm_su", imgui.ImVec2(140, 26)) then
            queueTask(function() P2_openTargetSu(tid) end)
            target_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"Штраф (/ticket)##tm_ticket", imgui.ImVec2(140, 26)) then
            queueTask(function() P2_openTargetTicket(tid) end)
            target_menu_show[0] = false
        end

        if imgui.Button(u8"Наручники (/cuff)##tm_cuff", imgui.ImVec2(140, 26)) then
            queueTask(function()
                local rp = "/me " .. rpVerb("снял", "сняла") .. " наручники с пояса и " .. rpVerb("надел", "надела") .. " их на подозреваемого"
                P2_sendWithOptionalRp("/cuff " .. tostring(tid), rp)
            end)
            target_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"Снять (/uncuff)##tm_uncuff", imgui.ImVec2(140, 26)) then
            queueTask(function()
                local rp = "/me " .. rpVerb("достал", "достала") .. " ключ и " .. rpVerb("снял", "сняла") .. " наручники"
                P2_sendWithOptionalRp("/uncuff " .. tostring(tid), rp)
            end)
            target_menu_show[0] = false
        end

        if imgui.Button(u8"Обыск (/search)##tm_search", imgui.ImVec2(140, 26)) then
            queueTask(function()
                local rp = "/me " .. rpVerb("надел", "надела") .. " перчатки и " .. rpVerb("провёл", "провела") .. " обыск"
                P2_sendWithOptionalRp("/search " .. tostring(tid), rp)
            end)
            target_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"История (/history)##tm_hist", imgui.ImVec2(140, 26)) then
            queueTask(function() cmdFastHistory(tostring(tid)) end)
            target_menu_show[0] = false
        end

        if imgui.Button(u8"Лечить (/medhelp)##tm_medhelp", imgui.ImVec2(140, 26)) then
            queueTask(function() P2_openTargetMed(tid) end)
            target_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"В карете (/heal)##tm_heal", imgui.ImVec2(140, 26)) then
            queueTask(function()
                local rp = "/me " .. rpVerb("достал", "достала") .. " аптечку скорой помощи и " .. rpVerb("оказал", "оказала") .. " помощь пациенту"
                P2_sendWithOptionalRp("/heal " .. tostring(tid), rp)
            end)
            target_menu_show[0] = false
        end
        imgui.Separator()
        if imgui.Button(u8"+ В друзья##tm_friend", imgui.ImVec2(140, 26)) then
            friends_list[cp1251_lower(tnick)] = { nick = tnick, note = "" }
            requestSaveSettings()
            queueTask(function() sampAddChatMessage("[Helper Друзья] Добавлен: " .. tnick, 0x00FF90) end)
            target_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"+ В ЧС СМИ##tm_bl", imgui.ImVec2(140, 26)) then
            queueTask(function() addBlacklistNick(tnick, "Из меню цели") end)
            target_menu_show[0] = false
        end

        imgui.Separator()
        if imgui.Button(u8"Закрыть##tm_close", imgui.ImVec2(100, 26)) then
            target_menu_show[0] = false
        end
        imgui.End()
    end
)

-- Поиск по истории чата (/clog)
imgui.OnFrame(
    function() return clog_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowSize(imgui.ImVec2(660, 420), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8"История чата (/clog)", clog_show, imgui.WindowFlags.NoCollapse)

        imgui.PushItemWidth(320)
        imgui.InputText(u8"Фильтр##clog_filter", clog_search_buf, ffi.sizeof(clog_search_buf))
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(u8"Очистить##clog_clear") then
            chat_log_history = {}
        end
        imgui.SameLine()
        imgui.TextUnformatted(u8"Всего: " .. #chat_log_history .. u8" (клик по строке — копировать)")
        imgui.Separator()

        local q = cp1251_lower(decodeUtf8Safe(ffi.string(clog_search_buf)))
        imgui.BeginChild("##clog_scroll", imgui.ImVec2(0, 315), true)
        local shown = 0
        for idx, item in ipairs(chat_log_history) do
            if q == "" or cp1251_lower(item.text):find(q, 1, true) then
                shown = shown + 1
                local line_str = "[" .. item.time .. "] " .. item.text
                if imgui.Selectable(encodeCp1251Safe(line_str) .. "##clog_" .. idx, false) then
                    local clip_txt = item.text
                    queueTask(function()
                        if type(setClipboardText) == "function" then pcall(setClipboardText, clip_txt) end
                        sampAddChatMessage("[Helper] Скопировано из /clog", 0x00FF90)
                    end)
                end
                if shown >= 150 then break end
            end
        end
        if shown == 0 then
            imgui.TextUnformatted(u8"Совпадений не найдено.")
        end
        imgui.EndChild()

        if imgui.Button(u8"Закрыть##clog_close", imgui.ImVec2(100, 28)) then
            clog_show[0] = false
        end
        imgui.End()
    end
)

-- Мини-окно Режиссёра викторины (/quiz)
imgui.OnFrame(
    function() return quiz_popout_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x * 0.5, display.y * 0.5), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(430, 500), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"Режиссёр викторины (/quiz)##quiz_pop_win", quiz_popout_show, imgui.WindowFlags.NoCollapse)
        drawQuizDirectorUI("_pop")
        imgui.End()
    end
)

-- Быстрое компактное меню на СКМ (/wheelmenu)
imgui.OnFrame(
    function() return wheel_menu_show[0] end,
    function()
        local io = imgui.GetIO()
        local display = io.DisplaySize
        if P2.wheel_menu_need_pos then
            local mp = io.MousePos
            if mp and mp.x >= 0 and mp.y >= 0 and mp.x <= display.x and mp.y <= display.y then
                wheel_menu_pos = { x = mp.x, y = mp.y }
            else
                wheel_menu_pos = { x = display.x * 0.5, y = display.y * 0.5 }
            end
            P2.wheel_menu_need_pos = false
        end
        local wx = math.max(16, math.min(display.x - 336, wheel_menu_pos.x or (display.x * 0.5)))
        local wy = math.max(16, math.min(display.y - 280, wheel_menu_pos.y or (display.y * 0.5)))
        local cond = (imgui.Cond and imgui.Cond.Appearing) or imgui.Cond.Once
        imgui.SetNextWindowPos(imgui.ImVec2(wx, wy), cond, imgui.ImVec2(0.0, 0.0))
        imgui.Begin(u8"Быстрое меню (СКМ)##p2_wheel_menu", wheel_menu_show, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.AlwaysAutoResize)

        local rp_items = P2_getWheelDisplayItems()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35, 0.95, 0.8, 1.0))
        imgui.TextUnformatted(#wheel_fav_slots > 0 and u8"Избранные РП-отыгровки:" or u8"РП-отыгровки (Глава 1):")
        imgui.PopStyleColor()

        if #rp_items == 0 then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1.0))
            imgui.TextUnformatted(u8"Нет доступных отыгровок (/rpeditor)")
            imgui.PopStyleColor()
        else
            for i, item in ipairs(rp_items) do
                local btn_lbl = encodeCp1251Safe(P2_truncCp1251(item.name, 20)) .. "##p2_wrp_" .. i
                if imgui.Button(btn_lbl, imgui.ImVec2(150, 26)) then
                    local rp_txt = item.text
                    local rp_ch = item.chapter
                    queueTask(function()
                        if rp_ch and rp_settings and rp_settings.setList then
                            rp_settings.setList[0] = rp_ch - 1
                        end
                        playRp(rp_txt, false)
                    end)
                    wheel_menu_show[0] = false
                end
                if (i % 2 == 1) and (i < #rp_items) then
                    imgui.SameLine()
                end
            end
        end

        imgui.Separator()
        local fac = selected_faction and selected_faction[0] or 0
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 0.85, 1.0, 1.0))
        if fac == 1 then
            imgui.TextUnformatted(u8"Фракция (МВД):")
        elseif fac == 2 then
            imgui.TextUnformatted(u8"Фракция (МЗ):")
        elseif fac == 3 then
            imgui.TextUnformatted(u8"Фракция (МО):")
        elseif fac == 4 then
            imgui.TextUnformatted(u8"Фракция (Мэрия):")
        elseif fac == 5 then
            imgui.TextUnformatted(u8"Фракция (СМИ):")
        elseif fac == 6 or fac == 7 then
            imgui.TextUnformatted(u8"Фракция (Нелегалы):")
        else
            imgui.TextUnformatted(u8"Фракция:")
        end
        imgui.PopStyleColor()

        if fac == 1 then
            if imgui.Button(u8"Розыск (/co)##p2_f_co", imgui.ImVec2(98, 26)) then
                queueTask(function() if isSampAvailable() then sampSendChat("/co") end end)
                wheel_menu_show[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"Мегафон (/m)##p2_f_m", imgui.ImVec2(98, 26)) then
                queueTask(function()
                    if isSampAvailable() then
                        pcall(sampSetChatInputEnabled, true)
                        pcall(sampSetChatInputText, "/m ")
                    end
                end)
                wheel_menu_show[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"Патруль (/patrol)##p2_f_pat", imgui.ImVec2(98, 26)) then
                queueTask(function() if isSampAvailable() then sampSendChat("/patrol") end end)
                wheel_menu_show[0] = false
            end
            if type(P4_openSuMenu) == "function" then
                if imgui.Button(u8"База УК (/suw)##p2_f_suw", imgui.ImVec2(150, 26)) then
                    queueTask(function() P4_openSuMenu(0) end)
                    wheel_menu_show[0] = false
                end
            end
        elseif fac == 2 then
            if imgui.Button(u8"Лечить (/medhelp)##p2_f_medh", imgui.ImVec2(150, 26)) then
                queueTask(function()
                    if type(P4_openMedMenu) == "function" then
                        P4_openMedMenu(0)
                    elseif isSampAvailable() then
                        pcall(sampSetChatInputEnabled, true)
                        pcall(sampSetChatInputText, "/medhelp ")
                    end
                end)
                wheel_menu_show[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"В карете (/heal)##p2_f_heal", imgui.ImVec2(150, 26)) then
                queueTask(function()
                    if isSampAvailable() then
                        pcall(sampSetChatInputEnabled, true)
                        pcall(sampSetChatInputText, "/heal ")
                    end
                end)
                wheel_menu_show[0] = false
            end
        elseif fac == 5 then
            if imgui.Button(u8"Объявления (/edit)##p2_f_edit", imgui.ImVec2(150, 26)) then
                queueTask(function() if isSampAvailable() then sampSendChat("/edit") end end)
                wheel_menu_show[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"Викторина (/quiz)##p2_f_quiz", imgui.ImVec2(150, 26)) then
                quiz_popout_show[0] = not quiz_popout_show[0]
                wheel_menu_show[0] = false
            end
            if imgui.Button(u8"Анаграмма (/anag)##p2_f_anag", imgui.ImVec2(150, 26)) then
                queueTask(function() startAnagram("") end)
                wheel_menu_show[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"Эфир (/mmefir)##p2_f_efir", imgui.ImVec2(150, 26)) then
                queueTask(function() cmdEfir() end)
                wheel_menu_show[0] = false
            end
        elseif fac == 3 then
            if imgui.Button(u8"Склад (/state)##p2_f_state", imgui.ImVec2(150, 26)) then
                queueTask(function() if isSampAvailable() then sampSendChat("/state") end end)
                wheel_menu_show[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"Оружие (/makegun)##p2_f_mgun", imgui.ImVec2(150, 26)) then
                queueTask(function() if isSampAvailable() then sampSendChat("/makegun") end end)
                wheel_menu_show[0] = false
            end
        elseif fac == 4 then
            if imgui.Button(u8"Рация (/r )##p2_f_mr", imgui.ImVec2(98, 26)) then
                queueTask(function()
                    if isSampAvailable() then
                        pcall(sampSetChatInputEnabled, true)
                        pcall(sampSetChatInputText, "/r ")
                    end
                end)
                wheel_menu_show[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"Департ. (/d )##p2_f_md", imgui.ImVec2(98, 26)) then
                queueTask(function()
                    if isSampAvailable() then
                        pcall(sampSetChatInputEnabled, true)
                        pcall(sampSetChatInputText, "/d ")
                    end
                end)
                wheel_menu_show[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"Выпустить (/free)##p2_f_free", imgui.ImVec2(98, 26)) then
                queueTask(function()
                    if isSampAvailable() then
                        pcall(sampSetChatInputEnabled, true)
                        pcall(sampSetChatInputText, "/free ")
                    end
                end)
                wheel_menu_show[0] = false
            end
        elseif fac == 6 or fac == 7 then
            if imgui.Button(u8"Лечение (/drugs)##p2_f_drugs", imgui.ImVec2(150, 26)) then
                queueTask(function() if isSampAvailable() then sampSendChat("/drugs") end end)
                wheel_menu_show[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"РП-цель (/mmact)##p2_f_act", imgui.ImVec2(150, 26)) then
                queueTask(function()
                    if isSampAvailable() then
                        pcall(sampSetChatInputEnabled, true)
                        pcall(sampSetChatInputText, "/mmact ")
                    end
                end)
                wheel_menu_show[0] = false
            end
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1.0))
            imgui.TextUnformatted(u8"Гражданский (выберите пресет фракции в Утилитах)")
            imgui.PopStyleColor()
        end

        imgui.Separator()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.85, 0.85, 0.85, 1.0))
        imgui.TextUnformatted(u8"Общие команды:")
        imgui.PopStyleColor()

        if imgui.Button("/c 60##p2_g_c60", imgui.ImVec2(98, 26)) then
            queueTask(function() if isSampAvailable() then sampSendChat("/c 60") end end)
            wheel_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button("/ss##p2_g_ss", imgui.ImVec2(98, 26)) then
            queueTask(function() P2_runQuickScreenshot() end)
            wheel_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button("/mask##p2_g_mask", imgui.ImVec2(98, 26)) then
            queueTask(function() if isSampAvailable() then sampSendChat("/mask") end end)
            wheel_menu_show[0] = false
        end

        if imgui.Button("/healme##p2_g_healme", imgui.ImVec2(98, 26)) then
            queueTask(function() if isSampAvailable() then sampSendChat("/healme") end end)
            wheel_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button("/lock##p2_g_lock", imgui.ImVec2(98, 26)) then
            queueTask(function() if isSampAvailable() then sampSendChat("/lock") end end)
            wheel_menu_show[0] = false
        end
        imgui.SameLine()
        if imgui.Button("/e##p2_g_e", imgui.ImVec2(98, 26)) then
            queueTask(function() if isSampAvailable() then sampSendChat("/e") end end)
            wheel_menu_show[0] = false
        end

        imgui.Separator()
        if imgui.Button(u8"Закрыть##p2_w_close", imgui.ImVec2(110, 24)) then
            wheel_menu_show[0] = false
        end
        imgui.End()
    end
)
imgui.OnFrame(
    function() return suw_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowSize(imgui.ImVec2(570, 500), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8"МВД: Розыск, Штрафы и Мегафон (/suw)##p4_suw_win", suw_show, imgui.WindowFlags.NoCollapse)

        imgui.PushItemWidth(110)
        imgui.InputInt(u8"ID цели##suw_tid", suw_target_id)
        if suw_target_id[0] < 0 then suw_target_id[0] = 0 end
        if suw_target_id[0] > 1004 then suw_target_id[0] = 1004 end
        imgui.PopItemWidth()
        local tid = suw_target_id[0]
        local tnick = online_ids_to_nicks and online_ids_to_nicks[tid]
        if tid == my_cached_id and my_cached_nick ~= "" then tnick = my_cached_nick end
        imgui.SameLine()
        if tnick and tnick ~= "" then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 1.0, 0.55, 1))
            imgui.TextUnformatted(encodeCp1251Safe(tnick))
            imgui.PopStyleColor()
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65, 0.65, 0.65, 1))
            imgui.TextUnformatted(u8"(ник не в кэше / проверьте ID)")
            imgui.PopStyleColor()
        end
        imgui.SameLine()
        imgui.Checkbox(u8"РП-отыгровка##suw_rp_chk", suw_use_rp)

        imgui.PushItemWidth(300)
        imgui.InputText(u8"Поиск по статье / слову##suw_search", suw_search_buf, ffi.sizeof(suw_search_buf))
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.SmallButton(u8"X##suw_clr_q") then
            safeStrCopy(suw_search_buf, "", ffi.sizeof(suw_search_buf))
        end

        if imgui.Button(u8"УК — Розыск (/su)##suw_t1", imgui.ImVec2(170, 24)) then suw_tab = 1 end
        imgui.SameLine()
        if imgui.Button(u8"АК — Штрафы (/ticket)##suw_t2", imgui.ImVec2(170, 24)) then suw_tab = 2 end
        imgui.SameLine()
        imgui.TextUnformatted(encodeCp1251Safe("[" .. (P4_codex.server_name or "Blue") .. "]"))

        local q = cp1251_lower(P4_sanitizeStr(decodeUtf8Safe(ffi.string(suw_search_buf)), 64))
        local do_rp = suw_use_rp[0]

        imgui.BeginChild("##suw_articles", imgui.ImVec2(0, 215), true)
        local shown = 0
        if suw_tab == 1 then
            for idx, art in ipairs(P4_codex.uk) do
                local hay = cp1251_lower(art.code .. " " .. art.title)
                if q == "" or hay:find(q, 1, true) then
                    shown = shown + 1
                    if imgui.SmallButton(u8"Выдать##suw_u_" .. idx) then
                        local p = tid
                        local st = art.stars or 1
                        local rsn = art.code:find("УК") and art.code or (art.code .. " УК")
                        local rp = do_rp and art.rp or nil
                        queueTask(function() P4_issueWanted(p, st, rsn, rp) end)
                    end
                    imgui.SameLine()
                    imgui.TextUnformatted(encodeCp1251Safe("[" .. art.code .. "] " .. art.title .. " (" .. tostring(art.stars) .. " зв.)"))
                end
            end
        else
            for idx, art in ipairs(P4_codex.ak) do
                local hay = cp1251_lower(art.code .. " " .. art.title)
                if q == "" or hay:find(q, 1, true) then
                    shown = shown + 1
                    if imgui.SmallButton(u8"Штраф##suw_a_" .. idx) then
                        local p = tid
                        local fn = art.fine or 1500
                        local rsn = art.code:find("АК") and art.code or (art.code .. " АК")
                        local rp = do_rp and art.rp or nil
                        queueTask(function() P4_issueTicket(p, fn, rsn, rp) end)
                    end
                    imgui.SameLine()
                    imgui.TextUnformatted(encodeCp1251Safe("[" .. art.code .. "] " .. art.title .. " (" .. tostring(art.fine) .. "$)"))
                end
            end
        end
        if shown == 0 then
            imgui.TextUnformatted(u8"Подходящих статей не найдено.")
        end
        imgui.EndChild()

        imgui.Separator()
        imgui.TextUnformatted(u8"Быстрый произвольный /su:")
        imgui.PushItemWidth(110)
        imgui.SliderInt(u8"Зв.##suw_cst", suw_custom_stars, 1, 6)
        imgui.PopItemWidth()
        imgui.SameLine()
        imgui.PushItemWidth(220)
        imgui.InputText(u8"Причина##suw_crs", suw_custom_reason, ffi.sizeof(suw_custom_reason))
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(u8"Выдать /su##suw_cs_go", imgui.ImVec2(100, 22)) then
            local p = tid
            local st = suw_custom_stars[0]
            local rsn = P4_sanitizeStr(decodeUtf8Safe(ffi.string(suw_custom_reason)), 64)
            local rp = do_rp and "/me открыл бортовой компьютер и объявил гражданина в розыск" or nil
            queueTask(function() P4_issueWanted(p, st, rsn, rp) end)
        end

        imgui.Separator()
        imgui.TextUnformatted(u8"Полицейский мегафон (/m):")
        for mi, mline in ipairs(P4_megaphone_lines) do
            if mi > 1 then imgui.SameLine() end
            if imgui.Button(u8"/m " .. mi .. "##suw_m_" .. mi, imgui.ImVec2(75, 22)) then
                local midx = mi
                queueTask(function() P4_sendMegaphone(midx) end)
            end
            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.TextUnformatted(encodeCp1251Safe(mline))
                imgui.EndTooltip()
            end
        end

        imgui.Spacing()
        if imgui.Button(u8"Закрыть##suw_close", imgui.ImVec2(110, 24)) then
            suw_show[0] = false
        end
        imgui.End()
    end
)

imgui.OnFrame(
    function() return medui_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowSize(imgui.ImVec2(510, 390), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8"МЗ: Единая ценовая политика (/medui)##p4_med_win", medui_show, imgui.WindowFlags.NoCollapse)

        imgui.PushItemWidth(110)
        imgui.InputInt(u8"ID пациента##medui_tid", medui_target_id)
        if medui_target_id[0] < 0 then medui_target_id[0] = 0 end
        if medui_target_id[0] > 1004 then medui_target_id[0] = 1004 end
        imgui.PopItemWidth()
        local pid = medui_target_id[0]
        local pnick = online_ids_to_nicks and online_ids_to_nicks[pid]
        if pid == my_cached_id and my_cached_nick ~= "" then pnick = my_cached_nick end
        imgui.SameLine()
        if pnick and pnick ~= "" then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 1.0, 0.55, 1))
            imgui.TextUnformatted(encodeCp1251Safe(pnick))
            imgui.PopStyleColor()
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.65, 0.65, 0.65, 1))
            imgui.TextUnformatted(u8"(ник не в кэше)")
            imgui.PopStyleColor()
        end
        imgui.SameLine()
        imgui.Checkbox(u8"РП-отыгровка##medui_rp_chk", medui_use_rp)

        imgui.Separator()
        local do_rp = medui_use_rp[0]
        imgui.BeginChild("##medui_ecp_list", imgui.ImVec2(0, 265), true)
        for idx, e in ipairs(P4_codex.ecp) do
            local cmd_str = P4_formatEcpCommand(e, pid)
            if imgui.Button(u8"Провести##med_go_" .. idx, imgui.ImVec2(95, 24)) then
                local c_send = cmd_str
                local rp = do_rp and e.rp or nil
                queueTask(function() P4_runMedicAction(c_send, rp) end)
            end
            imgui.SameLine()
            local has_price = (e.cmd ~= "medhelp" and e.cmd ~= "analysis")
            local row_txt = has_price
                and (e.name .. " — " .. tostring(e.price) .. "$ [" .. cmd_str .. "]")
                or (e.name .. " [" .. cmd_str .. "]")
            imgui.TextUnformatted(encodeCp1251Safe(row_txt))
        end
        imgui.EndChild()

        imgui.Spacing()
        if imgui.Button(u8"Закрыть##medui_close", imgui.ImVec2(110, 24)) then
            medui_show[0] = false
        end
        imgui.End()
    end
)

imgui.OnFrame(
    function() return dmg_log_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowSize(imgui.ImVec2(550, 360), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8"Damage Informer — Лог попаданий (/dmglog)##p4_dmg_win", dmg_log_show, imgui.WindowFlags.NoCollapse)

        if imgui.Checkbox(u8"Включить Damage Informer", dmg_enabled) then requestSaveSettings() end
        imgui.SameLine()
        if imgui.Checkbox(u8"В /hud", dmg_show_hud) then requestSaveSettings() end
        imgui.SameLine()
        if imgui.SmallButton(u8"Очистить##dmg_win_clr") then
            dmg_log = {}
            dmg_last_hud = ""
            dmg_last_ts = 0
        end
        imgui.Separator()

        imgui.BeginChild("##dmg_win_list", imgui.ImVec2(0, 235), true)
        if #dmg_log == 0 then
            imgui.TextUnformatted(u8"Журнал урона пуст. Клик по записи копирует её в буфер.")
        else
            for idx, entry in ipairs(dmg_log) do
                local col = entry.give and imgui.ImVec4(0.35, 1.0, 0.45, 1) or imgui.ImVec4(1.0, 0.4, 0.4, 1)
                imgui.PushStyleColor(imgui.Col.Text, col)
                if imgui.Selectable(encodeCp1251Safe(entry.text) .. "##dmg_row_" .. idx, false) then
                    local clip_txt = entry.text
                    queueTask(function()
                        if type(setClipboardText) == "function" then pcall(setClipboardText, clip_txt) end
                        sampAddChatMessage("[Helper] Строка урона скопирована", 0x00FF90)
                    end)
                end
                imgui.PopStyleColor()
            end
        end
        imgui.EndChild()

        if imgui.Button(u8"Закрыть##dmg_win_close", imgui.ImVec2(110, 24)) then
            dmg_log_show[0] = false
        end
        imgui.End()
    end
)
-- ФАЗА 6: Главное окно Конструктора локаций /location (Каталог 522 + Реестр + Редактор)
imgui.OnFrame(
    function() return loc_ui_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x * 0.5, display.y * 0.5), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(760, 560), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"Конструктор локаций /location — Advance RP##p6_loc_main", loc_ui_show, imgui.WindowFlags.NoCollapse)
        P6_drawLocationWindowUI()
        imgui.End()
    end
)

-- ФАЗА 6: Плавающая панель точного редактора (/tedit или активный /location)
imgui.OnFrame(
    function()
        local mod_on = (type(isModuleEnabled) ~= "function") or isModuleEnabled("location_builder")
        return mod_on and (tedit_show[0] or (tedit_active and not P6.tedit_dismissed))
    end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x - 450, 120), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowSize(imgui.ImVec2(430, 510), imgui.Cond.FirstUseEver)
        P6.tedit_win_open[0] = true
        imgui.Begin(u8"Точный редактор /tedit##p6_tedit_win", P6.tedit_win_open, imgui.WindowFlags.NoCollapse)
        P6_drawPrecisionPanel("")
        imgui.End()
        if not P6.tedit_win_open[0] then
            tedit_show[0] = false
            if tedit_active then P6.tedit_dismissed = true end
        end
    end
)
function onScriptTerminate(script, quitGame)
    if script ~= thisScript() then return end
    if settings_dirty then settings_dirty = false; pcall(saveSettings) end
    if db_dirty then db_dirty = false; pcall(saveDatabase) end
    if rules_dirty then rules_dirty = false; pcall(saveRules) end
    if corrections_dirty then corrections_dirty = false; pcall(saveCorrections) end
    if ad_history_dirty then ad_history_dirty = false; pcall(saveAdHistory) end
    if rp_settings_dirty then rp_settings_dirty = false; pcall(saveRpSettings) end
    if blacklist_dirty then blacklist_dirty = false; pcall(saveBlacklist) end
    pcall(setGameKeyState, 16, 0)
    pcall(function()
        if isCharInAnyCar(PLAYER_PED) then
            local car = storeCarCharIsInNoSave(PLAYER_PED)
            if car and doesVehicleExist(car) then
                restoreAllLights(car)
            end
        end
    end)
    if cam_active then pcall(P5_exitFreeCam) end
tedit_active = false
tedit_dup_pending = false
pcall(P6_saveLocations)
if not quitGame and type(imgui.IsInitialized) == "function" and imgui.IsInitialized() then
    if type(P6_flushTexReleaseQueue) == "function" then
        pcall(P6_flushTexReleaseQueue)
    end
    for _tid, _tex in pairs(loc_textures) do
        if _tex and _tex ~= false and type(imgui.ReleaseTexture) == "function" then
            pcall(imgui.ReleaseTexture, _tex)
        end
    end
end
P6.tex_release_queue = {}
P6.tex_order = {}
loc_textures = {}
end
