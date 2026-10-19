{ config, pkgs, ... }:
let
  tokyonight = pkgs.tokyonight-gtk-theme;
in
{
  # one cursor for gtk, hyprland and oxwm (also sets XCURSOR_THEME/XCURSOR_SIZE)
  home.pointerCursor = {
    name = "Bibata-Modern-Ice";
    package = pkgs.bibata-cursors;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  gtk = {
    # gtk4 follows the theme below; home-manager 26.05 defaults this to null and warns until set
    gtk4.theme = config.gtk.theme;

    enable = true;
    theme = {
      name = "Tokyonight-Dark";
      package = tokyonight;
    };
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      gtk-theme = "Tokyonight-Dark";
      icon-theme = "Papirus-Dark";
      cursor-theme = "Bibata-Modern-Ice";
      cursor-size = 24;
      font-name = "JetBrainsMono Nerd Font 11";
    };
  };

  xdg.configFile."gtk-4.0/assets".source = "${tokyonight}/share/themes/Tokyonight-Dark/gtk-4.0/assets";
  xdg.configFile."gtk-4.0/gtk.css".source = "${tokyonight}/share/themes/Tokyonight-Dark/gtk-4.0/gtk.css";
  xdg.configFile."gtk-4.0/gtk-dark.css".source = "${tokyonight}/share/themes/Tokyonight-Dark/gtk-4.0/gtk-dark.css";

  home.packages = with pkgs; [
    glib
    nautilus
  ];
}
