{ inputs, config, ... }:
{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;                          # puts the `hermes` CLI on PATH
    settings.model = {
      provider = "openai-codex";
      default = "gpt-6-astra";
    };
    environmentFiles = [ "/etc/hermes/env" ];            # secret file — NOT in git (you manage this)
  };

  users.users.christina.extraGroups = [ config.services.hermes-agent.group ];

  systemd.tmpfiles.rules = [
    "d /etc/hermes     0755 root root -"
    "f /etc/hermes/env 0600 root root -"
  ];
}
