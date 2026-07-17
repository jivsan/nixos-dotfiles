{ pkgs, ... }:
{
  systemd.services.postgres-exporter-immich = {
    description = "Postgres Exporter (immich)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "podman-immich-db.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = "${pkgs.prometheus-postgres-exporter}/bin/postgres_exporter --web.listen-address=127.0.0.1:9187";
      Restart = "always";
      RestartSec = "10s";
      EnvironmentFile = "/var/lib/secrets/postgres-exporter-immich.env";
    };
  };
}
