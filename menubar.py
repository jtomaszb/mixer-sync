#!/usr/bin/env python3
"""Menubar item for sync.sh — click "Sync now" instead of running the script.

Run with ./run-menubar.sh (uses the local .venv with rumps installed).
"""

import os
import re
import subprocess
import threading
from pathlib import Path

import rumps

HERE = Path(__file__).resolve().parent
SYNC = HERE / "sync.sh"
SOURCE = Path("/Volumes/Tascam/MTR")
DEST = Path.home() / "Music" / "Mixer"
LOG = Path.home() / "Library" / "Logs" / "mixer-sync.log"

ANSI = re.compile(r"\x1b\[[0-9;]*m")
STEP = re.compile(r"^Step (\d): (.*)")

# GUI apps don't inherit the shell PATH; sync.sh needs ffmpeg and rsync from brew.
ENV = {**os.environ, "PATH": f"/opt/homebrew/bin:/usr/local/bin:{os.environ.get('PATH', '')}"}

IDLE, BUSY = "🎚", "🎚…"


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
        self.menu = [
            self.sync_item,
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
        self.running = True
        self.title = BUSY
        self.sync_item.set_callback(None)  # greys out while running
        self.status.title = "Starting…"
        threading.Thread(target=self.run_sync, daemon=True).start()

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
            merged = next((l for l in reversed(tail) if l.startswith("Merged:")), "")
            norm = next((l for l in reversed(tail) if l.startswith("Normalized:")), "")
            notify("Mixer Sync finished", " / ".join(filter(None, [merged, norm])) or "All done")
            self.status.title = "Last sync: OK"
        else:
            notify("Mixer Sync failed", tail[-1] if tail else f"exit {code}")
            self.status.title = f"Last sync failed (exit {code})"
        self.title = IDLE
        self.running = False
        self.sync_item.set_callback(self.sync_now)


if __name__ == "__main__":
    MixerSync().run()
