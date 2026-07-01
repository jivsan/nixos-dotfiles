{ config, pkgs, ... }:
{
  # Headless NVIDIA compute stack (no desktop is enabled, so no X starts).
  # immich-ml / comfyui reach the GPU via the container toolkit (CDI);
  # ollama uses CUDA directly.
  nixpkgs.config.allowUnfree = true;              # nvidia driver + CUDA are unfree

  services.xserver.videoDrivers = [ "nvidia" ];   # installs/loads the driver (does NOT launch X)

  hardware.nvidia = {
    modesetting.enable = true;
    open = true;            # open kernel modules (Turing/RTX 20-series+). Set false for older GPUs.
    nvidiaSettings = false; # headless — no settings GUI
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Userspace GL/compute libraries (CUDA + containers need these)
  hardware.graphics.enable = true;

  # Expose the GPU to podman containers via CDI:  --device nvidia.com/gpu=all
  hardware.nvidia-container-toolkit.enable = true;

  environment.systemPackages = with pkgs; [
    nvtopPackages.nvidia   # `nvtop` for live GPU monitoring
  ];
}
