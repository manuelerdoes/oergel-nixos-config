#!/usr/bin/env python3
"""languagetool-check: review LanguageTool's findings for the selected text.

Select text anywhere and press the hotkey (Super+Alt+C). The text goes to the
local LanguageTool server (localhost only, nothing leaves the machine), and a
window lists every problem it finds. For each one, pick one of the
suggestions or keep the text as it is; the first suggestion is preselected.
The result below updates as you choose, and you can still edit it by hand.
"Copy" puts it in the clipboard.

German is checked as Swiss German (de-CH: "ss", never "ß"), English as
British English. Change VARIANTS below for others (e.g. en-US).

    languagetool-check            check the selected text (or the clipboard)
    languagetool-check --stdin    check text from stdin (for testing)
"""

import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

SERVER = "http://localhost:8081/v2"
VARIANTS = "de-CH,en-GB"
# Rule categories to skip: Oxford spelling hints ("realize" for "realise").
DISABLED_CATEGORIES = "BRE_STYLE_OXFORD_SPELLING"
MAX_SUGGESTIONS = 6
CONTEXT_CHARS = 45  # characters of context on each side of a problem
# Each paragraph is checked in its own language, so a German email with an
# English paragraph gets the right rules for both. Language detection is
# unreliable for a few words, so paragraphs shorter than this ("Best regards")
# use the language of the rest of the text.
SHORT_PARAGRAPH = 40

CSS = """
.choice:checked { background-color: var(--accent-bg-color); color: var(--accent-fg-color); }
"""


# ----------------------------------------------------------------- helpers
def notify(body, replace=None, urgent=False, timeout=None):
    """Show a notification; returns its id so it can be replaced later."""
    args = ["notify-send", "-a", "LanguageTool", "-p"]
    if replace:
        args += ["-r", replace]
    if urgent:
        args += ["-u", "critical"]
    if timeout is not None:
        args += ["-t", str(timeout)]
    try:
        out = subprocess.run(args + ["LanguageTool", body], capture_output=True, text=True)
        return out.stdout.strip() or None
    except OSError:
        return None


