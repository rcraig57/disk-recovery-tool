"""USB Writer page — write an ISO to a USB device, or format a USB device.

One sidebar section with a segmented Write/Format toggle. Both actions are
whole-device, destructive operations, so the target picker defaults to
removable (USB) devices only and a confirmation dialog names the exact device
before anything runs. As with every other page, the heavy lifting lives in the
authoritative backend scripts (usb-write.sh / usb-format.sh); this page only
builds the command line and shows the streamed output through the shared
JobView.
"""

import gi

gi.require_version("Gtk", "4.0")

import os  # noqa: E402
import pwd  # noqa: E402

import config  # noqa: E402
import disks  # noqa: E402
from gi.repository import Gtk  # noqa: E402
from jobview import JobView  # noqa: E402
from widgets import DiskPicker, PathChooser, make_intro, make_title  # noqa: E402

INTRO = (
    "Write an installer/live <b>ISO</b> to a USB stick, or <b>format</b> a USB "
    "stick with a fresh filesystem. Writing uses <tt>dd</tt> with "
    "<tt>oflag=sync</tt>. Both actions <b>erase the whole target device</b>, so "
    "only removable (USB) devices are listed by default."
)

# (display label, fstype passed to the backend) — the full mintstick set.
FILESYSTEMS = [
    ("FAT32 — universal (Windows/Mac/Linux, UEFI)", "fat32"),
    ("exFAT — large files, cross-platform", "exfat"),
    ("NTFS — Windows", "ntfs"),
    ("ext4 — Linux native", "ext4"),
]


def _invoking_owner() -> str:
    """'uid:gid' of the human who launched the (now-root) app, for ext4 owner.

    The launcher elevates via pkexec, which sets PKEXEC_UID; sudo sets SUDO_UID.
    Returns "" if neither is set (e.g. previewing the UI un-elevated).
    """
    uid = os.environ.get("PKEXEC_UID") or os.environ.get("SUDO_UID")
    if not uid:
        return ""
    try:
        gid = pwd.getpwuid(int(uid)).pw_gid
    except (KeyError, ValueError):
        gid = uid
    return f"{uid}:{gid}"


