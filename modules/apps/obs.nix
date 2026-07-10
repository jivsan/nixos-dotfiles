{ pkgs, ... }:
# ── OBS Studio on mjolnir — record straight to odyn over the 10GbE leg ──────
# Recordings land in ~/OBS-recordings, which is the odyn NFS dataset
# vault/OBS-recordings (recordsize=1M, mapall→christina, export scoped to
# VLAN 20). Even 4K60 NVENC (~100 Mbit/s) is nothing next to 10GbE, so no
# local staging is needed. In OBS: Settings → Output → Recording Path
# = ~/OBS-recordings, container MKV (remux to mp4 after — survives crashes
# and mount hiccups mid-recording, unlike mp4).
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
    ];
  };
}
