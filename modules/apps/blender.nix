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

  blenderVersion = "5.2.2";   # OctaneRender addon 31.10 needs Blender 5.2

  blender_5_2 = mkBlender {
    pname = "blender-bin";
    version = blenderVersion;
    src = pkgs.fetchurl {
      url = "https://download.blender.org/release/Blender5.2/blender-${blenderVersion}-linux-x64.tar.xz";
      hash = "sha256-hAmJEnidxFDpVpfEGE+4qQrL5REcK6Su3j/stXgGoWg=";
    };
  };

  # Carry a previous Blender version's user config into the installed one:
  # legacy addons (scripts/addons), extensions (user_default), presets,
  # startup.blend, userpref.blend (layout, keymap, enabled addons) and
  # bookmarks. Run BEFORE the first launch of the new version, then dismiss its
  # "load previous settings" splash. Default source is 4.5 — the config the
  # Blender Octane Edition used, which holds the Octane startup scene.
  blender-migrate-config = pkgs.writeShellScriptBin "blender-migrate-config" ''
    set -euo pipefail
    PATH=${lib.makeBinPath (with pkgs; [ coreutils rsync ])}:$PATH
    from=4.5 to=${lib.versions.majorMinor blenderVersion} force=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --from) from=$2; shift 2 ;;
        --to)   to=$2;   shift 2 ;;
        --force) force=1; shift ;;
        *) echo "usage: blender-migrate-config [--from 4.5] [--to $to] [--force]"; exit 1 ;;
      esac
    done
    base=$HOME/.config/blender
    [ -d "$base/$from" ] || { echo "no config for Blender $from under $base"; exit 1; }
    if [ -f "$base/$to/config/userpref.blend" ] && [ $force = 0 ]; then
      echo "Blender $to already has preferences ($base/$to/config/userpref.blend)."
      echo "Re-run with --force to overwrite them with the $from ones."
      exit 1
    fi
    echo "Copying Blender $from config -> $to  ($(du -sh "$base/$from" | cut -f1), plain copy on the same disk)"
    mkdir -p "$base/$to"
    for d in config scripts extensions datafiles; do
      [ -d "$base/$from/$d" ] || continue
      echo "  $d/"
      rsync -a "$base/$from/$d/" "$base/$to/$d/"
    done
    echo
    echo "Done. Blender $to now has:"
    ls "$base/$to/config" 2>/dev/null | sed 's/^/  config\//'
    echo "  $(ls "$base/$to/scripts/addons" 2>/dev/null | wc -l) entries in scripts/addons, $(ls "$base/$to/extensions/user_default" 2>/dev/null | wc -l) extensions"
    echo "Note: Blender $to bundles a newer Python than $from; addons that ship compiled"
    echo "modules may need a re-download for Blender $to."
  '';
in
{
  environment.systemPackages = [
    blender_5_2
    blender-migrate-config
  ];
}
