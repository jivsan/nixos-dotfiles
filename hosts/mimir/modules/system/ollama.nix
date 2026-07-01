{ pkgs, ... }:
{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;   # NVIDIA GPU build (replaces the removed `acceleration` option)

    # Bound to localhost — Open-WebUI (same box) talks to it here.
    # To let other hosts hit Ollama directly, set host = "0.0.0.0" and open
    # 11434 on the firewall. NOTE: Ollama has NO auth, so only expose it on
    # trusted VLAN 20 (or front it with Traefik + auth on heimdall).
    host = "127.0.0.1";
    port = 11434;

    # Pull models declaratively if you like, e.g.:
    # loadModels = [ "llama3.2" "qwen2.5-coder" ];
  };
}
