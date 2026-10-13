{ config, pkgs, ... }:
{
  # Headless NVIDIA compute stack (no desktop is enabled, so no X starts).
  # immich-ml / comfyui reach the GPU via the container toolkit (CDI).
  nixpkgs.config.allowUnfree = true;              # nvidia driver + CUDA are unfree

  services.xserver.videoDrivers = [ "nvidia" ];   # installs/loads the driver (does NOT launch X)

  hardware.nvidia = {
    modesetting.enable = true;
    # GTX 1070 (Pascal) until the RTX 5070 Ti is in: the open module and the 595
    # branch have no driver for it, the 580 legacy branch does. For the 5070 Ti:
    #   open = true;  package = config.boot.kernelPackages.nvidiaPackages.stable;
    open = false;
    nvidiaSettings = false; # headless — no settings GUI
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
  };

  # Userspace GL/compute libraries (CUDA + containers need these)
  hardware.graphics.enable = true;

  # Expose the GPU to podman containers via CDI:  --device nvidia.com/gpu=all
  hardware.nvidia-container-toolkit.enable = true;

  environment.systemPackages = with pkgs; [
    nvtopPackages.nvidia   # `nvtop` for live GPU monitoring
  ];
}
