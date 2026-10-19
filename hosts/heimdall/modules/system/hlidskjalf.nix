{ inputs, ... }:
 {
    imports = [ inputs.hlidskjalf.nixosModules.hlidskjalf ];

    services.hlidskjalf = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = 8787;
      cookieSecure = true;

      # traefik and newt both run on this host, so their forwarded headers can be trusted
      trustedProxies = [ "127.0.0.1/32" ];

      # admin only from the tailnet and vlan 20; anything through the pangolin tunnel is a tenant
      adminNetworks = [ "100.64.0.0/10" "10.0.20.0/24" ];

      # internet-facing: then it won't start without adminNetworks and trustedProxies
      # (docs/public-access.md in the hlidskjalf repo)
      public = true;

      # not behind cloudflare: true would believe a client-sent CF-Connecting-IP
      # and let anyone fake a tailnet ip into the admin zone
      cloudflare = false;

      settings.protectedVmids = [ 151 152 153 154 155 201 ];
    };
  }
