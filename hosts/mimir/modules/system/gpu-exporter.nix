{ config, pkgs, ... }:
{
  # GPU numbers (utilisation, VRAM, temperature, power, fan) for heimdall's
  # Prometheus, on :9835. It runs nvidia-smi on every scrape, every 15 s.
  #
  # Import this only while a card the driver supports is installed. With the
  # GTX 1070 and the open kernel module (2026-10-06), each nvidia-smi made the
  # kernel load the driver, fail to bind the card and unload it again, five
  # times per scrape: the card's fans ramped up and down all day.
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
  networking.firewall.allowedTCPPorts = [ 9835 ];
}
