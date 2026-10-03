{ pkgs, ... }:
# ── muninn on mjolnir — link the desktop terminal to the knowledge base ──────
# Mounts the vault (odyn NFS, VLAN 20) straight into ~/muninn so interactive
# Claude Code here can READ your notes (recall) and WRITE new ones (capture),
# plus a `capture` quick-note command that drops into _inbox and nudges huginn.
#
# Note: edits made here don't live-refresh the hosted Obsidian app (only
# heimdall-side edits do) — huginn still files them and they appear on reload.
let
  vault = "/home/christina/muninn";

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

  # ask: MiniMax (OpenRouter) Q&A over the muninn knowledge graph — NO Claude.
  # Runs muninn-ask on heimdall via sudo systemd-run (loads the OpenRouter secret).
  # Goes through the brain's bridge first (same front door as the dashboard:
  # Jev sorts the request, the exchange is logged in the vault) and needs no
  # SSH key. Falls back to the old SSH path if the bridge is not answering.
  ask = pkgs.writeShellApplication {
    name = "ask";
    runtimeInputs = [ pkgs.openssh pkgs.curl pkgs.jq ];
    text = ''
      q="$*"
      [ -n "$q" ] || { echo "usage: ask <question about your homelab / notes>" >&2; exit 1; }
      if out="$(jq -n --arg t "$q" '{text: $t}' \
           | curl -fsS -m 90 https://brain.oryxserver.org/bridge/talk -H 'Content-Type: application/json' -d @- 2>/dev/null)"; then
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
  # Reports Codex's 5-hour and weekly usage to the brain (Usage tab). Codex
  # writes a rate-limit snapshot into its session log after every turn; this
  # sends the newest one, stamped with when it was measured. Does nothing on a
  # host where Codex has never run, and never fails the unit if the brain is down.
  codexUsage = pkgs.writeShellApplication {
    name = "muninn-codex-usage";
    runtimeInputs = [ pkgs.jq pkgs.curl pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.hostname ];
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
      curl -fsS -m 10 https://brain.oryxserver.org/bridge/usage -H 'Content-Type: application/json' -d "$body" >/dev/null \
        || echo "muninn-codex-usage: the brain did not accept the report" >&2
    '';
  };

  # Claude Code status line that also reports the subscription's 5-hour and
  # weekly usage to the brain (Usage tab). Claude Code only exposes these
  # numbers to a status line command. Enable in ~/.claude/settings.json:
  #   "statusLine": { "type": "command", "command": "muninn-usage-statusline" }
  usageStatusline = pkgs.writeShellApplication {
    name = "muninn-usage-statusline";
    runtimeInputs = [ pkgs.jq pkgs.curl pkgs.coreutils pkgs.hostname ];
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
          ( curl -fsS -m 5 https://brain.oryxserver.org/bridge/usage -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1 & )
        fi
      fi
    '';
  };
in
{
  boot.supportedFilesystems = [ "nfs" ];

  # Mount the muninn vault subpath directly, so ~/muninn IS the vault root.
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

  environment.systemPackages = [ capture ask usageStatusline codexUsage ];

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
