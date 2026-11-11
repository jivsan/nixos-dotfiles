{ pkgs, ... }:

# dns-same: asks my two dns servers the same questions every 15 minutes. when one of them doesn't answer,
# or they answer differently, for more than 5 minutes, the unit fails. a failed unit is the alert:
# heimdall's DnsDiffer rule sends it to ntfy "alerts" (heimdall alerting.nix). the unit's log says what differs.
# it runs here because yggdrasil is on neither proxmox node: it still looks when garm or fenrir is down.
# but the alert goes through heimdall, a vm on garm: with garm down this still looks, and nothing reaches my phone.
#
# clients use both servers all the time, so a difference shows as "sometimes it doesn't work". this finds it.
# what to do when it fires: talos-helheim, kubernetes/README.md, stage 6, what i have to know.
let
  first = "10.0.20.4";    # the pi-hole lxc on garm
  second = "10.0.20.53";  # pihole2 in helheim (talos-helheim, kubernetes/apps/pihole2)

  check = pkgs.writeShellApplication {
    name = "dns-same";
    runtimeInputs = with pkgs; [ dnsutils gnugrep gawk coreutils ];
    text = ''
      first=${first}
      second=${second}
      flag=''${RUNTIME_DIRECTORY:-/tmp}/differ

      # name, type, and what is compared: "all" = the whole answer, "any" = only that there is one
      # (a public name can come back with other addresses each time)
      questions="
      garm.oryxserver.org A all
      garm.oryxserver.org AAAA all
      pihole2.oryxserver.org A all
      pihole2.oryxserver.org AAAA all
      nope.oryxserver.org A all
      doubleclick.net A all
      example.com A any
      "
      # garm: a name from the names file, and the same name with no ipv6 address (no error, empty).
      # pihole2: a route, both ways too. a pi-hole that was asked for a name before it had the record
      # says "no such name" for AAAA for 30 minutes, and that is what the AAAA lines find.
      # nope: a name that doesn't exist. doubleclick.net: blocked, 0.0.0.0

      answer() {
        local out status rr
        out=$(dig +tries=2 +time=2 +noall +comments +answer "@$1" "$2" "$3" 2>/dev/null) || true
        status=$(grep -o 'status: [A-Z]*' <<<"$out" | head -n 1 | cut -d' ' -f2)
        if [ -z "$status" ]; then echo "no answer"; return; fi
        rr=$(grep -v '^;' <<<"$out" | awk 'NF { print $NF }' | sort | tr '\n' ' ')
        if [ "$4" = any ] && [ -n "$rr" ]; then rr="an address"; fi
        echo "$status $rr"
      }

      differ() {
        local name type how a b
        while read -r name type how; do
          [ -n "$name" ] || continue
          a=$(answer "$first" "$name" "$type" "$how")
          b=$(answer "$second" "$name" "$type" "$how")
          [ "$a" = "$b" ] || echo "$name $type: $first says [$a], $second says [$b]"
        done <<<"$questions"
        # both servers lose a name together when its line leaves names.yaml (talos-helheim,
        # kubernetes/external), and "the same" stays true. so one name must be there
        a=$(answer "$first" garm.oryxserver.org A all)
        case $a in
          "NOERROR 10."*) ;;
          *) echo "garm.oryxserver.org A: $first says [$a], it should be an address" ;;
        esac
      }

      bad=$(differ)
      if [ -z "$bad" ]; then rm -f "$flag"; exit 0; fi
      # new: look again for 5 minutes first. a new pod of the second pi-hole is out for a minute or two.
      # known from the last run: fail at once, so the unit stays failed and the alert stays on
      if [ ! -e "$flag" ]; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          sleep 30
          bad=$(differ)
          if [ -z "$bad" ]; then exit 0; fi
        done
        touch "$flag"
      fi
      echo "my two dns servers differ:"
      echo "$bad"
      exit 1
    '';
  };
in
{
  systemd.services.dns-same = {
    description = "both dns servers (${first}, ${second}) answer the same";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${check}/bin/dns-same";
      DynamicUser = true;
      # /run/dns-same/differ remembers a difference from one run to the next
      RuntimeDirectory = "dns-same";
      RuntimeDirectoryPreserve = true;
    };
  };

  systemd.timers.dns-same = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = false;
    };
  };
}
