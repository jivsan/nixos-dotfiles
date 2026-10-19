# nixos-dotfiles — how the repo is put together

one flake for all six of my nixos machines. i only edit on `mjolnir`, push to github
(`jivsan/nixos-dotfiles`), and every other host pulls.

- **nixpkgs:** stable `nixos-26.05` (yarara), home-manager `release-26.05`
- **stateVersion:** `25.11` by default from `modules/system/nix.nix`, hosts installed on 26.05 set their own
- **git user:** `jivsan`

the network these hosts sit on (vlans, the `bifrost` arista switch, pfsense, pihole) is in the
[README](../README.md) and `network/`.

## hosts

| host        | what it is                                         |
|-------------|----------------------------------------------------|
| `mjolnir`   | my desktop, oxwm (X11) and Hyprland, blender + octane |
| `heimdall`  | services vm: traefik, immich, paperless, vaultwarden, homarr, monitoring, huginn |
| `mimir`     | ai box: llm, embeddings, comfyui, immich ml, octane render node, agents' blender checks |
| `tyr`       | agent workstation vm with the neon oxwm rice over xrdp |
| `njord`     | finance vm running sure, walled off from the rest  |
| `yggdrasil` | always-on mini pc for claude code, hermes and herdr |

ips and hardware are in the README.

## layout

```
nixos-dotfiles/
├── flake.nix                 # inputs, mkHost and the six hosts
├── flake.lock
├── hosts/
│   └── <host>/               # everything that belongs to one host
│       ├── default.nix       # the system: shared modules it picks + its own
│       ├── home.nix          # home-manager for christina on that host
│       ├── hardware-configuration.nix
│       └── modules/          # modules only this host uses
│           ├── system/
│           ├── apps/
│           └── home/
├── modules/                  # modules two or more hosts share
│   ├── system/               # boot, locale, nix, users, neovim, tailscale, odyn mounts …
│   ├── home/                 # git, shell, terminal, neovim, suckless
│   └── apps/                 # blender, claude code, codex, herdr, octane libs …
├── config/                   # nvim and alacritty configs, st and dmenu sources
├── network/                  # bifrost's arista config + changelog (not nixos)
└── docs/
```

host folders with extra stuff:

- `hosts/mjolnir/hypr`, `waybar`, `mako`: my Hyprland config, linked live into `~/.config`
- `hosts/heimdall/muninn`: the python behind huginn and the brain (inbox sweep, gardener, bridge …)
- `hosts/yggdrasil/install.sh`: the install script for the mini pc

## where a module goes

- only one host uses it → `hosts/<host>/modules/{system,apps,home}/`
- two or more hosts use it → `modules/{system,apps,home}/`
- when a second host starts using a host module, it moves to `modules/`

## mjolnir's base files

`hosts/mjolnir/modules/system/base.nix` and `hosts/mjolnir/modules/home/base.nix` are what used to be
`configuration.nix` and `home.nix` at the repo root. they stay their own files on purpose: nixos collects
modules level by level, so moving their imports one level up reorders package lists and key files and
changes the build, even though nothing else changed.

## the flake

