# muninn — the agentic OS

Muninn is the Obsidian vault on odyn, mounted at `/mnt/nas/obsidian/muninn`
on heimdall. The dashboard, bridge, indexer and huginn automations run on
heimdall. Jev routes requests; MiniMax answers questions; Hermes or Codex does
tool work. The desktop consumes these services.

## Request and memory loop

1. Typed or spoken requests enter `POST /bridge/talk`. Local Whisper and Kokoro
   on mimir provide transcription and speech.
2. **Jev** chooses a tier, command/skill, and worker from bounded choices. It sees
   which workers are configured. An explicit `target: hermes` or `target: codex`
   overrides dispatch while preserving Jev's classification in the job record.
3. **Commands** open views, search, capture notes, or start an allowlisted systemd
   skill. **Answers** use MiniMax with vault search and the config graph.
   **Agent work** goes to Hermes on hermod or Codex on heimdall.
4. Before dispatch, the bridge saves the job and routing decision in
   `/var/lib/muninn-brain/jobs.db`. At most two agent jobs run concurrently;
   excess requests receive `busy: true` and can be retried later.
5. The bridge files each terminal response in `Resources/Reports/`, including
   frontmatter, request, route, worker, timestamps, status and result. MiniMax
   names, tags and places it: `Up:` is the MOC it is about and `Related:` links
   up to four existing notes on the same subject. Only names that exist are
   written. A failed run, or one MiniMax could not place, stays under the
   Agents MOC, and a report it could not name is `Agent report <date> <job-id>.md`.
   Agents are asked to include findings, source URLs and actual output paths.
   A remote worker without vault access returns its deliverable for the bridge
   to file. Agent-created files normally go in `Resources/Outputs/`.
6. Reports enter the existing index and graph. Substantive conversations go
   into `Resources/Talk logs/`; nightly digests summarize changed notes. While
   an answer is being made, MiniMax picks the notes the exchange is about and
   the entry links those as `related:`. If MiniMax did not answer, the notes
   retrieved for the answer are linked as `sources:` instead.

Jev uses `https://openrouter.ai/api/v1/systemone`, `typesafe/jev-1.13` and the
existing OpenRouter key. Invalid, unavailable or low-confidence decisions fall
back to local rules, with `jev_error` and `route.fallback_reason` exposed.
Confidence is checked separately for the tier and its relevant command, skill
or worker. `JEV_MIN_CONFIDENCE=0.5` is application policy, not an accuracy guarantee.
Configured-worker flags do not prove remote reachability.

When a job ends, the bridge commits the vault as `muninn-bridge` with the worker
and report name as the message, so what an agent changed is not swept into
huginn's next commit. If Claude fails on a session, usage or rate limit, the
job goes to Hermes or Codex instead and `route.executor_fallback` says why.

Hermes jobs use separate conversations. Codex retains its `workspace-write`
sandbox. On bridge restart, unfinished execution becomes failed and receives an
interruption report. Tool actions are never automatically replayed. If execution
finished but filing was pending, startup files the saved result. Report-write
errors fail the job and retain its response plus `report_error` in SQLite.
Inspect that record before retrying work.

## Capture and filing

`capture "rough thought"`, the dashboard, or `POST /api/inbox` creates an inbox
note. Huginn validates the model's JSON and files a titled, frontmattered note
into `Areas/` or `Resources/`, linked to an existing MOC. Full originals are
archived under `agents/inbox/archive/`; source notes are not deleted after a
truncated model request. Invalid output and concurrent edits cause a recorded
failure. Each nonempty sweep files a report in `Resources/Reports/`; failures
return nonzero to systemd. Inputs above 128,000 bytes remain in the
inbox for manual handling.

Jev decides where a note goes: it chooses the folder and the MOC from the
existing ones, reading each MOC's first line of prose as its description.
MiniMax writes the title, tags and body, and links up to four existing notes on
the same subject as `Related:` (names that do not exist are dropped). The
generated `TODO MOC` is never offered as a hub. A capture above 2,000 characters is
already a note: MiniMax only titles and tags it and its text is filed unchanged,
which is faster and cannot lose content. A written body that outgrows twice its
capture by more than 200 characters has been padded (a request carried out,
detail invented), so the capture's own words are filed instead. If Jev is below
`JEV_MIN_CONFIDENCE` on the MOC or the folder, MiniMax's choice is used for
that one and the report says `minimax (jev unsure: ...)`; nothing is parked. If
Jev is unreachable, MiniMax's folder and MOC are used and the report says so.
Each sweep that did something adds its lines to `agents/logs/inbox-sweep.log`.

