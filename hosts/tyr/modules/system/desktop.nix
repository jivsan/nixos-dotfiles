{ config, pkgs, ... }:
# oxwm over rdp with xrdp (i connect with remmina), no display manager or local x server.
# the session keeps running after i disconnect, so agents carry on
let
  xrdpOxwm = pkgs.writeShellScript "xrdp-oxwm" ''
    export XDG_SESSION_TYPE=x11
    export XDG_CURRENT_DESKTOP=oxwm
    export _JAVA_AWT_WM_NONREPARENTING=1

    # home-manager session variables (cursor theme, EDITOR, ...) and Xresources
    hm=/etc/profiles/per-user/$USER/etc/profile.d/hm-session-vars.sh
    [ -r "$hm" ] && . "$hm"
    [ -r "$HOME/.Xresources" ] && ${pkgs.xrdb}/bin/xrdb -merge "$HOME/.Xresources"

    exec ${config.services.xserver.windowManager.oxwm.package}/bin/oxwm
  '';
in
{
  services.xserver.windowManager.oxwm.enable = true;

  services.xrdp = {
    enable = true;
    openFirewall = true;
    defaultWindowManager = "${xrdpOxwm}";
  };

  # no gpu in the vm: mesa llvmpipe so gl apps like alacritty can start
  hardware.graphics.enable = true;
}
