#!/usr/bin/env bash
# sync.sh — Copy new audio files from a mixer SD card to ~/Music/Mixer

set -euo pipefail

DEST="${HOME}/Music/Mixer"
AUDIO_EXTENSIONS=("wav" "mp3" "aiff" "aif" "flac" "m4a" "ogg")

# ── helpers ─────────────────────────────────────────────────────────────────

log()  { printf '%s\n' "$*"; }
info() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

# ── find SD card ─────────────────────────────────────────────────────────────

find_sd_card() {
    # List volumes that look like removable/SD media (exclude system volumes)
    local volumes=()
    while IFS= read -r vol; do
        # Skip macOS system volumes
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

    # Multiple volumes — let the user pick
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

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    info "Looking for SD card..."
    local source
    source="$(find_sd_card)"
    info "Source: $source"

    mkdir -p "$DEST"
    info "Destination: $DEST"
    log ""

    local copied=0 skipped=0 errors=0

    # Find audio files and stream them line-by-line (handles spaces in names)
    while IFS= read -r src_file; do
        local filename
        filename="$(basename "$src_file")"
        local dest_file="${DEST}/${filename}"

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
    log "─────────────────────────────"
    log "  Copied:  $copied"
    log "  Skipped: $skipped"
    [[ $errors -gt 0 ]] && log "  Errors:  $errors"
    log "─────────────────────────────"

    if [[ $errors -gt 0 ]]; then
        err "Completed with $errors error(s)."
        exit 1
    else
        ok "Done."
    fi
}

main "$@"
