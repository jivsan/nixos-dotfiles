# muninn — the agentic OS

An "agentic OS" whose memory lives in an **Obsidian vault** (`muninn`) on the homelab.
Humans and agents (Claude Code, headless) read and write the same plain-markdown notes;
wikilinks between notes form a knowledge graph. Everything runs **server-side on
`heimdall`** — the desktop (`mjolnir`) is just a consumer.

- **Vault (memory):** `muninn` — markdown on `odyn` (TrueNAS) NFS.
- **Agents (mind):** `huginn` — Claude Code on timers, filing/summarising/graphing.
- **Graph:** [Graphify](https://github.com/safishamsi/graphify) turns the config repo into a
  queryable knowledge graph; a live 3D "brain" renders it.

## Mental model

```
        YOU
         ├─ obsidian.oryxserver.org   ← read/write notes like a human (Obsidian in the browser)
         ├─ brain.oryxserver.org      ← watch the live 3D knowledge graph
         └─ claude (mjolnir terminal)  ← capture + ask, wired to the graph via MCP
                       │
   ────────────────────────────────────────────────────────────────
   heimdall (server) — the OS runs here
     • linuxserver/obsidian container (KasmVNC) + the muninn vault (odyn NFS)
     • huginn agents (systemd timers)         • Graphify + graphify-mcp
     • the "brain" (nginx + 30s graph builder)
   odyn (TrueNAS, 10.0.20.6) — vault dataset vault/obsidian, ZFS snapshots
```

**The one idea:** the vault is the OS; everyone edits the same files. You drop rough notes
in `_inbox/`, an agent turns them into titled, frontmattered, linked notes, and the graph
grows.

## Daily cheat-sheet

| I want to… | Do this |
|---|---|
| 💭 **Capture a thought** | `capture "rough idea..."` (mjolnir) → huginn files & links it |
| 🗣️ **Ask about my config / knowledge** | open a new `claude`, ask *"what connects traefik to acme?"* — it queries the graph via the `graphify-dotfiles` MCP |
| 📖 **Browse notes in the terminal** | Claude Code can read `~/muninn/` directly (NFS mount) |
| 🖥️ **Read/write like a human** | <https://obsidian.oryxserver.org> — the Home note is the dashboard |
| 🧠 **Watch it think** | <https://brain.oryxserver.org> — live 3D graph (hard-refresh after deploys) |

Both web apps are gated by Traefik's `lan-only` middleware (LAN + Tailscale) plus the
KasmVNC login.

## How you interact (the loop)

1. **Capture** — `capture "..."` writes `~/muninn/_inbox/capture-<ts>.md` and nudges huginn.
   (Or write anywhere in the vault directly; `_inbox/` is the "let the OS sort it" lane.)
2. **File** — `huginn-inbox-sweep` gives it a title + frontmatter, wikilinks it to a MOC in
   `MOCs/`, and moves it into `Areas/` or `Resources/`.
3. **Digest** — nightly, `huginn-daily-digest` appends a summary to `journal/<date>.md`.
4. **Graph** — weekly, `huginn-graphify-repo` rebuilds the code knowledge graph; the brain
   builder merges it with the vault wikilinks every 30s.

## Vault layout & note conventions

The vault root `CLAUDE.md` is the source of truth for agents. In short:

- `_inbox/` — capture queue · `journal/` — daily notes · `MOCs/` — hub notes (the graph
  backbone) · `Areas/`, `Resources/` — filed notes · `_templates/` — Templater templates ·
  `agents/logs/` — agent run logs · `graphify-out/` — generated graph.
- **Every note wikilinks to at least one MOC.** Frontmatter: `type, status, tags, created,
  agent`.
- Plugins: Dataview, Templater, Homepage. Theme: Tokyo Night + pink/cyan graph colours.

## Admin & operations

Run agents on demand (on `heimdall`); otherwise they run on their timers:

```bash
sudo systemctl start huginn-inbox-sweep.service     # file the _inbox now
sudo systemctl start huginn-daily-digest.service    # write today's journal digest
sudo systemctl start huginn-graphify.service        # rebuild the VAULT semantic graph
sudo systemctl start huginn-graphify-repo.service   # rebuild the DOTFILES code graph (MCP + brain)
systemctl list-timers 'huginn*' 'muninn*'           # when does each run next?
journalctl -u huginn-inbox-sweep -n 40              # what did it do?
```

Schedules: inbox-sweep 08/10/12/14/16/18/20 at :15 · daily-digest 23:00 · vault graphify
23:30 · repo graphify Sun 04:00 · brain builder every 30s.

### Model / cost

Everything the OS runs is **Claude Sonnet 4.6**. Change the single `model` variable at the
top of `hosts/heimdall/modules/system/huginn.nix` (e.g. `claude-haiku-4-5-20251001` for
cheaper, `claude-opus-4-8` for max reasoning), then rebuild. Your interactive terminal
Claude is separate — set it with `/model`.

### Auth / secrets (out of git)

- `heimdall:/var/lib/secrets/claude-code.env` → `ANTHROPIC_API_KEY=...` (drives the agents
  **and** Graphify's markdown extraction).
- `heimdall:/var/lib/secrets/obsidian.env` → `CUSTOM_USER` / `PASSWORD` for the KasmVNC login.
- `heimdall:/var/lib/secrets/cloudflare-dns-token` → wildcard TLS (existing).

## Where it lives (module map)

| Piece | File |
|---|---|
| Obsidian container + vault NFS mount | `hosts/heimdall/modules/system/obsidian.nix` |
| huginn agents + Graphify jobs | `hosts/heimdall/modules/system/huginn.nix` |
| the brain (nginx + builder) | `hosts/heimdall/modules/system/brain.nix` |
| brain builder + web app | `hosts/heimdall/muninn/brain/{build-graph.py,index.html}` |
| Traefik routers (`obsidian`, `brain`) | `hosts/heimdall/modules/system/traefik.nix` |
| vault bootstrap (folders, plugins, theme) | `hosts/heimdall/muninn/bootstrap.sh` |
| mjolnir `~/muninn` mount + `capture` | `modules/system/muninn.nix` |

**Key hosts/paths:** heimdall `10.0.20.17` · odyn `10.0.20.6` · vault export
`odyn:/mnt/vault/obsidian` → `heimdall:/mnt/nas/obsidian` and `mjolnir:~/muninn` · code graph
`heimdall:/var/lib/huginn/graphs/dotfiles/graph.json`.

## The terminal ↔ knowledge link (MCP)

`mjolnir` Claude Code has a user-scope MCP server `graphify-dotfiles` (in `~/.claude.json`)
that runs `graphify-mcp` on `heimdall` over SSH, serving the dotfiles graph:

```
ssh christina@10.0.20.17 env HOME=/var/lib/huginn \
  /var/lib/huginn/.local/bin/graphify-mcp /var/lib/huginn/graphs/dotfiles/graph.json
```

Tools it exposes: `query_graph`, `get_node`, `get_neighbors`, `get_community`, `god_nodes`,
`shortest_path`, `graph_stats`. Re-add with `claude mcp add graphify-dotfiles -s user -- …`
if you ever wipe `~/.claude.json`.
