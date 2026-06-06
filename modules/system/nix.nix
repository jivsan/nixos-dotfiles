{ ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  system.stateVersion = "25.11";

  nix.gc = {
  automatic = true;
  dates = "weekly";
  options = "--delete-older-than 7d";
 };
}
