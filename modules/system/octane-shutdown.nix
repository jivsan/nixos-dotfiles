# modules/system/octane-shutdown.nix
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
        echo "Releasing Octane licenses before shutdown..."
        # Gracefully terminate Blender (SIGTERM lets Octane plugin clean up)
        ${pkgs.procps}/bin/pkill -TERM -f blender || true
        # Also kill octane_server / OctaneServer if running (network rendering)
        ${pkgs.procps}/bin/pkill -TERM -f octane || true
        # Give Octane time to release the license back to OTOY
        sleep 10
        echo "Octane license release window complete."
      '';
      TimeoutStopSec = 20;
    };
  };
}
