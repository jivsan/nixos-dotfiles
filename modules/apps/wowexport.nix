{ pkgs, config, ... }:
let
  nvidiaPackage = config.hardware.nvidia.package;
  wow-export = pkgs.buildFHSEnv {
    name = "wow-export";
    targetPkgs = pkgs: with pkgs; [
      nvidiaPackage
      libGL
      libGLU
      libglvnd
      vulkan-loader
      alsa-lib
      at-spi2-atk
      atk
      cairo
      cups
      dbus
      expat
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libgbm
      libxkbcommon
      nspr
      nss
      pango
      pciutils
      systemd
      libx11
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxrandr
      libxcb
      gsettings-desktop-schemas
    ];
    runScript = pkgs.writeShellScript "wow-export-run" ''
      export XDG_DATA_DIRS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:''${XDG_DATA_DIRS:-}"
      cd "/mnt/data_ssd/3DBLENDER/wowexporttools"
      exec ./wow.export "$@"
    '';
  };
in
{
  environment.systemPackages = [ wow-export ];
}
