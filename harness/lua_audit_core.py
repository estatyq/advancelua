# -*- coding: utf-8 -*-
"""
Full Lua 5.1 / LuaJIT 2.1 lexer, recursive-descent AST parser,
and lexical scope / global / upvalue / local-slot analyzer.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, List, Optional, Tuple


KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end",
    "false", "for", "function", "if", "in", "local",
    "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}


@dataclass
class Token:
    kind: str   # KW, ID, NUM, STR, SYM, EOF
    val: str
    line: int
    col: int
    end_line: int
    end_col: int
    raw: str = ""
    raw_bytes: bytes = b""


def _decode_lua_string(raw_tok: str, encoding: str = "cp1251") -> Tuple[bytes, List[Tuple[int, str]]]:
    """Decode a Lua string literal into raw bytes and flag escaping hazards."""
    hazards: List[Tuple[int, str]] = []
    if raw_tok.startswith("["):
        eq = 0
        p = 1
        while p < len(raw_tok) and raw_tok[p] == "=":
            eq += 1
            p += 1
        body = raw_tok[p + 1 : -(2 + eq)]
        if body.startswith("\n"):
            body = body[1:]
        elif body.startswith("\r\n"):
            body = body[2:]
        return body.encode(encoding, errors="replace"), hazards

    q = raw_tok[0]
    inner = raw_tok[1:-1]
    out = bytearray()
    i = 0
    n = len(inner)
    simple = {
        "a": 7, "b": 8, "f": 12, "n": 10, "r": 13, "t": 9, "v": 11,
        "\\": 92, '"': 34, "'": 39, "[": 91, "]": 93, "\n": 10,
    }
    while i < n:
        ch = inner[i]
        if ch != "\\":
            out.extend(ch.encode(encoding, errors="replace"))
            i += 1
            continue
        i += 1
        if i >= n:
            hazards.append((i, "trailing_backslash"))
            break
        esc = inner[i]
        if esc == "\r" and i + 1 < n and inner[i + 1] == "\n":
            out.append(10)
            i += 2
            continue
        if esc in simple:
            out.append(simple[esc])
            i += 1
        elif esc.isdigit():
            j = i
            while j < n and j - i < 3 and inner[j].isdigit():
                j += 1
            val = int(inner[i:j])
            if val > 255:
                hazards.append((i, f"decimal_escape_gt_255:\\{inner[i:j]}"))
            out.append(val & 0xFF)
            i = j
        elif esc == "x":
            if i + 2 < n and all(c in "0123456789abcdefABCDEF" for c in inner[i + 1 : i + 3]):
                out.append(int(inner[i + 1 : i + 3], 16))
                i += 3
            else:
                hazards.append((i, "malformed_hex_escape"))
                out.append(ord("x"))
                i += 1
        elif esc == "z":
            i += 1
            while i < n and inner[i] in " \t\r\n\v\f":
                i += 1
        else:
            hazards.append((i, f"unknown_escape:\\{esc}"))
            out.extend(esc.encode(encoding, errors="replace"))
            i += 1
    return bytes(out), hazards


def lex_lua(src: str) -> Tuple[List[Token], List[Tuple[int, str, str]]]:
    """Lex LuaJIT source (LF-normalized). Returns (tokens, string_hazards)."""
    tokens: List[Token] = []
    hazards: List[Tuple[int, str, str]] = []
    n = len(src)
    i = 0
    line = 1
    line_start = 0

    def col_at(pos: int) -> int:
        return pos - line_start + 1

    def count_eq(pos: int) -> int:
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
            line_start = i
            continue
        if ch in " \t\r\f\v":
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
                        raise SyntaxError(f"Unclosed long comment at line {line}")
                    seg = src[i : j + len(close_pat)]
                    nl_cnt = seg.count("\n")
                    if nl_cnt:
                        line += nl_cnt
                        last_nl = src.rfind("\n", i, j + len(close_pat))
                        line_start = last_nl + 1
                    i = j + len(close_pat)
                    continue
            j = src.find("\n", i + 2)
            if j == -1:
                break
            i = j
            continue

        # Long string
        if ch == "[" and i + 1 < n and src[i + 1] in "[=":
            eq = count_eq(i + 1)
            if eq >= 0:
                s_line, s_col = line, col_at(i)
                close_pat = "]" + ("=" * eq) + "]"
                j = src.find(close_pat, i + 2 + eq)
                if j == -1:
                    raise SyntaxError(f"Unclosed long string at line {line}")
                raw_tok = src[i : j + len(close_pat)]
                nl_cnt = raw_tok.count("\n")
                if nl_cnt:
                    line += nl_cnt
                    last_nl = src.rfind("\n", i, j + len(close_pat))
                    line_start = last_nl + 1
                raw_b, h = _decode_lua_string(raw_tok)
                for _, hz in h:
                    hazards.append((s_line, hz, raw_tok[:60]))
                tokens.append(Token("STR", raw_tok, s_line, s_col, line, col_at(j + len(close_pat)), raw_tok, raw_b))
                i = j + len(close_pat)
                continue

        # Quoted string
        if ch in ("'", '"'):
            q = ch
            s_line, s_col = line, col_at(i)
            j = i + 1
            while j < n:
                c = src[j]
                if c == "\\":
                    if j + 1 < n and src[j + 1] == "\n":
                        line += 1
                        line_start = j + 2
                    j += 2
                    continue
                if c == "\n":
                    raise SyntaxError(f"Unclosed string at line {s_line}")
                if c == q:
                    j += 1
                    break
                j += 1
            else:
                raise SyntaxError(f"Unclosed string at EOF from line {s_line}")
            raw_tok = src[i:j]
            raw_b, h = _decode_lua_string(raw_tok)
            for _, hz in h:
                hazards.append((s_line, hz, raw_tok[:80]))
            tokens.append(Token("STR", raw_tok, s_line, s_col, line, col_at(j), raw_tok, raw_b))
            i = j
            continue

        # Identifiers / keywords
        if ch.isalpha() or ch == "_":
            s_col = col_at(i)
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            word = src[i:j]
            kind = "KW" if word in KEYWORDS else "ID"
            tokens.append(Token(kind, word, line, s_col, line, col_at(j), word))
            i = j
            continue

        # Numbers (including LuaJIT hex floats / LL / ULL)
        if ch.isdigit() or (ch == "." and i + 1 < n and src[i + 1].isdigit()):
            s_col = col_at(i)
            j = i
            if src[i : i + 2].lower() == "0x":
                j += 2
                while j < n and (src[j] in "0123456789abcdefABCDEF."):
                    j += 1
                if j < n and src[j] in "pP":
                    j += 1
                    if j < n and src[j] in "+-":
                        j += 1
                    while j < n and src[j].isdigit():
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
            while j < n and src[j] in "uUlLiI":
                j += 1
            num = src[i:j]
            tokens.append(Token("NUM", num, line, s_col, line, col_at(j), num))
            i = j
            continue

        s_col = col_at(i)
        if src[i : i + 3] == "...":
            tokens.append(Token("SYM", "...", line, s_col, line, s_col + 3, "..."))
            i += 3
            continue
        if src[i : i + 2] in ("..", "==", "~=", "<=", ">=", "::"):
            sym = src[i : i + 2]
            tokens.append(Token("SYM", sym, line, s_col, line, s_col + 2, sym))
            i += 2
            continue

        tokens.append(Token("SYM", ch, line, s_col, line, s_col + 1, ch))
        i += 1

    tokens.append(Token("EOF", "<EOF>", line, col_at(n), line, col_at(n), ""))
    return tokens, hazards


# ---- AST Nodes ----

@dataclass
class Node:
    kind: str
    line: int
    end_line: int = 0
    data: dict = field(default_factory=dict)


UNOPS = {"not", "#", "-"}
BINOPS = {
    "or": (1, 1),
    "and": (2, 2),
    "<": (3, 3), ">": (3, 3), "<=": (3, 3), ">=": (3, 3), "~=": (3, 3), "==": (3, 3),
    "..": (5, 4),  # right-associative
    "+": (6, 6), "-": (6, 6),
    "*": (7, 7), "/": (7, 7), "%": (7, 7),
    "^": (10, 9),  # right-associative
}
UNARY_PREC = 8


class LuaParser:
    def __init__(self, tokens: List[Token]):
        self.tokens = tokens
        self.pos = 0

    def cur(self) -> Token:
        return self.tokens[self.pos]

    def peek(self, off: int = 1) -> Token:
        idx = self.pos + off
        if idx >= len(self.tokens):
            return self.tokens[-1]
        return self.tokens[idx]

    def match(self, kind: str, val: Optional[str] = None) -> Optional[Token]:
        t = self.cur()
        if t.kind == kind and (val is None or t.val == val):
            self.pos += 1
            return t
        return None

    def expect(self, kind: str, val: Optional[str] = None) -> Token:
        t = self.cur()
        if t.kind == kind and (val is None or t.val == val):
            self.pos += 1
            return t
        raise SyntaxError(f"Expected {kind} {val or ''} at line {t.line}:{t.col}, got {t.kind} {t.val!r}")

    def parse_chunk(self) -> Node:
        stmts = self.parse_block(stop_vals=set(), is_chunk=True)
        self.expect("EOF")
        end_ln = self.tokens[-1].line
        return Node("Chunk", 1, end_ln, {"stmts": stmts})

    def parse_block(self, stop_vals: set[str], is_chunk: bool = False) -> List[Node]:
        stmts: List[Node] = []
        while self.cur().kind != "EOF":
            if self.cur().kind == "KW" and self.cur().val in stop_vals:
                break
            while self.match("SYM", ";"):
                pass
            if self.cur().kind == "EOF" or (self.cur().kind == "KW" and self.cur().val in stop_vals):
                break
            st = self.parse_stat()
            stmts.append(st)
            while self.match("SYM", ";"):
                pass
            if st.kind in ("Return", "Break"):
                while self.match("SYM", ";"):
                    pass
                break
        return stmts

    def parse_stat(self) -> Node:
        t = self.cur()
        if t.kind == "KW":
            if t.val == "do":
                self.pos += 1
                body = self.parse_block({"end"})
                end_t = self.expect("KW", "end")
                return Node("Do", t.line, end_t.line, {"body": body})
            if t.val == "while":
                self.pos += 1
                cond = self.parse_exp()
                self.expect("KW", "do")
                body = self.parse_block({"end"})
                end_t = self.expect("KW", "end")
                return Node("While", t.line, end_t.line, {"cond": cond, "body": body})
            if t.val == "repeat":
                self.pos += 1
                body = self.parse_block({"until"})
                self.expect("KW", "until")
                cond = self.parse_exp()
                return Node("Repeat", t.line, cond.end_line or cond.line, {"body": body, "cond": cond})
            if t.val == "if":
                return self.parse_if()
            if t.val == "for":
                return self.parse_for()
            if t.val == "function":
                return self.parse_funcstat()
            if t.val == "local":
                return self.parse_local()
            if t.val == "return":
                self.pos += 1
                exps: List[Node] = []
                if not (self.cur().kind == "EOF" or self.cur().val in {"end", "else", "elseif", "until", ";"}):
                    exps = self.parse_explist()
                end_ln = exps[-1].end_line if exps else t.line
                return Node("Return", t.line, end_ln, {"exps": exps})
            if t.val == "break":
                self.pos += 1
                return Node("Break", t.line, t.line, {})
        if t.kind == "SYM" and t.val == "::":
            self.pos += 1
            lbl = self.expect("ID")
            end_t = self.expect("SYM", "::")
            return Node("Label", t.line, end_t.line, {"name": lbl.val})
        if t.kind == "ID" and t.val == "goto" and self.peek().kind == "ID":
            self.pos += 1
            lbl = self.expect("ID")
            return Node("Goto", t.line, lbl.line, {"name": lbl.val})
        return self.parse_expr_stat()

    def parse_if(self) -> Node:
        t = self.expect("KW", "if")
        branches = []
        cond = self.parse_exp()
        self.expect("KW", "then")
        body = self.parse_block({"elseif", "else", "end"})
        branches.append((cond, body))
        while self.match("KW", "elseif"):
            c = self.parse_exp()
            self.expect("KW", "then")
            b = self.parse_block({"elseif", "else", "end"})
            branches.append((c, b))
        else_body = None
        if self.match("KW", "else"):
            else_body = self.parse_block({"end"})
        end_t = self.expect("KW", "end")
        return Node("If", t.line, end_t.line, {"branches": branches, "else_body": else_body})

    def parse_for(self) -> Node:
        t = self.expect("KW", "for")
        first = self.expect("ID")
        if self.match("SYM", "="):
            start = self.parse_exp()
            self.expect("SYM", ",")
            stop = self.parse_exp()
            step = None
            if self.match("SYM", ","):
                step = self.parse_exp()
            self.expect("KW", "do")
            body = self.parse_block({"end"})
            end_t = self.expect("KW", "end")
            return Node("ForNum", t.line, end_t.line, {
                "var": first.val, "var_line": first.line,
                "start": start, "stop": stop, "step": step, "body": body,
            })
        names = [(first.val, first.line)]
        while self.match("SYM", ","):
            id_t = self.expect("ID")
            names.append((id_t.val, id_t.line))
        self.expect("KW", "in")
        iters = self.parse_explist()
        self.expect("KW", "do")
        body = self.parse_block({"end"})
        end_t = self.expect("KW", "end")
        return Node("ForIn", t.line, end_t.line, {"names": names, "iters": iters, "body": body})

    def parse_funcstat(self) -> Node:
        t = self.expect("KW", "function")
        base = self.expect("ID")
        fields = []
        method = None
        while self.match("SYM", "."):
            f = self.expect("ID")
            fields.append((f.val, f.line))
        if self.match("SYM", ":"):
            m = self.expect("ID")
            method = (m.val, m.line)
        body_node = self.parse_funcbody(
            name=base.val + "".join("." + f[0] for f in fields) + (":" + method[0] if method else ""),
            has_self=(method is not None),
            start_line=t.line,
        )
        return Node("FuncDef", t.line, body_node.end_line, {
            "base": base.val, "base_line": base.line,
            "fields": fields, "method": method, "func": body_node,
        })

    def parse_local(self) -> Node:
        t = self.expect("KW", "local")
        if self.match("KW", "function"):
            nm = self.expect("ID")
            fn = self.parse_funcbody(name=nm.val, has_self=False, start_line=t.line)
            return Node("LocalFunc", t.line, fn.end_line, {"name": nm.val, "name_line": nm.line, "func": fn})
        names = []
        id_t = self.expect("ID")
        names.append((id_t.val, id_t.line))
        while self.match("SYM", ","):
            id_t = self.expect("ID")
            names.append((id_t.val, id_t.line))
        exps = []
        if self.match("SYM", "="):
            exps = self.parse_explist()
        end_ln = exps[-1].end_line if exps else names[-1][1]
        return Node("LocalAssign", t.line, end_ln, {"names": names, "exps": exps})

    def parse_funcbody(self, name: str, has_self: bool, start_line: int) -> Node:
        self.expect("SYM", "(")
        params = []
        vararg = False
        if not self.match("SYM", ")"):
            while True:
                if self.match("SYM", "..."):
                    vararg = True
                    break
                p = self.expect("ID")
                params.append((p.val, p.line))
                if not self.match("SYM", ","):
                    break
            self.expect("SYM", ")")
        body = self.parse_block({"end"})
        end_t = self.expect("KW", "end")
        return Node("FuncBody", start_line, end_t.line, {
            "name": name, "params": params, "has_self": has_self, "vararg": vararg, "body": body,
        })

    def parse_expr_stat(self) -> Node:
        first = self.parse_suffixed_exp()
        if self.cur().kind == "SYM" and self.cur().val in ("=", ","):
            targets = [first]
            while self.match("SYM", ","):
                targets.append(self.parse_suffixed_exp())
            self.expect("SYM", "=")
            exps = self.parse_explist()
            return Node("Assign", first.line, exps[-1].end_line, {"targets": targets, "exps": exps})
        if first.kind not in ("Call", "MethodCall"):
            raise SyntaxError(f"Expected assignment or call at line {first.line}, got {first.kind}")
        return Node("CallStat", first.line, first.end_line, {"call": first})

    def parse_explist(self) -> List[Node]:
        exps = [self.parse_exp()]
        while self.match("SYM", ","):
            exps.append(self.parse_exp())
        return exps

    def parse_exp(self, min_prec: int = 0) -> Node:
        t = self.cur()
        if (t.kind == "KW" and t.val == "not") or (t.kind == "SYM" and t.val in ("#", "-")):
            self.pos += 1
            rhs = self.parse_exp(UNARY_PREC)
            lhs = Node("UnOp", t.line, rhs.end_line, {"op": t.val, "rhs": rhs})
        else:
            lhs = self.parse_simple_exp()

        while True:
            op_t = self.cur()
            op = op_t.val if op_t.kind in ("KW", "SYM") and op_t.val in BINOPS else None
            if not op:
                break
            l_prec, r_prec = BINOPS[op]
            if l_prec < min_prec:
                break
            self.pos += 1
            rhs = self.parse_exp(r_prec)
            lhs = Node("BinOp", lhs.line, rhs.end_line, {"op": op, "lhs": lhs, "rhs": rhs})
        return lhs

    def parse_simple_exp(self) -> Node:
        t = self.cur()
        if t.kind == "NUM":
            self.pos += 1
            return Node("Num", t.line, t.line, {"val": t.val})
        if t.kind == "STR":
            self.pos += 1
            return Node("Str", t.line, t.end_line, {"token": t})
        if t.kind == "KW" and t.val in ("nil", "true", "false"):
            self.pos += 1
            return Node("Const", t.line, t.line, {"val": t.val})
        if t.kind == "SYM" and t.val == "...":
            self.pos += 1
            return Node("VarArg", t.line, t.line, {})
        if t.kind == "SYM" and t.val == "{":
            return self.parse_table()
        if t.kind == "KW" and t.val == "function":
            self.pos += 1
            return self.parse_funcbody(name=f"anon@{t.line}", has_self=False, start_line=t.line)
        return self.parse_suffixed_exp()

    def parse_suffixed_exp(self) -> Node:
        base = self.parse_primary_exp()
        while True:
            t = self.cur()
            if t.kind == "SYM" and t.val == ".":
                self.pos += 1
                f = self.expect("ID")
                base = Node("Field", base.line, f.line, {"obj": base, "field": f.val, "field_line": f.line})
            elif t.kind == "SYM" and t.val == "[":
                self.pos += 1
                idx = self.parse_exp()
                end_t = self.expect("SYM", "]")
                base = Node("Index", base.line, end_t.line, {"obj": base, "index": idx})
            elif t.kind == "SYM" and t.val == ":":
                self.pos += 1
                m = self.expect("ID")
                args, end_ln = self.parse_args()
                base = Node("MethodCall", base.line, end_ln, {"obj": base, "method": m.val, "method_line": m.line, "args": args})
            elif (t.kind == "SYM" and t.val in ("(", "{")) or t.kind == "STR":
                args, end_ln = self.parse_args()
                base = Node("Call", base.line, end_ln, {"fn": base, "args": args})
            else:
                break
        return base

    def parse_primary_exp(self) -> Node:
        t = self.cur()
        if t.kind == "ID":
            self.pos += 1
            return Node("Name", t.line, t.line, {"name": t.val, "col": t.col})
        if t.kind == "SYM" and t.val == "(":
            self.pos += 1
            e = self.parse_exp()
            end_t = self.expect("SYM", ")")
            return Node("Paren", t.line, end_t.line, {"exp": e})
        raise SyntaxError(f"Unexpected token {t.kind} {t.val!r} at line {t.line}:{t.col}")

    def parse_args(self) -> Tuple[List[Node], int]:
        t = self.cur()
        if t.kind == "SYM" and t.val == "(":
            self.pos += 1
            args = []
            if not self.match("SYM", ")"):
                args = self.parse_explist()
                end_t = self.expect("SYM", ")")
                return args, end_t.line
            return args, t.line
        if t.kind == "SYM" and t.val == "{":
            tbl = self.parse_table()
            return [tbl], tbl.end_line
        if t.kind == "STR":
            self.pos += 1
            return [Node("Str", t.line, t.end_line, {"token": t})], t.end_line
        raise SyntaxError(f"Expected function arguments at line {t.line}:{t.col}")

    def parse_table(self) -> Node:
        t = self.expect("SYM", "{")
        fields = []
        while not (self.cur().kind == "SYM" and self.cur().val == "}"):
            if self.match("SYM", "["):
                k = self.parse_exp()
                self.expect("SYM", "]")
                self.expect("SYM", "=")
                v = self.parse_exp()
                fields.append(("index", k, v))
            elif self.cur().kind == "ID" and self.peek().kind == "SYM" and self.peek().val == "=":
                k = self.cur().val
                k_ln = self.cur().line
                self.pos += 2
                v = self.parse_exp()
                fields.append(("name", (k, k_ln), v))
            else:
                v = self.parse_exp()
                fields.append(("array", None, v))
            if not (self.match("SYM", ",") or self.match("SYM", ";")):
                break
        end_t = self.expect("SYM", "}")
        return Node("Table", t.line, end_t.line, {"fields": fields})


# ---- Lexical Scope, Local Slot, Upvalue & Global Analyzer ----

@dataclass
class LocalVar:
    name: str
    line: int
    func_id: int
    shadowed_prev: bool = False


@dataclass
class FuncInfo:
    func_id: int
    name: str
    line: int
    end_line: int
    parent_id: Optional[int]
    depth: int
    params: List[str] = field(default_factory=list)
    active_locals: int = 0
    max_active_locals: int = 0   # exact LuaJIT live register / local slot high-water mark
    total_declared_locals: int = 0
    local_decls: List[Tuple[str, int]] = field(default_factory=list)
    upvalues: List[Tuple[str, int]] = field(default_factory=list)  # (name, owner_func_id)
    upvalue_keys: set = field(default_factory=set)
    blocks: List[dict] = field(default_factory=list)


class ScopeAnalyzer:
    def __init__(self, chunk: Node):
        self.chunk = chunk
        self.funcs: List[FuncInfo] = []
        self.global_writes: List[Tuple[str, int, str, int]] = []   # (name, line, kind, func_id)
        self.global_reads: List[Tuple[str, int, str, int]] = []    # (name, line, ctx, func_id)
        self.shadowed_locals: List[Tuple[str, int, int, int]] = [] # (name, line, prev_line, func_id)
        self.top_locals: List[Tuple[str, int]] = []
        self.dup_global_funcs: List[Tuple[str, int, int]] = []
        self._func_stack: List[FuncInfo] = []
        self._scope_stack: List[List[Tuple[str, LocalVar]]] = []  # per block, list of active locals in func
        self._func_scopes_base: List[int] = []  # index in _scope_stack where current func starts

    def analyze(self):
        top = FuncInfo(0, "<chunk>", 1, self.chunk.end_line, None, 0)
        self.funcs.append(top)
        self._push_func(top)
        self._push_block()
        self._visit_block(self.chunk.data["stmts"])
        self._pop_block()
        self._pop_func()

    def _push_func(self, fi: FuncInfo):
        self._func_stack.append(fi)
        self._func_scopes_base.append(len(self._scope_stack))

    def _pop_func(self):
        self._func_scopes_base.pop()
        self._func_stack.pop()

    def _push_block(self):
        self._scope_stack.append([])

    def _pop_block(self):
        vars_in_block = self._scope_stack.pop()
        fi = self._func_stack[-1]
        fi.active_locals -= len(vars_in_block)

    def _declare_local(self, name: str, line: int):
        fi = self._func_stack[-1]
        base = self._func_scopes_base[-1]
        prev = None
        for b_idx in range(len(self._scope_stack) - 1, -1, -1):
            for vname, vobj in reversed(self._scope_stack[b_idx]):
                if vname == name:
                    prev = vobj
                    break
            if prev:
                break
        if prev is not None:
            self.shadowed_locals.append((name, line, prev.line, fi.func_id))
        lv = LocalVar(name, line, fi.func_id, prev is not None)
        self._scope_stack[-1].append((name, lv))
        fi.active_locals += 1
        fi.total_declared_locals += 1
        fi.local_decls.append((name, line))
        if fi.active_locals > fi.max_active_locals:
            fi.max_active_locals = fi.active_locals
        if fi.func_id == 0 and len(self._scope_stack) == 1:
            self.top_locals.append((name, line))

    def _resolve_var(self, name: str, line: int, ctx: str):
        # Search scopes top-down. If found in an outer function, record upvalue in all intermediate functions!
        cur_fi = self._func_stack[-1]
        found_lv: Optional[LocalVar] = None
        for b_idx in range(len(self._scope_stack) - 1, -1, -1):
            for vname, vobj in reversed(self._scope_stack[b_idx]):
                if vname == name:
                    found_lv = vobj
                    break
            if found_lv is not None:
                break

        if found_lv is None:
            self.global_reads.append((name, line, ctx, cur_fi.func_id))
            return

        if found_lv.func_id < cur_fi.func_id:
            # Propagate upvalue through all functions between owner and cur_fi (inclusive of cur_fi)
            key = (found_lv.name, found_lv.line, found_lv.func_id)
            for fi in self._func_stack:
                if fi.func_id > found_lv.func_id:
                    if key not in fi.upvalue_keys:
                        fi.upvalue_keys.add(key)
                        fi.upvalues.append((found_lv.name, found_lv.func_id))

    def _visit_block(self, stmts: List[Node]):
        for st in stmts:
            self._visit_stat(st)

    def _visit_stat(self, st: Node):
        k = st.kind
        if k == "Do":
            self._push_block()
            self._visit_block(st.data["body"])
            self._pop_block()
        elif k == "While":
            self._visit_exp(st.data["cond"])
            self._push_block()
            self._visit_block(st.data["body"])
            self._pop_block()
        elif k == "Repeat":
            self._push_block()
            self._visit_block(st.data["body"])
            # In Lua, condition of repeat..until sees locals declared inside repeat body!
            self._visit_exp(st.data["cond"])
            self._pop_block()
        elif k == "If":
            for cond, body in st.data["branches"]:
                self._visit_exp(cond)
                self._push_block()
                self._visit_block(body)
                self._pop_block()
            if st.data["else_body"] is not None:
                self._push_block()
                self._visit_block(st.data["else_body"])
                self._pop_block()
        elif k == "ForNum":
            self._visit_exp(st.data["start"])
            self._visit_exp(st.data["stop"])
            if st.data["step"] is not None:
                self._visit_exp(st.data["step"])
            self._push_block()
            # Lua allocates 3 hidden control slots + loop variable in for-num!
            # Wait: LuaJIT allocates (var), (limit), (step) internal + visible loop var -> actually 4 slots in Lua 5.1/JIT, visible local = 1 (plus internal). We'll track visible locals accurately and note hidden slots separately!
            self._declare_local(st.data["var"], st.data["var_line"])
            self._visit_block(st.data["body"])
            self._pop_block()
        elif k == "ForIn":
            for it in st.data["iters"]:
                self._visit_exp(it)
            self._push_block()
            for nm, ln in st.data["names"]:
                self._declare_local(nm, ln)
            self._visit_block(st.data["body"])
            self._pop_block()
        elif k == "LocalAssign":
            for ex in st.data["exps"]:
                self._visit_exp(ex)
            for nm, ln in st.data["names"]:
                self._declare_local(nm, ln)
        elif k == "LocalFunc":
            # In Lua: `local function f()` declares `f` BEFORE body!
            self._declare_local(st.data["name"], st.data["name_line"])
            self._visit_funcbody(st.data["func"], custom_name=st.data["name"])
        elif k == "FuncDef":
            base = st.data["base"]
            base_line = st.data["base_line"]
            fields = st.data["fields"]
            method = st.data["method"]
            cur_fid = self._func_stack[-1].func_id
            if not fields and not method:
                # function foo(...) -> global (or local if shadowed? No, `function foo` ALWAYS assigns global _G unless no, wait: in Lua `function x` writes global `x` EVEN IF local `x` exists! Actually no: `function x()` is sugar for `x = function()`, which DOES write to local `x` if `x` is local!)
                # Let's check if base is local:
                if self._is_local_in_scope(base):
                    self._resolve_var(base, base_line, "funcdef_local")
                else:
                    self.global_writes.append((base, base_line, "func", cur_fid))
            else:
                # function a.b:c() reads base `a`!
                self._resolve_var(base, base_line, "funcdef_base")
                full_nm = base + "".join("." + f[0] for f in fields) + (":" + method[0] if method else "")
                self.global_writes.append((full_nm, base_line, "field_func", cur_fid))
            self._visit_funcbody(st.data["func"])
        elif k == "Assign":
            for ex in st.data["exps"]:
                self._visit_exp(ex)
            cur_fid = self._func_stack[-1].func_id
            for tgt in st.data["targets"]:
                if tgt.kind == "Name":
                    nm = tgt.data["name"]
                    if self._is_local_in_scope(nm):
                        self._resolve_var(nm, tgt.line, "assign_local")
                    else:
                        self.global_writes.append((nm, tgt.line, "var", cur_fid))
                else:
                    self._visit_exp(tgt)
        elif k == "CallStat":
            self._visit_exp(st.data["call"])
        elif k == "Return":
            for ex in st.data["exps"]:
                self._visit_exp(ex)

    def _is_local_in_scope(self, name: str) -> bool:
        for b_idx in range(len(self._scope_stack) - 1, -1, -1):
            for vname, _ in self._scope_stack[b_idx]:
                if vname == name:
                    return True
        return False

    def _visit_funcbody(self, fn_node: Node, custom_name: Optional[str] = None):
        parent = self._func_stack[-1]
        fid = len(self.funcs)
        nm = custom_name or fn_node.data["name"]
        fi = FuncInfo(
            func_id=fid,
            name=nm,
            line=fn_node.line,
            end_line=fn_node.end_line,
            parent_id=parent.func_id,
            depth=parent.depth + 1,
        )
        self.funcs.append(fi)
        self._push_func(fi)
        self._push_block()
        if fn_node.data["has_self"]:
            fi.params.append("self")
            self._declare_local("self", fn_node.line)
        for pnm, pln in fn_node.data["params"]:
            fi.params.append(pnm)
            self._declare_local(pnm, pln)
        self._visit_block(fn_node.data["body"])
        self._pop_block()
        self._pop_func()

    def _visit_exp(self, node: Node):
        k = node.kind
        if k == "Name":
            self._resolve_var(node.data["name"], node.line, "read")
        elif k == "Paren":
            self._visit_exp(node.data["exp"])
        elif k == "UnOp":
            self._visit_exp(node.data["rhs"])
        elif k == "BinOp":
            self._visit_exp(node.data["lhs"])
            self._visit_exp(node.data["rhs"])
        elif k == "Field":
            self._visit_exp(node.data["obj"])
        elif k == "Index":
            self._visit_exp(node.data["obj"])
            self._visit_exp(node.data["index"])
        elif k == "Call":
            # Tag if direct global call
            fn = node.data["fn"]
            if fn.kind == "Name" and not self._is_local_in_scope(fn.data["name"]):
                self._resolve_var(fn.data["name"], fn.line, "call")
            else:
                self._visit_exp(fn)
            for a in node.data["args"]:
                self._visit_exp(a)
        elif k == "MethodCall":
            self._visit_exp(node.data["obj"])
            for a in node.data["args"]:
                self._visit_exp(a)
        elif k == "Table":
            for fkind, k_node, v_node in node.data["fields"]:
                if fkind == "index":
                    self._visit_exp(k_node)
                self._visit_exp(v_node)
        elif k == "FuncBody":
            self._visit_funcbody(node)
