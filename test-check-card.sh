#!/usr/bin/env bash
# test-check-card.sh — self-test for `sync.sh --check` on generated data (touches nothing real).
#
# Walks a scratch library through: nothing synced -> synced -> new recording on the
# card -> a file reusing a synced name -> raw cleaned (registry takes over) -> card gone.
# Run from the repo: ./test-check-card.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-card-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CARD="$WORK/card" LIB="$WORK/lib"

fails=0
check() {  # description, expected, actual
    if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
result() {  # prints "new=N changed=C" from the Result: line
    "$HERE/sync.sh" --check --source "$CARD" --dest "$LIB" 2>&1 | sed -n 's/^Result: new=\([0-9]*\) bytes=[0-9]* changed=\([0-9]*\)$/new=\1 changed=\2/p'
}

"$HERE/make-test-data.sh" "$CARD" >/dev/null
mkdir -p "$LIB"

echo "Before any sync:"
check "every audio file on the card is new" "new=12 changed=0" "$(result)"

"$HERE/sync.sh" --source "$CARD" --dest "$LIB" >/dev/null 2>&1
echo "After a sync:"
check "nothing new, nothing changed" "new=0 changed=0" "$(result)"

echo "A new recording appears on the card:"
mkdir -p "$CARD/261201_0001"
cp "$CARD/260206_0001/01_260206_0001_TR01.wav" "$CARD/261201_0001/01_261201_0001_TR01.wav"
check "reported as new" "new=1 changed=0" "$(result)"
check "the check copies nothing" 12 "$(find "$LIB/raw" -name '*.wav' | wc -l | tr -d ' ')"
rm -rf "$CARD/261201_0001"

shift_mtime() {  # file seconds — move a file's mtime by N seconds
    local m; m="$(stat -f %m "$1")"
    touch -t "$(date -r $((m + $2)) +%Y%m%d%H%M.%S)" "$1"
}

echo "Daylight saving flips the card's clock by an hour:"
shift_mtime "$CARD/260206_0001/01_260206_0001_TR02.wav" 3600
check "a one-hour mtime shift is not a change" "new=0 changed=0" "$(result)"
shift_mtime "$CARD/260206_0001/01_260206_0001_TR02.wav" 7200
check "a two-hour shift is" "new=0 changed=1" "$(result)"
cp -p "$LIB/raw/260206_0001/01_260206_0001_TR02.wav" "$CARD/260206_0001/01_260206_0001_TR02.wav"

echo "A different file reuses a synced name:"
cp "$CARD/260206_0001/01_260206_0001_TR01.wav" "$WORK/orig.wav"
touch -t 202601010000 "$CARD/260206_0001/01_260206_0001_TR01.wav"
check "reported as changed" "new=0 changed=1" "$(result)"
cp -p "$LIB/raw/260206_0001/01_260206_0001_TR01.wav" "$CARD/260206_0001/01_260206_0001_TR01.wav"
check "restored: clean again" "new=0 changed=0" "$(result)"

echo "After cleaning raw (the registry takes over):"
"$HERE/clean_raw.py" --dest "$LIB" --delete --yes >/dev/null 2>&1
check "raw is empty but nothing is 'new'" "new=0 changed=0" "$(result)"
check "registry has a row per cleaned track" 12 "$(grep -c . "$LIB/raw/.registry.tsv")"
shift_mtime "$CARD/251116_0001/01_251116_0001_TR04.wav" 3600
check "a one-hour shift on a cleaned name is not a change" "new=0 changed=0" "$(result)"
touch -t 202601010000 "$CARD/251116_0001/01_251116_0001_TR03.wav"
check "a cleaned name that changed is caught" "new=0 changed=1" "$(result)"

echo "No card:"
if "$HERE/sync.sh" --check --source "$WORK/nope" --dest "$LIB" >/dev/null 2>&1; then
    check "exits non-zero when the card is missing" "fail" "ok"
else
    check "exits non-zero when the card is missing" "fail" "fail"
fi

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "All checks passed"
