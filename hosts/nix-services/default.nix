{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix

    # Shared modules from your existing setup
    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix
    ../../modules/system/tailscale.nix
    
    ./modules/system/acme.nix
    ./modules/system/traefik.nix
    ./modules/system/nas.nix
    ./modules/system/immich.nix
    ./modules/system/nextcloud.nix
    ./modules/system/crafty.nix
    ./modules/system/homepage.nix
    ./modules/system/paperless.nix
    ./modules/system/grafana.nix
    ./modules/system/prometheus.nix
    ./modules/system/loki.nix  
#   ./modules/system/promtail.nix
    ./modules/system/postgres-exporter.nix
    ./modules/system/blackbox-exporter.nix
    ./modules/system/nexterm.nix
    ./modules/system/scrutiny.nix
  ];

  networking.hostName = "nix-services";
  networking.useDHCP = false;
  networking.interfaces.ens18.useDHCP = true;
  networking.firewall.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  environment.systemPackages = with pkgs; [
    git vim curl wget htop tree jq
  ];

  system.stateVersion = "25.11";
}
