{ config, pkgs, ... }:

let
  xrdpOxwm = pkgs.writeShellScript "xrdp-oxwm" ''
    export XDG_SESSION_TYPE=x11
    export XDG_CURRENT_DESKTOP=oxwm
    export _JAVA_AWT_WM_NONREPARENTING=1
    exec ${config.services.xserver.windowManager.oxwm.package}/bin/oxwm
  '';
in
{
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
  };

  services.xrdp = {
    enable = true;
    openFirewall = true;
    defaultWindowManager = "${xrdpOxwm}";
  };
}
