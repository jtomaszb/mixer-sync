#!/usr/bin/env bash
# sync.sh — Sync mixer SD card audio: copy → merge stereo pairs → trim end silence → normalize
#
# Naming convention: {prefix}_TR{NN}.wav
#   Odd track numbers  = left channel  (TR01, TR03, TR05, ...)
#   Even track numbers = right channel (TR02, TR04, TR06, ...)
#   Adjacent pairs are merged: TR01+TR02 → TR01-02.wav, TR03+TR04 → TR03-04.wav
#
# Output layout:
#   $DEST/raw/{session}/        raw copies from SD (untouched)
#   $DEST/processed/{session}/  merged stereo, end-trimmed, peak-normalized files

set -Eeuo pipefail

DEST="${HOME}/Music/Mixer"
SOURCE="/Volumes/Tascam/MTR"
PEAK_TARGET="-1"            # dBFS
NORMALIZE_FLOOR="-60"       # dBFS; files whose peak is below this are not normalized
                            # (near-silent/dead tracks: boosting them only amplifies noise)
AUDIO_CODEC="pcm_s24le"     # processed files are written as 24-bit PCM

# Trailing-silence trim (step 3)
TRIM=1                      # set to 0, or pass --no-trim, to skip the step
SILENCE_THRESHOLD="-50dB"   # at or below this level counts as silence
SILENCE_MIN="2"             # seconds of silence before the end counts as trimmable
TRIM_KEEP="0.5"             # seconds of silence left after the last sound
TRIM_WINDOW="60"            # first tail window scanned, in seconds (doubles as needed)

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { printf '%s\n' "$*"; }
info() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Under set -e a failing command exits silently. Remember the last failure and, only
# if the script actually exits with an error, say where. (Printing from the ERR trap
# itself would also fire for failures the script handles, e.g. `cmd || fallback`.)
LAST_FAILURE=""
trap 'LAST_FAILURE="line $LINENO (status $?): $BASH_COMMAND"' ERR
trap 'rc=$?; if [[ $rc -ne 0 && -n "$LAST_FAILURE" ]]; then err "Exited with status $rc. Last failure seen: $LAST_FAILURE"; fi' EXIT

require() {
    if ! command -v "$1" &>/dev/null; then
        err "Required tool not found: $1"
        err "Install with: brew install $1"
        exit 1
    fi
}

# ── step 1: copy raw files, preserving folder structure ───────────────────────

copy_from_sd() {
    local source="$1"
    local raw_dir="$2"

    # Prefer Homebrew rsync 3.x: it starts copying immediately (incremental file
    # list). The system rsync (2.6.9 / openrsync) stats the whole card up front.
    local rsync_bin
    for rsync_bin in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
        [[ -x "$rsync_bin" ]] && break
        rsync_bin=""
    done
    if [[ -z "$rsync_bin" ]]; then
        rsync_bin="$(command -v rsync)"
        warn "Using $rsync_bin — slow file listing; 'brew install rsync' for a faster scan"
    fi

    # rsync: archive mode, skip files that already exist at destination
    # -a: preserve timestamps/permissions, -v: verbose, --ignore-existing: skip existing
    "$rsync_bin" -av --ignore-existing --min-size=100k \
          --exclude="*.sys" --exclude="*.bin" --exclude=".*" \
          "${source}/" "${raw_dir}/"
}

# ── step 2: merge adjacent odd/even TR pairs into stereo ─────────────────────
#
# Matches files like: 01_260206_0001_TR01.wav
# Pattern:            {anything}_TR{NN}.wav  where NN is odd (left channel)
# Pairs with:         {anything}_TR{NN+1}.wav (even = right channel)
# Output name:        {anything}_TR{NN}-{NN+1}.wav

