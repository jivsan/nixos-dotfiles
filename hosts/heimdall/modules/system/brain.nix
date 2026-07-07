{ pkgs, ... }:
# ── muninn brain — live animated knowledge-graph frontend ────────────────────
# A builder regenerates graph.json + activity.json from the vault every 30s
# (fast, no LLM), nginx serves the single-page 3D force-graph app on localhost,
# and Traefik exposes it at brain.oryxserver.org (behind lan-only).
let
  vault = "/mnt/nas/obsidian/muninn";
  www   = "/var/lib/muninn-brain/www";

  buildGraph = pkgs.writeShellApplication {
    name = "muninn-brain-build";
    # git + systemctl: activity.json includes the vault audit log and huginn
    # timer/service health
    runtimeInputs = [ pkgs.python3Minimal pkgs.coreutils pkgs.git pkgs.systemd ];
    text = ''python3 ${../../muninn/brain/build-graph.py}'';
  };
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/muninn-brain 0755 christina users -"
    "d ${www} 0755 christina users -"
    # index.html is served from the store; refreshed on each rebuild
    "L+ ${www}/index.html - - - - ${../../muninn/brain/index.html}"
  ];

  # regenerate the graph data from the vault, on a fast cadence for a "live" feel
  systemd.services."muninn-brain-build" = {
    description = "muninn brain: rebuild graph.json + activity.json from the vault";
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = {
      Type = "oneshot";
      User = "christina";
      Group = "users";
      ExecStart = "${buildGraph}/bin/muninn-brain-build";
    };
  };
  systemd.timers."muninn-brain-build" = {
    description = "muninn brain build cadence";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30s";
    };
  };

  # static server on localhost; Traefik fronts it (see traefik.nix → brain router)
  services.nginx = {
    enable = true;
    virtualHosts."muninn-brain" = {
      listen = [ { addr = "127.0.0.1"; port = 8090; } ];
      root = www;
      locations."/".index = "index.html";
      locations."~ \\.json$".extraConfig = "add_header Cache-Control no-store;";
    };
  };
}
