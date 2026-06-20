"""Verify page — re-check a stored backup folder without restoring it.

Read-only: re-hashes every compressed partition image against the SHA-256
recorded at backup time, so corruption is caught before you rely on the set.
"""

import gi

gi.require_version("Gtk", "4.0")

import os  # noqa: E402

import config  # noqa: E402
from gi.repository import Gtk  # noqa: E402
from jobview import JobView  # noqa: E402
from widgets import PathChooser, make_intro, make_title  # noqa: E402

INTRO = (
    "Re-verify a backup folder (made on the Backup page) <b>without restoring "
    "it</b>. Every compressed partition image is re-hashed and compared with the "
    "SHA-256 recorded at backup time, so bit-rot or a truncated copy is caught "
    "before you ever depend on the backup. Nothing is written — this is "
    "completely safe to run."
)


class VerifyPage(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.set_margin_top(18)
        self.set_margin_bottom(18)
        self.set_margin_start(18)
        self.set_margin_end(18)

        self.append(make_title("Verify"))
        self.append(make_intro(INTRO))

        self.backup = PathChooser(
            "Backup folder:", mode="folder",
            placeholder="the …-img-YYYYMMDD-HHMMSS folder to check",
        )
        self.append(self.backup)

        self.deep = Gtk.CheckButton(
            label="Deep check — also test that each image decompresses (slower)"
        )
        self.append(self.deep)

        # Action buttons.
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        buttons.set_halign(Gtk.Align.START)
        self.start_btn = Gtk.Button(label="Verify")
        self.start_btn.add_css_class("suggested-action")
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

    # -- helpers ------------------------------------------------------------ #
    def _set_inputs_sensitive(self, sensitive: bool):
        for widget in (self.backup, self.deep, self.start_btn):
            widget.set_sensitive(sensitive)
        self.cancel_btn.set_sensitive(not sensitive)

    def _error(self, text: str):
        self.error_label.set_text(text)

    # -- actions ------------------------------------------------------------ #
    def _on_start(self, _button):
        self._error("")
        backup_dir = self.backup.get_path()
        if not backup_dir or not os.path.isdir(backup_dir):
            self._error("Choose a valid backup folder.")
            return
        if not os.path.isfile(os.path.join(backup_dir, "backup-metadata.conf")):
            self._error("That folder is not a backup (no backup-metadata.conf).")
            return

        argv = [str(config.verify_script())]
        if self.deep.get_active():
            argv.append("--deep")
        argv.append(backup_dir)

        self._set_inputs_sensitive(False)
        self.job.run(argv, on_finished=lambda _rc: self._set_inputs_sensitive(True),
                     noun="Verify")

    def _on_cancel(self, _button):
        self.job.cancel()
