{ lib, pkgs, ... }:

# hermes on yggdrasil reaches mjolnir two ways: mcp servers over ssh with a key that starts
# nothing else, and claude's skills, notes and context pushed from here with `claude-to-yggdrasil`
let
  # the word hermes sends picks the server. blender: the same blender lab mcp claude runs,
  # it needs my blender open (extension on localhost:9876). wowx: ~/projects/testwowexportai/mcp.js,
  # its native module is built for this node, the one in my profile
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
    # hermes' mcp key, /var/lib/hermes-ssh/id_ed25519 on yggdrasil
    ''restrict,command="${yggdrasilMcp}" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEAh74ChiC+JFYRzamn8iwVW03txv1S8HgkDxUvOqCXb hermes-mcp@hermod''
    # my own key on yggdrasil, a full login
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
