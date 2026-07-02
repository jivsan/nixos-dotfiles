# Deploying a New NixOS Host

How to bring a new machine (bare metal or Proxmox VM) into the fleet from
[`jivsan/nixos-dotfiles`](https://github.com/jivsan/nixos-dotfiles).

**The philosophy:** mjolnir is the source of truth. Hosts only ever *pull* from
GitHub — never hand-edit configs on a running host. The single exception is
`hardware-configuration.nix`, which must be **generated on the machine itself**
during install and then ferried back into the repo (Phase 4).

_Last verified against NixOS 26.05 "Yarara" · flake with `mkHost` pattern · July 2026_

| Phase | What happens | Where |
|-------|--------------|-------|
| 1 | Define the host in the repo | **mjolnir** |
| 2 | Create the VM *(VM hosts only)* | **Proxmox web UI (hella)** |
| 3 | Partition disks, generate hardware config, install | **target machine**, booted from the NixOS ISO |
| 4 | First-boot checks, sync hardware config back to the repo | **new host** + **mjolnir** |
| 5 | Ongoing rebuilds | **mjolnir** (edit + push) → **host** (pull + switch) |

---

## 0 · Mental model — how a machine maps to the repo

Each host is one line in `flake.nix`:

```nix
nixosConfigurations = {
  mjolnir  = mkHost ./hosts/mjolnir/default.nix  ./hosts/mjolnir/home.nix;
  heimdall = mkHost ./hosts/heimdall/default.nix ./hosts/heimdall/home.nix;
  mimir    = mkHost ./hosts/mimir/default.nix    ./hosts/mimir/home.nix;
};
```

…and one directory:

```
hosts/<name>/
├── default.nix                  # imports + networking + host identity
├── home.nix                     # home-manager for christina on this host
├── hardware-configuration.nix   # GENERATED ON THE MACHINE — placeholder until install
└── modules/                     # optional host-local modules (mimir pattern)
```

Shared fleet behaviour lives in `modules/system/` and `modules/home/`.
Two consequences worth internalising:

- `modules/system/boot.nix` enables **systemd-boot** → every install in this
  fleet is a **UEFI** install. No exceptions, no BIOS/MBR.
- `modules/system/users.nix` bakes in **christina + SSH key + passwordless
  sudo** → every host is SSH-able as christina from mjolnir on first boot.

Network conventions (VLAN 20, trusted): static IPs on `10.0.20.0/24`,
gateway `10.0.20.1`, DNS `10.0.20.4` (Pi-hole, resolves `*.oryxserver.org`).

---

## 1 · Phase 1 — Define the host in the repo

**Where: mjolnir**, in `~/nixos-dotfiles`.

### 1.1 Decide identity

- **Hostname** — Norse, per tradition.
- **Static IP** — pick a free `10.0.20.x` (check pfSense / Pi-hole for taken
  leases and the other `hosts/*/default.nix` files for assigned statics).
- **NIC name guess** — Proxmox VMs are `ens18`. Bare metal is usually
  `enpXsY` / `enoX` and **cannot be known for sure until the machine boots**
  (verified in Phase 3.7).

### 1.2 Create `hosts/<name>/`

```bash
cd ~/nixos-dotfiles
mkdir -p hosts/<name>
```

**`hosts/<name>/default.nix`** — full template, trim to taste:

```nix
{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix

    # ── shared fleet modules ──
    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix       # christina + SSH key + passwordless sudo
    ../../modules/system/tailscale.nix

    # ── host-local modules go here (create hosts/<name>/modules/ as needed) ──
    # ./modules/system/something.nix
  ];

  networking.hostName = "<name>";
  networking.useDHCP = false;

  # ⚠️ NIC name is a GUESS until verified on the box (`ip -br link`, Phase 3.7).
  # Proxmox VMs: ens18 · bare metal: usually enpXsY / enoX.
  networking.interfaces.ens18.ipv4.addresses = [{
    address = "10.0.20.XX";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.20.1";
  networking.nameservers = [ "10.0.20.4" ];   # Pi-hole
  networking.firewall.enable = true;          # open service ports explicitly!

  # Proxmox VMs only — delete on bare metal:
  # services.qemuGuest.enable = true;

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

  # Current NixOS release AT INSTALL TIME. Set once, NEVER change afterwards —
  # it records which release first created this host's state.
  system.stateVersion = "26.05";
}
```

**`hosts/<name>/home.nix`** — minimal server baseline:

```nix
{ config, pkgs, ... }:
{
  home.stateVersion = "26.05";

  imports = [
    ../../modules/home/git.nix
    ../../modules/home/shell.nix
  ];
}
```

**`hosts/<name>/hardware-configuration.nix`** — the placeholder stub. It only
exists so the flake evaluates before the machine is installed:

```nix
# ============================================================================
#  PLACEHOLDER — DO NOT DEPLOY AS-IS
# ============================================================================
# This stub only exists so the flake evaluates before <name> is installed.
# It is REPLACED during install (Phase 3.6) with the config generated on the
# machine itself, then synced back to this repo (Phase 4.3).
# The device labels below are fake and will NOT boot real hardware.
# ============================================================================
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];   # "kvm-intel" on Intel hosts / Proxmox VMs
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
```

### 1.3 Register in `flake.nix`

Add one line to `nixosConfigurations`:

```nix
<name> = mkHost ./hosts/<name>/default.nix ./hosts/<name>/home.nix;
```

### 1.4 Sanity-check, commit, push

```bash
nix flake show          # new host listed under nixosConfigurations?
git add hosts/<name> flake.nix
git commit -m "<name>: initial host definition"
git push
```

---

## 2 · Phase 2 — Create the VM (VM hosts only)

**Where: Proxmox web UI on hella.** Bare metal → skip to Phase 3.

| Setting | Value | Why |
|---------|-------|-----|
| BIOS / Firmware | **OVMF (UEFI)** + add an **EFI disk** | systemd-boot requires UEFI |
| EFI disk → Pre-Enroll keys | **UNCHECKED** | pre-enrolled Secure Boot keys refuse to boot unsigned systemd-boot |
| Machine | q35 | modern PCIe layout |
| SCSI Controller | VirtIO SCSI single | disk shows up as `/dev/sda` |
| Disk | scsi0, size to taste; enable *Discard* on thin storage | |
| CPU | type = `host` | |
| Network | VirtIO, trunk bridge, **VLAN Tag = 20** | |
| Network → Firewall | **UNCHECKED** | ⚠️ **`firewall=1` on a NIC with a VLAN tag silently breaks tag propagation** through the firewall bridge (hard-won hella lesson) |
| CD/DVD | latest NixOS ISO (minimal is fine for servers) | |

Boot order: ISO first for the install, disk after.

---

## 3 · Phase 3 — Install on the target machine

**Where: the target machine**, booted from the NixOS installer ISO/USB.
All commands as root (`sudo -i` on the graphical ISO).

### 3.1 Verify the installer booted in UEFI mode

```bash
ls /sys/firmware/efi/efivars >/dev/null 2>&1 && echo "UEFI ✅" || echo "BIOS ❌ — reboot in UEFI mode"
```

Must say UEFI. If not, fix the boot mode in the firmware/boot menu — a BIOS
install will not work with `systemd-boot`.

### 3.2 Identify the target disk

Device letters are **not stable** — with NVMe + SATA + SAS controllers
enumerating, "sdb" today can be "sdc" tomorrow. Confirm by **size and model**:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,TYPE
```

Note the target's device name (`/dev/sdX` below — **replace X everywhere**).
Double-check you are *not* about to wipe a data disk, an NVMe reserved for
later, or future ZFS members.

### 3.3 Partition — GPT: ESP + swap + root

Standard layout (1 GiB ESP, 16 GiB swap, root = rest):

```bash
parted /dev/sdX -- mklabel gpt
parted /dev/sdX -- mkpart ESP  fat32      1MiB   1GiB
parted /dev/sdX -- set 1 esp on
parted /dev/sdX -- mkpart swap linux-swap 1GiB   17GiB
parted /dev/sdX -- mkpart root ext4       17GiB  100%
```

Result: `sdX1` = ESP, `sdX2` = swap, `sdX3` = root.

**Swap sizing:** 16 GiB is a sane bare-metal default. VMs typically skip swap
entirely (heimdall runs none) — then it's just two partitions:

```bash
parted /dev/sdX -- mklabel gpt
parted /dev/sdX -- mkpart ESP  fat32 1MiB 1GiB
parted /dev/sdX -- set 1 esp on
parted /dev/sdX -- mkpart root ext4  1GiB 100%
```

### 3.4 Format (with labels)

```bash
mkfs.fat -F 32 -n BOOT /dev/sdX1
mkswap        -L swap  /dev/sdX2      # skip if no swap partition
mkfs.ext4     -L nixos /dev/sdX3      # sdX2 in the no-swap layout
```

Labels give stable `/dev/disk/by-label/*` paths regardless of device-letter
shuffling. (The installed system will use `by-uuid` paths captured by
`nixos-generate-config` — same idea, keyed on the filesystem UUID.)

### 3.5 Mount + enable swap

```bash
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=077 /dev/disk/by-label/BOOT /mnt/boot
swapon /dev/disk/by-label/swap        # skip if no swap
```

### 3.6 Clone the repo and generate the real hardware config

```bash
nix-shell -p git      # minimal ISO only — graphical ISO ships git

git clone https://github.com/jivsan/nixos-dotfiles /mnt/etc/nixos
cd /mnt/etc/nixos

# Generate from the ACTUAL mounted disks, straight over the placeholder:
nixos-generate-config --root /mnt --show-hardware-config \
  > hosts/<name>/hardware-configuration.nix

cat hosts/<name>/hardware-configuration.nix
```

Sanity-check the output: `/` is ext4 `by-uuid`, `/boot` is vfat `by-uuid`,
swap listed if created, and on Proxmox VMs the `qemu-guest.nix` profile import
appears.

> `/mnt` is the new system's root — this clone **persists after reboot as
> `/etc/nixos`** on the installed machine, including this generated file.
> That's how it gets ferried back to the repo in Phase 4.

### 3.7 Verify the NIC name

```bash
ip -br link
```

Compare against `networking.interfaces.<nic>` in `hosts/<name>/default.nix`:

- **Matches** → carry on.
- **Doesn't match** → either fix the interface name in the file right here in
  the installer, or (for a quick test install) flip to DHCP: comment out the
  `interfaces` / `defaultGateway` / `nameservers` block and set
  `networking.useDHCP = true;`. Whatever you change here gets replicated on
  mjolnir in Phase 4.3.

### 3.8 Install

**Flakes only see git-*tracked* files.** The generated hardware config is a
new file and *must* be `git add`-ed or the build fails with "path does not
exist". (Edits to already-tracked files are picked up automatically — no
commit needed.)

```bash
git add hosts/<name>/hardware-configuration.nix
nixos-install --flake /mnt/etc/nixos#<name>
```

- Set a **root password** at the prompt — it's your console rescue login
  (`PermitRootLogin no` keeps it off SSH; day-to-day access is christina + key).
- Heavy hosts (GPU stacks, AI services) make the first build long. For a fast
  "does it boot" pass, comment out the heavy host-local imports in
  `default.nix` first and rebuild them in after first boot.

```bash
reboot        # pull the USB / detach the ISO as it goes down
```

---

## 4 · Phase 4 — First boot & sync back to the repo

### 4.1 Get a shell — **where: new host**

SSH as christina from mjolnir (key + passwordless sudo are baked in via
`users.nix`):

```bash
ssh christina@10.0.20.XX      # or the DHCP lease if you flipped it
```

Fallback: console as root with the install-time password.

### 4.2 Health checks

```bash
ip -br addr          # expected IP on the expected NIC?
systemctl --failed   # should be empty
bootctl status       # systemd-boot healthy
ss -tlnp             # expected services listening
nvidia-smi           # GPU hosts only
```

### 4.3 Ferry the hardware config back — **where: mjolnir**

The generated file lives on the new host at
`/etc/nixos/hosts/<name>/hardware-configuration.nix` (the install-time clone).
Pull it into the source-of-truth clone and push:

```bash
scp christina@10.0.20.XX:/etc/nixos/hosts/<name>/hardware-configuration.nix \
    ~/nixos-dotfiles/hosts/<name>/hardware-configuration.nix

cd ~/nixos-dotfiles
# If you edited anything else in the installer (NIC name, DHCP flip,
# commented-out modules) — make the SAME edits here now.
git add hosts/<name>/hardware-configuration.nix
git commit -m "<name>: real hardware-configuration from install"
git push
```

### 4.4 Set up the working clone — **where: new host**

```bash
git clone https://github.com/jivsan/nixos-dotfiles ~/nixos-dotfiles
cd ~/nixos-dotfiles
sudo nixos-rebuild switch --flake .#<name>    # should be a near no-op — confirms the loop
```

The leftover install-time clone at `/etc/nixos` is now unused (flake rebuilds
run from `~/nixos-dotfiles`). Leave it or `sudo rm -rf /etc/nixos` — either is
fine.

---

## 5 · Phase 5 — Ongoing management

### The canonical loop (pull-based)

```bash
# mjolnir: edit → commit → push
cd ~/nixos-dotfiles
$EDITOR hosts/<name>/default.nix
git commit -am "<name>: describe change" && git push

# host: pull → switch
cd ~/nixos-dotfiles
git pull
sudo nixos-rebuild switch --flake .#<name>
```

### Alternative: push a rebuild from mjolnir (no SSH-in needed)

`users.nix` provides everything this needs (key auth + passwordless sudo):

```bash
# mjolnir — builds locally on the 5900X, copies closures to the host, switches:
nixos-rebuild switch --flake ~/nixos-dotfiles#<name> \
  --target-host christina@10.0.20.XX --use-remote-sudo
```

Handy for weak hosts (mjolnir does the compiling) and quick iterations. It
deploys from mjolnir's **working tree**, so still push to GitHub afterwards to
keep the host's `~/nixos-dotfiles` from drifting.

Garbage collection is already fleet-wide (`nix.gc`, weekly, 7-day retention in
`modules/system/nix.nix`) — nothing to set up per host.

---

## 6 · Gotchas

- **"path does not exist" during install/rebuild** → a *new* file isn't
  git-tracked. `git add` it. (Flakes copy the worktree but ignore untracked
  files.)
- **`nixos-install` can't install the bootloader / no efivars** → the ISO was
  booted in BIOS mode. Reboot the stick in UEFI mode (3.1).
- **VM boots to UEFI shell / "no bootable device"** → OVMF EFI disk was
  created with pre-enrolled Secure Boot keys. Disable Secure Boot in the OVMF
  menu, or recreate the EFI disk with *Pre-Enroll keys* unchecked.
- **Host boots but is off the network** → NIC name mismatch. Console in as
  root, `ip -br link`, fix the name in the config, rebuild. This is why 3.7
  exists.
- **Proxmox VM gets no traffic on its VLAN** → `firewall=1` on a tagged NIC.
  Turn the NIC firewall **off** (Phase 2 table).
- **Wrong disk letters after adding hardware** → expected; this is why
  everything is `by-uuid`/`by-label` and ZFS uses `by-id`.
- **`stateVersion`** → set to the release current at install time, then
  **never change it**, even across upgrades. It is not "the version you run".
- **`nix` on the ISO complains about experimental features** → prefix
  `--extra-experimental-features "nix-command flakes"`
  (`nixos-install --flake` itself works out of the box on current ISOs).
- **New service unreachable** → `networking.firewall.enable = true` is the
  fleet default; open ports explicitly with
  `networking.firewall.allowedTCPPorts`.

---

## Appendix A — Extra data disks / ZFS come *after* first boot

Pool creation is deliberately **not** part of the install. Get the OS booting
on a single disk first, then add storage as a separate, revertible step:

```nix
# host-local storage module, added post-install:
boot.supportedFilesystems = [ "zfs" ];
networking.hostId = "xxxxxxxx";        # head -c 8 /etc/machine-id — unique per host, REQUIRED by ZFS
boot.zfs.extraPools = [ "<pool>" ];    # import pools not listed in fileSystems
```

Create pools with stable `/dev/disk/by-id/...` paths, never `/dev/sdX`. Full
walkthrough lives with the mimir scratch/archive pool notes.

## Appendix B — Checklist

```
Phase 1 — mjolnir
[ ] hosts/<name>/ created: default.nix · home.nix · placeholder hardware-configuration.nix
[ ] registered in flake.nix nixosConfigurations · nix flake show lists it
[ ] hostname + free 10.0.20.x picked · NIC guess noted · stateVersion = current release
[ ] committed + pushed

Phase 2 — Proxmox (VMs only)
[ ] OVMF + EFI disk, Pre-Enroll keys UNCHECKED
[ ] VirtIO SCSI · CPU host · NIC VLAN tag 20 · NIC firewall OFF

Phase 3 — target machine (ISO)
[ ] booted UEFI (efivars present)
[ ] target disk confirmed by size/model
[ ] GPT: ESP (+ swap) + root · labels BOOT / swap / nixos
[ ] mounted at /mnt (+ /mnt/boot umask=077) · swapon
[ ] repo cloned to /mnt/etc/nixos
[ ] hardware config generated into hosts/<name>/ · sanity-checked · git add-ed
[ ] NIC verified with ip -br link (config fixed or DHCP-flipped if needed)
[ ] nixos-install --flake /mnt/etc/nixos#<name> · root password set · rebooted

Phase 4 — first boot
[ ] SSH in as christina · IP correct · systemctl --failed clean · bootctl ok
[ ] mjolnir: hardware-configuration.nix scp'd back (+ any installer edits replicated) · committed · pushed
[ ] host: ~/nixos-dotfiles cloned · nixos-rebuild switch --flake .#<name> clean
```
