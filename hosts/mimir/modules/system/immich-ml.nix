{ pkgs, ... }:
let
  # v3.0.3-cuda. must be the same immich version as immich-server in heimdall's
  # immich.nix, a mismatched ml/server pair can break the api
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

    # gpu via cdi, needs hardware.nvidia-container-toolkit (nvidia.nix)
    extraOptions = [ "--device=nvidia.com/gpu=all" ];
  };

  networking.firewall.allowedTCPPorts = [ 3003 ];
}
