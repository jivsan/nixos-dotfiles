{ config, pkgs, ... }:
{
  # gpu numbers for heimdall's prometheus on :9835, it runs nvidia-smi on every 15 s scrape
  # only import it while the driver binds the card: if it can't, every nvidia-smi loads and
  # unloads the driver and the fans ramp up and down all day
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
