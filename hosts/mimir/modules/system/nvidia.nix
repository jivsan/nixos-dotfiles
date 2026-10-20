{ pkgs, ... }:
{
  imports = [ ../../../../modules/system/nvidia-driver.nix ];

  # headless nvidia compute, no desktop
  nixpkgs.config.allowUnfree = true;

  services.xserver.videoDrivers = [ "nvidia" ];   # loads the driver, doesn't start x

  hardware.nvidia = {
    nvidiaSettings = false;
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
