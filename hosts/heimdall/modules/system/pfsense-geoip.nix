{ pkgs, ... }:
let
  pyEnv = pkgs.python3.withPackages (ps: [ ps.geoip2 ]);
in
{
  # weekly GeoLite2-City.mmdb download, maxmind license key in /var/lib/secrets/maxmind-license
  systemd.services.geolite-update = {
    description = "Download/refresh MaxMind GeoLite2-City database";
    # pfsense-geoip pulls it in at boot, so wait for the network (and dns) first
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.curl pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.findutils ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      set -eu
      KEY=$(cat /var/lib/secrets/maxmind-license)
      mkdir -p /var/lib/GeoIP
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      curl -sSL -o "$tmp/gl.tar.gz" \
        "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=$KEY&suffix=tar.gz"
      tar -xzf "$tmp/gl.tar.gz" -C "$tmp"
      mmdb=$(find "$tmp" -name 'GeoLite2-City.mmdb' | head -1)
      install -m 0644 "$mmdb" /var/lib/GeoIP/GeoLite2-City.mmdb
    '';
  };
  systemd.timers.geolite-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2min"; OnCalendar = "weekly"; Persistent = true; };
  };

  # pfsense firewall syslog in, blocked inbound sources geolocated into influxdb
  systemd.services.pfsense-geoip = {
    description = "pfSense firewall geo-locator (syslog -> InfluxDB)";
    after = [ "geolite-update.service" "podman-influxdb.service" "network.target" ];
    wants = [ "geolite-update.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pyEnv}/bin/python3 ${./pfsense-geoip.py}";
      Restart = "always";
      RestartSec = "10";
      DynamicUser = true;                 # 5514 is above 1024, so no root needed
      ReadOnlyPaths = [ "/var/lib/GeoIP" ];
    };
  };

  # set on pfsense under status > system logs > settings > remote logging
  networking.firewall.allowedUDPPorts = [ 5514 ];
}
