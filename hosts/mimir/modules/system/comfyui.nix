{ ... }:
let
  # Keep in sync with comfyui/Containerfile + comfyui/build.sh.
  version = "v0.27.0";
in
{
  # ComfyUI has no first-class NixOS module, so run it as a podman container
  # with GPU passthrough (CDI, see nvidia.nix). The image is built locally on
  # mimir from ./comfyui/Containerfile — pinned by construction, nothing is
  # pulled at runtime:   cd comfyui && ./build.sh
  #
  # Models + state live on the ZFS scratch pool. The bot on this host and
  # humans on http://10.0.20.18:8188 share this instance (and its queue).

  systemd.tmpfiles.rules = [
    "d /scratch/comfyui         0755 root root -"
    "d /scratch/comfyui/output  0755 root root -"
    "d /scratch/comfyui/input   0755 root root -"
    "d /scratch/comfyui/user    0755 root root -"
    "d /scratch/comfyui/temp    0755 root root -"
    # model library (synced from mjolnir; see discordbot repo README)
    "d /scratch/models                   0755 root root -"
    "d /scratch/models/checkpoints       0755 root root -"
    "d /scratch/models/loras             0755 root root -"
    "d /scratch/models/vae               0755 root root -"
    "d /scratch/models/embeddings        0755 root root -"
    "d /scratch/models/upscale_models    0755 root root -"
    "d /scratch/models/ultralytics       0755 root root -"
    "d /scratch/models/ultralytics/bbox  0755 root root -"
    "d /scratch/models/controlnet        0755 root root -"
    "d /scratch/models/clip              0755 root root -"
    "d /scratch/models/clip_vision       0755 root root -"
    "d /scratch/models/diffusion_models  0755 root root -"
    "d /scratch/models/text_encoders     0755 root root -"
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.comfyui = {
    image = "localhost/comfyui:${version}";
    autoStart = true;

    ports = [ "0.0.0.0:8188:8188" ];

    volumes = [
      "/scratch/models:/app/ComfyUI/models"
      "/scratch/comfyui/output:/app/ComfyUI/output"
      "/scratch/comfyui/input:/app/ComfyUI/input"
      "/scratch/comfyui/user:/app/ComfyUI/user"
      "/scratch/comfyui/temp:/app/ComfyUI/temp"
    ];

    # GPU via CDI — requires hardware.nvidia-container-toolkit (nvidia.nix)
    extraOptions = [ "--device=nvidia.com/gpu=all" "--pull=never" ];
  };

  # reachable from the storage VLAN (mjolnir browses the web UI here)
  networking.firewall.allowedTCPPorts = [ 8188 ];
}
