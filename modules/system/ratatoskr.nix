{ ... }:

# /mnt/ratatoskr on odyn (the squirrel that runs messages up and down yggdrasil): screenshots,
# snippets and files between me, hermes and claude. same path on mjolnir and yggdrasil.
# odyn lets only those two in and writes everything as me, so hermes' files are mine too.
# deleted files are in /mnt/ratatoskr/.zfs/snapshot/
{
  fileSystems."/mnt/ratatoskr" = {
    device = "10.0.20.6:/mnt/vault/ratatoskr";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "soft"
      "noatime"
      "_netdev"
      "nofail"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=15"
      # no x-gvfs-show (nixos has no setuid mount.nfs): a bookmark in ~/.config/gtk-3.0/bookmarks
    ];
  };
}
