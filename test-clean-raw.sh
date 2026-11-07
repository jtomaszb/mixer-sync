#!/usr/bin/env bash
# test-clean-raw.sh — self-test for clean_raw.py on generated data (touches nothing real).
#
# Builds a mock card, syncs it into a scratch library, then checks that clean_raw.py
# verifies the good files, refuses damaged ones, and that --delete + the .cleaned
# manifest behave. Run from the repo: ./test-clean-raw.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/clean-raw-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fails=0
check() {  # description, expected, actual
    if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
verified() { "$HERE/clean_raw.py" --dest "$1" "${@:2}" 2>&1 | sed -n 's/^Verified: \([0-9]*\) file.*/\1/p'; }
ff() { ffmpeg -nostdin -loglevel error -y "$@"; }

echo "Building scratch library..."
"$HERE/make-test-data.sh" "$WORK/card" >/dev/null
"$HERE/sync.sh" --source "$WORK/card" --dest "$WORK/lib" >/dev/null 2>&1
cp "$WORK/lib/raw/260206_0001/01_260206_0001_TR01.wav" "$WORK/lib/raw/260206_0001/01_260206_0001_TR10.wav"  # orphan

echo "Intact library:"
check "all 7 processed files verify" 7 "$(verified "$WORK/lib")"

echo "Damaged copies (each must be kept):"
cp -R "$WORK/lib" "$WORK/neg"
P="$WORK/neg/processed"
cp "$P/251116_0001/01_251116_0001_TR03-04.wav" "$P/251116_0001/01_251116_0001_TR05-06.wav"   # wrong audio
rm "$P/251116_0001/01_251116_0001_TR03-04.wav"                                                # missing
ff -i "$P/251116_0001/01_251116_0001_TR01-02.wav" -c:a pcm_s16le "$WORK/x.wav"                # 16-bit
cp "$WORK/x.wav" "$P/251116_0001/01_251116_0001_TR01-02.wav"
ff -i "$P/260206_0001/01_260206_0001_TR03-04.wav" -t 2 -c copy "$WORK/x.wav"                  # truncated
cp "$WORK/x.wav" "$P/260206_0001/01_260206_0001_TR03-04.wav"
ff -f lavfi -i "sine=frequency=440:duration=6" -ar 48000 -ac 1 -c:a pcm_s24le \
   "$P/251116_0001/01_251116_0001_TR07.wav"                                                   # sound where raw is silent
# Left intact: 260206 TR01-02 and TR05, so 2 of 7 should still verify.
check "5 of 7 damaged files rejected" 2 "$(verified "$WORK/neg")"

echo "Delete and re-sync:"
raw_before=$(find "$WORK/lib/raw" -name '*.wav' | wc -l | tr -d ' ')
"$HERE/clean_raw.py" --dest "$WORK/lib" --delete --yes >/dev/null 2>&1
check "only the orphan track is left in raw/" 1 "$(find "$WORK/lib/raw" -name '*.wav' | wc -l | tr -d ' ')"
check "12 of $raw_before raw tracks removed" 12 $((raw_before - $(find "$WORK/lib/raw" -name '*.wav' | wc -l | tr -d ' ')))
check "processed files untouched" 7 "$(find "$WORK/lib/processed" -name '*.wav' | wc -l | tr -d ' ')"
"$HERE/sync.sh" --source "$WORK/card" --dest "$WORK/lib" >/dev/null 2>&1
check "re-sync doesn't copy cleaned files back" 1 "$(find "$WORK/lib/raw" -name '*.wav' | wc -l | tr -d ' ')"

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "All checks passed"
