--[[
    auto_gov.lua
    Описание: Auto /gov
    Автор: vk.com/seanizze (v1.1) rewritten for mimgui by Antigravity
]]

local imgui = require 'mimgui'
local ffi = require 'ffi'
local key = require 'vkeys'
local inicfg = require 'inicfg'
local encoding = require 'encoding'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- Настройки
local default_settings = {
    settings = {
        frak_text_buffer = "Больница LS",
        ftag_text_buffer = "H-LS",
        mesto_text_buffer = "в холле",
        krit_player_buffer = "3 года в штате, законопослушность, мед.карта",
        q_pole_buffer = "Собеседование в Больницу LS продолжается. Ждём вас!",
        w_polee_buffer = "Собеседование в Больницу LS окончено. Спасибо всем.",

        fftag_text_buffer = "Больница",
        mmesto_text_buffer = "в холле",
        kkrit_player_buffer = "3 года в штате, мед.карта",
        qq_pole_buffer = "Собеседование продолжается. Ждём вас!",
        ww_polee_buffer = "Собеседование окончено. Всем спасибо.",

        dop_1_buffer = "",
        dop_2_buffer = "",
        dop_3_buffer = "",
        dop_4_buffer = "",
        dop_5_buffer = "",
        dop_6_buffer = "",
        dop_7_buffer = "",
        dop_8_buffer = "",
        dop_9_buffer = "",
        dop_10_buffer = "",
    }
}

local ini_file = "LT(seanize).ini"
local settings = inicfg.load(default_settings, ini_file)
if not settings then
    settings = default_settings
    inicfg.save(settings, ini_file)
end

-- Состояние ImGui окна
local main_window_state = imgui.new.bool(false)

-- Буферы ImGui (UTF-8, так как ImGui работает с UTF-8)
local frak_buf = imgui.new.char[256](u8:encode(settings.settings.frak_text_buffer or ""))
local tag_buf = imgui.new.char[256](u8:encode(settings.settings.ftag_text_buffer or ""))
local mesto_buf = imgui.new.char[256](u8:encode(settings.settings.mesto_text_buffer or ""))
local krit_buf = imgui.new.char[256](u8:encode(settings.settings.krit_player_buffer or ""))
local q_pole_buf = imgui.new.char[256](u8:encode(settings.settings.q_pole_buffer or ""))
local w_polee_buf = imgui.new.char[256](u8:encode(settings.settings.w_polee_buffer or ""))

local fftag_buf = imgui.new.char[256](u8:encode(settings.settings.fftag_text_buffer or ""))
local mmesto_buf = imgui.new.char[256](u8:encode(settings.settings.mmesto_text_buffer or ""))
local kkrit_buf = imgui.new.char[256](u8:encode(settings.settings.kkrit_player_buffer or ""))
local qq_pole_buf = imgui.new.char[256](u8:encode(settings.settings.qq_pole_buffer or ""))
local ww_polee_buf = imgui.new.char[256](u8:encode(settings.settings.ww_polee_buffer or ""))

local dop_bufs = {}
for i = 1, 10 do
    dop_bufs[i] = imgui.new.char[256](u8:encode(settings.settings["dop_"..i.."_buffer"] or ""))
end

-- Функция сохранения настроек
local function saveSettings()
    settings.settings.frak_text_buffer = u8:decode(ffi.string(frak_buf))
    settings.settings.ftag_text_buffer = u8:decode(ffi.string(tag_buf))
    settings.settings.mesto_text_buffer = u8:decode(ffi.string(mesto_buf))
    settings.settings.krit_player_buffer = u8:decode(ffi.string(krit_buf))
    settings.settings.q_pole_buffer = u8:decode(ffi.string(q_pole_buf))
    settings.settings.w_polee_buffer = u8:decode(ffi.string(w_polee_buf))

    settings.settings.fftag_text_buffer = u8:decode(ffi.string(fftag_buf))
    settings.settings.mmesto_text_buffer = u8:decode(ffi.string(mmesto_buf))
    settings.settings.kkrit_player_buffer = u8:decode(ffi.string(kkrit_buf))
    settings.settings.qq_pole_buffer = u8:decode(ffi.string(qq_pole_buf))
    settings.settings.ww_polee_buffer = u8:decode(ffi.string(ww_polee_buf))

    for i = 1, 10 do
        settings.settings["dop_"..i.."_buffer"] = u8:decode(ffi.string(dop_bufs[i]))
    end
    inicfg.save(settings, ini_file)
end

-- ================= Потоки =================

