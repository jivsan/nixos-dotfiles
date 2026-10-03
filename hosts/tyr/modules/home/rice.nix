{ config, lib, pkgs, ... }:
# tyr's rice: the neon oxwm desktop you get over RDP.
#
# The configs in ./rice are symlinked straight out of the repo clone
# (~/nixos-dotfiles), the same trick as modules/home/xdg.nix, so you can edit
# them on tyr and reload without a rebuild:
#   oxwm   Mod+Shift+R          picom   Mod+Shift+P twice
# The wallpaper is drawn at build time by ./rice/wallpaper.sh.
let
  rice = "${config.home.homeDirectory}/nixos-dotfiles/hosts/tyr/modules/home/rice";
  link = path: config.lib.file.mkOutOfStoreSymlink "${rice}/${path}";

  wallpaper = pkgs.runCommand "tyr-neon-wallpaper.png"
    { nativeBuildInputs = [ pkgs.imagemagick ]; }
    "sh ${./rice/wallpaper.sh} $out";

  # Your dmenu build (config/dmenu) with one tyr-only patch that adds two
  # flags: -c WIDTH (centre the menu) and -bw PX (border). The colours are
  # passed by the Mod+D keybind in rice/oxwm/config.lua.
  dmenuTyr = pkgs.dmenu.overrideAttrs (_: {
    src = ../../../../config/dmenu;
    patches = [ ./rice/dmenu-center-border.diff ];
  });
in
{
  home.packages = with pkgs; [
    # takes the place of the unpatched build from modules/home/suckless.nix
    (lib.hiPrio dmenuTyr)

    picom      # effects — started by oxwm's autostart, not as a service
    feh        # wallpaper
    xev        # rice/oxwm/scripts/wallpaper.sh watches for screen resizes with it
    xrandr     # ... and refreshes the monitor layout before each repaint
    maim       # Mod+S: screenshot region ...
    xclip      # ... to the clipboard
    xsetroot
    procps     # pgrep/pkill for the bar's agent counter and the picom toggle
    cmatrix    # Mod+Shift+M
  ];

  xdg.configFile."oxwm".source = link "oxwm";
  xdg.configFile."picom/picom.conf".source = link "picom.conf";
  xdg.dataFile."wallpapers/tyr-neon.png".source = wallpaper;

  programs.rofi = {
    enable = true;
    terminal = "alacritty";
    theme = ./rice/rofi/neon.rasi;
    extraConfig = {
      display-drun = "apps";
      display-run = "run";
      display-window = "windows";
      show-icons = false;
    };
  };

  # Same cursor as mjolnir
  home.pointerCursor = {
    name = "Bibata-Modern-Ice";
    package = pkgs.bibata-cursors;
    size = 24;
    x11.enable = true;
  };

  # See-through terminals (modules/home/terminal.nix sets 0.94)
  programs.alacritty.settings.window.opacity = lib.mkForce 0.86;

  # btop on the terminal's own colours and background, so it is glass too
  programs.btop = {
    enable = true;
    settings = {
      color_theme = "TTY";
      theme_background = false;
      rounded_corners = true;
    };
  };
}
