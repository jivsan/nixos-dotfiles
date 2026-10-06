{ pkgs, ... }:
# ── ai-gateway — one OpenAI-style endpoint for the models, with metrics ───────
# Clients call http://10.0.20.17:4000/v1 and name a model; the gateway forwards
# to the server that has it and measures the request (tokens, time to first
# token, queueing, finish reason). Prometheus scrapes :4000/metrics and Grafana
# shows it on the "AI gateway" dashboard. Runbook: docs/misc/ai-gateway.md.
#
# Nothing is pointed at it by this module: huginn, the bridge and hermes keep
# calling what they call today until their own config is changed.
let
  port = 4000;
  mimir = "10.0.20.18";

  python = pkgs.python3.withPackages (ps: [ ps.aiohttp ps.prometheus-client ]);

  config = pkgs.writeText "ai-gateway.json" (builtins.toJSON {
    listen = { host = "0.0.0.0"; inherit port; };

    # One line per request also goes to Loki (loki.nix), which is what the
    # dashboard's Request ID box searches. No prompt or answer text is logged.
    loki_url = "http://127.0.0.1:3100/loki/api/v1/push";

    targets = {
      # llama-server on mimir (hosts/mimir/modules/system/llm.nix). The 16 GB
      # card holds one chat model at a time, and llama-server kills the loaded
      # model mid-answer when the other one is asked for. `exclusive` makes the
      # gateway hold that request back until the running ones are done.
      mimir-chat = {
        base_url = "http://${mimir}:8080/v1";
        health = "http://${mimir}:8080/health";
        max_concurrent = 2;   # the most `parallel` slots any model has in llm.nix
        exclusive = true;
      };

      # The key's variable name in graphify-openrouter.env. The key itself is
      # only ever in /var/lib/secrets, never in this repo.
      openrouter = {
        base_url = "https://openrouter.ai/api/v1";
        api_key_env = "OPENAI_API_KEY";
      };

      # Not called through the gateway; listed so the dashboard's health row
      # shows them next to the chat server.
      mimir-embed-notes.health = "http://${mimir}:8081/health";
      mimir-embed-query.health = "http://${mimir}:8082/health";
      mimir-voice.health = "http://${mimir}:8000/health";
    };

    # Names here are what a client sends as "model". Local names must match the
    # sections of the preset in mimir's llm.nix.
    models = {
      "qwen3.5-9b" = {
        target = "mimir-chat";
        tier = "efficient";
        max_prompt_chars = 40000;   # about 12k tokens: fits its 16k-token slot with room for the answer
      };
      "qwen3.8-27b" = { target = "mimir-chat"; tier = "capable"; };
      "minimax/minimax-m3" = { target = "openrouter"; tier = "capable"; };
    };

    # "auto": the local model first; MiniMax when the request is too long for
    # it, or mimir is down or fails. Only callers on heimdall itself (or with a
    # client key) are ever sent to MiniMax, since that one costs money.
    routes.auto.models = [ "qwen3.5-9b" "minimax/minimax-m3" ];
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
      # Both optional ("-"): without the first, the openrouter target is off;
      # the second may set AIGW_CLIENT_KEYS=key1,key2 to let other hosts use it.
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

  # LAN only (ens18): not the VPN or Tailscale interfaces.
  networking.firewall.interfaces.ens18.allowedTCPPorts = [ port ];
}
