"""Add bookmarks from an exported bookmarks.html file to Chromium and Zen.

Usage:  import-bookmarks FILE.html [--only chromium|zen]

Close both browsers first. Bookmarks that already exist (same URL) are
skipped and folders with the same name are merged, so running it twice is
harmless.

- Chromium: the bookmarks are written straight into its Bookmarks file.
- Zen: the new bookmarks are merged with Zen's current ones into
  bookmarks.html in the Zen profile, and Zen imports that file the next time
  it starts (Firefox's browser.places.importBookmarksHTML mechanism).

The HTML file is only read. Keep it out of the git repo (*.html is ignored).
"""

import argparse
import configparser
import html
import json
import shutil
import sqlite3
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path

HOME = Path.home()
CHROMIUM_DIR = HOME / ".config/chromium"
ZEN_DIRS = [HOME / ".zen", HOME / ".config/zen"]

# Chromium counts microseconds since 1601-01-01, Unix since 1970-01-01.
CHROMIUM_EPOCH_OFFSET = 11_644_473_600

NOW = int(time.time())


# ==============================================================================
# Browser-independent bookmark tree


@dataclass
class Link:
    title: str
    url: str
    added: int = NOW  # Unix seconds


@dataclass
class Folder:
    title: str
    children: list = field(default_factory=list)
    added: int = NOW


@dataclass
class Bookmarks:
    menu: Folder  # top level of the file / Firefox's bookmarks menu
    toolbar: Folder  # bookmarks bar / toolbar
    other: Folder  # "Other bookmarks"


def empty_bookmarks() -> Bookmarks:
    return Bookmarks(Folder("Bookmarks Menu"), Folder("Bookmarks Toolbar"), Folder("Other Bookmarks"))


def links(nodes):
    for node in nodes:
        if isinstance(node, Link):
            yield node
        else:
            yield from links(node.children)


def count(bm: Bookmarks) -> int:
    return sum(1 for _ in links([bm.menu, bm.toolbar, bm.other]))


def merge(children: list, new: list, known_urls: set) -> int:
    """Add `new` nodes to `children`, skipping known URLs. Returns how many were added."""
    added = 0
    for node in new:
        if isinstance(node, Link):
            if node.url not in known_urls:
                known_urls.add(node.url)
                children.append(node)
                added += 1
            continue
        target = next((c for c in children if isinstance(c, Folder) and c.title == node.title), None)
        if target is None:
            folder = Folder(node.title, [], node.added)
            n = merge(folder.children, node.children, known_urls)
            if n:
                children.append(folder)
        else:
            n = merge(target.children, node.children, known_urls)
        added += n
    return added


# ==============================================================================
# Reading the exported HTML file (Netscape bookmark format, used by all browsers)


def date_attr(attrs: dict) -> int:
    try:
        return int(attrs.get("add_date") or NOW)
    except ValueError:
        return NOW


class NetscapeParser(HTMLParser):
    """Folders are <DT><H3>name</H3> followed by <DL>...</DL>; links are <DT><A HREF>."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.result = empty_bookmarks()
        self.stack = []  # folders whose <DL> is open
        self.pending = None  # folder from the last </H3>, waiting for its <DL>
        self.text = None  # text inside the current <H3> or <A>
        self.attrs = {}

    def current(self) -> Folder:
        return self.stack[-1] if self.stack else self.result.menu

    def handle_starttag(self, tag, attrs):
        if tag == "dl":
            self.stack.append(self.pending or self.current())
            self.pending = None
        elif tag in ("h3", "a"):
            self.text = ""
            self.attrs = {k: v or "" for k, v in attrs}

    def handle_data(self, data):
        if self.text is not None:
            self.text += data

    def handle_endtag(self, tag):
        if tag == "dl":
            if self.stack:
                self.stack.pop()
        elif tag == "h3" and self.text is not None:
            if "personal_toolbar_folder" in self.attrs:
                folder = self.result.toolbar
            elif "unfiled_bookmarks_folder" in self.attrs:
                folder = self.result.other
            else:
                folder = Folder(self.text.strip(), [], date_attr(self.attrs))
                self.current().children.append(folder)
            self.pending = folder
            self.text = None
        elif tag == "a" and self.text is not None:
            url = self.attrs.get("href", "")
            if url:
                self.current().children.append(Link(self.text.strip() or url, url, date_attr(self.attrs)))
            self.text = None


def read_html(path: Path) -> Bookmarks:
    parser = NetscapeParser()
    parser.feed(path.read_text(encoding="utf-8", errors="replace"))
    parser.close()
    return parser.result


# ==============================================================================
# Helpers


def backup(path: Path) -> None:
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + ".before-import"))


def is_locked(lock: Path) -> bool:
    # Browsers keep a (dangling) symlink here while they run.
    return lock.is_symlink() or lock.exists()


def skip(browser: str, reason: str) -> bool:
    print(f"{browser}: skipped. {reason}")
    return False


# ==============================================================================
# Chromium: ~/.config/chromium/Default/Bookmarks (JSON)


def chromium_walk(node: dict):
    yield node
    for child in node.get("children", []):
        yield from chromium_walk(child)


def chromium_node(state: dict, name: str, added: int, url: str | None = None) -> dict:
    stamp = str((added + CHROMIUM_EPOCH_OFFSET) * 1_000_000)
    node = {
        "date_added": stamp,
        "date_last_used": "0",
        "guid": str(uuid.uuid4()),
        "id": str(state["next_id"]),
        "name": name,
        "type": "url" if url else "folder",
    }
    state["next_id"] += 1
    if url:
        node["url"] = url
    else:
        node["children"] = []
        node["date_modified"] = stamp
    return node


def chromium_merge(children: list, new: list, state: dict) -> int:
    """Like merge(), but into Chromium's JSON nodes."""
    added = 0
    for node in new:
        if isinstance(node, Link):
            if node.url not in state["urls"]:
                state["urls"].add(node.url)
                children.append(chromium_node(state, node.title, node.added, node.url))
                added += 1
            continue
        target = next((c for c in children if c.get("type") == "folder" and c.get("name") == node.title), None)
        if target is None:
            folder = chromium_node(state, node.title, node.added)
            n = chromium_merge(folder["children"], node.children, state)
            if n:
                children.append(folder)
        else:
            n = chromium_merge(target["children"], node.children, state)
        added += n
    return added


