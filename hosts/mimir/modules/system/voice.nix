{ pkgs, ... }:
let
  # keep in sync with MUNINN_STT_MODEL / MUNINN_TTS_MODEL in heimdall's bridge.py
  models = [ "Systran/faster-whisper-small" "speaches-ai/Kokoro-82M-v1.0-ONNX" ];
in
{
  # voice for the muninn brain: whisper + kokoro behind one openai-style api (speaches).
  # only heimdall's bridge calls :8000, so no audio leaves the lan
  # cpu image. for the card: tag latest-cuda + extraOptions = [ "--device=nvidia.com/gpu=all" ];
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

  # the image has no models: ask the server for them once it's up (safe to repeat)
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
