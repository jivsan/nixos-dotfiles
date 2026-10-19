{ config, pkgs, pkgs-unstable, ... }:

# yggdrasil: my always-on control box outside hella (thinkcentre m93p tiny), for claude, hermes and herdr
# installed from mjolnir with ./install.sh
{
  imports = [
    ./hardware-configuration.nix

    ../../modules/system/boot.nix
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix
    ../../modules/system/neovim.nix
    ../../modules/system/dotfiles-pull.nix
    ../../modules/system/muninn.nix
    ../../modules/system/hermes-wowx.nix
    ../../modules/system/studio.nix
    ../../modules/apps/mimir-blender.nix
    ../../modules/apps/unfree.nix          # claude-code is unfree
    ../../modules/apps/claude-code.nix
    ../../modules/system/agent-memory.nix   # claude's memory notes, same copy as mjolnir
    ../../modules/apps/herdr.nix

    ./modules/system/hermes-agent.nix
  ];

  boot.kernelPackages = pkgs-unstable.linuxPackages_latest;

  networking.hostName = "yggdrasil";
  # one onboard port (intel I217-LM), matched by en* so its name doesn't matter
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
  # the intel nic (e1000e) and haswell graphics need no firmware files, so no 800 MB bundle
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

  # hermes' state in /var/lib/hermes is owned by these ids, keep them
  users.users.hermes.uid = 999;
  users.groups.hermes.gid = 999;

  # so mjolnir can push a system with `nixos-rebuild --target-host` and big builds stay there
  nix.settings.trusted-users = [ "root" "@wheel" ];

  environment.systemPackages = with pkgs; [
    git curl wget btop tree jq rsync
    python3   # for scripts hermes writes and runs from its terminal (the cli's PATH)
  ];
  # python on the gateway's PATH too; its code-execution tool brings its own
  services.hermes-agent.extraPackages = [ pkgs.python3 ];

  system.stateVersion = "26.05";
}
