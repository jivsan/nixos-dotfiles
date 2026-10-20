{ config, pkgs, ... }:

let
  sureBase = "/var/lib/sure";

  sureEnv = {
    SELF_HOSTED      = "true";
    RAILS_ENV        = "production";
    RAILS_FORCE_SSL  = "false";   # traefik on heimdall does the tls
    RAILS_ASSUME_SSL = "true";

    DB_HOST       = "sure-db";
    DB_PORT       = "5432";
    POSTGRES_USER = "sure";
    POSTGRES_DB   = "sure_production";

    REDIS_URL = "redis://sure-redis:6379/1";

    # without it, password reset and invite emails link to a bare host (action_mailer reads it)
    APP_DOMAIN = "sure.oryxserver.org";

    WEBAUTHN_RP_ID           = "sure.oryxserver.org";
    WEBAUTHN_ALLOWED_ORIGINS = "https://sure.oryxserver.org";
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${sureBase} 0750 root root -"
    "d ${sureBase}/postgres 0700 70 70 -"   # alpine postgres runs as uid/gid 70
    "d ${sureBase}/redis 0700 999 1000 -"   # redis-alpine runs as 999:1000; root-owned, a rebuild stops its writes
    "d ${sureBase}/backups 0700 root root -"
  ];

  systemd.services.create-sure-network = {
    description = "Create Sure Podman network";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman ];
    serviceConfig.Type = "oneshot";
    script = ''
      # --interface-name pins the bridge to a known name so the firewall can
      # trust it (podman would otherwise allocate podmanN by creation order).
      podman network exists sure \
        || podman network create --interface-name sure0 --subnet 10.89.0.0/24 sure
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
      ports = [ "10.0.20.20:3000:3000" ];   # lan only; the nftables table below lets just heimdall in
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

  # only heimdall's traefik may reach port 3000
  # sure0 must be trusted: under nftables netavark's accept rules don't land ahead of nixos-fw's
  # drop, so containers can't reach aardvark-dns (:53 on the bridge) to find each other
  networking.nftables.enable = true;
  networking.firewall.trustedInterfaces = [ "sure0" ];

  # the published port can't be dropped in input (netavark dnats it in prerouting) or in
  # extraForwardRules (nixos-fw accepts dnat'd traffic first), so it's dropped in its own table
  # at prerouting priority raw, before dstnat, while the destination is still 10.0.20.20:3000
  networking.nftables.tables.sure-isolation = {
    family = "ip";
    content = ''
      chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        iifname "ens18" ip daddr 10.0.20.20 tcp dport 3000 ip saddr != 10.0.20.17 drop
      }
    '';
  };

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
