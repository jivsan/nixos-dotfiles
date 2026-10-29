{ pkgs, pkgs-unstable, ... }:

# orcaslicer for the ender-3 v3 se: i slice here and save the g-code in /mnt/ratatoskr/3dprint,
# the elitebook hands it to octoprint. from unstable for 2.4.2 (cached, nothing compiles)
let
  # webkitgtk's dma-buf renderer and the nvidia driver on wayland don't get along: orca died with
  # "Error 71 (Protocol error) dispatching to Wayland display" as soon as its setup wizard (a web page) opened
  orca = pkgs.symlinkJoin {
    name = "orca-slicer-${pkgs-unstable.orca-slicer.version}";
    paths = [ pkgs-unstable.orca-slicer ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/orca-slicer --set WEBKIT_DISABLE_DMABUF_RENDERER 1
    '';
  };
  # if the 3d plate is black on hyprland with the nvidia card: `orca-slicer-zink` draws it through mesa's
  # zink on vulkan. same settings as nixpkgs' withNvidiaGLWorkaround, but that override compiles orca from source
  orca-zink = pkgs.writeShellScriptBin "orca-slicer-zink" ''
    export __GLX_VENDOR_LIBRARY_NAME=mesa
    export __EGL_VENDOR_LIBRARY_FILENAMES=/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json
    export MESA_LOADER_DRIVER_OVERRIDE=zink
    export GALLIUM_DRIVER=zink
    exec ${orca}/bin/orca-slicer "$@"
  '';
in
{
  environment.systemPackages = [ orca orca-zink ];
}
