#!/usr/bin/env python3
# muninn unlinked-mentions — weekly weave check. Fully offline: finds notes that
# mention another note's title as plain text without wikilinking it, so the
# graph keeps gaining edges. Writes "Resources/Reports/unlinked-mentions-<date>.md"
# and prints a one-line summary.
import argparse, datetime, os, re

SKIP = {".obsidian", ".git", ".trash", "_templates", "agents", "graphify-out", "_inbox"}
WIKILINK = re.compile(r"\[\[([^\]|#]+)")
MIN_TITLE = 4          # shorter titles ("Home", "TODO") match prose too often
MAX_REPORT = 50        # cap the report; this is a nudge, not a chore list

p = argparse.ArgumentParser()
p.add_argument("--vault", default="/mnt/nas/obsidian/muninn")
VAULT = p.parse_args().vault

notes = {}  # name -> {rel, body_lower, links}
for root, dirs, files in os.walk(VAULT):
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
        body = text.split("---", 2)[-1] if text.startswith("---") else text
        notes[fn[:-3]] = {
            "rel": os.path.relpath(path, VAULT),
            "body": body.lower(),
            "links": {m.group(1).strip().split("/")[-1] for m in WIKILINK.finditer(text)},
        }

# title -> [(mentioning note, count)]  (only where the mentioner does not link it)
mentions = {}
titles = [t for t in notes if len(t) >= MIN_TITLE and not t.startswith(("alert-", "health-"))]
for title in titles:
    tl = title.lower()
    wordy = re.compile(r"(?<![\w/])" + re.escape(tl) + r"(?![\w])")
    hits = []
    for name, m in notes.items():
        if name == title or title in m["links"] or tl not in m["body"]:
            continue
        n = len(wordy.findall(m["body"]))
        if n:
            hits.append((name, n))
    if hits:
        mentions[title] = sorted(hits, key=lambda h: -h[1])

ranked = sorted(mentions.items(), key=lambda kv: -sum(n for _, n in kv[1]))
total = sum(n for _, hits in ranked for _, n in hits)

today = datetime.date.today().isoformat()
os.makedirs(os.path.join(VAULT, "Resources", "Reports"), exist_ok=True)
report = os.path.join(VAULT, "Resources", "Reports", f"unlinked-mentions-{today}.md")
with open(report, "w", encoding="utf-8") as fh:
    fh.write(f"---\ntype: report\nagent: huginn\ncreated: {datetime.datetime.now().isoformat(timespec='seconds')}\n---\n\n")
    fh.write(f"# unlinked mentions — {today}\n\n")
    fh.write(f"{total} plain-text mentions across {len(ranked)} notes could become wikilinks. "
             "Weaving them in makes the neural graph stronger.\n\n")
    if not ranked:
        fh.write("Nothing missing — the vault is fully woven. ✨\n\n")
    for title, hits in ranked[:MAX_REPORT]:
        fh.write(f"## [[{title}]]\n")
        for name, n in hits[:6]:
            fh.write(f"- mentioned {n}× in [[{name}]]\n")
        fh.write("\n")
    fh.write("[[MOCs/Agents MOC]]\n")

print(f"unlinked-mentions: {total} candidate mentions over {len(ranked)} notes → {os.path.basename(report)}")
