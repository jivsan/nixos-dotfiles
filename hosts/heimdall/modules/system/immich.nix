{ pkgs, ... }:
let
  # immich-server; keep immich-ml on mimir on the same release
  immichImage = "ghcr.io/immich-app/immich-server:v3.3.3@sha256:bae7664ff3aa4c2c1fcbdcdd86b40b105643c5f861f3e6a770fc760089f25862";
  # immich's own postgres, tag 16-vectorchord0.4.3-pgvector0.8.1-pgvectors0.2.1
  pgvectorImage = "ghcr.io/immich-app/postgres@sha256:13d1ff1638f54be482620d0ef1eb2b004c99bfd674d06359ae0b91d8f5b5696b";
  redisImage = "docker.io/library/redis:8.10.2-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0";   # queue only, no volume

  # ml on mimir (hosts/mimir/modules/system/immich-ml.nix); when it's down
  # immich still runs, only smart search is gone
  mlUrl = "http://10.0.20.18:3003";

  # odyn:/mnt/vault/immich, mounted in nas.nix
  uploadHostPath = "/mnt/nas/immich-upload";
in
{
  # db on local disk (999 is postgres inside the image)
  systemd.tmpfiles.rules = [
    "d /var/lib/immich-db 0700 999 999 -"
  ];

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers = {

    immich-db = {
      image = pgvectorImage;
      autoStart = true;

      environment = {
        POSTGRES_USER = "immich";
        POSTGRES_DB = "immich";
        POSTGRES_INITDB_ARGS = "--data-checksums";
      };

      environmentFiles = [ "/var/lib/secrets/immich-db.env" ];

      volumes = [
        "/var/lib/immich-db:/var/lib/postgresql/data"
      ];

      ports = [
        "127.0.0.1:5433:5432"          # 5433 so a native postgres can have 5432 later
      ];

      # no cmd override: the image's entrypoint sets shared_preload_libraries itself

      extraOptions = [
        "--network=immich-net"
      ];
    };

    immich-redis = {
      image = redisImage;
      autoStart = true;

      ports = [
        "127.0.0.1:6379:6379"
      ];

      extraOptions = [
        "--network=immich-net"
      ];
    };

    immich-server = {
      image = immichImage;
      autoStart = true;

      environment = {
        DB_HOSTNAME = "immich-db";
        DB_DATABASE_NAME = "immich";
        DB_USERNAME = "immich";
        REDIS_HOSTNAME = "immich-redis";
        IMMICH_MACHINE_LEARNING_URL = mlUrl;

        # no upgrade nag, the image is pinned by digest
        IMMICH_VERSION_CHECK = "false";
      };

      environmentFiles = [ "/var/lib/secrets/immich-db.env" ];

      volumes = [
        "${uploadHostPath}:/usr/src/app/upload:rw"
        "/etc/localtime:/etc/localtime:ro"
      ];

      ports = [
        "0.0.0.0:2283:2283"
      ];

      dependsOn = [ "immich-db" "immich-redis" ];

      extraOptions = [
        "--network=immich-net"
      ];
    };
  };

  systemd.services."create-immich-network" = {
    description = "Create podman network for immich";
    after = [ "network.target" "podman.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.podman}/bin/podman network exists immich-net || \
      ${pkgs.podman}/bin/podman network create immich-net
    '';
  };

  networking.firewall.allowedTCPPorts = [ 2283 ];
}
