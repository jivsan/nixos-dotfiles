{ config, pkgs, ... }:

let
  sureBase = "/var/lib/sure";

  # Shared by sure-web and sure-worker — they run the same image.
  sureEnv = {
    SELF_HOSTED      = "true";
    RAILS_ENV        = "production";
    RAILS_FORCE_SSL  = "false";   # Traefik on heimdall terminates TLS
    RAILS_ASSUME_SSL = "true";

    DB_HOST       = "sure-db";
    DB_PORT       = "5432";
    POSTGRES_USER = "sure";
    POSTGRES_DB   = "sure_production";

    REDIS_URL = "redis://sure-redis:6379/1";

    WEBAUTHN_RP_ID           = "sure.oryxserver.org";
    WEBAUTHN_ALLOWED_ORIGINS = "https://sure.oryxserver.org";
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${sureBase} 0750 root root -"
    "d ${sureBase}/postgres 0700 70 70 -"   # alpine postgres runs as uid/gid 70
    "d ${sureBase}/redis 0755 root root -"
    "d ${sureBase}/backups 0700 root root -"
  ];

  systemd.services.create-sure-network = {
    description = "Create Sure Podman network";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman ];
    serviceConfig.Type = "oneshot";
    script = ''
      podman network exists sure || podman network create sure
    '';
  };

  virtualisation.oci-containers.containers = {
    sure-db = {
      image = "docker.io/library/postgres:16-alpine";
      autoStart = true;
      environmentFiles = [ "/var/lib/secrets/sure.env" ];
      environment = {
        POSTGRES_USER = "sure";
        POSTGRES_DB   = "sure_production";
      };
      volumes = [ "${sureBase}/postgres:/var/lib/postgresql/data" ];
      extraOptions = [ "--network=sure" ];
    };

    sure-redis = {
      image = "docker.io/library/redis:7-alpine";
      autoStart = true;
      cmd = [ "redis-server" "--appendonly" "yes" ];
      volumes = [ "${sureBase}/redis:/data" ];
      extraOptions = [ "--network=sure" ];
    };

    sure-web = {
      image = "ghcr.io/we-promise/sure:stable";
      autoStart = true;
      ports = [ "10.0.20.20:3000:3000" ];   # LAN-bound; nftables restricts to heimdall
      environmentFiles = [ "/var/lib/secrets/sure.env" ];
      environment = sureEnv;
      extraOptions = [ "--network=sure" ];
    };

    sure-worker = {
      image = "ghcr.io/we-promise/sure:stable";
      autoStart = true;
      cmd = [ "bundle" "exec" "sidekiq" ];
      environmentFiles = [ "/var/lib/secrets/sure.env" ];
      environment = sureEnv;
      extraOptions = [ "--network=sure" ];
    };
  };

  systemd.services.podman-sure-db = {
    after    = [ "create-sure-network.service" ];
    requires = [ "create-sure-network.service" ];
  };

  systemd.services.podman-sure-redis = {
    after    = [ "create-sure-network.service" ];
    requires = [ "create-sure-network.service" ];
  };

  systemd.services.podman-sure-web = {
    after    = [ "create-sure-network.service" "podman-sure-db.service" "podman-sure-redis.service" ];
    requires = [ "create-sure-network.service" "podman-sure-db.service" "podman-sure-redis.service" ];
  };

  systemd.services.podman-sure-worker = {
    after    = [ "create-sure-network.service" "podman-sure-db.service" "podman-sure-redis.service" ];
    requires = [ "create-sure-network.service" "podman-sure-db.service" "podman-sure-redis.service" ];
  };

  # ─── Only heimdall's Traefik may reach the app port ───
  networking.nftables.enable = true;
  networking.firewall.extraInputRules = ''
    ip saddr 10.0.20.17 tcp dport 3000 accept
  '';

  systemd.services.sure-db-backup = {
    description = "Back up the Sure database";
    path = [ pkgs.podman pkgs.coreutils pkgs.gzip ];
    serviceConfig.Type = "oneshot";
    script = ''
      podman exec sure-db pg_dump -U sure sure_production \
        | gzip > ${sureBase}/backups/sure-$(date +%F-%H%M%S).sql.gz
      find ${sureBase}/backups -type f -name 'sure-*.sql.gz' -mtime +30 -delete
    '';
  };

  systemd.timers.sure-db-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
