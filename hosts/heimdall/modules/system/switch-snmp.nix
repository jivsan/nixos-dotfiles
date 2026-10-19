{ ... }:
{
  # telegraf polls bifrost's interface counters over snmp v2c for prometheus (job "switch")
  # needs SNMP_COMMUNITY=ro-... in /var/lib/secrets/telegraf.env,
  # the same community set on the switch: snmp-server community <same> ro SNMP-RO
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

        # numeric oids with names, so no mibs are needed
        field = [
          { name = "sysName";   oid = "1.3.6.1.2.1.1.5.0"; is_tag = true; }
          { name = "sysUpTime"; oid = "1.3.6.1.2.1.1.3.0"; }
        ];

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
        listen         = "127.0.0.1:9274";
        metric_version = 2;
      }];
    };
  };
}
