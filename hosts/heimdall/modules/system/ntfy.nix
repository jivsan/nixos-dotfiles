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

  # tailscale0 is a trusted interface, so without this every tailnet device could reach :2586 and skip
  # traefik. only home assistant may (it can't resolve the https name); ipv6 not at all
  networking.firewall.extraCommands = ''
    iptables -I nixos-fw -i tailscale0 -p tcp --dport 2586 ! -s 100.127.147.56 -j nixos-fw-refuse
    ip6tables -I nixos-fw -i tailscale0 -p tcp --dport 2586 -j nixos-fw-refuse
  '';

  # topics: alerts (something is wrong), backups, renders, updates, home
  #
  # /var/lib/secrets/ntfy.env (root, 0600). single quotes, the bcrypt hashes have $ in them.
  # every sender is its own user that can only write to its own topics, with its own token, so a
  # leaked token can't read anything, can't post elsewhere, and can be revoked alone:
  #
  #   NTFY_AUTH_USERS='christina:<hash>:admin,publisher:<hash>:user,heimdall:<hash>:user,...'
  #   NTFY_AUTH_ACCESS='publisher:*:write-only,heimdall:alerts:write-only,proxmox:backups:write-only,...'
  #   NTFY_AUTH_TOKENS='publisher:tk_...:fleet,heimdall:tk_...:heimdall,proxmox:tk_...:hella,...'
  #
  #   christina      admin, the phone and the web app
  #   publisher      * (my own curl token, only in vaultwarden)
  #   heimdall       alerts (alertmanager, grafana, scrutiny, huginn: /var/lib/secrets/ntfy-publish.env)
  #   proxmox        backups, alerts, updates (tokens "hella" and "pbs", in their notification secrets)
  #   truenas        alerts (odyn's slack-type alert service, basic auth in the url)
  #   mjolnir        renders (~/.config/ntfy/token, the blender render hook)
  #   homeassistant  home
  #
  # hash: `ntfy user hash`, token: `ntfy token generate`. sender passwords are random and never used.
  # users removed from here are deleted from user.db on restart; a changed env file needs
  # `systemctl restart ntfy-sh`.
  #
  # send:  curl -H "Authorization: Bearer tk_..." -d "render done" https://ntfy.oryxserver.org/renders
}
