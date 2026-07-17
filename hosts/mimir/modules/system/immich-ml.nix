{ pkgs, ... }:
let
  # ⚠️ Pin this to the SAME immich version as immich-server on heimdall
  # (heimdall's immich.nix pins the server by digest). A mismatched ML/server
  # pair can break the API. The `-cuda` tag is the GPU build for NVIDIA.
  # v3.0.3-cuda (matches heimdall's immich-server v3.0.3)
  immichMlImage = "ghcr.io/immich-app/immich-machine-learning@sha256:0d66acce99224495fda2288e2d8f52b459712b2e897e67b492729bce07775c08";
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/immich-ml-cache 0700 root root -"   # downloaded models (multi-GB)
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.immich-machine-learning = {
    image = immichMlImage;
    autoStart = true;

    # heimdall's immich-server (10.0.20.17) connects here for smart search / faces
    ports = [ "0.0.0.0:3003:3003" ];

    volumes = [
      "/var/lib/immich-ml-cache:/cache"
    ];

    environment = {
      IMMICH_VERSION_CHECK = "false";
    };

    # GPU acceleration — requires hardware.nvidia-container-toolkit (see nvidia.nix)
    extraOptions = [ "--device=nvidia.com/gpu=all" ];
  };

  # Reachable from heimdall over VLAN 20
  networking.firewall.allowedTCPPorts = [ 3003 ];

  # ── FOLLOW-UP once mimir is up (do NOT do this before, or Immich will stall) ──
  # In hosts/heimdall/modules/system/immich.nix:
  #   mlUrl = "http://10.0.20.18:3003";
  #   IMMICH_MACHINE_LEARNING_URL = mlUrl;   # uncomment on immich-server
  # then rebuild heimdall.
}
