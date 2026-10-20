# yggdrasil

my always-on control box: a lenovo thinkcentre m93p tiny on its own, outside `hella`, so my agents and
my git server keep running when the proxmox host is down. `hosts/yggdrasil/`.

## what runs where (so i don't forget)

**almost every self-hosted service is on heimdall** (`10.0.20.17`, a vm on hella): traefik, immich,
paperless, vaultwarden, homarr, grafana/prometheus/alertmanager, ntfy, changedetection, searxng,
crafty, scrutiny, the muninn vault's huginn agents and the brain dashboard. see
[`heimdall-docs.md`](heimdall-docs.md).

**forgejo is the exception: it runs on yggdrasil**, with its files and database on odyn. new apps
from now on go the same way, see [`apps-on-odyn.md`](apps-on-odyn.md).

| host | what lives there |
|---|---|
| heimdall `10.0.20.17` | the services above, plus traefik for *every* `*.oryxserver.org` name (forgejo's too) |
| **yggdrasil `10.0.20.21`** | **forgejo** (git.oryxserver.org), hermes (my agent), claude code + herdr |
| odyn `10.0.20.6` | storage, **appdb** (postgres for the yggdrasil apps), dockge with the arr apps, plex/jellyfin |
| mimir `10.0.20.18` | llm server, comfyui, immich machine learning, blender test node |
| njord `10.0.20.20` | sure (finance), walled off |
| mjolnir `10.0.20.100` | my desktop, the one place i edit this repo |

## repos on forgejo

| repo | also on github | how it gets there |
|---|---|---|
| `nixos-dotfiles` | yes (public) | `git push origin` sends to both: origin has two push urls. hosts keep pulling from github |
| `Hlidskjalf` | yes (private) | same, two push urls on origin |
| `agentic-os` | no, its github repo is gone | origin is forgejo |
| `muninn-os-linux` | yes (private) | copied once from github; no local clone |

on a fresh clone, add the second push url again (the first `--add --push` replaces the default):

```sh
git remote set-url --add --push origin git@github.com:jivsan/nixos-dotfiles.git
git remote set-url --add --push origin ssh://git@git.oryxserver.org:2222/jivsan/nixos-dotfiles.git
```

forgejo has no push-to-create: make the repo in the web ui first (private is the default).

## the box

- **hardware:** i5-4570T (2 cores / 4 threads), 16 GB ram, 223 GB sata ssd, one intel nic
- **ip:** `10.0.20.21/24` static (systemd-networkd), gateway pfsense, dns pihole `10.0.20.4`
- **os:** nixos 26.05, `pkgs-unstable.linuxPackages_latest` kernel, zram swap, no firmware bundle
- **no tailscale** on this host: only the lan reaches it
- installed from mjolnir without a keyboard, see `hosts/yggdrasil/install.sh`

## services

| service | what it is | port (who may connect) | config |
|---|---|---|---|
| **forgejo** | my git server: web at https://git.oryxserver.org, ssh at `ssh://git@git.oryxserver.org:2222/<user>/<repo>.git`. repos, lfs, attachments, settings on odyn; issues, users etc. in appdb on odyn. `forgejo-lts` | 3000 web, 2222 ssh (only heimdall: traefik passes them through) | `hosts/yggdrasil/modules/system/forgejo.nix` |
| **hermes-agent** | my ai agent (hermes) on my kimi pro plan with openrouter as fallback. tools over mcp: graphify (vault + dotfiles knowledge graphs on heimdall), blender, wowx and a dotfiles worktree on mjolnir, homarr | 8642 gateway api (only heimdall: the brain bridge) | `hosts/yggdrasil/modules/system/hermes-agent.nix` |
| prometheus-node-exporter | cpu, memory, disk and systemd numbers for heimdall's prometheus (homarr host card, `UnitFailed` alerts) | 9100 | `hosts/yggdrasil/modules/system/exporters.nix` |
| sshd | me (key only, no root, no passwords) | 22 | `default.nix` |
| thermald, fstrim | keep the little box cool, trim the ssd weekly | — | `default.nix` |

**tools for me and the agents** (no daemon): `claude` (claude code), `herdr` (agent runner),
`mimir-blender` (runs blender on mimir for agent checks), `capture` / `ask` (vault inbox and cheap
answers from the knowledge graph, `modules/system/muninn.nix`).

## scheduled jobs

| timer | what | when |
|---|---|---|
| `appdb-backup` | dumps every appdb database (forgejo …) to odyn `vault/appdata/backups`, keeps 14 days | 03:30 |
| `dotfiles-pull` | `git pull --ff-only` of `~/nixos-dotfiles` from github, never rebuilds | every 2 min |
| `nix-gc` | old nix store paths | weekly |
| `fstrim` | ssd trim | weekly |

a failed unit (any of these) shows up as `UnitFailed` on my phone through heimdall's alerting.

## storage from odyn (nfs)

| path | what | mount |
|---|---|---|
| `/mnt/appdata/forgejo` | forgejo's repos, lfs, attachments, ssh host keys, app.ini + secret keys | hard, automount |
| `/mnt/appdata/backups` | the nightly appdb dumps | hard, automount |
| `~/muninn` and `/mnt/muninn` | the vault (the second path is for hermes, who can't enter my home) | soft, automount |
| `/mnt/studio`, `/mnt/studio-cache` | my blender files and job scratch (same paths on mjolnir and mimir) | hard / soft |
| `/mnt/hermes-wowx` | wow models from wowx and their upscales | soft, automount |
| `/mnt/ratatoskr` | screenshots, snippets and files between me, hermes and claude | soft, automount |
| `~/.agent-memory` | claude's memory notes, shared with mjolnir | soft, short timeout |

only the local disk holds rebuildable things (logs, caches, forgejo's search index) and the secrets.

## secrets (never in git)

| where | what |
|---|---|
| `/var/lib/secrets/` (root 0600) | appdb admin + backup passwords, forgejo's database password |
| `/etc/hermes/env` | hermes' api keys (kimi, openrouter, brave, homarr) |
| `/var/lib/hermes-ssh/` | hermes' ssh key for its mcp servers (locked to forced commands on heimdall and mjolnir) |

## deploy and admin

```sh
# deploy (after pushing from mjolnir; the clone pulls by itself every 2 minutes)
ssh christina@10.0.20.21
cd /tmp && sudo nixos-rebuild switch --flake ~/nixos-dotfiles#yggdrasil
# or straight from mjolnir
nixos-rebuild switch --flake .#yggdrasil --target-host christina@10.0.20.21 --sudo

# forgejo admin (users, tokens …)
sudo -u forgejo env FORGEJO_WORK_DIR=/var/lib/forgejo FORGEJO_CUSTOM=/mnt/appdata/forgejo/custom \
  forgejo admin user list

# run the database dump now
sudo systemctl start appdb-backup
```

## gotchas

- `nixos-rebuild` as root on my christina-owned clone fails ("not owned by current user"): run it
  from `/tmp` with sudo, as above.
- a rebuild doesn't restart hermes. after changing `/etc/hermes/env`, check it isn't busy
  (`gateway_state.json` active work) before `systemctl restart hermes-agent`.
- the first deploy of an app whose folders are on an odyn share can fail with "No such file or
  directory" in a namespace step: tmpfiles ran before the share was mounted. `sudo systemd-tmpfiles
  --create` and restart the unit. later boots are fine.
- forgejo's built-in ssh server only answers to the one user name in `BUILTIN_SSH_SERVER_USER`
  (`git`); anything else gets "Permission denied (publickey)".
- after a power cut yggdrasil is up long before odyn: forgejo keeps retrying every 15 s until the
  share and appdb answer, nothing to do by hand.
