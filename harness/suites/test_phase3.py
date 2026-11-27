# -*- coding: utf-8 -*-
import datetime
import json
import re
import sys
from pathlib import Path

SWARM_DIR = Path(__file__).resolve().parent
SLOTS_PATH = SWARM_DIR / "phase3_slots.json"
CORE_PATH = Path(__file__).resolve().parents[2] / "helper_core.lua"
SCRATCH_ROOT = SWARM_DIR.parent

EXPECTED_SLOTS = {
    "PHASE3_STATE",
    "PHASE3_LOAD",
    "PHASE3_SAVE",
    "PHASE3_GNEWS_UI",
    "PHASE3_MODULE",
    "PHASE3_LOGIC",
    "PHASE3_CMDS",
    "PHASE3_TICK_1S",
    "PHASE3_HUD",
}


def _strip_task_calls(lua_block: str) -> str:
    """Remove queueTask(...) and scheduleTask(...) argument bodies for render-thread checks."""
    cleaned_parts = []
    k = 0
    while k < len(lua_block):
        m = re.search(r"\b(queueTask|scheduleTask)\s*\(", lua_block[k:])
        if not m:
            cleaned_parts.append(lua_block[k:])
            break
        cleaned_parts.append(lua_block[k : k + m.start()])
        p = k + m.start() + len(m.group(0)) - 1
        d = 0
        s_q = None
        while p < len(lua_block):
            cc = lua_block[p]
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
    return "".join(cleaned_parts)


def _extract_lua_function(src_lf: str, func_name: str) -> str:
    m = re.search(rf"(?m)^function\s+{re.escape(func_name)}\s*\(", src_lf)
    assert m, f"Function {func_name} not found!"
    lines = src_lf[m.start() :].split("\n")
    out = []
    for ln in lines:
        out.append(ln)
        if ln == "end":
            break
    return "\n".join(out)


def _count_depth0_locals(snippet_lf: str) -> list:
    if str(SCRATCH_ROOT) not in sys.path:
        sys.path.insert(0, str(SCRATCH_ROOT))
    try:
        import verify_helper as vh
    except ImportError:
        import run as vh

    toks = vh.lex_lua(snippet_lf)
    depth = 0
    expect_loop_do = False
    prev = None
    found = []
    for i, (kind, val, ln) in enumerate(toks):
        is_field = prev and prev[0] == "SYM" and prev[1] in (".", ":")
        if kind == "ID" and not is_field:
            if depth == 0 and val == "local":
                nxt = toks[i + 1][1] if i + 1 < len(toks) else "?"
                found.append((ln, nxt))
            if val in ("function", "if", "repeat"):
                depth += 1
            elif val in ("for", "while"):
                depth += 1
                expect_loop_do = True
            elif val == "do":
                if expect_loop_do:
                    expect_loop_do = False
                else:
                    depth += 1
            elif val in ("end", "until"):
                depth -= 1
        prev = (kind, val, ln)
    return found


