#!/usr/bin/env python3
"""huginn dead-link fixer — finds wikilinks in filed notes that point at no note,
lists them in Resources/Dead Link Report.md and creates a stub note for each
missing target so the link resolves. Runs weekly, driven by systemd.

Offline and stdlib only. It used to ask the brain API, which lists only the MOCs
and only ever returns links that resolve, so it never saw a dead one.
"""
import argparse
import difflib
import os
import re
import sys
from datetime import date, datetime

SKIP = {".obsidian", ".git", ".trash", "_templates", "agents", "graphify-out"}
# Journals, talk logs and reports quote whatever a model said: a dead link there
# is noise, not a note waiting to be written. The gardener still lists those.
LOGS = ("journal/", "Resources/Talk logs/", "Resources/Reports/", "_inbox/")
GENERATED = {"CLAUDE", "README", "Gardener Report", "Dead Link Report"}
WIKILINK = re.compile(r"\[\[([^\]|#]+)")
CODE = re.compile(r"```.*?```|`[^`\n]*`", re.S)   # a shell `[[ -d x ]]` test is not a wikilink
UNSAFE = re.compile(r'[\x00-\x1f\x7f/\\\[\]#|:]')   # not allowed in a note title
CLOSE = 0.8        # how alike two squashed titles must be to count as the same note
STUB_DIR = "Resources"


def targets(text):
    """Note names a text links to. A link into a skipped folder (the inbox archive
    under agents/) is not part of the graph, so it is not dead either."""
    found = set()
    for match in WIKILINK.finditer(CODE.sub("", text)):
        target = match.group(1).strip()
        if target.split("/")[0] in SKIP or not any(c.isalnum() for c in target):
            continue
        name = target.split("/")[-1]
        found.add(name[:-3] if name.endswith(".md") else name)
    return found


def scan(vault):
    """Every note by name, with its vault path and the names it links to."""
    notes = {}
    for root, dirs, files in os.walk(vault):
        dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".")]
        for fn in files:
            if not fn.endswith(".md"):
                continue
            path = os.path.join(root, fn)
            try:
                with open(path, encoding="utf-8", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            notes[fn[:-3]] = {"rel": os.path.relpath(path, vault), "links": targets(text)}
    return notes


def squash(name):
    return re.sub(r"[^a-z0-9]+", "", name.lower())


def find_dead(notes):
    """Split the dead links of filed notes into (dead, misspelt).

    dead: source -> targets no note answers to. misspelt: source -> {target: the
    existing note it almost certainly means}, which wants the link fixed, not a stub."""
    squashed = {squash(name): name for name in notes}
    dead, misspelt = {}, {}
    for source, note in notes.items():
        if source in GENERATED or note["rel"].startswith(LOGS):
            continue
        for target in sorted(note["links"]):
            if target in notes:
                continue
            near = difflib.get_close_matches(squash(target), list(squashed), n=1, cutoff=CLOSE)
            if near:
                misspelt.setdefault(source, {})[target] = squashed[near[0]]
            else:
                dead.setdefault(source, []).append(target)
    return dead, misspelt


def create_stub(vault, target, sources, today):
    """Create the missing note under its linked name. Never overwrites; True if written."""
    if UNSAFE.search(target) or target.startswith(".") or len(target.encode()) > 160:
        return False
    backlinks = "\n".join(f"- [[{s}]]" for s in sorted(sources))
    content = (
        "---\n"
        "type: stub\n"
        "status: inbox\n"
        "tags: [dead-link, stub, needs-content]\n"
        f"created: {today}\n"
        "agent: huginn/dead-link-fixer\n"
        "---\n\n"
        f"# {target}\n\n"
        "> [!missing] This note was auto-created because it was linked but missing.\n\n"
        f"Linked from:\n{backlinks}\n\n"
        "See also: [[Home MOC]]\n"
    )
    directory = os.path.join(vault, STUB_DIR)
    try:
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, target + ".md"), "x", encoding="utf-8") as fh:
            fh.write(content)
        return True
    except OSError as e:
        print(f"  [warn] no stub for {target}: {e}", file=sys.stderr)
        return False


def write_report(vault, dead, misspelt, stubs, total, today):
    """Write (or overwrite) the dead-link report note."""
    lines = [
        "---", "type: note", "status: active", "tags: [gardener, maintenance, dead-links]",
        f"created: {today}", "agent: huginn", "---", "", "# Dead Link Report", "",
    ]
    count = sum(len(t) for t in dead.values()) + sum(len(t) for t in misspelt.values())
    if count:
        sources = sorted(set(dead) | set(misspelt))
        lines += [f"Weekly dead-link sweep ({today}) — {count} dead links in "
                  f"{len(sources)} of {total} notes.", ""]
        for src in sources:
            lines.append(f"## [[{src}]]")
            lines += [f"- Links to missing **{t}**" for t in dead.get(src, [])]
            lines += [f"- Links to **{t}**, which is probably [[{note}]]: fix the link"
                      for t, note in sorted(misspelt.get(src, {}).items())]
            lines.append("")
        lines += [f"## Stubs created ({len(stubs)})", ""]
        lines += [f"- [[{s}]]" for s in stubs]
        lines += ["", f"A stub is written to `{STUB_DIR}/` under the name it was linked by, so the "
                  "link resolves. Fill it in, or delete it and point the link at the right note.", ""]
    else:
        lines += [f"Weekly dead-link sweep ({today}) — no dead links found across {total} notes. 🌱", ""]
    lines += ["See also: [[Home MOC]]", ""]
    path = os.path.join(vault, "Resources", "Dead Link Report.md")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault", default="/mnt/nas/obsidian/muninn")
    parser.add_argument("--dry-run", action="store_true", help="print the findings, write nothing")
    args = parser.parse_args()
    today = date.today().isoformat()
    print(f"[{datetime.now().isoformat()}] huginn/dead-link-fixer start")
    notes = scan(args.vault)
    dead, misspelt = find_dead(notes)
    print(f"  Scanned {len(notes)} notes: {sum(len(t) for t in dead.values())} dead links, "
          f"{sum(len(t) for t in misspelt.values())} misspelt")
    wanted = {}   # missing target -> the notes that link to it
    for source, missing in dead.items():
        for target in missing:
            wanted.setdefault(target, []).append(source)
    if args.dry_run:
        for target, sources in sorted(wanted.items()):
            print(f"  would stub {target!r} (linked from {', '.join(sorted(sources))})")
        for source, pairs in sorted(misspelt.items()):
            for target, note in sorted(pairs.items()):
                print(f"  {source}: {target!r} is probably {note!r}")
        return
    stubs = [t for t, sources in sorted(wanted.items()) if create_stub(args.vault, t, sources, today)]
    write_report(args.vault, dead, misspelt, stubs, len(notes), today)
    print("  Report written to Resources/Dead Link Report.md")
    print(f"[{datetime.now().isoformat()}] huginn/dead-link-fixer done "
          f"({len(wanted)} dead, {len(stubs)} stubs)")


if __name__ == "__main__":
    main()
