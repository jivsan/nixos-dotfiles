{ config, pkgs, ... }:
{
  home.stateVersion = "26.05";

  imports = [
    ../../modules/home/git.nix
    ../../modules/home/shell.nix

    ./modules/home/fastfetch.nix
  ];

  # The hermes CLI runs as the hermes user, like the gateway. Its sessions, login
  # and databases in /var/lib/hermes/.hermes are 0600, and hermes tightens that
  # folder to 0700 whenever it saves a login, so as christina it lost its history
  # and then could not start. Its vault is /mnt/muninn.
  programs.bash.initExtra = ''
    hermes() {
      ( cd /var/lib/hermes/workspace &&
        sudo -u hermes env HERMES_HOME=/var/lib/hermes/.hermes HERMES_MANAGED=true HOME=/var/lib/hermes \
          /run/current-system/sw/bin/hermes "$@" )
    }
  '';
}
