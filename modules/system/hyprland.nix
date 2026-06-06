{ pkgs, inputs, ... }:
# Reusable Hyprland *session* enablement. Importing this only makes Hyprland
# available as a login option (ly lists it next to oxwm) — it does not change
# or disable your X11/oxwm session in any way. Safe to import on any host.
{
  programs.hyprland = {
    enable = true;
    package       = inputs.hyprland.packages.${pkgs.system}.hyprland;
    portalPackage = inputs.hyprland.packages.${pkgs.system}.xdg-desktop-portal-hyprland;
  };

  # Lock screen + PAM so it can authenticate.
  programs.hyprlock.enable = true;
  security.pam.services.hyprlock = { };

  # hyprexpo plugin .so, built against the pinned Hyprland for ABI match.
  # (Only loaded if a session's hyprland.lua actually calls `hyprctl plugin load`.)
 # environment.sessionVariables.HYPREXPO_PLUGIN =
 #   "${inputs.hyprland-plugins.packages.${pkgs.system}.hyprexpo}/lib/libhyprexpo.so";

  # Prebuilt Hyprland binaries instead of compiling.
  nix.settings = {
    extra-substituters = [ "https://hyprland.cachix.org" ];
    extra-trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
    ];
  };
}
