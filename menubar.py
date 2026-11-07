#!/usr/bin/env python3
"""Menubar item for sync.sh — click "Sync now" instead of running the script.

Run with ./run-menubar.sh (uses the local .venv with rumps installed).
"""

import os
import re
import subprocess
import threading
import time
from pathlib import Path

import rumps

HERE = Path(__file__).resolve().parent
SYNC = HERE / "sync.sh"
SOURCE = Path("/Volumes/Tascam/MTR")
DEST = Path.home() / "Music" / "Mixer"
LOG = Path.home() / "Library" / "Logs" / "mixer-sync.log"

ANSI = re.compile(r"\x1b\[[0-9;]*m")
STEP = re.compile(r"^Step (\d): (.*)")
CHECK_RESULT = re.compile(r"^Result: new=(\d+) bytes=(\d+) changed=(\d+)$")

# GUI apps don't inherit the shell PATH; sync.sh needs ffmpeg and rsync from brew.
ENV = {**os.environ, "PATH": f"/opt/homebrew/bin:/usr/local/bin:{os.environ.get('PATH', '')}"}

IDLE, BUSY, PENDING = "🎚", "🎚…", "🎚●"  # PENDING: the card has files not yet synced


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def notify(title, message):
    # osascript works without an app bundle, unlike rumps.notification on recent macOS.
    esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')
    script = f'display notification "{esc(message)}" with title "{esc(title)}"'
    subprocess.run(["osascript", "-e", script], check=False)


class MixerSync(rumps.App):
    def __init__(self):
        super().__init__("Mixer Sync", title=IDLE, quit_button="Quit")
        self.status = rumps.MenuItem("Idle")
        self.sync_item = rumps.MenuItem("Sync now", callback=self.sync_now)
        self.check_item = rumps.MenuItem("Check SD card for new files", callback=self.check_card)
        self.menu = [
            self.sync_item,
            self.check_item,
            self.status,
            None,
            rumps.MenuItem("Open processed folder", callback=lambda _: self.open(DEST / "processed")),
            rumps.MenuItem("Open raw folder", callback=lambda _: self.open(DEST / "raw")),
            rumps.MenuItem("Show last log", callback=lambda _: self.open(LOG)),
        ]
        self.running = False

    @staticmethod
    def open(path):
        subprocess.run(["open", str(path)], check=False)

    def sync_now(self, _):
        if self.running:
            return
        if not SOURCE.is_dir():
            notify("Mixer Sync", "SD card not found — is it plugged in?")
            self.status.title = "SD card not found"
            return
        self.set_busy(True)
        self.status.title = "Starting…"
        threading.Thread(target=self.run_sync, daemon=True).start()

    def set_busy(self, busy):
        """Grey out both actions (and show the busy icon) while a sync or check runs."""
        self.running = busy
        self.title = BUSY if busy else IDLE
        self.sync_item.set_callback(None if busy else self.sync_now)
        self.check_item.set_callback(None if busy else self.check_card)

    def check_card(self, _):
        if self.running:
            return
        if not SOURCE.is_dir():
            notify("Mixer Sync", "SD card not found — is it plugged in?")
            self.status.title = "SD card not found"
            return
        self.set_busy(True)
        self.status.title = "Checking card…"
        threading.Thread(target=self.run_check, daemon=True).start()

    def run_check(self):
        """Run `sync.sh --check` (metadata only, a few seconds) and report what's unsynced."""
        result = None
        try:
            p = subprocess.run([str(SYNC), "--check"], capture_output=True, text=True,
                               stdin=subprocess.DEVNULL, env=ENV, timeout=300)
            for line in reversed(ANSI.sub("", p.stdout).splitlines()):
                result = CHECK_RESULT.match(line.strip())
                if result:
                    break
            error = None if result else (p.stderr.strip().splitlines() or ["check failed"])[-1]
        except Exception as exc:  # sync.sh missing, timeout, ...
            error = str(exc)

        stamp = time.strftime("%H:%M")
        pending = False
        if not result:
            notify("Mixer Sync", f"Card check failed: {error}")
            self.status.title = "Card check failed"
        else:
            new, nbytes, changed = (int(g) for g in result.groups())
            pending = bool(new or changed)
            parts = []
            if new:
                parts.append(f"{new} new file{'s' * (new != 1)} ({human(nbytes)}) not synced")
            if changed:
                parts.append("1 file differs from its synced copy" if changed == 1
                             else f"{changed} files differ from their synced copies")
            if parts:
                msg = "; ".join(parts)
                notify("Mixer Sync: card check", msg + ("" if not changed else ". See sync.sh --check."))
                self.status.title = f"{msg} ({stamp})"[:80]
            else:
                notify("Mixer Sync: card check", "Everything on the card has been synced")
                self.status.title = f"Card fully synced ✓ ({stamp})"
            self.sync_item.title = f"Sync now ({new} new)" if new else "Sync now"
        self.set_busy(False)
        if pending:
            self.title = PENDING

    def run_sync(self):
        LOG.parent.mkdir(parents=True, exist_ok=True)
        tail = []
        try:
            with open(LOG, "w") as log, subprocess.Popen(
                [str(SYNC)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, text=True, env=ENV,
            ) as proc:
                for raw in proc.stdout:
                    line = ANSI.sub("", raw).rstrip()
                    log.write(line + "\n")
                    log.flush()
                    if line.strip():
                        tail.append(line.strip())
                        tail = tail[-30:]
                    m = STEP.match(line)
                    if m:
                        self.status.title = f"Step {m.group(1)}: {m.group(2)}"[:60]
                code = proc.wait()
        except Exception as exc:  # e.g. sync.sh missing or not executable
            code, tail = -1, [str(exc)]

        if code == 0:
            # sync.sh summary lines look like "Merged: 3  |  Skipped: 0  |  Errors: 0";
            # report just the leading count for each step.
            parts = []
            for key in ("Merged:", "Trimmed:", "Normalized:"):
                line = next((l for l in reversed(tail) if l.startswith(key)), "")
                if line:
                    parts.append(line.split("|")[0].strip())
            notify("Mixer Sync finished", " · ".join(parts) or "All done")
            self.status.title = "Last sync: OK"
            self.sync_item.title = "Sync now"  # whatever the last check found has been copied
        else:
            notify("Mixer Sync failed", tail[-1] if tail else f"exit {code}")
            self.status.title = f"Last sync failed (exit {code})"
        self.set_busy(False)


if __name__ == "__main__":
    MixerSync().run()
