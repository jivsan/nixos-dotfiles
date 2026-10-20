{ ... }:

# brunnr: the two 1.2 tb sas disks as one zfs stripe, only for the nix cache (nix-cache-server.nix) and ci's store (forgejo-runner.nix).
# no redundancy on purpose, everything on it can be downloaded or built again
{
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;   # no zfs root here

  # pinned: zfs only auto-imports pools made with this hostid. never change it
  networking.hostId = "de34016a";

  # arc capped at 1 gib so the ram stays free for octane out-of-core textures
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=1073741824 zfs_arc_min=268435456
  '';

  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };
}
