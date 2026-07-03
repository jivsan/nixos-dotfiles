{ inputs, pkgs, ... }:
{
  imports = [
    ../../configuration.nix
    ./hardware-configuration.nix
    ../../modules/apps/unfree.nix
    ../../modules/apps/discord.nix
    ../../modules/apps/audio.nix
    ../../modules/apps/gaming.nix
    ../../modules/apps/wow.nix
    ../../modules/apps/nvidia.nix
    ../../modules/apps/screenshot.nix
    ../../modules/apps/nvtop.nix
    ../../modules/apps/wallpaper.nix
    ../../modules/apps/filemanager.nix
    ../../modules/apps/octane.nix
    ../../modules/system/backup.nix
    ../../modules/apps/vlc.nix
    ../../modules/apps/remote.nix
    ../../modules/apps/claude-code.nix
    ../../modules/apps/telegram.nix
    ../../modules/apps/wowexport.nix
    ../../modules/apps/blender.nix
    ../../modules/apps/upscayl.nix
    ../../modules/apps/quixel-bridge.nix
    ../../modules/apps/remote-desktop.nix
    ../../modules/system/tailscale.nix
    ../../modules/system/hyprland.nix      # Hyprland session (additive; oxwm untouched)
    ../../modules/system/muninn.nix        # ~/muninn vault mount + `capture` (terminal ↔ knowledge base)
  ];

  networking.hostName = "mjolnir";

  # X11/oxwm stays your default; Hyprland is just another option in ly.
  services.xserver.windowManager.oxwm.enable = true;

  nix.settings = {
    max-jobs = 6;     # your tuned 5900X values
    cores = 4;
  };
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
}
