{ config, pkgs, ... }:

let
  paperlessBase = "/mnt/nas/nix-services/paperless";
in
{
  systemd.tmpfiles.rules = [
    "d ${paperlessBase} 0775 christina users -"
    "d ${paperlessBase}/consume 0775 christina users -"
    "d ${paperlessBase}/media 0775 christina users -"
    "d ${paperlessBase}/export 0775 christina users -"
    "d ${paperlessBase}/backups 0775 christina users -"
    "d /var/lib/paperless/postgres 0700 70 70 -"   # alpine postgres runs as uid/gid 70
    "d /var/lib/paperless/redis 0755 root root -"
  ];

  systemd.services.create-paperless-network = {
    description = "Create Paperless Podman network";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman ];
    serviceConfig.Type = "oneshot";
    script = ''
      podman network exists paperless || podman network create paperless
    '';
  };

  virtualisation.oci-containers.containers = {
    paperless-db = {
      image = "docker.io/library/postgres:16-alpine";
      autoStart = true;
      environmentFiles = [ "/var/lib/secrets/paperless.env" ];
      volumes = [ "/var/lib/paperless/postgres:/var/lib/postgresql/data" ];
      extraOptions = [ "--network=paperless" ];
    };

    paperless-redis = {
      image = "docker.io/library/redis:7-alpine";
      autoStart = true;
      cmd = [ "redis-server" "--appendonly" "yes" ];
      volumes = [ "/var/lib/paperless/redis:/data" ];
      extraOptions = [ "--network=paperless" ];
    };

    paperless-web = {
      image = "ghcr.io/paperless-ngx/paperless-ngx:latest";
      autoStart = true;
      ports = [ "127.0.0.1:8010:8000" ];

      environmentFiles = [ "/var/lib/secrets/paperless.env" ];

      environment = {
        USERMAP_UID = "1000";
        USERMAP_GID = "100";

        PAPERLESS_REDIS = "redis://paperless-redis:6379";
        PAPERLESS_DBHOST = "paperless-db";
        PAPERLESS_DBNAME = "paperless";
        PAPERLESS_DBUSER = "paperless";

        PAPERLESS_URL = "https://paperless.oryxserver.org";
        PAPERLESS_ALLOWED_HOSTS = "paperless.oryxserver.org,localhost,127.0.0.1";
        PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.oryxserver.org";

        PAPERLESS_TIME_ZONE = config.time.timeZone;
        PAPERLESS_OCR_LANGUAGE = "eng";
        PAPERLESS_CONSUMER_POLLING = "30";
        PAPERLESS_FILENAME_FORMAT = "{created_year}/{correspondent}/{title}";
      };

      volumes = [
        "${paperlessBase}/consume:/usr/src/paperless/consume"
        "${paperlessBase}/media:/usr/src/paperless/media"
        "${paperlessBase}/export:/usr/src/paperless/export"
      ];

      extraOptions = [ "--network=paperless" ];
    };
  };

  systemd.services.podman-paperless-db = {
    after = [ "create-paperless-network.service" ];
    requires = [ "create-paperless-network.service" ];
  };

  systemd.services.podman-paperless-redis = {
    after = [ "create-paperless-network.service" ];
    requires = [ "create-paperless-network.service" ];
  };

  systemd.services.podman-paperless-web = {
    after = [
      "create-paperless-network.service"
      "podman-paperless-db.service"
      "podman-paperless-redis.service"
    ];
    requires = [
      "create-paperless-network.service"
      "podman-paperless-db.service"
      "podman-paperless-redis.service"
    ];
    unitConfig.RequiresMountsFor = [ paperlessBase ];
  };

  systemd.services.paperless-db-backup = {
    description = "Back up Paperless database to TrueNAS";
    path = [ pkgs.podman pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p ${paperlessBase}/backups
      podman exec paperless-db pg_dump -U paperless paperless \
        > ${paperlessBase}/backups/paperless-$(date +%F-%H%M%S).sql
      find ${paperlessBase}/backups -type f -name 'paperless-*.sql' -mtime +30 -delete
    '';
  };

  systemd.timers.paperless-db-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
