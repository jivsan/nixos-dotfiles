{ ... }:
# ── huginn / muninn — the "agentic OS" Obsidian backend ──────────────────────
# LinuxServer.io Obsidian (KasmVNC) streams the full desktop app to the browser;
# the vault itself is just markdown on odyn's NFS. Humans use the hosted app;
# agents edit the files directly on the same mount (so inotify → live refresh).
# One live Obsidian instance per vault: this container is the only one.
let
  # Vault (Norse: muninn = memory). Dataset lives on odyn (TrueNAS, 10.0.20.6) as
  # vault/obsidian, exported to VLAN 20. The vault is the `muninn` subfolder so the
  # same export can hold more vaults later — open /vaults/muninn inside the app.
  vaultHostPath = "/mnt/nas/obsidian";

  # Matches the shared NFS style in hosts/heimdall/modules/system/nas.nix
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
  # ── Vault storage on odyn (NFS) ──
  fileSystems.${vaultHostPath} = {
    device = "10.0.20.6:/mnt/vault/obsidian";
    fsType = "nfs";
    options = commonOpts;
  };

  # KasmVNC/app state on local SSD — the session writes a lot of junk we don't
  # want on NFS, and SQLite-on-NFS locking is flaky. Only the vault lives on NFS.
  systemd.tmpfiles.rules = [
    "d /var/lib/obsidian-config 0755 1000 1000 -"
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.obsidian = {
    image = "lscr.io/linuxserver/obsidian:latest";
    autoStart = true;

    environment = {
      PUID  = "1000";            # must match the NFS export's maproot on odyn
      PGID  = "1000";
      TZ    = "Europe/Oslo";
      TITLE = "muninn";          # KasmVNC page/window title
    };

    # KasmVNC login (CUSTOM_USER + PASSWORD). Kept out of git — create
    # /var/lib/secrets/obsidian.env on heimdall (see the deploy runbook).
    environmentFiles = [ "/var/lib/secrets/obsidian.env" ];

    volumes = [
      "/var/lib/obsidian-config:/config"   # KasmVNC/app state (local SSD)
      "${vaultHostPath}:/vaults"           # the vault(s) on NFS
    ];

    ports = [
      "127.0.0.1:3000:3000"   # KasmVNC HTTP — localhost only; Traefik fronts it
    ];

    # Electron/Chromium inside KasmVNC needs more than the 64M default /dev/shm.
    # (If a browser/app tab crashes on launch, add "--security-opt" "seccomp=unconfined".)
    extraOptions = [ "--shm-size=1g" ];
  };

  # Don't start the container until the NFS vault is actually mounted (and pull the
  # automount in on demand). RequiresMountsFor handles systemd unit-name escaping.
  systemd.services.podman-obsidian.unitConfig.RequiresMountsFor = vaultHostPath;

  # No firewall port: 3000 is bound to localhost and reached only via Traefik.
}
