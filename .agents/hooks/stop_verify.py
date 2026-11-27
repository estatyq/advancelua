# -*- coding: utf-8 -*-
"""
Antigravity Stop hook: when helper_core.lua was modified in the working tree,
automatically run `python harness/run.py --fast` before letting the agent stop.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
HARNESS_RUN = REPO_ROOT / "harness" / "run.py"


def main() -> int:
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        print("{}")
        return 0

    # Prevent infinite Stop continuation loops
    if payload.get("continuationActive"):
        print("{}")
        return 0

    # Only run fast gate if helper_core.lua actually has uncommitted modifications
    try:
        git_res = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "status", "--porcelain", "--", "helper_core.lua"],
            capture_output=True,
            text=True,
            timeout=4,
        )
        if git_res.returncode != 0 or not git_res.stdout.strip():
            print("{}")
            return 0
    except Exception:
        print("{}")
        return 0

    try:
        gate = subprocess.run(
            [sys.executable, str(HARNESS_RUN), "--fast"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=12,
        )
    except Exception as exc:
        print(
            json.dumps(
                {
                    "decision": "continue",
                    "reason": f"HARNESS STOP GATE error running `python harness/run.py --fast`: {exc}",
                },
                ensure_ascii=False,
            )
        )
        return 0

    if gate.returncode == 0:
        print("{}")
        return 0

    combined = (gate.stdout + "\n" + gate.stderr).strip().splitlines()
    tail = "\n".join(combined[-20:])
    print(
        json.dumps(
            {
                "decision": "continue",
                "reason": (
                    "HARNESS VERIFICATION FAILED on modified helper_core.lua (`python harness/run.py --fast`):\n"
                    f"{tail}\n"
                    "Fix the issue and verify with `python harness/run.py` before concluding."
                ),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
