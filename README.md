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
   (in place, only when it isn't already there). Files whose peak is below
   **-60 dBFS** are skipped: they're dead or near-silent tracks, and boosting
   them would just turn noise into loud noise.

Everything written to `processed/` is **24-bit PCM** (matching the recorder), so
merging and normalizing don't cost you bit depth.

`sync.sh` never modifies `raw/`; everything you'd actually use lands in
`processed/`. When you want the space back, [`clean_raw.py`](#cleaning-raw)
removes raw files only after proving the processed copy lost nothing.

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
It checks the card is mounted first. **Check SD card for new files** reports what's
on the card that hasn't been synced, without copying anything: the icon becomes 🎚●
and the sync item reads "Sync now (3 new)" until you sync. The menu also opens the
`raw/` and `processed/` folders and the last sync log.

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
| `sync.sh` | `NORMALIZE_FLOOR` | `-60` (dBFS) — quieter files aren't normalized |
| `sync.sh` | `AUDIO_CODEC` | `pcm_s24le` — output format of merged/normalized files |
| `sync.sh` | `TRIM` | `1` (set `0` or use `--no-trim` to skip) |
| `sync.sh` | `SILENCE_THRESHOLD` | `-50dB` — at or below this counts as silence |
| `sync.sh` | `SILENCE_MIN` | `2` — seconds of silence before the end is trimmed |
| `sync.sh` | `TRIM_KEEP` | `0.5` — seconds left after the last sound |
| `sync.sh` | `TRIM_WINDOW` | `60` — first tail window scanned, in seconds (doubles as needed) |
| `menubar.py` | `SOURCE`, `DEST` | same as above — keep in sync with `sync.sh` |

## Rebuilding `processed/`

Settings changes (bit depth, trim threshold, normalize floor) only apply to files
as they're created, and already-normalized files are skipped. To regenerate the
whole library from the untouched originals, remove `processed/` and re-run:

```bash
rm -rf ~/Music/Mixer/processed
./sync.sh
```

`raw/` is never modified by `sync.sh`, so nothing is lost, as long as you haven't
[cleaned](#cleaning-raw) the raw files you're rebuilding from.

## Checking the card

```bash
./sync.sh --check      # report what's on the card but not synced; copies nothing
```

It takes a second or two because it compares only names, sizes and modification
times, the same filters a real sync uses. (Checksumming the card would read every
byte at card speed, around 15 minutes for 70 GB, and a stored checksum would still
have to be re-computed from the card to compare, so it wouldn't be faster.) It
reports two things:

- **New**: on the card, not in `raw/`, and not cleaned from it. A sync would copy them.
- **Changed**: same name as something already synced but a different size or date,
  for example a reformatted card whose new recording reuses an old file name. A normal
  sync skips existing names, so it would silently never copy these. Compare them by
  hand before wiping the card.

For raw files that have been [cleaned](#cleaning-raw), the comparison uses
`raw/.registry.tsv` (size and modification time, recorded at cleaning time). Card
timestamps are allowed to differ by an hour, because FAT/exFAT cards store local
time with no UTC offset and shift when daylight saving flips.

`./test-check-card.sh` is the self-test for this.

## Cleaning raw

Once files are processed you can reclaim the space taken by `raw/`. `clean_raw.py`
only removes raw files it can prove are fully represented in `processed/`:

```bash
./clean_raw.py                  # dry run: verify and report, change nothing
./clean_raw.py --trash          # move verified raw files to the Trash (recoverable)
./clean_raw.py --delete         # permanently delete them (asks first; --yes to skip)
./clean_raw.py --session 261022_0001   # only one session folder
```

For each processed file it checks, with `ffmpeg`:

- the processed file exists, is **24-bit** PCM, and has the right channels and rate;
- its audio equals the raw audio times one gain (what normalize applied), to within
  24-bit rounding: the gain is fitted from the RMS, then `processed − gain × raw` is
  measured and must sit near the 24-bit noise floor (about -138 dBFS; the check
  allows -110). A 16-bit copy, a wrong or damaged file, or mismatched audio all fail;
- if the processed file is shorter (trimmed silence), the raw audio past the cut is
  really silent.

Anything that fails is **kept** and the reason is printed. Raw tracks that
`sync.sh` never processes (for example an even track with no odd partner) are also
kept. Verification is slow-ish, reading each file a few times, so `-j` runs several
in parallel; files cleaned on an earlier run aren't re-checked.

Removed files are listed in `raw/.cleaned`. `sync.sh` hands that list to rsync, so
a card that still holds those recordings doesn't get them copied back. (rsync may
recreate empty session folders; they're harmless.)

Cleaning makes `processed/` the only copy of those recordings, so keep it backed up,
and note that a rebuild of `processed/` can only use raw files that are still there.
If your `processed/` predates the 24-bit change it will be flagged as 16-bit and
nothing will be cleaned until you rebuild it.

## Testing without a recorder

`make-test-data.sh` generates a fake card with a couple of sessions (stereo pairs,
empty tracks, `.sys`/`.bin` files):

```bash
./make-test-data.sh /tmp/mock-card
./sync.sh --source /tmp/mock-card --dest /tmp/mixer-test-out
```

`./test-clean-raw.sh` is a self-test for the raw cleaner: it builds a scratch library,
checks that good files verify and damaged ones are refused, and that cleaning and the
`.cleaned` list behave. It never touches your real library.

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