merge_stereo_pairs() {
    local raw_dir="$1"
    local proc_dir="$2"
    local merged=0 skipped=0 errors=0

    # Walk all .wav files recursively, find left-channel (odd TR) files
    while IFS= read -r lfile; do
        local rel_path="${lfile#${raw_dir}/}"          # e.g. 260206_0001/01_260206_0001_TR01.wav
        local session_dir
        session_dir="$(dirname "$rel_path")"           # e.g. 260206_0001
        local filename
        filename="$(basename "$lfile")"                # e.g. 01_260206_0001_TR01.wav

        # Match the _TR{NN} suffix (case-insensitive, zero-padded number)
        if ! [[ "$filename" =~ ^(.+_[Tt][Rr])([0-9]+)(\.wav)$ ]]; then
            continue
        fi

        local prefix="${BASH_REMATCH[1]}"   # e.g. "01_260206_0001_TR"
        local num_str="${BASH_REMATCH[2]}"  # e.g. "01"
        local ext="${BASH_REMATCH[3]}"      # ".wav"
        local num=$(( 10#$num_str ))        # decimal value

        # Only process odd-numbered tracks (left channel)
        (( num % 2 == 1 )) || continue

        # Right channel is the next track number, zero-padded to same width
        local width=${#num_str}
        local right_num_str
        right_num_str=$(printf "%0${width}d" $(( num + 1 )))

        local raw_session_dir="${raw_dir}/${session_dir}"
        local rfile="${raw_session_dir}/${prefix}${right_num_str}${ext}"

        if [[ ! -f "$rfile" ]]; then
            warn "No stereo pair for: $filename — copying as mono"
            local out_session_dir="${proc_dir}/${session_dir}"
            mkdir -p "$out_session_dir"
            local mono_out="${out_session_dir}/${filename}"
            if [[ -e "$mono_out" ]]; then
                warn "Skipping mono (exists): ${session_dir}/${filename}"
                skipped=$((skipped + 1))
            elif cp "$lfile" "$mono_out"; then
                ok "Copied mono: ${session_dir}/${filename}"
                merged=$((merged + 1))
            else
                err "Copy failed: ${session_dir}/${filename}"
                errors=$((errors + 1))
            fi
            continue
        fi

        # Output: same session folder under processed/, with merged name
        local out_session_dir="${proc_dir}/${session_dir}"
        mkdir -p "$out_session_dir"
        local out_name="${prefix}${num_str}-${right_num_str}${ext}"
        local out_file="${out_session_dir}/${out_name}"

        if [[ -e "$out_file" ]]; then
            warn "Skipping (exists): ${session_dir}/${out_name}"
            skipped=$((skipped + 1))
            continue
        fi

        info "Merging: $filename + $(basename "$rfile") → $out_name"
        if ffmpeg -nostdin -loglevel error \
                  -i "$lfile" -i "$rfile" \
                  -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo[out]" \
                  -map "[out]" \
                  -c:a "$AUDIO_CODEC" \
                  "$out_file"; then
            ok "Merged: ${session_dir}/${out_name}"
            merged=$((merged + 1))
        else
            err "Merge failed: $out_name"
            rm -f "$out_file"
            errors=$((errors + 1))
        fi

    done < <(find "$raw_dir" -iname "*_tr[0-9]*.wav" -type f | sort)

    log ""
    log "  Merged: $merged  |  Skipped (exists): $skipped  |  Errors: $errors"
    [[ $errors -gt 0 ]] && return 1 || return 0
}

# ── step 3: trim trailing silence from files in processed/ ───────────────────
#
# Clips can be hours long, so never decode a whole file just to look at its end:
# scan only the tail, widening the window while the silence runs back past the
# window's start, then cut with a stream copy (no re-encode).

# Echo "<cut_seconds> <total_seconds>" if the file ends in silence worth trimming.
# Echo nothing if it doesn't, or "ALL" if the whole file is silent. Return 1 on error.
trailing_silence_cut() {
    local file="$1"
    local dur window="$TRIM_WINDOW" offset len silent_from

    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file") || return 1
    # A WAV with no usable duration reports "N/A"; treat that as unscannable, not as a number.
    [[ "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1

    while :; do
        offset=$(awk -v d="$dur" -v w="$window" 'BEGIN { o = d - w; if (o < 0) o = 0; printf "%.3f", o }')
        len=$(awk -v d="$dur" -v o="$offset" 'BEGIN { printf "%.3f", d - o }')

        # silencedetect reports times relative to the seek point. A silence is
        # "open" (runs to EOF) if it started and never ended, or ended at the end.
        # || true: no silence at all is a normal outcome, not an error.
        silent_from=$(ffmpeg -nostdin -loglevel info -ss "$offset" -i "$file" \
                        -af "silencedetect=noise=${SILENCE_THRESHOLD}:d=${SILENCE_MIN}" -f null - 2>&1 \
                      | awk -v len="$len" '
                          /silence_start:/ { s = $NF; open = 1 }
                          /silence_end:/   { if ($5 + 0 < len - 0.1) open = 0 }
                          END { if (open) print s }' || true)

        [[ -n "$silent_from" ]] || return 0   # file ends with sound

        # Silence reaching the start of the window: look further back, or give up
        # if the window already covers the whole file.
        if awk -v s="$silent_from" 'BEGIN { exit !(s <= 0.05) }'; then
            if awk -v o="$offset" 'BEGIN { exit !(o <= 0) }'; then
                echo "ALL"
                return 0
            fi
            window=$(awk -v w="$window" 'BEGIN { printf "%d", w * 2 }')
            continue
        fi

        awk -v o="$offset" -v s="$silent_from" -v k="$TRIM_KEEP" -v d="$dur" \
            'BEGIN { printf "%.3f %.3f", o + s + k, d }'
        return 0
    done
}

trim_trailing_silence() {
    local proc_dir="$1"
    local trimmed=0 skipped=0 errors=0

    while IFS= read -r file; do
        local rel="${file#${proc_dir}/}"
        local tmpfile="${file}.tmp.wav"
        local result cut total

        if ! result=$(trailing_silence_cut "$file"); then
            warn "Could not scan: $rel"
            errors=$((errors + 1))
            continue
        fi

        if [[ -z "$result" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        if [[ "$result" == "ALL" ]]; then
            warn "Entirely silent, leaving as is: $rel"
            skipped=$((skipped + 1))
            continue
        fi

        read -r cut total <<< "$result"
        info "Trimming: $rel  ($(awk -v t="$total" 'BEGIN { printf "%.1f", t }')s → ${cut}s)"

        if ffmpeg -nostdin -loglevel error -y -i "$file" -t "$cut" -c copy "$tmpfile" \
           && mv "$tmpfile" "$file"; then
            ok "Trimmed: $rel"
            trimmed=$((trimmed + 1))
        else
            rm -f "$tmpfile"
            err "Trim failed: $rel"
            errors=$((errors + 1))
        fi

    done < <(find "$proc_dir" -iname "*.wav" ! -name "*.tmp.wav" -type f | sort)

    log ""
    log "  Trimmed: $trimmed  |  Skipped: $skipped  |  Errors: $errors"
    [[ $errors -gt 0 ]] && return 1 || return 0
}

# ── step 4: peak-normalize all files in processed/ ───────────────────────────

normalize_files() {
    local proc_dir="$1"
    local normalized=0 skipped=0 errors=0

    while IFS= read -r file; do
        local rel="${file#${proc_dir}/}"
        local tmpfile="${file}.tmp.wav"

        # Detect current peak volume
        # Note: volumedetect logs at "info" level, so -loglevel error suppresses it.
        # Use -loglevel info and grep for just the max_volume line.
        local max_vol
        # -nostdin: don't let ffmpeg consume the file list piped into this loop.
        # || true: a no-match grep must not trip set -e/pipefail; handled below.
        max_vol=$(ffmpeg -nostdin -loglevel info -i "$file" -af "volumedetect" -f null /dev/null 2>&1 \
                  | grep "max_volume" | awk '{print $5}' || true)

        if [[ -z "$max_vol" ]]; then
            warn "Could not detect peak for: $rel"
            skipped=$((skipped + 1))
            continue
        fi

        # Near-silent files (or digital silence, reported as -inf) aren't worth boosting.
        if [[ "$max_vol" == *inf* ]] \
           || awk -v m="$max_vol" -v f="$NORMALIZE_FLOOR" 'BEGIN { exit !(m + 0 < f + 0) }'; then
            warn "Below ${NORMALIZE_FLOOR} dB floor (peak ${max_vol} dB), not normalizing: $rel"
            skipped=$((skipped + 1))
            continue
        fi

        # Gain needed: target - max_vol  (max_vol is negative, e.g. -3.2 dB)
        local gain
        gain=$(awk -v t="$PEAK_TARGET" -v m="$max_vol" 'BEGIN { printf "%.2f", t - m }')

        if [[ "$gain" == "0.00" ]]; then
            ok "Already at target: $rel"
            skipped=$((skipped + 1))
            continue
        fi

        info "Normalizing: $rel  (peak ${max_vol} dB → ${PEAK_TARGET} dBFS, gain ${gain} dB)"

        if ffmpeg -nostdin -loglevel error -y -i "$file" -af "volume=${gain}dB" -c:a "$AUDIO_CODEC" "$tmpfile" \
           && mv "$tmpfile" "$file"; then
            ok "Normalized: $rel"
            normalized=$((normalized + 1))
        else
            rm -f "$tmpfile"
            err "Failed: $rel"
            errors=$((errors + 1))
        fi

    done < <(find "$proc_dir" -iname "*.wav" ! -name "*.tmp.wav" -type f | sort)

    log ""
    log "  Normalized: $normalized  |  Skipped: $skipped  |  Errors: $errors"
    [[ $errors -gt 0 ]] && return 1 || return 0
}

# ── main ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --source DIR   Use DIR instead of the default card path ($SOURCE)
  --dest DIR     Override destination (default: $DEST)
  --no-trim      Skip trimming trailing silence (step 3)
  -h, --help     Show this help
EOF
    exit 0
}

main() {
    require ffmpeg
    require ffprobe
    require rsync

    local source_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source_override="$2"; shift 2 ;;
            --dest)   DEST="$2";            shift 2 ;;
            --no-trim) TRIM=0;              shift ;;
            -h|--help) usage ;;
            *) err "Unknown option: $1"; usage ;;
        esac
    done

    local raw_dir="${DEST}/raw"
    local proc_dir="${DEST}/processed"
    mkdir -p "$raw_dir" "$proc_dir"

    # ── 1. Copy ──────────────────────────────────────────────────────────────
    step "Step 1: Copy from SD card"
    local source="${source_override:-$SOURCE}"

    if [[ ! -d "$source" ]]; then
        err "Source not found: $source"
        err "Is the SD card plugged in?"
        exit 1
    fi

    info "Source:            $source"
    info "Destination (raw): $raw_dir"
    log ""
    copy_from_sd "$source" "$raw_dir"

    # ── 2. Merge stereo pairs ────────────────────────────────────────────────
    step "Step 2: Merge TR odd/even pairs → stereo"
    info "Pairing TR01+TR02, TR03+TR04, ... in $raw_dir"
    log ""
    merge_stereo_pairs "$raw_dir" "$proc_dir"

    # ── 3. Trim trailing silence ─────────────────────────────────────────────
    if [[ "$TRIM" == 1 ]]; then
        step "Step 3: Trim trailing silence"
        info "Silence: below ${SILENCE_THRESHOLD} for ${SILENCE_MIN}s+, keeping ${TRIM_KEEP}s after the last sound"
        log ""
        # Trim is optional polish: a clip that can't be scanned shouldn't stop the
        # rest of the files from being normalized.
        trim_trailing_silence "$proc_dir" || warn "Trim step had errors (see above); continuing to normalize"
    else
        step "Step 3: Trim trailing silence (skipped: --no-trim)"
    fi

    # ── 4. Normalize ─────────────────────────────────────────────────────────
    step "Step 4: Normalize to ${PEAK_TARGET} dBFS peak"
    info "Processing files in $proc_dir"
    log ""
    normalize_files "$proc_dir"

    log ""
    ok "All done! Processed files are in: $proc_dir"
}

main "$@"
