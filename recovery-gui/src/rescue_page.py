"""Rescue page — salvage a failing disk to an image + mapfile with GNU ddrescue.

The error-tolerant counterpart to Backup: where partclone needs a clean,
readable filesystem, ddrescue does a fs-agnostic block copy that tolerates read
errors and keeps a mapfile so the rescue can be resumed and retried.
"""

import gi

gi.require_version("Gtk", "4.0")

import os  # noqa: E402

import config  # noqa: E402
from gi.repository import Gtk  # noqa: E402
from jobview import JobView  # noqa: E402
from widgets import DiskPicker, PathChooser, make_intro, make_title  # noqa: E402

INTRO = (
    "Salvage a <b>failing</b> disk with <b>ddrescue</b>. Unlike Backup, this "
    "tolerates read errors and keeps a mapfile, so it can be resumed and can "
    "retry only the bad areas. The image is <b>raw and full-disk-size</b> "
    "(written sparse), so the destination must be a <b>different, healthy</b> "
    "disk with room for it. The source is only read, never written. Recover "
    "files afterwards by loop-mounting the image, or write it onto a replacement "
    "disk."
)


class RescuePage(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.set_margin_top(18)
        self.set_margin_bottom(18)
        self.set_margin_start(18)
        self.set_margin_end(18)

        self.append(make_title("Rescue"))
        self.append(make_intro(INTRO))

        self.source = DiskPicker("Failing disk:", include_mounted=False)
        self.append(self.source)

        self.dest = PathChooser(
            "Save to folder:", mode="folder",
            placeholder="a folder on a DIFFERENT, healthy disk",
        )
        self.append(self.dest)

        # Retry passes + force option on one row.
        opts = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        opts.append(Gtk.Label(xalign=0, label="Retry passes:"))
        self.retries = Gtk.SpinButton.new_with_range(0, 10, 1)
        self.retries.set_value(3)
        self.retries.set_tooltip_text("How many times ddrescue re-attempts bad areas. Default 3.")
        opts.append(self.retries)
        self.force = Gtk.CheckButton(label="Proceed even if free space looks smaller than the disk")
        self.force.set_margin_start(20)
        opts.append(self.force)
        self.append(opts)

        # Action buttons.
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        buttons.set_halign(Gtk.Align.START)
        self.start_btn = Gtk.Button(label="Start rescue")
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
        for widget in (self.source, self.dest, self.retries, self.force, self.start_btn):
            widget.set_sensitive(sensitive)
        self.cancel_btn.set_sensitive(not sensitive)

    def _error(self, text: str):
        self.error_label.set_text(text)

    # -- actions ------------------------------------------------------------ #
    def _on_start(self, _button):
        self._error("")
        disk = self.source.get_selected()
        dest = self.dest.get_path()
        if disk is None:
            self._error("Pick the failing disk to rescue.")
            return
        if not dest:
            self._error("Choose a destination folder on a different disk.")
            return
        if not os.path.isdir(dest):
            self._error(f"Destination folder does not exist: {dest}")
            return

        argv = [str(config.rescue_script()), "--yes",
                "--retries", str(int(self.retries.get_value()))]
        if self.force.get_active():
            argv.append("--force")
        argv += [disk["path"], dest]

        self._set_inputs_sensitive(False)
        self.job.run(argv, on_finished=lambda _rc: self._set_inputs_sensitive(True),
                     noun="Rescue")

    def _on_cancel(self, _button):
        self.job.cancel()
