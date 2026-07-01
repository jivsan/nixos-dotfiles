{ lib, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Fleet default; a host can override in its own default.nix (e.g. mimir → 26.05).
  system.stateVersion = lib.mkDefault "25.11";

  nix.gc = {
  automatic = true;
  dates = "weekly";
  options = "--delete-older-than 7d";
 };
}
