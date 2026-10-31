# mixer-sync

Syncs audio from a mixer SD card in three steps:

1. **Copy** — copies new audio files from SD card → `~/Music/Mixer/raw/`
2. **Merge** — pairs `TrackXXL.wav` + `TrackXXR.wav` split-mono files into a single stereo `TrackXX.wav` → `~/Music/Mixer/processed/`
3. **Normalize** — peak-normalizes each processed file to **-1 dBFS**

## Requirements

```bash
brew install ffmpeg
```

## Usage

```bash
chmod +x sync.sh   # one-time setup
./sync.sh
```

Plug in your SD card, then run the script. If multiple volumes are detected it will ask you to pick one.

## Menubar item

Click-to-sync from the macOS menubar (🎚) instead of running the script:

```bash
./run-menubar.sh
```

The first run creates a local `.venv` and installs `rumps`. The menu has **Sync now**, live step status, shortcuts to the processed/raw folders, and the last log (`~/Library/Logs/mixer-sync.log`). It checks that the SD card is mounted before starting and posts a notification when the sync finishes.

### Start at login

```bash
./install-login-item.sh              # install / update
./install-login-item.sh --uninstall  # remove
```

This installs a LaunchAgent that starts the menubar item at login. macOS blocks background login jobs from reading `~/Desktop`, so the installer copies the runtime files to `~/Library/Application Support/mixer-sync/` and runs from there. Re-run it after changing `sync.sh` or `menubar.py`. Logs: `~/Library/Logs/mixer-sync-menubar.log`.

## Output layout

```
~/Music/Mixer/
  raw/          ← untouched copies of every file from the SD card
  processed/    ← merged stereo + normalized files (ready to use)
```

## Supported formats

`wav`, `mp3`, `aiff`, `flac`, `m4a`, `ogg`

## L/R pair detection

The script matches files where the name ends in `L` / `R` (case-insensitive), with an optional `_` or `-` separator before the channel letter:

| Left file | Right file | Output |
|---|---|---|
| `Track01L.wav` | `Track01R.wav` | `Track01.wav` |
| `Track01_L.wav` | `Track01_R.wav` | `Track01.wav` |
| `Track01-L.wav` | `Track01-R.wav` | `Track01.wav` |

Files with no matching pair are left in `raw/` as-is with a warning.

## Configuration

Edit the top of `sync.sh` to change defaults:

| Variable | Default | Description |
|---|---|---|
| `DEST` | `~/Music/Mixer` | Root output folder |
| `PEAK_TARGET` | `-1` | Peak normalization target in dBFS |
| `AUDIO_EXTENSIONS` | wav mp3 aiff flac m4a ogg | File types to sync |
