{ pkgs, ... }:
let
  # Pinned to exactly what's running on k8s (Nextcloud 32.0.6.1)
  nextcloudImage = "docker.io/library/nextcloud@sha256:297c6ecc0a94a4bb6e55f12d693a1cf3e5ca24797f70f8570d18cf784f757792";
  postgresImage = "docker.io/library/postgres@sha256:20edbde7749f822887a1a022ad526fde0a47d6b2be9a8364433605cf65099416";
  redisImage = "docker.io/library/redis@sha256:c5e375abb885e6b2021c0377879e4890bf76f9065b8922ffc113f2b226b9fc17";
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/nextcloud-db 0700 999 999 -"
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
