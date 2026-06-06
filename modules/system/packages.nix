{ pkgs, ... }:
{
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      glib
      nss
      nspr
      atk
      at-spi2-atk
      at-spi2-core
      cups
      dbus
      expat
      libdrm
      mesa
      pango
      cairo
      alsa-lib
      libx11
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxrandr
      libxcb
      gtk3
      libxkbcommon
      stdenv.cc.cc.lib
      zlib
      fontconfig
      freetype
      libGL
      libgbm
      gsettings-desktop-schemas
    ];
  };
  programs.firefox.enable = true;
  environment.systemPackages = with pkgs; [
    nano
    wget
    alacritty
    git
    btop
    nixd
    lm_sensors
    claude-code
  ];
}
