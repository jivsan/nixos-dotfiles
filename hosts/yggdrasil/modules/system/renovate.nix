{ pkgs, pkgs-unstable, lib, ... }:

# renovate opens pull requests on git.oryxserver.org when a pinned image or a flake input is behind.
# its rules are in .forgejo/renovate.json. it never merges and can't push to main (branch protection)
{
  systemd.services.renovate.path = lib.mkBefore [ pkgs-unstable.git ];
  services.renovate = {
    enable = true;
    schedule = "*-*-* 00/3:20:00";
    credentials.RENOVATE_TOKEN = "/var/lib/secrets/renovate-token";   # the renovate user's forgejo token
    runtimePackages = [ pkgs.nix ];                                    # flake.lock updates
    settings = {
      platform = "forgejo";
      endpoint = "https://git.oryxserver.org/api/v1/";
      gitAuthor = "renovate <renovate@oryxserver.org>";
      repositories = [ "jivsan/nixos-dotfiles" "jivsan/modgud-vps-nix" "jivsan/talos-helheim" "jivsan/wowsims-image" ];
      onboarding = false;
      requireConfig = "required";
      persistRepoData = true;
      repositoryCache = "enabled";
      configFileNames = [ ".forgejo/renovate.json" ];   # 44.79 leaves .forgejo/ out when it checks a repo has a config
      internalHostAccess = "block";                     # no lan addresses, except forgejo itself
      hostRules = [ { matchHost = "git.oryxserver.org"; allowInternal = true; } ];
      # forgejo's registry wants a login for everything (REQUIRE_SIGNIN_VIEW), also to list the tags of
      # my own images (wowsims-image). the forgejo token above is for the api, to renovate the registry
      # is a docker host: it makes that login from the RENOVATE_DOCKER_GIT_ORYXSERVER_ORG_* lines below
      detectHostRulesFromEnv = true;
    };
    environment.RENOVATE_DOCKER_GIT_ORYXSERVER_ORG_USERNAME = "jivsan";
  };

  # the registry login's password: a token of mine for renovate alone that can only read packages
  # (forgejo, settings, applications: name renovate-registry, package: read, nothing else), root 0600
  # and never in git. on yggdrasil:
  #   read -rsp 'token: ' t; echo; printf 'RENOVATE_DOCKER_GIT_ORYXSERVER_ORG_PASSWORD=%s\n' "$t" | sudo install -m 0600 /dev/stdin /var/lib/secrets/renovate-registry.env; unset t
  # a file and not a credential like RENOVATE_TOKEN: the - lets renovate run without it, it then only
  # can't see my images
  systemd.services.renovate.serviceConfig.EnvironmentFile = "-/var/lib/secrets/renovate-registry.env";
}
