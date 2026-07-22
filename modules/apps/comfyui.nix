{ ... }:
# ── ComfyUI on mjolnir — GPU here, everything else on odyn over 10GbE ───────
# The model library, inputs and outputs live in the odyn dataset
# vault/comfyui (recordsize=1M, export scoped to VLAN 20, mapall→christina),
# shared with mimir so both hosts see one catalog. Only temp/ and user/ stay
# local: temp is hot scratch I/O and user/ holds a sqlite db that does not
# belong on NFS.
#
# A 6.5G SDXL checkpoint cold-loads in ~8s over the 10GbE leg; after that it
# is resident in VRAM, so the cost is per model *switch*, not per generation.
#
# ComfyUI has no first-class NixOS module, so it runs as a podman container
# with GPU passthrough (CDI). The image is built locally from
# ./comfyui/Containerfile — pinned by construction, nothing is pulled at
# runtime:   cd modules/apps/comfyui && ./build.sh
let
  # Keep in sync with comfyui/Containerfile + comfyui/build.sh.
  version = "v0.28.2";
in
{
  boot.supportedFilesystems = [ "nfs" ];

  # One mount for the whole dataset; the container maps subpaths out of it.
  # Mounted inside $HOME (not /mnt) so it shows up as an ordinary folder in
  # Nautilus and you can drag checkpoints/LoRAs straight in — same pattern as
  # ~/muninn and ~/OBS-recordings. Safe from the backup script: backup.nix only
  # walks ~/nixos-dotfiles, ~/.config and ~/octane-src, so this can't loop back
  # onto odyn.
  #
  # No x-systemd.automount here on purpose — podman resolves bind-mount paths
  # at container start and would happily bind an empty, un-triggered directory.
  fileSystems."/home/christina/comfyui" = {
    device = "10.0.20.6:/mnt/vault/comfyui";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "soft"
      "noatime"
      "_netdev"
      "nofail"
      "rsize=1048576"
      "wsize=1048576"
      "x-systemd.mount-timeout=30"
      "retry=2"
    ];
  };

  # Local-only state (see header).
  #
  # custom_nodes/ + venv/ exist because oci-containers runs podman with --rm and
  # `podman rm -f` on stop, so the container filesystem is destroyed every
  # restart. Without these, anything ComfyUI-Manager installs is gone the moment
  # you restart to activate it — and a restart is exactly what loading a new
  # node requires. Kept host-local, not on odyn: this is Python code compiled
  # against a specific torch (2.11 here vs 2.6 on mimir), so the two hosts must
  # not share it.
  systemd.tmpfiles.rules = [
    "d /var/lib/comfyui              0755 root root -"
    "d /var/lib/comfyui/temp         0755 root root -"
    "d /var/lib/comfyui/user         0755 root root -"
    "d /var/lib/comfyui/custom_nodes 0755 root root -"
    "d /var/lib/comfyui/venv         0755 root root -"
  ];

  # mjolnir had neither of these — ComfyUI is the first container on this host.
  virtualisation.podman.enable = true;
  hardware.nvidia-container-toolkit.enable = true;   # CDI: --device nvidia.com/gpu=all

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.comfyui = {
    image = "localhost/comfyui:${version}";

    # Off by default: this is a workstation and the 4060 Ti only has 8G of
    # VRAM, which you also want for games. Start it when you need it:
    #   sudo systemctl start podman-comfyui
    autoStart = false;

    # Loopback only — it is a desktop, not a service host. To reach it from
    # the laptop, change to "0.0.0.0:8188:8188" and open the firewall port.
    ports = [ "127.0.0.1:8188:8188" ];

    volumes = [
      "/home/christina/comfyui/models:/app/ComfyUI/models"
      "/home/christina/comfyui/output:/app/ComfyUI/output"
      "/home/christina/comfyui/input:/app/ComfyUI/input"
      "/var/lib/comfyui/user:/app/ComfyUI/user"
      "/var/lib/comfyui/temp:/app/ComfyUI/temp"
      # Survive --rm: Manager installs nodes into the first registered
      # custom_nodes path (extra_model_paths.yaml pins this one at index 0),
      # and their pip deps land in the venv.
      "/var/lib/comfyui/custom_nodes:/app/custom_nodes"
      "/var/lib/comfyui/venv:/app/venv"
    ];

    extraOptions = [ "--device=nvidia.com/gpu=all" "--pull=never" ];
  };

  # Refuse to start against a missing NFS mount rather than silently
  # generating into an empty local directory.
  systemd.services.podman-comfyui.unitConfig.RequiresMountsFor = "/home/christina/comfyui";
}
