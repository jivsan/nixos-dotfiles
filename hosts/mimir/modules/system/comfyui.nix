{ pkgs, ... }:
{
  # ComfyUI has no first-class NixOS module, so run it as a podman container
  # with GPU passthrough. Mount persistent model + output dirs.
  # (Alternative for later: a comfyui flake input built with nix — swap this out.)

  systemd.tmpfiles.rules = [
    "d /var/lib/comfyui         0750 root root -"
    "d /var/lib/comfyui/models  0750 root root -"
    "d /var/lib/comfyui/output  0750 root root -"
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.comfyui = {
    # TODO: pick a ComfyUI image you trust and pin it by digest.
    #       (community CUDA images exist; there is no official one.)
    image = "ghcr.io/CHANGE-ME/comfyui:latest";
    autoStart = true;

    ports = [ "0.0.0.0:8188:8188" ];

    volumes = [
      "/var/lib/comfyui/models:/app/models"
      "/var/lib/comfyui/output:/app/output"
    ];

    # GPU acceleration — requires hardware.nvidia-container-toolkit (see nvidia.nix)
    extraOptions = [ "--device=nvidia.com/gpu=all" ];
  };

  networking.firewall.allowedTCPPorts = [ 8188 ];
}
