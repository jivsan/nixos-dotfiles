{ pkgs, ... }:
let
  # immich-server; keep immich-ml on mimir on the same release
  immichImage = "ghcr.io/immich-app/immich-server:v3.3.3@sha256:bae7664ff3aa4c2c1fcbdcdd86b40b105643c5f861f3e6a770fc760089f25862";
  # immich's own postgres is an odyn app since 2026-10-22: odyn/apps/immichdb (vectorchord, user 3017,
  # vault/appdata/immichdb). the server reaches it by name, so the certificate is checked against
  # immichdb.odyn (with an ip, node would check "localhost" and fail)
  dbHost = "immichdb.odyn";
  # one url for both the server and its nightly backup (pg_dump gets this url as it is, so it checks the
  # certificate too and only does scram, never sends the password in clear). no password in it:
  # the server takes PGPASSWORD from its env file, pg_dump reads /root/.pgpass (both made from immich-db.env)
  dbUrl = "postgres://immich@${dbHost}:5433/immich?sslmode=verify-full&sslrootcert=/etc/immichdb/ca.crt&require_auth=scram-sha-256&channel_binding=require";
  redisImage = "docker.io/library/redis:8.10.2-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0";   # queue only, no volume

  # ml on mimir (hosts/mimir/modules/system/immich-ml.nix); when it's down
  # immich still runs, only smart search is gone
  mlUrl = "http://10.0.20.18:3003";

  # odyn:/mnt/vault/immich, mounted in nas.nix
  uploadHostPath = "/mnt/nas/immich-upload";
in
{
  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers = {

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
        DB_URL = dbUrl;
        REDIS_HOSTNAME = "immich-redis";
        IMMICH_MACHINE_LEARNING_URL = mlUrl;

        # no upgrade nag, the image is pinned by digest
        IMMICH_VERSION_CHECK = "false";
      };

      # PGPASSWORD (0600). immich-db.env stays as it was, for a rollback
      environmentFiles = [ "/var/lib/secrets/immich-server-db.env" ];

      volumes = [
        "${uploadHostPath}:/usr/src/app/upload:rw"
        "/etc/localtime:/etc/localtime:ro"
        "/etc/immichdb/ca.crt:/etc/immichdb/ca.crt:ro"   # appdata.nix
        "/var/lib/secrets/immich-db.pgpass:/root/.pgpass:ro"   # 0600, for the backup job's pg_dump
      ];

      ports = [
        "0.0.0.0:2283:2283"
      ];

      dependsOn = [ "immich-redis" ];

      extraOptions = [
        "--network=immich-net"
        "--add-host=${dbHost}:10.0.20.6"
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
