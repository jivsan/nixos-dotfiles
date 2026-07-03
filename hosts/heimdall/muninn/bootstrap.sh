#!/usr/bin/env bash
# ── muninn vault bootstrap (Phase 4 + frontend + graphify visuals) ───────────
# Run ON heimdall, as christina (uid 1000). Seeds the vault, installs the
# Obsidian plugins/theme, and wires the graph colours + Home dashboard.
#
#   bash hosts/heimdall/muninn/bootstrap.sh
#
# - Idempotent for NOTES (never overwrites your edits).
# - REWRITES the .obsidian config (theme/plugins/graph) — it's the setup step;
#   re-running resets those choices back to these defaults.
set -euo pipefail

VAULT="/mnt/nas/obsidian/muninn"
OBS="$VAULT/.obsidian"

[ -d "$VAULT" ] || { echo "!! $VAULT not found. Create the 'muninn' vault in Obsidian (open /vaults) first."; exit 1; }

echo ">> stopping the obsidian container (avoid .obsidian clobber)"
sudo systemctl stop podman-obsidian || true

echo ">> folder skeleton"
mkdir -p "$VAULT"/{_inbox,journal,MOCs,_templates,Areas,Resources,agents/logs}
mkdir -p "$OBS"/{plugins,snippets,themes}

# ensure <relpath> : write stdin to the file ONLY if it doesn't exist yet
ensure() {
  local f="$VAULT/$1"
  if [ -e "$f" ]; then echo "   = keep $1"; cat >/dev/null; else
    mkdir -p "$(dirname "$f")"; cat >"$f"; echo "   + $1"; fi
}
# write <relpath under .obsidian> : always overwrite (config)
obs() { local f="$OBS/$1"; mkdir -p "$(dirname "$f")"; cat >"$f"; echo "   ~ .obsidian/$1"; }

echo ">> seeding notes"

ensure "CLAUDE.md" <<'EOF'
# muninn — vault conventions (agents: read me first)

This vault is the shared memory of an **agentic OS**. Humans use the hosted
Obsidian app; agents (**huginn** — Claude Code headless on heimdall) read and
write these markdown files directly. Keep the graph meaningful.

## Golden rules for agents
1. **Every note you create links to at least one MOC** in `MOCs/` (a hub). A note
   with no links is dust — always connect it.
2. **Frontmatter on every note:**
   ```
   ---
   type: note | journal | reference | task | moc
   status: inbox | active | done | archive
   tags: []
   created: YYYY-MM-DD
   agent: <who wrote it — huginn, or a person>
   ---
   ```
3. **Do not touch** `.obsidian/`, `_templates/`, `agents/`, `graphify-out/`, or `Home.md`.
4. Prefer editing to duplicating. Keep notes factual; never invent.

## Folders
- `_inbox/` — capture queue. Drop rough notes; huginn's inbox sweep files them.
- `journal/` — daily notes `YYYY-MM-DD.md`; huginn appends a nightly digest.
- `MOCs/` — Maps of Content (hubs). The backbone of the graph.
- `Areas/`, `Resources/` — filed notes by domain.
- `_templates/` — Templater templates.
- `agents/` — agent logs (`agents/logs/`).
- `graphify-out/` — Graphify's generated knowledge graph (graph.html / graph.json).

## Agents (huginn)
- **Inbox sweep** (daytime): title, frontmatter, links, and file `_inbox/` notes.
- **Nightly digest** (23:00): summarise the day into today's journal note.
- **Graphify** (23:30): rebuild the queryable knowledge graph of the whole vault.

## Frontend
`[[Home]]` is the dashboard (Dataview) — the OS home screen.
EOF

ensure "Home.md" <<'EOF'
---
type: moc
status: active
tags: [home, dashboard]
created: 2026-07-03
agent: huginn
---
# 🏠 muninn — home

> The agentic OS dashboard. Map: [[Home MOC]] · Agents: [[Agents MOC]]

## 📥 Inbox
```dataview
LIST FROM "_inbox" WHERE file.name != "README" SORT file.mtime DESC
```

## 🗺️ Maps of Content
```dataview
LIST FROM "MOCs" SORT file.name ASC
```

## 🕒 Recently updated
```dataview
TABLE status, file.folder AS where, file.mtime AS updated
FROM "" WHERE file.name != "Home" SORT file.mtime DESC LIMIT 12
```

## 🤖 huginn — latest journals
```dataview
LIST FROM "journal" WHERE file.name != "README" SORT file.name DESC LIMIT 5
```
EOF

ensure "MOCs/Home MOC.md" <<'EOF'
---
type: moc
tags: [moc]
created: 2026-07-03
agent: huginn
---
# Home MOC
The top hub — everything links back here eventually.

- [[Home]] — dashboard
- [[Agents MOC]]
- [[Knowledge MOC]]
EOF

ensure "MOCs/Agents MOC.md" <<'EOF'
---
type: moc
tags: [moc, agents]
created: 2026-07-03
agent: huginn
---
# Agents MOC
The huginn agent layer running on heimdall.

- Inbox sweep — files `_inbox/` notes.
- Nightly digest — summarises the day into `journal/`.
- Graphify — rebuilds the knowledge graph.

Logs live in `agents/logs/`. Up: [[Home MOC]]
EOF

ensure "MOCs/Knowledge MOC.md" <<'EOF'
---
type: moc
tags: [moc]
created: 2026-07-03
agent: huginn
---
# Knowledge MOC
Hub for filed knowledge (Areas / Resources). New reference notes link here.

