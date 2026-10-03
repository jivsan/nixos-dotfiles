{ config, pkgs, ... }:
# tyr's desktop: oxwm served over RDP by xrdp (connect with Remmina).
#
# No display manager and no local X server — xrdp starts an Xorg session when
# you connect and keeps it running after you disconnect, so agents carry on.
# Unlike modules/system/remote.nix this leaves sshd alone (tyr is key-only).
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

  # No GPU in the VM: Mesa llvmpipe so GL clients (alacritty) can start.
  hardware.graphics.enable = true;
}
