#!/usr/bin/env bash
#
# usb-format.sh — wipe a device and lay down a single-partition filesystem.
#
# Front end: the recovery-gui "USB Writer" page (Format mode). Modeled on Linux
# Mint's mintstick raw_format: zero the start of the disk, write a fresh msdos
# table with one primary partition spanning the device, clear stale filesystem
# signatures, then mkfs. Emits coarse "Completed: NN%" lines so the GUI's shared
# progress bar advances through the (fast) stages.
#
# Usage:
#   usb-format.sh --yes --fs <fat32|exfat|ntfs|ext4> [--label L] [--owner UID:GID] <device>
#
set -euo pipefail

if [[ "${USB_FORMAT_LINEBUF:-}" != 1 ]]; then
  export USB_FORMAT_LINEBUF=1
  exec stdbuf -oL "$0" "$@"  # -oL only; see usb-write.sh for why not -eL
fi

die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }
pct()  { printf 'Completed: %s%%\n' "$1"; }

# --- parse arguments ------------------------------------------------------- #
YES=0; FS=""; LABEL=""; OWNER=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)   YES=1; shift ;;
    --fs)    FS="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    -*)      die "unknown option: $1" ;;
    *)       ARGS+=("$1"); shift ;;
  esac
done

[[ ${#ARGS[@]} -eq 1 ]] || die "usage: usb-format.sh --yes --fs <type> [--label L] <device>"
DEVICE="${ARGS[0]}"

# --- safety checks --------------------------------------------------------- #
[[ $YES -eq 1 ]]   || die "refusing to run without --yes (this erases $DEVICE)"
[[ $EUID -eq 0 ]]  || die "must run as root"
[[ -b "$DEVICE" ]] || die "not a block device: $DEVICE"
case "$FS" in fat32|exfat|ntfs|ext4) ;; *) die "unsupported filesystem: '$FS'" ;; esac
[[ -n "$LABEL" ]] || LABEL="USB"

while read -r mp; do
  case "$mp" in
    /|/boot|/boot/efi|/boot/*) die "refusing: $DEVICE has a partition mounted at $mp" ;;
  esac
done < <(lsblk -nro MOUNTPOINTS "$DEVICE" | sed '/^$/d')

# --- unmount --------------------------------------------------------------- #
step "Unmounting any mounted partitions on $DEVICE"
pct 5
while read -r part mp; do
  [[ -n "$mp" ]] || continue
  umount "/dev/$part" 2>/dev/null || umount "$mp" 2>/dev/null || true
done < <(lsblk -nro NAME,MOUNTPOINTS "$DEVICE" | awk 'NF==2')

# --- wipe + partition ------------------------------------------------------ #
step "Erasing existing partition table"
pct 15
wipefs -a "$DEVICE" >/dev/null 2>&1 || true
dd if=/dev/zero of="$DEVICE" bs=1M count=4 oflag=sync status=none

step "Creating msdos table and one primary partition"
pct 35
case "$FS" in
  fat32)      ptype=fat32 ;;
  exfat|ntfs) ptype=ntfs ;;   # parted has no exfat id; ntfs sets the same type byte
  ext4)       ptype=ext4 ;;
esac
parted -s "$DEVICE" mklabel msdos
parted -s -a optimal "$DEVICE" mkpart primary "$ptype" 1MiB 100%
partprobe "$DEVICE" 2>/dev/null || true

# Resolve the first partition node (sdb1 vs nvme0n1p1 / mmcblk0p1) and wait for
# udev to create it.
if [[ "$DEVICE" =~ [0-9]$ ]]; then PART="${DEVICE}p1"; else PART="${DEVICE}1"; fi
for _ in 1 2 3 4 5; do
  [[ -b "$PART" ]] && break
  sleep 1
  partprobe "$DEVICE" 2>/dev/null || true
done
[[ -b "$PART" ]] || die "partition node did not appear: $PART"

step "Clearing old filesystem signatures on $PART"
pct 55
wipefs -a --force "$PART" >/dev/null 2>&1 || true

# --- mkfs ------------------------------------------------------------------ #
step "Creating $FS filesystem (label: $LABEL)"
pct 70
case "$FS" in
  fat32) mkfs.fat -F 32 -n "${LABEL:0:11}" "$PART" ;;   # FAT labels max 11 chars
  exfat) mkfs.exfat -n "$LABEL" "$PART" ;;
  ntfs)  mkfs.ntfs -f -L "$LABEL" "$PART" ;;
  ext4)
    if [[ -n "$OWNER" ]]; then
      mkfs.ext4 -F -E root_owner="$OWNER" -L "$LABEL" "$PART"
    else
      mkfs.ext4 -F -L "$LABEL" "$PART"
    fi
    ;;
esac

# --- settle ---------------------------------------------------------------- #
step "Flushing"
pct 95
sync
partprobe "$DEVICE" 2>/dev/null || true
pct 100
step "Done — $DEVICE formatted as $FS (label: $LABEL)"
