{ config, ... }:

let
  # SQLite lives on local disk, never on the NFS share (same reason as vaultwarden).
  homarrData = "/var/lib/homarr";
in
{
  systemd.tmpfiles.rules = [
    "d ${homarrData} 0700 root root -"
  ];

  virtualisation.oci-containers.containers.homarr = {
    # :latest is only fetched when the image is missing, so updates happen when
    # you pull by hand (sudo podman pull ...; systemctl restart podman-homarr).
    # A new major migrates the DB: copy /var/lib/homarr somewhere first.
    image = "ghcr.io/homarr-labs/homarr:latest";
    autoStart = true;
    ports = [ "127.0.0.1:7575:7575" ];

    # SECRET_ENCRYPTION_KEY=<64 hex chars> (openssl rand -hex 32). It encrypts the
    # integration passwords and API keys in the DB: lose or change it and they
    # can no longer be read.
    environmentFiles = [ "/var/lib/secrets/homarr.env" ];

    environment = {
      BASE_URL = "https://home.oryxserver.org";   # behind Traefik's TLS: secure cookies, origin checks
      TZ = config.time.timeZone;
    };

    volumes = [ "${homarrData}:/appdata" ];
  };
}
