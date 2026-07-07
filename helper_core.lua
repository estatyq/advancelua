--[[
Universal Game Helper Core for SAMP (MoonLoader / Lua)

���� ���� �������� ����� � �������� ����� ������� ���������.
����� ���������� ��������������� ��������� �� mimgui (����������� �� �������/������),
�������� ������������� ����������� �������, ������� ���������� ��� ��� ���� �������,
�������� ������� �������, ������������������ ������, ��� �������� (MM Editor),
���������� ������ ������ Advance RP, �������������� RP ���������,
�����������, �����-��������, � ����� ����� ������/������� � ����-�������.

������ 1.0: AutoEdit � �����������, �������� ����������, JSON fallback. 
������ �������� ��� ������� �� ������ MoonLoader ��� ��������� ��������� ��������!

���������:
1. ���������� MoonLoader v0.26+.
2. ��������� ���� ���� � ����� `GTA San Andreas/moonloader/`.
3. ������� ����: ������� F11 ��� ������� /helper.
]]

script_name("Helper Core")
script_author("Advance RP Helper")
script_description("Universal Helper Platform for Advance RP")
script_dependencies("SAMP.Lua", "mimgui")
script_properties("work-in-pause")

local SCRIPT_VERSION = 'v1.7 (05.07.2026)'
local imgui = require 'mimgui'
local ffi = require 'ffi'
-- Safe string copy with bounds check (prevents FFI buffer overflow crash)
local function safeStrCopy(dst, src, dstSize)
    if src == nil then dst[0] = 0 return end
    local s = type(src) == "string" and src or ffi.string(src)
    if #s >= dstSize then s = s:sub(1, dstSize - 1) end
    ffi.copy(dst, s, #s)
    dst[#s] = 0  -- null terminator
end
local sampev = require 'lib.samp.events'
local encoding = require 'encoding'
local json = nil
local ok_json = pcall(function() json = require 'json' end)
if not ok_json or not json then
-- Minimal JSON fallback for save/load
json = {
encode = function(t)
local function enc(v)
if type(v) == 'string' then
return '"' .. v:gsub('"', '\\"') .. '"'
elseif type(v) == 'number' then
return tostring(v)
elseif type(v) == 'boolean' then
return v and 'true' or 'false'
elseif type(v) == 'table' then
local is_array = true
local arr = {}
local obj = {}
for k, val in pairs(v) do
if type(k) == 'number' then
arr[k] = enc(val)
else
is_array = false
obj[#obj+1] = '"' .. tostring(k) .. '": ' .. enc(val)
end
end
if is_array and #arr > 0 then
return '[' .. table.concat(arr, ',') .. ']'
else
return '{' .. table.concat(obj, ',') .. '}'
end
end
return 'null'
end
return enc(t)
end,
decode = function(s)
-- Simple JSON decoder
local pos = 1
local function val()
local c = s:match('^%s*([%[{"])', pos)
if c == '{' then
pos = pos + 1
local t = {}
while true do
pos = s:match('^%s*', pos):len() + pos
if s:sub(pos, pos) == '}' then pos = pos + 1 break end
local key = s:match('^"([^"]*)"', pos)
pos = s:match('^"[^"]*"%s*:%s*', pos):len() + pos
t[key] = val()
pos = s:match('^%s*,%s*', pos) and pos + s:match('^%s*,%s*', pos):len() or pos
end
return t
elseif c == '[' then
pos = pos + 1
local t = {}
while true do
pos = s:match('^%s*', pos):len() + pos
if s:sub(pos, pos) == ']' then pos = pos + 1 break end
t[#t+1] = val()
pos = s:match('^%s*,%s*', pos) and pos + s:match('^%s*,%s*', pos):len() or pos
end
return t
elseif c == '"' then
local str = s:match('^"([^"]*)"', pos)
pos = s:match('^"[^"]*"', pos):len() + pos
return str
else
local num = s:match('^%-?%d+%.?%d*', pos)
if num then pos = pos + num:len() return tonumber(num) end
local bool = s:match('^(true|false)', pos)
if bool then pos = pos + bool:len() return bool == 'true' end
pos = pos + 4
return nil
end
end
return val()
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

-- �������������� ���������� ��� GUI
local show_main_window = imgui.new.bool(false)
local active_module_idx = 1

-- ���� � ����� ������
local db_path = getWorkingDirectory() .. "/config/helper_db.json"
local rules_path = getWorkingDirectory() .. "/config/helper_mm_rules.json"
local settings_path = getWorkingDirectory() .. "/config/helper_settings.json"

local player_db = {}
local current_server_idx = imgui.new.int(0)
local server_names = {u8"Advance RP", u8"Diamond RP", u8"Arizona RP", u8"Evolve RP"}

-- ���������� ��� ������ "���� � ������"
local call_active = false
local call_worker_running = false
local call_delay = imgui.new.int(7000)
local max_calls_session = imgui.new.int(50)
local call_current_nick = ""
local call_current_phone = ""
local last_called = {}
local call_cooldown_hours = imgui.new.int(1)  -- don't re-call same person for N hours
local call_no_repeat = imgui.new.bool(true)  -- skip anyone in call history regardless of cooldown
local call_history_show = imgui.new.bool(false)  -- toggle call history view
local online_list_cache = {}
local online_list_cache_time = 0
local online_nicks_cache = {}
local player_db_queue = {}  -- queue of {sender=, phone=} to apply safely in main loop
local db_sorted_cache = {}  -- cached sorted db_list, rebuilt every 3 seconds
local db_sorted_cache_time = 0
local last_called_queue = {}  -- queue of {nick=, time=} to apply safely in main loop
local online_nicks_initialized = false

-- One-time initialization of online nicks cache.
-- Called from the main loop (wait(0)) where SAMP API is safe.
-- NOT called from lua_thread.create (causes coroutine crash).
local function initOnlineNicksCache()
    if online_nicks_initialized then return end
    if not isSampAvailable() then return end
    local id_ok, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not id_ok then return end
    local max_id = sampGetMaxPlayerId()
    for i = 0, max_id do
        if sampIsPlayerConnected(i) then
            local nick = sampGetPlayerNickname(i)
            if nick and i ~= myid then
                online_nicks_cache[nick] = true
            end
        end
    end
    online_nicks_initialized = true
end

-- Safe online check using cache only (no SAMP API calls)
local function isOnlineCached(nickname)
    return online_nicks_cache[nickname] == true
end

-- ���������� ��� ������ "MM Editor" (��� ��������)
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
local ae_ignore_enter = 0  -- grace period frames to ignore stale Enter from chat command
local ae_enter_was_down = false  -- track Enter key release before allowing send
local ae_esc_was_down = false  -- track Esc key release before allowing reject
local ad_history = {}
local ad_history_path = getFolderPath(0x1C) .. "\\helper_ad_history.json"
local ae_show_history = imgui.new.bool(false)
local ae_open_queue = nil  -- queued dialog open from onShowDialog (processed in main loop to avoid race with render thread)

local function loadAdHistory()
local file = io.open(ad_history_path, "r")
if file then
local content = file:read("*a")
file:close()
local ok, parsed = pcall(json.decode, content)
if ok and parsed then ad_history = parsed end
end
end

local function saveAdHistory()
local file = io.open(ad_history_path, "w")
if file then
file:write(json.encode(ad_history))
file:close()
end
end

local function addAdToHistory(ad_text)
if ad_text and ad_text ~= "" and ad_text ~= "���" then
for _, h in ipairs(ad_history) do
if h == ad_text then return end
end
table.insert(ad_history, 1, ad_text)
if #ad_history > 20 then table.remove(ad_history, #ad_history) end
lua_thread.create(function() saveAdHistory() end)
end
end

-- ������������: ���������� ������ ������������ � AutoEdit ��� ��������� �� ����� �������
local edit_corrections = {}
local corrections_path = getFolderPath(0x1C) .. "\\helper_edit_corrections.json"

local function loadCorrections()
local file = io.open(corrections_path, "r")
if file then
local content = file:read("*a")
file:close()
local ok, parsed = pcall(json.decode, content)
if ok and parsed then edit_corrections = parsed end
end
end

local function saveCorrections()
local file = io.open(corrections_path, "w")
if file then
file:write(json.encode(edit_corrections))
file:close()
end
end

-- ���������� ���������� ������� ����� ����� �������� (����� �������/������� �������������)
local function wordDiffMiddle(a, b)
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

-- ���������� ������, ���� ��� ��������, �������� � ��� �� ��������
local function recordEditCorrection(suggested, final_text)
if suggested == final_text then return end
local a_mid, b_mid = wordDiffMiddle(suggested, final_text)
if a_mid == "" or b_mid == "" or a_mid == b_mid then return end
if #a_mid > 30 or #b_mid > 100 then return end
for _, c in ipairs(edit_corrections) do
if c.abbr == a_mid and c.repl == b_mid then return end
end
table.insert(edit_corrections, 1, {abbr = a_mid, repl = b_mid})
if #edit_corrections > 20 then table.remove(edit_corrections, #edit_corrections) end
lua_thread.create(function() saveCorrections() end)
end

loadAdHistory()
loadCorrections()
local test_input = imgui.new.char[129]("")
local test_output = ""
local mm_rules = {
-- ������
{abbreviation = "�����", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "������", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "���", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "����", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "����", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "����", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "�����", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "�������", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "������", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "������", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "������", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "�����", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "�����", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "������", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "����", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "����", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "����", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "�������", replacement = "�/� ����� \"Super GT\""},
{abbreviation = "��������", replacement = "�/� ����� \"Super GT\""},
{abbreviation = "��������", replacement = "�/� ����� \"Super GT\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stinger\""},
{abbreviation = "��������", replacement = "�/� ����� \"Stinger\""},
{abbreviation = "��������", replacement = "�/� ����� \"Stinger\""},
{abbreviation = "������", replacement = "�/� ����� \"Comet\""},
{abbreviation = "������", replacement = "�/� ����� \"Comet\""},
{abbreviation = "������", replacement = "�/� ����� \"Comet\""},
{abbreviation = "������", replacement = "�/� ����� \"Comet\""},
{abbreviation = "������", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "�������", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "�������", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "�������", replacement = "�/� ����� \"Champion\""},
{abbreviation = "��������", replacement = "�/� ����� \"Champion\""},
{abbreviation = "��������", replacement = "�/� ����� \"Champion\""},
{abbreviation = "�����", replacement = "�/� ����� \"Alpha\""},
{abbreviation = "�����", replacement = "�/� ����� \"Alpha\""},
{abbreviation = "�����", replacement = "�/� ����� \"Alpha\""},
{abbreviation = "������", replacement = "�/� ����� \"Clover\""},
{abbreviation = "�������", replacement = "�/� ����� \"Clover\""},
{abbreviation = "�������", replacement = "�/� ����� \"Clover\""},
{abbreviation = "�������", replacement = "�/� ����� \"Clover\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sabre\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sabre\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sabre\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sabre\""},
{abbreviation = "����", replacement = "�/� ����� \"Voodoo\""},
{abbreviation = "����", replacement = "�/� ����� \"Voodoo\""},
{abbreviation = "�������", replacement = "�/� ����� \"Slamvan\""},
{abbreviation = "��������", replacement = "�/� ����� \"Slamvan\""},
{abbreviation = "��������", replacement = "�/� ����� \"Slamvan\""},
{abbreviation = "���������", replacement = "�/� ����� \"Remington\""},
{abbreviation = "����������", replacement = "�/� ����� \"Remington\""},
{abbreviation = "����������", replacement = "�/� ����� \"Remington\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bravura\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bravura\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bravura\""},
{abbreviation = "�����", replacement = "�/� ����� \"Blade\""},
{abbreviation = "������", replacement = "�/� ����� \"Blade\""},
{abbreviation = "������", replacement = "�/� ����� \"Blade\""},
{abbreviation = "������", replacement = "�/� ����� \"Tampa\""},
{abbreviation = "������", replacement = "�/� ����� \"Tampa\""},
{abbreviation = "�������", replacement = "�/� ����� \"Tornado\""},
{abbreviation = "��������", replacement = "�/� ����� \"Tornado\""},
{abbreviation = "��������", replacement = "�/� ����� \"Tornado\""},
{abbreviation = "������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "������", replacement = "�/� ����� \"Elegy\""},
{abbreviation = "������", replacement = "�/� ����� \"Elegy\""},
{abbreviation = "�����", replacement = "�/� ����� \"Elegy\""},
{abbreviation = "������", replacement = "�/� ����� \"Elegy\""},
{abbreviation = "�����", replacement = "�/� ����� \"Elegy\""},
{abbreviation = "����", replacement = "�/� ����� \"Flash\""},
{abbreviation = "�����", replacement = "�/� ����� \"Flash\""},
{abbreviation = "�����", replacement = "�/� ����� \"Flash\""},
{abbreviation = "�������", replacement = "�/� ����� \"Jester\""},
{abbreviation = "��������", replacement = "�/� ����� \"Jester\""},
{abbreviation = "��������", replacement = "�/� ����� \"Jester\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stratum\""},
{abbreviation = "��������", replacement = "�/� ����� \"Stratum\""},
{abbreviation = "��������", replacement = "�/� ����� \"Stratum\""},
{abbreviation = "����", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "�����", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "�����", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "�����", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "���������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "����������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "�����", replacement = "�/� ����� \"Picador\""},
{abbreviation = "������", replacement = "�/� ����� \"Picador\""},
{abbreviation = "������", replacement = "�/� ����� \"Picador\""},
{abbreviation = "�����", replacement = "�/� ����� \"Solair\""},
{abbreviation = "������", replacement = "�/� ����� \"Solair\""},
{abbreviation = "������", replacement = "�/� ����� \"Solair\""},
{abbreviation = "������", replacement = "�/� ����� \"Windsor\""},
{abbreviation = "�������", replacement = "�/� ����� \"Windsor\""},
{abbreviation = "�������", replacement = "�/� ����� \"Windsor\""},
{abbreviation = "������", replacement = "�/� ����� \"Stafford\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stafford\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stafford\""},
{abbreviation = "������", replacement = "�/� ����� \"Huntley\""},
{abbreviation = "�������", replacement = "�/� ����� \"Huntley\""},
{abbreviation = "�������", replacement = "�/� ����� \"Huntley\""},
{abbreviation = "������", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "�������", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "�������", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "�����", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "������", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "��������", replacement = "�/� ����� \"Yosemite\""},
{abbreviation = "���������", replacement = "�/� ����� \"Yosemite\""},
{abbreviation = "������", replacement = "�/� ����� \"Bobcat\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bobcat\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bobcat\""},
{abbreviation = "�������", replacement = "�/� ����� \"Premier\""},
{abbreviation = "��������", replacement = "�/� ����� \"Premier\""},
{abbreviation = "��������", replacement = "�/� ����� \"Premier\""},
{abbreviation = "������", replacement = "�/� ����� \"Stretch\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stretch\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stretch\""},
{abbreviation = "�������", replacement = "�/� ����� \"Admiral\""},
{abbreviation = "��������", replacement = "�/� ����� \"Admiral\""},
{abbreviation = "��������", replacement = "�/� ����� \"Admiral\""},
{abbreviation = "���������", replacement = "�/� ����� \"Washington\""},
{abbreviation = "����������", replacement = "�/� ����� \"Washington\""},
{abbreviation = "����������", replacement = "�/� ����� \"Washington\""},
{abbreviation = "������", replacement = "�/� ����� \"Willard\""},
{abbreviation = "�������", replacement = "�/� ����� \"Willard\""},
{abbreviation = "�������", replacement = "�/� ����� \"Emperor\""},
{abbreviation = "��������", replacement = "�/� ����� \"Emperor\""},
{abbreviation = "��������", replacement = "�/� ����� \"Emperor\""},
{abbreviation = "�������", replacement = "�/� ����� \"Elegant\""},
{abbreviation = "��������", replacement = "�/� ����� \"Elegant\""},
{abbreviation = "��������", replacement = "�/� ����� \"Elegant\""},
{abbreviation = "��������", replacement = "�/� ����� \"Glendale\""},
{abbreviation = "���������", replacement = "�/� ����� \"Glendale\""},
{abbreviation = "���������", replacement = "�/� ����� \"Glendale\""},
{abbreviation = "������", replacement = "�/� ����� \"Manana\""},
{abbreviation = "������", replacement = "�/� ����� \"Manana\""},
{abbreviation = "������", replacement = "�/� ����� \"Manana\""},
{abbreviation = "������", replacement = "�/� ����� \"Manana\""},
{abbreviation = "������", replacement = "�/� ����� \"Blista\""},
{abbreviation = "������", replacement = "�/� ����� \"Blista\""},
{abbreviation = "������", replacement = "�/� ����� \"Blista\""},
{abbreviation = "������", replacement = "�/� ����� \"Fortune\""},
{abbreviation = "�������", replacement = "�/� ����� \"Fortune\""},
{abbreviation = "�������", replacement = "�/� ����� \"Fortune\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sentinel\""},
{abbreviation = "���������", replacement = "�/� ����� \"Sentinel\""},
{abbreviation = "���������", replacement = "�/� ����� \"Sentinel\""},
{abbreviation = "�����", replacement = "�/� ����� \"Buccaneer\""},
{abbreviation = "������", replacement = "�/� ����� \"Buccaneer\""},
{abbreviation = "������", replacement = "�/� ����� \"Buccaneer\""},
{abbreviation = "������", replacement = "�/� ����� \"Hermes\""},
{abbreviation = "�������", replacement = "�/� ����� \"Hermes\""},
{abbreviation = "�������", replacement = "�/� ����� \"Hermes\""},
{abbreviation = "���������", replacement = "�/� ����� \"Majestic\""},
{abbreviation = "����������", replacement = "�/� ����� \"Majestic\""},
{abbreviation = "������", replacement = "�/� ����� \"Nevada\""},
{abbreviation = "������", replacement = "�/� ����� \"Nevada\""},
{abbreviation = "������", replacement = "�/� ����� \"Nevada\""},
{abbreviation = "�����", replacement = "�/� ����� \"Primo\""},
{abbreviation = "������", replacement = "�/� ����� \"Primo\""},
{abbreviation = "��������", replacement = "�/� ����� \"Hotknife\""},
{abbreviation = "���������", replacement = "�/� ����� \"Hotknife\""},
{abbreviation = "���������", replacement = "�/� ����� \"Hotknife\""},
{abbreviation = "����", replacement = "�/� ����� \"Dune\""},
{abbreviation = "����", replacement = "�/� ����� \"Dune\""},
{abbreviation = "����", replacement = "�/� ����� \"Dune\""},
{abbreviation = "����", replacement = "�/� ����� \"Dune\""},
{abbreviation = "������", replacement = "�/� ����� \"Monster\""},
{abbreviation = "�������", replacement = "�/� ����� \"Monster\""},
{abbreviation = "�������", replacement = "�/� ����� \"Monster\""},
{abbreviation = "�������", replacement = "�/� ����� \"Monster\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bandito\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bandito\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bandito\""},
{abbreviation = "������", replacement = "�/� ����� \"Calcium\""},
{abbreviation = "�������", replacement = "�/� ����� \"Calcium\""},
{abbreviation = "�������", replacement = "�/� ����� \"Calcium\""},
{abbreviation = "�������", replacement = "�/� ����� \"Patriot\""},
{abbreviation = "��������", replacement = "�/� ����� \"Patriot\""},
{abbreviation = "��������", replacement = "�/� ����� \"Patriot\""},
{abbreviation = "�������", replacement = "�/� ����� \"Hotring\""},
{abbreviation = "��������", replacement = "�/� ����� \"Hotring\""},
{abbreviation = "��������", replacement = "�/� ����� \"Hotring\""},
{abbreviation = "���������", replacement = "�/� ����� \"Hotring\""},
{abbreviation = "����������", replacement = "�/� ����� \"Hotring\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bandito\""},
{abbreviation = "������", replacement = "�/� ����� \"Bandito\""},
{abbreviation = "�����", replacement = "�/� ����� \"Crane\""},
{abbreviation = "������", replacement = "�/� ����� \"Crane\""},
{abbreviation = "��������", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "���������", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "���������", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "������", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�������", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "��������", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "������", replacement = "�/� ����� \"Clover\""},
{abbreviation = "������", replacement = "�/� ����� \"Clover\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "���������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Tampa\""},
{abbreviation = "�������", replacement = "�/� ����� \"Fortune\""},
{abbreviation = "��������", replacement = "�/� ����� \"Fortune\""},
{abbreviation = "�������", replacement = "�/� ����� \"Elegant\""},
{abbreviation = "��������", replacement = "�/� ����� \"Elegant\""},
{abbreviation = "�����", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "������", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "������", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "��350", replacement = "�/� ����� \"ZR-350\""},
{abbreviation = "��350�", replacement = "�/� ����� \"ZR-350\""},
{abbreviation = "��", replacement = "�/� ����� \"ZR-350\""},
{abbreviation = "���", replacement = "�/� ����� \"ZR-350\""},
{abbreviation = "��������", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "���������", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "�����", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "������", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "�����", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "�����", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "�������", replacement = "�/� ����� \"Chevrolet\""},
{abbreviation = "��������", replacement = "�/� ����� \"Chevrolet\""},
{abbreviation = "�����", replacement = "�/� ����� \"Lamborghini\""},
{abbreviation = "�����", replacement = "�/� ����� \"Lamborghini\""},
{abbreviation = "���", replacement = "�/� ����� \"BMW\""},
{abbreviation = "����", replacement = "�/� ����� \"BMW\""},
{abbreviation = "����", replacement = "�/� ����� \"Mercedes\""},
{abbreviation = "�����", replacement = "�/� ����� \"Mercedes\""},
{abbreviation = "�����", replacement = "�/� ����� \"Mercedes\""},
{abbreviation = "������", replacement = "�/� ����� \"Toyota\""},
{abbreviation = "������", replacement = "�/� ����� \"Toyota\""},
{abbreviation = "������", replacement = "�/� ����� \"Toyota\""},
{abbreviation = "����", replacement = "�/� ����� \"Audi\""},
{abbreviation = "�����", replacement = "�/� ����� \"Audi\""},
{abbreviation = "�����", replacement = "�/� ����� \"Porsche\""},
{abbreviation = "������", replacement = "�/� ����� \"Porsche\""},
{abbreviation = "�������", replacement = "�/� ����� \"Ferrari\""},
{abbreviation = "��������", replacement = "�/� ����� \"Ferrari\""},
{abbreviation = "������", replacement = "�/� ����� \"Lexus\""},
{abbreviation = "�������", replacement = "�/� ����� \"Lexus\""},
{abbreviation = "�����", replacement = "�/� ����� \"Honda\""},
{abbreviation = "�����", replacement = "�/� ����� \"Honda\""},
{abbreviation = "�����", replacement = "�/� ����� \"Honda\""},
{abbreviation = "������", replacement = "�/� ����� \"Nissan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Nissan\""},
{abbreviation = "�����", replacement = "�/� ����� \"Mazda\""},
{abbreviation = "�����", replacement = "�/� ����� \"Mazda\""},
{abbreviation = "�����", replacement = "�/� ����� \"Mazda\""},
{abbreviation = "������", replacement = "�/� ����� \"Subaru\""},
{abbreviation = "�������", replacement = "�/� ����� \"Subaru\""},
{abbreviation = "���������", replacement = "�/� ����� \"Mitsubishi\""},
{abbreviation = "��������", replacement = "�/� ����� \"Chrysler\""},
{abbreviation = "���������", replacement = "�/� ����� \"Chrysler\""},
{abbreviation = "����", replacement = "�/� ����� \"Ford\""},
{abbreviation = "�����", replacement = "�/� ����� \"Ford\""},
{abbreviation = "�����", replacement = "�/� ����� \"Ford\""},
{abbreviation = "������", replacement = "�/� ����� \"Volvo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Buick\""},
{abbreviation = "������", replacement = "�/� ����� \"Buick\""},
{abbreviation = "��������", replacement = "�/� ����� \"Cadillac\""},
{abbreviation = "���������", replacement = "�/� ����� \"Cadillac\""},
{abbreviation = "�������", replacement = "�/� ����� \"Pontiac\""},
{abbreviation = "��������", replacement = "�/� ����� \"Pontiac\""},
{abbreviation = "����", replacement = "�/� ����� \"Dodge\""},
{abbreviation = "�����", replacement = "�/� ����� \"Dodge\""},
{abbreviation = "�����", replacement = "�/� ����� \"Dodge\""},
{abbreviation = "�����", replacement = "�/� ����� \"Jaguar\""},
{abbreviation = "������", replacement = "�/� ����� \"Jaguar\""},
{abbreviation = "������", replacement = "�/� ����� \"Bentley\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bentley\""},
{abbreviation = "���������", replacement = "�/� ����� \"Rolls-Royce\""},
{abbreviation = "��������", replacement = "�/� ����� \"Maserati\""},
{abbreviation = "�����������", replacement = "�/� ����� \"Aston Martin\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bugatti\""},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "���", replacement = "�/�"},
{abbreviation = "����", replacement = "�/�"},
{abbreviation = "����", replacement = "�/�"},
{abbreviation = "������", replacement = "�/�"},
{abbreviation = "������", replacement = "�/�"},
{abbreviation = "������", replacement = "�/�"},
{abbreviation = "������", replacement = "�/�"},
{abbreviation = "����", replacement = "�/�"},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
-- ����
{abbreviation = "���", replacement = "���� ����� \"NRG-500\""},
{abbreviation = "����", replacement = "���� ����� \"NRG-500\""},
{abbreviation = "����", replacement = "���� ����� \"NRG-500\""},
{abbreviation = "����", replacement = "���� ����� \"NRG-500\""},
{abbreviation = "����", replacement = "���� ����� \"NRG-500\""},
{abbreviation = "����", replacement = "���� ����� \"Freeway\""},
{abbreviation = "����", replacement = "���� ����� \"Freeway\""},
{abbreviation = "����", replacement = "���� ����� \"Freeway\""},
{abbreviation = "����", replacement = "���� ����� \"Wayfarer\""},
{abbreviation = "�����", replacement = "���� ����� \"Wayfarer\""},
{abbreviation = "�����", replacement = "���� ����� \"Wayfarer\""},
{abbreviation = "����", replacement = "���� ����� \"Sanchez\""},
{abbreviation = "������", replacement = "���� ����� \"Sanchez\""},
{abbreviation = "�����", replacement = "���� ����� \"Sanchez\""},
{abbreviation = "�����", replacement = "���� ����� \"Sanchez\""},
{abbreviation = "���", replacement = "���� ����� \"PCJ-600\""},
{abbreviation = "����", replacement = "���� ����� \"PCJ-600\""},
{abbreviation = "����", replacement = "���� ����� \"PCJ-600\""},
{abbreviation = "���", replacement = "���� ����� \"FCR-900\""},
{abbreviation = "����", replacement = "���� ����� \"FCR-900\""},
{abbreviation = "����", replacement = "���� ����� \"FCR-900\""},
{abbreviation = "������", replacement = "���� ����� \"Faggio\""},
{abbreviation = "�����", replacement = "���� ����� \"Faggio\""},
{abbreviation = "������", replacement = "���� ����� \"Faggio\""},
{abbreviation = "��", replacement = "���� ����� \"BF-400\""},
{abbreviation = "���", replacement = "���� ����� \"BF-400\""},
{abbreviation = "������", replacement = "���� ����� \"Enduro\""},
{abbreviation = "������", replacement = "���� ����� \"Enduro\""},
{abbreviation = "�����", replacement = "���� ����� \"Angel\""},
{abbreviation = "������", replacement = "���� ����� \"Angel\""},
-- ����������
{abbreviation = "���", replacement = "��������� ����� \"BMX\""},
{abbreviation = "����", replacement = "��������� ����� \"BMX\""},
{abbreviation = "����", replacement = "��������� ����� \"BMX\""},
{abbreviation = "����", replacement = "��������� ����� \"BMX\""},
{abbreviation = "�����", replacement = "��������� ����� \"BMX\""},
{abbreviation = "�����", replacement = "��������� ����� \"BMX\""},
{abbreviation = "�����", replacement = "���������"},
{abbreviation = "������", replacement = "���������"},
{abbreviation = "������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
-- ������
{abbreviation = "��", replacement = "Los Santos"},
{abbreviation = "��� ������", replacement = "Los Santos"},
{abbreviation = "��", replacement = "San Fierro"},
{abbreviation = "��������", replacement = "San Fierro"},
{abbreviation = "��� ������", replacement = "San Fierro"},
{abbreviation = "��", replacement = "Las Venturas"},
{abbreviation = "las venturas", replacement = "Las Venturas"},
{abbreviation = "lv", replacement = "Las Venturas"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
-- ������
{abbreviation = "�����", replacement = "East Los Santos"},
{abbreviation = "������", replacement = "East Los Santos"},
{abbreviation = "����", replacement = "East Los Santos"},
{abbreviation = "���", replacement = "East Los Santos"},
{abbreviation = "������", replacement = "Ganton"},
{abbreviation = "�������", replacement = "Ganton"},
{abbreviation = "�������", replacement = "Ganton"},
{abbreviation = "���", replacement = "Idlewood"},
{abbreviation = "������", replacement = "Idlewood"},
{abbreviation = "����", replacement = "Jefferson"},
{abbreviation = "���������", replacement = "Jefferson"},
{abbreviation = "����", replacement = "Glen Park"},
{abbreviation = "�����", replacement = "Glen Park"},
{abbreviation = "�����", replacement = "Verona Beach"},
{abbreviation = "������", replacement = "Verona Beach"},
{abbreviation = "������", replacement = "Verona Beach"},
{abbreviation = "����", replacement = "Willowfield"},
{abbreviation = "������", replacement = "Willowfield"},
{abbreviation = "��������", replacement = "El Corona"},
{abbreviation = "�����", replacement = "El Corona"},
{abbreviation = "�����", replacement = "El Corona"},
{abbreviation = "�������", replacement = "Commerce"},
{abbreviation = "�������", replacement = "Commerce"},
{abbreviation = "������", replacement = "Market"},
{abbreviation = "�������", replacement = "Market"},
{abbreviation = "����", replacement = "Chinatown"},
{abbreviation = "��������", replacement = "Palomino Creek"},
{abbreviation = "��������", replacement = "Palomino Creek"},
{abbreviation = "����������", replacement = "Montgomery"},
{abbreviation = "����������", replacement = "Montgomery"},
{abbreviation = "��������", replacement = "Dillimore"},
{abbreviation = "���������", replacement = "Dillimore"},
{abbreviation = "�������", replacement = "Blueberry"},
{abbreviation = "��������", replacement = "Blueberry"},
{abbreviation = "���������", replacement = "Chinatown SF"},
{abbreviation = "�������", replacement = "Doherty"},
{abbreviation = "�����", replacement = "Kings"},
{abbreviation = "������", replacement = "Kings"},
{abbreviation = "��������", replacement = "Paradiso"},
{abbreviation = "�����", replacement = "The Strip"},
{abbreviation = "������", replacement = "The Strip"},
{abbreviation = "������", replacement = "Rockshore"},
{abbreviation = "�������", replacement = "Rockshore"},
{abbreviation = "�����", replacement = "Pilgrim"},
{abbreviation = "������", replacement = "Pilgrim"},
{abbreviation = "������", replacement = "Avalon"},
{abbreviation = "�������", replacement = "Avalon"},
{abbreviation = "������", replacement = "Dragons Dojo"},
{abbreviation = "�������", replacement = "Dragons Dojo"},
-- ������ (�������/������/������)
{abbreviation = "�����", replacement = "Flint County"},
{abbreviation = "������", replacement = "Flint County"},
{abbreviation = "����� ������", replacement = "Flint County"},
{abbreviation = "����� �������", replacement = "Flint County"},
{abbreviation = "��", replacement = "Palomino Creek"},
{abbreviation = "�������", replacement = "Palomino Creek"},
{abbreviation = "��������", replacement = "Palomino Creek"},
{abbreviation = "�������� ����", replacement = "Palomino Creek"},
{abbreviation = "��������", replacement = "Blueberry"},
{abbreviation = "��� ���������", replacement = "El Quebrados"},
{abbreviation = "���������", replacement = "El Quebrados"},
{abbreviation = "���� ������", replacement = "Fort Carson"},
{abbreviation = "���� �������", replacement = "Fort Carson"},
{abbreviation = "����", replacement = "Fort Carson"},
{abbreviation = "������", replacement = "Fort Carson"},
{abbreviation = "����� ������", replacement = "Tierra Robada"},
{abbreviation = "�����", replacement = "Tierra Robada"},
{abbreviation = "������", replacement = "Tierra Robada"},
{abbreviation = "����� ����", replacement = "Angel Pine"},
{abbreviation = "�����", replacement = "Angel Pine"},
{abbreviation = "���� ���", replacement = "North Rock"},
{abbreviation = "����", replacement = "North Rock"},
{abbreviation = "�������", replacement = "Ashberry"},
{abbreviation = "������", replacement = "Hilltop"},
{abbreviation = "�������", replacement = "Hilltop"},
{abbreviation = "�����", replacement = "Valle Ocultado"},
{abbreviation = "����� ��������", replacement = "Valle Ocultado"},
{abbreviation = "��������", replacement = "Valle Ocultado"},
{abbreviation = "���� ���� �����", replacement = "Arco del Oeste"},
{abbreviation = "����", replacement = "Arco del Oeste"},
{abbreviation = "�������", replacement = "Bayside"},
{abbreviation = "�������", replacement = "Bayside"},
{abbreviation = "�� ��������", replacement = "El Quebrados"},
{abbreviation = "��� ��������", replacement = "El Quebrados"},
{abbreviation = "���� �����", replacement = "Green Palms"},
{abbreviation = "����", replacement = "Green Palms"},
{abbreviation = "�����", replacement = "Green Palms"},
{abbreviation = "����� �������", replacement = "Union Station"},
{abbreviation = "�����", replacement = "Union Station"},
{abbreviation = "����", replacement = "Palomino Creek"},
{abbreviation = "������", replacement = "Flint County"},
{abbreviation = "�������", replacement = "Whitewood"},
{abbreviation = "������� ���", replacement = "Whitewood Beach"},
{abbreviation = "��������", replacement = "Whitewood"},
{abbreviation = "�����", replacement = "Prickle Pine"},
{abbreviation = "����� ����", replacement = "Prickle Pine"},
{abbreviation = "�����", replacement = "Prickle Pine"},
{abbreviation = "������ ����", replacement = "Rockshore West"},
{abbreviation = "��� �����", replacement = "Old Venturas"},
{abbreviation = "��������", replacement = "Old Venturas"},
{abbreviation = "��� �����", replacement = "New Venturas"},
{abbreviation = "��������", replacement = "New Venturas"},
{abbreviation = "�������� ���", replacement = "Rockshore"},
{abbreviation = "��������", replacement = "Rockshore"},
{abbreviation = "�������", replacement = "Pilbox"},
{abbreviation = "��������", replacement = "Pilbox"},
{abbreviation = "�����", replacement = "Royal Casino"},
{abbreviation = "������", replacement = "Royal Casino"},
{abbreviation = "��������", replacement = "Caligulas Palace"},
{abbreviation = "��������", replacement = "Caligulas Palace"},
{abbreviation = "�����", replacement = "Pirates in Mens Pants"},
{abbreviation = "������", replacement = "Pirates in Mens Pants"},
{abbreviation = "�����", replacement = "Visage"},
{abbreviation = "������", replacement = "Visage"},

-- ������������
{abbreviation = "��", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "���", replacement = "������"},
{abbreviation = "�����", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "������������"},
{abbreviation = "������", replacement = "������������"},
{abbreviation = "������", replacement = "������������"},
{abbreviation = "�������", replacement = "������������"},
{abbreviation = "�������", replacement = "������������"},
{abbreviation = "�������", replacement = "������������"},
{abbreviation = "��������", replacement = "������������"},
{abbreviation = "��������", replacement = "������������"},
{abbreviation = "��������", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "��������", replacement = "���"},
{abbreviation = "�������", replacement = "���"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "���", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�����", replacement = "�������"},
{abbreviation = "�����", replacement = "�������"},
{abbreviation = "�����", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "���������� ���"},
{abbreviation = "�������", replacement = "���������� ���"},
{abbreviation = "�������", replacement = "���������� ���"},
{abbreviation = "�������", replacement = "���������� ���"},
{abbreviation = "��������", replacement = "���������� ���"},
{abbreviation = "���������", replacement = "���������� ���"},
{abbreviation = "���", replacement = "���������� ���"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������������", replacement = "��������������"},
{abbreviation = "��������������", replacement = "��������������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "�������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
-- ��������
{abbreviation = "���", replacement = "SIM-card"},
{abbreviation = "�����", replacement = "SIM-card"},
{abbreviation = "�����", replacement = "SIM-card"},
{abbreviation = "�����", replacement = "SIM-card"},
{abbreviation = "���", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�����", replacement = "���. �����"},
{abbreviation = "������", replacement = "���. �����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "����", replacement = "������"},
{abbreviation = "�����", replacement = "������"},
{abbreviation = "�����", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "���", replacement = "��������� \"���\""},
{abbreviation = "����", replacement = "��������� \"���\""},
{abbreviation = "������", replacement = "��������� \"������\""},
{abbreviation = "�������", replacement = "��������� \"������\""},
{abbreviation = "����", replacement = "��������� \"����\""},
{abbreviation = "����", replacement = "��������� \"����\""},
{abbreviation = "�����", replacement = "��������� \"�����\""},
{abbreviation = "�����", replacement = "��������� \"�����\""},
{abbreviation = "�����", replacement = "��������� \"�����\""},
{abbreviation = "�����", replacement = "��������� \"�����\""},
{abbreviation = "�������", replacement = "��������� \"�������\""},
{abbreviation = "��������", replacement = "��������� \"�������\""},
{abbreviation = "�����", replacement = "�������"},
{abbreviation = "������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "�������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
-- ������
{abbreviation = "����", replacement = "������ \"Desert Eagle\""},
{abbreviation = "�����", replacement = "������ \"Desert Eagle\""},
{abbreviation = "�����", replacement = "������ \"Desert Eagle\""},
{abbreviation = "������", replacement = "������ \"Shotgun\""},
{abbreviation = "�������", replacement = "������ \"Shotgun\""},
{abbreviation = "��������", replacement = "������ \"Shotgun\""},
{abbreviation = "�4", replacement = "������ \"M4\""},
{abbreviation = "�4�1", replacement = "������ \"M4\""},
{abbreviation = "��", replacement = "������ \"AK-47\""},
{abbreviation = "���", replacement = "������ \"AK-47\""},
{abbreviation = "���", replacement = "������ \"SMG\""},
{abbreviation = "����", replacement = "������ \"SMG\""},
{abbreviation = "���", replacement = "������ \"Uzi\""},
{abbreviation = "����", replacement = "������ \"Uzi\""},
{abbreviation = "���", replacement = "������ \"TEC-9\""},
{abbreviation = "����", replacement = "������ \"TEC-9\""},
{abbreviation = "������", replacement = "������ \"Sniper Rifle\""},
{abbreviation = "������", replacement = "������ \"Sniper Rifle\""},
{abbreviation = "���������", replacement = "������ \"Sniper Rifle\""},
{abbreviation = "���������", replacement = "������ \"Sniper Rifle\""},
{abbreviation = "���", replacement = "������ \"Knife\""},
{abbreviation = "����", replacement = "������ \"Knife\""},
{abbreviation = "����", replacement = "������ \"Baseball Bat\""},
{abbreviation = "����", replacement = "������ \"Baseball Bat\""},
{abbreviation = "������", replacement = "��������� \"Katana\""},
{abbreviation = "������", replacement = "��������� \"Katana\""},
{abbreviation = "�������", replacement = "������ \"Grenade\""},
{abbreviation = "�������", replacement = "������ \"Grenade\""},
{abbreviation = "�����", replacement = "������ \"Taser\""},
{abbreviation = "������", replacement = "������ \"Taser\""},
{abbreviation = "��������", replacement = "������ \"Pistol\""},
{abbreviation = "���������", replacement = "������ \"Pistol\""},
{abbreviation = "���������", replacement = "������ \"Desert Eagle\""},
{abbreviation = "����������", replacement = "������ \"Desert Eagle\""},
-- ������
{abbreviation = "��", replacement = ".000.000$"},
{abbreviation = "���", replacement = ".000.000$"},
{abbreviation = "���", replacement = ".000.000$"},
{abbreviation = "��������", replacement = ".000.000.000$"},
{abbreviation = "����", replacement = ".000.000.000$"},
{abbreviation = "���������", replacement = ".000.000.000$"},
{abbreviation = "�������", replacement = ".000.000$"},
{abbreviation = "��������", replacement = ".000.000$"},
-- ����
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�� ������ ����"},
{abbreviation = "�����", replacement = "�� ������ ����"},
{abbreviation = "��������", replacement = "�� ������ ����"},
-- ������
{abbreviation = "�����", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "��������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
-- �����
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "�����", replacement = "�������������"},
{abbreviation = "�����", replacement = "�������������"},
-- ��������
{abbreviation = "�����", replacement = "���. �����"},
{abbreviation = "����", replacement = "���. �����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���", replacement = "��������"},
{abbreviation = "��������", replacement = "���. �����"},
{abbreviation = "��������", replacement = "���. �����"},
-- ������/�����������
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "��������������", replacement = "�������������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������������", replacement = "�������������"},
-- ���������
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "����", replacement = "��������"},
{abbreviation = "����", replacement = "��������"},
{abbreviation = "����", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "��������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "������", replacement = "�/� ����� \"Clover\""},
{abbreviation = "�����", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "�����", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "��������", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "�����", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "��350", replacement = "�/� ����� \"ZR-350\""},
{abbreviation = "��", replacement = "�/� ����� \"ZR-350\""},
{abbreviation = "��������", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "���������", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "������", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�������", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Clover\""},
{abbreviation = "�������", replacement = "�/� ����� \"Elegant\""},
{abbreviation = "��������", replacement = "�/� ����� \"Elegant\""},
{abbreviation = "�������", replacement = "�/� ����� \"Fortune\""},
{abbreviation = "�������", replacement = "�/� ����� \"Tampa\""},
{abbreviation = "��������", replacement = "�/� ����� \"Glendale\""},
{abbreviation = "���������", replacement = "�/� ����� \"Glendale\""},
{abbreviation = "�������", replacement = "�/� ����� \"Emperor\""},
{abbreviation = "��������", replacement = "�/� ����� \"Emperor\""},
{abbreviation = "������", replacement = "�/� ����� \"Nevada\""},
{abbreviation = "������", replacement = "�/� ����� \"Nevada\""},
{abbreviation = "�����", replacement = "�/� ����� \"Primo\""},
{abbreviation = "���������", replacement = "�/� ����� \"Majestic\""},
{abbreviation = "����������", replacement = "�/� ����� \"Majestic\""},
{abbreviation = "������", replacement = "�/� ����� \"Willard\""},
{abbreviation = "�������", replacement = "�/� ����� \"Willard\""},
{abbreviation = "���������", replacement = "�/� ����� \"Washington\""},
{abbreviation = "����������", replacement = "�/� ����� \"Washington\""},
{abbreviation = "�������", replacement = "�/� ����� \"Admiral\""},
{abbreviation = "��������", replacement = "�/� ����� \"Admiral\""},
{abbreviation = "������", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "�������", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "�����", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "������", replacement = "�/� ����� \"Bobcat\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bobcat\""},
{abbreviation = "��������", replacement = "�/� ����� \"Yosemite\""},
{abbreviation = "��������", replacement = "�/� ����� \"Walton\""},
{abbreviation = "���������", replacement = "�/� ����� \"Walton\""},
{abbreviation = "�������", replacement = "�/� ����� \"Tornado\""},
{abbreviation = "��������", replacement = "�/� ����� \"Tornado\""},
{abbreviation = "�����", replacement = "�/� ����� \"Blade\""},
{abbreviation = "������", replacement = "�/� ����� \"Blade\""},
{abbreviation = "������", replacement = "�/� ����� \"Tampa\""},
{abbreviation = "������", replacement = "�/� ����� \"Tampa\""},
{abbreviation = "�����", replacement = "�/� ����� \"Alpha\""},
{abbreviation = "�����", replacement = "�/� ����� \"Alpha\""},
{abbreviation = "������", replacement = "�/� ����� \"Comet\""},
{abbreviation = "������", replacement = "�/� ����� \"Comet\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stinger\""},
{abbreviation = "��������", replacement = "�/� ����� \"Stinger\""},
{abbreviation = "�������", replacement = "�/� ����� \"Super GT\""},
{abbreviation = "��������", replacement = "�/� ����� \"Super GT\""},
{abbreviation = "�������", replacement = "�/� ����� \"Champion\""},
{abbreviation = "��������", replacement = "�/� ����� \"Champion\""},
{abbreviation = "�����", replacement = "�/� ����� \"Buccaneer\""},
{abbreviation = "������", replacement = "�/� ����� \"Buccaneer\""},
{abbreviation = "������", replacement = "�/� ����� \"Hermes\""},
{abbreviation = "�������", replacement = "�/� ����� \"Hermes\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sentinel\""},
{abbreviation = "���������", replacement = "�/� ����� \"Sentinel\""},
{abbreviation = "������", replacement = "�/� ����� \"Fortune\""},
{abbreviation = "�������", replacement = "�/� ����� \"Fortune\""},
{abbreviation = "�������", replacement = "�/� ����� \"Fortune\""},
{abbreviation = "������", replacement = "�/� ����� \"Blista\""},
{abbreviation = "������", replacement = "�/� ����� \"Blista\""},
{abbreviation = "������", replacement = "�/� ����� \"Manana\""},
{abbreviation = "������", replacement = "�/� ����� \"Manana\""},
{abbreviation = "�����", replacement = "�/� ����� \"Picador\""},
{abbreviation = "������", replacement = "�/� ����� \"Picador\""},
{abbreviation = "�����", replacement = "�/� ����� \"Solair\""},
{abbreviation = "������", replacement = "�/� ����� \"Solair\""},
{abbreviation = "������", replacement = "�/� ����� \"Windsor\""},
{abbreviation = "�������", replacement = "�/� ����� \"Windsor\""},
{abbreviation = "������", replacement = "�/� ����� \"Stafford\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stafford\""},
{abbreviation = "������", replacement = "�/� ����� \"Huntley\""},
{abbreviation = "�������", replacement = "�/� ����� \"Huntley\""},
{abbreviation = "�������", replacement = "�/� ����� \"Patriot\""},
{abbreviation = "��������", replacement = "�/� ����� \"Patriot\""},
{abbreviation = "������", replacement = "�/� ����� \"Monster\""},
{abbreviation = "�������", replacement = "�/� ����� \"Monster\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bandito\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bandito\""},
{abbreviation = "������", replacement = "�/� ����� \"Calcium\""},
{abbreviation = "�������", replacement = "�/� ����� \"Calcium\""},
{abbreviation = "�������", replacement = "�/� ����� \"Hotring\""},
{abbreviation = "��������", replacement = "�/� ����� \"Hotring\""},
{abbreviation = "���������", replacement = "�/� ����� \"Hotring\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bandito\""},
{abbreviation = "�����", replacement = "�/� ����� \"Crane\""},
{abbreviation = "������", replacement = "�/� ����� \"Stretch\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stretch\""},
{abbreviation = "�������", replacement = "�/� ����� \"Premier\""},
{abbreviation = "��������", replacement = "�/� ����� \"Premier\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bravura\""},
{abbreviation = "�������", replacement = "�/� ����� \"Bravura\""},
{abbreviation = "�������", replacement = "�/� ����� \"Slamvan\""},
{abbreviation = "��������", replacement = "�/� ����� \"Slamvan\""},
{abbreviation = "���������", replacement = "�/� ����� \"Remington\""},
{abbreviation = "����������", replacement = "�/� ����� \"Remington\""},
{abbreviation = "����", replacement = "�/� ����� \"Flash\""},
{abbreviation = "�����", replacement = "�/� ����� \"Flash\""},
{abbreviation = "�������", replacement = "�/� ����� \"Jester\""},
{abbreviation = "��������", replacement = "�/� ����� \"Jester\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stratum\""},
{abbreviation = "��������", replacement = "�/� ����� \"Stratum\""},
{abbreviation = "����", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "�����", replacement = "�/� ����� \"Uranus\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "���������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "����������", replacement = "�/� ����� \"Sultan RS\""},
{abbreviation = "��������", replacement = "�/� ����� \"Hotknife\""},
{abbreviation = "���������", replacement = "�/� ����� \"Hotknife\""},
{abbreviation = "����", replacement = "�/� ����� \"Dune\""},
{abbreviation = "����", replacement = "�/� ����� \"Dune\""},
{abbreviation = "����", replacement = "�/� ����� \"Dune\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sabre\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sabre\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sabre\""},
{abbreviation = "����", replacement = "�/� ����� \"Voodoo\""},
{abbreviation = "������", replacement = "�/� ����� \"Clover\""},
{abbreviation = "�������", replacement = "�/� ����� \"Clover\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "���", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "����", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "�������", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "�����", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "����", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "����", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "������", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "�������", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "������", replacement = "�/� ����� \"Tahoma\""},
{abbreviation = "������", replacement = "�/� ����� \"Tahoma\""},
{abbreviation = "������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "������", replacement = "�/� ����� \"Elegy\""},
{abbreviation = "������", replacement = "�/� ����� \"Elegy\""},
{abbreviation = "�����", replacement = "�/� ����� \"Elegy\""},
{abbreviation = "������", replacement = "�/� ����� \"Elegy\""},
{abbreviation = "���", replacement = "���� ����� \"NRG-500\""},
{abbreviation = "����", replacement = "���� ����� \"NRG-500\""},
{abbreviation = "����", replacement = "���� ����� \"NRG-500\""},
{abbreviation = "����", replacement = "���� ����� \"NRG-500\""},
{abbreviation = "����", replacement = "���� ����� \"Freeway\""},
{abbreviation = "����", replacement = "���� ����� \"Freeway\""},
{abbreviation = "����", replacement = "���� ����� \"Freeway\""},
{abbreviation = "����", replacement = "���� ����� \"Wayfarer\""},
{abbreviation = "�����", replacement = "���� ����� \"Wayfarer\""},
{abbreviation = "����", replacement = "���� ����� \"Sanchez\""},
{abbreviation = "������", replacement = "���� ����� \"Sanchez\""},
{abbreviation = "�����", replacement = "���� ����� \"Sanchez\""},
{abbreviation = "�����", replacement = "���� ����� \"Sanchez\""},
{abbreviation = "���", replacement = "���� ����� \"PCJ-600\""},
{abbreviation = "����", replacement = "���� ����� \"PCJ-600\""},
{abbreviation = "���", replacement = "���� ����� \"FCR-900\""},
{abbreviation = "����", replacement = "���� ����� \"FCR-900\""},
{abbreviation = "������", replacement = "���� ����� \"Faggio\""},
{abbreviation = "�����", replacement = "���� ����� \"Faggio\""},
{abbreviation = "��", replacement = "���� ����� \"BF-400\""},
{abbreviation = "������", replacement = "���� ����� \"Enduro\""},
{abbreviation = "�����", replacement = "���� ����� \"Angel\""},
{abbreviation = "���", replacement = "��������� \"���\""},
{abbreviation = "������", replacement = "��������� \"������\""},
{abbreviation = "����", replacement = "��������� \"����\""},
{abbreviation = "����", replacement = "��������� \"����\""},
{abbreviation = "�����", replacement = "��������� \"�����\""},
{abbreviation = "�����", replacement = "��������� \"�����\""},
{abbreviation = "�������", replacement = "��������� \"�������\""},
{abbreviation = "����", replacement = "������ \"Desert Eagle\""},
{abbreviation = "�����", replacement = "������ \"Desert Eagle\""},
{abbreviation = "������", replacement = "������ \"Shotgun\""},
{abbreviation = "��������", replacement = "������ \"Shotgun\""},
{abbreviation = "�4", replacement = "������ \"M4\""},
{abbreviation = "��", replacement = "������ \"AK-47\""},
{abbreviation = "���", replacement = "������ \"SMG\""},
{abbreviation = "���", replacement = "������ \"Uzi\""},
{abbreviation = "���", replacement = "������ \"TEC-9\""},
{abbreviation = "������", replacement = "������ \"Sniper Rifle\""},
{abbreviation = "���������", replacement = "������ \"Sniper Rifle\""},
{abbreviation = "���", replacement = "������ \"Knife\""},
{abbreviation = "����", replacement = "������ \"Baseball Bat\""},
{abbreviation = "��������", replacement = "������ \"Pistol\""},
{abbreviation = "���������", replacement = "������ \"Desert Eagle\""},
{abbreviation = "������", replacement = "��������� \"Katana\""},
{abbreviation = "������", replacement = "��������� \"Katana\""},
{abbreviation = "�������", replacement = "������ \"Grenade\""},
{abbreviation = "�����", replacement = "������ \"Taser\""},
{abbreviation = "���", replacement = "��������� ����� \"BMX\""},
{abbreviation = "�������", replacement = "�/� ����� \"Greenwood\""},
{abbreviation = "��������", replacement = "�/� ����� \"Greenwood\""},
{abbreviation = "��������", replacement = "�/� ����� \"Greenwood\""},
{abbreviation = "�������", replacement = "�/� ����� \"Savanna\""},
{abbreviation = "�������", replacement = "�/� ����� \"Savanna\""},
{abbreviation = "�������", replacement = "�/� ����� \"Savanna\""},
{abbreviation = "�����", replacement = "�/� ����� \"Tahoma\""},
{abbreviation = "������", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "����", replacement = "�/� ����� \"Kart\""},
{abbreviation = "�����", replacement = "�/� ����� \"Kart\""},
{abbreviation = "����", replacement = "�/� ����� \"Bravura\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bravura\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bravura\""},
{abbreviation = "���� king", replacement = "�/� ����� \"Sandking\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sandking\""},
{abbreviation = "���������", replacement = "�/� ����� \"Sandking\""},
{abbreviation = "�����", replacement = "�/� ����� \"Mesa\""},
{abbreviation = "����", replacement = "�/� ����� \"Mesa\""},
{abbreviation = "����", replacement = "�/� ����� \"Mesa\""},
{abbreviation = "����", replacement = "�/� ����� \"Mesa\""},
{abbreviation = "������", replacement = "�/� ����� \"Moonbeam\""},
{abbreviation = "�������", replacement = "�/� ����� \"Moonbeam\""},
{abbreviation = "����", replacement = "�/� ����� \"Pony\""},
{abbreviation = "�����", replacement = "�/� ����� \"Pony\""},
{abbreviation = "������", replacement = "�/� ����� \"Regina\""},
{abbreviation = "������", replacement = "�/� ����� \"Regina\""},
{abbreviation = "������", replacement = "�/� ����� \"Regina\""},
{abbreviation = "������", replacement = "�/� ����� \"Romero\""},
{abbreviation = "�������", replacement = "�/� ����� \"Romero\""},
{abbreviation = "������", replacement = "�/� ����� \"Stocker\""},
{abbreviation = "�������", replacement = "�/� ����� \"Stocker\""},
{abbreviation = "������", replacement = "�/� ����� \"Topfun\""},
{abbreviation = "�������", replacement = "�/� ����� \"Topfun\""},
{abbreviation = "�������", replacement = "�/� ����� \"Tractor\""},
{abbreviation = "��������", replacement = "�/� ����� \"Tractor\""},
{abbreviation = "��������", replacement = "�/� ����� \"Tractor\""},
{abbreviation = "�����", replacement = "�/� ����� \"Woodpecker\""},
{abbreviation = "������", replacement = "�/� ����� \"Woodpecker\""},
{abbreviation = "�������", replacement = "�/� ����� \"Flatbed\""},
{abbreviation = "��������", replacement = "�/� ����� \"Flatbed\""},
{abbreviation = "������", replacement = "�/� ����� \"Linerunner\""},
{abbreviation = "�������", replacement = "�/� ����� \"Linerunner\""},
{abbreviation = "���������", replacement = "�/� ����� \"Linerunner\""},
{abbreviation = "����������", replacement = "�/� ����� \"Linerunner\""},
{abbreviation = "���������", replacement = "�/� ����� \"Roadtrain\""},
{abbreviation = "����������", replacement = "�/� ����� \"Roadtrain\""},
{abbreviation = "������", replacement = "�/� ����� \"Tanker\""},
{abbreviation = "�������", replacement = "�/� ����� \"Tanker\""},
{abbreviation = "���", replacement = "�/� ����� \"Dune\""},
{abbreviation = "����", replacement = "�/� ����� \"Dune\""},
{abbreviation = "����", replacement = "�/� ����� \"Dune\""},
{abbreviation = "������2", replacement = "�/� ����� \"Hunter\""},
{abbreviation = "�������2", replacement = "�/� ����� \"Hunter\""},
{abbreviation = "���������", replacement = "�/� ����� \"Sparrow\""},
{abbreviation = "����������", replacement = "�/� ����� \"Sparrow\""},
{abbreviation = "�������", replacement = "�/� ����� \"Sparrow\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sparrow\""},
{abbreviation = "��������", replacement = "�/� ����� \"Leviathan\""},
{abbreviation = "���������", replacement = "�/� ����� \"Leviathan\""},
{abbreviation = "�����", replacement = "�/� ����� \"Cargo\""},
{abbreviation = "������", replacement = "�/� ����� \"Cargo\""},
{abbreviation = "��������", replacement = "�/� ����� \"Andromada\""},
{abbreviation = "���������", replacement = "�/� ����� \"Andromada\""},
{abbreviation = "������", replacement = "�/� ����� \"Nebula\""},
{abbreviation = "������", replacement = "�/� ����� \"Nebula\""},
{abbreviation = "������", replacement = "�/� ����� \"Nebula\""},
{abbreviation = "�����2", replacement = "�/� ����� \"Zombie\""},
{abbreviation = "������", replacement = "�/� ����� \"Zombie\""},
{abbreviation = "����", replacement = "�/� ����� \"Firetruck\""},
{abbreviation = "�����", replacement = "�/� ����� \"Firetruck\""},
{abbreviation = "�������", replacement = "�/� ����� \"Firetruck\""},
{abbreviation = "�������", replacement = "�/� ����� \"Firetruck\""},
{abbreviation = "�������", replacement = "�/� ����� \"Firetruck\""},
{abbreviation = "������", replacement = "�/� ����� \"Ambulance\""},
{abbreviation = "������", replacement = "�/� ����� \"Ambulance\""},
{abbreviation = "������", replacement = "�/� ����� \"Ambulance\""},
{abbreviation = "��������", replacement = "�/� ����� \"Ambulance\""},
{abbreviation = "���������", replacement = "�/� ����� \"Ambulance\""},
{abbreviation = "��������", replacement = "�/� ����� \"Enforcer\""},
{abbreviation = "���������", replacement = "�/� ����� \"Enforcer\""},
{abbreviation = "���", replacement = "�/� ����� \"Rio\""},
{abbreviation = "����", replacement = "�/� ����� \"Rio\""},
{abbreviation = "����", replacement = "�/� ����� \"Astro\""},
{abbreviation = "�����", replacement = "�/� ����� \"Astro\""},
{abbreviation = "�����", replacement = "�/� ����� \"Astro\""},
{abbreviation = "�����", replacement = "�/� ����� \"Astro\""},
{abbreviation = "����2", replacement = "�/� ����� \"Voodoo\""},
{abbreviation = "����2", replacement = "�/� ����� \"Voodoo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Karma\""},
{abbreviation = "�����", replacement = "�/� ����� \"Karma\""},
{abbreviation = "�����", replacement = "�/� ����� \"Karma\""},
{abbreviation = "����", replacement = "�/� ����� \"Cleo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Cleo\""},
{abbreviation = "������", replacement = "�/� ����� \"Fury\""},
{abbreviation = "�������", replacement = "�/� ����� \"Fury\""},
{abbreviation = "�������", replacement = "�/� ����� \"Fury\""},
{abbreviation = "����", replacement = "�/� ����� \"Hakuchou\""},
{abbreviation = "�����", replacement = "�/� ����� \"Hakuchou\""},
{abbreviation = "������", replacement = "�/� ����� \"Hakuchou\""},
{abbreviation = "������", replacement = "�/� ����� \"Hakuchou\""},
{abbreviation = "���", replacement = "�/� ����� \"Neo\""},
{abbreviation = "����", replacement = "�/� ����� \"Neo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Fury\""},
{abbreviation = "������", replacement = "�/� ����� \"Fury\""},
{abbreviation = "�����", replacement = "�/� ����� \"Biff\""},
{abbreviation = "�����", replacement = "�/� ����� \"Biff\""},
{abbreviation = "�����", replacement = "�/� ����� \"Biff\""},
{abbreviation = "����", replacement = "�/� ����� \"Biff\""},
{abbreviation = "����������", replacement = "�/� ����� \"Securicar\""},
{abbreviation = "�����������", replacement = "�/� ����� \"Securicar\""},
{abbreviation = "�����", replacement = "�/� ����� \"Securicar\""},
{abbreviation = "������", replacement = "�/� ����� \"Securicar\""},
{abbreviation = "���������", replacement = "�/� ����� \"Securicar\""},
{abbreviation = "������", replacement = "�/� ����� \"Mr. Whoopee\""},
{abbreviation = "����", replacement = "�/� ����� \"Mr. Whoopee\""},
{abbreviation = "�����", replacement = "�/� ����� \"Mr. Whoopee\""},
{abbreviation = "������", replacement = "�/� ����� \"Hotdog\""},
{abbreviation = "�������", replacement = "�/� ����� \"Hotdog\""},
{abbreviation = "�������", replacement = "Queens"},
{abbreviation = "��������", replacement = "Queens"},
{abbreviation = "�������", replacement = "Hashbury"},
{abbreviation = "��������", replacement = "Hashbury"},
{abbreviation = "������", replacement = "Garcia"},
{abbreviation = "������", replacement = "Garcia"},
{abbreviation = "������", replacement = "Sanchez SF"},
{abbreviation = "�����", replacement = "El Fuego"},
{abbreviation = "�������", replacement = "El Fuego"},
{abbreviation = "��������", replacement = "Bayside"},
{abbreviation = "��������", replacement = "Bayside"},
{abbreviation = "�����", replacement = "Craig"},
{abbreviation = "������", replacement = "Craig"},
{abbreviation = "�������", replacement = "Chestnut"},
{abbreviation = "��������", replacement = "Chestnut"},
{abbreviation = "�������", replacement = "Highland"},
{abbreviation = "��������", replacement = "Highland"},
{abbreviation = "�����", replacement = "Valley"},
{abbreviation = "������", replacement = "Valley"},
{abbreviation = "�������", replacement = "Hillside"},
{abbreviation = "��������", replacement = "Hillside"},
{abbreviation = "�����", replacement = "Santa Flora"},
{abbreviation = "����� �����", replacement = "Santa Flora"},
{abbreviation = "����������", replacement = "Santa Flora"},
{abbreviation = "�������", replacement = "Angel Pine"},
{abbreviation = "��������", replacement = "Angel Pine"},
{abbreviation = "���������", replacement = "El Quebrados"},
{abbreviation = "����������", replacement = "El Quebrados"},
{abbreviation = "������", replacement = "Tierra Robada"},
{abbreviation = "�������", replacement = "Tierra Robada"},
{abbreviation = "������", replacement = "Tierra Robada"},
{abbreviation = "�����2", replacement = "Flint County"},
{abbreviation = "�����2�", replacement = "Flint County"},
{abbreviation = "�������2", replacement = "Whitewood"},
{abbreviation = "������2", replacement = "Rockshore"},
{abbreviation = "�������2", replacement = "Rockshore"},
{abbreviation = "�������", replacement = "Rockshore"},
{abbreviation = "�������", replacement = "Rockshore"},
{abbreviation = "������", replacement = "Springfield"},
{abbreviation = "�������", replacement = "Springfield"},
{abbreviation = "����", replacement = "Bell"},
{abbreviation = "�����", replacement = "Bell"},
{abbreviation = "������", replacement = "Harbor"},
{abbreviation = "�������", replacement = "Harbor"},
{abbreviation = "���", replacement = "Dock"},
{abbreviation = "����", replacement = "Dock"},
{abbreviation = "����", replacement = "Dock"},
{abbreviation = "����2", replacement = "Port"},
{abbreviation = "�����2", replacement = "Port"},
{abbreviation = "���", replacement = "Bay"},
{abbreviation = "���", replacement = "Bay"},
{abbreviation = "����", replacement = "Bays"},
{abbreviation = "�����", replacement = "Bays"},
{abbreviation = "�����", replacement = "Cross"},
{abbreviation = "������", replacement = "Cross"},
{abbreviation = "����", replacement = "Hill"},
{abbreviation = "�����", replacement = "Hill"},
{abbreviation = "����", replacement = "Park"},
{abbreviation = "�����", replacement = "Park"},
{abbreviation = "���", replacement = "View"},
{abbreviation = "����", replacement = "View"},
{abbreviation = "�����", replacement = "Heights"},
{abbreviation = "������", replacement = "Heights"},
{abbreviation = "�����", replacement = "Tower"},
{abbreviation = "������", replacement = "Tower"},
{abbreviation = "�����", replacement = "Bridge"},
{abbreviation = "������", replacement = "Bridge"},
{abbreviation = "�����", replacement = "Avenue"},
{abbreviation = "������", replacement = "Avenue"},
{abbreviation = "�����", replacement = "Street"},
{abbreviation = "������", replacement = "Street"},
{abbreviation = "����", replacement = "Road"},
{abbreviation = "�����", replacement = "Road"},
{abbreviation = "�����", replacement = "Plaza"},
{abbreviation = "�����", replacement = "Plaza"},
{abbreviation = "�����", replacement = "Square"},
{abbreviation = "������", replacement = "Square"},
{abbreviation = "���������", replacement = "��������������"},
{abbreviation = "����������", replacement = "��������������"},
{abbreviation = "��������������", replacement = "��������������"},
{abbreviation = "��������������", replacement = "��������������"},
{abbreviation = "�����", replacement = "����� �������"},
{abbreviation = "������", replacement = "����� �������"},
{abbreviation = "������", replacement = "����� �������"},
{abbreviation = "����", replacement = "����-�����"},
{abbreviation = "����-�����", replacement = "����-�����"},
{abbreviation = "����-������", replacement = "����-�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "��������"},
{abbreviation = "�����", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������-����"},
{abbreviation = "��������-����", replacement = "��������-����"},
{abbreviation = "��������-�����", replacement = "��������-����"},
{abbreviation = "����������", replacement = "��������-����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�����", replacement = "���������"},
{abbreviation = "�����", replacement = "���������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "������������", replacement = "����������"},
{abbreviation = "������������", replacement = "����������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "���������", replacement = "��������� �������"},
{abbreviation = "����������", replacement = "��������� �������"},
{abbreviation = "��������", replacement = "��������� �������"},
{abbreviation = "��������", replacement = "��������� �������"},
{abbreviation = "��������", replacement = "��������� �������"},
{abbreviation = "���������", replacement = "��������� �������"},
{abbreviation = "����������", replacement = "��������� �������"},
{abbreviation = "��������", replacement = "��������� �������"},
{abbreviation = "��������", replacement = "��������� �������"},
{abbreviation = "��������", replacement = "��������� �������"},
{abbreviation = "�������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������������", replacement = "������������ �������"},
{abbreviation = "�������������", replacement = "������������ �������"},
{abbreviation = "����", replacement = "������������ �������"},
{abbreviation = "�����", replacement = "������������ �������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������������", replacement = "�����������"},
{abbreviation = "�������������", replacement = "������������� �������"},
{abbreviation = "��������������", replacement = "������������� �������"},
{abbreviation = "������", replacement = "������������� �������"},
{abbreviation = "�������", replacement = "������������� �������"},
{abbreviation = "��������", replacement = "����������� �������"},
{abbreviation = "�����������", replacement = "����������� �������"},
{abbreviation = "������������", replacement = "����������� �������"},
{abbreviation = "�������", replacement = "����������� �������"},
{abbreviation = "��������", replacement = "����������� �������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������������", replacement = "�����������"},
{abbreviation = "������������", replacement = "�����������"},
{abbreviation = "����", replacement = "����-������"},
{abbreviation = "����-������", replacement = "����-������"},
{abbreviation = "����-�������", replacement = "����-������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "�������2", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "�����", replacement = "������ \"Sawn-off Shotgun\""},
{abbreviation = "������", replacement = "������ \"Sawn-off Shotgun\""},
{abbreviation = "������", replacement = "������ \"Sawn-off Shotgun\""},
{abbreviation = "����������", replacement = "������ \"Sawn-off Shotgun\""},
{abbreviation = "����������", replacement = "������ \"Sawn-off Shotgun\""},
{abbreviation = "�����", replacement = "������ \"Combat Shotgun\""},
{abbreviation = "�����", replacement = "������ \"Combat Shotgun\""},
{abbreviation = "�����", replacement = "������ \"Combat Shotgun\""},
{abbreviation = "������", replacement = "������ \"Combat Shotgun\""},
{abbreviation = "�������", replacement = "������ \"Combat Shotgun\""},
{abbreviation = "�����", replacement = "������ \"Micro SMG\""},
{abbreviation = "������", replacement = "������ \"Micro SMG\""},
{abbreviation = "������", replacement = "������ \"Micro SMG\""},
{abbreviation = "��5", replacement = "������ \"MP5\""},
{abbreviation = "��5�", replacement = "������ \"MP5\""},
{abbreviation = "����", replacement = "������ \"Pistol\""},
{abbreviation = "�����", replacement = "������ \"Pistol\""},
{abbreviation = "�����", replacement = "������ \"Pistol\""},
{abbreviation = "������", replacement = "������ \"Pistol\""},
{abbreviation = "�������", replacement = "������ \"Pistol\""},
{abbreviation = "�������", replacement = "������ \"Pistol\""},
{abbreviation = "������", replacement = "������ \"Desert Eagle\""},
{abbreviation = "�������", replacement = "������ \"Desert Eagle\""},
{abbreviation = "���", replacement = "������ \"Desert Eagle\""},
{abbreviation = "����", replacement = "������ \"Desert Eagle\""},
{abbreviation = "����", replacement = "������ \"Desert Eagle\""},
{abbreviation = "�����", replacement = "������ \"Desert Eagle\""},
{abbreviation = "�����", replacement = "������ \"AK-47\""},
{abbreviation = "������", replacement = "������ \"AK-47\""},
{abbreviation = "������", replacement = "������ \"AK-47\""},
{abbreviation = "�16", replacement = "������ \"M4\""},
{abbreviation = "�16�", replacement = "������ \"M4\""},
{abbreviation = "�����", replacement = "������ \"AK-47\""},
{abbreviation = "������", replacement = "������ \"AK-47\""},
{abbreviation = "�������", replacement = "������ \"TEC-9\""},
{abbreviation = "��������", replacement = "������ \"TEC-9\""},
{abbreviation = "��������", replacement = "������ \"TEC-9\""},
{abbreviation = "���������", replacement = "������ \"TEC-9\""},
{abbreviation = "�����", replacement = "������ \"Knife\""},
{abbreviation = "������", replacement = "������ \"Knife\""},
{abbreviation = "������", replacement = "������ \"Machete\""},
{abbreviation = "�������", replacement = "������ \"Machete\""},
{abbreviation = "������", replacement = "������ \"Baseball Bat\""},
{abbreviation = "������", replacement = "������ \"Baseball Bat\""},
{abbreviation = "������", replacement = "������ \"Baseball Bat\""},
{abbreviation = "�������", replacement = "������ \"Baseball Bat\""},
{abbreviation = "�������", replacement = "������ \"Baseball Bat\""},
{abbreviation = "�������", replacement = "������ \"Baseball Bat\""},
{abbreviation = "������", replacement = "������ \"Hockey Stick\""},
{abbreviation = "������", replacement = "������ \"Hockey Stick\""},
{abbreviation = "������", replacement = "������ \"Hockey Stick\""},
{abbreviation = "�����", replacement = "������ \"Baseball Bat\""},
{abbreviation = "�����", replacement = "������ \"Baseball Bat\""},
{abbreviation = "�����", replacement = "������ \"Baseball Bat\""},
{abbreviation = "������", replacement = "������ \"Rocket Launcher\""},
{abbreviation = "������", replacement = "������ \"Rocket Launcher\""},
{abbreviation = "������", replacement = "������ \"Rocket Launcher\""},
{abbreviation = "������", replacement = "������ \"Rocket Launcher\""},
{abbreviation = "������", replacement = "������ \"Rocket Launcher\""},
{abbreviation = "������", replacement = "������ \"Rocket Launcher\""},
{abbreviation = "����������", replacement = "������ \"Rocket Launcher\""},
{abbreviation = "�����������", replacement = "������ \"Rocket Launcher\""},
{abbreviation = "�������", replacement = "������ \"Flamethrower\""},
{abbreviation = "��������", replacement = "������ \"Flamethrower\""},
{abbreviation = "�������", replacement = "������ \"Minigun\""},
{abbreviation = "��������", replacement = "������ \"Minigun\""},
{abbreviation = "����", replacement = "������ \"Minigun\""},
{abbreviation = "�����", replacement = "������ \"Minigun\""},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "���������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������������", replacement = "��������������"},
{abbreviation = "��������������", replacement = "��������������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�����2", replacement = "�������������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "���������������", replacement = "���������������"},
{abbreviation = "���������������", replacement = "���������������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "���������2", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������3", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������2", replacement = "��������"},
{abbreviation = "��������2", replacement = "��������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "���������2", replacement = "���������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "������", replacement = "������ ���������"},
{abbreviation = "�������", replacement = "������ ���������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "������ �����"},
{abbreviation = "�����", replacement = "������ �����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "���", replacement = "����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������������", replacement = "�����������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "��������2", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�����", replacement = "��������"},
{abbreviation = "������", replacement = "��������"},
{abbreviation = "�������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������������", replacement = "�����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����2", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "�������2", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����2", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "�/� ����� \"Benson\""},
{abbreviation = "�������", replacement = "�/� ����� \"Benson\""},
{abbreviation = "�������", replacement = "�/� ����� \"Benson\""},
{abbreviation = "��������", replacement = "�/� ����� \"Boxville\""},
{abbreviation = "���������", replacement = "�/� ����� \"Boxville\""},
{abbreviation = "����", replacement = "�/� ����� \"Bord\""},
{abbreviation = "�����", replacement = "�/� ����� \"Bord\""},
{abbreviation = "������", replacement = "�/� ����� \"Culver\""},
{abbreviation = "�������", replacement = "�/� ����� \"Culver\""},
{abbreviation = "�����", replacement = "�/� ����� \"Dunes\""},
{abbreviation = "������", replacement = "�/� ����� \"Dunes\""},
{abbreviation = "����2", replacement = "�/� ����� \"Ford\""},
{abbreviation = "�����2", replacement = "�/� ����� \"Ford\""},
{abbreviation = "�����", replacement = "�/� ����� \"Hanley\""},
{abbreviation = "������", replacement = "�/� ����� \"Hanley\""},
{abbreviation = "������3", replacement = "�/� ����� \"Hunter\""},
{abbreviation = "�������3", replacement = "�/� ����� \"Hunter\""},
{abbreviation = "�����", replacement = "�/� ����� \"Largo\""},
{abbreviation = "������", replacement = "�/� ����� \"Largo\""},
{abbreviation = "�����", replacement = "�/� ����� \"Locust\""},
{abbreviation = "������", replacement = "�/� ����� \"Locust\""},
{abbreviation = "�������", replacement = "�/� ����� \"Maverick\""},
{abbreviation = "��������", replacement = "�/� ����� \"Maverick\""},
{abbreviation = "�����", replacement = "�/� ����� \"Merit\""},
{abbreviation = "������", replacement = "�/� ����� \"Merit\""},
{abbreviation = "�������", replacement = "�/� ����� \"Maverick\""},
{abbreviation = "��������", replacement = "�/� ����� \"Maverick\""},
{abbreviation = "������", replacement = "�/� ����� \"Nesson\""},
{abbreviation = "�������", replacement = "�/� ����� \"Nesson\""},
{abbreviation = "�����", replacement = "�/� ����� \"Polar\""},
{abbreviation = "������", replacement = "�/� ����� \"Polar\""},
{abbreviation = "������2", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "�������2", replacement = "�/� ����� \"Rancher\""},
{abbreviation = "�����", replacement = "�/� ����� \"Sanchez\""},
{abbreviation = "������", replacement = "�/� ����� \"Sanchez\""},
{abbreviation = "�������", replacement = "�/� ����� \"Simpleon\""},
{abbreviation = "��������", replacement = "�/� ����� \"Simpleon\""},
{abbreviation = "�����", replacement = "�/� ����� \"Simpleon\""},
{abbreviation = "��������", replacement = "�/� ����� \"Sprinter\""},
{abbreviation = "���������", replacement = "�/� ����� \"Sprinter\""},
{abbreviation = "����", replacement = "�/� ����� \"Stock\""},
{abbreviation = "�����", replacement = "�/� ����� \"Stock\""},
{abbreviation = "����", replacement = "�/� ����� \"Trash\""},
{abbreviation = "�����", replacement = "�/� ����� \"Trash\""},
{abbreviation = "����������", replacement = "�/� ����� \"Trashmaster\""},
{abbreviation = "�����������", replacement = "�/� ����� \"Trashmaster\""},
{abbreviation = "����", replacement = "�/� ����� \"Ural\""},
{abbreviation = "�����", replacement = "�/� ����� \"Ural\""},
{abbreviation = "�����", replacement = "�/� ����� \"Ural\""},
{abbreviation = "���", replacement = "�/� ����� \"Van\""},
{abbreviation = "����", replacement = "�/� ����� \"Van\""},
{abbreviation = "����", replacement = "�/� ����� \"Van\""},
{abbreviation = "����", replacement = "�/� ����� \"Vance\""},
{abbreviation = "�����", replacement = "�/� ����� \"Vance\""},
{abbreviation = "������", replacement = "�/� ����� \"Venson\""},
{abbreviation = "�������", replacement = "�/� ����� \"Venson\""},
{abbreviation = "����", replacement = "�/� ����� \"Yolk\""},
{abbreviation = "�����", replacement = "�/� ����� \"Yolk\""},
{abbreviation = "�����3", replacement = "�/� ����� \"Zombie\""},
{abbreviation = "������3", replacement = "�/� ����� \"Zombie\""},
{abbreviation = "������2", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "�������2", replacement = "�/� ����� \"Bullet\""},
{abbreviation = "��������2", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "���������2", replacement = "�/� ����� \"Infernus\""},
{abbreviation = "�������2", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "��������2", replacement = "�/� ����� \"Turismo\""},
{abbreviation = "�����2", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "������2", replacement = "�/� ����� \"Cheetah\""},
{abbreviation = "�����2", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "�����2�", replacement = "�/� ����� \"Banshee\""},
{abbreviation = "������2", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "�������2", replacement = "�/� ����� \"Phoenix\""},
{abbreviation = "�������2", replacement = "�/� ����� \"Super GT\""},
{abbreviation = "��������2", replacement = "�/� ����� \"Super GT\""},
{abbreviation = "�������2", replacement = "�/� ����� \"Stinger\""},
{abbreviation = "��������2", replacement = "�/� ����� \"Stinger\""},
{abbreviation = "������2", replacement = "�/� ����� \"Comet\""},
{abbreviation = "������2", replacement = "�/� ����� \"Comet\""},
{abbreviation = "���2", replacement = "��������� ����� \"BMX\""},
{abbreviation = "����2", replacement = "��������� ����� \"BMX\""},
{abbreviation = "����2", replacement = "��������� ����� \"BMX\""},
{abbreviation = "����2", replacement = "��������� ����� \"BMX\""},
{abbreviation = "�����2", replacement = "��������� ����� \"BMX\""},
{abbreviation = "������2", replacement = "���������"},
{abbreviation = "������2", replacement = "���������"},
{abbreviation = "�����2", replacement = "���������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "����2", replacement = "����"},
{abbreviation = "����2", replacement = "����"},
{abbreviation = "����2", replacement = "����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "��������", replacement = "�����"},
{abbreviation = "��������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "��������2", replacement = "�������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "��������2", replacement = "�������"},
{abbreviation = "�������2", replacement = "������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "�������2", replacement = "������"},
{abbreviation = "�������2", replacement = "������"},
{abbreviation = "����������", replacement = "������"},
{abbreviation = "�����������", replacement = "������"},
{abbreviation = "�����������", replacement = "������"},
{abbreviation = "�����������", replacement = "������"},
{abbreviation = "�����������", replacement = "������"},
{abbreviation = "��������������", replacement = "������"},
{abbreviation = "���������������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "�������2", replacement = "��������� \"�������\""},
{abbreviation = "��������2", replacement = "��������� \"�������\""},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "���", replacement = "East Los Santos"},
{abbreviation = "����", replacement = "East Los Santos"},
{abbreviation = "��� ����", replacement = "East Los Santos"},
{abbreviation = "���������", replacement = "Idlewood"},
{abbreviation = "����������", replacement = "Idlewood"},
{abbreviation = "����2", replacement = "Jefferson"},
{abbreviation = "����2�", replacement = "Jefferson"},
{abbreviation = "����2", replacement = "Glen Park"},
{abbreviation = "�����2", replacement = "Glen Park"},
{abbreviation = "����������2", replacement = "Willowfield"},
{abbreviation = "��������2", replacement = "El Corona"},
{abbreviation = "��������2�", replacement = "El Corona"},
{abbreviation = "�������2", replacement = "Commerce"},
{abbreviation = "������2", replacement = "Market"},
{abbreviation = "�������2", replacement = "Market"},
{abbreviation = "���������", replacement = "Conference Center"},
{abbreviation = "����������", replacement = "Conference Center"},
{abbreviation = "��������", replacement = "Pershing Square"},
{abbreviation = "���������", replacement = "Pershing Square"},
{abbreviation = "�������", replacement = "Pershing Square"},
{abbreviation = "��������", replacement = "Pershing Square"},
{abbreviation = "����", replacement = "City Hall"},
{abbreviation = "����2", replacement = "City Hall"},
{abbreviation = "����", replacement = "Downtown"},
{abbreviation = "�����", replacement = "Downtown"},
{abbreviation = "��������", replacement = "Downtown"},
{abbreviation = "���������", replacement = "Downtown"},
{abbreviation = "�����2", replacement = "Pershing Square"},
{abbreviation = "������2", replacement = "Garcia"},
{abbreviation = "������2", replacement = "Garcia"},
{abbreviation = "�������2", replacement = "Hashbury"},
{abbreviation = "��������2", replacement = "Hashbury"},
{abbreviation = "�������2", replacement = "Doherty"},
{abbreviation = "��������2", replacement = "Doherty"},
{abbreviation = "�����2", replacement = "Kings"},
{abbreviation = "������2", replacement = "Kings"},
{abbreviation = "��������2", replacement = "Paradiso"},
{abbreviation = "���������2", replacement = "Paradiso"},
{abbreviation = "�������2", replacement = "Queens"},
{abbreviation = "��������2", replacement = "Queens"},
{abbreviation = "����������2", replacement = "Santa Flora"},
{abbreviation = "�����2", replacement = "Santa Flora"},
{abbreviation = "������", replacement = "Foster Valley"},
{abbreviation = "�������", replacement = "Foster Valley"},
{abbreviation = "������2", replacement = "Foster Valley"},
{abbreviation = "�������2", replacement = "Foster Valley"},
{abbreviation = "��������", replacement = "Garberry"},
{abbreviation = "���������", replacement = "Garberry"},
{abbreviation = "�������2", replacement = "Ashberry"},
{abbreviation = "�������2�", replacement = "Ashberry"},
{abbreviation = "�������2", replacement = "Bayside"},
{abbreviation = "�������2�", replacement = "Bayside"},
{abbreviation = "��������2", replacement = "Bayside"},
{abbreviation = "�����2", replacement = "The Strip"},
{abbreviation = "������2", replacement = "The Strip"},
{abbreviation = "�����2", replacement = "Pilgrim"},
{abbreviation = "������2", replacement = "Pilgrim"},
{abbreviation = "������2", replacement = "Avalon"},
{abbreviation = "�������2", replacement = "Avalon"},
{abbreviation = "������2", replacement = "Dragons Dojo"},
{abbreviation = "�������2", replacement = "Dragons Dojo"},
{abbreviation = "�����2", replacement = "Prickle Pine"},
{abbreviation = "�����2", replacement = "Prickle Pine"},
{abbreviation = "��������2", replacement = "Whitewood"},
{abbreviation = "�������2", replacement = "Pilbox"},
{abbreviation = "��������2", replacement = "Pilbox"},
{abbreviation = "�����2", replacement = "Royal Casino"},
{abbreviation = "��������2", replacement = "Caligulas Palace"},
{abbreviation = "�����2", replacement = "Pirates in Mens Pants"},
{abbreviation = "�����2", replacement = "Visage"},
{abbreviation = "�����3", replacement = "Flint County"},
{abbreviation = "������3", replacement = "Flint County"},
{abbreviation = "��2", replacement = "Palomino Creek"},
{abbreviation = "��������2", replacement = "Palomino Creek"},
{abbreviation = "����������2", replacement = "Montgomery"},
{abbreviation = "��������2", replacement = "Dillimore"},
{abbreviation = "�������2", replacement = "Blueberry"},
{abbreviation = "��������2", replacement = "Blueberry"},
{abbreviation = "����2", replacement = "Fort Carson"},
{abbreviation = "������2", replacement = "Fort Carson"},
{abbreviation = "�����2", replacement = "Tierra Robada"},
{abbreviation = "������2", replacement = "Tierra Robada"},
{abbreviation = "�����2", replacement = "Angel Pine"},
{abbreviation = "����2", replacement = "North Rock"},
{abbreviation = "�����2", replacement = "Valle Ocultado"},
{abbreviation = "����2", replacement = "Arco del Oeste"},
{abbreviation = "����2", replacement = "Green Palms"},
{abbreviation = "�����2", replacement = "Green Palms"},
{abbreviation = "�����2", replacement = "Union Station"},
{abbreviation = "����2", replacement = "Palomino Creek"},
{abbreviation = "�����������", replacement = "El Quebrados"},
{abbreviation = "������������", replacement = "El Quebrados"},
{abbreviation = "��������", replacement = "Airport"},
{abbreviation = "���������", replacement = "Airport"},
{abbreviation = "���������", replacement = "Airport"},
{abbreviation = "����", replacement = "Airport"},
{abbreviation = "�����", replacement = "Airport"},
{abbreviation = "����3", replacement = "Port"},
{abbreviation = "�����3", replacement = "Port"},
{abbreviation = "������", replacement = "Station"},
{abbreviation = "�������", replacement = "Station"},
{abbreviation = "�������", replacement = "Station"},
{abbreviation = "�������", replacement = "Station"},
{abbreviation = "�������", replacement = "Station"},
{abbreviation = "�����", replacement = "Metro"},
{abbreviation = "������", replacement = "Metro"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����3", replacement = "�����"},
{abbreviation = "���������2", replacement = "��������������"},
{abbreviation = "������", replacement = "��������������"},
{abbreviation = "��������", replacement = "��������������"},
{abbreviation = "��������", replacement = "��������������"},
{abbreviation = "��������������2", replacement = "��������������"},
{abbreviation = "�����2", replacement = "����� �������"},
{abbreviation = "������2", replacement = "����� �������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�anya", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "����2", replacement = "����"},
{abbreviation = "�����2", replacement = "����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "������2", replacement = "�����"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "����", replacement = "������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "����2", replacement = "����"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "�����2", replacement = "������"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "���2", replacement = "���"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "������2", replacement = "�����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "������2", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "������2", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����2", replacement = "���������"},
{abbreviation = "�����2", replacement = "���������"},
{abbreviation = "����������2", replacement = "����������"},
{abbreviation = "���2", replacement = "���"},
{abbreviation = "��������2", replacement = "��������"},
{abbreviation = "����������2", replacement = "����������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "������2", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�����������������", replacement = "�����������������"},
{abbreviation = "�����������������", replacement = "�����������������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������� ������"},
{abbreviation = "������������", replacement = "������������ ������"},
{abbreviation = "�����������", replacement = "���������� ���"},
{abbreviation = "����������", replacement = "���������� ���"},
{abbreviation = "��������2", replacement = "���������� ���"},
{abbreviation = "�������2", replacement = "���������� ���"},
{abbreviation = "�������2", replacement = "���������� ���"},
{abbreviation = "������", replacement = "������-����"},
{abbreviation = "�������", replacement = "������-����"},
{abbreviation = "������-����", replacement = "������-����"},
{abbreviation = "������-�����", replacement = "������-����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "����", replacement = "����-������"},
{abbreviation = "����-������", replacement = "����-������"},
{abbreviation = "�������", replacement = "������ ��������"},
{abbreviation = "������������", replacement = "��� �����������"},
{abbreviation = "����", replacement = "���������� ���"},
{abbreviation = "����������", replacement = "���������� ���"},
{abbreviation = "�����", replacement = "��������"},
{abbreviation = "������", replacement = "��������"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������������", replacement = "�����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "������� ���"},
{abbreviation = "�������", replacement = "������� ���"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������2", replacement = "�����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������2", replacement = "��������"},
{abbreviation = "��������2", replacement = "��������"},
{abbreviation = "������2", replacement = "��������-������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����-�����"},
{abbreviation = "�����", replacement = "�����-�����"},
{abbreviation = "�����", replacement = "�����-�����"},
{abbreviation = "�����-�����", replacement = "�����-�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "����2", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "���������", replacement = "��������� ������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "���", replacement = "�����������"},
{abbreviation = "������", replacement = "������ �����"},
{abbreviation = "�����", replacement = "������ �����"},
{abbreviation = "�����", replacement = "������ �����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "��������", replacement = "���������"},
{abbreviation = "��������", replacement = "���������"},
{abbreviation = "����2", replacement = "��������� \"����\""},
{abbreviation = "�����2", replacement = "��������� \"����\""},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������3", replacement = "�������"},
{abbreviation = "��������2", replacement = "��������"},
{abbreviation = "�����2", replacement = "��������"},
{abbreviation = "������2", replacement = "��������"},
{abbreviation = "�������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "��������"},
{abbreviation = "������", replacement = "��������"},
{abbreviation = "�����", replacement = "��������"},
{abbreviation = "�����", replacement = "��������"},
{abbreviation = "������", replacement = "��������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "�����", replacement = "�������"},
{abbreviation = "������", replacement = "�������"},
{abbreviation = "������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��", replacement = "���������"},
{abbreviation = "���", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "���", replacement = "����������� ������"},
{abbreviation = "�����������", replacement = "����������� ������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������� ����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "���", replacement = "SSD ����������"},
{abbreviation = "����", replacement = "SSD ����������"},
{abbreviation = "����", replacement = "������� ����"},
{abbreviation = "�����", replacement = "������� ����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "���", replacement = "USB-����������"},
{abbreviation = "���", replacement = "USB-����������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "����������"},
{abbreviation = "���", replacement = "������������"},
{abbreviation = "����", replacement = "����-����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�������", replacement = "������� ������"},
{abbreviation = "����", replacement = "���� �������"},
{abbreviation = "�����", replacement = "���� �������"},
{abbreviation = "��", replacement = "���� �������"},
{abbreviation = "���", replacement = "���� �������"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�����"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "���������", replacement = "����������� �����"},
{abbreviation = "�����������", replacement = "����������� �����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "��������", replacement = "�������� �����"},
{abbreviation = "�������", replacement = "������� �����"},
{abbreviation = "�������", replacement = "��-�����"},
{abbreviation = "�����", replacement = "���-������"},
{abbreviation = "���-������", replacement = "���-������"},
{abbreviation = "���-������", replacement = "���-������"},
{abbreviation = "���������", replacement = "���-������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "��", replacement = "���������"},
{abbreviation = "���", replacement = "���������"},
{abbreviation = "��������", replacement = "���������"},
{abbreviation = "�������", replacement = "���������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������������", replacement = "�����������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������", replacement = "���������� ������"},
{abbreviation = "����������", replacement = "���������� ������"},
{abbreviation = "����������", replacement = "���������� ������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "�������������", replacement = "�����������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "��������", replacement = "�������� ������"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������� �������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "�������2", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����-�������"},
{abbreviation = "������", replacement = "�����-�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "��������������", replacement = "�������������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������������", replacement = "�����������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "���2", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����-���"},
{abbreviation = "���2", replacement = "�����-���"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����������", replacement = "���������� ������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "������������", replacement = "������������"},
{abbreviation = "�������������", replacement = "������������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������", replacement = "���������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "��������������", replacement = "�������������� �����"},
{abbreviation = "�����", replacement = "�������������� �����"},
{abbreviation = "����", replacement = "�������������� �����"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "����2", replacement = "����"},
{abbreviation = "�������", replacement = "������� ����"},
{abbreviation = "��������", replacement = "�������� ����"},
{abbreviation = "���������", replacement = "��������� ����"},
{abbreviation = "��������2", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "��������������", replacement = "��������������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "����3", replacement = "����"},
{abbreviation = "����3", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����2", replacement = "����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "���"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�����������", replacement = "����������"},
{abbreviation = "����", replacement = "��������� ����"},
{abbreviation = "���������", replacement = "��������� ����"},
{abbreviation = "���������", replacement = "��������� ����"},
{abbreviation = "����", replacement = "��������� ����"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������������", replacement = "���������������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "24/7", replacement = "������� \"24/7\""},
{abbreviation = "24-7", replacement = "������� \"24/7\""},
{abbreviation = "247", replacement = "������� \"24/7\""},
{abbreviation = "��������������", replacement = "������� \"24/7\""},
{abbreviation = "���������������", replacement = "������� \"24/7\""},
{abbreviation = "��������", replacement = "������� \"24/7\""},
{abbreviation = "��", replacement = "�/� ����� \"Sultan\""},
{abbreviation = "�����", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "��������", replacement = "�������� ������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�� �����", replacement = "�� �����"},
{abbreviation = "��� �����", replacement = "��� �����"},
{abbreviation = "��", replacement = "RP"},
{abbreviation = "���", replacement = "RP"},
{abbreviation = "���", replacement = "DRP"},
{abbreviation = "���", replacement = "ARP"},
{abbreviation = "������", replacement = "Advance RP"},
{abbreviation = "�������", replacement = "Advance RP"},
{abbreviation = "��", replacement = "PRO"},
{abbreviation = "�����", replacement = "non-RP"},
{abbreviation = "��", replacement = "MG"},
{abbreviation = "���", replacement = "MG"},
{abbreviation = "��", replacement = "DM"},
{abbreviation = "���", replacement = "DM"},
{abbreviation = "��", replacement = "TK"},
{abbreviation = "��", replacement = "SK"},
{abbreviation = "��", replacement = "PG"},
{abbreviation = "��", replacement = "RK"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����� ��������", replacement = "���������"},
{abbreviation = "���������", replacement = "������������� ����"},
{abbreviation = "��������", replacement = "������������ ����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����-�������"},
{abbreviation = "������", replacement = "�����-�������"},
{abbreviation = "�������", replacement = "�����-�������"},
{abbreviation = "���������", replacement = "�����-�������"},
{abbreviation = "��������3", replacement = "��������"},
{abbreviation = "�����������", replacement = "�����������"},
{abbreviation = "������������", replacement = "�����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "����"},
{abbreviation = "������3", replacement = "������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "������", replacement = "�/�"},
{abbreviation = "�������", replacement = "�/�"},
{abbreviation = "�������", replacement = "�/�"},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "������", replacement = "�/�"},
{abbreviation = "������", replacement = "�/�"},
{abbreviation = "�������", replacement = "�/�"},
{abbreviation = "�������", replacement = "�/�"},
{abbreviation = "������", replacement = "�/�"},
{abbreviation = "������", replacement = "�/�"},
{abbreviation = "��������", replacement = "�/�"},
{abbreviation = "��������", replacement = "�/�"},
{abbreviation = "���������", replacement = "�/�"},
{abbreviation = "����������", replacement = "�/�"},
{abbreviation = "��������", replacement = "�/�"},
{abbreviation = "��������", replacement = "�/�"},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "�����", replacement = "�/�"},
{abbreviation = "��������", replacement = "�/�"},
{abbreviation = "��������", replacement = "�/�"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�����", replacement = "������"},
{abbreviation = "������", replacement = "$"},
{abbreviation = "�����", replacement = "$"},
{abbreviation = "�������", replacement = "$"},
{abbreviation = "�������2", replacement = "$"},
{abbreviation = "��������", replacement = "$"},
{abbreviation = "�����", replacement = "$"},
{abbreviation = "��������", replacement = "$"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "��������2", replacement = "�� ��������� ����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "������2", replacement = "�� ������ ����"},
{abbreviation = "�����2", replacement = "�� ������ ����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "� �������", replacement = "� �������"},
{abbreviation = "�������", replacement = "� �������"},
{abbreviation = "� �������", replacement = "� �������"},
{abbreviation = "�������", replacement = "� �������"},
{abbreviation = "��� �����2", replacement = "��� �����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����2", replacement = "�����"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������", replacement = "�����"},
{abbreviation = "������", replacement = "������ �����"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "���", replacement = "���"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "���������"},
{abbreviation = "������2", replacement = "������"},
{abbreviation = "����2", replacement = "���� � �������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������2", replacement = "��������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "�������", replacement = "������"},
{abbreviation = "����������2", replacement = "����������"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "�������������", replacement = "�������������"},
{abbreviation = "�������2", replacement = "�������"},
{abbreviation = "��������2", replacement = "�������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "���������", replacement = "��������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "������", replacement = "������"},
{abbreviation = "����", replacement = "����"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "���2", replacement = "���"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "�������"},
{abbreviation = "��������", replacement = "�������"},
{abbreviation = "��", replacement = "FT"},
-- �������
{abbreviation = "������", replacement = "������� ������"},
{abbreviation = "������", replacement = "������� ������"},
{abbreviation = "������� ������", replacement = "��������� �������"},
{abbreviation = "�������", replacement = "����� �������"},
{abbreviation = "�������", replacement = "����� �������"},
{abbreviation = "���������", replacement = "����� �������"},
{abbreviation = "��������������", replacement = "����� �������"},
{abbreviation = "����� �������", replacement = "����� �������"},
{abbreviation = "����������", replacement = "����������"},
{abbreviation = "��������", replacement = "����������"},
{abbreviation = "������", replacement = "Burger Shot"},
{abbreviation = "����", replacement = "Clucking Bell"},
{abbreviation = "�������", replacement = "Clucking Bell"},
{abbreviation = "������", replacement = "������-�����"},
{abbreviation = "������ �����", replacement = "������-�����"},
{abbreviation = "�����", replacement = "����� Visage"},
{abbreviation = "�����", replacement = "����� �����"},
{abbreviation = "���� ���", replacement = "����-���"},
{abbreviation = "����-���", replacement = "����-���"},
{abbreviation = "�����������", replacement = "������� �����������"},
{abbreviation = "����", replacement = "������� �����������"},
{abbreviation = "���������������", replacement = "��������������� �����"},
{abbreviation = "������������", replacement = "��������������� �����"},
{abbreviation = "�������", replacement = "����������� ���������"},
{abbreviation = "�����������", replacement = "����������� ���������"},
{abbreviation = "���������", replacement = "����������� ���������"},
{abbreviation = "����������", replacement = "���������� ����������"},
{abbreviation = "���������� ����������", replacement = "���������� ����������"},
{abbreviation = "������", replacement = "��������� �����"},
{abbreviation = "���������", replacement = "��������� �����"},
{abbreviation = "����������", replacement = "����� ����������"},
{abbreviation = "������", replacement = "����� ����������"},
{abbreviation = "��������������", replacement = "������� ���������������"},
{abbreviation = "��������", replacement = "������� ���������������"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "������ ����", replacement = "������ ������������ ����"},
{abbreviation = "������", replacement = "������ ������������ ����"},
{abbreviation = "�������� ����������", replacement = "�������� ����������"},
{abbreviation = "�������� ��", replacement = "�������� ����������"},
{abbreviation = "��������", replacement = "�������� ����������"},
{abbreviation = "�������� �����������", replacement = "�������� �����������"},
{abbreviation = "�������� ���", replacement = "�������� �����������"},
{abbreviation = "�����", replacement = "�������� �����������"},
-- ��������������� �����������
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�����", replacement = "�����"},
{abbreviation = "�������������", replacement = "������������� ����������"},
{abbreviation = "����������", replacement = "������������� ����������"},
{abbreviation = "��������", replacement = "��������"},
{abbreviation = "�������", replacement = "��������"},
{abbreviation = "���������", replacement = "���������"},
{abbreviation = "����������", replacement = "����������"},
-- ����� � �����
{abbreviation = "�����", replacement = "Ballas"},
{abbreviation = "������", replacement = "Ballas"},
{abbreviation = "�����", replacement = "Ballas"},
{abbreviation = "����", replacement = "Grove Street"},
{abbreviation = "�����", replacement = "Grove Street"},
{abbreviation = "�����", replacement = "Aztecas"},
{abbreviation = "������", replacement = "Aztecas"},
{abbreviation = "�����", replacement = "Vagos"},
{abbreviation = "�����", replacement = "Vagos"},
{abbreviation = "�������", replacement = "������� �����"},
{abbreviation = "������� �����", replacement = "������� �����"},
{abbreviation = "��� ���", replacement = "������� �����"},
{abbreviation = "�������", replacement = "La Cosa Nostra"},
{abbreviation = "�� �����", replacement = "La Cosa Nostra"},
{abbreviation = "������� ������", replacement = "La Cosa Nostra"},
{abbreviation = "������", replacement = "Yakuza"},
{abbreviation = "�����", replacement = "Yakuza"},
{abbreviation = "������", replacement = "Yakuza"},
-- ������������������ ������
{abbreviation = "���", replacement = "FBI"},
{abbreviation = "�������", replacement = "LVPD"},
{abbreviation = "�����������", replacement = "LVPD"},
{abbreviation = "����", replacement = "LVPD"},
{abbreviation = "lspd", replacement = "LSPD"},
{abbreviation = "sfpd", replacement = "SFPD"},
-- �����
{abbreviation = "���", replacement = "���"},
{abbreviation = "��", replacement = "��"},
{abbreviation = "���", replacement = "���"},
}

-- ���������� ��� ������ "����-��������� (Auto-RP)"
local rp_weapons_enabled = imgui.new.bool(true)
local rp_phone_enabled = imgui.new.bool(true)
local rp_mask_enabled = imgui.new.bool(true)
local rp_heal_enabled = imgui.new.bool(true)

-- ���������� ��� ������ "��������� � ������ (Vehicles & Visuals)"
local strobe_enabled = imgui.new.bool(false)
local strobe_speed = imgui.new.int(150)
local strobe_mode = imgui.new.int(1)
local strobe_active = false
local cruise_enabled = imgui.new.bool(false)
local turbo_cruise_enabled = imgui.new.bool(false)
local cruise_active = false

-- ������� ������� �� �������
-- key: VK ��� �������, command: �������, name: ��������
local keybinds = {
    {key = 0x4C, command = "/lock",   enabled = true,  name = "�������/������� ������"},
    {key = 0x4B, command = "/e",     enabled = true,  name = "�������/��������� ���������"},
}
-- VK ���� ��� �������: 0x4C=L, 0x4B=K, 0x4A=J, 0x4D=M, 0x4E=N, 0x50=P, 0x52=R, 0x54=T
local key_names = {
    [0x4A] = "J", [0x4B] = "K", [0x4C] = "L", [0x4D] = "M", [0x4E] = "N",
    [0x4F] = "O", [0x50] = "P", [0x51] = "Q", [0x52] = "R", [0x54] = "T",
    [0x55] = "U", [0x56] = "V", [0x57] = "W", [0x58] = "X", [0x59] = "Y",
    [0x5A] = "Z", [0x31] = "1", [0x32] = "2", [0x33] = "3", [0x34] = "4",
    [0x35] = "5", [0x36] = "6", [0x37] = "7", [0x38] = "8", [0x39] = "9",
    [0x30] = "0", [0x20] = "Space", [0x0D] = "Enter",
}
local new_bind_key = imgui.new.int(0x4C)
local new_bind_command = imgui.new.char[129]("")
local new_bind_name = imgui.new.char[129]("")
local cruise_speed = 0.0

-- ������ � ����� (������)
local weather_locked = imgui.new.bool(false)
local weather_id = imgui.new.int(1)
local time_locked = imgui.new.bool(false)
local time_hour = imgui.new.int(12)

-- ���������� ����-�������
local skin_changer_id = imgui.new.int(0)

-- ���������� ��� ������ "����-���������� (Auto-Ad)"
local aad_active = false
local aad_text = ""
local aad_delay = imgui.new.int(15000)
local aad_templates = {}
local aad_history = {}
local static_aad_buf = nil
local last_ad_sent_time = 0
local aad_waiting_for_publish = false

-- ���������� ��� ����������� �������
local selected_faction = imgui.new.int(0)

-- Forward declarations (������� ������������ �����, �� ������������ � �������)
local isModuleEnabled
local saved_module_states
local modules
local factionScannerWorker
local chatScannerWorker
local sendAdCommand


-- ���������� ������ ADVANCE RP
local advance_commands = {
{
category = u8"�������� / �����������",
cmds = {
{name = "/menu", desc = u8"������� ���� ��������� (����������, ���������)"},
{name = "/gps", desc = u8"��������� �� ������ ������ �����"},
{name = "/phone", desc = u8"������� ������� (���������)"},
{name = "/call [�����]", desc = u8"��������� ������"},
{name = "/h", desc = u8"�������� ������ ��������"},
{name = "/c [�����] [�����]", desc = u8"��������� SMS ������ (����� ��� Advance!)"},
{name = "/book", desc = u8"������� ���������� �����"},
{name = "/dir", desc = u8"���������� ����������� � ������� ������"},
{name = "/pay [ID] [�����]", desc = u8"�������� ������ ������"},
{name = "/id [���/ID]", desc = u8"������ ID � ������� ������"},
{name = "/number [ID]", desc = u8"������ ����� �������� ������"},
{name = "/lic", desc = u8"�������� ���� ��������"},
{name = "/pass [ID]", desc = u8"�������� ������� ������"},
{name = "/med [ID]", desc = u8"�������� ���. ����� ������"},
{name = "/w [ID] [�����]", desc = u8"������� (����� ���)"},
{name = "/s [�����]", desc = u8"������� (������� ���)"}
}
},
{
category = u8"��� (Mass Media)",
cmds = {
{name = "/edit", desc = u8"������������� ���������� �� �������"},
{name = "/ad [�����]", desc = u8"������ ���������� �� ���������"},
{name = "/t [�����]", desc = u8"������� � ���� �� ������ / ������� ��������"},
{name = "/u [�����]", desc = u8"������� � �������� �� ����� ���������"},
{name = "/bring [ID]", desc = u8"���������� ����� � ���������"},
{name = "/nbring [ID]", desc = u8"���������� ����� � �������� ����"},
{name = "/audiomedia", desc = u8"���������� ������������ �����������"},
{name = "/lead", desc = u8"���������� ������������� (��� ������/�����)"}
}
},
{
category = u8"��� (������� / ���)",
cmds = {
{name = "/su [ID] [�������] [�������]", desc = u8"������ ������ (�� 6 �����)"},
{name = "/cuff [ID]", desc = u8"������ ���������"},
{name = "/uncuff [ID]", desc = u8"����� ���������"},
{name = "/clear [ID]", desc = u8"����� ������ (�������� ������� �������)"},
{name = "/putpl [ID]", desc = u8"�������� ������������ � ���������� ������"},
{name = "/outpl [ID]", desc = u8"�������� ������������ �� ������"},
{name = "/arrest [ID] [���] [����� 0/1] [����]", desc = u8"���������� � ���"},
{name = "/co", desc = u8"������ ������������� ������������ ������ (Wanted)"},
{name = "/search [ID]", desc = u8"�������� ������ �� ���������/�������"},
{name = "/take [ID]", desc = u8"������ �����, ���������, ������ ��� ��������"},
{name = "/m [�����]", desc = u8"�������� � ����������� �������"},
{name = "/ticket [ID] [�����] [�������]", desc = u8"�������� �����"},
{name = "/patrol", desc = u8"������/��������� �������������� ������"},
{name = "/ram", desc = u8"�������� ����� ���� (�����)"},
{name = "/ftalk", desc = u8"������������ ����� ������ ���. ����������� (���)"}
}
},
{
category = u8"�� (��������)",
cmds = {
{name = "/heal [ID] [����]", desc = u8"�������� ������ (� �������� ��� ������)"},
{name = "/medcard [ID] [��� 1-3] [����]", desc = u8"������/�������� ����������� �����"},
{name = "/changeheal [����]", desc = u8"���������� ���� ������� �� ���������"}
}
},
{
category = u8"�� (�����)",
cmds = {
{name = "/makegun", desc = u8"������� ������ �� ��������/������� � �������"},
{name = "/state", desc = u8"��������� ��������� ������� �������� �� �����"},
{name = "/putammo", desc = u8"��������� ���� �������� � �������� ���������"},
{name = "/takeammo", desc = u8"��������� ���� �������� �� ����� ����"}
}
},
{
category = u8"����, ���� � ������",
cmds = {
{name = "/home", desc = u8"���������� �������� ���� (����������, ����)"},
{name = "/sellhome", desc = u8"������� ��� ����������� ��� ������"},
{name = "/lock", desc = u8"�������/������� ����� �������� ����� ��� ������"},
{name = "/car", desc = u8"���������� ������ ����������� (������������, �����)"},
{name = "/fill", desc = u8"��������� ��������� �� ��� ��� �� ��������"},
{name = "/sellcar [ID] [����]", desc = u8"������� ���� ���������� ������� ������"},
{name = "/biz", desc = u8"���������� �������� (����� ���������, ������)"},
{name = "/sellbiz", desc = u8"������� ������"}
}
}
}

-- �������� ���
local function loadDatabases()
-- Auto-resume AAD if it was active before reload
if aad_active and aad_text ~= "" then
lua_thread.create(function()
wait(3000)  -- wait for SAMP to be ready
if aad_active and aad_text ~= "" then
sampAddChatMessage("[Helper] ����-������� ������������", 0x00FF00)
sendAdCommand(aad_text)
end
end)
end
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
if parsed.mm_tag ~= nil then safeStrCopy(mm_tag, u8:encode(parsed.mm_tag, encoding.default), ffi.sizeof(mm_tag)) end
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
if parsed.call_no_repeat ~= nil then call_no_repeat[0] = parsed.call_no_repeat end
if parsed.module_states then saved_module_states = parsed.module_states end
if parsed.keybinds then
keybinds = {}
for _, kb in ipairs(parsed.keybinds) do
table.insert(keybinds, {key = kb.key, command = kb.command, enabled = kb.enabled, name = kb.name})
end
if #keybinds == 0 then
keybinds = {
{key = 0x4C, command = "/lock", enabled = true, name = "Lock/Unlock"},
{key = 0x4B, command = "/e", enabled = true, name = "Engine On/Off"}
}
end
end
-- ��������: ������������ ������ CP1251 �������/������� � UTF-8
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
    -- saveSettings() �� �������� ����� - ������� ���������� ����
    -- ����������� � ������, ���������� ��� ��������� ��������� ��������
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

-- ���������� ��������
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
call_no_repeat = call_no_repeat[0],
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

-- ����� �������������� ���
local function cp1251_upper(ch)
local b = ch:byte()
if b >= 97 and b <= 122 then return string.char(b - 32) end
if b >= 224 and b <= 255 then return string.char(b - 32) end
if b == 184 then return string.char(168) end
return ch
end

-- Escape special Lua pattern characters in a string
local function escapePattern(s)
    return (s:gsub("([%%%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

-- Truncate UTF-8 string at a valid character boundary (prevents invalid UTF-8 crash)
local function safeUtf8Truncate(s, maxBytes)
    if #s <= maxBytes then return s end
    local cut = maxBytes
    -- Scan backwards to find a valid UTF-8 boundary
    -- Continuation bytes are 0x80-0xBF (10xxxxxx)
    while cut > 0 do
        local b = s:byte(cut)
        if b < 0x80 or b > 0xBF then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. "..."
end

-- Remove invalid UTF-8 sequences from a string (prevents ImGui glyph crash)
local function sanitizeUtf8(s)
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

-- Recompute lower after tag extraction
lower = formatted:lower()

-- Detect car keywords (to skip city removal for cars)
local is_car = false
local car_keywords = {"����", "���", "������", "�����", "������", "��������", "���", "�������", "������", "����", "����", "����", "������", "�����", "�������", "������", "������", "�����", "����", "�������", "���������", "����", "�������", "�������", "����", "�����", "������", "�����", "�����", "���", "����", "�����", "������", "������", "�����", "�������", "�������", "�����", "�����", "�����", "������", "������", "������", "������", "�����", "�����", "�������", "���������", "���", "����", "����", "����", "���", "���", "������", "�����", "���", "������", "����", "�����", "�/�", "�/�", "����", "���", "����", "���������", "�����"}
for _, word in ipairs(car_keywords) do
if lower:find(word, 1, true) then
is_car = true
break
end
end

-- Convert numbers with slang: 50kk -> 50.000.000$, 5mln -> 5.000.000$, 1kkk -> 1.000.000.000$
formatted = formatted:gsub("(%d+)%s*[�k][�k]", "%1.000.000$")
formatted = formatted:gsub("(%d+)%s*[�k][�k][�k]", "%1.000.000.000$")
formatted = formatted:gsub("(%d+)%s*[�m][�l][�n]", "%1.000.000$")
formatted = formatted:gsub("(%d+)%s*[�m][�l][�p][�d]", "%1.000.000.000$")
formatted = formatted:gsub("(%d+)%s*[�m][�i][�l][�l][�i][�a][�p][�d]", "%1.000.000.000$")
formatted = formatted:gsub("(%d+)%s*[�m][�i][�l][�l][�i][�o][�n]", "%1.000.000$")

-- Apply replacement rules
local _rule_count = 0
for _, rule in ipairs(mm_rules) do
_rule_count = _rule_count + 1
if _rule_count > 200 then break end
local abbr = rule.abbreviation
local stem = abbr
if abbr:len() > 3 then stem = abbr:sub(1, -2) end
local abbr_esc = escapePattern(abbr)
local stem_esc = escapePattern(stem)
local pattern
if abbr:len() <= 2 then
pattern = "([%s%,%.])" .. abbr_esc .. "([%s%,%.])"
else
pattern = "([%s%,%.])" .. stem_esc .. "[^%s%,%.]*([%s%,%.])"
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
if formatted:lower():match("^" .. stem_esc) then
formatted = rule.replacement
end
end
end
-- Safety: limit output length to prevent ImGui render overflow
if #formatted > 1000 then formatted = formatted:sub(1, 1000) end

-- Fix declension after prepositions
-- Generic rules above replace all forms with accusative (�����, �������, etc.)
-- but after prepositions, other cases are grammatically required.
local prep_fixes = {
-- �����
{preposition="�", acc="�����", correct="�����"},
{preposition="�����", acc="�����", correct="�����"},
{preposition="�����", acc="�����", correct="�����"},
{preposition="��", acc="�����", correct="�����"},
{preposition="��", acc="�����", correct="�����"},
{preposition="�", acc="�����", correct="�����"},
{preposition="��", acc="�����", correct="������"},
{preposition="���", acc="�����", correct="������"},
{preposition="���", acc="�����", correct="������"},
{preposition="�����", acc="�����", correct="������"},
{preposition="�", acc="�����", correct="�����"},
{preposition="��", acc="�����", correct="�����"},
-- �������
{preposition="�", acc="�������", correct="�������"},
{preposition="�����", acc="�������", correct="�������"},
{preposition="�����", acc="�������", correct="�������"},
{preposition="��", acc="�������", correct="�������"},
{preposition="��", acc="�������", correct="�������"},
{preposition="�", acc="�������", correct="�������"},
{preposition="��", acc="�������", correct="��������"},
{preposition="���", acc="�������", correct="��������"},
{preposition="���", acc="�������", correct="��������"},
{preposition="�����", acc="�������", correct="��������"},
{preposition="�", acc="�������", correct="�������"},
{preposition="��", acc="�������", correct="�������"},
-- ��������
{preposition="�", acc="��������", correct="��������"},
{preposition="�����", acc="��������", correct="��������"},
{preposition="�����", acc="��������", correct="��������"},
{preposition="��", acc="��������", correct="��������"},
{preposition="��", acc="��������", correct="��������"},
{preposition="�", acc="��������", correct="��������"},
{preposition="��", acc="��������", correct="���������"},
{preposition="���", acc="��������", correct="���������"},
{preposition="���", acc="��������", correct="���������"},
{preposition="�����", acc="��������", correct="���������"},
{preposition="�", acc="��������", correct="��������"},
{preposition="��", acc="��������", correct="��������"},
-- �����
{preposition="�", acc="�����", correct="�����"},
{preposition="�����", acc="�����", correct="�����"},
{preposition="�����", acc="�����", correct="�����"},
{preposition="��", acc="�����", correct="�����"},
{preposition="��", acc="�����", correct="�����"},
{preposition="�", acc="�����", correct="�����"},
{preposition="��", acc="�����", correct="������"},
{preposition="���", acc="�����", correct="������"},
{preposition="���", acc="�����", correct="������"},
{preposition="�����", acc="�����", correct="������"},
{preposition="�", acc="�����", correct="�����"},
{preposition="��", acc="�����", correct="�����"},
-- �������
{preposition="�", acc="�������", correct="������"},
{preposition="�����", acc="�������", correct="������"},
{preposition="�����", acc="�������", correct="������"},
{preposition="��", acc="�������", correct="������"},
{preposition="��", acc="�������", correct="������"},
{preposition="�", acc="�������", correct="������"},
{preposition="��", acc="�������", correct="��������"},
{preposition="���", acc="�������", correct="��������"},
{preposition="���", acc="�������", correct="��������"},
{preposition="�����", acc="�������", correct="��������"},
{preposition="�", acc="�������", correct="������"},
{preposition="��", acc="�������", correct="������"},
-- ��������������
{preposition="�", acc="��������������", correct="��������������"},
{preposition="�����", acc="��������������", correct="��������������"},
{preposition="�����", acc="��������������", correct="��������������"},
{preposition="��", acc="��������������", correct="��������������"},
{preposition="��", acc="��������������", correct="��������������"},
{preposition="�", acc="��������������", correct="��������������"},
{preposition="��", acc="��������������", correct="���������������"},
{preposition="���", acc="��������������", correct="���������������"},
{preposition="���", acc="��������������", correct="���������������"},
{preposition="�����", acc="��������������", correct="���������������"},
{preposition="�", acc="��������������", correct="��������������"},
{preposition="��", acc="��������������", correct="��������������"},
-- ���� (���.���: ��.=���.)
{preposition="�", acc="����", correct="�����"},
{preposition="�����", acc="����", correct="�����"},
{preposition="�����", acc="����", correct="�����"},
{preposition="��", acc="����", correct="�����"},
{preposition="��", acc="����", correct="�����"},
{preposition="�", acc="����", correct="�����"},
{preposition="��", acc="����", correct="������"},
{preposition="���", acc="����", correct="������"},
{preposition="���", acc="����", correct="������"},
{preposition="�����", acc="����", correct="������"},
{preposition="�", acc="����", correct="�����"},
{preposition="��", acc="����", correct="�����"},
-- ������� (���.���: ��.=���.)
{preposition="�", acc="�������", correct="��������"},
{preposition="�����", acc="�������", correct="��������"},
{preposition="�����", acc="�������", correct="��������"},
{preposition="��", acc="�������", correct="��������"},
{preposition="��", acc="�������", correct="��������"},
{preposition="�", acc="�������", correct="��������"},
{preposition="��", acc="�������", correct="���������"},
{preposition="���", acc="�������", correct="���������"},
{preposition="���", acc="�������", correct="���������"},
{preposition="�����", acc="�������", correct="���������"},
{preposition="�", acc="�������", correct="��������"},
{preposition="��", acc="�������", correct="��������"},
}
formatted = " " .. formatted .. " "
for _, fix in ipairs(prep_fixes) do
formatted = formatted:gsub("(%s)" .. escapePattern(fix.preposition) .. "%s+" .. escapePattern(fix.acc) .. "([%s%,%.])", "%1" .. fix.preposition .. " " .. fix.correct .. "%2")
end
formatted = formatted:gsub("^%s+", ""):gsub("%s+$", "")
-- Auto-add location for "kuplyu" if no location mentioned
local has_location = false
local loc_words = {"Los Santos", "San Fierro", "Las Venturas", "East", "Ganton", "Idlewood", "Jefferson", "Glen", "Willowfield", "El Corona", "Commerce", "Market", "Verona", "Chinatown", "Palomino", "Montgomery", "Dillimore", "Blueberry", "Flint", "Fort Carson", "Tierra", "Angel", "Bayside", "North Rock", "Valle", "Arco", "Green Palms", "Union", "Strip", "Rockshore", "Pilgrim", "Avalon", "Prickle", "Whitewood", "Pilbox", "Doherty", "Kings", "Paradiso", "Queens", "Hashbury", "Garcia", "Santa Flora", "Foster", "Venturas", "����", "�����", "�����", "������", "������", "�����"}
for _, word in ipairs(loc_words) do
if formatted:lower():find(word:lower(), 1, true) then
has_location = true
break
end
end

-- Detect action type from original text
local is_buy = lower:find("^�����") ~= nil
local is_sell = lower:find("^������") ~= nil
local is_trade = lower:find("^�������") ~= nil
local is_rent_out = lower:find("^����") ~= nil
local is_rent_seek = lower:find("^�����") ~= nil
local is_ad = is_buy or is_sell or is_trade or is_rent_out or is_rent_seek or lower:find("^���������") ~= nil or lower:find("^����") ~= nil or lower:find("^�����") ~= nil

-- Add location for "kuplyu" without location
if (is_buy or is_rent_seek) and not has_location then
formatted = formatted:gsub("^(�����%s+[^%.%d]+)%s*$", "%1 � ����� ����� �����")
if not formatted:lower():find("� ����� �����") then
formatted = formatted:gsub("^(�����%s+[^%.%d]+)(%s+������.*)", "%1 � ����� ����� �����.%2")
end
if not formatted:lower():find("� ����� �����") then
formatted = formatted .. " � ����� ����� �����"
end
end

-- Clean up whitespace
formatted = formatted:gsub("%s+", " ")
formatted = formatted:gsub("^%s+", "")
formatted = formatted:gsub("%s+$", "")

-- Add period before ������
formatted = formatted:gsub("%s+(������)", ". %1")

-- Add "����: " before dollar amounts if not already present
formatted = formatted:gsub("([%s])(%d+%.%d+%$)", "%1���� %2")
formatted = formatted:gsub("^(%d+%.%d+%$)", "���� %1")

-- Check if has price already
local fl = formatted:lower()
local has_price = false
if fl:find("%$") or fl:find("����") or fl:find("���") or fl:find("����") or fl:find("�����") or fl:find("������") or fl:find("��������") or fl:find("������") then
has_price = true
end

-- Auto-add price if buy/sell but no price (NOT for trade/obmen)
if (is_buy or is_sell or is_rent_out or is_rent_seek) and not has_price then
formatted = formatted .. ". ���� ����������"
end

-- ������������ ������� ��� ������ (��� ������� �����������)
if is_trade and fl:find("������") and not (fl:find("������� � ��") or fl:find("������� � ���")) then
local doplata_mine = fl:find("��[�����]") or fl:find("���[��]") or fl:find("���������")
local doplata_theirs = fl:find("���") or fl:find("���")
if doplata_theirs and not doplata_mine then
formatted = formatted .. ". ������� � ����� �������"
elseif doplata_mine and not doplata_theirs then
formatted = formatted .. ". ������� � ���� �������"
end
end

-- Fix double periods and spaces
formatted = formatted:gsub("%.+%.", ".")
formatted = formatted:gsub("%. %.", ".")
formatted = formatted:gsub("%s+$", "")
formatted = formatted:gsub("%s+%.", ".")

-- Add server tag prefix
local tag = detected_tag or u8:decode(ffi.string(mm_tag))
if tag and tag ~= "" then
formatted = tag .. " | " .. formatted
end

-- Capitalize first letter after "TAG | "
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

-- SAMP ad character limit: trim if too long
local MAX_AD_LEN = 250
if #formatted > MAX_AD_LEN then
    -- Try removing auto-added suffixes first
    formatted = formatted:gsub(string.char(0x2E) .. string.char(0x20) .. string.char(0xD6,0xE5,0xED,0xE0,0x20,0xE4,0xEE,0xE3,0xEE,0xE2,0xEE,0xF0,0xED,0xE0,0xFF) .. "$", "")
    formatted = formatted:gsub(string.char(0x20,0xE2,0x20,0xEB,0xFE,0xE1,0xEE,0xE9,0x20,0xF2,0xEE,0xF7,0xEA,0xE5,0x20,0xF8,0xF2,0xE0,0xF2,0xE0) .. string.char(0x2E,0x3F), "")
    -- If still too long, hard truncate at last space before limit
    if #formatted > MAX_AD_LEN then
        local tag_part = ""
        local body = formatted
        local pipe_pos = formatted:find(" | ")
        if pipe_pos then
            tag_part = formatted:sub(1, pipe_pos + 2)
            body = formatted:sub(pipe_pos + 3)
        end
        local max_body = MAX_AD_LEN - #tag_part
        if #body > max_body then
            local cut = body:sub(1, max_body)
            local last_space = cut:match(".*%s%S*$")
            if last_space and #last_space < max_body then
                body = body:sub(1, #last_space - 1)
            else
                body = cut
            end
            formatted = tag_part .. body
        end
    end
end
return formatted
end

-- �������� ������� (����������� ��������)
local function isPlayerOnline(nickname)
-- Use cache for safety (render thread safe)
return isOnlineCached(nickname)
end

-- ���� ������ �������
local function getOnlinePlayersFromDb()
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

-- ===== ��-������: ��������� ��������� =====

-- ������ ������ (����������� playerLogin)
local user = {
    nick = "", fullName = "", name = "", family = "",
    rang = 0, rangName = "", podr = "", podrNum = 0,
    phone = "", id = -1, isWork = false
}

-- ������ ���� (��� /mmact)
local userTarget = { id = -1, nick = "", name = "" }

-- ��������� ��-���������
local rp_settings = {
    active = imgui.new.bool(false),
    wait = false,
    selected = 1,
    setList = imgui.new.int(0),
    -- �����: [1]=�����, [2]=���, [3]=��� ����
    set = { [1] = {}, [2] = {}, [3] = {} },
    -- ���� �����/������
    window = {
        type = 0, list = {},
        buf = imgui.new.char[256](""),
        select = 0, is = -1,
    },
    -- ��������������
    temp = {
        name = imgui.new.char[64](""),
        text = imgui.new.char[16384](""),
        cmd = imgui.new.char[32](""),
    },
}

-- ���� ��� ���������
local rp_tegs = {
    {   -- ����� ����
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
    {   -- ���� ���� (/mmact)
        {'<tFio>', function() return userTarget.name end},
        {'<tName>', function() return (userTarget.nick):match('(.-)_') or userTarget.name end},
        {'<tNick>', function() return userTarget.nick end},
        {'<tId>', function() return tostring(userTarget.id) end},
    },
}

local rp_cur_tegs = 1
local rp_sum_tegs = 0
local rp_thread = nil
local rp_reading_stats = false
local rp_stats_step = "idle"
local rp_stats_text = ""
local rp_show_window = imgui.new.bool(false)
local rp_show_edit = imgui.new.bool(false)
local rp_edit_chapter = 1
local rp_edit_index = 0
local rp_path = getFolderPath(0x1C) .. "\\helper_rp_settings.json"

local function setCurTeg(chapter)
    if chapter == 2 then
        rp_sum_tegs = #rp_tegs[1]
        rp_cur_tegs = 1
    else
        rp_sum_tegs = #rp_tegs[1] + #rp_tegs[2]
        rp_cur_tegs = 2
    end
end

local function saveRpSettings()
    local file = io.open(rp_path, "w")
    if file then
        file:write(json.encode(rp_settings.set))
        file:close()
    end
end


local function initDefaultRp()
    if rp_settings.set[1] and #rp_settings.set[1] > 0 then return end

    -- ����� 1: ����� ��������� (��������������� � ��, ��� �� ����������� �������������)
    -- ����-��������� (�������, ������, �����, �������) �������� �� ������� � auto_rp
    rp_settings.set[1] = {
        {
            name = "��������",
            text = "/me ������ ����� ������� �� �������\n<600>\n/me ������� �������� �� �����\n<400>\n/me ����� ����� ������� � ������\n<400>\n/me ������ ��������� � ��������\n<500>\n/do �������� �������, ��� ���"
        },
        {
            name = "�������� ��������",
            text = "/me ������ �������� �� �����\n<400>\n/me ������� �������� �����\n<300>\n/do �������� ��������"
        },
        {
            name = "�������� ����",
            text = "/me ������ ������� ����\n<500>\n/me �������� ������ �������\n<400>\n/me ������ ��������� ������� ����\n<600>\n/me �������� ������ �������\n<400>\n/do ������� ������"
        },
        {
            name = "�������� �������",
            text = "/me ������ ������� �� ����������� �������\n<500>\n/me ������ ������� �� ������ ��������\n<400>\n/me ������� �������\n<800>\n/do ������� ������, ���� � ������ �����"
        },
        {
            name = "�������� ��������",
            text = "/me ������ ����������� ����� �� �����\n<500>\n/me ������� ��������\n<400>\n/me ������� ��������\n<800>\n/do �������� ��������"
        },
        {
            name = "�������� ��������",
            text = "/me ������ ����� � ����������\n<500>\n/me ������ �����\n<400>\n/me ������� ��������\n<800>\n/do �������� �����"
        },
        {
            name = "�����������",
            text = "/me ���������� �� ��������\n<800>\n/do ����������� ������� ���������"
        },
        {
            name = "������� �����",
            text = "/me ���� ����� � �����\n<400>\n/me ����� ������ ������\n<300>\n/do ����� � ����, ����� �������"
        },
        {
            name = "������ �����",
            text = "/me �������� ������ ������\n<300>\n/me ������� ����� �� ����\n<400>\n/do ����� �� �����"
        },
        {
            name = "��������� ������",
            text = "/me ����� �� ������\n<500>\n/me ������ ����� � �������\n<400>\n/me ������� �������� � ��������\n<800>\n/do ������� ��������� � ���\n<2000>\n/me ������� �������� �� ���������\n<400>\n/me ������� ����� ������� �� �������"
        },
        {
            name = "������� �����",
            text = "/me ������� � ������\n<400>\n/me ������� �� ����� ������\n<300>\n/me ������ ����� ������\n<400>\n/do ����� ������"
        },
        {
            name = "������� �����",
            text = "/me ��������� ����� ������\n<400>\n/do ����� ������"
        },
        {
            name = "������� � ��������",
            text = "/me ������ �������� ������\n<400>\n/me ������ ������ ���� �� ���������\n<500>\n/me ������ ��������\n<300>\n/do �������� ������"
        },
        {
            name = "��������� � �����",
            text = "/me ������� � �����\n<400>\n/me �������� � �����\n<500>\n/do ���� � �����"
        },
        {
            name = "������� ����� ����",
            text = "/me ������ ����� �� �������\n<400>\n/me ������� ���� � �������� ��������\n<500>\n/me �������� ���� � ������ �����\n<400>\n/me ����� � ���������\n<300>\n/me ������ ����� �� �����"
        },
        {
            name = "������ ����",
            text = "/me ������ ��������� � ����\n<500>\n/me ������ ������ ����\n<600>\n/do Ҹ���� ���� ���������\n<400>\n/me �������� ��������� �� ����"
        },
        {
            name = "������� �������",
            text = "/me ������ ������� �� �������\n<400>\n/me ������� �������\n<300>\n/me ������ �����\n<400>\n/do ������� �������, ����� � ����"
        },
        {
            name = "������ �������",
            text = "/me ������ �������\n<300>\n/me ����� ������� � ����� � ������\n<400>\n/do ������� � �������"
        },
        {
            name = "������ ��������",
            text = "/me ������ �������� �� �������\n<400>\n/me ����� �������� �� ������\n<300>\n/do �������� ������"
        },
        {
            name = "����� ��������",
            text = "/me ���� �������� � ������\n<300>\n/me ����� �������� � ������\n<400>\n/do �������� ������"
        },
    }

    -- ����� 2: ��� ��������� (������ � ������������ ��������� ���)
    rp_settings.set[2] = {}

    -- ����� 3: ��� ���� (/mmact) � ������� ������������� ���������
    rp_settings.set[3] = {
        {
            name = "�������� ����������",
            text = "/me ��������� � ����������\n<500>\nr:{������������}{������ ����}r, � <myRang> <myPodr>.\n<800>\n/me ��������� �������������\n<600>\n/do ������������� � ����\n<1000>\n����� ���������� ���������.\n<0>\n/me ����� �������������\n<400>\n/do �������� ������"
        },
        {
            name = "������� ��������",
            text = "/me ������� � <tFio>\n<500>\n/me ������� ���� �� �����\n<400>\nr:{������}{������������}r, ���������� ������ �������.\n<1000>\n/me ������ ����� � �����\n<400>\n/me ������� ������ �� �����\n<800>\n/do ����� ����� ������\n<600>\n/me ����� ����� �� ����"
        },
        {
            name = "�����",
            text = "/me ������� � <tFio> �����\n<500>\n/me ������������ ���� ������������\n<400>\n/do ���� �������������\n<600>\n/me ����� ���������� ��������\n<800>\n/me �������� ���������� �������\n<600>\n/me �������� ��������\n<500>\n/do ����� ��������"
        },
        {
            name = "����������",
            text = "/me ������ ��������� ������� ���� <tFio>\n<500>\n/do ���� ��������� �� �����\n<400>\n/me ������ ��������� � �����\n<300>\n/me ����� ��������� �� ��������\n<500>\n/do ��������� ������, ���� �������������\n<400>\n�� ���������. �������� �� ����."
        },
        {
            name = "�������� � ������",
            text = "/me ������ ������ ����� ���������� ������\n<500>\n/me ������� �� ������ <tFio>, �������� � �����\n<600>\n/do ����������� � ������\n<400>\n/me ������ ����� ������\n<300>\n/do ����� �������"
        },
        {
            name = "�������� �� ������",
            text = "/me ������ ����� ������\n<400>\n/me ���� <tFio> �� ����\n<400>\n/me ����� ����� �� ������\n<500>\n/do ����������� �� �����"
        },
        {
            name = "�����",
            text = "/me ������� � <tFio>\n<400>\n/me ������ ������� � �����������\n<500>\n/me �������� ���������\n<800>\n/me ������� ��������� �� ��������\n<400>\n/me �������� ���������\n<600>\n/do ��������� ��������"
        },
        {
            name = "���������",
            text = "/me ������� � <tFio>\n<400>\n/me ������ ���������\n<500>\n/me �������� ��������� � �����\n<800>\n/do ������� ������������\n<600>\n/me ����� ���������\n<400>\n/me ������ ��������\n<500>\n/me ������� ��������\n<800>\n/do �������� ��������"
        },
        {
            name = "�������",
            text = "/me ������ �������\n<500>\n/me ������ �������\n<400>\n/me ������ ����\n<300>\n/me ��������� ���� <tFio>\n<800>\n/me ������� �������\n<600>\n/do ���� ����������, ������� ��������\n<400>\n/me ����� �������"
        },
        {
            name = "������",
            text = "/me ��� �������� <tFio>\n<500>\n/me ������ ������� � �����\n<400>\n/do ������� �������\n<600>\nr:{����������}{���������}r, ��� ���������.\n<0>\n/me ������� ��������� � �������\n<800>\n/do ����� ������� �� ������"
        },
        {
            name = "����������� ����",
            text = "/me ������� � <tFio>\n<400>\nr:{������������}{�����������}{������ ����}r.\n<800>\n/do ˸���� ����� �������"
        },
        {
            name = "�����������",
            text = "/me �������� ���� <tFio>\n<500>\n/me ����� ����\n<400>\n/do ������� �����������"
        },
    }

    saveRpSettings()
end

local function loadRpSettings()
    local file = io.open(rp_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local ok, parsed = pcall(json.decode, content)
        if ok and parsed then
            for k, v in pairs(parsed) do
                rp_settings.set[tonumber(k)] = v
            end
        end
    end
    -- ���� ���� ������ ��� ��� � ��������� ��������� ���������
    initDefaultRp()
end

-- playerLogin: ����-����������� �������/�����/�������������
local function playerLogin()
    if rp_reading_stats then return end
    rp_reading_stats = true
    rp_stats_text = ""
    rp_stats_step = "waiting"  -- waiting -> menu -> stats -> done

    lua_thread.create(function()
        wait(500)
        -- ������� ������� /stats �������� (�������)
        sampSendChat("/stats")

        local timer = os.time() + 3
        while rp_stats_step == "waiting" and os.time() < timer do wait(100) end

        -- ���� /stats �� ������ ���������� � ������� ����� /mn
        if rp_stats_step == "waiting" then
            sampSendChat("/mn")
            timer = os.time() + 5
            while rp_stats_step == "waiting" and os.time() < timer do wait(100) end
        end

        -- ���� ��������� ���� � ��� ���� ������ ����� ���� � ����������
        if rp_stats_step == "menu" then
            timer = os.time() + 5
            while rp_stats_step ~= "done" and os.time() < timer do wait(100) end
        end

        -- ��� ��������� ������ ����������
        timer = os.time() + 5
        while rp_stats_step == "stats" and os.time() < timer do wait(100) end

        if rp_stats_text ~= "" then
            local id_ok2, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
            if not id_ok2 then return end
            user.nick = sampGetPlayerNickname(pid)
            user.rang = tonumber(rp_stats_text:match("����:%s*{.-}(%d+)") or "0")
            user.podr = rp_stats_text:match("�������������:%s*{.-}(.-)\n") or ""
            user.rangName = rp_stats_text:match("���������:%s*{.-}(.-)\n") or ""
            user.phone = rp_stats_text:match("�������:%s*{.-}(%d+)") or ""

            user.fullName = (user.nick):gsub('_', ' ')
            user.name = (user.fullName):match('(.-) .-') or user.fullName
            user.family = (user.fullName):match('.- (.-)') or ""
            user.isWork = not rp_stats_text:find("������")

            local pl = user.podr:lower()
            if pl:find("�����") or pl:find("��") then user.podrNum = 1
            elseif pl:find("���") or pl:find("����") then user.podrNum = 2
            elseif pl:find("���") or pl:find("�������") or pl:find("���") then user.podrNum = 3
            elseif pl:find("���") or pl:find("��") then user.podrNum = 4
            elseif pl:find("���") then user.podrNum = 5
            else user.podrNum = 0 end

            user.id = pid
            sampAddChatMessage("[Helper] ��-������ ���������: " .. user.fullName .. " | " .. user.rangName .. " | " .. user.podr, 0x00FF00)
        else
            sampAddChatMessage("[Helper] �� ������� ��������� ����������. ���������� /rplogin", 0xFF0000)
        end
        rp_reading_stats = false
        rp_stats_step = "done"
    end)
end


local function stopRp()
    if rp_thread then
        local status = rp_thread:status()
        if status ~= "dead" then
            rp_thread:terminate()
            sampAddChatMessage("[Helper] ��������� �����������", 0xFFAA00)
        end
    end
    rp_settings.active[0] = false
    rp_settings.wait = false
    rp_settings.window.is = -1
end

local function playRp(text, test)
    if rp_settings.active[0] then
        lua_thread.create(function() sampAddChatMessage("[Helper] ��������� ��� �����������. /mmstop ��� ���������", 0xFF0000) end)
        return
    end
    rp_settings.active[0] = true

    rp_thread = lua_thread.create(function()
        local ok, err = pcall(function()
        local chapter = rp_settings.setList[0] + 1
        setCurTeg(chapter)
        local typeTeg = rp_cur_tegs

        text = text .. '\n'

        -- ������������ r:{...}{...}:r
        for line in string.gmatch(text, 'r:(.-):r') do
            local randText = {}
            for rand in string.gmatch(line, '{(.-)}') do
                randText[#randText + 1] = rand
            end
            if #randText > 0 then
                local id = math.random(1, #randText)
                text = text:gsub('r:' .. line .. ':r', randText[id], 1)
            end
        end

        -- ������ �����
        for i = 1, rp_sum_tegs do
            if rp_tegs[1][i] then
                local textTeg = test and (rp_tegs[1][i][1] .. ":OK") or rp_tegs[1][i][2]()
                text = text:gsub(rp_tegs[1][i][1], textTeg)
            else
                local id = i - #rp_tegs[1]
                if rp_tegs[typeTeg][id] then
                    local textTeg = test and (rp_tegs[typeTeg][id][1] .. ":OK") or rp_tegs[typeTeg][id][2]()
                    text = text:gsub(rp_tegs[typeTeg][id][1], textTeg)
                end
            end
        end

        if test then
            sampAddChatMessage("[Helper] ���� ���������. ���� �������� �� <���>:OK", 0x00FF00)
        end

        -- ���������� ���������
        for line in string.gmatch(text, '(.-)\n') do
            if line == '' then goto skip end
            if not rp_settings.active[0] then break end

            -- ����� <N>
            if line:find('^<%d+>') then
                local time = tonumber(line:match('<(%d+)>'))
                if time == 0 then
                    rp_settings.wait = true
                    sampAddChatMessage("[Helper] �����. /mmnext - ����������, /mmstop - ����������", 0xFFAA00)
                    while rp_settings.wait and rp_settings.active[0] do wait(0) end
                else
                    wait(time)
                end
                goto skip
            end

            -- ���� ����� #input:
            if line:find('^#input:') then
                rp_settings.window.type = 1
                rp_settings.window.is = 1
                rp_settings.window.select = 0
                imgui.StrCopy(rp_settings.window.buf, '')
                while rp_settings.window.is == 1 and rp_settings.active[0] do wait(0) end
                goto skip
            end

            -- ���� ������ #list: {a}{b}{c}
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

            -- ������� ���� #close:
            if line:find('^#close:') then
                rp_settings.window.is = -1
                goto skip
            end

            -- ����������� {w}
            if rp_settings.window.is == 2 and line:find('{w}') then
                if rp_settings.window.type == 1 then
                    local bufText = u8:decode(ffi.string(rp_settings.window.buf))
                    line = line:gsub('{w}', bufText)
                elseif rp_settings.window.type == 2 then
                    line = line:gsub('{w}', rp_settings.window.list[rp_settings.window.select] or "")
                end
            end

            -- �������� ������
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
            sampAddChatMessage("[Helper] ��������� ���������", 0x00FF00)
        end
    end)
end

-- /mmact [id] � ����� ���� ��� ���������
local function cmdAct(text)
    local id = tonumber(text:match('(%d+)'))
    if not id then
        sampAddChatMessage("[Helper] �����������: /mmact [id]", 0xFFAA00)
        return
    end
    local res, handle = sampGetCharHandleBySampPlayerId(id)
    if not res then
        sampAddChatMessage("[Helper] ����� �� ������", 0xFF0000)
        return
    end
    local x1, y1 = getCharCoordinates(PLAYER_PED)
    local x2, y2 = getCharCoordinates(handle)
    if math.sqrt((x1-x2)^2 + (y1-y2)^2) > 5 then
        sampAddChatMessage("[Helper] ����� ������� ������. ��������� �����.", 0xFF0000)
        return
    end
    userTarget.id = id
    userTarget.nick = sampGetPlayerNickname(id)
    userTarget.name = userTarget.nick:gsub('_', ' ')
    rp_show_window[0] = true
    sampAddChatMessage("[Helper] ����: " .. userTarget.name .. " [ID:" .. id .. "]", 0x00FF00)
end

-- ===== ����� ��-������ =====


-- ===== ���-������� =====

-- ���������: ������ ���� ��� �����/�� ���
local anag_words = {
    [1] = {"�����������", "������������", "��������", "��������", "�������", "�������������", "������", "��������", "����", "���������"},
    [2] = {"�������", "������", "�������", "���������", "�����", "��������", "���������", "�����", "�����", "�����"},
    [3] = {"������", "������", "��������", "����������", "���������", "���������", "������", "������", "�������", "�����"},
}

local anag_active = false
local anag_current_word = ""
local anag_current_result = ""

local function createAnagram(word, separator, firstLetter)
    local sep = separator or "."
    local letters = {}
    for i = 1, #word do
        letters[i] = word:sub(i, i)
    end
    -- �������������
    for i = 1, #letters do
        local j = math.random(#letters)
        letters[i], letters[j] = letters[j], letters[i]
    end
    if firstLetter and #letters > 0 then
        letters[1] = letters[1]:upper()
    end
    return table.concat(letters, sep)
end

local function startAnagram(type_num)
    type_num = tonumber(type_num) or 1
    if type_num < 1 or type_num > 3 then
        sampAddChatMessage("[Helper] �������������: /anag [1-3] (1=�����, 2=�������, 3=������)", 0xFFAA00)
        return
    end
    local words = anag_words[type_num]
    if not words or #words == 0 then
        sampAddChatMessage("[Helper] ��� ���� ��� ��������� ���� " .. type_num, 0xFF0000)
        return
    end
    local word = words[math.random(1, #words)]
    local anagram = createAnagram(word, ".", true)
    anag_current_word = word
    anag_current_result = anagram
    anag_active = true

    -- ��������� � ���
    sampSetChatInputEnabled(true)
    local prefix = ""
    if user.podr and user.podr:lower():find("�����") then
        prefix = "/t "
    elseif user.podr and user.podr:lower():find("�����") then
        prefix = "/u "
    end
    sampSetChatInputText(prefix .. anagram)
    sampAddChatMessage("[Helper] ���������: " .. anagram .. " (�����: " .. word .. ")", 0x00FF00)
end

-- tvlift: ���� � ��-�����
local tvlift_active = false
local function cmdTvlift(floor_str)
    local floor = tonumber(floor_str)
    if not floor then
        sampAddChatMessage("[Helper] �������������: /tvlf [���� 1-21]", 0xFFAA00)
        return
    end
    -- �������� ������� (��-����� � SF)
    local x, y, z = getCharCoordinates(PLAYER_PED)
    -- ���� ��-�����: �������� 1839, -1264, 13
    if not isCharInArea3d(PLAYER_PED, 1839.5557, -1264.6527, 13.4299, 1765.8602, -1319.9817, 134.1671, false) then
        sampAddChatMessage("[Helper] �� ������ ���������� ����� � ������ ��-�����.", 0xFF0000)
        return
    end
    if floor < 1 or floor > 21 then
        sampAddChatMessage("[Helper] ���� ������ ���� �� 1 �� 21.", 0xFF0000)
        return
    end
    local sex = user.name and user.name:sub(-1):lower() == "�" and "��" or "�"
    sampSendChat("/me ����" .. sex .. " �� ������ �����, ������ " .. floor .. " ����")
    tvlift_active = true
    sampSendChat("/tvlift")
end

-- uninvite: ���������� � ��-����������
local function cmdUninvite(arg)
    local id, reason = arg:match("^(%d+)%s+(.*)")
    if not id then
        sampAddChatMessage("[Helper] �������������: /uninv [id] [�������]", 0xFFAA00)
        return
    end
    id = tonumber(id)
    if not sampIsPlayerConnected(id) then
        sampAddChatMessage("[Helper] ����� �� ��������� � �������.", 0xFF0000)
        return
    end
    local nick = sampGetPlayerNickname(id)
    local name = nick:gsub('_', ' ')

    lua_thread.create(function()
        -- ��-��������� ����������
        sampSendChat("/me ������ ����� � ������� ������ �����������")
        wait(800)
        sampSendChat("/me ������ ����� � ����� ���� " .. name)
        wait(800)
        sampSendChat("/do ����� �������� �� ������ ��������")
        wait(600)
        sampSendChat("/me ������� ��������� �� ����������")
        wait(800)
        sampSendChat("/me �������� ������� � ������ �� ���������")
        wait(600)
        sampSendChat("/me ����� ����� � ����")
        wait(500)
        -- ��������� � �����
        if user.podr and user.podr ~= "" then
            sampSendChat("/r ��������� " .. name .. " ������. �������: " .. reason)
            wait(300)
        end
        -- ���� ����������
        sampSendChat("/uninvite " .. id .. " " .. reason)
        sampAddChatMessage("[Helper] ���������� " .. name .. " ���������. �������: " .. reason, 0x00FF00)
    end)
end

-- ����: ����-��������� ������/����� �����
local efir_active = false
local efir_start_text = "/me ����� �������� � �������� ��������\n<800>\n/do �������� �������, �������� ������\n<500>\n/efir"
local efir_end_text = "/me ���� ��������\n<500>\n/do �������� �����, �������� ��������\n<400>\n/efir"

local function cmdEfir()
    if efir_active then
        sampAddChatMessage("[Helper] ���� ��� �������. ����������� /mmstop ��� ���������.", 0xFFAA00)
        return
    end
    efir_active = true
    efir_stats.start_time = os.time()
    efir_stats.sms = 0
    efir_stats.calls = 0
    efir_stats.lines = 0
    playRp(efir_start_text, false)
    sampAddChatMessage("[Helper] ���� �����. /endefir ��� ����������.", 0x00FF00)
end

local function cmdEndEfir()
    if not efir_active then
        sampAddChatMessage("[Helper] ���� �� �������.", 0xFFAA00)
        return
    end
    playRp(efir_end_text, false)
    efir_active = false
    efir_stats.start_time = 0
    efir_stats.sms = 0
    efir_stats.calls = 0
    efir_stats.lines = 0
    sampAddChatMessage("[Helper] ���� ��������.", 0x00FF00)
end

-- /find: ����� ����������� � ��������� �������
local find_list = {}
local find_selected = 0
local find_show = imgui.new.bool(false)

local function cmdFind()
    sampSendChat("/find")
    sampAddChatMessage("[Helper] �������� ������� ������ �����������...", 0x00FF00)
end

-- ׸���� ������ ���
local blacklist_data = {}
local blacklist_show = imgui.new.bool(false)
local blacklist_url = ""

local function loadBlacklist()
    local path = getFolderPath(0x1C) .. "\\helper_blacklist.json"
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local ok, parsed = pcall(json.decode, content)
        if ok and parsed and type(parsed) == "table" then
            blacklist_data = parsed
        end
    end
end

local function saveBlacklist()
    local path = getFolderPath(0x1C) .. "\\helper_blacklist.json"
    local file = io.open(path, "w")
    if file then
        file:write(json.encode(blacklist_data))
        file:close()
    end
end

local function addBlacklistNick(nick, reason)
    nick = nick:lower()
    blacklist_data[nick] = { reason = reason or "", added = os.date("%d.%m.%Y") }
    saveBlacklist()
    sampAddChatMessage("[Helper] " .. nick .. " �������� � ������ ������", 0x00FF00)
end

local function removeBlacklistNick(nick)
    nick = nick:lower()
    if blacklist_data[nick] then
        blacklist_data[nick] = nil
        saveBlacklist()
        sampAddChatMessage("[Helper] " .. nick .. " ����� �� ������� ������", 0x00FF00)
    else
        sampAddChatMessage("[Helper] " .. nick .. " �� ������ � ������ ������", 0xFFAA00)
    end
end

local function checkBlacklistNick(nick)
    if not nick then return false end
    return blacklist_data[nick:lower()] ~= nil
end

-- ����-����������
local efir_stats = { sms = 0, calls = 0, lines = 0, start_time = 0 }

local function cmdEfirStats()
    if efir_stats.start_time == 0 then
        sampAddChatMessage("[Helper] ���� ��� �� �����. /mmefir ��� ������.", 0xFFAA00)
        return
    end
    local elapsed = os.time() - efir_stats.start_time
    local mins = math.floor(elapsed / 60)
    local secs = elapsed % 60
    sampAddChatMessage(string.format("[Helper] ����-����������: %d� %d� | SMS: %d | ������: %d | �����: %d",
        mins, secs, efir_stats.sms, efir_stats.calls, efir_stats.lines), 0x00FFCC)
end

-- ����-����� �� ������ � �����
local auto_answer_enabled = imgui.new.bool(false)
local auto_answer_text = imgui.new.char[257]("")

local function cmdAutoAnswer(arg)
    if arg and arg ~= "" then
        safeStrCopy(auto_answer_text, u8:encode(arg, encoding.default), ffi.sizeof(auto_answer_text))
        auto_answer_enabled[0] = not auto_answer_enabled[0]
        if auto_answer_enabled[0] then
            sampAddChatMessage("[Helper] ����-����� �������: " .. arg, 0x00FF00)
        else
            sampAddChatMessage("[Helper] ����-����� ��������", 0xFFAA00)
        end
    else
        auto_answer_enabled[0] = not auto_answer_enabled[0]
        if auto_answer_enabled[0] then
            local txt = u8:decode(ffi.string(auto_answer_text))
            sampAddChatMessage("[Helper] ����-����� �������: " .. txt, 0x00FF00)
        else
            sampAddChatMessage("[Helper] ����-����� ��������", 0xFFAA00)
        end
    end
end

-- ===== ����� ���-������� =====
-- ������ �������
modules = {
{
id = "autocall_db",
name = u8" ���� � ������",
description = u8"������ ������������� ��������� ��� ��� �� �������, ��������� ���� ��������� � �� ������ ���������, �������� �� � ����.\n����� �� ������ � 1 ���� ���������� 1-3 ��������� �������, ������� ������ ������, ��� ����� ����� � ��� �� �����.",
enabled = false,
drawSettings = function()
local total_records = 0
for _ in pairs(player_db) do total_records = total_records + 1 end

imgui.TextUnformatted(u8"����������:")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"����� ��������� � ����: " .. total_records)

if os.time() - online_list_cache_time > 3 then
    online_list_cache = getOnlinePlayersFromDb()
    online_list_cache_time = os.time()
end
local online_list = online_list_cache
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"��������� ������ ����� ������: " .. #online_list)

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextUnformatted(u8"��������� �������:")
imgui.PushItemWidth(150)
imgui.SliderInt(u8"�������� ������ (��)", call_delay, 2000, 15000)
imgui.InputInt(u8"����� ������� �� ������", max_calls_session)
imgui.InputInt(u8"�� ������� �������� (�����)", call_cooldown_hours, 0, 24)
imgui.PopItemWidth()
if imgui.Checkbox(u8"�� ��������� ������ (�������)", call_no_repeat) then lua_thread.create(function() saveSettings() end) end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"���� �������� � �� ������ ���, ���� ��� ������. ������� ������������. ����� � ������ ����.")
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
imgui.TextUnformatted(u8"��������:")
imgui.PopStyleColor()
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"��������� �� ����� ��������: " .. called_recently)

imgui.Spacing()
if imgui.Button(u8"�������� ������� �������") then
last_called_queue = {{nick = "__CLEAR__", time = 0}}
lua_thread.create(function() saveSettings() sampAddChatMessage("[Helper] ������� ������� ��������", 0x00FF00) end)
end
imgui.SameLine()
if imgui.Button(u8"�������� ��") then
player_db_queue = {{sender = "__CLEAR__", phone = ""}}
last_called_queue = {{nick = "__CLEAR__", time = 0}}
lua_thread.create(function() saveDatabase() saveSettings() sampAddChatMessage("[Helper] �� �������", 0x00FF00) end)
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if call_active then
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0, 1))
imgui.TextUnformatted(u8"������: ���� ������...")
imgui.PopStyleColor()
imgui.TextUnformatted(u8"������: " .. u8:encode(call_current_nick) .. " (" .. call_current_phone .. ")")
if imgui.Button(u8"���������� ������") then call_active = false end
else
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.5, 0, 1))
imgui.TextUnformatted(u8"������: ��������")
imgui.PopStyleColor()
if #online_list > 0 then
if imgui.Button(u8" ��������� ������-�������") then
if not call_worker_running then
call_active = true
call_worker_running = true
show_main_window[0] = false
lua_thread.create(onlineCallWorker, online_list)
end
end
else
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1))
imgui.TextUnformatted(u8"��� ��������� ������ ��� �������")
imgui.PopStyleColor()
end
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextUnformatted(u8"��������� ��������� ����������:")
-- Cache sorted list, rebuild every 3 seconds (not every frame!)
if os.time() - db_sorted_cache_time > 3 then
    db_sorted_cache = {}
    for nick, data in pairs(player_db) do
        table.insert(db_sorted_cache, {nick = nick, data = data})
    end
    table.sort(db_sorted_cache, function(a, b) return a.nick < b.nick end)
    db_sorted_cache_time = os.time()
end
local db_show = math.min(#db_sorted_cache, 20)
if #db_sorted_cache > 20 then
    imgui.TextUnformatted(u8"�������� ������ 20 �� " .. #db_sorted_cache .. " ���������")
end
imgui.Spacing()
for i = 1, db_show do
    local entry = db_sorted_cache[i]
    local is_on = isPlayerOnline(entry.nick) and " [+]" or ""
    imgui.TextUnformatted(u8:encode(entry.nick) .. " | " .. tostring(entry.data.phone) .. is_on)
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

if imgui.Button(u8"�������� ������� �������") then
    call_history_show[0] = not call_history_show[0]
end

if call_history_show[0] then
    imgui.Spacing()
    local hist_count = 0
    for _ in pairs(last_called) do hist_count = hist_count + 1 end
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 1, 1))
    imgui.TextUnformatted(u8"������� ������� (" .. hist_count .. "):")
    imgui.PopStyleColor()
    if hist_count == 0 then
        imgui.TextUnformatted(u8"������� �����.")
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
            imgui.TextUnformatted(u8:encode(entry.nick) .. " | " .. phone .. " | " .. time_str)
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
name = u8" ����-����������",
description = u8"������������� ���������� ���������� � �������� ����������. ������������ ������� � �������.",
enabled = false,
drawSettings = function()
    static_aad_buf = static_aad_buf or imgui.new.char[129]("")
    safeStrCopy(static_aad_buf, u8:encode(aad_text), ffi.sizeof(static_aad_buf))
static_aad_active = static_aad_active or imgui.new.bool(false)
    static_aad_active[0] = aad_active
    if imgui.Checkbox(u8"������������ ����-����������##checkbox_aad", static_aad_active) then
        aad_active = static_aad_active[0]
        if aad_active then
            aad_text = u8:decode(ffi.string(static_aad_buf))
            lua_thread.create(function() sendAdCommand(aad_text) end)
        end
    end

    imgui.PushItemWidth(350)
    if imgui.InputText(u8"����� ����������##input_aad", static_aad_buf, 129) then
        aad_text = u8:decode(ffi.string(static_aad_buf))
    end
    if imgui.SliderInt(u8"�������� ����� �������� (��)##delay_aad", aad_delay, 3000, 30000) then lua_thread.create(function() saveSettings() end) end
    imgui.PopItemWidth()

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))

    imgui.TextUnformatted(u8"-> �� ������ ����� ������������ �������: /aad [�����]")

    imgui.PopStyleColor()
    imgui.Spacing()

    imgui.Columns(2, "aad_columns", true)
    imgui.SetColumnWidth(0, 290)
    imgui.SetColumnWidth(1, 290)

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 0.8, 1, 1))

    imgui.TextUnformatted(u8"������� ����������:")

    imgui.PopStyleColor()
    imgui.SameLine()
    if imgui.Button(u8"��������##add_tpl", imgui.ImVec2(70, 20)) then
        local current_str = ffi.string(static_aad_buf)  -- UTF-8 for ImGui display
        if current_str ~= "" then
            local exists = false
            for _, val in ipairs(aad_templates) do
                if val == current_str then exists = true break end
            end
            if not exists then
                table.insert(aad_templates, current_str)
                lua_thread.create(function() saveSettings() end)
            end
        end
    end

    imgui.BeginChild("templates_child", imgui.ImVec2(280, 150), true)
    if #aad_templates > 0 then
        for idx, tpl in ipairs(aad_templates) do
            imgui.PushIDStr("tpl_" .. idx)
            if imgui.Button(u8"�������") then
                for i = 0, 128 do static_aad_buf[i] = 0 end
                if #tpl < 128 then ffi.copy(static_aad_buf, tpl) end
                aad_text = u8:decode(tpl)  -- UTF-8 -> CP1251 for sending
                lua_thread.create(function() saveSettings() end)
            end
            imgui.SameLine()
            if imgui.Button(u8"X") then
                table.remove(aad_templates, idx)
                lua_thread.create(function() saveSettings() end)
                imgui.PopID()
                break
            end
            imgui.SameLine()
            imgui.TextUnformatted(tpl)  -- already UTF-8
            imgui.PopID()
        end
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
        imgui.TextUnformatted(u8"��� ����������� ��������.")
        imgui.PopStyleColor()
    end
    imgui.EndChild()

    imgui.NextColumn()

    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.7, 0.3, 1))

    imgui.TextUnformatted(u8"������� ����������:")

    imgui.PopStyleColor()
    imgui.SameLine()
    if imgui.Button(u8"��������##clear_hist", imgui.ImVec2(70, 20)) then
        aad_history = {}
        lua_thread.create(function() saveSettings() end)
    end

    imgui.BeginChild("history_child", imgui.ImVec2(280, 150), true)
    if #aad_history > 0 then
        for idx, hist in ipairs(aad_history) do
            imgui.PushIDStr("hist_" .. idx)
            if imgui.Button(u8"�������") then
                for i = 0, 128 do static_aad_buf[i] = 0 end
                if #hist < 128 then ffi.copy(static_aad_buf, hist) end
                aad_text = u8:decode(hist)  -- UTF-8 -> CP1251 for sending
                lua_thread.create(function() saveSettings() end)
            end
            imgui.SameLine()
            if imgui.Button(u8"X") then
                table.remove(aad_history, idx)
                lua_thread.create(function() saveSettings() end)
                imgui.PopID()
                break
            end
            imgui.SameLine()
            imgui.TextUnformatted(hist)  -- already UTF-8
            imgui.PopID()
        end
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
        imgui.TextUnformatted(u8"������� �����.")
        imgui.PopStyleColor()
    end
    imgui.EndChild()

    imgui.Columns(1)
    imgui.Spacing()
end,
onToggle = function(state) end
},
{
id = "mm_editor",
name = u8" MM Editor (���)",
description = u8"�������� ��� ����������� ����������� (���). ������������� �������� ���������� ��� �������������� ���������� � ������ ������ ��� (����� ������� ��� �����/��������, �� ��������� ��� �����������).",
enabled = false,
drawSettings = function()
imgui.TextUnformatted(u8"��� ����������:")
imgui.SameLine()
imgui.PushItemWidth(60)
if imgui.InputText("##mm_tag", mm_tag, ffi.sizeof(mm_tag)) then lua_thread.create(function() saveSettings() end) end
imgui.PopItemWidth()
imgui.SameLine()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"��������: LV, LS, SF, TV")
imgui.PopStyleColor()
imgui.Spacing()
if imgui.Checkbox(u8"����-�������������� ��� �������� ���������", mm_auto_format) then lua_thread.create(function() saveSettings() end) end
if imgui.Checkbox(u8"����-�������� ���������� (Auto-Edit)", mm_auto_send) then lua_thread.create(function() saveSettings() end) end

if mm_auto_send[0] then
imgui.PushItemWidth(150)
if imgui.SliderInt(u8"�������� �������� (��)", mm_send_delay, 500, 8000) then lua_thread.create(function() saveSettings() end) end
imgui.PopItemWidth()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.8, 0, 1))
imgui.TextUnformatted(u8" ��������: ����������� �������� �� 2000 �� ��� ������������ �� �������!")
imgui.PopStyleColor()
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextUnformatted(u8"���� ����������:")
imgui.InputText(u8"������� ��������", test_input, 129)

if imgui.Button(u8"��������� ������") then
local raw_text = u8:decode(ffi.string(test_input))  -- UTF-8 -> CP1251
local fmt_ok, fmt_result = pcall(formatAdText, raw_text)
if fmt_ok then test_output = u8:encode(fmt_result) else test_output = u8"Error: " .. tostring(fmt_result) end
end

if test_output ~= "" then
imgui.TextUnformatted(u8"���������:")
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.8, 1))
imgui.PushTextWrapPos(0)
imgui.TextUnformatted(sanitizeUtf8(#test_output > 500 and safeUtf8Truncate(test_output, 500) or test_output))
imgui.PopTextWrapPos()
imgui.PopStyleColor()
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.TextUnformatted(u8"������� ������ ���������� (����):")
imgui.BeginChild("rules_list", imgui.ImVec2(0, 110), true)
local max_display = 25
local shown = 0
for idx, rule in ipairs(mm_rules) do
if shown >= max_display then break end
shown = shown + 1
local _rule_text = u8:encode(rule.abbreviation) .. " -> " .. u8:encode(rule.replacement)
            if #_rule_text > 80 then _rule_text = safeUtf8Truncate(_rule_text, 80) end
            imgui.TextUnformatted(sanitizeUtf8(_rule_text))
imgui.SameLine(350)
if imgui.Button("X##" .. idx) then
table.remove(mm_rules, idx)
lua_thread.create(function() saveRules() end)
end
imgui.Separator()
end
if #mm_rules > max_display then
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.8, 0, 1))
imgui.TextUnformatted(u8" : " .. #mm_rules .. ".  " .. max_display .. ".")
imgui.PopStyleColor()
end
imgui.EndChild()

static_new_abbr = static_new_abbr or imgui.new.char[65]("")
static_new_repl = static_new_repl or imgui.new.char[257]("")
imgui.InputText(u8"����������", static_new_abbr, 65)
imgui.InputText(u8"������ ��...", static_new_repl, 257)
if imgui.Button(u8"�������� �������") then
local abbr = u8:decode(ffi.string(static_new_abbr)):lower()  -- UTF-8 -> CP1251
local repl = u8:decode(ffi.string(static_new_repl))  -- UTF-8 -> CP1251
if abbr ~= "" and repl ~= "" then
table.insert(mm_rules, {abbreviation = abbr, replacement = repl})
lua_thread.create(function() saveRules() end)
static_new_abbr[0] = 0
static_new_repl[0] = 0
end
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 0.8, 1, 1))
imgui.TextUnformatted(u8"�������� (����������� �� ����� ������ � AutoEdit):")
imgui.PopStyleColor()
if #edit_corrections == 0 then
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"���� ��� �����������. ��������� ����� ����� ��������� � ���� AutoEdit - ����� �������� ����������� �������� �������.")
imgui.PopStyleColor()
else
imgui.BeginChild("corrections_list", imgui.ImVec2(0, 90), true)
for idx, corr in ipairs(edit_corrections) do
imgui.PushIDStr("corr_" .. idx)
local _corr_text = u8:encode(corr.abbr) .. " -> " .. u8:encode(corr.repl)
            if #_corr_text > 80 then _corr_text = safeUtf8Truncate(_corr_text, 80) end
            imgui.TextUnformatted(sanitizeUtf8(_corr_text))
imgui.SameLine(320)
if imgui.SmallButton(u8"������������") then
safeStrCopy(static_new_abbr, u8:encode(corr.abbr, encoding.default), ffi.sizeof(static_new_abbr))
safeStrCopy(static_new_repl, u8:encode(corr.repl, encoding.default), ffi.sizeof(static_new_repl))
end
imgui.SameLine()
if imgui.SmallButton(u8"X") then
table.remove(edit_corrections, idx)
lua_thread.create(function() saveCorrections() end)
imgui.PopID()
break
end
imgui.PopID()
imgui.Separator()
end
imgui.EndChild()
end
end,
onToggle = function(state) end
},
{
id = "auto_rp",
enabled = true,
name = u8" ����-���������",
description = u8"����-��������� �� ������� �������: ������/������� ������ ��� ����� �����, ������ ������� ��� �������� ������/SMS, ���������� /call, /h, /mask, /healme, /drugs. �������� ������������� � �� ����� �������� ������ �������������.",
drawSettings = function()
if imgui.Checkbox(u8"��������� ����������/�������� ������", rp_weapons_enabled) then lua_thread.create(function() saveSettings() end) end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> ���������� Deagle, M4, Shotgun, AK-47, ����")
imgui.PopStyleColor()

if imgui.Checkbox(u8"��������� ������� � ������� ��������", rp_phone_enabled) then lua_thread.create(function() saveSettings() end) end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> ����������� ��� �������� /call � /h")
imgui.PopStyleColor()

if imgui.Checkbox(u8"��������� �������� �����", rp_mask_enabled) then lua_thread.create(function() saveSettings() end) end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> ����������� ��� ������� /mask")
imgui.PopStyleColor()

if imgui.Checkbox(u8"��������� ������������� �������", rp_heal_enabled) then lua_thread.create(function() saveSettings() end) end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> ����������� ��� �������� /healme � /drugs")
imgui.PopStyleColor()
end,
onToggle = function(state) end
},
{
id = "vehicle_visuals",
name = u8" ��������� � ������",
description = u8"������� ��� ��������� � ���������� ������������ ����. �������� ����������� ������, �����-��������, ��������� ����� ������/������� � ����-�������.",
enabled = false,
drawSettings = function()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"����������� � �����:")
imgui.PopStyleColor()
if imgui.Checkbox(u8"�������� �����������", strobe_enabled) then
if strobe_enabled[0] then
strobe_active = true
lua_thread.create(strobeWorker)
else
strobe_active = false
end
end
imgui.SameLine(220)
        imgui.Checkbox(u8"�����-����� (���� ����!)", turbo_cruise_enabled)
        imgui.TextUnformatted(u8"�����: C=���/����  W=+5  S=-5")

imgui.PushItemWidth(150)
if imgui.SliderInt(u8"�������� ������������ (��)", strobe_speed, 50, 600) then lua_thread.create(function() saveSettings() end) end

local strobe_items = u8"��� ������" .. "\0" .. u8"�����������" .. "\0" .. u8"�������� (�� �����)" .. "\0" .. u8"������� ����/�����" .. "\0" .. u8"������� ��� (3�)" .. "\0" .. u8"����� ������� ��� (5�)" .. "\0" .. u8"����������� 1" .. "\0" .. u8"����������� 2 (3+3+���)" .. "\0" .. u8"����������� 3 (�������)" .. "\0" .. u8"SOS (�����)" .. "\0" .. u8"�����" .. "\0" .. u8"������� (�������+�����)" .. "\0" .. u8"������� ��������" .. "\0" .. u8"������� ������� (����)" .. "\0" .. u8"������" .. "\0" .. u8"���������� (2�2)" .. "\0" .. u8"���� (���������)" .. "\0" .. u8"�����������" .. "\0" .. u8"������ (�����������)" .. "\0"

if imgui.ComboStr(u8"����� ������������", strobe_mode, strobe_items) then
lua_thread.create(function() saveSettings() end)
end
imgui.PopItemWidth()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))

imgui.TextUnformatted(u8"��������� (��������):")

imgui.PopStyleColor()

if imgui.Checkbox(u8"������������� ������", weather_locked) then lua_thread.create(function() saveSettings() end) end
if weather_locked[0] then
imgui.PushItemWidth(250)
if imgui.SliderInt(u8"ID ������", weather_id, 0, 45) then lua_thread.create(function() saveSettings() end) end
imgui.PopItemWidth()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"���������� ID: 1-2 (����), 8 (�����), 9 (�����), 19 (�����)")
imgui.PopStyleColor()
end

if imgui.Checkbox(u8"������������� ����� �����", time_locked) then lua_thread.create(function() saveSettings() end) end
if time_locked[0] then
imgui.PushItemWidth(250)
if imgui.SliderInt(u8"����", time_hour, 0, 23) then lua_thread.create(function() saveSettings() end) end
imgui.PopItemWidth()
end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))

imgui.TextUnformatted(u8"����-������� (��������):")

imgui.PopStyleColor()
imgui.PushItemWidth(150)
imgui.InputInt(u8"ID ����� (0-311)", skin_changer_id)
imgui.PopItemWidth()

if imgui.Button(u8"��������� ����") then
applyLocalSkin(skin_changer_id[0])
end
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> �� ����� ������ ������ ������� � ���: /fskin [ID]")
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
name = u8" ������� �������",
description = u8"�������� ������ � ��������. ������� ������� - ���������� �������.\n�� ����������� ��� �������� ���� ��� �������.",
enabled = true,
drawSettings = function()
imgui.TextUnformatted(u8"������� �����:")
imgui.Spacing()
for i, bind in ipairs(keybinds) do
static_bind_en = static_bind_en or imgui.new.bool(false); static_bind_en[0] = bind.enabled; local en = static_bind_en
if imgui.Checkbox("##en" .. i, en) then
bind.enabled = en[0]
lua_thread.create(function() saveSettings() end)
end
imgui.SameLine()
local kname = key_names[bind.key] or ("0x" .. string.format("%02X", bind.key))
imgui.TextUnformatted(u8:encode("[" .. kname .. "] " .. bind.name .. "  (" .. bind.command .. ")"))
imgui.SameLine(350)
if imgui.Button(u8"�������##del" .. i) then
table.remove(keybinds, i)
lua_thread.create(function() saveSettings() end)
break
end
end
imgui.Spacing()
imgui.Separator()
imgui.Spacing()
imgui.TextUnformatted(u8"�������� ����� ����:")
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
if imgui.BeginCombo("##newkey", key_names[new_bind_key[0]] or "�������") then
for _, k in ipairs(key_keys) do
if imgui.Selectable(key_names[k], new_bind_key[0] == k) then
new_bind_key[0] = k
end
end
imgui.EndCombo()
end
imgui.SameLine()
imgui.PushItemWidth(150)
imgui.InputText("##newcmd", new_bind_command, 129)
imgui.SameLine()
imgui.PushItemWidth(150)
imgui.InputText("##newname", new_bind_name, 129)
imgui.SameLine()
if imgui.Button(u8" + �������� ") then
local cmd = u8:decode(ffi.string(new_bind_command))
local nm = u8:decode(ffi.string(new_bind_name))
if cmd ~= "" then
if nm == "" then nm = cmd end
table.insert(keybinds, {key = new_bind_key[0], command = cmd, enabled = true, name = nm})
new_bind_command[0] = 0
new_bind_name[0] = 0
lua_thread.create(function() saveSettings() end)
end
end
imgui.PopItemWidth()
imgui.PopItemWidth()
imgui.PopItemWidth()
imgui.Spacing()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
imgui.TextUnformatted(u8"������ �������: /lock, /e, /me ������ ����� � �.�.")
imgui.PopStyleColor()
end,
},
{
id = "commands_guide",
name = u8" ���������� ������",
description = u8"������ � ������ ������ ������ ������� Advance RP �� ��������. ������ �������� �� ����� ������� � ������, ����� ����������� � � ����� ������.",
enabled = true,
drawSettings = function()
imgui.TextUnformatted(u8"�������� ��������� �������:")
static_selected_cat = static_selected_cat or imgui.new.int(1)

if imgui.BeginCombo(u8"���������", advance_commands[static_selected_cat[0]].category) then
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
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 0.9, 0.7, 1))
imgui.TextUnformatted(cmd.name)
imgui.PopStyleColor()

if imgui.IsItemHovered() then
imgui.BeginTooltip()
imgui.TextUnformatted(u8"������� ����: ����������� � �����")
imgui.EndTooltip()
if imgui.IsMouseDoubleClicked(0) then
setClipboardText(cmd.name)
lua_thread.create(function() sampAddChatMessage(u8:decode("[Helper] ����������� � �����: " .. cmd.name), 0x00FFFF) end)
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
name = u8" ��-������ (���������)",
description = u8"��������� ��-��������� � ���������� �����, ����, ������� � ������������� ����. �������: /mmact [id], /mmnext, /mmstop, /rpeditor, /rptest, /rplogin.",
enabled = true,
drawSettings = function()
if imgui.Button(u8"������� �������� ���������", imgui.ImVec2(220, 30)) then rp_show_edit[0] = true end
imgui.SameLine()
if imgui.Button(u8"��������� ����������", imgui.ImVec2(150, 30)) then lua_thread.create(playerLogin) end
imgui.Spacing()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.8, 0.5, 1))
imgui.TextUnformatted(u8"�����: " .. u8:encode(user.fullName))
imgui.TextUnformatted(u8"���������: " .. u8:encode(user.rangName))
imgui.TextUnformatted(u8"�������������: " .. u8:encode(user.podr))
imgui.TextUnformatted(u8"�������: " .. u8:encode(user.phone))
imgui.PopStyleColor()
imgui.Spacing()
imgui.Separator()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))
imgui.TextUnformatted(u8"�������:")
imgui.PopStyleColor()
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/mmact [id] � ������� ���� � ������� ���������")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/mmnext � ���������� ��������� ����� ����� <0>")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/mmstop � ���������� ���������")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/rpeditor � ������� �������� ���������")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/rptest � ���� ��������� ���������")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/rplogin � ��������� ���������� ������")
end,
onToggle = function(state) end
},
{
id = "smi_tools",
name = u8" ���-�����������",
description = u8"���������, ����, ������ ������, ����� �����������, ���� ��-�����, ����-�����. �������: /anag, /mmefir, /endefir, /find, /tvlf, /uninv, /autoans, /bladd, /bldel, /blcheck, /bllist, /efirstats.",
enabled = false,
drawSettings = function()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"����:")
imgui.PopStyleColor()
if imgui.Button(u8"������ ����", imgui.ImVec2(120, 30)) then lua_thread.create(cmdEfir) end
imgui.SameLine()
if imgui.Button(u8"��������� ����", imgui.ImVec2(120, 30)) then lua_thread.create(cmdEndEfir) end
imgui.SameLine()
if imgui.Button(u8"����������", imgui.ImVec2(100, 30)) then lua_thread.create(cmdEfirStats) end

imgui.Spacing()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))
imgui.TextUnformatted(u8"����-����� �� ������:")
imgui.PopStyleColor()
if imgui.Checkbox(u8"�������� ����-�����", auto_answer_enabled) then end
imgui.PushItemWidth(300)
imgui.InputText(u8"##autoans_text", auto_answer_text, 257)
imgui.PopItemWidth()
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
imgui.TextUnformatted(u8"-> ����� ����� ��������� � /t ��� �������� ������ �� ����� �����")
imgui.PopStyleColor()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))

imgui.TextUnformatted(u8"���������:")

imgui.PopStyleColor()
if imgui.Button(u8"����� (1)", imgui.ImVec2(90, 25)) then lua_thread.create(function() startAnagram(1) end) end
imgui.SameLine()
if imgui.Button(u8"������� (2)", imgui.ImVec2(100, 25)) then lua_thread.create(function() startAnagram(2) end) end
imgui.SameLine()
if imgui.Button(u8"������ (3)", imgui.ImVec2(90, 25)) then lua_thread.create(function() startAnagram(3) end) end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 1, 0.7, 1))

imgui.TextUnformatted(u8"׸���� ������:")

imgui.PopStyleColor()
if imgui.Button(u8"������� ������", imgui.ImVec2(120, 30)) then blacklist_show[0] = true end
imgui.SameLine()
if imgui.Button(u8"����� �����������", imgui.ImVec2(150, 30)) then lua_thread.create(cmdFind) end

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))

imgui.TextUnformatted(u8"�������:")

imgui.PopStyleColor()
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/anag [1-3] � ��������� ��� �����/�� ���")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/mmefir � ������ ���� (����-��)")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/endefir � ��������� ���� (����-��)")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/efirstats � ���������� �����")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/find � ����� �����������")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/tvlf [����] � ���� ��-�����")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/uninv [id] [�������] � ���������� � ��")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/autoans [�����] � ����-����� �� ������")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/bladd [���] [�������] � �������� � ��")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/bldel [���] � ������� �� ��")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/blcheck [���] � ��������� ��� � ��")
imgui.Bullet()
imgui.SameLine()
imgui.TextUnformatted(u8"/bllist � �������� ���� ��")
end,
onToggle = function(state) end
}

}

-- ������� ������� (����� �����)
function main()
while not isSampAvailable() do wait(100) end

-- ��������� ���� � ���������
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

sampAddChatMessage("Helper Core " .. SCRIPT_VERSION .. " ��������. ����: F11", 0x00FF00)
sampAddChatMessage("������: J=���/����, N=����� | �����: C, W/S=�������� | �����: L=/lock, K=/e", 0xFFFFFF)

-- ������������ ������� �������� ����
sampRegisterChatCommand("helper", function()
show_main_window[0] = not show_main_window[0]
end)

sampRegisterChatCommand("aad", function(arg)
    if aad_active then
        aad_active = false
        aad_text = ""
        sampAddChatMessage("[Helper] Auto-Ad ����������.", 0xFF0000)
    else
        if not arg or arg == "" then
            sampAddChatMessage("[Helper] �������������: /aad [����� ����������]", 0xFF0000)
        else
            aad_active = true
            aad_text = arg
            sampAddChatMessage("[Helper] Auto-Ad �������! �����: " .. arg, 0x00FF00)
            sendAdCommand(aad_text)
        end
    end
end)



-- ������������ ������� ����� �����
sampRegisterChatCommand("fskin", function(arg)
local id = tonumber(arg)
if id and id >= 0 and id <= 311 then
skin_changer_id[0] = id
applyLocalSkin(id)
else
sampAddChatMessage("[Helper] �������������: /fskin [0-311]", 0xFF0000)
end
end)

-- ����������� ������ ��� ����-���������
-- RP ��������� ������ ����� sampev.onSendChat (��. ����)

-- ��-������: ��������� ���������
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

-- ���-�������: ����������� ������
loadBlacklist()
sampRegisterChatCommand('anag', function(arg) startAnagram(arg) end)
sampRegisterChatCommand('tvlf', cmdTvlift)
sampRegisterChatCommand('uninv', cmdUninvite)
sampRegisterChatCommand('mmefir', cmdEfir)
sampRegisterChatCommand('endefir', cmdEndEfir)
sampRegisterChatCommand('find', cmdFind)
sampRegisterChatCommand('efirstats', cmdEfirStats)
sampRegisterChatCommand('autoans', cmdAutoAnswer)
sampRegisterChatCommand('bladd', function(arg)
  local nick, reason = arg:match('^(%S+)%s*(.*)')
  if nick then addBlacklistNick(nick, reason) else sampAddChatMessage('[Helper] /bladd [���] [�������]', 0xFFAA00) end
end)
sampRegisterChatCommand('bldel', function(arg)
  if arg and arg ~= '' then removeBlacklistNick(arg) else sampAddChatMessage('[Helper] /bldel [���]', 0xFFAA00) end
end)
sampRegisterChatCommand('blcheck', function(arg)
  if arg and arg ~= '' then
    if checkBlacklistNick(arg) then sampAddChatMessage('[Helper] ' .. arg .. ' � ������ ������!', 0xFF0000)
    else sampAddChatMessage('[Helper] ' .. arg .. ' �� � ������ ������', 0x00FF00) end
  else sampAddChatMessage('[Helper] /blcheck [���]', 0xFFAA00) end
end)
sampRegisterChatCommand('bllist', function()
  local count = 0
  for nick, data in pairs(blacklist_data) do
    count = count + 1
    sampAddChatMessage('  ' .. nick .. ' � ' .. (data.reason or '��� �������') .. ' (' .. (data.added or '?') .. ')', 0xCECECE)
  end
  if count == 0 then sampAddChatMessage('[Helper] ׸���� ������ ����', 0xFFAA00)
  else sampAddChatMessage('[Helper] ����� � ��: ' .. count, 0x00FF00) end
end)

-- ������ �������
lua_thread.create(factionScannerWorker)
lua_thread.create(weaponTrackWorker)
lua_thread.create(cruiseControlWorker)
lua_thread.create(environmentWorker)

-- ������ ���� � ������� ����� (���������)

-- ����-�������� ��-������ ����� 3 ��� ����� ������
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

local sender, phone = text:match("�����������:%s*([A-Za-z0-9_]+).-[��]��%s*:%s*(%d+)")
if not sender or not phone then
sender, phone = text:match("([A-Za-z0-9_]+)%s*%.%s*[��]��%s*:%s*(%d+)")
end
local text_utf8 = u8:encode(text, encoding.default)

if sender and phone then
local ad_text = text_utf8:match("����������:%s*(.-)%s*�����������:") or ""
table.insert(player_db_queue, {sender = sender, phone = phone, ad = ad_text})
sampAddChatMessage(u8:decode("[Helper DB] �������� �������: " .. sender .. " (���: " .. phone .. ")"), 0x00FF90)
end
end
end
end


-- ����� ������������ ���������� ���� (������������ onShowDialog ��� SAMP.Lua)

while true do
wait(0)

-- Initialize online nicks cache once (safe from main loop, not from lua_thread)
if not online_nicks_initialized then
    initOnlineNicksCache()
end

-- Scan chat for contacts (safe from main loop, not from thread)
chatScannerTick()

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
    ae_original_text = u8:encode(q.original, encoding.default)
    ae_formatted_text = u8:encode(q.formatted, encoding.default)
    safeStrCopy(ae_input_buf, u8:encode(q.formatted, encoding.default), ffi.sizeof(ae_input_buf))
    ae_active[0] = true
    ae_focus = true
    ae_ignore_enter = 30  -- ignore stale Enter from /edit chat command (~0.5s)
    ae_enter_was_down = true  -- Enter was just pressed (for /edit), wait for release
    ae_esc_was_down = true  -- Esc may be held from chat, wait for release
end

-- ������� F11
if wasKeyPressed(0x7A) and not sampIsChatInputActive() and not sampIsDialogActive() then
show_main_window[0] = not show_main_window[0]
end

-- ������� J ��� ������������ � ������
if wasKeyPressed(0x4A) and isCharInAnyCar(PLAYER_PED) and not sampIsChatInputActive() and not sampIsDialogActive() then -- J
strobe_enabled[0] = not strobe_enabled[0]
strobe_active = strobe_enabled[0]
if strobe_active then
lua_thread.create(strobeWorker)
end
sampAddChatMessage(u8:decode("[Helper] �����������: " .. (strobe_enabled[0] and "{00FF00}���{FFFFFF} (���� - J)" or "{FF0000}����")), 0xFFFFFF)
end

-- ������� N ��� ����� ������ ������������ (������ ���� �������� � � ������)
if wasKeyPressed(0x4E) and isCharInAnyCar(PLAYER_PED) and strobe_enabled[0] and not sampIsChatInputActive() and not sampIsDialogActive() then -- N
local strobe_mode_names = {
    [1]="��������", [2]="�����������", [3]="������� (���)", [4]="������� �/�",
    [5]="������� 3��", [6]="������� 5��", [7]="������ 1", [8]="������ 2 (3+3+���)",
    [9]="������ 3 (��������)", [10]="SOS (�����)", [11]="��������", [12]="������� (����+�����)",
    [13]="������� �����������", [14]="������� ������� (�����)", [15]="����", [16]="������ (2�2)",
    [17]="���� (����������)", [18]="����������", [19]="������� (�������)",
}
strobe_mode[0] = strobe_mode[0] + 1
if strobe_mode[0] > 19 then strobe_mode[0] = 1 end
saveSettings()
local mname = strobe_mode_names[strobe_mode[0]] or ("#" .. strobe_mode[0])
sampAddChatMessage(u8:decode("[Helper] ���������� �����: {00FF00}" .. mname .. " {FFFFFF}(N - ���������)"), 0xFFFFFF)
end

-- ��������� ������ ������ �� �������
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

-- ����� ��� ������������ �������� ���� (��� SAMP.Lua)
-- ������ ������� (��� ����-���������)
factionScannerWorker = function()
    local last_dialog_id = -1
    local faction_names = {
        [1] = "��� (�������)",
        [2] = "�� (��������/���)",
        [3] = "�� (�����)",
        [4] = "����� (�������������)",
        [5] = "��� (����������)",
        [6] = "����� (�����)",
        [7] = "�����"
    }

    while true do
        wait(500)
        if isSampAvailable() and sampIsDialogActive() then
            local current_dialog_id = sampGetCurrentDialogId()
            if current_dialog_id ~= last_dialog_id then
                last_dialog_id = current_dialog_id
                local title = sampGetDialogCaption() or ""
                local text = sampGetDialogText() or ""
                if title:find("�����������") or title:find("�������") or title:find("�������������") or text:find("�������������:") then
                    local detected_faction = nil
                    if text:find("���") or text:find("�������") or text:find("�����������") or text:find("������") then
                        detected_faction = 1
                    elseif text:find("��������") or text:find("���") or text:find("�����") or text:find("�������") or text:find("����") then
                        detected_faction = 2
                    elseif text:find("�����") or text:find("��") or text:find("�������") then
                        detected_faction = 3
                    elseif text:find("�����") or text:find("�������������") or text:find("���") or text:find("�������") or text:find("��������") then
                        detected_faction = 4
                    elseif text:find("���") or text:find("���������") or text:find("�����") or text:find("�����������") then
                        detected_faction = 5
                    elseif text:find("Grove") or text:find("�����") or text:find("Ballas") or text:find("������") or text:find("Vagos") or text:find("�����") or text:find("Aztec") or text:find("�����") or text:find("Rifa") or text:find("����") then
                        detected_faction = 6
                    elseif text:find("�����") or text:find("������") or text:find("Yakuza") or text:find("La Cosa Nostra") or text:find("LCN") or text:find("�������") or text:find("������") then
                        detected_faction = 7
                    end
                    if detected_faction and selected_faction[0] ~= detected_faction then
                        selected_faction[0] = detected_faction
                        saveSettings()
                        sampAddChatMessage("[Helper] ���������� �������: {00FF00}" .. faction_names[detected_faction] .. "{FFFFFF}. ��������� ���������.", 0xFFFFFF)
                    end
                end
            end
        else
            last_dialog_id = -1
        end
    end
end

-- �������� ������� �� ������
isModuleEnabled = function(id)
    if not modules then return false end
    for _, mod in ipairs(modules) do
        if mod.id == id then
            return mod.enabled
        end
    end
    return false
end

-- �������� ����������
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

-- �������� ������ ��� ����-�� ���������
-- ��������� /me ����� ���������� ���������
function sampev.onSendChat(message)
    if isModuleEnabled("auto_rp") and not call_worker_running then
        local cmd = message:match("^/(%w+)")
        if cmd then
            -- /call <number>
            if (cmd == "call" or cmd == "c") and rp_phone_enabled[0] then
                local arg = message:match("^/call%s+(.+)") or message:match("^/c%s+(.+)")
                if arg and arg ~= "" then
                    lua_thread.create(function()
                        sampSendChat(u8:decode("/me ������ ��������� ������� � ������ ����� " .. arg))
                        wait(100)
                    end)
                end
            -- /h or /hangup
            elseif (cmd == "h" or cmd == "hangup") and rp_phone_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me ������ ������� � ����� ��� � ������"))
                    wait(100)
                end)
            -- /mask
            elseif cmd == "mask" and rp_mask_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me ����� �� ���� ����� � ����� ���� ����"))
                    wait(100)
                end)
            -- /healme
            elseif cmd == "healme" and rp_heal_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me ������ �������, ������ �� � ��������"))
                    wait(100)
                end)
            -- /drugs
            elseif cmd == "drugs" and rp_heal_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me ������ ����� � ������ ����"))
                    wait(100)
                end)
            -- /e (engine)
            elseif cmd == "e" and rp_weapons_enabled[0] then
                lua_thread.create(function()
                    sampSendChat(u8:decode("/me ����� ���������"))
                    wait(100)
                end)
            end
        end
    end
    return true  -- let the message go to server
