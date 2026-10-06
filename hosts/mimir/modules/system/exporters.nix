{ config, pkgs, ... }:
{
  # Numbers for heimdall's Prometheus: the host (:9100) and the GPU (:9835).
  # The GPU exporter runs nvidia-smi on every scrape; until a card the driver
  # can talk to is installed it stays up and reports no GPU.
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" ];
  };

  systemd.services.nvidia-gpu-exporter = {
    description = "Prometheus exporter for nvidia-smi";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.prometheus-nvidia-gpu-exporter}/bin/nvidia_gpu_exporter"
        + " --web.listen-address=:9835"
        + " --nvidia-smi-command=${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
      DynamicUser = true;
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # reachable from heimdall over VLAN 20
  networking.firewall.allowedTCPPorts = [ 9100 9835 ];
}
