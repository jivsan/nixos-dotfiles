{ config, pkgs, ... }:
{
  # Headless NVIDIA compute stack (no desktop is enabled, so no X starts).
  # immich-ml / comfyui reach the GPU via the container toolkit (CDI).
  nixpkgs.config.allowUnfree = true;              # nvidia driver + CUDA are unfree

  services.xserver.videoDrivers = [ "nvidia" ];   # installs/loads the driver (does NOT launch X)

  hardware.nvidia = {
    modesetting.enable = true;
    # RTX 4060 Ti (Ada, 8 GB) since 2026-10-19, mjolnir's old card. It runs on the 580
    # legacy branch that was put here for the GTX 1070 (Pascal has no driver in the
    # open module or the 595 branch). The 4060 Ti also runs on the newer driver:
    #   open = true;  package = config.boot.kernelPackages.nvidiaPackages.stable;
    open = false;
    nvidiaSettings = false; # headless — no settings GUI
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    # Keeps the card set up while nothing uses it, so the GPU exporter's nvidia-smi
    # every 15 s only reads numbers instead of waking the card (and its fans).
    nvidiaPersistenced = true;
  };

  # Userspace GL/compute libraries (CUDA + containers need these)
  hardware.graphics.enable = true;

  # Expose the GPU to podman containers via CDI:  --device nvidia.com/gpu=all
  hardware.nvidia-container-toolkit.enable = true;

  environment.systemPackages = with pkgs; [
    nvtopPackages.nvidia   # `nvtop` for live GPU monitoring
  ];
}
