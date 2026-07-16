{ ... }:

let
  # Fleet neon accents (same family as mimir), girl-approved: pink hair, cyan braids
  pink = "38;2;255;79;163";   # #ff4fa3
  cyan = "38;2;45;226;230";   # #2de2e6
  dim  = "38;2;99;99;125";    # muted steel
in
{
  programs.fastfetch = {
    enable = true;

    settings = {
      "$schema" = "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json";

      logo = {
        # chafa-rendered anime girl (half-block ANSI), colors baked into the file
        type = "file-raw";
        source = "${./tyr-chan.txt}";
        padding = { top = 1; right = 4; };
      };

      display = {
        separator = "  ";
        color.keys = cyan;
        percent.type = 9;   # colored % — green → yellow → red by usage
      };

      modules = [
        # ── identity ──────────────────────────────────────────────
        { type = "title"; color = { user = pink; at = dim; host = cyan; }; }
        { type = "custom"; format = "{#${dim}}⟨ {#${pink}}tyr{#${dim}} :: test node — break things here ⟩"; }
        { type = "separator"; string = "─"; }
        { type = "os";       key = " os";      keyColor = pink; }
        { type = "kernel";   key = " kernel";  keyColor = cyan; }
        { type = "packages"; key = "󰏖 pkgs";    keyColor = pink; }
        { type = "shell";    key = " shell";   keyColor = cyan; }
        { type = "uptime";   key = "󰔟 uptime";  keyColor = pink; }
        { type = "loadavg";  key = "󰓅 load";    keyColor = cyan; }
        "break"

        # ── lab — what a test box cares about ─────────────────────
        {
          type = "command";
          key = "󰜉 gen";
          keyColor = pink;
          text = "readlink /nix/var/nix/profiles/system | grep -o '[0-9]\\+' | head -1 | xargs -I{} echo 'generation {}'";
        }
        {
          type = "command";
          key = " flake";
          keyColor = cyan;
          text = "git -C ~/nixos-dotfiles rev-parse --short HEAD 2>/dev/null || echo 'no clone'";
        }
        {
          type = "command";
          key = "󰚰 drift";
          keyColor = pink;
          text = "timeout 2 git -C ~/nixos-dotfiles fetch -q origin main 2>/dev/null; b=$(git -C ~/nixos-dotfiles rev-list --count HEAD..origin/main 2>/dev/null); [ \"$b\" = 0 ] && echo 'in sync with main' || echo \"$b commit(s) behind main\"";
        }
        {
          type = "command";
          key = "󰒋 units";
          keyColor = cyan;
          text = "f=$(systemctl --failed --no-legend | wc -l); [ \"$f\" = 0 ] && echo 'all green' || echo \"$f FAILED\"";
        }
        "break"

        # ── hardware ──────────────────────────────────────────────
        { type = "cpu";    key = "󰻠 cpu";    keyColor = pink;  format = "{name} ({cores-logical}t)"; }
        { type = "memory"; key = "󰑭 memory"; keyColor = cyan; }
        { type = "disk";   key = "󰋊 disk";   keyColor = pink;  folders = "/"; }
        "break"

        # ── network ───────────────────────────────────────────────
        {
          type = "localip";
          key = "󰩟 network";
          keyColor = cyan;
          showPrefixLen = true;
          namePrefix = "ens";
        }
        {
          type = "command";
          key = "󰖂 tailnet";
          keyColor = pink;
          text = "tailscale ip -4 2>/dev/null || echo offline";
        }
        "break"

        { type = "colors"; paddingLeft = 2; symbol = "circle"; }
      ];
    };
  };
}
