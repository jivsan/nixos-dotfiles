{ inputs, ... }:
{
  imports = [ inputs.hlidskjalf.nixosModules.hlidskjalf ];

  services.hlidskjalf = {
    enable = true;

    bindAddress = "127.0.0.1";
    port = 8787;
    cookieSecure = true;

    settings = {
    # refused server-side for destroy / reinstall / stop / reset.
    # this are the protected vmid's for my setup: heimdall is 154 that is running this panel
      protectedVmids = [ 151 152 153 154 155 201 ];
    };
  };
}
