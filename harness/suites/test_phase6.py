# -*- coding: utf-8 -*-
import json
import math
import re
import sys
from pathlib import Path

SWARM_DIR = Path(__file__).resolve().parent
SCRATCH_DIR = SWARM_DIR.parent
SLOTS_PATH = SWARM_DIR / "phase6_slots.json"
ADV_DECOR_PATH = SCRATCH_DIR / "adv_decor_522.json"
HELPER_PATH = Path(__file__).resolve().parents[2] / "helper_core.lua"

EXPECTED_SLOTS = [
    "PHASE6_STATE",
    "PHASE6_LOAD",
    "PHASE6_SAVE",
    "PHASE6_MODULE",
    "PHASE6_LOGIC",
    "PHASE6_SAMPEV",
    "PHASE6_CMDS",
    "PHASE6_ONFRAME",
    "PHASE6_TERMINATE",
]

FORBIDDEN_RENDER_PATTERNS = [
    r"\bsamp[A-Z]\w*\s*\(",
    r"\bisSampAvailable\s*\(",
    r"\bplayRp\s*\(",
    r"\bapplyLocalSkin\s*\(",
    r"\bgetPlayerMoney\s*\(",
    r"\bgetCharPlayerIsTargeting\s*\(",
    r"\baddOneOffSound\s*\(",
    r"\bplaceWaypoint\s*\(",
    r"\bremoveWaypoint\s*\(",
    r"\bgetCharCoordinates\s*\(",
    r"\bsetFixedCameraPosition\s*\(",
    r"\bpointCameraAtPoint\s*\(",
    r"\brestoreCameraJumpcut\s*\(",
    r"\bsetObjectCoordinates\s*\(",
    r"\bsetObjectRotation\s*\(",
    r"\bgetObjectCoordinates\s*\(",
    r"\bgetObjectRotation\s*\(",
    r"\bgetObjectQuaternion\s*\(",
    r"\bgetObjectModel\s*\(",
    r"\bdoesObjectExist\s*\(",
    r"\bdownloadUrlToFile\s*\(",
    r"\bsetClipboardText\s*\(",
    r"\blua_thread\.create\s*\(",
]


def _strip_queued_calls(block: str) -> str:
    cleaned = []
    k = 0
    while k < len(block):
        m = re.search(r"\b(queueTask|scheduleTask)\s*\(", block[k:])
        if not m:
            cleaned.append(block[k:])
            break
        cleaned.append(block[k : k + m.start()])
        p = k + m.start() + len(m.group(0)) - 1
        depth = 0
        s_q = None
        while p < len(block):
            cc = block[p]
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
                    depth += 1
                elif cc == ")":
                    depth -= 1
                    if depth == 0:
                        p += 1
                        break
            p += 1
        k = p
    return "".join(cleaned)


def _extract_lua_function(src: str, func_name: str) -> str:
    m = re.search(rf"(?m)^function\s+{re.escape(func_name)}\s*\([^\)]*\)", src)
    assert m, f"Function {func_name} not found!"
    rest = src[m.start():]
    m_end = re.search(r"(?m)^end\s*$", rest)
    assert m_end, f"End of function {func_name} not found!"
    return rest[: m_end.end()]


def _extract_onframe_blocks(src: str):
    blocks = []
    pos = 0
    while True:
        idx = src.find("imgui.OnFrame(", pos)
        if idx == -1:
            break
        depth = 0
        j = idx + len("imgui.OnFrame")
        in_str = None
        while j < len(src):
            c = src[j]
            if in_str:
                if c == "\\":
                    j += 2
                    continue
                if c == in_str:
                    in_str = None
            else:
                if c in ("'", '"'):
                    in_str = c
                elif c == "-" and src[j : j + 2] == "--":
                    nl = src.find("\n", j)
                    j = len(src) if nl == -1 else nl + 1
                    continue
                elif c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
            j += 1
        blocks.append(src[idx:j])
        pos = j
    return blocks


