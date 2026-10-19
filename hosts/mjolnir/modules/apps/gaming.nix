{ pkgs, ... }:

{
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  programs.steam.enable = true;
  programs.gamemode.enable = true;

  programs.appimage.enable = true;
  programs.appimage.binfmt = true;

  environment.systemPackages = with pkgs; [
    lutris
    winetricks
    wineWow64Packages.staging
    mangohud
    vulkan-tools
    protonup-qt
    appimage-run
  ];
}
