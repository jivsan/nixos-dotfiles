{ config, ... }:

let
  data = "/var/lib/manyfold";          # sqlite database, thumbnails, settings: local disk, not nfs
  library = "/mnt/nas/manyfold";       # odyn /mnt/vault/studio/Manyfold (nas.nix)
in
{
  # Manyfold at manyfold.oryxserver.org: a library of 3D models with previews in the browser.
  # it writes a datapackage.json next to every model and can move files when asked to organize,
  # so it only gets its own folder on odyn (/mnt/studio/Manyfold), never my blender folders.
  # "solo" image: the database (sqlite) and its job queue are inside the one container
  systemd.tmpfiles.rules = [
    "d ${data} 0750 1000 100 -"        # PUID/PGID below
  ];

  virtualisation.oci-containers.containers.manyfold = {
    # pinned; update by changing the tag (github.com/manyfold3d/manyfold/releases)
    image = "ghcr.io/manyfold3d/manyfold-solo:0.152.0";
    autoStart = true;
    ports = [ "127.0.0.1:3214:3214" ];
    # SECRET_KEY_BASE=<openssl rand -hex 64>, signs the login cookies
    environmentFiles = [ "/var/lib/secrets/manyfold.env" ];
    environment = {
      PUID = "1000";                   # christina:users, like paperless
      PGID = "100";
      MULTIUSER = "enabled";           # a login; the first account made becomes the admin
      PUBLIC_HOSTNAME = "manyfold.oryxserver.org";
      HTTPS_ONLY = "enabled";          # secure cookies; traefik serves it over https only anyway
      # fewer workers than the defaults (4 web, 4 jobs), heimdall has 8 GB for everything
      WEB_CONCURRENCY = "1";
      RAILS_MAX_THREADS = "5";
      DEFAULT_WORKER_CONCURRENCY = "2";
      TZ = config.time.timeZone;
    };
    volumes = [
      "${data}:/config"
      "${library}:/libraries/manyfold"
    ];
    extraOptions = [ "--memory=1536m" ];
  };

  systemd.services.podman-manyfold.unitConfig.RequiresMountsFor = [ library ];
}
