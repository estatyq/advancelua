# -*- coding: utf-8 -*-
"""
Antigravity PreToolUse hook: block UTF-8 edit_file / write_file on CP1251+CRLF helper_core.lua.
Fails open on malformed input to avoid bricking unrelated tool calls.
"""
from __future__ import annotations

import json
import ntpath
import os
import sys


def main() -> int:
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        print(json.dumps({"decision": "allow"}))
        return 0

    tool_call = payload.get("toolCall") or {}
    args = tool_call.get("args") or {}
    target_path = args.get("Path") or args.get("path") or ""

    norm = str(target_path).strip().strip('"').strip("'")
    base = ntpath.basename(norm).lower() or os.path.basename(norm).lower()

    if base == "helper_core.lua":
        print(
            json.dumps(
                {
                    "decision": "deny",
                    "reason": (
                        "HARNESS GUARD: helper_core.lua is strictly Windows-1251 (cp1251) + CRLF. "
                        "Never edit it directly with UTF-8 edit_file or write_file. "
                        "Patch via Python using `from harness.patch_helper import load_helper, replace_once, save_helper` "
                        "(or `.decode('cp1251')` / `.encode('cp1251')`) and verify with `python harness/run.py`."
                    ),
                },
                ensure_ascii=False,
            )
        )
        return 0

    print(json.dumps({"decision": "allow"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
