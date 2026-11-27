# -*- coding: utf-8 -*-
"""
CP1251 + CRLF safe reader, searcher, and atomic patcher for helper_core.lua.

Usage (CLI):
  python harness/patch_helper.py --read 11525 11545
  python harness/patch_helper.py --search "P1_getImguiInputState" --limit 20

Usage (Library inside Python patch scripts):
  from harness.patch_helper import load_helper, replace_once, save_helper
  src = load_helper()
  src = replace_once(src, old_block, new_block, label="Add P8 state")
  save_helper(src, verify_fast=True)
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_HELPER = REPO_ROOT / "helper_core.lua"
HARNESS_RUN = Path(__file__).resolve().parent / "run.py"


def load_helper(path: Path | str = DEFAULT_HELPER) -> str:
    """Read helper_core.lua strictly as CP1251 and return LF-normalized Python str."""
    p = Path(path)
    raw = p.read_bytes()
    if b"\x00" in raw:
        raise ValueError(f"NUL byte detected in {p}")
    lf_only = raw.count(b"\n") - raw.count(b"\r\n")
    if lf_only != 0:
        raise ValueError(f"{p} contains {lf_only} bare LF line endings (expected strict CRLF)")
    return raw.decode("cp1251").replace("\r\n", "\n")


def replace_once(src: str, target: str, replacement: str, label: str = "") -> str:
    """Replace an exact snippet strictly once; raise ValueError on 0 or >1 matches."""
    target_lf = target.replace("\r\n", "\n")
    repl_lf = replacement.replace("\r\n", "\n")
    cnt = src.count(target_lf)
    tag = f" [{label}]" if label else ""
    if cnt == 0:
        raise ValueError(f"Target anchor not found{tag}:\n{target_lf[:240]}")
    if cnt > 1:
        raise ValueError(f"Target anchor matched {cnt} times (must be unique){tag}")
    return src.replace(target_lf, repl_lf, 1)


def save_helper(
    src_lf: str,
    path: Path | str = DEFAULT_HELPER,
    verify_fast: bool = True,
    verify_full: bool = False,
) -> None:
    """Encode src as CP1251+CRLF, write to disk, and optionally rollback if harness fails."""
    p = Path(path)
    prev_bytes: Optional[bytes] = p.read_bytes() if p.exists() else None
    crlf_str = src_lf.replace("\r\n", "\n").replace("\n", "\r\n")
    encoded = crlf_str.encode("cp1251")
    if b"\x00" in encoded:
        raise ValueError("Refusing to write NUL byte to helper_core.lua")

    p.write_bytes(encoded)
    if verify_full or verify_fast:
        cmd = [sys.executable, str(HARNESS_RUN)]
        if not verify_full:
            cmd.append("--fast")
        cmd.extend(["--target", str(p)])
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            if prev_bytes is not None:
                p.write_bytes(prev_bytes)
            msg = (res.stdout + "\n" + res.stderr).strip()
            raise RuntimeError(
                f"Harness verification failed after patching {p}; rolled back.\n{msg}"
            )


def cmd_read(path: Path, start: int, end: int) -> int:
    src = load_helper(path)
    lines = src.split("\n")
    s = max(1, start)
    e = min(len(lines), end)
    if s > e:
        print(f"Range {start}..{end} out of bounds (file has {len(lines)} lines)", file=sys.stderr)
        return 1
    out = "\n".join(f"L{idx}: {lines[idx - 1]}" for idx in range(s, e + 1))
    sys.stdout.buffer.write((out + "\n").encode("utf-8"))
    return 0


def cmd_search(path: Path, pattern: str, limit: int, ignore_case: bool) -> int:
    src = load_helper(path)
    lines = src.split("\n")
    flags = re.IGNORECASE if ignore_case else 0
    rx = re.compile(pattern, flags)
    hits = []
    for idx, line in enumerate(lines, 1):
        if rx.search(line):
            hits.append(f"L{idx}: {line}")
            if len(hits) >= limit:
                break
    out = "\n".join(hits) if hits else "(no matches)"
    sys.stdout.buffer.write((out + "\n").encode("utf-8"))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="CP1251+CRLF safe helper_core.lua inspector/patcher")
    parser.add_argument("--target", type=Path, default=DEFAULT_HELPER, help="Path to helper_core.lua")
    parser.add_argument("--read", nargs=2, type=int, metavar=("START", "END"), help="Print UTF-8 lines L[START..END]")
    parser.add_argument("--search", type=str, help="Regex search across CP1251 helper_core.lua")
    parser.add_argument("--limit", type=int, default=50, help="Max --search matches")
    parser.add_argument("-i", "--ignore-case", action="store_true", help="Case-insensitive --search")
    args = parser.parse_args()

    if args.read:
        return cmd_read(args.target, args.read[0], args.read[1])
    if args.search is not None:
        return cmd_search(args.target, args.search, args.limit, args.ignore_case)
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
