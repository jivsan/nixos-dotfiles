{ pkgs, lib, ... }:

# `mimir-blender <blender arguments>`: runs Blender on mimir instead of here. For agents'
# checks (dry runs, test scenes, bakes, look pictures) while Christina works in her own
# Blender on mjolnir, so mjolnir's RAM and card stay hers. Skill `mimir-test-node`.
#
# Paths are the same on every host (/mnt/studio, /mnt/studio-cache and the
# /mnt/data_ssd/<folder> links), so a .blend or script path works as it is. A file given
# from a path mimir cannot see (a scratchpad in /tmp) is copied into the job folder
# first. Every run gets its own folder /mnt/studio-cache/jobs/<time>-<host>-<pid>, which
# Blender sees as $MIMIR_JOB_DIR: write results there. Memory cap 12G, or
# MIMIR_BLENDER_MEM=20G. Octane is not installed on mimir's Blender: Octane renders stay
# in her Blender (the one licence seat is on mjolnir).
#
# The arguments go to mimir's `blender-job` NUL-separated on stdin, never on the SSH
# command line, so hermes' key there can be locked to that one command.
let
  # Paths mimir sees as they are: the studio, its cache, and only the moved data SSD
  # folders (the rest of mjolnir's data SSD, e.g. DF BETA, is not on mimir).
  sharedPatterns = lib.concatStringsSep "|" (
    [ "/mnt/studio/*" "/mnt/studio-cache/*" ]
    ++ map (d: "${lib.escapeShellArg "/mnt/data_ssd/${d}/"}*") (import ../system/studio-folders.nix)
  );

  mimir-blender = pkgs.writeShellApplication {
    name = "mimir-blender";
    runtimeInputs = with pkgs; [ openssh coreutils hostname ];
    text = ''
      if [ $# -eq 0 ]; then
        echo "usage: mimir-blender <blender arguments>   (e.g. -b --factory-startup file.blend --python check.py)" >&2
        exit 1
      fi
      mem="''${MIMIR_BLENDER_MEM:-12G}"
      if ! [[ "$mem" =~ ^[0-9]+[KMG]$ ]]; then
        echo "mimir-blender: MIMIR_BLENDER_MEM must look like 12G" >&2
        exit 1
      fi

      job="$(date +%Y%m%d-%H%M%S)-$(hostname)-$$"
      dir="/mnt/studio-cache/jobs/$job"
      mkdir -p "$dir"

      shared() { case "$1" in ${sharedPatterns}) return 0;; *) return 1;; esac; }

      # A local file mimir cannot see is copied in; two with the same name both stay.
      args=()
      n=0
      for a in "$@"; do
        if [ -f "$a" ] && ! shared "$(realpath "$a")"; then
          b="$(basename "$a")"
          if [ -e "$dir/$b" ]; then n=$((n + 1)); b="$n-$b"; fi
          cp "$a" "$dir/$b"
          args+=("$dir/$b")
        else
          args+=("$a")
        fi
      done

      # Work in the same folder on mimir when it is shared, else in the job folder.
      cwd="$dir"
      if shared "$(realpath .)/"; then cwd="$(realpath .)"; fi

      # hermes (on yggdrasil) has only its locked-down key; everyone else logs in as usual.
      opts=(-o BatchMode=yes -o ConnectTimeout=10)
      if [ "$(id -un)" = hermes ]; then
        opts+=(-o IdentitiesOnly=yes -i /var/lib/hermes-ssh/id_ed25519)
      fi

      echo "mimir-blender: job folder $dir" >&2
      status=0
      printf '%s\0' "$dir" "$cwd" "$mem" "''${args[@]}" |
        ssh "''${opts[@]}" christina@10.0.20.18 blender-job || status=$?
      case "$status" in
        137) echo "mimir-blender: killed at the memory cap ($mem); try MIMIR_BLENDER_MEM=20G" >&2 ;;
        255) echo "mimir-blender: lost the connection to mimir, or the job was stopped" >&2
             rmdir "$dir" 2>/dev/null || true ;;
      esac
      echo "mimir-blender: done (exit $status), results in $dir" >&2
      exit "$status"
    '';
  };
in
{
  environment.systemPackages = [ mimir-blender ];

  programs.ssh.knownHosts."10.0.20.18".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIInOzImfbcqOdQt9fVmX1rYWH9lebyT/HTvNna0WO25P";
}
