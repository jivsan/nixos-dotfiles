# nixos-dotfiles

Declarative [NixOS](https://nixos.org) configuration for all my machines — one flake, one
source of truth. A Ryzen/RTX workstation plus self-hosted services on Proxmox, all sitting
on a VLAN-segmented homelab network behind an Arista core switch.

**NixOS 26.05 (Yarara)** · flakes + [home-manager](https://github.com/nix-community/home-manager) · `git user: jivsan`

## Hosts

| Host           | Role                                            | Desktop                                   |
|----------------|-------------------------------------------------|-------------------------------------------|
| `mjolnir`      | Workstation / daily driver (5900X, RTX 4060 Ti) | oxwm (X11, default) **+** Hyprland — pick at `ly` |
| `nix-services` | Headless self-hosted services VM (Proxmox, on `hella`) | —                                  |

> These are the **NixOS** hosts in this flake. The homelab also runs non-NixOS
> infrastructure — the Arista switch, pfSense, TrueNAS, a Pi-hole LXC — described in the
> network section below.

## Homelab network

The network is built around an **Arista DCS-7050TX-48** core switch named `bifrost`
(Norse: the bridge between the realms — fitting for a switch). It runs Arista EOS, not
NixOS, so it isn't a flake host; its config lives in [`network/`](network/).

pfSense does the routing on a stick, the Arista is a pure L2 core, and VLANs separate
trusted gear from IoT, with a private storage VLAN that never touches the router.

| VLAN | Name      | Subnet         | What's on it                                   |
|------|-----------|----------------|------------------------------------------------|
| 20   | trusted   | `10.0.20.0/24` | workstation, Proxmox host, NAS, services       |
| 30   | storage   | `10.0.30.0/24` | private NAS fast-path (L2-only, no gateway)    |
| 50   | iot-wifi  | `10.0.50.0/24` | Wi-Fi, ESP32 / Shelly, Home Assistant          |

- **Gateways / DNS** — pfSense is `.1` on VLAN 20 and 50 and does all inter-VLAN routing.
  DNS chains **client → pfSense → Pi-hole (`10.0.20.4`, LXC on `hella`) → unbound → roots**,
  so ad-blocking sits in the path for every client.
- **Isolation** — IoT (VLAN 50) reaches DNS + the internet but is firewalled off every
  private subnet; trusted reaches everything (incl. Home Assistant) via pfSense's stateful
  return path, so the block is one-directional.

**Switch port map:**

| Port  | Device                       | Mode                          |
|-------|------------------------------|-------------------------------|
| Et1   | pfSense                      | trunk (native 20, +50 tagged) |
| Et2–3 | `hella` (Proxmox)            | LACP `Po1`, trunk 20+50       |
| Et4–5 | `odyn` (TrueNAS)             | LACP `Po2`, trunk 20+30       |
| Et6–7 | `mimir` (NixOS AI)           | LACP `Po3`, trunk 20+30       |
| Et8   | `mjolnir`                    | access, VLAN 20 (10G)         |
| Et9   | TP-Link (IoT/Wi-Fi switch)   | access, VLAN 50               |
| Et10  | `hella` onboard (management) | access, VLAN 20               |

Management: switch at `10.0.20.2` (SSH/EOS), pfSense at `10.0.20.1`, Proxmox/`hella` at
`https://10.0.20.10:8006`.

## Quick start

```bash
git clone https://github.com/jivsan/nixos-dotfiles ~/nixos-dotfiles
cd ~/nixos-dotfiles

# build a host
sudo nixos-rebuild switch --flake .#mjolnir      # or #nix-services

# after changing flake inputs
nix flake lock
```

Rebuilds are non-destructive — roll back with `sudo nixos-rebuild switch --rollback` or
pick an older generation at boot.

## What's in here

```
flake.nix            # entry point: inputs + mkHost + the hosts
configuration.nix    # mjolnir's umbrella (imports shared system modules)
home.nix             # shared home-manager imports
hosts/               # per-host config (default.nix, home.nix, hardware, host-local modules)
modules/system/      # shared OS modules (boot, networking, nix, users, hyprland, …)
modules/home/        # shared home modules (git, neovim, shell, terminal, …)
modules/apps/        # workstation app bundles (blender, octane, gaming, nvidia, …)
config/              # program configs / suckless sources (nvim, rofi, dwm, st, …)
network/             # homelab network: Arista EOS config + pfSense runbook (not NixOS)
docs/                # documentation
```

`mjolnir` pulls in everything via `configuration.nix`; the headless VM cherry-picks only
the shared modules it needs. Full breakdown in [`docs/nixos-structure.md`](docs/nixos-structure.md).

## Highlights

- **Dual desktop on the workstation** — oxwm (X11) and Hyprland (Wayland) coexist as
  selectable `ly` sessions, fully isolated; switching has no side effects.
- **Hyprland in Lua** (0.55), frosted-glass Tokyo Night theme, live-editable configs via
  out-of-store symlinks (edit → hot-reload, no rebuild).
- **Self-hosted stack** on `nix-services` — Immich, Nextcloud, Paperless, Crafty, behind
  Traefik with a Prometheus/Loki/Grafana monitoring setup.
- **VLAN-segmented network** behind the `bifrost` Arista core — trusted / storage / IoT
  separation, pfSense router-on-a-stick, Pi-hole DNS, IoT firewalled off the trusted side.
- Reproducible end to end — deploy a whole machine from a fresh install with one command.

## Docs

- [`docs/nixos-structure.md`](docs/nixos-structure.md) — repository structure & how hosts are assembled
- [`docs/deploying-services.md`](docs/deploying-services.md) — adding/deploying self-hosted services
- [`docs/nix-services-docs.md`](docs/nix-services-docs.md) — the services VM in detail
- [`network/bifrost-arista-core.cfg`](network/bifrost-arista-core.cfg) — Arista EOS core switch config
- [`network/pfsense-vlan-setup.md`](network/pfsense-vlan-setup.md) — pfSense VLAN + firewall runbook
