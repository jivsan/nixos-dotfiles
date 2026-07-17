{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix

    # ── shared fleet modules (same as heimdall) ──
    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix       # christina + SSH key
    ../../modules/system/tailscale.nix

    # ── mimir-local: AI / GPU stack ──
    ./modules/system/nvidia.nix
#   ./modules/system/storage.nix
    ./modules/system/immich-ml.nix
    ./modules/system/ollama.nix
    ./modules/system/open-webui.nix
#    ./modules/system/comfyui.nix
#    ./modules/system/discordbot.nix
  ];

  networking.hostName = "mimir";
  networking.useDHCP = false;

  # ⚠️ Confirm the real NIC name on the box after install (`ip -br link`).
  # Bare metal is usually enpXsY / enoX — NOT ens18 like the Proxmox VMs.
  # Update this attribute name before the first `nixos-rebuild switch`.
  networking.interfaces.enp5s0.ipv4.addresses = [{
    address = "10.0.20.18";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.20.1";
  networking.nameservers = [ "10.0.20.4" ];   # Pi-hole — resolves *.oryxserver.org locally
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

  system.stateVersion = "26.05";   # fresh install on the latest release
}
