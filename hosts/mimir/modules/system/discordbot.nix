{ pkgs, ... }:
let
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    discordpy
    aiohttp
    python-dotenv
    pillow
  ]);
in
{
  # Discord image bot — talks to the ComfyUI container on localhost:8188.
  # Code is rsynced from mjolnir by the repo's deploy.sh (git is the source
  # of truth; /var/lib/discordbot/app is just the deployment target).
  # Secrets: /var/lib/discordbot/.env  (DISCORD_TOKEN, COMFYUI_URL) — never in git.

  users.users.discordbot = {
    isSystemUser = true;
    group = "discordbot";
    home = "/var/lib/discordbot";
  };
  users.groups.discordbot = { };

  systemd.tmpfiles.rules = [
    "d /var/lib/discordbot      0750 discordbot discordbot -"
    "d /var/lib/discordbot/app  0755 discordbot discordbot -"
  ];

  systemd.services.discordbot = {
    description = "Discord image bot (ComfyUI backend on localhost)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "podman-comfyui.service" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      User = "discordbot";
      Group = "discordbot";
      WorkingDirectory = "/var/lib/discordbot/app";
      EnvironmentFile = "/var/lib/discordbot/.env";
      ExecStart = "${pythonEnv}/bin/python bot.py";
      Restart = "on-failure";
      RestartSec = 10;

      # hardening — the bot needs nothing but its own state dir + network
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/discordbot" ];
    };
  };
}
