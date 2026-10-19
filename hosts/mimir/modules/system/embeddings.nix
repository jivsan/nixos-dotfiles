{ config, pkgs, utils, ... }:
let
  # pinned to a revision: another file gives vectors that don't compare with the stored
  # ones, and a new model name makes heimdall's embedder re-embed the whole vault
  model = pkgs.fetchurl {
    url = "https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF/resolve/f4602530db1d980e16da9d7d3a70294cf5c190be/Qwen3-Embedding-4B-Q8_0.gguf";
    hash = "sha256-tgrlzi3WoLd/gsrfId7x8xCj4QzeOArQCBsHqdQWlJ0=";
  };
  notesPort = 8081;   # heimdall's embedder: one vector per note
  queryPort = 8082;   # heimdall's bridge: one vector per question
  common = [
    "--embedding"
    "--pooling" "last"            # Qwen3 puts the meaning in the last token
    "--alias" "Qwen3-Embedding-4B-Q8_0"   # keep in sync with MUNINN_EMBED_MODEL in heimdall's embed.py
    "--parallel" "1"
  ];
  # an input is embedded in one pass, so it must fit the batch
  window = n: [ "--ctx-size" (toString n) "--batch-size" (toString n) "--ubatch-size" (toString n) ];
  queryFlags = [ "--host" "0.0.0.0" "--port" (toString queryPort) "-m" model ]
    ++ common ++ window 2048 ++ [ "--threads" "8" ];
  # the first request pages the model in (25 s under load), so pay that here,
  # not on the first question
  warmUp = pkgs.writeShellScript "llama-cpp-query-warm-up" ''
    for _ in $(${pkgs.coreutils}/bin/seq 1 40); do
      ${pkgs.curl}/bin/curl -fsS -m 2 http://127.0.0.1:${toString queryPort}/health >/dev/null 2>&1 && break
      ${pkgs.coreutils}/bin/sleep 1
    done
    ${pkgs.curl}/bin/curl -fsS -m 45 http://127.0.0.1:${toString queryPort}/v1/embeddings \
      -H 'Content-Type: application/json' -d '{"model":"warm-up","input":"warm up"}' >/dev/null 2>&1 || true
  '';
in
{
  # embeddings for vault search and note placement, only heimdall calls /v1/embeddings here
  # on cpu: a question ~0.5 s, a 4,000-char note ~25 s. to put it on the card (8 gb, shared
  # with comfyui and the octane node):
  #   package = pkgs.llama-cpp.override { cudaSupport = true; };  extraFlags ++ [ "-ngl" "99" ]
  services.llama-cpp = {
    enable = true;
    inherit model;
    host = "0.0.0.0";
    port = notesPort;
    extraFlags = common ++ window 8192 ++ [ "--threads" "16" ];   # the physical cores
  };

  # second instance for questions only: llama-server runs all slots in one pass, so a
  # question sent above waits for the note being embedded (17-30 s there, 0.5 s here).
  # both map the same model file, so the weights are in memory once
  systemd.services.llama-cpp-query = {
    description = "LLaMA C++ server: question embeddings for the muninn bridge";
    inherit (config.systemd.services.llama-cpp) after wantedBy;
    serviceConfig = config.systemd.services.llama-cpp.serviceConfig // {
      StateDirectory = "llama-cpp-query";
      CacheDirectory = "llama-cpp-query";
      WorkingDirectory = "/var/lib/llama-cpp-query";
      Environment = [ "LLAMA_CACHE=/var/cache/llama-cpp-query" ];
      ExecStart = "${config.services.llama-cpp.package}/bin/llama-server ${utils.escapeSystemdExecArgs queryFlags}";
      ExecStartPost = warmUp;
    };
  };

  # reachable from heimdall over VLAN 20
  networking.firewall.allowedTCPPorts = [ notesPort queryPort ];
}
