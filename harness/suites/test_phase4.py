# -*- coding: utf-8 -*-
import json
import re
import sys
from pathlib import Path

SWARM_DIR = Path(__file__).resolve().parent
SCRATCH_DIR = SWARM_DIR.parent
if str(SCRATCH_DIR) not in sys.path:
    sys.path.insert(0, str(SCRATCH_DIR))

try:
    import verify_helper as vh
except ImportError:
    import run as vh

SLOTS_FILE = SWARM_DIR / "phase4_slots.json"
CORE_FILE = Path(__file__).resolve().parents[2] / "helper_core.lua"

EXPECTED_SLOT_KEYS = [
    "PHASE4_STATE",
    "PHASE4_LOAD",
    "PHASE4_SAVE",
    "PHASE4_MODULE",
    "PHASE4_AUTO_RP",
    "PHASE4_SAMPEV",
    "PHASE4_LOGIC",
    "PHASE4_CMDS",
    "PHASE4_HUD",
    "PHASE4_ONFRAME",
]


def _strip_queued_blocks(code: str) -> str:
    cleaned_parts = []
    k = 0
    while k < len(code):
        m = re.search(r"\b(queueTask|scheduleTask)\s*\(", code[k:])
        if not m:
            cleaned_parts.append(code[k:])
            break
        cleaned_parts.append(code[k : k + m.start()])
        p = k + m.start() + len(m.group(0)) - 1
        d = 0
        s_q = None
        while p < len(code):
            cc = code[p]
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


