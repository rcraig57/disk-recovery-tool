#!/usr/bin/env bash
#
# packages-export.sh — write a manifest of the packages YOU installed.
#
# After restoring an image or doing a fresh install, the disk is back but the
# extra software you'd added is not. This records the user-installed package set
# (not the base system) into a plain-text manifest that packages-import.sh can
# reinstall from.
#
# What it records:
#   * Native, repo-installed, explicitly-chosen packages — one name per line.
#     These are what Import reinstalls.
#   * AUR / foreign packages (pacman only) and Flatpak apps — written into a
#     LABELED, commented section for reference. They are NOT reinstalled
#     automatically: AUR needs a helper and Flatpak names aren't repo packages.
#
# Package names are not portable across managers, so the manifest header records
# which manager produced it; packages-import.sh refuses a mismatched system.
#
# Reading the package database needs no root, but the GUI runs the whole app
# elevated — so when launched that way the manifest is chown'd back to the user
# who started it ($PKEXEC_UID / $SUDO_UID) so it stays editable.
#
# Usage:  packages-export.sh <output-dir>
#
set -euo pipefail

OUT_DIR="${1:-}"
[ -n "$OUT_DIR" ] || { echo "Usage: $0 <output-dir>" >&2; exit 1; }
[ -d "$OUT_DIR" ] || { echo "Not a directory: $OUT_DIR" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Detect the package manager. The MANAGER is the portability key (Arch
# derivatives all share pacman, Debian/Mint share apt, Fedora/RHEL share dnf),
# so we match on it rather than the distro name.
# --------------------------------------------------------------------------- #
if   command -v pacman  >/dev/null 2>&1; then MGR=pacman
elif command -v apt-get >/dev/null 2>&1; then MGR=apt
elif command -v dnf     >/dev/null 2>&1; then MGR=dnf
else echo "Unsupported package manager (need pacman, apt-get or dnf)." >&2; exit 1; fi

DISTRO_ID="?"; DISTRO_PRETTY="?"
if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  DISTRO_ID="${ID:-?}"; DISTRO_PRETTY="${PRETTY_NAME:-${ID:-?}}"
fi

echo "==> Detecting user-installed packages ($MGR)..."

native_list="$(mktemp)"
foreign_list="$(mktemp)"
flatpak_list="$(mktemp)"
trap 'rm -f "$native_list" "$foreign_list" "$flatpak_list"' EXIT
: > "$foreign_list"; : > "$flatpak_list"

case "$MGR" in
  pacman)
    # -Qq quiet, -e explicitly installed (you asked for it, not a dependency),
    # -n native (from a repo). -m is the complement: foreign = AUR/manual.
    pacman -Qqen | sort -u > "$native_list"
    pacman -Qqem | sort -u > "$foreign_list" || true
    ;;
  apt)
    # Packages marked "manual" are the ones a user chose; the rest are deps.
    apt-mark showmanual | sort -u > "$native_list"
    ;;
  dnf)
    # "user-installed" = installed on purpose, not pulled in as a dependency.
    # dnf4 understands repoquery --userinstalled; dnf5 (Fedora 41+) keeps the
    # 'history userinstalled' form, so fall back to it.
    if dnf repoquery --userinstalled --qf '%{name}\n' >/dev/null 2>&1; then
      dnf repoquery --userinstalled --qf '%{name}\n' 2>/dev/null \
        | awk 'NF{print $1}' | sort -u > "$native_list"
    else
      dnf history userinstalled 2>/dev/null \
        | awk 'NF{print $1}' | sort -u > "$native_list"
    fi
    ;;
esac

# Flatpak apps — possible on any distro, never reinstallable via the system
# package manager, so always recorded in the reference-only section.
if command -v flatpak >/dev/null 2>&1; then
  flatpak list --app --columns=application 2>/dev/null \
    | awk 'NF{print $1}' | sort -u > "$flatpak_list" || true
fi

native_count="$(wc -l < "$native_list" | tr -d ' ')"

MANIFEST="$OUT_DIR/drt-packages-$MGR-$(uname -n)-$(date +%Y%m%d-%H%M%S).list"

{
  echo "# Disk Recovery Tool — package manifest"
  echo "# schema: 1"
  echo "# manager: $MGR"
  echo "# distro_id: $DISTRO_ID"
  echo "# distro_pretty: $DISTRO_PRETTY"
  echo "# created: $(date -Iseconds)"
  echo "# host: $(uname -n)"
  echo "# native_count: $native_count"
  echo "#"
  echo "# Lines below that do NOT start with '#' are reinstalled on Import."
  echo "# '#aur:' and '#flatpak:' lines are recorded for reference only and are"
  echo "# NOT reinstalled automatically (see the labeled sections at the end)."
  cat "$native_list"
} > "$MANIFEST"

if [ -s "$foreign_list" ]; then
  {
    echo "#"
    echo "# --- AUR / foreign packages — NOT auto-reinstalled ---"
    echo "# Reinstall these yourself with your AUR helper, e.g.  yay -S <name>"
    while IFS= read -r p; do [ -n "$p" ] && echo "#aur: $p"; done < "$foreign_list"
  } >> "$MANIFEST"
fi

if [ -s "$flatpak_list" ]; then
  {
    echo "#"
    echo "# --- Flatpak apps — NOT auto-reinstalled ---"
    echo "# Reinstall these yourself, e.g.  flatpak install <application-id>"
    while IFS= read -r p; do [ -n "$p" ] && echo "#flatpak: $p"; done < "$flatpak_list"
  } >> "$MANIFEST"
fi

# Hand the file back to the human who launched the elevated GUI, so it stays
# editable as them rather than root-owned.
target_uid="${PKEXEC_UID:-${SUDO_UID:-}}"
if [ -n "$target_uid" ] && [ "$target_uid" != "0" ]; then
  target_gid="$(id -g "$target_uid" 2>/dev/null || echo "")"
  if [ -n "$target_gid" ]; then
    chown "$target_uid:$target_gid" "$MANIFEST" 2>/dev/null || true
  fi
fi
chmod 0644 "$MANIFEST" 2>/dev/null || true

echo "==> Wrote manifest: $MANIFEST"
echo "Recorded $native_count reinstallable package(s)."
[ -s "$foreign_list" ] && echo "Also listed $(wc -l < "$foreign_list" | tr -d ' ') AUR/foreign package(s) for reference."
[ -s "$flatpak_list" ] && echo "Also listed $(wc -l < "$flatpak_list" | tr -d ' ') Flatpak app(s) for reference."
echo "==> Export complete."
