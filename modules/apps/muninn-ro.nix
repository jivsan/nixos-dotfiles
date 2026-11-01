{ pkgs, ... }:
# `muninn-ro`: my vault and graphs, read-only, from muninn-ro on heimdall
# (hosts/heimdall/modules/system/muninn-ro.nix). one token per host and user:
#   (umask 077; mkdir -p ~/.config/muninn-ro; ssh christina@10.0.20.17 'sudo muninn-ro-token add <name>' > ~/.config/muninn-ro/token)
# the token goes to curl on stdin, so it's never in argv, the environment or a log
let
  muninnRo = pkgs.writeShellApplication {
    name = "muninn-ro";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    text = ''
      url="''${MUNINN_RO_URL:-https://muninn-ro.oryxserver.org}"
      tokf="''${MUNINN_RO_TOKEN_FILE:-$HOME/.config/muninn-ro/token}"
      [ -r "$tokf" ] || { echo "muninn-ro: no token in $tokf (sudo muninn-ro-token add <name> on heimdall)" >&2; exit 1; }
      case "$(stat -c %a "$tokf")" in 600|400) ;; *) echo "muninn-ro: $tokf must be 0600" >&2; exit 1 ;; esac
      get() {
        local p="$1" out; shift
        if ! out="$(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d ' \n' < "$tokf")" \
                    | curl -sS --fail-with-body -m 30 -K - -G "$url$p" "$@")"; then
          printf 'muninn-ro: %s\n' "$(jq -r '.error // .' <<< "$out" 2>/dev/null || printf '%s' "$out")" >&2; return 1
        fi
        printf '%s' "$out"
      }
      cmd="''${1:-}"; shift || true
      g=notes; if [ "''${1:-}" = --dotfiles ]; then g=dotfiles; shift; fi
      case "$cmd" in
        search) get /search --data-urlencode "q=$*" | jq -r '.results[] | "\(.path)\n    \(.snippet)"' ;;
        read)   get /read --data-urlencode "path=$*" | jq -r .body ;;
        notes)  get /notes --data-urlencode "prefix=$*" --data-urlencode "limit=5000" | jq -r '.notes[].path' ;;
        graph)  get /graph/query --data-urlencode "graph=$g" --data-urlencode "q=$*" | jq -r .text ;;
        node|neighbors) get "/graph/$cmd" --data-urlencode "graph=$g" --data-urlencode "label=$*" | jq -r .text ;;
        path)   get /graph/path --data-urlencode "graph=$g" --data-urlencode "from=''${1:-}" --data-urlencode "to=''${2:-}" | jq -r .text ;;
        health) get /health | jq . ;;
        *) echo "usage: muninn-ro search <words> | read <path> | notes [folder/] | graph|node|neighbors [--dotfiles] <text>" >&2
           echo "       muninn-ro path [--dotfiles] <from> <to> | health" >&2; exit 2 ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [ muninnRo ];
}
