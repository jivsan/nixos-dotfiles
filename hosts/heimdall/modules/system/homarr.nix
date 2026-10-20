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
    # pinned by tag + digest: to update, put the new ones here and rebuild.
    # a new major migrates the db, so copy /var/lib/homarr first
    image = "ghcr.io/homarr-labs/homarr:v2.7.0@sha256:f532ce7cb2a388096d6dce30b7ee41ff4b413b48ddc219ad2321dedb758cd772";
    autoStart = true;
    ports = [ "127.0.0.1:7575:7575" ];
    # fixed address: traefik's lan-only lets this one container in, not all of podman's network
    extraOptions = [ "--ip=10.88.200.10" ];

    # SECRET_ENCRYPTION_KEY=<64 hex chars> (openssl rand -hex 32); it encrypts the
    # integration passwords and api keys in the db, lose or change it and they're unreadable
    environmentFiles = [ "/var/lib/secrets/homarr.env" ];

    environment = {
      BASE_URL = "https://home.oryxserver.org";   # the https name traefik serves, for secure cookies and origin checks
      TZ = config.time.timeZone;
    };

    volumes = [
      "${homarrData}:/appdata"
      # podman's docker api, so homarr can list and start/stop the containers here.
      # that's full control over every container, so homarr stays behind lan-only
      "/run/podman/podman.sock:/var/run/docker.sock"
    ];
  };
}
