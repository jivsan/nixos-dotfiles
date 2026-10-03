{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix

    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix
    ../../modules/system/tailscale.nix
    ../../modules/system/dotfiles-pull.nix
    ../../modules/system/fonts.nix
    ../../modules/system/muninn.nix        # ~/muninn vault mount + `capture` / `ask`

    ../../modules/apps/unfree.nix          # claude-code is unfree
    ../../modules/apps/claude-code.nix
    ../../modules/apps/codex.nix
    ../../modules/apps/herdr.nix

    ./modules/system/desktop.nix           # oxwm over xrdp (Remmina)
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

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

  zramSwap.enable = true;

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
