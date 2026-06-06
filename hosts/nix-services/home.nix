{ config, pkgs, ... }:
{
  home.stateVersion = "25.11";

  imports = [
    ../../modules/home/git.nix
    ../../modules/home/shell.nix
    

    ./modules/home/fastfetch.nix

  ];
}
