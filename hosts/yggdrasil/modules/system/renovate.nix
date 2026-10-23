{ pkgs, ... }:

# renovate opens pull requests on git.oryxserver.org when a pinned image or a flake input is behind.
# its rules are in .forgejo/renovate.json. it never merges and can't push to main (branch protection)
{
  services.renovate = {
    enable = true;
    schedule = "*-*-* 00/3:20:00";
    credentials.RENOVATE_TOKEN = "/var/lib/secrets/renovate-token";   # the renovate user's forgejo token
    runtimePackages = [ pkgs.nix ];                                    # flake.lock updates
    settings = {
      platform = "forgejo";
      endpoint = "https://git.oryxserver.org/api/v1/";
      gitAuthor = "renovate <renovate@oryxserver.org>";
      repositories = [ "jivsan/nixos-dotfiles" "jivsan/modgud-vps-nix" ];
      onboarding = false;
      requireConfig = "required";
      persistRepoData = true;
      repositoryCache = "enabled";
      configFileNames = [ ".forgejo/renovate.json" ];   # 44.79 leaves .forgejo/ out when it checks a repo has a config
      internalHostAccess = "block";                     # no lan addresses, except forgejo itself
      hostRules = [ { matchHost = "git.oryxserver.org"; allowInternal = true; } ];
    };
  };
}