class USBPage(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.set_margin_top(18)
        self.set_margin_bottom(18)
        self.set_margin_start(18)
        self.set_margin_end(18)

        self._mode_guard = False  # re-entrancy guard for the toggle pair

        self.append(make_title("USB Writer"))
        self.append(make_intro(INTRO))

        # -- segmented Write / Format toggle ------------------------------- #
        toggle = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        toggle.add_css_class("linked")
        toggle.set_halign(Gtk.Align.START)
        toggle.set_margin_bottom(4)
        self.mode_write = Gtk.ToggleButton(label="Write ISO")
        self.mode_format = Gtk.ToggleButton(label="Format")
        self.mode_write.set_active(True)
        self.mode_write.connect("toggled", self._on_mode_toggled, "write")
        self.mode_format.connect("toggled", self._on_mode_toggled, "format")
        toggle.append(self.mode_write)
        toggle.append(self.mode_format)
        self.append(toggle)

        # -- ISO chooser (Write mode only) --------------------------------- #
        self.iso = PathChooser(
            "ISO file:", mode="file",
            placeholder="the .iso image to write to the USB device",
        )
        self.append(self.iso)

        # -- target device (shared) ---------------------------------------- #
        # include_mounted so auto-mounted sticks still appear (the backend
        # unmounts them); removable_only so internal disks are hidden.
        self.target = DiskPicker(
            "USB device:", include_mounted=True, removable_only=True
        )
        self.append(self.target)

        self.show_all = Gtk.CheckButton(
            label="Show all disks (not just removable USB devices)"
        )
        self.show_all.set_margin_start(120)
        self.show_all.connect("toggled", self._on_show_all_toggled)
        self.append(self.show_all)

        # -- format options (Format mode only) ----------------------------- #
        self.format_opts = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        fs_label = Gtk.Label(xalign=0, label="Filesystem:")
        fs_label.set_size_request(110, -1)
        self.format_opts.append(fs_label)
        self.fs_model = Gtk.StringList()
        for display, _ in FILESYSTEMS:
            self.fs_model.append(display)
        self.fs_dropdown = Gtk.DropDown(model=self.fs_model)
        self.fs_dropdown.set_hexpand(True)
        self.format_opts.append(self.fs_dropdown)
        self.format_opts.append(Gtk.Label(xalign=0, label="Label:"))
        self.label_entry = Gtk.Entry()
        self.label_entry.set_placeholder_text("USB")
        self.label_entry.set_max_width_chars(16)
        self.format_opts.append(self.label_entry)
        self.append(self.format_opts)

        # -- action buttons ------------------------------------------------ #
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        buttons.set_halign(Gtk.Align.START)
        self.start_btn = Gtk.Button(label="Write to USB")
        self.start_btn.add_css_class("destructive-action")
        self.start_btn.connect("clicked", self._on_start)
        self.cancel_btn = Gtk.Button(label="Cancel")
        self.cancel_btn.set_sensitive(False)
        self.cancel_btn.connect("clicked", self._on_cancel)
        buttons.append(self.start_btn)
        buttons.append(self.cancel_btn)
        self.append(buttons)

        self.error_label = Gtk.Label(xalign=0)
        self.error_label.set_name("error_label")
        self.error_label.set_wrap(True)
        self.append(self.error_label)

        self.job = JobView()
        self.job.set_vexpand(True)
        self.append(self.job)

        self._update_mode_visibility()

    # -- mode handling ----------------------------------------------------- #
    def _on_mode_toggled(self, button, which):
        # Enforce exactly-one-active without recursing through set_active().
        if self._mode_guard:
            return
        self._mode_guard = True
        if button.get_active():
            other = self.mode_format if which == "write" else self.mode_write
            other.set_active(False)
        elif not self.mode_write.get_active() and not self.mode_format.get_active():
            # Don't allow both off — re-press the one just released.
            button.set_active(True)
        self._mode_guard = False
        self._update_mode_visibility()

    def _is_write_mode(self) -> bool:
        return self.mode_write.get_active()

    def _update_mode_visibility(self):
        write = self._is_write_mode()
        self.iso.set_visible(write)
        self.format_opts.set_visible(not write)
        self.start_btn.set_label("Write to USB" if write else "Format USB")

    def _on_show_all_toggled(self, button):
        self.target.set_removable_only(not button.get_active())

    # -- helpers ----------------------------------------------------------- #
    def _set_inputs_sensitive(self, sensitive: bool):
        for widget in (
            self.mode_write, self.mode_format, self.iso, self.target,
            self.show_all, self.format_opts, self.start_btn,
        ):
            widget.set_sensitive(sensitive)
        self.cancel_btn.set_sensitive(not sensitive)

    def _error(self, text: str):
        self.error_label.set_text(text)

    def _selected_fstype(self) -> str:
        idx = self.fs_dropdown.get_selected()
        if idx == Gtk.INVALID_LIST_POSITION or idx >= len(FILESYSTEMS):
            idx = 0
        return FILESYSTEMS[idx][1]

    # -- actions ----------------------------------------------------------- #
    def _on_start(self, _button):
        self._error("")
        disk = self.target.get_selected()
        if disk is None:
            self._error("Pick a USB device.")
            return

        if self._is_write_mode():
            iso = self.iso.get_path()
            if not iso:
                self._error("Choose an ISO file to write.")
                return
            if not os.path.isfile(iso):
                self._error(f"ISO file does not exist: {iso}")
                return
            title = f"Write this ISO to {disk['path']}?"
            detail = (
                f"{disk['path']} — {disk['model']} ({disks.human_size(disk['size'])})\n\n"
                f"{os.path.basename(iso)} will be written to the whole device. "
                "Everything currently on it will be destroyed. This cannot be undone."
            )
            confirm_label = "Write to USB"
            payload = ("write", disk, iso, None, None)
        else:
            fstype = self._selected_fstype()
            label = self.label_entry.get_text().strip() or "USB"
            title = f"Format {disk['path']} as {fstype}?"
            detail = (
                f"{disk['path']} — {disk['model']} ({disks.human_size(disk['size'])})\n\n"
                f"The whole device will be wiped and formatted as {fstype} "
                f"(label: {label}). Everything on it will be destroyed. "
                "This cannot be undone."
            )
            confirm_label = "Format USB"
            payload = ("format", disk, None, fstype, label)

        dialog = Gtk.AlertDialog()
        dialog.set_modal(True)
        dialog.set_message(title)
        dialog.set_detail(detail)
        dialog.set_buttons(["Cancel", confirm_label])
        dialog.set_default_button(0)
        dialog.set_cancel_button(0)
        dialog.choose(self.get_root(), None, self._on_confirm, payload)

    def _on_confirm(self, dialog, result, payload):
        try:
            choice = dialog.choose_finish(result)
        except Exception:
            return
        if choice != 1:  # not the destructive button
            return
        self._launch(payload)

    def _launch(self, payload):
        action, disk, iso, fstype, label = payload
        if action == "write":
            argv = [str(config.write_script()), "--yes", iso, disk["path"]]
        else:
            argv = [str(config.format_script()), "--yes", "--fs", fstype,
                    "--label", label]
            owner = _invoking_owner()
            if owner:
                argv += ["--owner", owner]
            argv.append(disk["path"])

        self._set_inputs_sensitive(False)
        self.job.run(argv, on_finished=lambda _rc: self._set_inputs_sensitive(True))

    def _on_cancel(self, _button):
        self.job.cancel()
