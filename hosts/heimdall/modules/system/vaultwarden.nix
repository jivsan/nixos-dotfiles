{ config, pkgs, ... }:

let
  # sqlite stays on local disk, nfs locking can corrupt it
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

    # no ADMIN_TOKEN on purpose: /admin stays off and the config stays here.
    # if i ever need it, put an argon2 hash in an environmentFiles entry (`/vaultwarden hash` needs a tty)

    environment = {
      DOMAIN = "https://vault.oryxserver.org";

      # open until my account is made, then back to "false". after that, invite people
      # from an organisation, or set "true" for a minute
      SIGNUPS_ALLOWED = "true";

      # failed logins still show at warn
      LOG_LEVEL = "warn";
      EXTENDED_LOGGING = "true";
    };

    volumes = [ "${vwData}:/data" ];
  };

  # daily backup to odyn with sqlite3 .backup: a plain cp of the live db can catch a torn page
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
