# Disk Recovery Tool (GUI)

A GTK4 front end for the whole-disk **backup** and **restore** scripts in
`../part_clone/`, plus **Rescue** (ddrescue salvage of a failing disk),
**Verify** (re-check a backup's checksums), a SMART health pre-flight in the
disk pickers, a **USB Writer** (write an ISO to a USB device, or format one),
and **Packages** (export/reinstall the packages you installed). Look and feel
modelled on Erik Dubois' Arch Linux Tweak Tool. The GUI is a
thin wrapper: every operation runs the same audited shell scripts you can run
from a terminal, so the CLI and GUI never drift.

## Run it

```
./recovery-tool
```

Do **not** run it as root yourself. The launcher elevates the whole app once via
`pkexec` (your desktop's polkit agent prompts for the admin password) — partclone,
losetup and mount all need root.

You can preview the UI as a normal user (`python3 src/recovery_tool.py`), but the
actual backup/restore operations will fail without root.

## Layout

```
recovery-tool                 launcher (pkexec, Wayland/X11)
src/
  recovery_tool.py            main: window, sidebar, stack, CSS, toast overlay
  backup_page.py              Backup page
  rescue_page.py              Rescue page (ddrescue failing-disk salvage)
  restore_page.py             Restore page (ERASE-guarded)
  packages_page.py            Packages page (export / reinstall package lists)
  verify_page.py              Verify page (re-check backup checksums)
  usb_page.py                 USB Writer page (write ISO / format, confirm dialog)
  about_page.py               About / Help
  jobview.py                  progress bar + collapsible log, owns the runner
  runner.py                   subprocess + progress parser (partclone/ddrescue)
  disks.py                    lsblk disk enumeration + SMART health (smartctl)
  widgets.py                  disk picker, path chooser, titles, toast notifications
  config.py                   app constants + backend-script discovery
  style.css                   ATT-style theme
data/
  io.github.rcraig57.DiskRecoveryTool.policy  polkit policy (for a packaged install)
  recovery-tool.desktop                       desktop entry
```

## How it talks to the backend

The GUI calls the scripts with their non-interactive flags so nothing blocks on
a prompt:

- **Backup:** `partclone-backup.sh --yes [--force] SRC DEST` (with `ZSTD_LEVEL`
  in the environment).
- **Rescue:** `ddrescue-rescue.sh --yes [--force] [--retries N] SRC DEST_DIR`.
- **Restore:** `partclone-restore.sh --erase --no-reboot (--grow|--no-grow)
  (--bootloader|--no-bootloader) BACKUP_DIR TARGET` (with `BOOTLOADER_DRYRUN=1`
  when the dry-run box is ticked).
- **Verify:** `verify-backup.sh [--deep] BACKUP_DIR`.
- **Packages export:** `packages-export.sh OUTPUT_DIR`.
- **Packages import:** `packages-import.sh MANIFEST_FILE` (refuses a manifest
  whose `# manager:` header differs from this system's package manager).
- **USB write:** `usb-write.sh --yes IMAGE DEVICE`.
- **USB format:** `usb-format.sh --yes --fs FSTYPE [--label L] [--owner UID:GID]
  DEVICE`.

The USB Writer page lists removable devices only by default and shows a
confirmation dialog naming the exact device; `usb-write.sh`/`usb-format.sh` then
unmount the target, refuse a device mounted at `/` or `/boot`, and (for writes)
translate `dd status=progress` into the same percentage the progress bar parses.

The backend keeps the real safety checks: it refuses mounted disks and the
backup's own disk, verifies every image checksum before writing, and the restore
script still ERASE-gates unless `--erase` is passed (the GUI passes it only after
its own typed-ERASE + confirmation-dialog guards).
