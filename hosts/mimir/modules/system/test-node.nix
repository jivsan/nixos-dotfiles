{ pkgs, ... }:

# mimir as the agents' Blender test node: `mimir-blender` on mjolnir and yggdrasil
# (modules/apps/mimir-blender.nix) ssh in here and run `blender-job`. Same Blender build
# as mjolnir (modules/apps/blender.nix), the studio at the same paths (studio.nix), her
# add-ons copied from mjolnir without Octane and the MCP extension
# (`blender-config-to-mimir` on mjolnir).
let
  blender-job = pkgs.writeShellApplication {
    name = "blender-job";
    runtimeInputs = with pkgs; [ coreutils systemd ];
    text = ''
      # blender-job <job folder> <working folder> <memory cap> <blender arguments...>
      dir=$1 cwd=$2 mem=$3
      shift 3
      cd "$cwd" 2>/dev/null || cd "$dir"
      # Its own scope with a memory cap: a runaway check is killed alone, and the
      # embedding and voice servers the muninn brain uses keep their RAM.
      exec systemd-run --user --scope --quiet -p MemoryMax="$mem" -p MemorySwapMax=0 --nice=5 \
        env MIMIR_JOB_DIR="$dir" /run/current-system/sw/bin/blender "$@"
    '';
  };
in
{
  imports = [ ../../../../modules/apps/blender.nix ];

  environment.systemPackages = [ blender-job ];

  # christina on yggdrasil (the key was made on hermod), for mimir-blender there.
  users.users.christina.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJqRu0/cwcMKm5+Rxm8jx8GfpaqCtPieqGaxetVH8Prj hermod"
  ];
}
