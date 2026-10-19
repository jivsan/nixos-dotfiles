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

      # cloudflare dns token; set on the cert, not in defaults, that's more reliable
      environmentFile = "/var/lib/secrets/cloudflare-dns-token";
    };
  };

  users.groups.traefik = { };
}