-- 1. Собеседование (/gov) - Начало
local function govStartThread()
    local tag = u8:decode(ffi.string(tag_buf))
    local frak = u8:decode(ffi.string(frak_buf))
    local mesto = u8:decode(ffi.string(mesto_buf))
    local krit = u8:decode(ffi.string(krit_buf))

    sampSendChat(string.format("/d %s to all || Занял государственную волну вещания.", tag))
    wait(10000)
    sampSendChat("/gov Внимание. Уважаемые жители штата. Минуточку внимания!")
    wait(5000)
    sampSendChat(string.format("/gov Напоминаю, что сейчас проходит собеседование в %s %s.", frak, mesto))
    wait(5000)
    sampSendChat(string.format("/gov Критерии: %s.", krit))
    wait(5000)
    sampSendChat("/gov Спасибо за внимание!")
    wait(5000)
    sampSendChat(string.format("/d %s to all || Освободил государственную волну вещания.", tag))
end

-- 2. Собеседование (/gov) - Продолжение
local function govContinueThread()
    local tag = u8:decode(ffi.string(tag_buf))
    local text = u8:decode(ffi.string(q_pole_buf))

    sampSendChat(string.format("/d %s to all || Занял государственную волну вещания.", tag))
    wait(10000)
    sampSendChat("/gov Внимание. Уважаемые жители штата. Минуточку внимания!")
    wait(5000)
    sampSendChat(string.format("/gov %s", text))
    wait(5000)
    sampSendChat("/gov Спасибо за внимание!")
    wait(5000)
    sampSendChat(string.format("/d %s to all || Освободил государственную волну вещания.", tag))
end

-- 3. Собеседование (/gov) - Конец
local function govFinishThread()
    local tag = u8:decode(ffi.string(tag_buf))
    local text = u8:decode(ffi.string(w_polee_buf))

    sampSendChat(string.format("/d %s to all || Занял государственную волну вещания.", tag))
    wait(10000)
    sampSendChat("/gov Внимание. Уважаемые жители штата. Минуточку внимания!")
    wait(5000)
    sampSendChat(string.format("/gov %s", text))
    wait(5000)
    sampSendChat("/gov Спасибо за внимание!")
    wait(5000)
    sampSendChat(string.format("/d %s to all || Освободил государственную волну вещания.", tag))
end

-- 4. Эфир (/news) - Начало
local function newsStartThread()
    local frak = u8:decode(ffi.string(frak_buf))
    local mesto = u8:decode(ffi.string(mmesto_buf))
    local krit = u8:decode(ffi.string(krit_buf))

    sampSendChat("/news Внимание. Уважаемые радиослушатели. Минуточку внимания!")
    wait(5000)
    sampSendChat(string.format("/news Напоминаю, что сейчас проходит собеседование в %s %s.", frak, mesto))
    wait(5000)
    sampSendChat(string.format("/news Критерии: %s.", krit))
    wait(5000)
    sampSendChat("/news Спасибо за внимание!")
end

-- 5. Эфир (/news) - Продолжение
local function newsContinueThread()
    local text = u8:decode(ffi.string(qq_pole_buf))

    sampSendChat("/news Внимание. Уважаемые радиослушатели. Минуточку внимания!")
    wait(5000)
    sampSendChat(string.format("/news %s", text))
    wait(5000)
    sampSendChat("/news Спасибо за внимание!")
end

-- 6. Эфир (/news) - Конец
local function newsFinishThread()
    local text = u8:decode(ffi.string(ww_polee_buf))

    sampSendChat("/news Внимание. Уважаемые радиослушатели. Минуточку внимания!")
    wait(5000)
    sampSendChat(string.format("/news %s", text))
    wait(5000)
    sampSendChat("/news Спасибо за внимание!")
end

-- ================= Интерфейс ImGui =================

local function applyStyle()
    local style = imgui.GetStyle()
    local colors = style.Colors

    style.WindowRounding = 6.0
    style.FrameRounding = 4.0
    style.ScrollbarRounding = 4.0
    style.GrabRounding = 4.0

    colors[imgui.Col.WindowBg] = imgui.ImVec4(0.08, 0.08, 0.10, 0.95)
    colors[imgui.Col.ChildBg] = imgui.ImVec4(0.11, 0.11, 0.14, 0.90)
    colors[imgui.Col.FrameBg] = imgui.ImVec4(0.15, 0.15, 0.18, 1.00)
    colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.22, 0.22, 0.27, 1.00)
    colors[imgui.Col.FrameBgActive] = imgui.ImVec4(0.28, 0.28, 0.33, 1.00)
    colors[imgui.Col.TitleBg] = imgui.ImVec4(0.10, 0.10, 0.12, 1.00)
    colors[imgui.Col.TitleBgActive] = imgui.ImVec4(0.15, 0.15, 0.18, 1.00)
    colors[imgui.Col.Button] = imgui.ImVec4(0.18, 0.45, 0.68, 0.80)
    colors[imgui.Col.ButtonHovered] = imgui.ImVec4(0.22, 0.53, 0.78, 1.00)
    colors[imgui.Col.ButtonActive] = imgui.ImVec4(0.14, 0.40, 0.62, 1.00)
    colors[imgui.Col.Header] = imgui.ImVec4(0.18, 0.18, 0.22, 1.00)
    colors[imgui.Col.HeaderHovered] = imgui.ImVec4(0.24, 0.24, 0.30, 1.00)
    colors[imgui.Col.HeaderActive] = imgui.ImVec4(0.30, 0.30, 0.37, 1.00)
