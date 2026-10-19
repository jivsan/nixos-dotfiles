{ ... }:
{
  # Host numbers (CPU, memory, disks, systemd units) for heimdall's Prometheus;
  # they feed yggdrasil's card on the Homarr dashboard and Grafana.
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" ];
  };

  # reachable from heimdall over VLAN 20
  networking.firewall.allowedTCPPorts = [ 9100 ];
}
