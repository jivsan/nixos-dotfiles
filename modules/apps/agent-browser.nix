{ inputs, pkgs, ... }:

# a headless browser for the agents on this box (claude, hermes, codex): `agent-browser open <url>`,
# `snapshot`, `screenshot`. chromium from nix is baked into the wrapper: agent-browser's own chrome
# download can't run on nixos
let
  agentBrowser = pkgs.symlinkJoin {
    name = "agent-browser";
    paths = [ inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agent-browser ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/agent-browser \
        --set-default AGENT_BROWSER_EXECUTABLE_PATH ${pkgs.chromium}/bin/chromium
    '';
  };
in
{
  environment.systemPackages = [ agentBrowser ];
  # for a service that needs it on its own path (hermes)
  _module.args.agentBrowser = agentBrowser;
}