| input              | what for                                                         |
|--------------------|------------------------------------------------------------------|
| `nixpkgs`          | stable `nixos-26.05`                                             |
| `nixpkgs-unstable` | passed in as `pkgs-unstable` (mjolnir's kernel + nvidia driver come from here) |
| `home-manager`     | `release-26.05`, as a nixos module                               |
| `hyprland`         | pinned `v0.55.0`, not following nixpkgs so the cachix cache keeps working |
| `oxwm`             | tony's X11 window manager configured in lua                     |
| `helium`           | helium browser                                                   |
| `claude-code`      | claude code, applied as an overlay                               |
| `llm-agents`       | numtide's agent packages: codex and herdr, from their binary cache |
| `hermes-agent`     | hermes, its nixos module runs on yggdrasil                       |

`mkHost hostPath homeFile` wraps `nixpkgs.lib.nixosSystem`: it passes `inputs` and `pkgs-unstable`
through `specialArgs`, wires home-manager in (`useGlobalPkgs`, `useUserPackages`,
`backupFileExtension = "backup"`) and adds the claude-code overlay.

```nix
nixosConfigurations = {
  mjolnir   = mkHost ./hosts/mjolnir/default.nix   ./hosts/mjolnir/home.nix;
  heimdall  = mkHost ./hosts/heimdall/default.nix  ./hosts/heimdall/home.nix;
  mimir     = mkHost ./hosts/mimir/default.nix     ./hosts/mimir/home.nix;
  tyr       = mkHost ./hosts/tyr/default.nix       ./hosts/tyr/home.nix;
  njord     = mkHost ./hosts/njord/default.nix     ./hosts/njord/home.nix;
  yggdrasil = mkHost ./hosts/yggdrasil/default.nix ./hosts/yggdrasil/home.nix;
};
```

## Hyprland on mjolnir

`hosts/mjolnir/modules/system/hyprland.nix` turns on `programs.hyprland` with the pinned package and
portal, hyprlock with its pam service and the `hyprland.cachix.org` cache.

`hosts/mjolnir/modules/home/hyprland.nix` installs the wayland userland (waybar, awww, mako, hypridle,
cliphist, wl-clipboard, grim, slurp, swappy) and links `hosts/mjolnir/{hypr,waybar,mako}` into
`~/.config` with `mkOutOfStoreSymlink`, so i edit and Hyprland hot reloads (waybar and mako reload with
`pkill -SIGUSR2 waybar` and `makoctl reload`).

the config is lua (Hyprland 0.55 dropped hyprlang): `hyprland.lua`, with `hl.meta.lua` + `.luarc.json`
for autocomplete. oxwm stays the default `ly` session and Hyprland is the other one.

keys i use most: `Super+Return` terminal, `Super+D` run list, `Super+V` clipboard history, `Super+L`
lock, `Super+Escape` power menu, `Print` region screenshot, `` Super+` `` overview.

## deploying

1. edit on `mjolnir`, commit, push
2. on mjolnir: `sudo nixos-rebuild switch --flake ~/nixos-dotfiles#mjolnir`
3. on another host: `git -C ~/nixos-dotfiles pull --ff-only` (it also pulls by itself every two
   minutes), then `sudo nixos-rebuild switch --flake ~/nixos-dotfiles#<host>`
4. yggdrasil can be pushed from mjolnir:
   `nixos-rebuild switch --flake .#yggdrasil --target-host christina@10.0.20.21 --sudo`
5. njord only has 1.9 GB of ram and gets oom-killed evaluating the flake, so mjolnir evaluates and
   njord builds:
   `nixos-rebuild switch --flake .#njord --build-host christina@10.0.20.20 --target-host christina@10.0.20.20 --sudo`.
   a plain `--target-host` push fails, njord won't take unsigned paths from my user
6. after changing flake inputs: `nix flake lock` before rebuilding

roll back with `sudo nixos-rebuild switch --rollback` or pick an older generation at boot.

## 26.05 gotchas (already handled)

| old name       | new name | where it bit                          |
|----------------|----------|---------------------------------------|
| `rofi-wayland` | `rofi`   | merged, use plain `rofi`              |
| `swww`         | `awww`   | package + `swww-daemon` → `awww-daemon` |

harmless warning: `gtk.gtk4.theme` defaults to `null` in 26.05, and mjolnir keeps the old behaviour because
its `home.stateVersion` is below 26.05. silence it with `gtk.gtk4.theme = config.gtk.theme;` if it gets
annoying.

## conventions

- norse names for everything: `mjolnir`, `heimdall`, `mimir`, `tyr`, `njord`, `yggdrasil`, the switch
  `bifrost`, the proxmox host `hella`, the nas `odyn`
- don't make Hyprland follow nixpkgs: that loses the cachix cache and risks mesa/egl mismatches
- live-edited configs use `mkOutOfStoreSymlink` into `~/nixos-dotfiles`
- comments in the config are short and only say why something is the way it is. the long explanations
  and history live in my vault (muninn)
