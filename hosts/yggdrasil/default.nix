{ config, pkgs, pkgs-unstable, ... }:

# yggdrasil — Lenovo ThinkCentre M93p Tiny (i5-4570T, 16 GB, 256 GB SSD, vPro), the
# always-on box outside hella. Takes over from the hermod VM: hermes (Kimi K3 via
# OpenRouter, MCP servers for the vault, Blender and wowx on mjolnir) with hermod's IP,
# SSH host keys, christina's key and the hermes MCP key, so nothing that talked to
# hermod has to change. Installed from mjolnir with ./install.sh.
{
  imports = [
    ./hardware-configuration.nix

    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix
    ../../modules/system/dotfiles-pull.nix
    ../../modules/system/muninn.nix
    ../../modules/system/hermes-wowx.nix
    ../../modules/system/studio.nix
    ../../modules/apps/mimir-blender.nix
    ../../modules/apps/unfree.nix          # claude-code is unfree
    ../../modules/apps/claude-code.nix
    ../../modules/system/agent-memory.nix   # Claude's memory notes, the same copy as on mjolnir
    ../../modules/apps/herdr.nix

    ./modules/system/hermes-agent.nix
    ./modules/system/exporters.nix          # node numbers for heimdall's Prometheus (Homarr host card)
  ];

  boot.kernelPackages = pkgs-unstable.linuxPackages_latest;

  networking.hostName = "yggdrasil";
  # One onboard port (Intel I217-LM); matched by type so its name does not matter.
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.networks."10-lan" = {
    matchConfig.Name = "en*";
    address = [ "10.0.20.21/24" ];
    gateway = [ "10.0.20.1" ];
    dns = [ "10.0.20.4" ];
    linkConfig.RequiredForOnline = "routable";
  };
  networking.firewall.enable = true;

  hardware.cpu.intel.updateMicrocode = true;
  # The onboard Intel port (e1000e) and Haswell graphics need no firmware files; the
  # 800 MB linux-firmware bundle is for other hardware.
  hardware.enableRedistributableFirmware = false;
  services.fstrim.enable = true;
  services.thermald.enable = true;
  zramSwap.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Same ids as hermes had on hermod, so its copied state keeps its owner.
  users.users.hermes.uid = 999;
  users.groups.hermes.gid = 999;

  # Lets christina (wheel, passwordless sudo anyway) receive store paths, so mjolnir
  # can push a system with `nixos-rebuild --target-host` and big builds stay there.
  nix.settings.trusted-users = [ "root" "@wheel" ];

  environment.systemPackages = with pkgs; [
    git vim curl wget btop tree jq rsync
    python3   # for scripts hermes writes and runs from its terminal (the CLI's PATH)
  ];
  # The gateway's own PATH; hermes' code-execution tool brings its own Python.
  services.hermes-agent.extraPackages = [ pkgs.python3 ];

  system.stateVersion = "26.05";
}
