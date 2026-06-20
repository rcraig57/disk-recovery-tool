"""Packages page — export the packages you installed, and reinstall them later.

After a restore or a fresh install the disk is back but your added software is
not. Export writes a manifest of user-installed packages; Import reinstalls from
one. Like every other page this is a thin front end: the real work lives in the
backend scripts (packages-export.sh / packages-import.sh).

Package names are not portable across package managers, so Import refuses a
manifest whose manager differs from this system's — the check is wired both here
(button disabled, reason shown) and in the backend script (hard refusal).
"""

import gi

gi.require_version("Gtk", "4.0")

import os  # noqa: E402
import shutil  # noqa: E402

import config  # noqa: E402
from gi.repository import Gtk  # noqa: E402
from jobview import JobView  # noqa: E402
from widgets import PathChooser, make_intro, make_title  # noqa: E402

INTRO = (
    "Save a list of the packages <b>you</b> installed (not the base system) to a "
    "manifest file, then reinstall them from that manifest after restoring an "
    "image or doing a fresh install. AUR/foreign and Flatpak apps are recorded "
    "in a labeled, reference-only section — they are <b>not</b> reinstalled "
    "automatically. Package names are not portable between distributions, so a "
    "manifest can only be imported on a system using the <b>same</b> package "
    "manager it was exported from."
)

_MGR_LABELS = {
    "pacman": "Arch family",
    "apt": "Debian/Ubuntu family",
    "dnf": "Fedora family",
}


def _detect_manager():
    """Return this system's package manager id ('pacman'/'apt'/'dnf'), or None.

    Matches the backend scripts: the manager is the portability key, so we look
    for the tool rather than parsing the distro name.
    """
    if shutil.which("pacman"):
        return "pacman"
    if shutil.which("apt-get"):
        return "apt"
    if shutil.which("dnf"):
        return "dnf"
    return None


def _manifest_manager(path):
    """Read the '# manager:' header from a manifest, or None if it isn't one."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("# manager:"):
                    return line.split(":", 1)[1].strip()
                # Header is contiguous at the top; once real content starts, stop.
                if line.strip() and not line.startswith("#"):
                    break
    except OSError:
        return None
    return None


def _framed(title, *children):
    frame = Gtk.Frame(label=title)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
    box.set_margin_top(10)
    box.set_margin_bottom(10)
    box.set_margin_start(10)
    box.set_margin_end(10)
    for child in children:
        box.append(child)
    frame.set_child(box)
    return frame


class PackagesPage(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.set_margin_top(18)
        self.set_margin_bottom(18)
        self.set_margin_start(18)
        self.set_margin_end(18)

        self.manager = _detect_manager()
        self._running = False

        self.append(make_title("Packages"))
        self.append(make_intro(INTRO))

        # Detected-manager badge — the anchor for the same-distro guardrail.
        badge = Gtk.Label(xalign=0)
        if self.manager:
            badge.set_markup(
                f"Detected package manager: <b>{self.manager}</b> "
                f"({_MGR_LABELS.get(self.manager, 'unknown family')})"
            )
        else:
            badge.set_name("error_label")
            badge.set_text("No supported package manager found (need pacman, apt or dnf).")
        self.append(badge)

        # -- Export section -------------------------------------------------- #
        self.export_chooser = PathChooser(
            "Save to:", mode="folder",
            placeholder="folder to write the package manifest into",
        )
        self.export_btn = Gtk.Button(label="Export")
        self.export_btn.add_css_class("suggested-action")
        self.export_btn.connect("clicked", self._on_export)
        export_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        export_row.set_halign(Gtk.Align.START)
        export_row.append(self.export_btn)
        self.append(_framed(
            "Export — record the packages you installed",
            self.export_chooser, export_row,
        ))

        # -- Import section -------------------------------------------------- #
        self.import_chooser = PathChooser(
            "Manifest:", mode="file",
            placeholder="a drt-packages-*.list file made by Export",
        )
        self.import_chooser.entry.connect("changed", self._on_manifest_changed)
        self.import_btn = Gtk.Button(label="Import")
        self.import_btn.add_css_class("suggested-action")
        self.import_btn.set_sensitive(False)
        self.import_btn.connect("clicked", self._on_import)
        import_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        import_row.set_halign(Gtk.Align.START)
        import_row.append(self.import_btn)
        self.append(_framed(
            "Import — reinstall from a manifest (same package manager only)",
            self.import_chooser, import_row,
        ))

        # Shared error line + job log.
        self.error_label = Gtk.Label(xalign=0)
        self.error_label.set_name("error_label")
        self.error_label.set_wrap(True)
        self.append(self.error_label)

        self.job = JobView()
        self.job.set_vexpand(True)
        self.append(self.job)

        if not self.manager:
            self.export_chooser.set_sensitive(False)
            self.export_btn.set_sensitive(False)
            self.import_chooser.set_sensitive(False)

    # -- helpers ------------------------------------------------------------- #
    def _error(self, text):
        self.error_label.set_text(text)

    def _set_inputs_sensitive(self, sensitive):
        for widget in (self.export_chooser, self.export_btn, self.import_chooser):
            widget.set_sensitive(sensitive)
        self._running = not sensitive
        # The Import button follows the manifest check, not the blanket toggle.
        if sensitive:
            self._on_manifest_changed(None)
        else:
            self.import_btn.set_sensitive(False)

    # -- import-manifest validation ------------------------------------------ #
    def _on_manifest_changed(self, _entry):
        if self._running or not self.manager:
            return
        path = self.import_chooser.get_path()
        if not path or not os.path.isfile(path):
            self.import_btn.set_sensitive(False)
            self._error("")
            return
        mgr = _manifest_manager(path)
        if mgr is None:
            self.import_btn.set_sensitive(False)
            self._error("That file is not a package manifest (no '# manager:' header).")
            return
        if mgr != self.manager:
            self.import_btn.set_sensitive(False)
            self._error(
                f"This manifest was made on '{mgr}', but this system uses "
                f"'{self.manager}'. Package names are not portable — import it on "
                f"a matching system."
            )
            return
        self._error("")
        self.import_btn.set_sensitive(True)

    # -- actions ------------------------------------------------------------- #
    def _on_export(self, _button):
        self._error("")
        out_dir = self.export_chooser.get_path()
        if not out_dir or not os.path.isdir(out_dir):
            self._error("Choose a folder to save the manifest into.")
            return
        argv = [str(config.packages_export_script()), out_dir]
        self._set_inputs_sensitive(False)
        self.job.run(
            argv,
            on_finished=lambda _rc: self._set_inputs_sensitive(True),
            noun="Export",
        )

    def _on_import(self, _button):
        self._error("")
        path = self.import_chooser.get_path()
        if not path or not os.path.isfile(path):
            self._error("Choose a manifest file to import.")
            return
        if _manifest_manager(path) != self.manager:
            self._error("That manifest's package manager does not match this system.")
            return
        argv = [str(config.packages_import_script()), path]
        self._set_inputs_sensitive(False)
        self.job.run(
            argv,
            on_finished=lambda _rc: self._set_inputs_sensitive(True),
            noun="Import",
        )
