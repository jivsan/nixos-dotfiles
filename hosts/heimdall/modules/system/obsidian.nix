{ ... }:
# obsidian in the browser (linuxserver, kasmvnc) for my muninn vault on odyn
# the only live obsidian on the vault; agents edit the same files and it refreshes live
let
  # odyn's vault/obsidian dataset; the vault is the muninn subfolder (/vaults/muninn in the app)
  vaultHostPath = "/mnt/nas/obsidian";

  # same as nas.nix, keep them in step
  commonOpts = [
    "nfsvers=4.2"
    "soft"
    "noatime"
    "_netdev"
    "nofail"
    "x-systemd.automount"
    "x-systemd.requires=network-online.target"
    "x-systemd.idle-timeout=600"
    "x-systemd.mount-timeout=30"
    "retry=2"
  ];
in
{
  fileSystems.${vaultHostPath} = {
    device = "10.0.20.6:/mnt/vault/obsidian";
    fsType = "nfs";
    options = commonOpts;
  };

  # app state on local disk: lots of churn, and sqlite locking on nfs is flaky
  systemd.tmpfiles.rules = [
    "d /var/lib/obsidian-config 0755 1000 1000 -"
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.obsidian = {
    image = "lscr.io/linuxserver/obsidian:v1.14.5-ls150@sha256:da0e7e082b5922fe9f9065254e38e7b9875211f85089834f5e822f7037dbfabb";
    autoStart = true;

    environment = {
      PUID  = "1000";            # muninn, the user odyn's export maps every client to
      PGID  = "1000";
      TZ    = "Europe/Oslo";
      TITLE = "muninn";          # browser tab title
    };

    # kasmvnc login: CUSTOM_USER=... and PASSWORD=... in /var/lib/secrets/obsidian.env
    environmentFiles = [ "/var/lib/secrets/obsidian.env" ];

    volumes = [
      "/var/lib/obsidian-config:/config"
      "${vaultHostPath}:/vaults"
    ];

    ports = [
      "127.0.0.1:3000:3000"   # traefik fronts it, no firewall port
    ];

    # electron needs more than the 64M default /dev/shm
    # if it crashes on launch, try adding "--security-opt" "seccomp=unconfined"
    extraOptions = [ "--shm-size=1g" ];
  };

  systemd.services.podman-obsidian.unitConfig.RequiresMountsFor = vaultHostPath;
}