end

-- ��������� ��������� ������������� ������� � ������
function sampev.onSetPlayerTime(hour, minute)
    if time_locked[0] then
        return false  -- ��������� ������, �� ������ �����
    end
end

function sampev.onSetWeather(weatherId)
    if weather_locked[0] then
        return false  -- ��������� ������, �� ������ ������
    end
end

-- ���������� ��������� ������� (SAMP events)
function sampev.onServerMessage(color, text)
    -- ���� � ������������ CP1251 ������
    local sender, phone = text:match("��������%s+([A-Za-z0-9_]+)%[%d+%]%s+%(���%.%s*(%d+)%)")
    if not sender or not phone then
        sender, phone = text:match("([A-Za-z0-9_]+)%[%d+%]%s+%(���%.%s*(%d+)%)")
    end
    if not sender or not phone then
        sender, phone = text:match("([A-Za-z0-9_]+).-%(���%.%s*(%d+)%)")
    end
    local text_utf8 = u8:encode(text, encoding.default)

    if sender and phone then
        local sender_cp = sender
        local phone_cp = phone
        lua_thread.create(function()
            local result, my_id = sampGetPlayerIdByCharHandle(PLAYER_PED)
            local my_name = result and sampGetPlayerNickname(my_id) or ""

            if sender_cp == my_name then
                if aad_active and aad_text ~= "" then
                    sampAddChatMessage("[Helper] ���������� ������������. ��������� ������ ����� " .. (aad_delay[0]/1000) .. " ���...", 0x00FFFF)
                    wait(aad_delay[0])
                    if aad_active and aad_text ~= "" then
                        sendAdCommand(aad_text)
                    end
                end
            elseif isModuleEnabled("autocall_db") then
                -- Queue the change instead of modifying player_db directly
                -- (ImGui render thread might be iterating player_db right now)
                table.insert(player_db_queue, {sender = sender_cp, phone = phone_cp})
                sampAddChatMessage("[Helper DB] ����� �������: " .. sender_cp .. " (���: " .. phone_cp .. ")", 0x00FF90)
            end
        end)
    end
    -- ����-��������� �� ������� ������� (������ auto_rp)
    -- ��������� �� ����� ������� ����� �� ������� ������ � sampSendChat
    if isModuleEnabled("auto_rp") and not call_worker_running then
        local lower = text:lower()
        -- �������� ������: ������ ����� "��� ������" ��� "�������� �����"
        if rp_phone_enabled[0] and (lower:find("��� ������") or lower:find("�������� �����") or lower:find("�������� ������")) then
            lua_thread.create(function()
                wait(200)
                sampSendChat(u8:decode("/me ������ ��������� ������� �� �������"))
                wait(600)
                sampSendChat(u8:decode("/me ��������� �� ����� ��������, ������ �������� �����"))
                wait(400)
                sampSendChat(u8:decode("/do ������� � ����, ����� ��������� �������� �������"))
            end)
        end
        -- ������ �������� / �������
        if rp_phone_enabled[0] and (lower:find("������ ��������") or lower:find("������ ��������") or lower:find("�� ��������") or lower:find("�������� �������") or lower:find("���������� �������")) then
            lua_thread.create(function()
                wait(200)
                sampSendChat(u8:decode("/me ����� ������ ������ �� ��������"))
                wait(500)
                sampSendChat(u8:decode("/me ����� ��������� ������� � ������"))
            end)
        end
        -- SMS ������
        if rp_phone_enabled[0] and (lower:find("sms:") or lower:find("���:") or lower:find("��� ������ ���������") or lower:find("����� ���������")) then
            lua_thread.create(function()
                wait(300)
                sampSendChat(u8:decode("/me ������ ��������� ������� �� �������"))
                wait(500)
                sampSendChat(u8:decode("/me �������� ��������� �� ������ ��������"))
                wait(800)
                sampSendChat(u8:decode("/me ����� ��������� ������� � ������"))
            end)
        end
        -- ����� ��� � ������ (����� �������� isCharInAnyCar � �������� � ������, �� �����)
        -- ����� ��������� / ������� � ���
        if rp_heal_enabled[0] and (lower:find("�� ����������") or lower:find("������� � ���") or lower:find("��������� � ������")) then
            lua_thread.create(function()
                wait(500)
                sampSendChat(u8:decode("/me ������� ������, �������� ��� ���������"))
                wait(600)
                sampSendChat(u8:decode("/do ��������� ���� � �����������"))
            end)
        end
        -- ����� �������
        if rp_heal_enabled[0] and (lower:find("�� ��������") or lower:find("�������� �������������") or lower:find("�������� �������������")) then
            lua_thread.create(function()
                wait(300)
                sampSendChat(u8:decode("/me ���������� ��������, ������������ ����������"))
                wait(400)
                sampSendChat(u8:decode("/do ������������ ����������"))
            end)
        end
    end

    -- ����-����������: ������� SMS, �������, ����� �����
    if efir_active then
        if text:find("SMS") or text:find("���") or text:find("���") then
            efir_stats.sms = efir_stats.sms + 1
        end
        if text:find("����") or text:find("����") or text:find("�����") or text:find("�����") then
            efir_stats.calls = efir_stats.calls + 1
            -- ����-����� �� ������
            if auto_answer_enabled[0] then
                local answer = u8:decode(ffi.string(auto_answer_text))
                if answer ~= "" then
                    lua_thread.create(function()
                        wait(500)
                        sampSendChat("/t " .. answer)
                    end)
                end
            end
        end
        -- ������� ����� ����� (��������� � /t ��� /u)
        efir_stats.lines = efir_stats.lines + 1
    end
