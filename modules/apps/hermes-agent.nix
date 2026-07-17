{ inputs, config, ... }:
{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;                          # puts the `hermes` CLI on PATH
    settings.model.default = "openrouter/moonshotai/kimi-k3";
    environmentFiles = [ "/etc/hermes/env" ];            # secret file — NOT in git (you manage this)
  };
}
