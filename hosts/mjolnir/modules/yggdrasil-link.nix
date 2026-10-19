{ lib, pkgs, ... }:

# hermes on yggdrasil reaches mjolnir in two ways: MCP servers started over SSH with a
# key that can start nothing else, and a copy of Claude Code's skills, memory notes
# and homelab context, pushed from here with `claude-to-yggdrasil`.
let
  # The word hermes sends picks the server:
  # - blender: the Blender Lab MCP server, the same one Claude Code runs (user-scope
  #   MCP `blender`). It drives the extension on localhost:9876, so Blender must be open.
  # - wowx: ~/projects/testwowexportai/mcp.js, which finds and exports WoW models into
  #   /mnt/hermes-wowx and upscales them with Upscayl on this GPU. Its native module
  #   needs this Node (24.21, the one in her profile).
  yggdrasilMcp = pkgs.writeShellScript "yggdrasil-mcp" ''
    export PATH=${lib.makeBinPath [ pkgs.uv pkgs.git pkgs.nodejs pkgs.imagemagick ]}:$PATH
    case "''${SSH_ORIGINAL_COMMAND:-blender}" in
      blender) exec uvx --from "git+https://projects.blender.org/lab/blender_mcp.git#subdirectory=mcp" blender-mcp ;;
      wowx) cd /home/christina/projects/testwowexportai && exec node mcp.js ;;
    esac
    echo "this key only starts the blender or wowx MCP servers" >&2
    exit 1
  '';
in
{
  users.users.christina.openssh.authorizedKeys.keys = [
    ''restrict,command="${yggdrasilMcp}" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEAh74ChiC+JFYRzamn8iwVW03txv1S8HgkDxUvOqCXb hermes-mcp@hermod''
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJqRu0/cwcMKm5+Rxm8jx8GfpaqCtPieqGaxetVH8Prj hermod"
  ];

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "claude-to-yggdrasil";
      runtimeInputs = with pkgs; [ coreutils findutils gnugrep gnused gnutar openssh ];
      text = builtins.readFile ./claude-to-yggdrasil.sh;
    })
  ];
}
