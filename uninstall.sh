#!/usr/bin/env bash
#
# uninstall.sh — remove the files install.sh placed on the system.
#
# It does NOT remove the dependency packages (partclone, gtk4, …) — those may be
# wanted by other software, so removing them is left to you.
#
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

rm -rf /usr/share/recovery-tool
rm -f  /usr/bin/recovery-tool
rm -f  /usr/share/applications/recovery-tool.desktop
rm -f  /usr/share/polkit-1/actions/io.github.rcraig57.DiskRecoveryTool.policy
rm -f  /usr/share/icons/hicolor/scalable/apps/io.github.rcraig57.DiskRecoveryTool.svg

gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
update-desktop-database -q 2>/dev/null || true

echo "Disk Recovery Tool removed. (Dependency packages were left installed.)"
