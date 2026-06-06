{ pkgs, ... }:
{
  home.packages = with pkgs; [
    neovim
    ripgrep
    fd
    fzf
    lua-language-server
    nil
    nixpkgs-fmt
    nodejs
  ];

  home.sessionVariables.EDITOR = "nvim";
  home.shellAliases = {
    vi = "nvim";
    vim = "nvim";
  };
}