end


-- Event handlers for maintaining online nicks cache
function sampev.onPlayerJoin(playerId, name)
    if name and name ~= "" then
        online_nicks_cache[name] = true
    end
end

function sampev.onPlayerQuit(playerId, reason)
    -- We don't have the name here, so we need to rebuild cache
    -- Actually, SAMP gives us the name in the event. Let me check...
    -- In MoonLoader, onPlayerQuit gives (playerId, reason). We need to find the name.
    -- Since we can't call sampGetPlayerNickname after disconnect, mark for re-init
    online_nicks_initialized = false
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
-- �������� ���������� ��� playerLogin (��-������)
    if rp_reading_stats then
        -- ������ ���������� � ������ � ���������
        if title:find("����������") or title:find("����������") then
            rp_stats_text = text
            rp_stats_step = "done"
            sampSendDialogResponse(dialogId, 1, -1, -1)
            return false
        end
        -- ������� ���� � �������� ������ "����������" (������ listitem 0 ��� 1)
        if title:find("����") or title:find("����") or title:find("�������") then
            rp_stats_step = "menu"
            -- ���� ����� "����������" � ������ �������
            local stats_item = -1
            local idx = 0
            for line in string.gmatch(text, "[^\n]+") do
                if line:find("����������") or line:find("����������") or line:find("����") then
                    stats_item = idx
                    break
                end
                idx = idx + 1
            end
            if stats_item >= 0 then
                sampSendDialogResponse(dialogId, 1, stats_item, -1)
            else
                -- ���� �� ����� � �������� ����� 0 (������ ���������� ������)
                sampSendDialogResponse(dialogId, 1, 0, -1)
            end
            rp_stats_step = "stats"
            return false
        end
        -- ������ �������� � ��������� ������ (�� ��������� �������� ���������� ����� ��������)
        if title:find("��������") or title:find("��������") or title:find("���������") then
            sampSendDialogResponse(dialogId, 1, 0, -1)
            rp_stats_step = "stats"
            return false
        end
    end
    -- �������� /find: ����� �����������
    if title:find("�����") or title:find("�����") or title:find("����������") then
        find_list = {}
        local i = 0
        for line in string.gmatch(text, "[^\n]+") do
            local nick, id, rang, podr, phone = line:match("(%d+)%..-(.-)%[(%d+)%].-(%d+)%s*����%s*(.-)%s+(%d+)")
            if nick then
                i = i + 1
                find_list[i] = {
                    nick = nick:gsub("^%s+",""):gsub("%s+$",""),
                    id = tonumber(id),
                    rang = tonumber(rang),
                    podr = podr or "",
                    phone = phone or ""
                }
            end
        end
        find_selected = 0
        find_show[0] = true
        sampAddChatMessage("[Helper] ������� �����������: " .. #find_list, 0x00FF00)
        return false
    end

    if not isModuleEnabled("mm_editor") or not mm_auto_format[0] then
        return
    end
    -- text is CP1251 from SAMP, patterns are CP1251 in this file
    if title:find("��������") or title:find("��������") or text:find("�����:") then
        local original = text:match("�����:(.-)�������") or text:match("�����:%s*(.+)") or ""
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

function applyLocalSkin(skinId)
lua_thread.create(function()
if skinId >= 0 and skinId <= 311 and skinId ~= 74 then
requestModel(skinId)
loadAllModelsNow()
if isModelAvailable(skinId) then
local charPtr = getCharPointer(PLAYER_PED)
if charPtr and charPtr >= 1 then
-- CPed::SetModel - ������� �� ������ 0x5E4880
-- void __thiscall SetModel(int thisPtr, int modelId)
ffi.cast("void (__thiscall *)(int, int)", 0x5E4880)(charPtr, skinId)
clearCharTasks(PLAYER_PED)
markModelAsNoLongerNeeded(skinId)
sampAddChatMessage("[Helper] ���� ������� ������� �� ID: " .. skinId, 0x00FF00)
else
sampAddChatMessage("[Helper] �� ������� �������� ��������� �� ���������.", 0xFF0000)
end
else
sampAddChatMessage("[Helper] ������ �������� ������ �����.", 0xFF0000)
end
else
sampAddChatMessage("[Helper] ������������ ID ����� (��������� 0-311, ����� 74).", 0xFF0000)
end
end)
end

-- ������ � ������� � ��������
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

-- ������ ������������
-- ������������������ ������� ��� ��� �����������
-- ������ ���: {left_light_state, right_light_state}
-- 0 = ���������, 2 = �������� (�������� ��� setCarLightDamageStatus)
-- ������������������ ������� ��� ��� �����������
-- ������ ���: {left_light, right_light}
-- 0 = ���� ��� (�����, ������), 1 = ���� ���� (����������, �� ������)
-- ������� ��� GTA SA: 0=�����-����, 1=�����-�����, 2=���-����, 3=���-�����
-- ������������������ ������� ��� ��� �����������
-- ������ ���: {left_light, right_light}
-- 0 = ���� ��� (�����, ������), 1 = ���� ���� (����������, �� ������)
-- 0 = ���� ��� (�����, ������), 1 = ���� ���� (����������, �� ������)
-- {left, right} - ��������� ����� � ������ �������� ����
local strobe_sequences = {
    -- ������� ������
    [0] = {{0, 0}, {1, 1}, {0, 0}, {1, 1}},                                      -- ��� ������
    [1] = {{0, 1}, {1, 0}, {0, 1}, {1, 0}},                                      -- ����������� (����-�����)
    [2] = {{0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 1}, {1, 0}},      -- �������� (������ �� �����)

    -- ������������ �������
    [3] = {{0, 1}, {0, 1}, {1, 0}, {1, 0}},                                      -- ������� ����, ������� �����
    [4] = {{0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}},                      -- ������� ��� (�������)
    [5] = {{0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}}, -- ����� ������� ���

    -- ����������� �����
    [6] = {{0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 0}, {1, 1}, {0, 0}, {1, 1}},      -- ����������� (����������� + ���)
    [7] = {{0, 1}, {0, 1}, {0, 1}, {1, 0}, {1, 0}, {1, 0}, {0, 0}, {1, 1}},      -- ����������� 2 (3� ����, 3� �����, ���)
    [8] = {{0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 1}, {1, 0}, {0, 0}, {0, 0}, {1, 1}, {1, 1}}, -- ����������� 3 (������ ����������� + ������� ���)

    -- SOS (������ �����: ... --- ...)
    -- ... = 3 ��������, --- = 3 �������, ... = 3 ��������
    -- �������� = 1 ��� ���, 1 ��� ����
    -- ������� = 3 ���� ���, 1 ��� ����
    -- ����� ����� ������� = 3 ���� ����
    [9] = {
        {0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1},  -- S: . . .
        {1, 1}, {1, 1}, {1, 1},                            -- �����
        {0, 0}, {0, 0}, {0, 0}, {1, 1},                    -- O: - (�������)
        {0, 0}, {0, 0}, {0, 0}, {1, 1},                    -- O: -
        {0, 0}, {0, 0}, {0, 0}, {1, 1},                    -- O: -
        {1, 1}, {1, 1}, {1, 1},                            -- �����
        {0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1},  -- S: . . .
        {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1},            -- ������� �����
    },

    -- ����� (������� ����������� ���� -> ��� -> ����� -> ��� -> ...)
    [10] = {{0, 1}, {0, 0}, {1, 0}, {0, 0}, {0, 1}, {0, 0}, {1, 0}, {0, 0}},

    -- ������� (�������� ����� ������� � �������� �������)
    [11] = {{0, 0}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}},  -- ���� ������� + ������� �����

    -- ������� �������� (�� �����, �� � ������ ����� ������)
    [12] = {{0, 1}, {1, 0}, {1, 1}, {0, 1}, {1, 0}, {1, 1}},

    -- ������� ������� (��� � ��������������)
    [13] = {{0, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 0}, {1, 1}, {1, 1}, {1, 1}, {1, 1}},

    -- ������ (����-���-�����-���-����-���-�����-��� ������)
    [14] = {{0, 1}, {0, 0}, {1, 0}, {0, 0}, {0, 1}, {0, 0}, {1, 0}, {0, 0}, {0, 1}, {0, 0}, {1, 0}, {0, 0}},

    -- ���������� (������� ������� ������� �� ��������)
    [15] = {{0, 1}, {0, 1}, {1, 1}, {1, 0}, {1, 0}, {1, 1}},

    -- ���� (��������� ��������� ������� ������)
    [16] = {{0, 0}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}, {1, 1}},

    -- ����������� (����-�����-���-�����, ������)
    [17] = {{0, 1}, {1, 0}, {0, 0}, {1, 1}, {0, 1}, {1, 0}, {0, 0}, {1, 1}},

    -- ������ (����������� �������)
    [18] = {{0, 0}, {1, 1}, {1, 1}, {1, 1},
            {0, 0}, {1, 1}, {1, 1},
            {0, 0}, {1, 1},
            {0, 0}, {1, 1},
            {0, 0}, {1, 1}, {1, 1},
            {0, 0}, {1, 1}, {1, 1}, {1, 1}},
}

