# Changelog

All notable changes to **Disk Recovery Tool** are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project aims to follow [Semantic Versioning](https://semver.org/).

## [0.4.1] — 2026-06-20

### Fixed
- **Packages export on Debian/Ubuntu/Mint now records only what you actually
  added.** On Debian proper, `apt-mark showmanual` is a tidy "what the user chose"
  set, but the Ubuntu/Mint installer seeds the *entire* base system as manually
  installed — so the export was listing ~2000 packages, almost all of them base OS.
  The apt path now subtracts the installer's own baseline snapshot
  (`/var/log/installer/initial-status.gz`) from `apt-mark showmanual`, leaving just
  the packages installed *after* the initial install. When that snapshot is absent
  (pure Debian, or a re-imaged system) it falls back to plain `apt-mark showmanual`
  exactly as before. The manifest header now carries a `# method:` line recording
  which path produced the list. pacman and dnf exports are unchanged.

## [0.4.0] — 2026-06-20

### Added
- **Packages page.** Export a manifest of the packages **you** installed (not the
  base system), then reinstall them from that manifest after a restore or a fresh
  install. Works across all three families: native/explicit packages come from
  `pacman -Qqen` (Arch), `apt-mark showmanual` (Debian), and
  `dnf repoquery --userinstalled` / `dnf history userinstalled` (Fedora). AUR /
  foreign packages and Flatpak apps are written into a **labeled, reference-only**
  section (`#aur:` / `#flatpak:`) and are not reinstalled automatically. Import is
  fully non-interactive (`--noconfirm` / `-y`), pre-filters the list against what's
  actually available so one renamed package can't abort the whole transaction, and
  reports the skipped names. A **same-manager guardrail** refuses a manifest whose
  package manager differs from the running system's — enforced both in the GUI
  (Import disabled with a reason) and in the backend script (hard refusal), since
  package names are not portable across managers. The manifest is chown'd back to
  the launching user so it stays editable. Backends:
  `part_clone/packages-export.sh`, `part_clone/packages-import.sh`. New sidebar
  order: Backup · Rescue · Restore · Packages · Verify · USB Writer · About.

## [0.3.0] — 2026-06-20

### Added
- **Rescue page (failing-disk salvage).** When partclone can't read a dying
  drive, **GNU ddrescue** images it block-by-block, tolerating read errors and
  keeping a mapfile so the rescue is resumable and retries only the bad areas.
  Produces a raw (sparse), full-disk image + mapfile + self-describing metadata;
  reads the source only, refuses a destination on the source disk, and reports
  unrecovered areas at the end. Backend: `part_clone/ddrescue-rescue.sh`. Adds a
  `ddrescue` dependency (**`gddrescue`** on Debian/Ubuntu). New sidebar order:
  Backup · Rescue · Restore · Verify · USB Writer · About.
- **SMART health pre-flight.** Disk pickers now show a SMART health badge
  (`⚠`/`✗`) next to any drive that reports aging or failure, read with
  `smartctl`. Backing up a failing **source** raises a non-blocking advisory
  pointing at the Rescue page; restoring onto a failing **target** adds a
  prominent warning to the erase-confirmation dialog. Clean and unknown drives
  add no badge. Adds a `smartmontools` dependency.
- **Verify page.** Re-check a stored backup folder without restoring it: every
  compressed partition image is re-hashed and compared with the SHA-256 recorded
  at backup time, so bit-rot or a truncated copy is caught before you rely on the
  set. Strictly read-only. An optional **Deep check** also runs `zstd -t` to
  confirm each image decompresses cleanly. Backend: `part_clone/verify-backup.sh`
  (`verify-backup.sh [--deep] BACKUP_DIR`), scriptable for cron archive checks.

## [0.2.1] — 2026-06-20

### Added
- **In-app toast notifications.** When a Backup, Restore, or USB write/format
  job finishes, a transient message slides up at the bottom of the window —
  green on success, red on failure — and auto-dismisses after a few seconds.
  This mirrors the Arch Linux Tweak Tool's in-app notification, built from
  plain GTK (no libadwaita) so it behaves identically on the GTK 4 versions
  shipped by Arch, Debian, and Fedora.

## [0.2.0] — 2026-06-17

### Added
- **USB Writer page.** A new left-sidebar section (between Restore and About)
  with a segmented **Write ISO / Format** toggle.
  - *Write ISO* — pick an `.iso` and a target device; the backend writes it with
    `dd … oflag=sync` and streams a live percentage to the shared progress bar
    (derived from `dd status=progress` against the image size).
  - *Format* — wipe a device and create a single-partition **FAT32 / exFAT /
    NTFS / ext4** filesystem with an optional volume label, modeled on Linux
    Mint's `mintstick`.
  - Safety: the target picker lists **removable (USB) devices only** by default,
    with a *Show all disks* escape hatch, and every run requires a confirmation
    dialog naming the exact device. The backend hard-refuses any device holding
    a partition mounted at `/`, `/boot`, or `/boot/*`.
- **Backend scripts** `part_clone/usb-write.sh` and `part_clone/usb-format.sh`
  (authoritative, same pattern as the partclone scripts).

### Changed
- **Dependencies** gained `dosfstools`, `exfatprogs`, and `ntfs-3g` (the `mkfs`
  tools for the format filesystems); installer and PKGBUILD updated.
- `DiskPicker` learned a `removable_only` mode (toggleable at runtime); disk
  labels now show a `[mounted]` marker where relevant.

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
