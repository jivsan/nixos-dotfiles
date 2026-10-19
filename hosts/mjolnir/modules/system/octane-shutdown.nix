# at shutdown, SIGTERM blender and OctaneServer and wait, so octane logs its license out.
# a hard power-off or SIGKILL leaves it bound to mjolnir until otoy support frees it
{ config, pkgs, ... }:

{
  systemd.services.octane-license-release = {
    description = "Gracefully stop Octane/Blender before shutdown to release license";
    wantedBy = [ "multi-user.target" ];
    # ExecStop runs at shutdown, before the network goes down (the logout needs it)
    before = [ "shutdown.target" "reboot.target" "network.target" ];
    conflicts = [ "shutdown.target" "reboot.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";  # nothing on start, the work is in ExecStop
      ExecStop = pkgs.writeShellScript "octane-release" ''
        pg=${pkgs.procps}/bin/pgrep
        pk=${pkgs.procps}/bin/pkill
        echo "Releasing Octane licenses before shutdown..."
        # SIGTERM lets the Octane plugin / server run its license logout
        $pk -TERM -x blender || true
        $pk -TERM -x OctaneServer || true
        $pk -TERM -f 'octane_(node|daemon)' || true
        for _ in $(seq 1 30); do
          if ! $pg -x blender >/dev/null && ! $pg -x OctaneServer >/dev/null \
             && ! $pg -f 'octane_(node|daemon)' >/dev/null; then
            echo "Octane processes exited, licenses released."
            exit 0
          fi
          sleep 1
        done
        echo "Octane still running after 30s; continuing shutdown."
      '';
      TimeoutStopSec = 45;
    };
  };
}