-- ��������� memory � bit ��� ������� ������� � CDamageManager
local has_memory, memory = pcall(require, 'memory')
local has_bit, bit = pcall(require, 'bit')

-- ���������� ��������� ��� ����� ������ ������ � ������
-- CAutomobile + 0x5A0 = m_damageManager (CDamageManager)
-- CDamageManager + 0x10 = m_nLightsStatus (uint32, 2 ���� �� ����)
-- LIGHT_FRONT_LEFT  = bits 0-1 (0 = OK/������, 2 = damaged/�� ������)
-- LIGHT_FRONT_RIGHT = bits 2-3 (0 = OK/������, 2 = damaged/�� ������)
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
    -- ����� m_nLightsStatus: carPtr + 0x5A0 + 0x10 = carPtr + 0x5B0
    local lightAddr = carPtr + 0x5B0
    -- ������ ������� ��������� (4 �����, true = virtual protect)
    local lightVal = memory.read(lightAddr, 4, true) or 0
    -- ���������� ���� �������� ��� (bits 0-3)
    lightVal = bit.band(lightVal, 0xFFFFFFF0)
    -- �������������: 2 = DAMSTATE_DAMAGED (�� ������)
    if not leftOn then lightVal = bit.bor(lightVal, 0x02) end   -- bits 0-1 = 2 (front-left damaged)
    if not rightOn then lightVal = bit.bor(lightVal, 0x08) end  -- bits 2-3 = 2 (front-right damaged)
    -- ����� ������� (4 �����, true = virtual protect)
    if memory then memory.write(lightAddr, lightVal, 4, true) end
