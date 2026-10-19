{ config, ... }:

let
  # sqlite stays on local disk, not nfs (same reason as vaultwarden)
  homarrData = "/var/lib/homarr";
in
{
  systemd.tmpfiles.rules = [
    "d ${homarrData} 0700 root root -"
  ];

  virtualisation.oci-containers.containers.homarr = {
    # :latest is only pulled when the image is missing, so i update by hand:
    # sudo podman pull ...; systemctl restart podman-homarr
    # a new major migrates the db, so copy /var/lib/homarr first
    image = "ghcr.io/homarr-labs/homarr:latest";
    autoStart = true;
    ports = [ "127.0.0.1:7575:7575" ];

    # SECRET_ENCRYPTION_KEY=<64 hex chars> (openssl rand -hex 32); it encrypts the
    # integration passwords and api keys in the db, lose or change it and they're unreadable
    environmentFiles = [ "/var/lib/secrets/homarr.env" ];

    environment = {
      BASE_URL = "https://home.oryxserver.org";   # the https name traefik serves, for secure cookies and origin checks
      TZ = config.time.timeZone;
    };

    volumes = [ "${homarrData}:/appdata" ];
  };
}
