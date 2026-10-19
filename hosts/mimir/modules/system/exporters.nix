{ ... }:
{
  # host numbers for heimdall's prometheus, the gpu has its own in gpu-exporter.nix
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" ];
  };

  # reachable from heimdall over VLAN 20
  networking.firewall.allowedTCPPorts = [ 9100 ];
}
