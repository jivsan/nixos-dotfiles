{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    maim
    xclip
  ];
}
