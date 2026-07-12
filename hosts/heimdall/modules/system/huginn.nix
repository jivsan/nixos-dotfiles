{ pkgs, lib, ... }:
# ── huginn — the MiniMax agent layer over the muninn vault ───────────────────
# All agents run on OpenRouter/MiniMax (OpenAI-compatible) — NO Claude, NO
# Anthropic credit. systemd-timer jobs:
#   • inbox-sweep    — MiniMax turns each _inbox note into a titled, frontmattered,
#                      MOC-linked note (model returns JSON → shell writes the file);
#                      also path-triggered (inotify on _inbox) for instant filing
#   • daily-digest   — MiniMax summarises the day into today's journal note
#   • graphify-repo  — offline code extraction + MiniMax community labeling (weekly)
#   • graphify-vault — the NOTES graph: staged copy of the vault's markdown only
#                      (no .obsidian plugin JS) → /var/lib/huginn/graphs/vault (nightly)
#   • gardener       — weekly vault hygiene report: orphans, dead links, stale notes
#   • dead-link-fixer — weekly brain-API sweep: find broken wikilinks, create stub notes
#
# Cross-cutting: every vault-writing agent auto-commits the vault git repo
# (audit trail, author huginn), and every huginn unit has OnFailure= wired to
# drop an alert note into _inbox/ so failures surface on the Home dashboard.
#
# Runs as `christina` (uid 1000, matches the vault's NFS ownership), hardened with
# NoNewPrivileges + ProtectHome. LLM creds live in the out-of-git secret
# /var/lib/secrets/graphify-openrouter.env:
#   OPENAI_API_KEY=<openrouter key>
#   OPENAI_BASE_URL=https://openrouter.ai/api/v1
#   OPENAI_MODEL=minimax/minimax-m3
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
      resp="$(printf 'header = "Authorization: Bearer %s"\n' "$OPENAI_API_KEY" | \
        curl -sS --max-time 120 --retry 2 -K - "$base/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$req" 2>/dev/null || true)"
      printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true
    '';
  };

  # ── vault git audit trail — one commit per agent run, author huginn ─────────
  # No-op if the vault isn't a git repo (bootstrap: git init once, see runbook).
  vaultCommit = pkgs.writeShellApplication {
    name = "muninn-vault-commit";
    runtimeInputs = [ pkgs.git pkgs.coreutils ];
    text = ''
      msg="''${1:?commit message required}"
      cd "${vault}" || exit 0
      [ -d .git ] || exit 0
      git add -A
      git -c user.name=huginn -c user.email=huginn@heimdall \
        commit -q -m "$msg" || true      # empty tree / nothing changed is fine
    '';
  };

  # ── OnFailure alert — drop a note into _inbox so it surfaces on Home + digest ──
  notify = pkgs.writeShellApplication {
    name = "huginn-notify";
    runtimeInputs = [ pkgs.coreutils pkgs.systemd ];
    text = ''
      unit="''${1:-unknown-unit}"
      mkdir -p "${vault}/_inbox"
      f="${vault}/_inbox/alert-$unit-$(date +%Y%m%d-%H%M%S).md"
      {
        echo "huginn alert: $unit FAILED on heimdall at $(date -Iseconds)."
        echo
        echo "Recent log lines:"
        echo '```'
        journalctl -u "$unit" -n 12 --no-pager -o short-iso 2>/dev/null || echo "(journal not readable)"
        echo '```'
        echo
        echo "Inspect: ssh christina@10.0.20.17 'systemctl status $unit'"
      } > "$f"
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

  # Graphify: the VAULT graph — the notes' knowledge graph, MiniMax-labeled.
  # graphify has no exclude flag, so stage ONLY the vault's markdown into a
  # scratch dir first: without this the graph drowns in .obsidian plugin JS
  # (the July build was 90% Dataview/Luxon internals).
  graphifyVault = pkgs.writeShellApplication {
    name = "huginn-graphify-vault";
    runtimeInputs = [ pkgs.uv pkgs.rsync pkgs.coreutils ];
    text = ''
      export HOME="${agentHome}"
      export PATH="${localBin}:$PATH"
      src="${agentHome}/vault-src"
      dst="${agentHome}/graphs/vault"
      logdir="${vault}/agents/logs"; mkdir -p "$logdir" "$dst"
      {
        echo "[$(date -Iseconds)] huginn/graphify-vault start (labeling: ''${OPENAI_MODEL:-<offline, none>})"
        rm -rf "$src"; mkdir -p "$src"
        rsync -a --prune-empty-dirs \
          --exclude='.obsidian' --exclude='.git' --exclude='.trash' \
          --exclude='graphify-out' --exclude='_templates' --exclude='agents' \
          --include='*/' --include='*.md' --exclude='*' \
          "${vault}/" "$src/"
        cd "$src" || exit 1
        graphify update .            # offline extraction of the notes, no LLM
        if [ -n "''${OPENAI_API_KEY:-}" ]; then
          echo "[$(date -Iseconds)] labeling communities via ''${OPENAI_MODEL:-openai backend}"
          graphify label . || echo "[$(date -Iseconds)] [warn] label step failed; keeping offline graph"
        fi
        if [ -f graphify-out/graph.json ]; then
          cp -f graphify-out/graph.json "$dst/graph.json"
          cp -f graphify-out/GRAPH_REPORT.md "$dst/GRAPH_REPORT.md" 2>/dev/null || true
          echo "[$(date -Iseconds)] huginn/graphify-vault done → $dst/graph.json ($(wc -c < "$dst/graph.json") bytes)"
        else
          echo "[$(date -Iseconds)] huginn/graphify-vault FAILED — no graph.json produced"; exit 1
        fi
      } 2>&1 | tee -a "$logdir/graphify-vault.log"
    '';
  };

  # muninn-ask: MiniMax (OpenRouter) Q&A over BOTH graphs + the recent journal —
  # NO Claude. Retrieves context via `graphify query` from the dotfiles graph
  # (code) and the vault graph (notes), plus the last two journal entries, then
  # synthesises an answer on the OpenAI-compatible OpenRouter endpoint.
  # Question arrives on stdin; the mjolnir `ask` wrapper runs it via sudo systemd-run
  # so the secret env is loaded.
  askBrain = pkgs.writeShellApplication {
    name = "muninn-ask";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.findutils ];
    text = ''
      q="$(cat)"
      [ -n "$q" ] || { echo "usage: muninn-ask  (question on stdin)" >&2; exit 1; }
      : "''${OPENAI_API_KEY:?not set — needs /var/lib/secrets/graphify-openrouter.env}"
      base="''${OPENAI_BASE_URL:-https://openrouter.ai/api/v1}"
      model="''${OPENAI_MODEL:-minimax/minimax-m3}"
      export HOME=/var/lib/huginn
      export PATH="/var/lib/huginn/.local/bin:$PATH"
      code_ctx="$(graphify query "$q" --graph /var/lib/huginn/graphs/dotfiles/graph.json 2>/dev/null | head -c 9000 || true)"
      note_ctx=""
      if [ -f /var/lib/huginn/graphs/vault/graph.json ]; then
        note_ctx="$(graphify query "$q" --graph /var/lib/huginn/graphs/vault/graph.json 2>/dev/null | head -c 9000 || true)"
      fi
      # the two most recent journal notes — cheap grounding for "what happened lately"
      jrnl="$(find "${vault}/journal" -maxdepth 1 -name '20*.md' -print0 2>/dev/null \
        | sort -z | tail -zn 2 | xargs -0 -r cat 2>/dev/null | head -c 4000 || true)"
      body="$(jq -n --arg m "$model" --arg q "$q" --arg c "$code_ctx" --arg n "$note_ctx" --arg j "$jrnl" '{
        model: $m,
        messages: [
          { role: "system", content: "You are muninn, the memory of a personal homelab + note system. Answer using ONLY the provided context: a NixOS-config knowledge graph (hosts: mjolnir desktop, heimdall services VM, odyn TrueNAS, mimir AI box), a notes knowledge graph from the muninn Obsidian vault, and recent journal entries. Be concise and concrete; cite file paths or [[note names]] when relevant. If the context lacks the answer, say so plainly." },
          { role: "user", content: ("Question: " + $q
            + "\n\n--- code graph (nixos-dotfiles) ---\n" + $c
            + "\n\n--- notes graph (muninn vault) ---\n" + $n
            + "\n\n--- recent journal ---\n" + $j) }
        ]
      }')"
      printf 'header = "Authorization: Bearer %s"\n' "$OPENAI_API_KEY" | \
        curl -sS -K - "$base/chat/completions" \
        -d "$body" \
        | jq -r '.choices[0].message.content // .error.message // "no response"'
    '';
  };

  # ── inbox sweep (MiniMax) — file each _inbox note into a titled, linked note ──
  inboxSweep = pkgs.writeShellApplication {
    name = "huginn-inbox-sweep";
    runtimeInputs = [ llm vaultCommit pkgs.jq pkgs.coreutils ];
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
        [ -r "$f" ] || { log "  ! skip $bn (unreadable — foreign NFS uid? fix perms on odyn)"; continue; }
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
      if [ "$filed" -gt 0 ]; then muninn-vault-commit "huginn: inbox-sweep filed $filed note(s)"; fi
      log "inbox-sweep done ($filed filed)"
    '';
  };

  # ── daily digest (MiniMax) — summarise the day into today's journal note ──
  dailyDigest = pkgs.writeShellApplication {
    name = "huginn-daily-digest";
    runtimeInputs = [ llm vaultCommit pkgs.jq pkgs.coreutils pkgs.findutils pkgs.gnused ];
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
      # idempotent: a rerun regenerates today's digest instead of stacking a second
      # one (digest sections are always the tail of the journal note)
      sed -i '/^## huginn digest/,$d' "$journal"
      if [ "$count" -eq 0 ]; then
        digest="- Quiet day — no notes changed."
      else
        sys="You are huginn writing a nightly journal digest for an Obsidian vault. From the list of notes touched today, write 3-6 concise markdown bullets summarising the day. Each bullet MUST wikilink the note it refers to using its [[Note Name]] exactly as given. Output only the bullets, no preamble."
        digest="$(printf '%s' "$ctx" | muninn-llm "$sys")"
        [ -n "$digest" ] || digest="- ($count notes changed today; digest model returned nothing.)"
      fi
      printf '\n## huginn digest (%s)\n%s\n\n[[Home MOC]]\n' "$(date +%H:%M)" "$digest" >> "$journal"
      muninn-vault-commit "huginn: daily digest for $today ($count notes)"
      log "daily-digest done ($count notes -> journal/$today.md)"
    '';
  };

  # ── gardener (weekly) — vault hygiene: orphans, dead links, stale notes ──
  # Analysis is offline python; MiniMax only suggests MOC links for orphans.
  gardener = pkgs.writeShellApplication {
    name = "huginn-gardener";
    runtimeInputs = [ vaultCommit pkgs.python3 pkgs.coreutils ];
    text = ''
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      {
        echo "[$(date -Iseconds)] gardener start (minimax)"
        python3 ${../../muninn/gardener.py}
        muninn-vault-commit "huginn: weekly gardener report"
        echo "[$(date -Iseconds)] gardener done"
      } 2>&1 | tee -a "$logdir/gardener.log"
    '';
  };

  # ── dead-link-fixer (weekly) — brain API: find broken wikilinks, create stubs ──
  deadLinkFixer = pkgs.writeShellApplication {
    name = "huginn-dead-link-fixer";
    runtimeInputs = [ vaultCommit pkgs.python3 pkgs.coreutils ];
    text = ''
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      {
        echo "[$(date -Iseconds)] dead-link-fixer start"
        python3 ${../../muninn/dead-link-fixer.py}
        muninn-vault-commit "huginn: weekly dead-link fixer sweep"
        echo "[$(date -Iseconds)] dead-link-fixer done"
      } 2>&1 | tee -a "$logdir/dead-link-fixer.log"
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
  environment.systemPackages = [ pkgs.uv askBrain vaultCommit ];

  # let huginn-notify quote the failing unit's log lines in its alert note
  users.users.christina.extraGroups = [ "systemd-journal" ];

  # every huginn job that dies drops an alert note into _inbox (→ Home dashboard)
  systemd.services."huginn-notify@" = {
    description = "huginn: file a failure alert for %i into the vault inbox";
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = {
      Type = "oneshot";
      User = "christina";
      Group = "users";
      ExecStart = "${notify}/bin/huginn-notify %i";
    };
  };

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
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${inboxSweep}/bin/huginn-inbox-sweep";
    };
  };
  # instant filing: fire the sweep when something lands in _inbox. Only sees
  # writes made through heimdall's NFS client (the hosted Obsidian app, huginn
  # itself, alert notes) — mjolnir's `capture` writes bypass this inotify, but
  # capture already ssh-nudges the service directly. The timer below is the
  # slow safety net for anything both mechanisms miss.
  systemd.paths."huginn-inbox-sweep" = {
    description = "huginn: watch _inbox and sweep on change";
    wantedBy = [ "paths.target" ];
    unitConfig.RequiresMountsFor = vault;
    pathConfig = {
      PathChanged = "${vault}/_inbox";
      TriggerLimitIntervalSec = "2min";   # coalesce bursts of captures
      TriggerLimitBurst = 3;
    };
  };
  systemd.timers."huginn-inbox-sweep" = {
    description = "huginn inbox sweep schedule (fallback; path unit does the real work)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 08,14,20:15:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  systemd.services."huginn-daily-digest" = {
    description = "huginn: append a nightly digest to today's journal note";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
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
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
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

  # ── graphify: the vault (notes) graph — the OS's memory, queryable over MCP ──
  systemd.services."huginn-graphify-vault" = {
    description = "huginn: rebuild the vault knowledge graph (notes only)";
    after = [ "network-online.target" "huginn-graphify-setup.service" ];
    wants = [ "network-online.target" ];
    requires = [ "huginn-graphify-setup.service" ];
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${graphifyVault}/bin/huginn-graphify-vault";
    };
  };
  systemd.timers."huginn-graphify-vault" = {
    description = "huginn vault-graph rebuild schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 23:30:00";   # nightly, after the 23:00 digest
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  # ── gardener: weekly hygiene report ──
  systemd.services."huginn-gardener" = {
    description = "huginn: weekly vault hygiene report (orphans, dead links, stale)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${gardener}/bin/huginn-gardener";
    };
  };
  systemd.timers."huginn-gardener" = {
    description = "huginn gardener schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sat *-*-* 08:30:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  # ── dead-link-fixer: weekly broken-wikilink sweep ──
  systemd.services."huginn-dead-link-fixer" = {
    description = "huginn: find broken wikilinks via brain API and create stub notes";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${deadLinkFixer}/bin/huginn-dead-link-fixer";
    };
  };
  systemd.timers."huginn-dead-link-fixer" = {
    description = "huginn dead-link fixer schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 06:00:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };
}