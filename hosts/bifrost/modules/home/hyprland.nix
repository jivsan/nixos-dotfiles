{ config, lib, pkgs, inputs, ... }:
{
  home.packages = with pkgs; [
    rofi            # launcher (Super+D). rofi-wayland was merged into rofi in nixpkgs 26.05
    waybar          # status bar
    hypridle        # idle daemon (lock-on-idle; no suspend/dpms — VNC-safe)
    mako            # notifications (frosted glass)
    xfce.thunar     # file manager (Super+E)
    swaybg          # wallpaper
    wayvnc          # the VNC server Remmina connects to
    wl-clipboard    # wl-copy / wl-paste
    grim slurp      # screenshots (handy over VNC)
    # hyprlock comes from programs.hyprlock.enable in default.nix (also sets up PAM)
    # lua-language-server comes from ../../modules/home/neovim.nix
  ] ++ [
    inputs.helium.packages.${pkgs.system}.default   # helium browser (Super+W)
  ];

  # Live-edit ~/.config/hypr  <- repo (same mkOutOfStoreSymlink trick as xdg.nix)
  xdg.configFile."hypr".source =
    config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nixos-dotfiles/hosts/bifrost/hypr";

  # Live-edit ~/.config/waybar <- repo
  xdg.configFile."waybar".source =
    config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nixos-dotfiles/hosts/bifrost/waybar";

  # Live-edit ~/.config/mako <- repo
  xdg.configFile."mako".source =
    config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nixos-dotfiles/hosts/bifrost/mako";
}
