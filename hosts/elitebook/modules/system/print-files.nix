{ pkgs, ... }:

# /mnt/ratatoskr/3dprint: the folder on odyn where i save g-code from mjolnir. odyn shares only this
# folder with the elitebook, read-only (nfs share 27), so this box never sees the rest of ratatoskr.
# every 30 seconds the .gcode files are copied into octoprint's own folder "3dprint", so a print always
# reads from the laptop's disk and keeps going if odyn or the network drops out. a file i delete or
# rename on mjolnir goes from octoprint's list too (a print that is running still finishes)
let
  share = "/mnt/ratatoskr/3dprint";
  target = "/var/lib/octoprint/uploads/3dprint";
in
{
  fileSystems.${share} = {
    device = "10.0.20.6:/mnt/vault/ratatoskr/3dprint";
    fsType = "nfs";
    options = [
      "ro"
      "nfsvers=4.2"
      "soft"
      "noatime"
      "_netdev"
      "nofail"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=15"
    ];
  };

  systemd.services.octoprint-3dprint-sync = {
    description = "Copy g-code from ${share} into OctoPrint";
    path = [ pkgs.rsync pkgs.coreutils pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      User = "octoprint";
      Group = "octoprint";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/octoprint" ];
    };
    script = ''
      ls ${share} > /dev/null || true   # wakes the automount
      # odyn down or the share missing: change nothing, or --delete would empty octoprint's folder
      if ! findmnt -n -t nfs4 ${share} > /dev/null; then
        echo "${share} isn't mounted, nothing copied"
        exit 0
      fi
      mkdir -p ${target}
      # g-code only. octoprint's own .metadata.json is excluded, so --delete leaves it alone
      rsync -rt --delete --prune-empty-dirs \
        --include='*/' --include='*.gcode' --include='*.gco' --include='*.g' --exclude='*' \
        ${share}/ ${target}/
    '';
  };

  systemd.timers.octoprint-3dprint-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
  };
}
