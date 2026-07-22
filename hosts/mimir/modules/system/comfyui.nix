{ ... }:
let
  # Keep in sync with comfyui/Containerfile + comfyui/build.sh.
  version = "v0.28.2";
in
{
  # ComfyUI has no first-class NixOS module, so run it as a podman container
  # with GPU passthrough (CDI, see nvidia.nix). The image is built locally on
  # mimir from ./comfyui/Containerfile — pinned by construction, nothing is
  # pulled at runtime:   cd comfyui && ./build.sh
  #
  # Models + outputs live on odyn in the dataset vault/comfyui, shared with
  # mjolnir so both hosts see one catalog — drop a checkpoint once and it shows
  # up on both. This replaced the local ZFS scratch pool when those SSDs came
  # out of mimir; /scratch no longer exists as a mount.
  #
  # The bot on this host and humans on http://10.0.20.18:8188 share this
  # instance (and its queue).

  boot.supportedFilesystems = [ "nfs" ];

  # No x-systemd.automount: podman resolves bind-mount paths at container
  # start and would otherwise bind an empty, un-triggered directory.
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

  # Host-local state only. user/ holds a sqlite db and temp/ is hot scratch
  # I/O — neither belongs on NFS, and both are per-host anyway.
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

    # GPU via CDI — requires hardware.nvidia-container-toolkit (nvidia.nix)
    extraOptions = [ "--device=nvidia.com/gpu=all" "--pull=never" ];
  };

  # Refuse to start against a missing NFS mount rather than silently serving an
  # empty model library. NOTE: this makes ComfyUI *and* the Discord bot depend
  # on odyn being up.
  systemd.services.podman-comfyui.unitConfig.RequiresMountsFor = "/mnt/odyn/comfyui";

  # reachable from the storage VLAN (mjolnir browses the web UI here)
  networking.firewall.allowedTCPPorts = [ 8188 ];
}
