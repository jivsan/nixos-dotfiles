#!/usr/bin/env bash
# Installs the elitebook (HP EliteBook 8540p, old-style BIOS) from mjolnir. Wipes the target disk.
#
# On the laptop first:
#   BIOS (Esc, then F10 at power on):
#     Boot Options: UEFI Boot Mode Disabled, USB boot on (for the install)
#     Device Configurations: SATA AHCI, Fan Always on while on AC Power on
#     Built-In Device Options: wireless off, Wake on LAN Follow Boot Order
#     never set up Intel AMT and never flash the BIOS (no battery: a power blip bricks it)
#   Boot the NixOS 26.05 minimal ISO from USB (F9 boot menu), network cable in, then on its console:
#     sudo mkdir -p /root/.ssh && curl -sL https://github.com/jivsan.keys | sudo tee /root/.ssh/authorized_keys
#     ip -4 a        # the address to give this script
#
#   hosts/elitebook/install.sh <installer-ip>              lists the disks and stops
#   hosts/elitebook/install.sh <installer-ip> /dev/sdX     installs (asks before wiping)
#
# It writes the laptop's real hardware-configuration.nix into this clone: commit it afterwards.
set -euo pipefail

ip=${1:?usage: install.sh <installer-ip> [disk]}
disk=${2:-}
target="root@$ip"
flake=$(cd "$(dirname "$0")/../.." && pwd)
hw="$flake/hosts/elitebook/hardware-configuration.nix"
opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
# shellcheck disable=SC2029  # commands are meant to expand here, before they are sent
t() { ssh -n "${opts[@]}" "$target" "$@"; }

t 'ls /sys/firmware/efi > /dev/null 2>&1' && { echo "The ISO booted in UEFI mode: turn UEFI Boot Mode off in the BIOS and boot it again."; exit 1; }
t lsblk -d -o NAME,SIZE,MODEL,TRAN,TYPE
if [ -z "$disk" ]; then echo "Run again with the disk to install on, e.g. /dev/sda."; exit 0; fi
read -r -p "ERASE $disk on $ip and install the elitebook? Type the disk name again: " again
[ "$again" = "$disk" ] || { echo "Not confirmed, nothing changed."; exit 1; }

# grub goes in the mbr of this disk, by id so it can't hit the usb stick after a reboot
byid=$(t "for l in /dev/disk/by-id/ata-* /dev/disk/by-id/wwn-*; do
            case \$l in *-part*) continue ;; esac
            [ \"\$(readlink -f \$l)\" = $disk ] && { echo \$l; break; }
          done")
[ -n "$byid" ] || { echo "No /dev/disk/by-id name for $disk, is it the internal sata disk?"; exit 1; }
echo "==> grub goes on $byid"

echo "==> partitions: msdos label, one ext4 root labelled nixos (no esp on a bios install)"
t "set -e
   wipefs -af $disk
   parted -s $disk mklabel msdos mkpart primary ext4 1MiB 100% set 1 boot on
   udevadm settle
   p1=\$(lsblk -lnpo NAME $disk | sed -n 2p)
   mkfs.ext4 -q -F -L nixos \$p1
   udevadm settle
   mount /dev/disk/by-label/nixos /mnt"

echo "==> hardware-configuration.nix from the laptop, plus the grub disk"
{
  echo "# generated on the elitebook by install.sh (nixos-generate-config), plus the disk grub goes on"
  t nixos-generate-config --root /mnt --show-hardware-config | sed '$d'
  echo
  echo "  boot.loader.grub.device = \"$byid\";"
  echo "}"
} > "$hw.new"
mv "$hw.new" "$hw"
git -C "$flake" add hosts/elitebook/hardware-configuration.nix
grep -n 'fileSystems\|device\|availableKernelModules' "$hw"

echo "==> system: built here from the caches (the laptop is slow), copied over, installed"
top=$(nix build --no-link --print-out-paths "$flake#nixosConfigurations.elitebook.config.system.build.toplevel")
NIX_SSHOPTS="${opts[*]}" nix copy --to "ssh://$target?remote-store=local?root=/mnt" "$top"
t nixos-install --root /mnt --system "$top" --no-root-passwd --no-channel-copy

echo
echo "Installed. Next:"
echo "  ssh ${opts[*]} $target reboot    (pull the usb stick as it goes down)"
echo "  commit hosts/elitebook/hardware-configuration.nix on mjolnir and push"
echo "  ssh christina@10.0.20.22 git clone https://github.com/jivsan/nixos-dotfiles nixos-dotfiles"
