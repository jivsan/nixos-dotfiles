# HEIMDALL — Build & Handoff Brief (for Claude Code)

> **Read this first.** You (Claude Code) did **not** see the long live-debugging session
> that produced this plan, so everything you need is written out below. Treat this file as
> the single source of truth for building `heimdall`. Ask Christina before doing anything
> destructive (`qm destroy`, deleting datasets, force-pushing).

---

## 1. What we're building & why

`heimdall` is a **fresh NixOS VM** on the Proxmox host **`hella`**. It **replaces** the old
`nix-services` VM (VMID 153), whose network stack got corrupted during a network re-IP and
became unrecoverable. Rather than keep fighting it, we're rebuilding clean.

- **Host name (new):** `heimdall` (Norse watchman who guards Bifrost — fits the
  monitoring/reverse-proxy/services role; sits thematically next to the switch `bifrost`).
- **It runs:** Traefik (reverse proxy + ACME), Immich, Nextcloud, Paperless, Crafty
  (Minecraft), Homepage, and the observability stack (Grafana / Prometheus / Loki /
  exporters / Scrutiny).
- **All service DATA lives on NFS from `odyn`** (TrueNAS, `10.0.20.6`). So a fresh VM just
  re-mounts the same data — **nothing is lost** by rebuilding, as long as odyn's NFS is up
  and its exports allow the new subnet (see §2 and the companion doc `odyn-10g-single-link.md`).

**Repo:** `git@github.com:jivsan/nixos-dotfiles.git` (user `jivsan`, email `chrsol3@gmail.com`).
Flake-based, `mkHost` abstraction, modules under `modules/system/`, `modules/home/`,
`modules/apps/`. Rebuild with `sudo nixos-rebuild switch --flake .#<host>`.
**Workflow rule:** Christina edits on **mjolnir** → commits → pushes → other hosts `git pull` +
rebuild. mjolnir is the single source of truth. Do **not** hand-edit configs on heimdall itself
except as a one-time install bootstrap.

---

## 2. NON-NEGOTIABLE lessons (these caused hours of pain — do not repeat)

1. **The VM NIC must have `firewall=0` (Proxmox firewall OFF on the vNIC).**
   With `firewall=1`, Proxmox inserts a firewall bridge (`fwbr…`) that **does not propagate
   the VLAN tag** to the inner tap — the tap stays on VLAN 1 while the uplink is VLAN 20, so
   the VM has no L2 path and silently APIPAs (`169.254.x`). pfSense already does all
   firewalling; the per-VM firewall is pure overhead **and** breaks VLAN tagging. **Leave it OFF.**

2. **Use a STATIC IP, not DHCP.** DHCP on the old VM never leased correctly after the re-IP.
   Bake the static into the NixOS config (below). The fresh VM on `firewall=0` *should* DHCP
   fine during the live-ISO install, but the installed system is **static**.

3. **Keep `system.stateVersion = "25.11"`.** The service data on odyn's NFS (Postgres,
   Nextcloud, Paperless, Immich) was created under the old `nix-services` at stateVersion
   `25.11`. Bumping to `26.05` can trigger data-format migrations. This value is install-time
   state, **not** the Nixpkgs channel — leave it at `25.11`.

4. **odyn's NFS exports must allow the new subnet.** They were scoped to the old `10.0.0.0/24`
   and must include **`10.0.20.0/24`** (and `10.0.30.0/24` if mounting over the storage VLAN),
   or every mount fails with `access denied by server`. See `odyn-10g-single-link.md` §D.

5. **Don't destroy VMID 153 until heimdall is verified working.** Keep it as a fallback.
   Create heimdall as a **new VMID** (e.g. 154).

---

## 3. Network facts (the new VLAN-segmented network)

