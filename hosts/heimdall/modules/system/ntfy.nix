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
      # traefik comes in on 127.0.0.1, home assistant over tailscale (100.118.226.25:2586, tailscale0 is
      # trusted). the lan can't reach the port, it isn't in allowedTCPPorts
      listen-http = ":2586";
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

      # ?template=<name> turns a webhook's json into a readable push (grafana's is built in)
      template-dir = "/etc/ntfy/templates";
    };
  };

  # alertmanager (alerting.nix): one push per group, high while firing, quiet when resolved
  environment.etc."ntfy/templates/prometheus.yml".text = ''
    title: |
      {{- if eq .status "firing" }}{{ .commonLabels.alertname }}{{ else }}Resolved: {{ .commonLabels.alertname }}{{ end }}
    message: |
      {{- range .alerts }}
      {{ if eq .status "firing" }}🔥{{ else }}✅ cleared:{{ end }} {{ .annotations.summary }}
      {{- end }}
    priority: |
      {{- if eq .status "firing" }}4{{ else }}2{{ end }}
  '';

  # truenas posts its alerts as a slack webhook ({"text": ...}); a message without new alerts only lists cleared ones
  environment.etc."ntfy/templates/truenas.yml".text = ''
    title: odyn (TrueNAS)
    message: |
      {{ .text }}
    priority: |
      {{- if contains "New alert" .text }}4{{ else }}2{{ end }}
  '';

  # topics: alerts (something is wrong), backups, renders, updates, home
  #
  # /var/lib/secrets/ntfy.env (root, 0600). single quotes, the bcrypt hashes have $ in them:
  #
  #   NTFY_AUTH_USERS='christina:<hash>:admin,publisher:<hash>:user'
  #   NTFY_AUTH_ACCESS='publisher:*:write-only'
  #   NTFY_AUTH_TOKENS='publisher:tk_<29 chars>:fleet'
  #
  # hash: `ntfy user hash`, token: `ntfy token generate`. publisher can only send, so a leaked
  # token can't read my notifications. users removed from here are deleted from user.db on restart.
  # the same token is in /var/lib/secrets/ntfy-publish.env (NTFY_TOKEN=...) for the senders on heimdall
  #
  # send:  curl -H "Authorization: Bearer tk_..." -d "render done" https://ntfy.oryxserver.org/renders
}
