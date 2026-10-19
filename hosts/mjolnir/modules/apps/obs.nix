{ pkgs, ... }:
# obs records straight to odyn: ~/OBS-recordings is the dataset vault/OBS-recordings.
# in obs: recording path ~/OBS-recordings, mkv (survives a crash or mount hiccup), remux to mp4 after
{
  programs.obs-studio.enable = true;

  boot.supportedFilesystems = [ "nfs" ];

  fileSystems."/home/christina/OBS-recordings" = {
    device = "10.0.20.6:/mnt/vault/OBS-recordings";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "soft"
      "noatime"
      "_netdev"
      "nofail"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=30"
      "retry=2"
      "x-gvfs-hide"   # not in the files sidebar, obs still sees it
    ];
  };
}
