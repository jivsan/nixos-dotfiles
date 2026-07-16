{ pkgs-unstable, ... }:

{
  environment.systemPackages = [
    pkgs-unstable.discord
  ];
}
