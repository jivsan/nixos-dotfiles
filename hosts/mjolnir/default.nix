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
    ../../modules/apps/grok.nix
    ../../modules/apps/hermes-agent.nix    # Hermes Agent (Nous Research) → OpenRouter, `hermes` CLI
    ../../modules/apps/telegram.nix
    ../../modules/apps/wowexport.nix
    ../../modules/apps/blender.nix
    ../../modules/apps/upscayl.nix
    ../../modules/apps/quixel-bridge.nix
    ../../modules/apps/remote-desktop.nix
    ../../modules/system/tailscale.nix
    ../../modules/system/hyprland.nix      # Hyprland session (additive; oxwm untouched)
    ../../modules/system/muninn.nix        # ~/muninn vault mount + `capture` (terminal ↔ knowledge base)
    ../../modules/apps/obs.nix             # OBS Studio + ~/OBS-recordings (odyn NFS over 10GbE)
    ../../modules/apps/comfyui.nix         # ComfyUI (podman + CDI), models on odyn over 10GbE
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

  # Disable systemd-ssh-proxy feature. Its ssh_config Include pulls in a
  # store file owned by nobody, which OpenSSH rejects ("Bad owner or permissions").
  # This was breaking all `ssh` (including graphify MCP over SSH and `ask`/`capture`).
  # See: nixos/modules/programs/ssh.nix (systemd-ssh-proxy.enable)
  programs.ssh.systemd-ssh-proxy.enable = false;
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
