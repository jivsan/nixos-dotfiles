{ config, lib, pkgs, ... }:
# my neon oxwm desktop on tyr, over rdp
# ./rice is linked from the repo clone, so a pulled change shows after a reload, no rebuild:
#   oxwm   Mod+Shift+R          picom   Mod+Shift+P twice
let
  rice = "${config.home.homeDirectory}/nixos-dotfiles/hosts/tyr/modules/home/rice";
  link = path: config.lib.file.mkOutOfStoreSymlink "${rice}/${path}";

  wallpaper = pkgs.runCommand "tyr-neon-wallpaper.png"
    { nativeBuildInputs = [ pkgs.imagemagick ]; }
    "sh ${./rice/wallpaper.sh} $out";

  # my dmenu (config/dmenu) with a tyr-only patch: -c WIDTH centres it, -bw PX adds a border.
  # the colours come from the Mod+D bind in rice/oxwm/config.lua
  dmenuTyr = pkgs.dmenu.overrideAttrs (_: {
    src = ../../../../config/dmenu;
    patches = [ ./rice/dmenu-center-border.diff ];
  });
in
{
  home.packages = with pkgs; [
    # wins over the unpatched build from modules/home/suckless.nix
    (lib.hiPrio dmenuTyr)

    picom      # started by oxwm's autostart, not as a service
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

  # same cursor as mjolnir
  home.pointerCursor = {
    name = "Bibata-Modern-Ice";
    package = pkgs.bibata-cursors;
    size = 24;
    x11.enable = true;
  };

  # more see-through than terminal.nix's 0.94
  programs.alacritty.settings.window.opacity = lib.mkForce 0.86;

  # btop on the terminal's own colours and background, so it's see-through too
  programs.btop = {
    enable = true;
    settings = {
      color_theme = "TTY";
      theme_background = false;
      rounded_corners = true;
    };
  };
}
