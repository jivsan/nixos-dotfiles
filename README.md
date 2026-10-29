# nixos-dotfiles

this is the nixos config for all my machines. one flake, one source of truth, everything declarative.
a ryzen workstation with an rtx card, a little lenovo mini pc that runs my agents and a bunch of self hosted
stuff on proxmox, all on my own vlans behind an arista switch.

**NixOS 26.05 (Yarara)** · flakes + [home-manager](https://github.com/nix-community/home-manager) · git user `jivsan`

## how i work on this

i only ever edit on `mjolnir`. i commit there and push, and every other machine just does `git pull origin main`.
they also pull by themselves every two minutes, but they never rebuild on their own, so a change goes from
mjolnir to github to the host and then i rebuild on that host.

after a push forgejo builds every host on mimir and puts the result in my nix cache there, so the rebuild on a host
downloads instead of compiling. `deploy` on mjolnir does the pull and the rebuild on the hosts for me when i don't
want to ssh into each one, and renovate opens pull requests for updates. all of it is in
[`docs/ci-and-nix-cache.md`](docs/ci-and-nix-cache.md).

## hosts

everything sits on vlan 20 (`10.0.20.0/24`). heimdall, tyr and njord are vms on `hella` (proxmox). yggdrasil is its
own little box, so my agents keep running even when hella is down. the elitebook is an old laptop that only
runs octoprint for my 3d printer.

| host        | ip            | what it does                                                                   | desktop                                                 |
|-------------|---------------|--------------------------------------------------------------------------------|---------------------------------------------------------|
| `mjolnir`   | `10.0.20.100` | my workstation and daily driver (5900X, RTX 5070 Ti)                           | oxwm on X11 by default and Hyprland too, picked in `ly` |
| `heimdall`  | `10.0.20.17`  | headless services vm with traefik, immich, paperless, vaultwarden, homarr, grafana and huginn | none                                     |
| `mimir`     | `10.0.20.18`  | headless ai box (5950X, RTX 4060 Ti) with llm, comfyui and immich ml            | none                                                    |
| `tyr`       | `10.0.20.19`  | agent workstation vm with claude code, codex and herdr, linked to the muninn vault | neon oxwm over xrdp, i connect from `mjolnir` with remmina |
| `njord`     | `10.0.20.20`  | headless finance vm running [sure](https://github.com/we-promise/sure), walled off from everything else | none                    |
| `yggdrasil` | `10.0.20.21`  | lenovo thinkcentre m93p mini pc, always on and outside hella. it runs hermes on kimi k3 with tools for the vault, blender and wow assets, and my self hosted apps (forgejo) with their data on odyn | none |
| `elitebook` | `10.0.20.22`  | my old hp elitebook 8540p next to the ender-3 v3 se. it only runs octoprint, i slice on mjolnir and save the g-code in `/mnt/ratatoskr/3dprint` | none |

> these are only the nixos hosts. the switch, pfsense, truenas and a pihole lxc aren't nixos, they're in the
> network part below.

## homelab network

the network is built around an **Arista DCS-7050TX-48** called `bifrost`, the norse bridge between the realms,
which felt right for a switch. it runs arista eos and not nixos, so it isn't a flake host. its config lives in
[`network/`](network/).

pfsense does the routing on a stick, the arista is a plain layer 2 core, and vlans keep my trusted stuff away from
iot. storage gets its own private vlan that never touches the router.

| vlan | name     | subnet         | what's on it                                        |
|------|----------|----------------|-----------------------------------------------------|
| 20   | trusted  | `10.0.20.0/24` | workstation, proxmox, nas, services and yggdrasil   |
| 30   | storage  | `10.0.30.0/24` | private fast path to the nas, layer 2 only with no gateway |
| 50   | iot-wifi | `10.0.50.0/24` | wifi, esp32 and shelly stuff, home assistant        |

pfsense is `.1` on vlan 20 and 50 and does all the routing between vlans. dns goes client → pfsense → pihole
(`10.0.20.4`, an lxc on `hella`) → unbound → the root servers, so ad blocking is in the path for everyone.

iot on vlan 50 gets dns and the internet but is firewalled off from every private subnet. trusted can reach
everything, home assistant too, through pfsense's stateful return path, so the block only goes one way.

**switch ports**

| port        | device                           | mode                                |
|-------------|----------------------------------|-------------------------------------|
| Et1         | pfsense                          | trunk, native 20 with 50 tagged     |
| Et2 and Et3 | `hella` (proxmox)                | lacp `Po1`, trunk 20 and 50         |
| Et4         | `odyn` (truenas)                 | trunk, native 20 with 30 tagged     |
| Et5         | `odyn` second port               | shut down, that port only does 1G   |
| Et6         | `mimir`                          | access vlan 20, single 10G          |
| Et7         | spare for a second mimir nic     | shut down                           |
| Et8         | `mjolnir`                        | access vlan 20, 10G                 |
| Et9         | tp link switch for iot and wifi  | access vlan 50                      |
| Et10        | `hella` onboard management       | access vlan 20                      |
| Et11        | `odyn` management                | access vlan 20                      |
| Et12        | `yggdrasil`                      | access vlan 20                      |
| Et19        | `elitebook` (octoprint)          | access vlan 20                      |

the switch is at `10.0.20.2` (ssh, eos), pfsense at `10.0.20.1` and proxmox on `hella` at
`https://10.0.20.10:8006`.

## quick start

```bash
git clone https://github.com/jivsan/nixos-dotfiles ~/nixos-dotfiles
cd ~/nixos-dotfiles

# build the host you're on
sudo nixos-rebuild switch --flake .#mjolnir      # or #heimdall, #yggdrasil ...

# push yggdrasil straight from mjolnir (it builds here, the mini pc only switches)
nixos-rebuild switch --flake .#yggdrasil --target-host christina@10.0.20.21 --sudo

# or from mjolnir: every host pulls and rebuilds itself, from mimir's cache
deploy                  # every host but mjolnir
deploy heimdall mimir   # only these, --dry first to see what would restart

# after changing flake inputs
nix flake lock
```

rebuilds don't break anything. if something goes wrong i roll back with `sudo nixos-rebuild switch --rollback`
or just pick an older generation at boot.

## what's in here

```
flake.nix            # the entry point with the inputs, mkHost and all the hosts
hosts/               # one folder per host: default.nix, home.nix, hardware and the modules only that host uses
modules/system/      # os modules two or more hosts share (boot, nix, users, neovim, odyn mounts …)
modules/home/        # home modules two or more hosts share (git, neovim, shell, terminal …)
modules/apps/        # app modules two or more hosts share (blender, claude code, codex, herdr …)
config/              # program configs (nvim, alacritty) and the st and dmenu sources
network/             # the homelab network, arista eos config and pfsense runbook (not nixos)
odyn/                # the truenas parts the hosts depend on: appdb (postgres) and the appdata datasets (not nixos)
docs/                # documentation, runbooks for octane, comfyui and the ai gateway in docs/misc
```

every host is put together the same way: its own folder under `hosts/` plus the shared modules it picks.
the full breakdown is in [`docs/nixos-structure.md`](docs/nixos-structure.md).

## highlights

**two desktops on the workstation.** oxwm (X11) and Hyprland (Wayland) live side by side as `ly` sessions, fully
separate, and switching between them has no side effects.

**Hyprland in lua** (0.55) riced in the same neon look as tyr. the configs are out of store symlinks, so i edit
and it hot reloads without a rebuild.

**bleeding edge gpu stack on `mjolnir`.** it takes `boot.kernelPackages`, and with it the nvidia driver, from
`nixpkgs-unstable` instead of the pinned 26.05, because the 595 driver in 26.05 doesn't build against kernel 7.2
anymore. right now that's kernel 7.2 with the 595 driver on the open module, the same as mimir
(`modules/system/nvidia-driver.nix`). everything else on the host still comes from 26.05.

**self hosted stack on `heimdall`** with immich, paperless, vaultwarden and homarr behind traefik, watched by
prometheus, loki and grafana.

**[muninn](docs/muninn-agentic-os.md), my agentic os.** an obsidian vault on `odyn` is shared memory for me and my
agents. huginn's agents tidy and file the vault on `heimdall`, the config repo is a knowledge graph they can query,
and the `brain` page shows it all live in 3d.

**yggdrasil, the world tree.** a tiny thinkcentre that's always on and sits outside hella, so hermes keeps going
even when proxmox is down. hermes is the agent i talk to, with tools into the vault and the dotfiles graph, blender
on mjolnir and wowx for game assets, which it exports and upscales on a shared folder on the nas. the install
script is in `hosts/yggdrasil/install.sh`.

**my finances stay on their own vm.** sure runs on `njord` and its nftables only accepts port 3000 from heimdall's
traefik, instead of sharing the services box.

**a vlan split network** behind `bifrost`, with trusted, storage and iot kept apart, pfsense routing on a stick,
pihole dns, and iot firewalled off the trusted side.

**reproducible end to end.** a fresh machine is one command away from being exactly what it was.

## docs

| file                                                                   | what's in it                                            |
|------------------------------------------------------------------------|---------------------------------------------------------|
| [`docs/nixos-structure.md`](docs/nixos-structure.md)                   | how the repo is laid out and how hosts are put together |
| [`docs/deploying-services.md`](docs/deploying-services.md)             | adding and deploying self hosted services               |
| [`docs/deploy-new-host.md`](docs/deploy-new-host.md)                   | bringing a brand new host into the flake                |
| [`docs/heimdall-docs.md`](docs/heimdall-docs.md)                       | the services vm in detail                               |
| [`docs/yggdrasil.md`](docs/yggdrasil.md)                               | the control box: everything running on it (forgejo, hermes) |
| [`docs/ci-and-nix-cache.md`](docs/ci-and-nix-cache.md)                 | ci on forgejo, the nix cache on mimir, renovate, `deploy` |
| [`docs/apps-on-odyn.md`](docs/apps-on-odyn.md)                         | apps on yggdrasil with their data and database on odyn  |
| [`odyn/README.md`](odyn/README.md)                                     | what's set up on odyn (truenas) for the hosts           |
| [`docs/muninn-agentic-os.md`](docs/muninn-agentic-os.md)               | the vault, the agents and the knowledge graph           |
| [`network/bifrost-arista-core.cfg`](network/bifrost-arista-core.cfg)   | the arista switch config                                |
| [`network/CHANGELOG.md`](network/CHANGELOG.md)                         | what changed on the network and why                     |
