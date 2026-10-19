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
# Start / stop (on mimir; the same two are linked into the home folder as
# ~/start-render-node and ~/stop-render-node):
#   octane-node-start     starts the service, shows the card and the node's log
#   octane-node-stop      stops it and waits for the license logout
# The service does not start at boot: the node takes a render-node license and
# the card while it runs, so it is started when it is wanted.
#
# License safety: stopping sends SIGTERM to octane_node first and waits for its
# license logout, then to the daemon (see node-stop-run). Never `kill -9`
# octane_node / octane_node_daemon.
{ pkgs, config, lib, ... }:
let
  octaneBase = "/opt/octane";
  nodeBase = "${octaneBase}/node";
  standaloneBase = "${octaneBase}/standalone";
  daemonPort = 48000;      # what mjolnir's OctaneServer scans for (its default)
  # A node must hold the whole scene on its own card. Without this the node runs
  # with "out-of-core textures disabled" (install-daemon.sh's default) and a scene
  # bigger than mimir's 8 GB card does not load on it (mjolnir's RTX 5070 Ti has
  # 16 GB since 2026-10-19, so its scenes can outgrow the node). Gigabytes of mimir's RAM.
  outOfCoreGb = 16;
  nodeUser = "christina";  # the OTOY sign-in lives in this user's ~/.OctaneRender
  octaneLibs = import ../../../../modules/apps/octane-libs.nix { inherit config; };

  # Generic FHS shell: `octane-node-env <cmd>` runs <cmd> with OTOY's expected libs.
  # Octane stores third-party downloads (cuDNN) under /etc/OctaneRender; the FHS
  # sandbox has its own /etc, so bind a user-writable dir there (see octane.nix).
  etcBind = [ "--bind ${octaneBase}/etc /etc/OctaneRender" ];

  octane-node-env = pkgs.buildFHSEnv {
    name = "octane-node-env";
    targetPkgs = octaneLibs;
    extraBwrapArgs = etcBind;
    runScript = "bash";
  };

  # OTOY's Linux zips are flat (liboctane.so next to the binary) and the RUNPATH
  # points at their build tree, so the install dir goes on the library path.
  octane-standalone = pkgs.buildFHSEnv {
    name = "octane-standalone";
    targetPkgs = octaneLibs;
    extraBwrapArgs = etcBind;
    runScript = pkgs.writeShellScript "octane-standalone-run" ''
      export LD_LIBRARY_PATH="${standaloneBase}:${standaloneBase}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      cd ${standaloneBase}
      exec ./octane "$@"
    '';
  };

  # What the service runs. The 2026.4 node zip holds: install-daemon.sh,
  # octane_node_daemon, octane_node, octane.dat, libsenseEIV.so (read 2026-10-13).
  # install-daemon.sh (interactive, optional) writes run_octane_daemon.sh with the
  # chosen port/GPUs; if it was not run, start the daemon the way that script
  # would:  octane_node_daemon --port P --slave <octane_node> --alias NAME
  daemon-start = pkgs.writeShellScript "octane-node-daemon-run" ''
    cd ${nodeBase} || exit 1
    export LD_LIBRARY_PATH="${nodeBase}:${nodeBase}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [ -x ./run_octane_daemon.sh ]; then
      exec ./run_octane_daemon.sh
    fi
    if [ -x ./octane_node_daemon ] && [ -x ./octane_node ]; then
      exec ./octane_node_daemon --port ${toString daemonPort} \
        --slave "${nodeBase}/octane_node" --alias "${config.networking.hostName}" \
        --out-of-core ${toString outOfCoreGb}g
    fi
    echo "octane-node: no daemon under ${nodeBase}. Run: sudo octane-node-install <node zip>" >&2
    exit 1
  '';

  # What stopping the service runs. The unit's main process is the bwrap wrapper
  # of the FHS env (--die-with-parent): a SIGTERM to it never reaches Octane, the
  # wrapper dies and the daemon is SIGKILLed with it, then systemd SIGKILLs what
  # is left. No license logout that way. So the signals go to the Octane
  # processes themselves, octane_node first (it holds the license), the daemon
  # after it. Process names are cut to 15 characters: octane_node_dae.
  node-stop-run = pkgs.writeShellScript "octane-node-stop-run" ''
    pg=${pkgs.procps}/bin/pgrep
    pk=${pkgs.procps}/bin/pkill
    gone() { ! $pg -u ${nodeUser} -x "$1" >/dev/null; }
    wait_gone() {
      for _ in $(${pkgs.coreutils}/bin/seq 1 "$2"); do
        gone "$1" && return 0
        ${pkgs.coreutils}/bin/sleep 1
      done
      return 1
    }
    if ! gone octane_node; then
      echo "SIGTERM to octane_node, waiting for its license logout..."
      $pk -TERM -u ${nodeUser} -x octane_node || true
      wait_gone octane_node 90 || echo "octane_node still running after 90 s"
    fi
    if ! gone octane_node_dae; then
      $pk -TERM -u ${nodeUser} -x octane_node_dae || true
      wait_gone octane_node_dae 20 || echo "octane_node_daemon still running after 20 s"
    fi
    exit 0
  '';

  # The two commands she runs. sudo on mimir asks for no password.
  octane-node-start = pkgs.writeShellScriptBin "octane-node-start" ''
    PATH=${lib.makeBinPath (with pkgs; [ coreutils systemd gnugrep iproute2 ])}:/run/current-system/sw/bin:$PATH
    root() { if [ "$(id -u)" = 0 ]; then "$@"; else /run/wrappers/bin/sudo "$@"; fi; }
    listens() { ss -ltn 2>/dev/null | grep -q ":${toString daemonPort} "; }

    if [ ! -x ${nodeBase}/octane_node_daemon ]; then
      echo "No render node under ${nodeBase}. Run: sudo octane-node-install <node zip>"
      exit 1
    fi
    if ! card=$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null); then
      echo "The NVIDIA driver does not answer (nvidia-smi fails): the node has no card to render on."
      exit 1
    fi
    echo "Card: $card"

    since=$(date '+%Y-%m-%d %H:%M:%S')
    if systemctl is-active --quiet octane-node; then
      echo "The render node is already running."
      since=""
    elif ! root systemctl start octane-node; then
      echo "Could not start the render node. Its last lines:"
      journalctl -u octane-node -n 20 --no-pager -o cat
      exit 1
    fi

    for _ in $(seq 1 20); do
      listens && break
      sleep 0.5
    done
    if listens; then
      echo "Render node is up, the daemon listens on port ${toString daemonPort}."
      echo "On mjolnir: OctaneServer > Network preferences, enable network rendering, add 10.0.20.18."
    else
      echo "The daemon does not listen on port ${toString daemonPort} yet. Look at the lines below."
    fi
    echo
    if [ -n "$since" ]; then
      journalctl -u octane-node --since "$since" --no-pager -o cat
    else
      journalctl -u octane-node -n 12 --no-pager -o cat
    fi
    echo
    echo "Stop it with: octane-node-stop      Follow its log: journalctl -fu octane-node"
  '';

  octane-node-stop = pkgs.writeShellScriptBin "octane-node-stop" ''
    PATH=${lib.makeBinPath (with pkgs; [ coreutils systemd procps ])}:$PATH
    root() { if [ "$(id -u)" = 0 ]; then "$@"; else /run/wrappers/bin/sudo "$@"; fi; }
    if ! systemctl is-active --quiet octane-node; then
      echo "The render node is not running."
      exit 0
    fi
    echo "Stopping the render node and waiting for its license logout (up to two minutes)..."
    root systemctl stop octane-node
    if pgrep -u ${nodeUser} -x octane_node >/dev/null || pgrep -u ${nodeUser} -x octane_node_dae >/dev/null; then
      echo "An Octane process is still running. Do NOT kill -9 it (the license stays"
      echo "bound to this machine). Look at: journalctl -u octane-node -n 30"
      exit 1
    fi
    echo "Render node stopped."
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
      2. octane-node-start        (or ~/start-render-node; stop with octane-node-stop)
         Without step 1 the service starts octane_node_daemon --port ${toString daemonPort} itself
         (out-of-core ${toString outOfCoreGb} GB).
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
    "d ${octaneBase}/etc             0755 ${nodeUser} users -"
    "d ${octaneBase}/etc/thirdparty  0755 ${nodeUser} users -"
    # The start and stop commands, also reachable in the home folder.
    "L+ /home/${nodeUser}/start-render-node - - - - ${octane-node-start}/bin/octane-node-start"
    "L+ /home/${nodeUser}/stop-render-node  - - - - ${octane-node-stop}/bin/octane-node-stop"
  ];

  environment.systemPackages = [
    octane-node-env
    octane-standalone
    octane-node-install
    octane-node-start
    octane-node-stop
  ];

  systemd.services.octane-node = {
    description = "OctaneRender render-node daemon (network rendering for mjolnir)";
    # No wantedBy: started with octane-node-start when the node is wanted.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Not started until the package is installed. The test is on the daemon file:
    # tmpfiles creates the directory, so a test on the directory was always true
    # and the unit failed and restarted every 15 s on a box without the package.
    unitConfig.ConditionPathExists = "${nodeBase}/octane_node_daemon";
    serviceConfig = {
      Type = "simple";
      User = nodeUser;
      Group = "users";
      WorkingDirectory = nodeBase;
      Environment = [ "HOME=/home/${nodeUser}" ];
      ExecStart = "${octane-node-env}/bin/octane-node-env ${daemon-start}";
      # Graceful stop = license logout, done by node-stop-run (see there). What
      # systemd sends after it only meets the empty wrapper.
      ExecStop = node-stop-run;
      Restart = "on-failure";
      RestartSec = 15;
      KillSignal = "SIGTERM";
      KillMode = "mixed";
      TimeoutStopSec = 150;
      FinalKillSignal = "SIGKILL";
    };
  };

  # mjolnir reaches the daemon on this port (UDP broadcast). The daemon answers by
  # TCP to a port OctaneServer picks itself, and the node then connects to the
  # primary's 1047 and 1048: mjolnir's networking.nix lets this host in on TCP.
  networking.firewall.allowedTCPPorts = [ daemonPort ];
  networking.firewall.allowedUDPPorts = [ daemonPort ];

  # One-time sign-in via `ssh -X` from mjolnir (CEF window over X forwarding).
  services.openssh.settings.X11Forwarding = true;
  programs.ssh.setXAuthLocation = true;
}
