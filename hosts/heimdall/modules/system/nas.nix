{ ... }:
let
  # Common options for our internal NFS mounts
  commonOpts = [
    "nfsvers=4.2"
    "soft"
    "noatime"
    "_netdev"                                     # network-dependent mount
    "nofail"                                      # never block boot on this share
    "x-systemd.automount"                         # lazy-mount on first access
    "x-systemd.requires=network-online.target"    # explicit: wait for network before mounting
    "x-systemd.idle-timeout=600"
    "x-systemd.mount-timeout=30"                  # was 10 — give NFS room to answer
    "retry=2"                                     # mount.nfs retries for 2 min on transient failure
  ];
in
{
  # ── Immich ──
  # Dedicated dataset (2026-07-17): 700 root:root, export answers heimdall only,
  # maproot=root. Old data migrated from /mnt/vault/nfs-pvc-kubernetes/immich/upload.
  fileSystems."/mnt/nas/immich-upload" = {
    device = "10.0.20.6:/mnt/vault/immich";
    fsType = "nfs";
    options = commonOpts;
  };
  # ── Crafty ──
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
  # ── nix-services shared app storage ──
  fileSystems."/mnt/nas/nix-services" = {
    device = "10.0.20.6:/mnt/vault/nix-services";
    fsType = "nfs";
    options = commonOpts;
  };

  # Ensure network-online.target actually waits for real connectivity,
  # so the _netdev / requires ordering above has something genuine to gate on.
  systemd.network.wait-online.enable = true;
  systemd.services.NetworkManager-wait-online.enable = true;
  networking.dhcpcd.wait = "ipv4";
}
