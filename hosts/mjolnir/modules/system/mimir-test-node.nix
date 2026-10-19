{ pkgs, ... }:

# `blender-config-to-mimir`: copies my blender 5.2 config to mimir, the agents' test node, so checks
# there open my files like my blender does. octane (one licence seat, here) and the mcp
# extension (for my live blender) stay behind. run again after adding or updating an add-on
let
  blender-config-to-mimir = pkgs.writeShellApplication {
    name = "blender-config-to-mimir";
    runtimeInputs = with pkgs; [ rsync openssh ];
    text = ''
      # --bwlimit: mjolnir's X540 froze the machine once under a long full-speed copy.
      rsync -a --info=stats1 --bwlimit=150M \
        --exclude='/scripts/addons/octane' \
        --exclude='/extensions/user_default/mcp' \
        --exclude='__pycache__/' \
        "$HOME/.config/blender/5.2/" christina@10.0.20.18:.config/blender/5.2/
      # Her Octane add-on is a link to /opt/octane (the excludes have no trailing slash,
      # so they match links too); this is the second guard.
      ssh christina@10.0.20.18 rm -f .config/blender/5.2/scripts/addons/octane
    '';
  };
in
{
  environment.systemPackages = [ blender-config-to-mimir ];
}
