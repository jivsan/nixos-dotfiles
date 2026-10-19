# mjolnir's desktop base for home-manager, imported as its own file so module order stays the same
{ pkgs, inputs, ... }:

{
  imports = [
    ../../../../modules/home/git.nix
    ../../../../modules/home/shell.nix
    ../../../../modules/home/terminal.nix
    ./xdg.nix
    ./programs.nix
    ../../../../modules/home/suckless.nix
    ../../../../modules/home/neovim.nix
    ./gtk.nix
    ./picom.nix
  ];

  home.username = "christina";
  home.homeDirectory = "/home/christina";
  home.stateVersion = "25.11";
  home.packages = [
    inputs.helium.packages.${pkgs.stdenv.hostPlatform.system}.default
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
