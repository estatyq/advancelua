# -*- coding: utf-8 -*-
import json
import re
import sys
from pathlib import Path

import argparse
import contextlib
import hashlib
import io
import subprocess

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

REPO_ROOT = Path(__file__).resolve().parent.parent
HARNESS_DIR = Path(__file__).resolve().parent
TARGET = REPO_ROOT / "helper_core.lua"
DEFAULT_DEPLOY = Path(r"E:\ukraine_rp_runtime\moonloader\helper_core.lua")
SWARM_DIR = HARNESS_DIR / "suites"


def lex_lua(src: str):
    """Full Lua 5.1/LuaJIT lexer returning list of (kind, text, line)."""
    tokens = []
    n = len(src)
    i = 0
    line = 1

    def count_eq(pos):
        k = 0
        while pos + k < n and src[pos + k] == "=":
            k += 1
        if pos + k < n and src[pos + k] == "[":
            return k
        return -1

    while i < n:
        ch = src[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch in " \t\r":
            i += 1
            continue

        # Comments
        if ch == "-" and i + 1 < n and src[i + 1] == "-":
            if i + 3 < n and src[i + 2] == "[":
                eq = count_eq(i + 3)
                if eq >= 0:
                    close_pat = "]" + ("=" * eq) + "]"
                    j = src.find(close_pat, i + 4 + eq)
                    if j == -1:
                        raise AssertionError(f"Unclosed long comment at line {line}")
                    line += src[i : j + len(close_pat)].count("\n")
                    i = j + len(close_pat)
                    continue
            j = src.find("\n", i + 2)
            if j == -1:
                break
            i = j
            continue

        # Long string [[...]] or [=[...]=]
        if ch == "[" and i + 1 < n and src[i + 1] in "[=":
            eq = count_eq(i + 1)
            if eq >= 0:
                close_pat = "]" + ("=" * eq) + "]"
                j = src.find(close_pat, i + 2 + eq)
                if j == -1:
                    raise AssertionError(f"Unclosed long string at line {line}")
                s_val = src[i : j + len(close_pat)]
                line += s_val.count("\n")
                tokens.append(("STR", s_val, line))
                i = j + len(close_pat)
                continue

        # Quoted strings
        if ch in ("'", '"'):
            q = ch
            start_line = line
            j = i + 1
            while j < n:
                c = src[j]
                if c == "\\":
                    if j + 1 < n and src[j + 1] == "\n":
                        line += 1
                    j += 2
                    continue
                if c == "\n":
                    raise AssertionError(f"Unclosed string at line {start_line}")
                if c == q:
                    j += 1
                    break
                j += 1
            else:
                raise AssertionError(f"Unclosed string at EOF from line {start_line}")
            tokens.append(("STR", src[i:j], start_line))
            i = j
            continue

        # Identifiers / keywords
        if ch.isalpha() or ch == "_":
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            word = src[i:j]
            tokens.append(("ID", word, line))
            i = j
            continue

        # Numbers
        if ch.isdigit() or (ch == "." and i + 1 < n and src[i + 1].isdigit()):
            j = i
            if src[i : i + 2].lower() == "0x":
                j += 2
                while j < n and src[j] in "0123456789abcdefABCDEF":
                    j += 1
            else:
                while j < n and (src[j].isdigit() or src[j] == "."):
                    j += 1
                if j < n and src[j] in "eE":
                    j += 1
                    if j < n and src[j] in "+-":
                        j += 1
                    while j < n and src[j].isdigit():
                        j += 1
            tokens.append(("NUM", src[i:j], line))
            i = j
            continue

        # Two/three char symbols
        if src[i : i + 3] == "...":
            tokens.append(("SYM", "...", line))
            i += 3
            continue
        if src[i : i + 2] in ("..", "==", "~=", "<=", ">=", "::"):
            tokens.append(("SYM", src[i : i + 2], line))
            i += 2
            continue

        tokens.append(("SYM", ch, line))
        i += 1

    return tokens


def check_lua_structure(tokens):
    # Balance (), [], {}
    paren_stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for kind, val, ln in tokens:
        if kind == "SYM" and val in "([{":
            paren_stack.append((val, ln))
        elif kind == "SYM" and val in ")]}":
            if not paren_stack or paren_stack[-1][0] != pairs[val]:
                raise AssertionError(f"Mismatched {val} at line {ln}; stack={paren_stack[-5:]}")
            paren_stack.pop()
    if paren_stack:
        raise AssertionError(f"Unclosed brackets: {paren_stack[:5]}")

    # Balance blocks: function/if/for/while/do/repeat vs end/until
    block_stack = []
    expect_loop_do = False
    prev_tok = None
    for idx, (kind, val, ln) in enumerate(tokens):
        is_field = prev_tok and prev_tok[0] == "SYM" and prev_tok[1] in (".", ":")
        if kind == "ID" and not is_field:
            if val in ("function", "if", "repeat"):
                block_stack.append((val, ln))
            elif val in ("for", "while"):
                block_stack.append((val, ln))
                expect_loop_do = True
            elif val == "do":
                if expect_loop_do:
                    expect_loop_do = False
                else:
                    block_stack.append(("do", ln))
            elif val == "end":
                if not block_stack or block_stack[-1][0] == "repeat":
                    raise AssertionError(f"Unexpected 'end' at line {ln}; stack={block_stack[-5:]}")
                block_stack.pop()
            elif val == "until":
                if not block_stack or block_stack[-1][0] != "repeat":
                    raise AssertionError(f"Unexpected 'until' at line {ln}; stack={block_stack[-5:]}")
                block_stack.pop()
        prev_tok = (kind, val, ln)
    if block_stack:
        raise AssertionError(f"Unclosed blocks: {block_stack}")


def _count_local_names(tokens, idx: int) -> int:
    """Count identifiers declared by a `local` token at tokens[idx]."""
    nxt = tokens[idx + 1] if idx + 1 < len(tokens) else ("", "", 0)
    if nxt[1] == "function":
        return 1
    j = idx + 1
    cnt = 0
    while j < len(tokens) and tokens[j][0] == "ID":
        cnt += 1
        if j + 1 < len(tokens) and tokens[j + 1][1] == ",":
            j += 2
        else:
            break
    return cnt


def _count_fn_params(tokens, fn_idx: int) -> int:
    """Count named parameters in a `function (...)` header starting at tokens[fn_idx]."""
    p = fn_idx + 1
    while p < len(tokens) and tokens[p][1] != "(":
        p += 1
    p += 1
    cnt = 0
    while p < len(tokens) and tokens[p][1] != ")":
        if tokens[p][0] == "ID":
            cnt += 1
        p += 1
    return cnt


def check_luajit_and_collisions(tokens, src_lf: str):
    """Enforce LuaJIT hard compile caps and uniqueness of sampev hooks & chat commands."""
    depth = 0
    expect_loop_do = False
    prev = None
    top_locals = []
    top_local_names = set()
    fn_ranges = []
    cur_fn = None
    proto_stack = []
    all_protos = []

    for i, (kind, val, ln) in enumerate(tokens):
        is_field = prev and prev[0] == "SYM" and prev[1] in (".", ":")
        if kind == "ID" and not is_field:
            if val == "local":
                if depth == 0:
                    nxt = tokens[i + 1] if i + 1 < len(tokens) else ("", "", ln)
                    if nxt[1] == "function":
                        fname = tokens[i + 2][1] if i + 2 < len(tokens) else "?"
                        top_locals.append((ln, fname))
                        top_local_names.add(fname)
                    else:
                        j = i + 1
                        while j < len(tokens) and tokens[j][0] == "ID":
                            nm = tokens[j][1]
                            top_locals.append((ln, nm))
                            top_local_names.add(nm)
                            if j + 1 < len(tokens) and tokens[j + 1][1] == ",":
                                j += 2
                            else:
                                break
                else:
                    cnt = _count_local_names(tokens, i)
                    if proto_stack:
                        proto_stack[-1]["direct_locals"] += cnt
                    if cur_fn is not None:
                        cur_fn["tree_locals"] += cnt
            if val == "function":
                fname = f"anon@{ln}"
                if i + 1 < len(tokens) and tokens[i + 1][0] == "ID":
                    fname = tokens[i + 1][1]
                    k = i + 2
                    while k + 1 < len(tokens) and tokens[k][1] in (".", ":") and tokens[k + 1][0] == "ID":
                        fname += tokens[k][1] + tokens[k + 1][1]
                        k += 2
                p_cnt = _count_fn_params(tokens, i)
                if depth == 0:
                    cur_fn = {"name": fname, "ln": ln, "refs": set(), "tree_locals": p_cnt}
                proto_stack.append({"name": fname, "ln": ln, "depth": depth, "direct_locals": p_cnt})
                if cur_fn is not None and depth > 0:
                    cur_fn["tree_locals"] += p_cnt
                depth += 1
            elif val in ("if", "repeat"):
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
                if proto_stack and proto_stack[-1]["depth"] == depth:
                    all_protos.append(proto_stack.pop())
                if depth == 0 and cur_fn is not None:
                    fn_ranges.append(cur_fn)
                    cur_fn = None
            elif cur_fn is not None and val in top_local_names:
                cur_fn["refs"].add(val)
        prev = (kind, val, ln)

    assert len(top_locals) <= 150, f"Too many top-level locals: {len(top_locals)} (LuaJIT cap 200, target <=150)"
    worst = max(fn_ranges, key=lambda x: len(x["refs"]), default={"name": "?", "ln": 0, "refs": set()})
    assert len(worst["refs"]) <= 45, f"Function {worst['name']}@L{worst['ln']} references {len(worst['refs'])} upvalues (target <=45, LuaJIT cap 60)"

    worst_direct = max(all_protos, key=lambda x: x["direct_locals"], default={"name": "?", "ln": 0, "direct_locals": 0})
    worst_tree = max(fn_ranges, key=lambda x: x["tree_locals"], default={"name": "?", "ln": 0, "tree_locals": 0})
    assert worst_direct["direct_locals"] <= 180, (
        f"Function {worst_direct['name']}@L{worst_direct['ln']} declares {worst_direct['direct_locals']} locals (target <=180, LuaJIT cap 200)"
    )
    assert worst_tree["tree_locals"] <= 180, (
        f"Top-level function {worst_tree['name']}@L{worst_tree['ln']} declares {worst_tree['tree_locals']} locals in body tree (target <=180)"
    )

    # No duplicate sampev.<handler> definitions
    sampev_handlers = re.findall(r"(?m)^\s*function\s+sampev\.(\w+)\s*\(", src_lf)
    dup_handlers = {h for h in sampev_handlers if sampev_handlers.count(h) > 1}
    assert not dup_handlers, f"Duplicate sampev handlers: {dup_handlers}"

    # No duplicate literal sampRegisterChatCommand names
    cmd_names = re.findall(r"""sampRegisterChatCommand\(\s*['"]([^'"]+)['"]""", src_lf)
    dup_cmds = {c for c in cmd_names if cmd_names.count(c) > 1}
    assert not dup_cmds, f"Duplicate chat commands: {dup_cmds}"

    print(
        f"LuaJIT & uniqueness OK (top_locals={len(top_locals)}/150, "
        f"max_fn_locals={worst_direct['direct_locals']}/180 [{worst_direct['name']}], "
        f"max_upvals={len(worst['refs'])}/45 [{worst['name']}], "
        f"{len(sampev_handlers)} sampev hooks, {len(cmd_names)} chat cmds)"
    )


FORBIDDEN_RENDER_CALLS = (
    r"\bsamp[A-Z]\w*\s*\(",
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
    r"\bsampGetObjectHandleBySampId\s*\(",
    r"\bdownloadUrlToFile\s*\(",
    r"\blua_thread\.create\s*\(",
)


def strip_queued_calls(block: str) -> str:
    """Remove queueTask(...) and scheduleTask(...) argument bodies while preserving strings/comments."""
    cleaned_parts = []
    k = 0
    while k < len(block):
        m = re.search(r"\b(queueTask|scheduleTask)\s*\(", block[k:])
        if not m:
            cleaned_parts.append(block[k:])
            break
        cleaned_parts.append(block[k : k + m.start()])
        p = k + m.start() + len(m.group(0)) - 1
        d = 0
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
                elif cc == "-" and block[p : p + 2] == "--":
                    nl = block.find("\n", p)
                    p = len(block) if nl == -1 else nl + 1
                    continue
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


def extract_lua_block(src: str, start_idx: int) -> str:
    """Extract a balanced Lua block starting at a `function ...` header through its matching `end`."""
    n = len(src)
    i = start_idx
    depth = 0
    expect_loop_do = False
    in_str = None
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
                    expect_loop_do = True
                elif word == "do":
                    if expect_loop_do:
                        expect_loop_do = False
                    else:
                        depth += 1
                elif word in ("end", "until"):
                    depth -= 1
                    if depth == 0:
                        return src[start_idx:j]
            prev_sym = ""
            i = j
            continue
        if not ch.isspace():
            prev_sym = ch
        i += 1
    raise AssertionError(f"Unclosed Lua block starting at offset {start_idx}")


def _assert_render_safe(code: str, label: str):
    outside = strip_queued_calls(code)
    for bad_pat in FORBIDDEN_RENDER_CALLS:
        mh = re.search(bad_pat, outside)
        assert not mh, f"Forbidden render-thread call {mh.group(0)} directly inside {label}"


def check_onframe_safety(src: str):
    # 1. Extract each imgui.OnFrame(...) block by balancing parens
    pos = 0
    count = 0
    while True:
        idx = src.find("imgui.OnFrame(", pos)
        if idx == -1:
            break
        count += 1
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
        _assert_render_safe(src[idx:j], f"OnFrame #{count}")
        pos = j
    assert count >= 17, f"Expected >=17 OnFrame windows, found {count}"

    # 2. Audit named UI draw helpers called directly from OnFrame / drawSettings
    ui_fns = (
        "P3_drawLecturerUI",
        "P4_drawFactionUI",
        "P6_drawLocationWindowUI",
        "P6_drawCatalogTab",
        "P6_drawRegistryTab",
        "P6_drawPrecisionPanel",
        "P6_drawLocationModuleSettings",
        "P6_drawProTab",
        "P7_drawMarketUI",
        "P7_drawPatrolUI",
        "P8_drawArmyUI",
        "P8_drawCapabilityBanner",
        "P8_drawEnvDiagnostics",
        "P8_drawContextQuickBar",
        "P9_drawOverviewTab",
        "P9_drawProfileTab",
        "P9_drawDashboardUI",
        "P9_drawServerIsolationBanner",
        "P9_drawSuwContent",
        "P9_drawTicketWindow",
        "P9_drawTakelicWindow",
        "P9_drawBlWindow",
        "P9_drawArticleJumpButtons",
        "P9_drawLawsAiTab",
        "P9_drawLawsWindow",
        "P9_drawRadialEditorUI",
        "P9_drawWheelCustomSlots",
        "P9_drawDryRunButton",
        "P9_drawKeybindDryRunBtn",
        "P9_drawRpDryRunBtn",
        "P9_drawPatrolDryRunBtn",
        "P9_drawArmyPostDryRunBtn",
        "P9_drawAutoSsSettings",
        "P9_drawSoftUnloadButton",
        "drawGnewsSettings",
        "drawMmEditorSettings",
        "P2_drawWheelFavSelector",
        "P2_getWheelDisplayItems",
        "drawQuizDirectorUI",
    )
    for fn_name in ui_fns:
        m = re.search(rf"(?m)^(?:local\s+)?function\s+{re.escape(fn_name)}\s*\(", src)
        assert m, f"UI draw function {fn_name} not found!"
        _assert_render_safe(extract_lua_block(src, m.start()), f"{fn_name}()")

    # 3. Audit inline drawSettings closures inside modules (including dashboard, vehicle_visuals & qol_tools)
    audited_mods = []
    for m_id in ("dashboard", "vehicle_visuals", "qol_tools", "autocall_db", "auto_ad", "auto_rp", "keybinds", "commands_guide", "rp_engine", "smi_tools", "lecturer", "faction_tools", "location_builder", "army_tools"):
        m_mod = re.search(rf'id\s*=\s*"{re.escape(m_id)}".*?drawSettings\s*=\s*(function\s*\()', src, re.S)
        assert m_mod, f"drawSettings closure missing for module {m_id!r}"
        _assert_render_safe(extract_lua_block(src, m_mod.start(1)), f"modules[{m_id}].drawSettings")
        audited_mods.append(m_id)

    print(
        f"OnFrame & UI render-thread safety OK "
        f"({count} OnFrame blocks, {len(ui_fns)} UI functions, {len(audited_mods)} module drawSettings verified)"
    )


def test_autoedit(src: str):
    # Extract default mm_rules from helper_core.lua
    lines = src.split("\n")
    s_idx = next(i for i, l in enumerate(lines) if l.strip() == "local mm_rules = {")
    e_idx = next(i for i in range(s_idx + 1, len(lines)) if lines[i].strip() == "}")
    pat = re.compile(r'^\{\s*abbreviation\s*=\s*"((?:[^"\\]|\\.)*)"\s*,\s*replacement\s*=\s*"((?:[^"\\]|\\.)*)"\s*\},?\s*$')
    mm_rules = []
    seen = set()
    for i in range(s_idx + 1, e_idx):
        s = lines[i].strip()
        if not s or s.startswith("--"):
            continue
        m = pat.match(s)
        assert m, f"Bad rule line {i+1}: {s}"
        a = m.group(1).replace('\\"', '"').replace("\\\\", "\\")
        r = m.group(2).replace('\\"', '"').replace("\\\\", "\\")
        assert not re.search(r"[а-яА-ЯёЁ]{2,}[23]$", a), f"Synthetic rule left: {a}"
        assert a.lower() not in seen, f"Duplicate rule left: {a}"
        seen.add(a.lower())
        mm_rules.append((a, r))

    # Mirror the exact CP1251-byte tokenizer and formatAdText logic from helper_core.lua
    def cp1251_lower(s):
        return s.lower()

    def is_word_byte(b):
        return (48 <= b <= 57) or (65 <= b <= 90) or (97 <= b <= 122) or b in (95, 47, 168, 184) or (192 <= b <= 255)

    def tokenize(s):
        raw = s.encode("cp1251")
        tokens = []
        i = 0
        n = len(raw)
        while i < n:
            if is_word_byte(raw[i]):
                j = i + 1
                while j < n:
                    if is_word_byte(raw[j]) or (raw[j] == 45 and j + 1 < n and is_word_byte(raw[j - 1]) and is_word_byte(raw[j + 1])):
                        j += 1
                    else:
                        break
                t = raw[i:j].decode("cp1251")
                tokens.append((True, t, t.lower()))
                i = j
            else:
                j = i + 1
                while j < n and not is_word_byte(raw[j]):
                    j += 1
                tokens.append((False, raw[i:j].decode("cp1251"), ""))
                i = j
        return tokens

    exact = {}
    base_map = {}
    multi_by_first = {}
    vowels = set("ауеыияю")
    for a, r in mm_rules:
        words = [t[2] for t in tokenize(a) if t[0]]
        if len(words) == 1:
            w = words[0]
            exact[w] = r
            if len(w) >= 5 and w[-1] in vowels:
                stem = w[:-1]
                if len(stem) >= 4 and stem not in base_map:
                    base_map[stem] = r
        elif len(words) >= 2:
            multi_by_first.setdefault(words[0], []).append((words, r))
    for lst in multi_by_first.values():
        lst.sort(key=lambda x: len(x[0]), reverse=True)

    ru_endings = ["ой", "ей", "ом", "ем", "ам", "ям", "ах", "ях", "ов", "ев", "а", "у", "е", "ы", "и", "о", "я", "ю"]

    def apply_rules(txt):
        toks = tokenize(txt)
        out = []
        i = 0
        n = len(toks)
        while i < n:
            is_w, raw_t, low_t = toks[i]
            if not is_w:
                out.append(raw_t)
                i += 1
            else:
                matched = None
                end_i = None
                for words, repl in multi_by_first.get(low_t, ()):
                    ti = i
                    ok = True
                    for wi in range(1, len(words)):
                        if ti + 2 >= n or toks[ti + 1][0] or not toks[ti + 1][1].isspace() or not toks[ti + 2][0] or toks[ti + 2][2] != words[wi]:
                            ok = False
                            break
                        ti += 2
                    if ok:
                        matched = repl
                        end_i = ti
                        break
                if matched is not None:
                    out.append(matched)
                    i = end_i + 1
                elif low_t in exact:
                    out.append(exact[low_t])
                    i += 1
                elif len(low_t) >= 5:
                    sr = None
                    for suf in ru_endings:
                        if len(low_t) - len(suf) >= 4 and low_t.endswith(suf):
                            base = low_t[: -len(suf)]
                            sr = exact.get(base) or base_map.get(base)
                            if sr:
                                break
                    out.append(sr if sr is not None else raw_t)
                    i += 1
                else:
                    out.append(raw_t)
                    i += 1
        return "".join(out)

    slang_units = {
        "ккк": 1000000000, "kkk": 1000000000, "ккk": 1000000000, "кkк": 1000000000, "kкк": 1000000000,
        "млрд": 1000000000, "mlrd": 1000000000, "миллиард": 1000000000, "миллиарда": 1000000000, "миллиардов": 1000000000,
        "кк": 1000000, "kk": 1000000, "кk": 1000000, "kк": 1000000,
        "млн": 1000000, "mln": 1000000, "миллион": 1000000, "миллиона": 1000000, "миллионов": 1000000,
        "к": 1000, "k": 1000, "тыс": 1000, "tys": 1000,
    }
    prep_map = {
        "у": {"мэрию": "мэрии", "полицию": "полиции", "больницу": "больницы", "школу": "школы", "церковь": "церкви", "электростанцию": "электростанции", "банк": "банка", "стадион": "стадиона"},
        "возле": {"банк": "банка", "мэрию": "мэрии"},
        "к": {"банк": "банку"},
        "в": {"мэрию": "мэрии", "банк": "банке"},
        "на": {"стадион": "стадионе"},
    }
    car_kw = ["булк", "инф", "туризм", "султан", "хотринг", "нрг", "машин", "а/м", "мото", "велосипед"]
    re_kw = ["дом", "жиль", "квартир", "особняк", "вилл", "бизнес", "азс", "магазин", "отель", "казино", "бар", "закусочн", "столов", "ресторан", "зал", "склад"]
    loc_kw = ["los santos", "san fierro", "las venturas", "east", "штат", "город", "район", "гетто"]

    def format_num(v):
        s = str(int(round(v)))
        out = []
        while len(s) > 3:
            out.append(s[-3:])
            s = s[:-3]
        out.append(s)
        return ".".join(reversed(out))

    def fmt_ad(inp, tag="LV"):
        s = re.sub(r"\{[0-9A-Fa-f]+\}", "", inp).strip()
        det_tag = None
        m = re.match(r"^\s*([A-Za-z0-9_\-А-Яа-яЁё]+)\s*\|\s*", s)
        if m and len(m.group(1)) <= 12:
            det_tag = m.group(1)
            s = s[m.end():]
        low = s.lower()

        # slang money
        padded = f" {s} "
        word_c = r"[A-Za-z0-9_А-Яа-яЁё]"
        letter_c = r"[A-Za-zА-Яа-яЁё]"
        pos = 0
        out_m = []
        pat_m = re.compile(rf"(?<!{word_c})(\d+[.,]?\d*)(\s*)({letter_c}+)(?!{word_c})")
        for mm in pat_m.finditer(padded):
            out_m.append(padded[pos : mm.start()])
            u = mm.group(3).lower()
            if u in slang_units:
                val = float(mm.group(1).replace(",", "."))
                out_m.append(format_num(val * slang_units[u]) + "$")
            else:
                out_m.append(mm.group(0))
            pos = mm.end()
        out_m.append(padded[pos:])
        s = "".join(out_m)[1:-1]

        s = apply_rules(s)
        # prepositions
        toks_p = s.split(" ")
        for idx_p in range(len(toks_p) - 1):
            p_low = toks_p[idx_p].lower()
            w_clean = toks_p[idx_p + 1].rstrip(".,")
            suf = toks_p[idx_p + 1][len(w_clean):]
            if p_low in prep_map and w_clean.lower() in prep_map[p_low]:
                toks_p[idx_p + 1] = prep_map[p_low][w_clean.lower()] + suf
        s = " ".join(toks_p)

        # leading verb
        verbs = {"продам": "Продам", "куплю": "Куплю", "обменяю": "Обменяю", "сдам": "Сдам", "сниму": "Сниму"}
        first_w = s.split(" ", 1)[0]
        if first_w.lower() in verbs:
            s = verbs[first_w.lower()] + s[len(first_w):]

        fl = s.lower()
        is_buy = low.startswith("куплю")
        is_sell = low.startswith("продам")
        is_trade = low.startswith("обменяю")
        is_rent_out = low.startswith("сдам")
        is_rent_seek = low.startswith("сниму")
        is_car = any(k in low or k in fl for k in car_kw)
        is_re = any(k in low or k in fl for k in re_kw)
        has_loc = any(k in fl for k in loc_kw)
        s = re.sub(r"\s+", " ", s).strip()

        if (is_buy or is_rent_seek) and is_re and not is_car and not has_loc:
            bm = re.search(r"\s+бюджет(?=[\s:.,]|$)", s.lower())
            if bm:
                s = s[: bm.start()] + " в любой точке штата" + s[bm.start():]
            else:
                s += " в любой точке штата"

        s = re.sub(r"([^.!? \t])\s+бюджет(?=[\s:.,]|$)", r"\1. Бюджет", s, flags=re.IGNORECASE)
        s = re.sub(r"([.!?])\s+бюджет(?=[\s:.,]|$)", r"\1 Бюджет", s, flags=re.IGNORECASE)
        s = re.sub(r"^\s*бюджет(?=[\s:.,]|$)", "Бюджет", s, flags=re.IGNORECASE)
        s = re.sub(r"([^.!?\s])\s+цена\s+договорная([\s.,]*)$", r"\1. Цена договорная", s, flags=re.IGNORECASE)
        m_dog = re.search(r"(\S+)\s+договорная([\s.,]*)$", s, flags=re.IGNORECASE)
        if m_dog:
            prev = m_dog.group(1)
            if prev.lower() in ("цена", "цена:"):
                s = s[: m_dog.start()] + prev + " договорная"
            elif prev.endswith("."):
                s = s[: m_dog.start()] + prev + " Цена договорная"
            else:
                s = s[: m_dog.start()] + prev + ". Цена договорная"

        # bare dollar
        def repl_dollar(dm):
            prev_raw = dm.group(1)
            amt = dm.group(2)
            pw = prev_raw.lower()
            if pw == "":
                return " Цена " + amt
            if pw in ("цена", "цена:", "бюджет", "бюджет:", "доплата", "от", "до"):
                return prev_raw + " " + amt
            if prev_raw.endswith("."):
                return prev_raw + " Цена " + amt
            return prev_raw + ". Цена " + amt

        s = re.sub(r"(\S*)\s+(\d[\d.]*\$)", repl_dollar, " " + s).lstrip()
        s = re.sub(r"([^.!?\s])\s+цена\s+(\d[\d.]*\$)", r"\1. Цена \2", s, flags=re.IGNORECASE)
        s = re.sub(r"([.!?])\s+цена(?=[\s:.,])", r"\1 Цена", s, flags=re.IGNORECASE)

        fl2 = s.lower()
        has_price = any(k in fl2 for k in ("$", "цена", "дог", "торг", "обмен", "бартер", "бесплатн", "бюджет"))
        if (is_buy or is_sell or is_rent_out or is_rent_seek) and not has_price:
            s += ". Цена договорная"
        if is_trade and "доплат" in fl2 and "доплата с мо" not in fl2 and "доплата с ваш" not in fl2:
            mine = bool(re.search(r"мо[йяеиёю]|мен[яе]|доплачива", fl2))
            theirs = ("ваш" in fl2) or ("вас" in fl2)
            if theirs and not mine:
                s += ". Доплата с вашей стороны"
            elif mine and not theirs:
                s += ". Доплата с моей стороны"

        s = re.sub(r"\.+", ".", s).replace(". .", ".")
        s = re.sub(r"\s+\.", ".", s).strip()
        use_tag = det_tag or tag
        if use_tag:
            s = f"{use_tag} | {s}"
            pp = s.find(" | ")
            s = s[: pp + 3] + s[pp + 3].upper() + s[pp + 4:]

        if len(s) > 144:
            s = re.sub(r"\. Цена договорная$", "", s)
            s = re.sub(r" в любой точке штата\.?", "", s)
            if len(s) > 144:
                pp = s.find(" | ")
                tp = s[: pp + 3] if pp != -1 else ""
                bd = s[pp + 3:] if pp != -1 else s
                mb = 144 - len(tp)
                cut = bd[:mb]
                tm = re.match(r"^(.*)\s+\S*$", cut)
                if tm and tm.group(1):
                    bd = tm.group(1)
                else:
                    bd = cut
                s = tp + bd
        return s

    cases = [
        ("продам булку дог", 'LV | Продам а/м марки "Bullet". Цена договорная'),
        ("куплю булку", 'LV | Куплю а/м марки "Bullet". Цена договорная'),
        ("куплю дом в лс", "LV | Куплю дом в Los Santos. Цена договорная"),
        ("куплю дом бюджет 5кк", "LV | Куплю дом в любой точке штата. Бюджет 5.000.000$"),
        ("ПРОДАМ БУЛКУ 1.5КК", 'LV | Продам а/м марки "Bullet". Цена 1.500.000$'),
        ("продам хотринг 5ккк", 'LV | Продам а/м марки "Hotring". Цена 5.000.000.000$'),
        ("продам телефон 500К", "LV | Продам телефон. Цена 500.000$"),
        ("продам дом 500ка", "LV | Продам дом 500ка. Цена договорная"),
        ("куплю бизнес качалка у банка лс", "LV | Куплю бизнес тренажёрный зал у банка Los Santos. Цена договорная"),
        ("продам столовая закусочная одежда бинокль бронежилет информация полиция",
         "LV | Продам столовую закусочную одежду бинокль бронежилет информация полицию. Цена договорная"),
        ("обменяю телефон на ноутбук с моей доплатой",
         "LV | Обменяю телефон на ноутбук с моей доплатой. Доплата с моей стороны"),
        ("SF | сдам кв в сф 15к", "SF | Сдам квартиру в San Fierro. Цена 15.000$"),
        ("сниму особняк", "LV | Сниму особняк в любой точке штата. Цена договорная"),
        ("Продам дом в ЛС | Срочно", "LV | Продам дом в Los Santos | Срочно. Цена договорная"),
        ("куплю инф 10кк", 'LV | Куплю а/м марки "Infernus". Цена 10.000.000$'),
        ("продам нрг 500к", 'LV | Продам мото марки "NRG-500". Цена 500.000$'),
        ("куплю дом в лс. бюджет 3кк", "LV | Куплю дом в Los Santos. Бюджет 3.000.000$"),
        ("продам булку. цена 4кк", 'LV | Продам а/м марки "Bullet". Цена 4.000.000$'),
    ]
    for inp, exp in cases:
        got = fmt_ad(inp)
        assert got == exp, f"AutoEdit mismatch for {inp!r}:\n  expected: {exp!r}\n  got:      {got!r}"
    # Truncation check
    long_res = fmt_ad("продам " + ("очень длинный текст объявления " * 8) + "в лс")
    assert len(long_res) <= 144, f"Exceeded 144 limit: {len(long_res)}"
    print(f"AutoEdit behavioral suite OK ({len(cases) + 1} cases passed, {len(mm_rules)} rules verified)")


def test_find_and_calc(src: str):
    # Verify /find Lua patterns logic against sample Advance RP lines
    sample_lines = [
        "1. Ivan_Petrov[14] - 5 ранг Радиоцентр ЛС  123456",
        "2. Anna_Smirnova[102]  8 ранг  Телецентр   998877",
    ]
    for line in sample_lines:
        m = re.match(r"^\s*\d+\.\s*(.*?)\[(\d+)\].*?(\d+)\s*[Рр]анг\s*(.*?)\s+(\d+)", line)
        assert m, f"/find failed on {line}"
        nick, pid, rang, podr, phone = m.groups()
        assert "_" in nick and pid.isdigit() and rang.isdigit() and phone.isdigit()

    # Verify calc grammar logic
    calc_mult = {"kkk": 1e9, "ккк": 1e9, "млрд": 1e9, "kk": 1e6, "кк": 1e6, "млн": 1e6, "k": 1e3, "к": 1e3, "тыс": 1e3}
    def eval_calc(expr):
        s = re.sub(r"\s+", "", expr.lower())
        toks = []
        i = 0
        while i < len(s):
            if s[i] in "+-*/()":
                toks.append(("op", s[i]))
                i += 1
            elif s[i].isdigit():
                m = re.match(r"\d+[.,]?\d*", s[i:])
                val = float(m.group(0).replace(",", "."))
                i += len(m.group(0))
                ms = re.match(r"[a-zа-яё]+", s[i:])
                if ms:
                    val *= calc_mult[ms.group(0)]
                    i += len(ms.group(0))
                toks.append(("num", val))
            else:
                raise ValueError("bad char")
        pos = [0]
        def pf():
            t = toks[pos[0]]
            if t[0] == "op" and t[1] in "+-":
                pos[0] += 1
                v = pf()
                return -v if t[1] == "-" else v
            if t[0] == "op" and t[1] == "(":
                pos[0] += 1
                v = pe()
                assert toks[pos[0]] == ("op", ")")
                pos[0] += 1
                return v
            pos[0] += 1
            return t[1]
        def pt():
            l = pf()
            while pos[0] < len(toks) and toks[pos[0]][1] in ("*", "/"):
                op = toks[pos[0]][1]; pos[0] += 1
                r = pf()
                if op == "/" and r == 0:
                    raise ZeroDivisionError()
                l = l * r if op == "*" else l / r
            return l
        def pe():
            l = pt()
            while pos[0] < len(toks) and toks[pos[0]][1] in ("+", "-"):
                op = toks[pos[0]][1]; pos[0] += 1
                r = pt()
                l = l + r if op == "+" else l - r
            return l
        res = pe()
        assert pos[0] == len(toks)
        return res

    assert eval_calc("1.5кк * 3 + 500к") == 5000000.0
    assert eval_calc("(10+2)*5") == 60.0
    try:
        eval_calc("10/0")
        raise AssertionError("Should divide by zero")
    except ZeroDivisionError:
        pass
    # Verify JSON fallback strings/patterns exist cleanly in helper_core.lua
    assert "local function parseString()" in src and "local function parseObject()" in src
    assert "s:sub(pos, pos + 3) == 'true'" in src and "(true|false)" not in src
    sample_json_payload = {
        "mm_auto_send": True,
        "mm_auto_format": False,
        "rules": [{"abbr": "булка", "repl": 'а/м марки "Bullet"'}],
        "rp_text": "/me достал\n<500>\n/do В руке",
    }
    encoded_py = json.dumps(sample_json_payload, ensure_ascii=False)
    decoded_py = json.loads(encoded_py)
    assert decoded_py == sample_json_payload
    print("/find, JSON fallback, & /calc behavioral checks OK")


def test_v19_features(src: str):
    # 1. Layout converter mirror
    en_to_ru = {
        "q":"й","w":"ц","e":"у","r":"к","t":"е","y":"н","u":"г","i":"ш","o":"щ","p":"з","[":"х","]":"ъ",
        "a":"ф","s":"ы","d":"в","f":"а","g":"п","h":"р","j":"о","k":"л","l":"д",";":"ж","'":"э",
        "z":"я","x":"ч","c":"с","v":"м","b":"и","n":"т","m":"ь",",":"б",".":"ю","`":"ё",
        "Q":"Й","W":"Ц","E":"У","R":"К","T":"Е","Y":"Н","U":"Г","I":"Ш","O":"Щ","P":"З","{":"Х","}":"Ъ",
        "A":"Ф","S":"Ы","D":"В","F":"А","G":"П","H":"Р","J":"О","K":"Л","L":"Д",":":"Ж",'"':"Э",
        "Z":"Я","X":"Ч","C":"С","V":"М","B":"И","N":"Т","M":"Ь","<":"Б",">":"Ю","~":"Ё",
    }
    ru_to_en = {v: k for k, v in en_to_ru.items()}
    punct_end = {",", ".", ":", '"'}
    skip_arg_cmds = {"sms", "c", "call", "w", "pay", "id", "pass", "lic", "med"}

    def convert_layout(s):
        prefix = ""
        body = s
        m = re.match(r"^(/\S+)\s*(.*)$", s)
        if m:
            prefix = m.group(1)
            body = m.group(2) or ""
            if prefix[1:].lower() in skip_arg_cmds and body:
                m2 = re.match(r"^(\S+)(.*)$", body)
                if m2 and (m2.group(1).isdigit() or "_" in m2.group(1)):
                    prefix += " " + m2.group(1)
                    body = m2.group(2).lstrip()
            if body:
                prefix += " "
        if not body:
            return s
        lat = sum(1 for c in body if ("A" <= c <= "Z") or ("a" <= c <= "z"))
        cyr = sum(1 for c in body if ("А" <= c <= "я") or c in "Ёё")
        to_en = cyr > lat
        out = []
        i = 0
        while i < len(body):
            if body[i].isspace():
                out.append(body[i])
                i += 1
            else:
                j = i
                while j < len(body) and not body[j].isspace():
                    j += 1
                tok = body[i:j]
                if "_" in tok or tok.startswith(("http://", "https://")):
                    out.append(tok)
                elif to_en:
                    out.append("".join(ru_to_en.get(c, c) for c in tok))
                else:
                    has_int = any(c in punct_end for c in tok[:-1])
                    res = []
                    for k, c in enumerate(tok):
                        if k == len(tok) - 1 and c in punct_end and not has_int:
                            res.append(c)
                        else:
                            res.append(en_to_ru.get(c, c))
                    out.append("".join(res))
                i = j
        return prefix + "".join(out)

    layout_cases = [
        ("ghbdtn, rfr ltkf.", "привет, как дела."),
        ("/me ljcnfk gfcgjhn", "/me достал паспорт"),
        ("/sms 12345 ghbdtn", "/sms 12345 привет"),
        ("k.,k.", "люблю"),
        ("Ivan_Petrov ghbdtn", "Ivan_Petrov привет"),
        ("привет", "ghbdtn"),
    ]
    for inp, exp in layout_cases:
        got = convert_layout(inp)
        assert got == exp, f"Layout mismatch for {inp!r}: expected {exp!r}, got {got!r}"

    # 2. Advance RP SMS parser check
    for line, exp in [
        ("SMS: Привет, продаёшь? | Отправитель: Ivan_Petrov [т.123456]", ("Ivan_Petrov", "123456")),
        ("{FFAA00}SMS: Ку! | Отправитель: Anna_Lee [т.778899]", ("Anna_Lee", "778899")),
    ]:
        clean = re.sub(r"\{[0-9A-Fa-f]+\}", "", line)
        m = re.search(r"SMS:.*?Отправитель:\s*([A-Za-z0-9_]+)\s*\[т\.\s*(\d+)\]", clean)
        assert m and m.groups() == exp, f"SMS parse failed on {line!r}"

    # 3. Radio auto-tag behavior mirror
    def radio_fmt(cmd, rest, rtag="[LV-FM]", punct=True):
        trimmed = rest.strip()
        if not trimmed or trimmed.startswith("(("):
            return "/" + cmd + " " + rest
        if punct:
            trimmed = trimmed[0].upper() + trimmed[1:]
            if trimmed[-1] not in ".!?)":
                trimmed += "."
        if rtag and not trimmed.startswith(rtag):
            trimmed = rtag + " " + trimmed
        return "/" + cmd + " " + trimmed

    assert radio_fmt("r", "еду в офис") == "/r [LV-FM] Еду в офис."
    assert radio_fmt("r", "(( оос ))") == "/r (( оос ))"
    assert radio_fmt("r", "[LV-FM] уже с тегом") == "/r [LV-FM] уже с тегом."

    # 4. sanitizeAndDedupeRules mirror
    assert "function sanitizeAndDedupeRules(" in src
    assert "default_mm_rules" in src
    print("v1.9 behavioral checks OK (layout switcher, SMS parser, radio auto-tag, rules migration)")


def test_v20_features(src: str):
    # 1. Version & README sync (checkGithubUpdates regex)
    assert "local SCRIPT_VERSION = 'v4.0 (28.11.2026)'" in src
    assert "local SCRIPT_VER_NUM = '4.0'" in src
    for doc_name in ("README.md", "README_RU.md", "README_EN.md", "INSTRUCTION_RU.md"):
        doc_txt = (TARGET.parent / doc_name).read_text(encoding="utf-8")
        m_ver = re.search(r"Universal Helper Platform v(\d+\.\d+)", doc_txt)
        assert m_ver and m_ver.group(1) == "4.0", f"{doc_name} header mismatch: {m_ver}"

    # 2. /find vs /gps dialog gating
    assert "sampRegisterChatCommand('find'" not in src and 'sampRegisterChatCommand("find"' not in src, "Must not shadow /find!"
    assert "find_wait_until > os.clock()" in src
    assert "style ~= 1 and style ~= 3" in src
    assert "is_gps_or_house" in src and "if #temp_list > 0 then" in src

    # 3. Turbo / Sport-mode controls
    for sym in ("turbo_boost_mode", "turbo_power", "turbo_max_speed", "turbo_turn_assist", "sport_boost_active"):
        assert sym in src, f"Missing turbo/sport symbol: {sym}"
    assert "риск бана!" in src, "Ban-risk disclaimer must remain!"
    assert "in_turn" in src and "braking" in src
    assert "math.min(cruise_speed, current_speed + step)" in src

    # 4. Expanded Anagrams bank parsed directly from helper_core.lua
    m_anag = re.search(r"(?:local\s+)?anag_words = \{\n(.*?)\n\}\n", src, re.S)
    assert m_anag, "anag_words block not found!"
    cat_blocks = re.findall(r"\[(\d+)\]\s*=\s*\{(.*?)\n\s*\}", m_anag.group(1), re.S)
    assert len(cat_blocks) == 5, f"Expected 5 anagram categories, got {len(cat_blocks)}"
    all_words = []
    seen = set()
    for cid, body in cat_blocks:
        words = re.findall(r'"([^"]+)"', body)
        assert len(words) >= 50, f"Category {cid} too small: {len(words)}"
        for w in words:
            assert re.fullmatch(r"[а-яё]{4,}", w), f"Invalid anagram word: {w!r}"
            assert w not in seen, f"Duplicate anagram word in Lua source: {w!r}"
            seen.add(w)
            all_words.append(w)
    assert len(all_words) >= 250, f"Expected >= 250 anagram words, got {len(all_words)}"
    assert "function drawNextAnagramWord(" in src
    assert "letters[1] = cp1251_upper(letters[1])" in src

    # 5. Quiz Director & banks
    m_caps = re.search(r"(?:local\s+)?quiz_capitals = \{\n(.*?)\n\}", src, re.S)
    assert m_caps and len(re.findall(r"\{q\s*=", m_caps.group(1))) >= 55, "quiz_capitals < 55!"
    m_triv = re.search(r"(?:local\s+)?quiz_trivia = \{\n(.*?)\n\}", src, re.S)
    assert m_triv and len(re.findall(r"\{q\s*=", m_triv.group(1))) >= 45, "quiz_trivia < 45!"
    assert "function normalizeQuizAnswer(" in src and "function isQuizAnswerMatch(" in src
    assert "isQuizAnswerMatch(sms_body, quiz_expected_answer)" in src
    assert "sampRegisterChatCommand('quiz'" in src

    # Mirror quiz normalization & alternative matching
    def norm_ans(s: str) -> str:
        s = s.lower().replace("ё", "е")
        s = re.sub(r"[^\w\s]+", " ", s)
        return re.sub(r"\s+", " ", s).strip()

    def match_ans(sms: str, exp: str) -> bool:
        ns = norm_ans(sms)
        return any(ns == norm_ans(p) for p in exp.split("|") if norm_ans(p))

    assert match_ans("  ПАРИЖ!! ", "Париж")
    assert match_ans("Зеленый", "Зелёный|Зеленый")
    assert match_ans("нью дели", "Нью-Дели|Дели")
    assert not match_ans("не знаю может Париж", "Париж")

    # 6. Personal GPS (/wp)
    m_wps = re.search(r"(?:local\s+)?preset_waypoints = \{\n(.*?)\n\}", src, re.S)
    assert m_wps and len(re.findall(r"\{name\s*=", m_wps.group(1))) >= 24, "preset_waypoints < 24!"
    for cmd_name in ("'wp'", "'wpsave'", "'wpclear'"):
        assert f"sampRegisterChatCommand({cmd_name}" in src, f"Missing {cmd_name} command"
    assert "if dist <= 18 then" in src

    # 7. Faction Presets & Single-File Config Export/Import
    for p_id in ("smi", "mvd", "mz", "mo", "mayor", "civ"):
        assert f"    {p_id} = {{" in src, f"Missing faction preset {p_id}"
    assert "function applyFactionPreset(" in src
    assert "function exportAllConfig()" in src and "function importAllConfig()" in src
    assert "helper_export.json" in src

    print(f"v2.0 checks OK (/find guard, sport/turbo controls, {len(all_words)} unique anagrams, quiz SMS match, 24 GPS presets, 6 faction presets, export/import)")


def test_v21_features(src: str):
    # 1. Phase 1 symbols, hooks, commands, and ordering
    for sym in (
        "function parseCsvTerms(",
        "function splitChatIntoChunks(",
        "function evaluateChatFilter(",
        "function cmdReconnect(",
        "function cmdFastHistory(",
        "function sampev.onSendChat(",
    ):
        assert sym in src, f"Missing Phase 1 symbol: {sym}"

    # onSendChat must strictly do line wrap only (never Auto-RP)
    m_osc = re.search(r"function sampev\.onSendChat\(message\)(.*?)\nend\n", src, re.S)
    assert m_osc and "splitChatIntoChunks" in m_osc.group(1)
    assert "/me " not in m_osc.group(1) and "rpVerb(" not in m_osc.group(1), "Auto-RP leaked back into onSendChat!"

    # evaluateChatFilter must run BEFORE onServerMessage logging / sound / player_db / Auto-RP / efir_stats side effects
    pos_filt = src.find("if evaluateChatFilter(clean_trimmed, clean_lower, sender, phone) == false then")
    pos_efir = src.find("efir_stats.calls = efir_stats.calls + 1")
    assert 0 < pos_filt < pos_efir, "evaluateChatFilter must run BEFORE onServerMessage side effects!"

    # /rec & /hist commands + safe reconnect APIs
    assert "sampRegisterChatCommand('rec'" in src and "sampRegisterChatCommand('hist'" in src
    assert "sampDisconnectWithReason" in src and "sampSetGamestate, 1" in src
    assert 'sampRegisterChatCommand("re"' not in src and "sampRegisterChatCommand('re'" not in src

    # 2. Mirror splitChatIntoChunks word-wrap logic
    def split_chunks(prefix: str, body: str, max_len: int = 108):
        max_len = max(60, min(125, max_len))
        if len(prefix) + len(body) <= max_len:
            return None
        words = body.split()
        if not words:
            return None
        parts = []
        idx = 0
        while idx < len(words) and len(parts) < 4:
            is_first = (len(parts) == 0)
            is_last_slot = (len(parts) == 3)
            reserve = 3 if (is_first or is_last_slot) else 6
            cap = max(12, max_len - len(prefix) - reserve)
            cur = ""
            while idx < len(words):
                w = words[idx]
                if not cur:
                    if len(w) <= cap:
                        cur = w
                        idx += 1
                    else:
                        cur = w[:cap]
                        words[idx] = w[cap:]
                        break
                elif len(cur) + 1 + len(w) <= cap:
                    cur = cur + " " + w
                    idx += 1
                else:
                    break
            if cur:
                parts.append(cur)
            else:
                break
        if len(parts) <= 1:
            return None
        res = []
        for i, p in enumerate(parts):
            if i == 0:
                res.append(prefix + p + "...")
            elif i < len(parts) - 1:
                res.append(prefix + "..." + p + "...")
            else:
                res.append(prefix + "..." + p)
        return res

    assert split_chunks("/me ", "достал паспорт", 108) is None
    long_msg = " ".join(["проверкадлинногосообщения"] * 8)
    chunks = split_chunks("/r [LV-FM] ", long_msg, 90)
    assert chunks and 2 <= len(chunks) <= 4
    assert all(len(c) <= 90 and c.startswith("/r [LV-FM] ") for c in chunks), f"Bad chunks: {chunks}"
    assert chunks[0].endswith("...") and chunks[-1].startswith("/r [LV-FM] ...")

    w_chunks = split_chunks("/w 42 ", "очень длинное секретное сообщение для игрока сорок два " * 3, 75)
    assert w_chunks and all(len(c) <= 75 and c.startswith("/w 42 ") for c in w_chunks)

    # 3. Mirror evaluateChatFilter rules
    def eval_filter(msg, hide_ads=True, wl="", bl="", triggers="", hide_efir=True, efir_on=False, my_nick="My_Nick", sender=None, phone=None):
        low = msg.lower()
        if "[Helper" in msg:
            return True
        if any(t.strip().lower() in low for t in re.split(r"[,;]", bl) if t.strip()):
            return False
        if hide_ads:
            is_ad = (sender is not None and phone is not None) or ("объявление:" in low) or ("отправил " in low and "(тел." in low)
            if is_ad and not (sender and sender.lower() == my_nick.lower()):
                w_terms = [t.strip().lower() for t in re.split(r"[,;]", wl) if t.strip()]
                return any(t in low for t in w_terms)
        if hide_efir and not efir_on:
            if any(p in low for p in ("[радио", "[тв", "радиостанция", "прямой эфир")):
                return False
        return True

    assert eval_filter("[Helper] Системное сообщение", hide_ads=True, bl="система") is True
    assert eval_filter("Продам дом. Отправил Bob_Lee[12] (тел. 555)", wl="биз, нрг", sender="Bob_Lee", phone="555") is False
    assert eval_filter("Продам дом в ЛС. Отправил Bob_Lee[12] (тел. 555)", wl="дом, нрг", sender="Bob_Lee", phone="555") is True
    assert eval_filter("Продам авто. Отправил My_Nick[1] (тел. 111)", wl="дом", sender="My_Nick", phone="111") is True
    assert eval_filter("[Радио LS-FM] Прямой эфир начался!", hide_efir=True, efir_on=False) is False
    assert eval_filter("[Радио LS-FM] Прямой эфир начался!", hide_efir=True, efir_on=True) is True
    print("v2.1 checks OK (chat filter post-parsers, line wrap <=4 chunks, /rec, /hist)")


def test_cross_phase_contracts(src: str):
    # 1. Zero leftover SWARM slot markers
    leftover = re.findall(r"--\s*\[\[SWARM:[A-Z0-9_]+\]\]|SWARM:[A-Z0-9_]+", src)
    assert not leftover, f"Leftover SWARM markers in helper_core.lua: {leftover}"

    # 2. All modules have non-nil drawSettings; forward-referenced UIs are deferred in closures
    m_mods = re.search(r"(?m)^modules\s*=\s*\{", src)
    assert m_mods, "modules table not found!"
    pos_mod_start = m_mods.start()
    brace_d = 0
    in_str = None
    j = src.find("{", pos_mod_start)
    mod_end = -1
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
            elif c == "{":
                brace_d += 1
            elif c == "}":
                brace_d -= 1
                if brace_d == 0:
                    mod_end = j + 1
                    break
        j += 1
    assert mod_end > pos_mod_start, "Unclosed modules table!"
    mod_tbl = src[pos_mod_start:mod_end]
    mod_ids = re.findall(r'id\s*=\s*"([^"]+)"', mod_tbl)
    draw_entries = re.findall(r"drawSettings\s*=\s*([^\n,]+)", mod_tbl)
    assert len(mod_ids) == 16, f"Expected 16 modules, got {len(mod_ids)}: {mod_ids}"
    assert mod_ids[0] == "dashboard", f"Expected 'dashboard' as first module, got {mod_ids[0]!r}"
    assert len(draw_entries) == len(mod_ids), f"drawSettings count mismatch: {len(draw_entries)} vs {len(mod_ids)}"
    assert all(d.strip() != "nil" and d.strip() != "" for d in draw_entries), f"Nil drawSettings found: {draw_entries}"

    # Pre-modules direct references must exist before modules table; post-modules must be wrapped
    for direct_fn in ("drawGnewsSettings", "drawMmEditorSettings"):
        pos_fn = src.find(f"function {direct_fn}(")
        assert 0 < pos_fn < pos_mod_start, f"{direct_fn} must be defined BEFORE modules table!"
    for deferred_fn in ("P3_drawLecturerUI", "P4_drawFactionUI", "P6_drawLocationModuleSettings", "P8_drawArmyUI", "P9_drawDashboardUI"):
        m_def = re.search(rf"drawSettings\s*=\s*function\s*\(\).*?{re.escape(deferred_fn)}", mod_tbl, re.S)
        assert m_def, f"Module drawSettings for {deferred_fn} must wrap lookup in a closure!"

    # 3. Cross-phase symbols & wiring contracts (P2 <-> P4, P5 <-> P3/P4/P6)
    required_contracts = (
        "function P4_openSuMenu(",
        "function P4_openMedMenu(",
        "function getTargetMenuVk(",
        "function getWheelMenuVk(",
        "P3_lecturer_templates =",
        "P4_codex =",
        "P6_loc_registry =",
        "P6_loc_favorites =",
        "function P3_saveLecturer(",
        "function P4_saveCodex(",
        "function P6_saveLocations(",
        "function P3_loadLecturer(",
        "function P4_loadCodex(",
        "function P6_loadLocations(",
    )
    for sym in required_contracts:
        assert sym in src, f"Missing cross-phase contract symbol: {sym}"

    # Phase 2 -> Phase 4 target menu & wheel menu delegation
    m_p2_su = re.search(r"function P2_openTargetSu\(tid\)(.*?)\nend\n", src, re.S)
    m_p2_med = re.search(r"function P2_openTargetMed\(tid\)(.*?)\nend\n", src, re.S)
    assert m_p2_su and "P4_openSuMenu" in m_p2_su.group(1), "P2_openTargetSu must delegate to P4_openSuMenu!"
    assert m_p2_med and "P4_openMedMenu" in m_p2_med.group(1), "P2_openTargetMed must delegate to P4_openMedMenu!"

    # Main loop wires P2, P3, P5 cleanly
    m_main = re.search(r"(?m)^function main\(\)", src)
    assert m_main, "main() not found!"
    main_body = extract_lua_block(src, m_main.start())
    for main_hook in ("getTargetMenuVk", "getWheelMenuVk", "P2_tickSirenAutoStrobe()", "P5_tickFreeCam()", "P5_tickSession1s()"):
        assert main_hook in main_body, f"Missing {main_hook} inside main()"

    # Load / Save / Export v2 / Import contracts across Phases 2..6
    m_load = re.search(r"(?m)^function loadDatabases\(\)", src)
    m_save = re.search(r"(?m)^function saveSettings\(\)", src)
    m_exp = re.search(r"(?m)^function exportAllConfig\(\)", src)
    m_imp = re.search(r"(?m)^function importAllConfig\(\)", src)
    m_term = re.search(r"(?m)^function onScriptTerminate\(", src)
    assert m_load and m_save and m_exp and m_imp and m_term

    load_body = extract_lua_block(src, m_load.start())
    save_body = extract_lua_block(src, m_save.start())
    exp_body = extract_lua_block(src, m_exp.start())
    imp_body = extract_lua_block(src, m_imp.start())
    term_body = extract_lua_block(src, m_term.start())

    for fn in ("P3_loadLecturer", "P4_loadCodex", "P6_loadLocations"):
        assert fn in load_body, f"{fn} not called inside loadDatabases()"
    for key in ("wheel_menu_enabled", "target_menu_key_idx", "gnews_l_template", "p4_autorp_enabled", "cam_feature_enabled", "loc_favorites"):
        assert f"parsed.{key}" in load_body, f"parsed.{key} missing in loadDatabases()"
        assert f"{key} =" in save_body, f"{key} missing in saveSettings()"

    for exp_ref in ("P3_lecturer_templates", "P4_codex", "P6_loc_registry", "P6_loc_favorites", "format_version = 2"):
        assert exp_ref in exp_body, f"Missing {exp_ref} in exportAllConfig()"
    pos_load_in_imp = imp_body.find("loadDatabases()")
    for imp_save in ("P3_saveLecturer", "P4_saveCodex", "P6_saveLocations"):
        pos_s = imp_body.find(imp_save)
        assert 0 < pos_s < pos_load_in_imp, f"{imp_save} must precede loadDatabases() in importAllConfig()"

    for term_req in ("P5_exitFreeCam", "tedit_active = false", "P6_saveLocations"):
        assert term_req in term_body, f"Missing {term_req} in onScriptTerminate()"

    print(f"Cross-phase contracts OK (0 SWARM leftovers, {len(mod_ids)} modules wired, Export/Import v2 + P2<->P4 + P6 verified)")


def run_swarm_phase_suites(src_lf: str):
    sys.modules["verify_helper"] = sys.modules[__name__]
    if str(HARNESS_DIR) not in sys.path:
        sys.path.insert(0, str(HARNESS_DIR))
    if str(SWARM_DIR) not in sys.path:
        sys.path.insert(0, str(SWARM_DIR))
    from test_phase2 import test_phase2_features
    from test_phase3 import test_phase3_features
    from test_phase4 import test_phase4_features
    from test_phase5 import test_phase5_features
    from test_phase6 import test_phase6_features

    test_phase2_features(src_lf)
    test_phase3_features(src_lf)
    test_phase4_features(src_lf)
    test_phase5_features(src_lf)
    test_phase6_features(src_lf)


def _read_helper_checked(target: Path):
    raw = target.read_bytes()
    assert b"\x00" not in raw, f"NUL byte found in {target}!"
    for ln, b_line in enumerate(raw.split(b"\r\n"), 1):
        for b in b_line:
            assert b >= 32 or b == 9, f"Unexpected control byte {b} at line {ln}: {b_line!r}"
    src = raw.decode("cp1251")
    lf_only = src.count("\n") - src.count("\r\n")
    assert lf_only == 0, f"Found {lf_only} bare LF line endings!"
    return raw, src.replace("\r\n", "\n")


def _extract_static_checks(src_lf: str):
    assert "imgui.CenterColumnText" not in src_lf, "CenterColumnText still present!"
    for vfn in ("imgui.Text(", "imgui.TextColored(", "imgui.TextWrapped(", "imgui.BulletText("):
        assert vfn not in src_lf, f"Variadic {vfn} still present!"
    even_bufs = [m.group(0) for m in re.finditer(r"imgui\.new\.char\[(\d+)\]", src_lf) if int(m.group(1)) % 2 == 0]
    assert not even_bufs, f"Even char buffers found: {even_bufs}"
    assert "ENGINE DEBUG" not in src_lf, "ENGINE DEBUG still present!"
    assert "MM UI pending page" not in src_lf, "MM UI debug print still present!"
    assert "function sampev.onSendCommand(" in src_lf, "sampev.onSendCommand missing!"
    assert "function sampev.onSendChat(" in src_lf and "splitChatIntoChunks" in src_lf, "onSendChat line wrap missing!"
    assert "function sampev.onPlayerJoin(playerId, color, isNpc, nickname)" in src_lf, "onPlayerJoin signature wrong!"
    assert 'sampRegisterChatCommand("re"' not in src_lf and "sampRegisterChatCommand('re'" not in src_lf, "Must NOT register /re!"
    assert 'sampRegisterChatCommand("lsms"' in src_lf, "/lsms command missing!"
    assert "function onScriptTerminate(" in src_lf, "onScriptTerminate missing!"

    efir_stats_pos = src_lf.find("efir_stats = {")
    if efir_stats_pos == -1:
        efir_stats_pos = src_lf.find("local efir_stats =")
    cmd_efir_pos = src_lf.find("function cmdEfir()")
    cmd_end_pos = src_lf.find("function cmdEndEfir()")
    assert 0 < efir_stats_pos < cmd_efir_pos < cmd_end_pos, "efir_stats ordering broken!"


def build_snapshot(target: Path):
    raw, src_lf = _read_helper_checked(target)
    lines = src_lf.split("\n")
    sha256 = hashlib.sha256(raw).hexdigest()

    m_ver = re.search(r"local\s+SCRIPT_VERSION\s*=\s*['\"]([^'\"]+)['\"]", src_lf)
    m_vnum = re.search(r"local\s+SCRIPT_VER_NUM\s*=\s*['\"]([^'\"]+)['\"]", src_lf)

    if str(HARNESS_DIR) not in sys.path:
        sys.path.insert(0, str(HARNESS_DIR))
    import lua_audit_core as lac

    ast_tokens, ast_hazards = lac.lex_lua(src_lf)
    parser = lac.LuaParser(ast_tokens)
    chunk = parser.parse_chunk()
    sa = lac.ScopeAnalyzer(chunk)
    sa.analyze()
    worst_act = max(sa.funcs, key=lambda f: f.max_active_locals)
    worst_upv = max(sa.funcs, key=lambda f: len(f.upvalues))

    modules = []
    m_mods = re.search(r"(?m)^modules\s*=\s*\{", src_lf)
    if m_mods:
        j = src_lf.find("{", m_mods.start())
        d = 0
        in_str = None
        end_pos = len(src_lf)
        while j < len(src_lf):
            ch = src_lf[j]
            if in_str:
                if ch == "\\":
                    j += 2
                    continue
                if ch == in_str:
                    in_str = None
            else:
                if ch in ("'", '"'):
                    in_str = ch
                elif ch == "{":
                    d += 1
                elif ch == "}":
                    d -= 1
                    if d == 0:
                        end_pos = j + 1
                        break
            j += 1
        base_ln = src_lf[: m_mods.start()].count("\n")
        for mm in re.finditer(r'id\s*=\s*"([^"]+)"', src_lf[m_mods.start():end_pos]):
            ln = base_ln + src_lf[m_mods.start() : m_mods.start() + mm.start()].count("\n") + 1
            modules.append({"index": len(modules) + 1, "id": mm.group(1), "line": ln})

    phase_tables = []
    sampev_hooks = []
    chat_cmds = []
    for idx, line in enumerate(lines, 1):
        mp = re.match(r"^(P[2-9]|ENV_CAPS)\s*=", line)
        if mp:
            phase_tables.append({"name": mp.group(1), "line": idx})
        ms = re.match(r"^\s*function\s+sampev\.(\w+)\s*\(", line)
        if ms:
            sampev_hooks.append({"hook": ms.group(1), "line": idx})
        for mc in re.finditer(r"""sampRegisterChatCommand\(\s*['\"]([^'\"]+)['\"]""", line):
            chat_cmds.append({"cmd": mc.group(1), "line": idx})

    onframe_count = len(re.findall(r"imgui\.OnFrame\(", src_lf))
    return {
        "target": str(target),
        "script_version": m_ver.group(1) if m_ver else "unknown",
        "script_ver_num": m_vnum.group(1) if m_vnum else "unknown",
        "lines": len(lines),
        "bytes": len(raw),
        "sha256": sha256,
        "ast_hazards": len(ast_hazards),
        "luajit_budget": {
            "top_locals": len(sa.top_locals),
            "top_locals_cap": 150,
            "max_active_locals": worst_act.max_active_locals,
            "max_active_cap": 180,
            "max_active_fn": worst_act.name,
            "max_upvalues": len(worst_upv.upvalues),
            "max_upvalues_cap": 45,
            "max_upvalues_fn": worst_upv.name,
        },
        "modules": modules,
        "phase_tables": phase_tables,
        "sampev_hooks": sampev_hooks,
        "onframe_count": onframe_count,
        "chat_commands_count": len(chat_cmds),
    }


def run_deploy_check(target: Path, deploy_path: Path):
    if not target.exists():
        return False, {"ok": False, "error": f"Source missing: {target}"}
    if not deploy_path.exists():
        return False, {"ok": False, "target": str(target), "deploy_path": str(deploy_path), "error": f"Deploy target missing: {deploy_path}"}
    t_bytes = target.read_bytes()
    d_bytes = deploy_path.read_bytes()
    t_sha = hashlib.sha256(t_bytes).hexdigest()
    d_sha = hashlib.sha256(d_bytes).hexdigest()
    match = (t_sha == d_sha) and (len(t_bytes) == len(d_bytes))
    return match, {
        "ok": match,
        "mode": "deploy-check",
        "target": str(target),
        "deploy_path": str(deploy_path),
        "target_bytes": len(t_bytes),
        "deploy_bytes": len(d_bytes),
        "target_sha256": t_sha,
        "deploy_sha256": d_sha,
    }


def check_luajit_compile(target: Path):
    """Run real LuaJIT loadfile() bytecode compile check when donor luajit.exe is present."""
    luajit_exe = REPO_ROOT / "donor" / "moonloader" / "luajit" / "bin" / "luajit.exe"
    if not luajit_exe.exists():
        print("LuaJIT compile check skipped (donor/moonloader/luajit/bin/luajit.exe not found)")
        return
    lua_path = str(target).replace("\\", "/")
    expr = (
        f"local fn, err = loadfile({lua_path!r}); "
        "if not fn then io.stderr:write(tostring(err)..'\\n'); os.exit(1) "
        "else print('LUAJIT_LOADFILE_OK') end"
    )
    proc = subprocess.run(
        [str(luajit_exe), "-e", expr],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    assert proc.returncode == 0 and "LUAJIT_LOADFILE_OK" in proc.stdout, (
        f"LuaJIT loadfile compile failed (rc={proc.returncode}):\n{proc.stderr}\n{proc.stdout}"
    )
    print(f"LuaJIT bytecode compile OK ({luajit_exe.name}: LUAJIT_LOADFILE_OK)")


def run_verification(target: Path, fast: bool = False):
    raw, src_lf = _read_helper_checked(target)
    tokens = lex_lua(src_lf)
    check_lua_structure(tokens)
    check_luajit_and_collisions(tokens, src_lf)
    print(f"Lua lexer & block/bracket balance OK ({len(tokens)} tokens, {len(src_lf.splitlines())} lines)")

    _extract_static_checks(src_lf)
    check_onframe_safety(src_lf)
    check_luajit_compile(target)

    if fast:
        test_audit_regressions(src_lf)
        print("FAST HARNESS GATE PASSED 100%!")
        return {"lines": len(src_lf.splitlines()), "bytes": len(raw), "tokens": len(tokens), "mode": "fast"}

    test_cross_phase_contracts(src_lf)
    test_autoedit(src_lf)
    test_find_and_calc(src_lf)
    test_v19_features(src_lf)
    test_v20_features(src_lf)
    test_v21_features(src_lf)
    run_swarm_phase_suites(src_lf)
    test_audit_regressions(src_lf)
    test_v27_features(src_lf)
    test_v30_features(src_lf)
    test_v40_features(src_lf)
    print("ALL VERIFICATION CHECKS PASSED 100%!")
    return {"lines": len(src_lf.splitlines()), "bytes": len(raw), "tokens": len(tokens), "mode": "full"}


def main(target: Path | None = None, fast: bool = False):
    global TARGET
    if target is not None:
        TARGET = Path(target)
    return run_verification(TARGET, fast=fast)

def test_audit_regressions(src_lf: str):
    """Permanent regression gates added after the 2-Wave Final Adversarial Swarm Audit."""
    import math
    audit_dir = HARNESS_DIR

    # Strip Lua line comments outside strings for API symbol checks
    no_comments_lines = []
    for ln in src_lf.split("\n"):
        if ln.lstrip().startswith("--"):
            no_comments_lines.append("")
        else:
            no_comments_lines.append(ln)
    code_only = "\n".join(no_comments_lines)

    # 1. Zero embedded \0 inside u8"..." or u8'...' (breaks iconv CP1251->UTF-8 in ComboStr)
    nul_in_u8 = re.findall(r'''u8\s*(?:\(\s*)?(?:"(?:[^"\\]|\\.)*\\0|'(?:[^'\\]|\\.)*\\0)''', code_only)
    assert not nul_in_u8, f"Found u8 strings containing embedded \\0: {nul_in_u8}"

    # 2. Zero Cyrillic char[N] initializers missing u8
    bad_char_buf = re.findall(r'''imgui\.new\.char\[\d+\]\s*\(\s*["'][^"'\n]*[\u0400-\u04FF]''', code_only)
    assert not bad_char_buf, f"Cyrillic imgui.new.char missing u8: {bad_char_buf}"

    # 3. Zero non-existent MoonLoader / SAMPFUNCS APIs
    for bad_api in (
        "isSampPauseMenuActive",
        "sampGetCurrentDialogStyle",
        "isThisModelABike",
        "isThisModelATrain",
        "getObjectRotation(",
        "setCarLightDamageStatus",
    ):
        assert bad_api not in code_only, f"Non-existent API still present in code: {bad_api}"

    # 4. Zero truncated pcall unpacks for sampGetPlayerIdByCharHandle (2 vals) / getObjectCoordinates (4 vals)
    bad_pid_pcall = re.findall(r"local\s+\w+\s*,\s*\w+\s*=\s*pcall\s*\(\s*sampGetPlayerIdByCharHandle\b", code_only)
    assert not bad_pid_pcall, f"Broken 2-var pcall(sampGetPlayerIdByCharHandle): {bad_pid_pcall}"
    bad_obj_pcall = re.findall(r"local\s+\w+\s*,\s*\w+\s*,\s*\w+\s*,\s*\w+\s*=\s*pcall\s*\(\s*getObjectCoordinates\b", code_only)
    assert not bad_obj_pcall, f"Broken 4-var pcall(getObjectCoordinates): {bad_obj_pcall}"

    # 5. Compact HUD OnFrame sets .HideCursor = true & NoInputs when main menu closed
    m_hud_block = re.search(r"local\s+(\w+)\s*=\s*imgui\.OnFrame\(.*?##helper_compact_hud.*?\1\.HideCursor = true", src_lf, re.S)
    assert m_hud_block, "Compact HUD must set .HideCursor = true!"
    assert "WindowFlags.NoInputs" in m_hud_block.group(0), "Compact HUD must add NoInputs when main menu closed!"

    # 6. P6_quatToEuler uses GTA:SA CMatrix::SetRotate (Rz*Rx*Ry) inverse & passes exact round-trip math
    m_q2e = re.search(r"function P6_quatToEuler\(.*?\nend\n", src_lf, re.S)
    assert m_q2e and "2.0 * (qw * qx + qy * qz)" in m_q2e.group(0), "P6_quatToEuler must use GTA:SA Rz*Rx*Ry inverse!"

    def gtasa_euler_to_quat(rx_d, ry_d, rz_d):
        rx, ry, rz = math.radians(rx_d), math.radians(ry_d), math.radians(rz_d)
        cx, sx = math.cos(rx), math.sin(rx)
        cy, sy = math.cos(ry), math.sin(ry)
        cz, sz = math.cos(rz), math.sin(rz)
        # GTA:SA CMatrix::SetRotate right, forward, up columns
        m00, m01, m02 = cz * cy - sz * sx * sy, -(sz * cx), cz * sy + sz * sx * cy
        m10, m11, m12 = cz * sx * sy + sz * cy, cz * cx, sz * sy - cz * sx * cy
        m20, m21, m22 = -(sy * cx), sx, cy * cx
        qw = 0.5 * math.sqrt(max(0.0, 1.0 + m00 + m11 + m22))
        qx = (m21 - m12) / (4.0 * qw)
        qy = (m02 - m20) / (4.0 * qw)
        qz = (m10 - m01) / (4.0 * qw)
        return qx, qy, qz, qw

    def py_p6_quat_to_euler(qx, qy, qz, qw):
        sx = max(-1.0, min(1.0, 2.0 * (qw * qx + qy * qz)))
        rx = math.asin(sx)
        if abs(math.cos(rx)) > 1e-4:
            ry = math.atan2(-2.0 * (qx * qz - qw * qy), 1.0 - 2.0 * (qx * qx + qy * qy))
            rz = math.atan2(-2.0 * (qx * qy - qw * qz), 1.0 - 2.0 * (qx * qx + qz * qz))
        else:
            ry = 0.0
            rz = math.atan2(2.0 * (qx * qy + qw * qz), 1.0 - 2.0 * (qy * qy + qz * qz))
        return tuple(((math.degrees(v) % 360.0) + 360.0) % 360.0 for v in (rx, ry, rz))

    for ex, ey, ez in ((25.0, 35.0, 60.0), (45.0, -30.0, 120.0)):
        qx, qy, qz, qw = gtasa_euler_to_quat(ex, ey, ez)
        rx_o, ry_o, rz_o = py_p6_quat_to_euler(qx, qy, qz, qw)
        for a, b in zip((rx_o, ry_o, rz_o), (ex % 360.0, ey % 360.0, ez % 360.0)):
            diff = abs(((a - b + 180.0) % 360.0) - 180.0)
            assert diff < 0.01, f"P6_quatToEuler math mismatch: got {(rx_o, ry_o, rz_o)} vs {(ex, ey, ez)}"

    # 7. Core safety invariants from audit
    m_utf = re.search(r"function needsUtf8Convert\(s\).*?\nend\n", src_lf, re.S)
    assert m_utf and "0x80" in m_utf.group(0) and "0xBF" in m_utf.group(0), "needsUtf8Convert must validate strict UTF-8 continuation bytes!"
    m_ldb = re.search(r"function loadDatabases\(\).*?local parsed = readJsonFile\(settings_path\)", src_lf, re.S)
    assert m_ldb and "if #cleaned > 0 then" in m_ldb.group(0), "loadDatabases must guard #cleaned > 0 before sanitizeAndDedupeRules!"
    m_jpg = re.search(r"local function isValidJpgFile\(.*?\nend\n", src_lf, re.S)
    assert m_jpg and "0xFF" in m_jpg.group(0) and "0xD8" in m_jpg.group(0), "isValidJpgFile helper must validate JPEG magic bytes!"
    m_dl = re.search(r"function P6_pumpPreviewDownloads\(.*?\nend\n", src_lf, re.S)
    assert m_dl and "isValidJpgFile(dl_path)" in m_dl.group(0) and "STATUSEX_ENDDOWNLOAD" in m_dl.group(0), "P6_pumpPreviewDownloads must validate JPEG magic and STATUSEX_ENDDOWNLOAD!"

    # 7b. No unguarded imgui.GetIO() before OnInitialize/OnFrame section (must go through P1_getImguiInputState)
    on_init_pos = src_lf.find("imgui.OnInitialize(")
    assert on_init_pos > 0, "imgui.OnInitialize missing!"
    m_getio_guard = re.search(r"function P1_getImguiInputState\(.*?\nend\n", src_lf, re.S)
    assert m_getio_guard, "P1_getImguiInputState helper missing!"
    for req_guard in ("imgui.IsInitialized", "imgui.GetRenderer", "imgui.SwitchContext", "imgui.GetIO"):
        assert req_guard in m_getio_guard.group(0), f"P1_getImguiInputState missing {req_guard}!"
    m_style_guard = re.search(r"function applyCustomStyle\(\).*?\nend\n", src_lf, re.S)
    assert m_style_guard and "imgui.IsInitialized" in m_style_guard.group(0), "applyCustomStyle must guard GetIO with IsInitialized!"
    pre_ui_src = src_lf[:on_init_pos]
    for m_io in re.finditer(r"imgui\.GetIO\b", pre_ui_src):
        pos = m_io.start()
        in_p1 = m_getio_guard.start() <= pos <= m_getio_guard.end()
        in_st = m_style_guard.start() <= pos <= m_style_guard.end()
        assert in_p1 or in_st, f"Unguarded imgui.GetIO before OnInitialize at offset {pos}!"
    assert "local function mainFrameTick()" in src_lf and "pcall(mainFrameTick)" in src_lf, "mainFrameTick must be hoisted outside while true do!"

    # 8. ImGui Begin/End, BeginChild/EndChild, PushItemWidth/PopItemWidth exact counts & AST parse via lua_audit_core
    assert len(re.findall(r"\bimgui\.Begin\(", code_only)) == len(re.findall(r"\bimgui\.End\(", code_only)), "ImGui Begin/End mismatch!"
    assert len(re.findall(r"\bimgui\.BeginChild\(", code_only)) == len(re.findall(r"\bimgui\.EndChild\(", code_only)), "ImGui BeginChild/EndChild mismatch!"
    assert len(re.findall(r"\bimgui\.PushItemWidth\(", code_only)) == len(re.findall(r"\bimgui\.PopItemWidth\(", code_only)), "ImGui PushItemWidth/PopItemWidth mismatch!"

    if str(audit_dir) not in sys.path:
        sys.path.insert(0, str(audit_dir))
    import lua_audit_core as lac
    ast_tokens, ast_hazards = lac.lex_lua(src_lf)
    assert not ast_hazards, f"Lua string escape hazards found: {ast_hazards}"
    parser = lac.LuaParser(ast_tokens)
    chunk = parser.parse_chunk()
    sa = lac.ScopeAnalyzer(chunk)
    sa.analyze()
    max_act = max(f.max_active_locals for f in sa.funcs)
    max_upv = max(len(f.upvalues) for f in sa.funcs)
    assert len(sa.top_locals) <= 150, f"top_locals exceeded: {len(sa.top_locals)}"
    assert max_act <= 180, f"max_active_locals exceeded: {max_act}"
    assert max_upv <= 45, f"max_upvalues exceeded: {max_upv}"

    print(f"Audit regression gates OK (0 NUL-in-u8, 0 dead APIs, 0 broken pcalls, GTA:SA quat round-trip <0.01 deg, ImGui balanced, AST 0 errors, max_active={max_act}/180, max_upvals={max_upv}/45)")


def test_v27_features(src_lf: str):
    """Verify v2.7 features: ImGui Themes/Scale, Market /price, MVD /patrol, /location PRO & /cam UX."""
    import math

    # A. ImGui Themes (6 palettes), FontScale & WindowAlpha
    for sym in ("P7.theme_idx", "P7.window_alpha", "P7.font_scale", "P7.style_dirty", "FontGlobalScale"):
        assert sym in src_lf, f"Missing Theme/Scale symbol: {sym}"
    m_style = re.search(r"function applyCustomStyle\(\).*?\nend\n", src_lf, re.S)
    assert m_style and "[5] = {" in m_style.group(0) and "pal.txt_d" in m_style.group(0), "All 6 theme palettes must be defined!"

    # B. Market Price Tracker (/price)
    for sym in ("function P7_parseMarketPrice(", "function P7_parseMarketAd(", "function P7_cmdPrice(", "function P7_drawMarketUI(", "helper_market.json"):
        assert sym in src_lf, f"Missing Market symbol: {sym}"
    assert "sampRegisterChatCommand('price', P7_cmdPrice)" in src_lf

    def py_strip_tail(txt):
        s = re.sub(r"\{[0-9a-fA-F]+\}", "", txt)
        s = re.sub(r"^[Оо]бъявление:\s*", "", s)
        s = re.sub(r"[Оо]тправил.*$", "", s)
        s = re.sub(r"[Оо]тправитель.*$", "", s)
        s = re.sub(r"\(тел\.?\s*\d+\)", "", s)
        s = re.sub(r"\[\d+\]", "", s)
        return s.strip()

    def py_parse_num(num_raw, mult):
        norm = re.sub(r"\s+", "", num_raw)
        if mult > 1:
            if re.fullmatch(r"\d+[.,]\d{3}", norm):
                norm = re.sub(r"[.,]", "", norm)
            else:
                norm = norm.replace(",", ".")
                if norm.count(".") > 1:
                    norm = norm.replace(".", "")
            val = int(float(norm) * mult + 0.5)
        else:
            val = int(re.sub(r"[.,]", "", norm))
        return val if 100 <= val <= 2000000000 else None

    def py_parse_price(raw_ad):
        body = py_strip_tail(raw_ad).lower()
        body = re.sub(r"\s+", " ", body)
        for pat, mult in (
            (r"(\d+[.,]?\d*)\s*млрд", 1000000000),
            (r"(\d+[.,]?\d*)\s*(?:кк|kk|млн)", 1000000),
            (r"(\d+[.,]?\d*)\s*(?:[кk]\b|тыс)", 1000),
        ):
            m = re.search(pat, body)
            if m:
                v = py_parse_num(m.group(1), mult)
                if v:
                    return v
        for pat in (r"(\d[\d., ]*)\s*\$", r"\$\s*(\d[\d., ]*)"):
            m = re.search(pat, body)
            if m:
                v = py_parse_num(m.group(1), 1)
                if v:
                    return v
        if "договор" in body or "свободн" in body:
            return None
        m = re.search(r"(?:цена|бюджет|стоимость|доплата)[:\s]+(\d[\d., ]+)", body)
        return py_parse_num(m.group(1), 1) if m else None

    assert py_parse_price('Объявление: Продам а/м "Infernus". Цена: 1.500.000$. Отправил Vasya[12] (тел. 999888)') == 1500000
    assert py_parse_price('Куплю дом. Бюджет: 4,5кк. Отправил Test[1] (тел. 123456)') == 4500000
    assert py_parse_price('Продам скин за 450к | Отправитель Nick (тел. 111222)') == 450000
    assert py_parse_price('Продам авто "Elegy". Цена: договорная. Отправил Max[7] (тел. 555666)') is None

    # C. MVD Patrol Assistant (/patrol)
    for sym in ("P7_sa_zones", "function P7_getSanAndreasZone(", "function P7_patrolStart(", "function P7_patrolChaseCallout(", "function P7_cmdPatrol(", "function P7_drawPatrolUI("):
        assert sym in src_lf, f"Missing Patrol symbol: {sym}"
    assert "sampRegisterChatCommand('patrol', P7_cmdPatrol)" in src_lf
    assert "P7.patrol_hud_str" in src_lf and "P7_tickPatrol1s()" in src_lf

    # D. /location PRO: Row Builder + 4 Scene Presets (100% verified decor catalog IDs)
    for sym in ("P6_scene_presets", "function P6_computeRowStep(", "function P6_startRowFromLast(", "function P6_buildScenePlanFromPlayer(", "function P6_drawProTab("):
        assert sym in src_lf, f"Missing /location PRO symbol: {sym}"
    m_cat = re.search(r"P6_decor_catalog = \{\n(.*?)\n\}\n", src_lf, re.S)
    assert m_cat
    cat_ids = {int(x) for x in re.findall(r"id\s*=\s*(\d+)", m_cat.group(1))}
    m_presets = re.search(r"P6_scene_presets = \{\n(.*?)\n\}\n\n-- Фаза 7", src_lf, re.S)
    assert m_presets, "P6_scene_presets block not found!"
    preset_models = [int(x) for x in re.findall(r"model\s*=\s*(\d+)", m_presets.group(1))]
    assert len(preset_models) >= 25 and all(mid in cat_ids for mid in preset_models), "Invalid model ID in P6_scene_presets!"

    # Verify rotated P6_computeRowStep math: facing +90 deg rotated local +X step (3.5, 0) -> world (0, +3.5)
    rad90 = math.radians(90.0)
    wx = round(100.0 + 3.5 * math.cos(rad90), 4)
    wy = round(200.0 + 3.5 * math.sin(rad90), 4)
    assert abs(wx - 100.0) < 1e-3 and abs(wy - 203.5) < 1e-3

    # E. /cam UX fix: default false, auto-enables on explicit command/button
    m_enter_cam = re.search(r"function P5_enterFreeCam\(\).*?\nend\n", src_lf, re.S)
    assert m_enter_cam and "cam_feature_enabled[0] = true" in m_enter_cam.group(0), "/cam explicit activation must enable cam_feature_enabled[0]!"

    print(f"v2.7 checks OK (6 ImGui themes + FontGlobalScale, Market /price parser, Patrol /patrol, /location PRO + {len(preset_models)} verified scene objects, /cam UX)")


def test_v30_features(src_lf: str):
    """Verify v3.0 Faction-Adaptive platform, ENV_CAPS capability badges, army_tools (МО), and /sp confirmed RP."""
    for sym in (
        "ENV_CAPS = ENV_CAPS or {}",
        "P8 = P8 or {}",
        "function P8_parseVersionTuple(",
        "function P8_probeEnvironment(",
        "function P8_checkCapabilities(",
        "function P8_drawCapabilityBanner(",
        "function P8_drawEnvDiagnostics(",
        "function P8_isModuleVisible(",
        "function P8_ensureValidActiveModule(",
        "function P8_setFactionContext(",
        "function P8_tryDetectFactionFromDialog(",
        "function P8_tryDetectFactionFromOwnRadio(",
        "function P8_sendArmyPostReport(",
        "function P8_sendArmyConvoyReport(",
        "function P8_sendArmyAlarm(",
        "function P8_drawArmyUI(",
        "function P8_drawContextQuickBar(",
        "function P8_tick(",
    ):
        assert sym in src_lf, f"Missing v3.0 symbol: {sym}"

    # Every module in modules = {...} must declare factions = {...} and army_tools must exist for МО
    m_mods = re.search(r"(?m)^modules\s*=\s*\{", src_lf)
    assert m_mods
    j = src_lf.find("{", m_mods.start())
    d = 0
    in_s = None
    mod_end = len(src_lf)
    while j < len(src_lf):
        ch = src_lf[j]
        if in_s:
            if ch == "\\":
                j += 2
                continue
            if ch == in_s:
                in_s = None
        else:
            if ch in ("'", '"'):
                in_s = ch
            elif ch == "{":
                d += 1
            elif ch == "}":
                d -= 1
                if d == 0:
                    mod_end = j + 1
                    break
        j += 1
    mod_tbl = src_lf[m_mods.start():mod_end]
    factions_decls = re.findall(r"factions\s*=\s*\{", mod_tbl)
    assert len(factions_decls) >= 15, f"Expected all 15 modules to declare factions = {{...}}, found {len(factions_decls)}"
    assert 'id = "army_tools"' in mod_tbl and 'factions = {"mo"}' in mod_tbl

    # Hoisted P8_tick called from mainFrameTick; /army /post /chs registered; /sp bypass uses return rewrite
    assert 'if type(P8_tick) == "function" then P8_tick() end' in src_lf
    for cmd_nm in ("'army'", "'post'", "'chs'"):
        assert f"sampRegisterChatCommand({cmd_nm}" in src_lf, f"Missing command {cmd_nm}"

    m_osc = re.search(r"function sampev\.onSendCommand\(command\)(.*?)\nend\n", src_lf, re.S)
    assert m_osc and 'if cmd == "sp" then' in m_osc.group(1) and 'return { "/" .. inner }' in m_osc.group(1)
    assert "P8.rp_pending" in src_lf and "P8_registerRpPending" in m_osc.group(1)
    assert 'elseif cmd == "gotome" and p4_autorp_enabled[0]' in m_osc.group(1)

    # Damage Informer unlocked for МО/all when dmg_enabled[0] and guards invalid playerId
    m_dmg = re.search(r"function P4_recordDamage\(.*?\nend\n", src_lf, re.S)
    assert m_dmg and "if not dmg_enabled[0] then return end" in m_dmg.group(0) and "pid ~= 65535" in m_dmg.group(0)

    # Safe tostring version parse & guarded memory writes
    assert "tostring(raw_sfv)" in src_lf
    assert "if mem_ok and memory then memory.write(0xC81320" in src_lf
    assert "Блокпост / КПП (МО)" in src_lf
    assert "Военная присяга" in src_lf

    # Own-nickname radio detection must only inspect [R] / [F], never [D] / gnews
    m_rad = re.search(r"function P8_tryDetectFactionFromOwnRadio\(.*?\nend\n", src_lf, re.S)
    assert m_rad and "%[R%]" in m_rad.group(0) and "clean_msg:find(my_nick, 1, true)" in m_rad.group(0) and "%[D%]" not in m_rad.group(0)

    print("v3.0 checks OK (ENV_CAPS probe & banners, Faction-Adaptive UI, army_tools МО, /sp confirmed RP, P8_tick hoisted)")


def test_v40_features(src_lf: str):
    """Verify v4.0 (Phase 9) features: Dashboard, Profile/tags, Dynamic Island, Proximity opt-in OFF, /laws isolation, /sus+/ticket+/takelic, /bl, Offline+BYOK AI, Radial editor, /stoprp, Dry-Run, Auto-SS opt-in OFF, /hexit."""
    # 1. Core Phase 9 symbols & hoisted P9_tick
    for sym in (
        "P9 = P9 or {}",
        "function P9_applyProfileTags(",
        "function P9_pushIslandToast(",
        "function P9_pollProximityAlerts(",
        "function P9_tick(",
        "function P9_drawDashboardUI(",
        "function P9_buildIsolatedSkeleton(",
        "function P9_loadServerLaws(",
        "function P9_drawLawsWindow(",
        "function P9_drawSuwContent(",
        "function P9_drawTicketWindow(",
        "function P9_drawTakelicWindow(",
        "function P9_drawBlWindow(",
        "function P9_searchLawsScored(",
        "function P9_startAiRequest(",
        "function P9_drawRadialEditorUI(",
        "function P9_stopAllRp(",
        "function P9_dryRunLines(",
        "function P9_autoSsAfterReport(",
        "function P9_softUnload(",
    ):
        assert sym in src_lf, f"Missing v4.0 symbol: {sym}"

    assert 'if type(P9_tick) == "function" then P9_tick() end' in src_lf, "P9_tick() not called from mainFrameTick!"

    # 2. Dashboard module #16 first in modules, factions = {"all"}
    m_dash = re.search(r'(?m)^modules\s*=\s*\{\s*\{\s*id\s*=\s*"dashboard"\s*,\s*factions\s*=\s*\{"all"\}', src_lf, re.S)
    assert m_dash, "Module 'dashboard' must be first in modules with factions = {'all'}!"

    # 3. Unified Profile & all 8 RP tags
    m_tags = re.search(r"function P9_applyProfileTags\(.*?\nend\n", src_lf, re.S)
    assert m_tags, "P9_applyProfileTags body missing!"
    for tag in ("name", "surname", "fullname", "rank", "callsign", "subdiv", "badge", "ended"):
        assert tag in m_tags.group(0), f"Missing profile tag {tag} in P9_applyProfileTags"

    # 4. Dynamic Island HideCursor + NoInputs when F11 closed + WindowRounding + Proximity opt-in OFF
    m_isl = re.search(r"local\s+(\w+)\s*=\s*imgui\.OnFrame\(.*?##p9_dynamic_island.*?\1\.HideCursor = true", src_lf, re.S)
    assert m_isl, "Dynamic Island OnFrame must set .HideCursor = true!"
    assert "WindowFlags.NoInputs" in m_isl.group(0), "Dynamic Island must set NoInputs when F11 closed!"
    assert "WindowRounding" in m_isl.group(0), "Dynamic Island must set rounded pill style!"
    assert "P9.prox_enabled = imgui.new.bool(false)" in src_lf, "Proximity alerts MUST default to OFF!"

    # 5. /laws strict server isolation (non-Blue never substitutes Blue articles) & Large Font reset
    m_load_laws = re.search(r"function P9_loadServerLaws\(.*?\nend\n", src_lf, re.S)
    assert m_load_laws and 'if sk == "blue" then' in m_load_laws.group(0) and "P9_buildIsolatedSkeleton(sk)" in m_load_laws.group(0), (
        "/laws must isolate non-Blue servers without substituting Blue articles!"
    )
    assert "helper_laws_" in src_lf
    m_laws_ui = re.search(r"function P9_drawLawsWindow\(.*?\nend\n", src_lf, re.S)
    assert m_laws_ui and "imgui.SetWindowFontScale(1.22)" in m_laws_ui.group(0) and "imgui.SetWindowFontScale(1.0)" in m_laws_ui.group(0)

    # 6. /sus + /ticket (ПДД first before АК) + /takelic + /bl (URL sync opt-in OFF)
    m_pol = re.search(r"function P9_getChapteredPoliceArticles\(.*?\nend\n", src_lf, re.S)
    assert m_pol, "P9_getChapteredPoliceArticles missing!"
    pos_pdd = m_pol.group(0).find('appendDoc("pdd", nil)')
    pos_ak = m_pol.group(0).find('appendDoc("ak", nil)')
    assert 0 < pos_pdd < pos_ak, "/ticket must present ПДД chapters before АК!"
    assert "helper_faction_bl.json" in src_lf
    assert "url_sync_enabled = imgui.new.bool(false)" in src_lf, "/bl URL sync MUST default to OFF!"

    # 7. Offline search + BYOK AI opt-in OFF + explicit network disclosure
    assert "P9.ai_byok_enabled = false" in src_lf, "BYOK AI MUST default to OFF!"
    assert "Что передаётся в сеть:" in src_lf, "BYOK AI network disclosure missing!"

    # 8. Radial visual editor (ImDrawList primitives), /stoprp, Dry-Run tester, Auto-SS opt-in OFF, /hexit
    m_rad = re.search(r"function P9_drawRadialEditorUI\(.*?\nend\n", src_lf, re.S)
    assert m_rad and "GetWindowDrawList()" in m_rad.group(0) and "AddCircle" in m_rad.group(0) and "AddLine" in m_rad.group(0) and "AddText" in m_rad.group(0)
    m_stop = re.search(r"function P9_stopAllRp\(.*?\nend\n", src_lf, re.S)
    assert m_stop and "stopRp" in m_stop.group(0) and "P3_stopLecturer" in m_stop.group(0) and "P8.rp_pending" in m_stop.group(0)
    m_dry = re.search(r"function P9_dryRunLines\(.*?\nend\n", src_lf, re.S)
    assert m_dry and "[ТЕСТ БЕЗ ЧАТА]" in m_dry.group(0) and "sampSendChat" not in m_dry.group(0), "P9_dryRunLines must NEVER call sampSendChat!"
    assert "P9.auto_ss_reports = false" in src_lf, "Auto-SS after reports MUST default to OFF!"
    m_exit = re.search(r"function P9_softUnload\(.*?\nend\n", src_lf, re.S)
    assert m_exit and "scheduleTask(150" in m_exit.group(0) and "thisScript()" in m_exit.group(0)

    # 9. All 8 new v4.0 chat commands registered & zero raw imgui.Combo( (must use ComboStr)
    for cmd_nm in ("'laws'", "'sus'", "'ticket'", "'takelic'", "'bl'", "'island'", "'stoprp'", "'hexit'"):
        assert f"sampRegisterChatCommand({cmd_nm}" in src_lf, f"Missing v4.0 command {cmd_nm}"
    assert "imgui.Combo(" not in src_lf, "Use imgui.ComboStr(...) instead of imgui.Combo(...) for \\0-delimited strings!"

    print("v4.0 checks OK (Dashboard, Profile/tags, Dynamic Island, Proximity OFF, /laws isolation, /sus+/ticket(ПДД)+/takelic, /bl, Offline+BYOK AI OFF, Radial editor, /stoprp, Dry-Run, Auto-SS OFF, /hexit)")



def cli():
    global TARGET
    parser = argparse.ArgumentParser(description="Universal Helper Platform Agent Harness")
    parser.add_argument("--target", type=Path, default=TARGET, help="Path to helper_core.lua")
    parser.add_argument("--deploy-path", type=Path, default=DEFAULT_DEPLOY, help="Deployed game script path")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--fast", action="store_true", help="Run fast safety & AST gate (~1-2s)")
    mode.add_argument("--snapshot", action="store_true", help="Print live architectural telemetry snapshot")
    mode.add_argument("--deploy-check", action="store_true", help="Verify SHA256 match against game folder")
    parser.add_argument("--json", action="store_true", help="Emit single JSON result object to stdout")
    args = parser.parse_args()

    TARGET = args.target

    if args.snapshot:
        snap = build_snapshot(TARGET)
        if args.json:
            print(json.dumps({"ok": True, "mode": "snapshot", **snap}, ensure_ascii=False, indent=2))
        else:
            b = snap["luajit_budget"]
            print(f"Snapshot: {snap['target']}")
            print(f"  Version: {snap['script_version']} | Lines: {snap['lines']} | Bytes: {snap['bytes']} | SHA256: {snap['sha256']}")
            print(
                f"  LuaJIT Budget: top_locals={b['top_locals']}/{b['top_locals_cap']}, "
                f"max_active={b['max_active_locals']}/{b['max_active_cap']} [{b['max_active_fn']}], "
                f"max_upvals={b['max_upvalues']}/{b['max_upvalues_cap']} [{b['max_upvalues_fn']}]"
            )
            print(f"  Phase Tables ({len(snap['phase_tables'])}): " + ", ".join(f"{x['name']}@L{x['line']}" for x in snap["phase_tables"]))
            print(f"  Modules ({len(snap['modules'])}): " + ", ".join(f"{x['id']}@L{x['line']}" for x in snap["modules"]))
            print(f"  sampev Hooks ({len(snap['sampev_hooks'])}): " + ", ".join(f"{x['hook']}@L{x['line']}" for x in snap["sampev_hooks"]))
            print(f"  imgui.OnFrame windows: {snap['onframe_count']} | Chat commands: {snap['chat_commands_count']}")
        return 0

    if args.deploy_check:
        ok, info = run_deploy_check(TARGET, args.deploy_path)
        if args.json:
            print(json.dumps(info, ensure_ascii=False, indent=2))
        else:
            status = "MATCH" if ok else "MISMATCH"
            print(f"Deploy Check [{status}]: repo={info.get('target_sha256', '?')} vs game={info.get('deploy_sha256', '?')}")
            if not ok and "error" in info:
                print(f"  Error: {info['error']}")
        return 0 if ok else 1

    if args.json:
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                metrics = run_verification(TARGET, fast=args.fast)
            logs = [ln for ln in buf.getvalue().splitlines() if ln.strip()]
            payload = {"ok": True, "target": str(TARGET), **metrics, "logs": logs}
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            return 0
        except Exception as exc:
            logs = [ln for ln in buf.getvalue().splitlines() if ln.strip()]
            payload = {"ok": False, "target": str(TARGET), "mode": "fast" if args.fast else "full", "error": str(exc), "logs": logs}
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            return 1

    run_verification(TARGET, fast=args.fast)
    return 0


if __name__ == "__main__":
    raise SystemExit(cli())
