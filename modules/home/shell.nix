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

      # comfyui runs on demand (autoStart is off), so the vram stays free until i want it
      comfyui() {
        case "$1" in
          start)  sudo systemctl start podman-comfyui && echo "ComfyUI → http://127.0.0.1:8188" ;;
          stop)   sudo systemctl stop podman-comfyui && echo "ComfyUI stopped (VRAM released)" ;;
          status) systemctl status podman-comfyui --no-pager ;;
          logs)   sudo journalctl -u podman-comfyui -f ;;
          *)      echo "usage: comfyui {start|stop|status|logs}" ;;
        esac
      }

      # claude-kimi: claude code on kimi k3 through openrouter. my openrouter preset
      # @preset/claude-kimi is sail research fp4 only with no fallbacks, and every tier maps
      # to it, so nothing falls back to a claude model. the key (~/.config/openrouter.env,
      # chmod 600) only loads in this subshell. ArtifactData stays off: a regex in its
      # schema makes sail research hang without an answer.
      claude-kimi() (
        [ -f ~/.config/openrouter.env ] && . ~/.config/openrouter.env
        kimi="moonshotai/kimi-k3@preset/claude-kimi"
        ANTHROPIC_BASE_URL="https://openrouter.ai/api" \
        ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY" \
        ANTHROPIC_API_KEY="" \
        ANTHROPIC_MODEL="$kimi" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="$kimi" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$kimi" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="$kimi" \
        ANTHROPIC_SMALL_FAST_MODEL="$kimi" \
        CLAUDE_CODE_SUBAGENT_MODEL="$kimi" \
        command claude --disallowedTools ArtifactData "$@"
      )
    '';
  };

  home.packages = [ pkgs.fastfetch ];
}
