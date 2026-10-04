{ config, pkgs, utils, ... }:
let
  # Qwen3-Embedding-4B, 8-bit. Chosen 2026-10-04 as the strongest open English
  # embedding model this box can serve (MTEB English v2: 74.6 overall, 68.5
  # retrieval; Apache 2.0; reads 32K tokens). Pinned to a revision: a different
  # file would give vectors that cannot be compared with the stored ones, and
  # heimdall's embedder re-embeds the whole vault when the model name changes.
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
  # The first request to a fresh instance pages the model in (25 s under load):
  # spend that here, not on the first question.
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
  # Embeddings for the muninn vault: meaning-based search and note placement.
  # heimdall calls the OpenAI-style /v1/embeddings here; nothing else does.
  #
  # CPU for now, like the voice server: measured on the 5950X, a question takes
  # about 0.5 s and a 4,000-character note about 25 s. When the RTX 5070 Ti is
  # in, use a CUDA build and offload the layers:
  #   package = pkgs.llama-cpp.override { cudaSupport = true; };  extraFlags ++ [ "-ngl" "99" ]
  services.llama-cpp = {
    enable = true;
    inherit model;
    host = "0.0.0.0";
    port = notesPort;
    extraFlags = common ++ window 8192 ++ [ "--threads" "16" ];   # the physical cores
  };

  # A second instance of the same model, for questions only. llama-server runs
  # all slots of one instance in the same pass, so a question sent to the
  # instance above waits for whatever note it is embedding: measured 17-30 s
  # there, 0.5 s here while the other one was busy. Both map the same model
  # file, so the weights are in memory once.
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