def empty_chromium() -> dict:
    def root(id_, guid, name):
        return {
            "children": [],
            "date_added": str((NOW + CHROMIUM_EPOCH_OFFSET) * 1_000_000),
            "date_last_used": "0",
            "date_modified": "0",
            "guid": guid,
            "id": id_,
            "name": name,
            "type": "folder",
        }

    return {
        "roots": {
            "bookmark_bar": root("1", "0bc5d13f-2cba-5d74-951f-3f233fe6c908", "Bookmarks bar"),
            "other": root("2", "82b081ec-3dd3-529c-8475-ab6c344590dd", "Other bookmarks"),
            "synced": root("3", "4cf2e351-0e85-532b-bb37-df045d8f8d0f", "Mobile bookmarks"),
        },
        "version": 1,
    }


def import_chromium(new: Bookmarks) -> bool:
    profile = CHROMIUM_DIR / "Default"
    if not profile.is_dir():
        return skip("Chromium", "No profile yet. Start Chromium once, close it, and run this again.")
    if is_locked(CHROMIUM_DIR / "SingletonLock"):
        return skip(
            "Chromium",
            "It is running. Close it and run this again. (If it is definitely "
            f"closed, delete {CHROMIUM_DIR / 'SingletonLock'}.)",
        )

    file = profile / "Bookmarks"
    data = json.loads(file.read_text(encoding="utf-8")) if file.exists() else empty_chromium()
    roots = data["roots"]
    nodes = [n for root in roots.values() if isinstance(root, dict) for n in chromium_walk(root)]
    state = {
        "next_id": max(int(n.get("id") or 0) for n in nodes) + 1,
        "urls": {n["url"] for n in nodes if n.get("type") == "url"},
    }

    added = chromium_merge(roots["bookmark_bar"]["children"], new.toolbar.children, state)
    added += chromium_merge(roots["other"]["children"], new.menu.children + new.other.children, state)
    if added == 0:
        print("Chromium: nothing new, all bookmarks were already there.")
        return True

    # Chromium checks this against the content; without it, it just recomputes it.
    data.pop("checksum", None)
    backup(file)
    tmp = file.with_name("Bookmarks.tmp")
    tmp.write_text(json.dumps(data, indent=3, ensure_ascii=False), encoding="utf-8")
    tmp.replace(file)
    print(f"Chromium: {added} bookmarks added ({count(new) - added} were already there).")
    return True


# ==============================================================================
# Zen (Firefox-based): read places.sqlite, write bookmarks.html, import on start


def find_zen_profile() -> Path | None:
    for base in ZEN_DIRS:
        ini = base / "profiles.ini"
        if not ini.exists():
            continue
        cfg = configparser.ConfigParser(interpolation=None)
        cfg.read(ini)
        # [Install...] sections name the profile this Zen installation uses.
        for section in cfg.sections():
            if section.startswith("Install") and cfg[section].get("default"):
                return base / cfg[section]["default"]
        profiles = [s for s in cfg.sections() if s.startswith("Profile")]
        if profiles:
            chosen = next((s for s in profiles if cfg[s].get("default") == "1"), profiles[0])
            path = cfg[chosen]["path"]
            return base / path if cfg[chosen].get("isrelative", "1") == "1" else Path(path)
    return None


