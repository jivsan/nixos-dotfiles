# ============================================================================
#  PLACEHOLDER — DO NOT DEPLOY AS-IS
# ============================================================================
# This stub only exists so the flake evaluates before mimir is installed.
# Before the first real `nixos-rebuild`, REPLACE this file with the one
# generated ON mimir (exactly like we did for heimdall):
#
#   # on mimir, after `nixos-install` (or booted):
#   nixos-generate-config --show-hardware-config
#   # copy the output over this file, commit + push, THEN build .#mimir
#
# The device labels below are fake and will NOT boot real hardware.
# ============================================================================
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];   # Ryzen host (matches your other boxes); change if Intel
  boot.extraModulePackages = [ ];

  # TODO(replace): real UUIDs/labels from the installed disk
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
