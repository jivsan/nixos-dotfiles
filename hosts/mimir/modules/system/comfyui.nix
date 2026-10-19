{ ... }:
let
  # keep in sync with comfyui/Containerfile + comfyui/build.sh
  version = "v0.28.2";
in
{
  # comfyui as a podman container on the card (cdi, see nvidia.nix). the image is built
  # here from ./comfyui/Containerfile, nothing is pulled:  cd comfyui && ./build.sh
  # models and output are on odyn (vault/comfyui), shared with mjolnir: one catalog for both

  boot.supportedFilesystems = [ "nfs" ];

  # no x-systemd.automount: podman resolves bind paths at container start and would
  # bind the empty, untriggered dir
  fileSystems."/mnt/odyn/comfyui" = {
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

  # user/ has a sqlite db and temp/ is hot scratch, so both stay on local disk, not nfs
  systemd.tmpfiles.rules = [
    "d /var/lib/comfyui       0755 root root -"
    "d /var/lib/comfyui/user  0755 root root -"
    "d /var/lib/comfyui/temp  0755 root root -"
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.comfyui = {
    image = "localhost/comfyui:${version}";
    autoStart = true;

    ports = [ "0.0.0.0:8188:8188" ];

    volumes = [
      "/mnt/odyn/comfyui/models:/app/ComfyUI/models"
      "/mnt/odyn/comfyui/output:/app/ComfyUI/output"
      "/mnt/odyn/comfyui/input:/app/ComfyUI/input"
      "/var/lib/comfyui/user:/app/ComfyUI/user"
      "/var/lib/comfyui/temp:/app/ComfyUI/temp"
    ];

    # gpu via cdi, needs hardware.nvidia-container-toolkit (nvidia.nix)
    extraOptions = [ "--device=nvidia.com/gpu=all" "--pull=never" ];
  };

  # no start without the odyn mount, or it serves an empty model library. so comfyui
  # (and the discord bot, when it's on) needs odyn up
  systemd.services.podman-comfyui.unitConfig.RequiresMountsFor = "/mnt/odyn/comfyui";

  # web ui, mjolnir opens it at http://10.0.20.18:8188
  networking.firewall.allowedTCPPorts = [ 8188 ];
}
