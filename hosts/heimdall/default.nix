{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix

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
    ./modules/system/switch-snmp.nix
    ./modules/system/influxdb.nix
    ./modules/system/pfsense-geoip.nix
    ./modules/system/loki.nix
#   ./modules/system/promtail.nix
    ./modules/system/postgres-exporter.nix
    ./modules/system/blackbox-exporter.nix
    ./modules/system/nexterm.nix
    ./modules/system/scrutiny.nix
    ./modules/system/obsidian.nix
    ./modules/system/huginn.nix
    ./modules/system/brain.nix
    ./modules/system/hlidskjalf.nix
    ./modules/system/cloudflared.nix
  ];

  networking.hostName = "heimdall";
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [{
    address = "10.0.20.17";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.20.1";
  networking.nameservers = [ "10.0.20.4" ];   # Pi-hole — so *.oryxserver.org local records resolve
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
