{ config, pkgs, ... }:
{
  home.stateVersion = "26.05";

  imports = [
    ../../modules/home/git.nix
    ../../modules/home/shell.nix
    ../../modules/home/terminal.nix
    ../../modules/home/suckless.nix
    ../../modules/home/neovim.nix

    ./modules/home/fastfetch.nix
    ./modules/home/rice.nix
  ];

  # nvim config straight from the repo clone (what modules/home/xdg.nix does
  # on mjolnir; that module also links rofi, which rice.nix owns here).
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nixos-dotfiles/config/nvim";
}
