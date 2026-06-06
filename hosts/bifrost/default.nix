{ config, lib, pkgs, inputs, ... }:

let
  hyprPkg   = inputs.hyprland.packages.${pkgs.system}.hyprland;
  portalPkg = inputs.hyprland.packages.${pkgs.system}.xdg-desktop-portal-hyprland;
in
{
  imports = [
    ./hardware-configuration.nix

    # Shared modules — cherry-picked like nix-services does.
    # Deliberately NOT importing ../../configuration.nix (that pulls in desktop.nix
    # = X11 + oxwm + ly + mjolnir's xrandr layout, and remote.nix = xrdp).
    ../../modules/system/boot.nix         # systemd-boot -> VM must be UEFI/OVMF
    ../../modules/system/locale.nix       # Europe/Oslo, "no" keymap
    ../../modules/system/networking.nix   # NetworkManager
    ../../modules/system/nix.nix          # flakes + gc + stateVersion 25.11
    ../../modules/system/fonts.nix        # JetBrainsMono Nerd Font
    ../../modules/system/users.nix        # christina (wheel, ssh key, passwordless sudo)
    ../../modules/system/tailscale.nix    # trusts tailscale0 -> 5900 reachable over tailnet only
  ];

  networking.hostName = "bifrost";

  # ----- Hyprland 0.55.0 (Lua config) -----
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
    package = hyprPkg;
    portalPackage = portalPkg;
  };

  # Lock screen. The program option installs hyprlock; the PAM service lets it
  # authenticate against christina's password (without it, unlock falls back to su).
  programs.hyprlock.enable = true;
  security.pam.services.hyprlock = { };

  # Hyprland's binary cache so you don't compile it from source.
  nix.settings = {
    extra-substituters = [ "https://hyprland.cachix.org" ];
    extra-trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
    ];
  };

  # ----- Autologin straight into Hyprland (no greeter, headless box) -----
  services.greetd = {
    enable = true;
    settings = rec {
      initial_session = {
        command = "${hyprPkg}/bin/Hyprland";
        user = "christina";
      };
      default_session = initial_session;
    };
  };

  # bifrost's own ssh (we skipped remote.nix on purpose). Key-only, like nix-services.
  # NOTE: this disables root ssh login. Reconnect as christina (key in users.nix)
  # or use the VNC console after the first rebuild.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # wayvnc binds 0.0.0.0:5900 (started from hyprland.lua). tailscale.nix trusts
  # tailscale0 entirely, so it's reachable over the tailnet and blocked on the LAN.
  networking.firewall.allowedTCPPorts = [ 5900 ]; #allows for connection via LAN
  services.qemuGuest.enable = true;

  # stateVersion inherited from nix.nix ("25.11"). Do NOT set it here (would conflict).
}
