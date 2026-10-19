{ config, lib, pkgs, ... }:
# hyprland, waybar and mako config, only read in the hyprland session; oxwm uses none of it
{
  home.packages = with pkgs; [
    waybar awww mako hypridle      # bar, wallpaper engine, notifications, idle
    cliphist wl-clipboard          # clipboard history
    grim slurp swappy              # screenshots + annotate
    # rofi is in ./programs.nix, hyprlock in the system hyprland.nix
  ];

  # links into the repo, so i edit hypr, waybar and mako there without a rebuild
  xdg.configFile."hypr".source =
    config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nixos-dotfiles/hosts/mjolnir/hypr";

  xdg.configFile."waybar".source =
    config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nixos-dotfiles/hosts/mjolnir/waybar";

  xdg.configFile."mako".source =
    config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nixos-dotfiles/hosts/mjolnir/mako";
}
