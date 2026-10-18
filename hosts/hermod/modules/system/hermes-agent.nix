{ inputs, config, ... }:
let
  # One key for every MCP server reached over SSH, used by the gateway (user
  # hermes) and by christina's CLI alike. root:hermes 0640: ssh only checks the
  # permissions of keys the caller owns, so both accept it. Made once on hermod
  # with ssh-keygen (comment hermes-mcp@hermod). Its public half is authorized
  # on heimdall for graphify only and on mjolnir for the Blender MCP server only.
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
    # Claude Code's skills, memory notes (skill `claude-memory`) and homelab
    # context, copied from mjolnir by `claude-to-hermod`. Not in this repo: it is
    # public. The context lands in the workspace as AGENTS.md.
    settings.skills.external_dirs = [ "/var/lib/hermes/claude/skills" ];
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
      # Blender Lab MCP server on mjolnir: the key's forced command there starts
      # it, and it drives the extension on mjolnir's localhost:9876, so Blender
      # must be open on mjolnir. See hosts/mjolnir/modules/hermod-link.nix.
      blender = {
        command = "ssh";
        args = ssh ++ [ "christina@10.0.20.100" ];
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
  systemd.services.hermes-agent.serviceConfig.ReadWritePaths = [ "-/mnt/muninn" ];

  networking.firewall.allowedTCPPorts = [ 8642 ];

  users.users.christina.extraGroups = [ config.services.hermes-agent.group ];

  systemd.tmpfiles.rules = [
    "d /etc/hermes     0755 root root -"
    "f /etc/hermes/env 0600 root root -"
    "d /var/lib/hermes-ssh 0750 root hermes -"
    "z /var/lib/hermes-ssh/id_ed25519 0640 root hermes -"
    "d /var/lib/hermes/claude 2770 hermes hermes -"
  ];
}
