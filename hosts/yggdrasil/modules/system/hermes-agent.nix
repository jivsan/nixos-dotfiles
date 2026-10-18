{ inputs, config, lib, ... }:
let
  # One key for every MCP server reached over SSH, used by the gateway (user
  # hermes) and by christina's CLI alike. root:hermes 0640: ssh only checks the
  # permissions of keys the caller owns, so both accept it. Made on hermod
  # (comment hermes-mcp@hermod) and carried over to yggdrasil. Its public half is authorized
  # on heimdall for graphify only and on mjolnir for the blender and wowx MCP servers only.
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
    # Kimi K3 through OpenRouter (OPENROUTER_API_KEY in /etc/hermes/env), on Sail
    # Research only: the cheapest output price for K3. The Codex login stays in
    # auth.json, so provider "openai-codex" + "gpt-6-astra" switches back.
    settings.model = {
      provider = "openrouter";
      default = "moonshotai/kimi-k3";
    };
    settings.provider_routing.only = [ "sail-research/fp4" ];
    # Every tool goes to the model as is. With the tool_search bridge Kimi K3
    # dropped the arguments it passed through tool_call (graphify's `question`),
    # so MCP tools with arguments never ran; called directly they work on Sail.
    settings.tools.tool_search.enabled = "off";
    # Claude Code's skills, memory notes (skill `claude-memory`) and homelab
    # context, copied from mjolnir by `claude-to-yggdrasil`. Not in this repo: it is
    # public. The context lands in the workspace as AGENTS.md.
    settings.skills.external_dirs = [ "/var/lib/hermes/claude/skills" ];
    # The index of Claude's notes (about 26 KB) is in every session, CLI, API and
    # cron alike, so she never has to ask for it; the notes are read on demand.
    settings.skills.auto_load = [ "claude-memory" ];
    # With the Codex login hermes picks OpenAI's native web search as its one web
    # backend, and that backend can only search: every web_extract failed. Pages
    # are read through Firecrawl's public tier instead, which needs no key; when
    # it throttles, hermes moves on to Keenable, Exa and Parallel by itself.
    settings.web.extract_backend = "firecrawl";
    environmentFiles = [ "/etc/hermes/env" ];
    environment = {
      API_SERVER_ENABLED = "true";
      API_SERVER_HOST = "0.0.0.0";
    };
    mcpServers = {
      graphify-dotfiles = graphify "dotfiles";
      graphify-vault = graphify "vault";
      # MCP servers on mjolnir: the key's forced command there starts the one
      # named by the last word (hosts/mjolnir/modules/yggdrasil-link.nix). blender
      # drives the extension on mjolnir's localhost:9876, so Blender must be open;
      # wowx finds, exports and upscales WoW models into /mnt/hermes-wowx, which
      # is mounted here too. A wowx run takes 12 to 20 s, a building minutes.
      blender = {
        command = "ssh";
        args = ssh ++ [ "christina@10.0.20.100" "blender" ];
      };
      wowx = {
        command = "ssh";
        args = ssh ++ [ "christina@10.0.20.100" "wowx" ];
        timeout = 300;
      };
    };
  };

  programs.ssh.knownHosts."10.0.20.100".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIly980X2Lw7E3AiWvKeNs042hmgTaVEFzCcq6Ugqxiw";

  # The gateway runs as the hermes user, which cannot enter /home/christina
  # (0700), so it never saw the vault at ~/muninn. Mount the same export where
  # the service can reach it; odyn squashes every client to the vault owner, so
  # hermes reads and writes there. The unit is ProtectSystem=strict: without the
  # ReadWritePaths entry, a vault already mounted when the gateway starts would
  # be read-only inside it. The bridge on heimdall tells hermes this path.
  fileSystems."/mnt/muninn" = {
    inherit (config.fileSystems."/home/christina/muninn") device fsType options;
  };
  systemd.services.hermes-agent.serviceConfig.ReadWritePaths = [ "-/mnt/muninn" "-/mnt/hermes-wowx" ];

  networking.firewall.allowedTCPPorts = [ 8642 ];

  users.users.christina.extraGroups = [ config.services.hermes-agent.group ];

  # The CLI refuses to reach the gateway while hermes' home is group-writable
  # (unsafe_control_permissions), but the module sets it to 2770 on every activation
  # and in tmpfiles. Everything runs as the hermes user here, so the group only reads:
  # take the write bit away right after the module's setup, and put our tmpfiles
  # line first (tmpfiles keeps the first line for a path and ignores the duplicate).
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
