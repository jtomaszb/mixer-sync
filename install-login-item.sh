#!/usr/bin/env bash
# Install (or remove) a LaunchAgent so the menubar item starts at login.
#
#   ./install-login-item.sh             install / update
#   ./install-login-item.sh --uninstall remove it
#
# macOS blocks background login jobs from reading ~/Desktop, ~/Documents and
# ~/Downloads, so the runtime files are copied to ~/Library/Application Support
# and the LaunchAgent runs from there. Re-run this after changing sync.sh or
# menubar.py to update the installed copy.
set -euo pipefail

LABEL="local.mixer-sync.menubar"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${HOME}/Library/Application Support/mixer-sync"
LOG="${HOME}/Library/Logs/mixer-sync-menubar.log"
DOMAIN="gui/$(id -u)"

# bootout fails if the agent isn't loaded; that's fine.
launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$PLIST"
    echo "Removed login item ${LABEL} (files left in: ${APP_DIR})"
    exit 0
fi

mkdir -p "$APP_DIR" "$(dirname "$PLIST")" "${HOME}/Library/Logs"
cp "$SRC/menubar.py" "$SRC/sync.sh" "$SRC/run-menubar.sh" "$APP_DIR/"
chmod +x "$APP_DIR/sync.sh" "$APP_DIR/run-menubar.sh" "$APP_DIR/menubar.py"

# Build the venv now so the first login start doesn't depend on the network.
if [[ ! -x "$APP_DIR/.venv/bin/python" ]]; then
    python3 -m venv "$APP_DIR/.venv"
    "$APP_DIR/.venv/bin/pip" install -q rumps
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_DIR}/run-menubar.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${APP_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed login item ${LABEL}"
echo "Runs from: ${APP_DIR}"
echo "Logs:      ${LOG}"
