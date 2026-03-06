#!/usr/bin/env bash
# sync.sh — Sync mixer SD card audio: copy → merge stereo pairs → normalize
#
# Naming convention: {prefix}_TR{NN}.wav
#   Odd track numbers  = left channel  (TR01, TR03, TR05, ...)
#   Even track numbers = right channel (TR02, TR04, TR06, ...)
#   Adjacent pairs are merged: TR01+TR02 → TR01-02.wav, TR03+TR04 → TR03-04.wav
#
# Output layout:
#   $DEST/raw/{session}/        raw copies from SD (untouched)
#   $DEST/processed/{session}/  merged stereo + peak-normalized files

set -euo pipefail

DEST="${HOME}/Music/Mixer"
PEAK_TARGET="-1"   # dBFS

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { printf '%s\n' "$*"; }
info() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

require() {
    if ! command -v "$1" &>/dev/null; then
        err "Required tool not found: $1"
        err "Install with: brew install $1"
        exit 1
    fi
}

# ── find SD card ──────────────────────────────────────────────────────────────

# Known Tascam volume name — checked first to avoid scanning /Volumes
# (ls /Volumes/ can hang on unresponsive network mounts)
TASCAM_VOLUME="Tascam"

find_sd_card() {
    # Fast path: known Tascam volume name
    if [[ -d "/Volumes/${TASCAM_VOLUME}" ]]; then
        info "Found /Volumes/${TASCAM_VOLUME}"
        echo "/Volumes/${TASCAM_VOLUME}"
        return
    fi

    # Fallback: use diskutil to list only external physical volumes
    # (avoids hanging on unresponsive network mounts)
    local volumes=()
    while IFS= read -r mountpoint; do
        [[ -n "$mountpoint" ]] && volumes+=("$mountpoint")
    done < <(diskutil list -plist external physical 2>/dev/null \
             | xmllint --xpath '//array[preceding-sibling::key[1]="AllDisksAndPartitions"]/dict/string[preceding-sibling::key[1]="MountPoint"]' - 2>/dev/null \
             | grep -oE '[^<>]+' | grep '^/Volumes/' || true)

    if [[ ${#volumes[@]} -eq 0 ]]; then
        err "No external volumes found. Is the SD card plugged in?"
        err "If the volume name changed from '${TASCAM_VOLUME}', update TASCAM_VOLUME in sync.sh."
        exit 1
    fi

    if [[ ${#volumes[@]} -eq 1 ]]; then
        echo "${volumes[0]}"
        return
    fi

    log ""
    log "Multiple external volumes found. Select the SD card:"
    local i=1
    for vol in "${volumes[@]}"; do
        log "  $i) $vol"
        ((i++))
    done
    log ""
    printf "Enter number [1-%d]: " "${#volumes[@]}"
    read -r choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#volumes[@]} )); then
        err "Invalid selection."
        exit 1
    fi
    echo "${volumes[$((choice - 1))]}"
}

# ── step 1: copy raw files, preserving folder structure ───────────────────────

copy_from_sd() {
    local source="$1"
    local raw_dir="$2"

    # rsync: archive mode, skip files that already exist at destination
    # -a: preserve timestamps/permissions, -v: verbose, --ignore-existing: skip existing
    rsync -av --ignore-existing --min-size=100k \
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
            warn "No right-channel pair for: $filename (expected $(basename "$rfile"))"
            continue
        fi

        # Output: same session folder under processed/, with merged name
        local out_session_dir="${proc_dir}/${session_dir}"
        mkdir -p "$out_session_dir"
        local out_name="${prefix}${num_str}-${right_num_str}${ext}"
        local out_file="${out_session_dir}/${out_name}"

        if [[ -e "$out_file" ]]; then
            warn "Skipping (exists): ${session_dir}/${out_name}"
            ((skipped++))
            continue
        fi

        info "Merging: $filename + $(basename "$rfile") → $out_name"
        if ffmpeg -loglevel error \
                  -i "$lfile" -i "$rfile" \
                  -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo[out]" \
                  -map "[out]" \
                  "$out_file"; then
            ok "Merged: ${session_dir}/${out_name}"
            ((merged++))
        else
            err "Merge failed: $out_name"
            rm -f "$out_file"
            ((errors++))
        fi

    done < <(find "$raw_dir" -iname "*_tr[0-9]*.wav" -type f | sort)

    log ""
    log "  Merged: $merged  |  Skipped (exists): $skipped  |  Errors: $errors"
    [[ $errors -gt 0 ]] && return 1 || return 0
}

# ── step 3: peak-normalize all files in processed/ ───────────────────────────

normalize_files() {
    local proc_dir="$1"
    local normalized=0 skipped=0 errors=0

    while IFS= read -r file; do
        local rel="${file#${proc_dir}/}"
        local tmpfile="${file}.tmp.wav"

        # Detect current peak volume
        local max_vol
        max_vol=$(ffmpeg -loglevel error -i "$file" -af "volumedetect" -f null /dev/null 2>&1 \
                  | grep "max_volume" | awk '{print $5}')

        if [[ -z "$max_vol" ]]; then
            warn "Could not detect peak for: $rel"
            ((skipped++))
            continue
        fi

        # Gain needed: target - max_vol  (max_vol is negative, e.g. -3.2 dB)
        local gain
        gain=$(awk -v t="$PEAK_TARGET" -v m="$max_vol" 'BEGIN { printf "%.2f", t - m }')

        if [[ "$gain" == "0.00" ]]; then
            ok "Already at target: $rel"
            ((skipped++))
            continue
        fi

        info "Normalizing: $rel  (peak ${max_vol} dB → ${PEAK_TARGET} dBFS, gain ${gain} dB)"

        if ffmpeg -loglevel error -i "$file" -af "volume=${gain}dB" "$tmpfile" \
           && mv "$tmpfile" "$file"; then
            ok "Normalized: $rel"
            ((normalized++))
        else
            rm -f "$tmpfile"
            err "Failed: $rel"
            ((errors++))
        fi

    done < <(find "$proc_dir" -iname "*.wav" -type f | sort)

    log ""
    log "  Normalized: $normalized  |  Skipped: $skipped  |  Errors: $errors"
    [[ $errors -gt 0 ]] && return 1 || return 0
}

# ── main ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --source DIR   Use DIR instead of auto-detecting SD card from /Volumes
  --dest DIR     Override destination (default: $DEST)
  -h, --help     Show this help
EOF
    exit 0
}

main() {
    require ffmpeg
    require rsync

    local source_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source_override="$2"; shift 2 ;;
            --dest)   DEST="$2";            shift 2 ;;
            -h|--help) usage ;;
            *) err "Unknown option: $1"; usage ;;
        esac
    done

    local raw_dir="${DEST}/raw"
    local proc_dir="${DEST}/processed"
    mkdir -p "$raw_dir" "$proc_dir"

    # ── 1. Copy ──────────────────────────────────────────────────────────────
    step "Step 1: Copy from SD card"
    local source
    if [[ -n "$source_override" ]]; then
        source="$source_override"
        info "Source (override): $source"
    else
        info "Looking for SD card..."
        source="$(find_sd_card)"

        # Tascam recorders store multitrack sessions under MTR/
        if [[ -d "${source}/MTR" ]]; then
            source="${source}/MTR"
            info "Found Tascam MTR folder"
        fi
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

    # ── 3. Normalize ─────────────────────────────────────────────────────────
    step "Step 3: Normalize to ${PEAK_TARGET} dBFS peak"
    info "Processing files in $proc_dir"
    log ""
    normalize_files "$proc_dir"

    log ""
    ok "All done! Processed files are in: $proc_dir"
}

main "$@"