end

-- ������������ ��� ���� (��� ����� = 0)
local function restoreAllLights(car)
    if has_memory and has_bit then
        local carPtr = getCarPointer(car)
        if carPtr and carPtr ~= 0 then
            local lightAddr = carPtr + 0x5B0
            local lightVal = memory.read(lightAddr, 4, false) or 0
            -- ���������� ��� 8 ��� (4 ���� * 2 ����)
            lightVal = bit.band(lightVal, 0xFFFFFF00)
            if memory then memory.write(lightAddr, lightVal, 4, false) end
            return
        end
    end
    -- Fallback
    if type(setCarLightDamageStatus) == "function" then
        if type(setCarLightDamageStatus) == 'function' then setCarLightDamageStatus(car, 0, 0) end
        if type(setCarLightDamageStatus) == 'function' then setCarLightDamageStatus(car, 1, 0) end
        if type(setCarLightDamageStatus) == 'function' then setCarLightDamageStatus(car, 2, 0) end
        if type(setCarLightDamageStatus) == 'function' then setCarLightDamageStatus(car, 3, 0) end
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
                -- �������� ������� ���� ��� ����� � ������ (���� ���)
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

    -- ��������������� ���� ��� ������
    if last_car and doesVehicleExist(last_car) then
        restoreAllLights(last_car)
    end
