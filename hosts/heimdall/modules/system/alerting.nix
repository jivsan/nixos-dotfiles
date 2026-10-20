{ ... }:

let
  # same relabelling as blackbox-https in prometheus.nix: probe the target through the local blackbox exporter
  probe = job: module: targets: {
    job_name = job;
    metrics_path = "/probe";
    params.module = [ module ];
    static_configs = [{ inherit targets; }];
    relabel_configs = [
      { source_labels = [ "__address__" ];  target_label = "__param_target"; }
      { source_labels = [ "__param_target" ]; target_label = "instance"; }
      { target_label = "__address__"; replacement = "localhost:9115"; }
    ];
  };

  rules = {
    groups = [{
      name = "fleet";
      rules = [
        # mjolnir is off at night and truenas's node exporter comes and goes, so neither is here.
        # odyn has its own probe below
        {
          alert = "HostDown";
          expr = ''up{job="node", host=~"heimdall|hella|mimir|yggdrasil"} == 0'';
          for = "5m";
          annotations.summary = "{{ $labels.host }} has not answered for 5 minutes";
        }
        {
          alert = "OdynDown";
          expr = ''probe_success{job="odyn"} == 0'';
          for = "3m";
          annotations.summary = "odyn (TrueNAS) is not answering on {{ $labels.instance }}";
        }
        # appdb: the postgres on odyn that the apps on yggdrasil keep their data in (odyn/apps/appdb)
        {
          alert = "AppDbDown";
          expr = ''probe_success{job="appdb"} == 0'';
          for = "3m";
          annotations.summary = "appdb (postgres on odyn, 10.0.20.6:5432) is not answering, forgejo and n8n are down with it";
        }
        {
          alert = "PiholeDown";
          expr = ''probe_success{job="pihole-dns"} == 0'';
          for = "3m";
          annotations.summary = "Pi-hole (10.0.20.4) is not answering DNS, so *.oryxserver.org stops resolving";
        }
        # huginn's own units push through huginn-notify (huginn.nix) with their log lines, so not twice
        {
          alert = "UnitFailed";
          expr = ''node_systemd_unit_state{state="failed", name!~"huginn-.*"} == 1'';
          for = "5m";
          annotations.summary = "{{ $labels.name }} failed on {{ $labels.host }}";
        }
        {
          alert = "DiskAlmostFull";
          expr = ''node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|devtmpfs|overlay|squashfs|efivarfs|nfs.*|fuse.*"} / node_filesystem_size_bytes < 0.10'';
          for = "15m";
          annotations.summary = "{{ $labels.mountpoint }} on {{ $labels.host }} has {{ $value | humanizePercentage }} free";
        }
        {
          alert = "SiteDown";
          expr = ''probe_success{job="blackbox-https"} == 0'';
          for = "5m";
          annotations.summary = "{{ $labels.instance }} is not answering";
        }
        # every site shares the wildcard cert, so one alert, not one per site
        {
          alert = "CertExpiresSoon";
          expr = ''min(probe_ssl_earliest_cert_expiry{job="blackbox-https"}) - time() < 14 * 86400'';
          for = "1h";
          annotations.summary = "the *.oryxserver.org certificate runs out in {{ $value | humanizeDuration }}, acme renewal is failing";
        }
      ];
    }];
  };
in
{
  services.prometheus = {
    rules = [ (builtins.toJSON rules) ];
    alertmanagers = [{ static_configs = [{ targets = [ "127.0.0.1:9093" ]; }]; }];

    scrapeConfigs = [
      (probe "odyn" "tcp_connect" [ "10.0.20.6:2049" "10.0.20.6:443" ])   # nfs and the web ui
      (probe "pihole-dns" "dns_oryx" [ "10.0.20.4:53" ])
      (probe "appdb" "tcp_connect" [ "10.0.20.6:5432" ])   # odyn/apps/appdb
    ];

    # every alert goes to the ntfy topic "alerts", rendered by the prometheus template in ntfy.nix
    alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9093;
      extraFlags = [ "--cluster.listen-address=" ];   # one alertmanager, no cluster port
      # NTFY_TOKEN=tk_..., substituted into the config at start by envsubst
      environmentFile = "/var/lib/secrets/ntfy-publish.env";
      configuration = {
        route = {
          receiver = "ntfy";
          group_by = [ "alertname" ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";
        };
        receivers = [{
          name = "ntfy";
          webhook_configs = [{
            url = "http://127.0.0.1:2586/alerts?template=prometheus";
            send_resolved = true;
            http_config.authorization.credentials = "$NTFY_TOKEN";
          }];
        }];
      };
    };
  };
}
