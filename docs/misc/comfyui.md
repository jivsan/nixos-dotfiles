# ComfyUI — two-host GPU pipeline runbook

Image generation runs on **two** hosts that share one model library on odyn:

| host | GPU | ComfyUI | torch | starts |
|---|---|---|---|---|
| **mjolnir** (workstation) | RTX 4060 Ti 8G (Ada, sm_89) | v0.28.2 | 2.11.0+cu128 | on demand |
| **mimir** 10.0.20.18 | GTX 1070 8G (Pascal, sm_61) | v0.28.2 | **2.6.0+cu126** | at boot |

```
you (browser) ──▶ http://127.0.0.1:8188              (mjolnir, loopback only)
              └─▶ https://comfyui.oryxserver.org     (→ mimir, Traefik on heimdall, lan-only)

  mjolnir  ├─ podman: comfyui  (RTX 4060 Ti via CDI)
           ├─ ~/comfyui                 ← odyn NFS, visible in Nautilus
           └─ /var/lib/comfyui/{user,temp}   ← host-local

  mimir    ├─ podman: comfyui  (GTX 1070 via CDI)
           ├─ /mnt/odyn/comfyui         ← same odyn NFS export
           └─ /var/lib/comfyui/{user,temp}   ← host-local

  odyn 10.0.20.6 ── vault/comfyui  (recordsize=1M, LZ4, atime=off)
                    export: 10.0.20.0/24, mapall → christina (uid/gid 3002)
                    models/ · output/ · input/
```

Only `user/` and `temp/` are host-local — `user/` holds a sqlite db and `temp/` is hot
scratch I/O, neither of which belongs on NFS. Everything else is shared, so a checkpoint
dropped once is visible to both hosts immediately.

## URLs

| What | Where |
|---|---|
| mjolnir web UI | http://127.0.0.1:8188 (loopback only) |
| mimir web UI | https://comfyui.oryxserver.org (LAN + tailscale) · direct http://10.0.20.18:8188 |
| bot repo | github.com/jivsan/discordbot (private) · `~/projects/discordbot` on mjolnir |

## Adding models

Drop the file into `~/comfyui/models/<type>/` on mjolnir — it's an ordinary folder in
Nautilus, alongside `muninn` and `OBS-recordings`. Then press **R** in the web UI.

```
checkpoints/  loras/  vae/  controlnet/  upscale_models/  embeddings/
text_encoders/ (+ legacy clip/)   diffusion_models/ (+ legacy unet/)
ultralytics/bbox/  ultralytics/segm/  sams/  insightface/  ipadapter/
```

No scp, no ssh — both hosts read the same directory. Files land on odyn owned by
`christina` uid 3002; that's the export's `mapall`, not a permissions bug.

## The Pascal rule (mimir only — read before upgrading)

The GTX 1070 is **Pascal (sm_61)**. mimir's torch is pinned **2.6.0+cu126**, the last line
shipping Pascal kernels, via a pip constraints file — an incompatible bump **fails the
build loudly** instead of producing an image that can't see the GPU.

The **ComfyUI version is independent of that pin.** 0.28.2 runs fine on torch 2.6: the only
gate in `model_management.py` is a `>= (2, 7)` check guarding an optional optimization that
upstream notes "works on 2.6 but doesn't actually seem to improve much." So keep both hosts
on the same ComfyUI, and leave mimir's torch alone until the GPU changes.

mimir's driver is `legacy_580` (`nvidia.nix`) — NVIDIA dropped Pascal after the 580 branch,
so `nvidiaPackages.stable` (595.x) will not bind. Revert to `stable` when the 3090 lands.

## ComfyUI-Manager (the non-obvious part)

As of ComfyUI 0.28 Manager is a **first-class integration, not a custom node**. `nodes.py`
does `import comfyui_manager` guarded by `if args.enable_manager`.

- Install with `pip install comfyui-manager==4.2.2`. **Never** `git clone` it into
  `custom_nodes/` — Manager 4.x has no root `__init__.py`, and ComfyUI's loader
  (`spec_from_file_location(name, "<dir>/__init__.py")`) fails *silently*.
- Both flags are required in the CMD:
  - `--enable-manager` → backend only.
  - `--enable-manager-legacy-ui` → the actual **Manager button next to Run**. Manager 4.2.2
    serves its API under `/v2/`, but the frontend pinned by ComfyUI 0.28.2
    (`comfyui-frontend-package` 1.45.21) still calls the unprefixed `customnode/*` paths and
    404s. The legacy flag registers the routes its JS expects and injects the web dir.
- **Runtime installs persist on mjolnir** (see below). On mimir they do not — it has no
  persistence wiring yet, so bake nodes into its Containerfile there.
- Refusal: *"security_level must be `normal or below`, and network_mode must be
  `personal_cloud`"* → set `network_mode = personal_cloud` in `config.ini` and restart.
  Manager infers `public` because the container must listen on `0.0.0.0` for podman's port
  forward, even though the host only binds `127.0.0.1`. Correcting a false signal, not
  widening access.
