#!/usr/bin/env bash
# make-test-data.sh — Generate a fake Tascam SD card for testing sync.sh
#
# Usage:
#   ./make-test-data.sh [OUTPUT_DIR]
#
# Creates a directory that mimics /Volumes/Tascam/MTR/ with two sessions:
#   - 251116_0001: 3 stereo pairs (TR01-06; pair 3 has a silent tail), one fully
#                  silent track (TR07), TR08-16 empty (skipped by --min-size)
#   - 260206_0001: 2 stereo pairs (TR01-04), one very quiet track (TR05, -80 dB),
#                  rest empty
#   Also includes song.sys and tempTr*.bin files (should be excluded)
#
# After running, test with:
#   ./sync.sh --source OUTPUT_DIR --dest /tmp/mixer-test-out

set -euo pipefail

OUT="${1:-/tmp/mock-tascam-mtr}"

ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m→\033[0m %s\n' "$*"; }

require_ffmpeg() {
    if ! command -v ffmpeg &>/dev/null; then
        echo "ffmpeg is required. Install with: brew install ffmpeg" >&2
        exit 1
    fi
}

# Generate a mono WAV: sine wave at given frequency, duration, volume,
# optionally followed by TAIL_SEC of digital silence (exercises the trim step)
# make_wav OUTPUT FREQ_HZ DURATION_SEC VOLUME_DB [TAIL_SEC]
make_wav() {
    local out="$1" freq="$2" dur="$3" vol="$4" tail="${5:-0}"
    ffmpeg -loglevel error -f lavfi \
        -i "sine=frequency=${freq}:duration=${dur}" \
        -af "volume=${vol}dB,apad=pad_dur=${tail}" \
        -ar 48000 -ac 1 -c:a pcm_s24le \
        "$out"
}

# Generate a WAV that is silent from start to end, big enough to pass --min-size
# make_silent_wav OUTPUT DURATION_SEC
make_silent_wav() {
    ffmpeg -loglevel error -f lavfi \
        -i "anullsrc=r=48000:cl=mono" \
        -t "$2" \
        -c:a pcm_s24le \
        "$1"
}

# Generate a tiny near-silent WAV (~6KB, like an unused Tascam track)
make_empty_wav() {
    local out="$1"
    ffmpeg -loglevel error -f lavfi \
        -i "anullsrc=r=48000:cl=mono" \
        -t 0.05 \
        -c:a pcm_s24le \
        "$out"
}

make_junk_file() {
    printf 'TASCAM JUNK\n' > "$1"
}

# ── session 1: 3 real stereo pairs, rest empty ───────────────────────────────

SESSION1="${OUT}/251116_0001"
PREFIX1="01_251116_0001"
mkdir -p "$SESSION1"
info "Generating session: 251116_0001"

# TR01 (L, 220 Hz, -6 dB) + TR02 (R, 330 Hz, -8 dB)  → pair 1
make_wav "${SESSION1}/${PREFIX1}_TR01.wav" 220 5 -6
make_wav "${SESSION1}/${PREFIX1}_TR02.wav" 330 5 -8
ok "  TR01 + TR02 (pair 1)"

# TR03 (L, 440 Hz, -3 dB) + TR04 (R, 550 Hz, -5 dB)  → pair 2
make_wav "${SESSION1}/${PREFIX1}_TR03.wav" 440 5 -3
make_wav "${SESSION1}/${PREFIX1}_TR04.wav" 550 5 -5
ok "  TR03 + TR04 (pair 2)"

# TR05 (L, 660 Hz, -10 dB) + TR06 (R, 770 Hz, -12 dB) → pair 3
# Each has 6 s of silence after the 5 s tone: the trim step should cut it back.
make_wav "${SESSION1}/${PREFIX1}_TR05.wav" 660 5 -10 6
make_wav "${SESSION1}/${PREFIX1}_TR06.wav" 770 5 -12 6
ok "  TR05 + TR06 (pair 3, 6 s silent tail)"

# TR07: entirely silent but big enough to be copied (trim must leave it alone)
make_silent_wav "${SESSION1}/${PREFIX1}_TR07.wav" 6
ok "  TR07 (entirely silent, 6 s)"

# TR08–TR16: empty (should be skipped by --min-size=100k)
for n in 08 09 10 11 12 13 14 15 16; do
    make_empty_wav "${SESSION1}/${PREFIX1}_TR${n}.wav"
done
ok "  TR08–TR16 (empty, will be skipped)"

# Junk files (should be excluded)
make_junk_file "${SESSION1}/song.sys"
for n in $(seq 1 12); do
    make_junk_file "${SESSION1}/tempTr${n}_A.bin"
done
ok "  song.sys + tempTr*.bin (junk, will be excluded)"

# ── session 2: 2 real stereo pairs ───────────────────────────────────────────

SESSION2="${OUT}/260206_0001"
PREFIX2="01_260206_0001"
mkdir -p "$SESSION2"
info "Generating session: 260206_0001"

make_wav "${SESSION2}/${PREFIX2}_TR01.wav" 880  4 -4
make_wav "${SESSION2}/${PREFIX2}_TR02.wav" 1100 4 -7
ok "  TR01 + TR02"

make_wav "${SESSION2}/${PREFIX2}_TR03.wav" 1320 4 -2
make_wav "${SESSION2}/${PREFIX2}_TR04.wav" 1540 4 -9
ok "  TR03 + TR04"

# TR05: a very quiet track (-80 dB peak), like a dead channel picking up noise.
# Normalize must leave it alone (below the floor) instead of boosting it ~80 dB.
make_wav "${SESSION2}/${PREFIX2}_TR05.wav" 200 6 -80
ok "  TR05 (-80 dB, below the normalize floor)"

for n in 06 07 08 09 10 11 12 13 14 15 16; do
    make_empty_wav "${SESSION2}/${PREFIX2}_TR${n}.wav"
done
ok "  TR06–TR16 (empty)"

make_junk_file "${SESSION2}/song.sys"
for n in $(seq 1 12); do
    make_junk_file "${SESSION2}/tempTr${n}_A.bin"
done
ok "  song.sys + tempTr*.bin (junk)"

# ── done ─────────────────────────────────────────────────────────────────────

echo ""
echo "Mock SD card created at: $OUT"
echo ""
echo "Run the sync script against it:"
echo "  ./sync.sh --source \"$OUT\" --dest /tmp/mixer-test-out"
echo ""
echo "Then inspect results:"
echo "  ls /tmp/mixer-test-out/raw/"
echo "  ls /tmp/mixer-test-out/processed/"
