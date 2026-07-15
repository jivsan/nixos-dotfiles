{ ... }:
  {
    services.newt = {
      enable = true;

      # The Pangolin control server this site dials out to. Public, not a secret.
      settings.endpoint = "https://pangolin.im-goat.com";
          environmentFile = "/var/lib/newt/newt.env";
    };
  }
