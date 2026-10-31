{ inputs, pkgs, ... }:

# grok build (`grok`, xai's terminal agent) on yggdrasil, in herdr next to claude, codex and hermes.
# it gets my mcp servers over the lan with the same restricted key as hermes and claude
# (hermes-agent.nix): graphify on heimdall, blender and wowx on mjolnir, homarr. nothing of mine is
# reachable from xai's cloud. log in once with `grok login --device-auth` (token in ~/.grok/auth.json).
# homarr: grok's own api key (made in homarr, so i can revoke it alone) in ~/.config/grok/homarr-token.
# grok reads that file on every request, so the key isn't in its environment, its shell or this repo
let
  system = pkgs.stdenv.hostPlatform.system;
  grok-pkg = inputs.llm-agents.packages.${system}.grok;

  # numtide's package already turns off self-update. the wrapper also turns off crash reports and
  # usage numbers by env (the pins below do that too), and drops grok's second binary `agent`
  grok = pkgs.symlinkJoin {
    name = "grok-${grok-pkg.version}";
    paths = [ grok-pkg ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm -f $out/bin/agent
      wrapProgram $out/bin/grok \
        --set GROK_TELEMETRY_ENABLED false \
        --set GROK_FEEDBACK_ENABLED false \
        --set DISABLE_TELEMETRY 1 \
        --set DISABLE_ERROR_REPORTING 1
    '';
  };

  mcpKey = "/var/lib/hermes-ssh/id_ed25519";
  ssh = [ "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "-o" "IdentitiesOnly=yes" "-i" mcpKey ];
  graphify = graph: {
    command = "ssh";
    args = ssh ++ [
      "christina@10.0.20.17"
      "env" "HOME=/var/lib/huginn" "/var/lib/huginn/.local/bin/graphify-mcp"
      "/var/lib/huginn/graphs/${graph}/graph.json"
    ];
  };

  toml = pkgs.formats.toml { };

  # /etc/grok/requirements.toml: root-owned, the top layer. my ~/.grok/config.toml, env vars and
  # xai's remote settings can't undo what's here
  requirements = {
    # no usage numbers, no feedback prompts, no session traces, no workspace snapshots, no repo index
    features = { telemetry = false; feedback = false; codebase_indexing = false; };
    telemetry.trace_upload = false;
    harness.disable_workspace_teleport = true;
    cli.auto_update = false;
    # grok picks up claude's and codex's setup by default: claude's mcp servers (with claude's homarr
    # key), hooks (herdr's), skills (bridge, mimir bakes, my blender), and later old chats (sessions).
    # all off. claude.agents stays on: grok reads CLAUDE.md, so it gets my rules too
    compat = {
      claude = { mcps = false; hooks = false; skills = false; rules = false; sessions = false; };
      codex = { hooks = false; skills = false; sessions = false; };
      cursor = { mcps = false; hooks = false; skills = false; rules = false; agents = false; sessions = false; };
    };
    permission = {
      deny = [
        # these blender tools save a copy of my open file next to it and start a second blender
        "MCPTool(blender__*_for_cli)"
        # no renders without my yes, not even a viewport picture
        "MCPTool(blender__render_*)"
        # homarr: nothing that deletes, makes keys, users or invites, sets secrets, stops containers,
        # turns off pi-hole or switches things in my home. no raw requests either: integration_request
        # sends anything (even DELETE) to proxmox, truenas, home assistant… with homarr's saved logins
        "MCPTool(homarr__*delete*)"
        "MCPTool(homarr__*ecret*)"
        "MCPTool(homarr__apiKeys_*)"
        "MCPTool(homarr__invite_*)"
        "MCPTool(homarr__user_create)"
        "MCPTool(homarr__docker_*All)"
        "MCPTool(homarr__docker_reconcileServices)"
        "MCPTool(homarr__dnsHole_disable)"
        "MCPTool(homarr__smartHome_switchEntity)"
        "MCPTool(homarr__smartHome_executeAutomation)"
        "MCPTool(homarr__integration_request)"
        # keys: its own, claude's, home assistant's, ssh
        "Read(/home/christina/.config/grok/**)"
        "Read(/home/christina/.grok/auth.json)"
        "Read(/home/christina/.grok/mcp_credentials.json)"
        "Read(/home/christina/.config/homarr.env)"
        "Read(/home/christina/.config/claude/**)"
        "Read(/home/christina/.ssh/**)"
        "Read(/var/lib/hermes-ssh/**)"
        "Bash(*homarr-token*)"
        "Bash(*homarr.env*)"
        "Bash(*auth.json*)"
        "Bash(*mcp_credentials*)"
        "Bash(*ha-token*)"
        "Bash(*id_ed25519*)"
      ];
      # asks every time: code in my live blender. (always-approve skips asks, the denies still hold)
      ask = [ "MCPTool(blender__execute_blender_code)" ];
    };
  };

  # /etc/grok/managed_config.toml: my defaults. my own ~/.grok/config.toml wins over these
  managed = {
    mcp_servers = {
      graphify-dotfiles = graphify "dotfiles";
      graphify-vault = graphify "vault";
      # the key's forced command on mjolnir starts the server named by the last word
      # (hosts/mjolnir/modules/system/yggdrasil-link.nix). blender needs my blender open
      blender = { command = "ssh"; args = ssh ++ [ "christina@10.0.20.100" "blender" ]; startup_timeout_sec = 120; };
      wowx = { command = "ssh"; args = ssh ++ [ "christina@10.0.20.100" "wowx" ]; };
      homarr = {
        url = "https://home.oryxserver.org/api/mcp";
        bearer_token_file = "~/.config/grok/homarr-token";
      };
    };
    # one call at a time into my live blender: no parallel child sessions
    subagents.enabled = false;
    # keys stay out of grok's shell, and no .envrc
    shell_environment_policy.ignore_default_excludes = false;
    session.load_envrc = false;
  };
in
{
  nix.settings = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  environment.systemPackages = [ grok ];

  # real files, not store links (grok warns about links)
  environment.etc."grok/requirements.toml" = {
    source = toml.generate "grok-requirements.toml" requirements;
    mode = "0444";
  };
  environment.etc."grok/managed_config.toml" = {
    source = toml.generate "grok-managed_config.toml" managed;
    mode = "0444";
  };

  systemd.tmpfiles.rules = [
    "d /home/christina/.config/grok 0700 christina users -"
    "f /home/christina/.config/grok/homarr-token 0600 christina users -"
  ];
}
