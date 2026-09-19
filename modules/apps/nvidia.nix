{ config, ... }:
{
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = true;
    open = false;   # testing: proprietary module, chasing Xid 109 CTX SWITCH TIMEOUT
    package = config.boot.kernelPackages.nvidiaPackages.new_feature;
    forceFullCompositionPipeline = false;
  };
}
