# nixos-dotfiles

Declarative [NixOS](https://nixos.org) configuration for all my machines — one flake, one
source of truth. A Ryzen/RTX workstation plus a couple of Proxmox VMs, managed remotely
from the workstation.

**NixOS 26.05 (Yarara)** · flakes + [home-manager](https://github.com/nix-community/home-manager) · `git user: jivsan`

## Hosts

| Host           | Role                                       | Desktop                                   |
|----------------|--------------------------------------------|-------------------------------------------|
| `mjolnir`      | Workstation / daily driver (5900X, RTX 4060 Ti) | oxwm (X11, default) **+** Hyprland — pick at `ly` |
| `nix-services` | Headless self-hosted services VM (Proxmox) | —                                         |
| `bifrost`      | Hyprland remote-workstation VM (Proxmox)   | Hyprland over wayvnc → Remmina/Tailscale  |

## Quick start

```bash
git clone https://github.com/jivsan/nixos-dotfiles ~/nixos-dotfiles
cd ~/nixos-dotfiles

# build a host
sudo nixos-rebuild switch --flake .#mjolnir      # or #nix-services / #bifrost

# after changing flake inputs
nix flake lock
```

Rebuilds are non-destructive — roll back with `sudo nixos-rebuild switch --rollback` or
pick an older generation at boot.

## What's in here

```
flake.nix            # entry point: inputs + mkHost + the 3 hosts
configuration.nix    # mjolnir's umbrella (imports shared system modules)
home.nix             # shared home-manager imports
hosts/               # per-host config (default.nix, home.nix, hardware, host-local modules)
modules/system/      # shared OS modules (boot, networking, nix, users, hyprland, …)
modules/home/        # shared home modules (git, neovim, shell, terminal, …)
modules/apps/        # workstation app bundles (blender, octane, gaming, nvidia, …)
config/              # program configs / suckless sources (nvim, rofi, dwm, st, …)
docs/                # documentation
```

`mjolnir` pulls in everything via `configuration.nix`; the headless VMs cherry-pick only
the shared modules they need. Full breakdown in [`docs/nixos-structure.md`](docs/nixos-structure.md).

## Highlights

- **Dual desktop on the workstation** — oxwm (X11) and Hyprland (Wayland) coexist as
  selectable `ly` sessions, fully isolated; switching has no side effects.
- **Hyprland in Lua** (0.55), frosted-glass Tokyo Night theme, live-editable configs via
  out-of-store symlinks (edit → hot-reload, no rebuild).
- **Self-hosted stack** on `nix-services` — Immich, Nextcloud, Paperless, Crafty, behind
  Traefik with a Prometheus/Loki/Grafana monitoring setup.
- **Remote-workstation VM** (`bifrost`) reachable anywhere over Tailscale via VNC.
- Reproducible end to end — deploy a whole machine from a fresh install with one command.

## Docs

- [`docs/nixos-structure.md`](docs/nixos-structure.md) — repository structure & how hosts are assembled
- [`docs/deploying-services.md`](docs/deploying-services.md) — adding/deploying self-hosted services
- [`docs/nix-services-docs.md`](docs/nix-services-docs.md) — the services VM in detail
