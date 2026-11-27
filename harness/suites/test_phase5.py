# -*- coding: utf-8 -*-
import json
import math
import re
import sys
from pathlib import Path

EXPECTED_PHASE5_SLOTS = (
    "PHASE5_STATE",
    "PHASE5_LOAD",
    "PHASE5_SAVE",
    "PHASE5_VEHICLE_UI",
    "PHASE5_QOL_UI",
    "PHASE5_EXPORT",
    "PHASE5_IMPORT",
    "PHASE5_LOGIC",
    "PHASE5_CMDS",
    "PHASE5_TICK_1S",
    "PHASE5_MAIN_LOOP",
    "PHASE5_ON_DIALOG",
    "PHASE5_HUD",
    "PHASE5_TERMINATE",
)

FORBIDDEN_IMGUI_DIRECT_CALLS = (
    r"\bsamp[A-Z]\w*\s*\(",
    r"\bplayRp\s*\(",
    r"\bapplyLocalSkin\s*\(",
    r"\bgetPlayerMoney\s*\(",
    r"\bgetCharPlayerIsTargeting\s*\(",
    r"\baddOneOffSound\s*\(",
    r"\bplaceWaypoint\s*\(",
    r"\bremoveWaypoint\s*\(",
    r"\bgetCharCoordinates\s*\(",
    r"\bgetCharHeading\s*\(",
    r"\blockPlayerControl\s*\(",
    r"\bsetFixedCameraPosition\s*\(",
    r"\bpointCameraAtPoint\s*\(",
    r"\brestoreCameraJumpcut\s*\(",
    r"\bsetCameraBehindPlayer\s*\(",
    r"\blua_thread\.create\s*\(",
)


def _strip_queued_calls(lua_snippet: str) -> str:
    cleaned = []
    k = 0
    while k < len(lua_snippet):
        m = re.search(r"\b(queueTask|scheduleTask)\s*\(", lua_snippet[k:])
        if not m:
            cleaned.append(lua_snippet[k:])
            break
        cleaned.append(lua_snippet[k : k + m.start()])
        p = k + m.start() + len(m.group(0)) - 1
        d = 0
        s_q = None
        while p < len(lua_snippet):
            cc = lua_snippet[p]
            if s_q:
                if cc == "\\":
                    p += 2
                    continue
                if cc == s_q:
                    s_q = None
            else:
                if cc in ("'", '"'):
                    s_q = cc
                elif cc == "(":
                    d += 1
                elif cc == ")":
                    d -= 1
                    if d == 0:
                        p += 1
                        break
            p += 1
        k = p
    return "".join(cleaned)


