{ ... }:
{
  # Host numbers (CPU, memory, disks, systemd units) for heimdall's Prometheus.
  # The GPU has its own exporter in gpu-exporter.nix.
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" ];
  };

  # reachable from heimdall over VLAN 20
  networking.firewall.allowedTCPPorts = [ 9100 ];
}
