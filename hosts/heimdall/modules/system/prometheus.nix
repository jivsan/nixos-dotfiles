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
      {
        job_name = "prometheus";
        static_configs = [{ targets = [ "localhost:9090" ]; }];
      }
      {
        job_name = "node";
        static_configs = [
          { targets = [ "localhost:9100" ];      labels = { host = "heimdall"; }; }
          { targets = [ "10.0.20.10:9100" ];     labels = { host = "hella"; }; }
          { targets = [ "10.0.20.6:9100" ];      labels = { host = "truenas"; }; }
          { targets = [ "10.0.20.18:9100" ];     labels = { host = "mimir"; }; }
          { targets = [ "10.0.20.100:9100" ];    labels = { host = "mjolnir"; }; }
          { targets = [ "10.0.20.21:9100" ];     labels = { host = "yggdrasil"; }; }
        ];
      }
      {
        job_name = "ai-gateway";
        static_configs = [{ targets = [ "localhost:4000" ]; }];
      }
      # hosts/mimir/modules/system/gpu-exporter.nix
      {
        job_name = "nvidia-gpu";
        static_configs = [
          { targets = [ "10.0.20.18:9835" ];  labels = { host = "mimir"; }; }
          { targets = [ "10.0.20.100:9835" ]; labels = { host = "mjolnir"; }; }   # hosts/mjolnir/modules/system/exporters.nix
        ];
      }
      {
        job_name = "postgres-immich";
        static_configs = [{ targets = [ "localhost:9187" ]; labels.db = "immich"; }];
      }
      {
        job_name = "traefik";
        static_configs = [{ targets = [ "localhost:8082" ]; }];
      }
      # telegraf on pfsense
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
      # bifrost, through the telegraf snmp poller in switch-snmp.nix
      {
        job_name = "switch";
        static_configs = [{
          targets = [ "127.0.0.1:9274" ];
          labels = {
            host = "bifrost";
            role = "switch";
          };
        }];
      }
      {
        job_name = "blackbox-https";
        metrics_path = "/probe";
        params.module = [ "http_2xx" ];
        static_configs = [{
          targets = [
            "https://immich.oryxserver.org"
            "https://grafana.oryxserver.org"
            "https://traefik.oryxserver.org"
            "https://home.oryxserver.org"
            "https://paperless.oryxserver.org"
            "https://vault.oryxserver.org"
            "https://brain.oryxserver.org"
            "https://changedetection.oryxserver.org"
            "https://search.oryxserver.org"
            "https://git.oryxserver.org"
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
  # grafana's container reaches prometheus, loki and influxdb on the host over podman0
  networking.firewall.trustedInterfaces = [ "podman0" ];
}
