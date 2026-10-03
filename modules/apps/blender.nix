{ pkgs, lib, ... }:
let
  # Upstream Blender binaries wrapped for NixOS. This is mkBlender from
  # edolstra/nix-warez (blender/flake.nix), carried here because upstream still
  # uses the deprecated xorg.* package names and warned on every rebuild.
  mkBlender = { pname, version, src }:
    with pkgs;

    let
      libs =
        [ wayland libdecor libx11 libxi libxxf86vm libxfixes libxrender libxkbcommon libGLU libglvnd numactl SDL2 libdrm ocl-icd stdenv.cc.cc.lib openal alsa-lib pulseaudio ]
        ++ lib.optionals (lib.versionAtLeast version "3.5") [ libsm libice zlib ]
        ++ lib.optionals (lib.versionAtLeast version "4.5") [ vulkan-loader ];
    in

    stdenv.mkDerivation rec {
      inherit pname version src;

      buildInputs = [ makeWrapper ];

      preUnpack =
        ''
          mkdir -p $out/libexec
          cd $out/libexec
        '';

      installPhase =
        ''
          cd $out/libexec
          mv blender-* blender

          mkdir -p $out/share/applications
          mkdir -p $out/share/icons/hicolor/scalable/apps
          mv ./blender/blender.desktop $out/share/applications/blender.desktop
          mv ./blender/blender.svg $out/share/icons/hicolor/scalable/apps/blender.svg

          mkdir $out/bin

          makeWrapper $out/libexec/blender/blender $out/bin/blender \
            --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib:${lib.makeLibraryPath libs}

          patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
            blender/blender

          patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)"  \
            $out/libexec/blender/*/python/bin/python3*
        '';

      meta.mainProgram = "blender";
    };

  blender_5_1 = mkBlender {
    pname = "blender-bin";
    version = "5.1.1";
    src = pkgs.fetchurl {
      url = "https://download.blender.org/release/Blender5.1/blender-5.1.1-linux-x64.tar.xz";
      hash = "sha256-b5//if7xVO95dNGhxLkWq0vB9WGLy0jVvv7hvQp8fyo=";
    };
  };
in
{
  environment.systemPackages = [
    blender_5_1
  ];
}
