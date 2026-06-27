{ ... }:
{
  security.acme = {
    acceptTerms = true;

    defaults = {
      email = "chrsol3@gmail.com";
      dnsProvider = "cloudflare";
      dnsPropagationCheck = true;
    };

    certs."oryxserver.org" = {
      domain = "oryxserver.org";
      extraDomainNames = [ "*.oryxserver.org" ];
      group = "traefik";

      # Set environment file directly on the cert (more reliable than defaults)
      environmentFile = "/var/lib/secrets/cloudflare-dns-token";
    };
  };

  users.groups.traefik = { };
}
