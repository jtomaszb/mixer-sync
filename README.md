# mixer-sync

Pull recordings off a multitrack recorder's SD card, merge the mono tracks into
stereo pairs, trim the silence off the end, and peak-normalize them — from one
command or one click in the macOS menubar.

I built this for a Tascam multitrack recorder that writes one mono WAV per track
into numbered session folders. It should work with any recorder that uses the
same layout (see [Expected layout](#expected-layout)).

## What it does

`sync.sh` runs four steps:

1. **Copy** — `rsync` new files from the SD card into `raw/`. Files that already
   exist are skipped, so it's safe to run repeatedly. Empty tracks (under 100 KB),
   `*.sys`, `*.bin` and dotfiles are ignored.
2. **Merge** — pair adjacent odd/even tracks into stereo (`TR01`+`TR02` →
   `TR01-02`, `TR03`+`TR04` → `TR03-04`, …) with `ffmpeg`. An odd track with no
   even partner is copied through as mono.
3. **Trim** — cut trailing silence off every file in `processed/`. Silence is
   anything below -50 dB for at least 2 seconds at the end of a clip; the cut
   leaves 0.5 s after the last sound. Only the tail is scanned (clips can be
   hours long) and the cut is a stream copy, so there's no re-encode. A file
   that is silent from start to end is left alone. Skip the step with
   `--no-trim`.
4. **Normalize** — peak-normalize every file in `processed/` to **-1 dBFS**
   (in place, only when it isn't already there).

`raw/` is never modified; everything you'd actually use lands in `processed/`.

```
~/Music/Mixer/
  raw/<session>/        untouched copies from the SD card
  processed/<session>/  merged stereo (or mono) files, normalized
```

## Expected layout

```
<SD card>/MTR/<session>/<prefix>_TR01.wav
                        <prefix>_TR02.wav
                        ...
```

Track numbers in the `_TRnn.wav` suffix decide the pairing: odd = left channel,
even = right channel, merged as `<prefix>_TRnn-mm.wav`. The card is expected at
`/Volumes/Tascam/MTR`; change `SOURCE` in `sync.sh` (and `menubar.py`) for a
different volume name, or pass `--source`.

## Requirements

- macOS (the menubar item and login item use macOS-only APIs; `sync.sh` itself
  is plain bash)
- [`ffmpeg`](https://ffmpeg.org): `brew install ffmpeg`
- `rsync` 3.x is strongly recommended: `brew install rsync`. The system rsync
  builds a full file list before copying, which is very slow on a big SD card;
  `sync.sh` prefers the Homebrew one when it's installed.
- Python 3 for the menubar item (its `rumps` dependency is installed into a local
  virtualenv automatically)

## Usage

```bash
./sync.sh                              # card at /Volumes/Tascam/MTR → ~/Music/Mixer
./sync.sh --source /path/to/MTR        # different source folder
./sync.sh --dest ~/Audio/Mixer         # different destination
./sync.sh --no-trim                    # skip trimming trailing silence
./sync.sh --help
```

Re-running is idempotent: existing raw files, merged files, already-trimmed files
and already-normalized files are skipped. Note that Step 4 decodes every file in
`processed/` to measure its peak, so runs get slower as the library grows.

### Menubar item

```bash
./run-menubar.sh      # try it out in the foreground
```

A 🎚 icon appears in the menubar. (The menubar app always runs the default
settings; edit `sync.sh` to change the trim threshold there.) **Sync now** runs `sync.sh`, the icon changes
to 🎚… with a live step status in the menu, and a notification reports the result.
It checks the card is mounted first. The menu also opens the `raw/` and
`processed/` folders and the last sync log.

### Start at login / updating

`menubar.sh` installs and controls the menubar item as a login item:

```bash
./menubar.sh update      # first-time install, and after any change to sync.sh / menubar.py
./menubar.sh status      # running? is the installed copy up to date?
./menubar.sh start|stop|restart
./menubar.sh logs        # follow the app log
./menubar.sh uninstall   # remove the login item
```

`update` installs a LaunchAgent (`local.mixer-sync.menubar`) that starts the item
at every login, and restarts it with the latest code. macOS blocks background
login jobs from reading `~/Desktop`, `~/Documents` and `~/Downloads`, so the
runtime files are copied to `~/Library/Application Support/mixer-sync/` and run
from there. That installed copy is a snapshot: run `./menubar.sh update` after
editing. `stop` (or **Quit** in the menu) keeps it stopped until the next login
or `start`.

Logs: `~/Library/Logs/mixer-sync-menubar.log` (app) and
`~/Library/Logs/mixer-sync.log` (most recent sync).

## Configuration

| Where | Setting | Default |
|---|---|---|
| `sync.sh` | `DEST` | `~/Music/Mixer` |
| `sync.sh` | `SOURCE` | `/Volumes/Tascam/MTR` |
| `sync.sh` | `PEAK_TARGET` | `-1` (dBFS) |
| `sync.sh` | `TRIM` | `1` (set `0` or use `--no-trim` to skip) |
| `sync.sh` | `SILENCE_THRESHOLD` | `-50dB` — at or below this counts as silence |
| `sync.sh` | `SILENCE_MIN` | `2` — seconds of silence before the end is trimmed |
| `sync.sh` | `TRIM_KEEP` | `0.5` — seconds left after the last sound |
| `sync.sh` | `TRIM_WINDOW` | `60` — first tail window scanned, in seconds (doubles as needed) |
| `menubar.py` | `SOURCE`, `DEST` | same as above — keep in sync with `sync.sh` |

## Testing without a recorder

`make-test-data.sh` generates a fake card with a couple of sessions (stereo pairs,
empty tracks, `.sys`/`.bin` files):

```bash
./make-test-data.sh /tmp/mock-card
./sync.sh --source /tmp/mock-card --dest /tmp/mixer-test-out
```

## Troubleshooting

- **Menubar icon missing** — `./menubar.sh status`. If it's running, the menubar
  may be full (icons that don't fit are hidden, especially around the notch).
- **Login item won't start** — `./menubar.sh logs`. Don't point a LaunchAgent at
  a script under `~/Desktop`; that's what the install-to-Application-Support
  step avoids.
- **Slow "building file list"** — you're using the system rsync; `brew install rsync`.
- **Sync stops silently** — `sync.sh` runs with `set -e`; an `ERR` trap prints the
  failing line and command. Check `~/Library/Logs/mixer-sync.log`.

Not affiliated with or endorsed by TASCAM.
