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
5. The bridge files each terminal response in
   `Resources/Reports/Agent report <date> <job-id>.md`, including frontmatter,
   an Agents MOC link, request, route, worker, timestamps, status and result.
   Agents are asked to include findings, source URLs and actual output paths.
   A remote worker without vault access returns its deliverable for the bridge
   to file. Agent-created files normally go in `Resources/Outputs/`.
6. Reports enter the existing index and graph. Substantive conversations go
   into `Resources/Talk logs/`; nightly digests summarize changed notes.

Jev uses `https://openrouter.ai/api/v1/systemone`, `typesafe/jev-1.13` and the
existing OpenRouter key. Invalid, unavailable or low-confidence decisions fall
back to local rules, with `jev_error` and `route.fallback_reason` exposed.
Confidence is checked separately for the tier and its relevant command, skill
or worker. `JEV_MIN_CONFIDENCE=0.5` is application policy, not an accuracy guarantee.
Configured-worker flags do not prove remote reachability.

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

The vault's `CLAUDE.md` defines note conventions. `_inbox/` holds captures;
`Areas/` and `Resources/` hold organized knowledge; `MOCs/` holds hub notes;
`journal/` holds daily notes; `agents/` holds logs and archives. Templates and
Obsidian settings live in `_templates/` and `.obsidian/`.

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

Schedules: inbox on local changes plus 08:15/14:15/20:15; digest 23:00; vault graph
23:30; repo graph Sunday 04:00; gardener Saturday 08:30; dead-link fixer Sunday
06:00; brain builder every 30 seconds. Some timers add a short randomized delay.
NFS writes from other clients may miss inotify; the inbox timer is the fallback.

## Configuration and deployment

Secrets remain outside git:

- `/var/lib/secrets/graphify-openrouter.env`: `OPENAI_API_KEY`, optionally
  `OPENAI_BASE_URL` and `OPENAI_MODEL` (default `minimax/minimax-m3`).
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
python3 -m unittest discover -s hosts/heimdall/muninn -p 'test_inbox.py'
nix-instantiate --parse hosts/heimdall/modules/system/brain.nix >/dev/null
nix-instantiate --parse hosts/heimdall/modules/system/huginn.nix >/dev/null
```

| Component | Source |
|---|---|
| Routing, voice, worker adapters | `hosts/heimdall/muninn/brain/bridge.py` |
| Durable jobs and report filing | `hosts/heimdall/muninn/brain/jobs.py` |
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
