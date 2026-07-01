{ pkgs, ... }:
{
  # InfluxDB 1.x (InfluxQL) — receives streamed metrics from pfSense's Telegraf.
  # pfSense stores nothing locally; all retention lives here (bounded to 90d).
  # Grafana reads it via the InfluxDB datasource (see grafana.nix).
  systemd.tmpfiles.rules = [
    "d /var/lib/influxdb 0750 root root -"
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.influxdb = {
    image = "docker.io/library/influxdb:1.8";
    autoStart = true;
    # 0.0.0.0:8086 so pfSense (10.0.20.1) can push; gated by the firewall below.
    ports = [ "8086:8086" ];
    environment = {
      INFLUXDB_HTTP_AUTH_ENABLED = "false";   # trusted VLAN 20 only
      INFLUXDB_REPORTING_DISABLED = "true";
    };
    volumes = [
      "/var/lib/influxdb:/var/lib/influxdb"
    ];
  };

  # Ensure the pfsense DB exists with a bounded 90-day retention (self-limiting disk)
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

  # pfSense pushes metrics here over the trusted VLAN
  networking.firewall.allowedTCPPorts = [ 8086 ];
}
