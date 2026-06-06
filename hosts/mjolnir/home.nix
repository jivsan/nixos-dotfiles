{ ... }:
# mjolnir's home = your existing shared (oxwm/X11) home + the Hyprland module.
# Both sets of dotfiles are deployed; each session uses only its own.
{
  imports = [
    ../../home.nix
    ./modules/home/hyprland.nix
  ];
}
