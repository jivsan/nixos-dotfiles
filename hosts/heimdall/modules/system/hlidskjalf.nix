{ inputs, ... }:
 {
    imports = [ inputs.hlidskjalf.nixosModules.hlidskjalf ];

    services.hlidskjalf = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = 8787;
      cookieSecure = true;

      # Both doors terminate on this host, so their forwarded headers are believable.
      trustedProxies = [ "127.0.0.1/32" ];

      # Admin exists on the tailnet and nowhere else. Everything arriving through
      # Cloudflare is a tenant, whatever password it types.
      adminNetworks = [ "100.64.0.0/10" ];

      settings.protectedVmids = [ 151 152 153 154 155 201 ];
    };
  }
