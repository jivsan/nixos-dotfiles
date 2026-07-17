{ pkgs, ... }:
{
  programs.bash = {
    enable = true;
    shellAliases = {
      btw = "echo i use nixos, btw";
    };
    initExtra = ''
      PS1='\[\e[38;2;255;79;163m\][\u@\h:\[\e[38;2;45;226;230m\]\w\[\e[38;2;255;79;163m\]]\$\[\e[0m\] '
      fastfetch

        # Kimi/Moonshot key (chmod 600) — powers hermes CLI + claude-kimi
        [ -f ~/.config/moonshot.env ] && . ~/.config/moonshot.env

        # `claude` = Anthropic (me) · `claude-kimi` = Kimi direct
        claude-kimi() {
          ANTHROPIC_BASE_URL="https://api.moonshot.ai/anthropic" \
          ANTHROPIC_AUTH_TOKEN="$KIMI_API_KEY" \
          ANTHROPIC_MODEL="kimi-k3" \
          ANTHROPIC_SMALL_FAST_MODEL="kimi-k2.7-code-highspeed" \
          command claude "$@"
        }
    '';
  };

  home.packages = [ pkgs.fastfetch ];
}