A capture whose first line (after any frontmatter) starts with `todo:` or `jev:`
is a request, not a note. The sweep archives it and posts the rest to
`/bridge/talk`, so Jev routes it like anything said to the dashboard: an agent
job, an answer (written into the sweep report and the talk log) or a skill run.
If Jev reads it as something to capture or show, it is filed as an ordinary
note. A busy bridge leaves the capture in the inbox for the next sweep without
failing the unit; an unreachable bridge or a missing worker is a recorded
failure. Requests above 4,000 characters are refused. Anything that can write
to `_inbox/` can start agent work with these markers.

The vault's `CLAUDE.md` defines note conventions. `_inbox/` holds captures;
`Areas/` and `Resources/` hold organized knowledge; `MOCs/` holds hub notes;
`journal/` holds daily notes; `agents/` holds logs and archives. Templates and
Obsidian settings live in `_templates/` and `.obsidian/`.

## Search by meaning

Keyword search (SQLite FTS) finds exact names and error strings; it finds
nothing when a question shares no word with the note. So notes are also
searched by meaning.

- **Model:** Qwen3-Embedding-4B (8-bit GGUF, Apache 2.0) served by llama.cpp on
  mimir at `:8081` (`hosts/mimir/modules/system/embeddings.nix`), on CPU until
  the GPU is in. Measured there: a question about 0.3 s, a 4,000-character
  note about 25 s.
- **Index:** `muninn-embedder` on heimdall keeps one vector per note in
  `/var/lib/muninn-brain/embeddings.db`, re-embedding a note when it changes.
  Talk logs, sweep reports, alerts and the inbox are left out. A note is
  embedded by its title and first 8,000 characters (`MUNINN_EMBED_MAX_CHARS`).
  The first run takes about an hour. A different model name means every note is
  embedded again, since vectors of two models cannot be compared.
- **Answers:** the bridge merges the keyword ranking and the meaning ranking, so
  a note both agree on comes first. A note below `MUNINN_EMBED_MIN` (0.38)
  similarity is not counted as related.
- **Placement:** MiniMax chooses related notes from the 30 closest in meaning
  plus the 30 newest, instead of the newest 300 by title. The inbox sweep asks
  the bridge for them at `POST /bridge/similar {"text", "k"}`.
- **If mimir is down** the embedder waits, lookups return nothing and
  everything falls back to keyword search and the newest-notes list.
  `/bridge/health` reports `embedded`, the number of notes in the index.

## The dashboard's graph

`build-graph.py` rewrites `graph.json`, `notes.json` and `activity.json` only
when their content changed, so an unchanged graph keeps its `generated` stamp.
The page re-feeds the 3D graph only when neurons or synapses were added or
removed; an edited note refreshes the neurons in place. Feeding blocks the page
for about a second and restarts the layout, so it is never done for data the
graph already holds or while another view is shown. The resting particle on
every synapse is one instanced mesh rather than a mesh per synapse.

## API and operations

Dashboard: <https://brain.oryxserver.org>. Hosted Obsidian:
<https://obsidian.oryxserver.org>. Traefik restricts access to LAN/Tailscale.

```bash
curl -sS https://brain.oryxserver.org/bridge/talk \
  -H 'Content-Type: application/json' \
  -d '{"text":"Research my backup options and file a report","target":"auto"}'
curl -sS https://brain.oryxserver.org/bridge/jobs
curl -sS https://brain.oryxserver.org/bridge/jobs/JOB_ID
curl -sS https://brain.oryxserver.org/bridge/skills
curl -sS https://brain.oryxserver.org/bridge/health

# On heimdall:
sudo systemctl start huginn-inbox-sweep.service
sudo systemctl start huginn-daily-digest.service
sudo systemctl start huginn-graphify-vault.service
sudo systemctl start huginn-graphify-repo.service
systemctl list-timers 'huginn*' 'muninn*'
journalctl -u muninn-bridge -u huginn-inbox-sweep -n 60
```

`GET /bridge/jobs` returns the latest 50 records. Job states remain `running`,
`done` and `failed` for existing clients. Individual records include `route`,
`answer` and, when filed, the vault-relative `report` path. The existing
`/vault/<report-path>` reader serves its Markdown. History is retained until
an operator removes records; back up SQLite alongside vault snapshots.

