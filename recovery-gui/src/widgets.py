"""Small reusable widgets: page titles, a disk picker, and path chooser rows."""

import gi

gi.require_version("Gtk", "4.0")

import disks  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402


def make_title(text: str) -> Gtk.Label:
    label = Gtk.Label(xalign=0)
    label.set_name("title")
    label.set_text(text)
    return label


def make_intro(text: str) -> Gtk.Label:
    label = Gtk.Label(xalign=0)
    label.set_wrap(True)
    label.set_markup(text)
    label.set_margin_bottom(6)
    return label


class Toast(Gtk.Revealer):
    """A transient, bottom-anchored notification.

    Mirrors the Arch Linux Tweak Tool's in-app notification (a styled label
    that slides up, then auto-dismisses after a few seconds). Built from plain
    Gtk — no libadwaita — so it behaves identically on the differing GTK 4
    versions shipped by Arch, Debian and Fedora.
    """

    DURATION_MS = 4000

    def __init__(self):
        super().__init__()
        self.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP)
        self.set_transition_duration(200)
        self.set_halign(Gtk.Align.CENTER)
        self.set_valign(Gtk.Align.END)
        self.set_margin_bottom(18)
        self.set_reveal_child(False)

        self._label = Gtk.Label()
        self._label.set_wrap(True)
        self._label.set_justify(Gtk.Justification.CENTER)

        self._frame = Gtk.Box()
        self._frame.set_name("toast")
        self._frame.append(self._label)
        self.set_child(self._frame)

        self._timeout_id = None

    def show(self, message: str, kind: str = "info"):
        """Reveal a message. kind is one of 'info', 'success', 'error'."""
        # Cancel any pending auto-dismiss so rapid toasts don't fight.
        if self._timeout_id is not None:
            GLib.source_remove(self._timeout_id)
            self._timeout_id = None

        # remove_css_class on an absent class is a harmless no-op in GTK 4.
        self._frame.remove_css_class("toast-success")
        self._frame.remove_css_class("toast-error")
        if kind == "success":
            self._frame.add_css_class("toast-success")
        elif kind == "error":
            self._frame.add_css_class("toast-error")

        self._label.set_text(message)
        self.set_reveal_child(True)
        self._timeout_id = GLib.timeout_add(self.DURATION_MS, self._hide)

    def _hide(self):
        self.set_reveal_child(False)
        self._timeout_id = None
        return GLib.SOURCE_REMOVE


def notify(widget: Gtk.Widget, message: str, kind: str = "info"):
    """Show a transient toast on the application window holding ``widget``.

    Safe to call from any page: it walks up to the top-level window and uses
    its toast if one is present, otherwise does nothing.
    """
    root = widget.get_root()
    show_toast = getattr(root, "show_toast", None)
    if callable(show_toast):
        show_toast(message, kind)


class DiskPicker(Gtk.Box):
    """Label + dropdown of whole disks + a refresh button.

    include_mounted=False hides disks with a mounted partition (the running
    system); the backend scripts refuse those anyway.

    removable_only=True keeps only removable (USB) devices — used by the USB
    Writer page so an internal drive can't be picked by accident. It can be
    toggled at runtime with set_removable_only().
    """

    def __init__(self, label_text: str, include_mounted: bool = False,
                 removable_only: bool = False):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.include_mounted = include_mounted
        self.removable_only = removable_only
        self._disks = []

        label = Gtk.Label(xalign=0, label=label_text)
        label.set_size_request(110, -1)
        self.append(label)

        self.model = Gtk.StringList()
        self.dropdown = Gtk.DropDown(model=self.model)
        self.dropdown.set_hexpand(True)
        self.append(self.dropdown)

        refresh = Gtk.Button()
        refresh.set_icon_name("view-refresh-symbolic")
        refresh.set_tooltip_text("Rescan disks")
        refresh.connect("clicked", lambda _b: self.refresh())
        self.append(refresh)

        self.refresh()

    def set_removable_only(self, flag: bool):
        """Switch between removable-only and all-disks, then rescan."""
        self.removable_only = bool(flag)
        self.refresh()

    def refresh(self):
        self._disks = disks.list_disks(include_mounted=self.include_mounted)
        if self.removable_only:
            self._disks = [d for d in self._disks if d.get("removable")]
        # Rebuild the string model.
        while self.model.get_n_items() > 0:
            self.model.remove(0)
        if not self._disks:
            self.model.append("(no eligible disks found)")
            self.dropdown.set_sensitive(False)
            return
        self.dropdown.set_sensitive(True)
        for disk in self._disks:
            self.model.append(disks.describe(disk))

    def get_selected(self):
        """Return the selected disk dict, or None."""
        if not self._disks:
            return None
        idx = self.dropdown.get_selected()
        if idx == Gtk.INVALID_LIST_POSITION or idx >= len(self._disks):
            return None
        return self._disks[idx]


class PathChooser(Gtk.Box):
    """Label + entry + Browse button. mode is 'folder' or 'file'."""

    def __init__(self, label_text: str, mode: str = "folder", placeholder: str = ""):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.mode = mode

        label = Gtk.Label(xalign=0, label=label_text)
        label.set_size_request(110, -1)
        self.append(label)

        self.entry = Gtk.Entry()
        self.entry.set_hexpand(True)
        if placeholder:
            self.entry.set_placeholder_text(placeholder)
        self.append(self.entry)

        browse = Gtk.Button(label="Browse…")
        browse.connect("clicked", self._on_browse)
        self.append(browse)

    def get_path(self) -> str:
        return self.entry.get_text().strip()

    def set_path(self, path: str):
        self.entry.set_text(path)

    def _on_browse(self, _button):
        dialog = Gtk.FileDialog()
        dialog.set_title("Select a folder" if self.mode == "folder" else "Select a file")
        window = self.get_root()
        if self.mode == "folder":
            dialog.select_folder(window, None, self._on_folder_chosen)
        else:
            dialog.open(window, None, self._on_file_chosen)

    def _on_folder_chosen(self, dialog, result):
        try:
            folder = dialog.select_folder_finish(result)
        except GLib.Error:
            return
        if folder:
            self.entry.set_text(folder.get_path())

    def _on_file_chosen(self, dialog, result):
        try:
            gfile = dialog.open_finish(result)
        except GLib.Error:
            return
        if gfile:
            self.entry.set_text(gfile.get_path())
