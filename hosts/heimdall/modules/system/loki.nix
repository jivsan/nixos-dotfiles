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
        http_listen_address = "0.0.0.0";   # grafana's container comes in over podman0; the raw chain below limits it
        grpc_listen_port = 9096;
        grpc_listen_address = "127.0.0.1"; # only loki's own parts talk grpc
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

  # auth is off, so only these reach :3100: heimdall itself (lo: ai-gateway pushes its request lines,
  # promtail is off) and grafana's container (podman0, from its fixed address in grafana.nix).
  # nobody on the lan or the tailnet. tailscale's own ts-input chain accepts tailnet traffic before
  # nixos-fw runs, so this sits in the raw table like ntfy.nix. it only looks at packets for heimdall's
  # own addresses (addrtype LOCAL), so traffic i forward (containers, awg0) to some other :3100 still works
  networking.firewall.extraCommands = ''
    iptables -t raw -N loki-only 2>/dev/null || iptables -t raw -F loki-only
    iptables -t raw -A loki-only -i lo -j RETURN
    iptables -t raw -A loki-only -i podman0 -s 10.88.200.11 -j RETURN
    iptables -t raw -A loki-only -j DROP
    iptables -t raw -C PREROUTING -p tcp --dport 3100 -m addrtype --dst-type LOCAL -j loki-only 2>/dev/null \
      || iptables -t raw -A PREROUTING -p tcp --dport 3100 -m addrtype --dst-type LOCAL -j loki-only
    ip6tables -t raw -C PREROUTING -p tcp --dport 3100 -m addrtype --dst-type LOCAL ! -i lo -j DROP 2>/dev/null \
      || ip6tables -t raw -A PREROUTING -p tcp --dport 3100 -m addrtype --dst-type LOCAL ! -i lo -j DROP
  '';
  networking.firewall.extraStopCommands = ''
    iptables -t raw -D PREROUTING -p tcp --dport 3100 -m addrtype --dst-type LOCAL -j loki-only 2>/dev/null || true
    iptables -t raw -F loki-only 2>/dev/null || true
    iptables -t raw -X loki-only 2>/dev/null || true
    ip6tables -t raw -D PREROUTING -p tcp --dport 3100 -m addrtype --dst-type LOCAL ! -i lo -j DROP 2>/dev/null || true
  '';
}
