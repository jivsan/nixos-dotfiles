# nixos-dotfiles — Structure Reference

Declarative NixOS configuration for all of Christina's machines, managed from a single
flake. Primary workstation is `mjolnir`; the Proxmox VMs are deployed and managed
remotely from it. Pushed to GitHub (`jivsan/nixos-dotfiles`) and a self-hosted Forgejo.

- **nixpkgs:** stable `nixos-26.05` (Yarara) · home-manager `release-26.05`
- **stateVersion:** `25.11` (pinned in `modules/system/nix.nix`)
- **git user:** `jivsan`

## Hosts in this flake

| Host           | Role                                         | Hardware / Access                                  | Desktop |
|----------------|----------------------------------------------|----------------------------------------------------|---------|
| `mjolnir`      | Workstation / daily driver                   | Ryzen 9 5900X, RTX 4060 Ti                         | oxwm (X11, default) **+** Hyprland (Wayland), pick at `ly` |
| `nix-services` | Headless self-hosted services VM (Proxmox)   | Reached over LAN / Tailscale                        | none (server) |
| `bifrost`      | Hyprland remote-workstation VM (Proxmox)     | virtio-gpu, accessed via wayvnc → Remmina over Tailscale/LAN | Hyprland (Wayland) |

Build any host with:

```bash
sudo nixos-rebuild switch --flake ~/nixos-dotfiles#<host>
```

## Repository layout

```
nixos-dotfiles/
├── flake.nix                  # entry point — inputs + parameterized mkHost + 3 hosts
├── flake.lock
├── configuration.nix          # mjolnir's umbrella: imports the shared modules/system/*
├── home.nix                   # shared/mjolnir home: imports modules/home/*
│
├── hosts/
│   ├── mjolnir/
│   │   ├── default.nix              # imports configuration.nix + app modules + hyprland
│   │   ├── home.nix                 # imports ../../home.nix + ./modules/home/hyprland.nix
│   │   ├── hardware-configuration.nix
│   │   ├── modules/home/hyprland.nix   # Wayland userland + config symlinks (host-local)
│   │   ├── hypr/                    # hyprland.lua, hl.meta.lua, .luarc.json, rofi.rasi,
│   │   │                            #   hyprlock.conf, hypridle.conf, wall.png, powermenu.sh
│   │   ├── waybar/                  # config.jsonc, style.css
│   │   └── mako/                    # config
│   │
│   ├── bifrost/
│   │   ├── default.nix              # cherry-picks shared modules (NO configuration.nix)
│   │   ├── home.nix
│   │   ├── hardware-configuration.nix
│   │   ├── modules/home/{hyprland.nix, terminal.nix}
│   │   ├── hypr/  waybar/  mako/    # same shape as mjolnir's
│   │
│   └── nix-services/
│       ├── default.nix              # cherry-picks shared modules (NO configuration.nix)
│       ├── home.nix
│       ├── hardware-configuration.nix
│       └── modules/
│           ├── home/fastfetch.nix
│           └── system/             # one module per service (see below)
│
├── modules/                    # SHARED modules, imported selectively per host
│   ├── system/                 # OS-level
│   ├── home/                   # home-manager (user) level
│   └── apps/                   # mjolnir app bundles (packages)
│
├── config/                     # raw program configs / suckless sources (X11 era)
│   ├── alacritty/  nvim/  rofi/  qtile/     # symlinked into ~/.config via xdg.nix
│   └── dwm/  st/  dmenu/                     # suckless C sources, built via suckless.nix
│
└── docs/                       # this file lives here
```

## The three layers

