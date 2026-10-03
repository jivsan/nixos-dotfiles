{ pkgs, ... }:
let
  # Keep in sync with MUNINN_STT_MODEL / MUNINN_TTS_MODEL in heimdall's bridge.py.
  models = [ "Systran/faster-whisper-small" "speaches-ai/Kokoro-82M-v1.0-ONNX" ];
in
{
  # Local voice for the muninn brain: Whisper (ears) + Kokoro (mouth) behind one
  # OpenAI-compatible API (Speaches). heimdall's bridge calls it at :8000; the
  # browser never talks to mimir directly, and no audio leaves the LAN.
  #
  # CPU image for now. When the RTX 5070 Ti is in, switch the tag to
  # `latest-cuda` and add:  extraOptions = [ "--device=nvidia.com/gpu=all" ];
  systemd.tmpfiles.rules = [
    "d /var/lib/speaches 0755 1000 1000 -"   # model cache; the container runs as uid 1000
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.speaches = {
    image = "ghcr.io/speaches-ai/speaches:latest-cpu";
    autoStart = true;
    ports = [ "0.0.0.0:8000:8000" ];
    volumes = [ "/var/lib/speaches:/home/ubuntu/.cache/huggingface/hub" ];
  };

  # Models are not bundled: ask the server to download them once it is up.
  # Safe to repeat; an already-installed model returns straight away.
  systemd.services.speaches-models = {
    description = "speaches: download the Whisper and Kokoro models";
    after = [ "podman-speaches.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "podman-speaches.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for i in $(seq 1 60); do
        curl -fsS -m 3 http://127.0.0.1:8000/health >/dev/null && break
        sleep 2
      done
      ${pkgs.lib.concatMapStringsSep "\n" (m: ''
        curl -fsS -m 1800 -X POST "http://127.0.0.1:8000/v1/models/${m}" >/dev/null || echo "could not install ${m}" >&2
      '') models}
    '';
  };

  # reachable from heimdall over VLAN 20
  networking.firewall.allowedTCPPorts = [ 8000 ];
}
