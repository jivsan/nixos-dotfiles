{ config, lib, ... }:

# /mnt/studio (all my blender files and projects) and /mnt/studio-cache (sim caches and
# job scratch, no snapshots) on odyn, same paths on mjolnir, mimir and yggdrasil
# old versions of a studio file are in /mnt/studio/.zfs/snapshot/
let
  moved = import ./studio-folders.nix;

  share = name: extra: {
    device = "10.0.20.6:/mnt/vault/${name}";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      # hard, unlike my other shares: on an odyn hiccup blender waits instead of
      # failing halfway through saving a file
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
  # no x-gvfs-show: files would mount it as my user, which nixos refuses.
  # it's a bookmark in ~/.config/gtk-3.0/bookmarks on mjolnir instead
  fileSystems."/mnt/studio" = share "studio" [ ];
  fileSystems."/mnt/studio-cache" = share "studio-cache" [ ];

  # the old /mnt/data_ssd/<folder> paths in my .blend files and scripts keep working.
  # on mjolnir those links are on the data ssd itself (made by hand), so only hosts
  # without that disk declare them. plain L never replaces what's already there
  systemd.tmpfiles.rules = lib.mkMerge [
    (lib.mkIf (!(config.fileSystems ? "/mnt/data_ssd")) (
      [ "d /mnt/data_ssd 0755 root root -" ]
      ++ map (d: ''L "/mnt/data_ssd/${d}" - - - - /mnt/studio/${d}'') moved
    ))
    # my blender prefs have four asset libraries under /mnt/data-ssd/3DBLENDER, with a dash
    [ "L /mnt/data-ssd - - - - /mnt/data_ssd" ]
  ];
}
