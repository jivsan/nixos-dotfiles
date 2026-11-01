{ config, lib, pkgs, ... }:
# muninn-ro: a read-only view of my whole vault plus the vault and dotfiles graphs, for my muninn-ro
# cli, hermes, grok build and (later, over my tailnet) grok bot. there is no write path: no capture,
# no talk, no agents, no model calls, and nothing runs graphify.
#
# muninn-ro-build (every 15 min) copies every note into /var/lib/muninn-ro/view. a note is left out
# whole if it has a secret-shaped line, a word from my deny file, hidden characters or lines aimed at
# agents. emails and public ips are masked, links to left-out notes say "(private note)".
#   what it left out and why: sudo cat /var/lib/muninn-ro/drops.log
#   counts of the last run:   journalctl -u muninn-ro-build -n 5
# muninn-ro serves that view on 127.0.0.1:8095 (socket activated): GET-only rest + /mcp.
# traefik: muninn-ro.oryxserver.org, only from mjolnir and yggdrasil. tailnet: tailscaleServe below, off.
# code and tests: hosts/heimdall/muninn/ro (README.md there)
#
# by hand on heimdall, root 0600, not in git (the repo is public). tmpfiles makes them empty:
#   /var/lib/secrets/muninn-ro-exclude.txt   globs of notes to leave out, one a line (journal/*, Areas/x.md)
#   /var/lib/secrets/muninn-ro-deny.txt      words or names, one a line: a note with one is left out
#   /var/lib/secrets/muninn-ro-clients       "<name> <sha256 of its token>" a line: sudo muninn-ro-token add|revoke <name>
# the next build picks up exclude and deny changes, no deploy needed
let
  cfg = config.services.muninn-ro;
  vault = "/mnt/nas/obsidian/muninn";
  graphs = "/var/lib/huginn/graphs";
  state = "/var/lib/muninn-ro";
  port = 8095;
  src = "/run/muninn-ro-build";            # where the builder sees huginn's two graph files
  serverPython = pkgs.python3.withPackages (ps: [ ps.mcp ps.starlette ps.uvicorn ]);
  tailscale = "${config.services.tailscale.package}/bin/tailscale";

  # the server checks the Host header against these (traefik, tailscale serve, me on heimdall)
  hosts = [ "muninn-ro.oryxserver.org" "127.0.0.1:${toString port}" "localhost:${toString port}" ]
    ++ lib.optionals cfg.tailscaleServe [ "*.ts.net" "*.ts.net:8443" ];

  # both units: no privileges, no devices, no kernel knobs, a small syscall set
  hardening = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateIPC = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RemoveIPC = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    SystemCallErrorNumber = "EPERM";
    PrivateNetwork = true;                 # no network at all (nfs is the kernel's, the socket comes from systemd)
    IPAddressDeny = "any";
  };

  # sudo muninn-ro-token add <name>: a new token for one client, printed once (only the token on stdout)
  # sudo muninn-ro-token revoke <name> | list
  tokenTool = pkgs.writeShellApplication {
    name = "muninn-ro-token";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.systemd ];
    text = ''
      f=/var/lib/secrets/muninn-ro-clients
      if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi
      cmd="''${1:-}"; name="''${2:-}"
      case "$cmd" in
        list) { grep -v '^#' "$f" || true; } | cut -d' ' -f1; exit 0 ;;
        add|revoke) ;;
        *) echo "usage: muninn-ro-token add <name> | revoke <name> | list" >&2; exit 2 ;;
      esac
      if ! [[ $name =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then   # bash, not grep: grep would pass a name with a newline
        echo "a name is a-z, 0-9 and -, up to 32 long" >&2; exit 2
      fi
      install -m 600 -o root -g root /dev/null "$f.new"
      grep -v -E "^$name " "$f" > "$f.new" || true
      if [ "$cmd" = add ]; then
        if grep -q -E "^$name " "$f"; then rm -f "$f.new"; echo "$name has a token already, revoke it first" >&2; exit 1; fi
        tok="mro_$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
        printf '%s %s\n' "$name" "$(printf '%s' "$tok" | sha256sum | cut -d' ' -f1)" >> "$f.new"
      fi
      mv -f "$f.new" "$f"
      systemctl try-restart muninn-ro.service   # it reads the clients file at start
      if [ "$cmd" = add ]; then
        printf '%s\n' "$tok"
        echo "token for $name: shown once. keep it in ~/.config/muninn-ro/token (0600) on that host" >&2
      else
        echo "revoked $name" >&2
      fi
    '';
  };
in
{
  options.services.muninn-ro.tailscaleServe = lib.mkEnableOption ''
    muninn-ro on my tailnet: tailscale serve https 8443 -> 127.0.0.1:${toString port}.
    only after the tailnet policy gives every device but mine just heimdall tcp:8443,
    and after device approval and tailnet lock are on'';

  config = {
    users.users.muninn-ro = { isSystemUser = true; group = "muninn-ro"; };
    users.groups.muninn-ro = { };

    systemd.tmpfiles.rules = [
      "d /var/lib/secrets 0700 root root -"
      "f /var/lib/secrets/muninn-ro-exclude.txt 0600 root root -"
      "f /var/lib/secrets/muninn-ro-deny.txt 0600 root root -"
      "f /var/lib/secrets/muninn-ro-clients 0600 root root -"
      "d ${state} 0750 muninn-ro muninn-ro -"   # same owner and mode as StateDirectory below
    ];

    # the builder: reads the vault (read-only) and huginn's two graph files, writes only the view
    systemd.services.muninn-ro-build = {
      description = "muninn-ro: copy my vault into the read-only view, with the safety filters";
      unitConfig = {
        RequiresMountsFor = vault;
        OnFailure = [ "huginn-notify@%n.service" ];
        OnSuccess = [ "huginn-resolve@%n.service" ];
      };
      serviceConfig = hardening // {
        Type = "oneshot";
        User = "muninn-ro";
        Group = "muninn-ro";
        UMask = "0027";                    # the view is 0750/0640: the server reads it through the group
        StateDirectory = "muninn-ro";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "muninn-ro-build";
        LoadCredential = [
          "exclude:/var/lib/secrets/muninn-ro-exclude.txt"
          "deny:/var/lib/secrets/muninn-ro-deny.txt"
        ];
        # /var/lib/huginn is christina's (0750): bind just the two graph files in
        BindReadOnlyPaths = [
          "-${graphs}/vault/graph.json:${src}/vault-graph.json"
          "-${graphs}/dotfiles/graph.json:${src}/dotfiles-graph.json"
        ];
        ReadOnlyPaths = [ vault ];
        InaccessiblePaths = [
          "-/var/lib/secrets" "-/var/lib/muninn-brain" "-/var/lib/containers"
          "-/mnt/nas/immich-upload" "-/mnt/nas/nix-services" "-/mnt/appdata" "-/mnt/backups"
        ];
        RestrictAddressFamilies = "none";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.python3}/bin/python3 -I -u ${../../muninn/ro/build-view.py}"
          "--vault ${vault} --out ${state}"
          "--vault-graph ${src}/vault-graph.json --dotfiles-graph ${src}/dotfiles-graph.json"
          "--exclude %d/exclude --deny %d/deny"
        ];
        MemoryMax = "1G";
        TimeoutStartSec = "10min";
        Nice = 10;
      };
    };
    systemd.timers.muninn-ro-build = {
      description = "muninn-ro: rebuild the view every 15 minutes";
      wantedBy = [ "timers.target" ];
      # OnActiveSec: a first view a minute after boot or deploy, not at the next quarter hour
      timerConfig = { OnCalendar = "*:0/15"; OnActiveSec = "1min"; Persistent = true; RandomizedDelaySec = "30s"; };
    };

    # the server: systemd owns the socket, the process has no network of its own and sees only the view
    systemd.sockets.muninn-ro = {
      description = "muninn-ro: read-only api on 127.0.0.1:${toString port}";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "127.0.0.1:${toString port}" ];
      # the service's ip list doesn't cover a socket systemd passes in, so the listener gets its own
      socketConfig = { IPAddressAllow = "localhost"; IPAddressDeny = "any"; };
    };
    systemd.services.muninn-ro = {
      description = "muninn-ro: read-only api over the view (rest + mcp)";
      requires = [ "muninn-ro.socket" ];
      after = [ "muninn-ro.socket" ];
      environment = {
        MUNINN_RO_VIEW = "${state}/view/current";
        MUNINN_RO_HOSTS = lib.concatStringsSep " " hosts;
      };
      serviceConfig = hardening // {
        DynamicUser = true;
        SupplementaryGroups = [ "muninn-ro" ];
        UMask = "0077";
        LoadCredential = [ "clients:/var/lib/secrets/muninn-ro-clients" ];
        # nothing of /var or /mnt but the view: not the vault, not huginn, not the brain's index, no secrets
        TemporaryFileSystem = [ "/var:ro" "/mnt:ro" "/srv:ro" ];
        BindReadOnlyPaths = [ state ];
        # sockets anyone may connect to on heimdall
        InaccessiblePaths = [ "-/run/tailscale" "-/run/dbus" "-/run/ssh-unix-local" "-/run/rpcbind.sock" ];
        IPAddressAllow = "localhost";
        RestrictAddressFamilies = [ "AF_UNIX" ];   # asyncio's own socketpair; the tcp socket is systemd's
        ExecStart = "${serverPython}/bin/python3 -I -u ${../../muninn/ro/muninn-ro.py}";   # -u: log lines unbuffered
        MemoryMax = "512M";
        TasksMax = 64;
        Restart = "on-failure";
      };
    };

    # later and mine: grok bot's tailscale device reaches this on https 8443, nothing else.
    # tailscaled keeps a serve config in its own state, so with the option off this unit turns 8443 off
    # on every boot and every switch (it doesn't stay active, so switching starts it again).
    # 8443 on heimdall's tailnet side is muninn-ro's: don't serve anything else there by hand
    systemd.services.muninn-ro-tailscale-serve = {
      description = if cfg.tailscaleServe
        then "muninn-ro on my tailnet: tailscale serve https 8443 -> 127.0.0.1:${toString port}"
        else "muninn-ro is off my tailnet: tailscale serve https 8443 off";
      after = [ "tailscaled.service" "muninn-ro.socket" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" ];   # only tailscaled's socket
        IPAddressDeny = "any";
      } // (if cfg.tailscaleServe then {
        RemainAfterExit = true;
        ExecStart = "${tailscale} serve --bg --yes --https=8443 http://127.0.0.1:${toString port}";
        ExecStop = "${tailscale} serve --yes --https=8443 off";
        TimeoutStartSec = "60s";           # serve waits forever if https certs are off on the tailnet
        Restart = "on-failure";
        RestartSec = "30s";
      } else {
        # "-": an error here (nothing served on 8443, tailscaled down) doesn't fail the unit
        ExecStart = "-${tailscale} serve --yes --https=8443 off";
        TimeoutStartSec = "30s";
      });
    };

    # muninn-ro.oryxserver.org: only mjolnir and yggdrasil (not lan-only, it lets the whole tailnet in).
    # no access log for this router: the url holds my search words. the rule is the host alone, so every
    # request lands here (and stays out of the access log); the server answers 405 to a wrong method.
    # needs a pi-hole cname to traefik
    services.traefik.dynamicConfigOptions.http = {
      routers.muninn-ro = {
        rule = "Host(`muninn-ro.oryxserver.org`)";
        entryPoints = [ "websecure" ];
        service = "muninn-ro";
        tls = { };
        middlewares = [ "muninn-ro-clients" "muninn-ro-rate" ];
        observability.accessLogs = false;
      };
      services.muninn-ro.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
      middlewares = {
        muninn-ro-clients.ipAllowList.sourceRange = [ "10.0.20.100/32" "10.0.20.21/32" ];   # mjolnir, yggdrasil
        muninn-ro-rate.rateLimit = { average = 120; period = "1m"; burst = 40; };
      };
    };

    environment.systemPackages = [ tokenTool ];
  };
}
