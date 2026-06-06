{ pkgs, ... }:
let
  octaneBase = "/opt/octane";

  commonPkgs = pkgs: with pkgs; [
    # NVIDIA / CUDA
    linuxPackages.nvidia_x11
    cudaPackages.cudatoolkit
    cudaPackages.cuda_cudart
    # Graphics
    libGL
    libGLU
    vulkan-loader
    vulkan-headers
    # X11
    libx11
    libxi
    libxcursor
    libxrandr
    libxinerama
    libxext
    libxrender
    libxfixes
    libxcomposite
    libxdamage
    libxcb
    libxtst
    # System libs
    zlib
    stdenv.cc.cc.lib
    glibc
    glib
    dbus
    fontconfig
    freetype
    libxkbcommon
  ];

  octane-server = pkgs.buildFHSEnv {
    name = "octane-server";
    targetPkgs = pkgs: (commonPkgs pkgs) ++ (with pkgs; [
      nss
      nspr
      atk
      at-spi2-atk
      at-spi2-core
      cups
      expat
      libdrm
      mesa
      pango
      cairo
      alsa-lib
      systemd
      gtk3
    ]);
    runScript = "${octaneBase}/server/OctaneServer";
  };

  octane-blender = pkgs.buildFHSEnv {
    name = "octane-blender";
    targetPkgs = pkgs: (commonPkgs pkgs) ++ (with pkgs; [
      libxxf86vm
      libsm
      libice
      libGL
      libGLU
      alsa-lib
      pulseaudio
      libsndfile
      jack2
      openal
      # Image / media
      libpng
      libjpeg
      libtiff
      openexr
      openjpeg
      # Python
      python3
      # Wayland
      wayland
      libdecor
      # Other
      ocl-icd
      openssl
      libusb1
      udev
    ]);
    runScript = "${octaneBase}/blender/blender";
  };

  # Helper script to install/update Octane from extracted source
  octane-install = pkgs.writeShellScriptBin "octane-install" ''
    set -e
    SRC="''${1:-$HOME/octane-src}"

    if [ ! -d "$SRC/server" ] || [ ! -d "$SRC/blender" ]; then
      echo "Error: Expected $SRC/server and $SRC/blender directories"
      echo ""
      echo "Usage: octane-install [source-dir]"
      echo ""
      echo "To set up from .run files:"
      echo "  1. Extract the server .run file"
      echo "  2. Extract the blender .run file"
      echo "  3. Copy extracted files to ~/octane-src/server and ~/octane-src/blender"
      echo "  4. Run: sudo octane-install ~/octane-src"
      exit 1
    fi

    echo "Installing OctaneServer..."
    mkdir -p ${octaneBase}/server
    ${pkgs.rsync}/bin/rsync -a --delete "$SRC/server/" ${octaneBase}/server/
    chmod +x ${octaneBase}/server/OctaneServer

    echo "Installing Blender Octane Edition..."
    mkdir -p ${octaneBase}/blender
    ${pkgs.rsync}/bin/rsync -a --delete "$SRC/blender/" ${octaneBase}/blender/
    chmod +x ${octaneBase}/blender/blender

    echo ""
    echo "Octane installed successfully to ${octaneBase}"
  '';
in
{
  # Ensure /opt/octane directory structure exists with proper permissions
  systemd.tmpfiles.rules = [
    "d ${octaneBase}         0755 root root -"
    "d ${octaneBase}/server  0755 root root -"
    "d ${octaneBase}/blender 0755 root root -"
  ];

  environment.systemPackages = [
    octane-server
    octane-blender
    octane-install
  ];

  # Warn if Octane binaries are missing
  system.activationScripts.octane-check = ''
    if [ ! -f "${octaneBase}/server/OctaneServer" ]; then
      echo ""
      echo "WARNING: OctaneServer not found at ${octaneBase}/server/"
      echo "  Run: sudo octane-install ~/octane-src"
      echo ""
    fi
    if [ ! -f "${octaneBase}/blender/blender" ]; then
      echo ""
      echo "WARNING: Blender Octane Edition not found at ${octaneBase}/blender/"
      echo "  Run: sudo octane-install ~/octane-src"
      echo ""
    fi
  '';
}
