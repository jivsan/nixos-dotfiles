{ config, pkgs, inputs, ... }:
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

  home.packages = [
    inputs.helium.packages.${pkgs.stdenv.hostPlatform.system}.default   # helium browser, as on mjolnir
    pkgs.gcc                                                            # nvim-treesitter compiles its parsers
  ];

  # nvim config linked from the repo clone, like mjolnir's xdg.nix does
  # (that module isn't imported here: it links rofi too, which rice.nix owns)
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nixos-dotfiles/config/nvim";
}
