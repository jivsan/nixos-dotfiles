{ ... }:
{
  # host numbers for heimdall's prometheus: yggdrasil's card in homarr and grafana
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" ];
  };

  # heimdall scrapes it over vlan 20
  networking.firewall.allowedTCPPorts = [ 9100 ];
}
