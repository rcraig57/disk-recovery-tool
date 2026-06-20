"""Disk enumeration helpers — thin wrappers over lsblk.

Used to populate the source/target disk pickers. The authoritative safety
checks (refuse-if-mounted, refuse the backup's own disk, size check) still live
in the backend scripts; this module only decides what to OFFER in the UI.
"""

import json
import subprocess


def _run(cmd) -> str:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, check=False
        ).stdout
    except OSError:
        return ""


def human_size(num_bytes: int) -> str:
    """Format a byte count as IEC units (matches the scripts' numfmt --to=iec)."""
    value = float(num_bytes)
    for unit in ("B", "K", "M", "G", "T", "P"):
        if value < 1024 or unit == "P":
            if unit == "B":
                return f"{int(value)}{unit}"
            return f"{value:.1f}{unit}".replace(".0", "")
        value /= 1024
    return f"{num_bytes}B"


def disk_has_mount(name: str) -> bool:
    """True if any partition of /dev/<name> is currently mounted."""
    out = _run(["lsblk", "-nro", "MOUNTPOINTS", f"/dev/{name}"])
    return any(line.strip() for line in out.splitlines())


# -- SMART health ---------------------------------------------------------- #
# smartctl needs root; the GUI runs elevated (pkexec), so this works in-app and
# degrades to "unknown" in an unprivileged UI preview. JSON output (-j) is in
# smartmontools >= 7.0, which Arch, Debian and Fedora all ship. Results are
# cached for the process lifetime (SMART changes slowly, and the three disk
# pickers would otherwise each re-probe every disk).
_SMART_CACHE: dict = {}

# ATA attributes whose non-zero raw value means the drive is degrading.
_ATA_WARN_ATTRS = {
    "Reallocated_Sector_Ct": "reallocated sectors",
    "Current_Pending_Sector": "pending sectors",
    "Reported_Uncorrect": "uncorrectable errors",
    "Offline_Uncorrectable": "offline-uncorrectable",
}


def _smartctl_json(name: str):
    """Return parsed smartctl JSON for /dev/<name>, or None. Tries a plain query
    first, then '-d sat' for USB SATA bridges."""
    for extra in ([], ["-d", "sat"]):
        out = _run(["smartctl", "-j", "-H", "-A", *extra, f"/dev/{name}"])
        if not out:
            continue
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            continue
        # Only trust a reply that actually carries an overall SMART verdict;
        # many USB enclosures answer without one.
        if isinstance(data, dict) and "smart_status" in data:
            return data
    return None


def _smart_warnings(data: dict) -> list:
    """Collect human-readable degradation signs from a passing-but-aging drive."""
    warns = []
    for attr in data.get("ata_smart_attributes", {}).get("table", []):
        label = _ATA_WARN_ATTRS.get(attr.get("name", ""))
        if label and int(attr.get("raw", {}).get("value", 0) or 0) > 0:
            warns.append(f"{attr['raw']['value']} {label}")
    nvme = data.get("nvme_smart_health_information_log", {})
    if int(nvme.get("media_errors", 0) or 0) > 0:
        warns.append(f"{nvme['media_errors']} media errors")
    if int(nvme.get("critical_warning", 0) or 0) > 0:
        warns.append("NVMe critical warning")
    return warns


def smart_health(name: str) -> dict:
    """Best-effort SMART health for /dev/<name>.

    Returns {"status": "ok"|"warn"|"fail"|"unknown", "summary": str}.
    """
    if name in _SMART_CACHE:
        return _SMART_CACHE[name]

    data = _smartctl_json(name)
    if data is None:
        result = {"status": "unknown", "summary": ""}
    else:
        passed = data.get("smart_status", {}).get("passed")
        if passed is False:
            result = {"status": "fail", "summary": "SMART: FAILING"}
        elif passed is None:
            result = {"status": "unknown", "summary": ""}
        else:
            warns = _smart_warnings(data)
            result = ({"status": "warn", "summary": "SMART: " + ", ".join(warns)}
                      if warns else {"status": "ok", "summary": "SMART: OK"})
    _SMART_CACHE[name] = result
    return result


def list_disks(include_mounted: bool = False) -> list:
    """Return whole disks as dicts: name, path, size (bytes), model, mounted.

    Mounted disks are excluded by default (they're almost certainly the running
    system and the scripts will refuse them anyway).
    """
    out = _run(["lsblk", "-J", "-d", "-b", "-o", "NAME,SIZE,MODEL,TYPE,RM"])
    try:
        data = json.loads(out) if out else {}
    except json.JSONDecodeError:
        data = {}

    disks = []
    for dev in data.get("blockdevices", []):
        if dev.get("type") != "disk":
            continue
        name = dev["name"]
        mounted = disk_has_mount(name)
        if mounted and not include_mounted:
            continue
        disks.append(
            {
                "name": name,
                "path": f"/dev/{name}",
                "size": int(dev.get("size") or 0),
                "model": (dev.get("model") or "").strip() or "unknown",
                "mounted": mounted,
                "removable": bool(dev.get("rm")),
                "health": smart_health(name),
            }
        )
    return disks


def describe(disk: dict) -> str:
    """One-line label for a disk picker row."""
    label = f"{disk['path']}  —  {human_size(disk['size'])}  {disk['model']}"
    # The USB Writer page can list mounted (auto-mounted) sticks; flag them so the
    # user knows the backend will unmount before writing. Backup/Restore exclude
    # mounted disks, so this marker never shows there.
    if disk.get("mounted"):
        label += "  [mounted]"
    # Surface only SMART problems (failing/aging); a clean or unknown drive adds
    # no badge, keeping the row uncluttered and the signal high.
    health = disk.get("health", {})
    if health.get("status") == "fail":
        label += "  ✗ SMART: FAILING"
    elif health.get("status") == "warn":
        label += f"  ⚠ {health.get('summary', 'SMART warning')}"
    return label
