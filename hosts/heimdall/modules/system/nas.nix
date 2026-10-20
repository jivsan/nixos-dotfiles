{ ... }:
let
  # obsidian.nix has the same list, keep them in step
  commonOpts = [
    "nfsvers=4.2"
    "soft"
    "noatime"
    "_netdev"
    "nofail"
    "x-systemd.automount"
    "x-systemd.requires=network-online.target"
    "x-systemd.idle-timeout=600"
    "x-systemd.mount-timeout=30"                  # 10 was too short for odyn to answer
    "retry=2"                                     # minutes mount.nfs keeps retrying
  ];
in
{
  # immich photos: dataset 700 root:root, the export answers only heimdall (maproot=root)
  fileSystems."/mnt/nas/immich-upload" = {
    device = "10.0.20.6:/mnt/vault/immich";
    fsType = "nfs";
    options = commonOpts;
  };
  fileSystems."/mnt/nas/crafty-config" = {
    device = "10.0.20.6:/mnt/vault/nfs-pvc-kubernetes/crafty/config";
    fsType = "nfs";
    options = commonOpts;
  };
  fileSystems."/mnt/nas/crafty-backups" = {
    device = "10.0.20.6:/mnt/vault/nfs-pvc-kubernetes/crafty/backups";
    fsType = "nfs";
    options = commonOpts;
  };
  fileSystems."/mnt/nas/crafty-logs" = {
    device = "10.0.20.6:/mnt/vault/nfs-pvc-kubernetes/crafty/logs";
    fsType = "nfs";
    options = commonOpts;
  };
  fileSystems."/mnt/nas/crafty-import" = {
    device = "10.0.20.6:/mnt/vault/nfs-pvc-kubernetes/crafty/import";
    fsType = "nfs";
    options = commonOpts;
  };
  fileSystems."/mnt/nas/crafty-servers" = {
    device = "10.0.20.6:/mnt/vault/nfs-pvc-kubernetes/crafty/servers";
    fsType = "nfs";
    options = commonOpts;
  };
  # paperless data and the vaultwarden backups
  fileSystems."/mnt/nas/nix-services" = {
    device = "10.0.20.6:/mnt/vault/nix-services";
    fsType = "nfs";
    options = commonOpts;
  };
  # manyfold's library: only its own folder of the studio share, heimdall never sees my blender files
  fileSystems."/mnt/nas/manyfold" = {
    device = "10.0.20.6:/mnt/vault/studio/Manyfold";
    fsType = "nfs";
    options = commonOpts;
  };

  # make network-online.target really wait, so the mounts above have something to wait for
  systemd.network.wait-online.enable = true;
  systemd.services.NetworkManager-wait-online.enable = true;
  networking.dhcpcd.wait = "ipv4";
}
