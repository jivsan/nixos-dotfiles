{ config, pkgs, ... }:
{
  # headless nvidia compute, no desktop
  nixpkgs.config.allowUnfree = true;

  services.xserver.videoDrivers = [ "nvidia" ];   # loads the driver, doesn't start x

  hardware.nvidia = {
    modesetting.enable = true;
    # rtx 4060 ti (8 gb) on the closed 580 branch. it can move to the newer driver:
    #   open = true;  package = config.boot.kernelPackages.nvidiaPackages.stable;
    open = false;
    nvidiaSettings = false;
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    # keeps the card set up while idle, so the gpu exporter's nvidia-smi every 15 s
    # only reads numbers instead of waking the card (and its fans)
    nvidiaPersistenced = true;
  };

  hardware.graphics.enable = true;   # cuda and the containers need these libs

  # cdi for podman: immich-ml and comfyui ask for --device nvidia.com/gpu=all
  hardware.nvidia-container-toolkit.enable = true;

  environment.systemPackages = with pkgs; [
    nvtopPackages.nvidia
  ];
}
