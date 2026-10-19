{ inputs, config, lib, ... }:
let
  # one key for every mcp server over ssh, for the gateway (hermes) and my cli alike.
  # root:hermes 0640 works for both: ssh only checks the permissions of keys the caller owns.
  # its public half is allowed on heimdall for graphify only, on mjolnir for blender and wowx only
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
    # kimi k3 on openrouter (OPENROUTER_API_KEY=... in /etc/hermes/env), sail research only: cheapest k3 output.
    # the codex login is still in auth.json, so provider "openai-codex" + "gpt-6-astra" switches back
    settings.model = {
      provider = "openrouter";
      default = "moonshotai/kimi-k3";
    };
    settings.provider_routing.only = [ "sail-research/fp4" ];
    # tool_search off: through its bridge kimi dropped the arguments (graphify's `question`),
    # so mcp tools with arguments never ran. called directly they work
    settings.tools.tool_search.enabled = "off";
    # kimi still reasons, it's just not printed: every reasoning line redrew the cli's status bar
    # and it flickered badly over ssh. `/reasoning show` brings it back for one session
    settings.display.show_reasoning = false;
    # claude's skills, notes (skill `claude-memory`) and homelab context, pushed from mjolnir by
    # `claude-to-yggdrasil`. not in this repo since it's public; the context lands in the workspace as AGENTS.md
    settings.skills.external_dirs = [ "/var/lib/hermes/claude/skills" ];
    # the index of claude's notes (~26 KB) goes into every session, the notes are read on demand
    settings.skills.auto_load = [ "claude-memory" ];
    # brave: BRAVE_SEARCH_API_KEY=... in /etc/hermes/env, free tier 2,000 a month, search only (can't read pages).
    # a failed brave call is retried on the free keyless backends, brave again on the next search
    settings.web.search_backend = "brave-free";
    # pages via firecrawl's keyless public tier; when it throttles hermes moves on to keenable, exa and parallel
    settings.web.extract_backend = "firecrawl";
    environmentFiles = [ "/etc/hermes/env" ];
    environment = {
      API_SERVER_ENABLED = "true";
      API_SERVER_HOST = "0.0.0.0";
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
      # Homarr's own MCP server on heimdall: boards, apps, widgets, integrations.
      # HOMARR_API_KEY (a Homarr API key, acts as christina) is in /etc/hermes/env;
      # hermes fills in ${VAR} itself, so the key never lands in this public repo.
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
  # /mnt/studio-cache: `mimir-blender` makes its job folders there
  systemd.services.hermes-agent.serviceConfig.ReadWritePaths =
    [ "-/mnt/muninn" "-/mnt/hermes-wowx" "-/mnt/studio-cache" ];

  # gateway api, the brain bridge on heimdall calls it
  networking.firewall.allowedTCPPorts = [ 8642 ];

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
    ]
  ];
}
