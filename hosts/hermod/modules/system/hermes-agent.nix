{ inputs, config, ... }:
let
  graphify = graph: {
    command = "ssh";
    args = [
      "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "christina@10.0.20.17"
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
    settings.model = {
      provider = "openai-codex";
      default = "gpt-6-astra";
    };
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
    };
  };

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
  ];
}
