#!/usr/bin/env bash
# menubar.sh — install, update and control the Mixer Sync menubar item.
#
#   ./menubar.sh update      copy the latest code to the installed location and restart
#                            (also the first-time install; starts the app at login)
#   ./menubar.sh start       start it (loads the login item if needed)
#   ./menubar.sh stop        stop it until next login (or `start`)
#   ./menubar.sh restart     stop + start
#   ./menubar.sh status      running? is the installed copy up to date?
#   ./menubar.sh logs        follow the app log
#   ./menubar.sh uninstall   remove the login item
#
# macOS blocks background login jobs from reading ~/Desktop, ~/Documents and
# ~/Downloads, so the runtime files are copied to ~/Library/Application Support
# and the LaunchAgent runs from there. Run `update` after changing sync.sh or
# menubar.py.
set -euo pipefail

LABEL="local.mixer-sync.menubar"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${HOME}/Library/Application Support/mixer-sync"
LOG="${HOME}/Library/Logs/mixer-sync-menubar.log"
DOMAIN="gui/$(id -u)"
FILES=(menubar.py sync.sh run-menubar.sh)

log() { printf '%s\n' "$*"; }

is_loaded() { launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; }

agent_field() { launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | awk -F' = ' -v k="$1" '$1 ~ "^[[:space:]]*"k"$" {print $2; exit}'; }

copy_files() {
    mkdir -p "$APP_DIR"
    local f
    for f in "${FILES[@]}"; do
        cp "$SRC/$f" "$APP_DIR/$f"
    done
    chmod +x "$APP_DIR/sync.sh" "$APP_DIR/run-menubar.sh" "$APP_DIR/menubar.py"

    # Build the venv now so the first login start doesn't depend on the network.
    if [[ ! -x "$APP_DIR/.venv/bin/python" ]]; then
        python3 -m venv "$APP_DIR/.venv"
        "$APP_DIR/.venv/bin/pip" install -q rumps
    fi
}

write_plist() {
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
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
}

stop_agent() {
    # bootout fails if the agent isn't loaded; that's fine.
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    # bootout returns before teardown finishes; wait so a following bootstrap/kickstart is safe.
    local i
    for i in {1..50}; do
        is_loaded || return 0
        sleep 0.1
    done
}

start_agent() {
    [[ -f "$PLIST" ]] || { log "Not installed — run: $0 update"; exit 1; }
    if is_loaded; then
        launchctl kickstart "${DOMAIN}/${LABEL}"
    else
        launchctl bootstrap "$DOMAIN" "$PLIST"
    fi
}

cmd_update() {
    stop_agent
    copy_files
    write_plist
    launchctl bootstrap "$DOMAIN" "$PLIST"
    log "Updated and started ${LABEL}"
    log "Runs from: ${APP_DIR}"
}

cmd_status() {
    if [[ ! -f "$PLIST" ]]; then
        log "Login item: not installed (run: $0 update)"
        return
    fi
    log "Login item: installed"
    if is_loaded && [[ -n "$(agent_field pid)" ]]; then
        log "App:        running (pid $(agent_field pid))"
    else
        log "App:        not running (start with: $0 start)"
    fi
    local stale=() f
    for f in "${FILES[@]}"; do
        cmp -s "$SRC/$f" "$APP_DIR/$f" || stale+=("$f")
    done
    if ((${#stale[@]})); then
        log "Installed copy is out of date: ${stale[*]} (run: $0 update)"
    else
        log "Installed copy: up to date with ${SRC}"
    fi
}

case "${1:-}" in
    update|install) cmd_update ;;
    start)          start_agent; log "Started" ;;
    stop)           stop_agent; log "Stopped (starts again at next login, or: $0 start)" ;;
    restart)        stop_agent; start_agent; log "Restarted" ;;
    status)         cmd_status ;;
    logs)           touch "$LOG"; exec tail -n 50 -f "$LOG" ;;
    uninstall)      stop_agent; rm -f "$PLIST"; log "Removed login item (files left in: ${APP_DIR})" ;;
    *)              sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
