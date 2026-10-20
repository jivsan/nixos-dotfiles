{ lib, pkgs, ... }:

# forgejo: my own git server at git.oryxserver.org (web) and ssh://git@git.oryxserver.org:2222.
# runs here, keeps everything worth keeping on odyn (appdata.nix): repos, lfs, attachments, avatars,
# its ssh host keys, app.ini and the secret keys on the share; issues, users, settings in appdb.
# traefik on heimdall is the only way in. docs/apps-on-odyn.md
let
  data = "/mnt/appdata/forgejo";
in
{
  # the same ids as the odyn user that owns the share, so the files agree on both sides
  users.users.forgejo.uid = 3011;
  users.groups.forgejo.gid = 3011;

  services.forgejo = {
    enable = true;
    package = pkgs.forgejo-lts;                # long-term support line, fewer big upgrades
    stateDir = "/var/lib/forgejo";             # local: logs, queues, issue search index, git's home
    customDir = "${data}/custom";              # app.ini + secret keys (2fa secrets in the db are encrypted with them)
    repositoryRoot = "${data}/repositories";
    lfs = {
      enable = true;
      contentDir = "${data}/lfs";
    };
    database = {
      type = "postgres";
      host = "10.0.20.6";                      # appdb on odyn
      port = 5432;
      name = "forgejo";
      user = "forgejo";
      passwordFile = "/var/lib/secrets/forgejo-db-password";
      createDatabase = false;
    };
    settings = {
      DEFAULT.APP_NAME = "forgejo · oryxserver";
      server = {
        DOMAIN = "git.oryxserver.org";
        ROOT_URL = "https://git.oryxserver.org/";
        HTTP_ADDR = "0.0.0.0";                 # the firewall below lets only heimdall in
        HTTP_PORT = 3000;
        APP_DATA_PATH = "${data}/data";        # attachments, avatars, packages, ssh host keys
        START_SSH_SERVER = true;               # forgejo's own ssh server, not the system's sshd
        SSH_PORT = 2222;                       # what clone urls show (traefik's tcp entrypoint)
        SSH_LISTEN_PORT = 2222;
        SSH_DOMAIN = "git.oryxserver.org";
        OFFLINE_MODE = true;                   # no cdn or gravatar lookups
      };
      database = {
        SSL_MODE = lib.mkForce "require";      # appdb only takes tls from the lan
        MAX_OPEN_CONNS = 20;
        MAX_IDLE_CONNS = 5;
      };
      queue.DATADIR = "/var/lib/forgejo/queues";
      git.HOME_PATH = "/var/lib/forgejo/home";
      session = {
        PROVIDER = "db";                       # logins survive a restart
        COOKIE_SECURE = true;
      };
      service = {
        DISABLE_REGISTRATION = true;           # accounts only by admin; no first-visitor-becomes-admin
        REQUIRE_SIGNIN_VIEW = true;            # nothing visible without logging in
      };
      repository.DEFAULT_PRIVATE = "private";
      picture.DISABLE_GRAVATAR = true;
      actions.ENABLED = false;                 # no runner (yet)
      mailer.ENABLED = false;
      "cron.update_checker".ENABLED = false;
    };
  };

  # odyn boots much slower than this box after a power cut: keep retrying until the share answers
  systemd.services.forgejo = {
    unitConfig.RequiresMountsFor = [ data ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      ReadWritePaths = [ data ];
      RestartSec = "15s";
    };
  };
  systemd.services.forgejo-secrets.unitConfig.RequiresMountsFor = [ data ];

  environment.systemPackages = [ pkgs.forgejo-lts ];   # `forgejo admin ...` (as user forgejo)

  # web (3000) and ssh (2222) only for traefik on heimdall; everyone else comes through it.
  # extraCommands runs before nixos-fw's final refuse rule (this box has no tailscale to get around it)
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s 10.0.20.17 -m multiport --dports 3000,2222 -j nixos-fw-accept
  '';
}
