# octane: vanilla blender + the octane addon + OctaneServer, which holds the otoy sign-in and renders
# stop the server only with octane-stop: SIGTERM logs the license out, kill -9 leaves it
# bound to mjolnir until otoy frees it. sign out in the old server before upgrading it
{ pkgs, config, lib, ... }:
let
  octaneBase = "/opt/octane";
  octaneLibs = import ../../../../modules/apps/octane-libs.nix { inherit config; };

  # the server's RUNPATH points at otoy's build tree, so the run script sets LD_LIBRARY_PATH.
  # /etc/OctaneRender is bound to a dir i can write, so the in-app cuDNN download works and stays
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
      # from a launcher stdin is /dev/null: the server's command prompt hits end-of-file
      # and reprints itself forever (one core at 100 %). a fifo opened read-write never ends
      if [ ! -t 0 ]; then
        fifo=$(${pkgs.coreutils}/bin/mktemp -u "''${XDG_RUNTIME_DIR:-/tmp}/octane-stdin.XXXXXX")
        ${pkgs.coreutils}/bin/mkfifo -m 600 "$fifo"
        exec 0<>"$fifo"
        ${pkgs.coreutils}/bin/rm -f "$fifo"
      fi
      exec ./OctaneServer "$@"
    '';
  };

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
    # /etc/OctaneRender inside the sandbox
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
