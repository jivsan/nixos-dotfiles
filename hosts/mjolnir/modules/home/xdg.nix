{ config, ... }:
{
  # live link to my nvim config in the repo, so edits apply without a rebuild
  xdg.configFile.nvim = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nixos-dotfiles/config/nvim";
    recursive = true;
  };
}
