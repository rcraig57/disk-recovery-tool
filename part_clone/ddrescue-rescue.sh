#!/usr/bin/env bash
#
# ddrescue-rescue.sh — salvage a FAILING disk to an image + mapfile with GNU
# ddrescue. This is the error-tolerant counterpart to partclone-backup.sh.
#
# partclone needs a clean, readable filesystem — exactly what a dying drive does
# not have. ddrescue instead does a fs-agnostic block copy that tolerates read
# errors, keeps a mapfile of what was/wasn't recovered, and can be resumed and
# retried. Because it works at the raw block level it cannot skip unused blocks
# or compress inline, so:
#
#   * the rescue image is RAW and FULL DISK SIZE (a 1 TB disk -> ~1 TB image,
#     though it is written sparse, so free space on the destination is what
#     actually gets consumed for unwritten regions);
#   * the destination MUST be a different, healthy disk with room for it.
#
# It is read-only on the SOURCE and never writes to it. Recovering files from
# the resulting image: `losetup -fP rescue.img` then mount the partitions
# read-only, or `dd` the image onto a replacement disk.
#
# Usage:
#   ./ddrescue-rescue.sh [--yes] [--force] [--retries N] SRC_DISK DEST_DIR
#
#   --yes        no interactive confirmation (the GUI passes this)
#   --force      proceed even if the destination has less free space than the
#                source's full size (the image is sparse, so this is often fine)
#   --retries N  ddrescue retry passes over bad areas (default 3)
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

confirm() {
  local prompt="$1" reply
  read -r -p "$prompt [y/N] " reply || true
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# --------------------------------------------------------------------------- #
# 1. Parse arguments.
# --------------------------------------------------------------------------- #
ASSUME_YES=0
FORCE=0
RETRIES=3
SRC=""
DEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)     ASSUME_YES=1; shift ;;
    --force)   FORCE=1; shift ;;
    --retries) RETRIES="${2:?--retries needs a number}"; shift 2 ;;
    --)        shift; break ;;
    -*)        die "Unknown option: $1" ;;
    *)         if [[ -z "$SRC" ]]; then SRC="$1"; elif [[ -z "$DEST" ]]; then DEST="$1"; else die "Too many arguments"; fi; shift ;;
  esac
done
[[ -n "${SRC:-}" && -n "${DEST:-}" ]] || die "Usage: $0 [--yes] [--force] [--retries N] SRC_DISK DEST_DIR"
[[ "$RETRIES" =~ ^[0-9]+$ ]] || die "--retries must be a number, got: $RETRIES"

# --------------------------------------------------------------------------- #
# 2. Must be root (raw block-device reads).
# --------------------------------------------------------------------------- #
[[ "$(id -u)" -eq 0 ]] || die "Run as root (e.g. sudo $0)."

# --------------------------------------------------------------------------- #
# 3. Tool preflight.
# --------------------------------------------------------------------------- #
for t in ddrescue ddrescuelog blockdev lsblk findmnt numfmt; do
  command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
done

# --------------------------------------------------------------------------- #
# 4. Validate the SOURCE: a whole block disk, not mounted.
# --------------------------------------------------------------------------- #
[[ -b "$SRC" ]] || die "Source is not a block device: $SRC"
SRC_NAME="$(lsblk -ndo NAME "$SRC" 2>/dev/null || true)"
SRC_TYPE="$(lsblk -ndo TYPE "$SRC" 2>/dev/null || true)"
[[ "$SRC_TYPE" == "disk" ]] || die "Source is not a whole disk (type=$SRC_TYPE): $SRC"

disk_has_mount() {
  local line
  while read -r line; do [[ -n "$line" ]] && return 0; done \
    < <(lsblk -nro MOUNTPOINTS "$SRC" | grep -v '^$' || true)
  return 1
}
disk_has_mount && die "Source $SRC has a mounted partition. Unmount it (or boot elsewhere) first."

SRC_SIZE="$(blockdev --getsize64 "$SRC")"
SRC_MODEL="$(lsblk -ndo MODEL "$SRC" 2>/dev/null | sed 's/[[:space:]]*$//')"
SRC_SERIAL="$(lsblk -ndo SERIAL "$SRC" 2>/dev/null | sed 's/[[:space:]]*$//')"

# --------------------------------------------------------------------------- #
# 5. Validate the DESTINATION: a writable directory, NOT on the source disk.
# --------------------------------------------------------------------------- #
[[ -d "$DEST" ]] || die "Destination is not a directory: $DEST"
[[ -w "$DEST" ]] || die "Destination is not writable: $DEST"

