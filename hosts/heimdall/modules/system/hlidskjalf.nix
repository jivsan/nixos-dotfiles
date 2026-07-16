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
      # the Pangolin tunnel is a tenant, whatever password it types.
      adminNetworks = [ "100.64.0.0/10" "10.0.20.0/24" ];

      # Declare the panel internet-facing. Changes no behaviour on its own, but
      # refuses to start unless adminNetworks + trustedProxies are set (both are,
      # above) — so the panel can never be exposed with admin login open to the
      # world, or blind to who is calling. See docs/public-access.md.
      public = true;

      # We are behind Pangolin/Newt + Traefik, NOT Cloudflare — leave this false so
      # a client-supplied CF-Connecting-IP is ignored and only the X-Forwarded-For
      # chain is believed. Setting it true here would let anyone spoof a tailnet
      # source IP and reach the admin zone.
      cloudflare = false;

      settings.protectedVmids = [ 151 152 153 154 155 201 ];
    };
  }
