{ config, pkgs, ... }:
{
  home.stateVersion = "26.05";

  imports = [
    ../../modules/home/git.nix
    ../../modules/home/shell.nix

    ./modules/home/fastfetch.nix
  ];

  # the hermes cli runs as the hermes user, like the gateway: its files in /var/lib/hermes/.hermes
  # are 0600 and it tightens the folder to 0700 on login, so as me it can't read its history or start.
  # herdr only sees sudo in the pane and can't read sudo's environment, so a small bash carries
  # HERDR_AGENT=hermes and waits for sudo
  programs.bash.initExtra = ''
    hermes() {
      ( cd /var/lib/hermes/workspace &&
        HERDR_AGENT=hermes bash -c '"$@"; exit $?' hermes \
          sudo -u hermes env HERMES_HOME=/var/lib/hermes/.hermes HERMES_MANAGED=true HOME=/var/lib/hermes \
            /run/current-system/sw/bin/hermes "$@" )
    }
  '';
}
