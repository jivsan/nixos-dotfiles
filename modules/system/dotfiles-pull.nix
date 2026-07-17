{ pkgs, ... }:
{
  # Keep ~/nixos-dotfiles in sync with GitHub — PULL ONLY, never rebuilds.
  # Rebuilding stays a human decision (nixos-rebuild switch by hand).
  #
  # --ff-only: refuses to merge/rebase if the local clone has diverged
  # (stray local edits), so it can never eat uncommitted work — the unit
  # just fails visibly instead (shows up in fastfetch's "units" line).
  systemd.services.dotfiles-pull = {
    description = "Pull nixos-dotfiles from GitHub (no rebuild)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "christina";
      ExecStart = "${pkgs.git}/bin/git -C /home/christina/nixos-dotfiles pull --ff-only --quiet origin main";
    };
  };

  systemd.timers.dotfiles-pull = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "2m";        # poll every 2 min — a no-change fetch is a few hundred bytes
      RandomizedDelaySec = "30s";    # hosts don't all hit GitHub in the same second
    };
  };
}
