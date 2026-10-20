{ ... }:

# my nix cache on brunnr (storage.nix). ncps keeps everything the hosts download from the upstream
# caches, plus what the forgejo runner builds here (forgejo-runner.nix). hosts read it through nginx on :5000,
# which only lets GET and HEAD through; uploads go straight to ncps on localhost. docs/ci-and-nix-cache.md
let
  key = "/var/lib/secrets/nixcache-signing-key";   # root 0600, made on this box, never in git
in
{
  fileSystems."/srv/nixcache" = {
    device = "brunnr/nixcache";
    fsType = "zfs";
    options = [ "nofail" ];
  };
  fileSystems."/srv/nixcache-db" = {
    device = "brunnr/nixcache-db";
    fsType = "zfs";
    options = [ "nofail" ];
  };

  services.ncps = {
    enable = true;
    server.addr = "127.0.0.1:8501";
    prometheus.enable = true;
    cache = {
      hostName = "mimir";
      secretKeyPath = key;
      storage.local = "/srv/nixcache";
      databaseURL = "sqlite:/srv/nixcache-db/db.sqlite";
      maxSize = "1600G";               # brunnr/nixcache has a 1.8 tb quota
      lru.schedule = "0 4 * * *";
      allowPutVerb = true;
      upstream = {
        urls = [
          "https://cache.nixos.org"
          "https://cache.numtide.com"
        ];
        publicKeys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        ];
      };
    };
  };
  systemd.services.ncps.unitConfig.RequiresMountsFor = [ "/srv/nixcache" "/srv/nixcache-db" ];

  # paths built on this box get the same signature, so what the runner uploads is trusted too
  nix.settings.secret-key-files = [ key ];

  # ncps 0.9.4 can't read cachix's nar names (uuids) and answers 500, so hyprland's cache isn't an upstream.
  # this box fetches those paths from cachix itself, and ci uploads them here like the rest
  nix.settings.extra-substituters = [ "https://hyprland.cachix.org" ];
  nix.settings.extra-trusted-public-keys = [ "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc=" ];

  services.nginx = {
    enable = true;
    virtualHosts.nixcache = {
      listen = [ { addr = "10.0.20.18"; port = 5000; } ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:8501";
        extraConfig = ''
          limit_except GET { deny all; }
          proxy_buffering off;
          proxy_read_timeout 600s;
        '';
      };
    };
  };
  systemd.services.nginx = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };

  # my hosts only: mjolnir, heimdall, tyr, njord, yggdrasil. nginx listens on the lan address alone,
  # so tailscale (which skips nixos-fw) can't reach it on mimir's 100.x address
  networking.firewall.extraCommands = ''
    for ip in 10.0.20.100 10.0.20.17 10.0.20.19 10.0.20.20 10.0.20.21; do
      iptables -A nixos-fw -p tcp -s $ip --dport 5000 -j nixos-fw-accept
    done
  '';
}