def test_phase3_features(src: str):
    src_lf = src.replace("\r\n", "\n")

    # 1. Required Phase 3 symbols and functions
    required_symbols = [
        "P3 = P3 or {}",
        "gnews_sched_time_buf = imgui.new.char[17]",
        "gnews_sched_active = false",
        "gnews_sched_target_ts = nil",
        "gnews_sched_target_str = \"\"",
        "gnews_sched_warned_15 = false",
        "gnews_l_template_buf = imgui.new.char[129]",
        "gnews_sched_hud_str = \"\"",
        "P3_lecturer_path =",
        "P3_lecturer_templates =",
        "lect_selected = 1",
        "lect_delay_ms = imgui.new.int(2000)",
        "lect_running = false",
        "lect_paused = false",
        "lect_step = 0",
        "lect_total = 0",
        "lect_name_buf = imgui.new.char[65]",
        "lect_text_buf = imgui.new.char[4097]",
        "lect_loaded_idx = -1",
        "function P3_parseNextScheduleTs(",
        "function P3_scheduleGnews(",
        "function P3_cancelGnewsSchedule(",
        "function P3_sendGnewsBookingL(",
        "function P3_startLecturer(",
        "function P3_stopLecturer(",
        "function P3_togglePauseLecturer(",
        "function P3_saveLecturer(",
        "function P3_loadLecturer(",
        "function P3_drawLecturerUI(",
        "function P3_cmdLect(",
    ]
    for sym in required_symbols:
        assert sym in src_lf, f"Missing Phase 3 symbol: {sym}"

    # 2. Odd char[N] buffers & zero variadic ImGui text functions
    even_bufs = [
        m.group(0)
        for m in re.finditer(r"imgui\.new\.char\[(\d+)\]", src_lf)
        if int(m.group(1)) % 2 == 0
    ]
    assert not even_bufs, f"Even char buffers found: {even_bufs}"
    for vfn in ("imgui.Text(", "imgui.TextColored(", "imgui.TextWrapped(", "imgui.BulletText(", "imgui.CenterColumnText"):
        assert vfn not in src_lf, f"Forbidden ImGui call {vfn} found!"

    # 3. Module registration and deferred drawSettings
    m_mod = re.search(r'id\s*=\s*"lecturer".*?onToggle\s*=\s*function\(state\)\s*end\s*\}', src_lf, re.S)
    assert m_mod, "Lecturer module missing from modules table!"
    mod_txt = m_mod.group(0)
    assert "P3_drawLecturerUI" in mod_txt
    assert "drawSettings = function()" in mod_txt, "Lecturer drawSettings must defer P3_drawLecturerUI lookup!"

    # 4. Persistence hooks & chat commands & 1s tick & HUD
    assert "gnews_l_template = decodeUtf8Safe(ffi.string(gnews_l_template_buf))," in src_lf
    assert "lect_delay_ms = lect_delay_ms[0]," in src_lf
    assert "parsed.gnews_l_template" in src_lf and "parsed.lect_delay_ms" in src_lf
    assert "pcall(P3_loadLecturer)" in src_lf
    assert "sampRegisterChatCommand('lect', P3_cmdLect)" in src_lf
    assert "sampRegisterChatCommand('lectstop', P3_stopLecturer)" in src_lf

    assert "playAlertSound(1058)" in src_lf
    assert "gnewsPublishLines(lines, gnews_settings.delay or 1500)" in src_lf
    assert 'imgui.TextUnformatted(encodeCp1251Safe(gnews_sched_hud_str))' in src_lf

    # 5. Render-thread safety inside drawGnewsSettings() and P3_drawLecturerUI()
    for fn_name in ("drawGnewsSettings", "P3_drawLecturerUI"):
        fn_body = _extract_lua_function(src_lf, fn_name)
        outside = _strip_task_calls(fn_body)
        for bad_pat in (
            r"\bsamp[A-Z]\w*\s*\(",
            r"\blua_thread\.create\s*\(",
            r"\baddOneOffSound\s*\(",
            r"\bplayAlertSound\s*\(",
            r"\bP3_scheduleGnews\s*\(",
            r"\bP3_cancelGnewsSchedule\s*\(",
            r"\bP3_sendGnewsBookingL\s*\(",
            r"\bP3_startLecturer\s*\(",
            r"\bP3_stopLecturer\s*\(",
            r"\bP3_togglePauseLecturer\s*\(",
            r"\bP3_saveLecturer\s*\(",
        ):
            mh = re.search(bad_pat, outside)
            assert not mh, f"Unsafe direct call {mh.group(0)} inside {fn_name}() outside queueTask!"

    # 6. Validate P3_default_lecturer_templates invariants directly from Lua source
    m_tpls = re.search(r"P3_default_lecturer_templates\s*=\s*\{(.*?)\n\}\n", src_lf, re.S)
    assert m_tpls, "P3_default_lecturer_templates block not found!"
    tpl_entries = re.findall(
        r'name\s*=\s*"((?:[^"\\]|\\.)*)"\s*,\s*text\s*=\s*"((?:[^"\\]|\\.)*)"',
        m_tpls.group(1),
        re.S,
    )
    assert len(tpl_entries) >= 7, f"Expected >=7 lecturer templates, got {len(tpl_entries)}"
    seen_names = set()
    has_pause0 = False
    for raw_name, raw_text in tpl_entries:
        name = raw_name.replace('\\"', '"').replace("\\\\", "\\")
        text = raw_text.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")
        assert name.strip(), "Empty template name!"
        assert name.lower() not in seen_names, f"Duplicate template name: {name}"
        seen_names.add(name.lower())
        name.encode("cp1251")
        text.encode("cp1251")
        assert len(name.encode("utf-8")) <= 64, f"Template name exceeds lect_name_buf (64 bytes): {name!r}"
        assert len(text.encode("utf-8")) <= 2048, f"Template text exceeds lect_text_buf (2048 bytes): {name!r}"
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        assert len(lines) >= 3, f"Template {name!r} too short!"
        for ln in lines:
            if ln == "<0>":
                has_pause0 = True
            elif not re.fullmatch(r"<\d+>", ln):
                assert len(ln) <= 120, f"Speech line too long ({len(ln)} chars) in {name!r}: {ln!r}"
    assert has_pause0, "Expected at least one <0> interactive pause token in default templates!"

    # 7. Behavioral mirror: P3_parseNextScheduleTs(hhmmss, now_ts)
    def py_parse_next_schedule_ts(hhmmss, now_ts):
        if not isinstance(hhmmss, str):
            return None, "Введите время в формате ЧЧ:ММ:СС"
        clean = hhmmss.strip()
        m = re.fullmatch(r"(\d{1,2}):(\d{2}):(\d{2})", clean)
        if not m:
            return None, "Неверный формат! Используйте ЧЧ:ММ:СС (напр. 18:30:00)"
        h, mi, s = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if not (0 <= h <= 23 and 0 <= mi <= 59 and 0 <= s <= 59):
            return None, "Неверное время! Часы 0-23, мин/сек 0-59"
        base_dt = datetime.datetime.fromtimestamp(now_ts)
        target_dt = base_dt.replace(hour=h, minute=mi, second=s, microsecond=0)
        target_ts = int(target_dt.timestamp())
        if target_ts <= now_ts:
            target_ts += 86400
        return target_ts, None

    base = int(datetime.datetime(2026, 11, 26, 18, 29, 0).timestamp())
    ts_future, err_f = py_parse_next_schedule_ts("18:30:00", base)
    assert err_f is None and ts_future == base + 60
    ts_exact, err_e = py_parse_next_schedule_ts("18:29:00", base)
    assert err_e is None and ts_exact == base + 86400
    ts_past, err_p = py_parse_next_schedule_ts("18:28:59", base)
    assert err_p is None and ts_past == base + 86399
    ts_padded, err_pad = py_parse_next_schedule_ts(" 9:05:00 ", int(datetime.datetime(2026, 11, 26, 8, 0, 0).timestamp()))
    assert err_pad is None and ts_padded == int(datetime.datetime(2026, 11, 26, 9, 5, 0).timestamp())
    ts_midnight, err_mid = py_parse_next_schedule_ts("00:00:00", int(datetime.datetime(2026, 11, 26, 23, 59, 50).timestamp()))
    assert err_mid is None and ts_midnight == int(datetime.datetime(2026, 11, 27, 0, 0, 0).timestamp())
    for bad in ("", None, "abc", "18:30", "24:00:00", "12:60:00", "12:00:60", "12:3:00", "-1:00:00"):
        ts_b, err_b = py_parse_next_schedule_ts(bad, base)
        assert ts_b is None and isinstance(err_b, str) and len(err_b) > 0, f"Should reject {bad!r}"

    # 8. Behavioral mirror: P3_formatBookingText & P3_parseLectureSteps
    def py_format_booking_text(tpl: str, tag: str, hhmm: str) -> str:
        s = (tpl or "").strip() or "[%s] Занимаю волну гос. новостей на %s."
        s = s.replace("{tag}", tag or "ГОС").replace("{time}", hhmm or "00:00")
        cnt = s.count("%s")
        if cnt >= 2:
            s = s.replace("%s", tag or "ГОС", 1).replace("%s", hhmm or "00:00", 1).replace("%s", "")
        elif cnt == 1:
            if re.search(r"\[\s*%s\s*\]", s):
                s = s.replace("%s", tag or "ГОС", 1)
            else:
                s = s.replace("%s", hhmm or "00:00", 1)
        if s[:3].lower() == "/l ":
            s = s[3:]
        return s

    assert py_format_booking_text("[%s] Занимаю волну гос. новостей на %s.", "LS", "18:30") == "[LS] Занимаю волну гос. новостей на 18:30."
    assert py_format_booking_text("Занимаю волну на %s (100%)", "LS", "18:30") == "Занимаю волну на 18:30 (100%)"
    assert py_format_booking_text("/l [Мэрия ЛС] Волна на %s", "Мэрия ЛС", "19:00") == "[Мэрия ЛС] Волна на 19:00"

    def py_parse_lecture_steps(raw_text: str):
        norm = raw_text.replace("\r\n", "\n").replace("\r", "\n")
        steps = []
        speech = 0
        for ln in norm.split("\n"):
            tr = ln.strip()
            if not tr:
                continue
            mm = re.fullmatch(r"<(\d+)>", tr)
            if mm:
                ms = int(mm.group(1))
                steps.append(("pause0", 0) if ms == 0 else ("wait", max(50, min(60000, ms))))
            else:
                steps.append(("say", tr))
                speech += 1
        return steps, speech

    st_res, st_cnt = py_parse_lecture_steps("Первая строка\r\n\r\n<0>\r\n<1200>\r\nВторая строка\r\n")
    assert st_cnt == 2 and st_res == [("say", "Первая строка"), ("pause0", 0), ("wait", 1200), ("say", "Вторая строка")]

    print(f"Phase 3 checks OK ({len(tpl_entries)} default templates, scheduler, /l booking, /lect & /lectstop, HUD, ImGui safety)")


