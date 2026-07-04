# ComfyUI + discordbot — mimir GPU pipeline runbook

The image-generation stack lives on **mimir** (10.0.20.18, GTX 1070 8GB).
One ComfyUI instance serves both the Discord bot (localhost) and humans
(browser). Everything is declarative except two secrets files.

```
you (browser) ──▶ https://comfyui.oryxserver.org      (Traefik on heimdall, lan-only)
                        │
mjolnir (dev) ──deploy.sh──▶ mimir
                              ├─ systemd: discordbot ──▶ localhost:8188
                              ├─ podman:  comfyui  (localhost/comfyui:v0.27.0)
                              │             └─ GTX 1070 via CDI
                              ├─ /scratch/models    ← 41G checkpoints/loras (zfs scratch)
                              └─ /scratch/comfyui   ← output / input / user
```

## URLs

| What | Where |
|---|---|
| ComfyUI web UI | https://comfyui.oryxserver.org (LAN + tailscale only) |
| direct (no Traefik) | http://10.0.20.18:8188 |
| bot repo | github.com/jivsan/discordbot (private) · `~/projects/discordbot` on mjolnir |

## The Pascal rule (read before upgrading anything)

The GTX 1070 is **Pascal (sm_61)**. torch is pinned **2.6.0+cu126** — the
last builds shipping Pascal kernels. The Containerfile has a pip constraints
file so an incompatible bump **fails the build loudly** instead of producing
an image that can't see the GPU. If you upgrade ComfyUI
(`hosts/mimir/modules/system/comfyui/Containerfile` ARGs), keep torch where
it is until the GPU changes.

## Common operations

**Add a model / LoRA** — drop the `.safetensors` on mimir:
```
scp model.safetensors mimir:/tmp/ && ssh mimir 'sudo mv /tmp/model.safetensors /scratch/models/checkpoints/'
# loras → /scratch/models/loras/   upscalers → /scratch/models/upscale_models/
```
Then press **R** in the web UI, or `/models` in Discord (forces a catalog refresh).

**Deploy bot code changes** (from mjolnir, in `~/projects/discordbot`):
```
./deploy.sh        # rsync *.py → mimir:/var/lib/discordbot/app + restart service
```

**Upgrade ComfyUI / custom nodes** (on mimir):
```
# 1. bump ARGs in hosts/mimir/modules/system/comfyui/Containerfile
#    + version in comfyui.nix + build.sh   (keep torch pinned!)
# 2. commit, push, then on mimir:
cd ~/nixos-dotfiles && git pull
cd hosts/mimir/modules/system/comfyui && ./build.sh
sudo nixos-rebuild switch --flake ~/nixos-dotfiles#mimir
```

**Add a permanent custom node**: add a `git clone` + `pip install -r` layer to
the Containerfile and rebuild. Runtime installs via ComfyUI-Manager do NOT
survive restarts (`podman run --rm` recreates the container fs every start).

## Secrets (never in git)

| File | Contents |
|---|---|
| mimir `/var/lib/discordbot/.env` | `DISCORD_TOKEN=…`, `COMFYUI_URL=http://127.0.0.1:8188`, optional `GUILD_ID=…` |
| mjolnir `~/projects/discordbot/.env` | same shape, `COMFYUI_URL=http://10.0.20.18:8188` (dev) |

## Troubleshooting

```
ssh mimir
systemctl status podman-comfyui discordbot      # both should be active
sudo journalctl -u podman-comfyui -f            # container stdout lives here
sudo journalctl -u discordbot -f                # bot logs (discord.py INFO)
curl -s localhost:8188/system_stats | jq .devices   # GPU must be listed
```

- **Container dies with "Failed to find C compiler"** → the gcc layer is
  missing from the image (triton JIT needs it) — rebuild from the current
  Containerfile.
- **`statfs /scratch/...: no such file`** → scratch dirs missing before the
  container started; `sudo systemctl restart podman-comfyui` after checking
  `ls /scratch/comfyui`.
- **Bot: `Improper token`** → token rotated; fix `/var/lib/discordbot/.env`,
  `sudo systemctl restart discordbot`.
- **Slash commands missing in Discord** → invite must include the
  `applications.commands` scope; set `GUILD_ID` in the bot .env for instant
  sync (global sync takes up to an hour).
