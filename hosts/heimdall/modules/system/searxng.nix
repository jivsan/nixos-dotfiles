{ config, pkgs, ... }:

let
  cache = "/var/cache/searxng";

  # only what differs from searxng's defaults. the secret key comes from SEARXNG_SECRET in the env file
  settings = (pkgs.formats.yaml { }).generate "searxng-settings.yml" {
    use_default_settings = true;
    general = {
      instance_name = "oryx search";
      enable_metrics = false;
    };
    search = {
      safe_search = 0;
      autocomplete = "duckduckgo";
      formats = [ "html" "json" ];   # json lets my agents search through it too
    };
    server = {
      base_url = "https://search.oryxserver.org/";
      limiter = false;               # lan-only behind traefik, nobody to rate-limit
      public_instance = false;
      image_proxy = true;            # result thumbnails come through here, not straight from the sites
      # the search form posts, so queries stay out of traefik's access log (GET /search?q=... still works)
      method = "POST";
    };
    ui = {
      query_in_title = true;
      theme_args.simple_style = "dark";
    };
  };
in
{
  # SearXNG at search.oryxserver.org: one private search page that asks google, bing, duckduckgo,
  # wikipedia etc. for me. container rather than nixpkgs, whose snapshot is months old and engines
  # break as the sites change
  systemd.tmpfiles.rules = [
    "d ${cache} 0750 977 977 -"      # the image's searxng user
  ];

  virtualisation.oci-containers.containers.searxng = {
    # pinned by digest; update tag and digest together (hub.docker.com/r/searxng/searxng/tags, dated daily)
    image = "docker.io/searxng/searxng:2026.10.19-81371861f@sha256:5ed0323b5f5f8701264ef65e239a2bd83cb57098f2b971fa30bf79c06eeae271";
    autoStart = true;
    user = "977:977";                # it would run as root otherwise
    ports = [ "127.0.0.1:8888:8080" ];
    # SEARXNG_SECRET=<openssl rand -hex 32>
    environmentFiles = [ "/var/lib/secrets/searxng.env" ];
    environment = {
      SEARXNG_BASE_URL = "https://search.oryxserver.org/";
      TZ = config.time.timeZone;
    };
    volumes = [
      "${settings}:/etc/searxng/settings.yml:ro"
      "${cache}:/var/cache/searxng"
    ];
    extraOptions = [ "--memory=512m" "--cap-drop=all" "--security-opt=no-new-privileges" ];
  };
}
