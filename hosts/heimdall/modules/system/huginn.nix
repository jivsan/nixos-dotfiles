{ pkgs, lib, ... }:
# ── huginn — the MiniMax agent layer over the muninn vault ───────────────────
# All agents run on OpenRouter/MiniMax (OpenAI-compatible) — NO Claude, NO
# Anthropic credit. systemd-timer jobs:
#   • inbox-sweep    — MiniMax turns each _inbox note into a titled, frontmattered,
#                      MOC-linked note with archived originals and a sweep report;
#                      also path-triggered (inotify on _inbox) for instant filing.
#                      Jev picks the folder + MOC (unsure → _inbox/review/); a
#                      capture starting `todo:` or `jev:` goes to the bridge instead
#   • daily-digest   — MiniMax summarises the day into today's journal note
#   • graphify-repo  — offline code extraction + MiniMax community labeling (weekly)
#   • graphify-vault — the NOTES graph: staged copy of the vault's markdown only
#                      (no .obsidian plugin JS) → /var/lib/huginn/graphs/vault (nightly)
#   • gardener       — weekly vault hygiene report: orphans, dead links, stale notes
#   • dead-link-fixer — weekly offline sweep: dead wikilinks in filed notes → report + stub notes
#   • morning-brief  — MiniMax overnight briefing into today's journal (daily 07:45)
#   • weeknote       — MiniMax weekly review from the week's journals (Sundays 18:00)
#   • todo-board     — regathers every open checkbox into MOCs/TODO MOC.md (daily 07:00)
#   • resurface      — three >90-day-old notes back into today's journal (daily 09:00)
#   • unlinked-mentions — offline weave check: plain-text mentions that could be links
#   • health-report  — heimdall health note: failed units, timers, disk, memory
#
# Cross-cutting: every vault-writing agent auto-commits the vault git repo
# (audit trail, author huginn), and every huginn unit has OnFailure= wired to
# drop an alert note into _inbox/ so failures surface on the Home dashboard.
# Inbox-sweep alerts go directly to Resources/Reports to avoid retrigger loops.
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
      umask 0022  # nginx serves these reports through /vault
      unit="''${1:-unknown-unit}"
      dest="${vault}/_inbox"
      case "$unit" in
        huginn-inbox-sweep|huginn-inbox-sweep.service) dest="${vault}/Resources/Reports" ;;
      esac
      mkdir -p "$dest"
      f="$dest/alert-$unit-$(date +%Y%m%d-%H%M%S-%N).md"
      {
        printf -- '---\ntype: report\nagent: huginn\nstatus: failed\ncreated: %s\n---\n\n' "$(date -Iseconds)"
        echo "huginn alert: $unit FAILED on heimdall at $(date -Iseconds)."
        echo
        echo "Recent log lines:"
        echo '```'
        journalctl -u "$unit" -n 12 --no-pager -o short-iso 2>/dev/null || echo "(journal not readable)"
        echo '```'
        echo
        echo "Inspect: ssh christina@10.0.20.17 'systemctl status $unit'"
        echo
        echo '[[MOCs/Agents MOC]]'
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

  # One line per waiting capture (mtime + name). The sweep records what it saw
  # when it started; the poll below starts it again only for lines not in there.
  inboxSeen = "${agentHome}/inbox-seen";
  listCaptures = "find ${vault}/_inbox -maxdepth 1 -type f -name '*.md' ! -name README.md -printf '%T@ %f\\n'";

  # ── inbox filing: preserve full originals and file a durable sweep report ──
  inboxSweep = pkgs.writeShellApplication {
    name = "huginn-inbox-sweep";
    runtimeInputs = [ vaultCommit pkgs.python3 pkgs.findutils pkgs.coreutils ];
    text = ''
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      ${listCaptures} > ${inboxSeen} || true
      status=0
      # an empty sweep prints nothing, so the log (which the dashboard tails) only
      # gains lines when something was filed or failed
      python3 ${../../muninn/inbox.py} --vault "${vault}" 2>&1 \
        | while IFS= read -r line; do echo "[$(date -Iseconds)] $line"; done \
        | tee -a "$logdir/inbox-sweep.log" || status=$?
      muninn-vault-commit "huginn: inbox filing and report (status $status)"
      exit "$status"
    '';
  };

  # ── inbox poll: a capture written from another NFS client (mjolnir, tyr,
  # hermod) never reaches the path unit's inotify, and one that lands while a
  # sweep is running is missed by it too. Look every 20 s and start the sweep
  # for anything it has not seen. A capture that failed stays seen, so it is
  # left to the timer instead of being retried every 20 s.
  inboxPoll = pkgs.writeShellApplication {
    name = "huginn-inbox-poll";
    runtimeInputs = [ pkgs.findutils pkgs.coreutils pkgs.gnugrep pkgs.systemd ];
    text = ''
      while sleep 20; do
        state="$(systemctl is-active huginn-inbox-sweep.service || true)"
        [ "$state" = activating ] && continue   # look again once it is done
        now="$(${listCaptures})" || continue    # vault briefly unreachable
        [ -n "$now" ] || continue
        touch ${inboxSeen}
        if grep -qFxvf ${inboxSeen} <<< "$now"; then
          /run/wrappers/bin/sudo -n systemctl start --no-block huginn-inbox-sweep.service || true
        fi
      done
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

  # ── dead-link-fixer (weekly) — offline: find dead wikilinks, report, create stubs ──
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

  # ── morning brief (MiniMax, daily 07:45) — overnight facts into today's journal ──
  # Idempotent: a rerun replaces the brief block only, leaving the rest of the
  # journal note (and the 23:00 digest appended below it) untouched.
  morningBrief = pkgs.writeShellApplication {
    name = "huginn-morning-brief";
    runtimeInputs = [ llm vaultCommit pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.gawk pkgs.git pkgs.systemd ];
    text = ''
      : "''${OPENAI_API_KEY:?not set — needs /var/lib/secrets/graphify-openrouter.env}"
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      today="$(date +%F)"
      yesterday="$(date -d yesterday +%F)"
      journal="${vault}/journal/$today.md"
      log(){ echo "[$(date -Iseconds)] $*" | tee -a "$logdir/morning-brief.log"; }
      log "morning-brief start (minimax)"
      changed="$(find "${vault}" -type f -name '*.md' \
        -newermt "$yesterday 00:00:00" ! -newermt "$today 00:00:00" \
        -not -path '*/.obsidian/*' -not -path '*/agents/*' -not -path '*/_templates/*' \
        -not -path '*/graphify-out/*' -not -path '*/journal/*' -not -path '*/_inbox/*' \
        -not -name 'README.md' 2>/dev/null | sed 's|.*/||; s|\.md$||' | sort | head -40 || true)"
      inbox_n="$(find "${vault}/_inbox" -maxdepth 1 -type f -name '*.md' ! -name README.md 2>/dev/null | wc -l)"
      failed="$(systemctl list-units --failed --no-legend 2>/dev/null | wc -l)"
      commits="0"
      if [ -d "${vault}/.git" ]; then
        commits="$(git -C "${vault}" log --since="$yesterday 00:00:00" --oneline 2>/dev/null | wc -l)"
      fi
      mkdir -p "${vault}/journal"
      [ -f "$journal" ] || printf -- '---\ntype: journal\ncreated: %s\nagent: huginn\n---\n\n# %s\n' "$today" "$today" > "$journal"
      awk '/^## morning brief/{skip=1; next} skip && /^## /{skip=0} !skip' "$journal" > "$journal.tmp" \
        && mv "$journal.tmp" "$journal"
      ctx="Notes changed yesterday:
''${changed:-none}

Inbox captures waiting: $inbox_n
Vault git commits since yesterday: $commits
Failed systemd units on heimdall: $failed"
      sys="You are huginn writing Christina's morning briefing in her Obsidian vault. From the overnight facts, write a warm, concise brief: one greeting line, then 3-5 markdown bullets. Wikilink note names as [[Note Name]] exactly as listed. If nothing happened overnight, say so cheerfully in one line. Output only the brief, no preamble."
      brief="$(printf '%s' "$ctx" | muninn-llm "$sys")"
      [ -n "$brief" ] || brief="Overnight: $inbox_n capture(s) waiting, $commits vault commit(s), $failed failed unit(s). (brief model returned nothing.)"
      printf '\n## morning brief (%s)\n%s\n' "$(date +%H:%M)" "$brief" >> "$journal"
      muninn-vault-commit "huginn: morning brief for $today"
      log "morning-brief done ($inbox_n inbox, $commits commits, $failed failed)"
    '';
  };

  # ── weeknote (MiniMax, Sundays 18:00) — the week's journals → journal/YYYY-Www.md ──
  # Fully regenerated each run, so a manual rerun after a quiet Sunday re-weaves
  # the same week rather than stacking a second note.
  weeknote = pkgs.writeShellApplication {
    name = "huginn-weeknote";
    runtimeInputs = [ llm vaultCommit pkgs.coreutils pkgs.findutils pkgs.gnused ];
    text = ''
      : "''${OPENAI_API_KEY:?not set — needs /var/lib/secrets/graphify-openrouter.env}"
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      week="$(date +%G-W%V)"
      note="${vault}/journal/$week.md"
      log(){ echo "[$(date -Iseconds)] $*" | tee -a "$logdir/weeknote.log"; }
      log "weeknote start for $week (minimax)"
      ctx=""
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        ctx="$ctx"$'\n'"--- $(basename "$f" .md) ---"$'\n'"$(sed '/^---$/,/^---$/d' "$f" | head -c 1200)"
      done < <(find "${vault}/journal" -maxdepth 1 -name '20*.md' -mtime -8 2>/dev/null | sort | head -14)
      ncount="$(find "${vault}" -type f -name '*.md' -mtime -7 \
        -not -path '*/.obsidian/*' -not -path '*/agents/*' -not -path '*/_templates/*' \
        -not -path '*/graphify-out/*' 2>/dev/null | wc -l)"
      mkdir -p "${vault}/journal"
      printf -- '---\ntype: journal\nagent: huginn\nweek: %s\ncreated: %s\n---\n\n# Week %s\n' \
        "$week" "$(date -Iseconds)" "$week" > "$note"
      if [ -z "$ctx" ]; then
        body="- A quiet week — no journal entries."
      else
        sys="You are huginn writing Christina's weekly review in her Obsidian vault. From this week's journal entries, write three sections: '## Highlights' with 3-6 bullets (wikilink notes as [[Name]] exactly as written), '## Threads' naming 2-3 ongoing themes, and '## Open loops' with anything left unfinished. Concise and warm, no preamble."
        body="$(printf 'Notes touched in the last 7 days: %s\n%s' "$ncount" "$ctx" | muninn-llm "$sys")"
        [ -n "$body" ] || body="- ($ncount notes touched this week; the review model returned nothing.)"
      fi
      printf '%s\n\n[[Home MOC]]\n' "$body" >> "$note"
      muninn-vault-commit "huginn: weeknote $week"
      log "weeknote done → journal/$week.md ($ncount notes this week)"
    '';
  };

  # ── todo-board (daily 07:00) — every open checkbox → MOCs/TODO MOC.md ──
  # Offline; only rewrites the MOC when the gathered set actually changed, so
  # quiet days leave no commit churn.
  todoBoard = pkgs.writeShellApplication {
    name = "huginn-todo-board";
    runtimeInputs = [ vaultCommit pkgs.coreutils pkgs.gnugrep pkgs.gawk ];
    text = ''
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      moc="${vault}/MOCs/TODO MOC.md"
      mkdir -p "${vault}/MOCs"
      tmp="$(mktemp)"
      {
        printf -- '---\ntype: moc\nagent: huginn\nupdated: %s\n---\n\n' "$(date -Iseconds)"
        echo '# TODO MOC'
        echo
        echo 'Every open checkbox in the vault, regathered nightly by huginn.'
        echo
        grep -rn --include='*.md' -E '^[[:space:]]*[-*] \[ \]' "${vault}" \
          --exclude-dir=.obsidian --exclude-dir=.git --exclude-dir=.trash \
          --exclude-dir=agents --exclude-dir=_templates --exclude-dir=graphify-out \
          --exclude-dir=_inbox 2>/dev/null \
          | grep -v "^${vault}/MOCs/TODO MOC.md:" \
          | sort \
          | awk -F: -v v="${vault}/" '{
              f = $1; sub(v, "", f)
              $1 = ""; $2 = ""; sub(/^::/, "")
              if (f != prev) {
                if (prev != "") print ""
                n = f; sub(/\.md$/, "", n); gsub(".*/", "", n)
                printf "## [[%s]]\n_%s_\n", n, f
                prev = f
              }
              sub(/^[[:space:]]*/, "")
              print
            }' \
          || true
      } > "$tmp"
      open_n="$(grep -c '^[-*] \[ \]' "$tmp" || true)"
      if [ -f "$moc" ] && cmp -s "$tmp" "$moc"; then
        rm -f "$tmp"
        echo "[$(date -Iseconds)] todo-board: unchanged ($open_n open)" | tee -a "$logdir/todo-board.log"
      else
        chmod 0644 "$tmp"   # the vault must stay group-readable over the odyn NFS mapall
        mv "$tmp" "$moc"
        muninn-vault-commit "huginn: TODO board refresh ($open_n open)"
        echo "[$(date -Iseconds)] todo-board: $open_n open loops → MOCs/TODO MOC.md" | tee -a "$logdir/todo-board.log"
      fi
    '';
  };

  # ── resurface (daily 09:00) — three forgotten notes back into the journal ──
  # Spaced repetition for a personal vault: pure chance, no LLM, idempotent per day.
  resurface = pkgs.writeShellApplication {
    name = "huginn-resurface";
    runtimeInputs = [ vaultCommit pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.gawk ];
    text = ''
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      today="$(date +%F)"
      journal="${vault}/journal/$today.md"
      log(){ echo "[$(date -Iseconds)] $*" | tee -a "$logdir/resurface.log"; }
      log "resurface start"
      picks="$(find "${vault}" -type f -name '*.md' -mtime +90 \
        -not -path '*/.obsidian/*' -not -path '*/agents/*' -not -path '*/_templates/*' \
        -not -path '*/graphify-out/*' -not -path '*/journal/*' -not -path '*/_inbox/*' \
        -not -path '*/MOCs/*' -not -path '*/Resources/Reports/*' -not -name 'README.md' 2>/dev/null \
        | shuf -n 3 || true)"
      if [ -z "$picks" ]; then
        log "resurface: vault too young — nothing older than 90 days"
        exit 0
      fi
      mkdir -p "${vault}/journal"
      [ -f "$journal" ] || printf -- '---\ntype: journal\ncreated: %s\nagent: huginn\n---\n\n# %s\n' "$today" "$today" > "$journal"
      awk '/^## resurfaced memories/{skip=1; next} skip && /^## /{skip=0} !skip' "$journal" > "$journal.tmp" \
        && mv "$journal.tmp" "$journal"
      {
        printf '\n## resurfaced memories (%s)\n' "$(date +%H:%M)"
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          name="$(basename "$f" .md)"
          snip="$(sed '/^---$/,/^---$/d' "$f" 2>/dev/null | grep -m1 -v '^[[:space:]]*$' | cut -c1-200)"
          printf -- '- [[%s]] — %s\n' "$name" "$snip"
        done <<< "$picks"
      } >> "$journal"
      muninn-vault-commit "huginn: resurfaced memories for $today"
      log "resurface done ($(printf '%s' "$picks" | wc -l) notes)"
    '';
  };

  # ── unlinked-mentions (Fridays 07:00) — offline weave check ──
  unlinkedMentions = pkgs.writeShellApplication {
    name = "huginn-unlinked-mentions";
    runtimeInputs = [ vaultCommit pkgs.python3 pkgs.coreutils ];
    text = ''
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      {
        echo "[$(date -Iseconds)] unlinked-mentions start"
        python3 ${../../muninn/unlinked-mentions.py} --vault "${vault}"
        muninn-vault-commit "huginn: weekly unlinked-mentions report"
        echo "[$(date -Iseconds)] unlinked-mentions done"
      } 2>&1 | tee -a "$logdir/unlinked-mentions.log"
    '';
  };

  # ── health-report (Mondays 07:30) — heimdall's own health note, offline ──
  healthReport = pkgs.writeShellApplication {
    name = "huginn-health-report";
    runtimeInputs = [ vaultCommit pkgs.coreutils pkgs.systemd pkgs.procps pkgs.gawk ];
    text = ''
      logdir="${vault}/agents/logs"; mkdir -p "$logdir"
      day="$(date +%F)"
      mkdir -p "${vault}/Resources/Reports"
      report="${vault}/Resources/Reports/health-$day.md"
      failed="$(systemctl list-units --failed --no-legend 2>/dev/null || true)"
      {
        printf -- '---\ntype: report\nagent: huginn\ncreated: %s\n---\n\n' "$(date -Iseconds)"
        echo "# heimdall health — $day"
        echo
        echo '## failed units'
        echo '```'
        echo "''${failed:-(none — all quiet)}"
        echo '```'
        echo
        echo '## huginn + muninn timers'
        echo '```'
        systemctl list-timers 'huginn-*' 'muninn-*' --no-pager 2>/dev/null || true
        echo '```'
        echo
        echo '## disk'
        echo '```'
        df -h / /var/lib "${vault}" 2>/dev/null | awk 'NR == 1 || !seen[$1]++'
        echo '```'
        echo
        echo '## memory'
        echo '```'
        free -h
        echo '```'
        echo
        echo '## uptime'
        echo '```'
        uptime
        echo '```'
        echo
        echo '[[MOCs/Agents MOC]]'
      } > "$report" 2>&1
      muninn-vault-commit "huginn: heimdall health report $day"
      echo "[$(date -Iseconds)] health-report done → Resources/Reports/health-$day.md" | tee -a "$logdir/health-report.log"
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
  # No NoNewPrivileges here: the poll starts the sweep through sudo, like the bridge.
  systemd.services."huginn-inbox-poll" = {
    description = "huginn: start the inbox sweep for captures written over NFS";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = {
      User = "christina";
      Group = "users";
      ExecStart = "${inboxPoll}/bin/huginn-inbox-poll";
      Restart = "always";
      RestartSec = "30s";
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
    description = "huginn: find dead wikilinks in filed notes, report them and create stub notes";
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

  # ── morning brief: overnight facts → today's journal, before the day starts ──
  systemd.services."huginn-morning-brief" = {
    description = "huginn: morning briefing into today's journal note";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${morningBrief}/bin/huginn-morning-brief";
    };
  };
  systemd.timers."huginn-morning-brief" = {
    description = "huginn morning brief schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 07:45:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  # ── weeknote: the week's journals woven into a weekly review ──
  systemd.services."huginn-weeknote" = {
    description = "huginn: weekly review note from the week's journals";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${weeknote}/bin/huginn-weeknote";
    };
  };
  systemd.timers."huginn-weeknote" = {
    description = "huginn weeknote schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 18:00:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };

  # ── todo-board: every open checkbox in the vault → the TODO MOC ──
  systemd.services."huginn-todo-board" = {
    description = "huginn: regather open checkboxes into the TODO MOC";
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${todoBoard}/bin/huginn-todo-board";
    };
  };
  systemd.timers."huginn-todo-board" = {
    description = "huginn TODO board schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 07:00:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  # ── resurface: spaced repetition — forgotten notes back into the journal ──
  systemd.services."huginn-resurface" = {
    description = "huginn: resurface three >90-day-old notes into today's journal";
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${resurface}/bin/huginn-resurface";
    };
  };
  systemd.timers."huginn-resurface" = {
    description = "huginn resurface schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 09:00:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  # ── unlinked-mentions: plain-text mentions that could be wikilinks ──
  systemd.services."huginn-unlinked-mentions" = {
    description = "huginn: weekly unlinked-mentions weave report";
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${unlinkedMentions}/bin/huginn-unlinked-mentions";
    };
  };
  systemd.timers."huginn-unlinked-mentions" = {
    description = "huginn unlinked-mentions schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Fri *-*-* 07:00:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  # ── health-report: heimdall's own health note (failed units, disk, memory) ──
  systemd.services."huginn-health-report" = {
    description = "huginn: weekly heimdall health report into the vault";
    unitConfig = {
      RequiresMountsFor = vault;
      OnFailure = [ "huginn-notify@%n.service" ];
    };
    serviceConfig = agentServiceConfig // {
      ExecStart = "${healthReport}/bin/huginn-health-report";
    };
  };
  systemd.timers."huginn-health-report" = {
    description = "huginn health report schedule";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon *-*-* 07:30:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}