# Refuse to write the rescue image onto the very disk we are rescuing.
DEST_SRC_DEV="$(findmnt -nro SOURCE --target "$DEST" 2>/dev/null || true)"
DEST_DISK="$(lsblk -ndo PKNAME "$DEST_SRC_DEV" 2>/dev/null || true)"
[[ -z "$DEST_DISK" ]] && DEST_DISK="$(lsblk -ndo NAME "$DEST_SRC_DEV" 2>/dev/null || true)"
if [[ -n "$DEST_DISK" && "$DEST_DISK" == "$SRC_NAME" ]]; then
  die "Destination is on the source disk ($SRC). Choose a different, healthy disk."
fi

# Free-space check (the image is sparse, so this is advisory unless --force).
AVAIL="$(findmnt -nbo AVAIL --target "$DEST" 2>/dev/null || echo 0)"
if [[ "$FORCE" -ne 1 && "$AVAIL" -gt 0 && "$AVAIL" -lt "$SRC_SIZE" ]]; then
  die "Destination has $(numfmt --to=iec "$AVAIL") free but the source is $(numfmt --to=iec "$SRC_SIZE"). The image is sparse and may fit, but to proceed anyway pass --force."
fi

# --------------------------------------------------------------------------- #
# 6. Name the output set and confirm.
# --------------------------------------------------------------------------- #
TS="$(date +%Y%m%d-%H%M%S)"
BASE="rescue-${SRC_NAME}-${TS}"
IMG="$DEST/$BASE.img"
MAP="$DEST/$BASE.map"
META="$DEST/$BASE.metadata.conf"

msg "Rescue plan"
msg "  Source : $SRC  ($(numfmt --to=iec "$SRC_SIZE"), ${SRC_MODEL:-unknown})"
msg "  Image  : $IMG"
msg "  Mapfile: $MAP"
msg "  Retries: $RETRIES"

if [[ "$ASSUME_YES" -ne 1 ]]; then
  confirm "Start rescue of $SRC?" || die "Aborted."
fi

# --------------------------------------------------------------------------- #
# 7. Self-describing metadata, so the rescue set stands on its own.
# --------------------------------------------------------------------------- #
{
  echo "# ddrescue-rescue metadata — generated $(date -Is)"
  echo "RESCUE_VERSION=1"
  echo "SOURCE_DEVICE=$SRC"
  echo "SOURCE_MODEL=${SRC_MODEL:-unknown}"
  echo "SOURCE_SERIAL=${SRC_SERIAL:-unknown}"
  echo "SOURCE_SIZE_BYTES=$SRC_SIZE"
  echo "IMAGE=$BASE.img"
  echo "MAPFILE=$BASE.map"
  echo "DDRESCUE_VERSION=$(ddrescue --version 2>&1 | grep -oiE '[0-9]+\.[0-9]+' | head -1 || echo unknown)"
} > "$META"

# --------------------------------------------------------------------------- #
# 8. Run ddrescue. Translate its in-place status display into the GUI runner's
#    protocol: convert the carriage-return updates to lines, rewrite the
#    "pct rescued:" line into a "Completed: NN%" progress line, and drop the
#    repeating status fields so the log shows the banner, progress and summary
#    rather than thousands of duplicate blocks.
# --------------------------------------------------------------------------- #
msg "Rescuing $SRC -> $IMG (mapfile $BASE.map)"

set +e
ddrescue --retry-passes="$RETRIES" "$SRC" "$IMG" "$MAP" 2>&1 \
  | stdbuf -oL tr '\r' '\n' \
  | stdbuf -oL sed -u -E '
      s/\x1b\[[0-9;?]*[A-Za-z]//g
      s/.*pct rescued:[[:space:]]*([0-9.]+)%.*/Completed: \1%/
      /^[[:space:]]*(ipos|opos|non-tried|non-trimmed|non-scraped|rescued|bad areas|read errors|current rate|average rate|run time|time since last successful read|remaining time|recovered|errsize|errors|slow reads|other errors):/Id
      /^[[:space:]]*$/d
    '
rc="${PIPESTATUS[0]}"
set -e

# --------------------------------------------------------------------------- #
# 9. Summarise what was and was not recovered, then give the verdict.
# --------------------------------------------------------------------------- #
echo
msg "Recovery summary (ddrescuelog -t):"
ddrescuelog -t "$MAP" || true

if [[ "$rc" -ne 0 ]]; then
  die "ddrescue exited with status $rc — see the log above."
fi

# A clean run can still leave unrecovered areas on a dying disk. Report it but
# do not call the run a failure: a partial image is the whole point of a rescue.
# `ddrescuelog -D` returns 0 only when the rescue is FINISHED (nothing left bad
# or non-tried); a non-zero result means the image is partial.
if ! ddrescuelog -D "$MAP" >/dev/null 2>&1; then
  warn "Some areas could NOT be read — the image is partial. Re-running against the same .img/.map retries only the bad areas."
fi

ok "Rescue finished. Image: $IMG  Mapfile: $MAP"
exit 0
