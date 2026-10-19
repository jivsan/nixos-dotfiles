{ pkgs, ... }:
{
  # influxdb 1.8 for pfsense's telegraf and pfsense-geoip.nix, read by grafana
  # pfsense keeps no history itself, these 90 days are all there is
  systemd.tmpfiles.rules = [
    "d /var/lib/influxdb 0750 root root -"
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.influxdb = {
    image = "docker.io/library/influxdb:1.8";
    autoStart = true;
    # on all interfaces so pfsense (10.0.20.1) can push
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

  networking.firewall.allowedTCPPorts = [ 8086 ];
}
