{ pkgs, inputs, ... }:
# hyprland as a login option in ly next to oxwm, the x11/oxwm session stays as it is
{
  programs.hyprland = {
    enable = true;
    package       = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  };

  # hyprlock needs its own pam service to unlock
  programs.hyprlock.enable = true;
  security.pam.services.hyprlock = { };

  # hyprland's cache, so the flake's hyprland isn't compiled here
  nix.settings = {
    extra-substituters = [ "https://hyprland.cachix.org" ];
    extra-trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
    ];
  };
}
