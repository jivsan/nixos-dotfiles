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
  model   = "claude-sonnet-4-6";        # routine jobs; bump to claude-opus-4-8 for heavier reasoning
  agentHome = "/var/lib/huginn";        # HOME for claude-code + graphify (off christina's real home)
  localBin  = "${agentHome}/.local/bin";

  # Named note-agent runner: $1 = job name (for the log), prompt arrives on stdin.
  runAgent = pkgs.writeShellApplication {
    name = "huginn-run";
    runtimeInputs = [ pkgs.claude-code pkgs.coreutils ];
    text = ''
      job="''${1:?usage: huginn-run <job-name> (prompt on stdin)}"
      logdir="${vault}/agents/logs"
      mkdir -p "$logdir"
      prompt="$(cat)"
      cd "${vault}" || exit 1
      {
        echo "[$(date -Iseconds)] huginn/$job start (model ${model})"
        claude -p "$prompt" --model "${model}" --dangerously-skip-permissions
        echo "[$(date -Iseconds)] huginn/$job done"
      } 2>&1 | tee -a "$logdir/$job.log"
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

  inboxPrompt = pkgs.writeText "huginn-inbox-sweep.md" ''
    You are huginn, an automated agent maintaining the "muninn" Obsidian vault.
    Read the vault's CLAUDE.md first and follow it exactly.

    Task — inbox sweep:
    - Look at the notes in `_inbox/` (ignore README.md and any dotfiles).
    - For each captured note: give it a clear title, add/repair frontmatter
      (type, status, tags, created, agent: huginn), tidy the body, wikilink it to
      at least one relevant MOC in `MOCs/`, then MOVE it out of `_inbox/` into the
      most fitting folder (Areas/ or Resources/).
    - If `_inbox/` has nothing actionable, make NO changes at all and stop.
    - Never modify `.obsidian/`, `_templates/`, `agents/`, `graphify-out/`, or `Home.md`.
    - Keep edits minimal and factual; never invent content.
    End with a one-line summary of what you filed.
  '';

  digestPrompt = pkgs.writeText "huginn-daily-digest.md" ''
    You are huginn, an automated agent maintaining the "muninn" Obsidian vault.
    Read the vault's CLAUDE.md first and follow it exactly.

    Task — nightly digest:
    - Today's date is the real current date (YYYY-MM-DD).
    - Find notes created or modified today, skipping `.obsidian/`, `agents/`,
      `_templates/`, `graphify-out/`.
    - Append to `journal/<YYYY-MM-DD>.md` (create it if missing, with frontmatter
      type: journal, created, agent: huginn) a section `## huginn digest` with 3-6
      bullets summarising the day, each wikilinking the note it refers to, plus a
      trailing wikilink to [[Home MOC]].
    - If nothing changed today, write a single bullet saying so.
    End with a one-line summary.
  '';

  # Common hardening + auth for the LLM-calling jobs.
  agentServiceConfig = {
    Type = "oneshot";
    User = "christina";
    Group = "users";
    Environment = [ "HOME=${agentHome}" ];
    EnvironmentFile = "/var/lib/secrets/claude-code.env";
    NoNewPrivileges = true;   # block sudo/setuid escalation despite passwordless-sudo christina
    ProtectHome = true;       # hide /home/christina; HOME is ${agentHome}
    PrivateTmp = true;
  };
in
{
  # claude-code is unfree; allow just it — heimdall otherwise stays fully free.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

  environment.systemPackages = [ pkgs.claude-code pkgs.uv ];

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
      ExecStart = "${runAgent}/bin/huginn-run inbox-sweep";
      StandardInput = "file:${inboxPrompt}";
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
      ExecStart = "${runAgent}/bin/huginn-run daily-digest";
      StandardInput = "file:${digestPrompt}";
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
