#!/usr/bin/env bash
# Installs yggdrasil on the ThinkCentre M93p from mjolnir and moves hermod's identity
# (SSH host keys, christina's key, hermes' MCP key and state) onto it. Wipes the target disk.
#
# On the M93p first:
#   BIOS (F1 at power on): UEFI boot only, Secure Boot off, After Power Loss = Power On,
#   Wake on LAN on. Boot the NixOS minimal ISO from USB (UEFI entry), then on its console:
#     sudo mkdir -p /root/.ssh && curl -sL https://github.com/jivsan.keys | sudo tee /root/.ssh/authorized_keys
#     ip -4 a        # the address to give this script
#
#   hosts/yggdrasil/install.sh <installer-ip>              lists the disks and stops
#   hosts/yggdrasil/install.sh <installer-ip> /dev/sdX     installs (asks before wiping and before stopping hermes)
#
# Afterwards: shut hermod down (it holds 10.0.20.21), then reboot the M93p; it comes up as
# yggdrasil on 10.0.20.21 with hermod's host keys, so nothing that knew hermod notices.
set -euo pipefail

ip=${1:?usage: install.sh <installer-ip> [disk]}
disk=${2:-}
target="root@$ip"
hermod=christina@10.0.20.21
flake=$(cd "$(dirname "$0")/../.." && pwd)
opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
# shellcheck disable=SC2029  # commands are meant to expand here, before they are sent
t() { ssh "${opts[@]}" "$target" "$@"; }

t lsblk -d -o NAME,SIZE,MODEL,TRAN,TYPE
if [ -z "$disk" ]; then echo "Run again with the disk to install on, e.g. /dev/sda."; exit 0; fi
read -r -p "ERASE $disk on $ip and install yggdrasil? Type the disk name again: " again
[ "$again" = "$disk" ] || { echo "Not confirmed, nothing changed."; exit 1; }

echo "==> partitions: 1 GiB ESP + ext4 root, by label (see hardware-configuration.nix)"
t "set -e
   wipefs -af $disk
   parted -s $disk mklabel gpt mkpart ESP fat32 1MiB 1GiB set 1 esp on mkpart nixos ext4 1GiB 100%
   udevadm settle
   p1=\$(lsblk -lnpo NAME $disk | sed -n 2p); p2=\$(lsblk -lnpo NAME $disk | sed -n 3p)
   mkfs.fat -F 32 -n ESP \$p1
   mkfs.ext4 -q -F -L nixos \$p2
   udevadm settle
   mount /dev/disk/by-label/nixos /mnt
   mkdir -p /mnt/boot
   mount -o umask=077 /dev/disk/by-label/ESP /mnt/boot"

echo "==> system: built here (the i5-4570T is slow at compiling), copied over, installed"
top=$(nix build --no-link --print-out-paths "$flake#nixosConfigurations.yggdrasil.config.system.build.toplevel")
NIX_SSHOPTS="${opts[*]}" nix copy --to "ssh://$target?remote-store=local?root=/mnt" "$top"
t nixos-install --root /mnt --system "$top" --no-root-passwd --no-channel-copy

read -r -p "Stop hermes on hermod and copy hermod's identity and hermes' state now? [y/N] " ok
[ "$ok" = y ] || { echo "Stopped before touching hermod. The new system is installed but has no hermod state."; exit 1; }
echo "==> hermod -> yggdrasil: host keys, hermes env, hermes state + MCP key, christina's key and files"
ssh "$hermod" 'sudo systemctl stop hermes-agent'
# Home-manager's own links are left out: yggdrasil makes its own. The parent folders go
# first without their contents, so tar does not create them as root.
ssh "$hermod" 'sudo tar -C / --numeric-owner -cpf - \
    --no-recursion home/christina home/christina/.config home/christina/.local home/christina/.local/state --recursion \
    etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub \
    etc/hermes/env var/lib/hermes var/lib/hermes-ssh \
    home/christina/.ssh home/christina/nixos-dotfiles home/christina/blender-stuff home/christina/.bash_history \
    home/christina/.config/herdr home/christina/.local/state/herdr' \
  | t 'tar -C /mnt --numeric-owner -xpf -'

echo
echo "Installed. Next: shut hermod down so 10.0.20.21 is free, then: ssh ${opts[*]} $target reboot"