end


function getActiveVehicleSpeed(car)
    -- getCarVelocity �� ���������� � MoonLoader, ���������� getCarSpeed
    local spd = getCarSpeed(car)
    local angle = getCarHeading(car)
    local rad = math.rad(angle)
    local x = -math.sin(rad) * (spd or 0)
    local y = math.cos(rad) * (spd or 0)
    return x, y, 0
end

-- �������� �� �������
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
[4] = "���"
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
sampSendChat(u8:decode("/me �������� �������� \"" .. weapon_name .. "\" �� �������������� � ����� � ������"))
elseif current_weapon == 4 then
sampSendChat(u8:decode("/me ����� \"" .. weapon_name .. "\" � ����� �� �����"))
else
sampSendChat(u8:decode("/me ������� ������� \"" .. weapon_name .. "\" �� �����"))
end
wait(500)
end

if new_weapon ~= 0 and weapon_names[new_weapon] then
local weapon_name = weapon_names[new_weapon]
if new_weapon == 24 then
sampSendChat(u8:decode("/me ������ ��������� �������� �������� \"" .. weapon_name .. "\" �� ������"))
elseif new_weapon == 4 then
sampSendChat(u8:decode("/me ����� \"" .. weapon_name .. "\" �� ����� �� �����"))
else
sampSendChat(u8:decode("/me ���� ������� \"" .. weapon_name .. "\" � ����� � ���� � ��������������"))
end
end
current_weapon = new_weapon
end
end
end
end
end

