{ ... }:
{
  imports = [ ../../../../modules/system/nvidia-driver.nix ];

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    nvidiaSettings = true;
    forceFullCompositionPipeline = false;
  };
}
