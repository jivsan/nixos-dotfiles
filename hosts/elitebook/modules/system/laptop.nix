{ ... }:

# the elitebook runs 24/7 on mains (no battery) with the lid shut. it must never sleep: the printer
# only buffers a few lines of g-code, so a pause of a few seconds ruins a print
{
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    IdleAction = "ignore";
  };

  # screen off after a minute (lid shut anyway), and no usb autosuspend: it stalls the printer's serial link.
  # if the boot hangs on the nvidia card: add "nomodeset" here and boot.blacklistedKernelModules = [ "nouveau" ];
  boot.kernelParams = [ "consoleblank=60" "usbcore.autosuspend=-1" ];
}
