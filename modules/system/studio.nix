{ config, lib, ... }:

# odyn datasets vault/studio and vault/studio-cache (NFS shares 14 and 15, every client
# mapped to the NAS user christina, uid 3002). The studio holds all Blender files and
# projects: 3DBLENDER and the other folders she uses for Blender, moved off mjolnir's
# data SSD in 2026-10. It has hourly (2 days), daily (30 days) and weekly (12 weeks)
# snapshots, so older versions of a file are under /mnt/studio/.zfs/snapshot/. The cache
# is for sim caches and job scratch (mimir-blender's job folders) and has none. Same
# paths on mjolnir, mimir and yggdrasil.
let
  moved = import ./studio-folders.nix;

  share = name: extra: {
    device = "10.0.20.6:/mnt/vault/${name}";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      # hard, unlike the other shares: when odyn hiccups, Blender waits instead of
      # getting a write error halfway through saving a file.
      "hard"
      "noatime"
      "_netdev"
      "nofail"
      "rsize=1048576"
      "wsize=1048576"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=30"
    ] ++ extra;
  };
in
{
  # In the Files sidebar as a bookmark (~/.config/gtk-3.0/bookmarks on mjolnir), not
  # x-gvfs-show: Files would try to mount the NFS share as her user, which NixOS refuses.
  fileSystems."/mnt/studio" = share "studio" [ ];
  fileSystems."/mnt/studio-cache" = share "studio-cache" [ ];

  # The old paths keep working: .blend files, scripts and notes point at
  # /mnt/data_ssd/<folder>. On mjolnir those links sit on the data SSD itself (made by
  # hand when the folders moved), so they are only declared on hosts without that disk.
  # Plain L never replaces a file or folder that is already there.
  systemd.tmpfiles.rules = lib.mkMerge [
    (lib.mkIf (!(config.fileSystems ? "/mnt/data_ssd")) (
      [ "d /mnt/data_ssd 0755 root root -" ]
      ++ map (d: ''L "/mnt/data_ssd/${d}" - - - - /mnt/studio/${d}'') moved
    ))
    # Her Blender preferences keep four asset libraries (Fia base/extra, Sanctus,
    # Strandkit) under /mnt/data-ssd/3DBLENDER, with a dash; this makes them resolve.
    [ "L /mnt/data-ssd - - - - /mnt/data_ssd" ]
  ];
}
