#!/usr/bin/env python3
# muninn brain — build graph.json + activity.json for the live 3D view.
# Two sources merged:
#   • the vault's wikilinks (notes)  — fast, from markdown
#   • the Graphify code graph (repo) — from /var/lib/huginn/graphs/dotfiles/graph.json
# Code nodes are coloured by Graphify "community" so the graph looks like a brain.
import os, re, json, time, glob, colorsys

VAULT = "/mnt/nas/obsidian/muninn"
WWW = "/var/lib/muninn-brain/www"
REPO_GRAPH = "/var/lib/huginn/graphs/dotfiles/graph.json"
SKIP = {".obsidian", "_templates", "agents", "graphify-out", ".git", "node_modules"}
WIKILINK = re.compile(r"\[\[([^\]|#]+)")

FOLDER_COLOR = {
    "MOCs": "#ff4fa3", "root": "#ff8ac4", "_inbox": "#2de2e6",
    "journal": "#39d0ff", "Resources": "#8a7dff", "Areas": "#5ad1a0",
}


def community_color(c):
    # deterministic vivid colour per Graphify community index (golden-ratio hue)
    try:
        h = (int(c) * 0.6180339887) % 1.0
    except (TypeError, ValueError):
        h = 0.58
    r, g, b = colorsys.hls_to_rgb(h, 0.62, 0.72)
    return "#%02x%02x%02x" % (int(r * 255), int(g * 255), int(b * 255))


now = time.time()
nodes, links = [], []

# ── vault notes (wikilinks) ──
notes = {}
for root, dirs, files in os.walk(VAULT):
    dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".")]
    for fn in files:
        if not fn.endswith(".md"):
            continue
        rel = os.path.relpath(os.path.join(root, fn), VAULT)
        folder = rel.split(os.sep)[0] if os.sep in rel else "root"
        try:
            mt = os.path.getmtime(os.path.join(VAULT, rel))
        except OSError:
            mt = now
        notes[fn[:-3]] = {"rel": rel, "folder": folder, "mtime": mt}

deg = {n: 0 for n in notes}
for name, meta in notes.items():
    try:
        with open(os.path.join(VAULT, meta["rel"]), encoding="utf-8", errors="ignore") as fh:
            text = fh.read()
    except OSError:
        text = ""
    for m in WIKILINK.finditer(text):
        t = m.group(1).strip().split("/")[-1]
        if t in notes and t != name:
            links.append({"source": name, "target": t})
            deg[name] += 1
            deg[t] += 1
for name, meta in notes.items():
    nodes.append({
        "id": name, "label": name, "source": "note",
        "color": FOLDER_COLOR.get(meta["folder"], "#7f8cff"),
        "val": 2 + deg.get(name, 0),
        "recent": (now - meta["mtime"]) < 86400,
    })

# ── code graph (Graphify, repo) ──
code_nodes = 0
if os.path.exists(REPO_GRAPH):
    try:
        with open(REPO_GRAPH, encoding="utf-8") as fh:
            g = json.load(fh)
        cdeg = {}
        for e in g.get("links", g.get("edges", [])):
            s, t = e.get("source"), e.get("target")
            if s is None or t is None:
                continue
            cdeg[s] = cdeg.get(s, 0) + 1
            cdeg[t] = cdeg.get(t, 0) + 1
            links.append({"source": "c:" + str(s), "target": "c:" + str(t)})
        for n in g.get("nodes", []):
            nid = n.get("id")
            if nid is None:
                continue
            nodes.append({
                "id": "c:" + str(nid),
                "label": n.get("norm_label") or n.get("label") or str(nid),
                "source": "code",
                "color": community_color(n.get("community")),
                "val": 1 + cdeg.get(nid, 0),
                "recent": False,
            })
            code_nodes += 1
    except (ValueError, OSError):
        pass

os.makedirs(WWW, exist_ok=True)
with open(os.path.join(WWW, "graph.json"), "w") as fh:
    json.dump({"nodes": nodes, "links": links, "generated": int(now)}, fh)

# ── activity feed ──
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
    json.dump({
        "generated": int(now),
        "counts": {"notes": len(notes), "code": code_nodes, "links": len(links)},
        "log": log[-40:],
        "recent": [{"id": n, "folder": m["folder"], "mtime": int(m["mtime"])} for n, m in recent],
    }, fh)

print(f"muninn-brain: {len(notes)} notes + {code_nodes} code nodes, {len(links)} links")
