{ pkgs, ... }:
# my vault at ~/muninn (nfs from odyn), plus `capture`, `ask` and the usage reports for the brain
# notes written from here show up in the hosted obsidian only after a reload
let
  vault = "/home/christina/muninn";

  # curl to https://brain.oryxserver.org<path> with one of this host's tokens, from
  # ~/.config/muninn/brain-token-<role> (mode 600, made by muninn-brain-get-token: docs/muninn-agentic-os.md).
  # the role is MUNINN_BRAIN_ROLE, usage when it's unset: the usage reports send that one, ask its own.
  # the token reaches curl through a pipe, never its command line, so ps doesn't show it.
  # no file: no token is sent, which works only while the brain still lets everyone in
  brainCurl = pkgs.writeShellApplication {
    name = "muninn-brain-curl";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      path="''${1:?usage: [MUNINN_BRAIN_ROLE=role] muninn-brain-curl /path [curl options]}"
      shift
      role="''${MUNINN_BRAIN_ROLE:-usage}"
      if ! [[ "$role" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "muninn-brain-curl: MUNINN_BRAIN_ROLE is lowercase letters, digits and -" >&2
        exit 2
      fi
      tokf="''${XDG_CONFIG_HOME:-$HOME/.config}/muninn/brain-token-$role"
      tok=""
      if [ -r "$tokf" ]; then
        tok="$(< "$tokf")"
        tok="''${tok//[[:space:]]/}"
      fi
      if [ -n "$tok" ]; then
        exec curl -fsS "https://brain.oryxserver.org$path" -H @<(printf 'Authorization: Bearer %s\n' "$tok") "$@"
      fi
      exec curl -fsS "https://brain.oryxserver.org$path" "$@"
    '';
  };

  # gets one of this host's tokens from heimdall straight into ~/.config/muninn/brain-token-<role>,
  # over ssh: it never shows on the screen, a command line or in chat. on heimdall it's <host>-<role>.
  #   muninn-brain-get-token               role usage: /bridge/usage only, for the usage reports
  #   muninn-brain-get-token ask           role ask: /bridge/talk, for ask. only if i want ask on the
  #                                        bridge: talk can start hermes, codex and claude jobs, and
  #                                        anything running as me on this host can read the file
  #   muninn-brain-get-token ROLE PATH...  any other role, limited to those paths
  # a second run for the same role refuses: revoke the old one first
  getToken = pkgs.writeShellApplication {
    name = "muninn-brain-get-token";
    runtimeInputs = [ pkgs.openssh pkgs.coreutils pkgs.hostname ];
    text = ''
      role="''${1:-usage}"
      if [ "$#" -gt 0 ]; then shift; fi
      if ! [[ "$role" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "role: lowercase letters, digits and -" >&2
        exit 2
      fi
      if [ "$#" -eq 0 ]; then
        case "$role" in
          usage) set -- /bridge/usage ;;
          ask) set -- /bridge/talk ;;
          *) echo "usage: muninn-brain-get-token [usage | ask | ROLE PATH...]" >&2; exit 2 ;;
        esac
      fi
      name="$(hostname)-$role"
      dir="''${XDG_CONFIG_HOME:-$HOME/.config}/muninn"
      f="$dir/brain-token-$role"
      if [ -e "$f" ]; then
        echo "$f is already there. to replace it: on heimdall sudo muninn-brain-token revoke $name, then rm $f" >&2
        exit 1
      fi
      umask 077
      mkdir -p "$dir"
      tmp="$(mktemp "$dir/.brain-token.XXXXXX")"
      trap 'rm -f "$tmp"' EXIT
      rc=0
      ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=8 christina@10.0.20.17 \
        "sudo muninn-brain-token add $(printf '%q ' "$name" "$@")" > "$tmp" || rc=$?
      # keep a token that came back whole even if ssh ended badly: heimdall has saved its hash by then
      if ! [[ "$(< "$tmp")" =~ ^mb_[A-Za-z0-9_-]{43}$ ]]; then
        echo "no token came back from heimdall (ssh ended with $rc)." >&2
        echo "if sudo muninn-brain-token list there shows $name anyway, revoke it and run this again" >&2
        exit 1
      fi
      mv "$tmp" "$f"
      trap - EXIT
      if [ "$rc" -ne 0 ]; then echo "ssh ended with $rc, but the token came back whole" >&2; fi
      echo "saved the token for $name ($*) in $f"
    '';
  };

  capture = pkgs.writeShellApplication {
    name = "capture";
    runtimeInputs = [ pkgs.coreutils pkgs.openssh ];
    text = ''
      inbox="${vault}/_inbox"
      if [ ! -d "$inbox" ]; then
        echo "muninn not mounted yet at ${vault} (cd ${vault} to trigger the automount), aborting." >&2
        exit 1
      fi
      ts="$(date +%Y-%m-%d-%H%M%S)"
      f="$inbox/capture-$ts.md"
      if [ "$#" -gt 0 ]; then printf '%s\n' "$*" > "$f"; else cat > "$f"; fi
      echo "captured → $f"
      # best-effort: nudge huginn to file it now (timer files it otherwise)
      ( ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=5 christina@10.0.20.17 \
          'sudo systemctl start --no-block huginn-inbox-sweep.service' >/dev/null 2>&1 & )
      echo "huginn nudged — it'll file this into a linked note shortly."
    '';
  };

  # ask: answers from my knowledge graph on minimax, never claude
  # brain bridge first (logged in the vault), ssh to heimdall's muninn-ask if the bridge is down.
  # the bridge needs this host's ask token (muninn-brain-get-token ask), not the usage one: /bridge/talk
  # can start agent jobs. without it the brain refuses ask once the login is on, and ask goes over ssh
  ask = pkgs.writeShellApplication {
    name = "ask";
    runtimeInputs = [ pkgs.openssh brainCurl pkgs.jq ];
    text = ''
      q="$*"
      [ -n "$q" ] || { echo "usage: ask <question about your homelab / notes>" >&2; exit 1; }
      if out="$(jq -n --arg t "$q" '{text: $t}' \
           | MUNINN_BRAIN_ROLE=ask muninn-brain-curl /bridge/talk -m 90 -H 'Content-Type: application/json' -d @- 2>/dev/null)"; then
        printf '%s' "$out" | jq -r '
          (.answer // "no answer"),
          (if (.sources // []) | length > 0 then "\nsources: " + ([.sources[].title] | join(" · ")) else empty end),
          ("\n[" + .route.tier + " via " + .route.via + "]")'
        exit 0
      fi
      printf '%s' "$q" | ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=8 christina@10.0.20.17 \
        'sudo systemd-run --wait --pipe --quiet --uid=christina --gid=users -p EnvironmentFile=/var/lib/secrets/graphify-openrouter.env -p Environment=HOME=/var/lib/huginn /run/current-system/sw/bin/muninn-ask'
    '';
  };
  # codex's 5h and weekly usage for the brain's usage tab, from its newest session log
  codexUsage = pkgs.writeShellApplication {
    name = "muninn-codex-usage";
    runtimeInputs = [ pkgs.jq brainCurl pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.hostname ];
    text = ''
      dir="''${CODEX_HOME:-$HOME/.codex}/sessions"
      [ -d "$dir" ] || exit 0
      f="$(find "$dir" -name '*.jsonl' -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)"
      [ -n "$f" ] || exit 0
      line="$(tail -n 400 "$f" | grep '"rate_limits"' | tail -n 1 || true)"
      [ -n "$line" ] || exit 0
      body="$(printf '%s' "$line" | jq -c --arg h "$(hostname)" --argjson t "$(stat -c %Y "$f")" '
        [.. | objects | select(has("rate_limits")) | .rate_limits] | last
        | select(. != null)
        | { provider: "openai", host: $h, as_of: $t,
            five_hour: (.primary | if . then {used_percent, resets_at} else null end),
            seven_day: (.secondary | if . then {used_percent, resets_at} else null end) }' || true)"
      [ -n "$body" ] || exit 0
      muninn-brain-curl /bridge/usage -m 10 -H 'Content-Type: application/json' -d "$body" >/dev/null \
        || echo "muninn-codex-usage: the brain did not accept the report" >&2
    '';
  };

  # claude's status line, it also sends the 5h and weekly usage to the brain's usage tab
  # (claude only gives those numbers to a status line command). turn on in ~/.claude/settings.json:
  #   "statusLine": { "type": "command", "command": "muninn-usage-statusline" }
  usageStatusline = pkgs.writeShellApplication {
    name = "muninn-usage-statusline";
    runtimeInputs = [ pkgs.jq brainCurl pkgs.coreutils pkgs.hostname ];
    text = ''
      input="$(cat)"
      printf '%s' "$input" | jq -r '
        "[" + (.model.display_name // "claude") + "] "
        + ((.context_window.used_percentage // 0) | floor | tostring) + "% ctx"
        + (if .rate_limits.five_hour then " · 5h " + (.rate_limits.five_hour.used_percentage | floor | tostring) + "%" else "" end)
        + (if .rate_limits.seven_day then " · wk " + (.rate_limits.seven_day.used_percentage | floor | tostring) + "%" else "" end)'
      stamp="''${XDG_RUNTIME_DIR:-/tmp}/muninn-usage.stamp"
      now="$(date +%s)"
      last="$(cat "$stamp" 2>/dev/null || echo 0)"
      if [ $((now - last)) -ge 60 ]; then
        body="$(printf '%s' "$input" | jq -c --arg h "$(hostname)" 'select(.rate_limits != null) | {
          provider: "anthropic", host: $h,
          five_hour: (.rate_limits.five_hour | if . then {used_percent: .used_percentage, resets_at: .resets_at} else null end),
          seven_day: (.rate_limits.seven_day | if . then {used_percent: .used_percentage, resets_at: .resets_at} else null end) }')"
        if [ -n "$body" ]; then
          echo "$now" > "$stamp"
          ( muninn-brain-curl /bridge/usage -m 5 -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1 & )
        fi
      fi
    '';
  };
in
{
  boot.supportedFilesystems = [ "nfs" ];

  # hermes-agent.nix on yggdrasil mounts the same export at /mnt/muninn with these options
  fileSystems.${vault} = {
    device = "10.0.20.6:/mnt/vault/obsidian/muninn";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "soft"
      "noatime"
      "_netdev"
      "nofail"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=30"
      "retry=2"
    ];
  };

  environment.systemPackages = [ capture ask usageStatusline codexUsage brainCurl getToken ];

  systemd.user.services.muninn-codex-usage = {
    description = "report Codex usage to the muninn brain";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${codexUsage}/bin/muninn-codex-usage";
    };
  };
  systemd.user.timers.muninn-codex-usage = {
    description = "report Codex usage to the muninn brain every few minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnStartupSec = "2m";
      OnUnitActiveSec = "5m";
    };
  };

  programs.ssh.knownHosts."10.0.20.17".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMafsna8LlSXtsC1h7kSPV3Y3gcTnXdmTNvHArpIUoQZ";
}