-- ����������� ������ ������ �������
function onlineCallWorker(online_list)
local called_count = 0
local limit = max_calls_session[0]

if not isSampAvailable() then
call_active = false
call_worker_running = false
return
end

-- ������: ���� � ������� ������ (��� �����) ������� ������������� ������,
-- ���������� ��� ����� �������, ����� �� ���� ��������� ���������
sampSendChat("/h")
wait(300)

for i = #online_list, 2, -1 do
local j = math.random(i)
online_list[i], online_list[j] = online_list[j], online_list[i]
end

for _, target in ipairs(online_list) do
if not call_active or called_count >= limit or not isSampAvailable() then break end

local last_time = last_called[target.nick] or 0
local can_call = false
if call_no_repeat[0] then
    -- Skip anyone already in call history
    can_call = (last_time == 0)
else
    -- Use cooldown timer (0 hours = call everyone)
    can_call = (os.time() - last_time > call_cooldown_hours[0] * 3600)
end
if can_call then
call_current_nick = target.nick
call_current_phone = target.phone

sampAddChatMessage(u8:decode("[Helper] ������: ������ " .. target.nick .. " (���: " .. target.phone .. ") [" .. (called_count+1) .. "/" .. limit .. "]"), 0xFFFF00)
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

-- ������ ������ � ����� ������: � ���� ����� ����� ����, � ���� ������
-- ���������� ������� ������� "����" ������� ������ (������ � ���� ������
-- /h �� �����������, � ������ ��������� ������ �� �������)
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
saveSettings()
sampAddChatMessage(u8:decode("[Helper] ������ ������� ���������. ��������� �������: " .. called_count), 0x00FF00)
end

