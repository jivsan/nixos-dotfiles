{ config, pkgs, pkgs-unstable, ... }:
{
  imports = [
    ./hardware-configuration.nix

    # shared fleet modules
    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix
    ../../modules/system/neovim.nix
    ../../modules/system/tailscale.nix
    ../../modules/system/dotfiles-pull.nix
    ../../modules/apps/herdr.nix
    ../../modules/system/muninn.nix
    ../../modules/system/studio.nix      # /mnt/studio + /mnt/studio-cache on odyn, /mnt/data_ssd/<folder> links

    # mimir's own: ai / gpu stack
    ./modules/system/nvidia.nix
#   ./modules/system/storage.nix        # zfs scratch pool, the ssds are out. kept for the pinned hostId + brunnr plan
    ./modules/system/immich-ml.nix
    ./modules/system/comfyui.nix
    ./modules/system/voice.nix            # whisper + kokoro for heimdall's brain bridge
    ./modules/system/embeddings.nix       # Qwen3-Embedding-4B for vault search and placement (heimdall)
    ./modules/system/exporters.nix        # host numbers for heimdall's prometheus
    ./modules/system/gpu-exporter.nix     # gpu numbers for heimdall's prometheus
#   ./modules/system/llm.nix              # chat models for heimdall's ai-gateway, needs a 16 gb card
    ./modules/system/octane-node.nix    # octane render node for mjolnir
    ./modules/system/test-node.nix        # the agents' blender test node (mimir-blender runs blender-job here)
#    ./modules/system/discordbot.nix      # off until /var/lib/discordbot/.env exists
  ];

  boot.kernelPackages = pkgs-unstable.linuxPackages_latest;

  networking.hostName = "mimir";
  networking.useDHCP = false;

  # bare metal nic name (ip -br link), not ens18 like the proxmox vms
  networking.interfaces.enp5s0.ipv4.addresses = [{
    address = "10.0.20.18";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.20.1";
  networking.nameservers = [ "10.0.20.4" ];   # pi-hole, resolves *.oryxserver.org locally
  networking.firewall.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  environment.systemPackages = with pkgs; [
    git curl wget htop tree jq
  ];

  system.stateVersion = "26.05";
}
