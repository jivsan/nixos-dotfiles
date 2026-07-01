{ pkgs, ... }:
let
  pyEnv = pkgs.python3.withPackages (ps: [ ps.geoip2 ]);
in
{
  # 1) Keep GeoLite2-City.mmdb fresh (license key is a host secret, never in the repo).
  systemd.services.geolite-update = {
    description = "Download/refresh MaxMind GeoLite2-City database";
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

  # 2) Receive pfSense firewall syslog, geolocate blocked inbound sources -> InfluxDB.
  systemd.services.pfsense-geoip = {
    description = "pfSense firewall geo-locator (syslog -> InfluxDB)";
    after = [ "geolite-update.service" "podman-influxdb.service" "network.target" ];
    wants = [ "geolite-update.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pyEnv}/bin/python3 ${./pfsense-geoip.py}";
      Restart = "always";
      RestartSec = "10";
      DynamicUser = true;                 # unprivileged; 5514 is a high port
      ReadOnlyPaths = [ "/var/lib/GeoIP" ];
    };
  };

  # pfSense sends firewall events here (Status → System Logs → Settings → Remote Logging)
  networking.firewall.allowedUDPPorts = [ 5514 ];
}
