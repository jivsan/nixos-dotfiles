# modules/apps/octane.nix — OctaneRender on the workstation (mjolnir)
#
# Since OctaneBlender 31.x the workflow is: vanilla Blender (modules/apps/blender.nix)
# + the OctaneRender Blender *addon* zip + a separate OctaneServer process that
# holds the OTOY sign-in and does the rendering. There is no "Blender Octane
# Edition" binary any more. Both downloads need the OTOY account:
#   https://render.otoy.com/forum/viewtopic.php?t=85781   (addon 31.10 + server)
#
# Install / update (never with the server running — see octane-stop):
#   octane-stop
#   sudo octane-install ~/Downloads/OctaneStudio_for_BlenderOctaneAddon_Linux_31.10-stable.zip \
#                       ~/Downloads/octane_blender_addon-31.10-stable.zip
# Then enable the "OctaneRender" addon once in Blender > Preferences > Add-ons.
#
# License safety: OctaneServer releases its license on SIGTERM ("Caught signal,
# please wait for license logout"). SIGKILL does not, and the license then stays
# bound to this machine until OTOY frees it. Use `octane-stop`, never `pkill -9`.
# Before moving to a new OctaneServer version, sign out in the old one first
# (Account menu > Sign Out), which releases every license bound to this machine.
{ pkgs, config, lib, ... }:
let
  octaneBase = "/opt/octane";
  octaneLibs = import ./octane-libs.nix { inherit config; };

  # The 31.x server zip is flat (liboctane.so, libcef.so next to the binary) and
  # the binary's RUNPATH points at OTOY's build tree, so add the install dir
  # (and lib/, the pre-31 layout) to the library path ourselves.
  #
  # Octane keeps third-party downloads (cuDNN, ...) under /etc/OctaneRender.
  # The FHS sandbox builds its own /etc, so the host's is invisible, and the
  # real one is root-owned anyway. Bind a user-writable dir there instead so the
  # in-app "Download" button works and the files persist across rebuilds.
  octane-server = pkgs.buildFHSEnv {
    name = "octane-server";
    targetPkgs = octaneLibs;
    extraBwrapArgs = [ "--bind ${octaneBase}/etc /etc/OctaneRender" ];
    runScript = pkgs.writeShellScript "octane-server-run" ''
      # Single instance. A second server starts a second OTOY session while the
      # first still holds the one workstation seat -> "no available licenses".
      if ${pkgs.procps}/bin/pgrep -x OctaneServer >/dev/null; then
        msg="OctaneServer is already running. Use octane-stop first."
        echo "$msg" >&2
        ${pkgs.libnotify}/bin/notify-send "Octane" "$msg" 2>/dev/null || true
        exit 0
      fi
      export LD_LIBRARY_PATH="${octaneBase}/server:${octaneBase}/server/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      cd ${octaneBase}/server
      exec ./OctaneServer "$@"
    '';
  };

  # Stop OctaneServer gracefully and wait for its license logout to finish.
  octane-stop = pkgs.writeShellScriptBin "octane-stop" ''
    pg=${pkgs.procps}/bin/pgrep
    if ! $pg -x OctaneServer >/dev/null; then
      echo "OctaneServer is not running."
      exit 0
    fi
    echo "Sending SIGTERM to OctaneServer (license logout)..."
    ${pkgs.procps}/bin/pkill -TERM -x OctaneServer || true
    for _ in $(seq 1 40); do
      $pg -x OctaneServer >/dev/null || { echo "OctaneServer exited, license released."; exit 0; }
      sleep 1
    done
    echo "OctaneServer still running after 40s. Do NOT kill -9 it (that leaves the"
    echo "license bound to this machine). Check its window / log for the logout."
    exit 1
  '';

  # Install or update OctaneServer and the Blender addon from the OTOY zips.
  octane-install = pkgs.writeShellScriptBin "octane-install" ''
    set -euo pipefail
    PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils rsync unzip procps gnugrep gawk ])}:$PATH

    usage() {
      cat <<USAGE
    Usage: sudo octane-install <OctaneServer zip or dir> [<addon zip or dir>]

      OctaneServer:  OctaneStudio_for_BlenderOctaneAddon_Linux_<ver>.zip
      Blender addon: octane_blender_addon-<ver>.zip
    Both come from the release thread on render.otoy.com (OTOY login needed).
    Layout inside the zips does not matter; the binaries are located by name.
    USAGE
      exit 1
    }
    [ $# -ge 1 ] || usage
    [ "$(id -u)" = 0 ] || { echo "run with sudo (writes ${octaneBase})"; usage; }

    if pgrep -x OctaneServer >/dev/null; then
      echo "OctaneServer is running. Sign out in it (Account > Sign Out), then run"
      echo "'octane-stop' and retry. Replacing files under a live server can leave"
      echo "the license bound to this machine."
      exit 1
    fi

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    # Unpack a zip into $tmp/<name>, or point at a directory as-is.
    unpack() {
      local src=$1 name=$2
      if [ -d "$src" ]; then printf '%s\n' "$src"; return; fi
      mkdir -p "$tmp/$name"
      unzip -q "$src" -d "$tmp/$name"
      printf '%s\n' "$tmp/$name"
    }

    # ── OctaneServer ───────────────────────────────────────────────
    srv=$(unpack "$1" server)
    bin=$(find "$srv" -type f -name OctaneServer | head -1)
    [ -n "$bin" ] || { echo "no OctaneServer binary found in $1"; exit 1; }
    echo "Installing OctaneServer from $(dirname "$bin") -> ${octaneBase}/server"
    mkdir -p ${octaneBase}/server
    rsync -a --delete "$(dirname "$bin")/" ${octaneBase}/server/
    chmod +x ${octaneBase}/server/OctaneServer
    find ${octaneBase}/server -name '*.sh' -exec chmod +x {} +

    # ── Blender addon ──────────────────────────────────────────────
    if [ $# -ge 2 ]; then
      add=$(unpack "$2" addon)
      # Either a legacy addon (bl_info in __init__.py) or an extension (manifest).
      manifest=$(find "$add" -maxdepth 3 -name blender_manifest.toml | head -1)
      init=$(find "$add" -maxdepth 3 -name __init__.py -exec grep -l bl_info {} + | head -1)
      if [ -n "$manifest" ]; then
        dir=$(dirname "$manifest"); kind=extension
      elif [ -n "$init" ]; then
        dir=$(dirname "$init"); kind=addon
      else
        echo "no Blender addon or extension found in $2"; exit 1
      fi
      name=$(basename "$dir")
      echo "Installing Blender $kind '$name' -> ${octaneBase}/addon/$name"
      mkdir -p ${octaneBase}/addon
      rsync -a --delete "$dir/" "${octaneBase}/addon/$name/"
      find "${octaneBase}/addon/$name" -type f \( -name '*.so' -o -name '*.pyd' \) -exec chmod +x {} + || true
      rm -f ${octaneBase}/addon/current; ln -s "$name" ${octaneBase}/addon/current
      echo "$kind" > ${octaneBase}/addon/kind

      # Link it into the invoking user's Blender config for the installed Blender.
      user=''${SUDO_USER:-}
      if [ -n "$user" ]; then
        home=$(getent passwd "$user" | cut -d: -f6)
        ver=$(blender --version 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1,2)
        ver=''${ver:-5.2}
        if [ "$kind" = extension ]; then
          dest="$home/.config/blender/$ver/extensions/user_default/$name"
        else
          dest="$home/.config/blender/$ver/scripts/addons/$name"
        fi
        mkdir -p "$(dirname "$dest")"
        if [ -e "$dest" ] && [ ! -L "$dest" ]; then
          mv "$dest" "$dest.bak-$(date +%F)"   # a real dir from an older install; keep it
        fi
        rm -f "$dest"
        ln -s "${octaneBase}/addon/$name" "$dest"
        chown -h "$user" "$dest"
        chown "$user" "$(dirname "$dest")" "$home/.config/blender/$ver" 2>/dev/null || true
        echo "Linked into $dest"
        echo "Next: start octane-server, sign in, then in Blender $ver enable the"
        echo "'OctaneRender' $kind under Preferences > Add-ons (no 'Install from Disk' needed)."
        echo "Old addons / startup scene / layout: run blender-migrate-config (as yourself) first."
      fi
    fi

    echo
    echo "Done. Installed under ${octaneBase}:"
    ls -1 ${octaneBase}
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${octaneBase}         0755 root root -"
    "d ${octaneBase}/server  0755 root root -"
    "d ${octaneBase}/addon   0755 root root -"
    # appears as /etc/OctaneRender inside the sandbox; Octane writes cuDNN etc. here
    "d ${octaneBase}/etc              0755 christina users -"
    "d ${octaneBase}/etc/thirdparty   0755 christina users -"
  ];

  environment.systemPackages = [
    octane-server
    octane-install
    octane-stop
  ];

  system.activationScripts.octane-check = ''
    if [ ! -f "${octaneBase}/server/OctaneServer" ]; then
      echo ""
      echo "WARNING: OctaneServer not found at ${octaneBase}/server/"
      echo "  Run: sudo octane-install <OctaneServer zip> <addon zip>"
      echo ""
    fi
  '';
}
