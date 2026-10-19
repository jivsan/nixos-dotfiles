{ ... }:

# wow models from wowx and their upscayl upscales, on odyn. same path on mjolnir (wowx and
# upscayl run there) and yggdrasil (hermes uses them), so a path one reports works on the other
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
      # no x-gvfs-show: files would mount it as my user, and nixos has no setuid mount.nfs.
      # it's a bookmark in ~/.config/gtk-3.0/bookmarks instead, opening it wakes the automount
    ];
  };
}
