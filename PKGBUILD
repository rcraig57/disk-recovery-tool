# Maintainer: rcraig <rcraig.netmail@gmail.com>
#
# Disk Recovery Tool — GTK4 front end + partclone backup/restore backend.
#
# This is a VCS (-git) package: it builds the latest commit of the project repo.
# Before publishing/building, set _repo below to YOUR git remote. The repo is
# expected to contain two top-level directories:
#     recovery-gui/   (the GTK4 app: recovery-tool launcher, src/, data/)
#     part_clone/     (the backend: partclone-backup.sh, partclone-restore.sh)
#
# Build & install locally:   makepkg -si
# Generate AUR metadata:     makepkg --printsrcinfo > .SRCINFO

# ----- set this to your repository's clone URL ------------------------------ #
_repo="https://github.com/rcraig57/disk-recovery-tool.git"
# ---------------------------------------------------------------------------- #

_pkgname=disk-recovery-tool
pkgname=disk-recovery-tool-git
pkgver=0.2.1
pkgrel=1
pkgdesc="GTK4 whole-disk backup/restore + USB ISO-writer and formatter (partclone + zstd), styled like Arch Linux Tweak Tool"
arch=('x86_64')
url="${_repo%.git}"
license=('GPL-3.0-or-later')
depends=(
  'python'
  'python-gobject'
  'gtk4'
  'partclone'
  'zstd'
  'util-linux'      # lsblk, blkid, findmnt, sfdisk, blockdev, wipefs, mkswap, mount
  'gptfdisk'        # sgdisk
  'parted'          # partprobe, partition table + partition creation (USB format)
  'btrfs-progs'     # btrfs (resize + superblock size estimate)
  'e2fsprogs'       # dumpe2fs, e2fsck, resize2fs, mkfs.ext4 (USB format)
  'dosfstools'      # mkfs.fat — FAT32 (USB format)
  'exfatprogs'      # mkfs.exfat — exFAT (USB format)
  'ntfs-3g'         # mkfs.ntfs — NTFS (USB format)
  'coreutils'       # dd, stdbuf (USB write progress streaming)
  'polkit'          # pkexec
)
optdepends=(
  'xorg-xhost: run the GUI as root under an X11/XWayland session'
  'limine: bootloader re-registration when restoring a Limine system to a new machine'
  'grub: bootloader re-registration when restoring a GRUB system to a new machine'
)
makedepends=('git')
provides=("$_pkgname")
conflicts=("$_pkgname")
install="$_pkgname.install"
source=("$_pkgname::git+$_repo")
sha256sums=('SKIP')

pkgver() {
  cd "$srcdir/$_pkgname"
  printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
}

package() {
  cd "$srcdir/$_pkgname"

  local share="$pkgdir/usr/share/recovery-tool"

  # --- GUI: python sources + stylesheet ---
  install -dm755 "$share/src"
  install -m644 recovery-gui/src/*.py recovery-gui/src/style.css "$share/src/"

  # --- data: icon used in-app by the About page (config.icon_file()) ---
  install -Dm644 recovery-gui/data/icons/hicolor/scalable/apps/io.github.rcraig57.DiskRecoveryTool.svg \
    "$share/data/icons/hicolor/scalable/apps/io.github.rcraig57.DiskRecoveryTool.svg"

  # --- backend scripts (authoritative backup/restore + USB writer logic) ---
  install -dm755 "$share/scripts"
  install -m755 part_clone/partclone-backup.sh part_clone/partclone-restore.sh \
    part_clone/usb-write.sh part_clone/usb-format.sh "$share/scripts/"
  # optional self-test / diagnostic helpers (ignore if absent)
  install -m755 part_clone/test-grow-loopback.sh part_clone/test-bootloader-detect.sh \
    "$share/scripts/" 2>/dev/null || true

  # --- launcher (run as user; elevates the whole app via pkexec) ---
  install -Dm755 recovery-gui/recovery-tool "$pkgdir/usr/bin/recovery-tool"

  # --- desktop entry ---
  install -Dm644 recovery-gui/data/recovery-tool.desktop \
    "$pkgdir/usr/share/applications/recovery-tool.desktop"

  # --- polkit policy (custom auth message for the installed binary) ---
  install -Dm644 recovery-gui/data/io.github.rcraig57.DiskRecoveryTool.policy \
    "$pkgdir/usr/share/polkit-1/actions/io.github.rcraig57.DiskRecoveryTool.policy"

  # --- system icon (titlebar + application menu) ---
  install -Dm644 recovery-gui/data/icons/hicolor/scalable/apps/io.github.rcraig57.DiskRecoveryTool.svg \
    "$pkgdir/usr/share/icons/hicolor/scalable/apps/io.github.rcraig57.DiskRecoveryTool.svg"

  # --- docs ---
  install -Dm644 recovery-gui/README.md "$pkgdir/usr/share/doc/$_pkgname/README.md"
}
