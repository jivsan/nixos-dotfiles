#!/usr/bin/env python3
# muninn gardener — weekly vault hygiene. Offline analysis (orphans, dead links,
# stale notes); MiniMax (OpenRouter, OPENAI_* env) only for MOC-link suggestions.
# Writes/overwrites "Resources/Gardener Report.md" and prints a one-line summary.
import os, re, json, time, datetime, urllib.request

VAULT = "/mnt/nas/obsidian/muninn"
SKIP = {".obsidian", ".git", ".trash", "_templates", "agents", "graphify-out"}
WIKILINK = re.compile(r"\[\[([^\]|#]+)")
STALE_DAYS = 30

now = time.time()
notes = {}  # name -> {rel, folder, links, status, type, mtime, snippet}
for root, dirs, files in os.walk(VAULT):
    dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".")]
    for fn in files:
        if not fn.endswith(".md"):
            continue
        rel = os.path.relpath(os.path.join(root, fn), VAULT)
        folder = rel.split(os.sep)[0] if os.sep in rel else "root"
        try:
            with open(os.path.join(VAULT, rel), encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
            mtime = os.path.getmtime(os.path.join(VAULT, rel))
        except OSError:
            continue
        fm = {}
        if text.startswith("---"):
            for line in text.split("---", 2)[1].splitlines():
                if ":" in line:
                    k, v = line.split(":", 1)
                    fm[k.strip()] = v.strip()
        body = text.split("---", 2)[-1] if text.startswith("---") else text
        notes[fn[:-3]] = {
            "rel": rel, "folder": folder, "mtime": mtime,
            "status": fm.get("status", ""), "type": fm.get("type", ""),
            "links": {m.group(1).strip().split("/")[-1] for m in WIKILINK.finditer(text)},
            "snippet": " ".join(body.split())[:200],
        }

mocs = {n for n, m in notes.items() if m["folder"] == "MOCs"}
inbound = {n: 0 for n in notes}
dead = []  # (note, missing target)
for name, m in notes.items():
    for t in m["links"]:
        if t in notes:
            inbound[t] += 1
        elif name != "CLAUDE" and not m["rel"].endswith("README.md"):
            dead.append((name, t))

# orphans: filed notes (Areas/Resources/root) that violate golden rule #1 —
# no outgoing link to any MOC. READMEs/CLAUDE.md are plumbing, not notes.
orphans = [
    n for n, m in notes.items()
    if m["folder"] in ("Areas", "Resources", "root")
    and not (m["links"] & mocs)
    and n not in ("CLAUDE", "Home", "README", "Gardener Report")
]
stale = [
    n for n, m in notes.items()
    if m["status"] in ("inbox", "active") and m["folder"] in ("Areas", "Resources", "_inbox")
    and (now - m["mtime"]) > STALE_DAYS * 86400
]

# MiniMax pass: suggest a MOC for each orphan (skipped without the OpenRouter key)
suggestions = {}
key = os.environ.get("OPENAI_API_KEY")
if key and orphans:
    try:
        payload = {
            "model": os.environ.get("OPENAI_MODEL", "minimax/minimax-m3"),
            "temperature": 0.2,
            "messages": [
                {"role": "system", "content":
                 "You organise an Obsidian vault. Given orphan notes and the list of "
                 "MOCs (hubs), pick the single best MOC for each note. Reply with ONLY "
                 "a JSON object mapping note name to MOC name (must be from the list)."},
                {"role": "user", "content": json.dumps({
                    "mocs": sorted(mocs),
                    "orphans": {n: notes[n]["snippet"] for n in orphans[:20]},
                })},
            ],
        }
        req = urllib.request.Request(
            os.environ.get("OPENAI_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/")
            + "/chat/completions",
            data=json.dumps(payload).encode(),
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            content = json.load(resp)["choices"][0]["message"]["content"]
        content = re.sub(r"^```(json)?|```$", "", content.strip(), flags=re.M)
        suggestions = {k: v for k, v in json.loads(content).items() if v in mocs}
    except Exception as e:  # suggestions are optional — never fail the report
        suggestions = {"_error": str(e)}

today = datetime.date.today().isoformat()
lines = [
    "---", "type: note", "status: active", "tags: [gardener, maintenance]",
    f"created: {today}", "agent: huginn", "---", "",
    "# Gardener Report", "",
    f"Weekly vault hygiene sweep ({today}) — {len(notes)} notes, {len(mocs)} MOCs.",
    "",
]
err = suggestions.pop("_error", None)
if orphans:
    lines += [f"## Orphan notes ({len(orphans)}) — no MOC link", ""]
    for n in sorted(orphans):
        hint = f" → consider [[{suggestions[n]}]]" if n in suggestions else ""
        lines.append(f"- [[{n}]] ({notes[n]['folder']}){hint}")
    lines.append("")
if dead:
    lines += [f"## Dead wikilinks ({len(dead)})", ""]
    lines += [f"- [[{src}]] links to missing `{t}`" for src, t in sorted(set(dead))[:30]] + [""]
if stale:
    lines += [f"## Stale notes ({len(stale)}) — status inbox/active, untouched > {STALE_DAYS}d", ""]
    lines += [f"- [[{n}]] (status: {notes[n]['status']})" for n in sorted(stale)] + [""]
if not (orphans or dead or stale):
    lines += ["All clean: every note is MOC-linked, no dead links, nothing stale. 🌱", ""]
if err:
    lines += [f"> [!note] MOC suggestions unavailable this week ({err[:120]})", ""]
lines += ["See also: [[Home MOC]]", ""]

with open(os.path.join(VAULT, "Resources", "Gardener Report.md"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))
print(f"gardener: {len(orphans)} orphans, {len(set(dead))} dead links, {len(stale)} stale "
      f"({len(suggestions)} MOC suggestions) -> Resources/Gardener Report.md")
