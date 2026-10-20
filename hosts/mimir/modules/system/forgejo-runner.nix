{ lib, pkgs, ... }:

# the forgejo actions runner for git.oryxserver.org (yggdrasil). jobs from .forgejo/workflows run as a
# plain user straight on this box: they build every host and upload the result to the nix cache
{
  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.mimir = {
      enable = true;
      name = "mimir";
      url = "https://git.oryxserver.org";
      tokenFile = "/var/lib/secrets/forgejo-runner-token";   # TOKEN=<registration token>, root 0600
      labels = [ "nixos:host" ];
      hostPackages = with pkgs; [ bash coreutils findutils gnugrep gnused gitMinimal nix ];
      settings = {
        runner.capacity = 1;
        runner.timeout = "6h";
        cache.enabled = false;
      };
    };
  };

  # builds run at idle priority, a few at a time, so comfyui, the llms and octane keep the box
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
  nix.settings = {
    max-jobs = 4;
    cores = 8;
    # ci leaves every host's system in this box's own store; the copy that counts is on brunnr
    min-free = 100 * 1024 * 1024 * 1024;
    max-free = 150 * 1024 * 1024 * 1024;
  };
  nix.gc.dates = lib.mkForce "daily";
}
