{ config, pkgs, ... }:

let
  data = "/var/lib/changedetection";
in
{
  # changedetection.io at changedetection.oryxserver.org: watches web pages and pushes to ntfy
  # (topic "changes") when they change. a chrome container next to it renders pages that only
  # fill in with javascript
  systemd.tmpfiles.rules = [
    "d ${data} 0700 root root -"      # the app runs as root in its container; the watch list and the ntfy token live here
  ];

  # their own network: the browser answers only changedetection, nothing on the host or lan
  systemd.services.create-changedetection-network = {
    description = "Create changedetection Podman network";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman ];
    serviceConfig.Type = "oneshot";
    script = ''
      podman network exists changedetection || podman network create changedetection
    '';
  };

  virtualisation.oci-containers.containers = {
    changedetection = {
      # pinned; update by changing the tag (releases: github.com/dgtlmoon/changedetection.io)
      image = "ghcr.io/dgtlmoon/changedetection.io:0.60.9";
      autoStart = true;
      ports = [ "127.0.0.1:5000:5000" ];
      volumes = [ "${data}:/datastore" ];
      environment = {
        BASE_URL = "https://changedetection.oryxserver.org";   # links in the pushes point here
        USE_X_SETTINGS = "1";                                    # behind traefik: trust X-Forwarded-*
        # its live-update websocket refused its own https origin behind traefik (400 every few seconds)
        SOCKETIO_CORS_ORIGINS = "https://changedetection.oryxserver.org";
        LOGGER_LEVEL = "INFO";                                   # DEBUG by default: ~70 journal lines a minute
        PLAYWRIGHT_DRIVER_URL = "ws://changedetection-browser:3000";
        HIDE_REFERER = "true";
        DISABLE_VERSION_CHECK = "true";
        FETCH_WORKERS = "4";
        TZ = config.time.timeZone;
      };
      extraOptions = [ "--network=changedetection" "--memory=768m" ];
    };

    # sockpuppetbrowser starts chrome with --no-sandbox itself, so it needs none of the extra
    # rights (SYS_ADMIN) changedetection's example gives it. no ports, no host access
    changedetection-browser = {
      # :latest is the only maintained tag; pinned by digest, update by pulling and changing it
      image = "docker.io/dgtlmoon/sockpuppetbrowser@sha256:1d8f72d2ce2085faed4232e5ae1e65c02efe5b831a18e127829b267c260b4fb2";
      autoStart = true;
      environment = {
        MAX_CONCURRENT_CHROME_PROCESSES = "2";
        SCREEN_WIDTH = "1920";
        SCREEN_HEIGHT = "1080";
        SCREEN_DEPTH = "16";
      };
      extraOptions = [
        "--network=changedetection"
        "--memory=1g"
        "--shm-size=512m"                       # chrome's renderers crash on podman's 64 MB /dev/shm
        "--cap-drop=all"
        "--security-opt=no-new-privileges"
      ];
    };
  };

  systemd.services.podman-changedetection-browser = {
    after = [ "create-changedetection-network.service" ];
    requires = [ "create-changedetection-network.service" ];
  };
  systemd.services.podman-changedetection = {
    after = [ "create-changedetection-network.service" "podman-changedetection-browser.service" ];
    requires = [ "create-changedetection-network.service" ];
    wants = [ "podman-changedetection-browser.service" ];
  };
}
