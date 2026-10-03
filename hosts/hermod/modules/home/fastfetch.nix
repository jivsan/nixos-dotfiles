{ ... }:

let
  pink = "38;2;255;79;163";   # #ff4fa3
  gold = "38;2;255;203;107";  # #ffcb6b
  cyan = "38;2;45;226;230";   # #2de2e6
  dim  = "38;2;99;99;125";    # muted steel
in
{
  programs.fastfetch = {
    enable = true;

    settings = {
      "$schema" = "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json";

      logo = {
        type = "file";
        source = "${./hermod.txt}";
        position = "top";
        padding = { top = 1; left = 2; };
        color = { "1" = pink; "2" = gold; "3" = cyan; "4" = dim; };
      };

      display = {
        separator = "  ";
        color.keys = cyan;
        percent.type = 9;   # colored % — green → yellow → red by usage
      };

      modules = [
        # ── identity ──────────────────────────────────────────────
        { type = "title"; color = { user = pink; at = dim; host = cyan; }; }
        { type = "custom"; format = "{#${dim}}⟨ {#${pink}}hermod{#${dim}} :: hermes agent — sandboxed on hella ⟩"; }
        { type = "separator"; string = "─"; }
        { type = "os";       key = " os";      keyColor = pink; }
        { type = "kernel";   key = " kernel";  keyColor = cyan; }
        { type = "packages"; key = "󰏖 pkgs";    keyColor = pink; }
        { type = "shell";    key = " shell";   keyColor = cyan; }
        { type = "uptime";   key = "󰔟 uptime";  keyColor = pink; }
        { type = "loadavg";  key = "󰓅 load";    keyColor = cyan; }
        "break"

        # ── deploy state ─────────────────────
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

        {
          type = "command";
          key = "☿ hermes";
          keyColor = gold;
          text = "s=$(systemctl is-active hermes-agent 2>/dev/null); [ \"$s\" = active ] && echo 'gateway running' || echo \"gateway $s\"";
        }
        {
          type = "command";
          key = "✦ model";
          keyColor = pink;
          text = "awk '/^model:/{f=1;next} f&&/default:/{d=$2} f&&/provider:/{p=$2} /^[a-z]/&&!/^model:/{f=0} END{print (d?d:\"unset\") (p?\" via \" p:\"\")}' /var/lib/hermes/.hermes/config.yaml 2>/dev/null || echo unknown";
        }
        {
          type = "command";
          key = "◈ vault";
          keyColor = cyan;
          text = "n=$(timeout 3 ls ~/muninn/_inbox 2>/dev/null | wc -l); [ -d ~/muninn/MOCs ] && echo \"muninn mounted, $n in inbox\" || echo 'muninn offline'";
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
        "break"

        { type = "colors"; paddingLeft = 2; symbol = "circle"; }
      ];
    };
  };
}
