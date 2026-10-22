{ pkgs, ... }:
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
