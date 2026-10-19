{ config, pkgs, ... }:
{
  # host and gpu numbers for heimdall's prometheus (mjolnir's card in homarr and grafana),
  # the same pair mimir runs
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" ];
  };

  # runs nvidia-smi on every scrape (15 s). vram matters: a full card hangs octane test renders
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

  # heimdall scrapes these over vlan 20
  networking.firewall.allowedTCPPorts = [ 9100 9835 ];
}
