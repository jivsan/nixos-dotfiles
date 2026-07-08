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
  ask = pkgs.writeShellApplication {
    name = "ask";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      q="$*"
      [ -n "$q" ] || { echo "usage: ask <question about your homelab / notes>" >&2; exit 1; }
      printf '%s' "$q" | ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=8 christina@10.0.20.17 \
        'sudo systemd-run --wait --pipe --quiet --uid=christina --gid=users -p EnvironmentFile=/var/lib/secrets/graphify-openrouter.env -p Environment=HOME=/var/lib/huginn /run/current-system/sw/bin/muninn-ask'
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

  environment.systemPackages = [ capture ask ];
}
