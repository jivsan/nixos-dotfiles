{ config, pkgs, ... }:
{
  # Headless NVIDIA compute stack (no desktop is enabled, so no X starts).
  # immich-ml / comfyui reach the GPU via the container toolkit (CDI);
  # ollama uses CUDA directly.
  nixpkgs.config.allowUnfree = true;              # nvidia driver + CUDA are unfree

  services.xserver.videoDrivers = [ "nvidia" ];   # installs/loads the driver (does NOT launch X)

  hardware.nvidia = {
    modesetting.enable = true;
    open = false;           # proprietary modules. GTX 1070 is Pascal — the OPEN modules only
                            # support Turing (RTX 20-series)+ and never bind on Pascal.
                            # Flip to true when the 3090 goes in (open modules are the
                            # mainline path for Ampere on the 59x drivers).
    nvidiaSettings = false; # headless — no settings GUI

    # ── STOPGAP: GTX 1070 (Pascal) ────────────────────────────────────────
    # NVIDIA dropped Maxwell/Pascal/Volta after the 580 branch, so
    # nvidiaPackages.stable (595.x) ignores the card ("No NVIDIA GPU found").
    # TODO: revert to `stable` when the RTX 3090 arrives.
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    # package = config.boot.kernelPackages.nvidiaPackages.stable;   # ← 3090
  };

  # Userspace GL/compute libraries (CUDA + containers need these)
  hardware.graphics.enable = true;

  # Expose the GPU to podman containers via CDI:  --device nvidia.com/gpu=all
  hardware.nvidia-container-toolkit.enable = true;

  environment.systemPackages = with pkgs; [
    nvtopPackages.nvidia   # `nvtop` for live GPU monitoring
  ];
}
