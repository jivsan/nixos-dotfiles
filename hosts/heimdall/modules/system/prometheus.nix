{ ... }:
{
  services.prometheus = {
    enable = true;
    port = 9090;
    listenAddress = "0.0.0.0";
    retentionTime = "30d";
    globalConfig = {
      scrape_interval = "15s";
      evaluation_interval = "15s";
    };
    exporters.node = {
      enable = true;
      port = 9100;
      listenAddress = "127.0.0.1";
      enabledCollectors = [ "systemd" "processes" ];
    };
    scrapeConfigs = [
      # === Self ===
      {
        job_name = "prometheus";
        static_configs = [{ targets = [ "localhost:9090" ]; }];
      }
      # === node_exporter on every host ===
      {
        job_name = "node";
        static_configs = [
          { targets = [ "localhost:9100" ];      labels = { host = "heimdall"; }; }
          { targets = [ "10.0.20.10:9100" ];     labels = { host = "hella"; }; }
          { targets = [ "10.0.20.6:9100" ];      labels = { host = "truenas"; }; }
        ];
      }
      # === Postgres exporters ===
      {
        job_name = "postgres-immich";
        static_configs = [{ targets = [ "localhost:9187" ]; labels.db = "immich"; }];
      }
      {
        job_name = "postgres-nextcloud";
        static_configs = [{ targets = [ "localhost:9188" ]; labels.db = "nextcloud"; }];
      }
      # === Traefik built-in metrics ===
      {
        job_name = "traefik";
        static_configs = [{ targets = [ "localhost:8082" ]; }];
      }
      # === pfSense via Telegraf ===
      {
        job_name = "pfsense";
        static_configs = [{
          targets = [ "10.0.20.1:9273" ];
          labels = {
            host = "pfsense";
            role = "firewall";
          };
        }];
      }
      # === Blackbox: HTTPS endpoint health ===
      {
        job_name = "blackbox-https";
        metrics_path = "/probe";
        params.module = [ "http_2xx" ];
        static_configs = [{
          targets = [
            "https://immich.oryxserver.org"
            "https://nextcloud.oryxserver.org"
            "https://grafana.oryxserver.org"
            "https://traefik.oryxserver.org"
            "https://homepage.oryxserver.org"
            "https://paperless.oryxserver.org"
          ];
        }];
        relabel_configs = [
          { source_labels = [ "__address__" ];  target_label = "__param_target"; }
          { source_labels = [ "__param_target" ]; target_label = "instance"; }
          { target_label = "__address__"; replacement = "localhost:9115"; }
        ];
      }
    ];
  };
  networking.firewall.trustedInterfaces = [ "podman0" ];
}
