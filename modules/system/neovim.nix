{ ... }:
{
  # nvim for vi, vim, sudoedit, git and crontab on every host that imports this
  # my config/nvim and its tools are only on mjolnir and tyr, through home-manager (modules/home/neovim.nix)
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };
}
