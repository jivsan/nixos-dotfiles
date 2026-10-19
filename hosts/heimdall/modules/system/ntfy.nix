{ ... }:

{
  # push notifications at ntfy.oryxserver.org: anything that can curl can reach my phone.
  # native module rather than a container: nixpkgs keeps it updated and it runs as a sandboxed DynamicUser
  services.ntfy-sh = {
    enable = true;

    # the users and the token live here, out of git (format at the bottom of this file)
    environmentFile = "/var/lib/secrets/ntfy.env";

    settings = {
      base-url = "https://ntfy.oryxserver.org";
      listen-http = "127.0.0.1:2586";   # only traefik talks to it
      behind-proxy = true;              # rate limits per client from X-Forwarded-For, not everyone as 127.0.0.1

      # the iphone can't keep a connection open. for every message ntfy asks ntfy.sh to wake the app
      # (only the message id and a hash of the topic url leave the lan), then the app fetches the
      # message from here. without it ios delivery can take hours
      upstream-base-url = "https://ntfy.sh";

      # nobody reads or publishes without a login: me on the phone and web app, scripts with a token
      auth-default-access = "deny-all";
      enable-login = true;

      # keep messages two days, so the phone still gets what came while it couldn't reach heimdall
      cache-duration = "48h";
    };
  };

  # /var/lib/secrets/ntfy.env (root, 0600). single quotes, the bcrypt hashes have $ in them:
  #
  #   NTFY_AUTH_USERS='christina:<hash>:admin,publisher:<hash>:user'
  #   NTFY_AUTH_ACCESS='publisher:*:write-only'
  #   NTFY_AUTH_TOKENS='publisher:tk_<29 chars>:fleet'
  #
  # hash: `ntfy user hash`, token: `ntfy token generate`. publisher can only send, so a leaked
  # token can't read my notifications. users removed from here are deleted from user.db on restart.
  #
  # send:  curl -H "Authorization: Bearer tk_..." -d "render done" https://ntfy.oryxserver.org/renders
}
