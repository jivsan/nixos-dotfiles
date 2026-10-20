{ lib, pkgs, ... }:

# n8n at n8n.oryxserver.org, behind traefik on heimdall. data on odyn: workflows, credentials and
# runs in appdb, the encryption key and stored files on the share. docs/apps-on-odyn.md
let
  data = "/mnt/appdata/n8n";

  # nixpkgs is behind upstream; drop this once pkgs.n8n catches up
  n8n = pkgs.n8n.overrideAttrs (finalAttrs: prev: {
    version = "2.43.8";
    src = pkgs.fetchFromGitHub {
      owner = "n8n-io";
      repo = "n8n";
      tag = "n8n@${finalAttrs.version}";
      hash = "sha256-OiZmRb7d2wkMqFSTf9ngd2quBFA9Kg7CB09INZi3dbA=";
    };
    pnpmDeps = pkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pkgs.pnpm_12;
      fetcherVersion = 4;
      hash = "sha256-4YhMYBw7N02kjPkn3neAKMWnVS0h99VPRHHs7KrcAqU=";
    };
    nativeBuildInputs = map (p: if p == pkgs.pnpm_11 then pkgs.pnpm_12 else p) prev.nativeBuildInputs;
    # pnpm 12 prune re-checks minimumReleaseAge against the registry; fetchPnpmDeps already did
    preInstall = builtins.replaceStrings
      [ "pnpm --ignore-scripts prune" ]
      [ "pnpm --offline --config.minimum-release-age=0 --ignore-scripts prune" ]
      prev.preInstall;
  });
in
{
  users.users.n8n = {
    uid = 3012;
    group = "n8n";
    isSystemUser = true;
  };
  users.groups.n8n.gid = 3012;

  services.n8n = {
    enable = true;
    package = n8n;
    environment = {
      N8N_HOST = "n8n.oryxserver.org";
      N8N_PROTOCOL = "https";
      N8N_EDITOR_BASE_URL = "https://n8n.oryxserver.org/";
      WEBHOOK_URL = "https://n8n.oryxserver.org/";
      N8N_PROXY_HOPS = 1;
      N8N_ENCRYPTION_KEY_FILE = "${data}/encryption-key";
      N8N_STORAGE_PATH = "${data}/storage";
      DB_TYPE = "postgresdb";
      DB_POSTGRESDB_HOST = "10.0.20.6";
      DB_POSTGRESDB_PORT = 5432;
      DB_POSTGRESDB_DATABASE = "n8n";
      DB_POSTGRESDB_USER = "n8n";
      DB_POSTGRESDB_PASSWORD_FILE = "/var/lib/secrets/n8n-db-password";
      DB_POSTGRESDB_SSL_ENABLED = true;
      DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED = false;
    };
  };

  systemd.services.n8n = {
    unitConfig.RequiresMountsFor = [ data ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "n8n";
      Group = "n8n";
      ReadWritePaths = [ data ];
      RestartSec = "15s";
    };
  };

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s 10.0.20.17 --dport 5678 -j nixos-fw-accept
  '';
}