-- ==========================================
-- ��������� ���������� (MIMGUI)
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
imgui.Begin(WINDOW_TITLE, show_main_window, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

-- ������� ������: ������������� ��������
imgui.TextUnformatted(u8"����� �������� �������:")
imgui.SameLine()
imgui.PushItemWidth(150)
if imgui.BeginCombo("##ServerSelector", server_names[current_server_idx[0] + 1]) then
for idx, srv_name in ipairs(server_names) do
local is_selected = (current_server_idx[0] == idx - 1)
if imgui.Selectable(srv_name, is_selected) then
current_server_idx[0] = idx - 1
lua_thread.create(function() saveSettings() sampAddChatMessage(u8:decode("[Helper] ������ ������� ��: " .. server_names[current_server_idx[0] + 1]), 0x00FF90) end)
end
end
imgui.EndCombo()
end
imgui.PopItemWidth()

imgui.Spacing()
imgui.Separator()
imgui.Spacing()

-- ����� �������: ������������� ������
imgui.BeginChild("navigation_panel", imgui.ImVec2(220, 0), true)
imgui.TextUnformatted(u8" ��������� ������")
imgui.Separator()
imgui.Spacing()

for i, mod in ipairs(modules) do
local is_selected = (active_module_idx == i)
if imgui.Selectable(mod.name, is_selected, 0, imgui.ImVec2(0, 32)) then
active_module_idx = i
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

-- ������ �������: ��������� ������
imgui.BeginChild("content_panel", imgui.ImVec2(0, 0), true)
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
if imgui.Checkbox(u8"������������ ������", static_module_enabled) then
active_module.enabled = static_module_enabled[0]
lua_thread.create(function() saveSettings() end)
if active_module.onToggle then
active_module.onToggle(static_module_enabled[0])
end
end
imgui.Spacing()
imgui.Separator()
imgui.Spacing()
end

if active_module.drawSettings then
local ok, err = pcall(active_module.drawSettings)
if not ok then
imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1,0,0,1))
imgui.TextUnformatted("drawSettings ERROR: " .. tostring(err))
imgui.PopStyleColor()
end
end
else
imgui.TextUnformatted(u8"�������� ������ �����.")
end
imgui.EndChild()
imgui.End()
end
)


-- ��-������: ���� ������ ��������� (��� /mmact)
imgui.OnFrame(
    function() return rp_show_window[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(500, 400), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"��-��������� (����: " .. u8:encode(userTarget.name) .. ")", rp_show_window, imgui.WindowFlags.NoCollapse)

        local chapters = {u8"�����", u8"��� ���������", u8"��� ����"}
        imgui.TextUnformatted(u8"�����:")
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
                local name = (rp.name and rp.name ~= "") and u8:encode(rp.name) or u8"(��� ��������)"
                if imgui.Selectable(name, rp_settings.selected == i) then
                    rp_settings.selected = i
                end
            end
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
            imgui.TextUnformatted(u8"��� ���������. �������� /rpeditor ��� ��������.")
            imgui.PopStyleColor()
        end
        imgui.EndChild()

        if #list > 0 and rp_settings.selected <= #list then
            if imgui.Button(u8"���������", imgui.ImVec2(120, 30)) then
                playRp(list[rp_settings.selected].text, false)
                rp_show_window[0] = false
            end
            imgui.SameLine()
            if imgui.Button(u8"����", imgui.ImVec2(80, 30)) then
                playRp(list[rp_settings.selected].text, true)
            end
            imgui.SameLine()
        end
        if imgui.Button(u8"�������", imgui.ImVec2(80, 30)) then
            rp_show_window[0] = false
        end
        imgui.End()
    end
)

-- ��-������: ���� ��������� ��������� (/rpeditor)
imgui.OnFrame(
    function() return rp_show_edit[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(700, 550), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"��-�������� ���������", rp_show_edit, imgui.WindowFlags.NoCollapse)

        local chapters = {u8"�����", u8"��� ���������", u8"��� ����"}
        imgui.TextUnformatted(u8"�����:")
        imgui.SameLine()
        imgui.PushItemWidth(200)
        if imgui.ComboStr("##rp_edit_chapter", rp_settings.setList, table.concat(chapters, "\0") .. "\0") then
            rp_edit_index = 0
            rp_settings.selected = 1
        end
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(u8"+ ��������") then
            local chapter = rp_settings.setList[0] + 1
            if not rp_settings.set[chapter] then rp_settings.set[chapter] = {} end
            table.insert(rp_settings.set[chapter], {name = "", text = ""})
            rp_edit_index = #rp_settings.set[chapter]
            imgui.StrCopy(rp_settings.temp.name, "")
            imgui.StrCopy(rp_settings.temp.text, "")
            lua_thread.create(function() saveRpSettings() end)
        end

        imgui.Separator()

        local chapter = rp_settings.setList[0] + 1
        local list = rp_settings.set[chapter] or {}

        imgui.BeginChild("##rp_edit_list", imgui.ImVec2(200, 350), true)
        for i, rp in ipairs(list) do
            local name = (rp.name and rp.name ~= "") and u8:encode(rp.name) or u8"(��� �������� #" .. i .. ")"
            if imgui.Selectable(name, rp_edit_index == i) then
                rp_edit_index = i
                safeStrCopy(rp_settings.temp.name, u8:encode(rp.name or ""), ffi.sizeof(rp_settings.temp.name))
                safeStrCopy(rp_settings.temp.text, u8:encode(rp.text or ""), ffi.sizeof(rp_settings.temp.text))
            end
        end
        imgui.EndChild()

        imgui.SameLine()
        imgui.BeginChild("##rp_edit_form", imgui.ImVec2(0, 350), true)
        if rp_edit_index > 0 and list[rp_edit_index] then
            imgui.TextUnformatted(u8"��������:")
            imgui.PushItemWidth(-1)
            imgui.InputText("##rp_name", rp_settings.temp.name, 64)
            imgui.PopItemWidth()

            imgui.TextUnformatted(u8"����� ���������:")
            imgui.PushItemWidth(-1)
            imgui.InputTextMultiline("##rp_text", rp_settings.temp.text, 16384, imgui.ImVec2(0, 200))
            imgui.PopItemWidth()

            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.8, 0.5, 1))

            imgui.TextUnformatted(u8"����: <myFio> <myName> <myRang> <myPodr> <myId> <myPhone> <time> <date>")

            imgui.PopStyleColor()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.8, 0.5, 1))
            imgui.TextUnformatted(u8"����: <tFio> <tName> <tNick> <tId>")
            imgui.PopStyleColor()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))
            imgui.TextUnformatted(u8"�����: <1000> (��) ��� <0> (�� /mmnext)")
            imgui.PopStyleColor()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))
            imgui.TextUnformatted(u8"������: r:{�������1}{�������2}:r")
            imgui.PopStyleColor()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.7, 0.3, 1))
            imgui.TextUnformatted(u8"����: #input: | �����: #list: {a}{b} | �����������: {w}")
            imgui.PopStyleColor()

            if imgui.Button(u8"���������", imgui.ImVec2(100, 30)) then
                list[rp_edit_index].name = u8:decode(ffi.string(rp_settings.temp.name))
                list[rp_edit_index].text = u8:decode(ffi.string(rp_settings.temp.text))
                lua_thread.create(function() saveRpSettings() sampAddChatMessage("[Helper] ��������� ���������", 0x00FF00) end)
            end
            imgui.SameLine()
            if imgui.Button(u8"�������", imgui.ImVec2(100, 30)) then
                table.remove(list, rp_edit_index)
                rp_edit_index = 0
                imgui.StrCopy(rp_settings.temp.name, "")
                imgui.StrCopy(rp_settings.temp.text, "")
                lua_thread.create(function() saveRpSettings() end)
            end
            imgui.SameLine()
            if imgui.Button(u8"����", imgui.ImVec2(80, 30)) then
                local testText = u8:decode(ffi.string(rp_settings.temp.text))
                playRp(testText, true)
            end
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
            imgui.TextUnformatted(u8"�������� ��������� ����� ��� ������� '+ ��������'")
            imgui.PopStyleColor()
        end
        imgui.EndChild()

        imgui.Separator()
        if imgui.Button(u8"�������", imgui.ImVec2(100, 30)) then
            rp_show_edit[0] = false
        end
        imgui.End()
    end
)

-- ��-������: ���� �����/������ (��� #input: � #list:)
imgui.OnFrame(
    function() return rp_settings.window.is == 1 end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(400, 150), imgui.Cond.Always)
        imgui.Begin(u8"��-����", nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

        if rp_settings.window.type == 1 then
            imgui.TextUnformatted(u8"������� �����:")
            imgui.PushItemWidth(-1)
            if imgui.InputText("##rp_input_w", rp_settings.window.buf, 256, imgui.InputTextFlags.EnterReturnsTrue) then
                rp_settings.window.is = 2
            end
            imgui.PopItemWidth()
            imgui.SameLine()
            if imgui.Button(u8"OK", imgui.ImVec2(80, 30)) then
                rp_settings.window.is = 2
            end
        elseif rp_settings.window.type == 2 then
            imgui.TextUnformatted(u8"�������� �������:")
            for i, item in ipairs(rp_settings.window.list) do
                if imgui.Button(u8:encode(item), imgui.ImVec2(-1, 0)) then
                    rp_settings.window.select = i
                    rp_settings.window.is = 2
                end
            end
        end
        imgui.End()
    end
)


-- ���: ���� /find (������ ��������� �����������)
imgui.OnFrame(
    function() return find_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(600, 400), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"����� ����������� (/find)", find_show, imgui.WindowFlags.NoCollapse)

        if #find_list > 0 then
            imgui.Columns(5, nil, false)
            imgui.SetColumnWidth(0, 30)
            imgui.CenterColumnText(u8"�")
            imgui.NextColumn()
            imgui.CenterColumnText(u8"���")
            imgui.NextColumn()
            imgui.SetColumnWidth(0, 50)
            imgui.CenterColumnText(u8"ID")
            imgui.NextColumn()
            imgui.SetColumnWidth(0, 50)
            imgui.CenterColumnText(u8"����")
            imgui.NextColumn()
            imgui.CenterColumnText(u8"�������������")
            imgui.NextColumn()
            imgui.Separator()

            for i, p in ipairs(find_list) do
                if imgui.Selectable(tostring(i), find_selected == i, imgui.SelectableFlags.SpanAllColumns) then
                    find_selected = i
                end
                imgui.NextColumn()
                imgui.TextUnformatted(u8:encode(p.nick))
                imgui.NextColumn()
                imgui.TextUnformatted(tostring(p.id))
                imgui.NextColumn()
                imgui.TextUnformatted(tostring(p.rang))
                imgui.NextColumn()
                imgui.TextUnformatted(u8:encode(p.podr))
                imgui.NextColumn()
            end
            imgui.Columns(1)
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
            imgui.TextUnformatted(u8"������ ����. ����������� /find")
            imgui.PopStyleColor()
        end

        imgui.Separator()
        if find_selected > 0 and find_list[find_selected] then
            local p = find_list[find_selected]
            if imgui.Button(u8"���������", imgui.ImVec2(100, 30)) then
                local phone = p.phone
                lua_thread.create(function() sampSendChat("/call " .. phone) end)
            end
            imgui.SameLine()
            if imgui.Button(u8"� ��", imgui.ImVec2(80, 30)) then
                local nick = p.nick
                lua_thread.create(function() addBlacklistNick(nick, "�� /find") end)
            end
            imgui.SameLine()
            if imgui.Button(u8"mmact", imgui.ImVec2(80, 30)) then
                local pid = tostring(p.id)
                lua_thread.create(function() cmdAct(pid) end)
            end
        end
        imgui.SameLine()
        if imgui.Button(u8"�������", imgui.ImVec2(80, 30)) then
            find_show[0] = false
        end
        imgui.End()
    end
)

-- ���: ���� ������� ������
imgui.OnFrame(
    function() return blacklist_show[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(500, 400), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"׸���� ������ ���", blacklist_show, imgui.WindowFlags.NoCollapse)

        local count = 0
        for nick, data in pairs(blacklist_data) do
            count = count + 1
        end
        imgui.TextUnformatted(u8"����� � ������: " .. count)
        imgui.Separator()

        imgui.BeginChild("##bl_list", imgui.ImVec2(0, 280), true)
        for nick, data in pairs(blacklist_data) do
            imgui.PushIDStr("bl_" .. nick)
            imgui.TextUnformatted(u8:encode(nick))
            imgui.SameLine(200)
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
            imgui.TextUnformatted(u8:encode(data.reason or ""))
            imgui.PopStyleColor()
            imgui.SameLine(350)
            if imgui.Button(u8"X") then
                lua_thread.create(function() removeBlacklistNick(nick) end)
                imgui.PopID()
                break
            end
            imgui.PopID()
            imgui.Separator()
        end
        imgui.EndChild()

        if imgui.Button(u8"�������", imgui.ImVec2(100, 30)) then
            blacklist_show[0] = false
        end
        imgui.End()
    end
)

-- ���������� ���������� ��� ������ � ������� ����� ImGui (FFI)
local ffi = require 'ffi'

-- AutoEdit ImGui Window
imgui.OnFrame(
    function() return ae_active[0] end,
    function()
        local display = imgui.GetIO().DisplaySize
        imgui.SetNextWindowSize(imgui.ImVec2(600, 280), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(display.x / 2, display.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8"AutoEdit - �������� ����������", nil, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

        imgui.TextUnformatted(u8"������������ �����:")
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
        imgui.PushTextWrapPos(0)
        imgui.TextUnformatted(ae_original_text)
        imgui.PopTextWrapPos()
        imgui.PopStyleColor()
        imgui.Separator()

        imgui.TextUnformatted(u8"����������������� ���������:")
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.8, 0.5, 1))
        imgui.PushTextWrapPos(0)
        imgui.TextUnformatted(ae_formatted_text)
        imgui.PopTextWrapPos()
        imgui.PopStyleColor()
        imgui.Separator()

        imgui.TextUnformatted(u8"�������������:")
        imgui.PushItemWidth(-1)
        if ae_focus then imgui.SetKeyboardFocusHere(0) end
        local ae_enter = imgui.InputText("##ae_input", ae_input_buf, ffi.sizeof(ae_input_buf), imgui.InputTextFlags.EnterReturnsTrue)
        ae_focus = false
        imgui.PopItemWidth()

        imgui.Spacing()
        local function aeQuickInsert(phrase)
            local cur = u8:decode(ffi.string(ae_input_buf))
            cur = cur:gsub("%s+$", "")
            if cur ~= "" and not cur:find("%.$") then cur = cur .. "." end
            if cur ~= "" then cur = cur .. " " .. phrase else cur = phrase end
            safeStrCopy(ae_input_buf, u8:encode(cur, encoding.default), ffi.sizeof(ae_input_buf))
        end
        if imgui.SmallButton(u8"+ ���� ����������") then aeQuickInsert("���� ����������") end
        imgui.SameLine()
        if imgui.SmallButton(u8"+ ������� (���)") then aeQuickInsert("������� � ���� �������") end
        imgui.SameLine()
        if imgui.SmallButton(u8"+ ������� (����)") then aeQuickInsert("������� � ����� �������") end

        -- Grace period: ignore Enter until the key is released after opening.
        -- The Enter key from sending /edit in chat may still be held down.
        if ae_ignore_enter > 0 then
            ae_ignore_enter = ae_ignore_enter - 1
            ae_enter = false
        end
        -- Also track Enter key state: don't send until Enter was released at least once
        local enter_key_down = imgui.GetIO().KeysDown[0x0D]
        if ae_enter_was_down then
            if not enter_key_down then
                ae_enter_was_down = false  -- Enter released, now allow future presses
            end
            ae_enter = false  -- still holding or just released, ignore
        end
        -- Track Esc key: ignore until released after opening
        local esc_key_down = imgui.GetIO().KeysDown[0x1B]
        if ae_esc_was_down then
            if not esc_key_down then
                ae_esc_was_down = false
            end
        end

        imgui.Spacing()

        if ae_enter or imgui.Button(u8"���������##send", imgui.ImVec2(120, 30)) then
            if ae_dialog_id >= 0 then
                local input_text = u8:decode(ffi.string(ae_input_buf))
                addAdToHistory(input_text)
                local suggested_cp1251 = u8:decode(ae_formatted_text)
                if suggested_cp1251 then
                    recordEditCorrection(suggested_cp1251, input_text)
                end
                local dlg_id = ae_dialog_id
                lua_thread.create(function() sampSendDialogResponse(dlg_id, 1, -1, input_text) end)
            end
            ae_active[0] = false
        end

        imgui.SameLine()

        if imgui.Button(ORIG_BTN_TEXT, imgui.ImVec2(100, 30)) then
            if ae_dialog_id >= 0 then
                local orig_text = u8:decode(ae_original_text)
                -- Strip existing tag prefix, add current tag
                orig_text = orig_text:gsub("^%s*[A-Za-z%A-Z%d]+%s*|%s*", "")
                local tag = u8:decode(ffi.string(mm_tag))
                if tag and tag ~= "" then
                    orig_text = tag .. " | " .. orig_text
                end
                -- Capitalize first letter after tag
                local pipe_pos = orig_text:find(" | ")
                if pipe_pos then
                    local after_pipe = pipe_pos + 3
                    if after_pipe <= #orig_text then
                        orig_text = orig_text:sub(1, after_pipe - 1) .. cp1251_upper(orig_text:sub(after_pipe, after_pipe)) .. orig_text:sub(after_pipe + 1)
                    end
                else
                    if #orig_text > 0 then
                        orig_text = cp1251_upper(orig_text:sub(1, 1)) .. orig_text:sub(2)
                    end
                end
                addAdToHistory(orig_text)
                local dlg_id = ae_dialog_id
                lua_thread.create(function() sampSendDialogResponse(dlg_id, 1, -1, orig_text) end)
            end
            ae_active[0] = false
        end
        imgui.SameLine()

        if imgui.Button(u8"��������� (���)", imgui.ImVec2(160, 30)) or (not ae_esc_was_down and imgui.GetIO().KeysDown[0x1B]) then
            if ae_dialog_id >= 0 then
                local tag = u8:decode(ffi.string(mm_tag))
                local reject_text = "���"
                if tag and tag ~= "" then
                    reject_text = tag .. " | ���"
                end
                safeStrCopy(ae_input_buf, u8:encode(reject_text, encoding.default), ffi.sizeof(ae_input_buf))
                local dlg_id = ae_dialog_id
                lua_thread.create(function() sampSendDialogResponse(dlg_id, 0, -1, reject_text) end)
            end
            ae_active[0] = false
        end

        
        imgui.SameLine()

        if imgui.Button(u8"�������", imgui.ImVec2(100, 30)) then
            ae_show_history[0] = not ae_show_history[0]
        end

        if ae_show_history[0] and #ad_history > 0 then
            imgui.Separator()
            imgui.TextUnformatted(u8"��������� ����������:")
            for i, h in ipairs(ad_history) do
                if imgui.Button(sanitizeUtf8(u8:encode(h:sub(1, 60) .. (h:len() > 60 and "..." or ""))), imgui.ImVec2(-1, 0)) then
                    safeStrCopy(ae_input_buf, u8:encode(h, encoding.default), ffi.sizeof(ae_input_buf))
                end
            end
        end

imgui.End()
    end
)


