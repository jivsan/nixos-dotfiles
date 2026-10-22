{ config, pkgs, ... }:

let
  # the documents are on odyn: vault/appdata/paperless, mounted in appdata.nix. the database is in
  # appdb on odyn. both moved there from heimdall 2026-10-22 (docs/apps-on-odyn.md)
  paperlessBase = "/mnt/appdata/paperless";
in
{
  systemd.tmpfiles.rules = [
    # nothing for paperlessBase: odyn makes every file on that share paperless's own (mapall), so a
    # chown there only fails on every rebuild. the copy made consume/, media/ and export/
    # redis-alpine runs as 999:1000. owned by root, every rebuild took it back and redis stopped
    # taking writes (paperless answered 500 from 2026-10-18 until the 20th)
    "d /var/lib/paperless/redis 0700 999 1000 -"
    # search index, classifier, scheduler state: kept across container re-creates (it was an
    # anonymous volume, thrown away on every rebuild). local, not on nfs (it holds sqlite files).
    # paperless runs as USERMAP 3014:3014, the odyn user that owns its share
    "d /var/lib/paperless/data 0750 3014 3014 -"
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
    paperless-redis = {
      image = "docker.io/library/redis:7.4.11-alpine@sha256:858f009f9709ce576febc734aa78b8f6d624b82571f9ddb6bda4377c833b3499";
      autoStart = true;
      cmd = [ "redis-server" "--appendonly" "yes" ];
      volumes = [ "/var/lib/paperless/redis:/data" ];
      extraOptions = [ "--network=paperless" ];
    };

    paperless-web = {
      image = "ghcr.io/paperless-ngx/paperless-ngx:3.3.3@sha256:dba0242c1df1843643df4eb50ce5639f3a7900f414879088fd5bed8eaf2d456d";
      autoStart = true;
      ports = [ "127.0.0.1:8010:8000" ];

      # PAPERLESS_SECRET_KEY (the same as before the move) and PAPERLESS_DBPASS (its appdb role)
      environmentFiles = [ "/var/lib/secrets/paperless-app.env" ];

      environment = {
        # the odyn user paperless (3014) that owns vault/appdata/paperless
        USERMAP_UID = "3014";
        USERMAP_GID = "3014";

        PAPERLESS_REDIS = "redis://paperless-redis:6379";
        PAPERLESS_DBENGINE = "postgresql";            # required since 3.0
        # appdb on odyn (odyn/apps/appdb), checked against its certificate
        PAPERLESS_DBHOST = "10.0.20.6";
        PAPERLESS_DBPORT = "5432";
        PAPERLESS_DBNAME = "paperless";
        PAPERLESS_DBUSER = "paperless";
        PAPERLESS_DB_OPTIONS = "sslmode=verify-full,sslrootcert=/etc/appdb/ca.crt";

        PAPERLESS_URL = "https://paperless.oryxserver.org";
        PAPERLESS_ALLOWED_HOSTS = "paperless.oryxserver.org,localhost,127.0.0.1";
        PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.oryxserver.org";

        PAPERLESS_TIME_ZONE = config.time.timeZone;
        PAPERLESS_OCR_LANGUAGE = "eng";
        # consume/ is on nfs, where inotify sees nothing: look every 30 s. 3.0 renamed this from
        # PAPERLESS_CONSUMER_POLLING; with the old name it silently stops picking up files
        PAPERLESS_CONSUMER_POLLING_INTERVAL = "30";
        PAPERLESS_CONSUMER_DELETE_DUPLICATES = "true";   # 2.x behaviour: a duplicate is not imported again
        PAPERLESS_FILENAME_FORMAT = "{{ created_year }}/{{ correspondent }}/{{ title }}";
      };

      volumes = [
        "${paperlessBase}/consume:/usr/src/paperless/consume"
        "${paperlessBase}/media:/usr/src/paperless/media"
        "${paperlessBase}/export:/usr/src/paperless/export"
        "/var/lib/paperless/data:/usr/src/paperless/data"
        "/etc/appdb/ca.crt:/etc/appdb/ca.crt:ro"
      ];

      extraOptions = [ "--network=paperless" ];
    };
  };

  systemd.services.podman-paperless-redis = {
    after = [ "create-paperless-network.service" ];
    requires = [ "create-paperless-network.service" ];
  };

  systemd.services.podman-paperless-web = {
    after = [
      "create-paperless-network.service"
      "podman-paperless-redis.service"
    ];
    requires = [
      "create-paperless-network.service"
      "podman-paperless-redis.service"
    ];
    unitConfig.RequiresMountsFor = [ paperlessBase ];
  };

  # no backup job here any more: yggdrasil's appdb-backup dumps the paperless database every night,
  # and odyn snapshots vault/appdata (documents included)
}
