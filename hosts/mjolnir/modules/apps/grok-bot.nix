{ inputs, pkgs, ... }:

# grok bot, xai's desktop app for my bot team. numtide packages it next to codex and herdr, so it
# comes from their cache, not a download from x.ai. new versions come with the llm-agents flake
# update (renovate), the app can't update itself in the store.
# the bots work on xai's cloud computer, not here. two switches in the app reach this machine, keep
# both off (settings → computer → your computer): "execution on this computer" (commands on mjolnir,
# my keys and sudo) and "route traffic through this computer" (its web traffic out of my lan).
# no mcp servers here: those stay on the lan, for grok build on yggdrasil (hosts/yggdrasil/modules/system/grok.nix)
{
  nix.settings = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  environment.systemPackages = [ inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.grok-bot ];
}
