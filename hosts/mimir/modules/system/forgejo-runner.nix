{ lib, pkgs, ... }:

# the forgejo actions runner for git.oryxserver.org (yggdrasil). jobs from .forgejo/workflows run as a
# plain user straight on this box: they build every host and upload the result to the nix cache.
# ci has its own nix store on brunnr, with its temp files and caches, so none of it lands on the boot disk
let
  ci = "/srv/ci-store";
  gib = n: toString (n * 1024 * 1024 * 1024);
in
{
  fileSystems.${ci} = {
    device = "brunnr/ci-store";
    fsType = "zfs";
    options = [ "nofail" ];
  };

  # a fixed user instead of a dynamic one, so the files in ci's store keep their owner
  users.users.gitea-runner = {
    isSystemUser = true;
    group = "gitea-runner";
  };
  users.groups.gitea-runner = { };

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
        runner.envs = {
          # brunnr/ci-store has a 300G quota: nix cleans it when less than 60G is free, down to 120G free
          NIX_CONFIG = "store = ${ci}\nmin-free = ${gib 60}\nmax-free = ${gib 120}";
          TMPDIR = "${ci}/tmp";
          XDG_CACHE_HOME = "${ci}/cache";
        };
        cache.enabled = false;
      };
    };
  };

  systemd.services.gitea-runner-mimir = {
    unitConfig.RequiresMountsFor = [ ci ];
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      PrivateTmp = true;
      ReadWritePaths = [ ci ];
      ExecStartPre = [ "+${pkgs.coreutils}/bin/install -d -o gitea-runner -g gitea-runner ${ci} ${ci}/tmp ${ci}/cache" ];
      # idle priority, so comfyui, the llms and octane keep the box
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
    };
  };

  nix.settings = {
    max-jobs = 4;
    cores = 8;
  };
}
