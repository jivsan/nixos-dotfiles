{ pkgs, ... }:

{
  services.xserver = {
    enable = true;
    dpi = 110;
    displayManager.startx.enable = true;
    windowManager.oxwm.enable = true;

    # the 5070 Ti renamed the ports (dell DP-0 -> DP-4), so i find the screens
    # by port type: dell on displayport, benq on hdmi
    displayManager.sessionCommands = ''
      xr=${pkgs.xrandr}/bin/xrandr
      dell=$($xr | ${pkgs.gawk}/bin/awk '/^DP-[0-9]+ connected/ {print $1; exit}')
      benq=$($xr | ${pkgs.gawk}/bin/awk '/^HDMI-[0-9]+ connected/ {print $1; exit}')
      $xr --fb 4480x1440 \
        --output "$dell" --primary --mode 2560x1440 --rate 120 --pos 1920x0 --rotate normal \
        --output "$benq" --mode 1920x1080 --rate 60 --pos 0x180 --rotate normal

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