def read_zen(profile: Path) -> Bookmarks:
    bm = empty_bookmarks()
    if not (profile / "places.sqlite").exists():
        return bm

    # Work on a copy, so Zen's database is never touched.
    with tempfile.TemporaryDirectory() as tmp:
        for name in ("places.sqlite", "places.sqlite-wal"):
            if (profile / name).exists():
                shutil.copy2(profile / name, Path(tmp) / name)
        con = sqlite3.connect(Path(tmp) / "places.sqlite")
        rows = con.execute(
            """SELECT b.id, b.type, b.parent, b.title, b.dateAdded, b.guid, p.url
               FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
               ORDER BY b.parent, b.position"""
        ).fetchall()
        con.close()

    children = {}
    ids = {}
    for row in rows:
        children.setdefault(row[2], []).append(row)
        ids[row[5]] = row[0]

    def build(parent_id):
        nodes = []
        for id_, type_, _, title, added, _, url in children.get(parent_id, []):
            added = (added or 0) // 1_000_000  # microseconds -> seconds
            if type_ == 1 and url:
                nodes.append(Link(title or url, url, added))
            elif type_ == 2:
                nodes.append(Folder(title or "", build(id_), added))
        return nodes

    # Firefox's fixed root folders. Tags and mobile bookmarks are left out.
    for attr, guid in (("menu", "menu________"), ("toolbar", "toolbar_____"), ("other", "unfiled_____")):
        if guid in ids:
            getattr(bm, attr).children = build(ids[guid])
    return bm


def to_html(bm: Bookmarks) -> str:
    out = [
        "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
        '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
        "<TITLE>Bookmarks</TITLE>",
        "<H1>Bookmarks Menu</H1>",
        "<DL><p>",
    ]

    def esc(text):
        return html.escape(text, quote=True)

    def emit(nodes, depth):
        for node in nodes:
            if isinstance(node, Link):
                out.append(f'{"    " * depth}<DT><A HREF="{esc(node.url)}" ADD_DATE="{node.added}">{esc(node.title)}</A>')
            else:
                folder(node, depth, "")

    def folder(f, depth, special):
        pad = "    " * depth
        out.append(f'{pad}<DT><H3 ADD_DATE="{f.added}"{special}>{esc(f.title)}</H3>')
        out.append(f"{pad}<DL><p>")
        emit(f.children, depth + 1)
        out.append(f"{pad}</DL><p>")

    emit(bm.menu.children, 1)
    folder(bm.toolbar, 1, ' PERSONAL_TOOLBAR_FOLDER="true"')
    folder(bm.other, 1, ' UNFILED_BOOKMARKS_FOLDER="true"')
    out.append("</DL>")
    return "\n".join(out) + "\n"


def import_zen(new: Bookmarks) -> bool:
    profile = find_zen_profile()
    if profile is None or not profile.is_dir():
        return skip("Zen", "No profile yet. Start Zen once, close it, and run this again.")
    if is_locked(profile / "lock"):
        return skip(
            "Zen",
            f"It is running. Close it and run this again. (If it is definitely closed, delete {profile / 'lock'}.)",
        )

    bm = read_zen(profile)
    known = {link.url for link in links([bm.menu, bm.toolbar, bm.other])}
    added = merge(bm.toolbar.children, new.toolbar.children, known)
    added += merge(bm.menu.children, new.menu.children, known)
    added += merge(bm.other.children, new.other.children, known)
    if added == 0:
        print("Zen: nothing new, all bookmarks were already there.")
        return True

    # Zen replaces its bookmarks with this file on the next start. It holds
    # the current bookmarks plus the new ones, so nothing is lost.
    (profile / "bookmarks.html").write_text(to_html(bm), encoding="utf-8")

    prefs = profile / "prefs.js"
    lines = prefs.read_text(encoding="utf-8").splitlines() if prefs.exists() else []
    backup(prefs)
    lines = [
        line for line in lines if '"browser.places.importBookmarksHTML"' not in line and '"browser.bookmarks.file"' not in line
    ]
    lines.append('user_pref("browser.places.importBookmarksHTML", true);')
    prefs.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Zen: {added} bookmarks will be added the next time you start Zen ({count(new) - added} were already there).")
    return True


# ==============================================================================


def main() -> None:
    ap = argparse.ArgumentParser(description="Add bookmarks from an exported bookmarks.html to Chromium and Zen.")
    ap.add_argument("file", type=Path, help="exported bookmarks file (.html)")
    ap.add_argument("--only", choices=["chromium", "zen"], help="import into one browser only")
    args = ap.parse_args()

    if not args.file.is_file():
        sys.exit(f"File not found: {args.file}")
    new = read_html(args.file)
    total = count(new)
    if total == 0:
        sys.exit("No bookmarks found. Is this an exported bookmarks HTML file?")
    print(f"Found {total} bookmarks in {args.file.name}.")

    ok = True
    if args.only in (None, "chromium"):
        ok = import_chromium(new) and ok
    if args.only in (None, "zen"):
        ok = import_zen(new) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
