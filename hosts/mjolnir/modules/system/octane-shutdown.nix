# modules/system/octane-shutdown.nix
# At shutdown/reboot, SIGTERM Blender and OctaneServer and wait for them to exit,
# so Octane logs its license out of OTOY's server. A hard power-off or SIGKILL
# leaves the license bound to this machine until OTOY support frees it.
{ config, pkgs, ... }:

{
  systemd.services.octane-license-release = {
    description = "Gracefully stop Octane/Blender before shutdown to release license";
    wantedBy = [ "multi-user.target" ];
    # Runs at shutdown/reboot, before network goes down
    before = [ "shutdown.target" "reboot.target" "network.target" ];
    conflicts = [ "shutdown.target" "reboot.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";  # no-op on start
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
