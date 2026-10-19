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
}
