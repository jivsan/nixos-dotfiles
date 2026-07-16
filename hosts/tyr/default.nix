{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix

    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix
    ../../modules/system/tailscale.nix
  ];

  networking.hostName = "tyr";
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [{
    address = "10.0.20.19";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.20.1";
  networking.nameservers = [ "10.0.20.4" ];   # Pi-hole — so *.oryxserver.org local records resolve
  networking.firewall.enable = true;

  services.qemuGuest.enable = true;

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

  system.stateVersion = "26.05";
}