| Thing | Value |
|---|---|
| VLAN 20 — trusted | `10.0.20.0/24`, gateway pfSense `10.0.20.1` |
| VLAN 30 — storage | `10.0.30.0/24`, **L2-only, no gateway** (never routed) |
| VLAN 50 — IoT/Wi-Fi | `10.0.50.0/24`, gateway `10.0.20.1` |
| pfSense (router) | `10.0.20.1` |
| bifrost (Arista switch) | `10.0.20.2` |
| Pi-hole (DNS, LXC 152 on hella) | `10.0.20.4` |
| odyn (TrueNAS) data | `10.0.20.6` (storage: `10.0.30.6`) |
| hella (Proxmox host) | `10.0.20.10` |
| **heimdall (this build)** | **`10.0.20.17`** |
| mjolnir (workstation) | `10.0.20.100` |
| DHCP pool (VLAN 20) | `.100`–`.199` (heimdall's `.17` is safely outside it) |

`heimdall` reuses the **same `10.0.20.17`** that was planned for `nix-services`, so the Pi-hole
local DNS records (`*.oryxserver.org → 10.0.20.17`) and Traefik routing stay valid.

DNS chain: client → pfSense `10.0.20.1` → Pi-hole `10.0.20.4` → Pi-hole's unbound → roots.
heimdall's nameserver is **Pi-hole (`10.0.20.4`)** so it resolves internal `*.oryxserver.org`.

---

## 4. PHASE 1 — Create the Proxmox VM (Christina, on hella)

Create heimdall as a **new VMID (e.g. 154)** on **hella**. Recommended settings:

- **General:** Name `heimdall`, VMID `154`.
- **OS:** NixOS **minimal** ISO (latest, matching the channel — 26.05). Upload to hella's ISO
  storage if not present.
- **System:**
  - Machine: **q35**
  - BIOS: **OVMF (UEFI)** ← important; add an **EFI Disk** when prompted (small, on the same
    storage). This makes the UEFI partition flow below work cleanly.
  - SCSI Controller: **VirtIO SCSI single**
- **Disk:** e.g. 64–128 GB on fast storage (this is OS + Nix store only; data is on NFS).
  Bus **SCSI** (will appear as `/dev/sda` in the guest).
- **CPU:** 4+ cores (host type fine).
- **Memory:** 8–16 GB (Immich + Postgres + observability stack like room).
- **Network:**
  - Bridge: **`vmbr1`** (the VLAN-aware bridge on hella's bond)
  - VLAN Tag: **`20`**
  - **Firewall: UNCHECKED (off)** ← THE critical setting (see §2.1)
  - Model: VirtIO (paravirtualized) → appears as **`ens18`** in the guest.

CLI equivalent for the NIC (note: **no** `firewall=1`):
```
qm set 154 --net0 virtio,bridge=vmbr1,tag=20
```

> After creating, confirm the tap lands on VLAN 20 once it's running:
> `bridge vlan show | grep tap154`  → should show `20 PVID`. If it shows `1 PVID`,
> the firewall is still on — remove it and `qm stop 154 && qm start 154`.

---

## 5. PHASE 2 — NixOS minimal install (Christina, via Proxmox console / SSH)

Christina is following tony's video for the base install. Steps, adapted for a headless
UEFI VM. **Run these in the VM (Proxmox console first; enable SSH to make it copy-paste-able).**

### 5.1 Boot the minimal ISO and enable SSH on the live environment
Boot the VM off the NixOS minimal ISO. On the live ISO:
```bash
sudo su
passwd root            # set a temporary root password for the live session
systemctl start sshd   # sshd is present on the ISO; this starts it
ip -br addr            # note the DHCP address it got on ens18 (10.0.20.x)
```
Now SSH in from mjolnir for easy paste: `ssh root@<that-ip>`.
(The fresh VM with `firewall=0` should DHCP fine on VLAN 20 — that's the proof the tag fix works.)

### 5.2 Confirm the disk
```bash
lsblk
```
You should see the VM disk (likely **`/dev/sda`** with VirtIO-SCSI). Confirm its name before
partitioning. The rest of this doc assumes `/dev/sda` — **substitute if lsblk shows otherwise.**

### 5.3 Partition with cfdisk (GPT, UEFI)
```bash
cfdisk /dev/sda
```
In cfdisk:
1. Select label type **gpt**.
2. Create partition **1**: size **512M**, then set Type → **EFI System**.
3. Create partition **2**: **remaining space**, Type → **Linux filesystem**.
4. **Write**, confirm `yes`, then **Quit**.

(No swap partition — we'll use zram/swapfile via config if needed. Keep it simple.)

### 5.4 Make filesystems + mount
```bash
mkfs.fat -F32 -n BOOT /dev/sda1
mkfs.ext4 -L nixos /dev/sda2

mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/BOOT /mnt/boot
```

### 5.5 Generate hardware config
```bash
nixos-generate-config --root /mnt
```
This writes `/mnt/etc/nixos/hardware-configuration.nix` (disk/filesystem layout) and a stub
`configuration.nix`. **We keep the hardware-configuration.nix and discard the stub** — the real
config comes from the flake. Save the generated hardware config; Claude Code will drop it into
`hosts/heimdall/hardware-configuration.nix` (Phase 3).

```bash
cat /mnt/etc/nixos/hardware-configuration.nix   # copy this out, or scp it to mjolnir
```

> **Bootloader note for Claude Code:** this VM is **UEFI/systemd-boot**. Ensure the effective
> boot config for heimdall is:
> ```nix
> boot.loader.systemd-boot.enable = true;
> boot.loader.efi.canTouchEfiVariables = true;
> ```
> Check `modules/system/boot.nix` — if it's GRUB/BIOS-specific for mjolnir's bare metal, add a
> **host-local** boot setting in `hosts/heimdall/` instead of changing the shared module.

---

## 6. PHASE 3 — Repo rename `nix-services` → `heimdall` (Claude Code, on mjolnir)

Do this in the `nixos-dotfiles` repo on a feature branch, then Christina reviews + merges.

### 6.1 Move the host directory
```bash
git mv hosts/nix-services hosts/heimdall
```

### 6.2 `flake.nix`
Find the `nix-services` entry under `nixosConfigurations` and rename it, preserving the existing
`mkHost` call signature — only the attribute name and path change:
```nix
# before:  nix-services = mkHost ./hosts/nix-services/default.nix ... ;
# after:
heimdall = mkHost ./hosts/heimdall/default.nix ... ;
```
(Match whatever arity `mkHost` actually uses in this repo — don't invent args.)

### 6.3 `hosts/heimdall/default.nix` — full file
Replace with this (hostName → heimdall, static IP, SSH lockdown kept, stateVersion 25.11):
```nix
{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix

    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix
    ../../modules/system/tailscale.nix

    ./modules/system/acme.nix
    ./modules/system/traefik.nix
    ./modules/system/nas.nix
    ./modules/system/immich.nix
    ./modules/system/nextcloud.nix
    ./modules/system/crafty.nix
    ./modules/system/homepage.nix
    ./modules/system/paperless.nix
    ./modules/system/grafana.nix
    ./modules/system/prometheus.nix
    ./modules/system/loki.nix
#   ./modules/system/promtail.nix
    ./modules/system/postgres-exporter.nix
    ./modules/system/blackbox-exporter.nix
    ./modules/system/nexterm.nix
    ./modules/system/scrutiny.nix
  ];

  networking.hostName = "heimdall";
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [{
    address = "10.0.20.17";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.20.1";
  networking.nameservers = [ "10.0.20.4" ];   # Pi-hole — resolves *.oryxserver.org
  networking.firewall.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  environment.systemPackages = with pkgs; [
    git vim curl wget htop tree jq
  ];

  # Keep 25.11 — service data on odyn's NFS expects it. Do NOT bump to 26.05.
  system.stateVersion = "25.11";
}
```
> **SSH-lockout guard:** because `PasswordAuthentication=false` and `PermitRootLogin=no`,
> Christina's SSH **public key must be present** (via `modules/system/users.nix`) before the
> first switch, or she's locked to the Proxmox console. Confirm her key is in `users.nix`.

### 6.4 Drop in the generated hardware config
Replace `hosts/heimdall/hardware-configuration.nix` with the one generated in §5.5 (the new
VM's disk layout, by-label `nixos` + `BOOT`, UEFI). Do **not** reuse the old nix-services one.

### 6.5 Find & fix every remaining `nix-services` reference
```bash
git grep -n "nix-services"
```
Expected hits and how to handle each:
- **`hosts/heimdall/modules/system/traefik.nix`** — any router/service names or comments
  referencing `nix-services`; rename to `heimdall`. Confirm Traefik still serves
  `immich.oryxserver.org`, `nextcloud.oryxserver.org`, etc., and that the entrypoint binds to
  `10.0.20.17` (or `0.0.0.0`).
- **`hosts/heimdall/modules/system/acme.nix`** — wildcard `*.oryxserver.org` via Cloudflare
  DNS-01. Hostname references → `heimdall`. The cert itself is wildcard, so no per-host cert
  change needed.
- **`hosts/heimdall/modules/system/nas.nix`** — **verify the NFS server IP is `10.0.20.6`**
  (Christina already fixed mjolnir's copy in commit "fix truenas IP in nas.nix"; make sure
  heimdall's copy matches). Mount paths point at `odyn:/mnt/vault/<share>`.
- **`README.md`** and **`docs/nixos-structure.md`** — replace the `nix-services` host entry in
  the host table, the flake example, the service-stack section, and the deploy workflow with
  `heimdall`. (Earlier rewritten versions of both exist; mirror their structure.)
- **`network/`** docs, homepage config, prometheus scrape targets, grafana datasource URLs,
  any `*.oryxserver.org` mentions — update host label/target to `heimdall` / `10.0.20.17`.

### 6.6 Validate
```bash
nix flake check        # or at least: nix flake show  → confirms heimdall builds, nix-services gone
```
Active flake hosts after this should be: **mjolnir**, **heimdall** (no more nix-services).
Commit on the branch; Christina reviews and pushes.

---

## 7. PHASE 4 — Deploy onto the VM (Christina + Claude Code)

With partitions mounted at `/mnt` (from Phase 2) and the repo rename pushed:

```bash
# in the live ISO, with /mnt mounted and internet (DHCP) working:
nix-shell -p git nixos-install-tools

# bring the flake in (clone over https to avoid needing the deploy key on the ISO):
git clone https://github.com/jivsan/nixos-dotfiles /mnt/etc/nixos/dotfiles
cd /mnt/etc/nixos/dotfiles

# put the freshly-generated hardware-configuration.nix into the repo location
cp /mnt/etc/nixos/hardware-configuration.nix hosts/heimdall/hardware-configuration.nix

# install from the flake
nixos-install --flake .#heimdall
# set root password when prompted (or rely on users.nix), then:
reboot
```

On reboot it should come up **static at `10.0.20.17`** on VLAN 20. If anything network-related
misbehaves, the Proxmox console is the fallback (don't lock out over SSH).

> If `nixos-install` wants to fetch flake inputs and the ISO's DNS is flaky, set
> `echo "nameserver 1.1.1.1" > /etc/resolv.conf` in the live session first.

---

## 8. PHASE 5 — Verify, then decommission old VM

After heimdall boots at `10.0.20.17`:
```bash
# from heimdall:
ping -c2 10.0.20.1            # gateway
ping -c2 github.com          # DNS
mount | grep vault           # NFS mounts from 10.0.20.6 present?
systemctl --failed           # any failed service units?
systemctl status traefik
```
Checklist:
- [ ] NFS shares from `odyn` (`10.0.20.6:/mnt/vault/*`) mounted (needs odyn exports to allow
      `10.0.20.0/24` — see companion doc).
- [ ] Traefik up; `immich.oryxserver.org`, `nextcloud.oryxserver.org`, etc. resolve (Pi-hole)
      and serve with valid `*.oryxserver.org` TLS (Cloudflare DNS-01).
- [ ] Grafana / Prometheus / Loki reachable; Prometheus scraping heimdall + other hosts.
- [ ] Immich / Nextcloud / Paperless load with their data intact (it's on NFS).
- [ ] Tailscale back up on heimdall (`tailscale status`).

**Only after all green:** decommission the old VM on hella:
```bash
qm stop 153
qm destroy 153 --purge    # ONLY once heimdall is fully verified — ask Christina first
```
Also apply the **same `firewall=0` fix** to any other VM that still has `firewall=1` with a VLAN
tag (e.g. VMID 151 / proxmox-backup-server) so it doesn't hit the same tap-on-VLAN-1 bug:
```bash
qm set 151 --net0 virtio=<MAC>,bridge=vmbr1,tag=20    # no firewall=1
qm stop 151 && qm start 151
```

---

## 9. Quick reference

- **Active hosts (post-rename):** `mjolnir` (workstation), `heimdall` (services VM on hella).
- **Aesthetic:** Tokyo Night — pink `#ff4fa3`, cyan `#2de2e6`, JetBrainsMono Nerd Font.
- **Internal domain:** `oryxserver.org`, wildcard cert via Cloudflare DNS-01, Traefik fronts all.
- **Prereq before heimdall services work:** odyn online with single 10G link + NFS exports
  updated to `10.0.20.0/24` → see `odyn-10g-single-link.md`.
