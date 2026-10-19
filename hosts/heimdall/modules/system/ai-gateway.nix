{ pkgs, lib, ... }:
# one openai-style endpoint for my models at http://10.0.20.17:4000/v1, with metrics
# for the "AI gateway" grafana dashboard. runbook: docs/misc/ai-gateway.md
let
  port = 4000;
  mimir = "10.0.20.18";

  # mimir's local chat models (hosts/mimir/modules/system/llm.nix), off: its 8 GB card
  # is shared with octane. true again once llm.nix runs on a card that holds them
  localChat = false;

  python = pkgs.python3.withPackages (ps: [ ps.aiohttp ps.prometheus-client ]);

  config = pkgs.writeText "ai-gateway.json" (builtins.toJSON {
    listen = { host = "0.0.0.0"; inherit port; };

    # one line per request, for the dashboard's request id box; no prompt or answer text
    loki_url = "http://127.0.0.1:3100/loki/api/v1/push";

    # callers can name themselves as http://10.0.20.17:4000/client/<name>/v1 and the dashboard
    # splits requests, tokens and cost by name. huginn.nix and brain.nix use the first two
    clients = [ "huginn" "bridge" "hermes" "mjolnir" ];

    targets = lib.optionalAttrs localChat {
      # one chat model fits on the card at a time, and llama-server kills the loaded one
      # mid-answer when the other is asked for. exclusive holds that request until the rest finish
      mimir-chat = {
        base_url = "http://${mimir}:8080/v1";
        health = "http://${mimir}:8080/health";
        max_concurrent = 2;   # the most `parallel` slots any model has in llm.nix
        exclusive = true;
      };
    } // {
      # key is OPENAI_API_KEY=... in /var/lib/secrets/graphify-openrouter.env
      openrouter = {
        base_url = "https://openrouter.ai/api/v1";
        api_key_env = "OPENAI_API_KEY";
      };

      # health only, not called through the gateway: they show in the dashboard's health row
      mimir-embed-notes.health = "http://${mimir}:8081/health";
      mimir-embed-query.health = "http://${mimir}:8082/health";
      mimir-voice.health = "http://${mimir}:8000/health";
    };

    # what a client sends as "model"; local names must match the preset sections in mimir's llm.nix
    models = lib.optionalAttrs localChat {
      "qwen3.5-9b" = {
        target = "mimir-chat";
        tier = "efficient";
        max_prompt_chars = 40000;   # about 12k tokens: fits its 16k-token slot with room for the answer
      };
      "qwen3.8-27b" = { target = "mimir-chat"; tier = "capable"; };
    } // {
      "minimax/minimax-m3" = { target = "openrouter"; tier = "capable"; };
    };

    # auto: local model first, minimax when the request is too long or mimir fails.
    # only callers on heimdall or with a client key ever get minimax, it costs money
    routes.auto.models = lib.optional localChat "qwen3.5-9b" ++ [ "minimax/minimax-m3" ];
  });
in
{
  systemd.services.ai-gateway = {
    description = "ai-gateway: OpenAI-style front door for the model servers, with Prometheus metrics";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment.AIGW_CONFIG = "${config}";
    serviceConfig = {
      ExecStart = "${python}/bin/python3 ${../../ai-gateway/gateway.py}";
      # both optional: without the first the openrouter target is off;
      # the second can set AIGW_CLIENT_KEYS=key1,key2 so other hosts may use the gateway
      EnvironmentFile = [
        "-/var/lib/secrets/graphify-openrouter.env"
        "-/var/lib/secrets/ai-gateway.env"
      ];
      DynamicUser = true;
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  # lan only (ens18), not tailscale or awg0
  networking.firewall.interfaces.ens18.allowedTCPPorts = [ port ];
}
