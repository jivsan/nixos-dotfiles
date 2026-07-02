{ config, pkgs, ... }:
{
  # ── ZFS core ──────────────────────────────────────────────────────────
  boot.supportedFilesystems = [ "zfs" ];

  # ZFS refuses to auto-import pools whose hostid doesn't match the system.
  # PINNED so it survives the NVMe reinstall — pools import on the fresh
  # system with zero fuss. Generated once via `head -c 8 /etc/machine-id`.
  # ⚠️ NEVER change after pools are created.
  networking.hostId = "de34016a"; 

  # No ZFS root on this box — silences the forceImportRoot warning.
  boot.zfs.forceImportRoot = false;

  # Data pools to import at boot. NOT declared in fileSystems /
  # hardware-configuration.nix — ZFS mounts these itself.
  boot.zfs.extraPools = [ "scratch" ];
  # boot.zfs.extraPools = [ "scratch" "brunnr" ];   # ← when the SAS mirror exists

  boot.kernelParams = [ "zfs.zfs_arc_max=8589934592" ];

  # ── housekeeping ──────────────────────────────────────────────────────
  services.zfs.trim.enable = true;      # periodic TRIM (SSD stripe)
  services.zfs.autoScrub = {
    enable = true;                      # checksum verification pass
    interval = "monthly";
  };
}
