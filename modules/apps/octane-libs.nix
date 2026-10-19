# libraries otoy's linux binaries need, shared by octane.nix (mjolnir) and octane-node.nix (mimir)
# the driver has to be config.hardware.nvidia.package: a pinned nvidia_x11 here gave a
# driver/library version mismatch at runtime
{ config }:
pkgs: with pkgs; [
  # nvidia / cuda (octane brings its own cuda 12 + cudnn 9 runtime in lib/)
  config.hardware.nvidia.package
  cudaPackages.cudatoolkit
  cudaPackages.cuda_cudart
  # graphics
  libGL
  libGLU
  vulkan-loader
  vulkan-headers
  libdrm
  mesa
  # x11, the headless node needs it too: the binaries link against it
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
  # cef: the sign-in window in OctaneServer and the Standalone is chromium
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
  # system libs
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
