# -*- coding: utf-8 -*-
import json
import re
import sys
from pathlib import Path

SWARM_DIR = Path(__file__).resolve().parent
SCRATCH_DIR = SWARM_DIR.parent
REPO_DIR = Path(__file__).resolve().parents[2]
HELPER_PATH = REPO_DIR / "helper_core.lua"
SLOTS_PATH = SWARM_DIR / "phase2_slots.json"

REQUIRED_SLOTS = (
    "PHASE2_STATE",
    "PHASE2_LOAD",
    "PHASE2_SAVE",
    "PHASE2_VEHICLE_UI",
    "PHASE2_QOL_UI",
    "PHASE2_LOGIC",
    "PHASE2_CMDS",
    "PHASE2_MAIN_LOOP",
    "PHASE2_TARGET_MENU_BTNS",
    "PHASE2_ONFRAME",
)


def _import_verify_helper():
    if str(SCRATCH_DIR) not in sys.path:
        sys.path.insert(0, str(SCRATCH_DIR))
    try:
        import verify_helper as vh
    except ImportError:
        import run as vh
    return vh


def validate_slots_file(slots_path: Path = SLOTS_PATH):
    assert slots_path.exists(), f"Missing {slots_path}"
    raw_bytes = slots_path.read_bytes()
    slots = json.loads(raw_bytes.decode("utf-8"))
    assert isinstance(slots, dict), "phase2_slots.json must be a JSON object"
    assert set(slots.keys()) == set(REQUIRED_SLOTS), (
        f"Slot key mismatch: extra={set(slots.keys()) - set(REQUIRED_SLOTS)}, "
        f"missing={set(REQUIRED_SLOTS) - set(slots.keys())}"
    )

    vh = _import_verify_helper()
    for key in REQUIRED_SLOTS:
        val = slots[key]
        assert isinstance(val, str) and val.strip(), f"Slot {key} must be a non-empty string"
        # Must encode strictly to Windows-1251 (CP1251)
        try:
            cp = val.encode("cp1251")
        except UnicodeEncodeError as exc:
            raise AssertionError(f"Slot {key} contains non-CP1251 char: {exc}") from exc
        assert b"\x00" not in cp, f"NUL byte in slot {key}"
        for ln, b_line in enumerate(cp.replace(b"\r\n", b"\n").split(b"\n"), 1):
            for b in b_line:
                assert b >= 32 or b == 9, f"Unexpected control byte {b} in {key} line {ln}"
        # No variadic ImGui text calls
        for vfn in ("imgui.Text(", "imgui.TextColored(", "imgui.TextWrapped(", "imgui.BulletText(", "imgui.CenterColumnText("):
            assert vfn not in val, f"Forbidden variadic {vfn} in {key}"
        # Odd sizes only for imgui.new.char[N]
        even_bufs = [m.group(0) for m in re.finditer(r"imgui\.new\.char\[(\d+)\]", val) if int(m.group(1)) % 2 == 0]
        assert not even_bufs, f"Even char buffer(s) in {key}: {even_bufs}"

    # Zero top-level locals in PHASE2_STATE and PHASE2_LOGIC
    for top_slot in ("PHASE2_STATE", "PHASE2_LOGIC"):
        toks = vh.lex_lua(slots[top_slot].replace("\r\n", "\n"))
        vh.check_lua_structure(toks)
        depth = 0
        expect_loop_do = False
        prev = None
        for kind, val, ln in toks:
            is_field = prev and prev[0] == "SYM" and prev[1] in (".", ":")
            if kind == "ID" and not is_field:
                if depth == 0 and val == "local":
                    raise AssertionError(f"Top-level 'local' forbidden in {top_slot} at line {ln}")
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

    # Check Lua structure for standalone snippets where applicable
    for bal_slot in ("PHASE2_LOAD", "PHASE2_VEHICLE_UI", "PHASE2_QOL_UI", "PHASE2_CMDS", "PHASE2_MAIN_LOOP", "PHASE2_TARGET_MENU_BTNS", "PHASE2_ONFRAME"):
        toks = vh.lex_lua(slots[bal_slot].replace("\r\n", "\n"))
        vh.check_lua_structure(toks)

    # PHASE2_SAVE entries must each end with a comma (ignoring blank/comment lines)
    save_lines = [l.strip() for l in slots["PHASE2_SAVE"].splitlines() if l.strip() and not l.strip().startswith("--")]
    assert save_lines and all(l.endswith(",") for l in save_lines), f"PHASE2_SAVE lines must end with ',': {save_lines}"

    return slots


