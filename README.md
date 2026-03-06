# mixer-sync

Copies new audio files from a mixer SD card to `~/Music/Mixer`, skipping files that already exist.

## Usage

```bash
chmod +x sync.sh   # one-time setup
./sync.sh
```

The script will:
1. Scan `/Volumes` for connected external volumes
2. Prompt you to pick one if multiple are found
3. Recursively find all audio files (`wav`, `mp3`, `aiff`, `flac`, `m4a`, `ogg`)
4. Copy any that don't already exist in `~/Music/Mixer`
5. Print a summary of copied / skipped / errors

## Configuration

Edit the top of `sync.sh` to change defaults:

| Variable | Default | Description |
|---|---|---|
| `DEST` | `~/Music/Mixer` | Destination folder |
| `AUDIO_EXTENSIONS` | wav mp3 aiff flac m4a ogg | File types to sync |
