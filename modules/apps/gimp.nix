{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    gimp
    imagemagick
    gmic
  ];
}