- Its own config persists (`user/__manager/config.ini`, on the host-local volume). Git-URL
  and pip installs are gated by `allow_git_url_install` / `allow_pip_install` there, plus a
  non-local-listener rule needing `network_mode = personal_cloud`.
- Known upstream bug: `/customnode/alternatives` 500s (`fetch_customnode_alternatives`).
  That's the "Alternatives of A1111" panel only; install/update work fine.

## Common operations

**Start / stop on mjolnir** (`autoStart = false` — the 8G of VRAM is shared with games):
```
comfyui start | stop | status | logs      # bash function, modules/home/shell.nix
```

**Upgrade ComfyUI / custom nodes** — bump the ARGs in the host's `comfyui/Containerfile`,
plus `version` in `comfyui.nix` and `VERSION` in `build.sh` (all three must match), commit,
then on the host:
```
cd ~/nixos-dotfiles && git pull
cd <host>/modules/system/comfyui && ./build.sh     # image MUST exist before the switch:
sudo nixos-rebuild switch --flake ~/nixos-dotfiles#<host>   # --pull=never + autoStart
```
mjolnir's copy lives at `modules/apps/comfyui/`; mimir's at
`hosts/mimir/modules/system/comfyui/`. **Do not copy one Containerfile over the other** —
they pin different torch builds.

**Add a permanent custom node**: on mjolnir just install it from Manager — it persists (see
below). To pin one declaratively (or on mimir), add a `git clone` + `pip install -r` layer to
the Containerfile and rebuild.

## How runtime installs survive `--rm` (mjolnir)

oci-containers runs podman with `--rm` and `podman rm -f` in ExecStopPost, so the container
filesystem is destroyed on every stop. That created a catch-22: loading a newly installed node
requires a restart, and the restart deleted it. Two volumes fix it:

| host path | in container | holds |
|---|---|---|
| `/var/lib/comfyui/custom_nodes` | `/app/custom_nodes` | the node files |
| `/var/lib/comfyui/venv` | `/app/venv` | their pip dependencies |

- `extra_model_paths.yaml` registers `/app/custom_nodes` with `is_default: true`, which
  `folder_paths.add_model_folder_path` inserts at **index 0** — exactly what Manager's
  `get_default_custom_nodes_path()` returns, so Manager installs there. ComfyUI scans *all*
  registered paths, so the baked-in Impact Pack nodes keep working alongside it.
- `entrypoint.sh` creates a venv (`--system-site-packages`) on the volume and execs ComfyUI
  from it, so `sys.executable` is the venv python and Manager's pip/uv installs land on the
  volume. torch and ComfyUI's own deps still come from the image. The venv is recreated
  automatically if the image's python minor version changes (`.pyver` marker) — a venv built
  against a different python silently fails to import everything.

Both are host-local on purpose: this is Python compiled against a specific torch (2.11 on
mjolnir vs 2.6 on mimir), so the hosts must **not** share it via odyn.

## Secrets (never in git)

| File | Contents |
|---|---|
| mimir `/var/lib/discordbot/.env` | `DISCORD_TOKEN=…`, `COMFYUI_URL=http://127.0.0.1:8188`, optional `GUILD_ID=…` |
| mjolnir `~/projects/discordbot/.env` | same shape, `COMFYUI_URL=http://10.0.20.18:8188` (dev) |

⚠️ **discordbot is currently disabled** — `./modules/system/discordbot.nix` is commented out
in `hosts/mimir/default.nix` because `/var/lib/discordbot/.env` no longer exists. Restore the
token file first, then uncomment.

## Troubleshooting

```
ssh christina@10.0.20.18                # NOTE: `ssh mimir` does not resolve — no DNS record
systemctl status podman-comfyui
sudo journalctl -u podman-comfyui -f    # container stdout
curl -s localhost:8188/system_stats     # GPU must be listed under .devices
findmnt /home/christina/comfyui         # mjolnir   (mimir: /mnt/odyn/comfyui)
```

- **Container won't start, mount missing** → `RequiresMountsFor` is refusing to run against
  an absent NFS mount, by design (better than silently serving an empty library). Check odyn
  is up: `showmount -e 10.0.20.6`.
- **"Failed to find C compiler"** → the gcc layer is missing from the image (triton JIT needs
  it); rebuild from the current Containerfile.
- **Image missing / container dies instantly** → `--pull=never` and the tag isn't built on
  that host. Run `./build.sh` there.
- **No Manager button** → hard-refresh the browser (Ctrl+Shift+R); the old frontend is
  cached. Then confirm `--enable-manager-legacy-ui` is in the running CMD:
  `sudo podman inspect comfyui --format '{{.Config.Cmd}}'`.
- **Models not showing** → press **R** in the UI. If still absent, check the file actually
  landed on odyn and not in a stale local dir: `ls ~/comfyui/models/checkpoints/`.

## History

The model library used to be 41G on a local ZFS `scratch` pool on mimir. Those SSDs were
physically removed in July 2026; `storage.nix` is commented out in `hosts/mimir/default.nix`
(kept, not deleted — it holds the pinned `hostId` and the `brunnr` plan) and the library moved
to odyn, shared with mjolnir.
