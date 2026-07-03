#!/usr/bin/env python3
# muninn brain — turn the vault's wikilinks into graph.json + activity.json.
# Fast, no LLM: scans markdown, extracts [[links]], emits a force-graph dataset
# and a live agent-activity feed. Runs every 60s via systemd (see brain.nix).
import os, re, json, time, glob

VAULT = "/mnt/nas/obsidian/muninn"
WWW = "/var/lib/muninn-brain/www"
SKIP = {".obsidian", "_templates", "agents", "graphify-out", ".git", "node_modules"}
WIKILINK = re.compile(r"\[\[([^\]|#]+)")  # [[Note]], [[Note|alias]], [[Note#heading]]

now = time.time()

# 1. collect notes
notes = {}  # name -> {rel, folder, mtime}
for root, dirs, files in os.walk(VAULT):
    dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".")]
    for fn in files:
        if not fn.endswith(".md"):
            continue
        p = os.path.join(root, fn)
        rel = os.path.relpath(p, VAULT)
        folder = rel.split(os.sep)[0] if os.sep in rel else "root"
        try:
            mt = os.path.getmtime(p)
        except OSError:
            mt = now
        notes[fn[:-3]] = {"rel": rel, "folder": folder, "mtime": mt}

# 2. build links from wikilinks
degree = {n: 0 for n in notes}
links = []
for name, meta in notes.items():
    try:
        with open(os.path.join(VAULT, meta["rel"]), encoding="utf-8", errors="ignore") as fh:
            text = fh.read()
    except OSError:
        text = ""
    targets = set()
    for m in WIKILINK.finditer(text):
        t = m.group(1).strip().split("/")[-1]
        if t in notes and t != name:
            targets.add(t)
    for t in targets:
        links.append({"source": name, "target": t})
        degree[name] += 1
        degree[t] += 1

# 3. nodes (val = size by degree; recent = touched in last 24h)
nodes = [
    {
        "id": name,
        "folder": meta["folder"],
        "val": 1 + degree.get(name, 0),
        "recent": (now - meta["mtime"]) < 86400,
        "mtime": int(meta["mtime"]),
    }
    for name, meta in notes.items()
]

os.makedirs(WWW, exist_ok=True)
with open(os.path.join(WWW, "graph.json"), "w") as fh:
    json.dump({"nodes": nodes, "links": links, "generated": int(now)}, fh)

# 4. activity feed — recent agent log lines + freshest notes
log = []
for logf in sorted(glob.glob(os.path.join(VAULT, "agents", "logs", "*.log"))):
    job = os.path.basename(logf)[:-4]
    try:
        with open(logf, encoding="utf-8", errors="ignore") as fh:
            for line in fh.read().splitlines()[-8:]:
                log.append({"job": job, "line": line})
    except OSError:
        pass

recent = sorted(notes.items(), key=lambda kv: kv[1]["mtime"], reverse=True)[:10]
with open(os.path.join(WWW, "activity.json"), "w") as fh:
    json.dump(
        {
            "generated": int(now),
            "counts": {"notes": len(nodes), "links": len(links)},
            "log": log[-40:],
            "recent": [
                {"id": n, "folder": m["folder"], "mtime": int(m["mtime"])}
                for n, m in recent
            ],
        },
        fh,
    )

print(f"muninn-brain: {len(nodes)} nodes, {len(links)} links")
