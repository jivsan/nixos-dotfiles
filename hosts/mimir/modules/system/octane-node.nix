# octane render node: mjolnir's OctaneServer renders on mimir's card over the lan
# the node version must equal mjolnir's OctaneServer (2026.4 now), or it gets refused
# install: sudo octane-node-install <node zip>, then octane-node-start / octane-node-stop
# (also ~/start-render-node, ~/stop-render-node). more in docs/misc/octane.md
# never kill -9 octane_node or the daemon: the license stays bound to this machine
{ pkgs, config, lib, ... }:
let
  octaneBase = "/opt/octane";
  nodeBase = "${octaneBase}/node";
  standaloneBase = "${octaneBase}/standalone";
  daemonPort = 48000;      # octane's default, what mjolnir's OctaneServer looks for
  # gb of mimir's ram for out-of-core textures. a node must hold the whole scene on its own
  # card (8 gb here, 16 on mjolnir), and install-daemon.sh's default turns this off
  outOfCoreGb = 16;
  nodeUser = "christina";  # the otoy sign-in lives in this user's ~/.OctaneRender
  octaneLibs = import ../../../../modules/apps/octane-libs.nix { inherit config; };

  # octane keeps its downloads (cudnn) in /etc/OctaneRender, but the fhs sandbox has
  # its own /etc, so a writable dir is bound there (same as mjolnir's octane.nix)
  etcBind = [ "--bind ${octaneBase}/etc /etc/OctaneRender" ];

  # octane-node-env <cmd>: runs a command with the libs otoy expects
  octane-node-env = pkgs.buildFHSEnv {
    name = "octane-node-env";
    targetPkgs = octaneLibs;
    extraBwrapArgs = etcBind;
    runScript = "bash";
  };

  # otoy's zips are flat and their RUNPATH points at otoy's build tree, so the
  # install dir goes on LD_LIBRARY_PATH
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

  # uses run_octane_daemon.sh if install-daemon.sh wrote one, else starts the daemon
  # the way that script would
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

  # the unit's main process is the fhs bwrap wrapper: a SIGTERM to it never reaches octane,
  # the daemon gets SIGKILLed and the license isn't logged out. so signal octane_node first
  # (it holds the license), then the daemon. process names are cut to 15 chars: octane_node_dae
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

  # the two commands i run (sudo on mimir asks for no password)
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
    # no wantedBy: it holds a render-node license and the card while it runs,
    # so i start it with octane-node-start when i want it
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # test the daemon file, not the dir: tmpfiles makes the dir, so that test is always true
    unitConfig.ConditionPathExists = "${nodeBase}/octane_node_daemon";
    serviceConfig = {
      Type = "simple";
      User = nodeUser;
      Group = "users";
      WorkingDirectory = nodeBase;
      Environment = [ "HOME=/home/${nodeUser}" ];
      ExecStart = "${octane-node-env}/bin/octane-node-env ${daemon-start}";
      # the license logout happens here, what systemd sends after only hits the empty wrapper
      ExecStop = node-stop-run;
      Restart = "on-failure";
      RestartSec = 15;
      KillSignal = "SIGTERM";
      KillMode = "mixed";
      TimeoutStopSec = 150;
      FinalKillSignal = "SIGKILL";
    };
  };

  # mjolnir finds the daemon by udp broadcast on this port. the node then calls mjolnir back
  # on tcp (1047, 1048 and a port OctaneServer picks), mjolnir's networking.nix lets mimir in
  networking.firewall.allowedTCPPorts = [ daemonPort ];
  networking.firewall.allowedUDPPorts = [ daemonPort ];

  # for the one-time otoy sign-in: octane-standalone --no-opengl over ssh -X from mjolnir
  services.openssh.settings.X11Forwarding = true;
  programs.ssh.setXAuthLocation = true;
}
