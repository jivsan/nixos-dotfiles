{ config, pkgs, inputs, ... }:

{
  imports = [
    ./modules/home/git.nix
    ./modules/home/shell.nix
    ./modules/home/terminal.nix
    ./modules/home/xdg.nix
    ./modules/home/programs.nix
    ./modules/home/suckless.nix
    ./modules/home/neovim.nix
    ./modules/home/gtk.nix
    ./modules/home/picom.nix
  ];

  home.username = "christina";
  home.homeDirectory = "/home/christina";
  home.stateVersion = "25.11";
  home.packages = [
    inputs.helium.packages.${pkgs.system}.default
      pkgs.brave
  ];

  services.easyeffects.enable = true;
  
  services.udiskie = {
    enable = true;
    automount = true;
    notify = false;
    tray = "never";
  };

  xresources.properties = {
    "Xft.dpi" = 110;
    "Xcursor.size" = 24;
  };
}
