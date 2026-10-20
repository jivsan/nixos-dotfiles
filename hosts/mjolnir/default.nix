{ inputs, pkgs, pkgs-unstable, ... }:
{
  imports = [
    ./modules/system/base.nix
    ./hardware-configuration.nix
    ../../modules/apps/unfree.nix
    ./modules/apps/discord.nix
    ./modules/apps/audio.nix
    ./modules/apps/gaming.nix
    ./modules/apps/wow.nix
    ./modules/apps/nvidia.nix
    ./modules/apps/screenshot.nix
    ./modules/apps/nvtop.nix
    ./modules/apps/wallpaper.nix
    ./modules/apps/filemanager.nix
    ./modules/apps/octane.nix
    ./modules/system/backup.nix
    ./modules/apps/vlc.nix
    ./modules/apps/gimp.nix
    ./modules/apps/remote.nix
    ../../modules/apps/claude-code.nix
    ../../modules/apps/codex.nix
    ../../modules/apps/herdr.nix
    ./modules/apps/telegram.nix
    ./modules/apps/wowexport.nix
    ../../modules/apps/blender.nix
    ./modules/apps/upscayl.nix
    ./modules/apps/quixel-bridge.nix
    ./modules/apps/remote-desktop.nix
    ../../modules/system/tailscale.nix
    ./modules/system/hyprland.nix          # hyprland as a second session, oxwm stays
    ../../modules/system/muninn.nix        # ~/muninn vault mount + `capture`
    ./modules/apps/obs.nix                 # obs, records to ~/OBS-recordings on odyn
    ./modules/apps/comfyui.nix             # comfyui in podman, models on odyn
    ./modules/system/yggdrasil-link.nix    # hermes on yggdrasil: blender + wowx mcp over ssh, `claude-to-yggdrasil`
    ../../modules/system/hermes-wowx.nix   # /mnt/hermes-wowx on odyn: wow exports, shared with yggdrasil
    ../../modules/system/studio.nix        # /mnt/studio on odyn: my blender files
    ../../modules/apps/mimir-blender.nix   # `mimir-blender`: agents run blender checks on mimir, not here
    ./modules/system/mimir-test-node.nix   # `blender-config-to-mimir`: my add-ons for mimir's blender
    ../../modules/system/agent-memory.nix  # ~/.agent-memory on odyn: claude's memory notes
    ../../modules/system/ratatoskr.nix     # /mnt/ratatoskr on odyn: screenshots + snippets for hermes and claude
    ./modules/system/exporters.nix         # node + gpu numbers for heimdall's prometheus (homarr host card)
    ../../modules/system/nix-cache.nix     # mimir's nix cache first, then cache.nixos.org
  ];

  networking.hostName = "mjolnir";

  # oxwm on x11 stays my default, hyprland is just another option in ly
  services.xserver.windowManager.oxwm.enable = true;

  nix.settings = {
    max-jobs = 4;
    cores = 0;
  };
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";

  # off: its ssh_config Include is a store file owned by nobody, openssh refuses it
  # ("Bad owner or permissions") and every ssh breaks, graphify mcp, `ask` and `capture` too
  programs.ssh.systemd-ssh-proxy.enable = false;
  boot.kernelPackages = pkgs-unstable.linuxPackages_latest;

  # the X540 10GbE card froze mjolnir under long nfs copies (IO_PAGE_FAULT, then tx hangs).
  # passthrough costs nothing, no vms here
  boot.kernelParams = [ "iommu=pt" ];
}