def selected_text():
    """The primary selection (selected text), or the clipboard."""
    for args in (["wl-paste", "--primary", "--no-newline"], ["wl-paste", "--no-newline"]):
        try:
            out = subprocess.run(args, capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout
    return ""


def check(text, language="auto"):
    params = {
        "text": text,
        "language": language,
        "disabledCategories": DISABLED_CATEGORIES,
    }
    if language == "auto":
        params["preferredVariants"] = VARIANTS
    data = urllib.parse.urlencode(params).encode()
    with urllib.request.urlopen(f"{SERVER}/check", data, timeout=60) as response:
        return json.load(response)


def paragraphs(text):
    """(start offset, text) of each paragraph, i.e. text between blank lines,
    without the whitespace around it."""
    out = []
    for m in re.finditer(r"(?:(?!\n[ \t]*\n).)+", text, re.S):
        para = m.group()
        if para.strip():
            lead = len(para) - len(para.lstrip())
            out.append((m.start() + lead, para.strip()))
    return out


def check_text(text):
    """All problems in the text, and the names of the languages found."""
    paras = paragraphs(text)
    results, weight = {}, {}
    for start, para in paras:
        if len(para.strip()) >= SHORT_PARAGRAPH:
            results[start] = check(para)
            code = results[start]["language"]["code"]
            weight[code] = weight.get(code, 0) + len(para)
    if weight:
        main = max(weight, key=weight.get)
    else:
        main = check(text)["language"]["code"]
    for start, para in paras:
        if start not in results:
            results[start] = check(para, main)

    problems, languages = [], []
    for start, para in paras:
        name = results[start].get("language", {}).get("name", "?")
        if name not in languages:
            languages.append(name)
        problems += problems_from(para, results[start], offset=start)
    problems.sort(key=lambda p: (p["start"], p["end"]))
    return problems, languages


def utf16_index_map(text):
    """LanguageTool (Java) counts offsets in UTF-16 units, Python in code
    points. They differ after characters like emoji; this maps one to the other."""
    index = []
    for i, ch in enumerate(text):
        index.append(i)
        if ord(ch) > 0xFFFF:
            index.append(i)
    index.append(len(text))
    return index


def problems_from(text, result, offset=0):
    """Problems in text (one paragraph), with positions shifted by offset."""
    index = utf16_index_map(text)
    problems = []
    for m in result.get("matches", []):
        start = index[min(m["offset"], len(index) - 1)]
        end = index[min(m["offset"] + m["length"], len(index) - 1)]
        suggestions = []
        for r in m.get("replacements", []):
            if r["value"] not in suggestions and r["value"] != text[start:end]:
                suggestions.append(r["value"])
        problems.append(
            {
                "start": offset + start,
                "end": offset + end,
                "message": m.get("message", ""),
                "category": m.get("rule", {}).get("category", {}).get("name", ""),
                "suggestions": suggestions[:MAX_SUGGESTIONS],
                # Index into suggestions, or None to keep the text as it is.
                "choice": 0 if suggestions else None,
            }
        )
    return problems


def apply_choices(text, problems):
    """The text with the chosen suggestions. A problem that overlaps one
    already changed is skipped. Returns the text and the changed ranges."""
    out, changed, pos = [], [], 0
    length = 0
    for p in problems:
        if p["choice"] is None or p["start"] < pos:
            continue
        out.append(text[pos : p["start"]])
        length += p["start"] - pos
        new = p["suggestions"][p["choice"]]
        changed.append((length, length + len(new)))
        out.append(new)
        length += len(new)
        pos = p["end"]
    out.append(text[pos:])
    return "".join(out), changed


def one_line(s):
    return " ".join(s.split())


# ------------------------------------------------------------------ window
class ReviewWindow(Adw.ApplicationWindow):
    def __init__(self, app, text, problems, languages):
        super().__init__(application=app)
        css = Gtk.CssProvider()
        css.load_from_string(CSS)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self.text = text
        self.problems = problems
        self.buttons = []  # per problem: list of toggle buttons, last = keep
        self.rebuilding = False

        language = ", ".join(languages)
        count = len(problems)
        what = "1 problem" if count == 1 else f"{count} problems"
        # Mango and Umbriel float windows whose title starts with "LanguageTool".
        self.set_title(f"LanguageTool: {what} ({language})")
        self.set_default_size(780, 760)

        header = Adw.HeaderBar()
        header.set_title_widget(Adw.WindowTitle(title="LanguageTool", subtitle=f"{what} · {language}"))
        accept_all = Gtk.Button(label="Accept all")
        accept_all.set_tooltip_text("Pick the first suggestion everywhere")
        accept_all.connect("clicked", lambda *_: self.set_all(0))
        keep_all = Gtk.Button(label="Keep all")
        keep_all.set_tooltip_text("Keep the text as it is everywhere")
        keep_all.connect("clicked", lambda *_: self.set_all(None))
        header.pack_start(accept_all)
        header.pack_start(keep_all)

        # Problems
        listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        listbox.add_css_class("boxed-list")
        for i, p in enumerate(problems):
            listbox.append(self.problem_row(i, p))
        problems_scroll = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        problems_scroll.set_child(
            Adw.Clamp(maximum_size=900, child=self.margins(listbox, 12, 12, 12, 6))
        )

        # Result
        self.result = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.result.set_top_margin(8)
        self.result.set_bottom_margin(8)
        self.result.set_left_margin(10)
        self.result.set_right_margin(10)
        self.result.add_css_class("card")
        self.changed_tag = self.result.get_buffer().create_tag("changed", underline=1, weight=700)
        result_scroll = Gtk.ScrolledWindow(min_content_height=150, max_content_height=260)
        result_scroll.set_propagate_natural_height(True)
        result_scroll.set_child(self.result)

        result_title = Gtk.Label(label="Result", xalign=0)
        result_title.add_css_class("heading")
        result_hint = Gtk.Label(
            label="Changes are bold and underlined. You can edit the text here too; "
            "changing a choice above rebuilds it.",
            xalign=0,
            wrap=True,
        )
        result_hint.add_css_class("dim-label")
        result_hint.add_css_class("caption")

        # Buttons
        close = Gtk.Button(label="Close")
        close.connect("clicked", lambda *_: self.close())
        copy = Gtk.Button(label="Copy")
        copy.connect("clicked", lambda *_: self.copy(close_after=False))
        copy_close = Gtk.Button(label="Copy and close")
        copy_close.add_css_class("suggested-action")
        copy_close.set_tooltip_text("Ctrl+Enter")
        copy_close.connect("clicked", lambda *_: self.copy(close_after=True))
        buttons = Gtk.Box(spacing=8, halign=Gtk.Align.END)
        for b in (close, copy, copy_close):
            buttons.append(b)

        bottom = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        for w in (result_title, result_scroll, result_hint, buttons):
            bottom.append(w)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        body.append(problems_scroll)
        body.append(Gtk.Separator())
        body.append(Adw.Clamp(maximum_size=900, child=self.margins(bottom, 12, 12, 10, 12)))

        self.toasts = Adw.ToastOverlay(child=body)
        view = Adw.ToolbarView(content=self.toasts)
        view.add_top_bar(header)
        self.set_content(view)

        keys = Gtk.ShortcutController(scope=Gtk.ShortcutScope.GLOBAL)
        keys.add_shortcut(
            Gtk.Shortcut.new(
                Gtk.ShortcutTrigger.parse_string("Escape"),
                Gtk.CallbackAction.new(lambda *_: self.close() or True),
            )
        )
        keys.add_shortcut(
            Gtk.Shortcut.new(
                Gtk.ShortcutTrigger.parse_string("<Control>Return"),
                Gtk.CallbackAction.new(lambda *_: self.copy(close_after=True) or True),
            )
        )
        self.add_controller(keys)

        self.rebuild()
        copy_close.grab_focus()

    @staticmethod
    def margins(widget, start, end, top, bottom):
        widget.set_margin_start(start)
        widget.set_margin_end(end)
        widget.set_margin_top(top)
        widget.set_margin_bottom(bottom)
        return widget

    def problem_row(self, i, p):
        text = self.text
        before = text[max(0, p["start"] - CONTEXT_CHARS) : p["start"]]
        after = text[p["end"] : p["end"] + CONTEXT_CHARS]
        wrong = text[p["start"] : p["end"]] or "␣"
        markup = (
            ("…" if p["start"] > CONTEXT_CHARS else "")
            + GLib.markup_escape_text(one_line(before) + (" " if before[-1:].isspace() else ""))
            + "<span weight='bold' underline='single' underline_color='#e01b24'"
            + " bgcolor='#e01b24' bgalpha='22%'>"
            + GLib.markup_escape_text(wrong)
            + "</span>"
            + GLib.markup_escape_text((" " if after[:1].isspace() else "") + one_line(after))
            + ("…" if p["end"] + CONTEXT_CHARS < len(text) else "")
        )
        context = Gtk.Label(xalign=0, wrap=True, selectable=False)
        context.set_markup(markup)

        message = Gtk.Label(label=p["message"], xalign=0, wrap=True)
        message.add_css_class("dim-label")

        choices = Adw.WrapBox(child_spacing=6, line_spacing=6)
        group = None
        row_buttons = []
        for n, s in enumerate(p["suggestions"]):
            b = Gtk.ToggleButton(label=s if s.strip() else "(remove)")
            b.add_css_class("choice")
            if n == 0:
                b.set_tooltip_text("Suggested")
            row_buttons.append(b)
        keep = Gtk.ToggleButton(label="Keep as is")
        keep.add_css_class("choice")
        keep.add_css_class("flat")
        row_buttons.append(keep)
        for b in row_buttons:
            if group is None:
                group = b
            else:
                b.set_group(group)
            choices.append(b)
        active = p["choice"] if p["choice"] is not None else len(row_buttons) - 1
        row_buttons[active].set_active(True)
        for n, b in enumerate(row_buttons):
            choice = None if b is keep else n
            b.connect("toggled", self.on_toggled, i, choice)
        self.buttons.append(row_buttons)

        category = Gtk.Label(label=p["category"], xalign=0)
        category.add_css_class("caption")
        category.add_css_class("dim-label")

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        for w in (context, message, choices, category):
            box.append(w)
        row = Gtk.ListBoxRow(activatable=False, child=self.margins(box, 12, 12, 10, 10))
        return row

    def on_toggled(self, button, i, choice):
        if not button.get_active():
            return
        self.problems[i]["choice"] = choice
        if not self.rebuilding:
            self.rebuild()

    def set_all(self, first_or_none):
        self.rebuilding = True
        for p, row_buttons in zip(self.problems, self.buttons):
            if first_or_none == 0 and p["suggestions"]:
                row_buttons[0].set_active(True)
            else:
                row_buttons[-1].set_active(True)
        self.rebuilding = False
        self.rebuild()

    def rebuild(self):
        new, changed = apply_choices(self.text, self.problems)
        buf = self.result.get_buffer()
        buf.set_text(new)
        for start, end in changed:
            buf.apply_tag(self.changed_tag, buf.get_iter_at_offset(start), buf.get_iter_at_offset(end))

    def copy(self, close_after):
        buf = self.result.get_buffer()
        text = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), True)
        # wl-copy keeps serving the clipboard after this window is gone.
        try:
            subprocess.run(["wl-copy"], input=text, text=True, check=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            Gdk.Display.get_default().get_clipboard().set(text)
        if close_after:
            notify("Corrected text is in the clipboard", timeout=3000)
            self.close()
        else:
            self.toasts.add_toast(Adw.Toast(title="Copied", timeout=2))


# -------------------------------------------------------------------- main
def main():
    text = sys.stdin.read() if "--stdin" in sys.argv[1:] else selected_text()
    if not text.strip():
        notify("No text selected", timeout=3000)
        return 0

    nid = notify("Checking ...", timeout=0)
    try:
        problems, languages = check_text(text)
    except (urllib.error.URLError, OSError, ValueError, KeyError):
        notify("Server not reachable (systemctl status languagetool)", replace=nid, urgent=True)
        return 1

    if not problems:
        notify(f"No problems found ({', '.join(languages)})", replace=nid, timeout=3000)
        return 0
    # Close the "Checking" notification; the window takes over.
    notify(f"{len(problems)} problem(s) found", replace=nid, timeout=1)

    app = Adw.Application(
        application_id="local.oergel.LanguageToolCheck",
        flags=Gio.ApplicationFlags.NON_UNIQUE,
    )
    app.connect("activate", lambda a: ReviewWindow(a, text, problems, languages).present())
    return app.run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
