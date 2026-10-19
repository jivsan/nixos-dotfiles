{ ... }:
# comfyui in podman on my gpu; models, input and output on odyn (vault/comfyui), shared with mimir
# the image is built here, nothing is pulled: cd hosts/mjolnir/modules/apps/comfyui && ./build.sh
let
  # keep in sync with comfyui/Containerfile and comfyui/build.sh
  version = "v0.28.2";
in
{
  boot.supportedFilesystems = [ "nfs" ];

  # in my home so i can drag checkpoints and loras in from nautilus.
  # no automount on purpose: podman would bind the empty, untriggered dir at container start
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

  # temp/ and user/ stay local: hot scratch, and a sqlite db that doesn't belong on nfs.
  # custom_nodes/ and venv/ keep what Manager installs, the container is removed on every stop.
  # local, not on odyn: compiled against this host's image, mimir builds its own
  systemd.tmpfiles.rules = [
    "d /var/lib/comfyui              0755 root root -"
    "d /var/lib/comfyui/temp         0755 root root -"
    "d /var/lib/comfyui/user         0755 root root -"
    "d /var/lib/comfyui/custom_nodes 0755 root root -"
    "d /var/lib/comfyui/venv         0755 root root -"
  ];

  virtualisation.podman.enable = true;
  hardware.nvidia-container-toolkit.enable = true;   # CDI, for --device=nvidia.com/gpu=all below

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.comfyui = {
    image = "localhost/comfyui:${version}";

    # off by default, the card is for blender and games too: sudo systemctl start podman-comfyui
    autoStart = false;

    # loopback only. for another machine: "0.0.0.0:8188:8188" and open 8188 in the firewall
    ports = [ "127.0.0.1:8188:8188" ];

    volumes = [
      "/home/christina/comfyui/models:/app/ComfyUI/models"
      "/home/christina/comfyui/output:/app/ComfyUI/output"
      "/home/christina/comfyui/input:/app/ComfyUI/input"
      "/var/lib/comfyui/user:/app/ComfyUI/user"
      "/var/lib/comfyui/temp:/app/ComfyUI/temp"
      # Manager installs into the first custom_nodes path (extra_model_paths.yaml puts
      # this one first) and their pip deps into the venv
      "/var/lib/comfyui/custom_nodes:/app/custom_nodes"
      "/var/lib/comfyui/venv:/app/venv"
    ];

    extraOptions = [ "--device=nvidia.com/gpu=all" "--pull=never" ];
  };

  # no start without the nfs mount, instead of generating into an empty local dir
  systemd.services.podman-comfyui.unitConfig.RequiresMountsFor = "/home/christina/comfyui";
}
