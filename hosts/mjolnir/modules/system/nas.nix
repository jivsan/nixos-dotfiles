{ ... }:

{
  boot.supportedFilesystems = [ "nfs" ];

  fileSystems."/mnt/nas-backups-workstation" = {
    device = "10.0.20.6:/mnt/vault/backups-workstation";
    fsType = "nfs";
    options = [
      "nfsvers=3"
      "x-systemd.automount"
      "noauto"
      "x-systemd.idle-timeout=600"
      "nofail"
    ];
  };

  fileSystems."/mnt/nas-media" = {
    device = "10.0.20.6:/mnt/vault/media";
    fsType = "nfs";
    options = [
      "nfsvers=3"
      "x-systemd.automount"
      "noauto"
      "x-systemd.idle-timeout=600"
      "nofail"
    ];
  };


}
