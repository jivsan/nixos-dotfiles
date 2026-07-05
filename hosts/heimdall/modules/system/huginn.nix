{ pkgs, lib, ... }:
# ── huginn — the agent layer over the muninn vault ───────────────────────────
# Claude Code runs headless on heimdall, cwd = the vault on NFS, editing notes
# directly (same mount as the container → inotify → live refresh in the app).
#
# Three kinds of job (systemd timers):
#   • inbox-sweep   — file rough captures out of _inbox/
#   • daily-digest  — summarise the day into today's journal note
#   • graphify      — (safishamsi/graphify) rebuild a queryable knowledge graph
#                     of the whole vault into <vault>/graphify-out (graph.html +
#                     graph.json + an obsidian/ export). This is the "agentic OS
#                     + Graphify" workflow from the video.
#
# Runs as `christina` (uid 1000) so writes match the vault's NFS ownership, but
# hardened (NoNewPrivileges + ProtectHome) so a --dangerously-skip-permissions
# agent can't use her passwordless sudo or read her real home.
#
# Auth — create /var/lib/secrets/claude-code.env (out of git) with:
#   ANTHROPIC_API_KEY=sk-...       ← recommended: works for BOTH claude-code and graphify
# (A Claude subscription token, CLAUDE_CODE_OAUTH_TOKEN=..., also drives the note
#  agents, but Graphify's markdown extraction needs a real API key like the above.)
let
  vault   = "/mnt/nas/obsidian/muninn";
  agentHome = "/var/lib/huginn";        # HOME for graphify (off christina's real home)
  localBin  = "${agentHome}/.local/bin";

  # ── MiniMax LLM helper (OpenRouter, OpenAI-compatible) — the agents' brain ──
  # $1 = system prompt; user content on stdin; prints the model reply (or empty).
  llm = pkgs.writeShellApplication {
    name = "muninn-llm";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    text = ''
      sys="''${1:?system prompt required}"
      : "''${OPENAI_API_KEY:?OPENAI_API_KEY not set (needs graphify-openrouter.env)}"
      base="''${OPENAI_BASE_URL:-https://openrouter.ai/api/v1}"
      mdl="''${OPENAI_MODEL:-minimax/minimax-m3}"
      user="$(cat)"
      req="$(jq -n --arg m "$mdl" --arg s "$sys" --arg u "$user" \
        '{model:$m, temperature:0.2, messages:[{role:"system",content:$s},{role:"user",content:$u}]}')"
      resp="$(curl -sS --max-time 120 --retry 2 "$base/chat/completions" \
        -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" \
        -d "$req" 2>/dev/null || true)"
      printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true
    '';
  };

  # Graphify: install the tool + its Claude Code skill into the agent HOME.
  graphifySetup = pkgs.writeShellApplication {
    name = "huginn-graphify-setup";
    runtimeInputs = [ pkgs.uv pkgs.git pkgs.coreutils ];
    text = ''
      export HOME="${agentHome}"
      export PATH="${localBin}:$PATH"
      # isolated install of the graphify CLI (PyPI package is 'graphifyy').
      # Install `mcp` (graphify-mcp server) and `openai` (the OpenRouter/MiniMax
      # labeling backend) explicitly with --with: the "graphifyy[...]" extras
      # silently resolve to nothing on some versions, so graphify-mcp and
      # `graphify label` would break.
      uv tool install --force graphifyy --with mcp --with openai
      # register the /graphify Claude Code skill under $HOME/.claude/skills/graphify
      graphify install || true
    '';
  };

  # Graphify: (re)build the DOTFILES repo graph → the graph both the MCP and the
  # brain read from /var/lib/huginn/graphs/dotfiles/graph.json.
  # NO Claude: `graphify update` extracts the code offline (tree-sitter, no LLM),
  # then `graphify label` names the communities using whatever LLM backend the env
  # selects. With ONLY the OpenRouter (OpenAI-compatible) vars present, Graphify's
  # auto-detect picks the openai backend → MiniMax-M3. No key → offline graph only.
  graphifyRepo = pkgs.writeShellApplication {
    name = "huginn-graphify-repo";
    runtimeInputs = [ pkgs.uv pkgs.git pkgs.coreutils ];
    text = ''
      export HOME="${agentHome}"
      export PATH="${localBin}:$PATH"
      src="${agentHome}/graph-src"
      dst="${agentHome}/graphs/dotfiles"
      logdir="${vault}/agents/logs"; mkdir -p "$logdir" "$dst"
      {
        echo "[$(date -Iseconds)] huginn/graphify-repo start (labeling: ''${OPENAI_MODEL:-<offline, none>})"
        rm -rf "$src"
        git clone --depth 1 https://github.com/jivsan/nixos-dotfiles "$src"
        cd "$src" || exit 1
        graphify update .            # extract code → graph.json (offline, no LLM, no Claude)
        if [ -n "''${OPENAI_API_KEY:-}" ]; then
          echo "[$(date -Iseconds)] labeling communities via ''${OPENAI_MODEL:-openai backend}"
          graphify label . || echo "[$(date -Iseconds)] [warn] label step failed; keeping offline graph"
        fi
        if [ -f graphify-out/graph.json ]; then
          cp -f graphify-out/graph.json "$dst/graph.json"
          cp -f graphify-out/GRAPH_REPORT.md "$dst/GRAPH_REPORT.md" 2>/dev/null || true
          echo "[$(date -Iseconds)] huginn/graphify-repo done → $dst/graph.json ($(wc -c < "$dst/graph.json") bytes)"
        else
          echo "[$(date -Iseconds)] huginn/graphify-repo FAILED — no graph.json produced"; exit 1
        fi
      } 2>&1 | tee -a "$logdir/graphify-repo.log"
    '';
  };

  # muninn-ask: MiniMax (OpenRouter) Q&A over the dotfiles graph — NO Claude.
  # Retrieves graph context via `graphify query`, then synthesises an answer with
  # the OpenAI-compatible OpenRouter endpoint (OPENAI_* env from the secret file).
  # Question arrives on stdin; the mjolnir `ask` wrapper runs it via sudo systemd-run
  # so the secret env is loaded.
  askBrain = pkgs.writeShellApplication {
    name = "muninn-ask";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    text = ''
      q="$(cat)"
      [ -n "$q" ] || { echo "usage: muninn-ask  (question on stdin)" >&2; exit 1; }
      : "''${OPENAI_API_KEY:?not set — needs /var/lib/secrets/graphify-openrouter.env}"
      base="''${OPENAI_BASE_URL:-https://openrouter.ai/api/v1}"
      model="''${OPENAI_MODEL:-minimax/minimax-m3}"
      export HOME=/var/lib/huginn
      export PATH="/var/lib/huginn/.local/bin:$PATH"
      ctx="$(graphify query "$q" --graph /var/lib/huginn/graphs/dotfiles/graph.json 2>/dev/null | head -c 7000 || true)"
      body="$(jq -n --arg m "$model" --arg q "$q" --arg c "$ctx" '{
        model: $m,
        messages: [
          { role: "system", content: "You are muninn, a homelab assistant. Answer using ONLY the knowledge-graph context from a NixOS homelab (hosts: mjolnir desktop, heimdall services VM, odyn TrueNAS, mimir AI box). Be concise and concrete; cite file paths when relevant. If the context lacks the answer, say so plainly." },
          { role: "user", content: ("Question: " + $q + "\n\n--- knowledge-graph context ---\n" + $c) }
        ]
      }')"
      curl -sS "$base/chat/completions" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$body" \
        | jq -r '.choices[0].message.content // .error.message // "no response"'
    '';
  };

  # ── inbox sweep (MiniMax) — file each _inbox note into a titled, linked note ──
  inboxSweep = pkgs.writeShellApplication {
    name = "huginn-inbox-sweep";
    runtimeInputs = [ llm pkgs.jq pkgs.coreutils ];
    text = ''
      : "''${OPENAI_API_KEY:?not set — needs /var/lib/secrets/graphify-openrouter.env}"
      inbox="${vault}/_inbox"
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      today="$(date +%F)"
      log(){ echo "[$(date -Iseconds)] $*" | tee -a "$logdir/inbox-sweep.log"; }
      mocs=""
      for m in "${vault}/MOCs"/*.md; do [ -e "$m" ] && mocs="$mocs, $(basename "$m" .md)"; done
      mocs="''${mocs#, }"; [ -n "$mocs" ] || mocs="Home MOC"
      log "inbox-sweep start (minimax)"
      filed=0
      shopt -s nullglob
      for f in "$inbox"/*.md; do
        bn="$(basename "$f")"
        [ "$bn" = "README.md" ] && continue
        raw="$(head -c 8000 "$f")"
        [ -n "$raw" ] || { log "  ! skip $bn (empty)"; continue; }
        sys="You file a rough inbox note into an Obsidian vault. Reply with ONLY a JSON object (no code fences, no prose) with keys: title (concise, no slashes or newlines), folder (exactly Areas or Resources), moc (choose the single best from: $mocs), tags (array of 1-4 short lowercase strings), body (the note rewritten as clean markdown, keeping every fact, inventing nothing)."
        j="$(printf '%s' "$raw" | muninn-llm "$sys" | sed '/^```/d')"
        if ! printf '%s' "$j" | jq -e 'type=="object"' >/dev/null 2>&1; then
          log "  ! skip $bn (no JSON from model)"; continue
        fi
        title="$(printf '%s' "$j" | jq -r '.title // empty' | tr -d '\r\n' | tr '/' '-' | cut -c1-90)"
        [ -n "$title" ] || { log "  ! skip $bn (no title)"; continue; }
        folder="$(printf '%s' "$j" | jq -r 'if .folder=="Areas" then "Areas" else "Resources" end')"
        moc="$(printf '%s' "$j" | jq -r '.moc // "Home MOC"')"
        tags="$(printf '%s' "$j" | jq -r '(.tags // []) | map(tostring) | join(", ")')"
        body="$(printf '%s' "$j" | jq -r '.body // ""')"
        dest="${vault}/$folder"; mkdir -p "$dest"
        target="$dest/$title.md"; k=2
        while [ -e "$target" ]; do target="$dest/$title ($k).md"; k=$((k+1)); done
        printf -- '---\ntype: note\nstatus: active\ntags: [%s]\ncreated: %s\nagent: huginn\n---\n\n# %s\n\n%s\n\nSee also: [[%s]]\n' \
          "$tags" "$today" "$title" "$body" "$moc" > "$target"
        rm -f "$f"
        log "  + $bn -> $folder/$(basename "$target")  [[$moc]]"
        filed=$((filed+1))
      done
      log "inbox-sweep done ($filed filed)"
    '';
  };

  # ── daily digest (MiniMax) — summarise the day into today's journal note ──
  dailyDigest = pkgs.writeShellApplication {
    name = "huginn-daily-digest";
    runtimeInputs = [ llm pkgs.jq pkgs.coreutils pkgs.findutils pkgs.gnused ];
    text = ''
      : "''${OPENAI_API_KEY:?not set — needs /var/lib/secrets/graphify-openrouter.env}"
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      today="$(date +%F)"
      journal="${vault}/journal/$today.md"
      log(){ echo "[$(date -Iseconds)] $*" | tee -a "$logdir/daily-digest.log"; }
      log "daily-digest start (minimax)"
      ctx=""; count=0
      while IFS= read -r f; do
        name="$(basename "$f" .md)"
        snip="$(sed '/^---$/,/^---$/d' "$f" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | cut -c1-280)"
        ctx="$ctx"$'\n'"- [[$name]] :: $snip"
        count=$((count+1))
      done < <(find "${vault}" -type f -name '*.md' -newermt "$today 00:00:00" \
          -not -path '*/.obsidian/*' -not -path '*/agents/*' -not -path '*/_templates/*' \
          -not -path '*/graphify-out/*' -not -path '*/journal/*' -not -path '*/_inbox/*' \
          -not -name 'README.md' 2>/dev/null | sort)
      mkdir -p "${vault}/journal"
      [ -f "$journal" ] || printf -- '---\ntype: journal\ncreated: %s\nagent: huginn\n---\n\n# %s\n' "$today" "$today" > "$journal"
      if [ "$count" -eq 0 ]; then
        digest="- Quiet day — no notes changed."
      else
        sys="You are huginn writing a nightly journal digest for an Obsidian vault. From the list of notes touched today, write 3-6 concise markdown bullets summarising the day. Each bullet MUST wikilink the note it refers to using its [[Note Name]] exactly as given. Output only the bullets, no preamble."
        digest="$(printf '%s' "$ctx" | muninn-llm "$sys")"
        [ -n "$digest" ] || digest="- ($count notes changed today; digest model returned nothing.)"
      fi
      printf '\n## huginn digest (%s)\n%s\n\n[[Home MOC]]\n' "$(date +%H:%M)" "$digest" >> "$journal"
      log "daily-digest done ($count notes -> journal/$today.md)"
    '';
  };

  # Common hardening + auth for the LLM-calling jobs.
  agentServiceConfig = {
    Type = "oneshot";
    User = "christina";
    Group = "users";
    Environment = [ "HOME=${agentHome}" ];
    EnvironmentFile = "-/var/lib/secrets/graphify-openrouter.env";   # OpenRouter/MiniMax creds
    NoNewPrivileges = true;   # block sudo/setuid escalation despite passwordless-sudo christina
    ProtectHome = true;       # hide /home/christina; HOME is ${agentHome}
    PrivateTmp = true;
  };
in
{
  environment.systemPackages = [ pkgs.uv askBrain ];

  # graphify's tree-sitter wheels are prebuilt binaries → need the ld shim on NixOS.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [ stdenv.cc.cc.lib zlib openssl ];

  # claude-code + graphify state (their HOME) off christina's real home dir.
  systemd.tmpfiles.rules = [
    "d ${agentHome} 0750 christina users -"
    "d ${agentHome}/graphs 0750 christina users -"
    "d ${agentHome}/graphs/dotfiles 0750 christina users -"
  ];

  # ── note agents ──
  systemd.services."huginn-inbox-sweep" = {
    description = "huginn: sweep the muninn _inbox and file notes";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = agentServiceConfig // {
      ExecStart = "${inboxSweep}/bin/huginn-inbox-sweep";
    };
  };
  systemd.timers."huginn-inbox-sweep" = {
    description = "huginn inbox sweep schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 08,10,12,14,16,18,20:15:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  systemd.services."huginn-daily-digest" = {
    description = "huginn: append a nightly digest to today's journal note";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = agentServiceConfig // {
      ExecStart = "${dailyDigest}/bin/huginn-daily-digest";
    };
  };
  systemd.timers."huginn-daily-digest" = {
    description = "huginn nightly digest schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 23:00:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  # ── graphify: one-time tool/skill install, then a nightly graph rebuild ──
  systemd.services."huginn-graphify-setup" = {
    description = "huginn: install the graphify tool + /graphify Claude Code skill";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "christina";
      Group = "users";
      Environment = [ "HOME=${agentHome}" ];
      ExecStart = "${graphifySetup}/bin/huginn-graphify-setup";
    };
  };

  # ── graphify: the dotfiles repo graph (feeds the graphify-mcp + the brain) ──
  systemd.services."huginn-graphify-repo" = {
    description = "huginn: rebuild the dotfiles knowledge graph (MCP + brain)";
    after = [ "network-online.target" "huginn-graphify-setup.service" ];
    wants = [ "network-online.target" ];
    requires = [ "huginn-graphify-setup.service" ];
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = agentServiceConfig // {
      # OpenRouter/MiniMax creds ONLY (no ANTHROPIC_API_KEY, so Graphify's
      # auto-detect picks the openai backend); optional (leading '-') so the job
      # still builds an offline graph if the file is absent.
      EnvironmentFile = "-/var/lib/secrets/graphify-openrouter.env";
      ExecStart = "${graphifyRepo}/bin/huginn-graphify-repo";
    };
  };
  systemd.timers."huginn-graphify-repo" = {
    description = "huginn dotfiles-graph rebuild schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:00:00";   # weekly; code changes less often
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };
}
