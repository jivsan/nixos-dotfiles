{ pkgs, utils, ... }:
let
  port = 8080;
  models = "/var/lib/llama-chat/models";

  # a section's name is the model's name on the api, it must match `models` in heimdall's
  # ai-gateway.nix. ctx-size is shared by the slots: 32768 over 2 slots is 16k each
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
    "--models-max" "1"   # one chat model in vram at a time
  ];
in
{
  # chat models for heimdall's ai-gateway, llama-server in router mode (swaps models on demand)
  # not imported: needs a 16 gb card, mimir's 4060 ti has 8 gb shared with comfyui and octane
  # only call it through the gateway (http://10.0.20.17:4000/v1): a direct request for the
  # unloaded model kills the running one. nothing scrapes its /metrics, that loads a model too
  # model files aren't in the store, download them once (docs/misc/ai-gateway.md)
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
