{ pkgs, ... }:
let
  # Nextcloud 33.0.6-apache (upgraded 32.0.6 → 32.0.12 → 33.0.6; majors go ONE at a time)
  nextcloudImage = "docker.io/library/nextcloud@sha256:73280a6f559e9a6c96e012324086ff63af7ccfbed260f71f17738e5494375052";
  # postgres:16-alpine (minor bump within PG16 — data dir compatible)
  postgresImage = "docker.io/library/postgres@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777";
  # redis:alpine (current)
  redisImage = "docker.io/library/redis@sha256:9d317178eceac8454a2284a9e6df2466b93c745529947f0cd42a0fa9609d7005";
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/nextcloud-db 0700 70 70 -"   # alpine postgres runs as uid/gid 70
  ];

  virtualisation.oci-containers.containers = {

    # ── Postgres for Nextcloud ──
    nextcloud-db = {
      image = postgresImage;
      autoStart = true;

      environment = {
        POSTGRES_USER = "nextcloud";
        POSTGRES_DB = "nextcloud";
      };

      environmentFiles = [ "/var/lib/secrets/nextcloud-db.env" ];

      volumes = [
        "/var/lib/nextcloud-db:/var/lib/postgresql/data"
      ];

      ports = [
        "127.0.0.1:5434:5432"     # localhost-only, port 5434 (immich uses 5433)
      ];

      extraOptions = [
        "--network=nextcloud-net"
      ];
    };

    # ── Redis for Nextcloud ──
    nextcloud-redis = {
      image = redisImage;
      autoStart = true;

      ports = [
        "127.0.0.1:6380:6379"     # localhost-only, port 6380 (immich uses 6379)
      ];

      extraOptions = [
        "--network=nextcloud-net"
      ];
    };

    # ── Nextcloud server (config.php is on the NFS app mount) ──
    nextcloud-server = {
      image = nextcloudImage;
      autoStart = true;

      environment = {};

      volumes = [
        "/mnt/nas/nextcloud-app:/var/www/html:rw"
        "/mnt/nas/nextcloud-data:/var/www/html/data:rw"
        "/etc/localtime:/etc/localtime:ro"
      ];

      ports = [
        "0.0.0.0:8081:80"          # Nextcloud listens on 80 in the container
      ];

      dependsOn = [ "nextcloud-db" "nextcloud-redis" ];

      extraOptions = [
        "--network=nextcloud-net"
      ];
    };
  };

  # Create the user-defined network so containers resolve each other by name
  systemd.services."create-nextcloud-network" = {
    description = "Create podman network for nextcloud";
    after = [ "network.target" "podman.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.podman}/bin/podman network exists nextcloud-net || \
      ${pkgs.podman}/bin/podman network create nextcloud-net
    '';
  };

  networking.firewall.allowedTCPPorts = [ 8081 ];
}