**`modules/system/`** — shared OS-level modules. A host gets them either via
`configuration.nix` (mjolnir's umbrella imports the lot) or by importing individual ones
(the VMs cherry-pick to stay lean and headless).

```
boot  dconf  desktop  fonts  locale  nas  network-identity  networking  nix
octane-shutdown  packages  remote  storage  tailscale  usb  users  uv  backup  hyprland
```

Notable ones: `desktop.nix` (X11 + oxwm + `ly` display manager + monitor layout — mjolnir
only), `nix.nix` (flakes, gc, `stateVersion`, build parallelism), `tailscale.nix` (trusts
the `tailscale0` interface), `hyprland.nix` (see below), `users.nix` (the `christina` user).

**`modules/home/`** — shared home-manager modules.

```
git  gtk  neovim  picom  programs  shell  suckless  terminal  xdg
```

`xdg.nix` out-of-store-symlinks `~/.config/{nvim,rofi,qtile}` to the repo's `config/` so
they're live-editable; `suckless.nix` builds dwm/st/dmenu from the `config/` sources.

**`modules/apps/`** — mjolnir application bundles (mostly `environment.systemPackages`).

```
audio  blender  claude-code  discord  filemanager  gaming  nvidia  nvtop  octane
quixel-bridge  remote  remote-desktop  screenshot  telegram  unfree  upscayl  vlc
wallpaper  wow  wowexport
```

These are session-agnostic — installed system-wide, so they work under both oxwm (X11)
and Hyprland (Wayland, via XWayland for the X11 apps).

## The flake (`flake.nix`)

Inputs:

| Input              | Purpose                                                      |
|--------------------|--------------------------------------------------------------|
| `nixpkgs`          | stable `nixos-26.05`                                         |
| `nixpkgs-unstable` | passed in as `pkgs-unstable` via `specialArgs`              |
| `home-manager`     | `release-26.05`, as a NixOS module                          |
| `hyprland`         | pinned `v0.55.0` (NOT following nixpkgs → keeps cachix cache) |
| `hyprland-plugins` | pinned to the commit that still ships `hyprexpo`, follows `hyprland` |
| `oxwm`             | tony's Wayland-config'd X11 WM (Lua)                         |
| `helium`           | Helium browser                                              |
| `blender-bin`      | Blender binary builds                                       |
| `claude-code`      | Claude Code (applied as an overlay)                         |

`mkHost hostPath homeFile` wraps `nixpkgs.lib.nixosSystem`: passes `inputs` +
`pkgs-unstable` through `specialArgs`, wires home-manager (`useGlobalPkgs`,
`useUserPackages`, `backupFileExtension = "backup"`, `extraSpecialArgs = { inherit inputs; }`),
and applies the `claude-code` overlay. There's also a `devShells.suckless` for compiling
the suckless tools.

```nix
nixosConfigurations = {
  mjolnir      = mkHost ./hosts/mjolnir/default.nix      ./hosts/mjolnir/home.nix;
  nix-services = mkHost ./hosts/nix-services/default.nix ./hosts/nix-services/home.nix;
  bifrost      = mkHost ./hosts/bifrost/default.nix      ./hosts/bifrost/home.nix;
};
```

## How a host is assembled

There are two patterns:

**Umbrella (mjolnir).** `hosts/mjolnir/default.nix` imports `configuration.nix` (which
pulls in every shared `modules/system/*`), then layers on the `modules/apps/*` bundles,
`tailscale.nix`, and `modules/system/hyprland.nix`. Its home file imports the shared
`home.nix` plus the host-local Hyprland home module.

**Cherry-pick (nix-services, bifrost).** These deliberately do **not** import
`configuration.nix` (that would drag in `desktop.nix` = X11/oxwm/`ly`). Instead they import
just the shared system modules they need (e.g. `boot`, `locale`, `networking`, `nix`,
`users`, `tailscale`) and add their own host-local modules. This keeps server/headless
hosts lean.

## Hyprland setup

Added as a clean, modular layer that coexists with oxwm without affecting it.

**`modules/system/hyprland.nix`** (reusable, imported by mjolnir and bifrost): enables
`programs.hyprland` with the pinned `v0.55.0` package + portal, `programs.hyprlock` + its
PAM service, the `hyprland.cachix.org` substituter, and exposes the `hyprexpo` plugin `.so`
path as `$HYPREXPO_PLUGIN`.

**Per-host config** lives in `hosts/<host>/hypr|waybar|mako/` and is deployed by the host's
`modules/home/hyprland.nix` via `mkOutOfStoreSymlink` — so the files are symlinked from the
repo into `~/.config/`, making them **live-editable** (edit + save → Hyprland hot-reloads;
waybar/mako reload with `pkill -SIGUSR2 waybar` / `makoctl reload`).

The config is written in **Lua** (Hyprland 0.55 deprecated hyprlang): `hyprland.lua` with
`hl.meta.lua` + `.luarc.json` providing LSP autocomplete. Theme is frosted-glass Tokyo
Night with pink/cyan accents (`#2de2e6` / `#ff4fa3`), JetBrainsMono Nerd Font.

Session behaviour:
- **mjolnir** — oxwm (default) and Hyprland are both `ly` sessions; cycle the session field
  at the login screen. Hyprland uses NVIDIA env vars + hardware cursors; `hyprexpo`
  workspace overview on `Super+\``.
- **bifrost** — Hyprland-only; autostarts `wayvnc` (reachable on `:5900` over Tailscale, and
  LAN). Software-rendered (llvmpipe), so blur/animation are the perf dial.

Hyprland userland (per-host home module): `waybar awww mako hypridle cliphist wl-clipboard
grim slurp swappy` (+ `rofi` from shared `programs.nix`, `hyprlock` from the system module).

Common Hyprland keybinds: `Super+Return` terminal, `Super+D` rofi, `Super+V` clipboard
history, `Super+L` lock, `Super+Escape` power menu, `Print` region screenshot, `Super+\``
overview.

## nix-services — self-hosted stack

Host-local service modules under `hosts/nix-services/modules/system/`:

```
acme  blackbox-exporter  crafty  grafana  homepage  immich  loki  nas  nextcloud
nexterm  paperless  postgres-exporter  prometheus  promtail  scrutiny  traefik
```

Reverse-proxied behind Traefik (Let's Encrypt wildcard via Cloudflare DNS-01), with a
Prometheus + Loki + Grafana monitoring stack and Scrutiny for drive health.

## Deploy workflow

1. Edit on `mjolnir`, commit, push.
2. `mjolnir`: `sudo nixos-rebuild switch --flake ~/nixos-dotfiles#mjolnir`
3. Remote VMs: `git -C ~/nixos-dotfiles pull` on the host, then
   `sudo nixos-rebuild switch --flake ~/nixos-dotfiles#<host>` (or build from mjolnir).
4. After changing flake inputs: `nix flake lock` before rebuilding.
5. Hyprland config changes hot-reload via the live-edit symlinks — no rebuild needed unless
   packages or the system module change.

NixOS keeps prior generations — roll back with `sudo nixos-rebuild switch --rollback` or
pick an older generation from the boot menu.

## 26.05 migration gotchas (already handled)

| Old name        | New name | Where it bit                          |
|-----------------|----------|---------------------------------------|
| `rofi-wayland`  | `rofi`   | merged; use plain `rofi`              |
| `swww`          | `awww`   | package + `swww-daemon`→`awww-daemon` |

Harmless warning: `gtk.gtk4.theme` default changed to `null` in 26.05 — kept legacy
behaviour because `home.stateVersion` is < `26.05`. Silence with
`gtk.gtk4.theme = config.gtk.theme;` if desired.

## Conventions

- **Naming:** Norse-themed (`mjolnir`, `bifrost`); `nix-` prefix for service VMs.
- **Hyprland version** pinned to `v0.55.0` via the flake; don't make it follow `nixpkgs`
  (that loses the cachix binary cache and risks Mesa/EGL mismatches).
- **Headless hosts** cherry-pick shared modules; only `mjolnir` uses the
  `configuration.nix` umbrella.
- **Live-editable configs** use `mkOutOfStoreSymlink` to the repo at `~/nixos-dotfiles`.
- **Editing preference:** complete file contents over diffs; rebuild with
  `sudo nixos-rebuild switch --flake .#<hostname>`.
