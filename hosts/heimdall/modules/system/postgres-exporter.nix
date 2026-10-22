{ pkgs, ... }:
{
  # immich's postgres is on odyn since 2026-10-22 (odyn/apps/immichdb). the exporter logs in as its own
  # role postgres_exporter (pg_monitor, metrics only) over tls with the certificate checked:
  #   DATA_SOURCE_URI=10.0.20.6:5433/immich?sslmode=verify-full&sslrootcert=/etc/immichdb/ca.crt
  #   DATA_SOURCE_USER=postgres_exporter, DATA_SOURCE_PASS=...
  systemd.services.postgres-exporter-immich = {
    description = "Postgres Exporter (immich)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      DynamicUser = true;
      ExecStart = "${pkgs.prometheus-postgres-exporter}/bin/postgres_exporter --web.listen-address=127.0.0.1:9187";
      Restart = "always";
      RestartSec = "10s";
      EnvironmentFile = "/var/lib/secrets/postgres-exporter-immich-odyn.env";
    };
  };
}
