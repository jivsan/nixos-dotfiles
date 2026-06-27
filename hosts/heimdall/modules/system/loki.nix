{ ... }:
{
  systemd.tmpfiles.rules = [
    "d /var/lib/loki 0750 loki loki -"
  ];

  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;

      server = {
        http_listen_port = 3100;
        http_listen_address = "0.0.0.0";
        grpc_listen_port = 9096;
      };

      common = {
        path_prefix = "/var/lib/loki";
        storage.filesystem = {
          chunks_directory = "/var/lib/loki/chunks";
          rules_directory = "/var/lib/loki/rules";
        };
        replication_factor = 1;
        ring.kvstore.store = "inmemory";
        instance_addr = "127.0.0.1";
      };

      schema_config.configs = [{
        from = "2024-01-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = {
          prefix = "index_";
          period = "24h";
        };
      }];

      limits_config = {
        retention_period = "720h";
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
        allow_structured_metadata = true;
      };

      compactor = {
        working_directory = "/var/lib/loki/compactor";
        retention_enabled = true;
        retention_delete_delay = "2h";
        retention_delete_worker_count = 150;
        delete_request_store = "filesystem";
      };

      analytics.reporting_enabled = false;
    };
  };

  networking.firewall.allowedTCPPorts = [ 3100 ];
}
