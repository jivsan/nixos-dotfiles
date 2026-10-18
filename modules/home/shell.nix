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

        # ComfyUI runs on demand — the container is autoStart=false so the
        # 4060 Ti's 8G of VRAM stays free for games until you actually want it.
        comfyui() {
          case "$1" in
            start)  sudo systemctl start podman-comfyui && echo "ComfyUI → http://127.0.0.1:8188" ;;
            stop)   sudo systemctl stop podman-comfyui && echo "ComfyUI stopped (VRAM released)" ;;
            status) systemctl status podman-comfyui --no-pager ;;
            logs)   sudo journalctl -u podman-comfyui -f ;;
            *)      echo "usage: comfyui {start|stop|status|logs}" ;;
          esac
        }

        # `claude` = Anthropic (me) · `claude-kimi` = Kimi K3 through OpenRouter.
        # @preset/claude-kimi (OpenRouter account preset) = Sail Research fp4 only,
        # no fallbacks; every tier maps to it so nothing falls back to a Claude model.
        # The key (~/.config/openrouter.env, chmod 600) is only loaded in this
        # subshell, not into every terminal. ArtifactData is left out: a regex in
        # its schema makes Sail Research hang with no answer (pings only).
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
