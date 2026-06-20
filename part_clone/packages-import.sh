#!/usr/bin/env bash
#
# packages-import.sh — reinstall packages from a manifest made by
# packages-export.sh.
#
# The GUI runs every job with stdin closed (so a stray prompt can't hang it),
# therefore the install MUST be non-interactive: each manager is driven with its
# no-prompt flag (--noconfirm / -y).
#
# Two safety behaviours matter here:
#   1. Same-manager guardrail. Package names are not portable across managers, so
#      a manifest made on 'pacman' is refused on an 'apt' system, and vice versa.
#      The check is on the manager, not the distro name, so Arch derivatives (and
#      Debian/Fedora derivatives) interoperate.
#   2. No all-or-nothing abort. A single unknown/renamed package would otherwise
#      sink the whole transaction (pacman in particular). We pre-filter the list
#      against what's actually available and report the skipped names, then
#      install only the resolvable ones.
#
# Usage:  packages-import.sh <manifest-file>
#
set -euo pipefail

FILE="${1:-}"
[ -n "$FILE" ] || { echo "Usage: $0 <manifest-file>" >&2; exit 1; }
[ -r "$FILE" ] || { echo "Cannot read manifest: $FILE" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Detect this system's package manager (the portability key).
# --------------------------------------------------------------------------- #
if   command -v pacman  >/dev/null 2>&1; then MGR=pacman
elif command -v apt-get >/dev/null 2>&1; then MGR=apt
elif command -v dnf     >/dev/null 2>&1; then MGR=dnf
else echo "Unsupported package manager (need pacman, apt-get or dnf)." >&2; exit 1; fi

# --------------------------------------------------------------------------- #
# Same-manager guardrail — refuse a manifest from a different manager.
# --------------------------------------------------------------------------- #
# '|| true' so a missing header doesn't trip 'set -e' before our friendly check.
manifest_mgr="$(grep -m1 '^# manager:' "$FILE" | awk '{print $3}' || true)"
if [ -z "$manifest_mgr" ]; then
  echo "==> Refusing: '$FILE' has no '# manager:' header — not a Disk Recovery Tool manifest." >&2
  exit 2
fi
if [ "$manifest_mgr" != "$MGR" ]; then
  echo "==> Refusing: this manifest was made on '$manifest_mgr', but this system uses '$MGR'." >&2
  echo "==> Package names are not portable across managers — import it on a matching system." >&2
  exit 2
fi

[ "$(id -u)" -eq 0 ] || { echo "Import needs root — launch through the elevated GUI." >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Parse the installable names: every non-comment, non-blank line, first field.
# The metadata header and the '#aur:' / '#flatpak:' reference lines all start
# with '#', so they are skipped automatically.
# --------------------------------------------------------------------------- #
mapfile -t wanted < <(grep -vE '^[[:space:]]*#' "$FILE" | awk 'NF{print $1}' | sort -u)
[ "${#wanted[@]}" -gt 0 ] || { echo "No installable packages listed in the manifest." >&2; exit 1; }

echo "==> ${#wanted[@]} package(s) requested from the manifest."

available=()
skipped=()

case "$MGR" in
  pacman)
    echo "==> Refreshing package databases..."
    pacman -Sy --noconfirm >/dev/null
    echo "==> Checking availability..."
    for p in "${wanted[@]}"; do
      if pacman -Si "$p" >/dev/null 2>&1; then available+=("$p"); else skipped+=("$p"); fi
    done
    ;;
  apt)
    export DEBIAN_FRONTEND=noninteractive
    echo "==> Refreshing package lists..."
    apt-get update -qq || true
    echo "==> Checking availability..."
    for p in "${wanted[@]}"; do
      if apt-cache show "$p" >/dev/null 2>&1; then available+=("$p"); else skipped+=("$p"); fi
    done
    ;;
  dnf)
    echo "==> Refreshing metadata..."
    dnf -q makecache >/dev/null 2>&1 || true
    echo "==> Checking availability..."
    for p in "${wanted[@]}"; do
      # -C uses the cache we just built, so this is one local lookup per name.
      if dnf -C -q info "$p" >/dev/null 2>&1; then available+=("$p"); else skipped+=("$p"); fi
    done
    ;;
esac

if [ "${#skipped[@]}" -gt 0 ]; then
  echo "==> Skipping ${#skipped[@]} unavailable or renamed package(s):"
  printf '      %s\n' "${skipped[@]}"
fi

if [ "${#available[@]}" -eq 0 ]; then
  echo "Nothing left to install — none of the listed packages are available here." >&2
  exit 1
fi

echo "==> Installing ${#available[@]} package(s)..."
case "$MGR" in
  pacman) pacman -S --needed --noconfirm "${available[@]}" ;;
  apt)    apt-get install -y --no-install-recommends "${available[@]}" ;;
  dnf)    dnf install -y "${available[@]}" ;;
esac

echo "==> Import complete."
