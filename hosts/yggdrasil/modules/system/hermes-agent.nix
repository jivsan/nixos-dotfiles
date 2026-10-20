{ inputs, config, lib, pkgs, agentBrowser, ... }:
let
  # one key for every mcp server over ssh, for the gateway (hermes) and my cli alike.
  # root:hermes 0640 works for both: ssh only checks the permissions of keys the caller owns.
  # its public half is allowed on heimdall for graphify only, on mjolnir for blender, wowx and dotfiles only
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
in
{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    # kimi k3 on my kimi pro plan (KIMI_API_KEY=sk-kimi-... in /etc/hermes/env), on the overseas
    # endpoint (api.kimi.ai; api.kimi.com is the china one). pro serves k3 with 1m context and images
    settings.providers.kimi-plan = {
      api = "https://api.kimi.ai/coding/v1";
      key_env = "KIMI_API_KEY";
      transport = "chat_completions";
      models.k3 = { context_length = 1048576; supports_vision = true; };
    };
    settings.model = {
      provider = "custom:kimi-plan";
      default = "k3";
      context_length = 1048576;
      supports_vision = true;
      # hermes knows kimi only by api.kimi.com, so its kimi tool-call fix is switched on by hand
      reasoning_echo = true;
    };
    # when the plan fails (5-hour limit, monthly total, outage) the turn moves to kimi k3 on openrouter
    # (OPENROUTER_API_KEY=... in /etc/hermes/env), sail research only: cheapest k3 output, also 1m context.
    # the next message tries the plan again first. the codex login is still in auth.json, so provider
    # "openai-codex" + "gpt-6-astra" switches back to codex
    settings.fallback_providers = [ { provider = "openrouter"; model = "moonshotai/kimi-k3"; } ];
    settings.provider_routing.only = [ "sail-research/fp4" ];
    # tool_search on again (2026-10-20, now on the kimi plan): mcp tools are loaded only when needed
    # instead of sending all ~240 tool descriptions with every call (homarr alone was 41% of each one).
    # it was off because kimi through openrouter/sail dropped the arguments in its bridge (graphify's
    # `question`); if that comes back, "off" again
    settings.tools.tool_search.enabled = "on";
    # never called since 2026-10-03, ~2,900 tokens per call: scheduled jobs, past-session search,
    # text to speech. browser and web search stay
    settings.agent.disabled_toolsets = [ "cronjob" "session_search" "tts" ];
    # kimi still reasons, it's just not printed: every reasoning line redrew the cli's status bar
    # and it flickered badly over ssh. `/reasoning show` brings it back for one session
    settings.display.show_reasoning = false;
    # claude's skills, notes (skill `claude-memory`) and homelab context, pushed from mjolnir by
    # `claude-to-yggdrasil`. not in this repo since it's public; the context lands in the workspace as AGENTS.md
    settings.skills.external_dirs = [ "/var/lib/hermes/claude/skills" ];
    # the index of claude's notes (~26 KB) goes into every session, the notes are read on demand
    settings.skills.auto_load = [ "claude-memory" ];
    # search through my own searxng on heimdall (search.oryxserver.org, its json api): no key, no monthly
    # limit, nothing leaves the house but the searches themselves. search only (can't read pages); a failed
    # call is retried on the free keyless backends. brave's key stays in /etc/hermes/env for going back
    settings.web.search_backend = "searxng";
    # pages via firecrawl's keyless public tier; when it throttles hermes moves on to keenable, exa and parallel
    settings.web.extract_backend = "firecrawl";
    # a browser to look at what it builds, like my homarr board (modules/apps/agent-browser.nix).
    # logins go in hermes' vault (`hermes vault add`): filled in on the page, the model never sees them
    extraPackages = [ agentBrowser ];
    environmentFiles = [ "/etc/hermes/env" ];
    environment = {
      API_SERVER_ENABLED = "true";
      API_SERVER_HOST = "0.0.0.0";
      SEARXNG_URL = "https://search.oryxserver.org";
      # hermes looks for chromium itself before it offers the browser tools (the cli reads it from .env too)
      AGENT_BROWSER_EXECUTABLE_PATH = "${pkgs.chromium}/bin/chromium";
    };
    mcpServers = {
      graphify-dotfiles = graphify "dotfiles";
      graphify-vault = graphify "vault";
      # on mjolnir the key's forced command starts the server named by the last word
      # (hosts/mjolnir/modules/system/yggdrasil-link.nix). blender needs my blender open
      # (extension on mjolnir's localhost:9876); wowx can take minutes on a building, hence the timeout
      blender = {
        command = "ssh";
        args = ssh ++ [ "christina@10.0.20.100" "blender" ];
      };
      wowx = {
        command = "ssh";
        args = ssh ++ [ "christina@10.0.20.100" "wowx" ];
        timeout = 300;
      };
      # my nixos-dotfiles on mjolnir: files and git in hermes' own worktree there
      # (~/nixos-dotfiles-hermes, branch hermes), no shell and no push. i merge what i want
      dotfiles = {
        command = "ssh";
        args = ssh ++ [ "christina@10.0.20.100" "dotfiles" ];
      };
      dotfiles-git = {
        command = "ssh";
        args = ssh ++ [ "christina@10.0.20.100" "dotfiles-git" ];
      };
      # homarr's mcp server: boards, apps, widgets, integrations.
      # HOMARR_API_KEY (a homarr api key, acts as me) is in /etc/hermes/env,
      # hermes fills in ${VAR} itself so the key stays out of this public repo
      homarr = {
        url = "https://home.oryxserver.org/api/mcp";
        headers.ApiKey = "\${HOMARR_API_KEY}";
      };
    };
  };

  programs.ssh.knownHosts."10.0.20.100".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIly980X2Lw7E3AiWvKeNs042hmgTaVEFzCcq6Ugqxiw";

  # the vault again at /mnt/muninn: hermes can't enter my home (0700), and odyn maps every client
  # to the vault owner so it can write there. the unit is ProtectSystem=strict, so a mount without
  # a ReadWritePaths entry is read-only inside it. the brain bridge on heimdall tells hermes this path
  fileSystems."/mnt/muninn" = {
    inherit (config.fileSystems."/home/christina/muninn") device fsType options;
  };
  # /mnt/studio-cache: `mimir-blender` makes its job folders there.
  # /mnt/ratatoskr: screenshots, snippets and files between me and hermes (modules/system/ratatoskr.nix)
  systemd.services.hermes-agent.serviceConfig.ReadWritePaths =
    [ "-/mnt/muninn" "-/mnt/hermes-wowx" "-/mnt/studio-cache" "-/mnt/ratatoskr" ];

  # gateway api: only the brain bridge on heimdall calls it (with the api key), so only heimdall gets in
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s 10.0.20.17 --dport 8642 -j nixos-fw-accept
  '';

  users.users.christina.extraGroups = [ config.services.hermes-agent.group ];

  # the cli won't reach the gateway while .hermes is group-writable (unsafe_control_permissions),
  # and the module sets 2770 on every activation and in tmpfiles. so: chmod g-w right after its
  # setup, and my tmpfiles line goes first (tmpfiles keeps the first line for a path)
  system.activationScripts.hermes-home-not-group-writable =
    lib.stringAfter [ "hermes-agent-setup" ] "chmod g-w /var/lib/hermes/.hermes";
  systemd.tmpfiles.rules = lib.mkMerge [
    (lib.mkBefore [ "d /var/lib/hermes/.hermes 2750 hermes hermes - -" ])
    [
      "d /etc/hermes     0755 root root -"
      "f /etc/hermes/env 0600 root root -"
      "d /var/lib/hermes-ssh 0750 root hermes -"
      "z /var/lib/hermes-ssh/id_ed25519 0640 root hermes -"
      "d /var/lib/hermes/claude 2770 hermes hermes -"
      # ~/hermes-workspace links here: what i put in it stays editable for hermes, whatever my umask
      "a+ /var/lib/hermes/workspace - - - - default:group:hermes:rwx,group:hermes:rwx"
    ]
  ];
}
