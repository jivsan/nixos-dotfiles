{ ... }:
{
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9115;
    configFile = builtins.toFile "blackbox.yml" (builtins.toJSON {
      modules = {
        http_2xx = {
          prober = "http";
          timeout = "5s";
          http = {
            valid_status_codes = [];  # Defaults to 2xx
            method = "GET";
            preferred_ip_protocol = "ip4";
            tls_config.insecure_skip_verify = false;
          };
        };
        http_2xx_insecure = {
          prober = "http";
          timeout = "5s";
          http = {
            method = "GET";
            preferred_ip_protocol = "ip4";
            tls_config.insecure_skip_verify = true;
          };
        };
        icmp = {
          prober = "icmp";
          timeout = "5s";
        };
      };
    });
  };
}
