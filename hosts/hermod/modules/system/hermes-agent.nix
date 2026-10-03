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
    environmentFiles = [ "/etc/hermes/env" ];
    mcpServers = {
      graphify-dotfiles = graphify "dotfiles";
      graphify-vault = graphify "vault";
    };
  };

  users.users.christina.extraGroups = [ config.services.hermes-agent.group ];

  systemd.tmpfiles.rules = [
    "d /etc/hermes     0755 root root -"
    "f /etc/hermes/env 0600 root root -"
  ];
}
