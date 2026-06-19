#!/usr/bin/env bash
# Install bittensor-burn-message from wheels in this folder (no dist/ subfolder needed).
set -euo pipefail

WheelDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
  Py=python3
elif command -v python >/dev/null 2>&1; then
  Py=python
else
  echo "Python not found. Install Python 3.9+ and ensure it is on PATH." >&2
  exit 1
fi

echo "Installing from: $WheelDir"
"$Py" -m pip install bittensor-burn-message --no-index --find-links "$WheelDir"
echo
echo "Done. Try: bittensor-burn-message install --help"
