{ config, pkgs, ... }:
# the wowsims update by itself, twice a day: a new wowsims build onto the engine (mimir) and the page (the
# cluster). it is the command i run by hand, `nix run .#upgrade` in ~/my-code/wowsims-image (its readme says what
# it does, step by step). it runs here because mjolnir has the logins it needs: my git key, the cluster's
# ~/.kube/helheim.yaml, the token in ~/.config/wowsims-upgrade, and `deploy`. so it runs as me.
#
# - mjolnir is off at night: a run it missed happens a few minutes after the next boot (Persistent)
# - it works in its own clones of the three repos in /var/lib/wowsims-upgrade, set to forgejo's main at the
#   start of every run. what i have open in ~/nixos-dotfiles doesn't stop it and never goes out with it. at the
#   end it fast-forwards my own clones when they are on main and git can do that without touching my changes
# - the script it runs is scripts/upgrade.sh of wowsims-image at `rev` below, not whatever is newest on that
#   repo's main: what runs here as me, with my keys, only changes when i change this line. after a change to
#   the script: its new commit here, push, `deploy mjolnir`
# - a sim that runs on the engine gets up to 30 minutes to finish before the engine restarts (--when-idle)
# - stop the updates: touch ~/.config/wowsims-upgrade/hold (rm it and they run again)
# - a run that fails leaves the unit failed: heimdall's UnitFailed alert (alerting.nix) sends it to ntfy
#   through the node exporter here. the next good run clears it. exit 75 is "my own nix run .#upgrade has the
#   lock", not a failure
#
#   systemctl list-timers wowsims-upgrade     when it runs next
#   journalctl -u wowsims-upgrade -n 60       what the last run did
#   sudo systemctl start wowsims-upgrade      run it now
let
  rev = "668072df51a937a6b39789f8f8426544f16973f0";
  forgejo = "ssh://git@git.oryxserver.org:2222/jivsan";

  auto = pkgs.writeShellApplication {
    name = "wowsims-upgrade-auto";
    runtimeInputs = [ config.nix.package pkgs.git pkgs.openssh pkgs.coreutils ];
    text = ''
      hold=$HOME/.config/wowsims-upgrade/hold
      if [ -e "$hold" ]; then
        echo "on hold ($hold is there): nothing done. rm it and the updates run again"
        exit 0
      fi
      cd "$STATE_DIRECTORY"

      # folder = repo: the clone as main is on forgejo now, whatever a run that was cut off left in it
      fresh() {
        [ -d "$1/.git" ] || git clone -q "${forgejo}/$1.git" "$1"
        git -C "$1" fetch -q origin main
        git -C "$1" checkout -q main
        git -C "$1" reset -q --hard origin/main
      }
      fresh wowsims-image
      fresh nixos-dotfiles
      fresh talos-helheim
      # nixos-dotfiles goes to github too, the same two addresses ~/nixos-dotfiles pushes to
      git -C nixos-dotfiles config --replace-all remote.origin.pushurl git@github.com:jivsan/nixos-dotfiles.git
      git -C nixos-dotfiles config --add remote.origin.pushurl "${forgejo}/nixos-dotfiles.git"

      export WOWSIMS_IMAGE=$PWD/wowsims-image DOTFILES=$PWD/nixos-dotfiles TALOS=$PWD/talos-helheim
      nix run "git+file://$PWD/wowsims-image?rev=${rev}#upgrade" -- --yes --when-idle

      # my own clones, forward to what was just pushed, so `deploy` and my next push fit. only on main and
      # only fast-forward: git leaves it when my changes are in the way
      for d in "$HOME/my-code/wowsims-image" "$HOME/nixos-dotfiles" "$HOME/my-code/talos-helheim"; do
        if [ "$(git -C "$d" symbolic-ref --short HEAD 2>/dev/null)" = main ]; then
          git -C "$d" pull -q --ff-only 2>/dev/null || echo "$d: not forwarded (git pull --ff-only there says why)"
        fi
      done
    '';
  };
in
{
  systemd.services.wowsims-upgrade = {
    description = "a new wowsims build onto the engine (mimir) and the page (the cluster)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ "/run/current-system/sw" ]; # deploy
    restartIfChanged = false; # a `deploy mjolnir` in the middle of a run leaves the run alone
    serviceConfig = {
      Type = "oneshot";
      User = "christina";
      StateDirectory = "wowsims-upgrade";
      StateDirectoryMode = "0700";
      ExecStart = "${auto}/bin/wowsims-upgrade-auto";
      SuccessExitStatus = 75;
      TimeoutStartSec = "3h"; # ci's build, ci's build of mimir, a sim that still runs: each can take a while
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.wowsims-upgrade = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = [ "06:30" "18:30" ];
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
