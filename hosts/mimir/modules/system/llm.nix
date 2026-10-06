{ pkgs, utils, ... }:
let
  port = 8080;
  models = "/var/lib/llama-chat/models";

  # One section per model; the section name is the model's name on the API and
  # must match `models` in heimdall's ai-gateway.nix. Picked from the vault note
  # "Local LLM recommendation for RTX 5070 Ti 16GB" (2026-10-04): the 9B as the
  # everyday model, the 27B for hard jobs. Neither is measured on the card yet.
  # ctx-size is shared by the slots: 32768 over 2 slots is 16k tokens each.
  preset = pkgs.writeText "llama-chat-models.ini" ''
    [qwen3.5-9b]
    model = ${models}/Qwen3.5-9B-Q6_K.gguf
    ctx-size = 32768
    parallel = 2
    n-gpu-layers = 99

    [qwen3.8-27b]
    model = ${models}/Qwen3.8-27B-UD-IQ4_XS.gguf
    ctx-size = 8192
    parallel = 1
    n-gpu-layers = 99
  '';

  flags = [
    "--host" "0.0.0.0" "--port" (toString port)
    "--models-preset" preset
    "--models-max" "1"   # 16 GB of VRAM: one chat model loaded at a time
  ];
in
{
  # Chat models for the ai-gateway on heimdall: llama-server in router mode,
  # which loads a model when it is first asked for and swaps it out for the
  # other one on demand. Needs the RTX 5070 Ti; import this once it is in.
  #
  # Talk to it through the gateway (http://10.0.20.17:4000/v1), not directly:
  # a direct request for the model that is not loaded makes llama-server kill
  # whatever the loaded one is generating, and it is not counted on the
  # dashboard. For the same reason nothing scrapes this server's own /metrics:
  # that call loads the model it asks about.
  #
  # The model files are not in the Nix store. Download them once (runbook:
  # docs/misc/ai-gateway.md) into /var/lib/llama-chat/models.
  systemd.tmpfiles.rules = [
    "d ${models} 0755 root root -"
  ];

  systemd.services.llama-chat = {
    description = "llama.cpp: chat models for the ai-gateway";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.llama-cpp.override { cudaSupport = true; }}/bin/llama-server ${utils.escapeSystemdExecArgs flags}";
      DynamicUser = true;
      CacheDirectory = "llama-chat";
      Environment = [ "LLAMA_CACHE=/var/cache/llama-chat" ];
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # reachable from heimdall over VLAN 20
  networking.firewall.allowedTCPPorts = [ port ];
}
