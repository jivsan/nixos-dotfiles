{ pkgs, ... }:
let
  tokyonight = pkgs.tokyonight-gtk-theme;
in
{
  gtk = {
    enable = true;
    theme = {
      name = "Tokyonight-Dark";
      package = tokyonight;
    };
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      gtk-theme = "Tokyonight-Dark";
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