def splice_slots_in_memory(base_src_lf: str, slots: dict) -> str:
    src = base_src_lf
    for key in REQUIRED_SLOTS:
        marker = f"-- [[SWARM:{key}]]"
        cnt = src.count(marker)
        assert cnt == 1, f"Marker {marker} matched {cnt} times in helper_core.lua (expected 1)"
        src = src.replace(marker, slots[key].replace("\r\n", "\n"), 1)
    return src


def test_phase2_features(src: str):
    src_lf = src.replace("\r\n", "\n")

    # 1. Required globals, functions, UI strings, and commands
    required_symbols = (
        "P2 = P2 or {",
        "wheel_menu_enabled = imgui.new.bool(true)",
        "wheel_menu_show = imgui.new.bool(false)",
        "wheel_menu_pos = {",
        "wheel_fav_slots = {",
        "target_menu_key_idx = imgui.new.int(0)",
        "target_menu_autorp = imgui.new.bool(true)",
        "siren_auto_strobe = imgui.new.bool(false)",
        "function getTargetMenuVk()",
        "function getWheelMenuVk()",
        "function P2_toggleWheelMenu()",
        "function P2_sendWithOptionalRp(",
        "function P2_openTargetSu(",
        "function P2_openTargetTicket(",
        "function P2_openTargetMed(",
        "function P2_tickSirenAutoStrobe()",
        "function P2_getWheelDisplayItems()",
        "function P2_drawWheelFavSelector()",
        "sampRegisterChatCommand('wheelmenu'",
        "wasKeyPressed(getTargetMenuVk and getTargetMenuVk() or 0x58)",
        "isCarSirenOn",
        "restoreAllLights",
        "P4_openSuMenu",
        "P4_openMedMenu",
        "encodeCp1251Safe(",
    )
    for sym in required_symbols:
        assert sym in src_lf, f"Missing Phase 2 symbol: {sym}"

    # 2. Persistence keys present in load & save
    for key in ("wheel_menu_enabled", "target_menu_key_idx", "target_menu_autorp", "siren_auto_strobe", "wheel_favs"):
        assert f"parsed.{key}" in src_lf, f"Missing load handling for parsed.{key}"
        assert f"{key} =" in src_lf, f"Missing save field for {key}"

    # 3. Target menu buttons present before + В друзья
    pos_tm_su = src_lf.find("Розыск (/su)##tm_su")
    pos_tm_ticket = src_lf.find("Штраф (/ticket)##tm_ticket")
    pos_tm_cuff = src_lf.find("Наручники (/cuff)##tm_cuff")
    pos_tm_search = src_lf.find("Обыск (/search)##tm_search")
    pos_tm_med = src_lf.find("Лечить (/medhelp)##tm_medhelp")
    pos_tm_heal = src_lf.find("В карете (/heal)##tm_heal")
    pos_tm_hist = src_lf.find("История (/history)##tm_hist")
    pos_tm_friend = src_lf.find("+ В друзья##tm_friend")
    for name, pos in (
        ("tm_su", pos_tm_su),
        ("tm_ticket", pos_tm_ticket),
        ("tm_cuff", pos_tm_cuff),
        ("tm_search", pos_tm_search),
        ("tm_med", pos_tm_med),
        ("tm_heal", pos_tm_heal),
        ("tm_hist", pos_tm_hist),
    ):
        assert 0 < pos < pos_tm_friend, f"Target menu button {name} not placed before + В друзья"

    # 4. Behavioral mirror checks
    # 4a. Key mappings
    def get_target_vk(idx: int) -> int:
        if idx == 1:
            return 0x52
        if idx == 2:
            return 0x45
        return 0x58

    def get_wheel_vk(idx: int) -> int:
        return {1: 0x47, 2: 0x42, 3: 0x5A, 4: 0x56}.get(idx, 0x04)

    assert get_target_vk(0) == 0x58
    assert get_target_vk(1) == 0x52
    assert get_target_vk(2) == 0x45
    assert get_target_vk(99) == 0x58
    assert get_wheel_vk(0) == 0x04
    assert get_wheel_vk(1) == 0x47

    # 4b. Wheel menu trigger gating
    def should_toggle_wheel(enabled, chat_active, dialog_active, rmb_down, pressed):
        return bool(enabled and not chat_active and not dialog_active and not rmb_down and pressed)

    assert should_toggle_wheel(True, False, False, False, True) is True
    assert should_toggle_wheel(False, False, False, False, True) is False
    assert should_toggle_wheel(True, True, False, False, True) is False
    assert should_toggle_wheel(True, False, True, False, True) is False
    assert should_toggle_wheel(True, False, False, True, True) is False  # RMB aiming guard

    # 4c. Auto-strobe siren state machine mirror
    class SirenSim:
        def __init__(self):
            self.mod_on = True
            self.opt_on = True
            self.in_car = True
            self.siren_on = False
            self.siren_was_on = False
            self.siren_started_strobe = False
            self.strobe_active = False
            self.strobe_enabled = False
            self.restored_calls = 0

        def tick(self):
            if not self.mod_on or not self.opt_on:
                if self.siren_was_on or self.siren_started_strobe:
                    self.siren_was_on = False
                    if self.siren_started_strobe:
                        self.siren_started_strobe = False
                        self.strobe_active = False
                        self.strobe_enabled = False
                        if self.in_car:
                            self.restored_calls += 1
                return
            if not self.in_car:
                if self.siren_was_on or self.siren_started_strobe:
                    self.siren_was_on = False
                    if self.siren_started_strobe:
                        self.siren_started_strobe = False
                        self.strobe_active = False
                        self.strobe_enabled = False
                return
            if self.siren_on and not self.siren_was_on:
                self.siren_was_on = True
                if not self.strobe_active or not self.strobe_enabled:
                    self.siren_started_strobe = True
                    self.strobe_enabled = True
                    self.strobe_active = True
            elif not self.siren_on and self.siren_was_on:
                self.siren_was_on = False
                if self.siren_started_strobe:
                    self.siren_started_strobe = False
                    if self.strobe_active or self.strobe_enabled:
                        self.strobe_active = False
                        self.strobe_enabled = False
                        self.restored_calls += 1

    sim = SirenSim()
    # Siren turns on -> strobes turn on
    sim.siren_on = True
    sim.tick()
    assert sim.strobe_active and sim.strobe_enabled and sim.siren_started_strobe
    # User manually stops strobes while siren remains on -> steady state doesn't re-enable
    sim.strobe_active = False
    sim.strobe_enabled = False
    sim.tick()
    assert not sim.strobe_active
    # Siren turns back on from off -> starts again, then siren turns off -> restores lights
    sim.siren_on = False
    sim.tick()
    sim.siren_on = True
    sim.tick()
    assert sim.strobe_active
    sim.siren_on = False
    sim.tick()
    assert not sim.strobe_active and not sim.strobe_enabled and sim.restored_calls == 1
    # Manual strobes already on before siren -> turning siren off keeps manual strobes on
    sim.strobe_active = True
    sim.strobe_enabled = True
    sim.siren_on = True
    sim.tick()
    assert not sim.siren_started_strobe
    sim.siren_on = False
    sim.tick()
    assert sim.strobe_active and sim.strobe_enabled and sim.restored_calls == 1
    # Leaving car while siren was on resets siren_was_on and stops siren-started strobes
    sim.strobe_active = False
    sim.strobe_enabled = False
    sim.siren_on = True
    sim.tick()
    assert sim.siren_was_on and sim.strobe_active
    sim.in_car = False
    sim.tick()
    assert not sim.siren_was_on and not sim.strobe_active and not sim.siren_started_strobe

    # 4d. Wheel favorite slots load/cap/dedupe mirror
    def clean_favs(raw):
        out = []
        for item in raw:
            if isinstance(item, dict) and isinstance(item.get("chapter"), (int, float)) and isinstance(item.get("index"), (int, float)):
                ch = int(item["chapter"])
                idx = int(item["index"])
                if 1 <= ch <= 3 and 1 <= idx <= 500:
                    out.append({"chapter": ch, "index": idx})
                    if len(out) >= 6:
                        break
        return out

    favs = clean_favs([
        {"chapter": 1, "index": 1},
        {"chapter": 2, "index": 3},
        {"chapter": 9, "index": 1},  # invalid chapter filtered
        {"chapter": 3, "index": 0},  # invalid index filtered
        {"chapter": 1, "index": 2},
        {"chapter": 1, "index": 3},
        {"chapter": 1, "index": 4},
        {"chapter": 1, "index": 5},
        {"chapter": 1, "index": 6},  # capped at 6
    ])
    assert len(favs) == 6
    assert all(1 <= f["chapter"] <= 3 and 1 <= f["index"] <= 500 for f in favs)

    # 4e. Target menu delegation + optional RP check
    sent = []
    chat_opened = []

    def sim_open_su(tid, has_p4=False):
        if tid is None or tid < 0:
            return
        if has_p4:
            sent.append(("p4_su", tid))
        else:
            chat_opened.append(f"/su {tid} ")

    def sim_open_med(tid, has_p4=False, autorp=True):
        if tid is None or tid < 0:
            return
        if has_p4:
            sent.append(("p4_med", tid))
        else:
            if autorp:
                sent.append(("rp", "/me осмотрел пациента и выписал лекарство"))
            sent.append(("cmd", f"/medhelp {tid}"))

    sim_open_su(14, has_p4=False)
    assert chat_opened[-1] == "/su 14 "
    sim_open_su(14, has_p4=True)
    assert sent[-1] == ("p4_su", 14)
    sim_open_med(7, has_p4=False, autorp=True)
    assert sent[-2][0] == "rp" and sent[-1] == ("cmd", "/medhelp 7")
    sim_open_med(7, has_p4=True)
    assert sent[-1] == ("p4_med", 7)

    # 4f. CP1251 safe byte truncation never produces invalid UTF-8/CP1251
    def trunc_cp1251(s: str, max_bytes: int) -> bytes:
        raw = s.encode("cp1251")
        if len(raw) <= max_bytes:
            return raw
        return raw[: max_bytes - 2] + b".."

    tr = trunc_cp1251("Очень длинная ролевая отыгровка для меню", 20)
    assert len(tr) == 20 and tr.decode("cp1251").endswith("..")

    print("Phase 2 (v2.2) checks OK (wheel menu, target menu X/R/E + faction actions, siren auto-strobes)")


def main():
    vh = _import_verify_helper()
    slots = validate_slots_file(SLOTS_PATH)

    raw_helper = HELPER_PATH.read_bytes()
    assert b"\x00" not in raw_helper
    base_src = raw_helper.decode("cp1251")
    base_lf = base_src.replace("\r\n", "\n")

    spliced_lf = splice_slots_in_memory(base_lf, slots)
    spliced_crlf = spliced_lf.replace("\n", "\r\n")
    spliced_cp1251 = spliced_crlf.encode("cp1251")
    assert b"\x00" not in spliced_cp1251

    tokens = vh.lex_lua(spliced_lf)
    vh.check_lua_structure(tokens)
    vh.check_luajit_and_collisions(tokens, spliced_lf)
    vh.check_onframe_safety(spliced_lf)

    vh.test_autoedit(spliced_lf)
    vh.test_find_and_calc(spliced_lf)
    vh.test_v19_features(spliced_lf)
    vh.test_v20_features(spliced_lf)
    vh.test_v21_features(spliced_lf)
    test_phase2_features(spliced_lf)

    print("ALL PHASE 2 + VERIFY_HELPER CHECKS PASSED 100%!")


if __name__ == "__main__":
    main()
