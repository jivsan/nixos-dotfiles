# modules/apps/octane-node.nix — OctaneRender network render node (mimir)
#
# Runs the OTOY render-node daemon so mjolnir's OctaneServer can use mimir's GPU
# over the LAN. The node package is "OctaneRender_Studio+_<ver>_node_linux.zip"
# from the OctaneRender release thread (OTOY login). The node version MUST equal
# the OctaneServer version on mjolnir, or the primary refuses it:
#   addon 31.10 = Octane 2026.4  ->  OctaneRender_Studio+_2026_4_node_linux.zip
#
# Install:  sudo octane-node-install ~/OctaneRender_Studio+_2026_4_node_linux.zip
# Sign-in:  the node needs the OTOY account on this machine once. The node pulls
#           one of the Studio+ render-node licenses (10 included); it does not
#           take the workstation license. Headless option: run the Standalone
#           over `ssh -X mimir` (sshd has X11Forwarding on) and sign in there:
#             sudo octane-node-install ~/OctaneRender_Studio+_2026_4_linux.zip
#             octane-standalone --no-opengl
#
# License safety: the service stops with SIGTERM and waits up to 40s so the
# node can log its license out. Never `kill -9` octane_node / octane_daemon.
{ pkgs, config, lib, ... }:
let
  octaneBase = "/opt/octane";
  nodeBase = "${octaneBase}/node";
  standaloneBase = "${octaneBase}/standalone";
  daemonPort = 48000;      # what mjolnir's OctaneServer scans for (its default)
  nodeUser = "christina";  # the OTOY sign-in lives in this user's ~/.OctaneRender
  octaneLibs = import ./octane-libs.nix { inherit config; };

  # Generic FHS shell: `octane-node-env <cmd>` runs <cmd> with OTOY's expected libs.
  octane-node-env = pkgs.buildFHSEnv {
    name = "octane-node-env";
    targetPkgs = octaneLibs;
    runScript = "bash";
  };

  # OTOY's Linux zips are flat (liboctane.so next to the binary) and the RUNPATH
  # points at their build tree, so the install dir goes on the library path.
  octane-standalone = pkgs.buildFHSEnv {
    name = "octane-standalone";
    targetPkgs = octaneLibs;
    runScript = pkgs.writeShellScript "octane-standalone-run" ''
      export LD_LIBRARY_PATH="${standaloneBase}:${standaloneBase}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      cd ${standaloneBase}
      exec ./octane "$@"
    '';
  };

  # What the service runs. install-daemon.sh (interactive, run once) writes
  # run_octane_daemon.sh with the chosen port/GPUs; if it was not run, start the
  # daemon directly with our port.
  daemon-start = pkgs.writeShellScript "octane-node-start" ''
    cd ${nodeBase} || exit 1
    export LD_LIBRARY_PATH="${nodeBase}:${nodeBase}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [ -x ./run_octane_daemon.sh ]; then
      exec ./run_octane_daemon.sh
    fi
    for b in octane_daemon octane-daemon; do
      [ -x "./$b" ] && exec "./$b" --daemon-port ${toString daemonPort}
    done
    echo "octane-node: no daemon under ${nodeBase}. Run: sudo octane-node-install <node zip>" >&2
    exit 1
  '';

  octane-node-install = pkgs.writeShellScriptBin "octane-node-install" ''
    set -euo pipefail
    PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils rsync unzip systemd gnugrep ])}:$PATH
    usage() {
      cat <<USAGE
    Usage: sudo octane-node-install <zip or dir>

      OctaneRender_Studio+_<ver>_node_linux.zip  -> ${nodeBase}   (render node + daemon)
      OctaneRender_Studio+_<ver>_linux.zip       -> ${standaloneBase} (Standalone, for sign-in only)
    The kind is detected from the files inside. <ver> must match mjolnir's OctaneServer.
    USAGE
      exit 1
    }
    [ $# -eq 1 ] || usage
    [ "$(id -u)" = 0 ] || { echo "run with sudo"; usage; }

    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    src=$1
    if [ ! -d "$src" ]; then
      mkdir -p "$tmp/x"; unzip -q "$src" -d "$tmp/x"; src=$tmp/x
    fi

    node=$(find "$src" -type f \( -name octane_node -o -name install-daemon.sh \) | head -1)
    sa=$(find "$src" -type f -name octane | head -1)
    if [ -n "$node" ]; then
      dir=$(dirname "$node"); dest=${nodeBase}; what="render node"
      systemctl stop octane-node.service || true   # SIGTERM + wait: releases the node license
    elif [ -n "$sa" ]; then
      dir=$(dirname "$sa"); dest=${standaloneBase}; what="Standalone"
    else
      echo "neither a node package (octane_node / install-daemon.sh) nor a Standalone (octane) found in $1"
      exit 1
    fi

    echo "Installing $what from $dir -> $dest"
    mkdir -p "$dest"
    rsync -a --delete "$dir/" "$dest/"
    find "$dest" -maxdepth 1 -type f \( -name 'octane*' -o -name '*.sh' \) -exec chmod +x {} +
    chown -R ${nodeUser} "$dest"   # the service runs as ${nodeUser}; install-daemon.sh writes here
    echo "Files:"; ls -1 "$dest"

    if [ "$what" = "render node" ]; then
      cat <<NEXT

    Next:
      1. (optional) pick port/GPUs the OTOY way, inside the FHS env, as ${nodeUser}:
           cd ${nodeBase} && octane-node-env ./install-daemon.sh      # answer port ${toString daemonPort}
      2. sudo systemctl start octane-node && journalctl -fu octane-node
         Without step 1 the service starts octane_daemon --daemon-port ${toString daemonPort} itself.
      3. On mjolnir, OctaneServer > Network preferences: enable network rendering,
         daemon port ${toString daemonPort}, add 10.0.20.18 to the daemon list.
    NEXT
    fi
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${octaneBase}       0755 root root -"
    "d ${nodeBase}         0755 ${nodeUser} users -"
    "d ${standaloneBase}   0755 ${nodeUser} users -"
  ];

  environment.systemPackages = [
    octane-node-env
    octane-standalone
    octane-node-install
  ];

  systemd.services.octane-node = {
    description = "OctaneRender render-node daemon (network rendering for mjolnir)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Not started until the package is installed; the start script fails fast otherwise.
    unitConfig.ConditionPathIsDirectory = nodeBase;
    serviceConfig = {
      Type = "simple";
      User = nodeUser;
      Group = "users";
      WorkingDirectory = nodeBase;
      Environment = [ "HOME=/home/${nodeUser}" ];
      ExecStart = "${octane-node-env}/bin/octane-node-env ${daemon-start}";
      Restart = "on-failure";
      RestartSec = 15;
      # Graceful stop = license logout. SIGTERM to the whole group, generous timeout.
      KillSignal = "SIGTERM";
      KillMode = "mixed";
      TimeoutStopSec = 40;
      FinalKillSignal = "SIGKILL";
    };
  };

  # mjolnir reaches the daemon on this port; the node connects back to the
  # primary's master port (1047, already open on mjolnir in networking.nix).
  networking.firewall.allowedTCPPorts = [ daemonPort ];
  networking.firewall.allowedUDPPorts = [ daemonPort ];

  # One-time sign-in via `ssh -X` from mjolnir (CEF window over X forwarding).
  services.openssh.settings.X11Forwarding = true;
  programs.ssh.setXAuthLocation = true;
}
