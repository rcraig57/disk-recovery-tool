#!/usr/bin/env bash
#
# verify-backup.sh — re-verify a partclone backup folder WITHOUT restoring it.
#
# A backup you cannot trust is not a backup. This re-reads every compressed
# partition image in a backup folder and confirms it still matches the SHA-256
# recorded at backup time, so bit-rot or a truncated copy is caught before you
# ever rely on the set in a restore.
#
# It is strictly READ-ONLY: it never writes to a disk and never modifies the
# backup folder. No root is required (it only reads files), but it runs fine
# under the elevated GUI too.
#
# What it checks:
#   1. Completeness — every non-swap image named in partitions.tsv exists on disk
#      and has a matching <image>.sha256 sidecar; stray images are flagged.
#   2. Integrity    — `sha256sum -c` re-hashes each image against its sidecar.
#   3. Deep (opt)   — `zstd -t` confirms the compressed stream decompresses
#      cleanly (catches structural truncation a hash alone would still "match"
#      against if the sidecar were also truncated).
#
# Usage:
#   ./verify-backup.sh [--deep] BACKUP_DIR
#
# Progress/step lines (==> and "Completed: NN%") are emitted for the GUI runner.
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Small output helpers (colored only when writing to a terminal).
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_BLUE=$'\e[34m'
  C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_YELLOW=""; C_RED=""; C_GREEN=""
fi
msg()  { printf '%s==>%s %s\n'  "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '%s==>%s %s\n'  "$C_GREEN$C_BOLD" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
err()  { printf '%s[x]%s %s\n'  "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

progress() { printf 'Completed: %s%%\n' "$1"; }

# --------------------------------------------------------------------------- #
# 1. Parse arguments.
# --------------------------------------------------------------------------- #
DEEP=0
DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep) DEEP=1; shift ;;
    --)     shift; break ;;
    -*)     die "Unknown option: $1" ;;
    *)      DIR="$1"; shift ;;
  esac
done
[[ -n "${DIR:-}" ]] || die "Usage: $0 [--deep] BACKUP_DIR"
[[ -d "$DIR" ]]     || die "Not a directory: $DIR"

# --------------------------------------------------------------------------- #
# 2. Tool preflight.
# --------------------------------------------------------------------------- #
for t in sha256sum awk; do
  command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
done
if [[ "$DEEP" -eq 1 ]]; then
  command -v zstd >/dev/null 2>&1 || die "Missing required tool for --deep: zstd"
fi

# --------------------------------------------------------------------------- #
# 3. Recognise the folder as a backup.
# --------------------------------------------------------------------------- #
MANIFEST="$DIR/partitions.tsv"
[[ -f "$DIR/backup-metadata.conf" ]] \
  || die "That folder is not a backup (no backup-metadata.conf)."
[[ -f "$MANIFEST" ]] \
  || die "Missing manifest: partitions.tsv"

cd "$DIR"  # the .sha256 sidecars reference bare image filenames

# --------------------------------------------------------------------------- #
# 4. Collect the images to check from the manifest (skip the header and swap
#    rows, which carry image "-"). Columns:
#      partn devname fstype engine image uuid size_bytes sha256 label
# --------------------------------------------------------------------------- #
mapfile -t IMAGES < <(awk -F'\t' 'NR>1 && $5!="-" && $4!="SWAP" {print $5}' "$MANIFEST")
TOTAL="${#IMAGES[@]}"
[[ "$TOTAL" -gt 0 ]] || die "Manifest lists no partition images to verify."

msg "Verifying backup: $DIR"
if [[ "$DEEP" -eq 1 ]]; then
  msg "Images to check: $TOTAL (deep: zstd decompress test enabled)"
else
  msg "Images to check: $TOTAL"
fi

# --------------------------------------------------------------------------- #
# 5. Completeness — flag manifest images that are missing, and on-disk images
#    that the manifest does not mention.
# --------------------------------------------------------------------------- #
FAIL=0
for img in "${IMAGES[@]}"; do
  [[ -f "$img"        ]] || { err "Missing image named in manifest: $img"; FAIL=1; }
  [[ -f "$img.sha256" ]] || { err "Missing checksum sidecar: $img.sha256"; FAIL=1; }
done
shopt -s nullglob
for found in *.img.zst; do
  listed=0
  for img in "${IMAGES[@]}"; do [[ "$found" == "$img" ]] && { listed=1; break; }; done
  [[ "$listed" -eq 1 ]] || warn "Stray image not in manifest (ignored): $found"
done
shopt -u nullglob
[[ "$FAIL" -eq 0 ]] || die "Completeness check failed — backup is incomplete."

# --------------------------------------------------------------------------- #
# 6. Integrity (+ optional deep decompress test), per image, with progress.
# --------------------------------------------------------------------------- #
i=0
for img in "${IMAGES[@]}"; do
  i=$((i + 1))
  msg "Verifying $img ($i/$TOTAL)"

  if sha256sum -c --status "$img.sha256"; then
    ok "  checksum OK: $img"
  else
    err "  CHECKSUM MISMATCH: $img"
    FAIL=1
  fi

  if [[ "$DEEP" -eq 1 ]]; then
    if zstd -t -q "$img"; then
      ok "  decompresses cleanly: $img"
    else
      err "  ZSTD STREAM CORRUPT: $img"
      FAIL=1
    fi
  fi

  progress "$(( i * 100 / TOTAL ))"
done

# --------------------------------------------------------------------------- #
# 7. Verdict.
# --------------------------------------------------------------------------- #
echo
if [[ "$FAIL" -eq 0 ]]; then
  ok "Verify PASSED — all $TOTAL images intact."
  exit 0
fi
die "Verify FAILED — one or more images did not match. Do not rely on this backup."
