{ ... }:
  {
    services.cloudflared = {
      enable = true;

      tunnels."" = {
        credentialsFile = "/var/lib/cloudflared/7e2ff33e-964d-4f95-b99f-0736833da23a.json";

        # The public door: tenants only. Straight to the panel — Traefik is not
        # involved here, and does not need to be.
        ingress."hlidskjalf.im-goat.com" = "http://127.0.0.1:8787";

        # Anything else that reaches this tunnel gets nothing.
        default = "http_status:404";
      };
    };
  }
