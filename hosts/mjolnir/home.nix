{ ... }:
# mjolnir's home = your existing shared (oxwm/X11) home + the Hyprland module.
# Both sets of dotfiles are deployed; each session uses only its own.
{
  imports = [
    ../../home.nix
    ./modules/home/hyprland.nix
  ];

  # Her herdr session on yggdrasil (Claude Code, hermes, panes on mimir), from here.
  programs.bash.shellAliases.ygg = "herdr --remote christina@10.0.20.21";
}