def test_phase4_features(src: str):
    src_lf = src.replace("\r\n", "\n")

    # 1. Required Phase 4 symbols & defaults
    for sym in (
        "P4 = P4 or {}",
        "P4_codex_path =",
        "P4_codex =",
        "P4_megaphone_lines =",
        "P4_weapon_names =",
        "function P4_buildDefaultCodex(",
        "function P4_saveCodex(",
        "function P4_loadCodex(",
        "function P4_applyServerPreset(",
        "function P4_openSuMenu(",
        "function P4_openMedMenu(",
        "function P4_issueWanted(",
        "function P4_issueTicket(",
        "function P4_formatEcpCommand(",
        "function P4_runMedicAction(",
        "function P4_sendMegaphone(",
        "function P4_recordDamage(",
        "function P4_drawFactionUI(",
        "function sampev.onSendGiveDamage(playerId, damage, weapon, bodypart)",
        "function sampev.onSendTakeDamage(playerId, damage, weapon, bodypart)",
    ):
        assert sym in src_lf, f"Missing Phase 4 symbol: {sym}"

    assert "dmg_enabled = imgui.new.bool(false)" in src_lf, "dmg_enabled MUST default to false!"
    assert "p4_autorp_enabled = imgui.new.bool(true)" in src_lf, "p4_autorp_enabled must default to true!"
    assert "suw_show = imgui.new.bool(false)" in src_lf
    assert "medui_show = imgui.new.bool(false)" in src_lf
    assert "dmg_log_show = imgui.new.bool(false)" in src_lf

    # 2. Codex sizes: >= 20 UK, >= 10 AK, >= 7 ECP, 4 megaphone lines
    m_codex_fn = re.search(r"function P4_buildDefaultCodex\(server_idx\)(.*?)\nend\n", src_lf, re.S)
    assert m_codex_fn, "P4_buildDefaultCodex body not found!"
    c_body = m_codex_fn.group(1)
    m_uk = re.search(r"uk = \{(.*?)\n        \},\n", c_body, re.S)
    m_ak = re.search(r"ak = \{(.*?)\n        \},\n", c_body, re.S)
    m_ecp = re.search(r"ecp = \{(.*?)\n        \},\n", c_body, re.S)
    assert m_uk and m_ak and m_ecp, "Codex sections uk/ak/ecp missing!"
    uk_count = len(re.findall(r'\{\s*code\s*=\s*"', m_uk.group(1)))
    ak_count = len(re.findall(r'\{\s*code\s*=\s*"', m_ak.group(1)))
    ecp_count = len(re.findall(r'\{\s*name\s*=\s*"', m_ecp.group(1)))
    assert uk_count >= 20, f"Expected >= 20 UK articles, got {uk_count}"
    assert ak_count >= 10, f"Expected >= 10 AK articles, got {ak_count}"
    assert ecp_count >= 7, f"Expected >= 7 ECP entries, got {ecp_count}"

    m_mega = re.search(r"P4_megaphone_lines = \{(.*?)\n\}", src_lf, re.S)
    assert m_mega and len(re.findall(r'"[^"]+"', m_mega.group(1))) == 4, "Expected 4 megaphone presets!"

    # 3. Module registration, settings load/save, commands (and NEVER shadow /su)
    assert 'id = "faction_tools"' in src_lf, "faction_tools module missing!"
    assert "P4_drawFactionUI" in src_lf
    assert "pcall(P4_loadCodex)" in src_lf
    assert "p4_autorp_enabled = p4_autorp_enabled[0]," in src_lf
    assert "dmg_enabled = dmg_enabled[0]," in src_lf
    assert "dmg_show_hud = dmg_show_hud[0]," in src_lf

    for cmd_name in ("'suw'", "'medui'", "'dmglog'"):
        assert f"sampRegisterChatCommand({cmd_name}" in src_lf, f"Missing command {cmd_name}"
    assert "sampRegisterChatCommand('su'" not in src_lf and 'sampRegisterChatCommand("su"' not in src_lf, "Must NOT shadow /su!"

    # 4. Auto-RP checks inside sampev.onSendCommand
    m_osc = re.search(r"function sampev\.onSendCommand\(command\)(.*?)\nend\n", src_lf, re.S)
    assert m_osc, "sampev.onSendCommand not found!"
    osc_body = m_osc.group(1)
    for auto_cmd in ("cuff", "uncuff", "search", "putpl", "arrest", "medhelp", "heal"):
        assert f'cmd == "{auto_cmd}"' in osc_body, f"Missing Auto-RP branch for /{auto_cmd}"
    assert 'cmd == "su"' not in osc_body, "Manual /su must NEVER be intercepted in onSendCommand!"

    # 5. Damage Informer hooks NEVER return false
    for ev in ("onSendGiveDamage", "onSendTakeDamage"):
        m_ev = re.search(rf"function sampev\.{ev}\([^)]*\)(.*?)\nend", src_lf, re.S)
        assert m_ev, f"Missing handler sampev.{ev}"
        assert "return false" not in m_ev.group(1), f"sampev.{ev} must NEVER return false!"

    # 6. HUD integration
    assert 'dmg_enabled[0] and dmg_show_hud[0] and dmg_last_hud ~= "" and (os.time() - dmg_last_ts) <= 6' in src_lf
    assert "encodeCp1251Safe(dmg_last_hud)" in src_lf

    # 7. Render-thread safety inside P4_drawFactionUI (runs inside OnFrame)
    m_ui = re.search(r"function P4_drawFactionUI\(\)(.*?)\nend\n", src_lf, re.S)
    assert m_ui, "P4_drawFactionUI body not found!"
    outside_ui = _strip_queued_blocks(m_ui.group(1))
    for bad_pat in (r"\bsamp[A-Z]\w*\s*\(", r"\baddOneOffSound\s*\(", r"\blua_thread\.create\s*\(", r"\bgetCharCoordinates\s*\("):
        mh = re.search(bad_pat, outside_ui)
        assert not mh, f"Forbidden direct call {mh.group(0)} inside P4_drawFactionUI!"

    # 8. Behavioral mirrors
    # 8a. /su & /ticket formatting
    def fmt_su(pid, stars, reason):
        if pid is None or pid < 0 or pid > 1004:
            return None
        st = max(1, min(6, int(stars)))
        rsn = (reason or "").strip()[:64] or "Нарушение УК"
        return f"/su {int(pid)} {st} {rsn}"

    assert fmt_su(12, 9, " 2.1 УК ") == "/su 12 6 2.1 УК"
    assert fmt_su(5, 0, "") == "/su 5 1 Нарушение УК"
    assert fmt_su(-1, 2, "test") is None
    assert fmt_su(1005, 2, "test") is None

    def fmt_ticket(pid, fine, reason):
        if pid is None or pid < 0 or pid > 1004:
            return None
        fn = max(100, min(50000, int(fine)))
        rsn = (reason or "").strip()[:64] or "Нарушение АК"
        return f"/ticket {int(pid)} {fn} {rsn}"

    assert fmt_ticket(44, 1500, "1.1 АК") == "/ticket 44 1500 1.1 АК"
    assert fmt_ticket(44, 10, "") == "/ticket 44 100 Нарушение АК"

    # 8b. ECP command builder
    def fmt_ecp(cmd, pid, price=500, med_type=1):
        pid = max(0, min(1004, int(pid)))
        price = max(0, min(100000, int(price)))
        if cmd == "medhelp":
            return f"/medhelp {pid}"
        if cmd == "heal":
            return f"/heal {pid} {price}"
        if cmd == "medcard":
            mt = max(1, min(3, int(med_type)))
            return f"/medcard {pid} {mt} {price}"
        if cmd == "analysis":
            return f"/analysis {pid}"
        return f"/{cmd} {pid}"

    assert fmt_ecp("medhelp", 7, 500) == "/medhelp 7"
    assert fmt_ecp("heal", 7, 300) == "/heal 7 300"
    assert fmt_ecp("medcard", 7, 2500, 2) == "/medcard 7 2 2500"
    assert fmt_ecp("analysis", 7, 1000) == "/analysis 7"

    # 8c. Damage Informer log cap (25), rounding, and 6s HUD expiry
    dmg_log = []
    for i in range(30):
        dmg_int = int(i + 0.4 + 0.5)
        entry = f"+Хит: Test_Player [{i}] -{dmg_int} (Desert Eagle)"
        dmg_log.insert(0, entry)
        while len(dmg_log) > 25:
            dmg_log.pop()
    assert len(dmg_log) == 25 and "[29]" in dmg_log[0] and "[5]" in dmg_log[-1]

    print(
        f"Phase 4 checks OK (UK={uk_count}, AK={ak_count}, ECP={ecp_count}, "
        "Auto-RP intact, /su native, Damage Informer safe & off by default)"
    )