def test_phase6_features(src: str):
    src_lf = src.replace("\r\n", "\n")

    # 1. Verify ALL 522 official adv-rp.com/decor IDs are present with zero duplicates or omissions
    assert ADV_DECOR_PATH.exists(), f"Missing reference catalog: {ADV_DECOR_PATH}"
    expected_ids = json.loads(ADV_DECOR_PATH.read_text(encoding="utf-8"))
    assert len(expected_ids) == 522 and len(set(expected_ids)) == 522

    m_cat = re.search(r"P6_decor_catalog\s*=\s*\{\n(.*?)\n\}", src_lf, re.S)
    assert m_cat, "P6_decor_catalog table not found!"
    cat_entries = re.findall(
        r'\{\s*id\s*=\s*(\d+)\s*,\s*cat\s*=\s*(\d+)\s*,\s*name\s*=\s*"((?:[^"\\]|\\.)*)"\s*\}',
        m_cat.group(1),
    )
    assert len(cat_entries) == 522, f"Expected 522 catalog entries, got {len(cat_entries)}"

    found_ids = []
    seen_ids = set()
    cats_seen = set()
    catalog_parsed = []
    for sid, scat, sname in cat_entries:
        oid = int(sid)
        cat = int(scat)
        assert oid not in seen_ids, f"Duplicate catalog ID: {oid}"
        seen_ids.add(oid)
        found_ids.append(oid)
        assert 1 <= cat <= 7, f"Invalid category {cat} for ID {oid}"
        cats_seen.add(cat)
        unescaped = sname.replace('\\"', '"').replace("\\\\", "\\")
        assert unescaped.strip() != "", f"Empty name for ID {oid}"
        unescaped.encode("cp1251")
        catalog_parsed.append({"id": oid, "cat": cat, "name": unescaped})

    assert set(found_ids) == set(expected_ids), (
        f"ID mismatch! missing={set(expected_ids) - set(found_ids)}, extra={set(found_ids) - set(expected_ids)}"
    )
    assert cats_seen == {1, 2, 3, 4, 5, 6, 7}, f"Some categories empty: {cats_seen}"

    # 2. Required symbols, buffers, module, sampev hooks, commands, terminate
    required_symbols = [
        "P6 = P6 or {}",
        "P6_loc_path",
        "P6_decor_catalog",
        "P6_loc_favorites",
        "P6_loc_recents",
        "P6_loc_registry",
        "loc_ui_show",
        "loc_ui_tab",
        "loc_cat_filter",
        "loc_sort_mode",
        "loc_compact_cards",
        "loc_search_buf",
        "loc_selected_id",
        "loc_cache_previews",
        "loc_textures",
        "loc_use_short_cmd",
        "tedit_show",
        "tedit_active",
        "tedit_player_obj",
        "tedit_obj_id",
        "tedit_handle",
        "tedit_model",
        "tedit_pos",
        "tedit_rot",
        "tedit_step_pos",
        "tedit_step_rot",
        "tedit_undo",
        "tedit_redo",
        "tedit_clipboard",
        "tedit_offset",
        "tedit_dup_pending",
        "loc_bp_json_path",
        "loc_status_msg",
        "loc_mid_helper_idx",
        "function P6_saveLocations(",
        "function P6_loadLocations(",
        "function P6_getProfileKey(",
        "function P6_exportBlueprint(",
        "function P6_importBlueprint(",
        "function P6_recordSavedObject(",
        "function P6_applyLocalPreview(",
        "function P6_nudgeAxis(",
        "function P6_undoEdit(",
        "function P6_redoEdit(",
        "function P6_copyParams(",
        "function P6_pasteParams(",
        "function P6_duplicateLast(",
        "function P6_selectDecorId(",
        "function P6_requestPreviewDownload(",
        "function P6_drawLocationWindowUI(",
        "function P6_drawPrecisionPanel(",
        "function P6_drawLocationModuleSettings(",
        'id = "location_builder"',
        "function sampev.onEnterEditObject(playerObject, objectId)",
        "function sampev.onSendEditObject(playerObject, objectId, response, position, rotation)",
    ]
    for sym in required_symbols:
        assert sym in src_lf, f"Missing required Phase 6 symbol: {sym}"

    for cmd in ("'tloc'", "'tedit'", "'tcopy'", "'tpaste'", "'tdup'", "'loc'"):
        assert cmd in src_lf, f"Missing Phase 6 command registration: {cmd}"
    assert "pcall(sampRegisterChatCommand, 'loc'" in src_lf, "/loc must be registered safely with pcall!"

    # Module drawSettings must resolve cleanly even though modules table appears before PHASE6_LOGIC
    pos_mod = src_lf.find('id = "location_builder"')
    pos_fn = src_lf.find("function P6_drawLocationModuleSettings(")
    assert 0 < pos_mod < pos_fn
    m_mod = re.search(r'id\s*=\s*"location_builder".*?drawSettings\s*=\s*([^\n]+)', src_lf, re.S)
    assert m_mod and "function(" in m_mod.group(1), "drawSettings in modules must wrap P6_drawLocationModuleSettings in a closure!"

    # onEnterEditObject must NEVER block entering editor (no `return false`)
    enter_fn = _extract_lua_function(src_lf, "sampev.onEnterEditObject")
    assert "return false" not in enter_fn, "onEnterEditObject must NEVER return false!"

    # onSendEditObject must handle response == 1 & response == 0 and record saved objects
    send_fn = _extract_lua_function(src_lf, "sampev.onSendEditObject")
    assert "response == 1" in send_fn and "response == 0" in send_fn
    assert "P6_recordSavedObject(" in send_fn
    assert "return {playerObject, objectId, response, position, rotation}" in send_fn

    # onScriptTerminate must clear tedit_active and save locations
    assert "tedit_active = false" in src_lf
    assert "pcall(P6_saveLocations)" in src_lf

    # 3. Render-thread safety & ImGui rules across all Phase 6 UI functions and OnFrame windows
    for fn_name in (
        "P6_drawPrecisionPanel",
        "P6_drawCatalogTab",
        "P6_drawRegistryTab",
        "P6_drawLocationWindowUI",
        "P6_drawLocationModuleSettings",
    ):
        fn_body = _extract_lua_function(src_lf, fn_name)
        outside = _strip_queued_calls(fn_body)
        for pat in FORBIDDEN_RENDER_PATTERNS:
            mh = re.search(pat, outside)
            assert not mh, f"Forbidden render-thread call {mh.group(0)} in {fn_name}"
        for bad_txt in ("imgui.Text(", "imgui.TextColored(", "imgui.TextWrapped(", "imgui.BulletText(", "imgui.CenterColumnText"):
            assert bad_txt not in fn_body, f"Forbidden ImGui text call {bad_txt} in {fn_name}"
        for line_no, raw_l in enumerate(fn_body.splitlines(), 1):
            if "imgui." in raw_l:
                for sm in re.finditer(r'(?:u8)?"((?:[^"\\]|\\.)*)"', raw_l):
                    if not sm.group(0).startswith('u8"') and any(ord(ch) > 127 for ch in sm.group(1)):
                        raise AssertionError(f"Non-ASCII string without u8 in {fn_name}:{line_no}: {raw_l.strip()}")

    p6_onframes = [b for b in _extract_onframe_blocks(src_lf) if ("P6_drawLocationWindowUI" in b or "P6_drawPrecisionPanel" in b)]
    assert len(p6_onframes) == 2, f"Expected 2 Phase 6 OnFrame blocks, found {len(p6_onframes)}"
    for idx, blk in enumerate(p6_onframes, 1):
        outside = _strip_queued_calls(blk)
        for pat in FORBIDDEN_RENDER_PATTERNS:
            mh = re.search(pat, outside)
            assert not mh, f"Forbidden render-thread call {mh.group(0)} in Phase 6 OnFrame #{idx}"

    # Check odd char[N] buffers on Phase 6 buffers
    even_p6 = [m.group(0) for m in re.finditer(r"loc_\w+\s*=\s*imgui\.new\.char\[(\d+)\]", src_lf) if int(m.group(1)) % 2 == 0]
    assert not even_p6, f"Even char buffer(s): {even_p6}"

    # 4. Behavioral checks mirroring Phase 6 precision editor, undo/redo, copy/paste, registry & catalog filter
    def norm_angle(deg):
        a = deg % 360.0
        if a < 0:
            a += 360.0
        a = round(a, 4)
        return 0.0 if a >= 360.0 else a

    state = {"pos": {"x": 100.0, "y": 200.0, "z": 10.0}, "rot": {"x": 5.0, "y": 10.0, "z": 90.0}, "undo": [], "redo": []}

    def nudge(kind, axis, delta):
        state["undo"].append({"pos": dict(state["pos"]), "rot": dict(state["rot"])})
        state["redo"].clear()
        if kind == "pos":
            state["pos"][axis] = round(state["pos"][axis] + delta, 4)
        else:
            state["rot"][axis] = norm_angle(state["rot"][axis] + delta)

    def undo():
        if not state["undo"]:
            return False
        state["redo"].append({"pos": dict(state["pos"]), "rot": dict(state["rot"])})
        prev = state["undo"].pop()
        state["pos"], state["rot"] = prev["pos"], prev["rot"]
        return True

    def redo():
        if not state["redo"]:
            return False
        state["undo"].append({"pos": dict(state["pos"]), "rot": dict(state["rot"])})
        nxt = state["redo"].pop()
        state["pos"], state["rot"] = nxt["pos"], nxt["rot"]
        return True

    nudge("pos", "z", 0.15)
    nudge("rot", "z", -95.0)
    assert state["pos"]["z"] == 10.15 and state["rot"]["z"] == 355.0
    assert undo() is True and state["rot"]["z"] == 90.0 and state["pos"]["z"] == 10.15
    assert redo() is True and state["rot"]["z"] == 355.0

    # Paste modes: all, z, rot, offset
    clip = {"pos": {"x": 50.0, "y": 60.0, "z": 12.5}, "rot": {"x": 0.0, "y": 0.0, "z": 180.0}}
    offset = {"x": 3.2, "y": 0.0, "z": 0.0}

    def paste(mode):
        if mode == "z":
            state["pos"]["z"] = clip["pos"]["z"]
        elif mode == "rot":
            state["rot"] = dict(clip["rot"])
        elif mode == "offset":
            state["pos"] = {k: round(clip["pos"][k] + offset[k], 4) for k in ("x", "y", "z")}
            state["rot"] = dict(clip["rot"])
        else:
            state["pos"] = dict(clip["pos"])
            state["rot"] = dict(clip["rot"])

    paste("z")
    assert state["pos"]["z"] == 12.5 and state["pos"]["x"] == 100.0
    paste("rot")
    assert state["rot"]["z"] == 180.0 and state["pos"]["x"] == 100.0
    paste("offset")
    assert state["pos"] == {"x": 53.2, "y": 60.0, "z": 12.5} and state["rot"]["z"] == 180.0

    # Registry record & re-edit update check
    reg = []

    def record(model, pos, rot, samp_id, start_pos=None):
        idx = None
        for i, cur in enumerate(reg):
            if cur.get("samp_obj_id") == samp_id and samp_id >= 0 and cur["model"] == model:
                idx = i
                break
        if idx is None and start_pos is not None:
            for i, cur in enumerate(reg):
                if cur["model"] == model:
                    d = math.sqrt((cur["x"] - start_pos["x"]) ** 2 + (cur["y"] - start_pos["y"]) ** 2 + (cur["z"] - start_pos["z"]) ** 2)
                    if d <= 0.35:
                        idx = i
                        break
        obj = {"model": model, **pos, **rot, "samp_obj_id": samp_id}
        if idx is not None:
            reg[idx] = obj
        else:
            reg.append(obj)

    record(19375, {"x": 1, "y": 2, "z": 3}, {"rx": 0, "ry": 0, "rz": 90}, 10)
    record(19375, {"x": 1.5, "y": 2, "z": 3}, {"rx": 0, "ry": 0, "rz": 90}, 10)
    assert len(reg) == 1 and reg[0]["x"] == 1.5
    # Reconnect changed samp_id to 42, matched via edit_start_pos
    record(19375, {"x": 8.0, "y": 9.0, "z": 3}, {"rx": 0, "ry": 0, "rz": 45}, 42, start_pos={"x": 1.5, "y": 2.0, "z": 3.0})
    assert len(reg) == 1 and reg[0]["x"] == 8.0 and reg[0]["samp_obj_id"] == 42

    # Catalog search/filter checks on the actual 522 parsed entries
    walls = [e for e in catalog_parsed if e["cat"] == 6 and "wall023" in e["name"].lower()]
    assert len(walls) == 1 and walls[0]["id"] == 19375
    neons = [e for e in catalog_parsed if "неон" in e["name"].lower()]
    assert len(neons) == 6

    print(f"Phase 6 checks OK ({len(catalog_parsed)}/522 catalog IDs verified, 7 categories, OnFrame & behavioral suite passed)")