def _extract_lua_function(src: str, func_header_regex: str) -> str:
    m = re.search(func_header_regex, src)
    assert m, f"Function matching {func_header_regex!r} not found!"
    pos = m.start()
    n = len(src)
    depth = 0
    expect_do = False
    in_str = None
    i = pos
    prev_sym = ""
    while i < n:
        ch = src[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == in_str:
                in_str = None
            i += 1
            continue
        if ch in ("'", '"'):
            in_str = ch
            prev_sym = ""
            i += 1
            continue
        if ch == "-" and i + 1 < n and src[i + 1] == "-":
            if i + 3 < n and src[i + 2] == "[" and src[i + 3] in "[=":
                eq = 0
                k = i + 3
                while k < n and src[k] == "=":
                    eq += 1
                    k += 1
                if k < n and src[k] == "[":
                    end_cmt = src.find("]" + ("=" * eq) + "]", k + 1)
                    i = n if end_cmt == -1 else end_cmt + 2 + eq
                    continue
            nl = src.find("\n", i + 2)
            i = n if nl == -1 else nl + 1
            continue
        if ch == "[" and i + 1 < n and src[i + 1] in "[=":
            eq = 0
            k = i + 1
            while k < n and src[k] == "=":
                eq += 1
                k += 1
            if k < n and src[k] == "[":
                end_str = src.find("]" + ("=" * eq) + "]", k + 1)
                i = n if end_str == -1 else end_str + 2 + eq
                prev_sym = ""
                continue
        if ch.isalpha() or ch == "_":
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            word = src[i:j]
            if prev_sym not in (".", ":"):
                if word in ("function", "if", "repeat"):
                    depth += 1
                elif word in ("for", "while"):
                    depth += 1
                    expect_do = True
                elif word == "do":
                    if expect_do:
                        expect_do = False
                    else:
                        depth += 1
                elif word in ("end", "until"):
                    depth -= 1
                    if depth == 0:
                        return src[pos:j]
            prev_sym = ""
            i = j
            continue
        if not ch.isspace():
            prev_sym = ch
        i += 1
    raise AssertionError(f"Unclosed Lua function starting at {func_header_regex!r}")


def test_phase5_features(src: str):
    src = src.replace("\r\n", "\n")

    # 1. Opt-in state defaults MUST be false
    for flag in ("cam_feature_enabled", "buyfast_enabled", "session_track_enabled"):
        m = re.search(rf"\b{flag}\s*=\s*imgui\.new\.bool\((true|false)\)", src)
        assert m and m.group(1) == "false", f"{flag} MUST default to false!"

    for sym in (
        "P5 = P5 or {}",
        "cam_active = false",
        "cam_speed = imgui.new.float(0.6)",
        "cam_controls_locked = false",
        "buyfast_item_idx = imgui.new.int(0)",
        "buyfast_armed_until = 0",
        "buyfast_last_fire = 0",
        "session_active_sec = 0",
        "session_afk_sec = 0",
        "session_idle_sec = 0",
        "function P5_enterFreeCam()",
        "function P5_exitFreeCam()",
        "function P5_toggleFreeCam()",
        "function P5_tickFreeCam()",
        "function P5_cmdBuyFast(",
        "function P5_matchBuyFastLine(",
        "function P5_tickSession1s()",
        "function P5_formatDuration(",
        "function P5_cleanImportValue(",
    ):
        assert sym in src, f"Missing Phase 5 symbol: {sym}"

    # 2. Commands registered cleanly without duplicates
    assert re.search(r"""sampRegisterChatCommand\(\s*['"]cam['"]""", src), "Missing /cam command"
    assert re.search(r"""sampRegisterChatCommand\(\s*['"]buyfast['"]""", src), "Missing /buyfast command"

    # 3. Settings persistence (loadDatabases & saveSettings)
    load_body = _extract_lua_function(src, r"function loadDatabases\(\)")
    save_body = _extract_lua_function(src, r"function saveSettings\(\)")
    for key in ("cam_feature_enabled", "cam_speed", "buyfast_enabled", "buyfast_item_idx", "session_track_enabled"):
        assert f"parsed.{key}" in load_body, f"Missing loadDatabases handling for {key}"
        assert f"{key} =" in save_body, f"Missing saveSettings handling for {key}"

    # 4. Drone /cam safety: pcall guards, warning text, thread-safe UI, cleanup on terminate
    assert "(только для скринов/осмотра, соблюдайте правила сервера!)" in src, "Missing server rules warning for /cam"
    assert "WASD — полёт, Space/Shift — вверх/вниз, Q/E и Стрелки — обзор" in src, "Missing drone controls hint"
    assert "pcall(getCharCoordinates, PLAYER_PED)" in src
    assert "pcall(getCharHeading, PLAYER_PED)" in src
    assert 'type(lockPlayerControl) == "function"' in src and "pcall(lockPlayerControl" in src
    assert "pcall(setFixedCameraPosition" in src
    assert "pcall(pointCameraAtPoint" in src
    assert "pcall(restoreCameraJumpcut)" in src

    term_body = _extract_lua_function(src, r"function onScriptTerminate\(")
    assert "P5_exitFreeCam" in term_body, "onScriptTerminate must call P5_exitFreeCam when cam_active!"

    m_vv = re.search(r'id = "vehicle_visuals".*?drawSettings = function\(\)(.*?)\n\s*end,\n\s*onToggle', src, re.S)
    assert m_vv, "vehicle_visuals.drawSettings not found!"
    vv_outside = _strip_queued_calls(m_vv.group(1))
    for pat in FORBIDDEN_IMGUI_DIRECT_CALLS:
        assert not re.search(pat, vv_outside), f"Direct forbidden call {pat} inside vehicle_visuals.drawSettings"
    assert "queueTask(P5_toggleFreeCam)" in m_vv.group(1), "Free cam toggle must use queueTask"

    m_qol = re.search(r'id = "qol_tools".*?elseif qol_ui_page == 3 then(.*?)\n\s*else\n', src, re.S)
    assert m_qol, "qol_tools Tab 3 not found!"
    qol_tab3 = m_qol.group(1)
    assert "session_track_enabled" in qol_tab3 and "buyfast_enabled" in qol_tab3 and "buyfast_item_idx" in qol_tab3
    qol_outside = _strip_queued_calls(qol_tab3)
    for pat in FORBIDDEN_IMGUI_DIRECT_CALLS:
        assert not re.search(pat, qol_outside), f"Direct forbidden call {pat} inside qol_tools Tab 3"

    # 5. Quick Shop Buy (/buyfast) onShowDialog ordering & guards
    dlg_body = _extract_lua_function(src, r"function sampev\.onShowDialog\(")
    pos_bf = dlg_body.find("buyfast_enabled[0]")
    pos_mm = dlg_body.find('isModuleEnabled("mm_editor")')
    assert 0 < pos_bf < pos_mm, "buyfast dialog hook must run BEFORE mm_editor check!"
    assert "buyfast_armed_until > os.clock()" in dlg_body
    assert "(os.clock() - buyfast_last_fire) >= 1.5" in dlg_body
    assert "style == 2" in dlg_body
    assert "sampSendDialogResponse(dialogId, 1, bf_idx" in dlg_body
    assert "buyfast_armed_until = 0" in dlg_body

    # 6. Export v2 & Import restoration ordering
    exp_body = _extract_lua_function(src, r"function exportAllConfig\(\)")
    imp_body = _extract_lua_function(src, r"function importAllConfig\(\)")
    assert "format_version = 2" in exp_body
    for field in ("chat_filter", "lecturer_templates", "codex", "locations", "location_favorites"):
        assert field in exp_body, f"Export v2 missing field: {field}"
    pos_load_call = imp_body.find("loadDatabases()")
    for fn_name in ("P3_saveLecturer", "P4_saveCodex", "P6_saveLocations"):
        pos_fn = imp_body.find(fn_name)
        assert 0 < pos_fn < pos_load_call, f"importAllConfig must call {fn_name} BEFORE loadDatabases()!"

    # 7. HUD active/AFK tracker rendering & main loop calls
    assert "if cam_active then P5_tickFreeCam() end" in src
    assert "P5_tickSession1s()" in src
    m_hud = re.search(r'"##helper_compact_hud".*?imgui\.End\(\)', src, re.S)
    assert m_hud, "Compact HUD OnFrame block not found!"
    assert "session_track_enabled[0]" in m_hud.group(0) and "encodeCp1251Safe(session_hud_str)" in m_hud.group(0)

    # =========================================================================
    # Behavioral unit mirrors
    # =========================================================================

    # A. Free Cam kinematics & clamping mirror
    def sim_cam_pose(x, y, z, yaw_deg, pitch, spd_raw, keys, dt=0.05):
        yaw = math.radians(yaw_deg)
        spd = max(0.1, min(3.0, spd_raw)) * (dt * 30.0)
        rot_spd = 1.8 * dt
        if "Q" in keys or "LEFT" in keys:
            yaw += rot_spd
        if "E" in keys or "RIGHT" in keys:
            yaw -= rot_spd
        if "UP" in keys:
            pitch = min(1.45, pitch + rot_spd * 0.85)
        if "DOWN" in keys:
            pitch = max(-1.45, pitch - rot_spd * 0.85)
        cp = math.cos(pitch)
        fx, fy, fz = -math.sin(yaw) * cp, math.cos(yaw) * cp, math.sin(pitch)
        rx, ry = math.cos(yaw), math.sin(yaw)
        if "W" in keys:
            x, y, z = x + fx * spd, y + fy * spd, z + fz * spd
        if "S" in keys:
            x, y, z = x - fx * spd, y - fy * spd, z - fz * spd
        if "D" in keys:
            x, y = x + rx * spd, y + ry * spd
        if "A" in keys:
            x, y = x - rx * spd, y - ry * spd
        if "SPACE" in keys:
            z += spd
        if "SHIFT" in keys:
            z -= spd
        return x, y, z, yaw, pitch

    nx, ny, nz, nyaw, npitch = sim_cam_pose(100.0, 200.0, 10.0, 0.0, 0.0, 10.0, {"W", "D", "SPACE"})
    assert abs(nx - 104.5) < 1e-6 and abs(ny - 204.5) < 1e-6 and abs(nz - 14.5) < 1e-6, "Speed clamp/W+D+Space mismatch"
    _, _, _, _, clamped_p = sim_cam_pose(0, 0, 0, 0, 1.44, 0.6, {"UP"}, dt=1.0)
    assert clamped_p == 1.45, f"Pitch clamp failed: {clamped_p}"
    _, _, _, nyaw2, _ = sim_cam_pose(0, 0, 0, 90.0, 0.0, 0.6, {"W"}, dt=0.1)
    nx_w, ny_w, _, _, _ = sim_cam_pose(0.0, 0.0, 0.0, 90.0, 0.0, 1.0, {"W"}, dt=1/30.0)
    assert nx_w < -0.99 and abs(ny_w) < 1e-6, f"Heading 90deg should point West (-X): {(nx_w, ny_w)}"

    # B. Quick Shop Buy (/buyfast) matching mirror
    bf_keywords = [
        ("Аптечка", ["аптеч"]),
        ("Маска", ["маск"]),
        ("Ремкомплект", ["рем"]),
        ("Канистра", ["канистр"]),
        ("Телефон / Сим", ["телеф", "сим", "sim"]),
    ]

    def match_buyfast(title, text, item_idx, enabled=True, armed=True, elapsed_since_fire=2.0, style=2):
        if not enabled or not armed or elapsed_since_fire < 1.5 or style != 2:
            return None
        ct = re.sub(r"\{[0-9A-Fa-f]+\}", "", title or "").lower()
        if not any(k in ct for k in ("магазин", "24/7", "аптек", "товар")):
            return None
        kws = bf_keywords[max(0, min(4, item_idx))][1]
        for idx, line in enumerate(re.findall(r"[^\r\n]+", text or "")):
            cl = re.sub(r"\{[0-9A-Fa-f]+\}", "", line).lower()
            if any(kw in cl for kw in kws):
                return idx
        return None

    shop_text = "{FFFFFF}Чипсы - 50$\n{00FF00}Аптечка - 150$\nМаска - 300$\nРемкомплект - 500$\nКанистра - 400$\nSIM-карта - 1000$"
    assert match_buyfast("{FFAA00}Магазин 24/7", shop_text, 0) == 1
    assert match_buyfast("Аптека города LS", shop_text, 0) == 1
    assert match_buyfast("Магазин 24/7", shop_text, 1) == 2
    assert match_buyfast("Магазин 24/7", shop_text, 2) == 3
    assert match_buyfast("Магазин 24/7", shop_text, 3) == 4
    assert match_buyfast("Список товаров", shop_text, 4) == 5
    assert match_buyfast("Магазин 24/7", shop_text, 0, enabled=False) is None
    assert match_buyfast("Магазин 24/7", shop_text, 0, armed=False) is None
    assert match_buyfast("Магазин 24/7", shop_text, 0, elapsed_since_fire=0.8) is None
    assert match_buyfast("Магазин 24/7", shop_text, 0, style=0) is None
    assert match_buyfast("Навигатор GPS", shop_text, 0) is None

    # C. Session Active / AFK Tracker mirror
    def fmt_dur(sec):
        s = max(0, int(sec))
        if s >= 3600:
            return f"{s // 3600}ч {(s % 3600) // 60:02d}м"
        return f"{s // 60:02d}м {s % 60:02d}с"

    assert fmt_dur(65) == "01м 05с"
    assert fmt_dur(3665) == "1ч 01м"

    st = {"active": 0, "afk": 0, "idle": 0, "last_pos": None}

    def tick_session(pos, moved_input=False, paused=False, alive=True):
        moved = False
        if st["last_pos"] is not None:
            dx = pos[0] - st["last_pos"][0]
            dy = pos[1] - st["last_pos"][1]
            if dx * dx + dy * dy > 0.04:
                moved = True
        st["last_pos"] = pos
        if (not paused) and alive and (moved or moved_input):
            st["idle"] = 0
            st["active"] += 1
        else:
            st["idle"] += 1
            if st["idle"] >= 45:
                st["afk"] += 1
            else:
                st["active"] += 1

    tick_session((0.0, 0.0), moved_input=False)
    assert st["active"] == 1 and st["idle"] == 1
    tick_session((2.0, 0.0), moved_input=False)
    assert st["active"] == 2 and st["idle"] == 0
    for _ in range(44):
        tick_session((2.0, 0.0), moved_input=False, paused=False)
    assert st["idle"] == 44 and st["afk"] == 0 and st["active"] == 46
    tick_session((2.0, 0.0), moved_input=False, paused=True)
    assert st["idle"] == 45 and st["afk"] == 1 and st["active"] == 46

    # D. Export v2 / Import sanitization mirror
    def clean_val(v, depth=0):
        if depth > 6:
            return None
        if isinstance(v, str):
            return v[:16384].replace("\x00", "")
        if isinstance(v, bool):
            return v
        if isinstance(v, (int, float)):
            return 0 if not math.isfinite(v) else v
        if isinstance(v, dict):
            return {k: clean_val(val, depth + 1) for k, val in v.items() if isinstance(k, str) and "\x00" not in k}
        if isinstance(v, list):
            return [clean_val(val, depth + 1) for val in v]
        return None

    sample_bundle = {
        "format_version": 2,
        "chat_filter": {"enabled": True, "whitelist": "дом\x00, биз"},
        "lecturer_templates": [{"name": "Лекция", "text": "Привет\x00"}],
        "codex": {"uk": [{"code": "1.1", "stars": 2}]},
        "locations": {"Advance|Nick": [{"model": 1234, "x": 1.0}]},
        "location_favorites": {"1234": True},
    }
    cleaned = clean_val(sample_bundle)
    assert cleaned["chat_filter"]["whitelist"] == "дом, биз"
    assert cleaned["lecturer_templates"][0]["text"] == "Привет"
    assert cleaned["codex"]["uk"][0]["code"] == "1.1"
    assert cleaned["location_favorites"]["1234"] is True

    print("Phase 5 checks OK (/cam drone, /buyfast shop guard, session active/AFK HUD, export v2)")


def _check_slot_basics(slots: dict):
    missing = [k for k in EXPECTED_PHASE5_SLOTS if k not in slots]
    extra = [k for k in slots if k not in EXPECTED_PHASE5_SLOTS]
    assert not missing, f"Missing Phase 5 slots: {missing}"
    assert not extra, f"Unexpected Phase 5 slots: {extra}"

    for key, code in slots.items():
        assert isinstance(code, str) and code.strip(), f"Slot {key} must be non-empty string"
        try:
            cp = code.encode("cp1251")
        except UnicodeEncodeError as e:
            raise AssertionError(f"Slot {key} contains non-CP1251 character: {e}") from e
        assert b"\x00" not in cp, f"Slot {key} contains raw NUL byte"
        for b in cp:
            assert b >= 32 or b in (9, 10, 13), f"Slot {key} contains control byte {b}"

    # UI slots strict render-thread checks
    for ui_key in ("PHASE5_VEHICLE_UI", "PHASE5_QOL_UI", "PHASE5_HUD"):
        ui_code = slots[ui_key]
        for vfn in ("imgui.Text(", "imgui.TextColored(", "imgui.TextWrapped(", "imgui.BulletText("):
            assert vfn not in ui_code, f"Variadic {vfn} forbidden in {ui_key}"
        even_bufs = [m.group(0) for m in re.finditer(r"imgui\.new\.char\[(\d+)\]", ui_code) if int(m.group(1)) % 2 == 0]
        assert not even_bufs, f"Even char buffers in {ui_key}: {even_bufs}"
        outside = _strip_queued_calls(ui_code)
        for pat in FORBIDDEN_IMGUI_DIRECT_CALLS:
            assert not re.search(pat, outside), f"Forbidden direct call {pat} inside {ui_key}"


def run_standalone_verification():
    swarm_dir = Path(__file__).resolve().parent
    scratch_dir = swarm_dir.parent
    sys.path.insert(0, str(scratch_dir))
    sys.path.insert(0, str(swarm_dir))

    try:
        import verify_helper as vh
    except ImportError:
        import run as vh
    import prepare_hooks as ph

    slots_path = swarm_dir / "phase5_slots.json"
    slots = json.loads(slots_path.read_text(encoding="utf-8"))
    _check_slot_basics(slots)

    # Verify zero depth-0 locals in standalone top-level slots
    for top_key in ("PHASE5_STATE", "PHASE5_LOGIC"):
        toks = vh.lex_lua(slots[top_key])
        vh.check_lua_structure(toks)
        depth = 0
        expect_do = False
        prev = None
        for kind, val, ln in toks:
            is_field = prev and prev[0] == "SYM" and prev[1] in (".", ":")
            if kind == "ID" and not is_field:
                assert not (depth == 0 and val == "local"), f"Top-level 'local' forbidden in {top_key} at line {ln}"
                if val in ("function", "if", "repeat"):
                    depth += 1
                elif val in ("for", "while"):
                    depth += 1
                    expect_do = True
                elif val == "do":
                    if expect_do:
                        expect_do = False
                    else:
                        depth += 1
                elif val in ("end", "until"):
                    depth -= 1
            prev = (kind, val, ln)

    # In-memory assembly against helper_core.lua (never mutates helper_core.lua on disk!)
    raw = vh.TARGET.read_bytes()
    src = raw.decode("cp1251")
    if "-- [[SWARM:PHASE5_STATE]]" not in src:
        src = ph.demote_depth0_locals(src)
        src = ph.replace_once(
            src,
            r"""if target_menu_enabled[0] and not sampIsChatInputActive() and not sampIsDialogActive() and wasKeyPressed(0x58) then""",
            r"""if target_menu_enabled[0] and not sampIsChatInputActive() and not sampIsDialogActive() and wasKeyPressed(getTargetMenuVk and getTargetMenuVk() or 0x58) then""",
            "target_menu hotkey delegation",
        )
        src = ph.replace_once(
            src,
            "    local bundle = {\n        format_version = 1,",
            "    local bundle = {\n        format_version = 2,",
            "export bundle format_version = 2",
        )
        src = ph.replace_once(
            src,
            "-- Флаг быстрого реконнекта\nreconnect_pending = false\n\ncruise_speed = 0.0",
            "-- Флаг быстрого реконнекта\nreconnect_pending = false\n-- [[SWARM:PHASE5_STATE]]\n\ncruise_speed = 0.0",
            "PHASE5_STATE",
        )
        src = ph.replace_once(
            src,
            'if type(parsed.line_wrap_delay) == "number" then line_wrap_delay[0] = math.max(350, math.min(1500, math.floor(parsed.line_wrap_delay))) end',
            'if type(parsed.line_wrap_delay) == "number" then line_wrap_delay[0] = math.max(350, math.min(1500, math.floor(parsed.line_wrap_delay))) end\n-- [[SWARM:PHASE5_LOAD]]',
            "PHASE5_LOAD",
        )
        src = ph.replace_once(
            src,
            "line_wrap_delay = line_wrap_delay[0],\nkeybinds = kb,",
            "line_wrap_delay = line_wrap_delay[0],\n-- [[SWARM:PHASE5_SAVE]]\nkeybinds = kb,",
            "PHASE5_SAVE",
        )
        src = ph.replace_once(
            src,
            'imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))\nimgui.TextUnformatted(u8"-> Команды: /hud (вкл/выкл HUD), /calc [пример] (напр. /calc 1.5кк * 3 + 500к)")\nimgui.PopStyleColor()\nend,',
            'imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))\nimgui.TextUnformatted(u8"-> Команды: /hud (вкл/выкл HUD), /calc [пример] (напр. /calc 1.5кк * 3 + 500к)")\nimgui.PopStyleColor()\n-- [[SWARM:PHASE5_VEHICLE_UI]]\nend,',
            "PHASE5_VEHICLE_UI",
        )
        src = ph.replace_once(
            src,
            '        if imgui.Checkbox(u8"Показывать баланс сессии в /hud", hud_show_finance) then requestSaveSettings() end',
            '        if imgui.Checkbox(u8"Показывать баланс сессии в /hud", hud_show_finance) then requestSaveSettings() end\n-- [[SWARM:PHASE5_QOL_UI]]',
            "PHASE5_QOL_UI",
        )
        src = ph.replace_once(
            src,
            "        custom_rules = custom_rules,\n    }",
            "        custom_rules = custom_rules,\n-- [[SWARM:PHASE5_EXPORT]]\n    }",
            "PHASE5_EXPORT",
        )
        src = ph.replace_once(
            src,
            "    loadDatabases()\n    if saved_module_states then",
            "-- [[SWARM:PHASE5_IMPORT]]\n    loadDatabases()\n    if saved_module_states then",
            "PHASE5_IMPORT",
        )
        src = ph.replace_once(
            src,
            "-- ГЛАВНАЯ ФУНКЦИЯ (Точка входа)",
            "-- [[SWARM:PHASE5_LOGIC]]\n\n-- ГЛАВНАЯ ФУНКЦИЯ (Точка входа)",
            "PHASE5_LOGIC",
        )
        src = ph.replace_once(
            src,
            "sampRegisterChatCommand('hist', cmdFastHistory)",
            "sampRegisterChatCommand('hist', cmdFastHistory)\n-- [[SWARM:PHASE5_CMDS]]",
            "PHASE5_CMDS",
        )
        src = ph.replace_once(
            src,
            '    else\n        hud_cache.wp_text = ""\n    end\n    if finance_enabled[0] and isSampAvailable() then',
            '    else\n        hud_cache.wp_text = ""\n    end\n-- [[SWARM:PHASE5_TICK_1S]]\n    if finance_enabled[0] and isSampAvailable() then',
            "PHASE5_TICK_1S",
        )
        src = ph.replace_once(
            src,
            "-- Клавиша J для стробоскопов в машине",
            "-- [[SWARM:PHASE5_MAIN_LOOP]]\n\n-- Клавиша J для стробоскопов в машине",
            "PHASE5_MAIN_LOOP",
        )
        src = ph.replace_once(
            src,
            '    if not isModuleEnabled("mm_editor") or not mm_auto_format[0] then',
            '-- [[SWARM:PHASE5_ON_DIALOG]]\n    if not isModuleEnabled("mm_editor") or not mm_auto_format[0] then',
            "PHASE5_ON_DIALOG",
        )
        src = ph.replace_once(
            src,
            '        if hud_cache.wp_text ~= "" then\n            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35, 0.9, 1.0, 1.0))\n            imgui.TextUnformatted("GPS: " .. encodeCp1251Safe(hud_cache.wp_text))\n            imgui.PopStyleColor()\n        end',
            '        if hud_cache.wp_text ~= "" then\n            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.35, 0.9, 1.0, 1.0))\n            imgui.TextUnformatted("GPS: " .. encodeCp1251Safe(hud_cache.wp_text))\n            imgui.PopStyleColor()\n        end\n-- [[SWARM:PHASE5_HUD]]',
            "PHASE5_HUD",
        )
        src = ph.replace_once(
            src,
            "                restoreAllLights(car)\n            end\n        end\n    end)\nend",
            "                restoreAllLights(car)\n            end\n        end\n    end)\n-- [[SWARM:PHASE5_TERMINATE]]\nend",
            "PHASE5_TERMINATE",
        )

    for key, code in slots.items():
        marker = f"-- [[SWARM:{key}]]"
        code_crlf = code.replace("\r\n", "\n").replace("\n", "\r\n")
        assert src.count(marker) == 1, f"Marker {marker} missing in prepared source"
        src = src.replace(marker, code_crlf, 1)

    encoded = src.encode("cp1251")
    assert b"\x00" not in encoded, "NUL byte found in assembled CP1251 output!"
    for ln, b_line in enumerate(encoded.split(b"\r\n"), 1):
        for b in b_line:
            assert b >= 32 or b == 9, f"Unexpected control byte {b} at line {ln}"
    lf_only = src.count("\n") - src.count("\r\n")
    assert lf_only == 0, f"Bare LF line endings found: {lf_only}"

    src_lf = src.replace("\r\n", "\n")
    tokens = vh.lex_lua(src_lf)
    vh.check_lua_structure(tokens)
    vh.check_luajit_and_collisions(tokens, src_lf)
    vh.check_onframe_safety(src_lf)
    vh.test_autoedit(src_lf)
    vh.test_find_and_calc(src_lf)
    vh.test_v19_features(src_lf)
    vh.test_v20_features(src_lf)
    vh.test_v21_features(src_lf)
    test_phase5_features(src_lf)
    print("STANDALONE PHASE 5 INTEGRATION & VERIFY_HELPER SUITE PASSED 100%!")


if __name__ == "__main__":
    run_standalone_verification()
