{ config, pkgs, ... }:
{
  # zfs scratch pool. not imported: the ssds are out of mimir (see default.nix)
  boot.supportedFilesystems = [ "zfs" ];

  # pinned: zfs won't auto-import pools with another hostid, never change it once pools exist
  networking.hostId = "de34016a"; 

  # no zfs root here, this silences the forceImportRoot warning
  boot.zfs.forceImportRoot = false;

  # zfs mounts these itself, so they're not in fileSystems
  boot.zfs.extraPools = [ "scratch" ];
  # boot.zfs.extraPools = [ "scratch" "brunnr" ];   # once the sas mirror exists

  boot.kernelParams = [ "zfs.zfs_arc_max=8589934592" ];

  services.zfs.trim.enable = true;
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };
}
