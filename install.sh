#!/usr/bin/env bash
#
# install.sh — universal installer for the Disk Recovery Tool.
#
# This is the cross-distro alternative to the Arch PKGBUILD: it detects the
# distribution family from /etc/os-release, installs the dependencies with the
# matching package manager, and copies the application into the same system
# layout the PKGBUILD produces (/usr/share/recovery-tool, /usr/bin/recovery-tool,
# the desktop entry, polkit policy and icon).
#
# Supported families:  arch (pacman) · debian (apt) · fedora (dnf)
#
# Usage:   sudo ./install.sh
#
# On Arch you can equally use the native package:  makepkg -si
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Output helpers.
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_BLUE=$'\e[34m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_RED=""; C_GREEN=""
fi
msg()  { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD"  "$C_RESET" "$*"; }
ok()   { printf '%s==>%s %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_RED$C_BOLD"   "$C_RESET" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# 0. Must be root (writes under /usr and installs packages).
# --------------------------------------------------------------------------- #
[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo $0"

# Locate the source tree (this script lives at the repo root).
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$SRC/recovery-gui" && -d "$SRC/part_clone" ]] \
  || die "Run this from the project root (recovery-gui/ and part_clone/ not found)."

# --------------------------------------------------------------------------- #
# 1. Detect the distribution family from /etc/os-release. We check ID first,
#    then ID_LIKE, so derivatives (Mint→debian, CachyOS→arch, etc.) map cleanly.
# --------------------------------------------------------------------------- #
[[ -r /etc/os-release ]] || die "/etc/os-release not found — cannot detect distro."
# shellcheck source=/dev/null
. /etc/os-release
haystack=" ${ID:-} ${ID_LIKE:-} "
FAMILY=""
case "$haystack" in
  *" arch "*|*" archlinux "*|*" cachyos "*) FAMILY=arch ;;
  *" debian "*|*" ubuntu "*)                FAMILY=debian ;;
  *" fedora "*|*" rhel "*|*" centos "*)     FAMILY=fedora ;;
esac
[[ -n "$FAMILY" ]] || die "Unsupported distro (ID='${ID:-?}' ID_LIKE='${ID_LIKE:-?}'). Supported: arch, debian, fedora."
msg "Detected distro family: $FAMILY  (${PRETTY_NAME:-$ID})"

# --------------------------------------------------------------------------- #
# 2. Per-family package manager + dependency package names.
#    The set of *needs* is identical across distros; only the names differ.
# --------------------------------------------------------------------------- #
case "$FAMILY" in
  arch)
    PM_INSTALL=(pacman -S --needed --noconfirm)
    PKGS=(partclone zstd gptfdisk parted btrfs-progs e2fsprogs util-linux
          dosfstools exfatprogs ntfs-3g coreutils
          polkit python python-gobject gtk4)
    ;;
  debian)
    export DEBIAN_FRONTEND=noninteractive
    PM_INSTALL=(apt-get install -y)
    apt-get update -qq || true
    PKGS=(partclone zstd gdisk parted btrfs-progs e2fsprogs util-linux
          dosfstools exfatprogs ntfs-3g coreutils
          policykit-1 python3 python3-gi gir1.2-gtk-4.0 libgtk-4-1)
    ;;
  fedora)
    PM_INSTALL=(dnf install -y)
    PKGS=(partclone zstd gdisk parted btrfs-progs e2fsprogs util-linux
          dosfstools exfatprogs ntfs-3g coreutils
          polkit python3 python3-gobject gtk4)
    ;;
esac

msg "Installing dependencies (${#PKGS[@]} packages)..."
"${PM_INSTALL[@]}" "${PKGS[@]}"

# --------------------------------------------------------------------------- #
# 3. Install the application files, mirroring the PKGBUILD's package() layout so
#    the launcher and config.py find everything at the paths they already expect.
# --------------------------------------------------------------------------- #
SHARE=/usr/share/recovery-tool
ICON_REL=icons/hicolor/scalable/apps/io.github.rcraig57.DiskRecoveryTool.svg

msg "Installing application files..."
install -dm755 "$SHARE/src"
install -m644  "$SRC"/recovery-gui/src/*.py "$SRC"/recovery-gui/src/style.css "$SHARE/src/"

install -Dm644 "$SRC/recovery-gui/data/$ICON_REL" "$SHARE/data/$ICON_REL"

install -dm755 "$SHARE/scripts"
install -m755  "$SRC/part_clone/partclone-backup.sh" "$SRC/part_clone/partclone-restore.sh" \
  "$SRC/part_clone/verify-backup.sh" \
  "$SRC/part_clone/usb-write.sh" "$SRC/part_clone/usb-format.sh" "$SHARE/scripts/"
# Optional self-test helpers (ignore if absent).
install -m755  "$SRC"/part_clone/test-grow-loopback.sh "$SRC"/part_clone/test-bootloader-detect.sh \
  "$SHARE/scripts/" 2>/dev/null || true

install -Dm755 "$SRC/recovery-gui/recovery-tool" /usr/bin/recovery-tool
install -Dm644 "$SRC/recovery-gui/data/recovery-tool.desktop" /usr/share/applications/recovery-tool.desktop
install -Dm644 "$SRC/recovery-gui/data/io.github.rcraig57.DiskRecoveryTool.policy" \
  /usr/share/polkit-1/actions/io.github.rcraig57.DiskRecoveryTool.policy
install -Dm644 "$SRC/recovery-gui/data/$ICON_REL" "/usr/share/$ICON_REL"

# --------------------------------------------------------------------------- #
# 4. Refresh icon + desktop caches (best-effort; matches the .install scripts).
# --------------------------------------------------------------------------- #
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
update-desktop-database -q 2>/dev/null || true

ok "Disk Recovery Tool installed."
echo
echo "  Launch:  recovery-tool   (or from your application menu)"
echo "  Do NOT run it as root — the launcher elevates via polkit."
echo "  Uninstall:  sudo $SRC/uninstall.sh"
