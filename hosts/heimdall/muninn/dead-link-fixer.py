#!/usr/bin/env python3
"""huginn dead-link fixer — finds broken wikilinks across the muninn vault via the
brain API and creates stub notes in _inbox/. Runs weekly, driven by systemd.

API endpoints:
  GET /api/mocs  → {"mocs": [{"path": "...", ...}], "count": N}
  GET /api/graph?path=relpath → {"outgoing": [{"path": "...", "title": "..."}], ...}
  GET /api/read?path=relpath  → 200 (exists) or 404 (missing)

Uses stdlib only (no requests, no pip deps).  TLS verification is disabled because
the brain API's cert is not trusted on heimdall (same as curl -k).
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime

BRAIN = "https://brain.oryxserver.org"
VAULT = "/mnt/nas/obsidian/muninn"
INBOX = os.path.join(VAULT, "_inbox")
REPORT_PATH = os.path.join(VAULT, "Resources", "Dead Link Report.md")
STUB_PREFIX = "stub"           # filename prefix for created stub notes
REQUEST_DELAY = 0.15            # seconds between API calls (gentle rate limit)

# ── TLS: disable cert verification (same as curl -k) ──────────────────────
_SSL_CTX = ssl.create_default_context()
_SSL_CTX.check_hostname = False
_SSL_CTX.verify_mode = ssl.CERT_NONE


def api_get(path: str, timeout: int = 30) -> dict | None:
    """Call the brain API.  Returns parsed JSON, or None on any failure."""
    url = f"{BRAIN}{path}"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CTX) as resp:
            body = resp.read()
            if not body:
                return None
            return json.loads(body)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        if e.code == 503:
            print(f"  [warn] API 503 for {path} — indexer not ready, skipping",
                  file=sys.stderr)
            return None
        print(f"  [warn] HTTP {e.code} for {path}", file=sys.stderr)
        return None
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"  [warn] API error for {path}: {e}", file=sys.stderr)
        return None


def discover_all_notes() -> list[str]:
    """Discover every note path known to the brain via /api/mocs."""
    data = api_get("/api/mocs")
    if not data:
        return []
    mocs = data.get("mocs", [])
    if not isinstance(mocs, list):
        return []
    return [m["path"] for m in mocs if isinstance(m, dict) and "path" in m]


def get_outgoing_links(path: str) -> list[str]:
    """Return outgoing wikilink paths for a note (via /api/graph)."""
    q = urllib.parse.quote(path, safe="/")
    data = api_get(f"/api/graph?path={q}")
    if not data:
        return []
    outgoing = data.get("outgoing", [])
    if not isinstance(outgoing, list):
        return []
    return [l["path"] for l in outgoing if isinstance(l, dict) and "path" in l]


def note_exists_in_brain(path: str) -> bool:
    """Check whether the brain knows about a note (200 via /api/read)."""
    q = urllib.parse.quote(path, safe="/")
    url = f"{BRAIN}/api/read?path={q}"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=15, context=_SSL_CTX) as resp:
            return resp.status == 200
    except urllib.error.HTTPError:
        return False
    except Exception:
        return False


def note_exists_on_disk(name: str) -> bool:
    """Check whether a .md file for this note name exists in the vault."""
    # Try exact match first, then common variations
    candidates = [
        os.path.join(VAULT, f"{name}.md"),
    ]
    for p in candidates:
        if os.path.exists(p):
            return True
    return False


def stub_exists_in_inbox(name: str) -> bool:
    """Check if a stub note for this name already exists in _inbox."""
    stub_name = f"{STUB_PREFIX} {name}.md"
    return os.path.exists(os.path.join(INBOX, stub_name))


def normalize_target(raw: str) -> str:
    """Normalise a wikilink target: strip .md, strip leading/trailing whitespace."""
    t = raw.strip()
    if t.endswith(".md"):
        t = t[:-3]
    return t


def create_stub(target: str, sources: list[str], today: str) -> bool:
    """Create a stub note in _inbox/ for a dead link target.  Returns True on success."""
    stub_name = f"{STUB_PREFIX} {target}.md"
    stub_path = os.path.join(INBOX, stub_name)

    backlinks = "\n".join(f"  - [[{s}]]" for s in sorted(sources)[:5])
    if len(sources) > 5:
        backlinks += f"\n  - ... and {len(sources) - 5} more"

    content = (
        "---\n"
        f"type: stub\n"
        "status: inbox\n"
        "tags: [dead-link, stub, needs-content]\n"
        f"created: {today}\n"
        "agent: huginn/dead-link-fixer\n"
        "---\n\n"
        f"# {target}\n\n"
        "> [!missing] This note was auto-created because it was linked but missing.\n"
        ">\n"
        "> Sources that link here:\n"
        f"{backlinks}\n\n"
    )
    try:
        with open(stub_path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return True
    except OSError as e:
        print(f"  [warn] Failed to create stub for {target}: {e}", file=sys.stderr)
        return False


def write_report(dead_links: dict[str, list[str]], stubs_created: int,
                 total_notes: int, today: str) -> None:
    """Write (or overwrite) the dead-link report note."""
    unique_dead = {t for targets in dead_links.values() for t in targets}

    if unique_dead:
        lines = [
            "---",
            "type: note",
            "status: active",
            "tags: [gardener, maintenance, dead-links]",
            f"created: {today}",
            "agent: huginn",
            "---",
            "",
            "# Dead Link Report",
            "",
            f"Weekly dead-link sweep ({today}) — {len(unique_dead)} dead links "
            f"found across {len(dead_links)} source notes ({total_notes} total).",
            "",
        ]
        for src in sorted(dead_links.keys()):
            targets = sorted(set(dead_links[src]))
            lines.append(f"## [[{src}]]")
            for t in targets:
                lines.append(f"- Links to missing **{t}**")
            lines.append("")

        lines += [
            f"## Stubs created ({stubs_created})",
            "",
            f"Stub notes were created in `_inbox/` with prefix `{STUB_PREFIX}`. "
            "They will be processed by the inbox sweep on the next run.",
            "",
            "See also: [[Home MOC]]",
            "",
        ]
    else:
        lines = [
            "---",
            "type: note",
            "status: active",
            "tags: [gardener, maintenance, dead-links]",
            f"created: {today}",
            "agent: huginn",
            "---",
            "",
            "# Dead Link Report",
            "",
            f"Weekly dead-link sweep ({today}) — no dead links found across "
            f"{total_notes} notes. 🌱",
            "",
            "See also: [[Home MOC]]",
            "",
        ]

    os.makedirs(os.path.dirname(REPORT_PATH), exist_ok=True)
    with open(REPORT_PATH, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def main() -> None:
    # Ensure log and inbox directories exist
    logdir = os.path.join(VAULT, "agents", "logs")
    os.makedirs(logdir, exist_ok=True)
    os.makedirs(INBOX, exist_ok=True)

    today = date.today().isoformat()
    print(f"[{datetime.now().isoformat()}] huginn/dead-link-fixer start")

    # ── Step 1: discover all note paths ──────────────────────────────────
    note_paths = discover_all_notes()
    if not note_paths:
        print("  No notes discovered — API may be unreachable or vault is empty.")
        print(f"[{datetime.now().isoformat()}] huginn/dead-link-fixer done (empty)")
        return

    print(f"  Discovered {len(note_paths)} notes via brain API")

    # ── Step 2: walk every note, collect outgoing links, check liveness ──
    dead_links: dict[str, list[str]] = {}  # source_path → [dead target ...]
    confirmed_exist: set[str] = set()       # paths we've confirmed exist
    checked: set[str] = set()               # paths we've already checked

    for i, path in enumerate(note_paths):
        if i % 10 == 0:
            print(f"  Processing {i + 1}/{len(note_paths)}...")

        outgoing = get_outgoing_links(path)
        if not outgoing:
            continue

        for raw_target in outgoing:
            target = normalize_target(raw_target)
            if not target:
                continue

            # Already confirmed existing — skip
            if target in confirmed_exist:
                continue

            if target in checked:
                # Already checked and didn't exist — record dead link
                if path not in dead_links:
                    dead_links[path] = []
                if target not in dead_links[path]:
                    dead_links[path].append(target)
                continue

            # Check liveness: brain API first, then filesystem as fallback
            if note_exists_in_brain(target):
                confirmed_exist.add(target)
                checked.add(target)
                continue

            if note_exists_on_disk(target):
                # Exists on disk but brain missed it — treat as alive
                confirmed_exist.add(target)
                checked.add(target)
                time.sleep(REQUEST_DELAY)
                continue

            # It's dead — but skip if a stub is already in _inbox
            if stub_exists_in_inbox(target):
                confirmed_exist.add(target)   # treat as "being handled"
                checked.add(target)
                time.sleep(REQUEST_DELAY)
                continue

            confirmed_exist.add(target)  # well, mark as checked so we don't re-check
            if path not in dead_links:
                dead_links[path] = []
            dead_links[path].append(target)
            checked.add(target)

            time.sleep(REQUEST_DELAY)

    # ── Step 3: create stubs and write report ────────────────────────────
    unique_dead = {t for targets in dead_links.values() for t in targets}
    print(f"  Found {len(unique_dead)} unique dead links across "
          f"{len(dead_links)} source notes")

    stubs_created = 0
    if unique_dead:
        # Collect all sources per dead target for backlinks
        target_sources: dict[str, list[str]] = {}
        for src, targets in dead_links.items():
            for t in targets:
                target_sources.setdefault(t, []).append(src)

        for target in sorted(target_sources.keys()):
            # Double-check: real note might have been created since we checked
            if note_exists_on_disk(target):
                continue
            if stub_exists_in_inbox(target):
                continue
            if create_stub(target, target_sources[target], today):
                stubs_created += 1

        print(f"  Created {stubs_created} stub notes in _inbox/")

    write_report(dead_links, stubs_created, len(note_paths), today)
    print(f"  Report written to Resources/Dead Link Report.md")
    print(f"[{datetime.now().isoformat()}] huginn/dead-link-fixer done "
          f"({len(unique_dead)} dead, {stubs_created} stubs)")


if __name__ == "__main__":
    main()