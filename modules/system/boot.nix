{ ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # GSP firmware left ENABLED. NVreg_EnableGpuFirmware=0 was inert under the open
  # kernel module but takes effect under the proprietary one, disabling the GPU
  # System Processor - which handles context scheduling, the subsystem raising
  # Xid 109 CTX SWITCH TIMEOUT. Removed while chasing those GPU hangs.
  boot.kernelParams = [ ];
}
