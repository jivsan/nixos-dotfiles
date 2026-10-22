{ config, ... }:

let
  # since 2026-10-22 the database is in appdb on odyn (copied over from sqlite with
  # odyn/apps/appdb/migrate/homarr-sqlite-to-pg.py). this folder keeps only homarr's
  # own redis and trusted certificates
  homarrData = "/var/lib/homarr";
in
{
  systemd.tmpfiles.rules = [
    "d ${homarrData} 0700 root root -"
  ];

  virtualisation.oci-containers.containers.homarr = {
    # pinned by tag + digest: to update, put the new ones here and rebuild.
    # it migrates its database by itself on start, so a new major wants a fresh dump first
    image = "ghcr.io/homarr-labs/homarr:v2.7.0@sha256:f532ce7cb2a388096d6dce30b7ee41ff4b413b48ddc219ad2321dedb758cd772";
    autoStart = true;
    ports = [ "127.0.0.1:7575:7575" ];
    extraOptions = [
      # fixed address: traefik's lan-only lets this one container in, not all of podman's network
      "--ip=10.88.200.10"
      # homarr's postgres driver checks the certificate against "localhost" when it gets an ip,
      # so it connects by the certificate's name instead (appdb.odyn, see docs/apps-on-odyn.md)
      "--add-host=appdb.odyn:10.0.20.6"
    ];

    environmentFiles = [
      # SECRET_ENCRYPTION_KEY=<64 hex chars> (openssl rand -hex 32); it encrypts the
      # integration passwords and api keys in the db, lose or change it and they're unreadable
      "/var/lib/secrets/homarr.env"
      # DB_URL=postgres://homarr:<password>@appdb.odyn:5432/homarr?sslmode=verify-full&sslrootcert=/etc/appdb/ca.crt
      "/var/lib/secrets/homarr-db.env"
    ];

    environment = {
      BASE_URL = "https://home.oryxserver.org";   # the https name traefik serves, for secure cookies and origin checks
      TZ = config.time.timeZone;
      DB_DRIVER = "node-postgres";
      DB_DIALECT = "postgresql";
    };

    volumes = [
      "${homarrData}:/appdata"
      "/etc/appdb/ca.crt:/etc/appdb/ca.crt:ro"
      # podman's docker api, so homarr can list and start/stop the containers here.
      # that's full control over every container, so homarr stays behind lan-only
      "/run/podman/podman.sock:/var/run/docker.sock"
    ];
  };

  # no backup job here: yggdrasil's appdb-backup dumps the homarr database every night
}
