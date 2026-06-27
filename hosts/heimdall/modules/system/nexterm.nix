{ ... }:

{
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  virtualisation.oci-containers = {
    backend = "podman";

    containers.nexterm = {
      image = "germannewsmaker/nexterm:latest";
      autoStart = true;

      ports = [
        "127.0.0.1:6989:6989"
      ];

      volumes = [
        "/var/lib/nexterm/data:/app/data"
      ];

      environment = {
        NODE_ENV = "production";
        SERVER_PORT = "6989";
        LOG_LEVEL = "info";
      };

      environmentFiles = [
        "/var/lib/nexterm/nexterm.env"
      ];
    };
  };
}
