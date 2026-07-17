{ pkgs, ... }:
let
  # immich-server v3.0.3 (DB migrated pgvecto.rs → VectorChord on 2026-07-17, on v2.7.5)
  immichImage = "ghcr.io/immich-app/immich-server@sha256:c716dc20f957aafd89fa9d284a2ec63e25c9e2d8d8e87c6197d540a3dce237db";
  # Immich's own postgres image: PG16 + VectorChord 0.4.3 + pgvecto.rs 0.2.1.
  # Ships BOTH vector extensions so the server can auto-migrate vectors → vchord
  # on first start (required before Immich v3, which dropped pgvecto.rs).
  # Tag: ghcr.io/immich-app/postgres:16-vectorchord0.4.3-pgvector0.8.1-pgvectors0.2.1
  pgvectorImage = "ghcr.io/immich-app/postgres@sha256:13d1ff1638f54be482620d0ef1eb2b004c99bfd674d06359ae0b91d8f5b5696b";
  redisImage = "redis:alpine";

  # ML backend on mimir (hosts/mimir/modules/system/immich-ml.nix, pinned to the
  # same immich release). Container needs mimir's GPU/driver working to start;
  # immich-server tolerates ML being down (smart search just stays unavailable).
  mlUrl = "http://10.0.20.18:3003";

  # Path containers will see for uploads (immich expects /usr/src/app/upload)
  uploadHostPath = "/mnt/nas/immich-upload";
  nextcloudHostPath = "/mnt/nas/nextcloud";
in
{
  # Pre-create local Postgres data dir on SSD
  systemd.tmpfiles.rules = [
    "d /var/lib/immich-db 0700 999 999 -"
  ];

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers = {

    # ── Postgres with pgvecto-rs (vector search) ──
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
        "127.0.0.1:5433:5432"          # bound to localhost only, port 5433 to avoid collision with future native PG
      ];

      # No cmd override: the immich-app/postgres entrypoint manages
      # shared_preload_libraries itself (loads vchord.so + vectors.so as needed).

      extraOptions = [
        "--network=immich-net"
      ];
    };

    # ── Redis ──
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

    # ── immich-server ──
    immich-server = {
      image = immichImage;
      autoStart = true;

      environment = {
        DB_HOSTNAME = "immich-db";
        DB_DATABASE_NAME = "immich";
        DB_USERNAME = "immich";
        REDIS_HOSTNAME = "immich-redis";
        IMMICH_MACHINE_LEARNING_URL = mlUrl;

        # Suppress upgrade nag if version drifts later
        IMMICH_VERSION_CHECK = "false";
      };

      environmentFiles = [ "/var/lib/secrets/immich-db.env" ];

      volumes = [
        "${uploadHostPath}:/usr/src/app/upload:rw"
        "${nextcloudHostPath}:/mnt/nextcloud:ro"
        "/etc/localtime:/etc/localtime:ro"
      ];

      ports = [
        "0.0.0.0:2283:2283"            # immich web UI
      ];

      dependsOn = [ "immich-db" "immich-redis" ];

      extraOptions = [
        "--network=immich-net"
      ];
    };
  };

  # Create the user-defined network so the 3 containers can talk by name
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

  # immich-server published on 2283 — Traefik routes to it
  networking.firewall.allowedTCPPorts = [ 2283 ];
}
