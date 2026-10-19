{ ... }:
{
  # neovim instead of vim on every host that imports this. vim and vi open nvim too,
  # and it's the default editor for sudoedit, git and crontab.
  # my own nvim config comes from modules/home/neovim.nix (mjolnir and tyr)
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };
}
