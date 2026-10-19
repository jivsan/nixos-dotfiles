{ ... }:

# odyn dataset vault/hermes-wowx (NFS share 13, every client mapped to the NAS user
# christina, uid 3002): WoW models exported by wowx and their Upscayl upscales. Mounted
# at the same path on mjolnir, where wowx and Upscayl run, and on yggdrasil, where hermes
# reads and writes them, so a path one of them reports works on the other.
{
  fileSystems."/mnt/hermes-wowx" = {
    device = "10.0.20.6:/mnt/vault/hermes-wowx";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "soft"
      "noatime"
      "_netdev"
      "nofail"
      "rsize=1048576"
      "wsize=1048576"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      # No x-gvfs-show: Files would mount it as her user and NixOS has no setuid
      # mount.nfs ("user" NFS mounts not supported). It is a bookmark in
      # ~/.config/gtk-3.0/bookmarks instead; opening that wakes the automount.
    ];
  };
}