end

imgui.OnFrame(function()
    return main_window_state[0]
end, function(player)
    applyStyle()
    imgui.SetNextWindowSize(imgui.ImVec2(620, 500), imgui.Cond.FirstUseEver)
    imgui.Begin(u8"Auto /gov | Автор: vk.com/seanizze | v1.1", main_window_state, imgui.WindowFlags.NoCollapse)

    -- 1. Собеседование гос.новости
    if imgui.CollapsingHeader(u8"Собеседование/Призыв [Команды: /gov, /d]") then
        imgui.PushItemWidth(250)
        if imgui.InputText(u8"Организация##gov_frak", frak_buf, 256) then saveSettings() end
        if imgui.InputText(u8"Тег в /d##gov_tag", tag_buf, 256) then saveSettings() end
        if imgui.InputText(u8"Место##gov_mesto", mesto_buf, 256) then saveSettings() end
        imgui.PopItemWidth()

        if imgui.InputText(u8"Критерии##gov_krit", krit_buf, 256) then saveSettings() end

        imgui.Separator()
        imgui.Text(u8"Строки продолжения и конца:")
        if imgui.InputText(u8"Продолжение##gov_cont_text", q_pole_buf, 256) then saveSettings() end
        if imgui.InputText(u8"Конец##gov_fin_text", w_polee_buf, 256) then saveSettings() end

        imgui.Spacing()
        if imgui.Button(u8"Начать собеседование##gov_btn_start") then
            lua_thread.create(govStartThread)
        end
        imgui.SameLine()
        if imgui.Button(u8"Напомнить##gov_btn_continue") then
            lua_thread.create(govContinueThread)
        end
        imgui.SameLine()
        if imgui.Button(u8"Закончить##gov_btn_finish") then
            lua_thread.create(govFinishThread)
        end
        imgui.Spacing()
    end

    -- 2. Эфиры новостей
    if imgui.CollapsingHeader(u8"Собеседование в эфир [Команда: /news]") then
        imgui.PushItemWidth(250)
        if imgui.InputText(u8"Тег фракции##news_tag", fftag_buf, 256) then saveSettings() end
        if imgui.InputText(u8"Место##news_mesto", mmesto_buf, 256) then saveSettings() end
        imgui.PopItemWidth()

        if imgui.InputText(u8"Критерии##news_krit", kkrit_buf, 256) then saveSettings() end

        imgui.Separator()
        imgui.Text(u8"Строки продолжения и конца:")
        if imgui.InputText(u8"Продолжение##news_cont_text", qq_pole_buf, 256) then saveSettings() end
        if imgui.InputText(u8"Конец##news_fin_text", ww_polee_buf, 256) then saveSettings() end

        imgui.Spacing()
        if imgui.Button(u8"Начать эфир##news_btn_start") then
            lua_thread.create(newsStartThread)
        end
        imgui.SameLine()
        if imgui.Button(u8"Напомнить в эфире##news_btn_continue") then
            lua_thread.create(newsContinueThread)
        end
        imgui.SameLine()
        if imgui.Button(u8"Закончить эфир##news_btn_finish") then
            lua_thread.create(newsFinishThread)
        end
        imgui.Spacing()
    end

    -- 3. Дополнительные строки
    if imgui.CollapsingHeader(u8"Доп. бинды") then
        imgui.Text(u8"Строки для отправки в чат при нажатии на кнопку:")
        for i = 1, 10 do
            imgui.PushItemWidth(430)
            if imgui.InputText(string.format("%d##dop_%d", i, i), dop_bufs[i], 256) then
                saveSettings()
            end
            imgui.PopItemWidth()
            imgui.SameLine()
            if imgui.Button(string.format(u8"Отправить##dop_%d_btn", i)) then
                local text_dop = ffi.string(dop_bufs[i])
                if text_dop ~= "" then
                    sampSendChat(u8:decode(text_dop))
                end
            end
        end
        imgui.Spacing()
    end

    imgui.End()
end)

-- ================= Основной поток =================

function main()
    while not isSampAvailable() do wait(100) end

    -- Команда активации меню (поддерживаем обе: lpanel и lgov)
    sampRegisterChatCommand("lpanel", function()
        main_window_state[0] = not main_window_state[0]
    end)
    sampRegisterChatCommand("lgov", function()
        main_window_state[0] = not main_window_state[0]
    end)

    -- Сообщение в чат при запуске
    sampAddChatMessage(u8:decode("[Auto /gov] Скрипт загружен. Введите /lpanel или /lgov для настроек."), 0xFFFFFF)

    while true do
        wait(0)
    end
end
