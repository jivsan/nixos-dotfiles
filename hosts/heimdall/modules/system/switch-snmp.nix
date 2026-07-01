{ ... }:
{
  # Poll bifrost (Arista DCS-7050TX-48) over SNMP v2c and expose the interface
  # counters as Prometheus metrics on 127.0.0.1:9274. Prometheus scrapes that
  # (see prometheus.nix, job "switch"); Grafana graphs it (switch-dashboard.json).
  #
  # The RO community lives in /var/lib/secrets/telegraf.env as:
  #     SNMP_COMMUNITY=ro-xxxxxxxx
  # and is enabled on the switch with `snmp-server community <same> ro SNMP-RO`.
  services.telegraf = {
    enable = true;
    environmentFiles = [ "/var/lib/secrets/telegraf.env" ];
    extraConfig = {
      agent = {
        interval = "30s";
        flush_interval = "30s";
        omit_hostname = true;          # don't tag switch metrics with "heimdall"
      };

      inputs.snmp = [{
        agents    = [ "udp://10.0.20.2:161" ];
        version   = 2;
        community = "\${SNMP_COMMUNITY}";
        timeout   = "5s";
        retries   = 1;
        name      = "snmp";

        # Device identity (numeric OIDs + explicit names → no MIBs needed)
        field = [
          { name = "sysName";   oid = "1.3.6.1.2.1.1.5.0"; is_tag = true; }
          { name = "sysUpTime"; oid = "1.3.6.1.2.1.1.3.0"; }
        ];

        # Per-interface counters (IF-MIB ifXTable / ifTable)
        table = [{
          name = "interface";
          inherit_tags = [ "sysName" ];
          field = [
            { name = "ifName";           oid = "1.3.6.1.2.1.31.1.1.1.1";  is_tag = true; }
            { name = "ifAlias";          oid = "1.3.6.1.2.1.31.1.1.1.18"; is_tag = true; }
            { name = "ifHCInOctets";     oid = "1.3.6.1.2.1.31.1.1.1.6";  }
            { name = "ifHCOutOctets";    oid = "1.3.6.1.2.1.31.1.1.1.10"; }
            { name = "ifHCInUcastPkts";  oid = "1.3.6.1.2.1.31.1.1.1.7";  }
            { name = "ifHCOutUcastPkts"; oid = "1.3.6.1.2.1.31.1.1.1.11"; }
            { name = "ifInErrors";       oid = "1.3.6.1.2.1.2.2.1.14"; }
            { name = "ifOutErrors";      oid = "1.3.6.1.2.1.2.2.1.20"; }
            { name = "ifOperStatus";     oid = "1.3.6.1.2.1.2.2.1.8";  }
            { name = "ifAdminStatus";    oid = "1.3.6.1.2.1.2.2.1.7";  }
            { name = "ifHighSpeed";      oid = "1.3.6.1.2.1.31.1.1.1.15"; }
          ];
        }];
      }];

      outputs.prometheus_client = [{
        listen         = "127.0.0.1:9274";   # loopback — Prometheus is on the same host
        metric_version = 2;
      }];
    };
  };
}
