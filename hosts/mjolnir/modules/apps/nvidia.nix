{ config, ... }:
{
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = true;
    # Open module: the RTX 5070 Ti (Blackwell, in from 2026-10-19) runs only on it. The
    # proprietary module was a test while chasing Xid 109 CTX SWITCH TIMEOUT on the
    # RTX 4060 Ti, which moved to mimir. The open module drives the 4060 Ti as well, so
    # this boots right before and after the swap.
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.production;
    forceFullCompositionPipeline = false;
  };
}
