#!/usr/bin/env bash
#
# usb-write.sh — write an ISO (or any disk image) to a whole device with dd.
#
# Front end: the recovery-gui "USB Writer" page (Write mode). This is the
# authoritative backend; the GUI only builds the command line and shows output,
# exactly as it does for the partclone backup/restore scripts.
#
# dd has no percentage of its own, so we run it with `status=progress` and turn
# its running byte count into "Completed: NN%" lines — the same format the GUI's
# shared progress bar already parses from partclone. That way the existing
# JobView/ScriptRunner drive the bar here with no GUI-side changes.
#
# Usage:  usb-write.sh --yes <image> <device>
#   <image>   path to the .iso (or .img) file to write
#   <device>  whole-disk block device to write to, e.g. /dev/sdb  (ERASED)
#
set -euo pipefail

# Re-exec once under stdbuf so our stdout is line-buffered. Without this, bash's
# block-buffered pipe stdout would hold every "Completed: NN%" line back until
# the write finished, making the GUI bar jump 0→100 at the very end. The stdbuf
# environment is inherited by children (tr, the while loop), so they stream
# promptly too.
#
# IMPORTANT: only -oL (stdout). Do NOT add -eL: `dd status=progress` writes each
# update terminated by a carriage return, not a newline, so line-buffering its
# stderr would hold updates until a 4K buffer fills — making the bar lurch
# 0→48→72% in bursts instead of climbing. dd's stderr is unbuffered by default;
# leave it that way so its progress reaches us every ~1s.
if [[ "${USB_WRITE_LINEBUF:-}" != 1 ]]; then
  export USB_WRITE_LINEBUF=1
  exec stdbuf -oL "$0" "$@"
fi

DD_BS="${DD_BS:-4M}"

die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

# --- parse arguments ------------------------------------------------------- #
YES=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --)    shift; while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done ;;
    -*)    die "unknown option: $1" ;;
    *)     ARGS+=("$1"); shift ;;
  esac
done

[[ ${#ARGS[@]} -eq 2 ]] || die "usage: usb-write.sh --yes <image> <device>"
IMAGE="${ARGS[0]}"
DEVICE="${ARGS[1]}"

# --- safety checks --------------------------------------------------------- #
[[ $YES -eq 1 ]]            || die "refusing to run without --yes (this erases $DEVICE)"
[[ $EUID -eq 0 ]]          || die "must run as root"
[[ -f "$IMAGE" && -r "$IMAGE" ]] || die "image not found or unreadable: $IMAGE"
[[ -b "$DEVICE" ]]         || die "not a block device: $DEVICE"

# Never write to a device that holds the running system, even if it was somehow
# offered. (The GUI defaults to removable devices, but this is the hard guard.)
while read -r mp; do
  case "$mp" in
    /|/boot|/boot/efi|/boot/*) die "refusing: $DEVICE has a partition mounted at $mp" ;;
  esac
done < <(lsblk -nro MOUNTPOINTS "$DEVICE" | sed '/^$/d')

img_size=$(stat -c %s "$IMAGE")
dev_size=$(blockdev --getsize64 "$DEVICE")
[[ "$img_size" -gt 0 ]] || die "image is empty: $IMAGE"
[[ "$dev_size" -ge "$img_size" ]] \
  || die "image ($img_size bytes) is larger than device $DEVICE ($dev_size bytes)"

# --- unmount any auto-mounted partitions on the target --------------------- #
step "Unmounting any mounted partitions on $DEVICE"
while read -r part mp; do
  [[ -n "$mp" ]] || continue
  umount "/dev/$part" 2>/dev/null || umount "$mp" 2>/dev/null || true
done < <(lsblk -nro NAME,MOUNTPOINTS "$DEVICE" | awk 'NF==2')

# --- write ----------------------------------------------------------------- #
step "Writing $(basename "$IMAGE") to $DEVICE  (bs=$DD_BS, oflag=sync)"
echo "Completed: 0%"

set -o pipefail
dd if="$IMAGE" of="$DEVICE" bs="$DD_BS" oflag=sync status=progress 2>&1 \
  | tr '\r' '\n' \
  | while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+bytes ]]; then
        copied="${BASH_REMATCH[1]}"
        pct=$(( copied * 100 / img_size ))
        if (( pct > 100 )); then pct=100; fi
        echo "Completed: ${pct}%"
      elif [[ -n "$line" ]]; then
        printf '%s\n' "$line"
      fi
    done
rc=${PIPESTATUS[0]}
[[ "$rc" -eq 0 ]] || die "dd failed (exit $rc)"

# --- settle ---------------------------------------------------------------- #
step "Flushing buffers and re-reading the partition table"
sync
partprobe "$DEVICE" 2>/dev/null || blockdev --rereadpt "$DEVICE" 2>/dev/null || true
echo "Completed: 100%"
step "Done — $(basename "$IMAGE") written to $DEVICE"
