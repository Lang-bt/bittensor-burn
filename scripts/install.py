#!/usr/bin/env python3
"""Install bittensor-burn-message from pre-built wheels in dist/."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
PACKAGE = "bittensor-burn-message"


def main() -> None:
    wheels = sorted(DIST.glob("*.whl"))
    if not wheels:
        print(f"No wheels found in {DIST}/", file=sys.stderr)
        print(
            "Copy downloaded .whl files into dist/ inside the cloned repo, then run:",
            file=sys.stderr,
        )
        print(f"  python scripts/install.py", file=sys.stderr)
        print("or:", file=sys.stderr)
        print(f"  pip install {PACKAGE} --no-index --find-links dist", file=sys.stderr)
        raise SystemExit(1)

    cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        PACKAGE,
        "--no-index",
        f"--find-links={DIST}",
    ]
    print("+", " ".join(cmd))
    subprocess.check_call(cmd, cwd=ROOT)


if __name__ == "__main__":
    main()
