#!/usr/bin/env python3
# muninn brain — build graph.json + activity.json for the live dashboard.
# Two sources merged into the 3D graph:
#   • the vault's wikilinks (notes)  — fast, from markdown
#   • the Graphify code graph (repo) — from /var/lib/huginn/graphs/dotfiles/graph.json
# Code nodes are coloured by Graphify "community" so the graph looks like a brain.
# activity.json additionally carries the at-a-glance OS state: huginn agent
# health (systemd timers/services), the inbox queue, today's digest, the vault
# git log (what huginn did), and hygiene counts.
import os, re, json, time, glob, colorsys, subprocess

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
                log.append({"job": job, "line": line, "mtime": int(os.path.getmtime(logf))})
    except OSError:
        pass
log.sort(key=lambda x: x["mtime"])
recent = sorted(notes.items(), key=lambda kv: kv[1]["mtime"], reverse=True)[:10]


# ── huginn agent health (systemd, unprivileged systemctl show) ──
def sysprop(unit, *props):
    try:
        out = subprocess.run(
            ["systemctl", "show", "--timestamp=unix", unit, "--"]
            + [f"-p{p}" for p in props],
            capture_output=True, text=True, timeout=5).stdout
        return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    except Exception:
        return {}


def epoch(v):
    # --timestamp=unix prints "@1751912228"; absent/n-a → 0
    return int(v[1:]) if v.startswith("@") and v[1:].isdigit() else 0


AGENTS = [
    ("inbox-sweep", "huginn-inbox-sweep"),
    ("daily-digest", "huginn-daily-digest"),
    ("graph:vault", "huginn-graphify-vault"),
    ("graph:repo", "huginn-graphify-repo"),
    ("gardener", "huginn-gardener"),
    ("brain-build", "muninn-brain-build"),
]
agents = []
for label, unit in AGENTS:
    t = sysprop(unit + ".timer", "LastTriggerUSec", "NextElapseUSecRealtime")
    s = sysprop(unit + ".service", "Result", "ExecMainExitTimestamp", "ActiveState")
    agents.append({
        "name": label,
        "last": epoch(t.get("LastTriggerUSec", "")) or epoch(s.get("ExecMainExitTimestamp", "")),
        "next": epoch(t.get("NextElapseUSecRealtime", "")),
        "result": s.get("Result", "unknown"),
        "active": s.get("ActiveState", "") == "activating",
    })
services = []
for label, unit in [("obsidian", "podman-obsidian.service"), ("nginx", "nginx.service")]:
    services.append({"name": label,
                     "ok": sysprop(unit, "ActiveState").get("ActiveState") == "active"})

# ── inbox queue ──
inbox = []
for f in sorted(glob.glob(os.path.join(VAULT, "_inbox", "*.md"))):
    if os.path.basename(f) == "README.md":
        continue
    inbox.append({"name": os.path.basename(f)[:-3], "mtime": int(os.path.getmtime(f))})

# ── today's (or latest) digest section from the journal ──
digest, digest_day = "", ""
jfiles = sorted(glob.glob(os.path.join(VAULT, "journal", "20*.md")))
if jfiles:
    digest_day = os.path.basename(jfiles[-1])[:-3]
    try:
        with open(jfiles[-1], encoding="utf-8", errors="ignore") as fh:
            txt = fh.read()
        if "## huginn digest" in txt:
            digest = txt.split("## huginn digest", 1)[1]
            digest = digest.split("\n", 1)[1] if "\n" in digest else ""
            digest = digest.replace("[[Home MOC]]", "").strip()[:1200]
    except OSError:
        pass

# ── vault git log — the audit trail of what huginn did ──
gitlog = []
try:
    out = subprocess.run(
        ["git", "-C", VAULT, "log", "-n", "12", "--format=%at%x09%s"],
        capture_output=True, text=True, timeout=5).stdout
    for line in out.splitlines():
        ts, _, subj = line.partition("\t")
        gitlog.append({"t": int(ts), "msg": subj})
except Exception:
    pass

# ── hygiene: orphans = filed notes with no MOC wikilink (golden rule #1) ──
moc_names = {n for n, m in notes.items() if m["folder"] == "MOCs"}
orphans = 0
for name, meta in notes.items():
    if meta["folder"] not in ("Areas", "Resources", "root"):
        continue
    if name in ("CLAUDE", "Home", "README", "Gardener Report"):
        continue
    try:
        with open(os.path.join(VAULT, meta["rel"]), encoding="utf-8", errors="ignore") as fh:
            targets = {m.group(1).strip().split("/")[-1] for m in WIKILINK.finditer(fh.read())}
    except OSError:
        continue
    if not (targets & moc_names):
        orphans += 1

with open(os.path.join(WWW, "activity.json"), "w") as fh:
    json.dump({
        "generated": int(now),
        "counts": {"notes": len(notes), "code": code_nodes, "links": len(links),
                   "mocs": len(moc_names), "inbox": len(inbox), "orphans": orphans},
        "agents": agents,
        "services": services,
        "inbox": inbox[:12],
        "digest": {"day": digest_day, "text": digest},
        "gitlog": gitlog,
        "log": log[-40:],
        "recent": [{"id": n, "folder": m["folder"], "mtime": int(m["mtime"])} for n, m in recent],
    }, fh)

print(f"muninn-brain: {len(notes)} notes + {code_nodes} code nodes, {len(links)} links, "
      f"{len(inbox)} inbox, {orphans} orphans")
