# Changelog

All notable changes to **Disk Recovery Tool** are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project aims to follow [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-06-15

First cross-distro release. The tool now installs and is verified on the three
major Linux families — **Arch, Debian, and Fedora** — and their derivatives.

### Added
- **Universal installer (`install.sh`).** Detects the distribution family from
  `/etc/os-release` and installs dependencies with the matching package manager
  (`pacman` / `apt` / `dnf`). Derivatives map automatically (Mint/Ubuntu →
  Debian, CachyOS → Arch, RHEL/CentOS → Fedora).
- **`CHANGELOG.md`** (this file).

### Changed
- **Application ID renamed** from `org.ohmychadwm.recovery` to
  `io.github.rcraig57.DiskRecoveryTool`, a distro-neutral, reverse-DNS
  identifier (freedesktop/Flathub convention). This touches the polkit policy,
  desktop entry, icon name, and config — no user action is needed on a fresh
  install.
- **README** rewritten for cross-distro use: the install instructions now lead
  with the universal `sudo ./install.sh` path, with `makepkg -si` kept as the
  Arch-native option. Dependency notes clarify that names are resolved per
  distro.
- **`NOTICE`** copyright holder updated to the author's full name.

### Verified
- Backup → restore → **boot** confirmed on real hardware across all three
  families, including a non-dry-run restore and a successful Fedora boot test.
- Restore correctly handles GRUB (Debian/Fedora) and detects btrfs subvolumes.

### Removed
- Stale `docs/baremetal-test-checklist.md`, which documented the retired
  archiso recovery-ISO workflow (scripts no longer part of this project).

[0.1.0]: https://github.com/rcraig57/disk-recovery-tool/releases/tag/v0.1.0
