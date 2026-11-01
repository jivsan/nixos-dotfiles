{ config, lib, pkgs, ... }:
# the login in front of brain.oryxserver.org: nginx asks muninn-brain-auth (127.0.0.1:8094) about every
# request before it serves the page, the vault files, /api, /bridge or /capture
# - agents send their own token: Authorization: Bearer <token>, from a file only they can read
# - my browsers log in once at /_brain/login with their own token, which sets a cookie
# - heimdall keeps only sha256 hashes, in /var/lib/secrets/muninn-brain-tokens (root only, never in git)
# make or drop a token: sudo muninn-brain-token add NAME [PATH...] [--qr] | revoke NAME | list
# enforce = false (the default) refuses nobody, it only logs who would be refused: journalctl -u muninn-brain-auth
let
  cfg = config.muninn.brain.auth;
  tokensFile = "/var/lib/secrets/muninn-brain-tokens";
  authPy = ../../muninn/brain/auth.py;

  tokenTool = pkgs.writeShellApplication {
    name = "muninn-brain-token";
    runtimeInputs = [ pkgs.python3 pkgs.systemd ];
    text = ''
      MUNINN_BRAIN_TOKENS=${tokensFile} MUNINN_QRENCODE=${pkgs.qrencode}/bin/qrencode python3 ${authPy} "$@"
      # a reload hands the service the new hashes without a restart, so nobody gets a 500 meanwhile.
      # the token is saved by now, so a failed reload only warns: muninn-brain-get-token keeps it
      case "''${1:-}" in
        add|revoke)
          systemctl try-reload-or-restart muninn-brain-auth.service >&2 \
            || echo "muninn-brain-token: saved, but the reload failed. it counts after: sudo systemctl restart muninn-brain-auth" >&2
          ;;
      esac
    '';
  };

  # what /_brain/ping answers. a file, not nginx's return, so the request goes through the check first
  pingFile = pkgs.writeText "muninn-brain-ping" "ok\n";
in
{
  options.muninn.brain.auth = {
    enforce = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "refuse callers without a token or login. false lets everyone in and only logs who would be refused";
    };
    allowFrom = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.0.50.10" ];
      description = ''
        addresses, as traefik sees them, let in without a token. only for a device nothing else runs on:
        never mjolnir or yggdrasil, where agents run, and any website open in a browser there could use it.
        the address is read from X-Forwarded-For when nginx's peer is 127.0.0.1, and nginx can't tell
        traefik from any other program on heimdall: the bridge's codex and claude workers, or anything
        else running there, can send their own X-Forwarded-For and pass as any address in this list
      '';
    };
  };

  config = {
    environment.systemPackages = [ tokenTool ];

    # an empty file the first time, so the service can start before the first token
    systemd.tmpfiles.rules = [ "f ${tokensFile} 0600 root root -" ];

    systemd.services."muninn-brain-auth" = {
      description = "muninn brain: the login check nginx asks before each request";
      before = [ "nginx.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        MUNINN_BRAIN_ENFORCE = if cfg.enforce then "1" else "0";
        MUNINN_BRAIN_ALLOW = lib.concatStringsSep " " cfg.allowFrom;
        PYTHONDONTWRITEBYTECODE = "1";
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.python3}/bin/python3 ${authPy} serve";
        # systemd reads the root-only file and hands the service its own copy.
        # on reload it hands over a fresh copy first, then the service reads it again
        LoadCredential = "tokens:${tokensFile}";
        RefreshOnReload = "credentials";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        DynamicUser = true;
        Restart = "always";
        RestartSec = "2s";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
        MemoryDenyWriteExecute = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };

    services.nginx.virtualHosts."muninn-brain" = {
      extraConfig = ''
        # every request asks muninn-brain-auth first; a refusal shows the login page with a 401
        auth_request /_brain_auth;
        error_page 401 /_brain/login;
      '';

      locations."= /_brain_auth".extraConfig = ''
        internal;
        auth_request off;
        proxy_pass http://127.0.0.1:8094/check;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        # set here, so a caller can't send its own. the raw uri, never the decoded one, in a header
        proxy_set_header X-Brain-Peer $remote_addr;
        proxy_set_header X-Original-URI $request_uri;
        proxy_set_header X-Original-Method $request_method;
      '' + lib.optionalString (!cfg.enforce) ''
        # log only: if the check is down, let the request through like before
        error_page 500 502 503 504 = @brain_auth_down;
      '';
      locations."@brain_auth_down".return = "204";

      # the login page and logout, open to all
      locations."/_brain/" = {
        proxyPass = "http://127.0.0.1:8094";
        extraConfig = ''
          auth_request off;
          proxy_set_header X-Brain-Peer $remote_addr;
          client_max_body_size 8k;
        '';
      };

      # for the blackbox probe and homarr's ping (homarr's brain app must use this url).
      # open to all, but it still asks the check (auth.py lets it in), so with enforce on
      # a dead check shows here as a 500, like it does for the whole brain
      locations."= /_brain/ping" = {
        alias = "${pingFile}";
        extraConfig = ''
          access_log off;
          default_type text/plain;
          add_header Cache-Control no-store;
        '';
      };
    };
  };
}
