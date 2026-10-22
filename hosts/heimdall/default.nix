{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix

    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix
    ../../modules/system/neovim.nix
    ../../modules/system/tailscale.nix
    ../../modules/system/dotfiles-pull.nix
    ../../modules/apps/codex.nix          # the brain's agent tier runs `codex exec` (see brain.nix)

    ./modules/system/acme.nix
    ./modules/system/traefik.nix
    ./modules/system/nas.nix
    ./modules/system/podman.nix          # podman for every container here
    ./modules/system/appdata.nix         # the apps' data on odyn: appdb's cert + /mnt/appdata shares
    ./modules/system/immich.nix
    ./modules/system/crafty.nix
    ./modules/system/homarr.nix          # dashboard at home.oryxserver.org
    ./modules/system/paperless.nix
    ./modules/system/grafana.nix
    ./modules/system/prometheus.nix
    ./modules/system/switch-snmp.nix
    ./modules/system/influxdb.nix
    ./modules/system/pfsense-geoip.nix
    ./modules/system/loki.nix
#   ./modules/system/promtail.nix
    ./modules/system/postgres-exporter.nix
    ./modules/system/blackbox-exporter.nix
    ./modules/system/scrutiny.nix
    ./modules/system/obsidian.nix
    ./modules/system/huginn.nix
    ./modules/system/brain.nix
    ./modules/system/ai-gateway.nix       # one openai-style endpoint for my models, with metrics
    ./modules/system/amneziawg.nix
    ./modules/system/vaultwarden.nix
    ./modules/system/ntfy.nix             # push notifications at ntfy.oryxserver.org
    ./modules/system/alerting.nix         # prometheus alert rules + alertmanager → ntfy
    ./modules/system/changedetection.nix  # web page watcher → ntfy "changes"
    ./modules/system/searxng.nix          # private search at search.oryxserver.org
  ];

  networking.hostName = "heimdall";
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [{
    address = "10.0.20.17";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.20.1";
  networking.nameservers = [ "10.0.20.4" ];   # pi-hole, so the local *.oryxserver.org records resolve
  networking.firewall.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.christina.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJzbgLEOUP00lHJUp6MYDOm2kDyHjr9khWaGc84YnpXL mimir"
    # me on yggdrasil (the key still says hermod)
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJqRu0/cwcMKm5+Rxm8jx8GfpaqCtPieqGaxetVH8Prj hermod"
    # hermes on yggdrasil: this key can only start the graphify mcp servers, no shell on heimdall
    ''restrict,command="${pkgs.writeShellScript "graphify-mcp-only" ''
      for g in vault dotfiles; do
        if [ "$SSH_ORIGINAL_COMMAND" = "env HOME=/var/lib/huginn /var/lib/huginn/.local/bin/graphify-mcp /var/lib/huginn/graphs/$g/graph.json" ]; then
          HOME=/var/lib/huginn exec /var/lib/huginn/.local/bin/graphify-mcp "/var/lib/huginn/graphs/$g/graph.json"
        fi
      done
      echo "this key only starts graphify-mcp" >&2
      exit 1
    ''}" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEAh74ChiC+JFYRzamn8iwVW03txv1S8HgkDxUvOqCXb hermes-mcp@hermod''
  ];

  environment.systemPackages = with pkgs; [
    git curl wget htop tree jq
  ];

  system.stateVersion = "25.11";
}
