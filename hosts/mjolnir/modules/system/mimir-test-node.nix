{ pkgs, ... }:

# `blender-config-to-mimir`: copies her Blender 5.2 config (add-ons, extensions,
# preferences) to mimir, the agents' Blender test node, so a check there opens her files
# like her own Blender does. Octane and the Blender MCP extension stay behind: the one
# Octane licence seat is hers on mjolnir, and the MCP server belongs to her live Blender.
# Run again after installing or updating an add-on. Deletes nothing on mimir but an
# Octane add-on link, if one is there.
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
