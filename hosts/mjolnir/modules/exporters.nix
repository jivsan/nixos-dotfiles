{ config, pkgs, ... }:
{
  # Host and GPU numbers for heimdall's Prometheus, the same pair mimir runs
  # (hosts/mimir/modules/system/exporters.nix + gpu-exporter.nix). They feed
  # mjolnir's card on the Homarr dashboard and Grafana.
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" ];
  };

  # RTX 5070 Ti: utilisation, VRAM, temperature, power, fan. Runs nvidia-smi on
  # every scrape (every 15 s); a full card is what hangs Octane test renders.
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
