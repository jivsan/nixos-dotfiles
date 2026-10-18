{ lib, pkgs, ... }:

# hermes on hermod reaches two things on mjolnir: the Blender MCP server, over SSH
# with a key that can start nothing else, and a copy of Claude Code's skills, memory
# notes and homelab context, pushed from here with `claude-to-hermod`.
let
  # Blender Lab MCP server, the same one Claude Code runs (user-scope MCP `blender`).
  # It drives the Blender extension on localhost:9876, so Blender must be open.
  blenderMcp = pkgs.writeShellScript "blender-mcp-for-hermod" ''
    export PATH=${lib.makeBinPath [ pkgs.uv pkgs.git ]}:$PATH
    exec uvx --from "git+https://projects.blender.org/lab/blender_mcp.git#subdirectory=mcp" blender-mcp
  '';
in
{
  users.users.christina.openssh.authorizedKeys.keys = [
    ''restrict,command="${blenderMcp}" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEAh74ChiC+JFYRzamn8iwVW03txv1S8HgkDxUvOqCXb hermes-mcp@hermod''
  ];

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "claude-to-hermod";
      runtimeInputs = with pkgs; [ coreutils findutils gnugrep gnused gnutar openssh ];
      text = builtins.readFile ./claude-to-hermod.sh;
    })
  ];
}
