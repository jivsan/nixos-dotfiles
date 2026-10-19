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
            valid_status_codes = [];  # empty means any 2xx
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
        # odyn's nfs and web ui ports (alerting.nix)
        tcp_connect = {
          prober = "tcp";
          timeout = "5s";
          tcp.preferred_ip_protocol = "ip4";
        };
        # pi-hole answers for a local name (alerting.nix)
        dns_oryx = {
          prober = "dns";
          timeout = "5s";
          dns = {
            query_name = "traefik.oryxserver.org";
            query_type = "A";
            valid_rcodes = [ "NOERROR" ];
            preferred_ip_protocol = "ip4";
          };
        };
      };
    });
  };
}