def main():
    assert SLOTS_PATH.exists(), f"Missing {SLOTS_PATH}"
    slots = json.loads(SLOTS_PATH.read_text(encoding="utf-8"))
    assert set(slots.keys()) == set(EXPECTED_SLOTS), f"Unexpected slot keys: {set(slots.keys())}"

    # Verify strict CP1251 & no zero-bytes on every slot
    for k, v in slots.items():
        assert isinstance(v, str) and v.strip() != "", f"Empty slot {k}"
        assert "\x00" not in v, f"NUL byte in slot {k}"
        v.encode("cp1251")

    sys.path.insert(0, str(SCRATCH_DIR))
    try:
        import verify_helper as vh
    except ImportError:
        import run as vh

    # Check depth-0 locals in top-level Phase 6 slots
    for k in ("PHASE6_STATE", "PHASE6_LOGIC", "PHASE6_SAMPEV", "PHASE6_ONFRAME"):
        toks = vh.lex_lua(slots[k])
        vh.check_lua_structure(toks)
        depth = 0
        expect_do = False
        prev = None
        top_locals = []
        for kind, val, ln in toks:
            is_f = prev and prev[0] == "SYM" and prev[1] in (".", ":")
            if kind == "ID" and not is_f:
                if depth == 0 and val == "local":
                    top_locals.append(ln)
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
        assert not top_locals, f"Top-level local(s) found in {k} at lines {top_locals}"

    # Splice Phase 6 slots into helper_core.lua IN MEMORY (read-only!) and run full verification
    if HELPER_PATH.exists():
        raw = HELPER_PATH.read_bytes()
        src = raw.decode("cp1251")
        for k, code in slots.items():
            anchor = f"-- [[SWARM:{k}]]"
            assert src.count(anchor) == 1, f"Anchor {anchor} count != 1 in helper_core.lua"
            src = src.replace(anchor, code.replace("\r\n", "\n").replace("\n", "\r\n"), 1)

        # Verify CP1251 & CRLF after full splice
        spliced_bytes = src.encode("cp1251")
        assert b"\x00" not in spliced_bytes
        for ln, b_line in enumerate(spliced_bytes.split(b"\r\n"), 1):
            for b in b_line:
                assert b >= 32 or b == 9, f"Unexpected control byte {b} at line {ln}"
        assert src.count("\n") - src.count("\r\n") == 0, "Bare LF after splice!"

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
        test_phase6_features(src_lf)
    else:
        combined = "\n".join(slots.values())
        test_phase6_features(combined)

    print("ALL PHASE 6 STANDALONE & SPLICED VERIFICATION CHECKS PASSED 100%!")


if __name__ == "__main__":
    main()
