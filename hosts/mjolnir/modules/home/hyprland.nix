{ config, lib, pkgs, ... }:
# mjolnir Hyprland home config. Coexists with your oxwm/X11 home modules — the
# files live under ~/.config/{hypr,waybar,mako} and are only read when you log
# into the Hyprland session. Nothing here touches oxwm.
{
  home.packages = with pkgs; [
    waybar awww mako hypridle      # bar, wallpaper engine, notifications, idle
    cliphist wl-clipboard          # clipboard history
    grim slurp swappy              # screenshots + annotate
    # rofi comes from your shared modules/home/programs.nix
    # hyprlock comes from programs.hyprlock.enable (system module)
  ];

  # Live-edit symlinks: edit files in the repo, Hyprland/waybar pick them up.
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