def main():
    assert SLOTS_PATH.exists(), f"Missing {SLOTS_PATH}"
    slots = json.loads(SLOTS_PATH.read_text(encoding="utf-8"))
    assert set(slots.keys()) == EXPECTED_SLOTS, f"Slot mismatch: got {set(slots.keys())}"

    for key, val in slots.items():
        assert isinstance(val, str) and val.strip(), f"Slot {key} must be non-empty string"
        assert "\x00" not in val, f"NUL byte in {key}"
        val.encode("cp1251")
        for b in val.encode("cp1251"):
            assert b >= 32 or b in (9, 10, 13), f"Control byte {b} in {key}"

    assert slots["PHASE3_MODULE"].lstrip().startswith(","), "PHASE3_MODULE must start with ','"
    assert not slots["PHASE3_MODULE"].rstrip().endswith(","), "PHASE3_MODULE must not end with ','"
    for ln in [x.strip() for x in slots["PHASE3_SAVE"].splitlines() if x.strip()]:
        assert ln.endswith(","), f"PHASE3_SAVE line must end with ',': {ln!r}"

    for top_slot in ("PHASE3_STATE", "PHASE3_LOGIC"):
        top_locals = _count_depth0_locals(slots[top_slot])
        assert not top_locals, f"Top-level local declarations forbidden in {top_slot}: {top_locals}"

    # Read-only in-memory integration test against helper_core.lua
    assert CORE_PATH.exists(), f"Missing {CORE_PATH}"
    core_src = CORE_PATH.read_bytes().decode("cp1251")
    for key, code in slots.items():
        marker = f"-- [[SWARM:{key}]]"
        assert core_src.count(marker) == 1, f"Marker {marker} count != 1 in helper_core.lua"
        core_src = core_src.replace(marker, code.replace("\r\n", "\n").replace("\n", "\r\n"), 1)

    core_src_lf = core_src.replace("\r\n", "\n")

    if str(SCRATCH_ROOT) not in sys.path:
        sys.path.insert(0, str(SCRATCH_ROOT))
    try:
        import verify_helper as vh
    except ImportError:
        import run as vh

    tokens = vh.lex_lua(core_src_lf)
    vh.check_lua_structure(tokens)
    vh.check_luajit_and_collisions(tokens, core_src_lf)
    vh.check_onframe_safety(core_src_lf)
    test_phase3_features(core_src_lf)
    print("ALL PHASE 3 STANDALONE & IN-MEMORY INTEGRATION CHECKS PASSED!")


if __name__ == "__main__":
    main()
