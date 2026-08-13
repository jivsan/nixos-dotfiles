{ config, pkgs, ... }:

let
  # SQLite must live on LOCAL disk — never on the NFS share. NFS file locking is
  # unreliable enough to corrupt a SQLite DB, and this one holds the vault.
  vwData = "/var/lib/vaultwarden";
  vwBackups = "/mnt/nas/nix-services/vaultwarden/backups";
in
{
  systemd.tmpfiles.rules = [
    "d ${vwData} 0700 root root -"
  ];

  virtualisation.oci-containers.containers.vaultwarden = {
    image = "ghcr.io/dani-garcia/vaultwarden:latest";
    autoStart = true;
    ports = [ "127.0.0.1:8222:80" ];

    # No ADMIN_TOKEN on purpose: leaving it unset disables /admin entirely,
    # which removes an attack surface on the host holding every password and
    # keeps configuration declarative here rather than in a web UI. If the
    # admin panel is ever needed, add an argon2 hash via an environmentFiles
    # entry — the `/vaultwarden hash` helper needs an interactive TTY.

    environment = {
      DOMAIN = "https://vault.oryxserver.org";

      # Flip to "false" and rebuild immediately after registering the first
      # account — otherwise anyone reaching Traefik can create a vault here.
      SIGNUPS_ALLOWED = "true";

      # Trim log noise; failed logins still surface.
      LOG_LEVEL = "warn";
      EXTENDED_LOGGING = "true";
    };

    volumes = [ "${vwData}:/data" ];
  };

  # ─── Daily backup to the NAS ───
  # sqlite3 .backup takes a consistent snapshot of a live DB — a plain cp can
  # copy a torn page mid-write and yield an unrestorable vault.
  systemd.services.vaultwarden-backup = {
    description = "Back up the Vaultwarden vault to TrueNAS";
    path = [ pkgs.sqlite pkgs.coreutils pkgs.gzip pkgs.gnutar ];
    serviceConfig.Type = "oneshot";
    unitConfig.RequiresMountsFor = [ "/mnt/nas/nix-services" ];
    script = ''
      mkdir -p ${vwBackups}
      stamp=$(date +%F-%H%M%S)

      sqlite3 ${vwData}/db.sqlite3 ".backup '/tmp/vw-$stamp.sqlite3'"
      gzip -c "/tmp/vw-$stamp.sqlite3" > ${vwBackups}/vaultwarden-$stamp.sqlite3.gz
      rm -f "/tmp/vw-$stamp.sqlite3"

      # Attachments, sends and the RSA keypair are NOT in the DB — without
      # rsa_key.pem every session token is invalidated on restore.
      tar czf ${vwBackups}/vaultwarden-files-$stamp.tar.gz \
        -C ${vwData} attachments sends rsa_key.pem config.json 2>/dev/null || true

      find ${vwBackups} -type f -name 'vaultwarden-*' -mtime +30 -delete
    '';
  };

  systemd.timers.vaultwarden-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
