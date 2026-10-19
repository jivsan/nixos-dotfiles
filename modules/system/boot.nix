{ ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # don't add NVreg_EnableGpuFirmware=0 back: with the proprietary driver it turns off
  # the gsp, which does context scheduling (the part raising xid 109 ctx switch timeouts)
  boot.kernelParams = [ ];
}
