{ ... }:
{
  services.open-webui = {
    enable = true;

    # Listen on all interfaces so Traefik on heimdall can route
    # e.g. chat.oryxserver.org -> mimir:3004 (mirrors the old openwebui route).
    host = "0.0.0.0";
    port = 3004;

    environment = {
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";   # local Ollama (ollama.nix)
      WEBUI_AUTH = "True";
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
    };
  };

  networking.firewall.allowedTCPPorts = [ 3004 ];
}
