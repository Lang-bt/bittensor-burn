#!/usr/bin/env python3
"""Build compiled platform wheels (Cython). Upload all dist/*.whl to PyPI."""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.check_call(cmd, cwd=ROOT)


def main() -> None:
    parser = argparse.ArgumentParser(description="Build bittensor-burn-message binary wheels")
    parser.add_argument(
        "--local",
        action="store_true",
        help="Build only for the current OS/Python (no cibuildwheel)",
    )
    args = parser.parse_args()

    pkg = ROOT / "bittensor_burn_message"
    for generated in pkg.glob("*.c"):
        generated.unlink()

    dist = ROOT / "dist"
    if dist.exists():
        shutil.rmtree(dist)

    if args.local:
        _run([sys.executable, "-m", "pip", "install", "cython", "build"])
        _run([sys.executable, "-m", "build", "--wheel"])
    else:
        _run([sys.executable, "-m", "pip", "install", "cibuildwheel>=3.4"])
        _run([sys.executable, "-m", "cibuildwheel", str(ROOT), "--output-dir", str(dist)])

    wheels = sorted(dist.glob("*.whl"))
    if not wheels:
        raise SystemExit("No wheels produced in dist/")

    print("\nBuilt wheels:")
    for whl in wheels:
        tag = "compiled" if "py3-none-any" not in whl.name else "pure-python (unexpected)"
        print(f"  {whl.name}  [{tag}]")

    print("\nInstall from repo root (dist/ stays in place):")
    print("  python scripts/install.py")
    print(f"  pip install bittensor-burn-message --no-index --find-links dist")
    print("\nUpload:  twine upload dist/*.whl")
    print("Note: upload ALL wheels so pip can pick the right OS/Python build.")


if __name__ == "__main__":
    main()
