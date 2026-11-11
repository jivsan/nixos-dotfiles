{ ... }:
{
  imports = [
    ./modules/home/base.nix
    ./modules/home/hyprland.nix
    ./modules/home/fastfetch.nix         # the same look as heimdall's
  ];

  # my herdr session on yggdrasil (claude code, hermes, panes on mimir)
  programs.bash.shellAliases.ygg = "herdr --remote christina@10.0.20.21";
}
