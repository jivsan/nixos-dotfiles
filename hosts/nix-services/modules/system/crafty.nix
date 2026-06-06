{ ... }:
let
  craftyImage = "registry.gitlab.com/crafty-controller/crafty-4@sha256:d2f61fcabb4756a63bc8538fb4f5e35ffddca3f1916a733c95a31c705c697742";
in
{
  virtualisation.oci-containers.containers.crafty = {
    image = craftyImage;
    autoStart = true;

    environment = {
      TZ = "Etc/UTC";
    };

    volumes = [
      "/mnt/nas/crafty-config:/crafty/app/config:rw"
      "/mnt/nas/crafty-backups:/crafty/backups:rw"
      "/mnt/nas/crafty-logs:/crafty/logs:rw"
      "/mnt/nas/crafty-import:/crafty/import:rw"
      "/mnt/nas/crafty-servers:/crafty/servers:rw"
    ];

    ports = [
      "0.0.0.0:8443:8443"        # Crafty web admin (HTTPS, self-signed)
      "0.0.0.0:25565:25565/tcp"  # Minecraft Java
      "0.0.0.0:19132:19132/udp"  # Minecraft Bedrock
      "0.0.0.0:8123:8123/tcp"    # Dynmap (if you ever add it)
    ];
  };

  networking.firewall = {
    allowedTCPPorts = [ 8443 25565 8123 ];
    allowedUDPPorts = [ 19132 ];
  };
}
