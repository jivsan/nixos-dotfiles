{ pkgs, ... }:

# mimir as the agents' Blender test node: `mimir-blender` on mjolnir and yggdrasil
# (modules/apps/mimir-blender.nix) ssh in here and run `blender-job`. Same Blender build
# as mjolnir (modules/apps/blender.nix), the studio at the same paths (studio.nix), her
# add-ons copied from mjolnir without Octane and the MCP extension
# (`blender-config-to-mimir` on mjolnir). Skill `mimir-test-node`.
let
  blender-job = pkgs.writeShellApplication {
    name = "blender-job";
    runtimeInputs = with pkgs; [ coreutils systemd ];
    text = ''
      # Everything comes NUL-separated on stdin: job folder, working folder, memory cap,
      # then Blender's arguments. Nothing from the SSH command line is run.
      mapfile -d "" -t a
      if [ "''${#a[@]}" -lt 3 ]; then
        echo "blender-job: send job folder, working folder, memory cap and Blender's arguments on stdin (mimir-blender does)" >&2
        exit 2
      fi
      dir=''${a[0]} cwd=''${a[1]} mem=''${a[2]}
      if ! [[ "$dir" =~ ^/mnt/studio-cache/jobs/[A-Za-z0-9._-]+$ ]] || [[ "$dir" == *..* ]]; then
        echo "blender-job: the job folder must be /mnt/studio-cache/jobs/<name>" >&2
        exit 2
      fi
      if ! [[ "$mem" =~ ^[0-9]+[KMG]$ ]]; then
        echo "blender-job: memory cap must look like 12G" >&2
        exit 2
      fi
      mkdir -p "$dir"
      cd "$cwd" 2>/dev/null || cd "$dir"
      # Its own scope with a memory cap: a runaway check is killed alone, and the
      # embedding and voice servers the muninn brain uses keep their RAM. Stop a run
      # with `systemctl --user stop mimir-job-<name>.scope`.
      exec systemd-run --user --scope --quiet --expand-environment=no --unit="mimir-job-''${dir##*/}" \
        -p MemoryMax="$mem" -p MemorySwapMax=0 --nice=5 \
        env MIMIR_JOB_DIR="$dir" /run/current-system/sw/bin/blender "''${a[@]:3}" </dev/null
    '';
  };
in
{
  imports = [ ../../../../modules/apps/blender.nix ];

  environment.systemPackages = [ blender-job ];

  users.users.christina.openssh.authorizedKeys.keys = [
    # christina on yggdrasil (the key was made on hermod): Claude Code there.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJqRu0/cwcMKm5+Rxm8jx8GfpaqCtPieqGaxetVH8Prj hermod"
    # hermes on yggdrasil: only blender-job. (Blender runs Python, so this is code on
    # mimir all the same; the lock keeps the key from being a plain login.)
    ''restrict,command="${blender-job}/bin/blender-job" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEAh74ChiC+JFYRzamn8iwVW03txv1S8HgkDxUvOqCXb hermes-mcp@hermod''
  ];
}
