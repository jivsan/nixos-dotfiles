{ lib, ... }:

{
  imports = [ ./nix-cache.nix ];   # mimir first, then cache.nixos.org

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;

  # fleet default, hosts installed on a newer release set their own in default.nix
  system.stateVersion = lib.mkDefault "25.11";

  nix.gc = {
  automatic = true;
  dates = "weekly";
  options = "--delete-older-than 7d";
 };
}