Up: [[Home MOC]]
EOF

ensure "_inbox/README.md" <<'EOF'
---
type: note
status: active
tags: [meta]
created: 2026-07-03
agent: huginn
---
# _inbox
Drop rough captures here as `*.md`. huginn's inbox sweep titles them, adds
frontmatter, links them to a MOC, and files them into Areas/ or Resources/.

Up: [[Home MOC]]
EOF

ensure "journal/README.md" <<'EOF'
---
type: note
status: active
tags: [meta]
created: 2026-07-03
agent: huginn
---
# journal
Daily notes `YYYY-MM-DD.md`. huginn appends a `## huginn digest` each night.

Up: [[Home MOC]]
EOF

ensure "_templates/note.md" <<'EOF'
---
type: note
status: active
tags: []
created: <% tp.date.now("YYYY-MM-DD") %>
agent: christina
---
# <% tp.file.title %>


Related: [[Home MOC]]
EOF

ensure "_templates/daily.md" <<'EOF'
---
type: journal
created: <% tp.date.now("YYYY-MM-DD") %>
agent: christina
---
# <% tp.date.now("YYYY-MM-DD") %>

## Notes


## huginn digest
_(huginn appends here nightly)_

[[Home MOC]]
EOF

echo ">> installing community plugins (file-based, NFS-safe)"
plugin() { # <id> <owner/repo>
  local id="$1" repo="$2" d="$OBS/plugins/$1"
  mkdir -p "$d"
  echo "   plugin $id ($repo)"
  curl -fsSL "https://github.com/$repo/releases/latest/download/main.js"       -o "$d/main.js"
  curl -fsSL "https://github.com/$repo/releases/latest/download/manifest.json" -o "$d/manifest.json"
  curl -fsSL "https://github.com/$repo/releases/latest/download/styles.css"    -o "$d/styles.css" || true
}
plugin dataview           blacksmithgu/obsidian-dataview
plugin templater-obsidian SilentVoid13/Templater
plugin homepage           mirnovov/obsidian-homepage

echo ">> installing Tokyo Night theme"
TN="$OBS/themes/Tokyo Night"; mkdir -p "$TN"
curl -fsSL "https://raw.githubusercontent.com/tcmmichaelb139/obsidian-tokyonight/main/theme.css"     -o "$TN/theme.css"
curl -fsSL "https://raw.githubusercontent.com/tcmmichaelb139/obsidian-tokyonight/main/manifest.json" -o "$TN/manifest.json"

echo ">> writing .obsidian config (theme / plugins / graph / homepage)"

obs "community-plugins.json" <<'EOF'
[
  "dataview",
  "templater-obsidian",
  "homepage"
]
EOF

obs "appearance.json" <<'EOF'
{
  "accentColor": "#ff4fa3",
  "theme": "obsidian",
  "cssTheme": "Tokyo Night",
  "enabledCssSnippets": [ "graph-accents" ],
  "baseFontSize": 16
}
EOF

# Graph colour groups — house accents: pink #ff4fa3 (16732067), cyan #2de2e6 (3007206)
obs "graph.json" <<'EOF'
{
  "collapse-filter": true,
  "search": "",
  "showTags": false,
  "showAttachments": false,
  "hideUnresolved": false,
  "showOrphans": true,
  "collapse-color-groups": false,
  "colorGroups": [
    { "query": "path:MOCs",  "color": { "a": 1, "rgb": 16732067 } },
    { "query": "tag:#moc",   "color": { "a": 1, "rgb": 16732067 } },
    { "query": "path:_inbox","color": { "a": 1, "rgb": 3007206 } },
    { "query": "path:journal","color": { "a": 1, "rgb": 3007206 } }
  ],
  "collapse-display": false,
  "showArrow": true,
  "textFadeMultiplier": 0,
  "nodeSizeMultiplier": 1.1,
  "lineSizeMultiplier": 1,
  "collapse-forces": true,
  "centerStrength": 0.5,
  "repelStrength": 12,
  "linkStrength": 1,
  "linkDistance": 90,
  "scale": 1
}
EOF

obs "snippets/graph-accents.css" <<'EOF'
/* muninn house accents (#ff4fa3 pink / #2de2e6 cyan) */
.theme-dark {
  --accent-h: 328; --accent-s: 100%; --accent-l: 65%;   /* pink UI accent */
  --graph-line: #2de2e644;
}
EOF

obs "plugins/homepage/data.json" <<'EOF'
{
  "version": "4.4.4",
  "homepages": {
    "Main Homepage": {
      "value": "Home",
      "kind": "File",
      "openOnStartup": true,
      "openMode": "Replace all open notes",
      "manualOpenMode": "Replace all open notes",
      "view": "Default view",
      "revertView": true,
      "openWhenEmpty": false,
      "refreshDataview": true,
      "autoCreate": false,
      "pin": false,
      "commands": [],
      "alwaysApply": false
    }
  },
  "separateMobile": false
}
EOF

echo ">> starting the obsidian container"
sudo systemctl start podman-obsidian

cat <<'DONE'

✔ muninn bootstrapped.
  Open https://obsidian.oryxserver.org
  - If prompted, click "Turn on community plugins" (Dataview / Templater / Homepage).
  - The Home dashboard should open automatically and render its Dataview blocks.
  - Graph view: MOCs = pink, inbox/journal = cyan.
DONE
