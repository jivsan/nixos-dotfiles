{ pkgs, lib, ... }:
{
  # influxdb 1.x for pfsense's telegraf and pfsense-geoip.nix, read by grafana (influxql)
  # pfsense keeps no history itself, these 90 days are all there is
  #
  # since 1.11 the image runs as influxdb (uid 1500) instead of root. going from 1.8 to 1.12 on
  # 2026-10-20 took one `chown -R 1500:1500 /var/lib/influxdb` with the container stopped; the
  # data from before is in /mnt/nas/nix-services/influxdb-before-1.12-2026-10-20.tar.gz
  # (rollback: stop, untar over /var/lib/influxdb, the 1.8 image, root:root here)
  systemd.tmpfiles.rules = [
    "d /var/lib/influxdb 0750 1500 1500 -"
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.influxdb = {
    image = "docker.io/library/influxdb:1.12.4@sha256:f86abb84b7b78f82f5bef55dd9d034837e10701940e408d3cfb8da256ffd4bb5";
    autoStart = true;
    # on all interfaces so pfsense can push, the raw rule below decides who gets in
    ports = [ "8086:8086" ];
    environment = {
      INFLUXDB_HTTP_AUTH_ENABLED = "false";   # no auth: anything that reaches 8086 can read and write
      INFLUXDB_REPORTING_DISABLED = "true";
    };
    volumes = [
      "/var/lib/influxdb:/var/lib/influxdb"
    ];
  };

  systemd.services.influxdb-init = {
    description = "Create InfluxDB pfsense database + 90d retention";
    after = [ "podman-influxdb.service" ];
    requires = [ "podman-influxdb.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      for i in $(seq 1 30); do
        curl -sf http://localhost:8086/ping && break || sleep 2
      done
      curl -sS -XPOST 'http://localhost:8086/query' \
        --data-urlencode 'q=CREATE DATABASE pfsense WITH DURATION 90d REPLICATION 1' || true
    '';
  };

  # no login, so only pfsense's telegraf (10.0.20.1), heimdall itself (lo: pfsense-geoip) and
  # my containers (podman0: grafana) reach 8086. a published podman port is forwarded, so
  # nixos-fw and allowedTCPPorts never see it: this sits in the raw table, before podman's nat
  networking.firewall.extraCommands = ''
    iptables -t raw -N influx-only 2>/dev/null || iptables -t raw -F influx-only
    iptables -t raw -A influx-only -i lo -j RETURN
    iptables -t raw -A influx-only -i podman0 -j RETURN
    iptables -t raw -A influx-only -s 10.0.20.1 -j RETURN
    iptables -t raw -A influx-only -j DROP
    iptables -t raw -C PREROUTING -p tcp --dport 8086 -j influx-only 2>/dev/null \
      || iptables -t raw -A PREROUTING -p tcp --dport 8086 -j influx-only
  '';
  networking.firewall.extraStopCommands = ''
    iptables -t raw -D PREROUTING -p tcp --dport 8086 -j influx-only 2>/dev/null || true
    iptables -t raw -F influx-only 2>/dev/null || true
    iptables -t raw -X influx-only 2>/dev/null || true
  '';

  # influx.oryxserver.org: a way in that can only read, for homarr's network widget. homarr moves to
  # kubernetes, and 8086 itself stays closed to it (the raw rule above). traefik reaches influxdb on
  # 127.0.0.1, like pfsense-geoip does.
  # influxdb can't make this read-only by itself: there is no login, and a GET /query runs every
  # statement it gets, a DROP DATABASE too. it only adds a warning to the answer
  # (1.12.4, coordinator/statement_executor.go). so the rule only lets through what can't write:
  # - GET /query, nothing else: no /write, /api/v2, /debug, /ping
  # - no "into" anywhere in q: SELECT ... INTO writes its result into a measurement
  # - every statement in q starts with select or show, the first one and each one after a ;
  #   (a ; inside a quoted string counts too, that only refuses more)
  # traefik looks at every q in the url and influxdb takes the first, so each one has to fit.
  # with no q in the url influxdb reads it from a multipart body, a GET too. without a Content-Type
  # header it never looks at the body, so traefik takes that header off.
  # anything else gets traefik's 404. who: the six workers of helheim (a pod leaves with its node's
  # address), and homarr's container here until homarr has moved
  services.traefik.dynamicConfigOptions.http = {
    routers.influx-read = {
      rule = lib.concatStringsSep " && " [
        "Host(`influx.oryxserver.org`)"
        "Method(`GET`)"
        "Path(`/query`)"
        "!QueryRegexp(`q`, `(?i)into`)"
        # a statement that starts with anything but select or show. letter by letter, because go's
        # regexp has no "not followed by"
        "!QueryRegexp(`q`, `(?i)(^|;)\\s*([^s\\s;]|s($|[^eh])|se($|[^l])|sel($|[^e])|sele($|[^c])|selec($|[^t])|sh($|[^o])|sho($|[^w]))`)"
      ];
      entryPoints = [ "websecure" ];
      service = "influx-read";
      tls = { };
      middlewares = [ "influx-read-clients" "influx-read-url-only" ];
    };
    services.influx-read.loadBalancer.servers = [ { url = "http://127.0.0.1:8086"; } ];
    middlewares = {
      influx-read-clients.ipAllowList.sourceRange = [
        "10.0.20.34/31"     # talos-w1, w2
        "10.0.20.36/30"     # talos-w3 to w6
        "10.88.200.10/32"   # homarr's container (homarr.nix), until homarr has moved
      ];
      # an empty value takes the header off. Content-Type: see above. Origin: without it influxdb
      # sends no cors header, so a web page that a browser in a pod opens (changedetection's chrome
      # opens any site) can't read the answer. homarr asks from its server and sends none
      influx-read-url-only.headers.customRequestHeaders = {
        "Content-Type" = "";
        "Origin" = "";
      };
    };
  };

  # nightly backup to odyn (since 2026-10-22): the data stays here, but a portable backup of the
  # pfsense database goes to vault/backups/influxdb-pfsense (odyn user backups 3013, share 25),
  # one folder per night, a week kept. odyn's snapshots of vault/backups keep older ones for a while.
  # restore: influxd restore -portable -db pfsense -newdb <name> <folder>, into a running influxd
  fileSystems."/mnt/backups/influxdb-pfsense" = {
    device = "10.0.20.6:/mnt/vault/backups/influxdb-pfsense";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "hard" "noatime" "_netdev" "nofail" "x-systemd.automount" "x-systemd.mount-timeout=30" ];
  };

  systemd.services.influxdb-backup = {
    description = "Back up InfluxDB's pfsense database to odyn";
    after = [ "podman-influxdb.service" ];
    requires = [ "podman-influxdb.service" ];
    unitConfig.RequiresMountsFor = [ "/mnt/backups/influxdb-pfsense" ];
    path = [ pkgs.podman pkgs.coreutils pkgs.findutils pkgs.rsync ];
    serviceConfig.Type = "oneshot";
    script = ''
      d=$(date +%F)
      tmp=/var/lib/influxdb/.backup-$d   # inside the container's volume, next to data/
      rm -rf "$tmp"
      podman exec influxdb influxd backup -portable -db pfsense "/var/lib/influxdb/.backup-$d"
      ls "$tmp"/*.manifest >/dev/null   # an empty backup is a failed one
      rsync -rt --delete "$tmp/" "/mnt/backups/influxdb-pfsense/$d/"
      rm -rf "$tmp"
      find /mnt/backups/influxdb-pfsense -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
    '';
  };

  systemd.timers.influxdb-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:15";
      Persistent = true;   # missed while heimdall was off: runs at boot
    };
  };
}
