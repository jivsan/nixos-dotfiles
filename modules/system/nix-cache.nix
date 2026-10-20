{ ... }:

# every host asks mimir's nix cache first (hosts/mimir/modules/system/nix-cache-server.nix).
# if mimir is off, nix gives up on it after the connect timeout and downloads as before
{
  nix.settings = {
    extra-substituters = [ "http://10.0.20.18:5000?priority=10" ];
    extra-trusted-public-keys = [ "mimir-nixcache-1:7VO4dCAHLyDybfMV0oM/7k6ig8yhEWHNjixoMvd17RU=" ];
    connect-timeout = 5;
    fallback = true;
  };
}
