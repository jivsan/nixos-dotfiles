{ lib, pkgs, ... }:

# the forgejo actions runners for git.oryxserver.org (yggdrasil). jobs from .forgejo/workflows run as a
# plain user straight on this box: they build the hosts and upload the result to the nix cache.
# one runner per repo, each registered with its own token, so a token only reaches its own repo.
# ci has its own nix store on brunnr, with its temp files and caches. only the build folders are on the
# boot disk (nvme): unpacking and compiling is lots of small files, slow on the spinning disks, and nix
# deletes each folder when its build ends
let
  ci = "/srv/ci-store";
  builds = "/var/lib/ci-builds";   # on the nvme: nix unpacks and compiles here, the result goes into ci's store
  gib = n: toString (n * 1024 * 1024 * 1024);

  # runner -> its token file (TOKEN=<registration token>, root 0600)
  runners = {
    mimir = "/var/lib/secrets/forgejo-runner-token";                    # jivsan/nixos-dotfiles
    modgud = "/var/lib/secrets/forgejo-runner-token-modgud-vps-nix";
    helheim = "/var/lib/secrets/forgejo-runner-token-talos-helheim";
  };
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
    instances = lib.mapAttrs (name: tokenFile: {
      enable = true;
      name = if name == "mimir" then "mimir" else "mimir-${name}";
      url = "https://git.oryxserver.org";
      inherit tokenFile;
      labels = [ "nixos:host" ];
      hostPackages = with pkgs; [ bash coreutils findutils gnugrep gnused gitMinimal nix ];
      settings = {
        runner.capacity = 1;
        runner.timeout = "6h";
        runner.envs = {
          # brunnr/ci-store has a 300G quota: nix cleans it when less than 60G is free, down to 120G free
          NIX_CONFIG = "store = ${ci}\nmin-free = ${gib 60}\nmax-free = ${gib 120}\nbuild-dir = ${builds}";
          TMPDIR = "${ci}/tmp";
          XDG_CACHE_HOME = "${ci}/cache";
        };
        cache.enabled = false;
      };
    }) runners;
  };

  systemd.services = lib.mapAttrs' (name: _: lib.nameValuePair "gitea-runner-${name}" {
    unitConfig.RequiresMountsFor = [ ci ];
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      PrivateTmp = true;
      ReadWritePaths = [ ci builds ];
      ExecStartPre = [
        "+${pkgs.coreutils}/bin/install -d -o gitea-runner -g gitea-runner ${ci} ${ci}/tmp ${ci}/cache"
        "+${pkgs.coreutils}/bin/install -d -m 0700 -o gitea-runner -g gitea-runner ${builds}"
      ];
      # idle priority, so comfyui, the llms and octane keep the box
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
    };
  }) runners;

  # leftovers from cancelled jobs (a new push cancels the old run) go after 2 days.
  # jobs time out after 6h, so a running build is never touched
  systemd.tmpfiles.rules = [ "d ${builds} 0700 gitea-runner gitea-runner 2d" ];

  nix.settings = {
    max-jobs = 4;
    cores = 8;
  };
}
