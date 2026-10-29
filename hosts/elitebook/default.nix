{ config, pkgs, ... }:

# elitebook: my old hp elitebook 8540p next to the ender-3 v3 se. it only runs octoprint and talks to
# the printer over usb. i make and slice everything on mjolnir and save the g-code in /mnt/ratatoskr/3dprint.
# installed from mjolnir with ./install.sh
{
  imports = [
    ./hardware-configuration.nix

    # no ../../modules/system/boot.nix: the 8540p boots old-style bios, so grub below and not systemd-boot
    ../../modules/system/locale.nix
    ../../modules/system/nix.nix
    ../../modules/system/users.nix
    ../../modules/system/neovim.nix
    ../../modules/system/dotfiles-pull.nix

    ./modules/system/laptop.nix        # lid shut, never sleeps, no usb power saving
    ./modules/system/octoprint.nix     # octoprint on port 5000, only mjolnir gets in
    ./modules/system/print-files.nix   # /mnt/ratatoskr/3dprint (read-only) copied into octoprint
  ];

  # grub in the disk's mbr. install.sh puts the disk (boot.loader.grub.device) in hardware-configuration.nix
  boot.loader.grub.enable = true;

  networking.hostName = "elitebook";
  # the onboard intel 82577lm (e1000e), matched by en* so its name doesn't matter. wifi stays off
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.networks."10-lan" = {
    matchConfig.Name = "en*";
    address = [ "10.0.20.22/24" ];
    gateway = [ "10.0.20.1" ];
    dns = [ "10.0.20.4" ];
    # pfsense's router ads also hand out its own ipv6 dns, which drops our internal names
    ipv6AcceptRAConfig.UseDNS = false;
    linkConfig.RequiredForOnline = "routable";
  };
  networking.firewall.enable = true;

  hardware.cpu.intel.updateMicrocode = true;
  # the intel nic needs no firmware files and the wifi stays off, so no 800 MB firmware bundle
  hardware.enableRedistributableFirmware = false;
  zramSwap.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # so mjolnir can push a system with `nixos-rebuild --target-host` and the old cpu never compiles
  nix.settings.trusted-users = [ "root" "@wheel" ];

  environment.systemPackages = with pkgs; [
    git curl btop
    usbutils   # lsusb: is the printer there (ch340, 1a86:7523)
  ];

  system.stateVersion = "26.05";
}
