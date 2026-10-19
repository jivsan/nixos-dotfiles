{ pkgs, ... }:
{
  # pulls ~/nixos-dotfiles from github, never rebuilds: i rebuild by hand
  # --ff-only: a clone with local edits fails the unit (fastfetch's units line) instead of losing them
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
      OnUnitActiveSec = "2m";        # a fetch with no changes is a few hundred bytes
      RandomizedDelaySec = "30s";    # so the hosts don't all hit github in the same second
    };
  };
}
