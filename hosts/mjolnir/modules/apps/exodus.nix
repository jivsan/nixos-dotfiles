{ pkgs, ... }:

# exodus crypto wallet (kryptex payouts from mimir's mining go here).
# nixpkgs only has an old version behind requireFile (the zip added by hand), so this fetches the release
# straight from exodus. the version is the build date (26.11.11 = 11 nov 2026). new version: its sha256 is in
# https://downloads.exodus.com/releases/hashes-exodus-<version>.txt (signed by exodus), as an sri hash:
# nix hash convert --hash-algo sha256 --to sri <hex>
# my 12 words are on paper, never in this repo or on a disk
let
  version = "26.11.11";
  exodus = pkgs.exodus.overrideAttrs {
    inherit version;
    src = pkgs.fetchurl {
      url = "https://downloads.exodus.com/releases/exodus-linux-x64-${version}.zip";
      hash = "sha256-EoSLO+n4wCLJkhXD3SzXggpnJ99ntIfKvhm6eQf860U=";
    };
  };
in
{
  environment.systemPackages = [ exodus ];
}
