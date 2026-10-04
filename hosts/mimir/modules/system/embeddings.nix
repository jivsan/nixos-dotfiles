{ pkgs, ... }:
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
  port = 8081;
in
{
  # Embeddings for the muninn vault: meaning-based search and note placement.
  # heimdall's embedder (one vector per note) and bridge (one per question) call
  # the OpenAI-style /v1/embeddings here; nothing else talks to it.
  #
  # CPU for now, like the voice server: measured on the 5950X, a question takes
  # about 0.3 s and a 4,000-character note about 25 s. When the RTX 5070 Ti is
  # in, use a CUDA build and offload the layers:
  #   package = pkgs.llama-cpp.override { cudaSupport = true; };  extraFlags ++ [ "-ngl" "99" ]
  services.llama-cpp = {
    enable = true;
    inherit model port;
    host = "0.0.0.0";
    extraFlags = [
      "--embedding"
      "--pooling" "last"            # Qwen3 puts the meaning in the last token
      "--alias" "Qwen3-Embedding-4B-Q8_0"   # keep in sync with MUNINN_EMBED_MODEL in heimdall's embed.py
      # two slots of 8,192 tokens: a question is not stuck behind a long note
      "--parallel" "2"
      "--ctx-size" "16384"
      "--batch-size" "8192"
      "--ubatch-size" "8192"        # an input is embedded in one pass, so it must fit the batch
      "--threads" "16"              # the physical cores
    ];
  };

  # reachable from heimdall over VLAN 20
  networking.firewall.allowedTCPPorts = [ port ];
}
