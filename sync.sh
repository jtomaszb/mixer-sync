#!/usr/bin/env bash
# sync.sh — Sync mixer SD card audio: copy → merge L/R stereo → normalize
#
# Output layout:
#   $DEST/raw/        raw copies from SD card (L/R mono files, untouched)
#   $DEST/processed/  merged stereo + peak-normalized files

set -euo pipefail

DEST="${HOME}/Music/Mixer"
PEAK_TARGET="-1"   # dBFS
AUDIO_EXTENSIONS=("wav" "mp3" "aiff" "aif" "flac" "m4a" "ogg")

# ── helpers ──────────────────────────────────────────────────────────────────

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

find_sd_card() {
    local volumes=()
    while IFS= read -r vol; do
        [[ "$vol" =~ ^(Macintosh\ HD|Preboot|Recovery|VM|Update|Data)$ ]] && continue
        volumes+=("$vol")
    done < <(ls /Volumes/)

    if [[ ${#volumes[@]} -eq 0 ]]; then
        err "No external volumes found in /Volumes."
        exit 1
    fi

    if [[ ${#volumes[@]} -eq 1 ]]; then
        echo "/Volumes/${volumes[0]}"
        return
    fi

    log ""
    log "Multiple volumes found. Select the SD card:"
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
    echo "/Volumes/${volumes[$((choice - 1))]}"
}

# ── build find expression for audio files ────────────────────────────────────

build_name_filter() {
    local args=()
    local first=true
    for ext in "${AUDIO_EXTENSIONS[@]}"; do
        if $first; then
            args+=(-iname "*.${ext}")
            first=false
        else
            args+=(-o -iname "*.${ext}")
        fi
    done
    printf '%s\n' "${args[@]}"
}

# ── step 1: copy raw files from SD card ──────────────────────────────────────

copy_from_sd() {
    local source="$1"
    local raw_dir="$2"
    local copied=0 skipped=0 errors=0

    while IFS= read -r src_file; do
        local filename
        filename="$(basename "$src_file")"
        local dest_file="${raw_dir}/${filename}"

        if [[ -e "$dest_file" ]]; then
            warn "Skipping (exists): $filename"
            ((skipped++))
        else
            if cp "$src_file" "$dest_file"; then
                ok "Copied: $filename"
                ((copied++))
            else
                err "Failed: $filename"
                ((errors++))
            fi
        fi
    done < <(find "$source" \( $(build_name_filter) \) -type f | sort)

    log ""
    log "  Copied:  $copied  |  Skipped: $skipped  |  Errors: $errors"
    [[ $errors -gt 0 ]] && return 1 || return 0
}

# ── step 2: merge L/R mono pairs into stereo ─────────────────────────────────
#
# Detects pairs like: Track01L.wav / Track01R.wav
#                     Track01_L.wav / Track01_R.wav
#                     Track01-L.wav / Track01-R.wav  (case-insensitive)

merge_stereo_pairs() {
    local raw_dir="$1"
    local proc_dir="$2"
    local merged=0 unpaired=0

    # Find all left-channel files
    while IFS= read -r lfile; do
        local lname
        lname="$(basename "$lfile")"
        local ext="${lname##*.}"
        local base="${lname%.*}"   # e.g. "Track01L" or "Track01_L"

        # Determine separator and strip the trailing L to get the root name
        local root sep rfile rname
        if [[ "$base" =~ ^(.+)([-_])([Ll])$ ]]; then
            root="${BASH_REMATCH[1]}"
            sep="${BASH_REMATCH[2]}"
        elif [[ "$base" =~ ^(.+)([Ll])$ ]]; then
            root="${BASH_REMATCH[1]}"
            sep=""
        else
            continue
        fi

        # Look for the matching right-channel file
        rname_upper="${root}${sep}R.${ext}"
        rname_lower="${root}${sep}r.${ext}"
        if [[ -f "${raw_dir}/${rname_upper}" ]]; then
            rfile="${raw_dir}/${rname_upper}"
        elif [[ -f "${raw_dir}/${rname_lower}" ]]; then
            rfile="${raw_dir}/${rname_lower}"
        else
            warn "No R pair found for: $lname — will process as mono"
            ((unpaired++))
            continue
        fi

        local out_file="${proc_dir}/${root}.${ext}"
        if [[ -e "$out_file" ]]; then
            warn "Skipping (exists): $(basename "$out_file")"
            continue
        fi

        info "Merging: $lname + $(basename "$rfile") → $(basename "$out_file")"
        if ffmpeg -loglevel error \
                  -i "$lfile" -i "$rfile" \
                  -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo[out]" \
                  -map "[out]" \
                  "$out_file"; then
            ok "Merged: $(basename "$out_file")"
            ((merged++))
        else
            err "Merge failed: $(basename "$out_file")"
        fi
    done < <(find "$raw_dir" \( $(build_name_filter) \) -type f | grep -iE '[_-]?[Ll]\.[^.]+$' | sort)

    log ""
    log "  Merged pairs: $merged  |  Unpaired mono: $unpaired"
}

# ── step 3: peak-normalize processed files ───────────────────────────────────

normalize_files() {
    local proc_dir="$1"
    local normalized=0 skipped=0 errors=0

    while IFS= read -r file; do
        local filename
        filename="$(basename "$file")"
        local tmpfile="${file}.tmp.wav"

        # Detect current peak volume
        local max_vol
        max_vol=$(ffmpeg -loglevel error -i "$file" -af "volumedetect" -f null /dev/null 2>&1 \
                  | grep "max_volume" | awk '{print $5}')

        if [[ -z "$max_vol" ]]; then
            warn "Could not detect peak for: $filename"
            ((skipped++))
            continue
        fi

        # Calculate gain needed: target - current_max  (max_vol is negative, e.g. -3.2)
        local gain
        gain=$(awk -v t="$PEAK_TARGET" -v m="$max_vol" 'BEGIN { printf "%.2f", t - m }')

        if [[ "$gain" == "0.00" ]]; then
            ok "Already normalized: $filename"
            ((skipped++))
            continue
        fi

        info "Normalizing: $filename  (${max_vol} dB → ${PEAK_TARGET} dBFS, gain: +${gain} dB)"

        if ffmpeg -loglevel error -i "$file" -af "volume=${gain}dB" "$tmpfile" \
           && mv "$tmpfile" "$file"; then
            ok "Normalized: $filename"
            ((normalized++))
        else
            rm -f "$tmpfile"
            err "Normalization failed: $filename"
            ((errors++))
        fi
    done < <(find "$proc_dir" \( $(build_name_filter) \) -type f | sort)

    log ""
    log "  Normalized: $normalized  |  Skipped: $skipped  |  Errors: $errors"
    [[ $errors -gt 0 ]] && return 1 || return 0
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    require ffmpeg

    local raw_dir="${DEST}/raw"
    local proc_dir="${DEST}/processed"
    mkdir -p "$raw_dir" "$proc_dir"

    # ── 1. Copy ──────────────────────────────────────────────────────────────
    step "Step 1: Copy from SD card"
    info "Looking for SD card..."
    local source
    source="$(find_sd_card)"
    info "Source: $source"
    info "Destination (raw): $raw_dir"
    log ""
    copy_from_sd "$source" "$raw_dir"

    # ── 2. Merge stereo pairs ────────────────────────────────────────────────
    step "Step 2: Merge L/R mono pairs → stereo"
    info "Scanning $raw_dir for L/R pairs..."
    log ""
    merge_stereo_pairs "$raw_dir" "$proc_dir"

    # ── 3. Normalize ─────────────────────────────────────────────────────────
    step "Step 3: Normalize to ${PEAK_TARGET} dBFS peak"
    info "Processing files in $proc_dir..."
    log ""
    normalize_files "$proc_dir"

    log ""
    ok "All done! Processed files are in: $proc_dir"
}

main "$@"