Schedules: inbox on local changes, within about 20 seconds of a capture written
from another host, plus 08:15/14:15/20:15; digest 23:00; vault graph
23:30; repo graph Sunday 04:00; gardener Saturday 08:30; dead-link fixer Sunday
06:00; brain builder every 30 seconds. Some timers add a short randomized delay.
NFS writes from other clients never reach inotify, so `huginn-inbox-poll` lists
the inbox every 20 seconds and starts the sweep for captures it has not seen
(`/var/lib/huginn/inbox-seen`). A capture that failed stays seen and is retried
by the timer, by a manual run, or once it is edited.

The dead-link fixer reads the vault offline. It checks filed notes only:
journals, talk logs, reports and the inbox quote whatever a model said, and the
gardener still lists their dead links. A target that nearly matches an existing
title is reported as a link to fix; any other missing target gets a stub in
`Resources/` under the name it was linked by, so the link resolves.
`python3 dead-link-fixer.py --vault <path> --dry-run` prints the findings and
writes nothing. Neither it nor the gardener counts wikilink-shaped text in code
or links into `agents/`.

## Configuration and deployment

Secrets remain outside git:

- `/var/lib/secrets/graphify-openrouter.env`: `OPENAI_API_KEY`, optionally
  `OPENAI_BASE_URL` and `OPENAI_MODEL` (default `minimax/minimax-m3`). The
  inbox sweep loads only this file, so `JEV_*` overrides for filing and
  `MUNINN_BRIDGE_URL` (default `http://127.0.0.1:8093`) go here too.
- `/var/lib/secrets/muninn-bridge.env`: `HERMES_API_KEY`, matching hermod's
  `API_SERVER_KEY`. Optional bridge overrides: `JEV_API_KEY`, `JEV_URL`,
  `JEV_MODEL`, `JEV_MIN_CONFIDENCE`, `MUNINN_MAX_JOBS`, `MUNINN_JOBS_DB`,
  `MUNINN_HERMES_URL`. Native TypeSafe uses its key,
  `JEV_URL=https://api.typesafe.ai/v1/systemone` and `JEV_MODEL=jev-latest`.
- Codex needs its existing login on heimdall. Hermes uses its configured provider
  on hermod. Neither worker's credentials are supplied to Jev.
- `/var/lib/secrets/obsidian.env`: browser login.

After review and merge, deploy the heimdall NixOS configuration using the usual
host rebuild procedure. Startup creates the jobs database. The Nix package
includes both bridge modules. Check health, submit a small job, verify its report,
and test an inbox capture. Offline tests mock model and worker calls; they do
not establish that live credentials or remote tools work.

## Development and source map

```bash
python3 -m unittest discover -s hosts/heimdall/muninn/brain -p 'test_*.py'
python3 -m unittest discover -s hosts/heimdall/muninn -p 'test_*.py'
nix-instantiate --parse hosts/heimdall/modules/system/brain.nix >/dev/null
nix-instantiate --parse hosts/heimdall/modules/system/huginn.nix >/dev/null
```

| Component | Source |
|---|---|
| Routing, voice, worker adapters | `hosts/heimdall/muninn/brain/bridge.py` |
| Durable jobs and report filing | `hosts/heimdall/muninn/brain/jobs.py` |
| Embedding index and search by meaning | `hosts/heimdall/muninn/brain/embed.py` |
| Embedding model server | `hosts/mimir/modules/system/embeddings.nix` |
| Dashboard feeds | `hosts/heimdall/muninn/brain/build-graph.py` |
| Inbox validation and archiving | `hosts/heimdall/muninn/inbox.py` |
| Services, API, indexer, nginx | `hosts/heimdall/modules/system/brain.nix` |
| Scheduled automations | `hosts/heimdall/modules/system/huginn.nix` |
| Vault/NFS and hosted Obsidian | `hosts/heimdall/modules/system/obsidian.nix` |
| Remote worker | `hosts/hermod/modules/system/hermes-agent.nix` |
| Desktop commands | `modules/system/muninn.nix` |

## Research basis

The [requested video](https://www.youtube.com/watch?v=EOdXR6lU5ZA) did not expose
a transcript to the research tools. The creator's
[companion article](https://www.chaseai.io/blog/how-to-build-an-agentic-os-claude-os)
describes three routing tiers and a vault receiving conversations and skill
outputs. This implementation keeps the existing vault layout and providers.
[OpenRouter's TypeSafe API documentation](https://openrouter.ai/docs/guides/community/typesafe-sdk)
confirms the endpoint and model namespace;
[TypeSafe's confidence documentation](https://docs.typesafe.ai/confidence)
explains confidence versus an option's probability.
