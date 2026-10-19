{ pkgs, ... }:
{
  programs.vscodium.enable = true;

  home.packages = with pkgs; [
    gcc
    rofi
    feh
    rsync
  ];
}
