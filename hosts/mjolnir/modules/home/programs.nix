{ pkgs, ... }:
{
  programs.vscodium.enable = true;

  home.packages = with pkgs; [
    gcc
    rofi
    feh
    rsync
    python3      # for scripts, mine and the agents' (none of them had a python here)
  ];
}
