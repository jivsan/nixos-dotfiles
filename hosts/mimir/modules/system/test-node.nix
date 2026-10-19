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
      # Only mimir-blender's request: scp, sftp or any other command through hermes' key
      # gets a clear no instead of hanging.
      if [ -n "''${SSH_ORIGINAL_COMMAND:-}" ] && [ "$SSH_ORIGINAL_COMMAND" != blender-job ]; then
        echo "blender-job: this key only runs Blender jobs sent by mimir-blender" >&2
        exit 2
      fi
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
      # 256M to 24G: mimir has 31 GB, and the brain's servers need theirs.
      if ! [[ "$mem" =~ ^([0-9]{1,8})([KMG])$ ]]; then
        echo "blender-job: memory cap must look like 12G" >&2
        exit 2
      fi
      n=$((10#''${BASH_REMATCH[1]}))
      case "''${BASH_REMATCH[2]}" in K) mib=$((n / 1024)) ;; M) mib=$n ;; G) mib=$((n * 1024)) ;; esac
      if [ "$mib" -lt 256 ] || [ "$mib" -gt 24576 ]; then
        echo "blender-job: memory cap must be between 256M and 24G" >&2
        exit 2
      fi
      mkdir -p "$dir"
      cd "$cwd" 2>/dev/null || cd "$dir"
      # Its own scope with a memory cap: a runaway check is killed alone, and the
      # embedding and voice servers the muninn brain uses keep their RAM. Stop a run
      # with `systemctl --user stop mimir-job-<name>.scope`. Output line by line, so a
      # long run shows its progress over ssh.
      unit="mimir-job-''${dir##*/}"
      status=0
      systemd-run --user --scope --quiet --expand-environment=no --unit="$unit" \
        -p MemoryMax="$mem" -p MemorySwapMax=0 --nice=5 \
        env MIMIR_JOB_DIR="$dir" PYTHONUNBUFFERED=1 \
        stdbuf -oL -eL /run/current-system/sw/bin/blender "''${a[@]:3}" </dev/null || status=$?

      # Say why it ended when Blender did not end by itself, then clear the failed unit
      # so it does not stay in `systemctl --user --failed`.
      result=""
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        state="$(systemctl --user show -p ActiveState --value "$unit" 2>/dev/null || true)"
        case "$state" in active | activating | deactivating) sleep 0.2 ;; *) break ;; esac
      done
      result="$(systemctl --user show -p Result --value "$unit" 2>/dev/null || true)"
      systemctl --user reset-failed "$unit" 2>/dev/null || true
      if [ "$result" = oom-kill ]; then
        echo "blender-job: Blender reached the memory cap of $mem and was killed" >&2
        exit 137
      fi
      if [ "$status" -gt 128 ]; then
        echo "blender-job: Blender was ended by signal $((status - 128))" >&2
      fi
      exit "$status"
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