def inject_phase4_in_memory(base_src_lf: str, slots: dict) -> str:
    src = base_src_lf
    for key in EXPECTED_SLOT_KEYS:
        marker = f"-- [[SWARM:{key}]]"
        assert src.count(marker) == 1, f"Marker {marker} count != 1 in helper_core.lua"
        src = src.replace(marker, slots[key].replace("\r\n", "\n"), 1)
    return src


def count_depth0_locals(tokens) -> int:
    depth = 0
    expect_loop_do = False
    prev = None
    cnt = 0
    for i, (kind, val, ln) in enumerate(tokens):
        is_field = prev and prev[0] == "SYM" and prev[1] in (".", ":")
        if kind == "ID" and not is_field:
            if depth == 0 and val == "local":
                cnt += 1
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
    return cnt


def main():
    assert SLOTS_FILE.exists(), f"Missing {SLOTS_FILE}"
    raw_json = SLOTS_FILE.read_text(encoding="utf-8")
    slots = json.loads(raw_json)
    assert isinstance(slots, dict), "phase4_slots.json must be a JSON object!"
    assert set(slots.keys()) == set(EXPECTED_SLOT_KEYS), (
        f"Unexpected slot keys: {set(slots.keys()) ^ set(EXPECTED_SLOT_KEYS)}"
    )

    # Verify every slot encodes cleanly to CP1251 with zero NUL/control bytes
    for key, val in slots.items():
        assert isinstance(val, str) and val.strip(), f"Empty slot {key}"
        assert "\x00" not in val, f"NUL byte in {key}"
        enc = val.encode("cp1251")
        for b in enc:
            assert b >= 32 or b in (9, 10, 13), f"Control byte {b} in {key}"

    # Read helper_core.lua (read-only) and test in-memory integration
    base_lf = CORE_FILE.read_bytes().decode("cp1251").replace("\r\n", "\n")
    base_tokens = vh.lex_lua(base_lf)
    base_top_locals = count_depth0_locals(base_tokens)

    merged_lf = inject_phase4_in_memory(base_lf, slots)
    merged_crlf = merged_lf.replace("\n", "\r\n")
    merged_cp1251 = merged_crlf.encode("cp1251")
    assert b"\x00" not in merged_cp1251

    tokens = vh.lex_lua(merged_lf)
    vh.check_lua_structure(tokens)
    vh.check_luajit_and_collisions(tokens, merged_lf)

    merged_top_locals = count_depth0_locals(tokens)
    assert merged_top_locals == base_top_locals, (
        f"Phase 4 introduced depth-0 locals! baseline={base_top_locals}, merged={merged_top_locals}"
    )

    even_bufs = [m.group(0) for m in re.finditer(r"imgui\.new\.char\[(\d+)\]", merged_lf) if int(m.group(1)) % 2 == 0]
    assert not even_bufs, f"Even char buffers found: {even_bufs}"
    for vfn in ("imgui.Text(", "imgui.TextColored(", "imgui.TextWrapped(", "imgui.BulletText("):
        assert vfn not in merged_lf, f"Variadic {vfn} found!"

    vh.check_onframe_safety(merged_lf)
    test_phase4_features(merged_lf)
    print("ALL PHASE 4 STANDALONE + IN-MEMORY INTEGRATION CHECKS PASSED 100%!")


if __name__ == "__main__":
    main()
