{ ... }:
  {
    services.newt = {
      enable = true;

      # the pangolin server this site dials out to, not a secret
      settings.endpoint = "https://pangolin.im-goat.com";
          environmentFile = "/var/lib/newt/newt.env";
    };
  }
