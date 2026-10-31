#!/usr/bin/env bash
# Launch the menubar item (creates the venv on first run).
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x .venv/bin/python ]]; then
    python3 -m venv .venv
    .venv/bin/pip install -q rumps
fi
exec .venv/bin/python menubar.py
