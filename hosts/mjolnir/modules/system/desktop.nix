{ pkgs, ... }:

{
  services.xserver = {
    enable = true;
    dpi = 110;
    displayManager.startx.enable = true;
    windowManager.oxwm.enable = true;

    displayManager.sessionCommands = ''
      ${pkgs.xrandr}/bin/xrandr --output HDMI-0 --off
      ${pkgs.xrandr}/bin/xrandr --output DP-0 --off
      ${pkgs.xrandr}/bin/xrandr --fb 4480x1440 \
        --output DP-0 --primary --mode 2560x1440 --rate 120 --pos 1920x0 --rotate normal \
        --output HDMI-0 --mode 1920x1080 --rate 60 --pos 0x180 --rotate normal

      ${pkgs.feh}/bin/feh --bg-fill /home/christina/pictures/wallpapers/bg1.png
    '';
  };

  services.displayManager.ly.enable = true;

  environment.systemPackages = with pkgs; [
    xinit
    xrandr
    xterm
  ];
}
