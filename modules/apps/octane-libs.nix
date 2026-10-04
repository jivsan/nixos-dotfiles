# modules/apps/octane-libs.nix
# Runtime libraries OTOY's Linux binaries expect (OctaneServer, octane_node,
# octane_daemon, the Standalone). Shared by octane.nix (mjolnir) and
# octane-node.nix (mimir) so both hosts wrap the binaries the same way.
#
# The driver must come from config.hardware.nvidia.package: pinning a fixed
# nvidia_x11 here caused a driver/library version mismatch at runtime (see the
# vault note "mjolnir kernel 7.2 NVIDIA fix via nixpkgs-unstable").
{ config }:
pkgs: with pkgs; [
  # NVIDIA / CUDA (Octane bundles its own CUDA 12 + cuDNN 9 runtime in lib/)
  config.hardware.nvidia.package
  cudaPackages.cudatoolkit
  cudaPackages.cuda_cudart
  # Graphics
  libGL
  libGLU
  vulkan-loader
  vulkan-headers
  libdrm
  mesa
  # X11 (needed even for the headless node: the binaries link against it)
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
  libxxf86vm
  libsm
  libice
  libxkbcommon
  # CEF (the sign-in window in OctaneServer / Standalone is Chromium)
  nss
  nspr
  atk
  at-spi2-atk
  at-spi2-core
  cups
  expat
  pango
  cairo
  gtk3
  alsa-lib
  systemd
  # System libs
  zlib
  stdenv.cc.cc.lib
  glibc
  glib
  dbus
  fontconfig
  freetype
  openssl
  libusb1
  udev
]
